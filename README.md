# Zova

SQLite-backed embedded database for records, objects, and vectors in one local
file.

Zova keeps SQLite as the relational core, then adds native local storage for
content-addressed objects, chunk manifests, streaming writes, and exact vector
search. Applications keep their own metadata in normal SQL tables and store
Zova object ids or vector ids alongside their rows.

Current package version: `0.11.0`.

Zova is not tied to one application language. The project exposes:

- a native Zig API
- a C ABI in `include/zova.h`
- a non-mutating CLI for inspection and checks
- a source-only release package that consumers build locally

Rust, Go, TypeScript, and Swift bindings are planned as layers over the C ABI.

## Architecture

```mermaid
flowchart TD
    App["Application"]
    SQL["User SQL tables<br/>records and metadata"]
    ZovaAPI["Zova API<br/>native Zig or C ABI"]
    CLI["zova CLI<br/>info, stats, inspect, check"]
    DB["local .zova file<br/>SQLite database"]
    Meta["_zova_meta<br/>identity and format"]
    Objects["_zova_objects<br/>object identity"]
    Chunks["_zova_chunks<br/>verified chunk BLOBs"]
    Manifest["_zova_object_chunks<br/>object manifests"]
    VecCols["_zova_vector_collections<br/>dimensions and metric"]
    Vecs["_zova_vectors<br/>f32 vector BLOBs"]

    App --> SQL
    App --> ZovaAPI
    ZovaAPI --> DB
    CLI --> DB
    DB --> SQL
    DB --> Meta
    DB --> Objects
    DB --> Chunks
    DB --> Manifest
    DB --> VecCols
    DB --> Vecs
    Objects --> Manifest
    Manifest --> Chunks
    VecCols --> Vecs
```

## What Works In v0.11

- normal SQLite access through a thin wrapper
- `.zova` database create/open/validation
- conversion from an existing SQLite database into a new `.zova` file
- content-addressed objects with `ObjectId = SHA-256(full bytes)`
- FastCDC-v1 chunking and chunk deduplication
- object manifests and verified chunk reads
- range reads for previews and partial serving
- streaming object writes with `ObjectWriter`
- verified loose chunk ingest and object assembly from chunks
- native vector collections
- vector CRUD, batch upsert, collection info/list/delete
- exact vector search, candidate-filtered search, search-by-id, and thresholds
- C ABI for database, SQL, objects, chunks, writers, and vectors
- CLI `info`, `stats`, object/chunk/vector/table inspection, and `check`
- source-only release packaging

The `.zova` format is still pre-1.0. Current files use
`_zova_meta.format_version = '3'`. Opening a file validates the current private
schema and does not repair, migrate, or lazily initialize older experimental
files.

## File Boundary

Zova is opt-in at the file level:

```text
*.zova  -> Zova database
other   -> normal SQLite database
```

Renaming `app.db` to `app.zova` is not enough. A valid Zova database has Zova
metadata and the required private object/vector schema.

Normal SQLite files remain normal SQLite files. Existing BLOB columns are not
automatically converted into Zova objects or vectors.

## C ABI

The C ABI is the language-neutral integration point.

Files and build steps:

- `include/zova.h`
- `src/c_api.zig`
- `zig build c-abi`
- `zig build c-abi-test`

The ABI exposes:

- database create/open/close
- SQL `exec`
- SQLite-to-Zova conversion
- object put/get/delete/existence/size/chunk count
- range reads
- object manifests and chunk reads
- verified loose chunk ingest
- object assembly from verified chunks
- streaming object writes
- vector collection create/exists/info/list/delete
- vector put/get/exists/delete
- batch vector put
- exact vector search, candidate-filtered search, search-by-id, and thresholds

Inputs are borrowed for the duration of each call. Paths and SQL use
null-terminated C strings. Bytes use pointer plus length. Vector values use
`const float *values` plus `size_t values_len`.

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

Every C ABI function returns `zova_status`. `ZOVA_OK` means success.
`zova_status_name(status)` returns a static status name.

Database-scoped diagnostics:

```c
const char *message = zova_database_last_error_message(db);
```

The returned pointer is borrowed and valid until the next call on that database
handle or until close. Create/open/convert failures can also return an owned
`zova_message` through their request structs.

Handles are opaque. Do not use the same database or writer handle concurrently
from multiple threads. Multiple database handles to the same file are allowed
and follow SQLite locking.

The ABI is additive and pre-1.0.

## Native Zig API

Zig users can import the package directly:

```zig
const zova = @import("zova");
```

Use `zova.Database` for `.zova` files:

```zig
var db = try zova.Database.create("app.zova");
defer db.deinit();
```

Use `zova.sqlite.Database` when you only want the thin SQLite wrapper:

```zig
var db = try zova.sqlite.Database.open("app.db");
defer db.deinit();

try db.exec("create table notes (id integer primary key, body text not null)");
```

Raw SQLite access remains available through `zova.sqlite.c` and public handles:

```zig
const c = zova.sqlite.c;
_ = c.sqlite3_total_changes64(db.handle);
```

## Convert SQLite To Zova

Convert an existing SQLite database into a new `.zova` file:

```zig
try zova.convertSqliteToZova("app.db", "app.zova");
```

Conversion uses SQLite's backup API. It never mutates the source file and never
overwrites the destination. The destination must end in `.zova`.

Schemas that already use `_zova_*` names are rejected with
`error.ZovaNameConflict`, because those names are reserved for Zova internals.

## SQL Records

SQL remains SQLite SQL. User tables stay application-owned:

```zig
try db.exec(
    \\create table attachments (
    \\  id integer primary key,
    \\  object_id blob not null,
    \\  filename text not null,
    \\  mime_type text not null
    \\)
);
```

Zova does not scan or mutate your user tables when objects or vectors are
deleted. If a user table still references a deleted object id or vector id, that
reference is application state.

## Objects

Zova objects are raw content-addressed bytes:

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
```

Read part of an object without allocating the full object:

```zig
var preview: [16]u8 = undefined;
const copied = try db.readObjectRange(id, 0, &preview);
```

Delete object storage:

```zig
try db.deleteObject(id);
```

Deletion removes Zova-owned object rows, manifest rows, and unreferenced chunks.
It never scans or mutates user SQL rows.

## Manifests, Chunks, And Transfers

Objects expose manifests so applications can inspect or transfer verified
chunks:

```zig
var manifest = try db.objectManifest(allocator, id);
defer manifest.deinit(allocator);

for (manifest.chunks) |chunk| {
    var data = try db.getObjectChunk(allocator, chunk.hash);
    defer data.deinit(allocator);
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

Transfer state belongs in user SQL tables: pending chunks, peer state, retries,
filenames, MIME types, UI progress, and final object references.

## Streaming Object Writes

Use `putObject` when the full byte slice is already in memory. Use
`ObjectWriter` when bytes arrive over time:

```zig
var writer = try db.objectWriter(allocator);
defer writer.deinit();

try writer.write(first_part);
try writer.write(second_part);

const id = try writer.finish();
```

The writer uses the same FastCDC-v1 boundaries as `putObject`, stores verified
chunks as they are emitted, and finishes by assembling the object from those
chunks. `cancel` removes unreferenced chunks seen by that writer. `deinit`
automatically cancels unfinished writers.

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

Put vectors:

```zig
try db.putVector("chunks", "chunk-001", &.{ 0.1, 0.2, 0.3 });

try db.putVectors("chunks", &.{
    .{ .id = "chunk-001", .values = &.{ 0.1, 0.2, 0.3 } },
    .{ .id = "chunk-002", .values = &.{ 0.2, 0.3, 0.4 } },
});
```

Inspect and delete collections:

```zig
var info = try db.vectorCollectionInfo(allocator, "chunks");
defer info.deinit(allocator);

var collections = try db.listVectorCollections(allocator);
defer collections.deinit(allocator);

try db.deleteVectorCollection("chunks");
```

Collection deletion removes private vector rows and the collection row. It does
not scan or mutate user SQL tables.

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

Candidate-filtered exact search:

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

Search is exact and flat-scan in v0.11. Missing candidate ids are skipped.
Invalid candidate ids return `error.VectorInvalid`. Corrupt selected vector rows
return `error.VectorCorrupt`.

## CLI

The `zova` executable is a non-mutating inspection/check tool.

Build and run:

```sh
zig build
zig-out/bin/zova --help
```

Commands:

```sh
zova --version
zova --help
zova info [--json] <file.zova>
zova stats [--json] [--limit <n>] <file.zova>
zova objects [--json] [--limit <n>] <file.zova>
zova object [--json] [--limit <n>] <file.zova> <object-id>
zova chunks [--json] [--limit <n>] <file.zova>
zova chunk [--json] [--limit <n>] <file.zova> <chunk-id>
zova vectors [--json] [--limit <n>] <file.zova>
zova vector-collection [--json] [--limit <n>] <file.zova> <name>
zova tables [--json] [--limit <n>] <file.zova>
zova check [--json] [--deep] <file.zova>
```

`info` reports package/SQLite/format versions, file sizes, SQLite page stats,
object counts, chunk counts, vector counts, and table counts.

`stats` adds bounded storage statistics: object size stats, chunk size stats,
deduped bytes saved, per-collection vector stats, top objects, and top chunks.

`objects`, `object`, `chunks`, and `chunk` inspect ids/counts/sizes only. They
do not read or print object bytes or chunk bytes.

`vectors` lists vector collections. `vector-collection` reports one collection
and bounded vector ids. They do not decode or print vector values.

`tables` reports bounded user/private table names. It does not print schema SQL
or row data.

`check` validates Zova identity/schema and runs SQLite `PRAGMA quick_check`.
`check --deep` also validates object manifests, referenced chunks, full object
hashes, loose chunks, and vector row shape/finite values. It reports bounded
issue examples where practical.

JSON output uses `cli_json_version = 1` and follows the same privacy rules as
text output.

Exit codes:

- `0`: success or healthy file
- `1`: unexpected internal error
- `2`: usage error
- `3`: open, path, Zova identity, or unsupported version error
- `4`: integrity or corruption check failure

The CLI does not repair, migrate, delete loose chunks, rebuild manifests, run
`VACUUM`, change PRAGMAs, or mutate `.zova` files.

## Vendored SQLite

Zova builds against the vendored SQLite amalgamation in `vendor/sqlite3.53.2`.

The build enables:

- `SQLITE_THREADSAFE=1`
- `SQLITE_ENABLE_FTS5`

Modern SQLite JSON support is built in for this SQLite version, so the old
`SQLITE_ENABLE_JSON1` flag is not required.

FTS5 and JSON are available as normal SQLite SQL. Zova does not add a separate
FTS or JSON API.

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

Run the full release smoke:

```sh
scripts/check-release.sh
```

## Release Package Policy

v0.11 releases a source-only package/archive. The package includes:

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
scripts/package-release.sh 0.11.0
```

tags the current commit, pushes the branch and tag, creates a source archive,
and creates the GitHub release. Do not run it until the exact commit you want
to release is ready.

## Non-Goals In v0.11

Zova v0.11 does not include:

- ANN indexes
- HNSW or IVFFlat
- vector SQL operators
- SQLite virtual table integration
- embedding generation
- Rust, Go, TypeScript, or Swift bindings
- repair commands
- orphan scan CLI
- CLI mutation commands
- object or chunk extraction commands
- vector search commands in the CLI
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

The goal is not to hide SQLite. The goal is to keep records, objects, and
vectors together in one embedded local database without extra services.
