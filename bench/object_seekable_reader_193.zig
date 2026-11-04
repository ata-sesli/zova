//! One bounded read sample for issue #193.
//! Usage: binary NEW_DATABASE_PATH deduplication|streaming TOTAL_BYTES
//! Stores one deterministic incompressible object (untimed), then times, from
//! a warm cache: sequential 32 KiB reads through `readObjectRange` (capped at
//! 32 MiB, since it hashes a whole chunk per call), `ObjectReader`, and
//! `ObjectSeekableReader`; then 256 random 64 KiB reads through
//! `readObjectRange` and through a seek plus read on `ObjectSeekableReader`.
//! Every byte read is compared with the payload.
const std = @import("std");
const objects = @import("object_impl");

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn seconds(start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / 1_000_000_000;
}

fn mbPerS(bytes: usize, elapsed: f64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1_000_000 / elapsed;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.InvalidArgument;
    const profile = std.meta.stringToEnum(objects.ObjectStorageProfile, args[2]) orelse return error.InvalidArgument;
    const total_bytes = try std.fmt.parseInt(usize, args[3], 10);
    if (total_bytes < 1024 * 1024 or total_bytes > 1024 * 1024 * 1024) return error.InvalidArgument;

    const allocator = std.heap.c_allocator;
    const payload = try allocator.alloc(u8, total_bytes);
    defer allocator.free(payload);
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
    const id = try db.putObjectWithOptions(payload, .{ .profile = profile });

    var buffer: [64 * 1024]u8 = undefined;
    const small = buffer[0 .. 32 * 1024];

    // Warm the page cache once.
    {
        var reader = try db.objectReader(id);
        defer reader.deinit();
        while (try reader.read(&buffer) != 0) {}
    }

    const range_bytes = @min(total_bytes, 32 * 1024 * 1024);
    var start = now();
    var offset: usize = 0;
    while (offset < range_bytes) {
        const count = try db.readObjectRange(id, offset, small[0..@min(small.len, range_bytes - offset)]);
        if (!std.mem.eql(u8, payload[offset..][0..count], small[0..count])) return error.PayloadMismatch;
        offset += count;
    }
    const range_seq = mbPerS(range_bytes, seconds(start));

    start = now();
    offset = 0;
    {
        var reader = try db.objectReader(id);
        defer reader.deinit();
        while (true) {
            const count = try reader.read(small);
            if (count == 0) break;
            if (!std.mem.eql(u8, payload[offset..][0..count], small[0..count])) return error.PayloadMismatch;
            offset += count;
        }
    }
    if (offset != total_bytes) return error.ShortRead;
    const reader_seq = mbPerS(total_bytes, seconds(start));

    var seekable = try db.objectSeekableReader(allocator, id);
    defer seekable.deinit();
    start = now();
    offset = 0;
    while (true) {
        const count = try seekable.read(small);
        if (count == 0) break;
        if (!std.mem.eql(u8, payload[offset..][0..count], small[0..count])) return error.PayloadMismatch;
        offset += count;
    }
    if (offset != total_bytes) return error.ShortRead;
    const seekable_seq = mbPerS(total_bytes, seconds(start));

    var range_ms: [256]f64 = undefined;
    var seekable_ms: [256]f64 = undefined;
    var prng = std.Random.DefaultPrng.init(0x193);
    for (&range_ms, &seekable_ms) |*range_sample, *seekable_sample| {
        const position = prng.random().uintLessThan(usize, total_bytes - buffer.len);
        var sample_start = now();
        _ = try db.readObjectRange(id, position, &buffer);
        range_sample.* = seconds(sample_start) * 1000;
        if (!std.mem.eql(u8, payload[position..][0..buffer.len], &buffer)) return error.PayloadMismatch;

        sample_start = now();
        seekable.seekTo(position);
        var filled: usize = 0;
        while (filled < buffer.len) filled += try seekable.read(buffer[filled..]);
        seekable_sample.* = seconds(sample_start) * 1000;
        if (!std.mem.eql(u8, payload[position..][0..buffer.len], &buffer)) return error.PayloadMismatch;
    }
    std.mem.sort(f64, &range_ms, {}, std.sort.asc(f64));
    std.mem.sort(f64, &seekable_ms, {}, std.sort.asc(f64));

    std.debug.print(
        "profile={s} total_bytes={d} range_32k_seq_mb_s={d:.1} object_reader_32k_mb_s={d:.1} seekable_32k_seq_mb_s={d:.1} " ++
            "range_64k_random_p50_ms={d:.3} range_64k_random_p95_ms={d:.3} seekable_64k_random_p50_ms={d:.3} seekable_64k_random_p95_ms={d:.3}\n",
        .{ args[2], total_bytes, range_seq, reader_seq, seekable_seq, range_ms[128], range_ms[243], seekable_ms[128], seekable_ms[243] },
    );
}
