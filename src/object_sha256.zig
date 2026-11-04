//! SHA-256 for object ids and chunk ids.
//!
//! `std.crypto.hash.sha2.Sha256` picks its hardware block function at compile
//! time, and never in the C backend (`-ofmt=c`), which every generated-C
//! binding package is built with. This hasher returns the same digests but
//! picks the block function at run time: ARMv8 SHA-2 or x86 SHA-NI
//! instructions when the CPU has them, otherwise std's rounds. Its inline
//! assembly passes only pointers and counts, never vectors, so the C backend
//! can emit it.

const std = @import("std");
const builtin = @import("builtin");

const StdSha256 = std.crypto.hash.sha2.Sha256;

/// Streaming SHA-256 with the same API as `std.crypto.hash.sha2.Sha256`.
pub const Sha256 = struct {
    pub const block_length = 64;
    pub const digest_length = 32;
    pub const Options = struct {};

    state: [8]u32 align(16) = iv,
    buf: [block_length]u8 = undefined,
    buf_len: u8 = 0,
    total_len: u64 = 0,

    pub fn init(options: Options) Sha256 {
        _ = options;
        return .{};
    }

    pub fn hash(bytes: []const u8, out: *[digest_length]u8, options: Options) void {
        var d = init(options);
        d.update(bytes);
        d.final(out);
    }

    pub fn update(d: *Sha256, bytes: []const u8) void {
        var rest = bytes;
        d.total_len +%= bytes.len;

        if (d.buf_len != 0) {
            const take = @min(block_length - d.buf_len, rest.len);
            @memcpy(d.buf[d.buf_len..][0..take], rest[0..take]);
            d.buf_len += @intCast(take);
            rest = rest[take..];
            if (d.buf_len < block_length) return;
            compress(&d.state, &d.buf);
            d.buf_len = 0;
        }

        const whole = rest.len - rest.len % block_length;
        if (whole != 0) compress(&d.state, rest[0..whole]);
        rest = rest[whole..];

        @memcpy(d.buf[0..rest.len], rest);
        d.buf_len = @intCast(rest.len);
    }

    pub fn final(d: *Sha256, out: *[digest_length]u8) void {
        const bit_len = d.total_len *% 8;
        @memset(d.buf[d.buf_len..], 0);
        d.buf[d.buf_len] = 0x80;
        if (d.buf_len >= block_length - 8) {
            compress(&d.state, &d.buf);
            @memset(&d.buf, 0);
        }
        std.mem.writeInt(u64, d.buf[block_length - 8 ..], bit_len, .big);
        compress(&d.state, &d.buf);

        for (d.state, 0..) |word, index| {
            std.mem.writeInt(u32, out[4 * index ..][0..4], word, .big);
        }
    }
};

const iv = [8]u32{
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
};

const round_constants = [64]u32{
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
};

pub const Backend = enum(u8) {
    /// `std.crypto.hash.sha2.Sha256` rounds. In a native build whose target
    /// CPU features already include the SHA extensions, std uses them.
    standard = 1,
    aarch64_sha2 = 2,
    x86_sha_ni = 3,
};

/// Whether std already selects hardware rounds at compile time. Run-time
/// detection adds nothing then.
const std_uses_hardware = builtin.zig_backend != .stage2_c and switch (builtin.cpu.arch) {
    .aarch64 => builtin.cpu.has(.aarch64, .sha2),
    .x86_64 => builtin.cpu.hasAll(.x86, &.{ .sha, .avx2 }),
    else => false,
};

/// The assembly needs a GNU-compatible assembler: LLVM, or the C compiler
/// for generated C. Zig's self-hosted backends (Debug builds) cannot parse
/// it, so those builds keep std's rounds.
const asm_backend = builtin.zig_backend == .stage2_llvm or builtin.zig_backend == .stage2_c;
const aarch64_asm = asm_backend and builtin.cpu.arch == .aarch64 and
    builtin.cpu.arch.endian() == .little and !std_uses_hardware;
const x86_asm = asm_backend and builtin.cpu.arch == .x86_64 and !std_uses_hardware;

/// 0 until the first hash resolves the backend. Detection is idempotent, so
/// racing first callers only repeat it.
var resolved_backend: std.atomic.Value(u8) = .init(0);

/// The block function this process uses.
pub fn backend() Backend {
    const cached = resolved_backend.load(.monotonic);
    if (cached != 0) return @fromBackingInt(@intCast(cached));
    const detected = detectBackend();
    resolved_backend.store(@backingInt(detected), .monotonic);
    return detected;
}

fn detectBackend() Backend {
    if (aarch64_asm and aarch64HasSha2()) return .aarch64_sha2;
    if (x86_asm and x86HasShaNi()) return .x86_sha_ni;
    return .standard;
}

fn compress(state: *align(16) [8]u32, blocks: []const u8) void {
    std.debug.assert(blocks.len % Sha256.block_length == 0);
    const count = blocks.len / Sha256.block_length;
    switch (backend()) {
        .standard => compressStandard(state, blocks),
        .aarch64_sha2 => if (aarch64_asm) compressAarch64(state, blocks.ptr, count) else unreachable,
        .x86_sha_ni => if (x86_asm) compressX86(state, blocks.ptr, count) else unreachable,
    }
}

fn compressStandard(state: *align(16) [8]u32, blocks: []const u8) void {
    // With an empty buffer, std's `update` runs its block function once per
    // whole block and leaves nothing buffered; only the state is kept.
    var d: StdSha256 = .{ .s = state.* };
    d.update(blocks);
    std.debug.assert(d.buf_len == 0);
    state.* = d.s;
}

fn aarch64HasSha2() bool {
    if (comptime builtin.cpu.has(.aarch64, .sha2)) return true;
    return switch (builtin.os.tag) {
        // Every Apple silicon CPU implements the ARMv8 SHA-2 instructions.
        .macos, .ios, .tvos, .watchos, .visionos => true,
        .linux => linuxHwcap() & linux_aarch64_hwcap_sha2 != 0,
        else => false,
    };
}

fn linuxHwcap() usize {
    // std's own auxv copy is filled in by Zig's start code, which does not
    // run when Zova is a library loaded by another runtime; ask libc then.
    if (builtin.link_libc) return std.c.getauxval(std.elf.AT.HWCAP);
    return std.os.linux.getauxval(std.elf.AT.HWCAP);
}

/// `HWCAP_SHA2` in Linux `arch/arm64/include/uapi/asm/hwcap.h`.
const linux_aarch64_hwcap_sha2: usize = 1 << 6;

fn x86HasShaNi() bool {
    const max_leaf = x86Cpuid(0, 0)[0];
    if (max_leaf < 7) return false;
    const ssse3 = x86Cpuid(1, 0)[2] & (1 << 9) != 0;
    const sha = x86Cpuid(7, 0)[1] & (1 << 29) != 0;
    return ssse3 and sha;
}

/// Return eax, ebx, ecx, edx. Results go through memory so the assembly
/// needs no fixed-register constraints.
fn x86Cpuid(leaf: u32, subleaf: u32) [4]u32 {
    if (!x86_asm) unreachable;
    var regs: [4]u32 = undefined;
    asm volatile (
        \\movl %[leaf], %%eax
        \\movl %[subleaf], %%ecx
        \\cpuid
        \\movl %%eax, 0(%[regs])
        \\movl %%ebx, 4(%[regs])
        \\movl %%ecx, 8(%[regs])
        \\movl %%edx, 12(%[regs])
        :
        : [leaf] "r" (leaf),
          [subleaf] "r" (subleaf),
          [regs] "r" (&regs),
        : .{ .rax = true, .rbx = true, .rcx = true, .rdx = true, .memory = true });
    return regs;
}

/// ARMv8 SHA-2 block function. v0/v1 hold abcd/efgh, v2/v3 the saved state,
/// v4-v7 the message schedule, v16 the round input and v17 a copy of abcd.
/// The loop uses `cbnz` so the flags stay untouched: C compilers do not
/// accept Zig's `nzcv` clobber name.
fn compressAarch64(state: *align(16) [8]u32, blocks: [*]const u8, count: usize) void {
    if (!aarch64_asm) unreachable;
    if (count == 0) return;
    asm volatile (aarch64_block_asm
        :
        : [state] "r" (state),
          [data] "r" (blocks),
          [count] "r" (count),
          [k] "r" (&round_constants),
        : .{
          .x9 = true,
          .x10 = true,
          .x11 = true,
          .memory = true,
          .v0 = true,
          .v1 = true,
          .v2 = true,
          .v3 = true,
          .v4 = true,
          .v5 = true,
          .v6 = true,
          .v7 = true,
          .v16 = true,
          .v17 = true,
        });
}

const aarch64_block_asm = blk: {
    var text: []const u8 =
        \\.arch_extension sha2
        \\mov x9, %[data]
        \\mov x10, %[count]
        \\ld1 {v0.4s, v1.4s}, [%[state]]
        \\1:
        \\ld1 {v4.16b, v5.16b, v6.16b, v7.16b}, [x9], #64
        \\mov x11, %[k]
        \\rev32 v4.16b, v4.16b
        \\rev32 v5.16b, v5.16b
        \\rev32 v6.16b, v6.16b
        \\rev32 v7.16b, v7.16b
        \\mov v2.16b, v0.16b
        \\mov v3.16b, v1.16b
        \\
    ;
    for (0..16) |group| {
        const m = 4 + group % 4;
        const m1 = 4 + (group + 1) % 4;
        const m2 = 4 + (group + 2) % 4;
        const m3 = 4 + (group + 3) % 4;
        text = text ++ std.fmt.comptimePrint(
            \\ld1 {{v16.4s}}, [x11], #16
            \\add v16.4s, v16.4s, v{d}.4s
            \\
        , .{m});
        if (group < 12) text = text ++ std.fmt.comptimePrint("sha256su0 v{d}.4s, v{d}.4s\n", .{ m, m1 });
        text = text ++
            \\mov v17.16b, v0.16b
            \\sha256h q0, q1, v16.4s
            \\sha256h2 q1, q17, v16.4s
            \\
        ;
        if (group < 12) text = text ++ std.fmt.comptimePrint("sha256su1 v{d}.4s, v{d}.4s, v{d}.4s\n", .{ m, m2, m3 });
    }
    text = text ++
        \\add v0.4s, v0.4s, v2.4s
        \\add v1.4s, v1.4s, v3.4s
        \\sub x10, x10, #1
        \\cbnz x10, 1b
        \\st1 {v0.4s, v1.4s}, [%[state]]
    ;
    break :blk text;
};

/// Byte order mask for `pshufb`: big-endian message words.
const x86_byte_flip_mask = [16]u8{ 3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12 };

/// x86 SHA-NI block function, following the Linux kernel's
/// `sha256_ni_transform`. xmm0 is the implicit `sha256rnds2` operand,
/// xmm1/xmm2 hold ABEF/CDGH, xmm3-xmm6 the message schedule, xmm7 a
/// temporary, xmm8 the byte-flip mask and xmm9/xmm10 the saved state.
fn compressX86(state: *align(16) [8]u32, blocks: [*]const u8, count: usize) void {
    if (!x86_asm) unreachable;
    if (count == 0) return;
    asm volatile (x86_block_asm
        :
        : [state] "r" (state),
          [data] "r" (blocks),
          [count] "r" (count),
          [k] "r" (&round_constants),
          [mask] "r" (&x86_byte_flip_mask),
        : .{
          .rax = true,
          .r10 = true,
          .r11 = true,
          .cc = true,
          .memory = true,
          .xmm0 = true,
          .xmm1 = true,
          .xmm2 = true,
          .xmm3 = true,
          .xmm4 = true,
          .xmm5 = true,
          .xmm6 = true,
          .xmm7 = true,
          .xmm8 = true,
          .xmm9 = true,
          .xmm10 = true,
        });
}

/// The four-round step is an assembler macro, as in the kernel source, so
/// the template stays short: Zig's C backend writes a template longer than
/// about 4 KiB as a character array, which C compilers reject in `asm`.
const x86_block_asm = blk: {
    var text: []const u8 =
        \\.macro zova_sha256_rounds4 i, m0, m1, m3
        \\.if \i < 16
        \\movdqu \i*4(%%r10), \m0
        \\pshufb %%xmm8, \m0
        \\.endif
        \\movdqu \i*4(%%rax), %%xmm0
        \\paddd \m0, %%xmm0
        \\sha256rnds2 %%xmm0, %%xmm1, %%xmm2
        \\.if \i >= 12 && \i < 60
        \\movdqa \m0, %%xmm7
        \\palignr $4, \m3, %%xmm7
        \\paddd %%xmm7, \m1
        \\sha256msg2 \m0, \m1
        \\.endif
        \\punpckhqdq %%xmm0, %%xmm0
        \\sha256rnds2 %%xmm0, %%xmm2, %%xmm1
        \\.if \i >= 4 && \i < 52
        \\sha256msg1 \m0, \m3
        \\.endif
        \\.endm
        \\movq %[data], %%r10
        \\movq %[count], %%r11
        \\shlq $6, %%r11
        \\addq %%r10, %%r11
        \\movq %[k], %%rax
        \\movdqu 0(%[state]), %%xmm1
        \\movdqu 16(%[state]), %%xmm2
        \\movdqa %%xmm1, %%xmm7
        \\punpcklqdq %%xmm2, %%xmm1
        \\punpckhqdq %%xmm7, %%xmm2
        \\pshufd $0x1B, %%xmm1, %%xmm1
        \\pshufd $0xB1, %%xmm2, %%xmm2
        \\movdqu 0(%[mask]), %%xmm8
        \\1:
        \\movdqa %%xmm1, %%xmm9
        \\movdqa %%xmm2, %%xmm10
        \\
    ;
    for (0..16) |group| {
        text = text ++ std.fmt.comptimePrint("zova_sha256_rounds4 {d}, %%xmm{d}, %%xmm{d}, %%xmm{d}\n", .{
            group * 4,
            3 + group % 4,
            3 + (group + 1) % 4,
            3 + (group + 3) % 4,
        });
    }
    text = text ++
        \\paddd %%xmm9, %%xmm1
        \\paddd %%xmm10, %%xmm2
        \\addq $64, %%r10
        \\cmpq %%r11, %%r10
        \\jne 1b
        \\movdqa %%xmm1, %%xmm7
        \\punpcklqdq %%xmm2, %%xmm1
        \\punpckhqdq %%xmm7, %%xmm2
        \\pshufd $0xB1, %%xmm1, %%xmm1
        \\pshufd $0x1B, %%xmm2, %%xmm2
        \\movdqu %%xmm2, 0(%[state])
        \\movdqu %%xmm1, 16(%[state])
        \\.purgem zova_sha256_rounds4
    ;
    break :blk text;
};

fn expectSameDigest(bytes: []const u8) !void {
    var expected: [32]u8 = undefined;
    StdSha256.hash(bytes, &expected, .{});
    var actual: [32]u8 = undefined;
    Sha256.hash(bytes, &actual, .{});
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "object sha256 matches standard vectors" {
    const cases = [_]struct { input: []const u8, hex: []const u8 }{
        .{ .input = "", .hex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        .{ .input = "abc", .hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
        .{
            .input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            .hex = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        },
    };
    for (cases) |case| {
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, case.hex);
        var actual: [32]u8 = undefined;
        Sha256.hash(case.input, &actual, .{});
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}

test "object sha256 matches std across lengths and streaming splits" {
    var bytes: [4 * 64 + 7]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x184);
    prng.random().bytes(&bytes);

    for (0..bytes.len + 1) |len| try expectSameDigest(bytes[0..len]);

    var expected: [32]u8 = undefined;
    StdSha256.hash(&bytes, &expected, .{});
    const splits = [_]usize{ 1, 3, 55, 56, 63, 64, 65, 127, 128, 200 };
    for (splits) |first| {
        for (splits) |second| {
            if (first + second > bytes.len) continue;
            var d = Sha256.init(.{});
            d.update(bytes[0..first]);
            d.update(bytes[first..][0..second]);
            d.update("");
            d.update(bytes[first + second ..]);
            var actual: [32]u8 = undefined;
            d.final(&actual);
            try std.testing.expectEqualSlices(u8, &expected, &actual);
        }
    }
}

test "object sha256 matches std on a large multi-block input" {
    const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024 + 13);
    defer std.testing.allocator.free(bytes);
    var prng = std.Random.DefaultPrng.init(0x1840);
    prng.random().bytes(bytes);
    try expectSameDigest(bytes);
}

test "object sha256 selects the hardware backend where std cannot" {
    // Native builds whose target features already include SHA keep std's
    // rounds. Every Apple silicon CPU has SHA-2, so a macOS build that
    // leaves it to run-time detection, such as generated C, must select it.
    if (aarch64_asm and builtin.os.tag == .macos) {
        try std.testing.expectEqual(Backend.aarch64_sha2, backend());
    }
}

test "object sha256 standard backend matches the selected backend" {
    var bytes: [3 * 64]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x18400);
    prng.random().bytes(&bytes);

    var selected: [8]u32 align(16) = iv;
    compress(&selected, &bytes);
    var standard: [8]u32 align(16) = iv;
    compressStandard(&standard, &bytes);
    try std.testing.expectEqualSlices(u32, &standard, &selected);
}
