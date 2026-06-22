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

test "sql vector scalar functions and virtual table rank metadata rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-sql.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec(
        \\create table chunks (
        \\  id text primary key,
        \\  document_id text not null,
        \\  body text not null,
        \\  vector_id text not null
        \\);
    );
    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("chunks", "chunk-a", &.{ 1.0, 0.0 });
    try db.putVector("chunks", "chunk-b", &.{ 3.0, 0.0 });
    try db.putVector("chunks", "chunk-c", &.{ 10.0, 0.0 });
    try db.exec(
        \\insert into chunks (id, document_id, body, vector_id) values
        \\  ('a', 'doc-1', 'alpha', 'chunk-a'),
        \\  ('b', 'doc-1', 'bravo', 'chunk-b'),
        \\  ('c', 'doc-2', 'charlie', 'chunk-c');
    );

    const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 0.0, 0.0 });
    defer std.testing.allocator.free(query_blob);

    {
        var stmt = try db.prepare(
            \\select c.id, zova_vector_distance('chunks', c.vector_id, ?) as distance
            \\from chunks c
            \\where c.document_id = 'doc-1'
            \\order by distance
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, query_blob);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("a", stmt.columnText(0));
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), stmt.columnDouble(1), 0.000001);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("b", stmt.columnText(0));
        try std.testing.expectApproxEqAbs(@as(f64, 3.0), stmt.columnDouble(1), 0.000001);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    {
        var stmt = try db.prepare(
            \\select c.id, zova_vector_distance_by_id('chunks', c.vector_id, 'chunk-a') as distance
            \\from chunks c
            \\where c.vector_id != 'chunk-a'
            \\order by distance
        );
        defer stmt.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("b", stmt.columnText(0));
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), stmt.columnDouble(1), 0.000001);
    }

    {
        var stmt = try db.prepare(
            \\select c.id, s.rank, s.distance
            \\from zova_vector_search as s
            \\join chunks c on c.vector_id = s.vector_id
            \\where s.collection = 'chunks'
            \\  and s.query_vector = ?
            \\  and s.top_k = 2
            \\order by s.rank
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, query_blob);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("a", stmt.columnText(0));
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(1));
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), stmt.columnDouble(2), 0.000001);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("b", stmt.columnText(0));
        try std.testing.expectEqual(@as(i64, 2), stmt.columnInt64(1));
        try std.testing.expectApproxEqAbs(@as(f64, 3.0), stmt.columnDouble(2), 0.000001);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    {
        var stmt = try db.prepare(
            \\select vector_id, distance
            \\from zova_vector_search
            \\where collection = 'chunks'
            \\  and source_vector_id = 'chunk-a'
            \\  and max_distance = 2.0
            \\order by rank
        );
        defer stmt.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("chunk-b", stmt.columnText(0));
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), stmt.columnDouble(1), 0.000001);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }
}

test "sql vector integration validates errors and registers only on zova connections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-sql-validation.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();

        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVector("docs", "source", &.{ 0.0, 0.0 });
        try db.putVector("docs", "near", &.{ 1.0, 0.0 });
        try db.putVector("docs", "far", &.{ 5.0, 0.0 });

        const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 0.0, 0.0 });
        defer std.testing.allocator.free(query_blob);

        {
            var stmt = try db.prepare(
                \\select vector_id
                \\from zova_vector_search
                \\where collection = 'docs'
                \\  and query_vector = ?
                \\  and top_k = 0
            );
            defer stmt.deinit();

            try stmt.bindBlob(1, query_blob);
            try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
        }

        try expectSqlPrepareOrStepError(&db, "select * from zova_vector_search");
        try expectSqlPrepareOrStepError(&db,
            \\select *
            \\from zova_vector_search
            \\where collection = 'docs'
            \\  and query_vector = x'0000000000000000'
            \\  and source_vector_id = 'source'
            \\  and top_k = 1
        );
        try expectSqlPrepareOrStepError(&db,
            \\select zova_vector_distance('docs', 'source', x'00')
        );
        try expectSqlPrepareOrStepError(&db,
            \\insert into zova_vector_search (rank, vector_id, distance)
            \\values (1, 'x', 0.0)
        );

        try db.exec("pragma ignore_check_constraints = on");
        try db.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'far'");
        try db.exec("pragma ignore_check_constraints = off");
        try expectSqlPrepareOrStepError(&db,
            \\select zova_vector_distance('docs', 'far', x'0000000000000000')
        );
        try expectSqlPrepareOrStepError(&db,
            \\select vector_id
            \\from zova_vector_search
            \\where collection = 'docs'
            \\  and source_vector_id = 'source'
            \\  and top_k = 10
        );
    }

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try std.testing.expectError(error.SqliteError, raw.prepare(
            \\select zova_vector_distance('docs', 'source', x'0000000000000000')
        ));
    }

    {
        var reopened = try Database.open(db_path);
        defer reopened.deinit();

        var stmt = try reopened.prepare(
            \\select zova_vector_distance_by_id('docs', 'near', 'source')
        );
        defer stmt.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), stmt.columnDouble(0), 0.000001);
    }
}

test "sql vector integration works after sqlite conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "vector-sql-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "vector-sql-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();

        try source.exec(
            \\create table chunks (
            \\  id text primary key,
            \\  document_id text not null,
            \\  vector_id text
            \\);
        );
        try source.exec(
            \\insert into chunks (id, document_id, vector_id) values
            \\  ('one', 'doc', null),
            \\  ('two', 'doc', null);
        );
    }

    try convertSqliteToZova(source_path, dest_path);

    var db = try Database.open(dest_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .dot });
    try db.putVector("chunks", "one-vector", &.{ 2.0, 0.0 });
    try db.putVector("chunks", "two-vector", &.{ 1.0, 0.0 });
    try db.exec("update chunks set vector_id = id || '-vector'");

    const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 1.0, 0.0 });
    defer std.testing.allocator.free(query_blob);

    var stmt = try db.prepare(
        \\select c.id, s.distance
        \\from zova_vector_search as s
        \\join chunks as c on c.vector_id = s.vector_id
        \\where s.collection = 'chunks'
        \\  and s.query_vector = ?
        \\  and s.top_k = 2
        \\order by s.rank
    );
    defer stmt.deinit();

    try stmt.bindBlob(1, query_blob);
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("one", stmt.columnText(0));
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), stmt.columnDouble(1), 0.000001);
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("two", stmt.columnText(0));
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), stmt.columnDouble(1), 0.000001);
}

test "sql vector integration supports all metrics and threshold-only searches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-sql-metrics.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });
    try db.putVector("cosine", "east", &.{ 1.0, 0.0 });
    try db.putVector("cosine", "northeast", &.{ 1.0, 1.0 });
    try db.putVector("cosine", "north", &.{ 0.0, 1.0 });

    try db.createVectorCollection("dot", .{ .dimensions = 2, .metric = .dot });
    try db.putVector("dot", "strong", &.{ 3.0, 0.0 });
    try db.putVector("dot", "weak", &.{ 1.0, 0.0 });
    try db.putVector("dot", "negative", &.{ -1.0, 0.0 });

    try db.createVectorCollection("empty", .{ .dimensions = 2, .metric = .l2 });

    const east_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 1.0, 0.0 });
    defer std.testing.allocator.free(east_blob);

    {
        var stmt = try db.prepare(
            \\select
            \\  zova_vector_distance('cosine', 'east', ?),
            \\  zova_vector_distance_by_id('cosine', 'northeast', 'east'),
            \\  zova_vector_distance('dot', 'strong', ?),
            \\  zova_vector_distance_by_id('dot', 'weak', 'strong')
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, east_blob);
        try stmt.bindBlob(2, east_blob);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), stmt.columnDouble(0), 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 0.292893), stmt.columnDouble(1), 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, -3.0), stmt.columnDouble(2), 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, -3.0), stmt.columnDouble(3), 0.000001);
    }

    {
        var stmt = try db.prepare(
            \\select vector_id
            \\from zova_vector_search
            \\where collection = 'dot'
            \\  and query_vector = ?
            \\  and max_distance = -1.0
            \\order by rank
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, east_blob);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("strong", stmt.columnText(0));
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("weak", stmt.columnText(0));
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    {
        var stmt = try db.prepare(
            \\select vector_id
            \\from zova_vector_search
            \\where collection = 'dot'
            \\  and query_vector = ?
            \\  and top_k = 1
            \\  and max_distance = -1.0
            \\order by rank
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, east_blob);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("strong", stmt.columnText(0));
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    {
        var stmt = try db.prepare(
            \\select vector_id
            \\from zova_vector_search
            \\where collection = 'empty'
            \\  and query_vector = ?
            \\  and top_k = 10
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, east_blob);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    try expectSqlPrepareOrStepError(&db, "select zova_vector_distance('missing', 'id', x'0000803f00000000')");
    try expectSqlPrepareOrStepError(&db, "select zova_vector_distance('dot', 'missing', x'0000803f00000000')");
    try expectSqlPrepareOrStepError(&db, "select zova_vector_distance_by_id('dot', 'weak', 'missing')");
}
