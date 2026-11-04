//! Bounded benchmark for keyed graph puts into an already large graph.
//! Usage: <binary> <database-path> [node-count] [runs]
//!
//! The graph is populated once with plain puts, then small keyed batches and a
//! full keyed replay are timed. Issue #179 is about the small-batch cost, which
//! used to be proportional to the whole graph size.

const std = @import("std");
const zova = @import("zova");

const default_node_count: usize = 100_000;
const default_runs: usize = 7;
const max_batch_size: usize = 1_024;
const batch_sizes = [_]usize{ 1, 8, 64, 256, 512, 1_024 };

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const nanoseconds = start.durationTo(now()).toNanoseconds();
    return if (nanoseconds <= 0) 0 else @as(f64, @floatFromInt(nanoseconds)) / @as(f64, std.time.ns_per_ms);
}

fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[values.len / 2];
}

fn mad(values: []f64) f64 {
    const center = median(values);
    var deviations: [default_runs]f64 = undefined;
    if (values.len > deviations.len) return 0;
    for (values, 0..) |value, index| deviations[index] = @abs(value - center);
    return median(deviations[0..values.len]);
}

fn reportBatch(kind: []const u8, requested: usize, samples: []f64) void {
    std.debug.print(
        "small_batch kind={s} requested={d} median_ms={d:.6} mad_ms={d:.6}\n",
        .{ kind, requested, median(samples), mad(samples) },
    );
}

fn reportReplay(kind: []const u8, count: usize, samples: []f64) void {
    std.debug.print(
        "large_replay kind={s} count={d} median_ms={d:.6} mad_ms={d:.6}\n",
        .{ kind, count, median(samples), mad(samples) },
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2 or args.len > 4) return error.InvalidArgument;
    const path = try allocator.dupeSentinel(u8, args[1], 0);
    const node_count = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else default_node_count;
    const runs = if (args.len >= 4) try std.fmt.parseInt(usize, args[3], 10) else default_runs;
    if (node_count < 2) return error.InvalidArgument;
    if (runs == 0 or runs > default_runs) return error.InvalidArgument;

    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    var db = try zova.Database.create(path);
    defer db.deinit();
    try db.createGraph("bench");

    var node_id_buffers = try allocator.alloc([16]u8, node_count);
    var node_inputs = try allocator.alloc(zova.GraphNodeInput, node_count);
    for (0..node_count) |index| {
        const node_id = try std.fmt.bufPrint(&node_id_buffers[index], "n{d:0>7}", .{index});
        node_inputs[index] = .{ .graph_name = "bench", .node_id = node_id, .kind = "bench" };
    }
    var edge_inputs = try allocator.alloc(zova.GraphEdgeInput, node_count);
    for (0..node_count) |index| {
        edge_inputs[index] = .{
            .graph_name = "bench",
            .from_node_id = node_inputs[index].node_id,
            .edge_type = "chain",
            .to_node_id = node_inputs[(index + 1) % node_count].node_id,
        };
    }
    try db.putGraphNodes(node_inputs);
    try db.putGraphEdges(edge_inputs);
    std.debug.print("fixture nodes={d} edges={d} runs={d}\n", .{ node_count, node_count, runs });

    var node_key_buffers: [max_batch_size][48]u8 = undefined;
    var edge_type_buffers: [max_batch_size][48]u8 = undefined;
    var batch_node_samples: [default_runs]f64 = undefined;
    var batch_edge_samples: [default_runs]f64 = undefined;
    for (batch_sizes) |size| {
        for (0..runs) |run| {
            var inputs: [max_batch_size]zova.GraphNodeInput = undefined;
            var keys: [max_batch_size]i64 = undefined;
            for (0..size) |index| {
                const node_id = try std.fmt.bufPrint(&node_key_buffers[index], "probe-n{d}-{d}-{d}", .{ size, run, index });
                inputs[index] = .{ .graph_name = "bench", .node_id = node_id, .kind = "probe" };
            }
            const start = now();
            try db.putGraphNodesKeyed(inputs[0..size], keys[0..size]);
            batch_node_samples[run] = elapsedMs(start);
        }
        reportBatch("nodes", size, batch_node_samples[0..runs]);

        for (0..runs) |run| {
            var inputs: [max_batch_size]zova.GraphEdgeInput = undefined;
            var keys: [max_batch_size]i64 = undefined;
            for (0..size) |index| {
                const edge_type = try std.fmt.bufPrint(&edge_type_buffers[index], "probe-e{d}-{d}-{d}", .{ size, run, index });
                inputs[index] = .{
                    .graph_name = "bench",
                    .from_node_id = node_inputs[0].node_id,
                    .edge_type = edge_type,
                    .to_node_id = node_inputs[1 + (run * size + index) % (node_count - 1)].node_id,
                };
            }
            const start = now();
            try db.putGraphEdgesKeyed(inputs[0..size], keys[0..size]);
            batch_edge_samples[run] = elapsedMs(start);
        }
        reportBatch("edges", size, batch_edge_samples[0..runs]);
    }

    const node_keys = try allocator.alloc(i64, node_count);
    const edge_keys = try allocator.alloc(i64, node_count);
    try db.putGraphNodesKeyed(node_inputs, node_keys);
    try db.putGraphEdgesKeyed(edge_inputs, edge_keys);

    var node_replay_samples: [default_runs]f64 = undefined;
    var edge_replay_samples: [default_runs]f64 = undefined;
    for (0..runs) |run| {
        var start = now();
        try db.putGraphNodesKeyed(node_inputs, node_keys);
        node_replay_samples[run] = elapsedMs(start);
        start = now();
        try db.putGraphEdgesKeyed(edge_inputs, edge_keys);
        edge_replay_samples[run] = elapsedMs(start);
    }
    reportReplay("nodes", node_count, node_replay_samples[0..runs]);
    reportReplay("edges", node_count, edge_replay_samples[0..runs]);
}
