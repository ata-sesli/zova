//! One bounded read sample for issue #98.
//! Usage: binary NEW_DATABASE_PATH graph|object main|bound
//!
//! graph: 1,000 nodes / 4,000 edges (seed 0x5a6f7661); repeated existing and
//! missing resolution, typed/untyped adjacency, exact-edge lookup and a
//! depth-2 walk. object: 1 MiB under each profile with repeated metadata reads
//! and 4 KiB range reads. Both use the common read protocol: 20 warmups then
//! 200 complete-call samples per op, reported as p50/p95.
//!
//! Allocation counts come from a counting wrapper around the allocator used for
//! caller-owned results; `stmt_live` is SQLITE_DBSTATUS_STMT_USED after each
//! op's window. `window_prepares`/`window_reuses` are the shared cache counters
//! for that window; they are zero on trees without the cache (baseline), where
//! every acquire prepares, so baseline prepares == prepares + reuses here.
const std = @import("std");
const zova = @import("zova");
const sqlite = zova.sqlite;

const node_count = 1000;
const edge_count = 4000;
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
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
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
        if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (self.parent.rawResize(memory, alignment, new_len, ret_addr)) {
            self.live_bytes = (self.live_bytes + new_len) -| memory.len;
            if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
            return true;
        }
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live_bytes = (self.live_bytes + new_len) -| memory.len;
        if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.live_bytes -|= memory.len;
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

const Counters = struct {
    prepares: u64,
    reuses: u64,

    fn read(db: *zova.Database) Counters {
        if (comptime @hasField(zova.Database, "read_statements")) {
            return .{ .prepares = db.read_statements.prepares, .reuses = db.read_statements.reuses };
        }
        return .{ .prepares = 0, .reuses = 0 };
    }
};

/// Bytes of heap and lookaside memory held by the connection's prepared
/// statements (SQLITE_DBSTATUS_STMT_USED): the retained-statement cost of the
/// cache, measured after the window.
fn stmtBytes(db: *zova.Database) i64 {
    var current: i64 = 0;
    var highwater: i64 = 0;
    _ = sqlite.c.sqlite3_db_status64(db.sqlite_db.handle, sqlite.c.SQLITE_DBSTATUS_STMT_USED, &current, &highwater, 0);
    return current;
}

fn retainedCount(db: *zova.Database) u64 {
    if (comptime @hasField(zova.Database, "read_statements")) return db.read_statements.retained();
    return 0;
}

fn payloadBytes(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, size);
    var state: u64 = 0x5a6f7661;
    for (bytes) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }
    return bytes;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.InvalidArgument;
    const workload = args[2];
    const graph = std.mem.eql(u8, workload, "graph");
    if (!graph and !std.mem.eql(u8, workload, "object")) return error.InvalidArgument;
    const bound = std.mem.eql(u8, args[3], "bound");
    if (!bound and !std.mem.eql(u8, args[3], "main")) return error.InvalidArgument;

    const path = try arena.dupeZ(u8, args[1]);
    var db = try zova.Database.create(path);
    defer db.deinit();

    var counting = CountingAllocator{ .parent = std.heap.c_allocator };
    const allocator = counting.allocator();
    const store = if (bound) "bound" else "main";

    if (graph) {
        try runGraph(arena, &db, path, &counting, allocator, store, bound);
    } else {
        try runObject(arena, &db, path, &counting, allocator, store, bound);
    }
}

fn printWindow(
    workload: []const u8,
    variant: []const u8,
    store: []const u8,
    op: []const u8,
    timings: []f64,
    counting: *CountingAllocator,
    db: *zova.Database,
    before: Counters,
) void {
    const after = Counters.read(db);
    std.debug.print("workload={s} variant={s} store={s} op={s} samples={d} p50_us={d:.3} p95_us={d:.3} allocs={d} peak_bytes={d} retained_bytes={d} stmt_bytes={d} cache_retained={d} window_prepares={d} window_reuses={d}\n", .{
        workload,
        variant,
        store,
        op,
        timings.len,
        percentile(timings, 50.0),
        percentile(timings, 95.0),
        counting.allocs,
        counting.peak_bytes,
        counting.live_bytes,
        stmtBytes(db),
        retainedCount(db),
        after.prepares - before.prepares,
        after.reuses - before.reuses,
    });
}

fn runGraph(
    arena: std.mem.Allocator,
    db: *zova.Database,
    path: [:0]const u8,
    counting: *CountingAllocator,
    allocator: std.mem.Allocator,
    store: []const u8,
    bound: bool,
) !void {
    if (bound) {
        const store_path = try arena.dupeZ(u8, try std.fmt.allocPrint(arena, "{s}-store.zova", .{path}));
        try zova.createGraphStore(store_path);
        try db.bindGraphStore(store_path);
    }
    try db.createGraph("bench");

    const nodes = try arena.alloc(zova.GraphNodeInput, node_count);
    for (0..node_count) |index| {
        nodes[index] = .{
            .graph_name = "bench",
            .node_id = try std.fmt.allocPrint(arena, "n{d}", .{index}),
            .kind = "node",
        };
    }
    try db.putGraphNodes(nodes);
    const edges = try arena.alloc(zova.GraphEdgeInput, edge_count);
    for (0..edge_count) |index| {
        edges[index] = .{
            .graph_name = "bench",
            .from_node_id = nodes[index % node_count].node_id,
            .to_node_id = nodes[(index * 7 + 3) % node_count].node_id,
            .edge_type = "link",
        };
    }
    try db.putGraphEdges(edges);

    const ops = [_][]const u8{ "resolve_existing", "resolve_missing", "neighbors_untyped", "neighbors_typed", "exact_edge", "walk_depth2" };
    const timings = try arena.alloc(f64, samples);
    for (ops) |op| {
        for (0..warmups) |_| try runGraphOp(allocator, db, op);
        counting.reset();
        const before = Counters.read(db);
        for (0..samples) |index| {
            const started = now();
            try runGraphOp(allocator, db, op);
            timings[index] = us(started);
        }
        printWindow("graph", "-", store, op, timings, counting, db, before);
        if (counting.live_bytes != 0) return error.LeakedResults;
    }
}

fn runGraphOp(allocator: std.mem.Allocator, db: *zova.Database, op: []const u8) !void {
    if (std.mem.eql(u8, op, "resolve_existing")) {
        if (!try db.hasGraphNode("bench", "n5")) return error.MissingNode;
    } else if (std.mem.eql(u8, op, "resolve_missing")) {
        if (try db.hasGraphNode("bench", "absent")) return error.UnexpectedNode;
    } else if (std.mem.eql(u8, op, "neighbors_untyped")) {
        var result = try db.graphNeighbors(allocator, .{ .graph_name = "bench", .node_id = "n0", .direction = .outgoing, .limit = 32 });
        result.deinit(allocator);
    } else if (std.mem.eql(u8, op, "neighbors_typed")) {
        var result = try db.graphNeighbors(allocator, .{ .graph_name = "bench", .node_id = "n0", .direction = .outgoing, .edge_type = "link", .limit = 32 });
        result.deinit(allocator);
    } else if (std.mem.eql(u8, op, "exact_edge")) {
        if (!try db.hasGraphEdge("bench", "n0", "link", "n3")) return error.MissingEdge;
    } else {
        var walk = try db.graphWalk(allocator, .{ .graph_name = "bench", .start_node_id = "n0", .max_depth = 2, .limit = 64 });
        walk.deinit(allocator);
    }
}

fn runObject(
    arena: std.mem.Allocator,
    db: *zova.Database,
    path: [:0]const u8,
    counting: *CountingAllocator,
    allocator: std.mem.Allocator,
    store: []const u8,
    bound: bool,
) !void {
    _ = allocator;
    if (bound) {
        const store_path = try arena.dupeZ(u8, try std.fmt.allocPrint(arena, "{s}-store.zova", .{path}));
        try zova.createObjectStore(store_path);
        try db.bindObjectStore(store_path);
    }
    const payload = try payloadBytes(arena, 1024 * 1024);
    const profiles = [_]zova.ObjectStorageProfile{ .deduplication, .streaming };
    const timings = try arena.alloc(f64, samples);
    var buffer: [4096]u8 = undefined;
    for (profiles) |profile| {
        const id = try db.putObjectWithOptions(payload, .{ .profile = profile });
        for ([_][]const u8{ "metadata", "range_4k" }) |op| {
            for (0..warmups) |_| try runObjectOp(db, id, op, &buffer);
            counting.reset();
            const before = Counters.read(db);
            for (0..samples) |index| {
                const started = now();
                try runObjectOp(db, id, op, &buffer);
                timings[index] = us(started);
            }
            printWindow("object", @tagName(profile), store, op, timings, counting, db, before);
        }
    }
}

fn runObjectOp(db: *zova.Database, id: zova.ObjectId, op: []const u8, buffer: []u8) !void {
    if (std.mem.eql(u8, op, "metadata")) {
        if (!try db.hasObject(id)) return error.MissingObject;
    } else {
        if (try db.readObjectRange(id, 4096, buffer) != buffer.len) return error.ShortRead;
    }
}
