//! Issue #100 scope audit benchmark.
//! Usage: binary NEW_DATABASE_PATH graph|object main|bound
//!
//! This intentionally measures existing operation scopes rather than adding a
//! public session or a long-lived data cache. It reports complete-call p50/p95
//! for the #98/#99 fixture shapes and traces one representative call per
//! operation to count repeated graph/object resolution SQL within that call.
const std = @import("std");
const zova = @import("zova");
const sqlite = zova.sqlite;
const c = sqlite.c;

const samples = 200;
const warmups = 20;
const node_count = 1000;
const edge_count = 4000;

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}
fn us(start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / 1_000;
}
fn percentile(values: []f64, pct: f64) f64 {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const rank = @min(values.len - 1, @as(usize, @intFromFloat(@ceil(pct / 100.0 * @as(f64, @floatFromInt(values.len))))) -| 1);
    return values[rank];
}

// Classification uses the stable private `zova_trace:*` SQL comments in the
// resolver statements (src/graph.zig, src/object.zig). SQLITE_TRACE_STMT
// counts statement executions, not rows; rows are never reported here.
const Trace = struct {
    statements: usize = 0,
    graph_keys: usize = 0,
    node_resolutions: usize = 0,
    edge_resolutions: usize = 0,
    adjacency: usize = 0,
    walk_adjacency: usize = 0,
    object_metadata: usize = 0,
    object_exists: usize = 0,
    object_range: usize = 0,
    object_reader_manifest: usize = 0,

    fn reset(self: *@This()) void {
        self.* = .{};
    }
    fn callback(_: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const handle: *c.sqlite3_stmt = @ptrCast(@alignCast(statement.?));
        const sql = std.mem.span(c.sqlite3_sql(handle));
        self.statements += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:graph_key") != null) self.graph_keys += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:graph_node_resolve") != null) self.node_resolutions += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:graph_edge_resolve") != null) self.edge_resolutions += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:graph_adjacency") != null) self.adjacency += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:walk_adjacency") != null) self.walk_adjacency += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:object_metadata") != null) self.object_metadata += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:object_exists") != null) self.object_exists += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:object_range") != null) self.object_range += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:object_reader_manifest") != null) self.object_reader_manifest += 1;
        return 0;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.InvalidArgument;
    const is_graph = std.mem.eql(u8, args[2], "graph");
    if (!is_graph and !std.mem.eql(u8, args[2], "object")) return error.InvalidArgument;
    const is_bound = std.mem.eql(u8, args[3], "bound");
    if (!is_bound and !std.mem.eql(u8, args[3], "main")) return error.InvalidArgument;

    var db = try zova.Database.create(try arena.dupeZ(u8, args[1]));
    defer db.deinit();
    if (is_bound) {
        const store_path = try arena.dupeZ(u8, try std.fmt.allocPrint(arena, "{s}-store.zova", .{args[1]}));
        if (is_graph) try zova.createGraphStore(store_path) else try zova.createObjectStore(store_path);
        if (is_graph) try db.bindGraphStore(store_path) else try db.bindObjectStore(store_path);
    }

    if (is_graph) try setupGraph(arena, &db) else try setupObject(arena, &db);
    if (is_graph) try runGraph(arena, &db, if (is_bound) "bound" else "main") else try runObject(arena, &db, if (is_bound) "bound" else "main");
}

fn setupGraph(arena: std.mem.Allocator, db: *zova.Database) !void {
    try db.createGraph("bench");
    const nodes = try arena.alloc(zova.GraphNodeInput, node_count);
    for (nodes, 0..) |*node, index| node.* = .{ .graph_name = "bench", .node_id = try std.fmt.allocPrint(arena, "n{d}", .{index}), .kind = "node" };
    try db.putGraphNodes(nodes);
    const edges = try arena.alloc(zova.GraphEdgeInput, edge_count);
    for (edges, 0..) |*edge, index| {
        const source = index / 4;
        const target = (index * 7 + 3) % node_count;
        edge.* = .{ .graph_name = "bench", .from_node_id = nodes[source].node_id, .to_node_id = nodes[target].node_id, .edge_type = if (index % 2 == 0) "link" else "calls" };
    }
    try db.putGraphEdges(edges);
}

fn setupObject(arena: std.mem.Allocator, db: *zova.Database) !void {
    const payload = try arena.alloc(u8, 1024 * 1024);
    var state: u64 = 0x5a6f7661;
    for (payload) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }
    _ = try db.putObjectWithOptions(payload, .{ .profile = .streaming });
}

fn runGraph(arena: std.mem.Allocator, db: *zova.Database, store: []const u8) !void {
    const ops = [_][]const u8{ "neighbors", "neighbors_typed", "degree", "walk" };
    for (ops) |op| {
        for (0..warmups) |_| try graphOp(std.heap.c_allocator, db, op);
        const timings = try arena.alloc(f64, samples);
        for (timings) |*sample| {
            const started = now();
            try graphOp(std.heap.c_allocator, db, op);
            sample.* = us(started);
        }
        var trace: Trace = .{};
        _ = c.sqlite3_trace_v2(db.sqlite_db.handle, c.SQLITE_TRACE_STMT, Trace.callback, &trace);
        try graphOp(std.heap.c_allocator, db, op);
        _ = c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);
        std.debug.print("scope=graph store={s} op={s} samples={d} p50_us={d:.3} p95_us={d:.3} traced_statements={d} graph_keys={d} node_resolutions={d} edge_resolutions={d} adjacency={d} walk_adjacency={d} object_metadata={d} object_exists={d} object_range={d} object_reader_manifest={d}\n", .{ store, op, samples, percentile(timings, 50), percentile(timings, 95), trace.statements, trace.graph_keys, trace.node_resolutions, trace.edge_resolutions, trace.adjacency, trace.walk_adjacency, trace.object_metadata, trace.object_exists, trace.object_range, trace.object_reader_manifest });
    }
}

fn graphOp(allocator: std.mem.Allocator, db: *zova.Database, op: []const u8) !void {
    if (std.mem.eql(u8, op, "neighbors")) {
        var result = try db.graphNeighbors(allocator, .{ .graph_name = "bench", .node_id = "n0", .limit = 32 });
        result.deinit(allocator);
    } else if (std.mem.eql(u8, op, "neighbors_typed")) {
        var result = try db.graphNeighbors(allocator, .{ .graph_name = "bench", .node_id = "n0", .edge_type = "link", .limit = 32 });
        result.deinit(allocator);
    } else if (std.mem.eql(u8, op, "degree")) {
        _ = try db.graphDegree(.{ .graph_name = "bench", .node_id = "n0" });
    } else {
        var walk = try db.graphWalk(allocator, .{ .graph_name = "bench", .start_node_id = "n0", .max_depth = 2, .limit = 64 });
        walk.deinit(allocator);
    }
}

fn runObject(arena: std.mem.Allocator, db: *zova.Database, store: []const u8) !void {
    var payload: [1024 * 1024]u8 = undefined;
    var state: u64 = 0x5a6f7661;
    for (&payload) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }
    const id = zova.objectId(&payload);
    const ops = [_][]const u8{ "exists", "range", "reader" };
    for (ops) |op| {
        for (0..warmups) |_| try objectOp(db, id, op);
        const timings = try arena.alloc(f64, samples);
        for (timings) |*sample| {
            const started = now();
            try objectOp(db, id, op);
            sample.* = us(started);
        }
        var trace: Trace = .{};
        _ = c.sqlite3_trace_v2(db.sqlite_db.handle, c.SQLITE_TRACE_STMT, Trace.callback, &trace);
        try objectOp(db, id, op);
        _ = c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);
        std.debug.print("scope=object store={s} op={s} samples={d} p50_us={d:.3} p95_us={d:.3} traced_statements={d} graph_keys={d} node_resolutions={d} edge_resolutions={d} adjacency={d} walk_adjacency={d} object_metadata={d} object_exists={d} object_range={d} object_reader_manifest={d}\n", .{ store, op, samples, percentile(timings, 50), percentile(timings, 95), trace.statements, trace.graph_keys, trace.node_resolutions, trace.edge_resolutions, trace.adjacency, trace.walk_adjacency, trace.object_metadata, trace.object_exists, trace.object_range, trace.object_reader_manifest });
    }
}

fn objectOp(db: *zova.Database, id: zova.ObjectId, op: []const u8) !void {
    if (std.mem.eql(u8, op, "exists")) {
        if (!try db.hasObject(id)) return error.ObjectNotFound;
    } else if (std.mem.eql(u8, op, "range")) {
        var buffer: [4096]u8 = undefined;
        if (try db.readObjectRange(id, 4096, &buffer) != buffer.len) return error.ShortRead;
    } else {
        var reader = try db.objectReader(id);
        defer reader.deinit();
        var buffer: [4096]u8 = undefined;
        while (try reader.read(&buffer) != 0) {}
    }
}
