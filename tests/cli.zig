const std = @import("std");
const cli = @import("cli");
const zova = @import("zova");

test "cli version and help are successful" {
    var result = try runCli(&.{ "zova", "--version" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, cli.package_version) != null);

    var help = try runCli(&.{ "zova", "--help" });
    defer help.deinit();
    try std.testing.expectEqual(@as(u8, 0), help.code);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "info <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "check [--deep] <file.zova>") != null);
}

test "cli usage errors return exit code 2" {
    var unknown = try runCli(&.{ "zova", "wat" });
    defer unknown.deinit();
    try std.testing.expectEqual(@as(u8, 2), unknown.code);
    try std.testing.expect(std.mem.indexOf(u8, unknown.stderr, "unknown command") != null);

    var missing = try runCli(&.{ "zova", "info" });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 2), missing.code);
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "usage") != null);
}

test "cli info reports bounded database summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "info.zova");
    try createHealthyDatabase(db_path);

    var result = try runCli(&.{ "zova", "info", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try expectContains(result.stdout, "Zova database");
    try expectContains(result.stdout, "format_version: 3");
    try expectContains(result.stdout, "objects:");
    try expectContains(result.stdout, "chunks:");
    try expectContains(result.stdout, "loose_chunks:");
    try expectContains(result.stdout, "vector_collections:");
    try expectContains(result.stdout, "user_tables:");
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "1.0") == null);
}

test "cli check succeeds for healthy databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "healthy.zova");
    try createHealthyDatabase(db_path);

    var quick = try runCli(&.{ "zova", "check", db_path });
    defer quick.deinit();
    try std.testing.expectEqual(@as(u8, 0), quick.code);
    try expectContains(quick.stdout, "ok");

    var deep = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);
    try expectContains(deep.stdout, "deep_check: ok");
    try expectContains(deep.stdout, "loose_chunks:");
}

test "cli open failures return exit code 3" {
    var result = try runCli(&.{ "zova", "info", "missing.zova" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 3), result.code);
    try expectContains(result.stderr, "open failed");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sqlite_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "plain.db");
    {
        var raw = try zova.sqlite.Database.open(sqlite_path);
        defer raw.deinit();
        try raw.exec("create table plain (id integer primary key)");
    }

    var non_zova = try runCli(&.{ "zova", "info", sqlite_path });
    defer non_zova.deinit();
    try std.testing.expectEqual(@as(u8, 3), non_zova.code);
    try expectContains(non_zova.stderr, "open failed");
}

test "cli deep check reports object corruption with exit code 4" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt.zova");
    try createHealthyDatabase(db_path);

    {
        var db = try zova.Database.open(db_path);
        defer db.deinit();
        try db.exec("delete from _zova_chunks");
    }

    var result = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.code);
    try expectContains(result.stderr, "object corruption");
}

test "cli check fails invalid metadata and missing private schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var invalid_meta_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_meta_path = try testingDbPath(&invalid_meta_buffer, tmp.sub_path[0..], "invalid-meta.zova");
    try createHealthyDatabase(invalid_meta_path);
    {
        var raw = try zova.sqlite.Database.open(invalid_meta_path);
        defer raw.deinit();
        try raw.exec("update _zova_meta set value = 'wrong' where key = 'magic'");
    }

    var invalid_meta = try runCli(&.{ "zova", "check", invalid_meta_path });
    defer invalid_meta.deinit();
    try std.testing.expectEqual(@as(u8, 3), invalid_meta.code);
    try expectContains(invalid_meta.stderr, "open failed");

    var missing_schema_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_schema_path = try testingDbPath(&missing_schema_buffer, tmp.sub_path[0..], "missing-schema.zova");
    try createHealthyDatabase(missing_schema_path);
    {
        var raw = try zova.sqlite.Database.open(missing_schema_path);
        defer raw.deinit();
        try raw.exec("drop table _zova_chunks");
    }

    var missing_schema = try runCli(&.{ "zova", "check", missing_schema_path });
    defer missing_schema.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing_schema.code);
    try expectContains(missing_schema.stderr, "open failed");
}

test "cli deep check reports full object hash mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "wrong-object-id.zova");
    try createHealthyDatabase(db_path);

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        const wrong_id = zova.objectId("not hello object");
        var update_object = try raw.prepare("update _zova_objects set object_id = ?");
        defer update_object.deinit();
        try update_object.bindBlob(1, &wrong_id);
        try std.testing.expectEqual(zova.sqlite.Step.done, try update_object.step());

        var update_manifest = try raw.prepare("update _zova_object_chunks set object_id = ?");
        defer update_manifest.deinit();
        try update_manifest.bindBlob(1, &wrong_id);
        try std.testing.expectEqual(zova.sqlite.Step.done, try update_manifest.step());
    }

    var result = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.code);
    try expectContains(result.stderr, "object corruption");
}

test "cli deep check reports vector corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "bad-vector.zova");
    try createHealthyDatabase(db_path);

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec("update _zova_vectors set dimensions = 1, \"values\" = x'0000803f' where vector_id = 'doc-1'");
    }

    var result = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.code);
    try expectContains(result.stderr, "vector corruption");
}

const CliResult = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *CliResult) void {
        std.testing.allocator.free(self.stdout);
        std.testing.allocator.free(self.stderr);
    }
};

fn runCli(args: []const []const u8) !CliResult {
    var stdout_buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_buffer.deinit();

    const code = try cli.run(std.testing.allocator, args, &stdout_buffer.writer, &stderr_buffer.writer);
    return .{
        .code = code,
        .stdout = try std.testing.allocator.dupe(u8, stdout_buffer.written()),
        .stderr = try std.testing.allocator.dupe(u8, stderr_buffer.written()),
    };
}

fn createHealthyDatabase(path: [:0]const u8) !void {
    var db = try zova.Database.create(path);
    defer db.deinit();

    try db.exec(
        \\create table documents (
        \\  id integer primary key,
        \\  object_id blob not null,
        \\  vector_id text not null,
        \\  title text not null
        \\)
    );

    const id = try db.putObject("hello object");
    try insertDocument(&db, id, "doc-1", "hello.txt");
    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("docs", "doc-1", &.{ 1.0, 2.0 });
    try db.putObjectChunk(zova.objectChunkId("loose"), "loose");
}

fn insertDocument(db: *zova.Database, object_id: zova.ObjectId, vector_id: []const u8, title: []const u8) !void {
    var insert = try db.prepare("insert into documents (object_id, vector_id, title) values (?, ?, ?)");
    defer insert.deinit();
    try insert.bindBlob(1, &object_id);
    try insert.bindText(2, vector_id);
    try insert.bindText(3, title);
    try std.testing.expectEqual(zova.sqlite.Step.done, try insert.step());
}

fn testingDbPath(buffer: []u8, sub_path: []const u8, name: []const u8) ![:0]u8 {
    return try std.fmt.bufPrintZ(buffer, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
