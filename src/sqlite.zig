//! Thin SQLite wrapper for Zova v0.
//!
//! This module deliberately stays close to SQLite's C API. It owns database
//! and statement handles, maps a small set of common result codes into Zig
//! errors, exposes explicit transaction helpers, and keeps raw SQLite access
//! available through `sqlite.c`.
//!
//! Object storage, vector storage, migrations, Zova system tables, ORM
//! behavior, query building, async behavior, and connection pooling are
//! intentionally absent from this module today. Plain SQLite usage should not
//! require Zova-specific schema setup.
//!
//! The stable v0 package surface is `zova.sqlite`. Database paths stay
//! zero-terminated, `deinit` keeps assert-style close behavior, transaction
//! helpers stay manual, and raw result-code/debug needs should use
//! `errorMessage()` or the public `sqlite.c` escape hatch.
//!
//! Zova v0 is not a stricter, distributed, or more concurrent SQL dialect. It
//! does not alter SQLite PRAGMAs on open; callers remain responsible for
//! connection settings such as journal mode, synchronous mode, and foreign
//! keys. The vendored SQLite build keeps FTS5 enabled and relies on modern
//! SQLite's built-in JSON support.

const std = @import("std");

/// Raw SQLite C bindings.
///
/// Zova keeps this public on purpose: the wrapper below covers the common
/// v0 lifecycle, statement, and transaction paths, but callers can still drop
/// down to SQLite directly when they need an API Zova does not wrap yet.
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

/// Error set for the small public SQLite wrapper.
///
/// The wrapper maps common SQLite result codes to named Zig errors and folds
/// everything else into `SqliteError` until Zova needs more detail.
pub const Error = error{
    SqliteError,
    Busy,
    Locked,
    Constraint,
    CantOpen,
    Misuse,
    NoMemory,
    Interrupt,
    ReadOnly,
    Corrupt,
};

/// Return the runtime SQLite library version used by this build.
pub fn version() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

/// Explicit SQLite open mode used when callers need to avoid SQLite's default
/// create-on-open behavior.
pub const OpenFlags = enum {
    /// Open an existing database for reads and writes.
    read_write,
    /// Open an existing database for reads only.
    read_only,
};

/// Owns one SQLite database connection.
///
/// `Database` is a thin owner around `sqlite3*`. It does not hide SQL, build
/// queries, or manage schemas. Callers prepare and execute normal SQLite SQL,
/// while Zova centralizes handle ownership and result-code mapping.
pub const Database = struct {
    handle: *c.sqlite3,

    /// Open a SQLite database at `path`.
    ///
    /// `path` is zero-terminated to match SQLite's C API. Use `":memory:"` for
    /// an in-memory database. v0 intentionally keeps this as the only open API
    /// and does not add an `openZ` alias or allocator-based path helper.
    pub fn open(path: [:0]const u8) Error!Database {
        var raw_db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &raw_db);
        if (rc != c.SQLITE_OK) {
            if (raw_db) |db| {
                _ = c.sqlite3_close(db);
            }
            return mapResultCode(rc);
        }

        return .{ .handle = raw_db.? };
    }

    /// Open an existing SQLite database with explicit SQLite flags.
    ///
    /// Plain `open` intentionally preserves SQLite's convenient default of
    /// creating a missing file. Use this when the caller needs read-only open
    /// behavior or wants missing files to fail.
    pub fn openWithFlags(path: [:0]const u8, flags: OpenFlags) Error!Database {
        var raw_db: ?*c.sqlite3 = null;
        const sqlite_flags: c_int = switch (flags) {
            .read_write => c.SQLITE_OPEN_READWRITE,
            .read_only => c.SQLITE_OPEN_READONLY,
        };
        const rc = c.sqlite3_open_v2(path.ptr, &raw_db, sqlite_flags, null);
        if (rc != c.SQLITE_OK) {
            if (raw_db) |db| {
                _ = c.sqlite3_close(db);
            }
            return mapResultCode(rc);
        }

        return .{ .handle = raw_db.? };
    }

    /// Close the database connection.
    ///
    /// In v0 this asserts that all statements have already been finalized.
    /// Leaving statements alive at database close is treated as programmer
    /// misuse rather than a recoverable runtime condition. v0 does not expose
    /// a fallible close API.
    pub fn deinit(self: *Database) void {
        const rc = c.sqlite3_close(self.handle);
        std.debug.assert(rc == c.SQLITE_OK);
    }

    /// Execute SQL that does not need bound parameters or returned rows.
    pub fn exec(self: *Database, sql: [:0]const u8) Error!void {
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Start a deferred SQLite transaction.
    ///
    /// This is a thin wrapper over `begin`; nested transaction behavior,
    /// locking, and failure modes are SQLite's normal semantics.
    pub fn begin(self: *Database) Error!void {
        try self.exec("begin");
    }

    /// Start an immediate SQLite transaction.
    ///
    /// This acquires the write lock up front, which is often the clearer
    /// default for storage code that knows it is about to write. Locking and
    /// busy behavior follow SQLite's normal `begin immediate` semantics.
    pub fn beginImmediate(self: *Database) Error!void {
        try self.exec("begin immediate");
    }

    /// Commit the active transaction using SQLite's normal `commit` semantics.
    pub fn commit(self: *Database) Error!void {
        try self.exec("commit");
    }

    /// Roll back the active transaction using SQLite's normal `rollback` semantics.
    pub fn rollback(self: *Database) Error!void {
        try self.exec("rollback");
    }

    /// Set SQLite's busy timeout in milliseconds.
    ///
    /// Passing 0 clears the busy handler, matching SQLite's C API.
    pub fn setBusyTimeout(self: *Database, milliseconds: u32) Error!void {
        if (milliseconds > std.math.maxInt(c_int)) return error.Misuse;
        const rc = c.sqlite3_busy_timeout(self.handle, @intCast(milliseconds));
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Prepare SQL for repeated execution or bound parameters.
    ///
    /// The returned statement borrows this database connection. Finalize it
    /// with `Statement.deinit` before closing the database.
    pub fn prepare(self: *Database, sql: [:0]const u8) Error!Statement {
        var raw_stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &raw_stmt, null);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);

        return .{
            .db = self,
            .handle = raw_stmt.?,
        };
    }

    /// Number of rows modified by the most recent INSERT, UPDATE, or DELETE.
    pub fn changes(self: *Database) i64 {
        return @intCast(c.sqlite3_changes64(self.handle));
    }

    /// Total number of rows modified by INSERT, UPDATE, or DELETE on this connection.
    pub fn totalChanges(self: *Database) i64 {
        return @intCast(c.sqlite3_total_changes64(self.handle));
    }

    /// Rowid from the most recent successful INSERT on this connection.
    pub fn lastInsertRowId(self: *Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Current SQLite error message for this connection.
    ///
    /// The slice is owned by SQLite and should be treated as borrowed.
    pub fn errorMessage(self: *Database) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }
};

/// Result of advancing a prepared statement.
pub const Step = enum {
    /// The statement produced a row, and column accessors may be used.
    row,
    /// The statement finished without producing another row.
    done,
};

/// SQLite's five fundamental runtime column types.
///
/// This is the Zig shape of `sqlite3_column_type`. The value is most useful
/// before calling accessors that may perform SQLite type conversion.
pub const ColumnType = enum {
    integer,
    float,
    text,
    blob,
    null,
};

/// Owns one prepared SQLite statement.
///
/// A statement borrows its parent database and must be finalized with
/// `deinit`. Column slices returned from this type are borrowed from SQLite
/// and are valid only until the statement is stepped, reset, or finalized.
pub const Statement = struct {
    db: *Database,
    handle: *c.sqlite3_stmt,

    /// Finalize the prepared statement.
    ///
    /// SQLite returns the previous `step` error from `sqlite3_finalize`, so
    /// cleanup intentionally ignores the result. Callers should observe
    /// execution errors from `step`, not from deferred cleanup.
    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    /// Bind a signed 64-bit integer to a 1-based SQL parameter index.
    pub fn bindInt64(self: *Statement, index: c_int, value: i64) Error!void {
        const rc = c.sqlite3_bind_int64(self.handle, index, value);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Bind SQL NULL to a 1-based SQL parameter index.
    pub fn bindNull(self: *Statement, index: c_int) Error!void {
        const rc = c.sqlite3_bind_null(self.handle, index);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Bind a 64-bit floating point value to a 1-based SQL parameter index.
    pub fn bindDouble(self: *Statement, index: c_int, value: f64) Error!void {
        const rc = c.sqlite3_bind_double(self.handle, index, value);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Bind UTF-8 text to a 1-based SQL parameter index.
    ///
    /// The input slice does not need to outlive this call. Zig cannot safely
    /// use SQLite's `SQLITE_TRANSIENT` function-pointer macro directly, so
    /// Zova makes a SQLite-owned copy and asks SQLite to free it when done.
    pub fn bindText(self: *Statement, index: c_int, value: []const u8) Error!void {
        const raw_copy = c.sqlite3_malloc64(@intCast(value.len + 1)) orelse return error.NoMemory;
        const copy: [*]u8 = @ptrCast(raw_copy);
        @memcpy(copy[0..value.len], value);
        copy[value.len] = 0;

        const rc = c.sqlite3_bind_text64(
            self.handle,
            index,
            copy,
            @intCast(value.len),
            c.sqlite3_free,
            c.SQLITE_UTF8,
        );
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Bind blob bytes to a 1-based SQL parameter index.
    ///
    /// The input slice does not need to outlive this call. Non-empty blobs are
    /// copied into SQLite-owned memory. Empty blobs use SQLite's zeroblob API
    /// so they stay zero-length blobs instead of becoming SQL NULL.
    pub fn bindBlob(self: *Statement, index: c_int, value: []const u8) Error!void {
        if (value.len == 0) {
            const rc = c.sqlite3_bind_zeroblob64(self.handle, index, 0);
            if (rc != c.SQLITE_OK) return mapResultCode(rc);
            return;
        }

        const raw_copy = c.sqlite3_malloc64(@intCast(value.len)) orelse return error.NoMemory;
        const copy: [*]u8 = @ptrCast(raw_copy);
        @memcpy(copy[0..value.len], value);

        const rc = c.sqlite3_bind_blob64(
            self.handle,
            index,
            copy,
            @intCast(value.len),
            c.sqlite3_free,
        );
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Advance the statement once.
    ///
    /// Returns `.row` when a result row is available and `.done` when the
    /// statement has completed.
    pub fn step(self: *Statement) Error!Step {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => mapResultCode(rc),
        };
    }

    /// Reset the statement so it can be executed again.
    ///
    /// Existing bindings are preserved, matching SQLite's behavior. Use
    /// `clearBindings` when the next execution should start unbound.
    pub fn reset(self: *Statement) Error!void {
        const rc = c.sqlite3_reset(self.handle);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Clear all currently bound SQL parameters on the statement.
    pub fn clearBindings(self: *Statement) Error!void {
        const rc = c.sqlite3_clear_bindings(self.handle);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Read a 0-based column from the current row as a signed 64-bit integer.
    ///
    /// Like SQLite's column APIs, this does not validate the index. Callers are
    /// responsible for passing a valid column index for the current row.
    pub fn columnInt64(self: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    /// Read a 0-based column from the current row as a 64-bit floating point value.
    ///
    /// Like SQLite's column APIs, this does not validate the index. Callers are
    /// responsible for passing a valid column index for the current row.
    pub fn columnDouble(self: *Statement, index: c_int) f64 {
        return c.sqlite3_column_double(self.handle, index);
    }

    /// Read a 0-based column from the current row as UTF-8 text.
    ///
    /// The returned slice is borrowed from SQLite. It remains valid until the
    /// next `step`, `reset`, or `deinit` on this statement. Call this only
    /// after `step` returns `.row`. Like SQLite's column APIs, this does not
    /// validate the index.
    pub fn columnText(self: *Statement, index: c_int) []const u8 {
        // SQLite documents this order as the safe way to force text conversion
        // before asking for the converted byte length.
        const ptr = c.sqlite3_column_text(self.handle, index);
        const bytes = c.sqlite3_column_bytes(self.handle, index);
        if (ptr == null or bytes <= 0) return "";

        const many: [*]const u8 = @ptrCast(ptr);
        return many[0..@intCast(bytes)];
    }

    /// Read a 0-based column from the current row as blob bytes.
    ///
    /// The returned slice is borrowed from SQLite. It remains valid until the
    /// next `step`, `reset`, or `deinit` on this statement. Call this only
    /// after `step` returns `.row`. Like SQLite's column APIs, this does not
    /// validate the index.
    pub fn columnBlob(self: *Statement, index: c_int) []const u8 {
        const ptr = c.sqlite3_column_blob(self.handle, index);
        const bytes = c.sqlite3_column_bytes(self.handle, index);
        if (ptr == null or bytes <= 0) return "";

        const many: [*]const u8 = @ptrCast(ptr);
        return many[0..@intCast(bytes)];
    }

    /// Return the runtime SQLite type of a column in the current row.
    ///
    /// Column indexes are 0-based. For the most precise result, call this
    /// before using accessors that may ask SQLite to convert the value.
    pub fn columnType(self: *Statement, index: c_int) ColumnType {
        return switch (c.sqlite3_column_type(self.handle, index)) {
            c.SQLITE_INTEGER => .integer,
            c.SQLITE_FLOAT => .float,
            c.SQLITE_TEXT => .text,
            c.SQLITE_BLOB => .blob,
            c.SQLITE_NULL => .null,
            else => unreachable,
        };
    }

    /// Return the number of columns produced by this statement.
    pub fn columnCount(self: *Statement) c_int {
        return c.sqlite3_column_count(self.handle);
    }

    /// Return the 0-based column name for a prepared statement result column.
    ///
    /// The returned slice is borrowed from SQLite and is valid until the
    /// statement is finalized or automatically reprepared. This validates the
    /// index before calling SQLite so bindings can surface clean misuse errors.
    pub fn columnName(self: *Statement, index: c_int) Error![]const u8 {
        if (index < 0 or index >= self.columnCount()) return error.Misuse;
        const ptr = c.sqlite3_column_name(self.handle, index) orelse return error.NoMemory;
        return std.mem.span(ptr);
    }

    /// Return the number of SQL parameters in this statement.
    pub fn parameterCount(self: *Statement) c_int {
        return c.sqlite3_bind_parameter_count(self.handle);
    }

    /// Return the 1-based index for a named SQL parameter.
    ///
    /// `name` must include SQLite's parameter prefix, such as `":id"`.
    /// SQLite returns `0` when the name is not present.
    pub fn parameterIndex(self: *Statement, name: [:0]const u8) c_int {
        return c.sqlite3_bind_parameter_index(self.handle, name.ptr);
    }
};

/// Convert a SQLite result code into Zova's small v0 error set.
fn mapResultCode(rc: c_int) Error {
    return switch (rc) {
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_NOMEM => error.NoMemory,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_CORRUPT => error.Corrupt,
        else => error.SqliteError,
    };
}

fn testingDbPath(buffer: []u8, sub_path: []const u8, filename: []const u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buffer, ".zig-cache/tmp/{s}/{s}", .{ sub_path, filename });
}

test "result code mapping covers locked misuse and generic errors" {
    try std.testing.expectEqual(error.Locked, mapResultCode(c.SQLITE_LOCKED));
    try std.testing.expectEqual(error.Misuse, mapResultCode(c.SQLITE_MISUSE));
    try std.testing.expectEqual(error.NoMemory, mapResultCode(c.SQLITE_NOMEM));
    try std.testing.expectEqual(error.Interrupt, mapResultCode(c.SQLITE_INTERRUPT));
    try std.testing.expectEqual(error.ReadOnly, mapResultCode(c.SQLITE_READONLY));
    try std.testing.expectEqual(error.Corrupt, mapResultCode(c.SQLITE_CORRUPT));
    try std.testing.expectEqual(error.SqliteError, mapResultCode(c.SQLITE_ERROR));
}

test "database opens memory database and exposes sqlite version" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try std.testing.expect(version().len > 0);
}

test "database can open an existing file read-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "readonly.db");

    {
        var setup = try Database.open(db_path);
        defer setup.deinit();
        try setup.exec("create table items (id integer primary key, name text not null)");
        try setup.exec("insert into items (name) values ('stored')");
    }

    var db = try Database.openWithFlags(db_path, .read_only);
    defer db.deinit();

    var stmt = try db.prepare("select name from items where id = 1");
    defer stmt.deinit();
    try std.testing.expectEqual(Step.row, try stmt.step());
    try std.testing.expectEqualStrings("stored", stmt.columnText(0));
    try std.testing.expectError(error.ReadOnly, db.exec("insert into items (name) values ('blocked')"));
}

test "database busy timeout can be set and cleared" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.setBusyTimeout(1);
    try db.setBusyTimeout(0);
}

test "database exec creates table and writes row" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table messages (id integer primary key, body text not null)");
    try db.exec("insert into messages (body) values ('hello')");

    try std.testing.expectEqual(@as(i64, 1), db.changes());
    try std.testing.expectEqual(@as(i64, 1), db.totalChanges());
    try std.testing.expectEqual(@as(i64, 1), db.lastInsertRowId());
}

test "database exec runs multiline schema sql unchanged" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec(
        \\create table accounts (
        \\  id integer primary key,
        \\  email text not null unique
        \\);
        \\create index accounts_email_idx on accounts (email);
        \\create view active_accounts as
        \\  select id, email from accounts;
    );

    var objects = try db.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where name in ('accounts', 'accounts_email_idx', 'active_accounts')
    );
    defer objects.deinit();

    try std.testing.expectEqual(Step.row, try objects.step());
    try std.testing.expectEqual(@as(i64, 3), objects.columnInt64(0));
}

test "vendored sqlite supports built in json functions" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var json = try db.prepare("select json_extract('{\"zova\":\"sqlite\"}', '$.zova') as value");
    defer json.deinit();

    try std.testing.expectEqual(Step.row, try json.step());
    try std.testing.expectEqualStrings("value", try json.columnName(0));
    try std.testing.expectEqualStrings("sqlite", json.columnText(0));
    try std.testing.expectError(error.Misuse, json.columnName(1));
}

test "vendored sqlite supports fts5 virtual tables" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create virtual table docs using fts5(body)");
    try db.exec("insert into docs (body) values ('zova wraps sqlite')");

    var search = try db.prepare("select body from docs where docs match 'sqlite'");
    defer search.deinit();

    try std.testing.expectEqual(Step.row, try search.step());
    try std.testing.expectEqualStrings("zova wraps sqlite", search.columnText(0));
    try std.testing.expectEqual(Step.done, try search.step());
}

test "database open leaves user controlled pragmas alone" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var foreign_keys = try db.prepare("pragma foreign_keys");
    defer foreign_keys.deinit();

    try std.testing.expectEqual(Step.row, try foreign_keys.step());
    try std.testing.expectEqual(@as(i64, 0), foreign_keys.columnInt64(0));
}

test "raw sqlite escape hatch can use public database handle" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table messages (id integer primary key, body text not null)");
    try db.exec("insert into messages (body) values ('hello')");

    try std.testing.expectEqual(@as(i64, 1), c.sqlite3_total_changes64(db.handle));
}

test "database open maps missing parent directory to CantOpen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(
        &path_buffer,
        ".zig-cache/tmp/{s}/missing-parent/missing.db",
        .{tmp.sub_path[0..]},
    );

    try std.testing.expectError(error.CantOpen, Database.open(db_path));
}

test "file-backed database persists rows across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "persist.db");

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        try db.exec("create table messages (id integer primary key, body text not null)");
        try db.exec("insert into messages (body) values ('alpha')");
        try db.exec("insert into messages (body) values ('beta')");
    }

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        var select = try db.prepare("select id, body from messages order by id");
        defer select.deinit();

        try std.testing.expectEqual(Step.row, try select.step());
        try std.testing.expectEqual(@as(i64, 1), select.columnInt64(0));
        try std.testing.expectEqualStrings("alpha", select.columnText(1));

        try std.testing.expectEqual(Step.row, try select.step());
        try std.testing.expectEqual(@as(i64, 2), select.columnInt64(0));
        try std.testing.expectEqualStrings("beta", select.columnText(1));

        try std.testing.expectEqual(Step.done, try select.step());
    }
}

test "existing sqlite file remains usable through zova" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "existing.db");

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        try db.exec("create table settings (key text primary key, value text not null)");
        try db.exec("insert into settings (key, value) values ('theme', 'light')");
    }

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        try db.exec("insert into settings (key, value) values ('density', 'compact')");

        var count = try db.prepare("select count(*) from settings");
        defer count.deinit();
        try std.testing.expectEqual(Step.row, try count.step());
        try std.testing.expectEqual(@as(i64, 2), count.columnInt64(0));
    }
}

test "database error message describes failing sql" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try std.testing.expectError(error.SqliteError, db.exec("select * from missing_table"));
    try std.testing.expect(std.mem.indexOf(u8, db.errorMessage(), "no such table") != null);
}

test "database open does not create zova schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "schema.db");

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        try db.exec("create table app_data (id integer primary key, value text not null)");
    }

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        var user_tables = try db.prepare(
            \\select name
            \\from sqlite_master
            \\where type = 'table' and name not like 'sqlite_%'
            \\order by name
        );
        defer user_tables.deinit();

        try std.testing.expectEqual(Step.row, try user_tables.step());
        try std.testing.expectEqualStrings("app_data", user_tables.columnText(0));
        try std.testing.expectEqual(Step.done, try user_tables.step());

        var zova_tables = try db.prepare(
            \\select count(*)
            \\from sqlite_master
            \\where type = 'table' and (name like 'zova%' or name like '_zova%')
        );
        defer zova_tables.deinit();

        try std.testing.expectEqual(Step.row, try zova_tables.step());
        try std.testing.expectEqual(@as(i64, 0), zova_tables.columnInt64(0));
    }
}

test "statement binds values and reads a row" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table messages (id integer primary key, body text not null)");

    var insert = try db.prepare("insert into messages (body) values (?)");
    defer insert.deinit();
    try insert.bindText(1, "hello");
    try std.testing.expectEqual(Step.done, try insert.step());

    var select = try db.prepare("select id, body from messages where body = ?");
    defer select.deinit();
    try select.bindText(1, "hello");
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqual(@as(i64, 1), select.columnInt64(0));
    try std.testing.expectEqualStrings("hello", select.columnText(1));
    try std.testing.expectEqual(Step.done, try select.step());
}

test "statement cleanup tolerates previous step error" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table users (email text not null unique)");
    try db.exec("insert into users (email) values ('a@example.com')");

    var duplicate = try db.prepare("insert into users (email) values (?)");
    defer duplicate.deinit();
    try duplicate.bindText(1, "a@example.com");
    try std.testing.expectError(error.Constraint, duplicate.step());
}

test "constraint errors are recoverable" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table users (email text not null unique)");
    try db.exec("insert into users (email) values ('a@example.com')");

    var duplicate = try db.prepare("insert into users (email) values (?)");
    defer duplicate.deinit();
    try duplicate.bindText(1, "a@example.com");
    try std.testing.expectError(error.Constraint, duplicate.step());

    try db.exec("insert into users (email) values ('b@example.com')");

    var count = try db.prepare("select count(*) from users");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 2), count.columnInt64(0));
}

test "column text reads converted values" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var select = try db.prepare("select 42");
    defer select.deinit();
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("42", select.columnText(0));
}

test "statement binds and reads scalar and blob values" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec(
        \\create table samples (
        \\  i integer,
        \\  r real,
        \\  b blob,
        \\  empty_blob blob,
        \\  n text
        \\)
    );

    var insert = try db.prepare("insert into samples (i, r, b, empty_blob, n) values (?, ?, ?, ?, ?)");
    defer insert.deinit();
    try insert.bindInt64(1, -42);
    try insert.bindDouble(2, 3.25);
    try insert.bindBlob(3, &.{ 0x01, 0x02, 0x03 });
    try insert.bindBlob(4, &.{});
    try insert.bindNull(5);
    try std.testing.expectEqual(Step.done, try insert.step());

    var select = try db.prepare("select i, r, b, empty_blob, n from samples");
    defer select.deinit();
    try std.testing.expectEqual(@as(c_int, 5), select.columnCount());
    try std.testing.expectEqual(Step.row, try select.step());

    try std.testing.expectEqual(ColumnType.integer, select.columnType(0));
    try std.testing.expectEqual(ColumnType.float, select.columnType(1));
    try std.testing.expectEqual(ColumnType.blob, select.columnType(2));
    try std.testing.expectEqual(ColumnType.blob, select.columnType(3));
    try std.testing.expectEqual(ColumnType.null, select.columnType(4));

    try std.testing.expectEqual(@as(i64, -42), select.columnInt64(0));
    try std.testing.expectEqual(@as(f64, 3.25), select.columnDouble(1));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03 }, select.columnBlob(2));
    try std.testing.expectEqual(@as(usize, 0), select.columnBlob(3).len);
}

test "bound text and blob are copied from caller buffers" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table payloads (body text not null, bytes blob not null)");

    var body = [_]u8{ 'a', 'l', 'p', 'h', 'a' };
    var bytes = [_]u8{ 0x01, 0x02, 0x03 };

    var insert = try db.prepare("insert into payloads (body, bytes) values (?, ?)");
    defer insert.deinit();
    try insert.bindText(1, body[0..]);
    try insert.bindBlob(2, bytes[0..]);

    @memcpy(body[0..], "omega");
    @memset(bytes[0..], 0xff);

    try std.testing.expectEqual(Step.done, try insert.step());

    var select = try db.prepare("select body, bytes from payloads");
    defer select.deinit();
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("alpha", select.columnText(0));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03 }, select.columnBlob(1));
}

test "statement reports parameter count and named parameter index" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var select = try db.prepare("select ?, :name, ?");
    defer select.deinit();

    try std.testing.expectEqual(@as(c_int, 3), select.parameterCount());
    try std.testing.expectEqual(@as(c_int, 2), select.parameterIndex(":name"));
}

test "invalid parameter indexes map to generic sqlite error" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var select = try db.prepare("select ?");
    defer select.deinit();

    try std.testing.expectError(error.SqliteError, select.bindInt64(0, 1));
    try std.testing.expectError(error.SqliteError, select.bindInt64(2, 1));
}

test "statement reset and clear bindings prevent stale values" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var select = try db.prepare("select coalesce(?1, 'fallback')");
    defer select.deinit();

    try select.bindText(1, "first");
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("first", select.columnText(0));

    try select.reset();
    try select.clearBindings();
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("fallback", select.columnText(0));
}

test "deferred transaction begin commits writes" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.begin();
    try db.exec("insert into items (name) values ('deferred')");
    try db.commit();

    var count = try db.prepare("select count(*) from items where name = 'deferred'");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}

test "immediate transaction begin commits writes" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.beginImmediate();
    try db.exec("insert into items (name) values ('immediate')");
    try db.commit();

    var count = try db.prepare("select count(*) from items where name = 'immediate'");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}

test "transaction commit keeps writes" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.beginImmediate();
    try db.exec("insert into items (name) values ('committed')");
    try db.commit();

    var count = try db.prepare("select count(*) from items");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}

test "transaction rollback discards writes" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.beginImmediate();
    try db.exec("insert into items (name) values ('rolled back')");
    try db.rollback();

    var count = try db.prepare("select count(*) from items");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 0), count.columnInt64(0));
}

test "commit without active transaction maps to generic sqlite error" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try std.testing.expectError(error.SqliteError, db.commit());
    try std.testing.expect(std.mem.indexOf(u8, db.errorMessage(), "no transaction is active") != null);
}

test "rollback without active transaction maps to generic sqlite error" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try std.testing.expectError(error.SqliteError, db.rollback());
    try std.testing.expect(std.mem.indexOf(u8, db.errorMessage(), "no transaction is active") != null);
}

test "nested transaction keeps sqlite semantics and leaves connection usable" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.begin();
    try std.testing.expectError(error.SqliteError, db.begin());
    try std.testing.expect(std.mem.indexOf(u8, db.errorMessage(), "within a transaction") != null);
    try db.rollback();

    try db.exec("insert into items (name) values ('usable')");
    var count = try db.prepare("select count(*) from items where name = 'usable'");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}

test "beginImmediate maps busy when another connection holds write lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "busy.db");

    {
        var setup = try Database.open(db_path);
        defer setup.deinit();
        try setup.exec("create table items (id integer primary key, name text not null)");
    }

    var first = try Database.open(db_path);
    defer first.deinit();
    var second = try Database.open(db_path);
    defer second.deinit();

    try first.beginImmediate();
    defer first.rollback() catch {};

    try std.testing.expectError(error.Busy, second.beginImmediate());
}
