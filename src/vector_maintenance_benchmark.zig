//! Bounded host-maintenance benchmark, not an ANN algorithm benchmark.
const std = @import("std");
const zova = @import("zova.zig");
const maintenance = @import("vector_maintenance.zig");
const api = @import("extension_plugin_api.zig");
fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}
fn ms(start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / std.time.ns_per_ms;
}
const Projection = struct {
    present: [2048]bool = @splat(true),
    values: [2048]i8 = @splat(1),
    rows: u64 = 0,
    fn row(raw: ?*anyopaque, values: ?[*]const api.Value, n: u64) callconv(.c) i32 {
        const self: *Projection = @ptrCast(@alignCast(raw.?));
        if (n != 4) return 3;
        const id = values.?[1].bytes.?[0..@intCast(values.?[1].bytes_len)];
        const slot = std.fmt.parseInt(usize, id[2..], 10) catch return 3;
        if (slot >= self.present.len) return 3;
        self.present[slot] = values.?[2].integer != 0;
        if (self.present[slot]) self.values[slot] = @bitCast(values.?[3].bytes.?[0]);
        self.rows += 1;
        return 0;
    }
};
fn distribution(name: []const u8, values: [7]f64) void {
    var sorted = values;
    std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
    var deviations: [7]f64 = undefined;
    for (values, &deviations) |v, *d| d.* = @abs(v - sorted[3]);
    std.mem.sort(f64, &deviations, {}, std.sort.asc(f64));
    std.debug.print("{s}: median_ms={d:.3} MAD_ms={d:.3} p95_ms={d:.3}\n", .{ name, sorted[3], deviations[3], sorted[6] });
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.InvalidArgument;
    std.debug.print("fixture=2048x32_i8 warmups=1 samples=7 updates=512 deletes=128 zig={s} sqlite={s}\n", .{ @import("builtin").zig_version_string, @import("version.zig").sqlite_version });
    const inputs = try a.alloc(zova.VectorInput, 2048);
    const base_values: [32]i8 = @splat(1);
    const new_values: [32]i8 = @splat(2);
    const deletes = try a.alloc([]const u8, 128);
    for (inputs, 0..) |*input, i| {
        input.* = .{ .id = try std.fmt.allocPrint(a, "v-{d}", .{i}), .values = .{ .i8 = &base_values } };
        if (i < deletes.len) deletes[i] = input.id;
    }
    for ([_]bool{ false, true }) |bound| {
        const name = if (bound) "bound" else "main";
        const main_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}.zova", .{ args[1], name }, 0);
        const store = try std.fmt.allocPrintSentinel(a, "{s}/{s}.vectors.zova", .{ args[1], name }, 0);
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        if (bound) {
            try zova.createVectorStore(store);
            try db.bindVectorStore(store);
        }
        try db.createVectorCollection("v", .{ .dimensions = 32, .metric = .l2, .element_type = .i8 });
        for (inputs) |*input| input.values = .{ .i8 = &base_values };
        try db.putVectors("v", inputs);
        const prefix = if (bound) "vector_store." else "main.";
        for (inputs[0..512]) |*input| input.values = .{ .i8 = &new_values };
        var write_samples: [7]f64 = undefined;
        var read_samples: [7]f64 = undefined;
        for (0..8) |run| {
            const coverage = try maintenance.view(&db.sqlite_db, prefix, "v");
            const write_start = now();
            try db.beginImmediate();
            try db.putVectors("v", inputs[0..512]);
            try db.deleteVectors("v", deletes);
            try db.commit();
            const write_ms = ms(write_start);
            const read_start = now();
            var projection: Projection = .{};
            var request: api.VectorChangesRequest = .{ .name = .from("v"), .since = coverage, .row_limit = 512, .byte_limit = 1024 * 1024, .row = Projection.row, .user_data = &projection };
            // The caller-owned read transaction also covers multiple pages.
            try db.begin();
            while (true) {
                const page = try maintenance.read(&db.sqlite_db, prefix, &request);
                if (page.has_more == 0) break;
                request.after_revision = page.next_revision;
            }
            try db.rollback();
            for (0..512) |i| {
                if (projection.present[i] != (i >= 128)) return error.Parity;
                if (i >= 128 and projection.values[i] != 2) return error.Parity;
            }
            if (projection.rows != 640) return error.Parity;
            const read_ms = ms(read_start);
            std.debug.print("{s} run={d} warmup={} write_commit_ms={d:.3} reconcile_projection_ms={d:.3} changes={d}\n", .{ name, run, run == 0, write_ms, read_ms, projection.rows });
            if (run != 0) {
                write_samples[run - 1] = write_ms;
                read_samples[run - 1] = read_ms;
            }
        }
        distribution(name, write_samples);
        distribution("reconcile", read_samples);
        var sql: [512]u8 = undefined;
        var storage = try db.prepare(try std.fmt.bufPrintSentinel(&sql, "select sum(d.pgsize),sum(d.payload),sum(d.unused) from dbstat(?1) d join {s}sqlite_schema s on s.name=d.name where s.tbl_name in ('_zova_vector_sources','_zova_vector_changes')", .{prefix}, 0));
        defer storage.deinit();
        try storage.bindTextBorrowed(1, if (bound) "vector_store" else "main");
        _ = try storage.step();
        std.debug.print("{s} journal_DBSTAT_bytes={d} payload_bytes={d} unused_bytes={d} projection_bytes={d}\n", .{ name, storage.columnInt64(0), storage.columnInt64(1), storage.columnInt64(2), @sizeOf(Projection) });
    }
}
