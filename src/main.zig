const std = @import("std");
const sqlite = @import("sqlite.zig");

pub fn main() !void {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();

    try db.exec("select 1");

    std.debug.print("SQLite version: {s}\n", .{sqlite.version()});
}
