const std = @import("std");
const zova = @import("zova");

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const short_only = args.len == 2 and std.mem.eql(u8, args[1], "short");
    if (args.len > 2 or (args.len == 2 and !short_only)) return error.InvalidArgument;
    for ([_]u32{ 33, 384 }) |dimensions| {
        if (short_only and dimensions != 33) continue;
        for ([_]zova.VectorElementType{ .f32, .f16 }) |element_type| {
            for ([_]zova.VectorMetric{ .cosine, .dot, .l2 }) |metric| {
                var db = try zova.Database.createMemory();
                defer db.deinit();
                try db.createVectorCollection("bench", .{ .dimensions = dimensions, .metric = metric, .element_type = element_type });
                const floats = try allocator.alloc(f32, dimensions);
                const halves = try allocator.alloc(u16, dimensions);
                var ids: [128][]const u8 = undefined;
                try db.begin();
                for (&ids, 0..) |*id, row| {
                    id.* = try std.fmt.allocPrint(allocator, "v-{d:0>3}", .{row});
                    for (floats, halves, 0..) |*f, *h, col| {
                        const n: i32 = @as(i32, @intCast((row * 17 + col * 13) % 127)) - 63;
                        f.* = @as(f32, @floatFromInt(n)) / 16;
                        h.* = @bitCast(@as(f16, @floatCast(f.*)));
                    }
                    try db.putVector("bench", id.*, if (element_type == .f32) .{ .f32 = floats } else .{ .f16 = halves });
                }
                try db.commit();
                const query: zova.VectorValuesConst = if (element_type == .f32) .{ .f32 = floats } else .{ .f16 = halves };
                for ([_][]const u8{ "full", "candidate", "prepare" }) |path| {
                    const Sample = struct { ns: i96, allocations: usize, bytes: usize, digest: u64 };
                    var samples: [256]Sample = undefined;
                    const warmups = 16;
                    for (0..warmups + samples.len) |sample| {
                        var counter = std.testing.FailingAllocator.init(std.heap.c_allocator, .{});
                        const start = now();
                        var result = if (std.mem.eql(u8, path, "candidate"))
                            try db.searchVectorsIn(counter.allocator(), "bench", query, ids[0..16], 10)
                        else
                            try db.searchVectors(counter.allocator(), "bench", query, if (std.mem.eql(u8, path, "prepare")) 0 else 10);
                        const elapsed = start.durationTo(now()).toNanoseconds();
                        var hash = std.hash.Wyhash.init(0x5a6f7661);
                        for (result.items) |item| {
                            hash.update(item.id);
                            hash.update(std.mem.asBytes(&item.distance));
                        }
                        result.deinit(counter.allocator());
                        if (sample >= warmups) samples[sample - warmups] = .{ .ns = elapsed, .allocations = counter.allocations, .bytes = counter.allocated_bytes, .digest = hash.final() };
                    }
                    // Keep formatting and output outside the sampling loop.
                    for (samples, 1..) |sample, index| {
                        std.debug.print("type={s} metric={s} dimensions={d} path={s} sample={d} us={d:.6} allocations={d} allocated_bytes={d} digest={x}\n", .{
                            @tagName(element_type),                    @tagName(metric),   dimensions,   path,          index,
                            @as(f64, @floatFromInt(sample.ns)) / 1000, sample.allocations, sample.bytes, sample.digest,
                        });
                    }
                }
            }
        }
    }
}
