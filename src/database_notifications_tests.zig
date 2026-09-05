//! Public-only Database behavior tests. No private implementation helpers.

const Database = @import("zova.zig").Database;
const Notification = @import("zova.zig").Notification;
const std = @import("std");
const testingDbPath = @import("zova_test_support.zig").testingDbPath;

test "notifications deliver after commit and rollback suppresses pending events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "notifications.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var sub = try db.listen("messages");
    defer sub.deinit();

    try db.notify("messages", "outside");
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("messages", note.channel);
        try std.testing.expectEqualStrings("outside", note.payload);
        try std.testing.expectEqual(@as(u64, 1), note.sequence);
        try std.testing.expectEqual(@as(u64, 0), note.dropped_before);
    }
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));

    try db.beginImmediate();
    try db.notify("messages", "committed");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("committed", note.payload);
    }

    try db.beginImmediate();
    try db.exec("select zova_notify('messages', 'sql-committed')");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("sql-committed", note.payload);
    }

    try db.exec("begin immediate");
    try std.testing.expectError(error.SqliteError, db.exec("select zova_notify('messages', 'raw-sql-transaction')"));
    try db.exec("rollback");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));

    try db.beginImmediate();
    try db.notify("messages", "rolled-back");
    try db.rollback();
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
}

test "notification savepoint release and rollback follow sqlite savepoint semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "notification-savepoints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var sub = try db.listen("objects:changed");
    defer sub.deinit();

    try db.beginImmediate();
    try db.notify("objects:changed", "outer");
    try db.savepoint("inner");
    try db.notify("objects:changed", "discarded");
    try db.rollbackToSavepoint("inner");
    try db.notify("objects:changed", "after-rollback-to");
    try db.releaseSavepoint("inner");
    try db.commit();

    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("outer", note.payload);
    }
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("after-rollback-to", note.payload);
    }
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));

    try db.beginImmediate();
    try db.savepoint("inner");
    try db.notify("objects:changed", "released");
    try db.releaseSavepoint("inner");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();

    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("released", note.payload);
    }
}

test "notifications support multiple listeners read-only handles and per-handle hubs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "notification-listeners.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();

        var first = try db.listen("events");
        defer first.deinit();
        var second = try db.listen("events");
        defer second.deinit();
        var other = try db.listen("other");
        defer other.deinit();
        var closed = try db.listen("events");
        closed.deinit();

        try db.notify("events", "one");

        var first_note = (try first.tryReceive(std.testing.allocator)).?;
        defer first_note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("one", first_note.payload);

        var second_note = (try second.tryReceive(std.testing.allocator)).?;
        defer second_note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("one", second_note.payload);

        try std.testing.expectEqual(@as(?Notification, null), try other.tryReceive(std.testing.allocator));
    }

    {
        var writer = try Database.open(db_path);
        defer writer.deinit();
        var reader = try Database.open(db_path);
        defer reader.deinit();

        var writer_sub = try writer.listen("local");
        defer writer_sub.deinit();
        var reader_sub = try reader.listen("local");
        defer reader_sub.deinit();

        try writer.notify("local", "writer-only");
        var note = (try writer_sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("writer-only", note.payload);
        try std.testing.expectEqual(@as(?Notification, null), try reader_sub.tryReceive(std.testing.allocator));
    }

    {
        var readonly = try Database.openWithOptions(db_path, .{ .read_only = true });
        defer readonly.deinit();
        var sub = try readonly.listen("readonly");
        defer sub.deinit();
        try readonly.notify("readonly", "local");
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("local", note.payload);
    }
}

test "notifications and SQL transactions share one deferred delivery scope" {
    var db = try Database.createMemory();
    defer db.deinit();

    var sql_sub = try db.listen("sql:changed");
    defer sql_sub.deinit();
    var kv_sub = try db.listen("cache:search-results");
    defer kv_sub.deinit();

    try db.beginImmediate();
    try db.exec("select zova_notify('sql:changed', 'row-updated')");
    try db.kvPutMany("search-results", &.{ .{ .key = "result-1", .value = "one" }, .{ .key = "result-2", .value = "two" } });
    try db.notify("cache:search-results", "generation:42");
    try std.testing.expectEqual(@as(?Notification, null), try sql_sub.tryReceive(std.testing.allocator));
    try std.testing.expectEqual(@as(?Notification, null), try kv_sub.tryReceive(std.testing.allocator));
    try db.commit();

    var sql_note = (try sql_sub.tryReceive(std.testing.allocator)).?;
    defer sql_note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("row-updated", sql_note.payload);

    var kv_note = (try kv_sub.tryReceive(std.testing.allocator)).?;
    defer kv_note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("generation:42", kv_note.payload);

    var value = try db.kvGet(std.testing.allocator, "search-results", "result-1");
    defer value.deinit(std.testing.allocator);
    try std.testing.expect(value.found);
    try std.testing.expectEqualSlices(u8, "one", value.value);
    try std.testing.expectEqual(@as(?Notification, null), try sql_sub.tryReceive(std.testing.allocator));
    try std.testing.expectEqual(@as(?Notification, null), try kv_sub.tryReceive(std.testing.allocator));
}

test "closing a subscription releases its delivery hub and never re-delivers" {
    var db = try Database.createMemory();
    defer db.deinit();

    var sub = try db.listen("events");
    try db.notify("events", "before-close");
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("before-close", note.payload);
    }

    sub.deinit();
    try std.testing.expectError(error.InvalidArgument, sub.tryReceive(std.testing.allocator));

    var reopened = try db.listen("events");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(?Notification, null), try reopened.tryReceive(std.testing.allocator));

    try db.notify("events", "after-reopen");
    var note = (try reopened.tryReceive(std.testing.allocator)).?;
    defer note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("after-reopen", note.payload);
}
