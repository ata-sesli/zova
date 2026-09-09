//! Issue #99 bounded graph-walk scratch benchmark.
//! Usage: binary NEW_DATABASE_PATH main|bound
//!
//! Two deterministic fixtures on one graph (seed 0x5a6f7661):
//! - chain:   20,000 nodes n0..n19999, edge n_i -> n_(i+1) for i < 19,999.
//!            The limit-20,000 depth-20,000 walk from n0 visits all 20,000
//!            nodes, forcing connection-owned scratch growth well beyond the
//!            1 MiB retention cap before the next small walk runs.
//! - binary:  8,191 nodes n0..n8190, edges n_i -> n_(2i+1) and n_i -> n_(2i+2)
//!            for i < 4,095. The depth-10 walk from n0 is a complete binary
//!            tree: exactly 2^11 - 1 = 2,047 reachable nodes, so visited
//!            counts are asserted exactly.
//!
//! The bench asserts the persisted unique edge counts and the visited result
//! counts of every workload, and reports scratch retained capacity alongside
//! timings. Small/medium windows use 20 warmups plus 200 complete-call
//! samples; the large chain walk runs once per trial and is reported
//! separately. Caller-owned result allocations are counted separately from
//! connection-owned scratch capacity.
const std = @import("std");
const zova = @import("zova");
const sqlite = zova.sqlite;

const chain_nodes = 20_000;
const tree_nodes = 8_191;
const samples = 200;
const warmups = 20;

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

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    allocs: usize = 0,
    frees: usize = 0,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn reset(self: *CountingAllocator) void {
        self.allocs = 0;
        self.frees = 0;
        self.live_bytes = 0;
        self.peak_bytes = 0;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocs += 1;
        self.live_bytes += len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return ptr;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live_bytes = (self.live_bytes + new_len) -| memory.len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live_bytes = (self.live_bytes + new_len) -| memory.len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return ptr;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.live_bytes -|= memory.len;
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

fn stmtBytes(db: *zova.Database) i64 {
    var current: i64 = 0;
    var highwater: i64 = 0;
    _ = sqlite.c.sqlite3_db_status64(db.sqlite_db.handle, sqlite.c.SQLITE_DBSTATUS_STMT_USED, &current, &highwater, 0);
    return current;
}

fn scratchCapacity(db: *zova.Database) usize {
    if (comptime @hasField(zova.Database, "graph_walk_scratch")) return db.graph_walk_scratch.retainedCapacity();
    return 0;
}

fn hasScratch() bool {
    return comptime @hasField(zova.Database, "graph_walk_scratch");
}

fn edgeCount(db: *zova.Database, bound: bool) !i64 {
    var buffer: [128]u8 = undefined;
    const sql = if (bound)
        "select count(*) from graph_store._zova_graph_edges"
    else
        "select count(*) from _zova_graph_edges";
    var stmt = try db.sqlite_db.prepare(try std.fmt.bufPrintZ(&buffer, "{s}", .{sql}));
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    return stmt.columnInt64(0);
}

fn expect(condition: bool) !void {
    if (!condition) return error.UnexpectedWalkShape;
}

fn nodeId(arena: std.mem.Allocator, index: usize) ![]u8 {
    return std.fmt.allocPrint(arena, "n{d}", .{index});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return error.InvalidArgument;
    const bound = std.mem.eql(u8, args[2], "bound");
    if (!bound and !std.mem.eql(u8, args[2], "main")) return error.InvalidArgument;
    var db = try zova.Database.create(try arena.dupeZ(u8, args[1]));
    defer db.deinit();
    if (bound) {
        const store_path = try arena.dupeZ(u8, try std.fmt.allocPrint(arena, "{s}-store.zova", .{args[1]}));
        try zova.createGraphStore(store_path);
        try db.bindGraphStore(store_path);
    }

    var counting = CountingAllocator{ .parent = std.heap.c_allocator };
    const allocator = counting.allocator();
    const store = if (bound) "bound" else "main";

    // Seed both fixtures into one graph and assert the persisted unique edge
    // counts: the chain has 19,999 edges, the tree 2 * 4,095 = 8,190.
    try db.createGraph("bench");
    const nodes = try arena.alloc(zova.GraphNodeInput, chain_nodes + tree_nodes);
    for (0..chain_nodes) |index| nodes[index] = .{ .graph_name = "bench", .node_id = try nodeId(arena, index), .kind = "node" };
    for (0..tree_nodes) |index| nodes[chain_nodes + index] = .{ .graph_name = "bench", .node_id = try nodeId(arena, chain_nodes + index), .kind = "node" };
    try db.putGraphNodes(nodes);
    const edges = try arena.alloc(zova.GraphEdgeInput, (chain_nodes - 1) + 2 * (tree_nodes / 2));
    var edge_index: usize = 0;
    for (0..chain_nodes - 1) |index| {
        edges[edge_index] = .{ .graph_name = "bench", .from_node_id = nodes[index].node_id, .to_node_id = nodes[index + 1].node_id, .edge_type = "chain" };
        edge_index += 1;
    }
    for (0..tree_nodes / 2) |index| {
        edges[edge_index] = .{ .graph_name = "bench", .from_node_id = nodes[chain_nodes + index].node_id, .to_node_id = nodes[chain_nodes + 2 * index + 1].node_id, .edge_type = "branch" };
        edge_index += 1;
        edges[edge_index] = .{ .graph_name = "bench", .from_node_id = nodes[chain_nodes + index].node_id, .to_node_id = nodes[chain_nodes + 2 * index + 2].node_id, .edge_type = "branch" };
        edge_index += 1;
    }
    try db.putGraphEdges(edges);
    const persisted = try edgeCount(&db, bound);
    try expect(persisted == (chain_nodes - 1) + 2 * (tree_nodes / 2));
    std.debug.print("store={s} fixture=edges unique_edges={d} expected={d} ok=1\n", .{ store, persisted, (chain_nodes - 1) + 2 * (tree_nodes / 2) });

    // Small walk (tree): 20 warmups + 200 complete calls; result count is
    // asserted to exactly 32 per call (first 32 BFS nodes of the tree).
    const small_timings = try arena.alloc(f64, samples);
    for (0..warmups) |_| try walkSmall(allocator, &db);
    counting.reset();
    for (small_timings) |*sample| {
        const started = now();
        try walkSmall(allocator, &db);
        sample.* = us(started);
    }
    printWindow(store, "tree_small", "32_of_2047", small_timings, &counting, &db);

    // Medium walk (tree, full): every call visits all 2,047 tree nodes.
    const medium_timings = try arena.alloc(f64, samples);
    for (0..warmups) |_| try walkTreeFull(allocator, &db);
    counting.reset();
    for (medium_timings) |*sample| {
        const started = now();
        try walkTreeFull(allocator, &db);
        sample.* = us(started);
    }
    printWindow(store, "tree_full", "2047", medium_timings, &counting, &db);

    // Large walk (chain): one call per trial visiting all 20,000 chain nodes,
    // so connection-owned scratch grows well beyond the 1 MiB retention cap.
    counting.reset();
    const large_start = now();
    const visited_large = try walkChainFull(allocator, &db);
    const large_us = us(large_start);
    try expect(visited_large == chain_nodes);
    std.debug.print("store={s} workload=chain_full limit=20000 samples=1 total_us={d:.3} visited={d} allocs={d} peak_bytes={d} retained_bytes={d} scratch_retained_bytes={d} scratch_exceeded_cap={d} stmt_bytes={d}\n", .{
        store,
        large_us,
        visited_large,
        counting.allocs,
        counting.peak_bytes,
        counting.live_bytes,
        scratchCapacity(&db),
        @intFromBool(hasScratch() and scratchCapacity(&db) == 1024 * 1024),
        stmtBytes(&db),
    });
    if (counting.live_bytes != 0) return error.LeakedResults;

    // Small walk after large: retention must keep at most the cap and the
    // small path must stay correct and fast after significant arena growth.
    const small_after_large = try arena.alloc(f64, samples);
    for (0..warmups) |_| try walkSmall(allocator, &db);
    counting.reset();
    for (small_after_large) |*sample| {
        const started = now();
        try walkSmall(allocator, &db);
        sample.* = us(started);
    }
    printWindow(store, "tree_small_after_large", "32_of_2047", small_after_large, &counting, &db);
    if (counting.live_bytes != 0) return error.LeakedResults;
}

fn printWindow(store: []const u8, workload: []const u8, visits: []const u8, timings: []f64, counting: *CountingAllocator, db: *zova.Database) void {
    std.debug.print("store={s} workload={s} limit={s} samples={d} p50_us={d:.3} p95_us={d:.3} allocs={d} peak_bytes={d} retained_bytes={d} scratch_retained_bytes={d} stmt_bytes={d}\n", .{
        store,
        workload,
        visits,
        timings.len,
        percentile(timings, 50),
        percentile(timings, 95),
        counting.allocs,
        counting.peak_bytes,
        counting.live_bytes,
        scratchCapacity(db),
        stmtBytes(db),
    });
    counting.reset();
}

fn walkSmall(allocator: std.mem.Allocator, db: *zova.Database) !void {
    var walk = try db.graphWalk(allocator, .{ .graph_name = "bench", .start_node_id = nodeId20000(), .max_depth = 10, .limit = 32 });
    defer walk.deinit(allocator);
    try expect(walk.items.len == 32);
    try expect(std.mem.eql(u8, walk.items[0].node_id, "n20000"));
    try expect(walk.items[0].depth == 0);
    try expect(std.mem.eql(u8, walk.items[1].node_id, "n20001"));
    try expect(walk.items[1].depth == 1 and walk.items[1].predecessor_node_id != null and std.mem.eql(u8, walk.items[1].predecessor_node_id.?, "n20000"));
    try expect(std.mem.eql(u8, walk.items[31].node_id, "n20031"));
}

fn walkTreeFull(allocator: std.mem.Allocator, db: *zova.Database) !void {
    var walk = try db.graphWalk(allocator, .{ .graph_name = "bench", .start_node_id = nodeId20000(), .max_depth = 10, .limit = 4096 });
    defer walk.deinit(allocator);
    try expect(walk.items.len == 2047);
    var index: usize = 0;
    while (index < walk.items.len) : (index += 1) {
        const depth = std.math.log2_int(usize, index + 1);
        try expect(walk.items[index].depth == depth);
        const expected = chain_nodes + index;
        var buffer: [8]u8 = undefined;
        const want = std.fmt.bufPrint(&buffer, "n{d}", .{expected}) catch unreachable;
        try expect(std.mem.eql(u8, walk.items[index].node_id, want));
    }
}

fn walkChainFull(allocator: std.mem.Allocator, db: *zova.Database) !usize {
    var walk = try db.graphWalk(allocator, .{ .graph_name = "bench", .start_node_id = "n0", .max_depth = chain_nodes, .limit = chain_nodes });
    defer walk.deinit(allocator);
    try expect(walk.items.len == chain_nodes);
    try expect(std.mem.eql(u8, walk.items[walk.items.len - 1].node_id, "n19999"));
    return walk.items.len;
}

fn nodeId20000() []const u8 {
    return "n20000";
}
