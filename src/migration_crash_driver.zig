//! Test executable: the parent terminates us at a real migration boundary.
const std = @import("std");
const zova = @import("zova.zig");
var target: []const u8 = undefined;
var marker: []const u8 = undefined;

fn pause(point: zova.MigrateFaultPoint) zova.Error!void {
    if (!std.mem.eql(u8, @tagName(point), target)) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "ready" }) catch return error.CantOpen;
    while (true) std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 5) return error.InvalidArgument;
    target = args[3];
    marker = args[4];
    try zova.migrateDatabaseInternal(a, try a.dupeZ(u8, args[1]), try a.dupeZ(u8, args[2]), .{}, zova.bundledExtensionRegistry(), pause);
}
