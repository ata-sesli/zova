//! Copy verification (backup, compact) must reject every stored-object
//! corruption the object pass detects, including ones the chunk pass cannot
//! see because every chunk is individually valid.

const Database = @import("zova.zig").Database;
const ObjectId = @import("zova.zig").ObjectId;
const sqlite = @import("sqlite.zig");
const std = @import("std");
const testingDbPath = @import("zova_test_support.zig").testingDbPath;

const streaming: @import("zova.zig").ObjectPutOptions = .{ .profile = .streaming };

/// Two single-chunk objects of equal size, so either chunk fits either
/// manifest row without tripping a size check.
fn createTwoObjects(path: [:0]const u8, first: *ObjectId, second: *ObjectId) !void {
    var db = try Database.create(path);
    defer db.deinit();
    first.* = try db.putObjectWithOptions("first object bytes", streaming);
    second.* = try db.putObjectWithOptions("other object bytes", streaming);
}

fn corrupt(path: [:0]const u8, sql: [:0]const u8, id: ObjectId) !void {
    var raw = try sqlite.Database.open(path);
    defer raw.deinit();
    try raw.exec("pragma foreign_keys = off");
    var stmt = try raw.prepare(sql);
    defer stmt.deinit();
    try stmt.bindBlob(1, &id);
    _ = try stmt.step();
}

fn expectCopiesRejected(dir: []const u8, source_path: [:0]const u8, name: []const u8) !void {
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try std.fmt.bufPrintSentinel(&backup_buffer, "{s}/{s}-backup.zova", .{ dir, name }, 0);
    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try std.fmt.bufPrintSentinel(&compact_buffer, "{s}/{s}-compact.zova", .{ dir, name }, 0);
    var unverified_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const unverified_path = try std.fmt.bufPrintSentinel(&unverified_buffer, "{s}/{s}-unverified.zova", .{ dir, name }, 0);

    var db = try Database.open(source_path);
    defer db.deinit();
    try std.testing.expectError(error.ObjectCorrupt, db.backupTo(backup_path, .{}));
    try std.testing.expectError(error.ObjectCorrupt, db.compactTo(compact_path, .{}));
    // The corruption is in the data, not the copy: skipping verification copies it.
    try db.backupTo(unverified_path, .{ .verify = false });
}

test "copy verification rejects an object whose chunks are valid but are not its bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "swapped.zova");

    var first: ObjectId = undefined;
    var second: ObjectId = undefined;
    try createTwoObjects(path, &first, &second);
    {
        var raw = try sqlite.Database.open(path);
        defer raw.deinit();
        var stmt = try raw.prepare(
            \\update _zova_object_chunks
            \\set chunk_hash = (select chunk_hash from _zova_object_chunks where object_id = ?2)
            \\where object_id = ?1
        );
        defer stmt.deinit();
        try stmt.bindBlob(1, &first);
        try stmt.bindBlob(2, &second);
        _ = try stmt.step();
    }
    try expectCopiesRejected(dir, path, "swapped");
}

test "copy verification rejects broken object manifests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    const cases = [_]struct { name: []const u8, sql: [:0]const u8 }{
        .{ .name = "missing-row", .sql = "delete from _zova_object_chunks where object_id = ?1" },
        .{ .name = "extra-count", .sql = "update _zova_objects set chunk_count = chunk_count + 1 where object_id = ?1" },
        .{ .name = "short-size", .sql = "update _zova_objects set size_bytes = size_bytes - 1 where object_id = ?1" },
        .{ .name = "bad-offset", .sql = "update _zova_object_chunks set offset = 1 where object_id = ?1" },
        .{ .name = "bad-index", .sql = "update _zova_object_chunks set chunk_index = 1 where object_id = ?1" },
    };
    for (cases) |case| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s}.zova", .{case.name});
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try testingDbPath(&path_buffer, tmp.sub_path[0..], name);
        var first: ObjectId = undefined;
        var second: ObjectId = undefined;
        try createTwoObjects(path, &first, &second);
        try corrupt(path, case.sql, first);
        expectCopiesRejected(dir, path, case.name) catch |err| {
            std.debug.print("case {s}\n", .{case.name});
            return err;
        };
    }
}

test "copy verification accepts multi-chunk and empty objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "large.zova");
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "large-backup.zova");
    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "large-compact.zova");

    // Larger than the reader's 64 KiB scratch and spanning several chunks.
    const bytes = try std.testing.allocator.alloc(u8, 3 * 1024 * 1024 + 12345);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 2654435761 >> 7);

    var db = try Database.create(path);
    defer db.deinit();
    _ = try db.putObjectWithOptions(bytes, streaming);
    _ = try db.putObject(bytes[0 .. 300 * 1024]);
    _ = try db.putObject("");
    try db.backupTo(backup_path, .{});
    try db.compactTo(compact_path, .{});
}

test "copy verification checks loose chunks larger than the FastCDC limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    const data = try std.testing.allocator.alloc(u8, 200 * 1024);
    defer std.testing.allocator.free(data);
    @memset(data, 0x5a);
    const hash = @import("zova.zig").objectId(data);

    // Valid: no object references it, and only the chunk pass reads it.
    var valid_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const valid_path = try testingDbPath(&valid_buffer, tmp.sub_path[0..], "loose-valid.zova");
    var corrupt_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const corrupt_path = try testingDbPath(&corrupt_buffer, tmp.sub_path[0..], "loose-corrupt.zova");
    for ([_][:0]const u8{ valid_path, corrupt_path }) |path| {
        {
            var db = try Database.create(path);
            db.deinit();
        }
        var raw = try sqlite.Database.open(path);
        defer raw.deinit();
        var stmt = try raw.prepare("insert into _zova_chunks (chunk_hash, size_bytes, data) values (?1, ?2, ?3)");
        defer stmt.deinit();
        try stmt.bindBlob(1, &hash);
        try stmt.bindInt64(2, @intCast(data.len));
        if (path.ptr == corrupt_path.ptr) data[100] ^= 1;
        try stmt.bindBlob(3, data);
        _ = try stmt.step();
    }

    {
        var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "loose-valid-backup.zova");
        var db = try Database.open(valid_path);
        defer db.deinit();
        try db.backupTo(backup_path, .{});
    }
    try expectCopiesRejected(dir, corrupt_path, "loose-corrupt");
}
