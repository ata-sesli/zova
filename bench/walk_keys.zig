const std = @import("std");
const zova = @import("zova");
const count = 256;
const repeats = 16;

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn digest(walk: zova.GraphWalk) u64 {
    var hash = std.hash.Wyhash.init(0x5a6f7661);
    for (walk.items) |item| {
        hash.update(item.node_id);
        hash.update(item.kind);
        hash.update(std.mem.asBytes(&item.depth));
        hash.update(item.predecessor_node_id orelse "");
        hash.update(item.edge_type orelse "");
    }
    return hash.final();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    for ([_]bool{ false, true }) |high_degree| {
        var db = try zova.Database.createMemory();
        defer db.deinit();
        try db.createGraph("bench");
        const nodes = try allocator.alloc(zova.GraphNodeInput, count);
        for (nodes, 0..) |*node, i| node.* = .{
            .graph_name = "bench",
            .node_id = try std.fmt.allocPrint(allocator, "pkg/components/module/symbol-{d}", .{i}),
            .kind = "function",
        };
        try db.putGraphNodes(nodes);
        var edges: std.ArrayList(zova.GraphEdgeInput) = .empty;
        for (1..count) |i| {
            const parent = if (high_degree) 0 else i - 1;
            for ([_]bool{ false, true }) |reverse| try edges.append(allocator, .{
                .graph_name = "bench",
                .from_node_id = nodes[if (reverse) i else parent].node_id,
                .to_node_id = nodes[if (reverse) parent else i].node_id,
                .edge_type = if (high_degree and i % 2 == 0) "other" else "link",
            });
        }
        try db.putGraphEdges(edges.items);
        for ([_]zova.GraphNeighborDirection{ .outgoing, .incoming }) |direction| {
            for ([_]bool{ false, true }) |typed| {
                const options = zova.GraphWalkDirectionOptions{
                    .graph_name = "bench",
                    .start_node_id = nodes[0].node_id,
                    .direction = direction,
                    .edge_type = if (typed) "link" else null,
                    .max_depth = count,
                    .limit = count,
                };
                var warm = try db.graphWalkDirection(std.heap.c_allocator, options);
                defer warm.deinit(std.heap.c_allocator);
                const expected = digest(warm);
                var counter = std.testing.FailingAllocator.init(std.heap.c_allocator, .{});
                const start = now();
                for (0..repeats) |_| {
                    var walk = try db.graphWalkDirection(counter.allocator(), options);
                    defer walk.deinit(counter.allocator());
                    if (digest(walk) != expected) return error.ParityMismatch;
                }
                const total_us = @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / repeats / 1000;
                var adjacency: f64 = 0;
                var bookkeeping: f64 = 0;
                var last: zova.GraphWalkScanProfile = .{};
                for (0..repeats) |_| {
                    var profile: zova.GraphWalkScanProfile = .{};
                    var walk = try db.graphWalkDirectionProfiled(std.heap.c_allocator, options, &profile);
                    defer walk.deinit(std.heap.c_allocator);
                    if (digest(walk) != expected) return error.ParityMismatch;
                    adjacency += profile.adjacency_execute_ms;
                    bookkeeping += profile.bfs_bookkeeping_allocation_ms;
                    last = profile;
                }
                std.debug.print("fixture={s}-{s}-{s} total_us={d:.6} adjacency_us={d:.6} bookkeeping_us={d:.6} allocations={d} expansions={d} rows={d} results={d} digest={x}\n", .{
                    if (high_degree) "high" else "low", @tagName(direction),        if (typed) "typed" else "all",
                    total_us,                           adjacency * 1000 / repeats, bookkeeping * 1000 / repeats,
                    counter.allocations / repeats,      last.frontier_expansions,   last.adjacency_rows_stepped,
                    last.result_count,                  expected,
                });
            }
        }
    }
}
