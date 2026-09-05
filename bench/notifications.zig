const std = @import("std");
const zova = @import("zova");

const events_per_iteration = 256;
const kv_batch_entries = 4096;
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

fn median(samples_slice: []f64) f64 {
    return percentile(samples_slice, 50, 100);
}

fn medianAbsoluteDeviation(samples_slice: []f64, median_value: f64) f64 {
    const deviations = std.heap.c_allocator.alloc(f64, samples_slice.len) catch return 0;
    defer std.heap.c_allocator.free(deviations);
    for (samples_slice, 0..) |sample, index| {
        deviations[index] = @abs(sample - median_value);
    }
    return percentile(deviations, 50, 100);
}

fn printDistribution(label: []const u8, samples_slice: []f64) void {
    const p50 = median(samples_slice);
    const mad = medianAbsoluteDeviation(samples_slice, p50);
    const p95 = percentile(samples_slice, 95, 100);
    std.debug.print("{s} median_ms={d:.6} mad_ms={d:.6} p95_ms={d:.6}\n", .{ label, p50, mad, p95 });
}

fn nextRandom(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.*;
}

fn receiveOne(sub: *zova.NotificationSubscription) !void {
    var note = (try sub.tryReceive(std.heap.c_allocator)).?;
    note.deinit(std.heap.c_allocator);
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
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "queue")) return queueBenchmark();

    std.debug.print("seed=0x{x} zig={s} sqlite={s} queue_capacity={d} events_per_iteration={d} kv_batch_entries={d}\n", .{
        seed,
        @import("builtin").zig_version_string,
        zova.version.sqlite_version,
        queue_capacity,
        events_per_iteration,
        kv_batch_entries,
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
        // Baseline: transaction commit with no notification.
        for (0..warmups + samples) |index| {
            const start = now();
            try db.beginImmediate();
            try db.commit();
            if (index >= warmups) samples_slice[index - warmups] = elapsedMs(start);
        }
        printDistribution("commit_no_notify", &samples_slice);
    }

    {
        // Commit with one notification, delivered and received after commit.
        var sub = try db.listen("bench:one");
        defer sub.deinit();
        for (0..warmups + samples) |index| {
            const start = now();
            try db.beginImmediate();
            try db.notify("bench:one", payloads_slice[0]);
            try db.commit();
            try receiveOne(&sub);
            if (index >= warmups) samples_slice[index - warmups] = elapsedMs(start);
        }
        printDistribution("commit_one_notify", &samples_slice);
    }

    {
        // Commit with one notification, but no listener receives it (delivery cost only).
        for (0..warmups + samples) |index| {
            const start = now();
            try db.beginImmediate();
            try db.notify("bench:no-listener", payloads_slice[0]);
            try db.commit();
            if (index >= warmups) samples_slice[index - warmups] = elapsedMs(start);
        }
        printDistribution("commit_one_notify_no_receive", &samples_slice);
    }

    {
        // Commit with multiple listeners, each draining the same 256-event batch.
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
        printDistribution("commit_256_four_listeners", &samples_slice);
    }

    {
        // One shared deterministic unique entry array for the aggregate case so
        // the no-notify and one-notify sides run the same batch. Keys are
        // `k-0` through `k-<kv_batch_entries - 1>` to match every binding.
        const entries = try allocator.alloc(zova.KvPutEntry, kv_batch_entries);
        for (entries, 0..) |*entry, index| {
            entry.* = .{
                .key = try std.fmt.allocPrint(allocator, "k-{d}", .{index}),
                .value = "v",
            };
        }
        for (0..warmups + samples) |index| {
            const start = now();
            try db.beginImmediate();
            try db.kvPutMany("bench:kv", entries);
            try db.commit();
            if (index >= warmups) samples_slice[index - warmups] = elapsedMs(start);
        }
        printDistribution("kv_batch_4096_commit_no_notify", &samples_slice);

        var sub = try db.listen("cache:search-results");
        defer sub.deinit();
        for (0..warmups + samples) |index| {
            const start = now();
            try db.beginImmediate();
            try db.kvPutMany("bench:kv", entries);
            try db.notify("cache:search-results", "generation:42");
            try db.commit();
            try receiveOne(&sub);
            if (index >= warmups) samples_slice[index - warmups] = elapsedMs(start);
        }
        printDistribution("kv_batch_4096_commit_one_notify", &samples_slice);
    }

    {
        // Queue receive overhead: prefill a 256-event queue, then time only
        // draining it.
        var sub = try db.listen("bench:receive");
        defer sub.deinit();
        for (0..warmups + samples) |index| {
            for (payloads_slice) |payload| {
                try db.notify("bench:receive", payload);
            }
            const start = now();
            try receiveAll(&sub);
            if (index >= warmups) samples_slice[index - warmups] = elapsedMs(start);
        }
        printDistribution("receive_256_prefilled", &samples_slice);
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
        printDistribution("notify_256_overflow_drop_oldest", &samples_slice);
    }
}

// Bounded queue-only mode: no KV workload or durable transactions. Each line
// reports the mean of 32 bursts, with enqueue and drain timed separately.
fn queueBenchmark() !void {
    const rounds = 32;
    for ([_]usize{ 1, 16, 256, 1024, 2048 }) |depth| {
        var counter = std.testing.FailingAllocator.init(std.heap.c_allocator, .{});
        var db = try zova.Database.createMemory();
        defer db.deinit();
        // The newly initialized hub owns no subscription/scope allocations yet.
        std.debug.assert(db.notifications.subscriptions.items.len == 0 and db.notifications.scopes.items.len == 0);
        db.notifications.allocator = counter.allocator();
        var sub = try db.listen("bench:queue");
        defer sub.deinit();
        var enqueue_ns: i128 = 0;
        var drain_ns: i128 = 0;
        const before = counter.allocations;
        const retained = @min(depth, queue_capacity);
        for (0..rounds) |round| {
            var start = now();
            for (0..depth) |_| try db.notify("bench:queue", "event");
            enqueue_ns += start.durationTo(now()).toNanoseconds();
            start = now();
            for (0..retained) |index| {
                var note = (try sub.tryReceive(counter.allocator())) orelse return error.MissingNotification;
                defer note.deinit(counter.allocator());
                if (note.sequence != round * depth + depth - retained + index + 1 or
                    note.dropped_before != (if (index == 0) depth - retained else @as(usize, 0)) or
                    !std.mem.eql(u8, note.payload, "event")) return error.BadNotification;
            }
            drain_ns += start.durationTo(now()).toNanoseconds();
            if (try sub.tryReceive(counter.allocator()) != null) return error.ExtraNotification;
        }
        std.debug.print("depth={d} enqueue_us={d:.6} drain_us={d:.6} allocations={d} retained_bytes={d}\n", .{
            depth,
            @as(f64, @floatFromInt(enqueue_ns)) / rounds / 1000,
            @as(f64, @floatFromInt(drain_ns)) / rounds / 1000,
            counter.allocations - before,
            counter.allocated_bytes - counter.freed_bytes,
        });
    }
}
