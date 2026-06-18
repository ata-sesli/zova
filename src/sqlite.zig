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
    Misuse,
};

/// Return the runtime SQLite library version used by this build.
pub fn version() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

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
    /// an in-memory database.
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

    /// Close the database connection.
    ///
    /// In v0 this asserts that all statements have already been finalized.
    /// Leaving statements alive at database close is treated as programmer
    /// misuse rather than a recoverable runtime condition.
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
    pub fn begin(self: *Database) Error!void {
        try self.exec("begin");
    }

    /// Start an immediate SQLite transaction.
    ///
    /// This acquires the write lock up front, which is often the clearer
    /// default for storage code that knows it is about to write.
    pub fn beginImmediate(self: *Database) Error!void {
        try self.exec("begin immediate");
    }

    /// Commit the active transaction.
    pub fn commit(self: *Database) Error!void {
        try self.exec("commit");
    }

    /// Roll back the active transaction.
    pub fn rollback(self: *Database) Error!void {
        try self.exec("rollback");
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
        const raw_copy = c.sqlite3_malloc64(@intCast(value.len + 1)) orelse return error.SqliteError;
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

        const raw_copy = c.sqlite3_malloc64(@intCast(value.len)) orelse return error.SqliteError;
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
    pub fn columnInt64(self: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    /// Read a 0-based column from the current row as a 64-bit floating point value.
    pub fn columnDouble(self: *Statement, index: c_int) f64 {
        return c.sqlite3_column_double(self.handle, index);
    }

    /// Read a 0-based column from the current row as UTF-8 text.
    ///
    /// The returned slice is borrowed from SQLite. It remains valid until the
    /// next `step`, `reset`, or `deinit` on this statement. Call this only
    /// after `step` returns `.row`.
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
    /// after `step` returns `.row`.
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
        c.SQLITE_MISUSE => error.Misuse,
        else => error.SqliteError,
    };
}

test "database opens memory database and exposes sqlite version" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try std.testing.expect(version().len > 0);
}

test "database exec creates table and writes row" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table messages (id integer primary key, body text not null)");
    try db.exec("insert into messages (body) values ('hello')");

    try std.testing.expectEqual(@as(i64, 1), db.changes());
    try std.testing.expectEqual(@as(i64, 1), db.lastInsertRowId());
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

test "statement reports parameter count and named parameter index" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var select = try db.prepare("select ?, :name, ?");
    defer select.deinit();

    try std.testing.expectEqual(@as(c_int, 3), select.parameterCount());
    try std.testing.expectEqual(@as(c_int, 2), select.parameterIndex(":name"));
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
