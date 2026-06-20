# Zova

Zova is a Zig-powered embedded data substrate built on SQLite.

Current package version: `0.4.0`.

The current v0.4 surface is intentionally small: a thin SQLite wrapper for
database lifecycle, prepared statements, transactions, common result-code
mapping, plus a `.zova` file identity layer, SQLite-to-Zova conversion, and
native content-addressed object storage with explicit object deletion. SQL
stays normal SQLite SQL, existing SQLite files can be opened directly, and
plain SQLite usage does not create Zova system tables.

Zova v0 is not a different SQL dialect and not "better SQL." It does not make
SQLite stricter, distributed, or magically concurrent. It wraps SQLite's native
model with clearer Zig ownership and boring, direct ergonomics.

Raw SQLite remains available through `sqlite.c` for APIs that Zova does not
wrap yet.

Zova v0.4 also has a file-level database boundary:

```text
*.zova  -> Zova-owned database
other   -> plain SQLite database
```

Use `zova.sqlite.Database` when you want the plain SQLite wrapper. Use
`zova.Database` when you want Zova to validate and manage a `.zova` file. Use
`zova.convertSqliteToZova` when you want to convert an existing SQLite database
into a new Zova database.

## Import

Zova v0.4 keeps `zova.sqlite` as the SQLite wrapper namespace. Packages
that depend on Zova use the package surface from `src/root.zig`:

```zig
const zova = @import("zova");
const sqlite = zova.sqlite;
```

Inside this repository, the smoke executable imports `src/sqlite.zig` directly.

## Zova Databases

`zova.Database` is the Zova-owned database API. It only accepts `.zova` paths
and validates private metadata before opening a file as Zova-managed storage.
It includes native object storage, but it does not add vector behavior yet.

Create a new `.zova` database:

```zig
var db = try zova.Database.create("app.zova");
defer db.deinit();
```

Open an initialized `.zova` database:

```zig
var db = try zova.Database.open("app.zova");
defer db.deinit();
```

The file is still SQLite underneath. You can inspect it with the plain wrapper
when needed:

```zig
var raw = try zova.sqlite.Database.open("app.zova");
defer raw.deinit();
```

Renaming a SQLite file to `.zova` is not enough. Zova validates the internal
`_zova_meta` table and rejects files that are missing the expected magic value
and format version.

Convert an existing SQLite database into a new `.zova` database:

```zig
try zova.convertSqliteToZova("app.db", "app.zova");
```

Conversion copies the source database with SQLite's backup API, initializes
Zova metadata in the destination, and does not mutate the source SQLite file.
The destination must end in `.zova` and must not already exist. Source schemas
that already use Zova-reserved `_zova_` names are rejected with
`error.ZovaNameConflict`.

After conversion, open the result through `zova.Database.open`:

```zig
var db = try zova.Database.open("app.zova");
defer db.deinit();
```

Conversion preserves SQLite data as SQLite data. It does not scan user BLOB
columns, convert them into Zova objects, or rewrite application schema. If an
application wants to move an existing BLOB column to Zova objects, that is an
application migration using the object API below.

## Objects

Zova objects are raw content-addressed bytes:

```text
Object -> FastCDC chunk manifest -> SQLite BLOB chunk rows
```

The public identity is `zova.ObjectId`, a raw `[32]u8` SHA-256 digest of the
full object bytes. The same bytes produce the same object id. Display it with
normal Zig formatting helpers such as `std.fmt.fmtSliceHexLower(&id)` when a
hex string is useful.

Store, load, and delete an object:

```zig
const id = try db.putObject("hello object");

var object = try db.getObject(allocator, id);
defer object.deinit(allocator);

std.debug.assert(std.mem.eql(u8, object.bytes, "hello object"));

try db.deleteObject(id);
std.debug.assert(!try db.hasObject(id));
```

`getObject` allocates the full object in memory in v0.4. Streaming reads are
not part of this release.

`deleteObject` removes the object row, removes its manifest rows, and
garbage-collects Zova chunks that are no longer referenced by any remaining
object manifest. It does not read, reassemble, or hash the object bytes during
delete. Delete is lifecycle cleanup, not repair tooling.

Missing or already-deleted object ids return `error.ObjectNotFound`.
`deleteObject` owns its own write transaction, so calling it inside an active
user transaction returns `error.ObjectTransactionActive`. Normal SQLite write
contention can still surface as SQLite wrapper errors such as `error.Busy`.

SQL BLOB columns and Zova objects are different tools. A user-created BLOB
column remains an ordinary SQLite BLOB column. Zova objects are stored in
private `_zova_` tables as FastCDC chunks, and those chunk boundaries are not
part of the public API.

Application metadata belongs in application tables. For example, store object
ids beside filenames or other app data:

```zig
try db.exec(
    \\create table attachments (
    \\  id integer primary key,
    \\  object_id blob not null,
    \\  filename text not null
    \\)
);

const id = try db.putObject(file_bytes);

var insert = try db.prepare("insert into attachments (object_id, filename) values (?, ?)");
defer insert.deinit();

try insert.bindBlob(1, &id);
try insert.bindText(2, "report.pdf");
std.debug.assert((try insert.step()) == .done);
```

Later, read the object id from SQL and load the bytes through Zova:

```zig
var select = try db.prepare("select object_id from attachments where filename = ?");
defer select.deinit();

try select.bindText(1, "report.pdf");
if ((try select.step()) == .row) {
    var stored_id: zova.ObjectId = undefined;
    const raw_id = select.columnBlob(0);
    std.debug.assert(raw_id.len == @sizeOf(zova.ObjectId));
    @memcpy(stored_id[0..], raw_id);

    var object = try db.getObject(allocator, stored_id);
    defer object.deinit(allocator);
}
```

Object references in user SQL tables are application-owned. Deleting an object
does not scan application tables, does not remove rows from user tables, and
does not rewrite object ids stored by the application. A user table can still
contain an object id after `deleteObject`; loading that id through `getObject`
returns `error.ObjectNotFound` until the application updates or removes its own
reference.

Deleting object rows does not mean the SQLite file shrinks immediately. Zova
does not run `VACUUM`, enable `auto_vacuum`, or change PRAGMAs on open or
delete. Physical file-size reclamation is normal SQLite behavior; applications
that want compaction can run SQLite mechanisms such as `VACUUM` explicitly.

## Open A Database

`Database.open` takes a zero-terminated path slice, matching SQLite's C API.
Zig string literals work naturally for this.

For v0, this is the only open API. There is no `openZ` alias and no
allocator-based helper for non-sentinel path slices.

```zig
var memory_db = try sqlite.Database.open(":memory:");
defer memory_db.deinit();

var file_db = try sqlite.Database.open("app.db");
defer file_db.deinit();
```

`Database.deinit()` closes the SQLite handle. In v0 it asserts that statements
have already been finalized and treats leaked statements as programmer misuse.
There is no fallible close API in v0.

Opening a file does not run Zova setup or create Zova system tables. You can
query an existing SQLite database directly:

```zig
var app_db = try sqlite.Database.open("app.db");
defer app_db.deinit();

var tables = try app_db.prepare(
    \\select name
    \\from sqlite_master
    \\where type = 'table'
    \\order by name
);
defer tables.deinit();

while ((try tables.step()) == .row) {
    std.debug.print("table: {s}\n", .{tables.columnText(0)});
}
```

## Execute SQL

Use `exec` for SQL that does not need bound parameters or returned rows.

```zig
try db.exec(
    \\create table messages (
    \\  id integer primary key,
    \\  body text not null
    \\)
);

try db.exec("insert into messages (body) values ('hello')");
```

Zova does not rewrite SQL. Schema definitions, queries, indexes, constraints,
and transaction behavior are SQLite behavior.

Zova v0 also does not change SQLite PRAGMAs on open. Users remain responsible
for connection settings such as `journal_mode`, `synchronous`, `foreign_keys`,
and any other SQLite PRAGMA their application needs.

## Prepared Statements

Prepared statements borrow their parent database and must be finalized with
`Statement.deinit()` before closing the database.

SQLite parameter indexes are 1-based:

```zig
var insert = try db.prepare("insert into messages (body) values (?)");
defer insert.deinit();

try insert.bindText(1, "hello");
std.debug.assert((try insert.step()) == .done);
```

SQLite column indexes are 0-based:

```zig
var select = try db.prepare("select id, body from messages where body = ?");
defer select.deinit();

try select.bindText(1, "hello");

while ((try select.step()) == .row) {
    const id = select.columnInt64(0);
    const body = select.columnText(1);
    std.debug.print("{d}: {s}\n", .{ id, body });
}
```

Text and blob column slices are borrowed from SQLite. They remain valid until
the next `step`, `reset`, or `deinit` on that statement.

Column accessors stay close to SQLite: they do not validate indexes and do not
return errors. Callers are responsible for using valid 0-based column indexes
for the current row.

## Named Parameters

Named parameters use SQLite's normal parameter names. Include the prefix when
looking up the index.

```zig
var find = try db.prepare("select id from messages where body = :body");
defer find.deinit();

const body_index = find.parameterIndex(":body");
try find.bindText(body_index, "hello");
```

## Transactions

Zova's transaction helpers are thin wrappers over SQLite SQL:

```zig
try db.beginImmediate();
errdefer db.rollback() catch {};

try db.exec("insert into messages (body) values ('inside transaction')");

try db.commit();
```

Use `begin()` for deferred transactions and `beginImmediate()` when the code is
about to write and should acquire the write lock up front. Nested transaction,
locking, busy, commit, and rollback behavior are normal SQLite semantics.
There is no scoped transaction object in v0; use an `errdefer` rollback pattern
when a transaction should roll back on early return.

## Errors

Common SQLite result codes map to Zova errors such as `error.Busy`,
`error.Locked`, `error.Constraint`, `error.CantOpen`, `error.Misuse`,
`error.NoMemory`, `error.Interrupt`, `error.ReadOnly`, and `error.Corrupt`.
Other SQLite result codes currently map to `error.SqliteError`.

The Zova-owned database layer adds boundary errors such as `error.NotZovaPath`,
`error.NotZovaDatabase`, `error.UnsupportedZovaVersion`,
`error.DestinationExists`, and `error.ZovaNameConflict`. Object APIs add
`error.ObjectNotFound`, `error.ObjectCorrupt`, `error.ObjectTooLarge`, and
`error.ObjectTransactionActive`.

Use `Database.errorMessage()` to read SQLite's current error message for the
connection:

```zig
db.exec("select * from missing_table") catch |err| {
    std.debug.print("sqlite error: {s}\n", .{db.errorMessage()});
    return err;
};
```

The returned message slice is owned by SQLite and should be treated as borrowed.
Zova v0 does not add a raw result-code method. For lower-level debugging, use
`sqlite.c` with the public wrapper handles.

## Raw SQLite Escape Hatch

The raw C API is public on purpose:

```zig
const c = sqlite.c;
```

For unwrapped SQLite APIs, use `sqlite.c` together with the low-level handles
owned by the wrapper types. For example, `Database.handle` is the wrapped
`sqlite3*`, and `Statement.handle` is the wrapped `sqlite3_stmt*`.

This is an escape hatch, not a second higher-level API. Prefer the wrapper when
it already covers the SQLite operation you need.

## Vendored SQLite Features

Zova v0 builds against the vendored SQLite amalgamation in `vendor/sqlite3.53.2`.
JSON support comes from modern SQLite's built-in JSON functions and operators;
the old `SQLITE_ENABLE_JSON1` compile flag is not required for this SQLite
version.

FTS5 is enabled in the vendored build. That means normal SQLite FTS5 virtual
tables are available through SQL, but Zova v0 does not add a search abstraction.

## Testing And Release Smoke

Run the normal library tests:

```sh
zig build test
```

Run realistic file-backed end-to-end tests:

```sh
zig build e2e
```

Run the full release smoke before publishing:

```sh
scripts/check-release.sh
```

The release smoke formats sources, runs unit/integration tests, runs E2E tests,
builds the smoke executable, runs it, creates a source-package candidate, and
verifies that candidate from extraction. The release package is source-only:
`README.md`, build files, `src`, `tests`, and `vendor`. Compiled CLI binaries are
not release artifacts in v0.4.

## Raw SQLite To Zova Mapping

| Raw SQLite C | Zova wrapper |
| --- | --- |
| `sqlite3_open(...)` | `sqlite.Database.open(path)` |
| `sqlite3_close(...)` | `db.deinit()` |
| `sqlite3_exec(...)` | `db.exec(sql)` |
| `sqlite3_prepare_v2(...)` | `db.prepare(sql)` |
| `sqlite3_bind_int64(...)` | `stmt.bindInt64(index, value)` |
| `sqlite3_bind_double(...)` | `stmt.bindDouble(index, value)` |
| `sqlite3_bind_text...(...)` | `stmt.bindText(index, value)` |
| `sqlite3_bind_blob...(...)` | `stmt.bindBlob(index, value)` |
| `sqlite3_bind_null(...)` | `stmt.bindNull(index)` |
| `sqlite3_step(...) == SQLITE_ROW` | `try stmt.step() == .row` |
| `sqlite3_step(...) == SQLITE_DONE` | `try stmt.step() == .done` |
| `sqlite3_reset(...)` | `stmt.reset()` |
| `sqlite3_clear_bindings(...)` | `stmt.clearBindings()` |
| `sqlite3_column_int64(...)` | `stmt.columnInt64(index)` |
| `sqlite3_column_text(...)` | `stmt.columnText(index)` |
| `sqlite3_column_blob(...)` | `stmt.columnBlob(index)` |
| `sqlite3_finalize(...)` | `stmt.deinit()` |

## What Is Not In This Module Yet

The plain `zova.sqlite` wrapper does not add object storage, vector storage,
migrations, system tables, an ORM, a query builder, connection pooling, async
behavior, or a background service.

The Zova-owned `zova.Database` layer adds `.zova` identity and native objects,
but v0.4 still has no vector API, streaming object API, repair CLI, automatic
BLOB migration, compression, encryption, or remote sync.

Those layers can grow later. The v0 foundation is boring on purpose: normal
SQLite first, wrapped just enough to make ownership and common usage clear in
Zig.
