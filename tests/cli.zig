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
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "objects [--json] [--limit <n>] <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "object [--json] [--limit <n>] <file.zova> <object-id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "chunks [--json] [--limit <n>] <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "chunk [--json] [--limit <n>] <file.zova> <chunk-id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "vectors [--json] [--limit <n>] <file.zova>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "vector-collection [--json] [--limit <n>] <file.zova> <name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "tables [--json] [--limit <n>] <file.zova>") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7.25") == null);
}

test "cli info json reports bounded database summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "info-json.zova");
    try createHealthyDatabase(db_path);

    var result = try runCli(&.{ "zova", "info", "--json", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonInt(root, "cli_json_version", 1);
    try expectJsonString(root, "package_version", cli.package_version);
    try expectJsonString(root, "sqlite_version", zova.sqlite.version());
    try expectJsonString(root, "format_version", "3");
    try expectJsonObjectHasInt(root, "files", "database_bytes");
    try expectJsonObjectHasInt(root, "sqlite", "page_count");
    try expectJsonObjectHasInt(root, "objects", "count");
    try expectJsonObjectHasInt(root, "objects", "logical_bytes");
    try expectJsonObjectHasInt(root, "chunks", "count");
    try expectJsonObjectHasInt(root, "chunks", "manifest_rows");
    try expectJsonObjectHasInt(root, "chunks", "loose_count");
    try expectJsonObjectHasInt(root, "vectors", "collections");
    try expectJsonObjectHasInt(root, "tables", "user");
    try expectJsonObjectHasInt(root, "tables", "private");
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "streamed object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "_zova_objects") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7.25") == null);
}

test "cli stats reports deeper bounded database summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "stats.zova");
    try createHealthyDatabase(db_path);

    var result = try runCli(&.{ "zova", "stats", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try expectContains(result.stdout, "Zova stats");
    try expectContains(result.stdout, "object_size_min:");
    try expectContains(result.stdout, "object_chunk_count_avg:");
    try expectContains(result.stdout, "chunk_size_max:");
    try expectContains(result.stdout, "loose_chunk_bytes:");
    try expectContains(result.stdout, "deduped_bytes_saved:");
    try expectContains(result.stdout, "vector_collections:");
    try expectContains(result.stdout, "top_objects:");
    try expectContains(result.stdout, "top_chunks:");
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "streamed object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7.25") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "_zova_objects") == null);
}

test "cli stats json reports deeper bounded database summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "stats-json.zova");
    try createHealthyDatabase(db_path);

    var result = try runCli(&.{ "zova", "stats", "--json", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonInt(root, "cli_json_version", 1);
    try expectJsonString(root, "status", "ok");
    try expectJsonString(root, "command", "stats");
    try expectJsonInt(root, "limit", 10);
    try expectJsonObjectHasInt(root, "objects", "count");
    try expectJsonObjectHasInt(root, "objects", "size_min");
    try expectJsonObjectHasInt(root, "objects", "chunk_count_max");
    try expectJsonObjectHasInt(root, "chunks", "loose_bytes");
    try expectJsonObjectHasInt(root, "chunks", "deduped_bytes_saved");
    try expectJsonArray(root, "vector_collections");
    try expectJsonArray(root, "top_objects");
    try expectJsonArray(root, "top_chunks");
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "streamed object") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "_zova_objects") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "7.25") == null);
}

test "cli stats limit bounds top lists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "stats-limit.zova");
    try createHealthyDatabase(db_path);

    var zero = try runCli(&.{ "zova", "stats", "--json", "--limit", "0", db_path });
    defer zero.deinit();
    try std.testing.expectEqual(@as(u8, 0), zero.code);
    var zero_json = try parseJson(zero.stdout);
    defer zero_json.deinit();
    try expectJsonInt(zero_json.value.object, "limit", 0);
    try expectJsonArrayLen(zero_json.value.object, "top_objects", 0);
    try expectJsonArrayLen(zero_json.value.object, "top_chunks", 0);

    var one = try runCli(&.{ "zova", "stats", "--limit", "1", "--json", db_path });
    defer one.deinit();
    try std.testing.expectEqual(@as(u8, 0), one.code);
    var one_json = try parseJson(one.stdout);
    defer one_json.deinit();
    try expectJsonInt(one_json.value.object, "limit", 1);
    try expectJsonArrayLen(one_json.value.object, "top_objects", 1);
    try expectJsonArrayLen(one_json.value.object, "top_chunks", 1);
}

test "cli stats usage and open failures use existing exit codes" {
    const usage_cases = [_][]const []const u8{
        &.{ "zova", "stats", "--wat", "x.zova" },
        &.{ "zova", "stats", "--json", "--json", "x.zova" },
        &.{ "zova", "stats", "--limit", "1", "--limit", "2", "x.zova" },
        &.{ "zova", "stats", "--limit", "nope", "x.zova" },
        &.{ "zova", "stats", "--limit" },
        &.{ "zova", "stats", "--limit", "101", "x.zova" },
        &.{ "zova", "stats", "x.zova", "extra" },
    };

    for (usage_cases) |args| {
        var result = try runCli(args);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 2), result.code);
    }

    var missing = try runCli(&.{ "zova", "stats", "--json", "missing.zova" });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing.code);
    var missing_json = try parseJson(missing.stderr);
    defer missing_json.deinit();
    try expectJsonString(missing_json.value.object, "command", "stats");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sqlite_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "plain-stats.db");
    {
        var raw = try zova.sqlite.Database.open(sqlite_path);
        defer raw.deinit();
        try raw.exec("create table plain (id integer primary key)");
    }

    var plain = try runCli(&.{ "zova", "stats", sqlite_path });
    defer plain.deinit();
    try std.testing.expectEqual(@as(u8, 3), plain.code);
}

test "cli object and chunk inspection commands report bounded summaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "inspect.zova");
    try createHealthyDatabase(db_path);

    const object_id = try queryText(db_path, "select lower(hex(object_id)) from _zova_objects order by hex(object_id) limit 1");
    defer std.testing.allocator.free(object_id);
    const chunk_id = try queryText(db_path, "select lower(hex(chunk_hash)) from _zova_chunks order by hex(chunk_hash) limit 1");
    defer std.testing.allocator.free(chunk_id);

    var objects_text = try runCli(&.{ "zova", "objects", db_path });
    defer objects_text.deinit();
    try std.testing.expectEqual(@as(u8, 0), objects_text.code);
    try expectContains(objects_text.stdout, "Zova objects");
    try expectContains(objects_text.stdout, object_id);
    try expectContains(objects_text.stdout, "size_bytes=");
    try expectContains(objects_text.stdout, "chunk_count=");
    try std.testing.expect(std.mem.indexOf(u8, objects_text.stdout, "hello object") == null);
    try std.testing.expect(std.mem.indexOf(u8, objects_text.stdout, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, objects_text.stdout, "_zova_objects") == null);

    var objects_json = try runCli(&.{ "zova", "objects", "--json", db_path });
    defer objects_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), objects_json.code);
    var parsed_objects = try parseJson(objects_json.stdout);
    defer parsed_objects.deinit();
    const objects_root = parsed_objects.value.object;
    try expectJsonString(objects_root, "command", "objects");
    try expectJsonInt(objects_root, "limit", 10);
    try expectJsonArray(objects_root, "objects");

    var object_json = try runCli(&.{ "zova", "object", "--json", db_path, object_id });
    defer object_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), object_json.code);
    var parsed_object = try parseJson(object_json.stdout);
    defer parsed_object.deinit();
    const object_root = parsed_object.value.object;
    try expectJsonString(object_root, "command", "object");
    try expectJsonString(object_root, "object_id", object_id);
    try expectJsonArray(object_root, "manifest");
    try std.testing.expect(std.mem.indexOf(u8, object_json.stdout, "hello object") == null);

    var chunks_text = try runCli(&.{ "zova", "chunks", db_path });
    defer chunks_text.deinit();
    try std.testing.expectEqual(@as(u8, 0), chunks_text.code);
    try expectContains(chunks_text.stdout, "Zova chunks");
    try expectContains(chunks_text.stdout, chunk_id);
    try expectContains(chunks_text.stdout, "reference_count=");
    try expectContains(chunks_text.stdout, "is_unreferenced=");
    try std.testing.expect(std.mem.indexOf(u8, chunks_text.stdout, "hidden chunk bytes") == null);

    var chunk_json = try runCli(&.{ "zova", "chunk", "--json", db_path, chunk_id });
    defer chunk_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), chunk_json.code);
    var parsed_chunk = try parseJson(chunk_json.stdout);
    defer parsed_chunk.deinit();
    const chunk_root = parsed_chunk.value.object;
    try expectJsonString(chunk_root, "command", "chunk");
    try expectJsonString(chunk_root, "chunk_hash", chunk_id);
    try expectJsonObjectHasInt(chunk_root, "chunk", "size_bytes");
    try expectJsonArray(chunk_root, "references");
    try std.testing.expect(std.mem.indexOf(u8, chunk_json.stdout, "hidden chunk bytes") == null);
}

test "cli object and chunk inspection limits and uppercase ids work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "inspect-limits.zova");
    try createHealthyDatabase(db_path);

    const object_id = try queryText(db_path, "select lower(hex(object_id)) from _zova_objects order by hex(object_id) limit 1");
    defer std.testing.allocator.free(object_id);
    const referenced_chunk_id = try queryText(db_path, "select lower(hex(chunk_hash)) from _zova_object_chunks order by hex(chunk_hash) limit 1");
    defer std.testing.allocator.free(referenced_chunk_id);
    const object_id_upper = try asciiUpperAlloc(object_id);
    defer std.testing.allocator.free(object_id_upper);
    const chunk_id_upper = try asciiUpperAlloc(referenced_chunk_id);
    defer std.testing.allocator.free(chunk_id_upper);

    var objects_zero = try runCli(&.{ "zova", "objects", "--json", "--limit", "0", db_path });
    defer objects_zero.deinit();
    try std.testing.expectEqual(@as(u8, 0), objects_zero.code);
    var objects_zero_json = try parseJson(objects_zero.stdout);
    defer objects_zero_json.deinit();
    try expectJsonArrayLen(objects_zero_json.value.object, "objects", 0);
    try expectJsonBool(objects_zero_json.value.object, "truncated", true);

    var object_zero = try runCli(&.{ "zova", "object", "--json", "--limit", "0", db_path, object_id_upper });
    defer object_zero.deinit();
    try std.testing.expectEqual(@as(u8, 0), object_zero.code);
    var object_zero_json = try parseJson(object_zero.stdout);
    defer object_zero_json.deinit();
    try expectJsonString(object_zero_json.value.object, "object_id", object_id);
    try expectJsonArrayLen(object_zero_json.value.object, "manifest", 0);
    try expectJsonBool(object_zero_json.value.object, "manifest_truncated", true);

    var chunks_one = try runCli(&.{ "zova", "chunks", "--limit", "1", "--json", db_path });
    defer chunks_one.deinit();
    try std.testing.expectEqual(@as(u8, 0), chunks_one.code);
    var chunks_one_json = try parseJson(chunks_one.stdout);
    defer chunks_one_json.deinit();
    try expectJsonArrayLen(chunks_one_json.value.object, "chunks", 1);
    try expectJsonBool(chunks_one_json.value.object, "truncated", true);

    var chunk_zero = try runCli(&.{ "zova", "chunk", "--json", "--limit", "0", db_path, chunk_id_upper });
    defer chunk_zero.deinit();
    try std.testing.expectEqual(@as(u8, 0), chunk_zero.code);
    var chunk_zero_json = try parseJson(chunk_zero.stdout);
    defer chunk_zero_json.deinit();
    try expectJsonString(chunk_zero_json.value.object, "chunk_hash", referenced_chunk_id);
    try expectJsonArrayLen(chunk_zero_json.value.object, "references", 0);
    try expectJsonBool(chunk_zero_json.value.object, "references_truncated", true);
}

test "cli object detail limit does not require full manifest validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "bounded-object-detail.zova");

    var object_id: zova.ObjectId = undefined;
    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();

        const bytes = try std.testing.allocator.alloc(u8, 200 * 1024);
        defer std.testing.allocator.free(bytes);
        fillDeterministic(bytes);

        object_id = try db.putObject(bytes);

        var delete_later_manifest_rows = try db.prepare("delete from _zova_object_chunks where object_id = ? and chunk_index > 0");
        defer delete_later_manifest_rows.deinit();
        try delete_later_manifest_rows.bindBlob(1, &object_id);
        try std.testing.expectEqual(zova.sqlite.Step.done, try delete_later_manifest_rows.step());
    }

    const object_id_hex = try lowerHexAlloc(&object_id);
    defer std.testing.allocator.free(object_id_hex);

    var result = try runCli(&.{ "zova", "object", "--json", "--limit", "1", db_path, object_id_hex });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectJsonString(parsed.value.object, "command", "object");
    try expectJsonString(parsed.value.object, "object_id", object_id_hex);
    try expectJsonArrayLen(parsed.value.object, "manifest", 1);
    try expectJsonBool(parsed.value.object, "manifest_truncated", true);
}

test "cli object and chunk inspection usage and missing ids use expected exit codes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "inspect-errors.zova");
    try createHealthyDatabase(db_path);

    const usage_cases = [_][]const []const u8{
        &.{ "zova", "objects", "--wat", db_path },
        &.{ "zova", "objects", "--json", "--json", db_path },
        &.{ "zova", "objects", "--limit", "1", "--limit", "2", db_path },
        &.{ "zova", "objects", "--limit", "abc", db_path },
        &.{ "zova", "objects", "--limit" },
        &.{ "zova", "objects", db_path, "extra" },
        &.{ "zova", "object", db_path },
        &.{ "zova", "object", db_path, "abc" },
        &.{ "zova", "object", db_path, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" },
        &.{ "zova", "object", db_path, missingHexId(), "extra" },
        &.{ "zova", "chunks", "--wat", db_path },
        &.{ "zova", "chunk", db_path },
        &.{ "zova", "chunk", db_path, "abc" },
        &.{ "zova", "chunk", db_path, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" },
    };

    for (usage_cases) |args| {
        var result = try runCli(args);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 2), result.code);
    }

    var duplicate_objects_json = try runCli(&.{ "zova", "objects", "--json", "--json", db_path });
    defer duplicate_objects_json.deinit();
    try std.testing.expectEqual(@as(u8, 2), duplicate_objects_json.code);
    var duplicate_objects_error = try parseJson(duplicate_objects_json.stderr);
    defer duplicate_objects_error.deinit();
    try expectJsonString(duplicate_objects_error.value.object, "command", "objects");

    var missing_limit_chunk_json = try runCli(&.{ "zova", "chunk", "--json", "--limit" });
    defer missing_limit_chunk_json.deinit();
    try std.testing.expectEqual(@as(u8, 2), missing_limit_chunk_json.code);
    var missing_limit_chunk_error = try parseJson(missing_limit_chunk_json.stderr);
    defer missing_limit_chunk_error.deinit();
    try expectJsonString(missing_limit_chunk_error.value.object, "command", "chunk");

    var missing_object = try runCli(&.{ "zova", "object", "--json", db_path, missingHexId() });
    defer missing_object.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing_object.code);
    var missing_object_json = try parseJson(missing_object.stderr);
    defer missing_object_json.deinit();
    try expectJsonString(missing_object_json.value.object, "command", "object");

    var missing_chunk = try runCli(&.{ "zova", "chunk", db_path, missingHexId() });
    defer missing_chunk.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing_chunk.code);
    try expectContains(missing_chunk.stderr, "not found");

    var missing_file = try runCli(&.{ "zova", "objects", "missing.zova" });
    defer missing_file.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing_file.code);
}

test "cli vector and table inspection commands report bounded summaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vectors-tables.zova");
    try createHealthyDatabase(db_path);
    {
        var db = try zova.Database.open(db_path);
        defer db.deinit();
        try db.createVectorCollection("images", .{ .dimensions = 2, .metric = .dot });
        try db.putVectors("images", &.{
            .{ .id = "image-1", .values = &.{ 1.0, 2.0 } },
            .{ .id = "image-2", .values = &.{ 2.0, 3.0 } },
        });
    }

    var vectors_text = try runCli(&.{ "zova", "vectors", db_path });
    defer vectors_text.deinit();
    try std.testing.expectEqual(@as(u8, 0), vectors_text.code);
    try expectContains(vectors_text.stdout, "Zova vector collections");
    try expectContains(vectors_text.stdout, "docs");
    try expectContains(vectors_text.stdout, "images");
    try expectContains(vectors_text.stdout, "dimensions=");
    try expectContains(vectors_text.stdout, "stored_bytes=");
    try std.testing.expect(std.mem.indexOf(u8, vectors_text.stdout, "7.25") == null);

    var vectors_json = try runCli(&.{ "zova", "vectors", "--json", "--limit", "1", db_path });
    defer vectors_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), vectors_json.code);
    var parsed_vectors = try parseJson(vectors_json.stdout);
    defer parsed_vectors.deinit();
    try expectJsonString(parsed_vectors.value.object, "command", "vectors");
    try expectJsonArrayLen(parsed_vectors.value.object, "collections", 1);
    try expectJsonBool(parsed_vectors.value.object, "truncated", true);
    try std.testing.expect(std.mem.indexOf(u8, vectors_json.stdout, "7.25") == null);

    var collection_json = try runCli(&.{ "zova", "vector-collection", "--json", "--limit", "1", db_path, "images" });
    defer collection_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), collection_json.code);
    var parsed_collection = try parseJson(collection_json.stdout);
    defer parsed_collection.deinit();
    const collection_root = parsed_collection.value.object;
    try expectJsonString(collection_root, "command", "vector-collection");
    try expectJsonString(collection_root, "name", "images");
    try expectJsonInt(collection_root, "dimensions", 2);
    try expectJsonString(collection_root, "metric", "dot");
    try expectJsonArrayLen(collection_root, "vector_ids", 1);
    try expectJsonBool(collection_root, "vector_ids_truncated", true);
    try std.testing.expect(std.mem.indexOf(u8, collection_json.stdout, "2.0") == null);

    var tables_text = try runCli(&.{ "zova", "tables", db_path });
    defer tables_text.deinit();
    try std.testing.expectEqual(@as(u8, 0), tables_text.code);
    try expectContains(tables_text.stdout, "Zova tables");
    try expectContains(tables_text.stdout, "user_tables:");
    try expectContains(tables_text.stdout, "private_tables:");
    try expectContains(tables_text.stdout, "documents");
    try expectContains(tables_text.stdout, "_zova_objects");
    try std.testing.expect(std.mem.indexOf(u8, tables_text.stdout, "create table") == null);
    try std.testing.expect(std.mem.indexOf(u8, tables_text.stdout, "hello.txt") == null);

    var tables_json = try runCli(&.{ "zova", "tables", "--json", "--limit", "0", db_path });
    defer tables_json.deinit();
    try std.testing.expectEqual(@as(u8, 0), tables_json.code);
    var parsed_tables = try parseJson(tables_json.stdout);
    defer parsed_tables.deinit();
    try expectJsonString(parsed_tables.value.object, "command", "tables");
    try expectJsonArrayLen(parsed_tables.value.object, "user_tables", 0);
    try expectJsonArrayLen(parsed_tables.value.object, "private_tables", 0);
    try expectJsonBool(parsed_tables.value.object, "user_tables_truncated", true);
    try expectJsonBool(parsed_tables.value.object, "private_tables_truncated", true);
}

test "cli vector and table inspection usage failures use expected exit codes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-table-errors.zova");
    try createHealthyDatabase(db_path);

    const usage_cases = [_][]const []const u8{
        &.{ "zova", "vectors", "--wat", db_path },
        &.{ "zova", "vectors", "--json", "--json", db_path },
        &.{ "zova", "vector-collection", db_path },
        &.{ "zova", "vector-collection", db_path, "_zova_bad" },
        &.{ "zova", "vector-collection", db_path, "bad\xff" },
        &.{ "zova", "vector-collection", db_path, "docs", "extra" },
        &.{ "zova", "tables", "--limit", "101", db_path },
        &.{ "zova", "tables", db_path, "extra" },
    };

    for (usage_cases) |args| {
        var result = try runCli(args);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 2), result.code);
    }

    var missing_collection = try runCli(&.{ "zova", "vector-collection", "--json", db_path, "missing" });
    defer missing_collection.deinit();
    try std.testing.expectEqual(@as(u8, 4), missing_collection.code);
    var missing_json = try parseJson(missing_collection.stderr);
    defer missing_json.deinit();
    try expectJsonString(missing_json.value.object, "command", "vector-collection");
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

test "cli check json succeeds for healthy databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "check-json.zova");
    try createHealthyDatabase(db_path);

    var quick = try runCli(&.{ "zova", "check", "--json", db_path });
    defer quick.deinit();
    try std.testing.expectEqual(@as(u8, 0), quick.code);
    var quick_json = try parseJson(quick.stdout);
    defer quick_json.deinit();
    const quick_root = quick_json.value.object;
    try expectJsonInt(quick_root, "cli_json_version", 1);
    try expectJsonString(quick_root, "status", "ok");
    try expectJsonString(quick_root, "quick_check", "ok");
    try std.testing.expect(quick_root.get("deep_check") == null);

    var deep = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer deep.deinit();
    try std.testing.expectEqual(@as(u8, 0), deep.code);
    var deep_json = try parseJson(deep.stdout);
    defer deep_json.deinit();
    const deep_root = deep_json.value.object;
    try expectJsonString(deep_root, "status", "ok");
    try expectJsonString(deep_root, "deep_check", "ok");
    try expectJsonObjectHasInt(deep_root, "checked", "objects");
    try expectJsonObjectHasInt(deep_root, "checked", "chunks");
    try expectJsonObjectHasInt(deep_root, "checked", "vectors");
    try expectJsonObjectHasInt(deep_root, "checked", "loose_chunks");
    try expectJsonInt(deep_root, "issue_count", 0);
    try expectJsonObjectHasInt(deep_root, "issue_counts", "object");
    try expectJsonObjectHasInt(deep_root, "issue_counts", "chunk");
    try expectJsonObjectHasInt(deep_root, "issue_counts", "vector");
    try expectJsonArrayLen(deep_root, "issues", 0);

    var reversed = try runCli(&.{ "zova", "check", "--deep", "--json", db_path });
    defer reversed.deinit();
    try std.testing.expectEqual(@as(u8, 0), reversed.code);
    var reversed_json = try parseJson(reversed.stdout);
    defer reversed_json.deinit();
    try expectJsonString(reversed_json.value.object, "deep_check", "ok");
}

test "cli check reports healthy converted database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var sqlite_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sqlite_path = try testingDbPath(&sqlite_path_buffer, tmp.sub_path[0..], "source.db");
    {
        var raw = try zova.sqlite.Database.open(sqlite_path);
        defer raw.deinit();
        try raw.exec(
            \\create table notes (id integer primary key, body text not null);
            \\insert into notes (body) values ('kept as sql');
        );
    }

    var zova_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const zova_path = try testingDbPath(&zova_path_buffer, tmp.sub_path[0..], "converted.zova");
    try zova.convertSqliteToZova(sqlite_path, zova_path);

    {
        var db = try zova.Database.open(zova_path);
        defer db.deinit();
        _ = try db.putObject("converted object");
        try db.createVectorCollection("converted", .{ .dimensions = 2, .metric = .l2 });
        try db.putVector("converted", "note-1", &.{ 3.0, 4.0 });
    }

    var info = try runCli(&.{ "zova", "info", zova_path });
    defer info.deinit();
    try std.testing.expectEqual(@as(u8, 0), info.code);
    try expectContains(info.stdout, "user_tables: 1");

    var check = try runCli(&.{ "zova", "check", "--deep", zova_path });
    defer check.deinit();
    try std.testing.expectEqual(@as(u8, 0), check.code);
    try expectContains(check.stdout, "deep_check: ok");

    var stats = try runCli(&.{ "zova", "stats", "--json", zova_path });
    defer stats.deinit();
    try std.testing.expectEqual(@as(u8, 0), stats.code);
    var stats_json = try parseJson(stats.stdout);
    defer stats_json.deinit();
    const stats_root = stats_json.value.object;
    try expectJsonObjectHasInt(stats_root, "tables", "user");
    try expectJsonObjectHasInt(stats_root, "objects", "count");
    try expectJsonObjectHasInt(stats_root, "vectors", "rows");
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

test "cli json mode preserves open and corruption exit codes" {
    var missing = try runCli(&.{ "zova", "info", "--json", "missing.zova" });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 3), missing.code);
    var missing_json = try parseJson(missing.stderr);
    defer missing_json.deinit();
    const missing_root = missing_json.value.object;
    try expectJsonInt(missing_root, "cli_json_version", 1);
    try expectJsonString(missing_root, "status", "error");
    try expectJsonString(missing_root, "command", "info");
    try std.testing.expect(missing_root.get("error") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "json-corrupt.zova");
    try createHealthyDatabase(db_path);

    {
        var db = try zova.Database.open(db_path);
        defer db.deinit();
        try db.exec("delete from _zova_chunks");
    }

    var corrupt = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer corrupt.deinit();
    try std.testing.expectEqual(@as(u8, 4), corrupt.code);
    var corrupt_json = try parseJson(corrupt.stderr);
    defer corrupt_json.deinit();
    const corrupt_root = corrupt_json.value.object;
    try expectJsonInt(corrupt_root, "cli_json_version", 1);
    try expectJsonString(corrupt_root, "status", "error");
    try expectJsonString(corrupt_root, "command", "check");
    try expectJsonObjectHasInt(corrupt_root, "issue_counts", "object");
    try expectJsonArray(corrupt_root, "issues");
}

test "cli json flag usage errors return exit code 2" {
    var unknown_info = try runCli(&.{ "zova", "info", "--wat", "x.zova" });
    defer unknown_info.deinit();
    try std.testing.expectEqual(@as(u8, 2), unknown_info.code);

    var duplicate_info = try runCli(&.{ "zova", "info", "--json", "--json", "x.zova" });
    defer duplicate_info.deinit();
    try std.testing.expectEqual(@as(u8, 2), duplicate_info.code);

    var duplicate_check = try runCli(&.{ "zova", "check", "--json", "--json", "x.zova" });
    defer duplicate_check.deinit();
    try std.testing.expectEqual(@as(u8, 2), duplicate_check.code);

    var extra = try runCli(&.{ "zova", "check", "--json", "x.zova", "extra" });
    defer extra.deinit();
    try std.testing.expectEqual(@as(u8, 2), extra.code);
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
    try expectContains(result.stderr, "deep_check: failed");
    try expectContains(result.stderr, "issue_count:");
    try expectContains(result.stderr, "object_issues:");
}

test "cli deep check reports multiple structured issue categories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "multiple-issues.zova");
    try createHealthyDatabase(db_path);

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec(
            \\update _zova_chunks
            \\set data = x'636f7272757074', size_bytes = 7
            \\where rowid = (select rowid from _zova_chunks limit 1);
            \\update _zova_vectors
            \\set dimensions = 1, "values" = x'0000c07f'
            \\where vector_id = 'doc-1';
        );
    }

    var result = try runCli(&.{ "zova", "check", "--json", "--deep", db_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.code);
    var parsed = try parseJson(result.stderr);
    defer parsed.deinit();
    const root = parsed.value.object;
    try expectJsonString(root, "command", "check");
    try expectJsonString(root, "status", "error");
    try expectJsonObjectHasInt(root, "issue_counts", "chunk");
    try expectJsonObjectHasInt(root, "issue_counts", "vector");
    try expectJsonArray(root, "issues");
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "corrupt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "doc-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "hidden chunk bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "7.25") == null);
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
    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
        _ = try db.putObject("hello object");
    }

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

test "cli deep check covers writer-created object and sql-introduced corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-and-corruption.zova");
    try createHealthyDatabase(db_path);

    var healthy = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer healthy.deinit();
    try std.testing.expectEqual(@as(u8, 0), healthy.code);
    try expectContains(healthy.stdout, "objects_checked: 2");
    try expectContains(healthy.stdout, "vectors_checked: 1");
    try expectContains(healthy.stdout, "loose_chunks: 1");

    {
        var raw = try zova.sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec("update _zova_chunks set data = x'636f7272757074', size_bytes = 7 where rowid = (select rowid from _zova_chunks limit 1)");
    }

    var corrupt = try runCli(&.{ "zova", "check", "--deep", db_path });
    defer corrupt.deinit();
    try std.testing.expectEqual(@as(u8, 4), corrupt.code);
    try expectContains(corrupt.stderr, "object corruption");
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
    try db.putVector("docs", "doc-1", &.{ 7.25, 8.5 });
    try db.putObjectChunk(zova.objectChunkId("hidden chunk bytes"), "hidden chunk bytes");

    var writer = try db.objectWriter(std.testing.allocator);
    defer writer.deinit();
    try writer.write("streamed ");
    try writer.write("object");
    _ = try writer.finish();
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

fn missingHexId() []const u8 {
    return "0000000000000000000000000000000000000000000000000000000000000000";
}

fn queryText(path: [:0]const u8, sql: [:0]const u8) ![]u8 {
    var db = try zova.sqlite.Database.open(path);
    defer db.deinit();

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .row => try std.testing.allocator.dupe(u8, stmt.columnText(0)),
        .done => error.NoRows,
    };
}

fn asciiUpperAlloc(value: []const u8) ![]u8 {
    const out = try std.testing.allocator.dupe(u8, value);
    for (out) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return out;
}

fn lowerHexAlloc(bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try std.testing.allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[@intCast(byte >> 4)];
        out[index * 2 + 1] = digits[@intCast(byte & 0x0f)];
    }
    return out;
}

fn fillDeterministic(bytes: []u8) void {
    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 31 + index / 7 + 11) % 256);
    }
}

fn parseJson(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
}

fn expectJsonInt(object: std.json.ObjectMap, key: []const u8, expected: i64) !void {
    const value = object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.integer, std.meta.activeTag(value));
    try std.testing.expectEqual(expected, value.integer);
}

fn expectJsonString(object: std.json.ObjectMap, key: []const u8, expected: []const u8) !void {
    const value = object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.string, std.meta.activeTag(value));
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectJsonObjectHasInt(object: std.json.ObjectMap, object_key: []const u8, key: []const u8) !void {
    const value = object.get(object_key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.object, std.meta.activeTag(value));
    const child = value.object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.integer, std.meta.activeTag(child));
}

fn expectJsonArray(object: std.json.ObjectMap, key: []const u8) !void {
    const value = object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.array, std.meta.activeTag(value));
}

fn expectJsonArrayLen(object: std.json.ObjectMap, key: []const u8, expected: usize) !void {
    const value = object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.array, std.meta.activeTag(value));
    try std.testing.expectEqual(expected, value.array.items.len);
}

fn expectJsonBool(object: std.json.ObjectMap, key: []const u8, expected: bool) !void {
    const value = object.get(key) orelse return error.MissingJsonField;
    try std.testing.expectEqual(std.json.Value.bool, std.meta.activeTag(value));
    try std.testing.expectEqual(expected, value.bool);
}
