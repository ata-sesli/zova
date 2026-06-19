const std = @import("std");

pub const sqlite = @import("sqlite.zig");
const zova = @import("zova.zig");

pub const Database = zova.Database;
pub const Error = zova.Error;

test "package exports sqlite namespace" {
    try std.testing.expect(@hasDecl(@This(), "sqlite"));
    try std.testing.expect(@hasDecl(sqlite, "Database"));
    try std.testing.expect(@hasDecl(sqlite, "Statement"));
    try std.testing.expect(@hasDecl(sqlite, "c"));
}

test "package exports zova database namespace" {
    try std.testing.expect(@hasDecl(@This(), "Database"));
    try std.testing.expect(@hasDecl(@This(), "Error"));
}
