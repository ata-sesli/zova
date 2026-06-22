//! Shared test helpers for Zova implementation tests.

const std = @import("std");
const fastcdc = @import("object_fastcdc.zig");
const object = @import("object.zig");
const sqlite = @import("sqlite.zig");
const vector = @import("vector.zig");

pub fn testingDbPath(buffer: []u8, sub_path: []const u8, filename: []const u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buffer, ".zig-cache/tmp/{s}/{s}", .{ sub_path, filename });
}

pub fn testingWriteMetadata(db: *sqlite.Database, magic: []const u8, version_value: []const u8) !void {
    try db.exec(
        \\create table _zova_meta (
        \\  key text primary key,
        \\  value text not null
        \\);
    );

    var insert = try db.prepare("insert into _zova_meta (key, value) values (?, ?)");
    defer insert.deinit();

    try insert.bindText(1, "magic");
    try insert.bindText(2, magic);
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());

    try insert.reset();
    try insert.clearBindings();

    try insert.bindText(1, "format_version");
    try insert.bindText(2, version_value);
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());
}

pub fn testingExpectTableCount(db: *sqlite.Database, table_name: []const u8, expected: i64) !void {
    var count = try db.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table' and name = ?
    );
    defer count.deinit();

    try count.bindText(1, table_name);
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    try std.testing.expectEqual(expected, count.columnInt64(0));
}

pub fn testingCount(db: anytype, sql: [:0]const u8) !i64 {
    var count = try db.prepare(sql);
    defer count.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    return count.columnInt64(0);
}

pub fn testingObjectManifestCount(db: anytype, id: object.ObjectId) !i64 {
    var count = try db.prepare("select count(*) from _zova_object_chunks where object_id = ?");
    defer count.deinit();

    try count.bindBlob(1, &id);
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    return count.columnInt64(0);
}

pub fn testingSharedChunkCount(db: anytype, left_id: object.ObjectId, right_id: object.ObjectId) !i64 {
    var count = try db.prepare(
        \\select count(*)
        \\from _zova_object_chunks left_chunks
        \\join _zova_object_chunks right_chunks
        \\  on right_chunks.chunk_hash = left_chunks.chunk_hash
        \\where left_chunks.object_id = ?
        \\  and right_chunks.object_id = ?
    );
    defer count.deinit();

    try count.bindBlob(1, &left_id);
    try count.bindBlob(2, &right_id);
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    return count.columnInt64(0);
}

pub fn testingExpectObjectMissing(db: anytype, id: object.ObjectId) !void {
    try std.testing.expect(!try db.hasObject(id));
    try std.testing.expectError(error.ObjectNotFound, db.objectSize(id));
    try std.testing.expectError(error.ObjectNotFound, db.objectChunkCount(id));
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, id));
}

pub fn testingQuickCheckOk(db: anytype) !void {
    var stmt = try db.prepare("pragma quick_check");
    defer stmt.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("ok", stmt.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

pub fn testingIntegrityCheckOk(db: anytype) !void {
    var stmt = try db.prepare("pragma integrity_check");
    defer stmt.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("ok", stmt.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

pub fn testingPutLooseManifest(allocator: std.mem.Allocator, db: anytype, bytes: []const u8) ![]object.ObjectChunk {
    var chunks: std.ArrayList(object.ObjectChunk) = .empty;
    errdefer chunks.deinit(allocator);

    var offset: usize = 0;
    var index: u64 = 0;
    while (offset < bytes.len) {
        const chunk_len = fastcdc.cut(bytes[offset..]);
        const chunk_bytes = bytes[offset .. offset + chunk_len];
        const hash = object.objectChunkId(chunk_bytes);
        try db.putObjectChunk(hash, chunk_bytes);
        try chunks.append(allocator, .{
            .index = index,
            .hash = hash,
            .offset = @intCast(offset),
            .size_bytes = @intCast(chunk_len),
        });
        offset += chunk_len;
        index += 1;
    }

    return try chunks.toOwnedSlice(allocator);
}

pub fn testingStreamObject(db: anytype, bytes: []const u8, pieces: []const usize) !object.ObjectId {
    var writer = try db.objectWriter(std.testing.allocator);
    defer writer.deinit();

    var offset: usize = 0;
    var piece_index: usize = 0;
    while (offset < bytes.len) {
        const requested = if (pieces.len == 0) bytes.len else pieces[piece_index % pieces.len];
        std.debug.assert(requested > 0);
        const len = @min(requested, bytes.len - offset);
        try writer.write(bytes[offset .. offset + len]);
        offset += len;
        piece_index += 1;
    }

    return try writer.finish();
}

pub const TestingTrackingAllocator = struct {
    backing: std.mem.Allocator,
    largest_request: usize = 0,

    pub fn allocator(self: *TestingTrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn record(self: *TestingTrackingAllocator, len: usize) void {
        self.largest_request = @max(self.largest_request, len);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TestingTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.record(len);
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *TestingTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.record(new_len);
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TestingTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.record(new_len);
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TestingTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

pub fn testingExpectObjectBytes(db: anytype, id: object.ObjectId, expected: []const u8) !void {
    var stored = try db.getObject(std.testing.allocator, id);
    defer stored.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &stored.id);
    try std.testing.expectEqualSlices(u8, expected, stored.bytes);
}

pub fn testingExpectManifestsEqual(left: object.ObjectManifest, right: object.ObjectManifest) !void {
    try std.testing.expectEqualSlices(u8, &left.object_id, &right.object_id);
    try std.testing.expectEqual(left.size_bytes, right.size_bytes);
    try std.testing.expectEqual(left.chunk_count, right.chunk_count);
    try std.testing.expectEqualStrings(left.chunker, right.chunker);
    try std.testing.expectEqual(left.chunks.len, right.chunks.len);

    for (left.chunks, right.chunks) |left_chunk, right_chunk| {
        try std.testing.expectEqual(left_chunk.index, right_chunk.index);
        try std.testing.expectEqualSlices(u8, &left_chunk.hash, &right_chunk.hash);
        try std.testing.expectEqual(left_chunk.offset, right_chunk.offset);
        try std.testing.expectEqual(left_chunk.size_bytes, right_chunk.size_bytes);
    }
}

pub fn expectSearchIds(results: *const vector.VectorSearchResults, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, results.items.len);
    for (expected, 0..) |expected_id, index| {
        try std.testing.expectEqualStrings(expected_id, results.items[index].id);
    }
}

pub fn expectSqlPrepareOrStepError(db: anytype, sql: [:0]const u8) !void {
    var stmt = db.prepare(sql) catch return;
    defer stmt.deinit();

    _ = stmt.step() catch return;
    try std.testing.expect(false);
}
