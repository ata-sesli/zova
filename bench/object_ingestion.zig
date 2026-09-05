//! One bounded ingestion sample; invoke baseline/candidate in alternating order.
//! Usage: binary NEW_DATABASE_PATH deduplication|streaming
//! Fixture: 1 MiB deterministic bytes. No reads, writers, or broad storage sweep.
const std = @import("std");
const objects = @import("object_impl");

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn ms(start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / 1_000_000;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArgument;
    const profile = std.meta.stringToEnum(objects.ObjectStorageProfile, args[2]) orelse return error.InvalidArgument;
    const payload = try allocator.alloc(u8, 1024 * 1024);
    var state: u64 = 0x5a6f7661;
    for (payload) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }
    var raw = try objects.sqlite.Database.open(try allocator.dupeZ(u8, args[1]));
    defer raw.deinit();
    try raw.exec(objects.objects_schema_sql ++ ";" ++ objects.chunks_schema_sql ++ ";" ++ objects.object_chunks_schema_sql ++ ";");
    var db = objects.Database.initForPrototype(&raw, .main);
    const hash_start = now();
    const expected = objects.objectId(payload);
    const hash_ms = ms(hash_start);
    const start = now();
    const id = try db.putObjectWithOptions(payload, .{ .profile = profile });
    const fresh_ms = ms(start);
    if (!std.mem.eql(u8, &expected, &id)) return error.HashMismatch;
    const duplicate_start = now();
    for (0..32) |_| {
        const duplicate = try db.putObjectWithOptions(payload, .{ .profile = profile });
        if (!std.mem.eql(u8, &id, &duplicate)) return error.HashMismatch;
    }
    std.debug.print("profile={s} bytes={d} hash_ms={d:.6} fresh_ms={d:.6} duplicate_ms={d:.6}\n", .{
        args[2], payload.len, hash_ms, fresh_ms, ms(duplicate_start) / 32,
    });
}
