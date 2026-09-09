//! Issue #99 bounded graph-walk scratch benchmark.
//! Usage: binary NEW_DATABASE_PATH main|bound
//!
//! Fixture: deterministic 10,000-node / 40,000-edge graph (seed
//! 0x5a6f7661). Small and medium walks use 20 warmups plus 200 complete-call
//! samples. The large limit-10,000 call runs once per trial and is reported
//! separately before the small/medium calls. Caller-owned result allocations
//! are counted separately from connection-owned scratch capacity.
const std = @import("std");
const zova = @import("zova");
const sqlite = zova.sqlite;

const node_count = 10_000;
const edge_count = 40_000;
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
    try db.createGraph("bench");
    const nodes = try arena.alloc(zova.GraphNodeInput, node_count);
    for (nodes, 0..) |*node, index| node.* = .{ .graph_name = "bench", .node_id = try std.fmt.allocPrint(arena, "n{d}", .{index}), .kind = "node" };
    try db.putGraphNodes(nodes);
    const edges = try arena.alloc(zova.GraphEdgeInput, edge_count);
    for (edges, 0..) |*edge, index| edge.* = .{ .graph_name = "bench", .from_node_id = nodes[index % node_count].node_id, .to_node_id = nodes[(index * 7 + 3) % node_count].node_id, .edge_type = "link" };
    try db.putGraphEdges(edges);

    var counting = CountingAllocator{ .parent = std.heap.c_allocator };
    const allocator = counting.allocator();
    const limits = [_]usize{ 32, 512 };
    for (limits) |limit| {
        const timings = try arena.alloc(f64, samples);
        for (0..warmups) |_| try runWalk(allocator, &db, limit);
        counting.reset();
        for (timings) |*sample| {
            const started = now();
            try runWalk(allocator, &db, limit);
            sample.* = us(started);
        }
        std.debug.print("store={s} limit={d} samples={d} p50_us={d:.3} p95_us={d:.3} allocs={d} peak_bytes={d} retained_bytes={d} scratch_retained_bytes={d} stmt_bytes={d}\n", .{ if (bound) "bound" else "main", limit, samples, percentile(timings, 50), percentile(timings, 95), counting.allocs, counting.peak_bytes, counting.live_bytes, scratchCapacity(&db), stmtBytes(&db) });
        if (counting.live_bytes != 0) return error.LeakedResults;
    }
    counting.reset();
    const large_start = now();
    try runWalk(allocator, &db, 10_000);
    const large_us = us(large_start);
    std.debug.print("store={s} limit=10000 samples=1 total_us={d:.3} allocs={d} peak_bytes={d} retained_bytes={d} scratch_retained_bytes={d} stmt_bytes={d}\n", .{ if (bound) "bound" else "main", large_us, counting.allocs, counting.peak_bytes, counting.live_bytes, scratchCapacity(&db), stmtBytes(&db) });
    if (counting.live_bytes != 0) return error.LeakedResults;

    const small_after_large = try arena.alloc(f64, samples);
    for (0..warmups) |_| try runWalk(allocator, &db, 32);
    counting.reset();
    for (small_after_large) |*sample| {
        const started = now();
        try runWalk(allocator, &db, 32);
        sample.* = us(started);
    }
    std.debug.print("store={s} limit=32_after_large samples={d} p50_us={d:.3} p95_us={d:.3} allocs={d} peak_bytes={d} retained_bytes={d} scratch_retained_bytes={d} stmt_bytes={d}\n", .{ if (bound) "bound" else "main", samples, percentile(small_after_large, 50), percentile(small_after_large, 95), counting.allocs, counting.peak_bytes, counting.live_bytes, scratchCapacity(&db), stmtBytes(&db) });
    if (counting.live_bytes != 0) return error.LeakedResults;
}

fn runWalk(allocator: std.mem.Allocator, db: *zova.Database, limit: usize) !void {
    var walk = try db.graphWalk(allocator, .{ .graph_name = "bench", .start_node_id = "n0", .max_depth = 4, .limit = limit });
    walk.deinit(allocator);
}
