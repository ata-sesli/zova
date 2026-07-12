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

test "trgm handles short strings and moderate document counts deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "trgm-short-moderate.zova");

    var db = try zova.Database.create(db_path);
    defer db.deinit();
    try db.installExtension("trgm");
    try execSql(&db, "select zova_trgm_create_index('docs')");

    try putWithBoundArgs(&db, "docs", "short:a", "record", "messages", "short:a", "a");
    try putWithBoundArgs(&db, "docs", "short:ab", "record", "messages", "short:ab", "ab");
    try putWithBoundArgs(&db, "docs", "short:abc", "record", "messages", "short:abc", "abc");
    try expectSearchIds(&db, "docs", "ab", 3, 0.0, &.{ "short:ab", "short:abc", "short:a" });

    var index: usize = 0;
    while (index < 128) : (index += 1) {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "doc:{d:0>3}", .{index});
        var ref_buffer: [32]u8 = undefined;
        const target_ref = try std.fmt.bufPrint(&ref_buffer, "messages:{d}", .{index});
        var text_buffer: [160]u8 = undefined;
        const text = if (index == 42)
            try std.fmt.bufPrint(&text_buffer, "moderate corpus document target neon orbital attachment receipt database", .{})
        else
            try std.fmt.bufPrint(&text_buffer, "moderate corpus document {d:0>3} filler archive note", .{index});
        try putWithBoundArgs(&db, "docs", id, "record", "messages", target_ref, text);
    }

    try expectSearchIds(&db, "docs", "neon orbital attachment receipt databse", 1, 0.0, &.{"doc:042"});
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
    try db.putVector("chunks", "vec:1", .{ .f32 = &.{ 1.0, 0.0 } });
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

test "trgm validates object and vector targets routed through bound stores" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "trgm-bound-main.zova");
    var object_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_store_path = try testingDbPath(&object_store_buffer, tmp.sub_path[0..], "trgm-bound-objects.zova");
    var vector_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vector_store_path = try testingDbPath(&vector_store_buffer, tmp.sub_path[0..], "trgm-bound-vectors.zova");

    try zova.createObjectStore(object_store_path);
    try zova.createVectorStore(vector_store_path);

    var db = try zova.Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(object_store_path);
    try db.bindVectorStore(vector_store_path);
    try db.installExtension("trgm");
    try execSql(&db, "select zova_trgm_create_index('targets')");

    const object_id = try db.putObject("bound attachment bytes");
    var object_hex_buffer: [64]u8 = undefined;
    const object_hex = try hexObjectId(&object_hex_buffer, object_id);
    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .cosine });
    try db.putVector("chunks", "vec:bound", .{ .f32 = &.{ 1.0, 0.0 } });

    try putWithBoundArgs(&db, "targets", "bound-object", "object", null, object_hex, "bound object target");
    try putWithBoundArgs(&db, "targets", "bound-vector", "vector", "chunks", "vec:bound", "bound vector target");
    try db.checkExtension("trgm");

    try db.deleteObject(object_id);
    try std.testing.expectError(error.ExtensionInvalid, db.checkExtension("trgm"));
}

test "object vector and graph stores coexist through reopen and backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "three-store-main.zova");
    var object_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_path = try testingDbPath(&object_buffer, tmp.sub_path[0..], "three-store-objects.zova");
    var vector_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vector_path = try testingDbPath(&vector_buffer, tmp.sub_path[0..], "three-store-vectors.zova");
    var graph_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const graph_path = try testingDbPath(&graph_buffer, tmp.sub_path[0..], "three-store-graph.zova");
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "three-store-backup.zova");

    try zova.createObjectStore(object_path);
    try zova.createVectorStore(vector_path);
    try zova.createGraphStore(graph_path);

    const object_id = objectId: {
        var db = try zova.Database.create(main_path);
        defer db.deinit();
        try db.bindObjectStore(object_path);
        try db.bindVectorStore(vector_path);
        try db.bindGraphStore(graph_path);
        try expectAttachedStoreCount(&db, 3);
        try expectStoreEpochs(&db, 0, 0, 0);

        const id = try db.putObject("three attached stores");
        try expectStoreEpochs(&db, 1, 0, 0);
        try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .cosine });
        try db.putVector("chunks", "vec:three", .{ .f32 = &.{ 1.0, 0.0 } });
        try expectStoreEpochs(&db, 1, 2, 0);

        var object_hex_buffer: [64]u8 = undefined;
        const object_hex = try hexObjectId(&object_hex_buffer, id);
        try db.createGraph("links");
        try db.putGraphNode(.{ .graph_name = "links", .node_id = "object", .kind = "attachment", .target_type = .object, .target_ref = object_hex });
        try db.putGraphNode(.{ .graph_name = "links", .node_id = "vector", .kind = "embedding", .target_type = .vector, .target_namespace = "chunks", .target_ref = "vec:three" });
        try db.putGraphEdge(.{ .graph_name = "links", .from_node_id = "object", .edge_type = "embedded_as", .to_node_id = "vector" });
        try expectStoreEpochs(&db, 1, 2, 4);
        break :objectId id;
    };

    {
        var reopened = try zova.Database.open(main_path);
        defer reopened.deinit();
        try expectAttachedStoreCount(&reopened, 3);
        try expectStoreEpochs(&reopened, 1, 2, 4);

        var object = try reopened.getObject(std.testing.allocator, object_id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "three attached stores", object.bytes);
        var vectors = try reopened.searchVectors(std.testing.allocator, "chunks", .{ .f32 = &.{ 1.0, 0.0 } }, 1);
        defer vectors.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), vectors.items.len);
        try std.testing.expectEqualStrings("vec:three", vectors.items[0].id);
        try expectThreeStoreGraphTargets(&reopened, object_id);
        var walk = try reopened.graphWalk(std.testing.allocator, .{ .graph_name = "links", .start_node_id = "object", .max_depth = 1, .limit = 10 });
        defer walk.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), walk.items.len);
        try std.testing.expectEqualStrings("vector", walk.items[1].node_id);

        try reopened.backupTo(backup_path, .{});
    }

    {
        var backup = try zova.Database.open(backup_path);
        defer backup.deinit();
        try std.testing.expectEqual(@as(i64, 1), try countSqlRows(&backup.sqlite_db, "select count(*) from pragma_database_list"));
        try std.testing.expectEqual(@as(?zova.BoundObjectStoreInfo, null), try backup.boundObjectStore(std.testing.allocator));
        try std.testing.expectEqual(@as(?zova.BoundVectorStoreInfo, null), try backup.boundVectorStore(std.testing.allocator));
        try std.testing.expectEqual(@as(?zova.BoundGraphStoreInfo, null), try backup.boundGraphStore(std.testing.allocator));
        var object = try backup.getObject(std.testing.allocator, object_id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "three attached stores", object.bytes);
        var vectors = try backup.searchVectors(std.testing.allocator, "chunks", .{ .f32 = &.{ 1.0, 0.0 } }, 1);
        defer vectors.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("vec:three", vectors.items[0].id);
        var walk = try backup.graphWalk(std.testing.allocator, .{ .graph_name = "links", .start_node_id = "object", .max_depth = 1, .limit = 10 });
        defer walk.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), walk.items.len);
        try expectThreeStoreGraphTargets(&backup, object_id);
    }
}

test "split object and vector stores preserve trgm metadata and target references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var object_main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_main_path = try testingDbPath(&object_main_buffer, tmp.sub_path[0..], "trgm-split-object-main.zova");
    var object_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const object_store_path = try testingDbPath(&object_store_buffer, tmp.sub_path[0..], "trgm-split-object-store.zova");

    {
        var db = try zova.Database.create(object_main_path);
        defer db.deinit();
        try db.installExtension("trgm");
        try execSql(&db, "select zova_trgm_create_index('attachments')");
        const object_id = try db.putObject("single-file attachment before split");
        var object_hex_buffer: [64]u8 = undefined;
        const object_hex = try hexObjectId(&object_hex_buffer, object_id);
        try putWithBoundArgs(&db, "attachments", "attachment:1", "object", null, object_hex, "invoice attachment filename");

        _ = try db.splitObjectStore(object_store_path);
        try db.checkExtension("trgm");
        try expectSearchIds(&db, "attachments", "invoice filename", 1, 0.0, &.{"attachment:1"});
    }

    {
        var reopened = try zova.Database.open(object_main_path);
        defer reopened.deinit();
        try reopened.checkExtension("trgm");
        try expectSearchIds(&reopened, "attachments", "invoice filename", 1, 0.0, &.{"attachment:1"});
    }

    var vector_main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vector_main_path = try testingDbPath(&vector_main_buffer, tmp.sub_path[0..], "trgm-split-vector-main.zova");
    var vector_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vector_store_path = try testingDbPath(&vector_store_buffer, tmp.sub_path[0..], "trgm-split-vector-store.zova");

    {
        var db = try zova.Database.create(vector_main_path);
        defer db.deinit();
        try db.installExtension("trgm");
        try execSql(&db, "select zova_trgm_create_index('chunks')");
        try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .cosine });
        try db.putVector("chunks", "chunk:1", .{ .f32 = &.{ 1.0, 0.0 } });
        try putWithBoundArgs(&db, "chunks", "chunk:1", "vector", "chunks", "chunk:1", "semantic chunk receipt text");

        _ = try db.splitVectorStore(vector_store_path);
        try db.checkExtension("trgm");
        try expectSearchIds(&db, "chunks", "reciept text", 1, 0.0, &.{"chunk:1"});
    }

    {
        var reopened = try zova.Database.open(vector_main_path);
        defer reopened.deinit();
        try reopened.checkExtension("trgm");
        try expectSearchIds(&reopened, "chunks", "reciept text", 1, 0.0, &.{"chunk:1"});
    }
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

test "trgm salvage rebuilds terms from copied postings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "trgm-salvage-rebuild-source.zova");
    var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination_path = try testingDbPath(&destination_buffer, tmp.sub_path[0..], "trgm-salvage-rebuild-destination.zova");

    {
        var db = try zova.Database.create(source_path);
        defer db.deinit();
        try db.installExtension("trgm");
        try execSql(&db, "select zova_trgm_create_index('docs')");
        try execSql(&db, "select zova_trgm_put('docs', 'doc:1', 'record', 'messages', '1', 'attachment upload failed')");
        try execSql(&db, "select zova_trgm_put('docs', 'doc:2', 'record', 'messages', '2', 'database opened successfully')");
    }
    {
        var raw = try sqlite.Database.open(source_path);
        defer raw.deinit();
        try raw.exec("delete from _zova_ext_trgm_terms");
    }

    try copyTrgmSalvage(source_path, destination_path, 1, 0);
    try expectTrgmCopy(destination_path);
}

test "trgm salvage copies valid subset when one document is unrecoverable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "trgm-salvage-subset-source.zova");
    var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination_path = try testingDbPath(&destination_buffer, tmp.sub_path[0..], "trgm-salvage-subset-destination.zova");

    {
        var db = try zova.Database.create(source_path);
        defer db.deinit();
        try db.installExtension("trgm");
        try execSql(&db, "select zova_trgm_create_index('docs')");
        try execSql(&db, "select zova_trgm_put('docs', 'doc:good', 'record', 'messages', 'good', 'alpha attachment receipt')");
        try execSql(&db, "select zova_trgm_put('docs', 'doc:bad', 'record', 'messages', 'bad', 'zzzzzyyyyyxxxxx')");
    }
    {
        var raw = try sqlite.Database.open(source_path);
        defer raw.deinit();
        try raw.exec(
            \\update _zova_ext_trgm_documents
            \\set target_type = 'vector',
            \\    target_namespace = 'missing',
            \\    target_ref = 'missing'
            \\where document_id = 'doc:bad'
        );
    }

    try copyTrgmSalvage(source_path, destination_path, 1, 0);

    var destination = try zova.Database.open(destination_path);
    defer destination.deinit();
    try destination.checkExtension("trgm");
    try std.testing.expectEqual(@as(i64, 1), try countSqlRows(&destination.sqlite_db, "select count(*) from _zova_ext_trgm_documents"));
    try expectSearchIds(&destination, "docs", "alpha attachment", 1, 0.0, &.{"doc:good"});
    try expectSearchIds(&destination, "docs", "zzzzzyyyyyxxxxx", 1, 0.80, &.{});
}

test "trgm salvage skips unrecoverable private storage without leaving tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "trgm-salvage-unrecoverable-source.zova");
    var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination_path = try testingDbPath(&destination_buffer, tmp.sub_path[0..], "trgm-salvage-unrecoverable-destination.zova");

    {
        var db = try zova.Database.create(source_path);
        defer db.deinit();
        try db.installExtension("trgm");
        try execSql(&db, "select zova_trgm_create_index('docs')");
        try execSql(&db, "select zova_trgm_put('docs', 'doc:1', 'record', 'messages', '1', 'attachment upload failed')");
    }
    {
        var raw = try sqlite.Database.open(source_path);
        defer raw.deinit();
        try raw.exec("drop table _zova_ext_trgm_postings");
    }

    try copyTrgmSalvage(source_path, destination_path, 0, 1);

    var raw_destination = try sqlite.Database.open(destination_path);
    defer raw_destination.deinit();
    try std.testing.expectEqual(@as(i64, 0), try countSqlRows(&raw_destination, "select count(*) from _zova_extensions where name = 'trgm'"));
    try std.testing.expectEqual(@as(i64, 0), try countSqlRows(&raw_destination, "select count(*) from sqlite_master where name like '_zova_ext_trgm_%'"));
}

fn execSql(db: *zova.Database, sql: [:0]const u8) !void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(0));
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

fn expectAttachedStoreCount(db: *zova.Database, expected: i64) !void {
    try std.testing.expectEqual(expected, try countSqlRows(
        &db.sqlite_db,
        "select count(*) from pragma_database_list where name in ('object_store', 'vector_store', 'graph_store')",
    ));
}

fn expectStoreEpochs(db: *zova.Database, object: i64, vector: i64, graph: i64) !void {
    var stmt = try db.prepare(
        \\select
        \\  max(case when role = 'object_store' then object_epoch end),
        \\  max(case when role = 'vector_store' then vector_epoch end),
        \\  max(case when role = 'graph_store' then graph_epoch end)
        \\from _zova_bound_stores
    );
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqual(object, stmt.columnInt64(0));
    try std.testing.expectEqual(vector, stmt.columnInt64(1));
    try std.testing.expectEqual(graph, stmt.columnInt64(2));
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

fn expectThreeStoreGraphTargets(db: *zova.Database, object_id: zova.ObjectId) !void {
    var object_hex_buffer: [64]u8 = undefined;
    const object_hex = try hexObjectId(&object_hex_buffer, object_id);

    var object_node = try db.getGraphNode(std.testing.allocator, "links", "object");
    defer object_node.deinit(std.testing.allocator);
    try std.testing.expectEqual(zova.GraphTargetType.object, object_node.target_type);
    try std.testing.expectEqual(@as(?[]const u8, null), object_node.target_namespace);
    try std.testing.expectEqualStrings(object_hex, object_node.target_ref.?);

    var vector_node = try db.getGraphNode(std.testing.allocator, "links", "vector");
    defer vector_node.deinit(std.testing.allocator);
    try std.testing.expectEqual(zova.GraphTargetType.vector, vector_node.target_type);
    try std.testing.expectEqualStrings("chunks", vector_node.target_namespace.?);
    try std.testing.expectEqualStrings("vec:three", vector_node.target_ref.?);
}

fn expectTrgmCopy(path: [:0]const u8) !void {
    var db = try zova.Database.open(path);
    defer db.deinit();
    try db.checkExtension("trgm");
    try expectSearchIds(&db, "docs", "attachement failed", 1, 0.0, &.{"doc:1"});
}

fn copyTrgmSalvage(source_path: [:0]const u8, destination_path: [:0]const u8, expected_copied_extensions: u64, expected_skipped_extensions: u64) !void {
    const registry = zova.bundledExtensionRegistry();
    var source = try sqlite.Database.open(source_path);
    defer source.deinit();
    var destination = try zova.Database.createWithExtensions(destination_path, registry);
    defer destination.deinit();

    const result = try zova.salvageInstalledExtensions(
        std.testing.allocator,
        &source,
        &destination.sqlite_db,
        registry,
        .copy,
    );
    try std.testing.expectEqual(expected_copied_extensions, result.copied_extensions);
    try std.testing.expectEqual(expected_skipped_extensions, result.skipped_extensions);
    try std.testing.expectEqual(expected_copied_extensions != 0, result.installed_in_destination);
    if (expected_copied_extensions != 0) {
        try std.testing.expect(result.copied_private_objects > 0);
        try std.testing.expectEqual(@as(u64, 0), result.skipped_private_objects);
    } else {
        try std.testing.expectEqual(@as(u64, 0), result.copied_private_objects);
        try std.testing.expect(result.skipped_private_objects > 0);
    }
}

fn countSqlRows(db: *sqlite.Database, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    const count = stmt.columnInt64(0);
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    return count;
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
