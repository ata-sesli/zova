const std = @import("std");
const sqlite = @import("sqlite.zig");
const test_support = @import("zova_test_support.zig");
const trgm = @import("trgm.zig");
const zova = @import("zova.zig");

const testingDbPath = test_support.testingDbPath;

test "bundled trgm installs checks searches drops and reinstalls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "trgm-lifecycle.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();

    try db.installExtension("trgm");

    var info = try db.extensionInfo(std.testing.allocator, "trgm");
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("trgm", info.name);
    try std.testing.expectEqualStrings("0.1.0", info.version);
    try std.testing.expectEqualStrings("_zova_ext_trgm_", info.storage_prefix);

    try db.checkExtension("trgm");
    try execSql(&db, "select zova_trgm_create_index('docs')");
    try execSql(&db, "select zova_trgm_put('docs', 'doc:1', 'record', 'messages', '1', 'attachment upload failed')");
    try execSql(&db, "select zova_trgm_put('docs', 'doc:2', 'record', 'messages', '2', 'database opened successfully')");
    try execSql(&db, "select zova_trgm_put('docs', 'doc:3', 'external', null, 'https://example.test', 'receipt processor')");

    {
        var stmt = try db.prepare(
            \\select document_id, target_type, target_namespace, target_ref, score
            \\from zova_trgm_search
            \\where index_name = 'docs'
            \\  and query = 'attachement failed'
            \\  and "limit" = 1
            \\order by rank
        );
        defer stmt.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("doc:1", stmt.columnText(0));
        try std.testing.expectEqualStrings("record", stmt.columnText(1));
        try std.testing.expectEqualStrings("messages", stmt.columnText(2));
        try std.testing.expectEqualStrings("1", stmt.columnText(3));
        try std.testing.expect(stmt.columnDouble(4) > 0.20);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    try db.dropExtension("trgm");
    try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "trgm"));
    try db.installExtension("trgm");
    try db.checkExtension("trgm");
}

test "trgm similarity documents typo punctuation case and utf8 behavior" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "trgm-similarity.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.installExtension("trgm");

    try expectSimilarity(&db, "attachment", "attachement", 0.50, 1.0);
    try expectSimilarity(&db, "receipt", "reciept", 0.35, 1.0);
    try expectSimilarity(&db, "database", "databse", 0.45, 1.0);
    try expectSimilarity(&db, "", "", 1.0, 1.0);
    try expectSimilarity(&db, "", "hello", 0.0, 0.0);
    try expectSimilarity(&db, "Hello, WORLD", "hello world", 1.0, 1.0);
    try expectSimilarity(&db, "İstanbul", "İstanbul", 1.0, 1.0);
}

test "trgm search respects upsert delete limit threshold transactions and read only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "trgm-search.zova");

    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();
        try db.installExtension("trgm");

        try execSql(&db, "select zova_trgm_create_index('docs')");
        try execSql(&db, "select zova_trgm_put('docs', 'a', 'record', 'messages', 'a', 'alpha attachment')");
        try execSql(&db, "select zova_trgm_put('docs', 'b', 'record', 'messages', 'b', 'alpha attachement')");
        try execSql(&db, "select zova_trgm_put('docs', 'c', 'record', 'messages', 'c', 'completely unrelated')");

        try expectSearchIds(&db, "docs", "alpha attachment", 10, 0.0, &.{ "a", "b" });
        try expectSearchIds(&db, "docs", "alpha attachment", 0, 0.0, &.{});
        try expectSearchIds(&db, "docs", "alpha attachment", 10, 0.80, &.{"a"});

        try execSql(&db, "select zova_trgm_put('docs', 'b', 'record', 'messages', 'b', 'database engine')");
        try expectSearchIds(&db, "docs", "alpha attachment", 10, 0.0, &.{"a"});

        try execSql(&db, "select zova_trgm_delete('docs', 'a')");
        try expectSearchIds(&db, "docs", "alpha attachment", 10, 0.0, &.{});

        try db.begin();
        try execSql(&db, "select zova_trgm_put('docs', 'tx', 'record', 'messages', 'tx', 'rollback text')");
        try db.rollback();
        try expectSearchIds(&db, "docs", "rollback text", 10, 0.0, &.{});

        try db.begin();
        try db.savepoint("sp1");
        try execSql(&db, "select zova_trgm_put('docs', 'sp', 'record', 'messages', 'sp', 'savepoint text')");
        try db.rollbackToSavepoint("sp1");
        try db.releaseSavepoint("sp1");
        try db.commit();
        try expectSearchIds(&db, "docs", "savepoint text", 10, 0.0, &.{});
    }

    {
        var readonly = try zova.Database.openWithOptions(db_path, .{ .read_only = true });
        defer readonly.deinit();
        try expectSearchIds(&readonly, "docs", "database engine", 10, 0.0, &.{"b"});
        try expectSqlError(&readonly, "select zova_trgm_put('docs', 'ro', 'record', 'messages', 'ro', 'blocked')");
    }
}

test "trgm validates zova owned object vector and graph targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "trgm-targets.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.installExtension("trgm");
    try execSql(&db, "select zova_trgm_create_index('targets')");

    const object_id = try db.putObject("attachment bytes");
    const chunk_id = zova.objectChunkId("loose chunk");
    try db.putObjectChunk(chunk_id, "loose chunk");
    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .cosine });
    try db.putVector("chunks", "vec:1", &.{ 1.0, 0.0 });
    try db.createGraph("app");
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "message:1", .kind = "message" });

    var object_hex_buffer: [64]u8 = undefined;
    const object_hex = try hexObjectId(&object_hex_buffer, object_id);
    var chunk_hex_buffer: [64]u8 = undefined;
    const chunk_hex = try hexObjectId(&chunk_hex_buffer, chunk_id);

    try putWithBoundArgs(&db, "targets", "object-doc", "object", null, object_hex, "object attachment");
    try putWithBoundArgs(&db, "targets", "chunk-doc", "object_chunk", null, chunk_hex, "loose chunk");
    try putWithBoundArgs(&db, "targets", "vector-doc", "vector", "chunks", "vec:1", "vector chunk");
    try putWithBoundArgs(&db, "targets", "graph-doc", "graph", "app", "message:1", "graph node");
    try db.checkExtension("trgm");

    try putExpectError(&db, "targets", "missing-object", "object", null, "0000000000000000000000000000000000000000000000000000000000000000", "missing");
    try putExpectError(&db, "targets", "missing-vector", "vector", "chunks", "missing", "missing");
    try putExpectError(&db, "targets", "missing-graph", "graph", "app", "missing", "missing");
}

test "trgm validates sql inputs and accepts app-owned target types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "trgm-validation.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.installExtension("trgm");
    try execSql(&db, "select zova_trgm_create_index('docs')");

    try putWithBoundArgs(&db, "docs", "record-doc", "record", "messages", "1", "record title");
    try putWithBoundArgs(&db, "docs", "entity-doc", "entity", "people", "alice", "alice sesli");
    try putWithBoundArgs(&db, "docs", "fact-doc", "fact", "facts", "fact:1", "stored fact");
    try putWithBoundArgs(&db, "docs", "concept-doc", "concept", "concepts", "graph", "graph concept");
    try putWithBoundArgs(&db, "docs", "external-doc", "external", null, "https://example.test", "external ref");
    try putWithBoundArgs(&db, "docs", "record-null-ref", "record", "messages", null, "record without target ref");
    try putWithBoundArgs(&db, "docs", "external-null-ref", "external", null, null, "external without target ref");

    try putExpectError(&db, "docs", "bad-target", "unknown", null, "ref", "bad target");
    try expectSqlError(&db, "select zova_trgm_create_index('bad name')");
    try expectSqlError(&db, "select zova_trgm_put('missing', 'doc', 'record', 'messages', '1', 'text')");
    try expectSqlError(&db, "select document_id from zova_trgm_search where query = 'text'");
    try expectSqlError(&db, "select document_id from zova_trgm_search where index_name = 'docs'");
    try expectSqlError(&db, "select document_id from zova_trgm_search where index_name = 'docs' and query = 'text' and threshold = 1.5");
    try expectSqlError(&db, "select document_id from zova_trgm_search where index_name = 'docs' and query = 'text' and \"limit\" = -1");
    try expectSqlError(&db, "insert into zova_trgm_search(index_name, query) values ('docs', 'text')");
}

test "trgm check reports private table and posting corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "trgm-corrupt.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.installExtension("trgm");
    try execSql(&db, "select zova_trgm_create_index('docs')");
    try execSql(&db, "select zova_trgm_put('docs', 'doc:1', 'record', 'messages', '1', 'hello world')");
    try db.checkExtension("trgm");

    try db.exec("delete from _zova_ext_trgm_terms");
    try std.testing.expectError(error.ExtensionInvalid, db.checkExtension("trgm"));
}

test "trgm is preserved by backup compact and restore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "trgm-source.zova");
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "trgm-backup.zova");
    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "trgm-compact.zova");
    var restored_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restored_path = try testingDbPath(&restored_buffer, tmp.sub_path[0..], "trgm-restored.zova");

    {
        var db = try zova.Database.create(source_path);
        defer db.deinit();
        try db.installExtension("trgm");
        try execSql(&db, "select zova_trgm_create_index('docs')");
        try execSql(&db, "select zova_trgm_put('docs', 'doc:1', 'record', 'messages', '1', 'attachment upload failed')");
        try db.backupTo(backup_path, .{});
        try db.compactTo(compact_path, .{});
    }

    try zova.restoreBackup(backup_path, restored_path, .{});

    try expectTrgmCopy(backup_path);
    try expectTrgmCopy(compact_path);
    try expectTrgmCopy(restored_path);
}

fn execSql(db: *zova.Database, sql: [:0]const u8) !void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(0));
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

fn expectTrgmCopy(path: [:0]const u8) !void {
    var db = try zova.Database.open(path);
    defer db.deinit();
    try db.checkExtension("trgm");
    try expectSearchIds(&db, "docs", "attachement failed", 1, 0.0, &.{"doc:1"});
}

fn expectSimilarity(db: *zova.Database, a: []const u8, b: []const u8, min: f64, max: f64) !void {
    var stmt = try db.prepare("select zova_trgm_similarity(?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, a);
    try stmt.bindText(2, b);
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    const score = stmt.columnDouble(0);
    try std.testing.expect(score >= min);
    try std.testing.expect(score <= max);
}

fn expectSearchIds(db: *zova.Database, index_name: []const u8, query: []const u8, limit: i64, threshold: f64, expected: []const []const u8) !void {
    var stmt = try db.prepare(
        \\select document_id
        \\from zova_trgm_search
        \\where index_name = ?
        \\  and query = ?
        \\  and "limit" = ?
        \\  and threshold = ?
        \\order by rank
    );
    defer stmt.deinit();
    try stmt.bindText(1, index_name);
    try stmt.bindText(2, query);
    try stmt.bindInt64(3, limit);
    try stmt.bindDouble(4, threshold);

    for (expected) |id| {
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings(id, stmt.columnText(0));
    }
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

fn expectSqlError(db: *zova.Database, sql: [:0]const u8) !void {
    var stmt = db.prepare(sql) catch |err| {
        try std.testing.expectEqual(error.SqliteError, err);
        return;
    };
    defer stmt.deinit();
    try std.testing.expectError(error.SqliteError, stmt.step());
}

fn putWithBoundArgs(
    db: *zova.Database,
    index_name: []const u8,
    document_id: []const u8,
    target_type: []const u8,
    target_namespace: ?[]const u8,
    target_ref: ?[]const u8,
    text: []const u8,
) !void {
    var stmt = try db.prepare("select zova_trgm_put(?, ?, ?, ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, index_name);
    try stmt.bindText(2, document_id);
    try stmt.bindText(3, target_type);
    if (target_namespace) |value| {
        try stmt.bindText(4, value);
    } else {
        try stmt.bindNull(4);
    }
    if (target_ref) |value| {
        try stmt.bindText(5, value);
    } else {
        try stmt.bindNull(5);
    }
    try stmt.bindText(6, text);
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(0));
}

fn putExpectError(
    db: *zova.Database,
    index_name: []const u8,
    document_id: []const u8,
    target_type: []const u8,
    target_namespace: ?[]const u8,
    target_ref: []const u8,
    text: []const u8,
) !void {
    var stmt = try db.prepare("select zova_trgm_put(?, ?, ?, ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, index_name);
    try stmt.bindText(2, document_id);
    try stmt.bindText(3, target_type);
    if (target_namespace) |value| {
        try stmt.bindText(4, value);
    } else {
        try stmt.bindNull(4);
    }
    try stmt.bindText(5, target_ref);
    try stmt.bindText(6, text);
    try std.testing.expectError(error.SqliteError, stmt.step());
}

fn hexObjectId(buffer: *[64]u8, id: [32]u8) ![]const u8 {
    const alphabet = "0123456789abcdef";
    for (id, 0..) |byte, index| {
        buffer[index * 2] = alphabet[byte >> 4];
        buffer[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return buffer[0..];
}

test "trgm module exports extension manifest" {
    const bundled = trgm.extension();
    try std.testing.expectEqualStrings("trgm", bundled.manifest.name);
    try std.testing.expectEqualStrings("_zova_ext_trgm_", bundled.manifest.storage_prefix);
}
