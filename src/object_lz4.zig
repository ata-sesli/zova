//! LZ4 block codec for object chunks.
//!
//! Implements the raw LZ4 *block* format (no frame header, no checksums):
//! a chunk row stores the plaintext size and SHA-256 separately, so the block
//! alone is enough. The encoder is the greedy single-hash-table matcher used
//! by the reference "fast" mode; any conforming LZ4 block decoder can read its
//! output. The decoder accepts any conforming block and validates every length
//! and offset, so malformed or truncated input fails with `error.Corrupt`
//! instead of reading or writing out of bounds.

const std = @import("std");

const min_match = 4;
/// The last five bytes of a block are always literals.
const last_literals = 5;
/// The last match must start at least twelve bytes before the end.
const mf_limit = 12;
const max_offset = 65535;
const hash_log = 12;
/// Skip faster through data with no matches (the reference "skip strength").
const skip_trigger = 6;

pub const DecodeError = error{Corrupt};

/// Compress `src` into `dst` and return the encoded length, or null when the
/// encoding does not fit in `dst`. Pass a `dst` shorter than `src` to keep an
/// encoding only when it saves space.
pub fn compress(dst: []u8, src: []const u8) ?usize {
    var out = Output{ .buffer = dst };
    var anchor: usize = 0;

    if (src.len >= mf_limit + 1) {
        var table: [1 << hash_log]u32 = @splat(0);
        const match_start_limit = src.len - mf_limit;
        const match_end_limit = src.len - last_literals;
        var ip: usize = 1;
        table[hash(read32(src, 0))] = 0;
        var search: usize = 1 << skip_trigger;

        while (ip <= match_start_limit) {
            const sequence = read32(src, ip);
            const slot = hash(sequence);
            const candidate: usize = table[slot];
            table[slot] = @intCast(ip);

            if (candidate >= ip or ip - candidate > max_offset or read32(src, candidate) != sequence) {
                ip += search >> skip_trigger;
                search += 1;
                continue;
            }
            search = 1 << skip_trigger;

            var start = ip;
            var reference = candidate;
            while (start > anchor and reference > 0 and src[start - 1] == src[reference - 1]) {
                start -= 1;
                reference -= 1;
            }
            var end = ip + min_match;
            var reference_end = candidate + min_match;
            while (end < match_end_limit and src[end] == src[reference_end]) {
                end += 1;
                reference_end += 1;
            }

            if (!out.sequence(src[anchor..start], start - reference, end - start)) return null;
            anchor = end;
            ip = end;
            // `end <= src.len - last_literals`, so four bytes at `ip - 2` exist.
            table[hash(read32(src, ip - 2))] = @intCast(ip - 2);
        }
    }

    if (!out.lastLiterals(src[anchor..])) return null;
    return out.len;
}

/// Decode an LZ4 block into `dst`, which must be exactly the plaintext size.
pub fn decompress(dst: []u8, src: []const u8) DecodeError!void {
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        if (ip >= src.len) return error.Corrupt;
        const token = src[ip];
        ip += 1;

        const literal_len = try readLength(src, &ip, token >> 4);
        if (literal_len > src.len - ip or literal_len > dst.len - op) return error.Corrupt;
        @memcpy(dst[op..][0..literal_len], src[ip..][0..literal_len]);
        ip += literal_len;
        op += literal_len;
        if (ip == src.len) break;

        if (src.len - ip < 2) return error.Corrupt;
        const offset: usize = std.mem.readInt(u16, src[ip..][0..2], .little);
        ip += 2;
        if (offset == 0 or offset > op) return error.Corrupt;

        const match_len = std.math.add(usize, try readLength(src, &ip, token & 0x0f), min_match) catch return error.Corrupt;
        if (match_len > dst.len - op) return error.Corrupt;
        copyMatch(dst, op, offset, match_len);
        op += match_len;
    }
    if (op != dst.len) return error.Corrupt;
}

fn readLength(src: []const u8, ip: *usize, nibble: u8) DecodeError!usize {
    var len: usize = nibble;
    if (nibble != 15) return len;
    while (true) {
        if (ip.* >= src.len) return error.Corrupt;
        const byte = src[ip.*];
        ip.* += 1;
        len = std.math.add(usize, len, byte) catch return error.Corrupt;
        if (byte != 255) return len;
    }
}

/// Copy `len` bytes from `offset` bytes back. Overlapping matches repeat the
/// last `offset` bytes, so the copy doubles a periodic run each step.
fn copyMatch(dst: []u8, op: usize, offset: usize, len: usize) void {
    const start = op - offset;
    if (offset >= len) {
        @memcpy(dst[op..][0..len], dst[start..][0..len]);
        return;
    }
    var done: usize = 0;
    while (done < len) {
        const n = @min(len - done, offset + done);
        @memcpy(dst[op + done ..][0..n], dst[start..][0..n]);
        done += n;
    }
}

fn read32(bytes: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, bytes[index..][0..4], .little);
}

fn hash(sequence: u32) usize {
    return @intCast((sequence *% 2654435761) >> (32 - hash_log));
}

const Output = struct {
    buffer: []u8,
    len: usize = 0,

    fn sequence(self: *Output, literals: []const u8, offset: usize, match_len: usize) bool {
        const match_extra = match_len - min_match;
        if (!self.token(literals.len, match_extra)) return false;
        if (!self.bytes(literals)) return false;
        var encoded_offset: [2]u8 = undefined;
        std.mem.writeInt(u16, &encoded_offset, @intCast(offset), .little);
        if (!self.bytes(&encoded_offset)) return false;
        return self.extraLength(match_extra);
    }

    fn lastLiterals(self: *Output, literals: []const u8) bool {
        if (!self.token(literals.len, 0)) return false;
        return self.bytes(literals);
    }

    fn token(self: *Output, literal_len: usize, match_extra: usize) bool {
        const high: u8 = @intCast(@min(literal_len, 15));
        const low: u8 = @intCast(@min(match_extra, 15));
        if (!self.bytes(&.{(high << 4) | low})) return false;
        return self.extraLength(literal_len);
    }

    fn extraLength(self: *Output, len: usize) bool {
        if (len < 15) return true;
        var remaining = len - 15;
        while (remaining >= 255) : (remaining -= 255) {
            if (!self.bytes(&.{255})) return false;
        }
        return self.bytes(&.{@intCast(remaining)});
    }

    fn bytes(self: *Output, data: []const u8) bool {
        if (data.len > self.buffer.len - self.len) return false;
        @memcpy(self.buffer[self.len..][0..data.len], data);
        self.len += data.len;
        return true;
    }
};

fn expectRoundTrip(src: []const u8) !void {
    const allocator = std.testing.allocator;
    const encoded = try allocator.alloc(u8, src.len + src.len / 255 + 16);
    defer allocator.free(encoded);
    const encoded_len = compress(encoded, src) orelse return error.TestUnexpectedResult;
    const decoded = try allocator.alloc(u8, src.len);
    defer allocator.free(decoded);
    try decompress(decoded, encoded[0..encoded_len]);
    try std.testing.expectEqualSlices(u8, src, decoded);
}

test "lz4 round-trips short, repetitive, mixed and random inputs" {
    const allocator = std.testing.allocator;
    try expectRoundTrip("");
    try expectRoundTrip("a");
    try expectRoundTrip("abcdefghijkl");
    try expectRoundTrip("abcdefghijklm");
    try expectRoundTrip("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    var prng = std.Random.DefaultPrng.init(0x5a0a_1234);
    const random = prng.random();
    const sizes = [_]usize{ 13, 64, 255, 4096, 65536, 70_000, 1 << 20 };
    for (sizes) |size| {
        const buffer = try allocator.alloc(u8, size);
        defer allocator.free(buffer);

        random.bytes(buffer);
        try expectRoundTrip(buffer);

        @memset(buffer, 0);
        try expectRoundTrip(buffer);

        // Text-like data: words from a small vocabulary, so matches have
        // varied offsets and lengths, including offsets near the 64 KiB limit.
        const words = [_][]const u8{ "zova ", "object ", "chunk ", "{\"id\":", "42,", "\n", "lz4 block ", "aaaaaaaaaaaaaaaaaaaa" };
        var index: usize = 0;
        while (index < size) {
            const word = words[random.uintLessThan(usize, words.len)];
            const n = @min(word.len, size - index);
            @memcpy(buffer[index..][0..n], word[0..n]);
            index += n;
        }
        try expectRoundTrip(buffer);
    }
}

test "lz4 shrinks repetitive data and refuses outputs that do not fit" {
    var zeros: [4096]u8 = @splat(0);
    var small: [64]u8 = undefined;
    const len = compress(&small, &zeros) orelse return error.TestUnexpectedResult;
    try std.testing.expect(len < 64);

    var prng = std.Random.DefaultPrng.init(7);
    var noise: [4096]u8 = undefined;
    prng.random().bytes(&noise);
    var bounded: [4095]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), compress(&bounded, &noise));
}

test "lz4 decodes hand-built spec blocks" {
    // Literals "abc", then a match of length 9 at offset 3 (overlapping), then
    // the final literals "xyz12".
    const block = [_]u8{ 0x35, 'a', 'b', 'c', 0x03, 0x00, 0x50, 'x', 'y', 'z', '1', '2' };
    var out: [17]u8 = undefined;
    try decompress(&out, &block);
    try std.testing.expectEqualStrings("abcabcabcabcxyz12", &out);

    // Extended literal length (15 + 3 = 18 literals) and nothing else.
    const q18: [18]u8 = @splat('q');
    const long_literals = [_]u8{ 0xf0, 0x03 } ++ q18;
    var long_out: [18]u8 = undefined;
    try decompress(&long_out, &long_literals);
    try std.testing.expectEqualSlices(u8, &q18, &long_out);

    // Extended match length: 1 literal, offset 1, match 4 + 15 + 255 + 1.
    const run = [_]u8{ 0x1f, 'r', 0x01, 0x00, 0xff, 0x01, 0x50, 'e', 'n', 'd', '!', '!' };
    var run_out: [1 + 275 + 5]u8 = undefined;
    try decompress(&run_out, &run);
    for (run_out[0..276]) |byte| try std.testing.expectEqual(@as(u8, 'r'), byte);
    try std.testing.expectEqualStrings("end!!", run_out[276..]);
}

test "lz4 rejects malformed blocks" {
    var out: [32]u8 = undefined;
    const cases = [_][]const u8{
        &.{},
        // Literal run longer than the input.
        &.{ 0x40, 'a', 'b' },
        // Offset zero.
        &.{ 0x10, 'a', 0x00, 0x00 },
        // Offset before the start of the output.
        &.{ 0x10, 'a', 0x02, 0x00 },
        // Truncated offset.
        &.{ 0x10, 'a', 0x01 },
        // Unterminated extended literal length.
        &.{ 0xf0, 0xff },
        // Unterminated extended match length.
        &.{ 0x1f, 'a', 0x01, 0x00, 0xff },
        // Match runs past the declared plaintext size.
        &.{ 0x1f, 'a', 0x01, 0x00, 0x40, 0x00 },
        // Ends after a match instead of a literal run.
        &.{ 0x10, 'a', 0x01, 0x00 },
    };
    for (cases) |block| {
        try std.testing.expectError(error.Corrupt, decompress(&out, block));
    }

    // A valid block whose plaintext is shorter or longer than `dst`.
    const block = [_]u8{ 0x30, 'a', 'b', 'c' };
    var short: [2]u8 = undefined;
    try std.testing.expectError(error.Corrupt, decompress(&short, &block));
    var long: [4]u8 = undefined;
    try std.testing.expectError(error.Corrupt, decompress(&long, &block));
}

const fuzz_corpus = @import("fuzz_corpus.zig");

test "fuzz: lz4 decoder rejects or decodes arbitrary blocks" {
    try std.testing.fuzz({}, fuzzDecode, .{ .corpus = comptime &.{
        fuzz_corpus.slice(&.{ 0x35, 'a', 'b', 'c', 0x03, 0x00, 0x50, 'x', 'y', 'z', '1', '2' }) ++ fuzz_corpus.int(17),
        fuzz_corpus.slice(&.{ 0x1f, 'r', 0x01, 0x00, 0xff, 0x01, 0x50, 'e', 'n', 'd', '!', '!' }) ++ fuzz_corpus.int(281),
        fuzz_corpus.slice("\xf0\x03" ++ "qqqqqqqqqqqqqqqqqq") ++ fuzz_corpus.int(18),
    } });
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    var input: [1024]u8 = undefined;
    const input_len = smith.slice(&input);
    var out: [4096]u8 = undefined;
    const out_len = smith.valueRangeAtMost(u16, 0, out.len);
    decompress(out[0..out_len], input[0..input_len]) catch |err| switch (err) {
        error.Corrupt => {},
    };
}

test "fuzz: lz4 round-trips arbitrary input" {
    try std.testing.fuzz({}, fuzzRoundTrip, .{ .corpus = comptime &.{
        fuzz_corpus.slice("abcdefghijklm"),
        fuzz_corpus.slice("zova object chunk zova object chunk lz4 block lz4 block aaaaaaaaaaaaaaaaaaaa"),
    } });
}

fn fuzzRoundTrip(_: void, smith: *std.testing.Smith) anyerror!void {
    var plain: [4096]u8 = undefined;
    const plain_len = smith.slice(&plain);
    // Worst-case LZ4 block size: every byte a literal, plus length bytes.
    var encoded: [plain.len + plain.len / 255 + 16]u8 = undefined;
    const encoded_len = compress(&encoded, plain[0..plain_len]) orelse return error.TestUnexpectedResult;
    var decoded: [plain.len]u8 = undefined;
    try decompress(decoded[0..plain_len], encoded[0..encoded_len]);
    try std.testing.expectEqualSlices(u8, plain[0..plain_len], decoded[0..plain_len]);
}
