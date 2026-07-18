const std = @import("std");
const root = @import("root.zig");

const zova = @import("zova.zig");
const graph = @import("graph.zig");
const sqlite = @import("sqlite.zig");
const test_support = @import("zova_test_support.zig");

const testingDbPath = test_support.testingDbPath;

fn lowerHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[@intCast(byte >> 4)];
        out[index * 2 + 1] = digits[@intCast(byte & 0x0f)];
    }
    return out;
}

fn schemaIndexExists(db: *sqlite.Database, index_name: []const u8) !bool {
    var stmt = try db.prepare("select count(*) from sqlite_master where type = 'index' and name = ?");
    defer stmt.deinit();
    try stmt.bindText(1, index_name);
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    return stmt.columnInt64(0) == 1;
}

fn expectQueryPlanUsesIndex(db: *sqlite.Database, sql: [:0]const u8, index_name: []const u8) !void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var saw_index = false;
    while (try stmt.step() == .row) {
        const detail = stmt.columnText(3);
        try std.testing.expect(std.mem.indexOf(u8, detail, "USE TEMP B-TREE FOR ORDER BY") == null);
        if (std.mem.indexOf(u8, detail, index_name) != null) saw_index = true;
    }
    try std.testing.expect(saw_index);
}

const ExpectedColumn = struct {
    name: []const u8,
    kind: []const u8,
    not_null: i64,
    primary_key: i64,
};

fn expectTableColumns(db: *sqlite.Database, table_name: []const u8, expected: []const ExpectedColumn) !void {
    var stmt = try db.prepare(
        "select name,type,\"notnull\",pk from pragma_table_info(?) order by cid",
    );
    defer stmt.deinit();
    try stmt.bindText(1, table_name);
    for (expected) |column| {
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings(column.name, stmt.columnText(0));
        try std.testing.expectEqualStrings(column.kind, stmt.columnText(1));
        try std.testing.expectEqual(column.not_null, stmt.columnInt64(2));
        try std.testing.expectEqual(column.primary_key, stmt.columnInt64(3));
    }
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

const GraphTraceCounter = struct {
    graph_endpoint_stage_steps: usize = 0,
    graph_endpoint_resolution_statements: usize = 0,
    graph_edge_insert_steps: usize = 0,
    resolver_seen: bool = false,
    slot_resolver_seen: bool = false,
    node_key_preload_statements: usize = 0,
    edge_key_preload_statements: usize = 0,
    keyed_returning_statements: usize = 0,
};

fn graphTraceCallback(mask: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    if (mask != sqlite.c.SQLITE_TRACE_STMT or context == null or statement == null) return 0;
    const stmt: *sqlite.c.sqlite3_stmt = @ptrCast(@alignCast(statement.?));
    const sql_ptr = sqlite.c.sqlite3_sql(stmt) orelse return 0;
    const sql = std.mem.span(sql_ptr);
    const counter: *GraphTraceCounter = @ptrCast(@alignCast(context.?));
    if (std.mem.indexOf(u8, sql, "returning node_key") != null or
        std.mem.indexOf(u8, sql, "returning edge_key") != null)
    {
        counter.keyed_returning_statements += 1;
    } else if (std.mem.indexOf(u8, sql, "zova_graph_node_key_preload") != null) {
        counter.node_key_preload_statements += 1;
    } else if (std.mem.indexOf(u8, sql, "zova_graph_edge_key_preload") != null) {
        counter.edge_key_preload_statements += 1;
    } else if (std.mem.indexOf(u8, sql, "zova_graph_endpoint_stage") != null or
        std.mem.indexOf(u8, sql, "insert or ignore into temp._zova_graph_batch_endpoints") != null)
    {
        counter.graph_endpoint_stage_steps += 1;
    } else if (std.mem.indexOf(u8, sql, "zova_graph_batch_slot_resolve") != null) {
        counter.slot_resolver_seen = true;
        if (!counter.resolver_seen) {
            counter.resolver_seen = true;
            counter.graph_endpoint_resolution_statements += 1;
        }
    } else if (std.mem.indexOf(u8, sql, "zova_graph_batch_resolve") != null) {
        if (!counter.resolver_seen) {
            counter.resolver_seen = true;
            counter.graph_endpoint_resolution_statements += 1;
        }
    } else if (std.mem.indexOf(u8, sql, "zova_graph_edge_insert") != null or
        std.mem.indexOf(u8, sql, "insert into main._zova_graph_edges") != null)
    {
        counter.graph_edge_insert_steps += 1;
    }
    return 0;
}

test "graph v8 schema uses integer private keys and retains public target fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-v8-schema.zova");
    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try expectTableColumns(&db.sqlite_db, "_zova_graphs", &.{
        .{ .name = "graph_key", .kind = "INTEGER", .not_null = 0, .primary_key = 1 },
        .{ .name = "name", .kind = "TEXT", .not_null = 1, .primary_key = 0 },
        .{ .name = "created_order", .kind = "INTEGER", .not_null = 1, .primary_key = 0 },
    });
    try expectTableColumns(&db.sqlite_db, "_zova_graph_nodes", &.{
        .{ .name = "node_key", .kind = "INTEGER", .not_null = 0, .primary_key = 1 },
        .{ .name = "graph_key", .kind = "INTEGER", .not_null = 1, .primary_key = 0 },
        .{ .name = "node_id", .kind = "TEXT", .not_null = 1, .primary_key = 0 },
        .{ .name = "kind", .kind = "TEXT", .not_null = 1, .primary_key = 0 },
        .{ .name = "target_type", .kind = "TEXT", .not_null = 1, .primary_key = 0 },
        .{ .name = "target_namespace", .kind = "TEXT", .not_null = 0, .primary_key = 0 },
        .{ .name = "target_ref", .kind = "TEXT", .not_null = 0, .primary_key = 0 },
        .{ .name = "created_order", .kind = "INTEGER", .not_null = 1, .primary_key = 0 },
    });
    try expectTableColumns(&db.sqlite_db, "_zova_graph_edges", &.{
        .{ .name = "edge_key", .kind = "INTEGER", .not_null = 0, .primary_key = 1 },
        .{ .name = "graph_key", .kind = "INTEGER", .not_null = 1, .primary_key = 0 },
        .{ .name = "from_node_key", .kind = "INTEGER", .not_null = 1, .primary_key = 0 },
        .{ .name = "edge_type", .kind = "TEXT", .not_null = 1, .primary_key = 0 },
        .{ .name = "to_node_key", .kind = "INTEGER", .not_null = 1, .primary_key = 0 },
        .{ .name = "created_order", .kind = "INTEGER", .not_null = 1, .primary_key = 0 },
    });

    const expected_indexes = [_][]const u8{
        "_zova_graph_nodes_created_order_idx",
        "_zova_graph_edges_created_order_idx",
        "_zova_graph_edges_from_node_idx",
        "_zova_graph_edges_from_node_type_idx",
        "_zova_graph_edges_to_node_idx",
        "_zova_graph_edges_to_node_type_idx",
    };
    for (expected_indexes) |index_name| try std.testing.expect(try schemaIndexExists(&db.sqlite_db, index_name));

    var foreign_keys = try db.prepare("pragma foreign_keys");
    defer foreign_keys.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try foreign_keys.step());
    try std.testing.expectEqual(@as(i64, 1), foreign_keys.columnInt64(0));

    var endpoint_foreign_keys = try db.prepare(
        \\select count(*)
        \\from pragma_foreign_key_list('_zova_graph_edges')
        \\where "table" = '_zova_graph_nodes'
        \\  and "from" in ('graph_key', 'from_node_key', 'to_node_key')
        \\  and "to" in ('graph_key', 'node_key')
        \\  and on_delete = 'CASCADE'
    );
    defer endpoint_foreign_keys.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try endpoint_foreign_keys.step());
    try std.testing.expectEqual(@as(i64, 4), endpoint_foreign_keys.columnInt64(0));
}

test "graph v8 composite foreign keys reject cross graph edges and cascade" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-v8-foreign-keys.zova");
    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try db.createGraph("left");
    try db.createGraph("right");
    try db.putGraphNodes(&.{
        .{ .graph_name = "left", .node_id = "a", .kind = "test" },
        .{ .graph_name = "left", .node_id = "b", .kind = "test" },
        .{ .graph_name = "right", .node_id = "a", .kind = "test" },
    });

    try std.testing.expectError(error.Constraint, db.exec(
        \\insert into _zova_graph_edges (graph_key, from_node_key, edge_type, to_node_key, created_order)
        \\select left_graph.graph_key, left_node.node_key, 'crosses', right_node.node_key, 1
        \\from _zova_graphs left_graph
        \\join _zova_graph_nodes left_node on left_node.graph_key = left_graph.graph_key and left_node.node_id = 'a'
        \\join _zova_graphs right_graph on right_graph.name = 'right'
        \\join _zova_graph_nodes right_node on right_node.graph_key = right_graph.graph_key and right_node.node_id = 'a'
        \\where left_graph.name = 'left'
    ));

    try db.putGraphEdge(.{ .graph_name = "left", .from_node_id = "a", .edge_type = "links", .to_node_id = "b" });
    try db.exec("delete from _zova_graph_nodes where graph_key=(select graph_key from _zova_graphs where name='left') and node_id='b'");
    try std.testing.expectEqual(@as(i64, 0), try test_support.testingCount(&db, "select count(*) from _zova_graph_edges"));
    try db.exec("delete from _zova_graphs where name='left'");
    try std.testing.expectEqual(@as(i64, 0), try test_support.testingCount(&db, "select count(*) from _zova_graph_nodes n join _zova_graphs g on g.graph_key=n.graph_key where g.name='left'"));
}

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

test "directional graph walk preserves incoming BFS order and shortest hops" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-directional-walk.zova");
    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("app");
    try db.putGraphNodes(&.{
        .{ .graph_name = "app", .node_id = "a", .kind = "function" },
        .{ .graph_name = "app", .node_id = "b", .kind = "function" },
        .{ .graph_name = "app", .node_id = "c", .kind = "function" },
        .{ .graph_name = "app", .node_id = "d", .kind = "function" },
    });
    try db.putGraphEdges(&.{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "c" },
        .{ .graph_name = "app", .from_node_id = "b", .edge_type = "calls", .to_node_id = "c" },
        .{ .graph_name = "app", .from_node_id = "d", .edge_type = "calls", .to_node_id = "a" },
        .{ .graph_name = "app", .from_node_id = "d", .edge_type = "calls", .to_node_id = "b" },
        // This closes c -> d -> a -> c. The walk must not re-emit c when
        // it reaches d at depth 2 and follows the cycle at depth 3.
        .{ .graph_name = "app", .from_node_id = "c", .edge_type = "calls", .to_node_id = "d" },
    });

    var incoming = try db.graphWalkDirection(std.testing.allocator, .{
        .graph_name = "app",
        .start_node_id = "c",
        .direction = .incoming,
        .edge_type = "calls",
        .max_depth = 3,
        .limit = 4,
    });
    defer incoming.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), incoming.items.len);
    try std.testing.expectEqualStrings("c", incoming.items[0].node_id);
    try std.testing.expectEqualStrings("a", incoming.items[1].node_id);
    try std.testing.expectEqualStrings("b", incoming.items[2].node_id);
    try std.testing.expectEqualStrings("d", incoming.items[3].node_id);
    try std.testing.expectEqual(@as(u32, 2), incoming.items[3].depth);
    try std.testing.expectEqualStrings("a", incoming.items[3].predecessor_node_id.?);

    var limited = try db.graphWalkDirection(std.testing.allocator, .{
        .graph_name = "app",
        .start_node_id = "c",
        .direction = .incoming,
        .max_depth = 2,
        .limit = 2,
    });
    defer limited.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), limited.items.len);
}

test "native graph database routes persistent queries to attached graph store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-schema-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-schema-store.zova");

    var main = try zova.Database.create(main_path);
    main.deinit();
    try zova.createGraphStore(store_path);

    var raw = try sqlite.Database.open(main_path);
    defer raw.deinit();
    try raw.exec("pragma foreign_keys = on");
    try raw.attachDatabase(store_path, "graph_store");
    try raw.exec(
        \\drop index main._zova_graph_nodes_created_order_idx;
        \\drop index graph_store._zova_graph_nodes_created_order_idx;
    );

    var graphs = graph.Database{
        .sqlite_db = &raw,
        .storage_schema = .graph_store,
    };
    try graphs.createGraph("external");
    var external_node_keys: [2]i64 = undefined;
    try graphs.putGraphNodesKeyed(&.{
        .{ .graph_name = "external", .node_id = "a", .kind = "test" },
        .{ .graph_name = "external", .node_id = "b", .kind = "test" },
    }, &external_node_keys);

    var indexes = try raw.prepare(
        \\select
        \\  (select count(*) from main.sqlite_master where type = 'index' and name = '_zova_graph_nodes_created_order_idx'),
        \\  (select count(*) from graph_store.sqlite_master where type = 'index' and name = '_zova_graph_nodes_created_order_idx')
    );
    defer indexes.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try indexes.step());
    try std.testing.expectEqual(@as(i64, 0), indexes.columnInt64(0));
    try std.testing.expectEqual(@as(i64, 1), indexes.columnInt64(1));

    var external_edge_keys: [1]i64 = undefined;
    try graphs.putGraphEdgesKeyed(&.{.{
        .graph_name = "external",
        .from_node_id = "a",
        .edge_type = "links",
        .to_node_id = "b",
    }}, &external_edge_keys);
    var external_scan = try graphs.graphScan(std.testing.allocator, .{
        .graph_name = "external",
        .node_limit = 10,
        .edge_limit = 10,
    });
    defer external_scan.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(i64, &external_node_keys, &.{ external_scan.nodes[0].node_key, external_scan.nodes[1].node_key });
    try std.testing.expectEqual(external_edge_keys[0], external_scan.edges[0].edge_key);
    var external_nodes = try graphs.graphNodesGetManyKeyed(std.testing.allocator, "external", &external_node_keys);
    defer external_nodes.deinit(std.testing.allocator);
    try std.testing.expect(external_nodes.items[0].found and external_nodes.items[1].found);
    var external_edges = try graphs.graphEdgesGetManyKeyed(std.testing.allocator, "external", &external_edge_keys);
    defer external_edges.deinit(std.testing.allocator);
    try std.testing.expect(external_edges.items[0].found);

    var counts = try raw.prepare(
        \\select
        \\  (select count(*) from main._zova_graphs),
        \\  (select count(*) from main._zova_graph_nodes),
        \\  (select count(*) from main._zova_graph_edges),
        \\  (select count(*) from graph_store._zova_graphs),
        \\  (select count(*) from graph_store._zova_graph_nodes),
        \\  (select count(*) from graph_store._zova_graph_edges)
    );
    defer counts.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try counts.step());
    try std.testing.expectEqual(@as(i64, 0), counts.columnInt64(0));
    try std.testing.expectEqual(@as(i64, 0), counts.columnInt64(1));
    try std.testing.expectEqual(@as(i64, 0), counts.columnInt64(2));
    try std.testing.expectEqual(@as(i64, 1), counts.columnInt64(3));
    try std.testing.expectEqual(@as(i64, 2), counts.columnInt64(4));
    try std.testing.expectEqual(@as(i64, 1), counts.columnInt64(5));

    var walk = try graphs.graphWalkDirection(std.testing.allocator, .{
        .graph_name = "external",
        .start_node_id = "a",
        .direction = .outgoing,
        .max_depth = 2,
        .limit = 10,
    });
    defer walk.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), walk.items.len);
    try std.testing.expectEqualStrings("a", walk.items[0].node_id);
    try std.testing.expectEqualStrings("b", walk.items[1].node_id);
    try std.testing.expectEqual(@as(u32, 1), walk.items[1].depth);
    try std.testing.expectEqualStrings("a", walk.items[1].predecessor_node_id.?);
    try std.testing.expectEqualStrings("links", walk.items[1].edge_type.?);

    try graphs.deleteGraphNodes("external", &.{"b"});
    var deleted_counts = try raw.prepare(
        \\select
        \\  (select count(*) from graph_store._zova_graph_nodes),
        \\  (select count(*) from graph_store._zova_graph_edges)
    );
    defer deleted_counts.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try deleted_counts.step());
    try std.testing.expectEqual(@as(i64, 1), deleted_counts.columnInt64(0));
    try std.testing.expectEqual(@as(i64, 0), deleted_counts.columnInt64(1));
}

test "graph batches are atomic delete incident edges and report filtered degree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-batches.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("app");

    const nodes = [_]zova.GraphNodeInput{
        .{ .graph_name = "app", .node_id = "a", .kind = "function" },
        .{ .graph_name = "app", .node_id = "b", .kind = "function" },
        .{ .graph_name = "app", .node_id = "c", .kind = "function" },
    };
    try db.putGraphNodes(&nodes);

    const edges = [_]zova.GraphEdgeInput{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "imports", .to_node_id = "c" },
    };
    try db.putGraphEdges(&edges);

    try std.testing.expectEqual(@as(u64, 2), try db.graphDegree(.{ .graph_name = "app", .node_id = "a", .direction = .outgoing }));
    try std.testing.expectEqual(@as(u64, 1), try db.graphDegree(.{ .graph_name = "app", .node_id = "a", .direction = .outgoing, .edge_type = "calls" }));
    try std.testing.expectEqual(@as(u64, 1), try db.graphDegree(.{ .graph_name = "app", .node_id = "b", .direction = .incoming }));

    const invalid_edges = [_]zova.GraphEdgeInput{
        .{ .graph_name = "app", .from_node_id = "c", .edge_type = "calls", .to_node_id = "a" },
        .{ .graph_name = "app", .from_node_id = "c", .edge_type = "calls", .to_node_id = "missing" },
    };
    try std.testing.expectError(error.GraphNodeNotFound, db.putGraphEdges(&invalid_edges));
    try std.testing.expect(!try db.hasGraphEdge("app", "c", "calls", "a"));

    try db.deleteGraphNodes("app", &.{ "b", "missing" });
    try std.testing.expect(!try db.hasGraphNode("app", "b"));
    try std.testing.expect(!try db.hasGraphEdge("app", "a", "calls", "b"));
    try std.testing.expectEqual(@as(u64, 1), try db.graphDegree(.{ .graph_name = "app", .node_id = "a", .direction = .outgoing }));

    try db.beginImmediate();
    try db.putGraphNodes(&.{.{ .graph_name = "app", .node_id = "rolled-back", .kind = "function" }});
    try db.rollback();
    try std.testing.expect(!try db.hasGraphNode("app", "rolled-back"));
    try std.testing.expectError(error.GraphNodeNotFound, db.graphDegree(.{ .graph_name = "app", .node_id = "missing", .direction = .outgoing }));
}

test "graph edge batches resolve each graph's repeated endpoints once before writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-batch-resolution.zova");
    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("app");
    try db.createGraph("other");
    try db.putGraphNodes(&.{
        .{ .graph_name = "app", .node_id = "a", .kind = "function" },
        .{ .graph_name = "app", .node_id = "b", .kind = "function" },
        .{ .graph_name = "app", .node_id = "c", .kind = "function" },
        .{ .graph_name = "other", .node_id = "a", .kind = "function" },
        .{ .graph_name = "other", .node_id = "b", .kind = "function" },
    });

    var counter: GraphTraceCounter = .{};
    try std.testing.expectEqual(@as(c_int, sqlite.c.SQLITE_OK), sqlite.c.sqlite3_trace_v2(
        db.sqlite_db.handle,
        sqlite.c.SQLITE_TRACE_STMT,
        graphTraceCallback,
        &counter,
    ));
    defer _ = sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);

    try db.putGraphEdges(&.{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "imports", .to_node_id = "c" },
        .{ .graph_name = "app", .from_node_id = "b", .edge_type = "calls", .to_node_id = "c" },
        .{ .graph_name = "other", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
    });
    try std.testing.expectEqual(@as(usize, 5), counter.graph_endpoint_stage_steps);
    try std.testing.expectEqual(@as(usize, 1), counter.graph_endpoint_resolution_statements);
    try std.testing.expectEqual(@as(usize, 5), counter.graph_edge_insert_steps);
    try std.testing.expect(counter.slot_resolver_seen);
    try std.testing.expect(try db.hasGraphEdge("other", "a", "calls", "b"));

    var legacy_resolved_table = try db.sqlite_db.prepare(
        "select count(*) from sqlite_temp_master where type = 'table' and name = '_zova_graph_batch_resolved'",
    );
    defer legacy_resolved_table.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try legacy_resolved_table.step());
    try std.testing.expectEqual(@as(i64, 0), legacy_resolved_table.columnInt64(0));

    var order = try db.sqlite_db.prepare(
        \\select e.edge_type
        \\from _zova_graph_edges e
        \\join _zova_graphs g on g.graph_key = e.graph_key
        \\where g.name = 'app'
        \\order by e.created_order, e.edge_key
    );
    defer order.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try order.step());
    try std.testing.expectEqualStrings("calls", order.columnText(0));
    try std.testing.expectEqual(sqlite.Step.row, try order.step());
    try std.testing.expectEqualStrings("imports", order.columnText(0));
    try std.testing.expectEqual(sqlite.Step.row, try order.step());
    try std.testing.expectEqualStrings("calls", order.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try order.step());

    const before = try db.graphInfo(std.testing.allocator, "app");
    defer {
        var owned = before;
        owned.deinit(std.testing.allocator);
    }
    counter = .{};
    try std.testing.expectError(error.GraphNodeNotFound, db.putGraphEdges(&.{
        .{ .graph_name = "app", .from_node_id = "c", .edge_type = "calls", .to_node_id = "a" },
        .{ .graph_name = "app", .from_node_id = "missing", .edge_type = "calls", .to_node_id = "a" },
    }));
    var staged_after_error = try db.sqlite_db.prepare(
        "select count(*) from temp._zova_graph_put_batch_endpoints",
    );
    defer staged_after_error.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try staged_after_error.step());
    try std.testing.expectEqual(@as(i64, 0), staged_after_error.columnInt64(0));
    try std.testing.expectEqual(@as(usize, 3), counter.graph_endpoint_stage_steps);
    try std.testing.expectEqual(@as(usize, 1), counter.graph_endpoint_resolution_statements);
    try std.testing.expectEqual(@as(usize, 0), counter.graph_edge_insert_steps);
    var after = try db.graphInfo(std.testing.allocator, "app");
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(before.edge_count, after.edge_count);

    counter = .{};
    try db.begin();
    try db.putGraphEdges(&.{.{ .graph_name = "app", .from_node_id = "c", .edge_type = "calls", .to_node_id = "a" }});
    try std.testing.expect(try db.hasGraphEdge("app", "c", "calls", "a"));
    try db.rollback();
    try std.testing.expect(!try db.hasGraphEdge("app", "c", "calls", "a"));
    try std.testing.expectEqual(@as(usize, 2), counter.graph_endpoint_stage_steps);
    try std.testing.expectEqual(@as(usize, 1), counter.graph_endpoint_resolution_statements);
    try std.testing.expectEqual(@as(usize, 1), counter.graph_edge_insert_steps);
}

test "graph batches ensure query indexes for direct ingestion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-batch-indexes.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_nodes_created_order_idx"));
    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_edges_created_order_idx"));
    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_edges_from_node_idx"));
    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_edges_from_node_type_idx"));
    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_edges_to_node_idx"));
    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_edges_to_node_type_idx"));

    try db.sqlite_db.exec("drop index _zova_graph_nodes_created_order_idx");
    try db.sqlite_db.exec("drop index _zova_graph_edges_created_order_idx");
    try db.sqlite_db.exec("drop index _zova_graph_edges_from_node_idx");
    try db.sqlite_db.exec("drop index _zova_graph_edges_from_node_type_idx");
    try db.sqlite_db.exec("drop index _zova_graph_edges_to_node_idx");
    try db.sqlite_db.exec("drop index _zova_graph_edges_to_node_type_idx");
    try db.createGraph("app");
    try db.putGraphNodes(&.{.{ .graph_name = "app", .node_id = "a", .kind = "function" }});

    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_nodes_created_order_idx"));
    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_edges_created_order_idx"));
    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_edges_from_node_idx"));
    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_edges_from_node_type_idx"));
    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_edges_to_node_idx"));
    try std.testing.expect(try schemaIndexExists(&db.sqlite_db, "_zova_graph_edges_to_node_type_idx"));
}

test "keyed graph batches return stable aligned node and edge keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-keyed-batches.zova");
    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("app");
    try db.createGraph("other");

    var node_keys: [4]i64 = undefined;
    try db.putGraphNodesKeyed(&.{
        .{ .graph_name = "app", .node_id = "a", .kind = "first" },
        .{ .graph_name = "app", .node_id = "b", .kind = "function" },
        .{ .graph_name = "app", .node_id = "a", .kind = "updated" },
        .{ .graph_name = "other", .node_id = "a", .kind = "function" },
    }, &node_keys);
    try std.testing.expect(node_keys[0] > 0);
    try std.testing.expectEqual(node_keys[0], node_keys[2]);
    try std.testing.expect(node_keys[0] != node_keys[1]);
    try std.testing.expect(node_keys[0] != node_keys[3]);
    var updated = try db.getGraphNode(std.testing.allocator, "app", "a");
    defer updated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("updated", updated.kind);

    try db.putGraphEdge(.{ .graph_name = "app", .from_node_id = "b", .edge_type = "existing", .to_node_id = "a" });
    var edge_keys: [5]i64 = undefined;
    try db.putGraphEdgesKeyed(&.{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "b", .edge_type = "existing", .to_node_id = "a" },
        .{ .graph_name = "other", .from_node_id = "a", .edge_type = "self", .to_node_id = "a" },
        .{ .graph_name = "app", .from_node_id = "b", .edge_type = "calls", .to_node_id = "a" },
    }, &edge_keys);
    try std.testing.expect(edge_keys[0] > 0);
    try std.testing.expectEqual(edge_keys[0], edge_keys[1]);
    try std.testing.expect(edge_keys[0] != edge_keys[2]);
    try std.testing.expect(edge_keys[0] != edge_keys[3]);
    try std.testing.expect(edge_keys[0] != edge_keys[4]);

    try db.begin();
    var rolled_back_key: [1]i64 = undefined;
    try db.putGraphNodesKeyed(&.{.{ .graph_name = "app", .node_id = "rolled-back", .kind = "function" }}, &rolled_back_key);
    try std.testing.expect(rolled_back_key[0] > 0);
    try db.rollback();
    try std.testing.expect(!try db.hasGraphNode("app", "rolled-back"));
}

test "keyed graph batches preload keys and retain the fast non-returning inserts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-keyed-fast-insert.zova");
    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("app");
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "a", .kind = "existing" });

    var counter: GraphTraceCounter = .{};
    _ = sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, sqlite.c.SQLITE_TRACE_STMT, graphTraceCallback, &counter);
    defer _ = sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);
    var node_keys: [3]i64 = undefined;
    try db.putGraphNodesKeyed(&.{
        .{ .graph_name = "app", .node_id = "a", .kind = "updated" },
        .{ .graph_name = "app", .node_id = "b", .kind = "new" },
        .{ .graph_name = "app", .node_id = "b", .kind = "final" },
    }, &node_keys);
    var edge_keys: [2]i64 = undefined;
    try db.putGraphEdgesKeyed(&.{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
    }, &edge_keys);
    var replay_edge_keys: [2]i64 = undefined;
    try db.putGraphEdgesKeyed(&.{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
    }, &replay_edge_keys);

    try std.testing.expectEqual(@as(usize, 1), counter.node_key_preload_statements);
    try std.testing.expectEqual(@as(usize, 2), counter.edge_key_preload_statements);
    try std.testing.expectEqual(@as(usize, 0), counter.keyed_returning_statements);
    try std.testing.expectEqual(@as(usize, 1), counter.graph_edge_insert_steps);
    try std.testing.expectEqual(node_keys[1], node_keys[2]);
    try std.testing.expectEqual(edge_keys[0], edge_keys[1]);
    try std.testing.expectEqualSlices(i64, &edge_keys, &replay_edge_keys);
}

test "keyed graph reads preserve order degree alignment and exclusive scan cursors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-keyed-reads.zova");
    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("app");

    var node_keys: [3]i64 = undefined;
    try db.putGraphNodesKeyed(&.{
        .{ .graph_name = "app", .node_id = "root", .kind = "root" },
        .{ .graph_name = "app", .node_id = "zeta", .kind = "leaf" },
        .{ .graph_name = "app", .node_id = "alpha", .kind = "leaf" },
    }, &node_keys);
    var edge_keys: [2]i64 = undefined;
    try db.putGraphEdgesKeyed(&.{
        .{ .graph_name = "app", .from_node_id = "root", .edge_type = "calls", .to_node_id = "zeta" },
        .{ .graph_name = "app", .from_node_id = "root", .edge_type = "calls", .to_node_id = "alpha" },
    }, &edge_keys);
    try db.exec("update _zova_graph_edges set created_order=1");

    var neighbors = try db.graphNeighborsKeyed(std.testing.allocator, .{
        .graph_name = "app",
        .node_id = "root",
        .direction = .outgoing,
        .limit = 10,
    });
    defer neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), neighbors.items.len);
    try std.testing.expectEqualStrings("alpha", neighbors.items[0].node_id);
    try std.testing.expectEqual(node_keys[2], neighbors.items[0].neighbor_node_key);
    try std.testing.expectEqual(edge_keys[1], neighbors.items[0].edge_key);
    try std.testing.expectEqualStrings("zeta", neighbors.items[1].node_id);

    var degrees: [3]u64 = undefined;
    try db.graphDegreeManyKeyed("app", &.{ node_keys[0], node_keys[2], node_keys[0] }, .outgoing, "calls", &degrees);
    try std.testing.expectEqualSlices(u64, &.{ 2, 0, 2 }, &degrees);

    var first = try db.graphScan(std.testing.allocator, .{
        .graph_name = "app",
        .node_limit = 2,
        .edge_limit = 1,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), first.nodes.len);
    try std.testing.expect(first.has_more_nodes);
    try std.testing.expectEqual(@as(usize, 1), first.edges.len);
    try std.testing.expect(first.has_more_edges);

    const node_cursor = zova.GraphScanCursor{
        .created_order = first.nodes[1].created_order,
        .key = first.nodes[1].node_key,
    };
    const edge_cursor = zova.GraphScanCursor{
        .created_order = first.edges[0].created_order,
        .key = first.edges[0].edge_key,
    };
    var second = try db.graphScan(std.testing.allocator, .{
        .graph_name = "app",
        .node_after = node_cursor,
        .edge_after = edge_cursor,
        .node_limit = 2,
        .edge_limit = 2,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), second.nodes.len);
    try std.testing.expect(!second.has_more_nodes);
    try std.testing.expectEqual(@as(usize, 1), second.edges.len);
    try std.testing.expect(!second.has_more_edges);
    try std.testing.expect(second.nodes[0].node_key != first.nodes[1].node_key);
    try std.testing.expect(second.edges[0].edge_key != first.edges[0].edge_key);
}

test "keyed graph mutation savepoint rolls back only its own partial work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-keyed-savepoint.zova");
    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("app");
    try db.exec(
        \\create temp trigger reject_keyed_node before insert on _zova_graph_nodes
        \\when new.node_id='reject'
        \\begin select raise(abort, 'forced keyed failure'); end
    );

    try db.begin();
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "caller-work", .kind = "function" });
    var keys: [2]i64 = undefined;
    try std.testing.expectError(error.Constraint, db.putGraphNodesKeyed(&.{
        .{ .graph_name = "app", .node_id = "partial", .kind = "function" },
        .{ .graph_name = "app", .node_id = "reject", .kind = "function" },
    }, &keys));
    try std.testing.expect(try db.hasGraphNode("app", "caller-work"));
    try std.testing.expect(!try db.hasGraphNode("app", "partial"));
    try std.testing.expect(!try db.hasGraphNode("app", "reject"));
    try db.commit();
    try std.testing.expect(try db.hasGraphNode("app", "caller-work"));
}

test "keyed degree and scan reject invalid keys and cursors without partial output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-keyed-validation.zova");
    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("one");
    try db.createGraph("two");
    var keys: [2]i64 = undefined;
    try db.putGraphNodesKeyed(&.{
        .{ .graph_name = "one", .node_id = "one", .kind = "node" },
        .{ .graph_name = "two", .node_id = "two", .kind = "node" },
    }, &keys);

    var degrees = [_]u64{ 77, 88 };
    try std.testing.expectError(error.GraphNodeNotFound, db.graphDegreeManyKeyed("one", &keys, .outgoing, null, &degrees));
    try std.testing.expectEqualSlices(u64, &.{ 0, 88 }, &degrees);
    try std.testing.expectError(error.InvalidArgument, db.graphDegreeManyKeyed("one", &.{0}, .outgoing, null, degrees[0..1]));
    try db.graphDegreeManyKeyed("one", &.{}, .outgoing, null, &.{});
    try std.testing.expectError(error.GraphNotFound, db.graphDegreeManyKeyed("missing", &.{}, .outgoing, null, &.{}));

    try std.testing.expectError(error.InvalidArgument, db.graphScan(std.testing.allocator, .{
        .graph_name = "one",
        .node_after = .{ .created_order = 1, .key = 0 },
        .node_limit = 1,
    }));
    var disabled = try db.graphScan(std.testing.allocator, .{ .graph_name = "one" });
    defer disabled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), disabled.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), disabled.edges.len);
    try std.testing.expect(!disabled.has_more_nodes and !disabled.has_more_edges);
}

test "graph scan pages retain a caller transaction WAL snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-keyed-snapshot.zova");
    var reader = try zova.Database.create(db_path);
    defer reader.deinit();
    try reader.exec("pragma journal_mode=wal");
    try reader.createGraph("app");
    try reader.putGraphNodes(&.{
        .{ .graph_name = "app", .node_id = "root", .kind = "node" },
        .{ .graph_name = "app", .node_id = "a", .kind = "node" },
        .{ .graph_name = "app", .node_id = "b", .kind = "node" },
    });
    try reader.putGraphEdges(&.{
        .{ .graph_name = "app", .from_node_id = "root", .edge_type = "links", .to_node_id = "a" },
        .{ .graph_name = "app", .from_node_id = "root", .edge_type = "links", .to_node_id = "b" },
    });
    var writer = try zova.Database.open(db_path);
    defer writer.deinit();

    try reader.begin();
    var first = try reader.graphScan(std.testing.allocator, .{ .graph_name = "app", .node_limit = 1, .edge_limit = 1 });
    defer first.deinit(std.testing.allocator);
    const node_after = zova.GraphScanCursor{ .created_order = first.nodes[0].created_order, .key = first.nodes[0].node_key };
    const edge_after = zova.GraphScanCursor{ .created_order = first.edges[0].created_order, .key = first.edges[0].edge_key };

    var new_node_key: [1]i64 = undefined;
    try writer.putGraphNodesKeyed(&.{.{ .graph_name = "app", .node_id = "c", .kind = "node" }}, &new_node_key);
    var new_edge_key: [1]i64 = undefined;
    try writer.putGraphEdgesKeyed(&.{.{ .graph_name = "app", .from_node_id = "root", .edge_type = "links", .to_node_id = "c" }}, &new_edge_key);

    var stable = try reader.graphScan(std.testing.allocator, .{
        .graph_name = "app",
        .node_after = node_after,
        .edge_after = edge_after,
        .node_limit = 10,
        .edge_limit = 10,
    });
    defer stable.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), stable.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), stable.edges.len);
    for (stable.nodes) |node| try std.testing.expect(node.node_key != new_node_key[0]);
    for (stable.edges) |edge| try std.testing.expect(edge.edge_key != new_edge_key[0]);
    var stable_nodes = try reader.graphNodesGetManyKeyed(std.testing.allocator, "app", &new_node_key);
    defer stable_nodes.deinit(std.testing.allocator);
    try std.testing.expect(!stable_nodes.items[0].found);
    var stable_edges = try reader.graphEdgesGetManyKeyed(std.testing.allocator, "app", &new_edge_key);
    defer stable_edges.deinit(std.testing.allocator);
    try std.testing.expect(!stable_edges.items[0].found);
    try reader.commit();

    var visible_nodes = try reader.graphNodesGetManyKeyed(std.testing.allocator, "app", &new_node_key);
    defer visible_nodes.deinit(std.testing.allocator);
    try std.testing.expect(visible_nodes.items[0].found);
    var visible_edges = try reader.graphEdgesGetManyKeyed(std.testing.allocator, "app", &new_edge_key);
    defer visible_edges.deinit(std.testing.allocator);
    try std.testing.expect(visible_edges.items[0].found);

    var current = try reader.graphScan(std.testing.allocator, .{
        .graph_name = "app",
        .node_after = node_after,
        .edge_after = edge_after,
        .node_limit = 10,
        .edge_limit = 10,
    });
    defer current.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), current.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), current.edges.len);
}

test "graph adjacency indexes cover ordered neighbor queries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-adjacency-indexes.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try expectQueryPlanUsesIndex(&db.sqlite_db,
        \\explain query plan
        \\select n.node_id, n.kind, e.edge_type
        \\from _zova_graph_edges e
        \\join _zova_graph_nodes n on n.node_key=e.to_node_key
        \\where (e.graph_key,e.from_node_key)=(
        \\  select g.graph_key,current.node_key from _zova_graphs g
        \\  join _zova_graph_nodes current on current.graph_key=g.graph_key
        \\  where g.name='app' and current.node_id='a'
        \\)
        \\order by e.created_order, e.to_node_key
        \\limit 10
    , "_zova_graph_edges_from_node_idx");
    try expectQueryPlanUsesIndex(&db.sqlite_db,
        \\explain query plan
        \\select n.node_id, n.kind, e.edge_type
        \\from _zova_graph_edges e
        \\join _zova_graph_nodes n on n.node_key=e.to_node_key
        \\where (e.graph_key,e.from_node_key)=(
        \\  select g.graph_key,current.node_key from _zova_graphs g
        \\  join _zova_graph_nodes current on current.graph_key=g.graph_key
        \\  where g.name='app' and current.node_id='a'
        \\) and e.edge_type='calls'
        \\order by e.created_order, e.to_node_key
        \\limit 10
    , "_zova_graph_edges_from_node_type_idx");
    try expectQueryPlanUsesIndex(&db.sqlite_db,
        \\explain query plan
        \\select n.node_id, n.kind, e.edge_type
        \\from _zova_graph_edges e
        \\join _zova_graph_nodes n on n.node_key=e.from_node_key
        \\where (e.graph_key,e.to_node_key)=(
        \\  select g.graph_key,current.node_key from _zova_graphs g
        \\  join _zova_graph_nodes current on current.graph_key=g.graph_key
        \\  where g.name='app' and current.node_id='a'
        \\)
        \\order by e.created_order, e.from_node_key
        \\limit 10
    , "_zova_graph_edges_to_node_idx");
    try expectQueryPlanUsesIndex(&db.sqlite_db,
        \\explain query plan
        \\select n.node_id, n.kind, e.edge_type
        \\from _zova_graph_edges e
        \\join _zova_graph_nodes n on n.node_key=e.from_node_key
        \\where (e.graph_key,e.to_node_key)=(
        \\  select g.graph_key,current.node_key from _zova_graphs g
        \\  join _zova_graph_nodes current on current.graph_key=g.graph_key
        \\  where g.name='app' and current.node_id='a'
        \\) and e.edge_type='calls'
        \\order by e.created_order, e.from_node_key
        \\limit 10
    , "_zova_graph_edges_to_node_type_idx");
}

test "profiled directional graph walk reports traversal stages and counters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-walk-profile.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("app");
    try db.putGraphNodes(&.{
        .{ .graph_name = "app", .node_id = "start", .kind = "function" },
        .{ .graph_name = "app", .node_id = "calls-child", .kind = "function" },
        .{ .graph_name = "app", .node_id = "imports-child", .kind = "module" },
        .{ .graph_name = "app", .node_id = "leaf", .kind = "function" },
    });
    try db.putGraphEdges(&.{
        .{ .graph_name = "app", .from_node_id = "start", .edge_type = "calls", .to_node_id = "calls-child" },
        .{ .graph_name = "app", .from_node_id = "start", .edge_type = "imports", .to_node_id = "imports-child" },
        .{ .graph_name = "app", .from_node_id = "calls-child", .edge_type = "calls", .to_node_id = "leaf" },
    });

    var profile: graph.GraphWalkScanProfile = .{};
    var graph_db = graph.Database{ .sqlite_db = &db.sqlite_db };
    var walk = try graph_db.graphWalkDirectionProfiled(std.testing.allocator, .{
        .graph_name = "app",
        .start_node_id = "start",
        .direction = .outgoing,
        .edge_type = "calls",
        .max_depth = 2,
        .limit = 3,
    }, &profile);
    defer walk.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), walk.items.len);
    try std.testing.expectEqualStrings("start", walk.items[0].node_id);
    try std.testing.expectEqualStrings("calls-child", walk.items[1].node_id);
    try std.testing.expectEqualStrings("leaf", walk.items[2].node_id);
    try std.testing.expectEqualStrings("start", walk.items[1].predecessor_node_id.?);
    try std.testing.expectEqualStrings("calls", walk.items[1].edge_type.?);
    try std.testing.expectEqual(@as(u64, 1), profile.adjacency_statement_prepares);
    try std.testing.expectEqual(@as(u64, 2), profile.adjacency_query_binds);
    try std.testing.expectEqual(@as(u64, 2), profile.adjacency_rows_stepped);
    try std.testing.expectEqual(@as(u64, 2), profile.frontier_expansions);
    try std.testing.expectEqual(@as(u64, 3), profile.result_count);
    try std.testing.expect(profile.root_lookup_ms >= 0);
    try std.testing.expect(profile.adjacency_prepare_ms >= 0);
    try std.testing.expect(profile.adjacency_execute_ms >= 0);
    try std.testing.expect(profile.bfs_bookkeeping_allocation_ms >= 0);
}

test "graph target examples cover records objects chunks and vectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-target-examples.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try db.exec("create table records (id text primary key, title text not null)");
    try db.exec("insert into records (id, title) values ('rec-1', 'record target')");

    const object_id = try db.putObject("object target bytes");
    const object_ref = try lowerHexAlloc(std.testing.allocator, &object_id);
    defer std.testing.allocator.free(object_ref);

    const chunk_bytes = "chunk target bytes";
    const chunk_id = zova.objectChunkId(chunk_bytes);
    const chunk_ref = try lowerHexAlloc(std.testing.allocator, &chunk_id);
    defer std.testing.allocator.free(chunk_ref);
    try db.putObjectChunk(chunk_id, chunk_bytes);

    try db.createVectorCollection("embeddings", .{ .dimensions = 2, .metric = .l2, .element_type = .i8 });
    try db.putVector("embeddings", "rec-1", .{ .i8 = &.{ @as(i8, 3), @as(i8, -4) } });

    try db.createGraph("targets");
    try db.putGraphNode(.{
        .graph_name = "targets",
        .node_id = "record:rec-1",
        .kind = "record",
        .target_type = .record,
        .target_namespace = "records",
        .target_ref = "rec-1",
    });
    try db.putGraphNode(.{
        .graph_name = "targets",
        .node_id = "object:primary",
        .kind = "object",
        .target_type = .object,
        .target_ref = object_ref,
    });
    try db.putGraphNode(.{
        .graph_name = "targets",
        .node_id = "chunk:primary",
        .kind = "chunk",
        .target_type = .object_chunk,
        .target_ref = chunk_ref,
    });
    try db.putGraphNode(.{
        .graph_name = "targets",
        .node_id = "vector:rec-1",
        .kind = "embedding",
        .target_type = .vector,
        .target_namespace = "embeddings",
        .target_ref = "rec-1",
    });

    const expected = [_]struct {
        node_id: []const u8,
        target_type: zova.GraphTargetType,
        target_namespace: ?[]const u8,
        target_ref: []const u8,
    }{
        .{ .node_id = "record:rec-1", .target_type = .record, .target_namespace = "records", .target_ref = "rec-1" },
        .{ .node_id = "object:primary", .target_type = .object, .target_namespace = null, .target_ref = object_ref },
        .{ .node_id = "chunk:primary", .target_type = .object_chunk, .target_namespace = null, .target_ref = chunk_ref },
        .{ .node_id = "vector:rec-1", .target_type = .vector, .target_namespace = "embeddings", .target_ref = "rec-1" },
    };

    for (expected) |item| {
        var node = try db.getGraphNode(std.testing.allocator, "targets", item.node_id);
        defer node.deinit(std.testing.allocator);
        try std.testing.expectEqual(item.target_type, node.target_type);
        if (item.target_namespace) |namespace| {
            try std.testing.expectEqualStrings(namespace, node.target_namespace.?);
        } else {
            try std.testing.expectEqual(@as(?[]u8, null), node.target_namespace);
        }
        try std.testing.expectEqualStrings(item.target_ref, node.target_ref.?);
    }
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

test "graph walk reports a missing root after the single root fetch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-walk-missing-root.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("app");

    try std.testing.expectError(error.GraphNodeNotFound, db.graphWalk(std.testing.allocator, .{
        .graph_name = "app",
        .start_node_id = "missing",
        .max_depth = 2,
        .limit = 10,
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

test "format version eight requires graph schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "format-seven.zova");

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
        try std.testing.expectEqualStrings("8", meta.columnText(0));
    }

    try std.testing.expect(try tableExists(&raw, "_zova_graphs"));
    try std.testing.expect(try tableExists(&raw, "_zova_graph_nodes"));
    try std.testing.expect(try tableExists(&raw, "_zova_graph_edges"));

    try raw.exec("drop table _zova_graph_edges");
    try std.testing.expectError(error.NotZovaDatabase, zova.Database.open(db_path));
}

test "opaque keyed batch reads preserve order duplicates and graph scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "keyed-reads.zova");
    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.createGraph("app");
    try db.createGraph("other");

    const nodes = [_]zova.GraphNodeInput{
        .{ .graph_name = "app", .node_id = "b", .kind = "beta" },
        .{ .graph_name = "app", .node_id = "a", .kind = "alpha" },
        .{ .graph_name = "other", .node_id = "a", .kind = "foreign" },
    };
    var node_keys: [3]i64 = undefined;
    try db.putGraphNodesKeyed(&nodes, &node_keys);
    const edges = [_]zova.GraphEdgeInput{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "links", .to_node_id = "b" },
        .{ .graph_name = "other", .from_node_id = "a", .edge_type = "self", .to_node_id = "a" },
    };
    var edge_keys: [2]i64 = undefined;
    try db.putGraphEdgesKeyed(&edges, &edge_keys);

    const requested_nodes = [_]i64{ node_keys[1], node_keys[0], node_keys[1], node_keys[2], std.math.maxInt(i64) };
    var found_nodes = try db.graphNodesGetManyKeyed(std.testing.allocator, "app", &requested_nodes);
    defer found_nodes.deinit(std.testing.allocator);
    try std.testing.expectEqual(requested_nodes.len, found_nodes.items.len);
    try std.testing.expectEqualStrings("a", found_nodes.items[0].node_id.?);
    try std.testing.expectEqualStrings("b", found_nodes.items[1].node_id.?);
    try std.testing.expectEqualStrings("a", found_nodes.items[2].node_id.?);
    try std.testing.expect(!found_nodes.items[3].found);
    try std.testing.expectEqual(node_keys[2], found_nodes.items[3].node_key);
    try std.testing.expect(!found_nodes.items[4].found);

    const requested_edges = [_]i64{ edge_keys[0], edge_keys[0], edge_keys[1], std.math.maxInt(i64) };
    var found_edges = try db.graphEdgesGetManyKeyed(std.testing.allocator, "app", &requested_edges);
    defer found_edges.deinit(std.testing.allocator);
    try std.testing.expect(found_edges.items[0].found);
    try std.testing.expectEqualStrings("links", found_edges.items[0].edge_type.?);
    try std.testing.expect(found_edges.items[1].found);
    try std.testing.expect(!found_edges.items[2].found);
    try std.testing.expect(!found_edges.items[3].found);

    var empty = try db.graphNodesGetManyKeyed(std.testing.allocator, "app", &.{});
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try std.testing.expectError(error.InvalidArgument, db.graphEdgesGetManyKeyed(std.testing.allocator, "app", &.{0}));
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
