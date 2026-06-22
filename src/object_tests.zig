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

test "object ids are sha256 of full object bytes" {
    const empty_expected = ObjectId{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    const hello_expected = ObjectId{
        0x2c, 0xf2, 0x4d, 0xba, 0x5f, 0xb0, 0xa3, 0x0e,
        0x26, 0xe8, 0x3b, 0x2a, 0xc5, 0xb9, 0xe2, 0x9e,
        0x1b, 0x16, 0x1e, 0x5c, 0x1f, 0xa7, 0x42, 0x5e,
        0x73, 0x04, 0x33, 0x62, 0x93, 0x8b, 0x98, 0x24,
    };

    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ObjectId));
    try std.testing.expectEqualSlices(u8, &empty_expected, &objectId(""));
    try std.testing.expectEqualSlices(u8, &hello_expected, &objectId("hello"));
    try std.testing.expectEqualSlices(u8, &objectId("same bytes"), &objectId("same bytes"));
    try std.testing.expect(!std.mem.eql(u8, &objectId("first"), &objectId("second")));
    try std.testing.expectEqualStrings("fastcdc-v1", fastcdc.version);
}

test "object chunk ids are sha256 of chunk bytes" {
    const abc_expected = ObjectChunkId{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };

    try std.testing.expectEqualSlices(u8, &abc_expected, &objectChunkId("abc"));
    try std.testing.expectEqualSlices(u8, &objectChunkId("same chunk"), &objectChunkId("same chunk"));
    try std.testing.expect(!std.mem.eql(u8, &objectChunkId("left"), &objectChunkId("right")));
}

test "object writer streams empty small binary and large objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-basic.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const empty_id = try testingStreamObject(&db, "", &.{1});
    try std.testing.expectEqualSlices(u8, &objectId(""), &empty_id);
    try testingExpectObjectBytes(&db, empty_id, "");
    try std.testing.expectEqual(@as(u64, 0), try db.objectChunkCount(empty_id));

    const small = "streamed hello object";
    const small_id = try testingStreamObject(&db, small, &.{ 1, 3, 2 });
    try std.testing.expectEqualSlices(u8, &objectId(small), &small_id);
    try testingExpectObjectBytes(&db, small_id, small);

    const binary = [_]u8{ 'z', 'o', 0, 1, 2, 0xff, 'a' };
    const binary_id = try testingStreamObject(&db, &binary, &.{2});
    try std.testing.expectEqualSlices(u8, &objectId(&binary), &binary_id);
    try testingExpectObjectBytes(&db, binary_id, &binary);

    var large: [fastcdc.max_size * 3 + fastcdc.avg_size]u8 = undefined;
    for (&large, 0..) |*byte, index| {
        byte.* = @intCast((index * 29 + index / 5 + 17) % 251);
    }

    const large_id = try testingStreamObject(&db, &large, &.{ 13, 8191, 3, 65537 });
    try std.testing.expectEqualSlices(u8, &objectId(&large), &large_id);
    try std.testing.expect(try db.objectChunkCount(large_id) > 1);
    try testingExpectObjectBytes(&db, large_id, &large);

    var range: [97]u8 = undefined;
    try std.testing.expectEqual(range.len, try db.readObjectRange(large_id, 1234, &range));
    try std.testing.expectEqualSlices(u8, large[1234 .. 1234 + range.len], &range);

    var manifest = try db.objectManifest(std.testing.allocator, large_id);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expect(manifest.chunks.len > 1);

    var first_chunk = try db.getObjectChunk(std.testing.allocator, manifest.chunks[0].hash);
    defer first_chunk.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &manifest.chunks[0].hash, &first_chunk.hash);
}

test "object writer manifest matches put object for same bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var put_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const writer_path = try testingDbPath(&writer_path_buffer, tmp.sub_path[0..], "writer-manifest.zova");
    const put_path = try testingDbPath(&put_path_buffer, tmp.sub_path[0..], "put-manifest.zova");

    var bytes: [fastcdc.max_size * 2 + 777]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 11 + index / 17 + 91) % 253);
    }

    var writer_db = try Database.create(writer_path);
    defer writer_db.deinit();
    const writer_id = try testingStreamObject(&writer_db, &bytes, &.{ 1, 5, 257, 4099 });

    var put_db = try Database.create(put_path);
    defer put_db.deinit();
    const put_id = try put_db.putObject(&bytes);

    try std.testing.expectEqualSlices(u8, &put_id, &writer_id);

    var writer_manifest = try writer_db.objectManifest(std.testing.allocator, writer_id);
    defer writer_manifest.deinit(std.testing.allocator);
    var put_manifest = try put_db.objectManifest(std.testing.allocator, put_id);
    defer put_manifest.deinit(std.testing.allocator);
    try testingExpectManifestsEqual(writer_manifest, put_manifest);
}

test "object writer does not allocate object sized memory for multi megabyte input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-memory.zova");

    const bytes = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 31 + index / 7 + 19) % 251);
    }

    var db = try Database.create(db_path);
    defer db.deinit();

    var tracking = TestingTrackingAllocator{ .backing = std.testing.allocator };
    var writer = try db.objectWriter(tracking.allocator());
    defer writer.deinit();

    var offset: usize = 0;
    while (offset < bytes.len) {
        const len = @min(bytes.len - offset, 37_919);
        try writer.write(bytes[offset .. offset + len]);
        offset += len;
    }

    const id = try writer.finish();
    try std.testing.expectEqualSlices(u8, &objectId(bytes), &id);
    try std.testing.expect(try db.objectChunkCount(id) > 1);
    try std.testing.expect(tracking.largest_request < bytes.len / 4);
    try std.testing.expect(tracking.largest_request <= fastcdc.max_size * 4);

    var preview: [128]u8 = undefined;
    try std.testing.expectEqual(preview.len, try db.readObjectRange(id, 123_456, &preview));
    try std.testing.expectEqualSlices(u8, bytes[123_456 .. 123_456 + preview.len], &preview);
}

test "object writer deduplicates repeated content and existing objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-dedupe.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const repeated = [_]u8{0} ** (fastcdc.max_size * 4);
    const first_id = try testingStreamObject(&db, &repeated, &.{ 1024, 7, 9000 });
    const second_id = try testingStreamObject(&db, &repeated, &.{repeated.len});

    try std.testing.expectEqualSlices(u8, &first_id, &second_id);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_objects"));

    const chunk_rows = try testingCount(&db, "select count(*) from _zova_chunks");
    const manifest_rows = try testingObjectManifestCount(&db, first_id);
    try std.testing.expect(manifest_rows > 1);
    try std.testing.expect(chunk_rows < manifest_rows);
}

test "object writer cancel and deinit cleanup unfinished chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-cancel.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = [_]u8{0x42} ** (fastcdc.max_size + fastcdc.avg_size);
    const id = objectId(&bytes);

    var writer = try db.objectWriter(std.testing.allocator);
    try writer.write(&bytes);
    try writer.cancel();
    defer writer.deinit();

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
    try std.testing.expectError(error.ObjectWriterClosed, writer.write("again"));
    try std.testing.expectError(error.ObjectWriterClosed, writer.finish());
    try std.testing.expectError(error.ObjectWriterClosed, writer.cancel());

    var finished = try db.objectWriter(std.testing.allocator);
    try finished.write("closed after finish");
    _ = try finished.finish();
    defer finished.deinit();
    try std.testing.expectError(error.ObjectWriterClosed, finished.write("again"));
    try std.testing.expectError(error.ObjectWriterClosed, finished.finish());
    try std.testing.expectError(error.ObjectWriterClosed, finished.cancel());

    const chunk_count_before_auto_cancel = try testingCount(&db, "select count(*) from _zova_chunks");
    {
        var auto_cancel = try db.objectWriter(std.testing.allocator);
        try auto_cancel.write(&bytes);
        auto_cancel.deinit();
    }
    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(chunk_count_before_auto_cancel, try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "object writer cancel preserves pre-existing loose chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-cancel-existing-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const chunk = [_]u8{0x73} ** fastcdc.max_size;
    const hash = objectChunkId(&chunk);
    try db.putObjectChunk(hash, &chunk);

    var writer = try db.objectWriter(std.testing.allocator);
    try writer.write(&chunk);
    try writer.cancel();
    defer writer.deinit();

    try std.testing.expect(try db.hasObjectChunk(hash));
    var stored = try db.getObjectChunk(std.testing.allocator, hash);
    defer stored.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &chunk, stored.bytes);
    try testingExpectObjectMissing(&db, objectId(&chunk));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "object writer rejects active transactions and can retry after finish failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-transaction.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.sqlite_db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.objectWriter(std.testing.allocator));
    try db.sqlite_db.rollback();

    var active_writer = try db.objectWriter(std.testing.allocator);
    defer active_writer.deinit();
    try db.sqlite_db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, active_writer.write("blocked"));
    try std.testing.expectError(error.ObjectTransactionActive, active_writer.finish());
    try std.testing.expectError(error.ObjectTransactionActive, active_writer.cancel());
    try db.sqlite_db.rollback();
    try active_writer.cancel();

    const bytes = "writer rollback retry";
    const id = objectId(bytes);
    var writer = try db.objectWriter(std.testing.allocator);
    defer writer.deinit();
    try writer.write(bytes);

    try db.exec(
        \\create trigger force_writer_manifest_failure
        \\before insert on _zova_object_chunks
        \\begin
        \\  select raise(abort, 'forced writer manifest failure');
        \\end;
    );
    try std.testing.expectError(error.Constraint, writer.finish());
    try std.testing.expect(!try db.hasObject(id));
    try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.exec("drop trigger force_writer_manifest_failure");
    try std.testing.expectError(error.ObjectWriterClosed, writer.write("after failed finish"));
    const retried_id = try writer.finish();
    try std.testing.expectEqualSlices(u8, &id, &retried_id);
    try testingExpectObjectBytes(&db, id, bytes);
}

test "object writer works after reopen and on converted databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-reopen.zova");

    const reopened_id = id: {
        var db = try Database.create(db_path);
        defer db.deinit();
        break :id try testingStreamObject(&db, "persisted writer object", &.{ 2, 3 });
    };

    {
        var db = try Database.open(db_path);
        defer db.deinit();
        try testingExpectObjectBytes(&db, reopened_id, "persisted writer object");
        try testingQuickCheckOk(&db);
        try testingIntegrityCheckOk(&db);
    }

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "writer-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "writer-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table notes (id integer primary key, body text not null)");
        try source.exec("insert into notes (body) values ('source row')");
    }

    try convertSqliteToZova(source_path, dest_path);
    var db = try Database.open(dest_path);
    defer db.deinit();

    const converted_id = try testingStreamObject(&db, "converted writer object", &.{1});
    try testingExpectObjectBytes(&db, converted_id, "converted writer object");
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes"));
}

test "put and get empty object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "put-get-empty.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("");
    try std.testing.expectEqualSlices(u8, &objectId(""), &id);
    try std.testing.expect(try db.hasObject(id));
    try std.testing.expectEqual(@as(u64, 0), try db.objectSize(id));
    try std.testing.expectEqual(@as(u64, 0), try db.objectChunkCount(id));

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &object.id);
    try std.testing.expectEqualSlices(u8, "", object.bytes);
}

test "put and get small binary object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "put-get-small.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = [_]u8{ 'z', 'o', 'v', 'a', 0, 1, 2, 255 };
    const id = try db.putObject(&bytes);
    try std.testing.expectEqualSlices(u8, &objectId(&bytes), &id);
    try std.testing.expect(try db.hasObject(id));
    try std.testing.expectEqual(@as(u64, bytes.len), try db.objectSize(id));
    try std.testing.expectEqual(@as(u64, 1), try db.objectChunkCount(id));

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &object.id);
    try std.testing.expectEqualSlices(u8, &bytes, object.bytes);
}

test "put and get large multi chunk object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "put-get-large.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var bytes: [fastcdc.max_size + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 17 + index / 3 + 11) % 251);
    }

    const id = try db.putObject(&bytes);
    try std.testing.expect(try db.objectChunkCount(id) > 1);

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &object.id);
    try std.testing.expectEqualSlices(u8, &bytes, object.bytes);
}

test "put same object twice deduplicates object chunks and manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "put-dedupe.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = "same object bytes";
    const first_id = try db.putObject(bytes);
    const second_id = try db.putObject(bytes);

    try std.testing.expectEqualSlices(u8, &first_id, &second_id);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));
    try std.testing.expectEqual(@as(i64, 1), try testingObjectManifestCount(&db, first_id));
}

test "put repeated content deduplicates identical chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "chunk-dedupe.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = [_]u8{0} ** (fastcdc.max_size * 4);
    const id = try db.putObject(&bytes);

    const chunk_rows = try testingCount(&db, "select count(*) from _zova_chunks");
    const manifest_rows = try testingObjectManifestCount(&db, id);
    try std.testing.expect(manifest_rows > 1);
    try std.testing.expect(chunk_rows < manifest_rows);
}

test "put similar objects shares at least one chunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "shared-chunks.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const base = [_]u8{0} ** (fastcdc.max_size * 4);
    var edited: [base.len + 257]u8 = undefined;
    for (edited[0..257], 0..) |*byte, index| {
        byte.* = @intCast((index * 23 + 5) % 241);
    }
    @memcpy(edited[257..], &base);

    const base_id = try db.putObject(&base);
    const edited_id = try db.putObject(&edited);

    try std.testing.expect(!std.mem.eql(u8, &base_id, &edited_id));
    try std.testing.expect(try testingSharedChunkCount(&db, base_id, edited_id) > 0);
}

test "object lookup helpers report present and missing objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-lookups.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const present = try db.putObject("present");
    const missing = objectId("missing");

    try std.testing.expect(try db.hasObject(present));
    try std.testing.expect(!try db.hasObject(missing));
    try std.testing.expectEqual(@as(u64, 7), try db.objectSize(present));
    try std.testing.expectEqual(@as(u64, 1), try db.objectChunkCount(present));
    try std.testing.expectError(error.ObjectNotFound, db.objectSize(missing));
    try std.testing.expectError(error.ObjectNotFound, db.objectChunkCount(missing));
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, missing));
}

test "delete object reports missing for absent and already deleted ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-missing.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expectError(error.ObjectNotFound, db.deleteObject(objectId("missing")));

    const id = try db.putObject("delete once");
    try db.deleteObject(id);
    try std.testing.expectError(error.ObjectNotFound, db.deleteObject(id));
}

test "putting same bytes after delete recreates same object id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-reput.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const first_id = try db.putObject("recreate me");
    try db.deleteObject(first_id);

    const second_id = try db.putObject("recreate me");
    try std.testing.expectEqualSlices(u8, &first_id, &second_id);

    var object = try db.getObject(std.testing.allocator, second_id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "recreate me", object.bytes);
}

test "delete object preserves user sql references and blob tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-user-sql.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec(
        \\create table attachments (object_id blob not null, filename text not null);
        \\create table user_blobs (data blob not null);
    );

    const id = try db.putObject("user referenced");
    {
        var insert = try db.prepare("insert into attachments (object_id, filename) values (?, ?)");
        defer insert.deinit();

        try insert.bindBlob(1, &id);
        try insert.bindText(2, "kept.bin");
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    const blob = [_]u8{ 9, 8, 7, 0, 6 };
    {
        var insert = try db.prepare("insert into user_blobs (data) values (?)");
        defer insert.deinit();

        try insert.bindBlob(1, &blob);
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    try db.deleteObject(id);

    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from attachments"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from user_blobs where length(data) = 5"));
    try testingExpectObjectMissing(&db, id);
    try testingQuickCheckOk(&db);
    try testingIntegrityCheckOk(&db);
}

test "delete object does not touch caller temp tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-temp-collision.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("temp table collision");
    try db.exec(
        \\create temp table zova_delete_candidate_chunks (
        \\  chunk_hash text primary key,
        \\  note text not null
        \\);
        \\insert into temp.zova_delete_candidate_chunks (chunk_hash, note)
        \\values ('caller-owned', 'preserved');
    );

    try db.deleteObject(id);

    var select = try db.prepare("select note from temp.zova_delete_candidate_chunks where chunk_hash = 'caller-owned'");
    defer select.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try select.step());
    try std.testing.expectEqualStrings("preserved", select.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try select.step());
}

test "delete object preserves multiple user sql references to the same id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-multiple-user-refs.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec(
        \\create table attachments (
        \\  id integer primary key,
        \\  object_id blob not null,
        \\  filename text not null
        \\)
    );

    const id = try db.putObject("referenced twice");
    for ([_][]const u8{ "first.bin", "second.bin" }) |filename| {
        var insert = try db.prepare("insert into attachments (object_id, filename) values (?, ?)");
        defer insert.deinit();

        try insert.bindBlob(1, &id);
        try insert.bindText(2, filename);
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    try db.deleteObject(id);

    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from attachments"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from attachments where length(object_id) = 32"));
    try testingExpectObjectMissing(&db, id);
}

test "delete object with missing manifest rows cleans remaining object state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-missing-manifest.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var bytes: [fastcdc.max_size + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 13 + index / 7 + 17) % 251);
    }

    const id = try db.putObject(&bytes);
    try std.testing.expect((try testingObjectManifestCount(&db, id)) > 1);
    try db.exec("delete from _zova_object_chunks where chunk_index = 0");
    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
}

test "sqlite wrapper can inspect object tables after deletion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "sqlite-inspect-after-delete.zova");
    const id = id: {
        var db = try Database.create(db_path);
        defer db.deinit();

        const stored_id = try db.putObject("raw sqlite inspect");
        try db.deleteObject(stored_id);
        break :id stored_id;
    };

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_objects", 1);
    try testingExpectTableCount(&raw, "_zova_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 1);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&raw, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&raw, "select count(*) from _zova_object_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&raw, "select count(*) from _zova_chunks"));
    _ = id;
    try testingIntegrityCheckOk(&raw);
}

test "delete object works on converted zova database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "delete-convert.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "delete-convert.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table notes (id integer primary key, body text not null)");
        try source.exec("insert into notes (body) values ('kept')");
    }

    try convertSqliteToZova(source_path, dest_path);

    var db = try Database.open(dest_path);
    defer db.deinit();

    const id = try db.putObject("converted delete");
    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes"));
}

test "delete object rejects active user transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-active-transaction.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const deferred_id = try db.putObject("deferred delete");
    try db.sqlite_db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.deleteObject(deferred_id));
    try db.sqlite_db.rollback();
    try std.testing.expect(try db.hasObject(deferred_id));

    const immediate_id = try db.putObject("immediate delete");
    try db.sqlite_db.beginImmediate();
    try std.testing.expectError(error.ObjectTransactionActive, db.deleteObject(immediate_id));
    try db.sqlite_db.rollback();
    try std.testing.expect(try db.hasObject(immediate_id));
}

test "delete object follows sqlite write lock behavior across connections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-two-connections.zova");

    var first = try Database.create(db_path);
    defer first.deinit();
    const id = try first.putObject("locked delete");

    var second = try Database.open(db_path);
    defer second.deinit();

    try first.sqlite_db.beginImmediate();
    try std.testing.expectError(error.Busy, second.deleteObject(id));
    try first.sqlite_db.rollback();

    try second.deleteObject(id);
    try testingExpectObjectMissing(&second, id);
}

test "object ids can be stored in user sql tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-relational.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec("create table attachments (id integer primary key, object_id blob not null, filename text not null)");

    const id = try db.putObject("attachment bytes");
    {
        var insert = try db.prepare("insert into attachments (object_id, filename) values (?, ?)");
        defer insert.deinit();

        try insert.bindBlob(1, &id);
        try insert.bindText(2, "note.bin");
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    var loaded_id: ObjectId = undefined;
    {
        var select = try db.prepare("select object_id from attachments where filename = ?");
        defer select.deinit();

        try select.bindText(1, "note.bin");
        try std.testing.expectEqual(sqlite.Step.row, try select.step());
        const stored_id = select.columnBlob(0);
        try std.testing.expectEqual(@as(usize, 32), stored_id.len);
        @memcpy(loaded_id[0..], stored_id);
    }

    var object = try db.getObject(std.testing.allocator, loaded_id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "attachment bytes", object.bytes);
}

test "plain sql blob tables still work in zova databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "plain-blob.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec("create table user_blobs (id integer primary key, data blob not null)");

    const blob = [_]u8{ 0, 1, 2, 3, 4 };
    {
        var insert = try db.prepare("insert into user_blobs (data) values (?)");
        defer insert.deinit();

        try insert.bindBlob(1, &blob);
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    var select = try db.prepare("select data from user_blobs");
    defer select.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try select.step());
    try std.testing.expectEqualSlices(u8, &blob, select.columnBlob(0));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
}

test "object api works on converted sqlite database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "object-convert.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "object-convert.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table notes (id integer primary key, body text not null)");
        try source.exec("insert into notes (body) values ('kept')");
    }

    try convertSqliteToZova(source_path, dest_path);

    var db = try Database.open(dest_path);
    defer db.deinit();

    const id = try db.putObject("converted object");
    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "converted object", object.bytes);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes"));
}

test "put object rejects active user transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "active-transaction.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.sqlite_db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.putObject("deferred"));
    try db.sqlite_db.rollback();

    try db.sqlite_db.beginImmediate();
    try std.testing.expectError(error.ObjectTransactionActive, db.putObject("immediate"));
    try db.sqlite_db.rollback();
}

test "failed put object rolls back visible private rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "put-rollback.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec("drop table _zova_object_chunks");
    try std.testing.expectError(error.SqliteError, db.putObject("rollback me"));

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.exec(object_impl.object_chunks_schema_sql ++ ";");
    const id = try db.putObject("later success");
    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "later success", object.bytes);
}

test "stored chunk hash is sha256 of chunk bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "chunk-hash.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    _ = try db.putObject("chunk");

    var select = try db.prepare("select chunk_hash from _zova_chunks");
    defer select.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try select.step());
    try std.testing.expectEqualSlices(u8, &objectId("chunk"), select.columnBlob(0));
}

test "object manifest exposes ordered chunk metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-manifest.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expectError(error.ObjectNotFound, db.objectManifest(std.testing.allocator, objectId("missing")));

    const empty_id = try db.putObject("");
    var empty_manifest = try db.objectManifest(std.testing.allocator, empty_id);
    defer empty_manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &empty_id, &empty_manifest.object_id);
    try std.testing.expectEqual(@as(u64, 0), empty_manifest.size_bytes);
    try std.testing.expectEqual(@as(u64, 0), empty_manifest.chunk_count);
    try std.testing.expectEqualStrings(fastcdc.version, empty_manifest.chunker);
    try std.testing.expectEqual(@as(usize, 0), empty_manifest.chunks.len);

    const small_id = try db.putObject("small object");
    var small_manifest = try db.objectManifest(std.testing.allocator, small_id);
    defer small_manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), small_manifest.chunk_count);
    try std.testing.expectEqual(@as(usize, 1), small_manifest.chunks.len);
    try std.testing.expectEqual(@as(u64, 0), small_manifest.chunks[0].offset);
    try std.testing.expectEqual(@as(u64, "small object".len), small_manifest.chunks[0].size_bytes);

    var bytes: [fastcdc.max_size + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 29 + index / 5 + 7) % 251);
    }

    const id = try db.putObject(&bytes);
    var manifest = try db.objectManifest(std.testing.allocator, id);
    defer manifest.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &manifest.object_id);
    try std.testing.expectEqual(@as(u64, bytes.len), manifest.size_bytes);
    try std.testing.expectEqual(try db.objectChunkCount(id), manifest.chunk_count);
    try std.testing.expectEqual(@as(usize, @intCast(manifest.chunk_count)), manifest.chunks.len);
    try std.testing.expectEqualStrings(fastcdc.version, manifest.chunker);
    try std.testing.expect(manifest.chunks.len > 1);

    var expected_offset: u64 = 0;
    for (manifest.chunks, 0..) |chunk, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index)), chunk.index);
        try std.testing.expectEqual(expected_offset, chunk.offset);
        try std.testing.expect(chunk.size_bytes > 0);
        try std.testing.expect(chunk.size_bytes <= fastcdc.max_size);
        try std.testing.expect(try db.hasObjectChunk(chunk.hash));
        expected_offset += chunk.size_bytes;
    }
    try std.testing.expectEqual(@as(u64, bytes.len), expected_offset);
}

test "object chunks can be read and reassembled through public API" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-chunk-read.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var bytes: [fastcdc.max_size + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 13 + index / 7 + 19) % 253);
    }

    const id = try db.putObject(&bytes);
    var manifest = try db.objectManifest(std.testing.allocator, id);
    defer manifest.deinit(std.testing.allocator);

    var rebuilt = try std.testing.allocator.alloc(u8, bytes.len);
    defer std.testing.allocator.free(rebuilt);

    for (manifest.chunks) |chunk| {
        var chunk_data = try db.getObjectChunk(std.testing.allocator, chunk.hash);
        defer chunk_data.deinit(std.testing.allocator);

        try std.testing.expectEqualSlices(u8, &chunk.hash, &chunk_data.hash);
        try std.testing.expectEqual(@as(usize, @intCast(chunk.size_bytes)), chunk_data.bytes.len);
        const start: usize = @intCast(chunk.offset);
        @memcpy(rebuilt[start .. start + chunk_data.bytes.len], chunk_data.bytes);
    }

    try std.testing.expectEqualSlices(u8, &bytes, rebuilt);

    const missing = [_]u8{0x91} ** 32;
    try std.testing.expect(!try db.hasObjectChunk(missing));
    try std.testing.expectError(error.ObjectChunkNotFound, db.getObjectChunk(std.testing.allocator, missing));
}

test "put object chunk stores verified loose chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "loose-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = "received loose chunk";
    const hash = objectChunkId(bytes);
    try db.putObjectChunk(hash, bytes);

    try std.testing.expect(try db.hasObjectChunk(hash));
    var chunk = try db.getObjectChunk(std.testing.allocator, hash);
    defer chunk.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &hash, &chunk.hash);
    try std.testing.expectEqualSlices(u8, bytes, chunk.bytes);

    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));
    try db.putObjectChunk(hash, bytes);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_object_chunks"));
}

test "put object chunk validates hash and size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "loose-chunk-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expectError(error.ObjectCorrupt, db.putObjectChunk(objectChunkId(""), ""));
    try std.testing.expectError(error.ObjectChunkHashMismatch, db.putObjectChunk(objectChunkId("expected"), "actual"));

    const too_large = try std.testing.allocator.alloc(u8, fastcdc.max_size + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 0xaa);
    try std.testing.expectError(error.ObjectCorrupt, db.putObjectChunk(objectChunkId(too_large), too_large));

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "loose object chunks persist and work after conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "loose-chunk-reopen.zova");

        const hash = objectChunkId("persisted loose chunk");
        {
            var db = try Database.create(db_path);
            defer db.deinit();
            try db.putObjectChunk(hash, "persisted loose chunk");
        }

        var reopened = try Database.open(db_path);
        defer reopened.deinit();
        var chunk = try reopened.getObjectChunk(std.testing.allocator, hash);
        defer chunk.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "persisted loose chunk", chunk.bytes);
    }

    {
        var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "loose-source.db");
        const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "loose-converted.zova");

        {
            var source = try sqlite.Database.open(source_path);
            defer source.deinit();
            try source.exec("create table source_rows (id integer primary key, body text not null)");
            try source.exec("insert into source_rows (body) values ('source data')");
        }

        try convertSqliteToZova(source_path, dest_path);

        var db = try Database.open(dest_path);
        defer db.deinit();

        const hash = objectChunkId("converted loose chunk");
        try db.putObjectChunk(hash, "converted loose chunk");

        var chunk = try db.getObjectChunk(std.testing.allocator, hash);
        defer chunk.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "converted loose chunk", chunk.bytes);
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from source_rows"));
    }
}

test "put object chunk detects existing corrupt rows and participates in caller transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "loose-chunk-corrupt-existing.zova");

        var db = try Database.create(db_path);
        defer db.deinit();

        const bytes = "loose valid";
        const hash = objectChunkId(bytes);
        try db.putObjectChunk(hash, bytes);

        var corrupt = try db.prepare("update _zova_chunks set data = ? where chunk_hash = ?");
        defer corrupt.deinit();
        try corrupt.bindBlob(1, "loose wrong");
        try corrupt.bindBlob(2, &hash);
        try std.testing.expectEqual(sqlite.Step.done, try corrupt.step());

        try std.testing.expectError(error.ObjectCorrupt, db.putObjectChunk(hash, bytes));
        try std.testing.expectError(error.ObjectCorrupt, db.getObjectChunk(std.testing.allocator, hash));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "loose-chunk-transaction.zova");

        var db = try Database.create(db_path);
        defer db.deinit();

        const hash = objectChunkId("transaction loose chunk");
        try db.sqlite_db.begin();
        try db.putObjectChunk(hash, "transaction loose chunk");
        try db.sqlite_db.commit();

        var chunk = try db.getObjectChunk(std.testing.allocator, hash);
        defer chunk.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "transaction loose chunk", chunk.bytes);
    }
}

test "assemble object from verified chunks supports empty one chunk multi chunk and shuffled input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "assemble-basic.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const empty_id = objectId("");
    try db.assembleObjectFromChunks(empty_id, 0, &.{});
    var empty = try db.getObject(std.testing.allocator, empty_id);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "", empty.bytes);

    const small = "assembled small";
    const small_id = objectId(small);
    const small_manifest = try testingPutLooseManifest(std.testing.allocator, &db, small);
    defer std.testing.allocator.free(small_manifest);
    try db.assembleObjectFromChunks(small_id, small.len, small_manifest);
    var small_object = try db.getObject(std.testing.allocator, small_id);
    defer small_object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, small, small_object.bytes);

    var large = try std.testing.allocator.alloc(u8, fastcdc.max_size + fastcdc.avg_size * 2);
    defer std.testing.allocator.free(large);
    for (large, 0..) |*byte, index| {
        byte.* = @intCast((index * 17 + index / 3 + 41) % 251);
    }

    const large_id = objectId(large);
    const large_manifest = try testingPutLooseManifest(std.testing.allocator, &db, large);
    defer std.testing.allocator.free(large_manifest);
    try std.testing.expect(large_manifest.len > 1);

    const shuffled = try std.testing.allocator.dupe(ObjectChunk, large_manifest);
    defer std.testing.allocator.free(shuffled);
    std.mem.reverse(ObjectChunk, shuffled);

    try db.assembleObjectFromChunks(large_id, large.len, shuffled);
    var range: [257]u8 = undefined;
    try std.testing.expectEqual(range.len, try db.readObjectRange(large_id, 1234, &range));
    try std.testing.expectEqualSlices(u8, large[1234 .. 1234 + range.len], &range);

    var manifest = try db.objectManifest(std.testing.allocator, large_id);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, large.len), manifest.size_bytes);
    try std.testing.expectEqual(@as(usize, large_manifest.len), manifest.chunks.len);
}

test "assemble object consumes existing chunks and rejects existing objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "assemble-existing.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const shared = "chunk already stored by another object";
    const tail = " plus loose chunk";
    const base_id = try db.putObject(shared);
    var base_manifest = try db.objectManifest(std.testing.allocator, base_id);
    defer base_manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), base_manifest.chunks.len);

    const combined = try std.mem.concat(std.testing.allocator, u8, &.{ shared, tail });
    defer std.testing.allocator.free(combined);
    const combined_id = objectId(combined);
    const tail_hash = objectChunkId(tail);
    try db.putObjectChunk(tail_hash, tail);

    const combined_manifest = [_]ObjectChunk{
        base_manifest.chunks[0],
        .{
            .index = 1,
            .hash = tail_hash,
            .offset = shared.len,
            .size_bytes = tail.len,
        },
    };
    try db.assembleObjectFromChunks(combined_id, combined.len, &combined_manifest);
    var combined_object = try db.getObject(std.testing.allocator, combined_id);
    defer combined_object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, combined, combined_object.bytes);
    try std.testing.expectEqual(@as(i64, 1), try testingSharedChunkCount(&db, base_id, combined_id));

    try std.testing.expectError(error.ObjectAlreadyExists, db.assembleObjectFromChunks(base_id, shared.len, &.{}));

    const corrupt_id = try db.putObject("corrupt existing");
    {
        var corrupt = try db.prepare(
            \\update _zova_chunks
            \\set data = ?
            \\where chunk_hash in (
            \\  select chunk_hash from _zova_object_chunks where object_id = ?
            \\)
        );
        defer corrupt.deinit();
        try corrupt.bindBlob(1, "xxxxxxxxxxxxxxxx");
        try corrupt.bindBlob(2, &corrupt_id);
        try std.testing.expectEqual(sqlite.Step.done, try corrupt.step());
    }
    try std.testing.expectError(error.ObjectCorrupt, db.assembleObjectFromChunks(corrupt_id, 0, &.{}));
}

test "assemble object validates manifest and chunk storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "assemble-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = "manifest validation";
    const id = objectId(bytes);
    const manifest = try testingPutLooseManifest(std.testing.allocator, &db, bytes);
    defer std.testing.allocator.free(manifest);
    try std.testing.expectEqual(@as(usize, 1), manifest.len);

    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(objectId("wrong id"), bytes.len, manifest));
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len + 1, manifest));

    var bad = try std.testing.allocator.dupe(ObjectChunk, manifest);
    defer std.testing.allocator.free(bad);

    bad[0].index = 1;
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, bad));

    bad[0] = manifest[0];
    bad[0].offset = 1;
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, bad));

    bad[0] = manifest[0];
    bad[0].size_bytes -= 1;
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, bad));

    bad[0] = manifest[0];
    bad[0].size_bytes = 0;
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, bad));

    bad[0] = manifest[0];
    bad[0].size_bytes = fastcdc.max_size + 1;
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, bad));

    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, &.{}));

    const left = "left";
    const right = "right";
    const left_hash = objectChunkId(left);
    const right_hash = objectChunkId(right);
    try db.putObjectChunk(left_hash, left);
    try db.putObjectChunk(right_hash, right);
    const overlap = [_]ObjectChunk{
        .{
            .index = 0,
            .hash = left_hash,
            .offset = 0,
            .size_bytes = left.len,
        },
        .{
            .index = 1,
            .hash = right_hash,
            .offset = 2,
            .size_bytes = right.len,
        },
    };
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(objectId("leftright"), left.len + right.len, &overlap));

    const missing = [_]ObjectChunk{.{
        .index = 0,
        .hash = objectChunkId("missing"),
        .offset = 0,
        .size_bytes = "missing".len,
    }};
    try std.testing.expectError(error.ObjectChunkNotFound, db.assembleObjectFromChunks(objectId("missing"), "missing".len, &missing));

    {
        const corrupt_bytes = try std.testing.allocator.dupe(u8, bytes);
        defer std.testing.allocator.free(corrupt_bytes);
        corrupt_bytes[0] +%= 1;

        var corrupt = try db.prepare("update _zova_chunks set data = ? where chunk_hash = ?");
        defer corrupt.deinit();
        try corrupt.bindBlob(1, corrupt_bytes);
        try corrupt.bindBlob(2, &manifest[0].hash);
        try std.testing.expectEqual(sqlite.Step.done, try corrupt.step());
    }
    try std.testing.expectError(error.ObjectCorrupt, db.assembleObjectFromChunks(id, bytes.len, manifest));
}

test "assemble object owns transactions rolls back failures and works after conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "assemble-transaction.zova");

        var db = try Database.create(db_path);
        defer db.deinit();

        const bytes = "transaction assembly";
        const id = objectId(bytes);
        const manifest = try testingPutLooseManifest(std.testing.allocator, &db, bytes);
        defer std.testing.allocator.free(manifest);

        try db.sqlite_db.begin();
        try std.testing.expectError(error.ObjectTransactionActive, db.assembleObjectFromChunks(id, bytes.len, manifest));
        try db.sqlite_db.rollback();

        try db.exec(
            \\create trigger force_manifest_insert_failure
            \\before insert on _zova_object_chunks
            \\begin
            \\  select raise(abort, 'forced manifest failure');
            \\end;
        );
        try std.testing.expectError(error.Constraint, db.assembleObjectFromChunks(id, bytes.len, manifest));
        try std.testing.expect(!try db.hasObject(id));
        try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
        try std.testing.expect(try db.hasObjectChunk(manifest[0].hash));

        try db.exec("drop trigger force_manifest_insert_failure");
        try db.assembleObjectFromChunks(id, bytes.len, manifest);
        var object = try db.getObject(std.testing.allocator, id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, bytes, object.bytes);
    }

    {
        var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "assemble-source.db");
        const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "assemble-converted.zova");

        {
            var source = try sqlite.Database.open(source_path);
            defer source.deinit();
            try source.exec("create table notes (id integer primary key, body text not null)");
            try source.exec("insert into notes (body) values ('source row')");
        }

        try convertSqliteToZova(source_path, dest_path);
        var db = try Database.open(dest_path);
        defer db.deinit();

        const bytes = "converted assembly";
        const id = objectId(bytes);
        const manifest = try testingPutLooseManifest(std.testing.allocator, &db, bytes);
        defer std.testing.allocator.free(manifest);
        try db.assembleObjectFromChunks(id, bytes.len, manifest);

        var object = try db.getObject(std.testing.allocator, id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, bytes, object.bytes);
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes"));
    }
}

test "delete object chunk removes only unreferenced loose chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-object-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const loose_hash = objectChunkId("loose cleanup");
    try std.testing.expect(!try db.deleteObjectChunk(loose_hash));
    try db.putObjectChunk(loose_hash, "loose cleanup");
    try std.testing.expect(try db.deleteObjectChunk(loose_hash));
    try std.testing.expect(!try db.hasObjectChunk(loose_hash));
    try std.testing.expect(!try db.deleteObjectChunk(loose_hash));

    const id = try db.putObject("referenced chunk");
    var manifest = try db.objectManifest(std.testing.allocator, id);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), manifest.chunks.len);
    try std.testing.expect(!try db.deleteObjectChunk(manifest.chunks[0].hash));
    try std.testing.expect(try db.hasObjectChunk(manifest.chunks[0].hash));

    try db.deleteObject(id);
    try std.testing.expect(!try db.hasObjectChunk(manifest.chunks[0].hash));

    try db.exec("drop table _zova_chunks");
    try std.testing.expectError(error.SqliteError, db.deleteObjectChunk(loose_hash));
    try db.exec(object_impl.chunks_schema_sql ++ ";");
    try db.putObjectChunk(loose_hash, "loose cleanup");
    try std.testing.expect(try db.deleteObjectChunk(loose_hash));
}

test "object range reads copy caller requested bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-range-read.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const empty_id = try db.putObject("");
    var empty_buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try db.readObjectRange(empty_id, 0, &empty_buffer));

    const missing = objectId("missing");
    try std.testing.expectError(error.ObjectNotFound, db.readObjectRange(missing, 0, &empty_buffer));

    const small = "hello range";
    const small_id = try db.putObject(small);
    var small_full: [small.len]u8 = undefined;
    try std.testing.expectEqual(small.len, try db.readObjectRange(small_id, 0, &small_full));
    try std.testing.expectEqualSlices(u8, small, &small_full);

    var one: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try db.readObjectRange(small_id, 0, &one));
    try std.testing.expectEqual(@as(u8, 'h'), one[0]);
    try std.testing.expectEqual(@as(usize, 1), try db.readObjectRange(small_id, small.len - 1, &one));
    try std.testing.expectEqual(@as(u8, 'e'), one[0]);

    var tail: [64]u8 = undefined;
    const tail_len = try db.readObjectRange(small_id, 6, &tail);
    try std.testing.expectEqual(@as(usize, 5), tail_len);
    try std.testing.expectEqualSlices(u8, "range", tail[0..tail_len]);
    try std.testing.expectEqual(@as(usize, 0), try db.readObjectRange(small_id, small.len, &tail));
    try std.testing.expectEqual(@as(usize, 0), try db.readObjectRange(small_id, 0, tail[0..0]));
    try std.testing.expectError(error.ObjectRangeInvalid, db.readObjectRange(small_id, small.len + 1, &tail));

    {
        var delete_manifest = try db.prepare("delete from _zova_object_chunks where object_id = ?");
        defer delete_manifest.deinit();

        try delete_manifest.bindBlob(1, &small_id);
        try std.testing.expectEqual(sqlite.Step.done, try delete_manifest.step());
    }
    try std.testing.expectEqual(@as(usize, 0), try db.readObjectRange(small_id, small.len, &tail));
    try std.testing.expectEqual(@as(usize, 0), try db.readObjectRange(small_id, 0, tail[0..0]));
    try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(small_id, 0, &tail));

    var bytes: [fastcdc.max_size * 3 + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 17 + index / 11 + 31) % 251);
    }

    const large_id = try db.putObject(&bytes);
    var manifest = try db.objectManifest(std.testing.allocator, large_id);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expect(manifest.chunks.len > 2);

    const full = try std.testing.allocator.alloc(u8, bytes.len);
    defer std.testing.allocator.free(full);
    try std.testing.expectEqual(bytes.len, try db.readObjectRange(large_id, 0, full));
    try std.testing.expectEqualSlices(u8, &bytes, full);

    var within_one_chunk: [17]u8 = undefined;
    const within_offset: usize = @intCast(manifest.chunks[0].offset + 3);
    try std.testing.expectEqual(within_one_chunk.len, try db.readObjectRange(large_id, within_offset, &within_one_chunk));
    try std.testing.expectEqualSlices(u8, bytes[within_offset .. within_offset + within_one_chunk.len], &within_one_chunk);

    var across_two_chunks: [32]u8 = undefined;
    const two_chunk_offset: usize = @intCast(manifest.chunks[1].offset - 7);
    try std.testing.expectEqual(across_two_chunks.len, try db.readObjectRange(large_id, two_chunk_offset, &across_two_chunks));
    try std.testing.expectEqualSlices(u8, bytes[two_chunk_offset .. two_chunk_offset + across_two_chunks.len], &across_two_chunks);

    var across_many_chunks: [fastcdc.max_size + 4096]u8 = undefined;
    const many_offset: usize = @intCast(manifest.chunks[0].size_bytes - 11);
    try std.testing.expectEqual(across_many_chunks.len, try db.readObjectRange(large_id, many_offset, &across_many_chunks));
    try std.testing.expectEqualSlices(u8, bytes[many_offset .. many_offset + across_many_chunks.len], &across_many_chunks);

    var reopened = try Database.open(db_path);
    defer reopened.deinit();
    var repeated: [19]u8 = undefined;
    try std.testing.expectEqual(repeated.len, try reopened.readObjectRange(large_id, 1234, &repeated));
    try std.testing.expectEqualSlices(u8, bytes[1234 .. 1234 + repeated.len], &repeated);
}

test "object range reads report corrupt private rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-missing-chunk.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("missing chunk");
        var buffer: [16]u8 = undefined;
        try db.exec("delete from _zova_chunks");
        try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(id, 0, &buffer));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-bad-chunk-data.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("abc");
        var buffer: [3]u8 = undefined;
        try db.exec("update _zova_chunks set data = x'616264'");
        try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(id, 0, &buffer));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-missing-manifest.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("missing manifest");
        var buffer: [16]u8 = undefined;
        try db.exec("delete from _zova_object_chunks");
        try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(id, 0, &buffer));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-bad-index.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("bad index");
        var buffer: [9]u8 = undefined;
        try db.exec("update _zova_object_chunks set chunk_index = 1");
        try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(id, 0, &buffer));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-inflated-count.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("inflated count");
        var buffer: [14]u8 = undefined;
        try db.exec("update _zova_objects set size_bytes = 1000000, chunk_count = 1000000");
        try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(id, 0, &buffer));
    }
}

test "database open accepts corrupt object bytes but read APIs detect corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "open-corrupt-object.zova");
    const id = id: {
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("corrupt after open");
        try db.exec("update _zova_chunks set data = x'636f7272757074206166746572204f50454e'");
        break :id id;
    };

    var reopened = try Database.open(db_path);
    defer reopened.deinit();

    try std.testing.expect(try reopened.hasObject(id));
    var buffer: [18]u8 = undefined;
    try std.testing.expectError(error.ObjectCorrupt, reopened.readObjectRange(id, 0, &buffer));
    try std.testing.expectError(error.ObjectCorrupt, reopened.getObject(std.testing.allocator, id));
}

test "two connections can read object ranges concurrently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "concurrent-range-reads.zova");

    var first = try Database.create(db_path);
    defer first.deinit();

    const bytes = "concurrent object range reads";
    const id = try first.putObject(bytes);

    var second = try Database.open(db_path);
    defer second.deinit();

    var first_read: [10]u8 = undefined;
    var second_read: [12]u8 = undefined;
    try std.testing.expectEqual(first_read.len, try first.readObjectRange(id, 0, &first_read));
    try std.testing.expectEqual(second_read.len, try second.readObjectRange(id, 11, &second_read));
    try std.testing.expectEqualSlices(u8, bytes[0..first_read.len], &first_read);
    try std.testing.expectEqualSlices(u8, bytes[11 .. 11 + second_read.len], &second_read);
}

test "two connections can read writer-created object ranges concurrently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-concurrent-range-reads.zova");

    var first = try Database.create(db_path);
    defer first.deinit();

    var bytes: [fastcdc.max_size * 2 + 4096]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 13 + index / 3 + 41) % 253);
    }
    const id = try testingStreamObject(&first, &bytes, &.{ 5, 1000, 65_537, 11 });

    var second = try Database.open(db_path);
    defer second.deinit();

    var first_read: [257]u8 = undefined;
    var second_read: [1024]u8 = undefined;
    try std.testing.expectEqual(first_read.len, try first.readObjectRange(id, 4093, &first_read));
    try std.testing.expectEqual(second_read.len, try second.readObjectRange(id, fastcdc.max_size - 17, &second_read));
    try std.testing.expectEqualSlices(u8, bytes[4093 .. 4093 + first_read.len], &first_read);
    try std.testing.expectEqualSlices(u8, bytes[fastcdc.max_size - 17 .. fastcdc.max_size - 17 + second_read.len], &second_read);
}

test "range reads report sqlite lock errors under exclusive lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-read-exclusive-lock.zova");

    var first = try Database.create(db_path);
    defer first.deinit();
    const id = try first.putObject("locked range read");

    var second = try Database.open(db_path);
    defer second.deinit();

    try first.exec("begin exclusive");
    defer first.exec("rollback") catch {};

    var buffer: [6]u8 = undefined;
    const result = second.readObjectRange(id, 0, &buffer);
    try std.testing.expectError(error.Busy, result);
}

test "duplicate chunks are addressable once by distinct chunk hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "distinct-duplicate-chunks.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = [_]u8{0} ** (fastcdc.max_size * 4);
    const id = try db.putObject(&bytes);
    const chunk_rows = try testingCount(&db, "select count(*) from _zova_chunks");
    const manifest_rows = try testingObjectManifestCount(&db, id);
    try std.testing.expect(manifest_rows > chunk_rows);

    var hashes = std.AutoHashMap(ObjectChunkId, void).init(std.testing.allocator);
    defer hashes.deinit();

    var manifest = try db.objectManifest(std.testing.allocator, id);
    defer manifest.deinit(std.testing.allocator);

    for (manifest.chunks) |chunk| {
        try hashes.put(chunk.hash, {});
    }
    try std.testing.expectEqual(@as(usize, @intCast(chunk_rows)), hashes.count());

    var iterator = hashes.iterator();
    while (iterator.next()) |entry| {
        var chunk = try db.getObjectChunk(std.testing.allocator, entry.key_ptr.*);
        defer chunk.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, entry.key_ptr, &chunk.hash);
    }
}

test "manifest and chunk reads report corrupt private rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-missing-chunk.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("missing chunk");
        try db.exec("delete from _zova_chunks");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-bad-offset.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("bad offset");
        try db.exec("update _zova_object_chunks set offset = 1");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-missing-row.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("missing manifest");
        try db.exec("delete from _zova_object_chunks");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-bad-index.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("bad index");
        try db.exec("update _zova_object_chunks set chunk_index = 1");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-bad-size.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("abc");
        try db.exec("update _zova_object_chunks set size_bytes = 1");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-inflated-count.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("inflated count");
        try db.exec("update _zova_objects set size_bytes = 1000000, chunk_count = 1000000");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "chunk-bad-data.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("abc");
        var manifest = try db.objectManifest(std.testing.allocator, id);
        defer manifest.deinit(std.testing.allocator);

        try db.exec("update _zova_chunks set data = x'616264'");
        try std.testing.expectError(error.ObjectCorrupt, db.getObjectChunk(std.testing.allocator, manifest.chunks[0].hash));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "chunk-bad-size.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("abc");
        var manifest = try db.objectManifest(std.testing.allocator, id);
        defer manifest.deinit(std.testing.allocator);

        try db.exec("pragma ignore_check_constraints = on");
        try db.exec("update _zova_chunks set size_bytes = 2");
        try db.exec("pragma ignore_check_constraints = off");
        try std.testing.expectError(error.ObjectCorrupt, db.getObjectChunk(std.testing.allocator, manifest.chunks[0].hash));
    }
}

test "get object reports corruption for missing chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt-missing-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("missing chunk");
    try db.exec("delete from _zova_chunks");

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
}

test "get object reports corruption for chunk hash mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt-chunk-data.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("abc");
    {
        var update = try db.prepare("update _zova_chunks set data = ?");
        defer update.deinit();

        try update.bindBlob(1, "abd");
        try std.testing.expectEqual(sqlite.Step.done, try update.step());
    }

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
}

test "get object reports corruption for manifest size and offset mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var size_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size_path = try testingDbPath(&size_path_buffer, tmp.sub_path[0..], "corrupt-manifest-size.zova");

    {
        var db = try Database.create(size_path);
        defer db.deinit();

        const id = try db.putObject("abcdef");
        try db.exec("update _zova_object_chunks set size_bytes = 2");
        try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
    }

    var offset_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const offset_path = try testingDbPath(&offset_path_buffer, tmp.sub_path[0..], "corrupt-manifest-offset.zova");

    {
        var db = try Database.create(offset_path);
        defer db.deinit();

        const id = try db.putObject("abcdef");
        try db.exec("update _zova_object_chunks set offset = 1");
        try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
    }
}

test "get object reports corruption for object size mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt-object-size.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("object size");
    try db.exec("update _zova_objects set size_bytes = size_bytes + 1");

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
}

test "get object reports corruption for full object hash mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt-object-hash.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const real_id = try db.putObject("real bytes");
    const wrong_id = objectId("wrong bytes");

    {
        var update_object = try db.prepare("update _zova_objects set object_id = ? where object_id = ?");
        defer update_object.deinit();

        try update_object.bindBlob(1, &wrong_id);
        try update_object.bindBlob(2, &real_id);
        try std.testing.expectEqual(sqlite.Step.done, try update_object.step());
    }

    {
        var update_manifest = try db.prepare("update _zova_object_chunks set object_id = ? where object_id = ?");
        defer update_manifest.deinit();

        try update_manifest.bindBlob(1, &wrong_id);
        try update_manifest.bindBlob(2, &real_id);
        try std.testing.expectEqual(sqlite.Step.done, try update_manifest.step());
    }

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, wrong_id));
}

test "object manifest rejects duplicate indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "duplicate-manifest-index.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    _ = try db.putObject("duplicate index");

    try std.testing.expectError(
        error.Constraint,
        db.exec(
            \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\select object_id, chunk_index, chunk_hash, offset, size_bytes
            \\from _zova_object_chunks
            \\limit 1
        ),
    );
}

test "get object reports corruption for invalid manifest index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "invalid-manifest-index.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("invalid index");
    try db.exec("update _zova_object_chunks set chunk_index = 1 where chunk_index = 0");

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
}

test "get object reports corruption for chunk count mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt-chunk-count.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("chunk count");
    try db.exec("update _zova_objects set chunk_count = chunk_count + 1");

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
}

test "open validates identity only and object corruption is read-time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "open-read-time-corruption.zova");
    const id = id: {
        var db = try Database.create(db_path);
        defer db.deinit();

        const stored_id = try db.putObject("abc");
        {
            var update = try db.prepare("update _zova_chunks set data = ?");
            defer update.deinit();

            try update.bindBlob(1, "abd");
            try std.testing.expectEqual(sqlite.Step.done, try update.step());
        }

        break :id stored_id;
    };

    var reopened = try Database.open(db_path);
    defer reopened.deinit();

    try std.testing.expectError(error.ObjectCorrupt, reopened.getObject(std.testing.allocator, id));
}

test "put and get vector rows use little endian f32 blobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-put-get.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 3, .metric = .cosine });
    try std.testing.expect(!try db.hasVector("chunks", "chunk-1"));
    try db.putVector("chunks", "chunk-1", &.{ 1.0, -2.5, 0.25 });
    try std.testing.expect(try db.hasVector("chunks", "chunk-1"));

    var vector = try db.getVector(std.testing.allocator, "chunks", "chunk-1");
    defer vector.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("chunk-1", vector.id);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, -2.5, 0.25 }, vector.values);

    var raw = try db.prepare("select dimensions, \"values\" from _zova_vectors where collection_name = 'chunks' and vector_id = 'chunk-1'");
    defer raw.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try raw.step());
    try std.testing.expectEqual(@as(i64, 3), raw.columnInt64(0));
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x00, 0x80, 0x3f,
        0x00, 0x00, 0x20, 0xc0,
        0x00, 0x00, 0x80, 0x3e,
    }, raw.columnBlob(1));
    try std.testing.expectEqual(sqlite.Step.done, try raw.step());
}

test "object table constraints reject invalid object ids and chunkers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-constraints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    {
        var short_id = [_]u8{0xaa} ** 31;
        var invalid_id = try db.prepare(
            \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
            \\values (?, 0, 0, 'fastcdc-v1')
        );
        defer invalid_id.deinit();

        try invalid_id.bindBlob(1, &short_id);
        try std.testing.expectError(error.Constraint, invalid_id.step());
    }

    {
        var object_id = [_]u8{0xbb} ** 32;
        var invalid_chunker = try db.prepare(
            \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
            \\values (?, 0, 0, ?)
        );
        defer invalid_chunker.deinit();

        try invalid_chunker.bindBlob(1, &object_id);
        try invalid_chunker.bindText(2, "other-chunker");
        try std.testing.expectError(error.Constraint, invalid_chunker.step());
    }
}

test "object table rejects null object ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "null-object-id.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var null_id = try db.prepare(
        \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
        \\values (?, 0, 0, 'fastcdc-v1')
    );
    defer null_id.deinit();

    try null_id.bindNull(1);
    try std.testing.expectError(error.Constraint, null_id.step());
}

test "chunk table constraints reject invalid chunk rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "chunk-constraints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    {
        var short_hash = [_]u8{0xcc} ** 31;
        var invalid_hash = try db.prepare(
            \\insert into _zova_chunks (chunk_hash, size_bytes, data)
            \\values (?, 0, ?)
        );
        defer invalid_hash.deinit();

        try invalid_hash.bindBlob(1, &short_hash);
        try invalid_hash.bindBlob(2, "");
        try std.testing.expectError(error.Constraint, invalid_hash.step());
    }

    {
        var chunk_hash = [_]u8{0xdd} ** 32;
        var invalid_size = try db.prepare(
            \\insert into _zova_chunks (chunk_hash, size_bytes, data)
            \\values (?, 5, ?)
        );
        defer invalid_size.deinit();

        try invalid_size.bindBlob(1, &chunk_hash);
        try invalid_size.bindBlob(2, "abc");
        try std.testing.expectError(error.Constraint, invalid_size.step());
    }

    {
        var chunk_hash = [_]u8{0xee} ** 32;
        var too_large_data = [_]u8{0x11} ** (fastcdc.max_size + 1);
        var too_large = try db.prepare(
            \\insert into _zova_chunks (chunk_hash, size_bytes, data)
            \\values (?, 65537, ?)
        );
        defer too_large.deinit();

        try too_large.bindBlob(1, &chunk_hash);
        try too_large.bindBlob(2, &too_large_data);
        try std.testing.expectError(error.Constraint, too_large.step());
    }
}

test "chunk table rejects null chunk hashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "null-chunk-hash.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var null_hash = try db.prepare(
        \\insert into _zova_chunks (chunk_hash, size_bytes, data)
        \\values (?, 1, ?)
    );
    defer null_hash.deinit();

    try null_hash.bindNull(1);
    try null_hash.bindBlob(2, "a");
    try std.testing.expectError(error.Constraint, null_hash.step());
}

test "chunk table rejects zero-length chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "zero-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var chunk_hash = [_]u8{0x12} ** 32;
    var zero_chunk = try db.prepare(
        \\insert into _zova_chunks (chunk_hash, size_bytes, data)
        \\values (?, 0, ?)
    );
    defer zero_chunk.deinit();

    try zero_chunk.bindBlob(1, &chunk_hash);
    try zero_chunk.bindBlob(2, "");
    try std.testing.expectError(error.Constraint, zero_chunk.step());
}

test "object manifest rejects zero-length entries and short ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-constraints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var object_id = [_]u8{0x21} ** 32;
    var chunk_hash = [_]u8{0x22} ** 32;
    var short_object_id = [_]u8{0x23} ** 31;
    var short_chunk_hash = [_]u8{0x24} ** 31;

    {
        var zero_manifest = try db.prepare(
            \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\values (?, 0, ?, 0, 0)
        );
        defer zero_manifest.deinit();

        try zero_manifest.bindBlob(1, &object_id);
        try zero_manifest.bindBlob(2, &chunk_hash);
        try std.testing.expectError(error.Constraint, zero_manifest.step());
    }

    {
        var invalid_object_id = try db.prepare(
            \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\values (?, 1, ?, 0, 1)
        );
        defer invalid_object_id.deinit();

        try invalid_object_id.bindBlob(1, &short_object_id);
        try invalid_object_id.bindBlob(2, &chunk_hash);
        try std.testing.expectError(error.Constraint, invalid_object_id.step());
    }

    {
        var invalid_chunk_hash = try db.prepare(
            \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\values (?, 2, ?, 0, 1)
        );
        defer invalid_chunk_hash.deinit();

        try invalid_chunk_hash.bindBlob(1, &object_id);
        try invalid_chunk_hash.bindBlob(2, &short_chunk_hash);
        try std.testing.expectError(error.Constraint, invalid_chunk_hash.step());
    }
}

test "object schema accepts empty object row without chunks or manifest rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "empty-object-schema.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var empty_object_id = objectId("");

    {
        var object = try db.prepare(
            \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
            \\values (?, 0, 0, 'fastcdc-v1')
        );
        defer object.deinit();

        try object.bindBlob(1, &empty_object_id);
        try std.testing.expectEqual(sqlite.Step.done, try object.step());
    }

    var chunks = try db.prepare("select count(*) from _zova_chunks");
    defer chunks.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try chunks.step());
    try std.testing.expectEqual(@as(i64, 0), chunks.columnInt64(0));

    var manifest = try db.prepare("select count(*) from _zova_object_chunks");
    defer manifest.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try manifest.step());
    try std.testing.expectEqual(@as(i64, 0), manifest.columnInt64(0));
}

test "object schema accepts minimal valid object chunk and manifest rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "valid-object-schema.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var object_id = [_]u8{0x01} ** 32;
    var chunk_hash = [_]u8{0x02} ** 32;

    {
        var chunk = try db.prepare(
            \\insert into _zova_chunks (chunk_hash, size_bytes, data)
            \\values (?, 3, ?)
        );
        defer chunk.deinit();

        try chunk.bindBlob(1, &chunk_hash);
        try chunk.bindBlob(2, "abc");
        try std.testing.expectEqual(sqlite.Step.done, try chunk.step());
    }

    {
        var object = try db.prepare(
            \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
            \\values (?, 3, 1, 'fastcdc-v1')
        );
        defer object.deinit();

        try object.bindBlob(1, &object_id);
        try std.testing.expectEqual(sqlite.Step.done, try object.step());
    }

    {
        var manifest = try db.prepare(
            \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\values (?, 0, ?, 0, 3)
        );
        defer manifest.deinit();

        try manifest.bindBlob(1, &object_id);
        try manifest.bindBlob(2, &chunk_hash);
        try std.testing.expectEqual(sqlite.Step.done, try manifest.step());
    }

    var count = try db.prepare("select count(*) from _zova_object_chunks");
    defer count.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}
test "delete empty object removes only object row and lookup APIs report missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-empty.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("");
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_object_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_object_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "delete one chunk object removes object manifest and unreferenced chunk rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-one-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("one chunk");
    try std.testing.expectEqual(@as(u64, 1), try db.objectChunkCount(id));
    try std.testing.expectEqual(@as(i64, 1), try testingObjectManifestCount(&db, id));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "delete multi chunk object removes manifests and unreferenced chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-multi-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var bytes: [fastcdc.max_size + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 19 + index / 5 + 3) % 253);
    }

    const id = try db.putObject(&bytes);
    const chunk_count = try db.objectChunkCount(id);
    try std.testing.expect(chunk_count > 1);

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "delete preserves chunks shared by another object and later removes them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-shared-chunks.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const base = [_]u8{0} ** (fastcdc.max_size * 4);
    var edited: [base.len + 257]u8 = undefined;
    for (edited[0..257], 0..) |*byte, index| {
        byte.* = @intCast((index * 29 + 7) % 251);
    }
    @memcpy(edited[257..], &base);

    const base_id = try db.putObject(&base);
    const edited_id = try db.putObject(&edited);
    const shared_count = try testingSharedChunkCount(&db, base_id, edited_id);
    try std.testing.expect(shared_count > 0);

    try db.deleteObject(base_id);
    try testingExpectObjectMissing(&db, base_id);
    try std.testing.expect(try db.hasObject(edited_id));

    var edited_object = try db.getObject(std.testing.allocator, edited_id);
    defer edited_object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &edited, edited_object.bytes);
    var edited_range: [64]u8 = undefined;
    try std.testing.expectEqual(edited_range.len, try db.readObjectRange(edited_id, 257, &edited_range));
    try std.testing.expectEqualSlices(u8, edited[257 .. 257 + edited_range.len], &edited_range);
    const remaining_chunk_rows = try testingCount(&db, "select count(*) from _zova_chunks");
    try std.testing.expect(remaining_chunk_rows > 0);
    try std.testing.expect(remaining_chunk_rows <= @as(i64, @intCast(try db.objectChunkCount(edited_id))));

    try db.deleteObject(edited_id);
    try testingExpectObjectMissing(&db, edited_id);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "delete repeated content object handles duplicate candidate chunk hashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-duplicate-candidates.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = [_]u8{0} ** (fastcdc.max_size * 4);
    const id = try db.putObject(&bytes);
    try std.testing.expect((try testingObjectManifestCount(&db, id)) > try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "delete corrupt object with missing chunk data still cleans object and manifest rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-corrupt-missing-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("missing chunk during delete");
    try db.exec("delete from _zova_chunks");
    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
}

test "failed delete rolls back visible changes and keeps connection usable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-rollback.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("rollback delete");
    try db.exec(
        \\create trigger force_chunk_delete_failure
        \\before delete on _zova_chunks
        \\begin
        \\  select raise(abort, 'forced chunk delete failure');
        \\end;
    );

    try std.testing.expectError(error.Constraint, db.deleteObject(id));

    try std.testing.expect(try db.hasObject(id));
    try std.testing.expectEqual(@as(i64, 1), try testingObjectManifestCount(&db, id));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.exec("drop trigger force_chunk_delete_failure");

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "rollback delete", object.bytes);

    const later_id = try db.putObject("later put after failed delete");
    try std.testing.expect(try db.hasObject(later_id));

    try db.deleteObject(id);
    try testingExpectObjectMissing(&db, id);
}
