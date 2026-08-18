const std = @import("std");
const zova = @import("zova");

const events_per_iteration = 256;
const warmups = 20;
const samples = 100;
const queue_capacity = 1024;
const seed: u64 = 0x4e6f74696679;

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const ns = start.durationTo(now()).toNanoseconds();
    return if (ns <= 0) 0 else @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

fn percentile(samples_slice: []f64, numerator: usize, denominator: usize) f64 {
    std.mem.sort(f64, samples_slice, {}, std.sort.asc(f64));
    const index = @min(samples_slice.len - 1, (samples_slice.len * numerator + denominator - 1) / denominator - 1);
    return samples_slice[index];
}

fn printDistribution(label: []const u8, samples_slice: []f64) void {
    const p50 = percentile(samples_slice, 50, 100);
    const p95 = percentile(samples_slice, 95, 100);
    std.debug.print("{s} p50_ms={d:.6} p95_ms={d:.6}\n", .{ label, p50, p95 });
}

fn nextRandom(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.*;
}

fn receiveAll(sub: *zova.NotificationSubscription) !void {
    var count: usize = 0;
    while (count < events_per_iteration) : (count += 1) {
        var note = (try sub.tryReceive(std.heap.c_allocator)).?;
        note.deinit(std.heap.c_allocator);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    std.debug.print("seed=0x{x} zig={s} sqlite={s} queue_capacity={d} events_per_iteration={d}\n", .{
        seed,
        @import("builtin").zig_version_string,
        zova.version.sqlite_version,
        queue_capacity,
        events_per_iteration,
    });

    var db = try zova.Database.createMemory();
    defer db.deinit();

    const payloads_slice = try allocator.alloc([]const u8, events_per_iteration);
    var state = seed;
    for (payloads_slice) |*payload| {
        payload.* = try std.fmt.allocPrint(allocator, "event-{x}", .{nextRandom(&state) & 0xffff});
    }
    var samples_slice: [samples]f64 = undefined;

    {
        var sub = try db.listen("bench:single");
        defer sub.deinit();
        for (0..warmups + samples) |index| {
            const start = now();
            for (payloads_slice) |payload| {
                try db.notify("bench:single", payload);
            }
            try receiveAll(&sub);
            if (index >= warmups) samples_slice[index - warmups] = elapsedMs(start);
        }
        printDistribution("notify_single_256_delivered", &samples_slice);
    }

    {
        var sub = try db.listen("bench:transaction");
        defer sub.deinit();
        for (0..warmups + samples) |index| {
            const start = now();
            try db.beginImmediate();
            for (payloads_slice) |payload| {
                try db.notify("bench:transaction", payload);
            }
            try db.commit();
            try receiveAll(&sub);
            if (index >= warmups) samples_slice[index - warmups] = elapsedMs(start);
        }
        printDistribution("notify_transaction_256_committed", &samples_slice);
    }

    {
        const subs = try allocator.alloc(zova.NotificationSubscription, 4);
        for (subs) |*listener| listener.* = try db.listen("bench:multi");
        defer for (subs) |*listener| listener.deinit();

        for (0..warmups + samples) |index| {
            const start = now();
            try db.beginImmediate();
            for (payloads_slice) |payload| {
                try db.notify("bench:multi", payload);
            }
            try db.commit();
            for (subs) |*listener| {
                try receiveAll(listener);
            }
            if (index >= warmups) samples_slice[index - warmups] = elapsedMs(start);
        }
        printDistribution("notify_transaction_256_four_listeners", &samples_slice);
    }

    {
        var sub = try db.listen("bench:overflow");
        defer sub.deinit();
        for (0..warmups + samples) |index| {
            const start = now();
            for (payloads_slice) |payload| {
                try db.notify("bench:overflow", payload);
            }
            var note = (try sub.tryReceive(std.heap.c_allocator)).?;
            note.deinit(std.heap.c_allocator);
            if (index >= warmups) samples_slice[index - warmups] = elapsedMs(start);
        }
        printDistribution("notify_overflow_256_dropped_oldest", &samples_slice);
    }
}