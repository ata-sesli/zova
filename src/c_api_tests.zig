//! C ABI test entrypoint.
//!
//! The ABI implementation tests currently live beside the internal helpers so
//! they can exercise non-exported conversion and validation paths. This module
//! keeps `src/c_api.zig` free of test bodies while still pulling those tests
//! into the `c-api-test` build root.

const internal = @import("c_api_internal.zig");
const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova = @import("zova.zig");

test {
    _ = internal;
}

test "c abi graph operations route through a bound store after reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try std.fmt.bufPrintZ(&main_buffer, ".zig-cache/tmp/{s}/c-abi-bound-graph-main.zova", .{tmp.sub_path[0..]});
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try std.fmt.bufPrintZ(&store_buffer, ".zig-cache/tmp/{s}/c-abi-bound-graph-store.zova", .{tmp.sub_path[0..]});

    try zova.createGraphStore(store_path);
    {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try db.bindGraphStore(store_path);
        try db.createGraph("deps");
        try db.putGraphNode(.{ .graph_name = "deps", .node_id = "a", .kind = "file" });
        try db.putGraphNode(.{ .graph_name = "deps", .node_id = "b", .kind = "file" });
        try db.putGraphNode(.{ .graph_name = "deps", .node_id = "c", .kind = "file" });
        try db.putGraphEdge(.{ .graph_name = "deps", .from_node_id = "a", .edge_type = "imports", .to_node_id = "b" });
        try db.putGraphEdge(.{ .graph_name = "deps", .from_node_id = "c", .edge_type = "imports", .to_node_id = "a" });
    }

    var handle: ?*internal.zova_database = null;
    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_database_open(&.{
        .path = main_path,
        .out_db = &handle,
        .out_error_message = null,
    }));
    defer {
        if (handle != null) _ = internal.zova_database_close(handle);
    }

    var graphs: internal.zova_graph_list = .{ .items = null, .len = 0 };
    defer internal.zova_graph_list_free(&graphs);
    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_graphs_list(&.{ .db = handle, .out_list = &graphs }));
    try std.testing.expectEqual(@as(usize, 1), graphs.len);
    try std.testing.expectEqualStrings("deps", graphs.items.?[0].name.?[0..graphs.items.?[0].name_len]);

    var node = std.mem.zeroes(internal.zova_graph_node);
    defer internal.zova_graph_node_free(&node);
    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_graph_node_get(&.{
        .db = handle,
        .graph_name = "deps",
        .node_id = "a",
        .out_node = &node,
    }));
    try std.testing.expectEqualStrings("a", node.node_id.?[0..node.node_id_len]);

    var neighbors: internal.zova_graph_neighbor_results = .{ .items = null, .len = 0 };
    defer internal.zova_graph_neighbor_results_free(&neighbors);
    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_graph_neighbors(&.{
        .db = handle,
        .graph_name = "deps",
        .node_id = "a",
        .direction = @intFromEnum(internal.zova_graph_neighbor_direction.OUTGOING),
        .edge_type = "imports",
        .limit = 10,
        .out_results = &neighbors,
    }));
    try std.testing.expectEqual(@as(usize, 1), neighbors.len);
    try std.testing.expectEqualStrings("b", neighbors.items.?[0].node_id.?[0..neighbors.items.?[0].node_id_len]);
    internal.zova_graph_neighbor_results_free(&neighbors);
    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_graph_neighbors(&.{
        .db = handle,
        .graph_name = "deps",
        .node_id = "a",
        .direction = @intFromEnum(internal.zova_graph_neighbor_direction.INCOMING),
        .edge_type = "imports",
        .limit = 10,
        .out_results = &neighbors,
    }));
    try std.testing.expectEqual(@as(usize, 1), neighbors.len);
    try std.testing.expectEqualStrings("c", neighbors.items.?[0].node_id.?[0..neighbors.items.?[0].node_id_len]);

    var walk: internal.zova_graph_walk_results = .{ .items = null, .len = 0 };
    defer internal.zova_graph_walk_results_free(&walk);
    var profile: internal.zova_graph_walk_profile = .{};
    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_graph_walk_direction_profiled(&.{
        .db = handle,
        .graph_name = "deps",
        .start_node_id = "b",
        .direction = @intFromEnum(internal.zova_graph_neighbor_direction.INCOMING),
        .edge_type = "imports",
        .max_depth = 2,
        .limit = 10,
        .out_results = &walk,
        .out_profile = &profile,
    }));
    try std.testing.expectEqual(@as(usize, 3), walk.len);
    try std.testing.expectEqual(@as(u64, 3), profile.result_count);

    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_graph_node_put(&.{
        .db = handle,
        .graph_name = "deps",
        .node_id = "d",
        .kind = "file",
        .target_type = @intFromEnum(internal.zova_graph_target_type.NONE),
        .target_namespace = null,
        .target_ref = null,
    }));
    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_graph_edge_put(&.{
        .db = handle,
        .graph_name = "deps",
        .from_node_id = "b",
        .edge_type = "imports",
        .to_node_id = "d",
    }));
    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_graph_edge_delete(&.{
        .db = handle,
        .graph_name = "deps",
        .from_node_id = "c",
        .edge_type = "imports",
        .to_node_id = "a",
    }));
    {
        var store_after_edge_delete = try sqlite.Database.open(store_path);
        defer store_after_edge_delete.deinit();
        try expectCount(&store_after_edge_delete, "select count(*) from _zova_graph_edges e join _zova_graphs g on g.graph_key=e.graph_key join _zova_graph_edge_types et on et.graph_key=e.graph_key and et.edge_type_key=e.edge_type_key join _zova_graph_nodes f on f.node_key=e.from_node_key join _zova_graph_nodes t on t.node_key=e.to_node_key where g.name='deps' and f.node_id='c' and et.name='imports' and t.node_id='a'", 0);
        try expectCount(&store_after_edge_delete, "select count(*) from _zova_graph_nodes n join _zova_graphs g on g.graph_key=n.graph_key where g.name='deps' and n.node_id='c'", 1);
    }
    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_graph_node_delete(&.{
        .db = handle,
        .graph_name = "deps",
        .node_id = "c",
    }));

    try std.testing.expectEqual(internal.zova_status.OK, internal.zova_database_close(handle));
    handle = null;

    var main = try sqlite.Database.open(main_path);
    defer main.deinit();
    try expectCount(&main, "select count(*) from _zova_graphs", 0);
    try expectCount(&main, "select count(*) from _zova_graph_nodes", 0);
    try expectCount(&main, "select count(*) from _zova_graph_edges", 0);

    var store = try sqlite.Database.open(store_path);
    defer store.deinit();
    try expectCount(&store, "select count(*) from _zova_graphs where name = 'deps'", 1);
    try expectCount(&store, "select count(*) from _zova_graph_nodes n join _zova_graphs g on g.graph_key=n.graph_key where g.name='deps'", 3);
    try expectCount(&store, "select count(*) from _zova_graph_nodes n join _zova_graphs g on g.graph_key=n.graph_key where g.name='deps' and n.node_id='d'", 1);
    try expectCount(&store, "select count(*) from _zova_graph_nodes n join _zova_graphs g on g.graph_key=n.graph_key where g.name='deps' and n.node_id='c'", 0);
    try expectCount(&store, "select count(*) from _zova_graph_edges e join _zova_graphs g on g.graph_key=e.graph_key where g.name='deps'", 2);
    try expectCount(&store, "select count(*) from _zova_graph_edges e join _zova_graphs g on g.graph_key=e.graph_key join _zova_graph_nodes f on f.node_key=e.from_node_key join _zova_graph_nodes t on t.node_key=e.to_node_key where g.name='deps' and f.node_id='b' and t.node_id='d'", 1);
}

fn expectCount(db: *sqlite.Database, sql: [:0]const u8, expected: i64) !void {
    var statement = try db.prepare(sql);
    defer statement.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try statement.step());
    try std.testing.expectEqual(expected, statement.columnInt64(0));
}
