const std = @import("std");

pub const sqlite = @import("sqlite.zig");

test "package exports sqlite namespace" {
    try std.testing.expect(@hasDecl(@This(), "sqlite"));
    try std.testing.expect(@hasDecl(sqlite, "Database"));
    try std.testing.expect(@hasDecl(sqlite, "Statement"));
    try std.testing.expect(@hasDecl(sqlite, "c"));
}
