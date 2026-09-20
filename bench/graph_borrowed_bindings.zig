const std = @import("std");
const zova = @import("zova");

const graph_name = "borrowed-bindings";
const edge_types = [_][]const u8{ "calls", "imports", "defines", "tests" };

const Mode = enum { fresh, endpoints };

const Fixture = struct {
    nodes: []zova.GraphNodeInput,
    fresh_nodes: []zova.FreshGraphNodeInput,
    edges: []zova.GraphEdgeInput,
    fresh_edges: []zova.FreshGraphEdgeInput,
};

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const ns = start.durationTo(now()).toNanoseconds();
    return if (ns <= 0) 0 else @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

fn makeFixture(allocator: std.mem.Allocator, node_count: usize, edge_count: usize) !Fixture {
    if (node_count == 0) return error.InvalidArgument;
    const node_ids = try allocator.alloc([]const u8, node_count);
    const nodes = try allocator.alloc(zova.GraphNodeInput, node_count);
    const fresh_nodes = try allocator.alloc(zova.FreshGraphNodeInput, node_count);
    for (node_ids, nodes, fresh_nodes, 0..) |*node_id, *node, *fresh_node, index| {
        node_id.* = try std.fmt.allocPrint(allocator, "node-{d:0>6}", .{index});
        node.* = .{ .graph_name = graph_name, .node_id = node_id.*, .kind = "symbol" };
        fresh_node.* = .{ .node_id = node_id.*, .kind = "symbol" };
    }

    const edges = try allocator.alloc(zova.GraphEdgeInput, edge_count);
    const fresh_edges = try allocator.alloc(zova.FreshGraphEdgeInput, edge_count);
    for (edges, fresh_edges, 0..) |*edge, *fresh_edge, index| {
        const from = index % node_count;
        const round = index / node_count;
        const to = (from + 1 + round * 97) % node_count;
        const edge_type = edge_types[round % edge_types.len];
        edge.* = .{
            .graph_name = graph_name,
            .from_node_id = node_ids[from],
            .edge_type = edge_type,
            .to_node_id = node_ids[to],
        };
        fresh_edge.* = .{
            .from_node_ordinal = from,
            .edge_type = edge_type,
            .to_node_ordinal = to,
        };
    }

    return .{
        .nodes = nodes,
        .fresh_nodes = fresh_nodes,
        .edges = edges,
        .fresh_edges = fresh_edges,
    };
}

fn verifyCounts(db: *zova.Database, node_count: usize, edge_count: usize) !void {
    var info = try db.graphInfo(std.heap.c_allocator, graph_name);
    defer info.deinit(std.heap.c_allocator);
    if (info.node_count != node_count or info.edge_count != edge_count) return error.GraphInvalid;
}

fn runFresh(allocator: std.mem.Allocator, db: *zova.Database, fixture: Fixture) !f64 {
    const node_keys = try allocator.alloc(i64, fixture.fresh_nodes.len);
    const edge_keys = try allocator.alloc(i64, fixture.fresh_edges.len);
    var profile: zova.FreshGraphBuildProfile = .{};
    const start = now();
    try db.buildFreshGraphKeyedProfiled(
        graph_name,
        fixture.fresh_nodes,
        fixture.fresh_edges,
        node_keys,
        edge_keys,
        &profile,
    );
    const total_ms = elapsedMs(start);
    try verifyCounts(db, fixture.fresh_nodes.len, fixture.fresh_edges.len);
    std.debug.print(
        "profile validation_ms={d:.6} metadata_ms={d:.6} nodes_ms={d:.6} edges_ms={d:.6} indexes_ms={d:.6}\n",
        .{ profile.validation_ms, profile.graph_and_types_ms, profile.node_load_ms, profile.edge_load_ms, profile.index_build_ms },
    );
    return total_ms;
}

fn runEndpoints(db: *zova.Database, fixture: Fixture) !f64 {
    try db.createGraph(graph_name);
    try db.putGraphNodes(fixture.nodes);
    const start = now();
    try db.putGraphEdges(fixture.edges);
    const total_ms = elapsedMs(start);
    try verifyCounts(db, fixture.nodes.len, fixture.edges.len);
    return total_ms;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5) return error.InvalidArgument;
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.InvalidArgument;
    const path = try allocator.dupeZ(u8, args[2]);
    const node_count = try std.fmt.parseInt(usize, args[3], 10);
    const edge_count = try std.fmt.parseInt(usize, args[4], 10);
    const fixture = try makeFixture(allocator, node_count, edge_count);

    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    var db = try zova.Database.create(path);
    defer db.deinit();

    const total_ms = switch (mode) {
        .fresh => try runFresh(allocator, &db, fixture),
        .endpoints => try runEndpoints(&db, fixture),
    };
    std.debug.print(
        "result mode={s} nodes={d} edges={d} total_ms={d:.6}\n",
        .{ @tagName(mode), node_count, edge_count, total_ms },
    );
}
