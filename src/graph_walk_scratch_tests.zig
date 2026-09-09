//! Issue #99 scratch lease and ownership regression coverage.

const std = @import("std");
const graph_impl = @import("graph.zig");
const scratch_impl = @import("graph_walk_scratch.zig");
const test_support = @import("zova_test_support.zig");
const zova = @import("zova.zig");

const testingDbPath = test_support.testingDbPath;

fn walkOptions(direction: graph_impl.GraphNeighborDirection, edge_type: ?[]const u8, limit: usize) graph_impl.GraphWalkDirectionOptions {
    return .{
        .graph_name = "walk",
        .start_node_id = "n0",
        .direction = direction,
        .edge_type = edge_type,
        .max_depth = 4,
        .limit = limit,
    };
}

fn fixture(db: *zova.Database) !void {
    try db.createGraph("walk");
    const nodes = [_]zova.GraphNodeInput{
        .{ .graph_name = "walk", .node_id = "n0", .kind = "root" },
        .{ .graph_name = "walk", .node_id = "n1", .kind = "node" },
        .{ .graph_name = "walk", .node_id = "n2", .kind = "node" },
        .{ .graph_name = "walk", .node_id = "n3", .kind = "node" },
    };
    try db.putGraphNodes(&nodes);
    const edges = [_]zova.GraphEdgeInput{
        .{ .graph_name = "walk", .from_node_id = "n0", .to_node_id = "n1", .edge_type = "link" },
        .{ .graph_name = "walk", .from_node_id = "n0", .to_node_id = "n2", .edge_type = "calls" },
        .{ .graph_name = "walk", .from_node_id = "n1", .to_node_id = "n3", .edge_type = "link" },
        .{ .graph_name = "walk", .from_node_id = "n2", .to_node_id = "n3", .edge_type = "calls" },
        .{ .graph_name = "walk", .from_node_id = "n3", .to_node_id = "n0", .edge_type = "link" },
    };
    try db.putGraphEdges(&edges);
}

test "walk scratch retains capacity but never owns returned results" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try fixture(&db);

    var first = try db.graphWalkDirection(std.testing.allocator, walkOptions(.outgoing, null, 3));
    defer first.deinit(std.testing.allocator);
    const first_copy = try std.testing.allocator.dupe(u8, first.items[1].node_id);
    defer std.testing.allocator.free(first_copy);
    const retained_after_first = db.graph_walk_scratch.retainedCapacity();
    try std.testing.expect(retained_after_first <= scratch_impl.retained_capacity_limit);

    var second = try db.graphWalkDirection(std.testing.allocator, walkOptions(.incoming, "link", 2));
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first_copy, first.items[1].node_id);
    try std.testing.expect(db.graph_walk_scratch.retainedCapacity() <= scratch_impl.retained_capacity_limit);

    try db.deleteGraphEdge(.{ .graph_name = "walk", .from_node_id = "n0", .to_node_id = "n1", .edge_type = "link" });
    var third = try db.graphWalkDirection(std.testing.allocator, walkOptions(.outgoing, null, 3));
    defer third.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), third.items.len);
    try std.testing.expectEqualStrings("n2", third.items[1].node_id);
}

test "walk scratch preserves BFS order, predecessor, direction, filters and limits" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try fixture(&db);

    for ([_]graph_impl.GraphNeighborDirection{ .outgoing, .incoming }) |direction| {
        for ([_]?[]const u8{ null, "link", "calls" }) |edge_type| {
            for ([_]usize{ 1, 2, 4 }) |limit| {
                var ordinary = try db.graphWalkDirection(std.testing.allocator, walkOptions(direction, edge_type, limit));
                defer ordinary.deinit(std.testing.allocator);
                var profiled_data: graph_impl.GraphWalkScanProfile = .{};
                var profiled = try db.graphWalkDirectionProfiled(std.testing.allocator, walkOptions(direction, edge_type, limit), &profiled_data);
                defer profiled.deinit(std.testing.allocator);
                try std.testing.expectEqualDeep(ordinary.items, profiled.items);
                try std.testing.expect(ordinary.items.len <= limit);
                try std.testing.expect(profiled_data.result_count == ordinary.items.len);
            }
        }
    }
}

test "walk scratch uses uncached fallback for nested calls and resets after SQL failures" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try fixture(&db);
    try std.testing.expect(!db.graph_walk_scratch.in_use);

    // Hold the connection lease to model a reentrant callback. The nested walk
    // must use an independent temporary arena and must not reset the in-flight
    // connection-owned scratch.
    try std.testing.expect(db.graph_walk_scratch.acquire());
    var nested = try db.graphWalkDirection(std.testing.allocator, walkOptions(.outgoing, null, 3));
    nested.deinit(std.testing.allocator);
    try std.testing.expect(db.graph_walk_scratch.in_use);
    db.graph_walk_scratch.release();

    var outer = try db.graphWalkDirection(std.testing.allocator, walkOptions(.outgoing, null, 3));
    defer outer.deinit(std.testing.allocator);
    try std.testing.expect(!db.graph_walk_scratch.in_use);

    try db.exec("drop table _zova_graph_nodes");
    try std.testing.expectError(error.SqliteError, db.graphWalkDirection(std.testing.allocator, walkOptions(.outgoing, null, 3)));
    try std.testing.expect(!db.graph_walk_scratch.in_use);
    try std.testing.expect(db.graph_walk_scratch.retainedCapacity() <= scratch_impl.retained_capacity_limit);
}

test "walk scratch is independent from caller allocator failures" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try fixture(&db);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, db.graphWalkDirection(failing.allocator(), walkOptions(.outgoing, null, 3)));
    try std.testing.expect(!db.graph_walk_scratch.in_use);
    var retry = try db.graphWalkDirection(std.testing.allocator, walkOptions(.outgoing, null, 3));
    defer retry.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), retry.items.len);
}

test "walk scratch main and bound stores have independent lifecycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "walk-scratch-main.zova");
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "walk-scratch-store.zova");
    try zova.createGraphStore(store_path);

    var db = try zova.Database.create(main_path);
    defer db.deinit();
    try db.bindGraphStore(store_path);
    try fixture(&db);
    var result = try db.graphWalkDirection(std.testing.allocator, walkOptions(.outgoing, null, 3));
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(db.graph_walk_scratch.retainedCapacity() <= scratch_impl.retained_capacity_limit);
    try db.unbindGraphStore();
    try std.testing.expect(!db.graph_walk_scratch.in_use);
    try std.testing.expect(db.graph_walk_scratch.retainedCapacity() <= scratch_impl.retained_capacity_limit);
}

fn walkWithAllocationFailures(allocator: std.mem.Allocator, db: *zova.Database, limit: usize) !void {
    defer std.debug.assert(!db.graph_walk_scratch.in_use);
    var result = try db.graphWalkDirection(allocator, walkOptions(.outgoing, null, limit));
    defer result.deinit(allocator);
    try std.testing.expectEqual(limit, result.items.len);
    // Reset/reuse the arena while the original caller-owned result is alive.
    var next = try db.graphWalkDirection(std.testing.allocator, walkOptions(.incoming, "link", 4));
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("n0", result.items[0].node_id);
    if (limit > 1) {
        try std.testing.expectEqualStrings("n1", result.items[1].node_id);
        try std.testing.expectEqualStrings("n0", result.items[1].predecessor_node_id.?);
        try std.testing.expectEqualStrings("link", result.items[1].edge_type.?);
    }
}

test "walk result copying cleans every allocation failure and reuses scratch" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try fixture(&db);
    // Cover both a visited prefix with queued leftovers and the whole frontier.
    for ([_]usize{ 2, 4 }) |limit| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, walkWithAllocationFailures, .{ &db, limit });
        var retry = try db.graphWalkDirection(std.testing.allocator, walkOptions(.outgoing, null, limit));
        defer retry.deinit(std.testing.allocator);
        try std.testing.expectEqual(limit, retry.items.len);
    }
}
