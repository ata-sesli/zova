# Zova

Zova is a Zig-powered embedded data substrate built on SQLite.

The current v0 surface is intentionally small: a thin SQLite wrapper for
database lifecycle, prepared statements, transactions, common result-code
mapping, and tests against the vendored SQLite build. SQL stays normal SQLite
SQL, existing SQLite files can be opened directly, and plain SQLite usage does
not create Zova system tables.

Zova v0 is not a different SQL dialect and not "better SQL." It does not make
SQLite stricter, distributed, or magically concurrent. It wraps SQLite's native
model with clearer Zig ownership and boring, direct ergonomics.

Raw SQLite remains available through `sqlite.c` for APIs that Zova does not
wrap yet.

## Import

Zova v0 commits to `zova.sqlite` as the SQLite wrapper namespace. Packages
that depend on Zova use the package surface from `src/root.zig`:

```zig
const zova = @import("zova");
const sqlite = zova.sqlite;
```

Inside this repository, the smoke executable imports `src/sqlite.zig` directly.

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

This SQLite wrapper does not add object storage, vector storage, migrations,
system tables, an ORM, a query builder, connection pooling, async behavior, or
a background service.

Those layers can grow later. The v0 foundation is boring on purpose: normal
SQLite first, wrapped just enough to make ownership and common usage clear in
Zig.
