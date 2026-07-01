const std = @import("std");
const root = @import("root.zig");

const zova = @import("zova.zig");
const sqlite = @import("sqlite.zig");
const test_support = @import("zova_test_support.zig");

const testingDbPath = test_support.testingDbPath;

test "graph CRUD and traversal use application stable node ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-crud.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try db.createGraph("app");
    try db.putGraphNode(.{
        .graph_name = "app",
        .node_id = "message:1",
        .kind = "message",
        .target_type = .record,
        .target_ref = "messages:1",
    });
    try db.putGraphNode(.{
        .graph_name = "app",
        .node_id = "object:abc",
        .kind = "attachment",
        .target_type = .external,
        .target_ref = "object:abc",
    });
    try db.putGraphNode(.{
        .graph_name = "app",
        .node_id = "message:2",
        .kind = "message",
        .target_type = .record,
        .target_ref = "messages:2",
    });

    try db.putGraphEdge(.{ .graph_name = "app", .from_node_id = "message:1", .edge_type = "has_attachment", .to_node_id = "object:abc" });
    try db.putGraphEdge(.{ .graph_name = "app", .from_node_id = "message:1", .edge_type = "replies_to", .to_node_id = "message:2" });

    try std.testing.expect(try db.hasGraphNode("app", "message:1"));
    try std.testing.expect(try db.hasGraphEdge("app", "message:1", "has_attachment", "object:abc"));

    var node = try db.getGraphNode(std.testing.allocator, "app", "message:1");
    defer node.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("message:1", node.node_id);
    try std.testing.expectEqualStrings("message", node.kind);
    try std.testing.expectEqual(zova.GraphTargetType.record, node.target_type);
    try std.testing.expectEqualStrings("messages:1", node.target_ref.?);

    var neighbors = try db.graphNeighbors(std.testing.allocator, .{
        .graph_name = "app",
        .node_id = "message:1",
        .direction = .outgoing,
        .limit = 10,
    });
    defer neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), neighbors.items.len);
    try std.testing.expectEqualStrings("object:abc", neighbors.items[0].node_id);
    try std.testing.expectEqualStrings("has_attachment", neighbors.items[0].edge_type);
    try std.testing.expectEqualStrings("message:2", neighbors.items[1].node_id);
    try std.testing.expectEqualStrings("replies_to", neighbors.items[1].edge_type);

    var walk = try db.graphWalk(std.testing.allocator, .{
        .graph_name = "app",
        .start_node_id = "message:1",
        .max_depth = 2,
        .limit = 10,
    });
    defer walk.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), walk.items.len);
    try std.testing.expectEqualStrings("message:1", walk.items[0].node_id);
    try std.testing.expectEqual(@as(u32, 0), walk.items[0].depth);
}

test "graph validation rejects invalid ids and missing edge endpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-validation.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try std.testing.expectError(error.GraphInvalid, db.createGraph("_zova_private"));
    try db.createGraph("app");
    try std.testing.expectError(error.GraphInvalid, db.putGraphNode(.{
        .graph_name = "app",
        .node_id = "",
        .kind = "message",
    }));
    try std.testing.expectError(error.GraphNodeNotFound, db.putGraphEdge(.{
        .graph_name = "app",
        .from_node_id = "missing:1",
        .edge_type = "contains",
        .to_node_id = "missing:2",
    }));
}

test "graph traversal rejects limits larger than sqlite int64" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-limit.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try db.createGraph("app");
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:1", .kind = "message" });

    const too_large_limit: usize = @as(usize, @intCast(std.math.maxInt(i64))) + 1;
    try std.testing.expectError(error.GraphInvalid, db.graphNeighbors(std.testing.allocator, .{
        .graph_name = "app",
        .node_id = "message:1",
        .limit = too_large_limit,
    }));
    try std.testing.expectError(error.GraphInvalid, db.graphWalk(std.testing.allocator, .{
        .graph_name = "app",
        .start_node_id = "message:1",
        .limit = too_large_limit,
    }));
}

test "graph writes follow transactions and savepoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-transactions.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try db.createGraph("app");

    try db.begin();
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:rollback", .kind = "message" });
    try db.rollback();
    try std.testing.expect(!try db.hasGraphNode("app", "message:rollback"));

    try db.begin();
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:kept", .kind = "message" });
    try db.savepoint("sp1");
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:discarded", .kind = "message" });
    try db.rollbackToSavepoint("sp1");
    try db.releaseSavepoint("sp1");
    try db.commit();

    try std.testing.expect(try db.hasGraphNode("app", "message:kept"));
    try std.testing.expect(!try db.hasGraphNode("app", "message:discarded"));
}

test "graph high fan-out traversal stays bounded and deterministic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-fanout.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try db.createGraph("fanout");
    try db.putGraphNode(.{ .graph_name = "fanout", .node_id = "center", .kind = "center" });

    var index: usize = 0;
    while (index < 150) : (index += 1) {
        var id_buffer: [32]u8 = undefined;
        const node_id = try std.fmt.bufPrint(&id_buffer, "leaf:{d}", .{index});
        try db.putGraphNode(.{ .graph_name = "fanout", .node_id = node_id, .kind = "leaf" });
        try db.putGraphEdge(.{ .graph_name = "fanout", .from_node_id = "center", .edge_type = "contains", .to_node_id = node_id });
    }

    var neighbors = try db.graphNeighbors(std.testing.allocator, .{
        .graph_name = "fanout",
        .node_id = "center",
        .limit = 25,
    });
    defer neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 25), neighbors.items.len);
    try std.testing.expectEqualStrings("leaf:0", neighbors.items[0].node_id);
    try std.testing.expectEqualStrings("leaf:24", neighbors.items[24].node_id);

    var walk = try db.graphWalk(std.testing.allocator, .{
        .graph_name = "fanout",
        .start_node_id = "center",
        .max_depth = 1,
        .limit = 30,
    });
    defer walk.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 30), walk.items.len);
    try std.testing.expectEqualStrings("center", walk.items[0].node_id);
    try std.testing.expectEqual(@as(u32, 0), walk.items[0].depth);
    try std.testing.expectEqualStrings("leaf:0", walk.items[1].node_id);
    try std.testing.expectEqual(@as(u32, 1), walk.items[1].depth);

    var sql = try db.prepare(
        \\select rank, node_id
        \\from zova_graph_neighbors
        \\where graph_name = 'fanout'
        \\  and source_node_id = 'center'
        \\  and "limit" = 7
        \\order by rank
    );
    defer sql.deinit();

    var row_index: usize = 0;
    while (row_index < 7) : (row_index += 1) {
        try std.testing.expectEqual(sqlite.Step.row, try sql.step());
        try std.testing.expectEqual(@as(i64, @intCast(row_index + 1)), sql.columnInt64(0));
        var expected_buffer: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "leaf:{d}", .{row_index});
        try std.testing.expectEqualStrings(expected, sql.columnText(1));
    }
    try std.testing.expectEqual(sqlite.Step.done, try sql.step());
}

test "graph workflow uses explicit notifications after commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-notify.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();

    var sub = try db.listen("graph:changed");
    defer sub.deinit();

    try db.createGraph("app");
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:auto", .kind = "message" });
    try std.testing.expectEqual(@as(?zova.Notification, null), try sub.tryReceive(std.testing.allocator));

    try db.beginImmediate();
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:1", .kind = "message" });
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:2", .kind = "message" });
    try db.putGraphEdge(.{ .graph_name = "app", .from_node_id = "message:1", .edge_type = "mentions", .to_node_id = "message:2" });
    try db.notify("graph:changed", "app");
    try std.testing.expectEqual(@as(?zova.Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();

    var note = (try sub.tryReceive(std.testing.allocator)).?;
    defer note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("graph:changed", note.channel);
    try std.testing.expectEqualStrings("app", note.payload);
    try std.testing.expectEqual(@as(?zova.Notification, null), try sub.tryReceive(std.testing.allocator));
}

test "format version four requires graph schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "format-four.zova");

    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    {
        var meta = try raw.prepare("select value from _zova_meta where key = 'format_version'");
        defer meta.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try meta.step());
        try std.testing.expectEqualStrings("4", meta.columnText(0));
    }

    try std.testing.expect(try tableExists(&raw, "_zova_graphs"));
    try std.testing.expect(try tableExists(&raw, "_zova_graph_nodes"));
    try std.testing.expect(try tableExists(&raw, "_zova_graph_edges"));

    try raw.exec("drop table _zova_graph_edges");
    try std.testing.expectError(error.NotZovaDatabase, zova.Database.open(db_path));
}

test "root exports graph API" {
    try std.testing.expect(@hasDecl(root, "GraphTargetType"));
    try std.testing.expect(@hasDecl(root, "GraphNode"));
    try std.testing.expect(@hasDecl(root, "GraphEdgeInput"));
    try std.testing.expect(@hasDecl(root.Database, "createGraph"));
    try std.testing.expect(@hasDecl(root.Database, "graphNeighbors"));
    try std.testing.expect(@hasDecl(root.Database, "graphWalk"));
}

fn tableExists(db: *sqlite.Database, table_name: []const u8) !bool {
    var stmt = try db.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table' and name = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, table_name);
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    return stmt.columnInt64(0) == 1;
}
