//! Public-only C ABI behavior tests. No private implementation helpers.

const std = @import("std");
const zova_database = @import("c_api_internal.zig").zova_database;
const zova_database_begin = @import("c_api_internal.zig").zova_database_begin;
const zova_database_close = @import("c_api_internal.zig").zova_database_close;
const zova_database_create = @import("c_api_internal.zig").zova_database_create;
const zova_database_rollback = @import("c_api_internal.zig").zova_database_rollback;
const zova_graph_build_fresh_keyed = @import("c_api_internal.zig").zova_graph_build_fresh_keyed;
const zova_graph_build_fresh_prepared_keyed = @import("c_api_internal.zig").zova_graph_build_fresh_prepared_keyed;
const zova_graph_create = @import("c_api_internal.zig").zova_graph_create;
const zova_graph_degree = @import("c_api_internal.zig").zova_graph_degree;
const zova_graph_edge_delete_many = @import("c_api_internal.zig").zova_graph_edge_delete_many;
const zova_graph_edge_exists = @import("c_api_internal.zig").zova_graph_edge_exists;
const zova_graph_edge_input = @import("c_api_internal.zig").zova_graph_edge_input;
const zova_graph_edge_put_many = @import("c_api_internal.zig").zova_graph_edge_put_many;
const zova_graph_edge_put_many_keyed = @import("c_api_internal.zig").zova_graph_edge_put_many_keyed;
const zova_graph_edges_get_many_keyed = @import("c_api_internal.zig").zova_graph_edges_get_many_keyed;
const zova_graph_fresh_edge_input = @import("c_api_internal.zig").zova_graph_fresh_edge_input;
const zova_graph_fresh_node_input = @import("c_api_internal.zig").zova_graph_fresh_node_input;
const zova_graph_keyed_edge_results = @import("c_api_internal.zig").zova_graph_keyed_edge_results;
const zova_graph_keyed_edge_results_free = @import("c_api_internal.zig").zova_graph_keyed_edge_results_free;
const zova_graph_keyed_node_result = @import("c_api_internal.zig").zova_graph_keyed_node_result;
const zova_graph_keyed_node_results = @import("c_api_internal.zig").zova_graph_keyed_node_results;
const zova_graph_keyed_node_results_free = @import("c_api_internal.zig").zova_graph_keyed_node_results_free;
const zova_graph_neighbor_direction = @import("c_api_internal.zig").zova_graph_neighbor_direction;
const zova_graph_node_delete_many = @import("c_api_internal.zig").zova_graph_node_delete_many;
const zova_graph_node_input = @import("c_api_internal.zig").zova_graph_node_input;
const zova_graph_node_put_many = @import("c_api_internal.zig").zova_graph_node_put_many;
const zova_graph_node_put_many_keyed = @import("c_api_internal.zig").zova_graph_node_put_many_keyed;
const zova_graph_nodes_get_many_keyed = @import("c_api_internal.zig").zova_graph_nodes_get_many_keyed;
const zova_graph_target_type = @import("c_api_internal.zig").zova_graph_target_type;
const zova_status = @import("c_api_internal.zig").zova_status;

test "c abi batches graph mutations and reads degree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-graph-batches.zova", .{tmp.sub_path[0..]});
    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{ .path = db_path, .out_db = &db, .out_error_message = null }));
    defer _ = zova_database_close(db);
    try std.testing.expectEqual(zova_status.OK, zova_graph_create(&.{ .db = db, .name = "app" }));

    const nodes = [_]zova_graph_node_input{
        .{ .graph_name = "app", .node_id = "a", .kind = "function", .target_type = @intFromEnum(zova_graph_target_type.NONE), .target_namespace = null, .target_ref = null },
        .{ .graph_name = "app", .node_id = "b", .kind = "function", .target_type = @intFromEnum(zova_graph_target_type.NONE), .target_namespace = null, .target_ref = null },
    };
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_put_many(&.{ .db = db, .nodes = &nodes, .nodes_len = nodes.len }));

    const edges = [_]zova_graph_edge_input{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
    };
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_put_many(&.{ .db = db, .edges = &edges, .edges_len = edges.len }));

    var degree: u64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_graph_degree(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "a",
        .direction = @intFromEnum(zova_graph_neighbor_direction.OUTGOING),
        .edge_type = "calls",
        .out_degree = &degree,
    }));
    try std.testing.expectEqual(@as(u64, 1), degree);

    const delete_ids = [_]?[*:0]const u8{ "b", "missing" };
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_delete_many(&.{ .db = db, .graph_name = "app", .node_ids = &delete_ids, .node_count = delete_ids.len }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_degree(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "a",
        .direction = @intFromEnum(zova_graph_neighbor_direction.OUTGOING),
        .edge_type = null,
        .out_degree = &degree,
    }));
    try std.testing.expectEqual(@as(u64, 0), degree);
}

test "c abi graph edge delete many is validated atomic and idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-graph-edge-delete-many.zova", .{tmp.sub_path[0..]});
    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{ .path = db_path, .out_db = &db, .out_error_message = null }));
    defer _ = zova_database_close(db);
    try std.testing.expectEqual(zova_status.OK, zova_graph_create(&.{ .db = db, .name = "app" }));
    const nodes = [_]zova_graph_node_input{
        .{ .graph_name = "app", .node_id = "a", .kind = "function", .target_type = @intFromEnum(zova_graph_target_type.NONE), .target_namespace = null, .target_ref = null },
        .{ .graph_name = "app", .node_id = "b", .kind = "function", .target_type = @intFromEnum(zova_graph_target_type.NONE), .target_namespace = null, .target_ref = null },
    };
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_put_many(&.{ .db = db, .nodes = &nodes, .nodes_len = nodes.len }));
    const inserted = [_]zova_graph_edge_input{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
    };
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_put_many(&.{ .db = db, .edges = &inserted, .edges_len = inserted.len }));

    const invalid = [_]zova_graph_edge_input{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "", .to_node_id = "b" },
    };
    try std.testing.expectEqual(zova_status.GRAPH_INVALID, zova_graph_edge_delete_many(&.{
        .db = db,
        .edges = &invalid,
        .edges_len = invalid.len,
    }));
    var exists: u8 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_exists(&.{ .db = db, .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b", .out_exists = &exists }));
    try std.testing.expectEqual(@as(u8, 1), exists);

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_delete_many(&.{
        .db = db,
        .edges = null,
        .edges_len = 1,
    }));

    var deleted = [_]zova_graph_edge_input{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "a" },
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_begin(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_delete_many(&.{
        .db = db,
        .edges = &deleted,
        .edges_len = deleted.len,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_rollback(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_exists(&.{ .db = db, .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b", .out_exists = &exists }));
    try std.testing.expectEqual(@as(u8, 1), exists);

    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_delete_many(&.{
        .db = db,
        .edges = &deleted,
        .edges_len = deleted.len,
    }));
    deleted[0].edge_type = "borrowed-input-was-not-retained";
    exists = 1;
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_exists(&.{ .db = db, .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b", .out_exists = &exists }));
    try std.testing.expectEqual(@as(u8, 0), exists);
}

test "c abi opaque keyed batch reads align and zero error outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/keyed-read.zova", .{tmp.sub_path[0..]});
    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{ .path = path, .out_db = &db, .out_error_message = null }));
    defer _ = zova_database_close(db);
    try std.testing.expectEqual(zova_status.OK, zova_graph_create(&.{ .db = db, .name = "app" }));
    const nodes = [_]zova_graph_node_input{
        .{ .graph_name = "app", .node_id = "a", .kind = "kind", .target_type = 0, .target_namespace = null, .target_ref = null },
        .{ .graph_name = "app", .node_id = "b", .kind = "kind", .target_type = 0, .target_namespace = null, .target_ref = null },
    };
    var node_keys: [2]i64 = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_put_many_keyed(&.{ .db = db, .nodes = &nodes, .nodes_len = nodes.len, .out_node_keys = &node_keys, .out_node_keys_capacity = node_keys.len }));
    const edges = [_]zova_graph_edge_input{.{ .graph_name = "app", .from_node_id = "a", .edge_type = "links", .to_node_id = "b" }};
    var edge_keys: [1]i64 = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_put_many_keyed(&.{ .db = db, .edges = &edges, .edges_len = 1, .out_edge_keys = &edge_keys, .out_edge_keys_capacity = 1 }));

    const requested_nodes = [_]i64{ node_keys[1], node_keys[0], node_keys[1], std.math.maxInt(i64) };
    var node_results = zova_graph_keyed_node_results{ .items = null, .len = 0 };
    defer zova_graph_keyed_node_results_free(&node_results);
    try std.testing.expectEqual(zova_status.OK, zova_graph_nodes_get_many_keyed(&.{ .db = db, .graph_name = "app", .node_keys = &requested_nodes, .key_count = requested_nodes.len, .out_results = &node_results }));
    try std.testing.expectEqual(requested_nodes.len, node_results.len);
    try std.testing.expectEqual(@as(u8, 1), node_results.items.?[0].found);
    try std.testing.expectEqual(node_keys[1], node_results.items.?[2].node_key);
    try std.testing.expectEqual(@as(u8, 0), node_results.items.?[3].found);
    zova_graph_keyed_node_results_free(&node_results);

    var edge_results = zova_graph_keyed_edge_results{ .items = null, .len = 0 };
    defer zova_graph_keyed_edge_results_free(&edge_results);
    try std.testing.expectEqual(zova_status.OK, zova_graph_edges_get_many_keyed(&.{ .db = db, .graph_name = "app", .edge_keys = &edge_keys, .key_count = 1, .out_results = &edge_results }));
    try std.testing.expectEqual(@as(u8, 1), edge_results.items.?[0].found);
    try std.testing.expectEqualStrings("links", edge_results.items.?[0].edge_type.?[0..edge_results.items.?[0].edge_type_len]);

    const invalid = [_]i64{0};
    node_results.items = @ptrFromInt(@alignOf(zova_graph_keyed_node_result));
    node_results.len = 99;
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_nodes_get_many_keyed(&.{ .db = db, .graph_name = "app", .node_keys = &invalid, .key_count = 1, .out_results = &node_results }));
    try std.testing.expectEqual(@as(?[*]zova_graph_keyed_node_result, null), node_results.items);
    try std.testing.expectEqual(@as(usize, 0), node_results.len);
    zova_graph_keyed_node_results_free(&node_results);
    zova_graph_keyed_node_results_free(&node_results);
}

test "c abi fresh graph build returns aligned keys and rejects partial output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/fresh-build.zova", .{tmp.sub_path[0..]});
    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{ .path = path, .out_db = &db, .out_error_message = null }));
    defer _ = zova_database_close(db);

    const nodes = [_]zova_graph_fresh_node_input{
        .{ .node_id = "a", .kind = "old", .target_type = 0, .target_namespace = null, .target_ref = null },
        .{ .node_id = "b", .kind = "node", .target_type = 0, .target_namespace = null, .target_ref = null },
        .{ .node_id = "a", .kind = "final", .target_type = 0, .target_namespace = null, .target_ref = null },
    };
    const edges = [_]zova_graph_fresh_edge_input{
        .{ .from_node_ordinal = 0, .edge_type = "links", .to_node_ordinal = 1 },
        .{ .from_node_ordinal = 2, .edge_type = "links", .to_node_ordinal = 1 },
    };
    var node_keys = [_]i64{ 71, 72, 73 };
    var edge_keys = [_]i64{ 81, 82 };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_build_fresh_keyed(&.{
        .db = db,
        .graph_name = "app",
        .nodes = &nodes,
        .nodes_len = nodes.len,
        .edges = &edges,
        .edges_len = edges.len,
        .out_node_keys = &node_keys,
        .out_node_keys_capacity = nodes.len - 1,
        .out_edge_keys = &edge_keys,
        .out_edge_keys_capacity = edges.len,
    }));
    try std.testing.expectEqualSlices(i64, &.{ 71, 72, 73 }, &node_keys);
    try std.testing.expectEqualSlices(i64, &.{ 81, 82 }, &edge_keys);
    try std.testing.expectEqual(zova_status.OK, zova_graph_build_fresh_keyed(&.{
        .db = db,
        .graph_name = "app",
        .nodes = &nodes,
        .nodes_len = nodes.len,
        .edges = &edges,
        .edges_len = edges.len,
        .out_node_keys = &node_keys,
        .out_node_keys_capacity = node_keys.len,
        .out_edge_keys = &edge_keys,
        .out_edge_keys_capacity = edge_keys.len,
    }));
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 1 }, &node_keys);
    try std.testing.expectEqualSlices(i64, &.{ 1, 1 }, &edge_keys);
    try std.testing.expectEqual(zova_status.GRAPH_INVALID, zova_graph_build_fresh_keyed(&.{
        .db = db,
        .graph_name = "other",
        .nodes = &nodes,
        .nodes_len = nodes.len,
        .edges = &edges,
        .edges_len = edges.len,
        .out_node_keys = &node_keys,
        .out_node_keys_capacity = node_keys.len,
        .out_edge_keys = &edge_keys,
        .out_edge_keys_capacity = edge_keys.len,
    }));
}

test "c abi prepared fresh graph build returns deterministic aligned keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/prepared-fresh-build.zova", .{tmp.sub_path[0..]});
    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{ .path = path, .out_db = &db, .out_error_message = null }));
    defer _ = zova_database_close(db);

    const nodes = [_]zova_graph_fresh_node_input{
        .{ .node_id = "a", .kind = "node", .target_type = 0, .target_namespace = null, .target_ref = null },
        .{ .node_id = "b", .kind = "node", .target_type = 0, .target_namespace = null, .target_ref = null },
    };
    const edges = [_]zova_graph_fresh_edge_input{
        .{ .from_node_ordinal = 0, .edge_type = "links", .to_node_ordinal = 1 },
    };
    var node_keys = [_]i64{ 71, 72 };
    var edge_keys = [_]i64{81};
    try std.testing.expectEqual(zova_status.OK, zova_graph_build_fresh_prepared_keyed(&.{
        .db = db,
        .graph_name = "app",
        .nodes = &nodes,
        .nodes_len = nodes.len,
        .edges = &edges,
        .edges_len = edges.len,
        .out_node_keys = &node_keys,
        .out_node_keys_capacity = node_keys.len,
        .out_edge_keys = &edge_keys,
        .out_edge_keys_capacity = edge_keys.len,
    }));
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, &node_keys);
    try std.testing.expectEqualSlices(i64, &.{1}, &edge_keys);
}
