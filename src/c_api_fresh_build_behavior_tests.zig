//! Public-only C ABI behavior tests. No private implementation helpers.

const std = @import("std");
const zova_database = @import("c_api_internal.zig").zova_database;
const zova_database_close = @import("c_api_internal.zig").zova_database_close;
const zova_database_create = @import("c_api_internal.zig").zova_database_create;
const zova_database_exec = @import("c_api_internal.zig").zova_database_exec;
const zova_fresh_build = @import("c_api_internal.zig").zova_fresh_build;
const zova_fresh_build_begin = @import("c_api_internal.zig").zova_fresh_build_begin;
const zova_status = @import("c_api_internal.zig").zova_status;

test "c abi fresh builder rejects sessions without foreign-key enforcement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/fresh-builder-foreign-keys-off.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "pragma foreign_keys=off" }));
    var build: ?*zova_fresh_build = null;
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_fresh_build_begin(&.{ .db = db, .out_build = &build }));
    try std.testing.expectEqual(@as(?*zova_fresh_build, null), build);
}

test "c abi fresh builder requires clean foreign-key evidence before loading" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/fresh-builder-preexisting-foreign-key.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql =
        \\pragma foreign_keys=off;
        \\create table parents(id integer primary key);
        \\create table children(parent_id integer references parents(id));
        \\insert into children(parent_id) values (42);
        \\pragma foreign_keys=on;
        ,
    }));

    var build: ?*zova_fresh_build = null;
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_fresh_build_begin(&.{ .db = db, .out_build = &build }));
    try std.testing.expectEqual(@as(?*zova_fresh_build, null), build);
}
