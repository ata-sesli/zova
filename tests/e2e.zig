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
            \\)
        );

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
        try expectQuickCheckOk(&db);

        break :ids .{ empty_id, small_id, duplicate_id, binary_id, large_id };
    };

    var reopened = try zova.Database.open(db_path);
    defer reopened.deinit();

    try expectAttachmentCount(&reopened, 5);
    try expectStoredObject(&reopened, "empty.bin", empty_id, "");
    try expectStoredObject(&reopened, "hello.txt", small_id, "hello object");
    try expectStoredObject(&reopened, "hello-copy.txt", duplicate_id, "hello object");
    try expectStoredObject(&reopened, "binary.bin", binary_id, &binary);
    try expectStoredObject(&reopened, "large.bin", large_id, large);

    try reopened.deleteObject(binary_id);
    try expectAttachmentCount(&reopened, 5);
    try expectDeletedAttachmentObject(&reopened, "binary.bin", binary_id);
    try expectStoredObject(&reopened, "large.bin", large_id, large);
    try expectQuickCheckOk(&reopened);
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
            \\)
        );

        const object_id = try db.putObject("converted object bytes");
        try insertObjectRef(&db, object_id, "converted");
        try expectQuickCheckOk(&db);
        break :id object_id;
    };

    var reopened = try zova.Database.open(dest_path);
    defer reopened.deinit();

    try expectCount(&reopened, "select count(*) from files", 3);
    try expectCount(&reopened, "select count(*) from audit", 3);
    try expectObjectRef(&reopened, "converted", converted_object_id, "converted object bytes");

    try reopened.deleteObject(converted_object_id);
    try expectCount(&reopened, "select count(*) from files", 3);
    try expectCount(&reopened, "select count(*) from audit", 3);
    try expectDeletedObjectRef(&reopened, "converted", converted_object_id);
    try expectQuickCheckOk(&reopened);
}

test "e2e two connections keep sqlite locking and later recover" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "two-connections.zova");

    var first = try zova.Database.create(db_path);
    defer first.deinit();
    try first.exec("create table notes (id integer primary key, body text not null)");

    var second = try zova.Database.open(db_path);
    defer second.deinit();

    try first.exec("begin immediate");
    try first.exec("insert into notes (body) values ('held')");
    try std.testing.expectError(error.ObjectTransactionActive, first.putObject("same connection"));
    try std.testing.expectError(error.Busy, second.putObject("second connection"));
    try first.exec("rollback");

    const id = try second.putObject("after lock");
    try std.testing.expect(try second.hasObject(id));

    const delete_id = try second.putObject("delete after lock");
    try first.exec("begin immediate");
    try std.testing.expectError(error.Busy, second.deleteObject(delete_id));
    try first.exec("rollback");

    try second.deleteObject(delete_id);
    try std.testing.expectError(error.ObjectNotFound, second.getObject(std.testing.allocator, delete_id));
    try expectQuickCheckOk(&second);
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
