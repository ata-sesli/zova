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
    try graphs.putGraphNodes(&.{
        .{ .graph_name = "external", .node_id = "a", .kind = "test" },
        .{ .graph_name = "external", .node_id = "b", .kind = "test" },
    });

    var indexes = try raw.prepare(
        \\select
        \\  (select count(*) from main.sqlite_master where type = 'index' and name = '_zova_graph_nodes_created_order_idx'),
        \\  (select count(*) from graph_store.sqlite_master where type = 'index' and name = '_zova_graph_nodes_created_order_idx')
    );
    defer indexes.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try indexes.step());
    try std.testing.expectEqual(@as(i64, 0), indexes.columnInt64(0));
    try std.testing.expectEqual(@as(i64, 1), indexes.columnInt64(1));

    try graphs.putGraphEdge(.{
        .graph_name = "external",
        .from_node_id = "a",
        .edge_type = "links",
        .to_node_id = "b",
    });

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
        \\join _zova_graph_nodes n on n.graph_name = e.graph_name and n.node_id = e.to_node_id
        \\where e.graph_name = 'app' and e.from_node_id = 'a'
        \\order by e.created_order, e.to_node_id
        \\limit 10
    , "_zova_graph_edges_from_node_idx");
    try expectQueryPlanUsesIndex(&db.sqlite_db,
        \\explain query plan
        \\select n.node_id, n.kind, e.edge_type
        \\from _zova_graph_edges e
        \\join _zova_graph_nodes n on n.graph_name = e.graph_name and n.node_id = e.to_node_id
        \\where e.graph_name = 'app' and e.from_node_id = 'a' and e.edge_type = 'calls'
        \\order by e.created_order, e.to_node_id
        \\limit 10
    , "_zova_graph_edges_from_node_type_idx");
    try expectQueryPlanUsesIndex(&db.sqlite_db,
        \\explain query plan
        \\select n.node_id, n.kind, e.edge_type
        \\from _zova_graph_edges e
        \\join _zova_graph_nodes n on n.graph_name = e.graph_name and n.node_id = e.from_node_id
        \\where e.graph_name = 'app' and e.to_node_id = 'a'
        \\order by e.created_order, e.from_node_id
        \\limit 10
    , "_zova_graph_edges_to_node_idx");
    try expectQueryPlanUsesIndex(&db.sqlite_db,
        \\explain query plan
        \\select n.node_id, n.kind, e.edge_type
        \\from _zova_graph_edges e
        \\join _zova_graph_nodes n on n.graph_name = e.graph_name and n.node_id = e.from_node_id
        \\where e.graph_name = 'app' and e.to_node_id = 'a' and e.edge_type = 'calls'
        \\order by e.created_order, e.from_node_id
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

test "format version seven requires graph schema" {
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
        try std.testing.expectEqualStrings("7", meta.columnText(0));
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
