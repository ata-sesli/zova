//! Peak memory of copy verification for issue #194.
//! Usage:
//!   binary setup NEW_DATABASE_PATH TOTAL_MIB
//!   binary backup DATABASE_PATH NEW_BACKUP_PATH
//! `setup` stores one deterministic pseudo-random `streaming` object through
//! `ObjectWriter` in 1 MiB writes. `backup` runs `backupTo` with verification
//! on and prints the process peak RSS, so the setup's own memory is excluded.
const std = @import("std");
const builtin = @import("builtin");
const zova = @import("zova");

fn peakRssBytes() u64 {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const maxrss: u64 = @intCast(usage.maxrss);
    // macOS reports bytes, Linux reports KiB.
    return if (builtin.os.tag.isDarwin()) maxrss else maxrss * 1024;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.InvalidArgument;
    const path = try arena.dupeSentinel(u8, args[2], 0);

    if (std.mem.eql(u8, args[1], "setup")) {
        const total_mib = try std.fmt.parseInt(usize, args[3], 10);
        if (total_mib == 0 or total_mib > 4096) return error.InvalidArgument;
        var db = try zova.Database.create(path);
        defer db.deinit();
        var writer = try db.objectWriterWithOptions(std.heap.c_allocator, .{ .profile = .streaming });
        defer writer.deinit();
        var block: [1024 * 1024]u8 = undefined;
        var state: u64 = 0x5a6f7661;
        for (0..total_mib) |_| {
            for (&block) |*byte| {
                state = state *% 6364136223846793005 +% 1442695040888963407;
                byte.* = @truncate(state >> 32);
            }
            try writer.write(&block);
        }
        _ = try writer.finish();
        return;
    }
    if (std.mem.eql(u8, args[1], "backup")) {
        const destination = try arena.dupeSentinel(u8, args[3], 0);
        var db = try zova.Database.open(path);
        defer db.deinit();
        try db.backupTo(destination, .{ .verify = true });
        std.debug.print("peak_rss_bytes={d}\n", .{peakRssBytes()});
        return;
    }
    return error.InvalidArgument;
}
