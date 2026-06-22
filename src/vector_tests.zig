const std = @import("std");
const fastcdc = @import("object_fastcdc.zig");
const object_impl = @import("object.zig");
const sqlite = @import("sqlite.zig");
const test_support = @import("zova_test_support.zig");
const vector_impl = @import("vector.zig");
const zova = @import("zova.zig");

const Database = zova.Database;
const Object = zova.Object;
const ObjectChunk = zova.ObjectChunk;
const ObjectChunkData = zova.ObjectChunkData;
const ObjectChunkId = zova.ObjectChunkId;
const ObjectId = zova.ObjectId;
const ObjectManifest = zova.ObjectManifest;
const ObjectWriter = zova.ObjectWriter;
const Vector = zova.Vector;
const VectorCollectionInfo = zova.VectorCollectionInfo;
const VectorCollectionList = zova.VectorCollectionList;
const VectorCollectionOptions = zova.VectorCollectionOptions;
const VectorInput = zova.VectorInput;
const VectorMetric = zova.VectorMetric;
const VectorSearchResult = zova.VectorSearchResult;
const VectorSearchResults = zova.VectorSearchResults;
const max_vector_dimensions = zova.max_vector_dimensions;
const convertSqliteToZova = zova.convertSqliteToZova;
const objectChunkId = zova.objectChunkId;
const objectId = zova.objectId;

const objects_schema_sql = object_impl.objects_schema_sql;
const chunks_schema_sql = object_impl.chunks_schema_sql;
const object_chunks_schema_sql = object_impl.object_chunks_schema_sql;

const TestingTrackingAllocator = test_support.TestingTrackingAllocator;
const expectSearchIds = test_support.expectSearchIds;
const expectSqlPrepareOrStepError = test_support.expectSqlPrepareOrStepError;
const testingCount = test_support.testingCount;
const testingDbPath = test_support.testingDbPath;
const testingExpectManifestsEqual = test_support.testingExpectManifestsEqual;
const testingExpectObjectBytes = test_support.testingExpectObjectBytes;
const testingExpectObjectMissing = test_support.testingExpectObjectMissing;
const testingExpectTableCount = test_support.testingExpectTableCount;
const testingIntegrityCheckOk = test_support.testingIntegrityCheckOk;
const testingObjectManifestCount = test_support.testingObjectManifestCount;
const testingPutLooseManifest = test_support.testingPutLooseManifest;
const testingQuickCheckOk = test_support.testingQuickCheckOk;
const testingSharedChunkCount = test_support.testingSharedChunkCount;
const testingStreamObject = test_support.testingStreamObject;
const testingWriteMetadata = test_support.testingWriteMetadata;

test "created zova database contains required vector tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-tables.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_vector_collections", 1);
    try testingExpectTableCount(&raw, "_zova_vectors", 1);
}

test "sqlite wrapper can inspect zova vector tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "sqlite-inspect-vectors.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    var tables = try raw.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table'
        \\  and name in ('_zova_vector_collections', '_zova_vectors')
    );
    defer tables.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try tables.step());
    try std.testing.expectEqual(@as(i64, 2), tables.columnInt64(0));
}

test "create and lookup vector collections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-collections.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expect(!try db.hasVectorCollection("chunks"));
    try db.createVectorCollection("chunks", .{ .dimensions = 3, .metric = .cosine });
    try std.testing.expect(try db.hasVectorCollection("chunks"));

    var row = try db.prepare(
        \\select dimensions, metric, element_type
        \\from _zova_vector_collections
        \\where name = 'chunks'
    );
    defer row.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try row.step());
    try std.testing.expectEqual(@as(i64, 3), row.columnInt64(0));
    try std.testing.expectEqualStrings("cosine", row.columnText(1));
    try std.testing.expectEqualStrings("f32", row.columnText(2));
    try std.testing.expectEqual(sqlite.Step.done, try row.step());
}

test "vector collection duplicate and validation behavior" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = max_vector_dimensions, .metric = .l2 });
    try std.testing.expectError(error.VectorCollectionExists, db.createVectorCollection("chunks", .{ .dimensions = max_vector_dimensions, .metric = .dot }));

    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection("", .{ .dimensions = 3, .metric = .cosine }));
    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection("_zova_vectors", .{ .dimensions = 3, .metric = .cosine }));
    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection("bad\xff", .{ .dimensions = 3, .metric = .cosine }));
    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection("zero", .{ .dimensions = 0, .metric = .cosine }));
    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection("too-many", .{ .dimensions = max_vector_dimensions + 1, .metric = .cosine }));

    var long_name: [256]u8 = undefined;
    @memset(&long_name, 'a');
    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection(&long_name, .{ .dimensions = 3, .metric = .cosine }));
    try std.testing.expectError(error.VectorInvalid, db.hasVectorCollection(""));
}

test "vector collection info and listing return owned sorted metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-collection-info.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    {
        var empty = try db.listVectorCollections(std.testing.allocator);
        defer empty.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    }

    try db.createVectorCollection("beta", .{ .dimensions = 2, .metric = .dot });
    try db.createVectorCollection("alpha", .{ .dimensions = 3, .metric = .cosine });
    try db.putVector("alpha", "a-1", &.{ 1.0, 0.0, 0.0 });
    try db.putVector("alpha", "a-2", &.{ 0.0, 1.0, 0.0 });
    try db.putVector("beta", "b-1", &.{ 2.0, 3.0 });

    {
        var info = try db.vectorCollectionInfo(std.testing.allocator, "alpha");
        defer info.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("alpha", info.name);
        try std.testing.expectEqual(@as(u32, 3), info.dimensions);
        try std.testing.expectEqual(VectorMetric.cosine, info.metric);
        try std.testing.expectEqual(@as(u64, 2), info.vector_count);
    }

    {
        var list = try db.listVectorCollections(std.testing.allocator);
        defer list.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), list.items.len);
        try std.testing.expectEqualStrings("alpha", list.items[0].name);
        try std.testing.expectEqual(@as(u32, 3), list.items[0].dimensions);
        try std.testing.expectEqual(VectorMetric.cosine, list.items[0].metric);
        try std.testing.expectEqual(@as(u64, 2), list.items[0].vector_count);
        try std.testing.expectEqualStrings("beta", list.items[1].name);
        try std.testing.expectEqual(@as(u32, 2), list.items[1].dimensions);
        try std.testing.expectEqual(VectorMetric.dot, list.items[1].metric);
        try std.testing.expectEqual(@as(u64, 1), list.items[1].vector_count);
    }

    try std.testing.expectError(error.VectorCollectionNotFound, db.vectorCollectionInfo(std.testing.allocator, "missing"));
    try std.testing.expectError(error.VectorInvalid, db.vectorCollectionInfo(std.testing.allocator, ""));
}

test "batch vector upsert validates before writing and last duplicate wins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-batch.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });

    const invalid_batch = [_]VectorInput{
        .{ .id = "good", .values = &.{ 1.0, 1.0 } },
        .{ .id = "bad", .values = &.{1.0} },
    };
    try std.testing.expectError(error.VectorDimensionMismatch, db.putVectors("chunks", &invalid_batch));
    try std.testing.expect(!try db.hasVector("chunks", "good"));

    const batch = [_]VectorInput{
        .{ .id = "a", .values = &.{ 1.0, 2.0 } },
        .{ .id = "b", .values = &.{ 3.0, 4.0 } },
        .{ .id = "a", .values = &.{ 5.0, 6.0 } },
    };
    try db.putVectors("chunks", &batch);

    {
        var vector = try db.getVector(std.testing.allocator, "chunks", "a");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 5.0, 6.0 }, vector.values);
    }
    {
        var vector = try db.getVector(std.testing.allocator, "chunks", "b");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 3.0, 4.0 }, vector.values);
    }

    try db.putVectors("chunks", &.{});
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from _zova_vectors where collection_name = 'chunks'"));

    try std.testing.expectError(error.VectorCollectionNotFound, db.putVectors("missing", &batch));
    const invalid_id = [_]VectorInput{.{ .id = "_zova_bad", .values = &.{ 1.0, 2.0 } }};
    try std.testing.expectError(error.VectorInvalid, db.putVectors("chunks", &invalid_id));

    try db.exec("begin");
    try db.putVectors("chunks", &[_]VectorInput{.{ .id = "tx", .values = &.{ 7.0, 8.0 } }});
    try db.exec("commit");
    try std.testing.expect(try db.hasVector("chunks", "tx"));
}

test "vector upsert delete and sql references remain application owned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-upsert-delete.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec(
        \\create table chunks (
        \\  id integer primary key,
        \\  vector_id text not null,
        \\  body text not null
        \\)
    );
    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.createVectorCollection("images", .{ .dimensions = 2, .metric = .dot });

    try db.putVector("chunks", "same-id", &.{ 1.0, 2.0 });
    try db.putVector("images", "same-id", &.{ 9.0, 8.0 });
    try db.putVector("chunks", "same-id", &.{ 3.0, 4.0 });
    try db.putVector("chunks", "delete-me", &.{ 5.0, 6.0 });

    var insert = try db.prepare("insert into chunks (vector_id, body) values (?, ?)");
    defer insert.deinit();
    try insert.bindText(1, "delete-me");
    try insert.bindText(2, "application row");
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());

    {
        var chunks_vector = try db.getVector(std.testing.allocator, "chunks", "same-id");
        defer chunks_vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 3.0, 4.0 }, chunks_vector.values);
    }
    {
        var images_vector = try db.getVector(std.testing.allocator, "images", "same-id");
        defer images_vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 9.0, 8.0 }, images_vector.values);
    }

    try db.deleteVector("chunks", "delete-me");
    try std.testing.expect(!try db.hasVector("chunks", "delete-me"));
    try std.testing.expectError(error.VectorNotFound, db.getVector(std.testing.allocator, "chunks", "delete-me"));
    try std.testing.expectError(error.VectorNotFound, db.deleteVector("chunks", "delete-me"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from chunks where vector_id = 'delete-me'"));
}

test "delete vector collection removes private vectors and leaves sql references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-delete-collection.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec(
        \\create table chunks (
        \\  id integer primary key,
        \\  vector_id text not null,
        \\  body text not null
        \\)
    );
    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.putVectors("chunks", &[_]VectorInput{
        .{ .id = "keep-ref-1", .values = &.{ 1.0, 1.0 } },
        .{ .id = "keep-ref-2", .values = &.{ 2.0, 2.0 } },
    });

    var insert = try db.prepare("insert into chunks (vector_id, body) values (?, ?)");
    defer insert.deinit();
    try insert.bindText(1, "keep-ref-1");
    try insert.bindText(2, "application row 1");
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    try insert.reset();
    try insert.clearBindings();
    try insert.bindText(1, "keep-ref-2");
    try insert.bindText(2, "application row 2");
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());

    try db.exec("begin");
    try db.deleteVectorCollection("chunks");
    try db.exec("commit");

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors where collection_name = 'chunks'"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vector_collections where name = 'chunks'"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from chunks"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.hasVector("chunks", "keep-ref-1"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.getVector(std.testing.allocator, "chunks", "keep-ref-1"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.searchVectors(std.testing.allocator, "chunks", &.{ 1.0, 1.0 }, 10));
    try std.testing.expectError(error.VectorCollectionNotFound, db.deleteVectorCollection("chunks"));
    try std.testing.expectError(error.VectorInvalid, db.deleteVectorCollection(""));
}

test "vector CRUD validates collections ids dimensions and finite values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-validation-crud.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 3, .metric = .cosine });

    try std.testing.expectError(error.VectorCollectionNotFound, db.putVector("missing", "id", &.{ 1.0, 2.0, 3.0 }));
    try std.testing.expectError(error.VectorCollectionNotFound, db.getVector(std.testing.allocator, "missing", "id"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.hasVector("missing", "id"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.deleteVector("missing", "id"));

    try std.testing.expectError(error.VectorInvalid, db.putVector("_zova_bad", "id", &.{ 1.0, 2.0, 3.0 }));
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", "", &.{ 1.0, 2.0, 3.0 }));
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", "_zova_id", &.{ 1.0, 2.0, 3.0 }));
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", "bad\xff", &.{ 1.0, 2.0, 3.0 }));
    try std.testing.expectError(error.VectorDimensionMismatch, db.putVector("chunks", "short", &.{ 1.0, 2.0 }));
    try std.testing.expectError(error.VectorDimensionMismatch, db.putVector("chunks", "empty", &.{}));
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", "nan", &.{ 1.0, std.math.nan(f32), 3.0 }));
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", "inf", &.{ 1.0, std.math.inf(f32), 3.0 }));

    var long_id: [256]u8 = undefined;
    @memset(&long_id, 'a');
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", &long_id, &.{ 1.0, 2.0, 3.0 }));
}

test "vector collection management persists and works after conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "collection-management-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "collection-management-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table docs (id integer primary key, body text not null); insert into docs (body) values ('alpha'), ('beta')");
    }

    try convertSqliteToZova(source_path, dest_path);

    {
        var db = try Database.open(dest_path);
        defer db.deinit();
        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .dot });
        try db.putVectors("docs", &[_]VectorInput{
            .{ .id = "doc-1", .values = &.{ 1.0, 0.0 } },
            .{ .id = "doc-2", .values = &.{ 0.0, 1.0 } },
        });
    }

    {
        var reopened = try Database.open(dest_path);
        defer reopened.deinit();

        var info = try reopened.vectorCollectionInfo(std.testing.allocator, "docs");
        defer info.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("docs", info.name);
        try std.testing.expectEqual(VectorMetric.dot, info.metric);
        try std.testing.expectEqual(@as(u64, 2), info.vector_count);

        try reopened.deleteVectorCollection("docs");
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&reopened, "select count(*) from docs"));
    }
}

test "get vector detects corrupt private rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-corrupt.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("chunks", "bad-len", &.{ 1.0, 2.0 });
    try db.putVector("chunks", "bad-dim", &.{ 3.0, 4.0 });
    try db.putVector("chunks", "bad-finite", &.{ 5.0, 6.0 });

    try db.exec("pragma ignore_check_constraints = on");
    try db.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'bad-len'");
    try db.exec("update _zova_vectors set dimensions = 3 where vector_id = 'bad-dim'");

    var inf_bytes = [_]u8{
        0x00, 0x00, 0x80, 0x3f,
        0x00, 0x00, 0x80, 0x7f,
    };
    var update = try db.prepare("update _zova_vectors set \"values\" = ? where vector_id = 'bad-finite'");
    defer update.deinit();
    try update.bindBlob(1, &inf_bytes);
    try std.testing.expectEqual(sqlite.Step.done, try update.step());
    try db.exec("pragma ignore_check_constraints = off");

    try std.testing.expectError(error.VectorCorrupt, db.getVector(std.testing.allocator, "chunks", "bad-len"));
    try std.testing.expectError(error.VectorCorrupt, db.getVector(std.testing.allocator, "chunks", "bad-dim"));
    try std.testing.expectError(error.VectorCorrupt, db.getVector(std.testing.allocator, "chunks", "bad-finite"));
}

test "vector CRUD persists works after conversion and participates in transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "vector-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "vector-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table docs (id integer primary key, body text not null); insert into docs (body) values ('hello')");
    }

    try convertSqliteToZova(source_path, dest_path);

    {
        var db = try Database.open(dest_path);
        defer db.deinit();

        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .cosine });
        try db.exec("begin");
        try db.putVector("docs", "doc-1", &.{ 0.5, 0.25 });
        try db.exec("commit");

        var vector = try db.getVector(std.testing.allocator, "docs", "doc-1");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.25 }, vector.values);
    }

    {
        var reopened = try Database.open(dest_path);
        defer reopened.deinit();

        try std.testing.expect(try reopened.hasVector("docs", "doc-1"));
        var vector = try reopened.getVector(std.testing.allocator, "docs", "doc-1");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("doc-1", vector.id);
        try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.25 }, vector.values);
    }
}

test "second connection vector write follows sqlite busy behavior" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-lock.zova");

    var first = try Database.create(db_path);
    defer first.deinit();
    try first.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .dot });

    var second = try Database.open(db_path);
    defer second.deinit();

    try first.exec("begin immediate");
    try first.putVector("chunks", "first", &.{ 1.0, 2.0 });
    try std.testing.expectError(error.Busy, second.putVector("chunks", "second", &.{ 3.0, 4.0 }));
    try std.testing.expectError(error.Busy, second.deleteVector("chunks", "first"));
    try first.exec("rollback");

    try second.putVector("chunks", "second", &.{ 3.0, 4.0 });
    try std.testing.expect(try second.hasVector("chunks", "second"));
}

test "search vectors validates inputs and handles empty limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });

    try std.testing.expectError(error.VectorCollectionNotFound, db.searchVectors(std.testing.allocator, "missing", &.{ 1.0, 2.0 }, 10));
    try std.testing.expectError(error.VectorDimensionMismatch, db.searchVectors(std.testing.allocator, "chunks", &.{1.0}, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectors(std.testing.allocator, "chunks", &.{ std.math.nan(f32), 1.0 }, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectors(std.testing.allocator, "chunks", &.{ std.math.inf(f32), 1.0 }, 10));
    try std.testing.expectError(error.VectorInvalid, db.putVector("cosine", "zero", &.{ 0.0, 0.0 }));
    try std.testing.expectError(error.VectorInvalid, db.searchVectors(std.testing.allocator, "cosine", &.{ 0.0, 0.0 }, 10));

    var empty_limit = try db.searchVectors(std.testing.allocator, "chunks", &.{ 1.0, 2.0 }, 0);
    defer empty_limit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_limit.items.len);

    var empty_collection = try db.searchVectors(std.testing.allocator, "chunks", &.{ 1.0, 2.0 }, 10);
    defer empty_collection.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_collection.items.len);
}

test "search vectors returns deterministic cosine l2 and dot results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-metrics.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });
    try db.createVectorCollection("l2", .{ .dimensions = 2, .metric = .l2 });
    try db.createVectorCollection("dot", .{ .dimensions = 2, .metric = .dot });

    try db.putVector("cosine", "east", &.{ 1.0, 0.0 });
    try db.putVector("cosine", "north", &.{ 0.0, 1.0 });
    try db.putVector("cosine", "northeast", &.{ 1.0, 1.0 });

    try db.putVector("l2", "near", &.{ 1.0, 1.0 });
    try db.putVector("l2", "far", &.{ 4.0, 5.0 });
    try db.putVector("l2", "tie-a", &.{ 1.0, 3.0 });
    try db.putVector("l2", "tie-b", &.{ 3.0, 1.0 });
    try db.putVector("l2", "other", &.{ 0.0, 0.0 });

    try db.putVector("dot", "large", &.{ 3.0, 0.0 });
    try db.putVector("dot", "small", &.{ 1.0, 0.0 });
    try db.putVector("dot", "negative", &.{ -1.0, 0.0 });

    {
        var results = try db.searchVectors(std.testing.allocator, "cosine", &.{ 1.0, 0.0 }, 3);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "east", "northeast", "north" });
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0 - 0.7071067811865475), results.items[1].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), results.items[2].distance, 0.000001);
    }

    {
        var results = try db.searchVectors(std.testing.allocator, "l2", &.{ 2.0, 2.0 }, 3);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "near", "tie-a", "tie-b" });
        try std.testing.expectApproxEqAbs(@as(f64, @sqrt(2.0)), results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, @sqrt(2.0)), results.items[1].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, @sqrt(2.0)), results.items[2].distance, 0.000001);
    }

    {
        var results = try db.searchVectors(std.testing.allocator, "dot", &.{ 1.0, 0.0 }, 5);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "large", "small", "negative" });
        try std.testing.expectApproxEqAbs(@as(f64, -3.0), results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, -1.0), results.items[1].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), results.items[2].distance, 0.000001);
    }
}

test "search vectors reflects updates deletes reopen and conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "search-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "search-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table docs (id integer primary key, body text not null); insert into docs (body) values ('a'), ('b')");
    }

    try convertSqliteToZova(source_path, dest_path);

    {
        var db = try Database.open(dest_path);
        defer db.deinit();
        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVector("docs", "a", &.{ 10.0, 10.0 });
        try db.putVector("docs", "b", &.{ 2.0, 2.0 });
        try db.putVector("docs", "a", &.{ 1.0, 1.0 });
        try db.deleteVector("docs", "b");

        var results = try db.searchVectors(std.testing.allocator, "docs", &.{ 0.0, 0.0 }, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"a"});
    }

    {
        var reopened = try Database.open(dest_path);
        defer reopened.deinit();
        var results = try reopened.searchVectors(std.testing.allocator, "docs", &.{ 0.0, 0.0 }, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"a"});
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&reopened, "select count(*) from docs"));
    }
}

test "search vectors reports corrupt private vector rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-corrupt.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("chunks", "bad", &.{ 1.0, 2.0 });
    try db.exec("pragma ignore_check_constraints = on");
    try db.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'bad'");
    try db.exec("pragma ignore_check_constraints = off");
    try std.testing.expectError(error.VectorCorrupt, db.searchVectors(std.testing.allocator, "chunks", &.{ 1.0, 2.0 }, 10));
}

test "candidate-filtered vector search ranks only supplied ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-candidates.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("docs", "global-nearest", &.{ 0.0, 0.0 });
    try db.putVector("docs", "near", &.{ 1.0, 0.0 });
    try db.putVector("docs", "tie-b", &.{ 0.0, 2.0 });
    try db.putVector("docs", "tie-a", &.{ 2.0, 0.0 });
    try db.putVector("docs", "far", &.{ 10.0, 0.0 });

    const candidates = [_][]const u8{ "far", "missing", "tie-b", "near", "tie-a", "near" };
    var results = try db.searchVectorsIn(std.testing.allocator, "docs", &.{ 0.0, 0.0 }, &candidates, 3);
    defer results.deinit(std.testing.allocator);

    try expectSearchIds(&results, &.{ "near", "tie-a", "tie-b" });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), results.items[0].distance, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), results.items[1].distance, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), results.items[2].distance, 0.000001);
}

test "candidate-filtered vector search validates inputs and handles empty limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-candidate-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });
    try db.putVector("docs", "valid", &.{ 1.0, 2.0 });

    const valid_candidates = [_][]const u8{"valid"};
    const invalid_candidates = [_][]const u8{ "_zova_bad", "valid" };

    try std.testing.expectError(error.VectorCollectionNotFound, db.searchVectorsIn(std.testing.allocator, "missing", &.{ 1.0, 2.0 }, &valid_candidates, 10));
    try std.testing.expectError(error.VectorDimensionMismatch, db.searchVectorsIn(std.testing.allocator, "docs", &.{1.0}, &valid_candidates, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsIn(std.testing.allocator, "docs", &.{ std.math.nan(f32), 1.0 }, &valid_candidates, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsIn(std.testing.allocator, "docs", &.{ std.math.inf(f32), 1.0 }, &valid_candidates, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsIn(std.testing.allocator, "cosine", &.{ 0.0, 0.0 }, &valid_candidates, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsIn(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &invalid_candidates, 0));

    var empty_limit = try db.searchVectorsIn(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &valid_candidates, 0);
    defer empty_limit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_limit.items.len);

    var empty_candidates = try db.searchVectorsIn(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &.{}, 10);
    defer empty_candidates.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_candidates.items.len);
}

test "candidate-filtered vector search supports cosine dot reopen and conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "candidate-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "candidate-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table docs (id integer primary key, body text not null); insert into docs (body) values ('a'), ('b')");
    }

    try convertSqliteToZova(source_path, dest_path);

    {
        var db = try Database.open(dest_path);
        defer db.deinit();

        try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });
        try db.putVector("cosine", "east", &.{ 1.0, 0.0 });
        try db.putVector("cosine", "north", &.{ 0.0, 1.0 });
        try db.putVector("cosine", "northeast", &.{ 1.0, 1.0 });

        try db.createVectorCollection("dot", .{ .dimensions = 2, .metric = .dot });
        try db.putVector("dot", "large", &.{ 3.0, 0.0 });
        try db.putVector("dot", "small", &.{ 1.0, 0.0 });
        try db.putVector("dot", "negative", &.{ -1.0, 0.0 });
    }

    {
        var reopened = try Database.open(dest_path);
        defer reopened.deinit();

        const cosine_candidates = [_][]const u8{ "north", "northeast" };
        var cosine_results = try reopened.searchVectorsIn(std.testing.allocator, "cosine", &.{ 1.0, 0.0 }, &cosine_candidates, 10);
        defer cosine_results.deinit(std.testing.allocator);
        try expectSearchIds(&cosine_results, &.{ "northeast", "north" });
        try std.testing.expectApproxEqAbs(@as(f64, 1.0 - 0.7071067811865475), cosine_results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosine_results.items[1].distance, 0.000001);

        const dot_candidates = [_][]const u8{ "small", "negative" };
        var dot_results = try reopened.searchVectorsIn(std.testing.allocator, "dot", &.{ 1.0, 0.0 }, &dot_candidates, 10);
        defer dot_results.deinit(std.testing.allocator);
        try expectSearchIds(&dot_results, &.{ "small", "negative" });
        try std.testing.expectApproxEqAbs(@as(f64, -1.0), dot_results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), dot_results.items[1].distance, 0.000001);
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&reopened, "select count(*) from docs"));
    }
}

test "candidate-filtered vector search reports only selected corrupt private vector rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-candidate-corrupt.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("docs", "good", &.{ 1.0, 2.0 });
    try db.putVector("docs", "bad", &.{ 3.0, 4.0 });
    try db.exec("pragma ignore_check_constraints = on");
    try db.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'bad'");
    try db.exec("pragma ignore_check_constraints = off");

    const good_only = [_][]const u8{"good"};
    var results = try db.searchVectorsIn(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &good_only, 10);
    defer results.deinit(std.testing.allocator);
    try expectSearchIds(&results, &.{"good"});

    const selected_bad = [_][]const u8{"bad"};
    try std.testing.expectError(error.VectorCorrupt, db.searchVectorsIn(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &selected_bad, 10));
}

test "search vectors by id excludes source and supports candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-by-id.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("docs", "source", &.{ 0.0, 0.0 });
    try db.putVector("docs", "near", &.{ 1.0, 0.0 });
    try db.putVector("docs", "tie-b", &.{ 0.0, 2.0 });
    try db.putVector("docs", "tie-a", &.{ 2.0, 0.0 });
    try db.putVector("docs", "global-far", &.{ 10.0, 0.0 });

    {
        var results = try db.searchVectorsById(std.testing.allocator, "docs", "source", 3);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "near", "tie-a", "tie-b" });
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), results.items[1].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), results.items[2].distance, 0.000001);
    }

    {
        const candidates = [_][]const u8{ "source", "global-far", "missing", "near", "near" };
        var results = try db.searchVectorsByIdIn(std.testing.allocator, "docs", "source", &candidates, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "near", "global-far" });
    }
}

test "vector search thresholds filter inclusively across search modes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-thresholds.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("l2", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("l2", "source", &.{ 0.0, 0.0 });
    try db.putVector("l2", "one", &.{ 1.0, 0.0 });
    try db.putVector("l2", "two", &.{ 2.0, 0.0 });
    try db.putVector("l2", "three", &.{ 3.0, 0.0 });

    {
        var results = try db.searchVectorsWithin(std.testing.allocator, "l2", &.{ 0.0, 0.0 }, 2.0, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "source", "one", "two" });
    }

    {
        const candidates = [_][]const u8{ "one", "two", "three" };
        var results = try db.searchVectorsInWithin(std.testing.allocator, "l2", &.{ 0.0, 0.0 }, &candidates, 1.0, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"one"});
    }

    {
        var results = try db.searchVectorsByIdWithin(std.testing.allocator, "l2", "source", 2.0, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "one", "two" });
    }

    {
        const candidates = [_][]const u8{ "source", "one", "two", "three" };
        var results = try db.searchVectorsByIdInWithin(std.testing.allocator, "l2", "source", &candidates, 1.0, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"one"});
    }

    try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });
    try db.putVector("cosine", "east", &.{ 1.0, 0.0 });
    try db.putVector("cosine", "northeast", &.{ 1.0, 1.0 });
    try db.putVector("cosine", "north", &.{ 0.0, 1.0 });
    {
        var results = try db.searchVectorsWithin(std.testing.allocator, "cosine", &.{ 1.0, 0.0 }, 0.3, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "east", "northeast" });
    }

    try db.createVectorCollection("dot", .{ .dimensions = 2, .metric = .dot });
    try db.putVector("dot", "strong", &.{ 3.0, 0.0 });
    try db.putVector("dot", "weak", &.{ 1.0, 0.0 });
    try db.putVector("dot", "negative", &.{ -1.0, 0.0 });
    {
        var results = try db.searchVectorsWithin(std.testing.allocator, "dot", &.{ 1.0, 0.0 }, -1.0, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "strong", "weak" });
    }

    {
        var results = try db.searchVectorsWithin(std.testing.allocator, "l2", &.{ 0.0, 0.0 }, 0.5, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"source"});
    }
}

test "search vectors by id and thresholds validate inputs and corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-by-id-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("docs", "source", &.{ 1.0, 2.0 });
    try db.putVector("docs", "good", &.{ 2.0, 3.0 });
    try db.putVector("docs", "bad", &.{ 3.0, 4.0 });

    const valid_candidates = [_][]const u8{"good"};
    const invalid_candidates = [_][]const u8{"_zova_bad"};

    try std.testing.expectError(error.VectorCollectionNotFound, db.searchVectorsById(std.testing.allocator, "missing", "source", 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsById(std.testing.allocator, "docs", "_zova_bad", 10));
    try std.testing.expectError(error.VectorNotFound, db.searchVectorsById(std.testing.allocator, "docs", "missing", 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsInWithin(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &invalid_candidates, 1.0, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsWithin(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, std.math.nan(f64), 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsWithin(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, std.math.inf(f64), 10));

    var empty_limit = try db.searchVectorsByIdInWithin(std.testing.allocator, "docs", "source", &valid_candidates, 1.0, 0);
    defer empty_limit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_limit.items.len);

    try db.exec("pragma ignore_check_constraints = on");
    try db.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'bad'");
    try db.exec("pragma ignore_check_constraints = off");

    try std.testing.expectError(error.VectorCorrupt, db.searchVectorsById(std.testing.allocator, "docs", "bad", 10));

    {
        var results = try db.searchVectorsByIdIn(std.testing.allocator, "docs", "source", &valid_candidates, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"good"});
    }

    const selected_bad = [_][]const u8{"bad"};
    try std.testing.expectError(error.VectorCorrupt, db.searchVectorsByIdIn(std.testing.allocator, "docs", "source", &selected_bad, 10));
}
