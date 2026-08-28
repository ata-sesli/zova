//! Fixed-size chunking for the object-storage streaming profile.
//!
//! This policy is deliberately separate from `object_fastcdc.zig`.  The
//! format-11 schema stores its chunks alongside FastCDC chunks, while callers
//! select only the public storage profile rather than physical boundaries.

const std = @import("std");

pub const version = "fixed-1m-v1";
pub const chunk_size: usize = 1024 * 1024;
pub const max_size = chunk_size;

pub const Chunk = struct {
    offset: usize,
    len: usize,
};

pub const StreamChunk = struct {
    offset: usize,
    bytes: []const u8,
};

/// Return the first fixed-policy chunk length in `input`.
///
/// Empty input returns zero.  Every non-final chunk is exactly 1 MiB and the
/// final chunk is the remaining 1..1 MiB bytes.
pub fn cut(input: []const u8) usize {
    return @min(input.len, chunk_size);
}

/// Return all fixed-policy chunk boundaries for `input`.
pub fn chunkBoundaries(allocator: std.mem.Allocator, input: []const u8) ![]Chunk {
    const chunk_count = count(input);
    const chunks = try allocator.alloc(Chunk, chunk_count);
    errdefer allocator.free(chunks);

    var offset: usize = 0;
    for (chunks) |*chunk| {
        const len = cut(input[offset..]);
        chunk.* = .{ .offset = offset, .len = len };
        offset += len;
    }
    return chunks;
}

/// Return the number of fixed-policy chunks without allocating.
pub fn count(input: []const u8) usize {
    if (input.len == 0) return 0;
    return (input.len + chunk_size - 1) / chunk_size;
}

/// Return the fixed-policy chunk count for a persisted object size.
pub fn countForSize(size_bytes: u64) u64 {
    if (size_bytes == 0) return 0;
    return (size_bytes + chunk_size - 1) / chunk_size;
}

/// Validate the fixed-policy manifest shape independent of storage.
pub fn validateShape(size_bytes: u64, chunks: []const Chunk) bool {
    if (size_bytes == 0) return chunks.len == 0;
    if (chunks.len != countForSize(size_bytes)) return false;

    var expected_offset: u64 = 0;
    for (chunks, 0..) |chunk, index| {
        const chunk_offset: u64 = @intCast(chunk.offset);
        const chunk_len: u64 = @intCast(chunk.len);
        if (chunk_offset != expected_offset or chunk_len == 0 or chunk_len > chunk_size) return false;
        if (index + 1 < chunks.len and chunk_len != chunk_size) return false;
        if (chunk_offset > size_bytes or chunk_len > size_bytes - chunk_offset) return false;
        expected_offset += chunk_len;
    }
    return expected_offset == size_bytes;
}

/// A streaming fixed chunker with a resident payload buffer bounded to 1 MiB.
pub const StreamChunker = struct {
    buffer: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    finished: bool = false,

    pub const empty: StreamChunker = .{};

    /// Append at most the remaining space in the current fixed chunk.
    /// Callers should drain `next()` whenever this returns zero.
    pub fn write(self: *StreamChunker, allocator: std.mem.Allocator, bytes: []const u8) !usize {
        std.debug.assert(!self.finished);
        const available = chunk_size - self.buffer.items.len;
        const accepted = @min(available, bytes.len);
        try self.buffer.appendSlice(allocator, bytes[0..accepted]);
        return accepted;
    }

    /// Return a complete fixed chunk, or the final remainder after finish.
    pub fn next(self: *StreamChunker) ?StreamChunk {
        if (self.buffer.items.len == 0) return null;
        if (self.buffer.items.len < chunk_size and !self.finished) return null;
        return .{ .offset = self.offset, .bytes = self.buffer.items };
    }

    /// Discard the emitted chunk and advance the stream offset.
    pub fn consume(self: *StreamChunker, allocator: std.mem.Allocator, len: usize) void {
        _ = allocator;
        std.debug.assert(len > 0 and len == self.buffer.items.len);
        self.buffer.clearRetainingCapacity();
        self.offset += len;
    }

    pub fn finish(self: *StreamChunker) void {
        self.finished = true;
    }

    pub fn deinit(self: *StreamChunker, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }
};

test "fixed-1m-v1 uses exact boundaries and final remainder" {
    var input: [chunk_size * 2 + 123]u8 = undefined;
    @memset(&input, 0x5a);

    const chunks = try chunkBoundaries(std.testing.allocator, &input);
    defer std.testing.allocator.free(chunks);

    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expectEqual(chunk_size, chunks[0].len);
    try std.testing.expectEqual(chunk_size, chunks[1].len);
    try std.testing.expectEqual(@as(usize, 123), chunks[2].len);
    try std.testing.expect(validateShape(input.len, chunks));
}

test "fixed-1m-v1 empty input has zero chunks" {
    const chunks = try chunkBoundaries(std.testing.allocator, "");
    defer std.testing.allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 0), chunks.len);
    try std.testing.expect(validateShape(0, chunks));
}

test "fixed-1m-v1 streaming buffer never exceeds one chunk" {
    const input = [_]u8{0x33} ** (chunk_size * 2 + 17);
    var chunker: StreamChunker = .empty;
    defer chunker.deinit(std.testing.allocator);

    var input_offset: usize = 0;
    while (input_offset < input.len) {
        const accepted = try chunker.write(std.testing.allocator, input[input_offset..]);
        try std.testing.expect(chunker.buffer.items.len <= chunk_size);
        input_offset += accepted;

        if (chunker.next()) |chunk| {
            try std.testing.expectEqual(chunk_size, chunk.bytes.len);
            chunker.consume(std.testing.allocator, chunk.bytes.len);
        } else {
            try std.testing.expect(accepted > 0);
        }
    }

    chunker.finish();
    const final = chunker.next() orelse return error.TestExpectedChunk;
    try std.testing.expectEqual(@as(usize, 17), final.bytes.len);
    chunker.consume(std.testing.allocator, final.bytes.len);
    try std.testing.expect(chunker.next() == null);
}
