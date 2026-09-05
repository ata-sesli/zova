//! Shared CLI database, SQLite, validation, and formatting primitives.

const std = @import("std");
const zova = @import("zova");
const sqlite = zova.sqlite;

const CommandContext = @import("types.zig").CommandContext;

pub const ExitCode = struct {
    pub const ok: u8 = 0;
    pub const unexpected: u8 = 1;
    pub const usage: u8 = 2;
    pub const open: u8 = 3;
    pub const check_failed: u8 = 4;
};

pub const cli_json_version = 1;

pub const default_list_limit = 10;

pub const max_list_limit = 100;

pub fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn openDatabase(ctx: CommandContext, path: [:0]const u8) zova.Error!zova.Database {
    return zova.Database.openWithExtensions(path, ctx.registry);
}

pub fn openDatabaseWithOptions(ctx: CommandContext, path: [:0]const u8, options: zova.OpenOptions) zova.Error!zova.Database {
    return zova.Database.openWithOptionsAndExtensions(path, options, ctx.registry);
}

pub fn openManagementDatabase(ctx: CommandContext, path: [:0]const u8) zova.Error!zova.Database {
    return zova.Database.openForObjectStoreManagementWithExtensions(path, .{}, ctx.registry);
}

pub fn lowerHex32(dest: *[32]u8, bytes: *const [16]u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes.*, 0..) |byte, index| {
        dest[index * 2] = alphabet[byte >> 4];
        dest[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

pub fn isExtensionHealthError(err: anyerror) bool {
    return switch (err) {
        error.ExtensionInvalid,
        error.ExtensionIncompatible,
        error.ExtensionUnavailable,
        error.ExtensionUntrusted,
        error.ExtensionLoadFailed,
        => true,
        else => false,
    };
}

pub fn isZovaPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zova");
}

pub fn expectDone(stmt: *sqlite.Statement) !void {
    switch (try stmt.step()) {
        .done => {},
        .row => return error.SqliteError,
    }
}

pub fn isValidCliVectorName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    return !startsWithZovaPrefix(name);
}

pub fn isValidCliExtensionName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (startsWithZovaPrefix(name)) return false;
    for (name) |byte| {
        const ok = (byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '_' or byte == '.' or byte == ':' or byte == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn startsWithZovaPrefix(name: []const u8) bool {
    const prefix = "_zova_";
    if (name.len < prefix.len) return false;
    for (prefix, 0..) |expected, index| {
        if (std.ascii.toLower(name[index]) != expected) return false;
    }
    return true;
}

pub fn lowerHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[@intCast(byte >> 4)];
        out[index * 2 + 1] = digits[@intCast(byte & 0x0f)];
    }
    return out;
}

pub fn graphTargetTypeText(target_type: zova.GraphTargetType) []const u8 {
    return switch (target_type) {
        .none => "none",
        .record => "record",
        .object => "object",
        .object_chunk => "object_chunk",
        .vector => "vector",
        .entity => "entity",
        .fact => "fact",
        .concept => "concept",
        .external => "external",
    };
}

pub fn graphTargetTypeFromText(text: []const u8) ?zova.GraphTargetType {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "record")) return .record;
    if (std.mem.eql(u8, text, "object")) return .object;
    if (std.mem.eql(u8, text, "object_chunk")) return .object_chunk;
    if (std.mem.eql(u8, text, "vector")) return .vector;
    if (std.mem.eql(u8, text, "entity")) return .entity;
    if (std.mem.eql(u8, text, "fact")) return .fact;
    if (std.mem.eql(u8, text, "concept")) return .concept;
    if (std.mem.eql(u8, text, "external")) return .external;
    return null;
}

pub fn graphDirectionText(direction: zova.GraphNeighborDirection) []const u8 {
    return switch (direction) {
        .outgoing => "outgoing",
        .incoming => "incoming",
    };
}

pub fn fileSize(path: [:0]const u8) u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return @intCast(stat.size);
}

pub fn fileSizeWithSuffix(allocator: std.mem.Allocator, path: [:0]const u8, suffix: []const u8) !u64 {
    const joined_raw = try std.mem.concat(allocator, u8, &.{ path, suffix });
    defer allocator.free(joined_raw);
    const joined = try allocator.dupeZ(u8, joined_raw);
    defer allocator.free(joined);
    return fileSize(joined);
}

pub fn quickCheck(db: *zova.Database) !void {
    try quickCheckSchema(db, "pragma quick_check");
    if (hasAttachedSchema(db, "object_store")) try quickCheckSchema(db, "pragma object_store.quick_check");
    if (hasAttachedSchema(db, "vector_store")) try quickCheckSchema(db, "pragma vector_store.quick_check");
    if (hasAttachedSchema(db, "graph_store")) try quickCheckSchema(db, "pragma graph_store.quick_check");
}

fn hasAttachedSchema(db: *zova.Database, comptime schema: []const u8) bool {
    var stmt = db.prepare("select 1 from " ++ schema ++ ".sqlite_master limit 1") catch return false;
    defer stmt.deinit();
    return true;
}

fn quickCheckSchema(db: *zova.Database, sql: [:0]const u8) !void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    while ((try stmt.step()) == .row) {
        if (!std.mem.eql(u8, stmt.columnText(0), "ok")) return error.CheckFailed;
    }
}

pub fn quoteSqlIdentifierAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var quote_count: usize = 0;
    for (name) |byte| {
        if (byte == '"') quote_count += 1;
    }

    const out = try allocator.alloc(u8, name.len + quote_count + 2);
    var index: usize = 0;
    out[index] = '"';
    index += 1;
    for (name) |byte| {
        out[index] = byte;
        index += 1;
        if (byte == '"') {
            out[index] = '"';
            index += 1;
        }
    }
    out[index] = '"';
    return out;
}

pub fn buildInsertAllSql(allocator: std.mem.Allocator, quoted_name: []const u8, column_count: usize) ![:0]u8 {
    if (column_count == 0) {
        return std.fmt.allocPrintSentinel(allocator, "insert into {s} default values", .{quoted_name}, 0);
    }

    const placeholders_len = column_count + (column_count - 1) * 2;
    const placeholders = try allocator.alloc(u8, placeholders_len);
    defer allocator.free(placeholders);

    var index: usize = 0;
    for (0..column_count) |column_index| {
        if (column_index != 0) {
            placeholders[index] = ',';
            placeholders[index + 1] = ' ';
            index += 2;
        }
        placeholders[index] = '?';
        index += 1;
    }

    return std.fmt.allocPrintSentinel(allocator, "insert into {s} values ({s})", .{ quoted_name, placeholders }, 0);
}

pub fn diagnosticObjectSchemaPrefix(db: *zova.Database) []const u8 {
    var stmt = db.prepare("select 1 from object_store.sqlite_master limit 1") catch return "";
    defer stmt.deinit();
    return "object_store.";
}

pub fn diagnosticVectorSchemaPrefix(db: *zova.Database) []const u8 {
    var stmt = db.prepare("select 1 from vector_store.sqlite_master limit 1") catch return "";
    defer stmt.deinit();
    return "vector_store.";
}

pub fn diagnosticGraphSchemaPrefix(db: *zova.Database) []const u8 {
    return if (hasAttachedSchema(db, "graph_store")) "graph_store." else "";
}

pub fn scalarU64(db: *zova.Database, sql: [:0]const u8) !u64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    return switch (try stmt.step()) {
        .row => @intCast(stmt.columnInt64(0)),
        .done => 0,
    };
}

pub fn sqliteMetaValueAlloc(allocator: std.mem.Allocator, db: *sqlite.Database, key: []const u8) !?[]u8 {
    var stmt = try db.prepare("select value from _zova_meta where key = ?");
    defer stmt.deinit();

    try stmt.bindText(1, key);
    return switch (try stmt.step()) {
        .done => null,
        .row => try allocator.dupe(u8, stmt.columnText(0)),
    };
}

pub fn scalarTextAlloc(allocator: std.mem.Allocator, db: *zova.Database, sql: [:0]const u8) ![]u8 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    return switch (try stmt.step()) {
        .row => try allocator.dupe(u8, stmt.columnText(0)),
        .done => try allocator.dupe(u8, ""),
    };
}
