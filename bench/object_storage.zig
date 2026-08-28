//! Object-storage profile measurements.
//!
//! This benchmark exercises the existing FastCDC-v1 policy and the isolated
//! fixed-1 MiB prototype schema side by side. It does not change the
//! production format-10 schema or activate the fixed profile for normal
//! Database.create callers.

const std = @import("std");
const object_impl = @import("object_impl");
const sqlite = object_impl.sqlite;
const version = @import("version_impl");

const default_payload_bytes: usize = 16 * 1024 * 1024;
const measured_runs = 7;
const warmup_runs = 1;
const random_range_count = 64;
const sequential_buffer_bytes = 64 * 1024;
const random_range_bytes = 64 * 1024;
const seed: u64 = 0x5a6f7661;
const fixed_chunk_size: u128 = 1024 * 1024;
const one_tib_bytes: u128 = 1024 * 1024 * 1024 * 1024;

const BenchmarkProfile = enum {
    fastcdc,
    fixed_1m,
};

const prototype_objects_schema_sql =
    \\create table _zova_objects (
    \\  object_id blob not null primary key check (length(object_id) = 32),
    \\  size_bytes integer not null check (size_bytes >= 0),
    \\  chunk_count integer not null check (chunk_count >= 0),
    \\  chunker text not null check (chunker in ('fastcdc-v1', 'fixed-1m-v1'))
    \\)
;
const prototype_chunks_schema_sql =
    \\create table _zova_chunks (
    \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
    \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 1048576),
    \\  data blob not null check (length(data) = size_bytes)
    \\)
;
const prototype_object_chunks_schema_sql =
    \\create table _zova_object_chunks (
    \\  object_id blob not null check (length(object_id) = 32),
    \\  chunk_index integer not null check (chunk_index >= 0),
    \\  chunk_hash blob not null check (length(chunk_hash) = 32),
    \\  offset integer not null check (offset >= 0),
    \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 1048576),
    \\  primary key (object_id, chunk_index),
    \\  foreign key (object_id) references _zova_objects(object_id),
    \\  foreign key (chunk_hash) references _zova_chunks(chunk_hash)
    \\)
;

const Sample = struct {
    put_ms: f64,
    writer_ms: f64,
    whole_read_ms: f64,
    sequential_64k_ms: f64,
    sequential_reader_ms: f64,
    random_64k_ms: f64,
    random_64k_p50_ms: f64,
    random_64k_p95_ms: f64,
    manifest_ms: f64,
    delete_gc_ms: f64,
    integrity_ms: f64,
    chunk_rows: i64,
    manifest_rows: i64,
    object_file_bytes: u64,
    object_dbstat_bytes: i64,
    writer_chunks_len: usize,
    writer_chunks_capacity: usize,
    writer_seen_chunks_len: usize,
    writer_seen_chunks_capacity: usize,
    writer_chunker_buffer_capacity: usize,
    writer_metadata_bytes: u64,
};

const WriterMeasurement = struct {
    elapsed_ms: f64,
    descriptors: object_impl.ObjectWriter.DescriptorMetrics,
    metadata_bytes: u64,
};

fn writerMetadataBytes(descriptors: object_impl.ObjectWriter.DescriptorMetrics) u64 {
    const bytes: u128 =
        @as(u128, @intCast(descriptors.chunks_capacity)) * @sizeOf(object_impl.ObjectChunk) +
        @as(u128, @intCast(descriptors.seen_chunks_capacity)) * @sizeOf(object_impl.ObjectChunkId) +
        descriptors.chunker_buffer_capacity;
    return @intCast(bytes);
}

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const ns = start.durationTo(now()).toNanoseconds();
    return if (ns <= 0) 0 else @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

fn median(values: []const f64) f64 {
    var sorted: [measured_runs]f64 = undefined;
    std.debug.assert(values.len == sorted.len);
    @memcpy(&sorted, values);
    std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
    return sorted[sorted.len / 2];
}

fn percentileSorted(values: []const f64, numerator: usize, denominator: usize) f64 {
    std.debug.assert(values.len > 0);
    const rank = (values.len * numerator + denominator - 1) / denominator;
    return values[@min(values.len - 1, rank - 1)];
}

fn mad(values: []const f64) f64 {
    const center = median(values);
    var deviations: [measured_runs]f64 = undefined;
    std.debug.assert(values.len == deviations.len);
    for (values, &deviations) |value, *deviation| deviation.* = @abs(value - center);
    return median(&deviations);
}

fn nextRandom(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.*;
}

fn fillPayload(payload: []u8) void {
    var state = seed;
    for (payload, 0..) |*byte, index| {
        const random = nextRandom(&state);
        byte.* = @truncate((random >> 32) ^ @as(u64, @intCast(index * 31 + index / 7)));
    }
}

fn deletePath(path: [:0]const u8) void {
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
}

fn fileBytes(path: [:0]const u8) !u64 {
    return (try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{})).size;
}

fn scalar(db: *sqlite.Database, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.InvalidBenchmarkResult;
    return stmt.columnInt64(0);
}

fn objectDbstatBytes(db: *sqlite.Database) !i64 {
    return scalar(db,
        \\select coalesce(sum(pgsize), 0)
        \\from dbstat
        \\where name like '_zova_objects%'
        \\   or name like '_zova_chunks%'
        \\   or name like '_zova_object_chunks%'
    );
}

fn runIntegrityCheck(db: *sqlite.Database) !void {
    var stmt = try db.prepare("pragma integrity_check");
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.InvalidBenchmarkResult;
    if (!std.mem.eql(u8, stmt.columnText(0), "ok")) return error.IntegrityCheckFailed;
}

fn readWhole(db: anytype, id: object_impl.ObjectId, expected: []const u8) !void {
    var object = try db.getObject(std.heap.c_allocator, id);
    defer object.deinit(std.heap.c_allocator);
    if (!std.mem.eql(u8, object.bytes, expected)) return error.ObjectMismatch;
}

fn readSequential64K(db: anytype, id: object_impl.ObjectId, expected: []const u8) !void {
    var buffer: [sequential_buffer_bytes]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const requested = @min(buffer.len, expected.len - offset);
        const count = try db.readObjectRange(id, offset, buffer[0..requested]);
        if (count != requested or !std.mem.eql(u8, buffer[0..count], expected[offset .. offset + count])) {
            return error.ObjectMismatch;
        }
        offset += count;
    }
}

fn readSequentialReader(db: anytype, id: object_impl.ObjectId, expected: []const u8) !void {
    var reader = try db.objectReader(id);
    defer reader.deinit();

    var buffer: [sequential_buffer_bytes]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const requested = @min(buffer.len, expected.len - offset);
        const count = try reader.read(buffer[0..requested]);
        if (count != requested or !std.mem.eql(u8, buffer[0..count], expected[offset .. offset + count])) {
            return error.ObjectMismatch;
        }
        offset += count;
    }
    if (try reader.read(buffer[0..0]) != 0) return error.ObjectMismatch;
}

const RandomTiming = struct {
    total_ms: f64,
    p50_ms: f64,
    p95_ms: f64,
};

fn readRandom64K(db: anytype, id: object_impl.ObjectId, expected: []const u8) !RandomTiming {
    if (expected.len < random_range_bytes) return error.InvalidBenchmarkInput;
    var buffer: [random_range_bytes]u8 = undefined;
    var timings: [random_range_count]f64 = undefined;
    var state = seed;
    const maximum_offset = expected.len - buffer.len;
    const total_start = now();
    for (0..random_range_count) |index| {
        const offset = @as(usize, @intCast(nextRandom(&state) % (maximum_offset + 1)));
        const operation_start = now();
        const count = try db.readObjectRange(id, offset, &buffer);
        if (count != buffer.len or !std.mem.eql(u8, buffer[0..count], expected[offset .. offset + count])) {
            return error.ObjectMismatch;
        }
        timings[index] = elapsedMs(operation_start);
    }
    const total_ms = elapsedMs(total_start);
    std.mem.sort(f64, &timings, {}, std.sort.asc(f64));
    return .{
        .total_ms = total_ms,
        .p50_ms = percentileSorted(&timings, 50, 100),
        .p95_ms = percentileSorted(&timings, 95, 100),
    };
}

fn runWriter(
    allocator: std.mem.Allocator,
    benchmark_dir: []const u8,
    payload: []const u8,
    ordinal: usize,
    profile: BenchmarkProfile,
) !WriterMeasurement {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/object-storage-writer-{d}.zova", .{ benchmark_dir, ordinal }, 0);
    defer deletePath(path);

    var raw = try sqlite.Database.open(path);
    defer raw.deinit();
    var db = try preparePrototypeDatabase(&raw);

    const start = now();
    var writer = try db.objectWriterWithOptions(std.heap.c_allocator, .{
        .profile = if (profile == .fastcdc) .deduplication else .streaming,
    });
    var offset: usize = 0;
    while (offset < payload.len) {
        const requested = @min(@as(usize, 37_919), payload.len - offset);
        try writer.write(payload[offset .. offset + requested]);
        offset += requested;
    }
    const id = try writer.finish();
    const descriptors = writer.descriptorMetrics();
    const metadata_bytes = writerMetadataBytes(descriptors);
    writer.deinit();
    try readWhole(&db, id, payload);
    return .{
        .elapsed_ms = elapsedMs(start),
        .descriptors = descriptors,
        .metadata_bytes = metadata_bytes,
    };
}

fn reportRuntimeSettings(db: anytype) !void {
    var page_size = try db.prepare("pragma page_size");
    defer page_size.deinit();
    if ((try page_size.step()) != .row) return error.InvalidBenchmarkResult;
    const page_size_value = page_size.columnInt64(0);

    var journal_mode = try db.prepare("pragma journal_mode");
    defer journal_mode.deinit();
    if ((try journal_mode.step()) != .row) return error.InvalidBenchmarkResult;
    const journal_mode_value = journal_mode.columnText(0);

    var cache_size = try db.prepare("pragma cache_size");
    defer cache_size.deinit();
    if ((try cache_size.step()) != .row) return error.InvalidBenchmarkResult;
    const cache_size_value = cache_size.columnInt64(0);

    var temp_store = try db.prepare("pragma temp_store");
    defer temp_store.deinit();
    if ((try temp_store.step()) != .row) return error.InvalidBenchmarkResult;
    const temp_store_value = temp_store.columnInt64(0);

    std.debug.print(
        "sqlite_settings page_size={d} journal_mode={s} cache_size={d} temp_store={d}\n",
        .{ page_size_value, journal_mode_value, cache_size_value, temp_store_value },
    );
}

fn preparePrototypeDatabase(raw: *sqlite.Database) !object_impl.Database {
    try raw.exec(prototype_objects_schema_sql ++ ";" ++ prototype_chunks_schema_sql ++ ";" ++ prototype_object_chunks_schema_sql ++ ";");
    return object_impl.Database.initForPrototype(raw, .main);
}
fn runSample(allocator: std.mem.Allocator, benchmark_dir: []const u8, payload: []const u8, ordinal: usize) !Sample {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/object-storage-{d}.zova", .{ benchmark_dir, ordinal }, 0);
    defer deletePath(path);

    var raw = try sqlite.Database.open(path);
    defer raw.deinit();
    var db = try preparePrototypeDatabase(&raw);
    if (ordinal == 0) try reportRuntimeSettings(&raw);

    const put_start = now();
    const id = try db.putObjectWithOptions(payload, .{ .profile = .deduplication });
    const put_ms = elapsedMs(put_start);

    const whole_start = now();
    try readWhole(&db, id, payload);
    const whole_read_ms = elapsedMs(whole_start);

    const sequential_start = now();
    try readSequential64K(&db, id, payload);
    const sequential_64k_ms = elapsedMs(sequential_start);

    const reader_start = now();
    try readSequentialReader(&db, id, payload);
    const sequential_reader_ms = elapsedMs(reader_start);

    const random_timing = try readRandom64K(&db, id, payload);

    const manifest_start = now();
    var manifest = try db.objectManifest(std.heap.c_allocator, id);
    const chunk_rows = try scalar(&raw, "select count(*) from _zova_chunks");
    const manifest_rows = try scalar(&raw, "select count(*) from _zova_object_chunks");
    manifest.deinit(std.heap.c_allocator);
    const manifest_ms = elapsedMs(manifest_start);

    const integrity_start = now();
    try runIntegrityCheck(&raw);
    const integrity_ms = elapsedMs(integrity_start);

    const object_file_bytes = try fileBytes(path);
    const object_dbstat_bytes = try objectDbstatBytes(&raw);
    const writer_measurement = try runWriter(allocator, benchmark_dir, payload, ordinal, .fastcdc);

    const delete_start = now();
    try db.deleteObject(id);
    const delete_gc_ms = elapsedMs(delete_start);
    if (try scalar(&raw, "select count(*) from _zova_chunks") != 0) return error.GarbageCollectionFailed;

    return .{
        .put_ms = put_ms,
        .writer_ms = writer_measurement.elapsed_ms,
        .whole_read_ms = whole_read_ms,
        .sequential_64k_ms = sequential_64k_ms,
        .sequential_reader_ms = sequential_reader_ms,
        .random_64k_ms = random_timing.total_ms,
        .random_64k_p50_ms = random_timing.p50_ms,
        .random_64k_p95_ms = random_timing.p95_ms,
        .manifest_ms = manifest_ms,
        .delete_gc_ms = delete_gc_ms,
        .integrity_ms = integrity_ms,
        .chunk_rows = chunk_rows,
        .manifest_rows = manifest_rows,
        .object_file_bytes = object_file_bytes,
        .object_dbstat_bytes = object_dbstat_bytes,
        .writer_chunks_len = writer_measurement.descriptors.chunks_len,
        .writer_chunks_capacity = writer_measurement.descriptors.chunks_capacity,
        .writer_seen_chunks_len = writer_measurement.descriptors.seen_chunks_len,
        .writer_seen_chunks_capacity = writer_measurement.descriptors.seen_chunks_capacity,
        .writer_chunker_buffer_capacity = writer_measurement.descriptors.chunker_buffer_capacity,
        .writer_metadata_bytes = writer_measurement.metadata_bytes,
    };
}

fn runFixedSample(allocator: std.mem.Allocator, benchmark_dir: []const u8, payload: []const u8, ordinal: usize) !Sample {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/object-storage-fixed-{d}.zova", .{ benchmark_dir, ordinal }, 0);
    defer deletePath(path);

    var raw = try sqlite.Database.open(path);
    defer raw.deinit();
    var db = try preparePrototypeDatabase(&raw);
    if (ordinal == 0) try reportRuntimeSettings(&raw);

    const put_start = now();
    const id = try db.putObjectWithOptions(payload, .{ .profile = .streaming });
    const put_ms = elapsedMs(put_start);

    const whole_start = now();
    try readWhole(&db, id, payload);
    const whole_read_ms = elapsedMs(whole_start);

    const sequential_start = now();
    try readSequential64K(&db, id, payload);
    const sequential_64k_ms = elapsedMs(sequential_start);

    const reader_start = now();
    try readSequentialReader(&db, id, payload);
    const sequential_reader_ms = elapsedMs(reader_start);

    const random_timing = try readRandom64K(&db, id, payload);

    const manifest_start = now();
    var manifest = try db.objectManifest(std.heap.c_allocator, id);
    const chunk_rows = try scalar(&raw, "select count(*) from _zova_chunks");
    const manifest_rows = try scalar(&raw, "select count(*) from _zova_object_chunks");
    manifest.deinit(std.heap.c_allocator);
    const manifest_ms = elapsedMs(manifest_start);

    const integrity_start = now();
    try runIntegrityCheck(&raw);
    const integrity_ms = elapsedMs(integrity_start);

    const writer_measurement = try runWriter(allocator, benchmark_dir, payload, ordinal, .fixed_1m);
    const object_file_bytes = try fileBytes(path);
    const object_dbstat_bytes = try objectDbstatBytes(&raw);

    const delete_start = now();
    try db.deleteObject(id);
    const delete_gc_ms = elapsedMs(delete_start);
    if (try scalar(&raw, "select count(*) from _zova_chunks") != 0) return error.GarbageCollectionFailed;

    return .{
        .put_ms = put_ms,
        .writer_ms = writer_measurement.elapsed_ms,
        .whole_read_ms = whole_read_ms,
        .sequential_64k_ms = sequential_64k_ms,
        .sequential_reader_ms = sequential_reader_ms,
        .random_64k_ms = random_timing.total_ms,
        .random_64k_p50_ms = random_timing.p50_ms,
        .random_64k_p95_ms = random_timing.p95_ms,
        .manifest_ms = manifest_ms,
        .delete_gc_ms = delete_gc_ms,
        .integrity_ms = integrity_ms,
        .chunk_rows = chunk_rows,
        .manifest_rows = manifest_rows,
        .object_file_bytes = object_file_bytes,
        .object_dbstat_bytes = object_dbstat_bytes,
        .writer_chunks_len = writer_measurement.descriptors.chunks_len,
        .writer_chunks_capacity = writer_measurement.descriptors.chunks_capacity,
        .writer_seen_chunks_len = writer_measurement.descriptors.seen_chunks_len,
        .writer_seen_chunks_capacity = writer_measurement.descriptors.seen_chunks_capacity,
        .writer_chunker_buffer_capacity = writer_measurement.descriptors.chunker_buffer_capacity,
        .writer_metadata_bytes = writer_measurement.metadata_bytes,
    };
}

fn reportMetric(name: []const u8, samples: []const f64) void {
    std.debug.print("{s} samples_ms=", .{name});
    for (samples, 0..) |sample, index| {
        if (index != 0) std.debug.print(",", .{});
        std.debug.print("{d:.3}", .{sample});
    }
    std.debug.print(" median_ms={d:.3} mad_ms={d:.3}\n", .{ median(samples), mad(samples) });
}

fn reportCompareMetric(profile: []const u8, name: []const u8, samples: []const f64) void {
    std.debug.print("compare_metric profile={s} metric={s} samples_ms=", .{ profile, name });
    for (samples, 0..) |sample, index| {
        if (index != 0) std.debug.print(",", .{});
        std.debug.print("{d:.3}", .{sample});
    }
    std.debug.print(" median_ms={d:.3} mad_ms={d:.3}\n", .{ median(samples), mad(samples) });
}

fn reportCompareSample(profile: []const u8, index: usize, sample: Sample) void {
    std.debug.print(
        "compare_sample profile={s} sample={d} put_ms={d:.3} writer_ms={d:.3} writer_chunks={d}/{d} writer_seen_chunks={d}/{d} writer_buffer_capacity={d} writer_metadata_bytes={d} whole_read_ms={d:.3} sequential_64k_ms={d:.3} sequential_reader_ms={d:.3} random_64k_total_ms={d:.3} random_64k_p50_ms={d:.3} random_64k_p95_ms={d:.3} manifest_ms={d:.3} integrity_ms={d:.3} delete_gc_ms={d:.3} chunk_rows={d} manifest_rows={d} object_file_bytes={d} object_dbstat_bytes={d}\n",
        .{
            profile,
            index + 1,
            sample.put_ms,
            sample.writer_ms,
            sample.writer_chunks_len,
            sample.writer_chunks_capacity,
            sample.writer_seen_chunks_len,
            sample.writer_seen_chunks_capacity,
            sample.writer_chunker_buffer_capacity,
            sample.writer_metadata_bytes,
            sample.whole_read_ms,
            sample.sequential_64k_ms,
            sample.sequential_reader_ms,
            sample.random_64k_ms,
            sample.random_64k_p50_ms,
            sample.random_64k_p95_ms,
            sample.manifest_ms,
            sample.integrity_ms,
            sample.delete_gc_ms,
            sample.chunk_rows,
            sample.manifest_rows,
            sample.object_file_bytes,
            sample.object_dbstat_bytes,
        },
    );
}

fn reportCompareProfile(profile: []const u8, samples: [measured_runs]Sample) void {
    var metric: [measured_runs]f64 = undefined;

    for (samples, 0..) |sample, index| metric[index] = sample.put_ms;
    reportCompareMetric(profile, "put", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.writer_ms;
    reportCompareMetric(profile, "writer", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.whole_read_ms;
    reportCompareMetric(profile, "whole_read", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.sequential_64k_ms;
    reportCompareMetric(profile, "sequential_64k", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.sequential_reader_ms;
    reportCompareMetric(profile, "sequential_reader", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.random_64k_ms;
    reportCompareMetric(profile, "random_64k_total", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.random_64k_p50_ms;
    reportCompareMetric(profile, "random_64k_operation_p50", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.random_64k_p95_ms;
    reportCompareMetric(profile, "random_64k_operation_p95", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.manifest_ms;
    reportCompareMetric(profile, "manifest", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.integrity_ms;
    reportCompareMetric(profile, "integrity", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.delete_gc_ms;
    reportCompareMetric(profile, "delete_gc", &metric);

    const first = samples[0];
    std.debug.print(
        "compare_storage profile={s} rows_chunks={d} rows_manifest={d} object_file_bytes={d} object_dbstat_bytes={d}\n",
        .{ profile, first.chunk_rows, first.manifest_rows, first.object_file_bytes, first.object_dbstat_bytes },
    );
}

fn runCompare(
    allocator: std.mem.Allocator,
    benchmark_dir: []const u8,
    payload: []const u8,
) !void {
    _ = try runSample(allocator, benchmark_dir, payload, 10_000);
    std.debug.print("compare_warmup profile=fastcdc-v1 complete=true\n", .{});
    _ = try runFixedSample(allocator, benchmark_dir, payload, 10_001);
    std.debug.print("compare_warmup profile=fixed-1m-v1 complete=true\n", .{});

    var fastcdc_samples: [measured_runs]Sample = undefined;
    var fixed_samples: [measured_runs]Sample = undefined;
    var fastcdc_count: usize = 0;
    var fixed_count: usize = 0;

    // Interleave A/B/B/A repeatedly.  This produces seven samples per
    // profile while distributing filesystem and thermal drift across both.
    for (0..measured_runs * 2) |run_index| {
        const use_fastcdc = switch (run_index % 4) {
            0, 3 => true,
            else => false,
        };
        if (use_fastcdc) {
            const sample_index = fastcdc_count;
            fastcdc_samples[sample_index] = try runSample(allocator, benchmark_dir, payload, sample_index);
            reportCompareSample("fastcdc-v1", sample_index, fastcdc_samples[sample_index]);
            fastcdc_count += 1;
        } else {
            const sample_index = fixed_count;
            fixed_samples[sample_index] = try runFixedSample(allocator, benchmark_dir, payload, sample_index);
            reportCompareSample("fixed-1m-v1", sample_index, fixed_samples[sample_index]);
            fixed_count += 1;
        }
    }

    reportCompareProfile("fastcdc-v1", fastcdc_samples);
    reportCompareProfile("fixed-1m-v1", fixed_samples);

    var fastcdc_random_p95: [measured_runs]f64 = undefined;
    var fixed_random_p95: [measured_runs]f64 = undefined;
    for (fastcdc_samples, 0..) |sample, index| fastcdc_random_p95[index] = sample.random_64k_p95_ms;
    for (fixed_samples, 0..) |sample, index| fixed_random_p95[index] = sample.random_64k_p95_ms;
    const fastcdc_p95 = median(&fastcdc_random_p95);
    const fixed_p95 = median(&fixed_random_p95);
    const threshold = fastcdc_p95 * 1.10;
    std.debug.print(
        "compare_gate metric=random_64k_operation_p95 baseline_profile=fastcdc-v1 baseline_median_ms={d:.3} candidate_profile=fixed-1m-v1 candidate_median_ms={d:.3} threshold_ms={d:.3} candidate_delta_percent={d:.2} pass={s}\n",
        .{
            fastcdc_p95,
            fixed_p95,
            threshold,
            if (fastcdc_p95 == 0) 0 else (fixed_p95 / fastcdc_p95 - 1.0) * 100.0,
            if (fixed_p95 <= threshold) "true" else "false",
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2 or args.len > 5) return error.InvalidArgument;

    const benchmark_dir = args[1];
    const payload_bytes = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else default_payload_bytes;
    const single_profile: ?BenchmarkProfile = if (args.len == 5)
        if (std.mem.eql(u8, args[3], "sample-fastcdc"))
            .fastcdc
        else if (std.mem.eql(u8, args[3], "sample-fixed-1m"))
            .fixed_1m
        else
            return error.InvalidArgument
    else
        null;
    const single_ordinal = if (single_profile != null)
        try std.fmt.parseInt(usize, args[4], 10)
    else
        0;
    const compare = args.len == 4 and std.mem.eql(u8, args[3], "compare");
    const profile = if (single_profile) |selected|
        selected
    else if (compare)
        BenchmarkProfile.fastcdc
    else if (args.len < 4 or std.mem.eql(u8, args[3], "fastcdc"))
        BenchmarkProfile.fastcdc
    else if (std.mem.eql(u8, args[3], "fixed-1m"))
        BenchmarkProfile.fixed_1m
    else
        return error.InvalidArgument;
    if (payload_bytes < random_range_bytes) return error.InvalidBenchmarkInput;

    const payload = try allocator.alloc(u8, payload_bytes);
    fillPayload(payload);

    std.debug.print(
        "object_benchmark profile={s} format={s} package={s} sqlite={s} zig={s} build_mode={s} payload_bytes={d} warmups={d} measured_runs={d} benchmark_dir={s}\n",
        .{
            if (compare) "compare" else if (profile == .fastcdc) "fastcdc-v1" else "fixed-1m-v1",
            version.format_version,
            version.package_version,
            version.sqlite_version,
            @import("builtin").zig_version_string,
            @tagName(@import("builtin").mode),
            payload_bytes,
            if (single_profile != null) @as(usize, 0) else warmup_runs,
            if (single_profile != null) @as(usize, 1) else measured_runs,
            benchmark_dir,
        },
    );
    const one_tib_fixed_chunks = one_tib_bytes / fixed_chunk_size;
    const object_chunk_descriptor_bytes: u128 = @sizeOf(object_impl.ObjectChunk);
    const seen_chunk_descriptor_bytes: u128 = @sizeOf(object_impl.ObjectChunkId);
    const descriptor_bytes_at_one_tib = one_tib_fixed_chunks *
        (object_chunk_descriptor_bytes + seen_chunk_descriptor_bytes);
    const chunks_capacity_upper_bound = one_tib_fixed_chunks + one_tib_fixed_chunks / 2 + 1;
    const seen_chunks_capacity_upper_bound = one_tib_fixed_chunks + one_tib_fixed_chunks / 2 + 2;
    const fixed_buffer_capacity_upper_bound = fixed_chunk_size + fixed_chunk_size / 2 + 64;
    const descriptor_allocation_upper_bound = chunks_capacity_upper_bound * object_chunk_descriptor_bytes +
        seen_chunks_capacity_upper_bound * seen_chunk_descriptor_bytes +
        fixed_buffer_capacity_upper_bound;
    std.debug.print(
        "writer_descriptors object_chunk_bytes={d} seen_chunk_bytes={d} fixed_chunks_for_1tib={d} descriptor_payload_bytes_for_1tib={d} fixed_buffer_bytes={d} array_growth=minimum_plus_half_plus_init descriptor_allocation_upper_bound_for_1tib={d}\n",
        .{
            object_chunk_descriptor_bytes,
            seen_chunk_descriptor_bytes,
            one_tib_fixed_chunks,
            descriptor_bytes_at_one_tib,
            fixed_chunk_size,
            descriptor_allocation_upper_bound,
        },
    );

    if (compare) {
        try runCompare(allocator, benchmark_dir, payload);
        return;
    }

    if (single_profile) |selected| {
        const sample = try switch (selected) {
            .fastcdc => runSample(allocator, benchmark_dir, payload, single_ordinal),
            .fixed_1m => runFixedSample(allocator, benchmark_dir, payload, single_ordinal),
        };
        reportCompareSample(
            if (selected == .fastcdc) "fastcdc-v1" else "fixed-1m-v1",
            single_ordinal,
            sample,
        );
        return;
    }

    _ = try switch (profile) {
        .fastcdc => runSample(allocator, benchmark_dir, payload, 10_000),
        .fixed_1m => runFixedSample(allocator, benchmark_dir, payload, 10_000),
    };

    var samples: [measured_runs]Sample = undefined;
    for (&samples, 0..) |*sample, ordinal| {
        sample.* = try switch (profile) {
            .fastcdc => runSample(allocator, benchmark_dir, payload, ordinal),
            .fixed_1m => runFixedSample(allocator, benchmark_dir, payload, ordinal),
        };
        std.debug.print(
            "sample={d} put_ms={d:.3} writer_ms={d:.3} writer_chunks={d}/{d} writer_seen_chunks={d}/{d} writer_buffer_capacity={d} writer_metadata_bytes={d} whole_read_ms={d:.3} sequential_64k_ms={d:.3} sequential_reader_ms={d:.3} random_64k_total_ms={d:.3} random_64k_p50_ms={d:.3} random_64k_p95_ms={d:.3} manifest_ms={d:.3} integrity_ms={d:.3} backup_ms=unavailable(prototype) reopen_ms=unavailable(prototype) delete_gc_ms={d:.3} chunk_rows={d} manifest_rows={d} object_file_bytes={d} backup_file_bytes=unavailable(prototype) object_dbstat_bytes={d}\n",
            .{
                ordinal + 1,
                sample.put_ms,
                sample.writer_ms,
                sample.writer_chunks_len,
                sample.writer_chunks_capacity,
                sample.writer_seen_chunks_len,
                sample.writer_seen_chunks_capacity,
                sample.writer_chunker_buffer_capacity,
                sample.writer_metadata_bytes,
                sample.whole_read_ms,
                sample.sequential_64k_ms,
                sample.sequential_reader_ms,
                sample.random_64k_ms,
                sample.random_64k_p50_ms,
                sample.random_64k_p95_ms,
                sample.manifest_ms,
                sample.integrity_ms,
                sample.delete_gc_ms,
                sample.chunk_rows,
                sample.manifest_rows,
                sample.object_file_bytes,
                sample.object_dbstat_bytes,
            },
        );
    }

    var metric: [measured_runs]f64 = undefined;
    for (samples, 0..) |sample, index| metric[index] = sample.put_ms;
    reportMetric("put", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.writer_ms;
    reportMetric("writer", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.whole_read_ms;
    reportMetric("whole_read", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.sequential_64k_ms;
    reportMetric("sequential_64k", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.random_64k_ms;
    reportMetric("random_64k_total", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.random_64k_p50_ms;
    reportMetric("random_64k_operation_p50", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.random_64k_p95_ms;
    reportMetric("random_64k_operation_p95", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.manifest_ms;
    reportMetric("manifest", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.integrity_ms;
    reportMetric("integrity", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.sequential_reader_ms;
    reportMetric("sequential_reader", &metric);
    for (samples, 0..) |sample, index| metric[index] = sample.delete_gc_ms;
    reportMetric("delete_gc", &metric);

    std.debug.print(
        "storage rows_chunks={d} rows_manifest={d} object_file_bytes={d} backup_file_bytes=unavailable(prototype) object_dbstat_bytes={d}\n",
        .{ samples[0].chunk_rows, samples[0].manifest_rows, samples[0].object_file_bytes, samples[0].object_dbstat_bytes },
    );
}
