//! One bounded `ObjectWriter` ingest sample for issue #196.
//! Usage: binary NEW_DATABASE_PATH deduplication|streaming WRITE_BYTES TOTAL_BYTES
//! Fixture: deterministic incompressible bytes, default rollback journal,
//! 4 KiB pages, `foreign_keys = on`. The timed region covers every `write`
//! call and `finish`; payload generation is untimed. The stored object id is
//! checked against SHA-256 of the payload.
const std = @import("std");
const objects = @import("object_impl");

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn seconds(start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / 1_000_000_000;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) return error.InvalidArgument;
    const profile = std.meta.stringToEnum(objects.ObjectStorageProfile, args[2]) orelse return error.InvalidArgument;
    const write_bytes = try std.fmt.parseInt(usize, args[3], 10);
    const total_bytes = try std.fmt.parseInt(usize, args[4], 10);
    if (write_bytes == 0 or total_bytes == 0 or total_bytes > 1024 * 1024 * 1024) return error.InvalidArgument;

    const payload = try std.heap.c_allocator.alloc(u8, total_bytes);
    defer std.heap.c_allocator.free(payload);
    var state: u64 = 0x5a6f7661;
    for (payload) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }

    var raw = try objects.sqlite.Database.open(try arena.dupeSentinel(u8, args[1], 0));
    defer raw.deinit();
    try raw.exec("pragma foreign_keys = on");
    try raw.exec(objects.objects_schema_sql ++ ";" ++ objects.chunks_schema_sql ++ ";" ++ objects.object_chunks_schema_sql ++ ";");
    var db = objects.Database.initForPrototype(&raw, .main);

    const start = now();
    var writer = try db.objectWriterWithOptions(std.heap.c_allocator, .{ .profile = profile });
    defer writer.deinit();
    var offset: usize = 0;
    while (offset < payload.len) {
        const len = @min(write_bytes, payload.len - offset);
        try writer.write(payload[offset .. offset + len]);
        offset += len;
    }
    const id = try writer.finish();
    const elapsed = seconds(start);

    if (!std.mem.eql(u8, &objects.objectId(payload), &id)) return error.HashMismatch;
    const mb_per_s = @as(f64, @floatFromInt(total_bytes)) / 1_000_000 / elapsed;
    std.debug.print("profile={s} write_bytes={d} total_bytes={d} seconds={d:.3} mb_per_s={d:.1}\n", .{ args[2], write_bytes, total_bytes, elapsed, mb_per_s });
}
