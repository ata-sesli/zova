# Zova

Zova is a Zig embedded data substrate built on SQLite.

Current package version: `0.9.0`.

Zova keeps SQLite as the foundation and adds native content types on top:

- plain SQLite access through `zova.sqlite`
- `.zova` database identity and validation through `zova.Database`
- content-addressed objects stored as FastCDC chunks
- an object streaming writer for large caller-owned byte streams
- verified loose chunk ingest and object assembly for transfer workflows
- native `f32` vector collections, CRUD, and exact search
- a C ABI foundation for object workflows
- a non-mutating inspection/check CLI

SQL is still normal SQLite SQL. User tables stay yours. Zova does not replace
SQLite with a new query language, ORM, migration system, or background service.

## Status

Zova is pre-1.0. The public API is intentionally small, but the internal
`.zova` file format is still experimental. Current `.zova` files use
`_zova_meta.format_version = '3'` and must contain the required private object
and vector schema. `Database.open` validates the current format and does not
repair, migrate, or lazily initialize older files.

Use this package when you want one SQLite-backed file that can hold relational
rows, raw byte objects, chunk manifests, and vectors without running separate
databases or services.

## Install

Add Zova as a Zig package dependency, then import it by package name:

```zig
const zova = @import("zova");
```

Inside this repository, the smoke executable imports source files directly, but
package users should use the `zova` package surface exported by `src/root.zig`.

## Database Layers

Zova has two database layers.

Use `zova.sqlite.Database` for a thin SQLite wrapper:

```zig
const sqlite = zova.sqlite;

var db = try sqlite.Database.open("app.db");
defer db.deinit();

try db.exec("create table if not exists notes (id integer primary key, body text not null)");
```

Use `zova.Database` for `.zova` files:

```zig
var db = try zova.Database.create("app.zova");
defer db.deinit();
```

The boundary is file-level:

```text
*.zova  -> Zova-owned database
other   -> plain SQLite database
```

Renaming `app.db` to `app.zova` is not enough. Zova validates private metadata
and required private schema before treating a file as Zova-owned.

## Convert SQLite To Zova

Convert an existing SQLite database into a new `.zova` file:

```zig
try zova.convertSqliteToZova("app.db", "app.zova");
```

Conversion uses SQLite's backup API, initializes Zova metadata in the
destination, and never mutates the source database. The destination must end in
`.zova` and must not already exist.

Source schemas that already use names reserved for Zova internals, such as
`_zova_meta` or other `_zova_*` names, are rejected with
`error.ZovaNameConflict`.

Conversion preserves SQLite data as SQLite data. Existing BLOB columns remain
normal SQLite BLOB columns. Zova does not automatically turn user BLOBs into
objects or vectors.

## Normal SQL Still Works

`zova.Database` forwards basic SQL operations to the underlying SQLite wrapper:

```zig
try db.exec(
    \\create table attachments (
    \\  id integer primary key,
    \\  object_id blob not null,
    \\  filename text not null,
    \\  mime_type text not null
    \\)
);

var stmt = try db.prepare("insert into attachments (object_id, filename, mime_type) values (?, ?, ?)");
defer stmt.deinit();
```

Application metadata belongs in user SQL tables. Zova private tables store only
Zova-owned object, chunk, and vector state.

## Objects

Zova objects are raw content-addressed bytes:

```text
Object -> FastCDC chunk manifest -> SQLite BLOB chunk rows
```

An `ObjectId` is the raw `[32]u8` SHA-256 digest of the full object bytes. The
same bytes produce the same id.

Store and read an object:

```zig
const id = try db.putObject("hello object");

var object = try db.getObject(allocator, id);
defer object.deinit(allocator);

std.debug.assert(std.mem.eql(u8, object.bytes, "hello object"));
```

Check object metadata without loading the full object:

```zig
if (try db.hasObject(id)) {
    const size = try db.objectSize(id);
    const chunks = try db.objectChunkCount(id);
    std.debug.print("object: {} bytes in {} chunks\n", .{ size, chunks });
}
```

Read a byte range into your own buffer:

```zig
var preview: [16]u8 = undefined;
const copied = try db.readObjectRange(id, 0, &preview);
std.debug.print("copied {} preview bytes\n", .{copied});
```

`getObject` allocates the full object. `readObjectRange` does not allocate the
full object and is the preferred API for previews, media serving, and partial
reads. `offset == object_size` returns `0`; `offset > object_size` returns
`error.ObjectRangeInvalid`.

Delete removes Zova-owned object rows, manifest rows, and unreferenced chunks.
It never scans or mutates user SQL rows:

```zig
try db.deleteObject(id);
```

User tables may still contain old object ids after deletion. Those references
are application-owned and will return `error.ObjectNotFound` if loaded later.

## Object Streaming Writer

Use `putObject` when the full byte slice is already in memory. Use
`ObjectWriter` when the caller receives or produces bytes in pieces and should
not keep the whole object in one buffer.

```zig
var writer = try db.objectWriter(allocator);
defer writer.deinit();

try writer.write(first_part);
try writer.write(second_part);

const id = try writer.finish();
```

`ObjectWriter` computes the final `ObjectId` incrementally, cuts bytes with the
same `fastcdc-v1` rules as `putObject`, stores verified chunks as they are
emitted, and finishes by assembling the object from those chunks. It keeps
memory bounded around the streaming buffer, chunk data, and manifest metadata;
it does not allocate an object-sized buffer.

The writer does not hold a long transaction while bytes are being written.
`objectWriter`, `write`, and `finish` return `error.ObjectTransactionActive`
when the connection is already inside a user transaction. `finish` returns the
existing id successfully if the same valid object is already stored, matching
`putObject`.

Cancel unfinished writes explicitly:

```zig
try writer.cancel();
```

`cancel` removes unreferenced chunks seen by that writer and preserves chunks
that are already referenced or existed before the writer. `deinit` automatically
cancels unfinished writers. After `finish` or `cancel`, further writer
operations return `error.ObjectWriterClosed`.

Use receive-side chunk assembly when chunks arrive as externally identified
transfer units:

```text
have all bytes now        -> putObject(bytes)
produce bytes over time   -> ObjectWriter
receive verified chunks   -> putObjectChunk + app SQL transfer state + assembleObjectFromChunks
```

In every path, filenames, MIME types, owners, transfer sessions, retry state,
and final object references belong in application SQL tables.

## Manifests And Chunks

Object manifests expose the public chunk layout:

```zig
var manifest = try db.objectManifest(allocator, id);
defer manifest.deinit(allocator);

for (manifest.chunks) |chunk| {
    var data = try db.getObjectChunk(allocator, chunk.hash);
    defer data.deinit(allocator);

    std.debug.print("chunk {}: {} bytes\n", .{ chunk.index, data.bytes.len });
}
```

`objectManifest` validates manifest shape: indexes, offsets, sizes, row
presence, and the `fastcdc-v1` chunker. `getObjectChunk` verifies
`SHA-256(chunk_bytes) == chunk.hash`.

Chunk ids are raw `[32]u8` SHA-256 digests of chunk bytes:

```zig
const chunk_hash = zova.objectChunkId(chunk_bytes);
```

Use `std.fmt.fmtSliceHexLower(&id)` or
`std.fmt.fmtSliceHexLower(&chunk_hash)` when you need displayable hex.

## Receive-Side Object Assembly

Zova supports verified loose chunks. This is useful for applications that
receive object chunks before the full object is ready.

Store a verified chunk:

```zig
const chunk_hash = zova.objectChunkId(received_bytes);
try db.putObjectChunk(chunk_hash, received_bytes);
```

`putObjectChunk` rejects empty chunks, chunks larger than Zova's current
FastCDC maximum, and bytes whose SHA-256 does not match the expected hash. It
is idempotent for already stored valid chunks. It does not create an object row
or manifest row.

Once the application has every expected chunk, assemble the complete object:

```zig
try db.assembleObjectFromChunks(object_id, total_size, manifest.chunks);
```

Assembly consumes existing verified chunks only. It validates the supplied
manifest, verifies stored chunk bytes, hashes the assembled stream, and creates
the object row plus manifest rows in one owned transaction.

Typical sender/receiver flow:

```text
sender:   putObject(bytes)
sender:   objectManifest(id)
sender:   getObjectChunk(hash) for each manifest chunk

receiver: app SQL tracks transfer state
receiver: putObjectChunk(hash, bytes) as chunks arrive
receiver: assembleObjectFromChunks(id, size, chunks)
receiver: app SQL stores final object_id
```

Transfer sessions, peer state, retry counters, missing chunk lists, filenames,
MIME types, and UI progress belong in application SQL tables. Zova stores
verified chunks and complete objects; it does not define a network protocol.

Clean up loose chunks explicitly:

```zig
const deleted = try db.deleteObjectChunk(chunk_hash);
```

`deleteObjectChunk` returns `true` only when it removed an unreferenced chunk.
It returns `false` for missing chunks or chunks referenced by any object
manifest.

## Vectors

Zova vectors follow the pgvector-style model: vectors are native searchable
numeric values, while labels and metadata stay in user SQL tables.

Create a collection:

```zig
try db.createVectorCollection("chunks", .{
    .dimensions = 3,
    .metric = .cosine,
});
```

Store vectors with application-provided text ids:

```zig
const chunk_001 = [_]f32{ 0.1, 0.2, 0.3 };
const chunk_002 = [_]f32{ 0.2, 0.1, 0.4 };

try db.putVector("chunks", "chunk-001", &chunk_001);
try db.putVector("chunks", "chunk-002", &chunk_002);
```

Vector ids are scoped to a collection. `putVector` is an upsert: the same
collection and vector id replaces previous values.

Search exactly:

```zig
const query = [_]f32{ 0.1, 0.2, 0.25 };
var results = try db.searchVectors(allocator, "chunks", &query, 10);
defer results.deinit(allocator);

for (results.items) |result| {
    std.debug.print("{s}: {}\n", .{ result.id, result.distance });
}
```

Search is collection-wide and exact. Distances are lower-is-better:

- cosine: `1 - cosine_similarity`
- l2: Euclidean distance
- dot: negative dot product

Equal distances are ordered by vector id text. Result ids are owned memory and
must be freed with `VectorSearchResults.deinit`.

Vectors are stored as deterministic little-endian `f32` BLOBs. Zova rejects
dimension mismatches, non-finite values, and all-zero vectors in cosine
collections. The current maximum dimension count is
`zova.max_vector_dimensions`, currently `16_384`.

Example with SQL metadata:

```zig
try db.exec(
    \\create table chunks (
    \\  id text primary key,
    \\  object_id blob not null,
    \\  vector_id text not null,
    \\  text text not null,
    \\  source text not null
    \\)
);

try db.putVector("chunks", "chunk-001", embedding);

var search = try db.searchVectors(allocator, "chunks", query_embedding, 5);
defer search.deinit(allocator);

// Use search.items[n].id to query your SQL metadata table.
```

Zova does not generate embeddings and does not store labels, JSON payloads,
owners, timestamps, filenames, or application metadata in vector private
tables.

## SQLite Wrapper

The plain wrapper is available as `zova.sqlite`.

Open a database:

```zig
var db = try zova.sqlite.Database.open(":memory:");
defer db.deinit();
```

Execute SQL:

```zig
try db.exec("create table items (id integer primary key, name text not null)");
try db.exec("insert into items (name) values ('one')");
```

Prepare and bind:

```zig
var stmt = try db.prepare("select id, name from items where name = ?");
defer stmt.deinit();

try stmt.bindText(1, "one"); // parameters are 1-based

while (try stmt.step() == .row) {
    const id = stmt.columnInt64(0); // columns are 0-based
    const name = stmt.columnText(1);
    std.debug.print("{} {s}\n", .{ id, name });
}
```

Text and blob column slices are borrowed from SQLite and are valid until the
statement is stepped, reset, cleared, or finalized. Bound text and blob values
are copied into SQLite, so caller buffers do not need to outlive the bind call.

Transactions are explicit:

```zig
try db.beginImmediate();
try db.exec("insert into items (name) values ('two')");
try db.commit();
```

Raw SQLite remains available:

```zig
const c = zova.sqlite.c;
_ = c.sqlite3_total_changes64(db.handle);
```

This is an escape hatch for APIs Zova does not wrap yet.

## C ABI

v0.9 adds a pre-1.0 C ABI foundation for object workflows. It is designed for
future Rust bindings and other host languages, but it is not a permanent stable
ABI promise yet.

The C ABI lives in:

- `include/zova.h`
- `src/c_api.zig`
- `zig build c-abi`
- `zig build c-abi-test`

The v0.9 C ABI exposes:

- database create/open/close
- SQL `exec`
- SQLite-to-Zova conversion
- object put/get/delete/existence/size/chunk count
- range reads
- manifests and chunk reads
- verified loose chunk ingest
- object assembly from verified chunks
- `ObjectWriter`

Vector APIs are intentionally not part of the v0.9 C ABI. A future low-level
`zova-sys` crate and safe Rust crate can wrap this boundary, but v0.9 ships no
Rust crate and no RChat adapter.

C inputs are borrowed for the duration of the call. Paths and SQL use
null-terminated C strings. Arbitrary bytes use pointer plus length. Returned
buffers, messages, and manifests are owned by Zova and must be released with
their matching free function:

```c
zova_buffer_free(&buffer);
zova_message_free(&message);
zova_object_manifest_free(&manifest);
```

Database and writer handles are opaque. Close or destroy them explicitly:

```c
zova_database_close(db);
zova_object_writer_destroy(writer);
```

Every C ABI function returns `zova_status`. `ZOVA_OK` means success. SQLite and
Zova failures map to explicit status values such as `ZOVA_BUSY`,
`ZOVA_CONSTRAINT`, `ZOVA_OBJECT_NOT_FOUND`, and `ZOVA_OBJECT_CORRUPT`.
`zova_status_name(status)` returns a static status name.

For database-scoped diagnostics, use:

```c
const char *message = zova_database_last_error_message(db);
```

That pointer is borrowed and valid until the next call on that database handle
or until close. Create/open/convert failures can also return an owned
`zova_message` through their request structs.

Minimal C object example:

```c
zova_database *db = NULL;
zova_message message = {0};

zova_database_open_request open_req = {
    .path = "app.zova",
    .out_db = &db,
    .out_error_message = &message,
};
zova_status status = zova_database_create(&open_req);
zova_message_free(&message);
if (status != ZOVA_OK) return 1;

zova_database_exec_request sql = {
    .db = db,
    .sql = "create table files (id integer primary key, object_id blob not null)",
};
if (zova_database_exec(&sql) != ZOVA_OK) return 1;

const uint8_t bytes[] = "hello";
zova_object_id id = {0};
zova_object_put_request put = {
    .db = db,
    .data = bytes,
    .len = sizeof(bytes) - 1,
    .out_id = &id,
};
if (zova_object_put(&put) != ZOVA_OK) return 1;

uint8_t preview[5] = {0};
size_t copied = 0;
zova_object_read_range_request range = {
    .db = db,
    .id = id,
    .offset = 0,
    .buffer = preview,
    .buffer_len = sizeof(preview),
    .out_copied = &copied,
};
if (zova_object_read_range(&range) != ZOVA_OK) return 1;

zova_buffer object = {0};
zova_object_get_request get = {
    .db = db,
    .id = id,
    .out_buffer = &object,
};
if (zova_object_get(&get) != ZOVA_OK) return 1;
zova_buffer_free(&object);

zova_database_close(db);
```

Manifest/chunk and assembly flow:

```c
zova_object_manifest manifest = {0};
zova_object_manifest_get_request manifest_req = {
    .db = db,
    .id = id,
    .out_manifest = &manifest,
};
if (zova_object_manifest_get(&manifest_req) != ZOVA_OK) return 1;

zova_buffer chunk = {0};
zova_object_chunk_get_request chunk_req = {
    .db = db,
    .hash = manifest.chunks[0].hash,
    .out_buffer = &chunk,
};
if (zova_object_chunk_get(&chunk_req) != ZOVA_OK) return 1;

zova_object_chunk_put_request loose = {
    .db = db,
    .expected_hash = manifest.chunks[0].hash,
    .data = chunk.data,
    .len = chunk.len,
};
if (zova_object_chunk_put(&loose) != ZOVA_OK) return 1;

zova_object_assemble_from_chunks_request assemble = {
    .db = db,
    .id = id,
    .size_bytes = manifest.size_bytes,
    .chunks = manifest.chunks,
    .chunk_count = manifest.chunks_len,
};
/* Existing valid objects return ZOVA_OBJECT_ALREADY_EXISTS. */
status = zova_object_assemble_from_chunks(&assemble);

zova_buffer_free(&chunk);
zova_object_manifest_free(&manifest);
```

Streaming writer flow:

```c
zova_object_writer *writer = NULL;
zova_object_writer_create_request create_writer = {
    .db = db,
    .out_writer = &writer,
};
if (zova_object_writer_create(&create_writer) != ZOVA_OK) return 1;

zova_object_writer_write_request write = {
    .writer = writer,
    .data = bytes,
    .len = sizeof(bytes) - 1,
};
if (zova_object_writer_write(&write) != ZOVA_OK) return 1;

zova_object_id streamed = {0};
zova_object_writer_finish_request finish = {
    .writer = writer,
    .out_id = &streamed,
};
if (zova_object_writer_finish(&finish) != ZOVA_OK) return 1;

zova_object_writer_destroy(writer);
```

## Error Shape

Zova keeps errors small and direct.

SQLite wrapper errors include common result-code mappings such as:

- `error.Busy`
- `error.Locked`
- `error.Constraint`
- `error.CantOpen`
- `error.ReadOnly`
- `error.Corrupt`
- `error.NoMemory`
- `error.Interrupt`
- `error.Misuse`
- `error.SqliteError`

Zova database errors include file identity, object, chunk, and vector failures,
such as:

- `error.NotZovaPath`
- `error.NotZovaDatabase`
- `error.UnsupportedZovaVersion`
- `error.DestinationExists`
- `error.ZovaNameConflict`
- `error.ObjectNotFound`
- `error.ObjectAlreadyExists`
- `error.ObjectChunkNotFound`
- `error.ObjectChunkHashMismatch`
- `error.ObjectCorrupt`
- `error.ObjectManifestInvalid`
- `error.ObjectRangeInvalid`
- `error.ObjectTooLarge`
- `error.ObjectTransactionActive`
- `error.ObjectWriterClosed`
- `error.VectorCollectionExists`
- `error.VectorCollectionNotFound`
- `error.VectorNotFound`
- `error.VectorDimensionMismatch`
- `error.VectorCorrupt`
- `error.VectorInvalid`

For SQLite failures, `db.errorMessage()` exposes SQLite's current diagnostic
message.

## CLI

v0.9 turns the `zova` executable into a non-mutating inspection/check CLI.

```sh
zig build run
```

`zig build run` is the release smoke and prints the version. Built directly,
the command shape is:

```sh
zig-out/bin/zova --version
zig-out/bin/zova --help
zig-out/bin/zova info app.zova
zig-out/bin/zova check app.zova
zig-out/bin/zova check --deep app.zova

zova --version
zova --help
zova info app.zova
zova check app.zova
zova check --deep app.zova
```

`info` prints bounded text output: package version, SQLite version, Zova format
version, object/chunk/vector counts, loose chunk count, stored chunk bytes, and
user table count. It does not print object bytes, vector values, or private
schema SQL.

`check` validates Zova identity/schema and runs SQLite `PRAGMA quick_check`.
`check --deep` also validates object manifests, referenced chunks, full object
hashes, loose chunks as informational state, and vector row shape/finite
values.

Exit codes:

- `0`: success or healthy file
- `1`: unexpected internal error
- `2`: usage error
- `3`: open, path, Zova identity, or unsupported version error
- `4`: integrity or corruption check failure

The CLI does not repair, migrate, delete loose chunks, rebuild manifests, run
`VACUUM`, change application data, or mutate `.zova` files in v0.9.

## Vendored SQLite

Zova builds against the vendored SQLite amalgamation in `vendor/sqlite3.53.2`.

The build enables:

- `SQLITE_THREADSAFE=1`
- `SQLITE_ENABLE_FTS5`

Modern SQLite JSON support is built in for this SQLite version, so the old
`SQLITE_ENABLE_JSON1` flag is not required.

FTS5 is available as normal SQLite SQL. Zova does not add a separate FTS API.

## Testing

Run unit and integration tests:

```sh
zig build test
```

Run realistic file-backed end-to-end tests:

```sh
zig build e2e
```

Run the smoke executable:

```sh
zig build run
```

Run CLI tests:

```sh
zig build cli-test
```

Build and test the C ABI:

```sh
zig build c-abi
zig build c-abi-test
```

Run the release smoke:

```sh
scripts/check-release.sh
```

## Release Package Policy

v0.9 releases a source-only package/archive. The package includes `README.md`,
`build.zig`, `build.zig.zon`, `include`, `src`, `tests`, and `vendor`.

`README.md` is the only markdown file included in the release package. Planning
notes stay outside the package.

Compiled CLI binaries and compiled C ABI libraries are not release artifacts in
v0.9. Consumers build the CLI or static C ABI library from source with Zig.

The release smoke formats sources, runs tests, runs E2E tests, builds and runs
the smoke executable, creates a source-package candidate, and verifies that
candidate from extraction.

## Release Package Policy

Zova releases a Zig source package.

The release archive contains:

- `README.md`
- build files
- `src`
- `tests`
- `vendor`

`README.md` is the only Markdown file included in the release archive. Planning
notes and version checklists are kept out of the package. The CLI executable is
built and run only as a smoke test; compiled CLI binaries are not release
artifacts.

## Not In This Release

Zova v0.8 does not include:

- peer protocol or transfer session tables
- transfer retry engine
- Rust crate or C ABI
- RChat adapter
- inspection/check CLI
- object repair or orphan scan CLI
- compression or encryption
- remote sync
- vector ANN index
- vector candidate filtering
- vector SQL virtual table integration
- embedding generation
- schema migrations for older experimental `.zova` files
- automatic migration from SQL BLOB columns, external chunk directories, or
  RChat storage

Those are future layers. The current release focuses on a small, inspectable
SQLite-backed core.
