//! One bounded graph batch sample for issue #95.
//! Usage: binary NEW_DATABASE_PATH EDGES(1|16|1024) steady|dropped main|bound
//! Fixture: deterministic graph (seed 0x5a6f7661), 1,024 existing nodes.
//! steady:  one ordinary edge batch repeated 200 times into a steady-state
//!          schema (all seven indexes present); reports per-batch median/MAD.
//! dropped: 20 batches, each preceded by dropping all seven indexes, so every
//!          batch must recreate them; reports per-batch median/MAD.
//! store:   main routes to the main database, bound to an attached graph store.
//! Counters come from sqlite3_trace_v2 over the measured window. Read controls
//! (typed/untyped neighbors, degree, depth-2 walk) report p50/p95 of 200 calls.
const std = @import("std");
const zova = @import("zova");
const sqlite = zova.sqlite;
const c = sqlite.c;

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn ns(start: std.Io.Timestamp) i64 {
    return @intCast(start.durationTo(now()).toNanoseconds());
}

const node_count = 1024;
const index_names = [_][]const u8{
    "_zova_graph_nodes_created_order_idx",
    "_zova_graph_edges_topology_idx",
    "_zova_graph_edges_created_order_idx",
    "_zova_graph_edges_from_node_idx",
    "_zova_graph_edges_from_node_type_idx",
    "_zova_graph_edges_to_node_idx",
    "_zova_graph_edges_to_node_type_idx",
};

const Counters = struct {
    stmts: usize = 0,
    create_index: usize = 0,
    probe: usize = 0,

    fn callback(_: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const handle: *c.sqlite3_stmt = @ptrCast(@alignCast(statement.?));
        const sql = std.mem.span(c.sqlite3_sql(handle));
        self.stmts += 1;
        if (std.mem.indexOf(u8, sql, "create index") != null or
            std.mem.indexOf(u8, sql, "create unique index") != null) self.create_index += 1;
        if (std.mem.indexOf(u8, sql, "sqlite_master") != null) self.probe += 1;
        return 0;
    }
};

fn median(values: []f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[values.len / 2];
}

fn mad(values: []f64) f64 {
    const centre = median(values);
    const deviations = values;
    for (deviations) |*value| value.* = @abs(value.* - centre);
    return median(deviations);
}

fn percentile(samples: []f64, pct: f64) f64 {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    const rank = @min(samples.len - 1, @as(usize, @intFromFloat(@ceil(pct / 100.0 * @as(f64, @floatFromInt(samples.len))))) -| 1);
    return samples[rank];
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5) return error.InvalidArgument;
    const edges = try std.fmt.parseInt(usize, args[2], 10);
    if (edges != 1 and edges != 16 and edges != 1024) return error.InvalidArgument;
    const dropped = std.mem.eql(u8, args[3], "dropped");
    if (!dropped and !std.mem.eql(u8, args[3], "steady")) return error.InvalidArgument;
    const bound = std.mem.eql(u8, args[4], "bound");
    if (!bound and !std.mem.eql(u8, args[4], "main")) return error.InvalidArgument;

    var db = try zova.Database.create(try allocator.dupeZ(u8, args[1]));
    defer db.deinit();
    const schema = if (bound) "graph_store" else "main";
    if (bound) {
        const store_path = try allocator.dupeZ(u8, try std.fmt.allocPrint(allocator, "{s}-store.zova", .{args[1]}));
        try zova.createGraphStore(store_path);
        try db.bindGraphStore(store_path);
    }
    try db.createGraph("bench");

    const nodes = try allocator.alloc(zova.GraphNodeInput, node_count);
    for (0..node_count) |index| {
        nodes[index] = .{
            .graph_name = "bench",
            .node_id = try std.fmt.allocPrint(allocator, "n{d}", .{index}),
            .kind = "node",
        };
    }
    try db.putGraphNodes(nodes);

    const inputs = try allocator.alloc(zova.GraphEdgeInput, edges);
    for (0..edges) |index| {
        inputs[index] = .{
            .graph_name = "bench",
            .from_node_id = nodes[index].node_id,
            .to_node_id = nodes[(index * 7 + 3) % node_count].node_id,
            .edge_type = "link",
        };
    }

    var counters: Counters = .{};
    _ = c.sqlite3_trace_v2(db.sqlite_db.handle, c.SQLITE_TRACE_STMT, Counters.callback, &counters);
    defer _ = c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);

    const samples: usize = if (dropped) 20 else 200;
    const timings = try allocator.alloc(f64, samples);

    try db.putGraphEdges(inputs); // warmup
    counters = .{};

    for (0..samples) |index| {
        if (dropped) try dropIndexes(allocator, &db, schema);
        const started = now();
        try db.putGraphEdges(inputs);
        timings[index] = @as(f64, @floatFromInt(ns(started))) / 1_000_000;
    }

    std.debug.print("write edges={d} mode={s} store={s} samples={d} median_ms={d:.6} mad_ms={d:.6} total_ms={d:.6} stmts={d} create_index={d} probe={d}\n", .{
        edges,                                                                                                args[3],        args[4],               samples,        median(timings), mad(timings),
        @as(f64, @floatFromInt(@as(i64, @intFromFloat(median(timings) * @as(f64, @floatFromInt(samples)))))), counters.stmts, counters.create_index, counters.probe,
    });

    const read_samples = try allocator.alloc(f64, 200);
    const read_ops = [_][]const u8{ "neighbors_untyped", "neighbors_typed", "degree", "walk_depth2" };
    for (read_ops) |op| {
        var warmups: usize = 0;
        while (warmups < 20) : (warmups += 1) try runRead(allocator, &db, op);
        for (0..read_samples.len) |index| {
            const t0 = now();
            try runRead(allocator, &db, op);
            read_samples[index] = @as(f64, @floatFromInt(ns(t0))) / 1_000;
        }
        std.debug.print("read op={s} store={s} edges={d} mode={s} p50_us={d:.3} p95_us={d:.3}\n", .{
            op, args[4], edges, args[3], percentile(read_samples, 50.0), percentile(read_samples, 95.0),
        });
    }
}

fn dropIndexes(allocator: std.mem.Allocator, db: *zova.Database, schema: []const u8) !void {
    for (index_names) |name| {
        const sql = try allocator.dupeZ(u8, try std.fmt.allocPrint(allocator, "drop index {s}.{s}", .{ schema, name }));
        try db.sqlite_db.exec(sql);
    }
}

fn runRead(allocator: std.mem.Allocator, db: *zova.Database, op: []const u8) !void {
    if (std.mem.eql(u8, op, "neighbors_untyped")) {
        var result = try db.graphNeighbors(allocator, .{ .graph_name = "bench", .node_id = "n0", .direction = .outgoing, .limit = 32 });
        result.deinit(allocator);
    } else if (std.mem.eql(u8, op, "neighbors_typed")) {
        var result = try db.graphNeighbors(allocator, .{ .graph_name = "bench", .node_id = "n0", .direction = .outgoing, .edge_type = "link", .limit = 32 });
        result.deinit(allocator);
    } else if (std.mem.eql(u8, op, "degree")) {
        _ = try db.graphDegree(.{ .graph_name = "bench", .node_id = "n0", .direction = .outgoing });
    } else {
        var walk = try db.graphWalk(allocator, .{ .graph_name = "bench", .start_node_id = "n0", .max_depth = 2, .limit = 64 });
        walk.deinit(allocator);
    }
}
