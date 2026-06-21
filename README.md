# Zova

Zova is a Zig embedded data substrate built on SQLite.

Current package version: `0.10.0`.

Zova keeps SQLite as the durable relational core and adds native local storage
for objects and vectors in the same `.zova` file.

```text
SQLite records + Zova objects + Zova vectors
```

It is not a SQLite replacement, ORM, daemon, cloud service, or distributed
database. It is a source-only Zig package for applications that want one local
storage layer instead of a separate SQL database, object store, vector database,
and cleanup script pile.

## What Works In v0.10

Zova v0.10 includes:

- thin SQLite access through `zova.sqlite`
- `.zova` database create/open/validation through `zova.Database`
- SQLite-to-Zova conversion with source preservation
- content-addressed objects
- FastCDC-v1 chunking and chunk deduplication
- object manifests and verified chunk reads
- range reads for serving previews or partial content
- streaming object writes with `ObjectWriter`
- verified loose chunk ingest and object assembly from chunks
- native vector collections
- vector CRUD, batch upsert, collection info/list/delete
- exact vector search, candidate-filtered search, search-by-id, and thresholds
- C ABI for database, SQL, objects, chunks, writers, and vectors
- non-mutating CLI `info` and `check`
- source-only release packaging

The current `.zova` file format is still pre-1.0 and experimental. Current
files use `_zova_meta.format_version = '3'`. `Database.open` validates the
current private object/vector schema and does not repair, migrate, or lazily
initialize older experimental files.

## Install

Add Zova as a Zig package dependency, then import it by package name:

```zig
const zova = @import("zova");
```

Inside this repository the smoke executable imports source files directly, but
package users should use the public package surface exported by `src/root.zig`.

## Database Layers

Zova exposes two layers.

Use `zova.sqlite.Database` when you want a thin SQLite wrapper:

```zig
const sqlite = zova.sqlite;

var db = try sqlite.Database.open("app.db");
defer db.deinit();

try db.exec("create table notes (id integer primary key, body text not null)");
```

Use `zova.Database` when you want Zova objects and vectors:

```zig
var db = try zova.Database.create("app.zova");
defer db.deinit();
```

The boundary is file-level:

```text
*.zova  -> Zova database
other   -> plain SQLite database
```

Renaming `app.db` to `app.zova` is not enough. A valid Zova file must have Zova
metadata and the required private schema.

## Convert SQLite To Zova

Convert an existing SQLite database into a new `.zova` file:

```zig
try zova.convertSqliteToZova("app.db", "app.zova");
```

Conversion uses SQLite's backup API. It never mutates the source file and never
overwrites the destination. The destination must end in `.zova`.

Schemas that already use `_zova_*` names are rejected with
`error.ZovaNameConflict`, because those names are reserved for Zova internals.

Existing SQLite data stays SQLite data. Existing BLOB columns are not
automatically converted into Zova objects or vectors.

## SQL Remains SQLite SQL

`zova.Database` forwards basic SQL work to the underlying SQLite database:

```zig
try db.exec(
    \\create table attachments (
    \\  id integer primary key,
    \\  object_id blob not null,
    \\  filename text not null,
    \\  mime_type text not null
    \\)
);

var stmt = try db.prepare(
    "insert into attachments (object_id, filename, mime_type) values (?, ?, ?)",
);
defer stmt.deinit();
```

User tables stay yours. Zova private tables store only Zova-owned object, chunk,
and vector state.

## SQLite Wrapper

The SQLite wrapper intentionally stays close to SQLite's C API.

```zig
var db = try zova.sqlite.Database.open(":memory:");
defer db.deinit();

try db.exec("create table items (id integer primary key, name text not null)");
try db.exec("insert into items (name) values ('one')");

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
are copied into SQLite.

Transactions are explicit:

```zig
try db.beginImmediate();
try db.exec("insert into items (name) values ('two')");
try db.commit();
```

Raw SQLite remains available through `zova.sqlite.c` and public handles:

```zig
const c = zova.sqlite.c;
_ = c.sqlite3_total_changes64(db.handle);
```

## Objects

Zova objects are raw content-addressed bytes.

```text
Object -> FastCDC-v1 chunks -> SQLite BLOB chunk rows
```

An `ObjectId` is the raw `[32]u8` SHA-256 digest of the full object bytes. The
same bytes produce the same id.

Store and read a complete object:

```zig
const id = try db.putObject("hello object");

var object = try db.getObject(allocator, id);
defer object.deinit(allocator);

std.debug.assert(std.mem.eql(u8, object.bytes, "hello object"));
```

Check object metadata without loading bytes:

```zig
if (try db.hasObject(id)) {
    const size = try db.objectSize(id);
    const chunks = try db.objectChunkCount(id);
    std.debug.print("object: {} bytes in {} chunks\n", .{ size, chunks });
}
```

Read a byte range into caller-owned memory:

```zig
var preview: [16]u8 = undefined;
const copied = try db.readObjectRange(id, 0, &preview);
std.debug.print("copied {} preview bytes\n", .{copied});
```

`getObject` allocates the full object. `readObjectRange` does not allocate an
object-sized buffer and is the better API for previews, media serving, and
partial reads.

Delete removes Zova-owned object rows, manifest rows, and unreferenced chunks:

```zig
try db.deleteObject(id);
```

Zova never scans or mutates user SQL rows during object deletion. If your SQL
table still stores the deleted object id, that reference is application-owned
and later reads return `error.ObjectNotFound`.

## Object Manifests And Chunks

Objects have public manifests so applications can inspect or transfer chunks.

```zig
var manifest = try db.objectManifest(allocator, id);
defer manifest.deinit(allocator);

for (manifest.chunks) |chunk| {
    var data = try db.getObjectChunk(allocator, chunk.hash);
    defer data.deinit(allocator);
    // send or inspect data.bytes
}
```

Loose chunks can be stored before they belong to a complete object:

```zig
const hash = zova.objectChunkId(received_bytes);
try db.putObjectChunk(hash, received_bytes);
```

`putObjectChunk` verifies that the supplied bytes match the expected SHA-256
chunk hash. Empty chunks and chunks larger than the current FastCDC maximum are
rejected.

Assemble a complete object from already stored chunks:

```zig
try db.assembleObjectFromChunks(object_id, size_bytes, manifest_chunks);
```

Zova validates manifest shape, chunk existence, chunk hashes, offsets, sizes,
and the final full-object SHA-256 before inserting the object row and manifest
rows.

Remove unreferenced loose chunks explicitly:

```zig
const deleted = try db.deleteObjectChunk(chunk_hash);
```

`deleteObjectChunk` returns `false` when the chunk is missing or still
referenced by an object.

## ObjectWriter

Use `putObject` when the full byte slice is already in memory. Use
`ObjectWriter` when bytes arrive over time and should not be held in one
object-sized buffer.

```zig
var writer = try db.objectWriter(allocator);
defer writer.deinit();

try writer.write(first_part);
try writer.write(second_part);

const id = try writer.finish();
```

The writer uses the same FastCDC-v1 boundaries as `putObject`, stores verified
chunks as they are emitted, and finishes by assembling the object from those
chunks. It keeps memory bounded around the streaming buffer, chunk data, and
manifest metadata.

Cancel unfinished writes:

```zig
try writer.cancel();
```

`cancel` removes unreferenced chunks seen by that writer and preserves chunks
already referenced by objects. `deinit` automatically cancels unfinished writers.
After `finish` or `cancel`, further writer operations return
`error.ObjectWriterClosed`.

## Application Metadata

Zova object APIs store bytes, identities, chunks, and manifests. Application
metadata belongs in user SQL tables.

Examples of application-owned metadata:

- filenames
- MIME types
- owners
- labels
- document ids
- transfer sessions
- retry state
- permissions
- UI progress

The intended model is:

```text
user SQL row -> object_id blob -> Zova object bytes
user SQL row -> vector_id text -> Zova vector values
```

## Vectors

Zova vectors follow a pgvector-style model:

```text
SQL filters metadata
Zova ranks vector ids by distance
application joins ids back to SQL rows
```

Create a collection:

```zig
try db.createVectorCollection("chunks", .{
    .dimensions = 3,
    .metric = .cosine,
});
```

Supported metrics:

- `.cosine` with distance `1 - cosine_similarity`
- `.l2` with Euclidean distance
- `.dot` with distance `-dot_product`

Vectors are stored as deterministic little-endian `f32` BLOBs in private Zova
tables. Collection names and vector ids are UTF-8 text. Vector ids are scoped to
their collection and are application-provided.

Put and get vectors:

```zig
try db.putVector("chunks", "chunk-001", &.{ 0.1, 0.2, 0.3 });

var vector = try db.getVector(allocator, "chunks", "chunk-001");
defer vector.deinit(allocator);
```

Batch upsert vectors:

```zig
try db.putVectors("chunks", &.{
    .{ .id = "chunk-001", .values = &.{ 0.1, 0.2, 0.3 } },
    .{ .id = "chunk-002", .values = &.{ 0.2, 0.3, 0.4 } },
});
```

`putVectors` validates the collection and every input row before writing. It
uses the same upsert behavior as `putVector`; duplicate ids in one batch are
applied in input order, so the last entry wins. It does not own a transaction,
so callers can wrap it in `beginImmediate` / `commit` when they want atomic
application-level work.

Inspect collections:

```zig
var info = try db.vectorCollectionInfo(allocator, "chunks");
defer info.deinit(allocator);

var collections = try db.listVectorCollections(allocator);
defer collections.deinit(allocator);
```

Delete a collection:

```zig
try db.deleteVectorCollection("chunks");
```

This deletes private vector rows and the collection row. It does not scan or
mutate user SQL tables that reference those vector ids.

## Vector Search

Collection-wide exact search:

```zig
var results = try db.searchVectors(
    allocator,
    "chunks",
    &.{ 0.1, 0.2, 0.3 },
    10,
);
defer results.deinit(allocator);
```

Results are sorted by ascending distance, then ascending vector id. Returned ids
are owned memory and must be freed with `VectorSearchResults.deinit`.

Candidate-filtered search:

```zig
const candidates = [_][]const u8{ "chunk-001", "chunk-004", "chunk-009" };

var filtered = try db.searchVectorsIn(
    allocator,
    "chunks",
    &.{ 0.1, 0.2, 0.3 },
    &candidates,
    5,
);
defer filtered.deinit(allocator);
```

This is the practical SQL-first path:

1. Query your metadata tables with SQL.
2. Collect candidate vector ids.
3. Let Zova rank only those candidates.
4. Join returned ids back to your SQL rows.

Search by an existing vector id:

```zig
var neighbors = try db.searchVectorsById(
    allocator,
    "chunks",
    "chunk-001",
    10,
);
defer neighbors.deinit(allocator);
```

The source vector is excluded from results. Candidate-filtered search by id is
also available:

```zig
var related = try db.searchVectorsByIdIn(
    allocator,
    "chunks",
    "chunk-001",
    &candidates,
    10,
);
defer related.deinit(allocator);
```

Threshold search is inclusive:

```zig
var close = try db.searchVectorsWithin(
    allocator,
    "chunks",
    &.{ 0.1, 0.2, 0.3 },
    0.25,
    10,
);
defer close.deinit(allocator);
```

Threshold variants exist for candidate-filtered search and search-by-id:

```zig
var close_related = try db.searchVectorsByIdInWithin(
    allocator,
    "chunks",
    "chunk-001",
    &candidates,
    0.25,
    10,
);
defer close_related.deinit(allocator);
```

`limit = 0` returns an empty result set after validating the collection and
query. Missing candidate ids are skipped. Invalid candidate ids return
`error.VectorInvalid`. Corrupt selected vector rows return
`error.VectorCorrupt`.

## CLI

The `zova` executable is a non-mutating inspection/check tool.

```sh
zig build run
```

Command shape:

```sh
zig-out/bin/zova --version
zig-out/bin/zova --help
zig-out/bin/zova info app.zova
zig-out/bin/zova check app.zova
zig-out/bin/zova check --deep app.zova
```

`info` prints bounded text output:

- package version
- SQLite version
- Zova format version
- object/chunk/vector counts
- loose chunk count
- stored chunk bytes
- user table count

It does not print object bytes, vector values, or private schema SQL.

`check` validates Zova identity/schema and runs SQLite `PRAGMA quick_check`.
`check --deep` also validates object manifests, referenced chunks, full object
hashes, loose chunks as informational state, and vector row shape/finite values.

Exit codes:

- `0`: success or healthy file
- `1`: unexpected internal error
- `2`: usage error
- `3`: open, path, Zova identity, or unsupported version error
- `4`: integrity or corruption check failure

The CLI does not repair, migrate, delete loose chunks, rebuild manifests, run
`VACUUM`, change PRAGMAs, or mutate `.zova` files in v0.10.

## C ABI

Zova ships a pre-1.0 C ABI for future language bindings.

Files and build steps:

- `include/zova.h`
- `src/c_api.zig`
- `zig build c-abi`
- `zig build c-abi-test`

The C ABI exposes:

- database create/open/close
- SQL `exec`
- SQLite-to-Zova conversion
- object put/get/delete/existence/size/chunk count
- range reads
- manifests and chunk reads
- verified loose chunk ingest
- object assembly from verified chunks
- `ObjectWriter`
- vector collection create/exists/info/list/delete
- vector put/get/exists/delete
- batch vector put
- collection-wide exact vector search
- candidate-filtered exact vector search
- search by existing vector id
- inclusive threshold search

Inputs are borrowed for the duration of each call. Paths and SQL use
null-terminated C strings. Object bytes use pointer plus length. Vector values
use `const float *values` plus `size_t values_len`.

Returned buffers, messages, manifests, vectors, collection info, collection
lists, and search results are owned by Zova and must be freed explicitly:

```c
zova_buffer_free(&buffer);
zova_message_free(&message);
zova_object_manifest_free(&manifest);
zova_vector_free(&vector);
zova_vector_collection_info_free(&info);
zova_vector_collection_list_free(&list);
zova_vector_search_results_free(&results);
```

Minimal C vector example:

```c
zova_vector_collection_create_request create = {
    .db = db,
    .name = "chunks",
    .options = { .dimensions = 3, .metric = ZOVA_VECTOR_METRIC_COSINE },
};
zova_vector_collection_create(&create);

const float a[3] = {0.1f, 0.2f, 0.3f};
const float b[3] = {0.2f, 0.3f, 0.4f};

zova_vector_input rows[] = {
    { .id = "chunk-001", .values = a, .values_len = 3 },
    { .id = "chunk-002", .values = b, .values_len = 3 },
};

zova_vector_put_many_request put_many = {
    .db = db,
    .collection_name = "chunks",
    .vectors = rows,
    .vectors_len = 2,
};
zova_vector_put_many(&put_many);

zova_vector_search_results results = {0};
zova_vector_search_by_id_within_request search = {
    .db = db,
    .collection_name = "chunks",
    .source_vector_id = "chunk-001",
    .max_distance = 0.25,
    .limit = 10,
    .out_results = &results,
};
zova_vector_search_by_id_within(&search);
zova_vector_search_results_free(&results);
```

Every C ABI function returns `zova_status`. `ZOVA_OK` means success.
`zova_status_name(status)` returns a static status name.

Database-scoped diagnostics:

```c
const char *message = zova_database_last_error_message(db);
```

The pointer is borrowed and valid until the next call on that database handle or
until close. Create/open/convert failures can also return an owned
`zova_message` through their request structs.

Handles are opaque. Do not use the same database or writer handle concurrently
from multiple threads. Multiple database handles to the same file are allowed
and follow SQLite locking.

The ABI is additive and pre-1.0. Rust, Go, TypeScript, and Swift bindings remain
future work.

## Vendored SQLite

Zova builds against the vendored SQLite amalgamation in `vendor/sqlite3.53.2`.

The build enables:

- `SQLITE_THREADSAFE=1`
- `SQLITE_ENABLE_FTS5`

Modern SQLite JSON support is built in for this SQLite version, so the old
`SQLITE_ENABLE_JSON1` flag is not required.

FTS5 and JSON are available as normal SQLite SQL. Zova does not add a separate
FTS or JSON API.

## Errors

SQLite wrapper errors include:

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

Zova database errors include:

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

## Testing

Run unit/integration tests:

```sh
zig build test
```

Run file-backed end-to-end tests:

```sh
zig build e2e
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

Run the smoke executable:

```sh
zig build run
```

Run the full release smoke:

```sh
scripts/check-release.sh
```

## Release Package Policy

v0.10 releases a source-only package/archive. The package includes:

- `README.md`
- `build.zig`
- `build.zig.zon`
- `include`
- `src`
- `tests`
- `vendor`

`README.md` is the only markdown file included in the release package. Planning
notes stay outside the package.

Compiled CLI binaries and compiled C ABI libraries are not release artifacts.
Consumers build the CLI or static C ABI library from source with Zig.

The release script:

```sh
scripts/package-release.sh 0.10.0
```

tags the current commit, pushes the branch and tag, creates a source archive,
and creates the GitHub release. Do not run it until the exact commit you want
to release is ready.

## Non-Goals In v0.10

Zova v0.10 does not include:

- ANN indexes
- HNSW or IVFFlat
- vector SQL operators
- SQLite virtual table integration
- embedding generation
- Rust, Go, TypeScript, or Swift bindings
- repair commands
- orphan scan CLI
- object compression or encryption
- remote sync
- daemon mode
- S3 compatibility
- Redis-like behavior
- NATS integration
- compiled release artifacts

## Design Philosophy

SQLite owns relational truth. Zova owns native local content that SQLite apps
usually bolt on by hand:

```text
records -> SQLite tables
objects -> content-addressed chunked bytes
vectors -> exact local similarity search
metadata -> user SQL tables
inspection -> non-mutating CLI
interop -> C ABI
```

The goal is not to hide SQLite. The goal is to make records, objects, and
vectors coexist in one embedded local storage layer without extra services.
