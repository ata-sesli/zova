const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    SqliteError,
    Busy,
    Locked,
    Constraint,
    Misuse,
};

pub fn version() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

pub const Database = struct {
    handle: *c.sqlite3,

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

    pub fn deinit(self: *Database) void {
        const rc = c.sqlite3_close(self.handle);
        std.debug.assert(rc == c.SQLITE_OK);
    }

    pub fn exec(self: *Database, sql: [:0]const u8) Error!void {
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    pub fn begin(self: *Database) Error!void {
        try self.exec("begin");
    }

    pub fn beginImmediate(self: *Database) Error!void {
        try self.exec("begin immediate");
    }

    pub fn commit(self: *Database) Error!void {
        try self.exec("commit");
    }

    pub fn rollback(self: *Database) Error!void {
        try self.exec("rollback");
    }

    pub fn prepare(self: *Database, sql: [:0]const u8) Error!Statement {
        var raw_stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &raw_stmt, null);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);

        return .{
            .db = self,
            .handle = raw_stmt.?,
        };
    }

    pub fn changes(self: *Database) i64 {
        return @intCast(c.sqlite3_changes64(self.handle));
    }

    pub fn lastInsertRowId(self: *Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn errorMessage(self: *Database) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }
};

pub const Step = enum {
    row,
    done,
};

pub const Statement = struct {
    db: *Database,
    handle: *c.sqlite3_stmt,

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn bindInt64(self: *Statement, index: c_int, value: i64) Error!void {
        const rc = c.sqlite3_bind_int64(self.handle, index, value);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

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

    pub fn step(self: *Statement) Error!Step {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => mapResultCode(rc),
        };
    }

    pub fn reset(self: *Statement) Error!void {
        const rc = c.sqlite3_reset(self.handle);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    pub fn clearBindings(self: *Statement) Error!void {
        const rc = c.sqlite3_clear_bindings(self.handle);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    pub fn columnInt64(self: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    pub fn columnText(self: *Statement, index: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.handle, index);
        const bytes = c.sqlite3_column_bytes(self.handle, index);
        if (ptr == null or bytes <= 0) return "";

        const many: [*]const u8 = @ptrCast(ptr);
        return many[0..@intCast(bytes)];
    }
};

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
