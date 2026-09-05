//! Low-level SQLite metadata, schema inspection, and scalar conversion helpers.

const std = @import("std");
const sqlite = @import("../sqlite.zig");

const Error = @import("types.zig").Error;
const format_version = @import("types.zig").format_version;

pub fn prepareSchemaSql(db: *sqlite.Database, comptime sql_format: []const u8, args: anytype) Error!sqlite.Statement {
    var sql_buffer: [4096]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&sql_buffer, sql_format, args) catch return error.SqliteError;
    return try db.prepare(sql);
}

pub fn attachedTableExists(db: *sqlite.Database, comptime schema_name: []const u8, table_name: []const u8) Error!bool {
    var stmt = try prepareSchemaSql(db,
        \\select count(*)
        \\from {s}.sqlite_master
        \\where type = 'table' and name = ?
    , .{schema_name});
    defer stmt.deinit();

    try stmt.bindText(1, table_name);
    const step = try stmt.step();
    std.debug.assert(step == .row);
    return stmt.columnInt64(0) == 1;
}

pub fn attachedTableColumnExists(
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    table_name: []const u8,
    column_name: []const u8,
) Error!bool {
    var stmt = try prepareSchemaSql(db,
        \\select count(*)
        \\from {s}.pragma_table_info(?)
        \\where name = ?
    , .{schema_name});
    defer stmt.deinit();

    try stmt.bindText(1, table_name);
    try stmt.bindText(2, column_name);
    const step = try stmt.step();
    std.debug.assert(step == .row);
    return stmt.columnInt64(0) == 1;
}

pub fn attachedObjectStoreIdAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    comptime schema_name: []const u8,
) Error![]u8 {
    const store_id = (try attachedMetadataValueAlloc(allocator, db, schema_name, "store_id")) orelse return error.BoundStoreInvalid;
    errdefer allocator.free(store_id);
    if (!isValidStoreId(store_id)) return error.BoundStoreInvalid;
    return store_id;
}

pub fn expectAttachedMetadataValue(
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    key: [:0]const u8,
    expected: []const u8,
    metadata_key: MetadataKey,
) Error!void {
    const actual_value = attachedMetadataValueAlloc(std.heap.c_allocator, db, schema_name, key) catch |err| switch (err) {
        error.SqliteError => return error.NotZovaDatabase,
        else => return err,
    };
    const actual = actual_value orelse return error.NotZovaDatabase;
    defer std.heap.c_allocator.free(actual);

    if (std.mem.eql(u8, actual, expected)) return;
    return switch (metadata_key) {
        .magic => error.NotZovaDatabase,
        .format_version => error.UnsupportedZovaVersion,
    };
}

pub fn attachedMetadataValueAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    key: []const u8,
) Error!?[]u8 {
    var stmt = try prepareSchemaSql(db, "select value from {s}._zova_meta where key = ?", .{schema_name});
    defer stmt.deinit();

    try stmt.bindText(1, key);
    return switch (try stmt.step()) {
        .done => null,
        .row => try allocator.dupe(u8, stmt.columnText(0)),
    };
}

pub fn attachedMetadataU64(
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    key: []const u8,
) Error!u64 {
    var stmt = try prepareSchemaSql(db, "select value from {s}._zova_meta where key = ?", .{schema_name});
    defer stmt.deinit();

    try stmt.bindText(1, key);
    return switch (try stmt.step()) {
        .done => error.BoundStoreInvalid,
        .row => std.fmt.parseInt(u64, stmt.columnText(0), 10) catch error.BoundStoreInvalid,
    };
}

fn setMetadataValue(db: *sqlite.Database, key: []const u8, value: []const u8) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_meta (key, value) values (?, ?)
        \\on conflict(key) do update set value = excluded.value
    );
    defer stmt.deinit();

    try stmt.bindText(1, key);
    try stmt.bindText(2, value);
    std.debug.assert((try stmt.step()) == .done);
}

pub fn setAttachedMetadataValue(
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    key: []const u8,
    value: []const u8,
) Error!void {
    var stmt = try prepareSchemaSql(db,
        \\insert into {s}._zova_meta (key, value) values (?, ?)
        \\on conflict(key) do update set value = excluded.value
    , .{schema_name});
    defer stmt.deinit();

    try stmt.bindText(1, key);
    try stmt.bindText(2, value);
    std.debug.assert((try stmt.step()) == .done);
}

pub fn objectStoreIdAlloc(allocator: std.mem.Allocator, db: *sqlite.Database) Error![]u8 {
    const store_id = (try metadataValueAlloc(allocator, db, "store_id")) orelse return error.BoundStoreInvalid;
    errdefer allocator.free(store_id);
    if (!isValidStoreId(store_id)) return error.BoundStoreInvalid;
    return store_id;
}

pub fn metadataValueAlloc(allocator: std.mem.Allocator, db: *sqlite.Database, key: []const u8) Error!?[]u8 {
    var stmt = try db.prepare("select value from _zova_meta where key = ?");
    defer stmt.deinit();

    try stmt.bindText(1, key);
    return switch (try stmt.step()) {
        .done => null,
        .row => try allocator.dupe(u8, stmt.columnText(0)),
    };
}

pub fn isValidStoreId(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        _ = std.fmt.charToDigit(byte, 16) catch return false;
    }
    return true;
}

pub fn randomHex64(dest: *[64]u8) void {
    var random_bytes: [32]u8 = undefined;
    sqlite.c.sqlite3_randomness(random_bytes.len, &random_bytes);
    lowerHexInto(dest, &random_bytes);
}

pub fn lowerHexInto(dest: *[64]u8, bytes: *const [32]u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes.*, 0..) |byte, index| {
        dest[index * 2] = alphabet[byte >> 4];
        dest[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

pub fn sqliteI64ToU64(value: i64) Error!u64 {
    if (value < 0) return error.BoundStoreInvalid;
    return @intCast(value);
}

pub fn expectDone(stmt: *sqlite.Statement) Error!void {
    switch (try stmt.step()) {
        .done => {},
        .row => return error.SqliteError,
    }
}

pub fn mapSqliteResultCode(rc: c_int) Error {
    const primary = rc & 0xff;
    return switch (primary) {
        sqlite.c.SQLITE_BUSY => error.Busy,
        sqlite.c.SQLITE_LOCKED => error.Locked,
        sqlite.c.SQLITE_CONSTRAINT => error.Constraint,
        sqlite.c.SQLITE_CANTOPEN => error.CantOpen,
        sqlite.c.SQLITE_MISUSE => error.Misuse,
        sqlite.c.SQLITE_NOMEM => error.NoMemory,
        sqlite.c.SQLITE_INTERRUPT => error.Interrupt,
        sqlite.c.SQLITE_READONLY => error.ReadOnly,
        sqlite.c.SQLITE_CORRUPT => error.Corrupt,
        else => error.SqliteError,
    };
}

pub fn tableExists(db: *sqlite.Database, table_name: []const u8) Error!bool {
    var stmt = try db.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table' and name = ?
    );
    defer stmt.deinit();

    try stmt.bindText(1, table_name);
    const step = try stmt.step();
    std.debug.assert(step == .row);
    return stmt.columnInt64(0) == 1;
}

pub fn tableColumnExists(db: *sqlite.Database, table_name: []const u8, column_name: []const u8) Error!bool {
    var stmt = try db.prepare(
        \\select count(*)
        \\from pragma_table_info(?)
        \\where name = ?
    );
    defer stmt.deinit();

    try stmt.bindText(1, table_name);
    try stmt.bindText(2, column_name);
    const step = try stmt.step();
    std.debug.assert(step == .row);
    return stmt.columnInt64(0) == 1;
}

pub fn schemaSqlEqual(actual: []const u8, expected: []const u8) bool {
    var actual_index: usize = 0;
    var expected_index: usize = 0;

    while (true) {
        actual_index = skipAsciiWhitespace(actual, actual_index);
        expected_index = skipAsciiWhitespace(expected, expected_index);

        if (actual_index == actual.len or expected_index == expected.len) {
            return actual_index == actual.len and expected_index == expected.len;
        }

        if (std.ascii.toLower(actual[actual_index]) != std.ascii.toLower(expected[expected_index])) {
            return false;
        }

        actual_index += 1;
        expected_index += 1;
    }
}

fn skipAsciiWhitespace(bytes: []const u8, start_index: usize) usize {
    var index = start_index;
    while (index < bytes.len and std.ascii.isWhitespace(bytes[index])) : (index += 1) {}
    return index;
}

const MetadataKey = enum {
    magic,
    format_version,
};

pub fn expectMetadataValue(
    db: *sqlite.Database,
    key: [:0]const u8,
    expected: []const u8,
    metadata_key: MetadataKey,
) Error!void {
    var stmt = db.prepare("select value from _zova_meta where key = ?") catch |err| switch (err) {
        error.SqliteError => return error.NotZovaDatabase,
        else => return err,
    };
    defer stmt.deinit();

    try stmt.bindText(1, key);

    return switch (try stmt.step()) {
        .done => error.NotZovaDatabase,
        .row => {
            const actual = stmt.columnText(0);
            if (std.mem.eql(u8, actual, expected)) return;
            return switch (metadata_key) {
                .magic => error.NotZovaDatabase,
                .format_version => error.UnsupportedZovaVersion,
            };
        },
    };
}
