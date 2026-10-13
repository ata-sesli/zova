//! Public-only Database behavior tests. No private implementation helpers.

const Database = @import("zova.zig").Database;
const createGraphStore = @import("zova.zig").createGraphStore;
const createObjectStore = @import("zova.zig").createObjectStore;
const std = @import("std");
const testingDbPath = @import("zova_test_support.zig").testingDbPath;

test "bind and unbind graph store preserve external graph data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bind-graph-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bind-graph-store.zova");
    try createGraphStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindGraphStore(store_path);
    try db.createGraph("deps");
    try db.putGraphNode(.{ .graph_name = "deps", .node_id = "a", .kind = "file" });
    var info = (try db.boundGraphStore(std.testing.allocator)).?;
    defer info.deinit(std.testing.allocator);

    try db.unbindGraphStore();
    try std.testing.expect(!(try db.hasGraph("deps")));
    try db.bindGraphStore(store_path);
    try std.testing.expect(try db.hasGraphNode("deps", "a"));
}

test "graph binding rejects nonempty main storage and active transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-reject-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-reject-store.zova");
    try createGraphStore(store_path);
    var db = try Database.create(main_path);
    defer db.deinit();
    try db.createGraph("local");
    try std.testing.expectError(error.BoundStoreExists, db.bindGraphStore(store_path));
    try db.deleteGraph("local");
    try db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.bindGraphStore(store_path));
    try db.rollback();
}

test "sequential object reader routes through a bound object store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "reader-main.zova");
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "reader-objects.zova");
    try createObjectStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(store_path);

    const payload = "sequential bytes from the bound object store";
    const id = try db.putObjectWithOptions(payload, .{ .profile = .deduplication });
    var reader = try db.objectReader(id);
    defer reader.deinit();

    var output: [payload.len]u8 = undefined;
    try std.testing.expectEqual(output.len, try reader.read(&output));
    try std.testing.expectEqualSlices(u8, payload, &output);
    try std.testing.expectEqual(@as(usize, 0), try reader.read(&output));
}

test "failed bound object epoch update rolls back the entire caller operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "epoch-failure-main.zova");
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "epoch-failure-store.zova");
    try createObjectStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(store_path);
    try db.exec("create table caller_work (value text not null)");
    try db.exec(
        "create temp trigger reject_object_epoch before update of object_epoch " ++
            "on main._zova_bound_stores begin select raise(abort, 'epoch update failed'); end",
    );

    try db.begin();
    try db.exec("insert into caller_work values ('earlier work')");
    const payload = "bound object whose epoch update fails";
    try std.testing.expectError(error.Constraint, db.putObject(payload));
    try std.testing.expect(!(try db.hasObject(@import("object.zig").objectId(payload))));

    var count = try db.sqlite_db.prepare("select count(*) from caller_work");
    defer count.deinit();
    try std.testing.expect((try count.step()) == .row);
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
    try db.rollback();
}

test "failed replacement bind preserves the current attached object store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-bind-failure-main.zova");

    var old_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const old_store_path = try testingDbPath(&old_store_buffer, tmp.sub_path[0..], "bound-bind-failure-old.zova");

    var missing_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_store_path = try testingDbPath(&missing_store_buffer, tmp.sub_path[0..], "bound-bind-failure-missing.zova");

    try createObjectStore(old_store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(old_store_path);

    const id = try db.putObject("old store remains attached");
    try std.testing.expectError(error.NotZovaDatabase, db.bindObjectStore(missing_store_path));

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "old store remains attached", object.bytes);

    var info = (try db.boundObjectStore(std.testing.allocator)).?;
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, info.path, "bound-bind-failure-old.zova"));
}

test "object store binding changes are rejected inside active transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-transaction-main.zova");

    var store_one_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_one_path = try testingDbPath(&store_one_buffer, tmp.sub_path[0..], "bound-transaction-one.zova");

    var store_two_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_two_path = try testingDbPath(&store_two_buffer, tmp.sub_path[0..], "bound-transaction-two.zova");

    try createObjectStore(store_one_path);
    try createObjectStore(store_two_path);

    var db = try Database.create(main_path);
    defer db.deinit();

    try db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.bindObjectStore(store_one_path));
    try db.rollback();

    try db.bindObjectStore(store_one_path);

    try db.savepoint("sp");
    try std.testing.expectError(error.ObjectTransactionActive, db.unbindObjectStore());
    try std.testing.expectError(error.ObjectTransactionActive, db.bindObjectStore(store_two_path));
    try db.releaseSavepoint("sp");
}

test "object store files are not accepted as main databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "role-object-store.zova");

    try createObjectStore(store_path);
    try std.testing.expectError(error.BoundStoreInvalid, Database.open(store_path));
}

test "each binding row sets only its own epoch column on bind rebind and mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffers: [4][std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&buffers[0], tmp.sub_path[0..], "epoch-columns-main.zova");
    const object_path = try testingDbPath(&buffers[1], tmp.sub_path[0..], "epoch-columns-object.zova");
    const vector_path = try testingDbPath(&buffers[2], tmp.sub_path[0..], "epoch-columns-vector.zova");
    const graph_path = try testingDbPath(&buffers[3], tmp.sub_path[0..], "epoch-columns-graph.zova");
    try createObjectStore(object_path);
    try @import("zova.zig").createVectorStore(vector_path);
    try createGraphStore(graph_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    const expected = [_][]const u8{ "graph_store|null|null|integer", "object_store|integer|null|null", "vector_store|null|integer|null" };

    // First pass inserts each row, second pass replaces it through the update path.
    for (0..2) |_| {
        try db.bindObjectStore(object_path);
        try db.bindVectorStore(vector_path);
        try db.bindGraphStore(graph_path);

        var stmt = try db.prepare(
            \\select role || '|' || typeof(object_epoch) || '|' || typeof(vector_epoch) || '|' || typeof(graph_epoch)
            \\from _zova_bound_stores order by role
        );
        defer stmt.deinit();
        for (expected) |row| {
            try std.testing.expectEqual(.row, try stmt.step());
            try std.testing.expectEqualStrings(row, stmt.columnText(0));
        }
        try std.testing.expectEqual(.done, try stmt.step());
    }

    _ = try db.putObject("epoch");
    var object_info = (try db.boundObjectStore(std.testing.allocator)).?;
    defer object_info.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), object_info.object_epoch);
    var vector_info = (try db.boundVectorStore(std.testing.allocator)).?;
    defer vector_info.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), vector_info.vector_epoch);
    var graph_info = (try db.boundGraphStore(std.testing.allocator)).?;
    defer graph_info.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), graph_info.graph_epoch);
}
