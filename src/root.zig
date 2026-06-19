const std = @import("std");

pub const sqlite = @import("sqlite.zig");
const zova = @import("zova.zig");

pub const Database = zova.Database;
pub const Error = zova.Error;
pub const Object = zova.Object;
pub const ObjectId = zova.ObjectId;
pub const objectId = zova.objectId;
pub const convertSqliteToZova = zova.convertSqliteToZova;

test "package exports sqlite namespace" {
    try std.testing.expect(@hasDecl(@This(), "sqlite"));
    try std.testing.expect(@hasDecl(sqlite, "Database"));
    try std.testing.expect(@hasDecl(sqlite, "Statement"));
    try std.testing.expect(@hasDecl(sqlite, "c"));
}

test "package exports zova database namespace" {
    try std.testing.expect(@hasDecl(@This(), "Database"));
    try std.testing.expect(@hasDecl(@This(), "Error"));
    try std.testing.expect(@hasDecl(@This(), "convertSqliteToZova"));
    try std.testing.expect(@hasDecl(@This(), "Object"));
    try std.testing.expect(@hasDecl(@This(), "ObjectId"));
    try std.testing.expect(@hasDecl(@This(), "objectId"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ObjectId));
    try std.testing.expect(@hasDecl(Database, "putObject"));
    try std.testing.expect(@hasDecl(Database, "getObject"));
    try std.testing.expect(@hasDecl(Database, "hasObject"));
    try std.testing.expect(@hasDecl(Database, "objectSize"));
    try std.testing.expect(@hasDecl(Database, "objectChunkCount"));
    try std.testing.expect(!@hasDecl(@This(), "fastcdc"));
}
