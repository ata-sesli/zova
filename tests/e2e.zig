const std = @import("std");
const zova = @import("zova");

test "e2e app database stores relational rows and native objects across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "app.zova");

    const large = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(large);
    fillDeterministic(large);

    const binary = [_]u8{ 0x00, 0x01, 0x02, 0xff, 0x00, 0x7f, 0x80 };

    const empty_id, const small_id, const duplicate_id, const binary_id, const large_id = ids: {
        var db = try zova.Database.create(db_path);
        defer db.deinit();

        try db.exec(
            \\create table attachments (
            \\  id integer primary key,
            \\  object_id blob not null,
            \\  filename text not null,
            \\  mime_type text not null,
            \\  size_bytes integer not null
            \\);
            \\create table chunks (
            \\  id integer primary key,
            \\  vector_id text not null,
            \\  document_id integer not null,
            \\  body text not null
            \\)
        );
        try db.createVectorCollection("chunks", .{ .dimensions = 3, .metric = .cosine });

        const empty_id = try db.putObject("");
        const small_id = try db.putObject("hello object");
        const duplicate_id = try db.putObject("hello object");
        const binary_id = try db.putObject(&binary);
        const large_id = try db.putObject(large);

        try std.testing.expectEqualSlices(u8, &small_id, &duplicate_id);
        try std.testing.expect(try db.hasObject(large_id));
        try std.testing.expectEqual(@as(u64, large.len), try db.objectSize(large_id));
        try std.testing.expect((try db.objectChunkCount(large_id)) > 1);
        try std.testing.expectEqual(@as(u64, 0), try db.objectChunkCount(empty_id));

        try insertAttachment(&db, empty_id, "empty.bin", "application/octet-stream", 0);
        try insertAttachment(&db, small_id, "hello.txt", "text/plain", "hello object".len);
        try insertAttachment(&db, duplicate_id, "hello-copy.txt", "text/plain", "hello object".len);
        try insertAttachment(&db, binary_id, "binary.bin", "application/octet-stream", binary.len);
        try insertAttachment(&db, large_id, "large.bin", "application/octet-stream", large.len);
        try insertChunkRef(&db, "chunk-1", 1, "first semantic chunk");
        try insertChunkRef(&db, "chunk-2", 1, "second semantic chunk");
        try db.putVector("chunks", "chunk-1", &.{ 1.0, 0.0, 0.0 });
        try db.putVector("chunks", "chunk-2", &.{ 0.0, 1.0, 0.0 });
        try std.testing.expect(try db.hasVectorCollection("chunks"));
        try expectQuickCheckOk(&db);
        try expectIntegrityCheckOk(&db);

        break :ids .{ empty_id, small_id, duplicate_id, binary_id, large_id };
    };

    var reopened = try zova.Database.open(db_path);
    defer reopened.deinit();

    try expectAttachmentCount(&reopened, 5);
    try expectChunkCount(&reopened, 2);
    try std.testing.expect(try reopened.hasVectorCollection("chunks"));
    try std.testing.expect(!try reopened.hasVectorCollection("missing"));
    try expectStoredVector(&reopened, "chunk-1", &.{ 1.0, 0.0, 0.0 });
    try expectStoredVector(&reopened, "chunk-2", &.{ 0.0, 1.0, 0.0 });
    try expectChunkSearchResult(&reopened, &.{ 0.9, 0.1, 0.0 }, &.{ "chunk-1", "chunk-2" }, &.{ "first semantic chunk", "second semantic chunk" });
    try expectStoredObject(&reopened, "empty.bin", empty_id, "");
    try expectStoredObject(&reopened, "hello.txt", small_id, "hello object");
    try expectStoredObject(&reopened, "hello-copy.txt", duplicate_id, "hello object");
    try expectStoredObject(&reopened, "binary.bin", binary_id, &binary);
    try expectStoredObject(&reopened, "large.bin", large_id, large);
    try expectStoredObjectRange(&reopened, "large.bin", large_id, large);
    try expectObjectChunksReassemble(&reopened, large_id, large);

    try reopened.putVector("chunks", "chunk-1", &.{ 0.25, 0.5, 0.75 });
    try expectStoredVector(&reopened, "chunk-1", &.{ 0.25, 0.5, 0.75 });
    try expectChunkSearchResult(&reopened, &.{ 0.25, 0.5, 0.75 }, &.{ "chunk-1", "chunk-2" }, &.{ "first semantic chunk", "second semantic chunk" });
    try reopened.deleteVector("chunks", "chunk-2");
    try expectMissingVectorRef(&reopened, "second semantic chunk", "chunk-2");
    try expectChunkSearchResult(&reopened, &.{ 0.25, 0.5, 0.75 }, &.{"chunk-1"}, &.{"first semantic chunk"});

    try reopened.deleteObject(binary_id);
    try expectAttachmentCount(&reopened, 5);
    try expectDeletedAttachmentObject(&reopened, "binary.bin", binary_id);
    try deleteAttachment(&reopened, "binary.bin");
    try expectAttachmentCount(&reopened, 4);
    try expectStoredObject(&reopened, "large.bin", large_id, large);

    try reopened.deleteObject(small_id);
    try expectAttachmentCount(&reopened, 4);
    try expectDeletedAttachmentObject(&reopened, "hello.txt", small_id);
    try expectDeletedAttachmentObject(&reopened, "hello-copy.txt", duplicate_id);

    const recreated_id = try reopened.putObject("hello object");
    try std.testing.expectEqualSlices(u8, &small_id, &recreated_id);
    try expectStoredObject(&reopened, "hello.txt", recreated_id, "hello object");
    try expectStoredObject(&reopened, "hello-copy.txt", duplicate_id, "hello object");
    try expectQuickCheckOk(&reopened);
    try expectIntegrityCheckOk(&reopened);
}

test "e2e converted sqlite database preserves sql data and accepts new objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "converted.zova");
    const alpha_payload = [_]u8{ 0x10, 0x00, 0x20, 0x30 };
    const beta_payload = [_]u8{ 0xaa, 0xbb, 0x00, 0xcc, 0xdd };

    {
        var source = try zova.sqlite.Database.open(source_path);
        defer source.deinit();

        try source.exec(
            \\create table files (
            \\  id integer primary key,
            \\  name text not null,
            \\  payload blob not null
            \\);
            \\create index files_name_idx on files(name);
            \\create view file_payloads as
            \\  select id, name, length(payload) as payload_len from files;
            \\create table audit (
            \\  file_id integer not null,
            \\  action text not null
            \\);
            \\create trigger files_ai after insert on files begin
            \\  insert into audit (file_id, action) values (new.id, 'insert');
            \\end;
        );

        try insertFile(&source, "alpha", &alpha_payload);
        try insertFile(&source, "beta", &beta_payload);
        try expectQuickCheckOk(&source);
    }

    try zova.convertSqliteToZova(source_path, dest_path);

    {
        var source = try zova.sqlite.Database.open(source_path);
        defer source.deinit();
        try expectSqliteMasterCount(&source, "_zova_meta", 0);
        try expectCount(&source, "select count(*) from files", 2);
        try expectCount(&source, "select count(*) from audit", 2);
    }

    const converted_object_id = id: {
        var db = try zova.Database.open(dest_path);
        defer db.deinit();

        try expectCount(&db, "select count(*) from files", 2);
        try expectCount(&db, "select count(*) from audit", 2);
        try expectFilePayload(&db, "alpha", &alpha_payload);
        try expectFilePayload(&db, "beta", &beta_payload);
        try expectViewPayloadLength(&db, "beta", beta_payload.len);

        const gamma_payload = [_]u8{ 0x44, 0x55, 0x66 };
        try insertFile(&db, "gamma", &gamma_payload);
        try expectCount(&db, "select count(*) from audit", 3);

        try db.exec(
            \\create table object_refs (
            \\  id integer primary key,
            \\  object_id blob not null,
            \\  label text not null
            \\);
            \\create table search_rows (
            \\  id integer primary key,
            \\  vector_id text not null,
            \\  body text not null
            \\)
        );
        try db.createVectorCollection("search_rows", .{ .dimensions = 3, .metric = .l2 });

        const object_id = try db.putObject("converted object bytes");
        try insertObjectRef(&db, object_id, "converted");
        try insertSearchRow(&db, "converted-row-1", "converted sql row");
        try db.putVector("search_rows", "converted-row-1", &.{ 1.0, 2.0, 3.0 });
        try std.testing.expect(try db.hasVectorCollection("search_rows"));
        try expectQuickCheckOk(&db);
        try expectIntegrityCheckOk(&db);
        break :id object_id;
    };

    var reopened = try zova.Database.open(dest_path);
    defer reopened.deinit();

    try expectCount(&reopened, "select count(*) from files", 3);
    try expectCount(&reopened, "select count(*) from audit", 3);
    try expectCount(&reopened, "select count(*) from search_rows", 1);
    try std.testing.expect(try reopened.hasVectorCollection("search_rows"));
    try expectStoredSearchVector(&reopened, "converted-row-1", &.{ 1.0, 2.0, 3.0 });
    try expectConvertedSearchResult(&reopened, &.{ 1.0, 2.0, 3.0 }, &.{"converted-row-1"}, &.{"converted sql row"});
    try expectObjectRef(&reopened, "converted", converted_object_id, "converted object bytes");
    try expectObjectRefRange(&reopened, "converted", converted_object_id, "converted object bytes");
    try expectObjectChunksReassemble(&reopened, converted_object_id, "converted object bytes");

    try reopened.putVector("search_rows", "converted-row-1", &.{ 3.0, 2.0, 1.0 });
    try expectStoredSearchVector(&reopened, "converted-row-1", &.{ 3.0, 2.0, 1.0 });
    try expectConvertedSearchResult(&reopened, &.{ 3.0, 2.0, 1.0 }, &.{"converted-row-1"}, &.{"converted sql row"});
    try reopened.deleteVector("search_rows", "converted-row-1");
    try expectMissingSearchVectorRef(&reopened, "converted-row-1");
    try reopened.deleteObject(converted_object_id);
    try expectCount(&reopened, "select count(*) from files", 3);
    try expectCount(&reopened, "select count(*) from audit", 3);
    try expectFilePayload(&reopened, "alpha", &alpha_payload);
    try expectFilePayload(&reopened, "beta", &beta_payload);
    try expectViewPayloadLength(&reopened, "beta", beta_payload.len);
    try expectDeletedObjectRef(&reopened, "converted", converted_object_id);
    try expectQuickCheckOk(&reopened);
    try expectIntegrityCheckOk(&reopened);
}

test "e2e two connections keep sqlite locking and later recover" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "two-connections.zova");

    var first = try zova.Database.create(db_path);
    defer first.deinit();
    try first.exec("create table notes (id integer primary key, body text not null)");
    try first.createVectorCollection("notes", .{ .dimensions = 2, .metric = .dot });

    var second = try zova.Database.open(db_path);
    defer second.deinit();

    try first.exec("begin immediate");
    try first.exec("insert into notes (body) values ('held')");
    try first.putVector("notes", "held", &.{ 1.0, 1.0 });
    try std.testing.expectError(error.ObjectTransactionActive, first.putObject("same connection"));
    try std.testing.expectError(error.Busy, second.putObject("second connection"));
    try std.testing.expectError(error.Busy, second.putVector("notes", "blocked", &.{ 2.0, 2.0 }));
    try first.exec("rollback");

    const id = try second.putObject("after lock");
    try std.testing.expect(try second.hasObject(id));
    try second.putVector("notes", "after-lock", &.{ 2.0, 2.0 });
    try std.testing.expect(try second.hasVector("notes", "after-lock"));

    const delete_id = try second.putObject("delete after lock");
    try second.putVector("notes", "delete-after-lock", &.{ 3.0, 3.0 });
    try first.exec("begin immediate");
    try std.testing.expectError(error.Busy, second.deleteObject(delete_id));
    try std.testing.expectError(error.Busy, second.deleteVector("notes", "delete-after-lock"));
    try first.exec("rollback");

    try second.deleteObject(delete_id);
    try std.testing.expectError(error.ObjectNotFound, second.getObject(std.testing.allocator, delete_id));
    try second.deleteVector("notes", "delete-after-lock");
    try std.testing.expectError(error.VectorNotFound, second.getVector(std.testing.allocator, "notes", "delete-after-lock"));
    try expectQuickCheckOk(&second);
    try expectIntegrityCheckOk(&second);
}

fn testingDbPath(buffer: []u8, sub_path: []const u8, filename: []const u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buffer, ".zig-cache/tmp/{s}/{s}", .{ sub_path, filename });
}

fn fillDeterministic(bytes: []u8) void {
    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 31 + index / 7 + 11) % 256);
    }
}

fn insertAttachment(db: *zova.Database, id: zova.ObjectId, filename: []const u8, mime_type: []const u8, size_bytes: usize) !void {
    var stmt = try db.prepare(
        \\insert into attachments (object_id, filename, mime_type, size_bytes)
        \\values (?, ?, ?, ?)
    );
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    try stmt.bindText(2, filename);
    try stmt.bindText(3, mime_type);
    try stmt.bindInt64(4, @intCast(size_bytes));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn deleteAttachment(db: *zova.Database, filename: []const u8) !void {
    var stmt = try db.prepare("delete from attachments where filename = ?");
    defer stmt.deinit();

    try stmt.bindText(1, filename);
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn insertChunkRef(db: *zova.Database, vector_id: []const u8, document_id: i64, body: []const u8) !void {
    var stmt = try db.prepare("insert into chunks (vector_id, document_id, body) values (?, ?, ?)");
    defer stmt.deinit();

    try stmt.bindText(1, vector_id);
    try stmt.bindInt64(2, document_id);
    try stmt.bindText(3, body);
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn insertSearchRow(db: *zova.Database, vector_id: []const u8, body: []const u8) !void {
    var stmt = try db.prepare("insert into search_rows (vector_id, body) values (?, ?)");
    defer stmt.deinit();

    try stmt.bindText(1, vector_id);
    try stmt.bindText(2, body);
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn insertFile(db: anytype, name: []const u8, payload: []const u8) !void {
    var stmt = try db.prepare("insert into files (name, payload) values (?, ?)");
    defer stmt.deinit();

    try stmt.bindText(1, name);
    try stmt.bindBlob(2, payload);
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn insertObjectRef(db: *zova.Database, id: zova.ObjectId, label: []const u8) !void {
    var stmt = try db.prepare("insert into object_refs (object_id, label) values (?, ?)");
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    try stmt.bindText(2, label);
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectStoredObject(db: *zova.Database, filename: []const u8, expected_id: zova.ObjectId, expected_bytes: []const u8) !void {
    const id = try loadObjectIdByFilename(db, filename);
    try std.testing.expectEqualSlices(u8, &expected_id, &id);

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, expected_bytes, object.bytes);
    try std.testing.expectEqual(@as(u64, expected_bytes.len), try db.objectSize(id));
}

fn expectStoredObjectRange(db: *zova.Database, filename: []const u8, expected_id: zova.ObjectId, expected_bytes: []const u8) !void {
    const id = try loadObjectIdByFilename(db, filename);
    try std.testing.expectEqualSlices(u8, &expected_id, &id);
    try std.testing.expectEqual(@as(u64, expected_bytes.len), try db.objectSize(id));
    try expectObjectRangeBytes(db, id, expected_bytes);
}

fn expectObjectRef(db: *zova.Database, label: []const u8, expected_id: zova.ObjectId, expected_bytes: []const u8) !void {
    var stmt = try db.prepare("select object_id from object_refs where label = ?");
    defer stmt.deinit();

    try stmt.bindText(1, label);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    const id = try objectIdFromColumn(&stmt, 0);
    try std.testing.expectEqualSlices(u8, &expected_id, &id);
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, expected_bytes, object.bytes);
}

fn expectObjectRefRange(db: *zova.Database, label: []const u8, expected_id: zova.ObjectId, expected_bytes: []const u8) !void {
    var stmt = try db.prepare("select object_id from object_refs where label = ?");
    defer stmt.deinit();

    try stmt.bindText(1, label);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    const id = try objectIdFromColumn(&stmt, 0);
    try std.testing.expectEqualSlices(u8, &expected_id, &id);
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());

    try expectObjectRangeBytes(db, id, expected_bytes);
}

fn expectObjectRangeBytes(db: *zova.Database, id: zova.ObjectId, expected_bytes: []const u8) !void {
    const full = try std.testing.allocator.alloc(u8, expected_bytes.len);
    defer std.testing.allocator.free(full);

    try std.testing.expectEqual(expected_bytes.len, try db.readObjectRange(id, 0, full));
    try std.testing.expectEqualSlices(u8, expected_bytes, full);

    if (expected_bytes.len == 0) return;

    var preview: [32]u8 = undefined;
    const preview_len = @min(preview.len, expected_bytes.len);
    try std.testing.expectEqual(preview_len, try db.readObjectRange(id, 0, preview[0..preview_len]));
    try std.testing.expectEqualSlices(u8, expected_bytes[0..preview_len], preview[0..preview_len]);

    var tail: [16]u8 = undefined;
    const tail_offset = if (expected_bytes.len > tail.len) expected_bytes.len - tail.len else 0;
    const tail_len = expected_bytes.len - tail_offset;
    try std.testing.expectEqual(tail_len, try db.readObjectRange(id, tail_offset, tail[0..tail_len]));
    try std.testing.expectEqualSlices(u8, expected_bytes[tail_offset..], tail[0..tail_len]);
}

fn expectObjectChunksReassemble(db: *zova.Database, id: zova.ObjectId, expected_bytes: []const u8) !void {
    var manifest = try db.objectManifest(std.testing.allocator, id);
    defer manifest.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &manifest.object_id);
    try std.testing.expectEqual(@as(u64, expected_bytes.len), manifest.size_bytes);
    try std.testing.expectEqual(try db.objectChunkCount(id), manifest.chunk_count);
    try std.testing.expectEqual(@as(usize, @intCast(manifest.chunk_count)), manifest.chunks.len);

    var rebuilt = try std.testing.allocator.alloc(u8, expected_bytes.len);
    defer std.testing.allocator.free(rebuilt);

    for (manifest.chunks) |chunk| {
        try std.testing.expect(try db.hasObjectChunk(chunk.hash));

        var chunk_data = try db.getObjectChunk(std.testing.allocator, chunk.hash);
        defer chunk_data.deinit(std.testing.allocator);

        try std.testing.expectEqualSlices(u8, &chunk.hash, &chunk_data.hash);
        try std.testing.expectEqual(@as(usize, @intCast(chunk.size_bytes)), chunk_data.bytes.len);
        const start: usize = @intCast(chunk.offset);
        @memcpy(rebuilt[start .. start + chunk_data.bytes.len], chunk_data.bytes);
    }

    try std.testing.expectEqualSlices(u8, expected_bytes, rebuilt);
}

fn expectDeletedAttachmentObject(db: *zova.Database, filename: []const u8, expected_id: zova.ObjectId) !void {
    const id = try loadObjectIdByFilename(db, filename);
    try std.testing.expectEqualSlices(u8, &expected_id, &id);
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, id));
    try std.testing.expectError(error.ObjectNotFound, db.objectSize(id));
}

fn expectDeletedObjectRef(db: *zova.Database, label: []const u8, expected_id: zova.ObjectId) !void {
    var stmt = try db.prepare("select object_id from object_refs where label = ?");
    defer stmt.deinit();

    try stmt.bindText(1, label);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    const id = try objectIdFromColumn(&stmt, 0);
    try std.testing.expectEqualSlices(u8, &expected_id, &id);
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());

    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, id));
}

fn expectStoredVector(db: *zova.Database, vector_id: []const u8, expected: []const f32) !void {
    var vector = try db.getVector(std.testing.allocator, "chunks", vector_id);
    defer vector.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(vector_id, vector.id);
    try std.testing.expectEqualSlices(f32, expected, vector.values);
}

fn expectStoredSearchVector(db: *zova.Database, vector_id: []const u8, expected: []const f32) !void {
    var vector = try db.getVector(std.testing.allocator, "search_rows", vector_id);
    defer vector.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(vector_id, vector.id);
    try std.testing.expectEqualSlices(f32, expected, vector.values);
}

fn expectChunkSearchResult(
    db: *zova.Database,
    query: []const f32,
    expected_ids: []const []const u8,
    expected_bodies: []const []const u8,
) !void {
    var results = try db.searchVectors(std.testing.allocator, "chunks", query, expected_ids.len);
    defer results.deinit(std.testing.allocator);
    try expectSearchIds(&results, expected_ids);

    for (results.items, expected_bodies) |result, expected_body| {
        try expectChunkBodyForVectorId(db, result.id, expected_body);
    }
}

fn expectConvertedSearchResult(
    db: *zova.Database,
    query: []const f32,
    expected_ids: []const []const u8,
    expected_bodies: []const []const u8,
) !void {
    var results = try db.searchVectors(std.testing.allocator, "search_rows", query, expected_ids.len);
    defer results.deinit(std.testing.allocator);
    try expectSearchIds(&results, expected_ids);

    for (results.items, expected_bodies) |result, expected_body| {
        try expectSearchRowBodyForVectorId(db, result.id, expected_body);
    }
}

fn expectSearchIds(results: *const zova.VectorSearchResults, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, results.items.len);
    for (expected, 0..) |expected_id, index| {
        try std.testing.expectEqualStrings(expected_id, results.items[index].id);
    }
}

fn expectChunkBodyForVectorId(db: *zova.Database, vector_id: []const u8, expected_body: []const u8) !void {
    var stmt = try db.prepare("select body from chunks where vector_id = ?");
    defer stmt.deinit();

    try stmt.bindText(1, vector_id);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings(expected_body, stmt.columnText(0));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectSearchRowBodyForVectorId(db: *zova.Database, vector_id: []const u8, expected_body: []const u8) !void {
    var stmt = try db.prepare("select body from search_rows where vector_id = ?");
    defer stmt.deinit();

    try stmt.bindText(1, vector_id);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings(expected_body, stmt.columnText(0));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectMissingVectorRef(db: *zova.Database, body: []const u8, expected_vector_id: []const u8) !void {
    var stmt = try db.prepare("select vector_id from chunks where body = ?");
    defer stmt.deinit();

    try stmt.bindText(1, body);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    const vector_id = stmt.columnText(0);
    try std.testing.expectEqualStrings(expected_vector_id, vector_id);
    try std.testing.expectError(error.VectorNotFound, db.getVector(std.testing.allocator, "chunks", vector_id));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectMissingSearchVectorRef(db: *zova.Database, expected_vector_id: []const u8) !void {
    var stmt = try db.prepare("select vector_id from search_rows where vector_id = ?");
    defer stmt.deinit();

    try stmt.bindText(1, expected_vector_id);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    const vector_id = stmt.columnText(0);
    try std.testing.expectEqualStrings(expected_vector_id, vector_id);
    try std.testing.expectError(error.VectorNotFound, db.getVector(std.testing.allocator, "search_rows", vector_id));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn loadObjectIdByFilename(db: *zova.Database, filename: []const u8) !zova.ObjectId {
    var stmt = try db.prepare("select object_id from attachments where filename = ?");
    defer stmt.deinit();

    try stmt.bindText(1, filename);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    const id = try objectIdFromColumn(&stmt, 0);
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
    return id;
}

fn objectIdFromColumn(stmt: *zova.sqlite.Statement, index: c_int) !zova.ObjectId {
    const blob = stmt.columnBlob(index);
    try std.testing.expectEqual(@sizeOf(zova.ObjectId), blob.len);
    var id: zova.ObjectId = undefined;
    @memcpy(&id, blob);
    return id;
}

fn expectAttachmentCount(db: *zova.Database, expected: i64) !void {
    try expectCount(db, "select count(*) from attachments", expected);
}

fn expectChunkCount(db: *zova.Database, expected: i64) !void {
    try expectCount(db, "select count(*) from chunks", expected);
}

fn expectCount(db: anytype, sql: [:0]const u8, expected: i64) !void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqual(expected, stmt.columnInt64(0));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectSqliteMasterCount(db: *zova.sqlite.Database, name: []const u8, expected: i64) !void {
    var stmt = try db.prepare("select count(*) from sqlite_master where name = ?");
    defer stmt.deinit();

    try stmt.bindText(1, name);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqual(expected, stmt.columnInt64(0));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectFilePayload(db: *zova.Database, name: []const u8, expected: []const u8) !void {
    var stmt = try db.prepare("select payload from files where name = ?");
    defer stmt.deinit();

    try stmt.bindText(1, name);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualSlices(u8, expected, stmt.columnBlob(0));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectViewPayloadLength(db: *zova.Database, name: []const u8, expected: usize) !void {
    var stmt = try db.prepare("select payload_len from file_payloads where name = ?");
    defer stmt.deinit();

    try stmt.bindText(1, name);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqual(@as(i64, @intCast(expected)), stmt.columnInt64(0));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectQuickCheckOk(db: anytype) !void {
    var stmt = try db.prepare("pragma quick_check");
    defer stmt.deinit();

    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("ok", stmt.columnText(0));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectIntegrityCheckOk(db: anytype) !void {
    var stmt = try db.prepare("pragma integrity_check");
    defer stmt.deinit();

    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("ok", stmt.columnText(0));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}
