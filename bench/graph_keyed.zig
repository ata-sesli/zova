const std = @import("std");
const zova = @import("zova");

const measured_runs = 7;

const Variant = enum { current, keyed };

const TraceCounter = struct {
    endpoint_stage_steps: usize = 0,
    resolver_statements: usize = 0,
    edge_insert_steps: usize = 0,
    resolver_seen: bool = false,
};

const Sample = struct {
    node_fresh_ms: f64,
    node_replay_ms: f64,
    edge_fresh_ms: f64,
    edge_replay_ms: f64,
    fresh_trace: TraceCounter,
    replay_trace: TraceCounter,
    graph_storage_bytes: i64,
};

const Fixture = struct {
    graph_names: [][]const u8,
    nodes: []zova.GraphNodeInput,
    edges: []zova.GraphEdgeInput,
};

fn traceCallback(mask: c_uint, context: ?*anyopaque, _: ?*anyopaque, sql_pointer: ?*anyopaque) callconv(.c) c_int {
    if (mask != zova.sqlite.c.SQLITE_TRACE_STMT or context == null or sql_pointer == null) return 0;
    const counter: *TraceCounter = @ptrCast(@alignCast(context.?));
    const sql: [*:0]const u8 = @ptrCast(sql_pointer.?);
    const text = std.mem.span(sql);
    if (std.mem.indexOf(u8, text, "zova_graph_endpoint_stage") != null) {
        counter.endpoint_stage_steps += 1;
    } else if (std.mem.indexOf(u8, text, "zova_graph_batch_slot_resolve") != null or
        std.mem.indexOf(u8, text, "zova_graph_batch_resolve") != null)
    {
        if (!counter.resolver_seen) {
            counter.resolver_seen = true;
            counter.resolver_statements += 1;
        }
    } else if (std.mem.indexOf(u8, text, "zova_graph_edge_insert") != null) {
        counter.edge_insert_steps += 1;
    }
    return 0;
}

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const nanoseconds = start.durationTo(now()).toNanoseconds();
    return if (nanoseconds <= 0) 0 else @as(f64, @floatFromInt(nanoseconds)) / @as(f64, std.time.ns_per_ms);
}

fn loadFixture(allocator: std.mem.Allocator, source_path: [:0]const u8) !Fixture {
    var source = try zova.Database.open(source_path);
    defer source.deinit();
    var graphs = try source.listGraphs(allocator);
    defer graphs.deinit(allocator);

    const graph_names = try allocator.alloc([]const u8, graphs.items.len);
    var nodes: std.ArrayList(zova.GraphNodeInput) = .empty;
    var edges: std.ArrayList(zova.GraphEdgeInput) = .empty;
    var node_ids = std.AutoHashMap(i64, []const u8).init(allocator);
    defer node_ids.deinit();

    for (graphs.items, 0..) |info, graph_index| {
        const graph_name = try allocator.dupe(u8, info.name);
        graph_names[graph_index] = graph_name;
        var scan = try source.graphScan(allocator, .{
            .graph_name = info.name,
            .node_limit = @intCast(info.node_count),
            .edge_limit = @intCast(info.edge_count),
        });
        defer scan.deinit(allocator);
        for (scan.nodes) |node| {
            const node_id = try allocator.dupe(u8, node.node_id);
            try node_ids.put(node.node_key, node_id);
            try nodes.append(allocator, .{
                .graph_name = graph_name,
                .node_id = node_id,
                .kind = try allocator.dupe(u8, node.kind),
            });
        }
        for (scan.edges) |edge| {
            try edges.append(allocator, .{
                .graph_name = graph_name,
                .from_node_id = node_ids.get(edge.source_node_key) orelse return error.InvalidFixture,
                .edge_type = try allocator.dupe(u8, edge.edge_type),
                .to_node_id = node_ids.get(edge.target_node_key) orelse return error.InvalidFixture,
            });
        }
    }
    return .{
        .graph_names = graph_names,
        .nodes = try nodes.toOwnedSlice(allocator),
        .edges = try edges.toOwnedSlice(allocator),
    };
}

fn graphStorageBytes(db: *zova.Database) !i64 {
    var stmt = try db.prepare(
        \\select coalesce(sum(pgsize),0) from dbstat
        \\where name in (
        \\ '_zova_graphs','_zova_graph_nodes','_zova_graph_edges',
        \\ '_zova_graphs_name','_zova_graph_nodes_1','_zova_graph_nodes_2',
        \\ '_zova_graph_nodes_created_order_idx','_zova_graph_edges_1',
        \\ '_zova_graph_edges_created_order_idx','_zova_graph_edges_from_node_idx',
        \\ '_zova_graph_edges_from_node_type_idx','_zova_graph_edges_to_node_idx',
        \\ '_zova_graph_edges_to_node_type_idx')
    );
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.InvalidFixture;
    return stmt.columnInt64(0);
}

fn runSample(
    allocator: std.mem.Allocator,
    fixture: Fixture,
    variant: Variant,
    label: []const u8,
    ordinal: usize,
) !Sample {
    const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/zova-keyed-{s}-{s}-{d}.zova", .{ label, @tagName(variant), ordinal }, 0);
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    var db = try zova.Database.create(path);
    defer db.deinit();
    for (fixture.graph_names) |graph_name| try db.createGraph(graph_name);
    const node_keys = try allocator.alloc(i64, fixture.nodes.len);
    const edge_keys = try allocator.alloc(i64, fixture.edges.len);

    var start = now();
    switch (variant) {
        .current => try db.putGraphNodes(fixture.nodes),
        .keyed => try db.putGraphNodesKeyed(fixture.nodes, node_keys),
    }
    const node_fresh_ms = elapsedMs(start);
    start = now();
    switch (variant) {
        .current => try db.putGraphNodes(fixture.nodes),
        .keyed => try db.putGraphNodesKeyed(fixture.nodes, node_keys),
    }
    const node_replay_ms = elapsedMs(start);

    var fresh_trace: TraceCounter = .{};
    _ = zova.sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, zova.sqlite.c.SQLITE_TRACE_STMT, traceCallback, &fresh_trace);
    start = now();
    switch (variant) {
        .current => try db.putGraphEdges(fixture.edges),
        .keyed => try db.putGraphEdgesKeyed(fixture.edges, edge_keys),
    }
    const edge_fresh_ms = elapsedMs(start);
    _ = zova.sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);

    var replay_trace: TraceCounter = .{};
    _ = zova.sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, zova.sqlite.c.SQLITE_TRACE_STMT, traceCallback, &replay_trace);
    start = now();
    switch (variant) {
        .current => try db.putGraphEdges(fixture.edges),
        .keyed => try db.putGraphEdgesKeyed(fixture.edges, edge_keys),
    }
    const edge_replay_ms = elapsedMs(start);
    _ = zova.sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);

    return .{
        .node_fresh_ms = node_fresh_ms,
        .node_replay_ms = node_replay_ms,
        .edge_fresh_ms = edge_fresh_ms,
        .edge_replay_ms = edge_replay_ms,
        .fresh_trace = fresh_trace,
        .replay_trace = replay_trace,
        .graph_storage_bytes = try graphStorageBytes(&db),
    };
}

fn median(values: []const f64) f64 {
    var copy: [measured_runs]f64 = undefined;
    @memcpy(&copy, values);
    std.mem.sort(f64, &copy, {}, std.sort.asc(f64));
    return copy[measured_runs / 2];
}

fn mad(values: []const f64) f64 {
    const center = median(values);
    var deviations: [measured_runs]f64 = undefined;
    for (values, &deviations) |value, *deviation| deviation.* = @abs(value - center);
    return median(&deviations);
}

fn reportMetric(label: []const u8, current: []const f64, keyed: []const f64) void {
    const current_median = median(current);
    const keyed_median = median(keyed);
    std.debug.print(
        "summary metric={s} current_median_ms={d:.6} current_mad_ms={d:.6} keyed_median_ms={d:.6} keyed_mad_ms={d:.6} ratio={d:.6}\n",
        .{ label, current_median, mad(current), keyed_median, mad(keyed), keyed_median / current_median },
    );
}

fn runKeyedReadBenchmark(allocator: std.mem.Allocator, fixture: Fixture, label: []const u8) !void {
    if (fixture.graph_names.len != 1) return error.InvalidFixture;
    const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/zova-keyed-read-{s}.zova", .{label}, 0);
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    var db = try zova.Database.create(path);
    defer db.deinit();
    try db.createGraph(fixture.graph_names[0]);
    const node_keys = try allocator.alloc(i64, fixture.nodes.len);
    const edge_keys = try allocator.alloc(i64, fixture.edges.len);
    try db.putGraphNodesKeyed(fixture.nodes, node_keys);
    try db.putGraphEdgesKeyed(fixture.edges, edge_keys);

    var warm_nodes = try db.graphNodesGetManyKeyed(allocator, fixture.graph_names[0], node_keys);
    warm_nodes.deinit(allocator);
    var warm_edges = try db.graphEdgesGetManyKeyed(allocator, fixture.graph_names[0], edge_keys);
    warm_edges.deinit(allocator);
    var node_samples: [measured_runs]f64 = undefined;
    var edge_samples: [measured_runs]f64 = undefined;
    for (0..measured_runs) |index| {
        var start = now();
        var nodes = try db.graphNodesGetManyKeyed(allocator, fixture.graph_names[0], node_keys);
        node_samples[index] = elapsedMs(start);
        nodes.deinit(allocator);
        start = now();
        var edges = try db.graphEdgesGetManyKeyed(allocator, fixture.graph_names[0], edge_keys);
        edge_samples[index] = elapsedMs(start);
        edges.deinit(allocator);
        std.debug.print("read_sample index={d} nodes={d} node_ms={d:.6} edges={d} edge_ms={d:.6}\n", .{ index + 1, node_keys.len, node_samples[index], edge_keys.len, edge_samples[index] });
    }
    std.debug.print("read_summary nodes={d} median_ms={d:.6} mad_ms={d:.6} edges={d} median_ms={d:.6} mad_ms={d:.6}\n", .{ node_keys.len, median(&node_samples), mad(&node_samples), edge_keys.len, median(&edge_samples), mad(&edge_samples) });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArgument;
    const source_path = try allocator.dupeZ(u8, args[1]);
    const label = args[2];
    const fixture = try loadFixture(allocator, source_path);
    std.debug.print("fixture={s} nodes={d} edges={d}\n", .{ label, fixture.nodes.len, fixture.edges.len });
    try runKeyedReadBenchmark(allocator, fixture, label);

    _ = try runSample(allocator, fixture, .current, label, 1000);
    _ = try runSample(allocator, fixture, .keyed, label, 1001);
    const order = [_]Variant{ .current, .keyed, .keyed, .current, .current, .keyed, .keyed, .current, .current, .keyed, .keyed, .current, .current, .keyed };
    var current: [measured_runs]Sample = undefined;
    var keyed: [measured_runs]Sample = undefined;
    var current_len: usize = 0;
    var keyed_len: usize = 0;
    for (order, 0..) |variant, ordinal| {
        const sample = try runSample(allocator, fixture, variant, label, ordinal);
        const sample_index = if (variant == .current) index: {
            defer current_len += 1;
            current[current_len] = sample;
            break :index current_len;
        } else index: {
            defer keyed_len += 1;
            keyed[keyed_len] = sample;
            break :index keyed_len;
        };
        std.debug.print(
            "sample variant={s} index={d} node_fresh_ms={d:.6} node_replay_ms={d:.6} edge_fresh_ms={d:.6} edge_replay_ms={d:.6} fresh_counters={d}/{d}/{d} replay_counters={d}/{d}/{d} graph_storage_bytes={d}\n",
            .{ @tagName(variant), sample_index + 1, sample.node_fresh_ms, sample.node_replay_ms, sample.edge_fresh_ms, sample.edge_replay_ms, sample.fresh_trace.endpoint_stage_steps, sample.fresh_trace.resolver_statements, sample.fresh_trace.edge_insert_steps, sample.replay_trace.endpoint_stage_steps, sample.replay_trace.resolver_statements, sample.replay_trace.edge_insert_steps, sample.graph_storage_bytes },
        );
    }

    inline for (.{ "node_fresh", "node_replay", "edge_fresh", "edge_replay" }, 0..) |metric, metric_index| {
        var current_values: [measured_runs]f64 = undefined;
        var keyed_values: [measured_runs]f64 = undefined;
        for (current, keyed, 0..) |current_sample, keyed_sample, index| {
            current_values[index] = switch (metric_index) {
                0 => current_sample.node_fresh_ms,
                1 => current_sample.node_replay_ms,
                2 => current_sample.edge_fresh_ms,
                3 => current_sample.edge_replay_ms,
                else => unreachable,
            };
            keyed_values[index] = switch (metric_index) {
                0 => keyed_sample.node_fresh_ms,
                1 => keyed_sample.node_replay_ms,
                2 => keyed_sample.edge_fresh_ms,
                3 => keyed_sample.edge_replay_ms,
                else => unreachable,
            };
        }
        reportMetric(metric, &current_values, &keyed_values);
    }
}
