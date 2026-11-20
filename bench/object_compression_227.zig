//! One bounded object ingest-and-read sample for issue #227.
//! Usage: binary NEW_DATABASE_PATH deduplication|streaming none|lz4 text|noise TOTAL_BYTES
//! Fixtures: `text` is deterministic log-like lines (compressible), `noise`
//! is deterministic incompressible bytes. Default rollback journal, 4 KiB
//! pages, `foreign_keys = on`. Timed regions:
//! - ingest: `ObjectWriter` with 8 MiB writes, through `finish`;
//! - from a warm cache: `getObject`, sequential 64 KiB `ObjectReader` and
//!   `ObjectSeekableReader` reads, and 256 random 64 KiB reads through
//!   `readObjectRange` and a seek plus read on `ObjectSeekableReader`.
//! Payload generation and comparisons are untimed. Every read is compared
//! with the payload. Builds against trees without `ObjectCompression`
//! (the pre-#227 baseline) accept only `none`.
const std = @import("std");
const objects = @import("object_impl");

const has_compression = @hasDecl(objects, "ObjectCompression");
const write_bytes = 8 * 1024 * 1024;

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn seconds(start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / 1_000_000_000;
}

fn mbPerS(bytes: usize, elapsed: f64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1_000_000 / elapsed;
}

const Lcg = struct {
    state: u64 = 0x5a6f7661,
    fn next(self: *Lcg) u32 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return @truncate(self.state >> 32);
    }
};

fn fillNoise(payload: []u8) void {
    var lcg: Lcg = .{};
    for (payload) |*byte| byte.* = @truncate(lcg.next());
}

fn fillText(payload: []u8) void {
    const levels = [_][]const u8{ "INFO", "INFO", "INFO", "DEBUG", "WARN", "ERROR" };
    const services = [_][]const u8{ "api", "worker", "scheduler", "billing", "search" };
    const methods = [_][]const u8{ "GET", "GET", "GET", "POST", "PUT", "DELETE" };
    const statuses = [_]u32{ 200, 200, 200, 200, 201, 204, 304, 404, 500 };
    var lcg: Lcg = .{};
    var line: [256]u8 = undefined;
    var offset: usize = 0;
    var timestamp: u64 = 1_790_000_000_000;
    while (offset < payload.len) {
        timestamp += lcg.next() % 50;
        const text = std.fmt.bufPrint(&line, "{d} level={s} service={s} request={x:0>8}{x:0>8} method={s} path=/api/v1/items/{d} status={d} bytes={d} duration_ms={d}\n", .{
            timestamp,
            levels[lcg.next() % levels.len],
            services[lcg.next() % services.len],
            lcg.next(),
            lcg.next(),
            methods[lcg.next() % methods.len],
            lcg.next() % 100_000,
            statuses[lcg.next() % statuses.len],
            lcg.next() % 65_536,
            lcg.next() % 2_000,
        }) catch unreachable;
        const len = @min(text.len, payload.len - offset);
        @memcpy(payload[offset..][0..len], text[0..len]);
        offset += len;
    }
}

fn queryInt(raw: *objects.sqlite.Database, sql: [:0]const u8) !i64 {
    var statement = try raw.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.NoRow;
    return statement.columnInt64(0);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 6) return error.InvalidArgument;
    const profile = std.meta.stringToEnum(objects.ObjectStorageProfile, args[2]) orelse return error.InvalidArgument;
    const lz4 = if (std.mem.eql(u8, args[3], "lz4")) true else if (std.mem.eql(u8, args[3], "none")) false else return error.InvalidArgument;
    if (lz4 and !has_compression) return error.InvalidArgument;
    const text = if (std.mem.eql(u8, args[4], "text")) true else if (std.mem.eql(u8, args[4], "noise")) false else return error.InvalidArgument;
    const total_bytes = try std.fmt.parseInt(usize, args[5], 10);
    if (total_bytes < 1024 * 1024 or total_bytes > 1024 * 1024 * 1024) return error.InvalidArgument;

    const allocator = std.heap.c_allocator;
    const payload = try allocator.alloc(u8, total_bytes);
    defer allocator.free(payload);
    if (text) fillText(payload) else fillNoise(payload);

    var raw = try objects.sqlite.Database.open(try arena.dupeSentinel(u8, args[1], 0));
    defer raw.deinit();
    try raw.exec("pragma foreign_keys = on");
    try raw.exec(objects.objects_schema_sql ++ ";" ++ objects.chunks_schema_sql ++ ";" ++ objects.object_chunks_schema_sql ++ ";");
    var db = objects.Database.initForPrototype(&raw, .main);
    if (has_compression and lz4) db.compression = .lz4;

    var start = now();
    const id = blk: {
        var writer = try db.objectWriterWithOptions(allocator, .{ .profile = profile });
        defer writer.deinit();
        var offset: usize = 0;
        while (offset < payload.len) {
            const len = @min(write_bytes, payload.len - offset);
            try writer.write(payload[offset .. offset + len]);
            offset += len;
        }
        break :blk try writer.finish();
    };
    const ingest = mbPerS(total_bytes, seconds(start));
    if (!std.mem.eql(u8, &objects.objectId(payload), &id)) return error.HashMismatch;

    const file_bytes = try queryInt(&raw, "pragma page_count") * try queryInt(&raw, "pragma page_size");
    const chunks = try queryInt(&raw, "select count(*) from _zova_chunks");
    const lz4_chunks = if (has_compression) try queryInt(&raw, "select count(*) from _zova_chunks where encoding = 1") else 0;

    var buffer: [64 * 1024]u8 = undefined;
    // Warm the page cache once.
    {
        var reader = try db.objectReader(id);
        defer reader.deinit();
        while (try reader.read(&buffer) != 0) {}
    }

    start = now();
    var object = try db.getObject(allocator, id);
    const get_object = mbPerS(total_bytes, seconds(start));
    if (!std.mem.eql(u8, payload, object.bytes)) return error.PayloadMismatch;
    object.deinit(allocator);

    start = now();
    var offset: usize = 0;
    var compare_seconds: f64 = 0;
    {
        var reader = try db.objectReader(id);
        defer reader.deinit();
        while (true) {
            const count = try reader.read(&buffer);
            if (count == 0) break;
            const compare_start = now();
            if (!std.mem.eql(u8, payload[offset..][0..count], buffer[0..count])) return error.PayloadMismatch;
            compare_seconds += seconds(compare_start);
            offset += count;
        }
    }
    if (offset != total_bytes) return error.ShortRead;
    const reader_seq = mbPerS(total_bytes, seconds(start) - compare_seconds);

    var seekable = try db.objectSeekableReader(allocator, id);
    defer seekable.deinit();
    start = now();
    offset = 0;
    compare_seconds = 0;
    while (true) {
        const count = try seekable.read(&buffer);
        if (count == 0) break;
        const compare_start = now();
        if (!std.mem.eql(u8, payload[offset..][0..count], buffer[0..count])) return error.PayloadMismatch;
        compare_seconds += seconds(compare_start);
        offset += count;
    }
    if (offset != total_bytes) return error.ShortRead;
    const seekable_seq = mbPerS(total_bytes, seconds(start) - compare_seconds);

    var range_ms: [256]f64 = undefined;
    var seekable_ms: [256]f64 = undefined;
    var prng = std.Random.DefaultPrng.init(0x227);
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
        "profile={s} compression={s} data={s} total_bytes={d} file_bytes={d} chunks={d} lz4_chunks={d} ingest_mb_s={d:.1} " ++
            "get_object_mb_s={d:.1} object_reader_64k_mb_s={d:.1} seekable_64k_seq_mb_s={d:.1} " ++
            "range_64k_random_p50_ms={d:.3} seekable_64k_random_p50_ms={d:.3}\n",
        .{ args[2], args[3], args[4], total_bytes, file_bytes, chunks, lz4_chunks, ingest, get_object, reader_seq, seekable_seq, range_ms[128], seekable_ms[128] },
    );
}
