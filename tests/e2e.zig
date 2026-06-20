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

    const streamed = try std.testing.allocator.alloc(u8, 768 * 1024);
    defer std.testing.allocator.free(streamed);
    fillDeterministic(streamed);
    streamed[0] ^= 0xaa;

    const cancelled = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(cancelled);
    fillDeterministic(cancelled);
    cancelled[0] ^= 0x55;

    const binary = [_]u8{ 0x00, 0x01, 0x02, 0xff, 0x00, 0x7f, 0x80 };

    const empty_id, const small_id, const duplicate_id, const binary_id, const large_id, const streamed_id = ids: {
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
        const streamed_id = try streamObject(&db, streamed, &.{ 17, 65_537, 3, 4096 });

        {
            var cancelled_writer = try db.objectWriter(std.testing.allocator);
            defer cancelled_writer.deinit();
            try cancelled_writer.write(cancelled);
            try cancelled_writer.cancel();
        }
        try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, zova.objectId(cancelled)));

        try std.testing.expectEqualSlices(u8, &small_id, &duplicate_id);
        try std.testing.expectEqualSlices(u8, &zova.objectId(streamed), &streamed_id);
        try std.testing.expect(try db.hasObject(large_id));
        try std.testing.expectEqual(@as(u64, large.len), try db.objectSize(large_id));
        try std.testing.expect((try db.objectChunkCount(large_id)) > 1);
        try std.testing.expectEqual(@as(u64, 0), try db.objectChunkCount(empty_id));

        try insertAttachment(&db, empty_id, "empty.bin", "application/octet-stream", 0);
        try insertAttachment(&db, small_id, "hello.txt", "text/plain", "hello object".len);
        try insertAttachment(&db, duplicate_id, "hello-copy.txt", "text/plain", "hello object".len);
        try insertAttachment(&db, binary_id, "binary.bin", "application/octet-stream", binary.len);
        try insertAttachment(&db, large_id, "large.bin", "application/octet-stream", large.len);
        try insertAttachment(&db, streamed_id, "streamed.bin", "application/octet-stream", streamed.len);
        try insertChunkRef(&db, "chunk-1", 1, "first semantic chunk");
        try insertChunkRef(&db, "chunk-2", 1, "second semantic chunk");
        try db.putVector("chunks", "chunk-1", &.{ 1.0, 0.0, 0.0 });
        try db.putVector("chunks", "chunk-2", &.{ 0.0, 1.0, 0.0 });
        try std.testing.expect(try db.hasVectorCollection("chunks"));
        try expectQuickCheckOk(&db);
        try expectIntegrityCheckOk(&db);

        break :ids .{ empty_id, small_id, duplicate_id, binary_id, large_id, streamed_id };
    };

    var reopened = try zova.Database.open(db_path);
    defer reopened.deinit();

    try expectAttachmentCount(&reopened, 6);
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
    try expectStoredObject(&reopened, "streamed.bin", streamed_id, streamed);
    try expectStoredObjectRange(&reopened, "large.bin", large_id, large);
    try expectStoredObjectRange(&reopened, "streamed.bin", streamed_id, streamed);
    try expectObjectChunksReassemble(&reopened, large_id, large);
    try expectObjectChunksReassemble(&reopened, streamed_id, streamed);

    try reopened.putVector("chunks", "chunk-1", &.{ 0.25, 0.5, 0.75 });
    try expectStoredVector(&reopened, "chunk-1", &.{ 0.25, 0.5, 0.75 });
    try expectChunkSearchResult(&reopened, &.{ 0.25, 0.5, 0.75 }, &.{ "chunk-1", "chunk-2" }, &.{ "first semantic chunk", "second semantic chunk" });
    try reopened.deleteVector("chunks", "chunk-2");
    try expectMissingVectorRef(&reopened, "second semantic chunk", "chunk-2");
    try expectChunkSearchResult(&reopened, &.{ 0.25, 0.5, 0.75 }, &.{"chunk-1"}, &.{"first semantic chunk"});

    try reopened.deleteObject(binary_id);
    try expectAttachmentCount(&reopened, 6);
    try expectDeletedAttachmentObject(&reopened, "binary.bin", binary_id);
    try deleteAttachment(&reopened, "binary.bin");
    try expectAttachmentCount(&reopened, 5);
    try expectStoredObject(&reopened, "large.bin", large_id, large);

    try reopened.deleteObject(small_id);
    try expectAttachmentCount(&reopened, 5);
    try expectDeletedAttachmentObject(&reopened, "hello.txt", small_id);
    try expectDeletedAttachmentObject(&reopened, "hello-copy.txt", duplicate_id);

    const recreated_id = try reopened.putObject("hello object");
    try std.testing.expectEqualSlices(u8, &small_id, &recreated_id);
    try expectStoredObject(&reopened, "hello.txt", recreated_id, "hello object");
    try expectStoredObject(&reopened, "hello-copy.txt", duplicate_id, "hello object");

    try reopened.deleteObject(streamed_id);
    try expectAttachmentCount(&reopened, 5);
    try expectDeletedAttachmentObject(&reopened, "streamed.bin", streamed_id);
    try expectStoredObject(&reopened, "large.bin", large_id, large);

    try expectQuickCheckOk(&reopened);
    try expectIntegrityCheckOk(&reopened);
}

test "e2e receiver stores verified loose chunks with app-owned transfer state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "receiver.zova");

    const bytes = "received transfer chunk";
    const hash = zova.objectChunkId(bytes);

    {
        var db = try zova.Database.create(db_path);
        defer db.deinit();

        try db.exec(
            \\create table incoming_chunks (
            \\  transfer_id text not null,
            \\  chunk_hash blob not null,
            \\  state text not null,
            \\  primary key (transfer_id, chunk_hash)
            \\)
        );

        try db.putObjectChunk(hash, bytes);
        try db.putObjectChunk(hash, bytes);
        try insertIncomingChunk(&db, "transfer-1", hash, "received");

        try expectIncomingChunk(&db, "transfer-1", hash, "received");
        try expectLooseChunk(&db, hash, bytes);
        try expectCount(&db, "select count(*) from _zova_chunks", 1);
        try expectCount(&db, "select count(*) from _zova_objects", 0);
        try expectCount(&db, "select count(*) from _zova_object_chunks", 0);
        try expectQuickCheckOk(&db);
        try expectIntegrityCheckOk(&db);
    }

    var reopened = try zova.Database.open(db_path);
    defer reopened.deinit();

    try expectIncomingChunk(&reopened, "transfer-1", hash, "received");
    try expectLooseChunk(&reopened, hash, bytes);
    try expectCount(&reopened, "select count(*) from _zova_chunks", 1);
    try expectCount(&reopened, "select count(*) from _zova_objects", 0);
    try expectCount(&reopened, "select count(*) from _zova_object_chunks", 0);
    try expectQuickCheckOk(&reopened);
    try expectIntegrityCheckOk(&reopened);
}

test "e2e receiver assembles object from shuffled verified chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var sender_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var receiver_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sender_path = try testingDbPath(&sender_buffer, tmp.sub_path[0..], "sender.zova");
    const receiver_path = try testingDbPath(&receiver_buffer, tmp.sub_path[0..], "receiver-assembly.zova");

    const payload = try std.testing.allocator.alloc(u8, 192 * 1024);
    defer std.testing.allocator.free(payload);
    fillDeterministic(payload);

    var sender = try zova.Database.create(sender_path);
    defer sender.deinit();
    const object_id = try sender.putObject(payload);
    var sender_manifest = try sender.objectManifest(std.testing.allocator, object_id);
    defer sender_manifest.deinit(std.testing.allocator);
    try std.testing.expect(sender_manifest.chunks.len > 1);

    var receiver = try zova.Database.create(receiver_path);
    defer receiver.deinit();
    try receiver.exec(
        \\create table incoming_chunks (
        \\  transfer_id text not null,
        \\  chunk_hash blob not null,
        \\  state text not null,
        \\  primary key (transfer_id, chunk_hash)
        \\);
        \\create table transfers (
        \\  transfer_id text primary key,
        \\  object_id blob not null,
        \\  state text not null
        \\)
    );

    try std.testing.expectError(
        error.ObjectChunkNotFound,
        receiver.assembleObjectFromChunks(object_id, payload.len, sender_manifest.chunks),
    );

    const shuffled = try std.testing.allocator.dupe(zova.ObjectChunk, sender_manifest.chunks);
    defer std.testing.allocator.free(shuffled);
    std.mem.reverse(zova.ObjectChunk, shuffled);

    for (shuffled[0 .. shuffled.len - 1]) |chunk| {
        const start: usize = @intCast(chunk.offset);
        const end = start + @as(usize, @intCast(chunk.size_bytes));
        try receiver.putObjectChunk(chunk.hash, payload[start..end]);
        try insertIncomingChunk(&receiver, "transfer-assembly", chunk.hash, "received");
    }

    const duplicate = shuffled[0];
    const duplicate_start: usize = @intCast(duplicate.offset);
    const duplicate_end = duplicate_start + @as(usize, @intCast(duplicate.size_bytes));
    try receiver.putObjectChunk(duplicate.hash, payload[duplicate_start..duplicate_end]);
    try expectPrivateChunkCountForHash(&receiver, duplicate.hash, 1);

    try std.testing.expectError(
        error.ObjectChunkNotFound,
        receiver.assembleObjectFromChunks(object_id, payload.len, sender_manifest.chunks),
    );

    const missing = shuffled[shuffled.len - 1];
    const missing_start: usize = @intCast(missing.offset);
    const missing_end = missing_start + @as(usize, @intCast(missing.size_bytes));
    try receiver.putObjectChunk(missing.hash, payload[missing_start..missing_end]);
    try insertIncomingChunk(&receiver, "transfer-assembly", missing.hash, "received");

    try receiver.assembleObjectFromChunks(object_id, payload.len, sender_manifest.chunks);
    try insertTransferObject(&receiver, "transfer-assembly", object_id, "complete");
    try expectTransferObject(&receiver, "transfer-assembly", object_id, "complete", payload);
    try expectObjectRangeBytes(&receiver, object_id, payload);
    try expectObjectChunksReassemble(&receiver, object_id, payload);

    try receiver.deleteObject(object_id);
    try expectDeletedTransferObject(&receiver, "transfer-assembly", object_id, "complete");
    try expectQuickCheckOk(&receiver);
    try expectIntegrityCheckOk(&receiver);
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
    const assembled_bytes = "converted assembled object bytes";
    const assembled_id = zova.objectId(assembled_bytes);
    const streamed_bytes = "converted streamed object bytes";

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

    const converted_object_id, const streamed_object_id = ids: {
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
        const streamed_id = try streamObject(&db, streamed_bytes, &.{ 1, 2, 8 });
        try insertObjectRef(&db, streamed_id, "streamed");
        const assembled_left = assembled_bytes[0..11];
        const assembled_right = assembled_bytes[11..];
        const assembled_left_hash = zova.objectChunkId(assembled_left);
        const assembled_right_hash = zova.objectChunkId(assembled_right);
        try db.putObjectChunk(assembled_right_hash, assembled_right);
        try db.putObjectChunk(assembled_left_hash, assembled_left);
        const assembled_manifest = [_]zova.ObjectChunk{
            .{
                .index = 0,
                .hash = assembled_left_hash,
                .offset = 0,
                .size_bytes = assembled_left.len,
            },
            .{
                .index = 1,
                .hash = assembled_right_hash,
                .offset = assembled_left.len,
                .size_bytes = assembled_right.len,
            },
        };
        try db.assembleObjectFromChunks(assembled_id, assembled_bytes.len, &assembled_manifest);
        try insertObjectRef(&db, assembled_id, "assembled");
        try insertSearchRow(&db, "converted-row-1", "converted sql row");
        try db.putVector("search_rows", "converted-row-1", &.{ 1.0, 2.0, 3.0 });
        try std.testing.expect(try db.hasVectorCollection("search_rows"));
        try expectQuickCheckOk(&db);
        try expectIntegrityCheckOk(&db);
        break :ids .{ object_id, streamed_id };
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
    try expectObjectRef(&reopened, "streamed", streamed_object_id, streamed_bytes);
    try expectObjectRefRange(&reopened, "streamed", streamed_object_id, streamed_bytes);
    try expectObjectRef(&reopened, "assembled", assembled_id, assembled_bytes);
    try expectObjectRefRange(&reopened, "assembled", assembled_id, assembled_bytes);

    try reopened.putVector("search_rows", "converted-row-1", &.{ 3.0, 2.0, 1.0 });
    try expectStoredSearchVector(&reopened, "converted-row-1", &.{ 3.0, 2.0, 1.0 });
    try expectConvertedSearchResult(&reopened, &.{ 3.0, 2.0, 1.0 }, &.{"converted-row-1"}, &.{"converted sql row"});
    try reopened.deleteVector("search_rows", "converted-row-1");
    try expectMissingSearchVectorRef(&reopened, "converted-row-1");
    try reopened.deleteObject(converted_object_id);
    try reopened.deleteObject(streamed_object_id);
    try reopened.deleteObject(assembled_id);
    try expectCount(&reopened, "select count(*) from files", 3);
    try expectCount(&reopened, "select count(*) from audit", 3);
    try expectFilePayload(&reopened, "alpha", &alpha_payload);
    try expectFilePayload(&reopened, "beta", &beta_payload);
    try expectViewPayloadLength(&reopened, "beta", beta_payload.len);
    try expectDeletedObjectRef(&reopened, "converted", converted_object_id);
    try expectDeletedObjectRef(&reopened, "streamed", streamed_object_id);
    try expectDeletedObjectRef(&reopened, "assembled", assembled_id);
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
    try std.testing.expectError(error.ObjectTransactionActive, first.objectWriter(std.testing.allocator));
    try std.testing.expectError(error.Busy, second.putObject("second connection"));
    {
        var blocked_writer = try second.objectWriter(std.testing.allocator);
        defer blocked_writer.deinit();
        try blocked_writer.write("second connection writer");
        try std.testing.expectError(error.Busy, blocked_writer.finish());
    }
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

fn streamObject(db: *zova.Database, bytes: []const u8, pieces: []const usize) !zova.ObjectId {
    var writer = try db.objectWriter(std.testing.allocator);
    defer writer.deinit();

    var offset: usize = 0;
    var piece_index: usize = 0;
    while (offset < bytes.len) {
        const requested = if (pieces.len == 0) bytes.len else pieces[piece_index % pieces.len];
        std.debug.assert(requested > 0);
        const len = @min(requested, bytes.len - offset);
        try writer.write(bytes[offset .. offset + len]);
        offset += len;
        piece_index += 1;
    }

    return try writer.finish();
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

fn insertIncomingChunk(db: *zova.Database, transfer_id: []const u8, hash: zova.ObjectChunkId, state: []const u8) !void {
    var stmt = try db.prepare("insert or ignore into incoming_chunks (transfer_id, chunk_hash, state) values (?, ?, ?)");
    defer stmt.deinit();

    try stmt.bindText(1, transfer_id);
    try stmt.bindBlob(2, &hash);
    try stmt.bindText(3, state);
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn insertTransferObject(db: *zova.Database, transfer_id: []const u8, id: zova.ObjectId, state: []const u8) !void {
    var stmt = try db.prepare("insert into transfers (transfer_id, object_id, state) values (?, ?, ?)");
    defer stmt.deinit();

    try stmt.bindText(1, transfer_id);
    try stmt.bindBlob(2, &id);
    try stmt.bindText(3, state);
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

fn expectIncomingChunk(db: *zova.Database, transfer_id: []const u8, expected_hash: zova.ObjectChunkId, expected_state: []const u8) !void {
    var stmt = try db.prepare("select chunk_hash, state from incoming_chunks where transfer_id = ?");
    defer stmt.deinit();

    try stmt.bindText(1, transfer_id);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualSlices(u8, &expected_hash, stmt.columnBlob(0));
    try std.testing.expectEqualStrings(expected_state, stmt.columnText(1));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectLooseChunk(db: *zova.Database, hash: zova.ObjectChunkId, expected_bytes: []const u8) !void {
    try std.testing.expect(try db.hasObjectChunk(hash));
    var chunk = try db.getObjectChunk(std.testing.allocator, hash);
    defer chunk.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &hash, &chunk.hash);
    try std.testing.expectEqualSlices(u8, expected_bytes, chunk.bytes);
}

fn expectPrivateChunkCountForHash(db: *zova.Database, hash: zova.ObjectChunkId, expected: i64) !void {
    var stmt = try db.prepare("select count(*) from _zova_chunks where chunk_hash = ?");
    defer stmt.deinit();

    try stmt.bindBlob(1, &hash);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqual(expected, stmt.columnInt64(0));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
}

fn expectTransferObject(
    db: *zova.Database,
    transfer_id: []const u8,
    expected_id: zova.ObjectId,
    expected_state: []const u8,
    expected_bytes: []const u8,
) !void {
    var stmt = try db.prepare("select object_id, state from transfers where transfer_id = ?");
    defer stmt.deinit();

    try stmt.bindText(1, transfer_id);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualSlices(u8, &expected_id, stmt.columnBlob(0));
    try std.testing.expectEqualStrings(expected_state, stmt.columnText(1));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());

    var object = try db.getObject(std.testing.allocator, expected_id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, expected_bytes, object.bytes);
}

fn expectDeletedTransferObject(
    db: *zova.Database,
    transfer_id: []const u8,
    expected_id: zova.ObjectId,
    expected_state: []const u8,
) !void {
    var stmt = try db.prepare("select object_id, state from transfers where transfer_id = ?");
    defer stmt.deinit();

    try stmt.bindText(1, transfer_id);
    try std.testing.expectEqual(zova.sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualSlices(u8, &expected_id, stmt.columnBlob(0));
    try std.testing.expectEqualStrings(expected_state, stmt.columnText(1));
    try std.testing.expectEqual(zova.sqlite.Step.done, try stmt.step());
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, expected_id));
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
