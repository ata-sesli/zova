const std = @import("std");
const zova = @import("zova");

const node_count = 124_818;
const edge_count = 481_770;
const measured_runs = 7;
const graph_name = "deno-shaped";
const edge_types = [_][]const u8{ "calls", "imports", "defines", "tests", "contains", "reads", "writes", "exports", "extends", "implements", "references", "uses", "owns", "returns", "accepts", "documents", "related" };

const Variant = enum { incremental, fresh, prepared };
const Fixture = struct {
    nodes: []zova.GraphNodeInput,
    fresh_nodes: []zova.FreshGraphNodeInput,
    edges: []zova.GraphEdgeInput,
    fresh_edges: []zova.FreshGraphEdgeInput,
};
const Sample = struct { total_ms: f64, storage_bytes: i64, profile: zova.FreshGraphBuildProfile = .{} };

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const ns = start.durationTo(now()).toNanoseconds();
    return if (ns <= 0) 0 else @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
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

fn makeFixture(allocator: std.mem.Allocator) !Fixture {
    const node_ids = try allocator.alloc([]const u8, node_count);
    const nodes = try allocator.alloc(zova.GraphNodeInput, node_count);
    const fresh_nodes = try allocator.alloc(zova.FreshGraphNodeInput, node_count);
    for (node_ids, nodes, fresh_nodes, 0..) |*id, *node, *fresh, index| {
        id.* = try std.fmt.allocPrint(allocator, "node-{d:0>6}", .{index});
        node.* = .{ .graph_name = graph_name, .node_id = id.*, .kind = "symbol" };
        fresh.* = .{ .node_id = id.*, .kind = "symbol" };
    }
    const edges = try allocator.alloc(zova.GraphEdgeInput, edge_count);
    const fresh_edges = try allocator.alloc(zova.FreshGraphEdgeInput, edge_count);
    for (edges, fresh_edges, 0..) |*edge, *fresh, index| {
        const from = index % node_count;
        const to = (from + 1 + (index / node_count) * 97) % node_count;
        const edge_type = edge_types[index % edge_types.len];
        edge.* = .{ .graph_name = graph_name, .from_node_id = node_ids[from], .edge_type = edge_type, .to_node_id = node_ids[to] };
        fresh.* = .{ .from_node_ordinal = from, .edge_type = edge_type, .to_node_ordinal = to };
    }
    return .{ .nodes = nodes, .fresh_nodes = fresh_nodes, .edges = edges, .fresh_edges = fresh_edges };
}

fn storageBytes(db: *zova.Database) !i64 {
    var stmt = try db.prepare("select coalesce(sum(pgsize),0) from dbstat where name in (select name from sqlite_master where tbl_name like '_zova_graph%')");
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.GraphInvalid;
    return stmt.columnInt64(0);
}

fn reportDbstat(db: *zova.Database) !void {
    var stmt = try db.prepare(
        "select name,sum(pgsize) from dbstat where name in (select name from sqlite_master where tbl_name like '_zova_graph%') group by name order by name",
    );
    defer stmt.deinit();
    while ((try stmt.step()) == .row) std.debug.print("dbstat name={s} bytes={d}\n", .{ stmt.columnText(0), stmt.columnInt64(1) });
}

fn runSample(allocator: std.mem.Allocator, fixture: Fixture, variant: Variant, ordinal: usize, report_dbstat: bool) !Sample {
    const path = try std.fmt.allocPrintSentinel(allocator, "/tmp/zova-deno-shaped-{s}-{d}.zova", .{ @tagName(variant), ordinal }, 0);
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    var db = try zova.Database.create(path);
    defer db.deinit();
    const node_keys = try allocator.alloc(i64, node_count);
    const edge_keys = try allocator.alloc(i64, edge_count);
    var profile: zova.FreshGraphBuildProfile = .{};
    const start = now();
    switch (variant) {
        .incremental => {
            try db.createGraph(graph_name);
            try db.putGraphNodesKeyed(fixture.nodes, node_keys);
            try db.putGraphEdgesKeyed(fixture.edges, edge_keys);
        },
        .fresh => try db.buildFreshGraphKeyedProfiled(graph_name, fixture.fresh_nodes, fixture.fresh_edges, node_keys, edge_keys, &profile),
        .prepared => try db.buildFreshGraphPreparedKeyedProfiled(graph_name, fixture.fresh_nodes, fixture.fresh_edges, node_keys, edge_keys, &profile),
    }
    const result: Sample = .{ .total_ms = elapsedMs(start), .storage_bytes = try storageBytes(&db), .profile = profile };
    if (report_dbstat) try reportDbstat(&db);
    return result;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const fixture = try makeFixture(allocator);
    std.debug.print("fixture nodes={d} edges={d} format={s}\n", .{ node_count, edge_count, zova.version.format_version });
    if (args.len == 2 and std.mem.eql(u8, args[1], "--dbstat-only")) {
        const sample = try runSample(allocator, fixture, .fresh, 9999, true);
        std.debug.print("dbstat_sample total_ms={d:.3} storage_bytes={d}\n", .{ sample.total_ms, sample.storage_bytes });
        return;
    }
    _ = try runSample(allocator, fixture, .incremental, 1000, false);
    _ = try runSample(allocator, fixture, .fresh, 1001, false);
    _ = try runSample(allocator, fixture, .prepared, 1002, false);
    const order = [_]Variant{ .incremental, .fresh, .prepared, .prepared, .fresh, .incremental, .incremental, .prepared, .fresh, .fresh, .prepared, .incremental, .incremental, .fresh, .prepared, .prepared, .fresh, .incremental, .incremental, .prepared, .fresh };
    var incremental: [measured_runs]f64 = undefined;
    var fresh: [measured_runs]f64 = undefined;
    var prepared: [measured_runs]f64 = undefined;
    var incremental_len: usize = 0;
    var fresh_len: usize = 0;
    var prepared_len: usize = 0;
    for (order, 0..) |variant, ordinal| {
        const sample = try runSample(allocator, fixture, variant, ordinal, false);
        const index = switch (variant) {
            .incremental => index: {
                defer incremental_len += 1;
                incremental[incremental_len] = sample.total_ms;
                break :index incremental_len;
            },
            .fresh => index: {
                defer fresh_len += 1;
                fresh[fresh_len] = sample.total_ms;
                break :index fresh_len;
            },
            .prepared => index: {
                defer prepared_len += 1;
                prepared[prepared_len] = sample.total_ms;
                break :index prepared_len;
            },
        };
        std.debug.print("sample variant={s} index={d} total_ms={d:.3} storage_bytes={d} payload_bytes={d} validation_ms={d:.3} key_generation_ms={d:.3} nodes_ms={d:.3} edges_ms={d:.3} indexes_ms={d:.3}\n", .{ @tagName(variant), index + 1, sample.total_ms, sample.storage_bytes, sample.profile.payload_bytes, sample.profile.validation_ms, sample.profile.key_generation_ms, sample.profile.node_load_ms, sample.profile.edge_load_ms, sample.profile.index_build_ms });
    }
    const incremental_median = median(&incremental);
    const fresh_median = median(&fresh);
    const prepared_median = median(&prepared);
    std.debug.print("summary incremental_median_ms={d:.3} incremental_mad_ms={d:.3} fresh_median_ms={d:.3} fresh_mad_ms={d:.3} prepared_median_ms={d:.3} prepared_mad_ms={d:.3} prepared_vs_fresh={d:.6}\n", .{ incremental_median, mad(&incremental), fresh_median, mad(&fresh), prepared_median, mad(&prepared), prepared_median / fresh_median });
}
