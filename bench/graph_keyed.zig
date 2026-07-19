const std = @import("std");
const zova = @import("zova");

const measured_runs = 7;
const read_warmups = 50;
const read_samples = 500;

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
    var source = zova.Database.open(source_path) catch |err| switch (err) {
        error.UnsupportedZovaVersion => return loadFormat8Fixture(allocator, source_path),
        else => return err,
    };
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

fn loadFormat8Fixture(allocator: std.mem.Allocator, source_path: [:0]const u8) !Fixture {
    var source = try zova.sqlite.Database.open(source_path);
    defer source.deinit();
    var graph_names_list: std.ArrayList([]const u8) = .empty;
    var nodes: std.ArrayList(zova.GraphNodeInput) = .empty;
    var edges: std.ArrayList(zova.GraphEdgeInput) = .empty;
    var graphs = try source.prepare("select name from _zova_graphs order by created_order,name");
    defer graphs.deinit();
    while ((try graphs.step()) == .row) try graph_names_list.append(allocator, try allocator.dupe(u8, graphs.columnText(0)));
    const graph_names = try graph_names_list.toOwnedSlice(allocator);
    for (graph_names) |graph_name| {
        var node_rows = try source.prepare(
            \\select n.node_id,n.kind from _zova_graph_nodes n
            \\join _zova_graphs g on g.graph_key=n.graph_key
            \\where g.name=? order by n.created_order,n.node_key
        );
        defer node_rows.deinit();
        try node_rows.bindText(1, graph_name);
        while ((try node_rows.step()) == .row) try nodes.append(allocator, .{
            .graph_name = graph_name,
            .node_id = try allocator.dupe(u8, node_rows.columnText(0)),
            .kind = try allocator.dupe(u8, node_rows.columnText(1)),
        });
        var edge_rows = try source.prepare(
            \\select src.node_id,e.edge_type,dst.node_id from _zova_graph_edges e
            \\join _zova_graphs g on g.graph_key=e.graph_key
            \\join _zova_graph_nodes src on src.graph_key=e.graph_key and src.node_key=e.from_node_key
            \\join _zova_graph_nodes dst on dst.graph_key=e.graph_key and dst.node_key=e.to_node_key
            \\where g.name=? order by e.created_order,e.edge_key
        );
        defer edge_rows.deinit();
        try edge_rows.bindText(1, graph_name);
        while ((try edge_rows.step()) == .row) try edges.append(allocator, .{
            .graph_name = graph_name,
            .from_node_id = try allocator.dupe(u8, edge_rows.columnText(0)),
            .edge_type = try allocator.dupe(u8, edge_rows.columnText(1)),
            .to_node_id = try allocator.dupe(u8, edge_rows.columnText(2)),
        });
    }
    return .{ .graph_names = graph_names, .nodes = try nodes.toOwnedSlice(allocator), .edges = try edges.toOwnedSlice(allocator) };
}

fn graphStorageBytes(db: *zova.Database) !i64 {
    var stmt = try db.prepare(
        \\select coalesce(sum(pgsize),0) from dbstat
        \\where name in (select name from sqlite_master where tbl_name like '_zova_graph%')
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

const FreshBuildSample = struct { total_ms: f64, profile: zova.FreshGraphBuildProfile };

fn runFreshBuildSample(allocator: std.mem.Allocator, fixture: Fixture, label: []const u8, ordinal: usize) !FreshBuildSample {
    if (fixture.graph_names.len != 1) return error.InvalidFixture;
    const graph_name = fixture.graph_names[0];
    const nodes = try allocator.alloc(zova.FreshGraphNodeInput, fixture.nodes.len);
    var ordinals = std.StringHashMap(usize).init(allocator);
    defer ordinals.deinit();
    for (fixture.nodes, nodes, 0..) |node, *fresh, index| {
        fresh.* = .{
            .node_id = node.node_id,
            .kind = node.kind,
            .target_type = node.target_type,
            .target_namespace = node.target_namespace,
            .target_ref = node.target_ref,
        };
        try ordinals.put(node.node_id, index);
    }
    const edges = try allocator.alloc(zova.FreshGraphEdgeInput, fixture.edges.len);
    for (fixture.edges, edges) |edge, *fresh| fresh.* = .{
        .from_node_ordinal = ordinals.get(edge.from_node_id) orelse return error.InvalidFixture,
        .edge_type = edge.edge_type,
        .to_node_ordinal = ordinals.get(edge.to_node_id) orelse return error.InvalidFixture,
    };
    const node_keys = try allocator.alloc(i64, nodes.len);
    const edge_keys = try allocator.alloc(i64, edges.len);
    const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/zova-fresh-build-{s}-{d}.zova", .{ label, ordinal }, 0);
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    var db = try zova.Database.create(path);
    defer db.deinit();
    var profile: zova.FreshGraphBuildProfile = .{};
    const start = now();
    try db.buildFreshGraphKeyedProfiled(graph_name, nodes, edges, node_keys, edge_keys, &profile);
    return .{ .total_ms = elapsedMs(start), .profile = profile };
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

fn p95(comptime count: usize, values: *const [count]f64) f64 {
    var copy = values.*;
    std.mem.sort(f64, &copy, {}, std.sort.asc(f64));
    return copy[(count * 95 + 99) / 100 - 1];
}

const GraphReadP95 = struct {
    typed_neighbors: f64,
    typed_degree: f64,
    typed_walk: f64,
    typed_multi_neighbors: f64,
    high_degree_outgoing: f64,
    high_degree_incoming: f64,
};

fn runGraphReadSuite(db: *zova.Database, allocator: std.mem.Allocator, fixture: Fixture, label: []const u8) !GraphReadP95 {
    const edge = fixture.edges[0];
    var neighbors_samples: [read_samples]f64 = undefined;
    var degree_samples: [read_samples]f64 = undefined;
    var walk_samples: [read_samples]f64 = undefined;
    var multi_samples: [read_samples]f64 = undefined;
    var high_out_samples: [read_samples]f64 = undefined;
    var high_in_samples: [read_samples]f64 = undefined;
    for (0..read_warmups + read_samples) |index| {
        var start = now();
        var neighbors = try db.graphNeighbors(allocator, .{ .graph_name = edge.graph_name, .node_id = edge.from_node_id, .edge_type = edge.edge_type, .limit = 64 });
        neighbors.deinit(allocator);
        if (index >= read_warmups) neighbors_samples[index - read_warmups] = elapsedMs(start);

        start = now();
        std.mem.doNotOptimizeAway(try db.graphDegree(.{ .graph_name = edge.graph_name, .node_id = edge.from_node_id, .edge_type = edge.edge_type }));
        if (index >= read_warmups) degree_samples[index - read_warmups] = elapsedMs(start);

        start = now();
        var walk = try db.graphWalkDirection(allocator, .{ .graph_name = edge.graph_name, .start_node_id = edge.from_node_id, .edge_type = edge.edge_type, .max_depth = 2, .limit = 64 });
        walk.deinit(allocator);
        if (index >= read_warmups) walk_samples[index - read_warmups] = elapsedMs(start);

        start = now();
        for (0..4) |_| {
            var part = try db.graphNeighbors(allocator, .{ .graph_name = edge.graph_name, .node_id = edge.from_node_id, .edge_type = edge.edge_type, .limit = 64 });
            part.deinit(allocator);
        }
        if (index >= read_warmups) multi_samples[index - read_warmups] = elapsedMs(start);

        start = now();
        std.mem.doNotOptimizeAway(try db.graphDegree(.{ .graph_name = "__zova_high_degree", .node_id = "root", .edge_type = "selected" }));
        if (index >= read_warmups) high_out_samples[index - read_warmups] = elapsedMs(start);

        start = now();
        std.mem.doNotOptimizeAway(try db.graphDegree(.{ .graph_name = "__zova_high_degree", .node_id = "sink", .direction = .incoming, .edge_type = "selected" }));
        if (index >= read_warmups) high_in_samples[index - read_warmups] = elapsedMs(start);
    }
    const result: GraphReadP95 = .{
        .typed_neighbors = p95(read_samples, &neighbors_samples),
        .typed_degree = p95(read_samples, &degree_samples),
        .typed_walk = p95(read_samples, &walk_samples),
        .typed_multi_neighbors = p95(read_samples, &multi_samples),
        .high_degree_outgoing = p95(read_samples, &high_out_samples),
        .high_degree_incoming = p95(read_samples, &high_in_samples),
    };
    std.debug.print("graph_read_p95 variant={s} neighbors_ms={d:.6} degree_ms={d:.6} walk_ms={d:.6} multi_neighbors_ms={d:.6} high_out_ms={d:.6} high_in_ms={d:.6}\n", .{ label, result.typed_neighbors, result.typed_degree, result.typed_walk, result.typed_multi_neighbors, result.high_degree_outgoing, result.high_degree_incoming });
    return result;
}

fn installHighDegreeFixture(db: *zova.Database, allocator: std.mem.Allocator) !void {
    const leaf_count = 10_000;
    try db.createGraph("__zova_high_degree");
    var nodes = try allocator.alloc(zova.GraphNodeInput, leaf_count + 2);
    nodes[0] = .{ .graph_name = "__zova_high_degree", .node_id = "root", .kind = "benchmark" };
    nodes[1] = .{ .graph_name = "__zova_high_degree", .node_id = "sink", .kind = "benchmark" };
    const node_ids = try allocator.alloc([]const u8, leaf_count);
    for (node_ids, 0..) |*node_id, index| {
        node_id.* = try std.fmt.allocPrint(allocator, "leaf-{d:0>5}", .{index});
        nodes[index + 2] = .{ .graph_name = "__zova_high_degree", .node_id = node_id.*, .kind = "benchmark" };
    }
    try db.putGraphNodes(nodes);
    var edges = try allocator.alloc(zova.GraphEdgeInput, leaf_count * 2);
    for (node_ids, 0..) |node_id, index| {
        const edge_type: []const u8 = if (index % 4 == 0) "selected" else "other";
        edges[index * 2] = .{ .graph_name = "__zova_high_degree", .from_node_id = "root", .edge_type = edge_type, .to_node_id = node_id };
        edges[index * 2 + 1] = .{ .graph_name = "__zova_high_degree", .from_node_id = node_id, .edge_type = edge_type, .to_node_id = "sink" };
    }
    try db.putGraphEdges(edges);
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
    try installHighDegreeFixture(&db, allocator);

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

    const retained = try runGraphReadSuite(&db, allocator, fixture, "typed-indexes");
    try db.exec("drop index _zova_graph_edges_from_node_type_idx; drop index _zova_graph_edges_to_node_type_idx");
    const consolidated = try runGraphReadSuite(&db, allocator, fixture, "consolidated-indexes");
    inline for (@typeInfo(GraphReadP95).@"struct".fields) |field| {
        const baseline = @field(retained, field.name);
        const candidate = @field(consolidated, field.name);
        std.debug.print("graph_read_ratio metric={s} ratio={d:.6}\n", .{ field.name, candidate / baseline });
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArgument;
    const source_path = try allocator.dupeZ(u8, args[1]);
    const label = args[2];
    const fixture = try loadFixture(allocator, source_path);
    std.debug.print("fixture={s} nodes={d} edges={d}\n", .{ label, fixture.nodes.len, fixture.edges.len });
    _ = try runFreshBuildSample(allocator, fixture, label, 1000);
    var fresh_build_samples: [measured_runs]f64 = undefined;
    for (&fresh_build_samples, 0..) |*sample, index| {
        const result = try runFreshBuildSample(allocator, fixture, label, index);
        sample.* = result.total_ms;
        std.debug.print("fresh_build_sample index={d} total_ms={d:.6} validation_ms={d:.6} index_drop_ms={d:.6} metadata_ms={d:.6} nodes_ms={d:.6} edges_ms={d:.6} indexes_ms={d:.6}\n", .{ index + 1, result.total_ms, result.profile.validation_ms, result.profile.index_drop_ms, result.profile.graph_and_types_ms, result.profile.node_load_ms, result.profile.edge_load_ms, result.profile.index_build_ms });
    }
    std.debug.print("fresh_build_summary median_ms={d:.6} mad_ms={d:.6}\n", .{ median(&fresh_build_samples), mad(&fresh_build_samples) });
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
