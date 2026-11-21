//! Public-only multi-handle behavior tests. No private implementation helpers.
//!
//! These tests pin the behavior that `docs/concurrency.md` describes: one
//! writer handle and several reader handles on the same database file, with
//! and without bound stores, in WAL and in rollback-journal mode.

const Database = @import("zova.zig").Database;
const Notification = @import("zova.zig").Notification;
const ObjectId = @import("zova.zig").ObjectId;
const createGraphStore = @import("zova.zig").createGraphStore;
const createObjectStore = @import("zova.zig").createObjectStore;
const createVectorStore = @import("zova.zig").createVectorStore;
const std = @import("std");
const testingCount = @import("zova_test_support.zig").testingCount;
const testingDbPath = @import("zova_test_support.zig").testingDbPath;

const Journal = enum { rollback, wal };

/// Paths of one database set inside a test temporary directory.
const SetPaths = struct {
    main_buffer: [std.fs.max_path_bytes]u8 = undefined,
    object_buffer: [std.fs.max_path_bytes]u8 = undefined,
    vector_buffer: [std.fs.max_path_bytes]u8 = undefined,
    graph_buffer: [std.fs.max_path_bytes]u8 = undefined,
    main: [:0]u8 = undefined,

    fn init(self: *SetPaths, sub_path: []const u8) !void {
        self.main = try testingDbPath(&self.main_buffer, sub_path, "main.zova");
    }
};

/// Create the main database, optionally bind one external store of each kind,
/// select the journal mode for every file, and write one seed entry through
/// each subsystem.
fn createSeededSet(paths: *SetPaths, sub_path: []const u8, bound: bool, journal: Journal) !Database {
    try paths.init(sub_path);
    var writer = try Database.create(paths.main);
    errdefer writer.deinit();

    if (bound) {
        const object_path = try testingDbPath(&paths.object_buffer, sub_path, "objects.zova");
        const vector_path = try testingDbPath(&paths.vector_buffer, sub_path, "vectors.zova");
        const graph_path = try testingDbPath(&paths.graph_buffer, sub_path, "graphs.zova");
        try createObjectStore(object_path);
        try createVectorStore(vector_path);
        try createGraphStore(graph_path);
        try writer.bindObjectStore(object_path);
        try writer.bindVectorStore(vector_path);
        try writer.bindGraphStore(graph_path);
    }
    if (journal == .wal) {
        // The journal mode is stored in each file, so every member of the set
        // is switched separately.
        try writer.exec("pragma main.journal_mode=wal");
        if (bound) {
            try writer.exec("pragma object_store.journal_mode=wal");
            try writer.exec("pragma vector_store.journal_mode=wal");
            try writer.exec("pragma graph_store.journal_mode=wal");
        }
    }

    try writer.exec("create table records(id integer primary key, body text not null)");
    try writer.exec("insert into records(body) values('seed')");
    _ = try writer.putObject("seed object");
    try writer.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    try writer.putVector("v", "seed", .{ .f32 = &.{ 1, 2 } });
    try writer.createGraph("g");
    try writer.putGraphNode(.{ .graph_name = "g", .node_id = "seed", .kind = "n" });
    try writer.kvPut("ns", "seed", "value");
    return writer;
}

/// Write one new entry through SQL, objects, vectors, graphs and KV.
fn writeNewEntries(writer: *Database) !ObjectId {
    try writer.exec("insert into records(body) values('new')");
    const object_id = try writer.putObject("new object");
    try writer.putVector("v", "new", .{ .f32 = &.{ 3, 4 } });
    try writer.putGraphNode(.{ .graph_name = "g", .node_id = "new", .kind = "n" });
    try writer.kvPut("ns", "new", "value");
    return object_id;
}

/// Assert that `reader` sees either only the seed entries or the seed and new
/// entries, consistently across every subsystem.
fn expectView(reader: *Database, new_object: ObjectId, sees_new: bool) !void {
    const entries: i64 = if (sees_new) 2 else 1;
    try std.testing.expectEqual(entries, try testingCount(reader, "select count(*) from records"));
    try std.testing.expectEqual(sees_new, try reader.hasObject(new_object));
    try std.testing.expectEqual(sees_new, try reader.hasVector("v", "new"));
    try std.testing.expectEqual(sees_new, try reader.hasGraphNode("g", "new"));
    try std.testing.expectEqual(@as(u64, @intCast(entries)), try reader.kvCount("ns"));
}

test "WAL readers see the last committed state while a writer transaction is open" {
    for ([_]bool{ false, true }) |bound| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths: SetPaths = .{};
        var writer = try createSeededSet(&paths, tmp.sub_path[0..], bound, .wal);
        defer writer.deinit();

        var reader_a = try Database.openWithOptions(paths.main, .{ .read_only = true, .busy_timeout_ms = 1000 });
        defer reader_a.deinit();
        var reader_b = try Database.openWithOptions(paths.main, .{ .read_only = true, .busy_timeout_ms = 1000 });
        defer reader_b.deinit();

        try writer.beginImmediate();
        const new_object = try writeNewEntries(&writer);

        // Uncommitted writes are visible to the writer only. Readers are not
        // blocked and do not see them.
        try expectView(&writer, new_object, true);
        try expectView(&reader_a, new_object, false);
        try expectView(&reader_b, new_object, false);

        // A reader transaction that has read every member keeps that view
        // after the writer commits; a reader outside a transaction moves on.
        try reader_a.begin();
        try expectView(&reader_a, new_object, false);
        try writer.commit();
        try expectView(&reader_b, new_object, true);
        try expectView(&reader_a, new_object, false);
        try reader_a.rollback();
        try expectView(&reader_a, new_object, true);
    }
}

test "rollback-journal readers block the writer's commit until they finish" {
    for ([_]bool{ false, true }) |bound| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths: SetPaths = .{};
        var writer = try createSeededSet(&paths, tmp.sub_path[0..], bound, .rollback);
        defer writer.deinit();

        var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
        defer reader.deinit();

        try reader.begin();
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&reader, "select count(*) from records"));

        // The writer can start and stage its changes beside the open reader,
        // and the reader keeps reading the committed state.
        try writer.beginImmediate();
        const new_object = try writeNewEntries(&writer);
        try expectView(&reader, new_object, false);

        // The commit needs exclusive access to the main file, which the open
        // reader transaction denies. The writer transaction stays open.
        try std.testing.expectError(error.Busy, writer.commit());
        try expectView(&writer, new_object, true);

        try reader.rollback();
        try writer.commit();
        try expectView(&reader, new_object, true);
    }
}

test "a second writer fails with Busy at once without a timeout and waits with one" {
    for ([_]Journal{ .rollback, .wal }) |journal| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths: SetPaths = .{};
        var first = try createSeededSet(&paths, tmp.sub_path[0..], false, journal);
        defer first.deinit();
        var second = try Database.open(paths.main);
        defer second.deinit();

        try first.beginImmediate();
        try first.kvPut("ns", "first", "value");
        try std.testing.expectError(error.Busy, second.beginImmediate());
        try std.testing.expectError(error.Busy, second.kvPut("ns", "second", "value"));

        // With a busy timeout the second writer waits for the first to
        // commit. The result is the same whichever thread runs first.
        try second.setBusyTimeout(30_000);
        const Worker = struct {
            fn run(db: *Database, failure: *?anyerror) void {
                db.beginImmediate() catch |err| {
                    failure.* = err;
                };
            }
        };
        var failure: ?anyerror = null;
        const thread = try std.Thread.spawn(.{}, Worker.run, .{ &second, &failure });
        first.commit() catch |err| {
            thread.join();
            return err;
        };
        thread.join();
        try std.testing.expectEqual(@as(?anyerror, null), failure);

        try second.kvPut("ns", "second", "value");
        try second.commit();
        try std.testing.expectEqual(@as(u64, 3), try first.kvCount("ns"));
    }
}

test "bound-store WAL readers pin each file when they first read it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: SetPaths = .{};
    var writer = try createSeededSet(&paths, tmp.sub_path[0..], true, .wal);
    defer writer.deinit();

    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
    defer reader.deinit();

    // The reader transaction reads only the main file before the writer
    // commits one transaction that changes the main file and every store.
    try reader.begin();
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&reader, "select count(*) from records"));

    try writer.beginImmediate();
    const new_object = try writeNewEntries(&writer);
    try writer.commit();

    // The main file stays at the view taken before the commit, while each
    // store is first read after it: one reader transaction sees the two
    // halves of the writer's transaction at different points in time.
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&reader, "select count(*) from records"));
    try std.testing.expectEqual(@as(u64, 1), try reader.kvCount("ns"));
    try std.testing.expect(try reader.hasObject(new_object));
    try std.testing.expect(try reader.hasVector("v", "new"));
    try std.testing.expect(try reader.hasGraphNode("g", "new"));
    try reader.rollback();
    try expectView(&reader, new_object, true);
}

test "notifications are delivered only on the handle that published them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: SetPaths = .{};
    var writer = try createSeededSet(&paths, tmp.sub_path[0..], false, .wal);
    defer writer.deinit();
    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
    defer reader.deinit();

    var writer_sub = try writer.listen("records");
    defer writer_sub.deinit();
    var reader_sub = try reader.listen("records");
    defer reader_sub.deinit();

    try writer.beginImmediate();
    try writer.exec("insert into records(body) values('announced')");
    try writer.notify("records", "inserted");
    try writer.commit();

    {
        var note = (try writer_sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("inserted", note.payload);
    }
    // The reader handle sees the committed row but receives no notification.
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&reader, "select count(*) from records"));
    try std.testing.expectEqual(@as(?Notification, null), try reader_sub.tryReceive(std.testing.allocator));
}
