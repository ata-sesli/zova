//! Run identical binaries before/after the carray experiment against one fixture.
//! Usage: <binary> <database-path> init|run
//! Or: <binary> <database-path> case nodes|edges 1|100|10000|100000 hits|mixed
//! Or: <binary> <database-path> tail (75 large-edge samples with attribution)
const std = @import("std");
const zova = @import("zova");
const c = zova.sqlite.c;
const count = 100_000;
const os = @cImport({
    @cInclude("sys/resource.h");
});

const Phases = struct { api_ms: f64 = 0, verify_ms: f64 = 0, free_ms: f64 = 0 };
const TailSample = struct {
    phases: Phases = .{},
    cpu_ms: f64 = 0,
    minor_faults: i64 = 0,
    major_faults: i64 = 0,
    involuntary_switches: i64 = 0,
    cache_hits: c_int = 0,
    cache_misses: c_int = 0,
};

fn usage() !os.struct_rusage {
    var value: os.struct_rusage = undefined;
    if (os.getrusage(os.RUSAGE_SELF, &value) != 0) return error.ResourceUsageFailed;
    return value;
}

fn cpuMs(value: os.struct_rusage) f64 {
    return @as(f64, @floatFromInt(value.ru_utime.tv_sec + value.ru_stime.tv_sec)) * 1000 +
        @as(f64, @floatFromInt(value.ru_utime.tv_usec + value.ru_stime.tv_usec)) / 1000;
}

fn cacheStatus(db: *zova.Database, operation: c_int, reset: bool) !c_int {
    var current: c_int = 0;
    var high: c_int = 0;
    if (c.sqlite3_db_status(db.sqlite_db.handle, operation, &current, &high, @intFromBool(reset)) != c.SQLITE_OK) return error.CacheStatusFailed;
    return current;
}

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

const Trace = struct {
    stages: usize = 0,
    sorts: usize = 0,
    scans: usize = 0,
    query: ?[:0]u8 = null,
};

fn trace(mask: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const counters: *Trace = @ptrCast(@alignCast(context.?));
    const stmt: *c.sqlite3_stmt = @ptrCast(statement.?);
    const sql = std.mem.span(c.sqlite3_sql(stmt));
    if (mask == c.SQLITE_TRACE_STMT) {
        if (std.mem.startsWith(u8, sql, "insert into temp._zova_graph_")) counters.stages += 1;
        if (std.mem.startsWith(u8, sql, "select batch.")) {
            if (counters.query) |previous| std.heap.c_allocator.free(previous);
            counters.query = std.heap.c_allocator.dupeZ(u8, sql) catch null;
        }
    } else if (mask == c.SQLITE_TRACE_PROFILE) {
        counters.sorts += @intCast(c.sqlite3_stmt_status(stmt, c.SQLITE_STMTSTATUS_SORT, 1));
        counters.scans += @intCast(c.sqlite3_stmt_status(stmt, c.SQLITE_STMTSTATUS_FULLSCAN_STEP, 1));
    }
    return 0;
}

fn read(db: *zova.Database, allocator: std.mem.Allocator, keys: []const i64, comptime edges: bool) !u64 {
    return readWithPhases(db, allocator, keys, edges, null);
}

fn readWithPhases(db: *zova.Database, allocator: std.mem.Allocator, keys: []const i64, comptime edges: bool, phases: ?*Phases) !u64 {
    const api_start = if (phases != null) now() else undefined;
    var rows = if (edges) try db.graphEdgesGetManyKeyed(allocator, "bench", keys) else try db.graphNodesGetManyKeyed(allocator, "bench", keys);
    const verify_start = if (phases != null) now() else undefined;
    if (phases) |p| p.api_ms = @as(f64, @floatFromInt(api_start.durationTo(verify_start).toNanoseconds())) / 1e6;
    defer {
        const free_start = if (phases != null) now() else undefined;
        rows.deinit(allocator);
        if (phases) |p| p.free_ms = @as(f64, @floatFromInt(free_start.durationTo(now()).toNanoseconds())) / 1e6;
    }
    if (rows.items.len != keys.len) return error.ParityMismatch;
    var digest = std.hash.Wyhash.init(0);
    for (rows.items, keys) |row, key| {
        if (row.found != (key <= count)) return error.ParityMismatch;
        const actual_key = if (edges) row.edge_key else row.node_key;
        if (actual_key != key) return error.ParityMismatch;
        digest.update(std.mem.asBytes(&actual_key));
        if (row.found) {
            if (row.created_order != key) return error.ParityMismatch;
            digest.update(std.mem.asBytes(&row.created_order));
            if (edges) {
                if (row.source_node_key != key or row.target_node_key != @mod(key, count) + 1) return error.ParityMismatch;
                digest.update(row.edge_type.?);
            } else {
                digest.update(row.node_id.?);
                digest.update(row.kind.?);
            }
        }
    }
    const result = digest.final();
    if (phases) |p| p.verify_ms = @as(f64, @floatFromInt(verify_start.durationTo(now()).toNanoseconds())) / 1e6;
    return result;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 6 and std.mem.eql(u8, args[2], "degree")) {
        const path = try allocator.dupeZ(u8, args[1]);
        const size = try std.fmt.parseInt(usize, args[4], 10);
        if (size == 0 or size > count) return error.InvalidArgument;
        const direction: zova.GraphNeighborDirection = if (std.mem.eql(u8, args[3], "incoming")) .incoming else if (std.mem.eql(u8, args[3], "outgoing")) .outgoing else return error.InvalidArgument;
        const filter: ?[]const u8 = if (std.mem.eql(u8, args[5], "all")) null else args[5];
        var db = try zova.Database.open(path);
        defer db.deinit();
        try db.exec("pragma cache_size=-32768");
        const expected = try allocator.alloc(u64, count + 1);
        @memset(expected, 0);
        const endpoint = if (direction == .incoming) "to_node_key" else "from_node_key";
        const sql = try std.fmt.allocPrintSentinel(allocator, "select {s},count(*) from _zova_graph_edges where graph_key=1 and (?1 is null or edge_type_key=(select edge_type_key from _zova_graph_edge_types where graph_key=1 and name=?1)) group by {s}", .{ endpoint, endpoint }, 0);
        var oracle = try db.sqlite_db.prepare(sql);
        defer oracle.deinit();
        if (filter) |f| try oracle.bindText(1, f) else try oracle.bindNull(1);
        while (try oracle.step() == .row) expected[@intCast(oracle.columnInt64(0))] = @intCast(oracle.columnInt64(1));
        const keys = try allocator.alloc(i64, size);
        const degrees = try allocator.alloc(u64, size);
        for (keys, 0..) |*key, i| key.* = @intCast(1 + (i * 7919) % count);
        var times: [10]f64 = undefined;
        for (0..13) |i| {
            const start = now();
            try db.graphDegreeManyKeyed("bench", keys, direction, filter, degrees);
            const elapsed = @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / 1e6;
            for (keys, degrees) |key, degree| if (degree != expected[@intCast(key)]) return error.ParityMismatch;
            if (i >= 3) times[i - 3] = elapsed;
        }
        for (times, 0..) |t, i| std.debug.print("degree,{s},{d},{s},{d},{d:.6}\n", .{ args[3], size, args[5], i, t });
        return;
    }
    if (args.len != 3 and args.len != 6) return error.InvalidArgument;
    const single_case = args.len == 6;
    const tail_case = args.len == 3 and std.mem.eql(u8, args[2], "tail");
    const selected_size = if (single_case) try std.fmt.parseInt(usize, args[4], 10) else 0;
    if (single_case) {
        if (!std.mem.eql(u8, args[2], "case") or
            (!std.mem.eql(u8, args[3], "nodes") and !std.mem.eql(u8, args[3], "edges")) or
            (selected_size != 1 and selected_size != 100 and selected_size != 10_000 and selected_size != 100_000) or
            (!std.mem.eql(u8, args[5], "hits") and !std.mem.eql(u8, args[5], "mixed"))) return error.InvalidArgument;
    }
    const path = try allocator.dupeZ(u8, args[1]);
    if (std.mem.eql(u8, args[2], "init")) {
        var db = try zova.Database.create(path);
        defer db.deinit();
        try db.createGraph("bench");
        try db.sqlite_db.exec(
            \\begin;
            \\with recursive seq(i) as (values(1) union all select i+1 from seq where i<100000)
            \\insert into _zova_graph_nodes(node_key,graph_key,node_id,kind,target_type,created_order)
            \\select i,1,printf('node-%06d',i),'function','none',i from seq;
            \\insert into _zova_graph_edge_types(edge_type_key,graph_key,name) values(1,1,'link');
            \\insert into _zova_graph_edges(edge_key,graph_key,from_node_key,edge_type_key,to_node_key,created_order)
            \\select node_key,1,node_key,1,node_key%100000+1,node_key from _zova_graph_nodes;
            \\commit;
        );
        std.debug.print("fixture nodes=100000 edges=100000 sqlite={s} zig={s}\n", .{ zova.sqlite.version(), @import("builtin").zig_version_string });
        return;
    }
    if (!single_case and !tail_case and !std.mem.eql(u8, args[2], "run")) return error.InvalidArgument;
    var db = try zova.Database.open(path);
    defer db.deinit();
    inline for (.{ false, true }) |edges| {
        for ([_]usize{ 1, 100, 10_000, 100_000 }) |size| {
            for ([_]bool{ false, true }) |mixed| {
                if (tail_case and (!edges or size != 100_000 or mixed)) continue;
                if (single_case and (size != selected_size or
                    edges != std.mem.eql(u8, args[3], "edges") or
                    mixed != std.mem.eql(u8, args[5], "mixed"))) continue;
                const samples: usize = if (tail_case) 75 else switch (size) {
                    1 => 16_384,
                    100 => 4_096,
                    10_000 => 64,
                    else => 12,
                };
                const warmups: usize = if (tail_case) 8 else switch (size) {
                    1 => 2_048,
                    100 => 512,
                    10_000 => 8,
                    else => 3,
                };
                const keys = try allocator.alloc(i64, size);
                for (keys, 0..) |*key, i| key.* = @intCast(if (mixed and i % 5 == 0) count + 1 + i else (i * 7919) % count + 1);
                const expected = try read(&db, std.heap.c_allocator, keys, edges);
                for (0..warmups) |_| {
                    if (try read(&db, std.heap.c_allocator, keys, edges) != expected) return error.ParityMismatch;
                }
                const times = try allocator.alloc(f64, samples);
                const details = try allocator.alloc(TailSample, if (tail_case) samples else 0);
                for (times, 0..) |*time, sample| {
                    if (tail_case) {
                        _ = try cacheStatus(&db, c.SQLITE_DBSTATUS_CACHE_HIT, true);
                        _ = try cacheStatus(&db, c.SQLITE_DBSTATUS_CACHE_MISS, true);
                    }
                    const before = if (tail_case) try usage() else undefined;
                    if (tail_case) details[sample] = .{};
                    const start = now();
                    const checksum = try readWithPhases(&db, std.heap.c_allocator, keys, edges, if (tail_case) &details[sample].phases else null);
                    time.* = @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / 1e6;
                    if (checksum != expected) return error.ParityMismatch;
                    if (tail_case) {
                        const after = try usage();
                        details[sample].cpu_ms = cpuMs(after) - cpuMs(before);
                        details[sample].minor_faults = after.ru_minflt - before.ru_minflt;
                        details[sample].major_faults = after.ru_majflt - before.ru_majflt;
                        details[sample].involuntary_switches = after.ru_nivcsw - before.ru_nivcsw;
                        details[sample].cache_hits = try cacheStatus(&db, c.SQLITE_DBSTATUS_CACHE_HIT, false);
                        details[sample].cache_misses = try cacheStatus(&db, c.SQLITE_DBSTATUS_CACHE_MISS, false);
                    }
                }
                // Logging between microsecond calls perturbs the measurement.
                for (times, 0..) |time, sample| std.debug.print("sample,{s},{d},{s},{d},{d:.6},{x}\n", .{ if (edges) "edges" else "nodes", size, if (mixed) "mixed" else "hits", sample, time, expected });
                for (details, 0..) |detail, sample| std.debug.print("tail,{d},api_ms={d:.6},verify_ms={d:.6},free_ms={d:.6},cpu_ms={d:.6},minor_faults={d},major_faults={d},involuntary_switches={d},cache_hits={d},cache_misses={d}\n", .{ sample, detail.phases.api_ms, detail.phases.verify_ms, detail.phases.free_ms, detail.cpu_ms, detail.minor_faults, detail.major_faults, detail.involuntary_switches, detail.cache_hits, detail.cache_misses });
                var counters: Trace = .{};
                var allocations = std.testing.FailingAllocator.init(std.heap.c_allocator, .{});
                _ = c.sqlite3_trace_v2(db.sqlite_db.handle, c.SQLITE_TRACE_STMT | c.SQLITE_TRACE_PROFILE, trace, &counters);
                _ = try read(&db, allocations.allocator(), keys, edges);
                _ = c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);
                std.mem.sort(f64, times, {}, std.sort.asc(f64));
                const median = (times[(samples - 1) / 2] + times[samples / 2]) / 2;
                const deviations = try allocator.alloc(f64, samples);
                for (times, deviations) |time, *deviation| deviation.* = @abs(time - median);
                std.mem.sort(f64, deviations, {}, std.sort.asc(f64));
                const mad = (deviations[(samples - 1) / 2] + deviations[samples / 2]) / 2;
                std.debug.print("summary,{s},{d},{s},p50={d:.6},p95={d:.6},mad={d:.6},stages={d},sorts={d},scans={d},zig_allocations={d}\n", .{ if (edges) "edges" else "nodes", size, if (mixed) "mixed" else "hits", median, times[(samples * 95 + 99) / 100 - 1], mad, counters.stages, counters.sorts, counters.scans, allocations.allocations });
                if (counters.query) |query| {
                    defer std.heap.c_allocator.free(query);
                    const explain = try std.fmt.allocPrintSentinel(allocator, "explain query plan {s}", .{query}, 0);
                    var plan = try db.sqlite_db.prepare(explain);
                    defer plan.deinit();
                    while (try plan.step() == .row) std.debug.print("plan,{s}\n", .{plan.columnText(3)});
                }
            }
        }
    }
}
