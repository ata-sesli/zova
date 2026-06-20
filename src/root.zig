const std = @import("std");

pub const sqlite = @import("sqlite.zig");
const zova = @import("zova.zig");

pub const Database = zova.Database;
pub const Error = zova.Error;
pub const Object = zova.Object;
pub const ObjectId = zova.ObjectId;
pub const VectorCollectionOptions = zova.VectorCollectionOptions;
pub const VectorMetric = zova.VectorMetric;
pub const max_vector_dimensions = zova.max_vector_dimensions;
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
    try std.testing.expect(@hasDecl(@This(), "VectorCollectionOptions"));
    try std.testing.expect(@hasDecl(@This(), "VectorMetric"));
    try std.testing.expect(@hasDecl(@This(), "max_vector_dimensions"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ObjectId));
    try std.testing.expectEqual(@as(u32, 16_384), max_vector_dimensions);
    try std.testing.expect(@hasDecl(Database, "putObject"));
    try std.testing.expect(@hasDecl(Database, "getObject"));
    try std.testing.expect(@hasDecl(Database, "hasObject"));
    try std.testing.expect(@hasDecl(Database, "objectSize"));
    try std.testing.expect(@hasDecl(Database, "objectChunkCount"));
    try std.testing.expect(@hasDecl(Database, "deleteObject"));
    try std.testing.expect(@hasDecl(Database, "createVectorCollection"));
    try std.testing.expect(@hasDecl(Database, "hasVectorCollection"));
    try std.testing.expect(!@hasDecl(@This(), "fastcdc"));
}
