//! Private FastCDC-v1 chunking for Zova native objects.
//!
//! This module defines deterministic content-defined chunk boundaries using
//! the current object parameters: 2 KiB minimum, 8 KiB average, and 64 KiB
//! maximum. The exact masks, table seed, SplitMix64 gear generation, scan
//! regions, and max-cut behavior are part of the `fastcdc-v1` storage contract.
//!
//! It is intentionally not exported from the package root. Public object APIs
//! expose whole objects through `zova.Database`; callers do not see or choose
//! chunk boundaries. Chunks are stored as SQLite BLOB rows by `src/zova.zig`.

const std = @import("std");

pub const version = "fastcdc-v1";

pub const min_size: usize = 2 * 1024;
pub const avg_size: usize = 8 * 1024;
pub const max_size: usize = 64 * 1024;

const mask_s: u64 = 0x0003590703530000;
const mask_a: u64 = 0x0000d90303530000;
const mask_l: u64 = 0x0000d90003530000;
const gear_seed: u64 = 0x5a4f56415f464344;
const gear = makeGearTable();

/// One chunk boundary as an offset and byte length into the original input.
pub const Chunk = struct {
    offset: usize,
    len: usize,
};

/// Return the byte length of the first FastCDC-v1 chunk in `input`.
///
/// Empty input returns `0`. Inputs at or below `min_size` are one chunk. Larger
/// inputs scan the normalized short region first, then the long region, and cut
/// at `max_size` when no content-defined breakpoint is found.
pub fn cut(input: []const u8) usize {
    if (input.len <= min_size) return input.len;

    const limit = @min(input.len, max_size);
    const normal_end = @min(avg_size, limit);
    var fp: u64 = 0;

    if (min_size < normal_end) {
        var end: usize = min_size + 1;
        while (end <= normal_end) : (end += 1) {
            fp = (fp *% 2) +% gear[input[end - 1]];
            if ((fp & mask_s) == 0) return end;
        }
    }

    if (normal_end < limit) {
        var end: usize = normal_end + 1;
        while (end <= limit) : (end += 1) {
            fp = (fp *% 2) +% gear[input[end - 1]];
            if ((fp & mask_l) == 0) return end;
        }
    }

    return limit;
}

/// Return all FastCDC-v1 chunk boundaries for `input`.
///
/// The returned slice is owned by `allocator`. Empty input returns an empty
/// owned slice. This helper is package-internal test/foundation code; object
/// storage currently calls `cut` directly while writing manifests.
pub fn chunkBoundaries(allocator: std.mem.Allocator, input: []const u8) ![]Chunk {
    var chunks: std.ArrayList(Chunk) = .empty;
    errdefer chunks.deinit(allocator);

    var offset: usize = 0;
    while (offset < input.len) {
        const len = cut(input[offset..]);
        try chunks.append(allocator, .{
            .offset = offset,
            .len = len,
        });
        offset += len;
    }

    return try chunks.toOwnedSlice(allocator);
}

fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn makeGearTable() [256]u64 {
    var state: u64 = gear_seed;
    var table: [256]u64 = undefined;
    for (&table) |*entry| {
        entry.* = splitmix64(&state);
    }
    return table;
}

test "fastcdc-v1 chunks empty input into zero chunks" {
    const chunks = try chunkBoundaries(std.testing.allocator, "");
    defer std.testing.allocator.free(chunks);

    try std.testing.expectEqual(@as(usize, 0), chunks.len);
}

test "fastcdc-v1 chunks small input as one chunk" {
    const input = [_]u8{'a'} ** (min_size - 1);

    const chunks = try chunkBoundaries(std.testing.allocator, &input);
    defer std.testing.allocator.free(chunks);

    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqual(@as(usize, input.len), chunks[0].len);
}

test "fastcdc-v1 chunks exactly minimum size as one chunk" {
    const input = [_]u8{'b'} ** min_size;

    const chunks = try chunkBoundaries(std.testing.allocator, &input);
    defer std.testing.allocator.free(chunks);

    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqual(@as(usize, input.len), chunks[0].len);
}

test "fastcdc-v1 caps chunks at maximum size" {
    const input = [_]u8{'c'} ** (max_size + 4096);

    const chunks = try chunkBoundaries(std.testing.allocator, &input);
    defer std.testing.allocator.free(chunks);

    try std.testing.expect(chunks.len >= 2);
    for (chunks) |chunk| {
        try std.testing.expect(chunk.len <= max_size);
    }
}

test "fastcdc-v1 non-final chunks respect minimum size" {
    const input = [_]u8{'d'} ** (max_size * 2 + 1024);

    const chunks = try chunkBoundaries(std.testing.allocator, &input);
    defer std.testing.allocator.free(chunks);

    try std.testing.expect(chunks.len >= 2);
    for (chunks[0 .. chunks.len - 1]) |chunk| {
        try std.testing.expect(chunk.len >= min_size);
    }
}

test "fastcdc-v1 chunk boundaries are deterministic" {
    var input: [max_size + avg_size]u8 = undefined;
    for (&input, 0..) |*byte, index| {
        byte.* = @intCast((index * 31 + 7) % 251);
    }

    const first = try chunkBoundaries(std.testing.allocator, &input);
    defer std.testing.allocator.free(first);

    const second = try chunkBoundaries(std.testing.allocator, &input);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |a, b| {
        try std.testing.expectEqual(a.offset, b.offset);
        try std.testing.expectEqual(a.len, b.len);
    }
}

test "fastcdc-v1 fixture locks exact boundaries" {
    var input: [160 * 1024]u8 = undefined;
    for (&input, 0..) |*byte, index| {
        byte.* = @intCast((index * 3 + index / 6 + 6) % 256);
    }

    const chunks = try chunkBoundaries(std.testing.allocator, &input);
    defer std.testing.allocator.free(chunks);

    try std.testing.expect(chunks[0].len != max_size);
    try expectChunkLengths(chunks, &.{
        9685,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        9216,
        6699,
    });
}

test "fastcdc-v1 repeated content produces duplicate chunk hashes" {
    const input = [_]u8{0} ** (max_size * 4);

    const chunks = try chunkBoundaries(std.testing.allocator, &input);
    defer std.testing.allocator.free(chunks);

    try std.testing.expect(hasDuplicateChunkHash(&input, chunks));
}

test "fastcdc-v1 insertion near front preserves a later chunk hash" {
    const base = [_]u8{0} ** (max_size * 4);

    var edited: [base.len + 257]u8 = undefined;
    for (edited[0..257], 0..) |*byte, index| {
        byte.* = @intCast((index * 23 + 5) % 241);
    }
    @memcpy(edited[257..], &base);

    const base_chunks = try chunkBoundaries(std.testing.allocator, &base);
    defer std.testing.allocator.free(base_chunks);

    const edited_chunks = try chunkBoundaries(std.testing.allocator, &edited);
    defer std.testing.allocator.free(edited_chunks);

    try std.testing.expect(hasSharedChunkHash(&base, base_chunks, &edited, edited_chunks));
}

test "fastcdc-v1 does not allocate per byte" {
    const input = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(input);

    for (input, 0..) |*byte, index| {
        byte.* = @intCast((index * 17 + index / 11 + 29) % 256);
    }

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const chunks = try chunkBoundaries(failing_allocator.allocator(), input);
    defer failing_allocator.allocator().free(chunks);

    try std.testing.expect(chunks.len > 1);
    try std.testing.expect(failing_allocator.allocations < 64);
}

test "fastcdc-v1 documents the unused published average mask" {
    try std.testing.expectEqual(@as(u64, 0x0000d90303530000), mask_a);
}

fn expectChunkLengths(chunks: []const Chunk, expected: []const usize) !void {
    try std.testing.expectEqual(expected.len, chunks.len);
    for (chunks, expected) |chunk, len| {
        try std.testing.expectEqual(len, chunk.len);
    }
}

fn hasDuplicateChunkHash(input: []const u8, chunks: []const Chunk) bool {
    for (chunks, 0..) |left, left_index| {
        const left_hash = chunkHash(input, left);
        for (chunks[left_index + 1 ..]) |right| {
            const right_hash = chunkHash(input, right);
            if (std.mem.eql(u8, &left_hash, &right_hash)) return true;
        }
    }
    return false;
}

fn hasSharedChunkHash(
    left_input: []const u8,
    left_chunks: []const Chunk,
    right_input: []const u8,
    right_chunks: []const Chunk,
) bool {
    for (left_chunks) |left| {
        const left_hash = chunkHash(left_input, left);
        for (right_chunks) |right| {
            const right_hash = chunkHash(right_input, right);
            if (std.mem.eql(u8, &left_hash, &right_hash)) return true;
        }
    }
    return false;
}

fn chunkHash(input: []const u8, chunk: Chunk) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input[chunk.offset..][0..chunk.len], &digest, .{});
    return digest;
}
