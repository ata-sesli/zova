const std = @import("std");
const sqlite = @import("sqlite.zig");
const test_support = @import("zova_test_support.zig");
const zova = @import("zova.zig");

const Database = zova.Database;
const expectSqlPrepareOrStepError = test_support.expectSqlPrepareOrStepError;
const testingDbPath = test_support.testingDbPath;
const default_graph_name = "default";

test "sql graph neighbors joins returned node ids to user SQL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-sql-neighbors.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try seedGraphSqlFixture(&db);

    {
        var stmt = try db.prepare(
            \\select m.body, g.rank, g.edge_type
            \\from zova_graph_neighbors as g
            \\join messages as m on m.graph_node_id = g.node_id
            \\where g.graph_name = 'default'
            \\  and g.source_node_id = 'message:1'
            \\  and g.direction = 'outgoing'
            \\  and g."limit" = 20
            \\order by g.rank
        );
        defer stmt.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("second message", stmt.columnText(0));
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(1));
        try std.testing.expectEqualStrings("replies_to", stmt.columnText(2));

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("attachment metadata", stmt.columnText(0));
        try std.testing.expectEqual(@as(i64, 2), stmt.columnInt64(1));
        try std.testing.expectEqualStrings("has_attachment", stmt.columnText(2));

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("entity metadata", stmt.columnText(0));
        try std.testing.expectEqual(@as(i64, 3), stmt.columnInt64(1));
        try std.testing.expectEqualStrings("mentions", stmt.columnText(2));

        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    {
        var stmt = try db.prepare(
            \\select node_id, kind, edge_type
            \\from zova_graph_neighbors
            \\where graph_name = 'default'
            \\  and source_node_id = 'attachment:1'
            \\  and direction = 'incoming'
            \\  and edge_type_filter = 'has_attachment'
            \\  and "limit" = 10
        );
        defer stmt.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("message:1", stmt.columnText(0));
        try std.testing.expectEqualStrings("message", stmt.columnText(1));
        try std.testing.expectEqualStrings("has_attachment", stmt.columnText(2));
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    {
        var stmt = try db.prepare(
            \\select node_id
            \\from zova_graph_neighbors
            \\where graph_name = 'default'
            \\  and source_node_id = 'message:1'
            \\  and "limit" = 0
        );
        defer stmt.deinit();
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }
}

test "sql graph walk returns bounded traversal rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-sql-walk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try seedGraphSqlFixture(&db);
    try db.putGraphEdge(.{ .from_node_id = "entity:zova", .edge_type = "related_to", .to_node_id = "message:1" });

    {
        var stmt = try db.prepare(
            \\select rank, node_id, kind, depth, predecessor_node_id, edge_type
            \\from zova_graph_walk
            \\where graph_name = 'default'
            \\  and start_node_id = 'message:1'
            \\  and max_depth = 2
            \\  and "limit" = 10
            \\order by rank
        );
        defer stmt.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(0));
        try std.testing.expectEqualStrings("message:1", stmt.columnText(1));
        try std.testing.expectEqualStrings("message", stmt.columnText(2));
        try std.testing.expectEqual(@as(i64, 0), stmt.columnInt64(3));
        try std.testing.expectEqual(sqlite.ColumnType.null, stmt.columnType(4));
        try std.testing.expectEqual(sqlite.ColumnType.null, stmt.columnType(5));

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqual(@as(i64, 2), stmt.columnInt64(0));
        try std.testing.expectEqualStrings("message:2", stmt.columnText(1));
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(3));
        try std.testing.expectEqualStrings("message:1", stmt.columnText(4));
        try std.testing.expectEqualStrings("replies_to", stmt.columnText(5));
    }

    {
        var stmt = try db.prepare(
            \\select node_id, depth, predecessor_node_id, edge_type
            \\from zova_graph_walk
            \\where graph_name = 'default'
            \\  and start_node_id = 'message:1'
            \\  and edge_type_filter = 'mentions'
            \\  and max_depth = 2
            \\  and "limit" = 50
            \\order by rank
        );
        defer stmt.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("message:1", stmt.columnText(0));
        try std.testing.expectEqual(@as(i64, 0), stmt.columnInt64(1));

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("entity:zova", stmt.columnText(0));
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(1));
        try std.testing.expectEqualStrings("message:1", stmt.columnText(2));
        try std.testing.expectEqualStrings("mentions", stmt.columnText(3));
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }
}

test "sql graph integration validates errors and registers only on zova connections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-sql-validation.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();

        try seedGraphSqlFixture(&db);

        try expectSqlPrepareOrStepError(&db,
            \\select *
            \\from zova_graph_neighbors
        );
        try expectSqlPrepareOrStepError(&db,
            \\select *
            \\from zova_graph_neighbors
            \\where graph_name = 'default'
            \\  and source_node_id = 'message:1'
            \\  and direction = 'sideways'
        );
        try expectSqlPrepareOrStepError(&db,
            \\select *
            \\from zova_graph_neighbors
            \\where graph_name = 'default'
            \\  and source_node_id = 'missing'
        );
        try expectSqlPrepareOrStepError(&db,
            \\select *
            \\from zova_graph_walk
            \\where graph_name = 'default'
            \\  and start_node_id = 'message:1'
        );
        try expectSqlPrepareOrStepError(&db,
            \\select *
            \\from zova_graph_walk
            \\where graph_name = 'default'
            \\  and start_node_id = 'message:1'
            \\  and max_depth = -1
        );
        try expectSqlPrepareOrStepError(&db,
            \\insert into zova_graph_neighbors (rank, node_id, kind, edge_type)
            \\values (1, 'x', 'kind', 'edge')
        );
    }

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try std.testing.expectError(error.SqliteError, raw.prepare(
            \\select *
            \\from zova_graph_neighbors
            \\where graph_name = 'default'
            \\  and source_node_id = 'message:1'
        ));
    }

    {
        var readonly = try Database.openWithOptions(db_path, .{ .read_only = true });
        defer readonly.deinit();

        var stmt = try readonly.prepare(
            \\select node_id
            \\from zova_graph_neighbors
            \\where graph_name = 'default'
            \\  and source_node_id = 'message:1'
            \\  and "limit" = 1
        );
        defer stmt.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("message:2", stmt.columnText(0));
    }
}

fn seedGraphSqlFixture(db: *Database) !void {
    try db.exec(
        \\create table messages (
        \\  id text primary key,
        \\  graph_node_id text not null unique,
        \\  body text not null
        \\);
    );
    try db.exec(
        \\insert into messages (id, graph_node_id, body) values
        \\  ('m1', 'message:1', 'first message'),
        \\  ('m2', 'message:2', 'second message'),
        \\  ('a1', 'attachment:1', 'attachment metadata'),
        \\  ('e1', 'entity:zova', 'entity metadata');
    );
    try db.createGraph(default_graph_name);
    try db.putGraphNode(.{ .node_id = "message:1", .kind = "message", .target_type = .record, .target_namespace = "messages", .target_ref = "m1" });
    try db.putGraphNode(.{ .node_id = "message:2", .kind = "message", .target_type = .record, .target_namespace = "messages", .target_ref = "m2" });
    try db.putGraphNode(.{ .node_id = "attachment:1", .kind = "attachment", .target_type = .record, .target_namespace = "messages", .target_ref = "a1" });
    try db.putGraphNode(.{ .node_id = "entity:zova", .kind = "entity", .target_type = .entity, .target_ref = "zova" });
    try db.putGraphEdge(.{ .from_node_id = "message:1", .edge_type = "replies_to", .to_node_id = "message:2" });
    try db.putGraphEdge(.{ .from_node_id = "message:1", .edge_type = "has_attachment", .to_node_id = "attachment:1" });
    try db.putGraphEdge(.{ .from_node_id = "message:1", .edge_type = "mentions", .to_node_id = "entity:zova" });
}
