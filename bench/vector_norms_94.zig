//! One bounded vector-write sample for issues #94 and #159.
//! Usage: binary NEW_DATABASE_PATH f32|f16|i8 COUNT fresh|replay|single|delete [bound]
//! Fixture: deterministic 384-dimension vectors (seed 0x5a6f7661).
//! Fresh: create collection then one putVectors of COUNT vectors.
//! Replay: populate once before timing one upsert batch.
//! Single: COUNT putVector calls inside one caller transaction, commit included.
//! Delete: populate once before timing one deleteVectors batch.
//! Bound: the collection lives in NEW_DATABASE_PATH.vectors.zova, bound before use.
//! Uses the public transaction-owning facade, not the internal vector layer.
//! Full payload read-back is verified outside the timed operation.
const std = @import("std");
const vector = @import("zova");

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn ms(start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / 1_000_000;
}

const dimensions = 384;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5 and args.len != 6) return error.InvalidArgument;
    const element_type = std.meta.stringToEnum(vector.VectorElementType, args[2]) orelse return error.InvalidArgument;
    const count = try std.fmt.parseInt(usize, args[3], 10);
    if (count == 0 or count > 4096) return error.InvalidArgument;
    const Mode = enum { fresh, replay, single, delete };
    const mode = std.meta.stringToEnum(Mode, args[4]) orelse return error.InvalidArgument;
    const bound = args.len == 6;
    if (bound and !std.mem.eql(u8, args[5], "bound")) return error.InvalidArgument;

    var db = try vector.Database.create(try allocator.dupeSentinel(u8, args[1], 0));
    defer db.deinit();
    if (bound) {
        const store = try std.fmt.allocPrintSentinel(allocator, "{s}.vectors.zova", .{args[1]}, 0);
        try vector.createVectorStore(store);
        try db.bindVectorStore(store);
    }
    try db.createVectorCollection("bench", .{ .dimensions = dimensions, .metric = .cosine, .element_type = element_type });

    // Deterministic incompressible values with a nonzero norm.
    var f32_values = try allocator.alloc(f32, count * dimensions);
    var f16_values = try allocator.alloc(u16, count * dimensions);
    var i8_values = try allocator.alloc(i8, count * dimensions);
    var state: u64 = 0x5a6f7661;
    for (0..count * dimensions) |index| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const sample: u32 = @truncate(state >> 33);
        const scaled: f32 = @as(f32, @floatFromInt(sample % 2001)) / 1000.0 - 1.0;
        f32_values[index] = scaled;
        f16_values[index] = @as(u16, @bitCast(@as(f16, @floatCast(scaled))));
        i8_values[index] = @intFromFloat(std.math.clamp(scaled * 100.0, -128.0, 127.0));
    }

    const inputs = try allocator.alloc(vector.VectorInput, count);
    for (0..count) |row| {
        inputs[row] = .{
            .id = try std.fmt.allocPrint(allocator, "vec-{d}", .{row}),
            .values = switch (element_type) {
                .f32 => .{ .f32 = f32_values[row * dimensions .. (row + 1) * dimensions] },
                .f16 => .{ .f16 = f16_values[row * dimensions .. (row + 1) * dimensions] },
                .i8 => .{ .i8 = i8_values[row * dimensions .. (row + 1) * dimensions] },
            },
        };
    }

    const ids = try allocator.alloc([]const u8, count);
    for (inputs, ids) |input, *id| id.* = input.id;

    if (mode == .replay or mode == .delete) try db.putVectors("bench", inputs);
    const start = now();
    switch (mode) {
        .fresh, .replay => try db.putVectors("bench", inputs),
        .single => {
            try db.beginImmediate();
            for (inputs) |input| try db.putVector("bench", input.id, input.values);
            try db.commit();
        },
        .delete => try db.deleteVectors("bench", ids),
    }
    const total_ms = ms(start);

    for (inputs) |input| {
        if (mode == .delete) {
            if (try db.hasVector("bench", input.id)) return error.VectorMismatch;
            continue;
        }
        var result = try db.getVector(allocator, "bench", input.id);
        defer result.deinit(allocator);
        const equal = switch (input.values) {
            .f32 => |values| std.mem.eql(f32, values, result.values.f32),
            .f16 => |values| std.mem.eql(u16, values, result.values.f16),
            .i8 => |values| std.mem.eql(i8, values, result.values.i8),
        };
        if (!equal) return error.VectorMismatch;
    }

    std.debug.print("type={s} count={d} mode={s} store={s} total_ms={d:.6} per_pass_ms={d:.6}\n", .{
        args[2], count, args[4], if (bound) "bound" else "main", total_ms, total_ms,
    });
}
