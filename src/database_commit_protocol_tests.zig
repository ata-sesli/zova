//! Format-15 commit-protocol markers: validation and refusal of CWAL sets.

const std = @import("std");
const zova = @import("zova.zig");
const commit_protocol = @import("database/commit_protocol.zig");
const sqlite = @import("sqlite.zig");
const testingDbPath = @import("zova_test_support.zig").testingDbPath;

const Database = zova.Database;
const cwal_available = @import("database/cwal_set.zig").available;

fn readFileAlloc(path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .unlimited);
}

fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn execRaw(path: [:0]const u8, sql: [:0]const u8) !void {
    var raw = try sqlite.Database.open(path);
    defer raw.deinit();
    try raw.exec(sql);
}

/// A main file bound to a vector store, both closed.
fn createBoundSet(main_path: [:0]const u8, store_path: [:0]const u8) !void {
    try zova.createVectorStore(store_path);
    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindVectorStore(store_path);
}

const marker_sql = commit_protocol.marker_schema_sql ++ "; insert into _zova_cwal_marker values (0, 0, 0)";
const declare_sql = "insert into _zova_meta (key, value) values ('commit_protocol', 'cwal-1')";

test "format 15 opens a set that declares the protocol and has every marker table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "store.zova");
    try createBoundSet(main_path, store_path);

    try execRaw(main_path, declare_sql ++ "; " ++ marker_sql);
    try execRaw(store_path, marker_sql);

    var db = try Database.open(main_path);
    db.deinit();
}

test "the protocol key without marker tables is an interrupted transition and opens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "store.zova");
    try createBoundSet(main_path, store_path);

    try execRaw(main_path, declare_sql);
    var db = try Database.open(main_path);
    db.deinit();
}

test "a marker table without the protocol key is refused in main and in a store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "store.zova");
    try createBoundSet(main_path, store_path);

    try execRaw(store_path, marker_sql);
    try std.testing.expectError(error.NotZovaDatabase, Database.open(main_path));

    try execRaw(store_path, "drop table _zova_cwal_marker");
    try execRaw(main_path, marker_sql);
    try std.testing.expectError(error.NotZovaDatabase, Database.open(main_path));
}

test "a marker table with another definition or an unknown protocol value is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "main.zova");
    var db = try Database.create(main_path);
    db.deinit();

    try execRaw(main_path, declare_sql ++ "; create table _zova_cwal_marker(k integer primary key, txn integer not null)");
    try std.testing.expectError(error.NotZovaDatabase, Database.open(main_path));

    try execRaw(main_path, "drop table _zova_cwal_marker; update _zova_meta set value = 'cwal-2' where key = 'commit_protocol'");
    try std.testing.expectError(error.NotZovaDatabase, Database.open(main_path));

    try execRaw(main_path, "update _zova_meta set value = 'cwal-1' where key = 'commit_protocol'");
    var reopened = try Database.open(main_path);
    reopened.deinit();
}

test "a standalone store accepts only the exact marker table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "store.zova");
    try zova.createVectorStore(store_path);

    try execRaw(store_path, marker_sql);
    {
        var raw = try sqlite.Database.open(store_path);
        defer raw.deinit();
        try @import("database/validation.zig").validateVectorStoreDatabaseExpected(&raw, @import("version.zig").format_version);
        try raw.exec("drop table _zova_cwal_marker; create table _zova_cwal_marker(k integer primary key)");
        try std.testing.expectError(error.NotZovaDatabase, @import("database/validation.zig").validateVectorStoreDatabaseExpected(&raw, @import("version.zig").format_version));
    }
}

test "the raw header flag check reads only SQLite headers with the CWAL application_id" {
    var header: [100]u8 = @splat(0);
    @memcpy(header[0..16], "SQLite format 3\x00");
    try std.testing.expect(!commit_protocol.headerHasFlag(&header));
    std.mem.writeInt(i32, header[68..72], commit_protocol.application_id, .big);
    try std.testing.expect(commit_protocol.headerHasFlag(&header));
    header[0] = 'X';
    try std.testing.expect(!commit_protocol.headerHasFlag(&header));
}

test "a CWAL set is refused before SQLite opens it, and its files stay unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "main.zova");
    var wal_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = try testingDbPath(&wal_buffer, tmp.sub_path[0..], "main.zova-wal");
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "dest.zova");
    var db = try Database.create(main_path);
    db.deinit();

    // The flag is checkpointed into the header; one later commit stays in
    // the WAL, as a torn commit could.
    {
        var raw = try sqlite.Database.open(main_path);
        defer raw.deinit();
        try raw.exec("pragma journal_mode = wal; pragma main.application_id = 1514362673; pragma wal_checkpoint(truncate)");
        _ = sqlite.c.sqlite3_db_config(raw.handle, sqlite.c.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, @as(c_int, 1), @as(?*c_int, null));
        try raw.exec("insert into _zova_kv (namespace, key, value) values ('n', x'01', x'02')");
    }
    comptime std.debug.assert(commit_protocol.application_id == 1514362673);
    try std.testing.expect(try commit_protocol.rawFlagSet(main_path));

    const main_before = try readFileAlloc(main_path);
    defer std.testing.allocator.free(main_before);
    const wal_before = try readFileAlloc(wal_path);
    defer std.testing.allocator.free(wal_before);

    // A CWAL build opens the set (database_cwal_set_tests.zig).
    if (!cwal_available) {
        try std.testing.expectError(error.UnsupportedZovaVersion, Database.open(main_path));
        try std.testing.expectError(error.UnsupportedZovaVersion, Database.openWithOptions(main_path, .{ .read_only = true }));
    }
    try std.testing.expectError(error.UnsupportedZovaVersion, zova.openForLogicalInspection(main_path));
    try std.testing.expectError(error.UnsupportedZovaVersion, zova.migrateDatabase(main_path, dest_path, .{}));
    try std.testing.expect(!fileExists(dest_path));

    const main_after = try readFileAlloc(main_path);
    defer std.testing.allocator.free(main_after);
    const wal_after = try readFileAlloc(wal_path);
    defer std.testing.allocator.free(wal_after);
    try std.testing.expectEqualSlices(u8, main_before, main_after);
    try std.testing.expectEqualSlices(u8, wal_before, wal_after);
}

test "a CWAL flag still only in the WAL is refused without a checkpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "main.zova");
    var wal_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = try testingDbPath(&wal_buffer, tmp.sub_path[0..], "main.zova-wal");
    var db = try Database.create(main_path);
    db.deinit();

    // Enable crashed between committing the flag and checkpointing it.
    {
        var raw = try sqlite.Database.open(main_path);
        defer raw.deinit();
        try raw.exec("pragma journal_mode = wal");
        _ = sqlite.c.sqlite3_db_config(raw.handle, sqlite.c.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, @as(c_int, 1), @as(?*c_int, null));
        try raw.exec("pragma main.application_id = 1514362673");
    }
    try std.testing.expect(!try commit_protocol.rawFlagSet(main_path));

    const main_before = try readFileAlloc(main_path);
    defer std.testing.allocator.free(main_before);
    const wal_before = try readFileAlloc(wal_path);
    defer std.testing.allocator.free(wal_before);

    // A CWAL build's writer finishes the enable (database_cwal_set_tests.zig).
    // A CWAL build's reader asks for a read-write open first.
    if (!cwal_available) try std.testing.expectError(error.UnsupportedZovaVersion, Database.open(main_path));
    try std.testing.expectError(
        if (cwal_available) error.CommitSetNeedsRepair else error.UnsupportedZovaVersion,
        Database.openWithOptions(main_path, .{ .read_only = true }),
    );
    try std.testing.expectError(error.UnsupportedZovaVersion, zova.openForLogicalInspection(main_path));

    const main_after = try readFileAlloc(main_path);
    defer std.testing.allocator.free(main_after);
    const wal_after = try readFileAlloc(wal_path);
    defer std.testing.allocator.free(wal_after);
    try std.testing.expectEqualSlices(u8, main_before, main_after);
    try std.testing.expectEqualSlices(u8, wal_before, wal_after);
}
