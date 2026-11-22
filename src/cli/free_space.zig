//! Free space on the filesystem holding a path, for `migrate --dry-run`.
//!
//! Zig's standard library has no statvfs/statfs wrapper, so this declares the
//! libc call per platform, and the Win32 call on Windows. Unsupported
//! platforms report null ("unknown").

const std = @import("std");
const builtin = @import("builtin");

/// Bytes available to an unprivileged writer on the filesystem holding
/// `path`, or null when the platform is unsupported or the call fails.
pub fn availableBytes(path: [:0]const u8) ?u64 {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => return darwinAvailableBytes(path),
        .linux => if (@sizeOf(usize) == 8) return linuxAvailableBytes(path) else return null,
        .windows => return windowsAvailableBytes(path),
        else => return null,
    }
}

fn windowsAvailableBytes(path: [:0]const u8) ?u64 {
    const native = struct {
        extern "kernel32" fn GetDiskFreeSpaceExW(
            directory_name: [*:0]const u16,
            free_bytes_available_to_caller: ?*u64,
            total_number_of_bytes: ?*u64,
            total_number_of_free_bytes: ?*u64,
        ) callconv(.winapi) std.os.windows.BOOL;
    };
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(std.heap.page_allocator, path) catch return null;
    defer std.heap.page_allocator.free(wide);
    var available: u64 = 0;
    if (native.GetDiskFreeSpaceExW(wide.ptr, &available, null, null) == .FALSE) return null;
    return available;
}

/// Darwin `struct statfs` (64-bit inode layout). Only the leading fields are
/// read; the tail is padding sized well past the kernel's 2168-byte struct.
const DarwinStatfs = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    rest: [4096]u8,
};

fn darwinAvailableBytes(path: [:0]const u8) ?u64 {
    const symbol = if (builtin.cpu.arch == .x86_64) "statfs$INODE64" else "statfs";
    const statfs = @extern(*const fn ([*:0]const u8, *DarwinStatfs) callconv(.c) c_int, .{ .name = symbol });
    var info: DarwinStatfs = undefined;
    if (statfs(path.ptr, &info) != 0) return null;
    return std.math.mul(u64, info.f_bavail, info.f_bsize) catch std.math.maxInt(u64);
}

/// 64-bit Linux `struct statvfs` (glibc and musl agree on this prefix).
const LinuxStatvfs = extern struct {
    f_bsize: u64,
    f_frsize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    rest: [512]u8,
};

fn linuxAvailableBytes(path: [:0]const u8) ?u64 {
    const statvfs = @extern(*const fn ([*:0]const u8, *LinuxStatvfs) callconv(.c) c_int, .{ .name = "statvfs" });
    var info: LinuxStatvfs = undefined;
    if (statvfs(path.ptr, &info) != 0) return null;
    const fragment = if (info.f_frsize != 0) info.f_frsize else info.f_bsize;
    return std.math.mul(u64, info.f_bavail, fragment) catch std.math.maxInt(u64);
}
