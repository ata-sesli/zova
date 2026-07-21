const std = @import("std");
const api = @import("zova_c");

const batch_rows: usize = 256;
const vector_dimensions: usize = 384;

const FixtureSize = struct {
    name: []const u8,
    node_count: usize,
    edge_count: usize,
    node_vector_count: usize,
    token_vector_count: usize,
};

const tops = FixtureSize{ .name = "tops", .node_count = 2_332, .edge_count = 10_354, .node_vector_count = 1_451, .token_vector_count = 1_540 };
const deno = FixtureSize{ .name = "deno", .node_count = 124_818, .edge_count = 481_770, .node_vector_count = 124_818, .token_vector_count = 62_409 };

const Stage = enum {
    graph,
    metadata,
    fts,
    node_vectors,
    token_vectors,
};

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const ns = start.durationTo(now()).toNanoseconds();
    return if (ns <= 0) 0 else @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

fn requireOk(status: api.zova_status) !void {
    if (status != .OK) return error.ZovaCallFailed;
}

fn freshInt(value: i64) api.zova_fresh_value {
    return .{ .value_type = 1, .int64_value = value, .float64_value = 0, .bytes = null, .bytes_len = 0 };
}

fn freshText(value: []const u8) api.zova_fresh_value {
    return .{ .value_type = 3, .int64_value = 0, .float64_value = 0, .bytes = value.ptr, .bytes_len = value.len };
}

const Fixture = struct {
    nodes: []api.zova_graph_fresh_node_input,
    edges: []api.zova_graph_fresh_edge_payload_input,
};

fn makeFixture(allocator: std.mem.Allocator, size: FixtureSize) !Fixture {
    const nodes = try allocator.alloc(api.zova_graph_fresh_node_input, size.node_count);
    for (nodes, 0..) |*node, index| {
        const id = try std.fmt.allocPrintSentinel(allocator, "node-{d}", .{index}, 0);
        node.* = .{ .node_id = id.ptr, .kind = "symbol", .target_type = 0, .target_namespace = null, .target_ref = null };
    }
    const edge_types = [_][*:0]const u8{ "calls", "imports", "contains", "references" };
    const edges = try allocator.alloc(api.zova_graph_fresh_edge_payload_input, size.edge_count);
    for (edges, 0..) |*edge, index| {
        const from = index % size.node_count;
        const round = index / size.node_count;
        edge.* = .{
            .from_node_ordinal = from,
            .edge_type = edge_types[index % edge_types.len],
            .to_node_ordinal = (from + 1 + round * 97) % size.node_count,
            .payload = null,
            .payload_len = 0,
        };
    }
    return .{ .nodes = nodes, .edges = edges };
}

fn loadMetadata(allocator: std.mem.Allocator, build: ?*api.zova_fresh_build, node_keys: []const i64) !void {
    const columns = [_]?[*:0]const u8{ "id", "node_key", "body" };
    const values = try allocator.alloc(api.zova_fresh_value, batch_rows * columns.len);
    var offset: usize = 0;
    while (offset < node_keys.len) {
        const count = @min(batch_rows, node_keys.len - offset);
        for (0..count) |row| {
            const index = offset + row;
            const body = try std.fmt.allocPrint(allocator, "symbol body {d}", .{index});
            values[row * columns.len] = freshInt(@intCast(index + 1));
            values[row * columns.len + 1] = freshInt(node_keys[index]);
            values[row * columns.len + 2] = freshText(body);
        }
        try requireOk(api.zova_fresh_build_table_rows(&.{
            .build = build,
            .table_name = "records",
            .column_names = &columns,
            .column_count = columns.len,
            .values = values.ptr,
            .row_count = count,
        }));
        offset += count;
    }
}

fn loadFts(allocator: std.mem.Allocator, build: ?*api.zova_fresh_build, node_keys: []const i64) !void {
    const columns = [_]?[*:0]const u8{ "rowid", "body" };
    const values = try allocator.alloc(api.zova_fresh_value, batch_rows * columns.len);
    var offset: usize = 0;
    while (offset < node_keys.len) {
        const count = @min(batch_rows, node_keys.len - offset);
        for (0..count) |row| {
            const index = offset + row;
            const body = try std.fmt.allocPrint(allocator, "symbol searchable body {d}", .{index});
            values[row * columns.len] = freshInt(node_keys[index]);
            values[row * columns.len + 1] = freshText(body);
        }
        try requireOk(api.zova_fresh_build_fts_rows(&.{
            .build = build,
            .table_name = "records_fts",
            .column_names = &columns,
            .column_count = columns.len,
            .values = values.ptr,
            .row_count = count,
        }));
        offset += count;
    }
}

fn loadVectors(
    allocator: std.mem.Allocator,
    build: ?*api.zova_fresh_build,
    collection: [*:0]const u8,
    prefix: []const u8,
    count: usize,
) !void {
    const vector_values = try allocator.alloc(i8, vector_dimensions);
    for (vector_values, 0..) |*value, index| value.* = @intCast(@as(i16, @intCast(index % 127)) - 63);
    const vectors = try allocator.alloc(api.zova_vector_input, batch_rows);
    var offset: usize = 0;
    while (offset < count) {
        const row_count = @min(batch_rows, count - offset);
        for (vectors[0..row_count], 0..) |*vector, row| {
            const id = try std.fmt.allocPrintSentinel(allocator, "{s}-{d}", .{ prefix, offset + row }, 0);
            vector.* = .{
                .id = id.ptr,
                .values = .{ .element_type = 2, .f32_values = null, .f16_values = null, .i8_values = vector_values.ptr, .values_len = vector_values.len },
            };
        }
        try requireOk(api.zova_fresh_build_vectors(&.{ .build = build, .collection_name = collection, .vectors = vectors.ptr, .vectors_len = row_count }));
        offset += row_count;
    }
}

fn runStage(
    allocator: std.mem.Allocator,
    size: FixtureSize,
    fixture: Fixture,
    stage: Stage,
    policy: api.FreshBuildCachePolicy,
    ordinal: usize,
) !void {
    api.setFreshBuildCachePolicyForBenchmark(policy);
    const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/zova-fresh-ablation-{s}-{s}-{s}-{d}.zova", .{ size.name, @tagName(stage), @tagName(policy), ordinal }, 0);
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

    const total_start = now();
    var db: ?*api.zova_database = null;
    try requireOk(api.zova_database_create(&.{ .path = path.ptr, .out_db = &db, .out_error_message = null }));
    defer _ = api.zova_database_close(db);
    try requireOk(api.zova_database_begin(&.{ .db = db }));
    if (@intFromEnum(stage) >= @intFromEnum(Stage.metadata)) try requireOk(api.zova_database_exec(&.{
        .db = db,
        .sql = "create table records(id integer primary key,node_key integer not null,body text not null); create index records_node_idx on records(node_key); create index records_body_idx on records(body)",
    }));
    if (@intFromEnum(stage) >= @intFromEnum(Stage.fts)) try requireOk(api.zova_database_exec(&.{ .db = db, .sql = "create virtual table records_fts using fts5(body)" }));
    if (@intFromEnum(stage) >= @intFromEnum(Stage.node_vectors)) try requireOk(api.zova_vector_collection_create(&.{
        .db = db,
        .name = "node_vectors",
        .options = .{ .dimensions = vector_dimensions, .metric = 0, .element_type = 2 },
    }));
    if (@intFromEnum(stage) >= @intFromEnum(Stage.token_vectors)) try requireOk(api.zova_vector_collection_create(&.{
        .db = db,
        .name = "token_vectors",
        .options = .{ .dimensions = vector_dimensions, .metric = 0, .element_type = 2 },
    }));

    var build: ?*api.zova_fresh_build = null;
    try requireOk(api.zova_fresh_build_begin(&.{ .db = db, .out_build = &build }));
    defer api.zova_fresh_build_destroy(build);
    const node_keys = try allocator.alloc(i64, fixture.nodes.len);
    const edge_keys = try allocator.alloc(i64, fixture.edges.len);

    const graph_start = now();
    try requireOk(api.zova_fresh_build_graph(&.{
        .build = build,
        .graph_name = "benchmark",
        .nodes = fixture.nodes.ptr,
        .nodes_len = fixture.nodes.len,
        .edges = fixture.edges.ptr,
        .edges_len = fixture.edges.len,
        .out_node_keys = node_keys.ptr,
        .out_node_keys_capacity = node_keys.len,
        .out_edge_keys = edge_keys.ptr,
        .out_edge_keys_capacity = edge_keys.len,
    }));
    const graph_ms = elapsedMs(graph_start);

    var metadata_ms: f64 = 0;
    var fts_ms: f64 = 0;
    var node_vector_ms: f64 = 0;
    var token_vector_ms: f64 = 0;
    if (@intFromEnum(stage) >= @intFromEnum(Stage.metadata)) {
        const start = now();
        try loadMetadata(allocator, build, node_keys);
        metadata_ms = elapsedMs(start);
    }
    if (@intFromEnum(stage) >= @intFromEnum(Stage.fts)) {
        const start = now();
        try loadFts(allocator, build, node_keys);
        fts_ms = elapsedMs(start);
    }
    if (@intFromEnum(stage) >= @intFromEnum(Stage.node_vectors)) {
        const start = now();
        try loadVectors(allocator, build, "node_vectors", "node", size.node_vector_count);
        node_vector_ms = elapsedMs(start);
    }
    if (@intFromEnum(stage) >= @intFromEnum(Stage.token_vectors)) {
        const start = now();
        try loadVectors(allocator, build, "token_vectors", "token", size.token_vector_count);
        token_vector_ms = elapsedMs(start);
    }

    var profile: api.zova_fresh_build_profile = .{};
    const finish_start = now();
    try requireOk(api.zova_fresh_build_finish(&.{
        .build = build,
        .out_node_keys = node_keys.ptr,
        .out_node_keys_capacity = node_keys.len,
        .out_edge_keys = edge_keys.ptr,
        .out_edge_keys_capacity = edge_keys.len,
        .out_profile = &profile,
    }));
    const finish_ms = elapsedMs(finish_start);
    const outer_commit_start = now();
    try requireOk(api.zova_database_commit(&.{ .db = db }));
    const outer_commit_ms = elapsedMs(outer_commit_start);
    const total_ms = elapsedMs(total_start);
    const cache_diagnostics = api.freshBuildCacheDiagnostics(build) orelse return error.InvalidArgument;
    const file_size = (try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{})).size;
    std.debug.print(
        "ablation fixture={s} policy={s} stage={s} total_ms={d:.3} graph_ms={d:.3} metadata_ms={d:.3} fts_ms={d:.3} node_vectors_ms={d:.3} token_vectors_ms={d:.3} finish_ms={d:.3} graph_and_deferred_index_ms={d:.3} deferred_index_ms={d:.3} validation_ms={d:.3} baseline_fk_check_ms={d:.3} finish_fk_check_ms={d:.3} finish_fk_check_ran={} deferred_fk_pending={} validation_fast_path={} cache_restore_ms={d:.3} savepoint_release_ms={d:.3} outer_commit_ms={d:.3} bytes={d} rows={d}/{d}/{d}\n",
        .{ size.name, @tagName(policy), @tagName(stage), total_ms, graph_ms, metadata_ms, fts_ms, node_vector_ms, token_vector_ms, finish_ms, profile.index_build_ms, cache_diagnostics.deferred_index_ms, profile.validation_ms, cache_diagnostics.baseline_foreign_key_check_ms, cache_diagnostics.foreign_key_check_ms, cache_diagnostics.foreign_key_check_ran, cache_diagnostics.deferred_foreign_keys_pending, cache_diagnostics.validation_fast_path, cache_diagnostics.cache_restore_ms, cache_diagnostics.transaction_finish_ms, outer_commit_ms, file_size, profile.table_rows, profile.fts_rows, profile.vector_rows },
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var size = deno;
    var full_only = false;
    var policy: api.FreshBuildCachePolicy = .session;
    var ordinal: usize = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--tops")) {
            size = tops;
        } else if (std.mem.eql(u8, arg, "--full-only")) {
            full_only = true;
        } else if (std.mem.startsWith(u8, arg, "--policy=")) {
            const value = arg["--policy=".len..];
            if (std.mem.eql(u8, value, "graph-only"))
                policy = .graph_only
            else if (std.mem.eql(u8, value, "session"))
                policy = .session
            else if (std.mem.eql(u8, value, "graph-indexes"))
                policy = .graph_and_deferred_indexes
            else
                return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "--ordinal=")) {
            ordinal = try std.fmt.parseInt(usize, arg["--ordinal=".len..], 10);
        } else {
            return error.InvalidArgument;
        }
    }
    const fixture = try makeFixture(allocator, size);
    if (full_only) {
        try runStage(allocator, size, fixture, .token_vectors, policy, ordinal);
    } else {
        inline for (std.meta.fields(Stage), 0..) |field, stage_ordinal| {
            try runStage(allocator, size, fixture, @enumFromInt(field.value), policy, stage_ordinal);
        }
    }
}
