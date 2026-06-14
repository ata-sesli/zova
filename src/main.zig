const std = @import("std");
const sqlite = @import("sqlite.zig").c;

pub fn main() !void {
    var db: ?*sqlite.sqlite3 = null;

    const rc = sqlite.sqlite3_open(":memory:", &db);
    if (rc != sqlite.SQLITE_OK) {
        std.debug.print("sqlite3_open failed: {d}\n", .{rc});
        return error.SqliteOpenFailed;
    }
    defer _ = sqlite.sqlite3_close(db);

    std.debug.print("SQLite version: {s}\n", .{sqlite.sqlite3_libversion()});
}