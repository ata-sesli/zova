const std = @import("std");
const zova = @import("zova");

const graph_count = 4;
const nodes_per_graph = 6_250;
const edge_fanout = 4;
const vector_count = 10_000;
const vector_dimensions = 384;
const single_warmups = 50;
const single_samples = 500;
const multi_warmups = 20;
const multi_samples = 200;
const seed: u64 = 0x5a6f7661;

const graph_names = [_][]const u8{ "graph-0", "graph-1", "graph-2", "graph-3" };
const edge_types = [_][]const u8{ "calls", "imports", "contains", "related" };
const edge_offsets = [_]usize{ 1, 7, 31, 127 };

const TraceCounter = struct {
    graph_endpoint_stage_steps: usize = 0,
    graph_endpoint_resolution_statements: usize = 0,
    graph_edge_insert_steps: usize = 0,
    resolver_seen: bool = false,
};

fn traceCallback(mask: c_uint, context: ?*anyopaque, _: ?*anyopaque, sql_pointer: ?*anyopaque) callconv(.c) c_int {
    if (mask == zova.sqlite.c.SQLITE_TRACE_STMT and context != null and sql_pointer != null) {
        const counter: *TraceCounter = @ptrCast(@alignCast(context.?));
        const sql: [*:0]const u8 = @ptrCast(sql_pointer.?);
        const sql_slice = std.mem.span(sql);
        if (std.mem.indexOf(u8, sql_slice, "zova_graph_endpoint_stage") != null) {
            counter.graph_endpoint_stage_steps += 1;
        } else if (std.mem.indexOf(u8, sql_slice, "zova_graph_batch_slot_resolve") != null or
            std.mem.indexOf(u8, sql_slice, "zova_graph_batch_resolve") != null)
        {
            if (!counter.resolver_seen) {
                counter.resolver_seen = true;
                counter.graph_endpoint_resolution_statements += 1;
            }
        } else if (std.mem.indexOf(u8, sql_slice, "zova_graph_edge_insert") != null) {
            counter.graph_edge_insert_steps += 1;
        }
    }
    return 0;
}

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const ns = start.durationTo(now()).toNanoseconds();
    return if (ns <= 0) 0 else @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

fn percentile(samples: []f64, numerator: usize, denominator: usize) f64 {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    const index = @min(samples.len - 1, (samples.len * numerator + denominator - 1) / denominator - 1);
    return samples[index];
}

fn printDistribution(label: []const u8, samples: []f64) void {
    const p50 = percentile(samples, 50, 100);
    const p95 = percentile(samples, 95, 100);
    std.debug.print("{s} p50_ms={d:.6} p95_ms={d:.6}\n", .{ label, p50, p95 });
}

fn nextRandom(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.*;
}

fn fillVectors(flat: []i8) void {
    var state = seed;
    for (flat) |*value| {
        const raw: u8 = @truncate(nextRandom(&state) >> 32);
        value.* = @as(i8, @bitCast(raw | 1));
    }
}

fn runNativeSearch(db: *zova.Database, query: []const i8, limit: usize) !void {
    var results = try db.searchVectors(std.heap.c_allocator, "vectors-a", .{ .i8 = query }, limit);
    results.deinit(std.heap.c_allocator);
}

fn runNativeMultiSearch(db: *zova.Database, queries: []const []const i8, limit: usize) !void {
    var results = try db.searchMultiI8Cosine(std.heap.c_allocator, "vectors-a", .{ .queries = queries }, limit);
    results.deinit(std.heap.c_allocator);
}

fn runCompatibilitySearch(db: *zova.Database, query: []const i8, limit: usize) !void {
    var stmt = try db.prepare("select values_blob from compatibility_vectors where collection_name='vectors-a'");
    defer stmt.deinit();
    var retained = try std.heap.c_allocator.alloc(f64, limit);
    defer std.heap.c_allocator.free(retained);
    var retained_len: usize = 0;
    while ((try stmt.step()) == .row) {
        const values = stmt.columnBlob(0);
        if (values.len != query.len) return error.VectorCorrupt;
        var dot: i64 = 0;
        var query_norm: u64 = 0;
        var stored_norm: u64 = 0;
        for (query, values) |query_value, stored_byte| {
            const q: i32 = query_value;
            const s: i32 = @as(i8, @bitCast(stored_byte));
            dot += @as(i64, q) * @as(i64, s);
            query_norm += @intCast(q * q);
            stored_norm += @intCast(s * s);
        }
        const distance = 1.0 - @as(f64, @floatFromInt(dot)) /
            (@sqrt(@as(f64, @floatFromInt(query_norm))) * @sqrt(@as(f64, @floatFromInt(stored_norm))));
        if (retained_len < limit) {
            retained[retained_len] = distance;
            retained_len += 1;
        } else {
            var worst: usize = 0;
            for (retained[1..], 1..) |candidate, index| if (candidate > retained[worst]) {
                worst = index;
            };
            if (distance < retained[worst]) retained[worst] = distance;
        }
    }
    std.mem.doNotOptimizeAway(retained_len);
}

fn reportStorage(db: *zova.Database) !void {
    var objects = try db.prepare(
        \\select name, sum(pgsize)
        \\from dbstat
        \\where name like '_zova_graph%' or name like '_zova_vector%'
        \\group by name order by name
    );
    defer objects.deinit();
    while ((try objects.step()) == .row) {
        std.debug.print("storage_object name={s} bytes={d}\n", .{ objects.columnText(0), objects.columnInt64(1) });
    }

    var stmt = try db.prepare(
        \\select case
        \\  when name like '_zova_graph%' then 'graph'
        \\  when name like '_zova_vector%' then 'vector'
        \\end as family, sum(pgsize)
        \\from dbstat
        \\where name like '_zova_graph%' or name like '_zova_vector%'
        \\group by family order by family
    );
    defer stmt.deinit();
    while ((try stmt.step()) == .row) {
        const family = stmt.columnText(0);
        const bytes = stmt.columnInt64(1);
        if (std.mem.eql(u8, family, "graph")) {
            std.debug.print("graph_storage_bytes={d} graph_bytes_per_edge={d:.6}\n", .{ bytes, @as(f64, @floatFromInt(bytes)) / 100_000.0 });
        } else {
            std.debug.print("vector_storage_bytes={d} vector_bytes_per_row={d:.6}\n", .{ bytes, @as(f64, @floatFromInt(bytes)) / 20_000.0 });
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArgument;
    const db_path = try allocator.dupeZ(u8, args[1]);
    std.Io.Dir.cwd().deleteFile(init.io, db_path) catch {};

    std.debug.print("seed=0x{x} zig={s} sqlite={s} format={s}\n", .{ seed, @import("builtin").zig_version_string, zova.version.sqlite_version, zova.version.format_version });
    var db = try zova.Database.create(db_path);
    defer db.deinit();

    var node_ids = try allocator.alloc([]u8, graph_count * nodes_per_graph);
    var node_inputs = try allocator.alloc(zova.GraphNodeInput, node_ids.len);
    for (graph_names, 0..) |graph_name, graph_index| {
        try db.createGraph(graph_name);
        for (0..nodes_per_graph) |node_index| {
            const flat_index = graph_index * nodes_per_graph + node_index;
            node_ids[flat_index] = try std.fmt.allocPrint(allocator, "node-{d:0>5}", .{node_index});
            node_inputs[flat_index] = .{ .graph_name = graph_name, .node_id = node_ids[flat_index], .kind = "benchmark" };
        }
    }
    try db.putGraphNodes(node_inputs);

    var edges = try allocator.alloc(zova.GraphEdgeInput, graph_count * nodes_per_graph * edge_fanout);
    var edge_index: usize = 0;
    for (graph_names, 0..) |graph_name, graph_index| {
        const graph_nodes = node_ids[graph_index * nodes_per_graph ..][0..nodes_per_graph];
        for (0..nodes_per_graph) |from_index| {
            for (edge_offsets, 0..) |offset, type_index| {
                edges[edge_index] = .{
                    .graph_name = graph_name,
                    .from_node_id = graph_nodes[from_index],
                    .edge_type = edge_types[type_index],
                    .to_node_id = graph_nodes[(from_index + offset) % nodes_per_graph],
                };
                edge_index += 1;
            }
        }
    }
    var trace_counter: TraceCounter = .{};
    _ = zova.sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, zova.sqlite.c.SQLITE_TRACE_STMT, traceCallback, &trace_counter);
    const graph_put_start = now();
    try db.putGraphEdges(edges);
    const graph_put_ms = elapsedMs(graph_put_start);
    _ = zova.sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);
    std.debug.print(
        "graph_put_many_ms={d:.6} graph_endpoint_stage_steps={d} graph_endpoint_resolution_statements={d} graph_edge_insert_steps={d}\n",
        .{
            graph_put_ms,
            trace_counter.graph_endpoint_stage_steps,
            trace_counter.graph_endpoint_resolution_statements,
            trace_counter.graph_edge_insert_steps,
        },
    );

    var graph_samples: [single_samples]f64 = undefined;
    const root_id = node_ids[0];
    for (0..single_warmups + single_samples) |index| {
        const start = now();
        var neighbors = try db.graphNeighbors(std.heap.c_allocator, .{ .graph_name = graph_names[index % graph_count], .node_id = root_id, .limit = 64 });
        neighbors.deinit(std.heap.c_allocator);
        if (index >= single_warmups) graph_samples[index - single_warmups] = elapsedMs(start);
    }
    printDistribution("graph_neighbors", &graph_samples);

    for (0..single_warmups + single_samples) |index| {
        const start = now();
        std.mem.doNotOptimizeAway(try db.graphDegree(.{
            .graph_name = graph_names[index % graph_count],
            .node_id = root_id,
            .direction = .outgoing,
        }));
        if (index >= single_warmups) graph_samples[index - single_warmups] = elapsedMs(start);
    }
    printDistribution("graph_degree", &graph_samples);

    for (0..single_warmups + single_samples) |index| {
        const start = now();
        var walk = try db.graphWalkDirection(std.heap.c_allocator, .{
            .graph_name = graph_names[index % graph_count],
            .start_node_id = root_id,
            .direction = .outgoing,
            .max_depth = 2,
            .limit = 64,
        });
        walk.deinit(std.heap.c_allocator);
        if (index >= single_warmups) graph_samples[index - single_warmups] = elapsedMs(start);
    }
    printDistribution("graph_walk", &graph_samples);

    var graph_multi_samples: [multi_samples]f64 = undefined;
    for (0..multi_warmups + multi_samples) |index| {
        const start = now();
        for (graph_names) |graph_name| {
            var neighbors = try db.graphNeighbors(std.heap.c_allocator, .{ .graph_name = graph_name, .node_id = root_id, .limit = 64 });
            neighbors.deinit(std.heap.c_allocator);
        }
        if (index >= multi_warmups) graph_multi_samples[index - multi_warmups] = elapsedMs(start);
    }
    printDistribution("graph_multi_neighbors", &graph_multi_samples);

    for (0..single_warmups + single_samples) |index| {
        const start = now();
        var neighbors = try db.graphNeighbors(std.heap.c_allocator, .{ .graph_name = graph_names[index % graph_count], .node_id = root_id, .edge_type = edge_types[0], .limit = 64 });
        neighbors.deinit(std.heap.c_allocator);
        if (index >= single_warmups) graph_samples[index - single_warmups] = elapsedMs(start);
    }
    printDistribution("graph_typed_neighbors", &graph_samples);

    for (0..single_warmups + single_samples) |index| {
        const start = now();
        std.mem.doNotOptimizeAway(try db.graphDegree(.{ .graph_name = graph_names[index % graph_count], .node_id = root_id, .edge_type = edge_types[0] }));
        if (index >= single_warmups) graph_samples[index - single_warmups] = elapsedMs(start);
    }
    printDistribution("graph_typed_degree", &graph_samples);

    for (0..single_warmups + single_samples) |index| {
        const start = now();
        var walk = try db.graphWalkDirection(std.heap.c_allocator, .{ .graph_name = graph_names[index % graph_count], .start_node_id = root_id, .edge_type = edge_types[0], .max_depth = 2, .limit = 64 });
        walk.deinit(std.heap.c_allocator);
        if (index >= single_warmups) graph_samples[index - single_warmups] = elapsedMs(start);
    }
    printDistribution("graph_typed_walk", &graph_samples);

    for (0..multi_warmups + multi_samples) |index| {
        const start = now();
        for (graph_names) |graph_name| {
            var neighbors = try db.graphNeighbors(std.heap.c_allocator, .{ .graph_name = graph_name, .node_id = root_id, .edge_type = edge_types[0], .limit = 64 });
            neighbors.deinit(std.heap.c_allocator);
        }
        if (index >= multi_warmups) graph_multi_samples[index - multi_warmups] = elapsedMs(start);
    }
    printDistribution("graph_typed_multi_neighbors", &graph_multi_samples);

    const flat_values = try allocator.alloc(i8, vector_count * vector_dimensions);
    fillVectors(flat_values);
    var vector_inputs = try allocator.alloc(zova.VectorInput, vector_count);
    for (0..vector_count) |index| vector_inputs[index] = .{
        .id = try std.fmt.allocPrint(allocator, "vector-{d:0>5}", .{index}),
        .values = .{ .i8 = flat_values[index * vector_dimensions ..][0..vector_dimensions] },
    };
    try db.createVectorCollection("vectors-a", .{ .dimensions = vector_dimensions, .metric = .cosine, .element_type = .i8 });
    try db.createVectorCollection("vectors-b", .{ .dimensions = vector_dimensions, .metric = .cosine, .element_type = .i8 });
    const vector_put_start = now();
    try db.putVectors("vectors-a", vector_inputs);
    try db.putVectors("vectors-b", vector_inputs);
    std.debug.print("vector_put_many_ms={d:.6}\n", .{elapsedMs(vector_put_start)});

    try db.exec("create table compatibility_vectors (collection_name text not null, vector_id text not null, values_blob blob not null, primary key(collection_name,vector_id))");
    var compat_insert = try db.prepare("insert into compatibility_vectors values ('vectors-a', ?, ?)");
    defer compat_insert.deinit();
    for (vector_inputs) |input| {
        try compat_insert.bindText(1, input.id);
        try compat_insert.bindBlob(2, std.mem.sliceAsBytes(input.values.i8));
        std.debug.assert((try compat_insert.step()) == .done);
        try compat_insert.reset();
        try compat_insert.clearBindings();
    }

    const limits = [_]usize{ 1, 10, 32, 100, 1000 };
    var samples: [single_samples]f64 = undefined;
    const query = flat_values[0..vector_dimensions];
    for (limits) |limit| {
        for (0..single_warmups + single_samples) |index| {
            const start = now();
            try runNativeSearch(&db, query, limit);
            if (index >= single_warmups) samples[index - single_warmups] = elapsedMs(start);
        }
        var label_buffer: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buffer, "vector_native_limit_{d}", .{limit});
        printDistribution(label, &samples);
    }

    for (0..single_warmups + single_samples) |index| {
        const start = now();
        try runCompatibilitySearch(&db, query, 10);
        if (index >= single_warmups) samples[index - single_warmups] = elapsedMs(start);
    }
    printDistribution("vector_compatibility_limit_10", &samples);

    const queries = [_][]const i8{
        flat_values[0..vector_dimensions],
        flat_values[vector_dimensions..][0..vector_dimensions],
        flat_values[vector_dimensions * 2 ..][0..vector_dimensions],
        flat_values[vector_dimensions * 3 ..][0..vector_dimensions],
    };
    var multi_timings: [multi_samples]f64 = undefined;
    for (0..multi_warmups + multi_samples) |index| {
        const start = now();
        try runNativeMultiSearch(&db, &queries, 10);
        if (index >= multi_warmups) multi_timings[index - multi_warmups] = elapsedMs(start);
    }
    printDistribution("vector_multi_limit_10", &multi_timings);
    try reportStorage(&db);
}
