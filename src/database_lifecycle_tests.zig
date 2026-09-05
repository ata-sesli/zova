//! Public-only Database behavior tests. No private implementation helpers.

const Database = @import("zova.zig").Database;
const convertSqliteToZova = @import("zova.zig").convertSqliteToZova;
const createGraphStore = @import("zova.zig").createGraphStore;
const createObjectStore = @import("zova.zig").createObjectStore;
const createVectorStore = @import("zova.zig").createVectorStore;
const restoreBackup = @import("zova.zig").restoreBackup;
const sqlite = @import("sqlite.zig");
const std = @import("std");
const testingCount = @import("zova_test_support.zig").testingCount;
const testingDbPath = @import("zova_test_support.zig").testingDbPath;

test "create initializes and open validates zova database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "identity.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();

        try db.exec("create table user_data (id integer primary key, body text not null)");
        try db.exec("insert into user_data (body) values ('hello')");
    }

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        var select = try db.prepare("select body from user_data");
        defer select.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try select.step());
        try std.testing.expectEqualStrings("hello", select.columnText(0));
    }
}

test "create options apply page size before private schema initialization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "page-size.zova");

    var db = try Database.createWithOptions(db_path, .{ .page_size = 65536 });
    defer db.deinit();

    var page_size = try db.prepare("pragma page_size");
    defer page_size.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try page_size.step());
    try std.testing.expectEqual(@as(i64, 65536), page_size.columnInt64(0));
    try std.testing.expectEqual(sqlite.Step.done, try page_size.step());
}

test "create treats memory path as the core volatile target" {
    var db = try Database.create(":memory:");
    defer db.deinit();

    try db.exec("create table memory_rows (id integer primary key, value text not null)");
    try db.exec("insert into memory_rows (value) values ('core target')");
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from memory_rows"));
}

test "in-memory databases are isolated and reclaim their data" {
    var left = try Database.createMemory();
    defer left.deinit();
    var right = try Database.createMemory();
    defer right.deinit();

    try left.exec("create table only_left (value text not null)");
    try left.exec("insert into only_left (value) values ('left only')");
    try right.exec("create table only_right (value text not null)");
    try right.exec("insert into only_right (value) values ('right only')");

    try std.testing.expectEqual(@as(i64, 1), try testingCount(&left, "select count(*) from only_left"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&right, "select count(*) from only_right"));

    // Nothing written to the left handle is visible to the right handle.
    try std.testing.expectError(error.SqliteError, right.prepare("select * from only_left"));
    try std.testing.expectError(error.SqliteError, left.prepare("select * from only_right"));
}

test "file-only operations reject the memory target explicitly" {
    try std.testing.expectError(error.NotZovaPath, Database.open(":memory:"));
    try std.testing.expectError(error.NotZovaPath, createObjectStore(":memory:"));
    try std.testing.expectError(error.NotZovaPath, createVectorStore(":memory:"));
    try std.testing.expectError(error.NotZovaPath, createGraphStore(":memory:"));
}

test "zova database rejects non zova paths" {
    try std.testing.expectError(error.NotZovaPath, Database.open("plain.db"));
    try std.testing.expectError(error.NotZovaPath, Database.create("plain.db"));
}

test "create refuses existing zova file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "existing.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expectError(error.DestinationExists, Database.create(db_path));
}

test "create maps missing parent directory to CantOpen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(
        &path_buffer,
        ".zig-cache/tmp/{s}/missing-parent/missing.zova",
        .{tmp.sub_path[0..]},
    );

    try std.testing.expectError(error.CantOpen, Database.create(db_path));
}

test "open maps inaccessible parent directory to CantOpen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(
        &path_buffer,
        ".zig-cache/tmp/{s}/missing-parent/missing.zova",
        .{tmp.sub_path[0..]},
    );

    try std.testing.expectError(error.CantOpen, Database.open(db_path));
}

test "open rejects uninitialized zova file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "plain.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try raw.exec("create table user_data (id integer primary key)");
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "convert sqlite to zova keeps extension adjacent app tables uninstalled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "extension-adjacent.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "extension-adjacent.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();

        try source.exec(
            \\create table extension_documents (
            \\  id integer primary key,
            \\  body text not null
            \\);
            \\create table zovaext_cache (
            \\  key text primary key,
            \\  value text not null
            \\);
            \\insert into extension_documents (body) values ('app owned');
            \\insert into zovaext_cache (key, value) values ('state', 'kept');
        );
    }

    try convertSqliteToZova(source_path, dest_path);

    var dest = try Database.open(dest_path);
    defer dest.deinit();

    var extensions = try dest.listExtensions(std.testing.allocator);
    defer extensions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), extensions.items.len);

    var row = try dest.prepare(
        \\select d.body, c.value
        \\from extension_documents d
        \\join zovaext_cache c on c.key = 'state'
    );
    defer row.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try row.step());
    try std.testing.expectEqualStrings("app owned", row.columnText(0));
    try std.testing.expectEqualStrings("kept", row.columnText(1));
    try std.testing.expectEqual(sqlite.Step.done, try row.step());
}

test "convert sqlite to zova preserves index view and trigger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "schema.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "schema.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();

        try source.exec(
            \\create table notes (
            \\  id integer primary key,
            \\  body text not null
            \\);
            \\create table note_log (
            \\  note_id integer not null,
            \\  body text not null
            \\);
            \\create index notes_body_idx on notes (body);
            \\create view note_bodies as select body from notes;
            \\create trigger notes_after_insert
            \\after insert on notes
            \\begin
            \\  insert into note_log (note_id, body) values (new.id, new.body);
            \\end;
            \\insert into notes (body) values ('first');
        );
    }

    try convertSqliteToZova(source_path, dest_path);

    var dest = try Database.open(dest_path);
    defer dest.deinit();

    var objects = try dest.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where name in ('notes_body_idx', 'note_bodies', 'notes_after_insert')
    );
    defer objects.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try objects.step());
    try std.testing.expectEqual(@as(i64, 3), objects.columnInt64(0));

    try dest.exec("insert into notes (body) values ('second')");

    var log = try dest.prepare("select body from note_log order by note_id");
    defer log.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try log.step());
    try std.testing.expectEqualStrings("first", log.columnText(0));
    try std.testing.expectEqual(sqlite.Step.row, try log.step());
    try std.testing.expectEqualStrings("second", log.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try log.step());
}

test "operational copy APIs reject invalid and existing destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "operations-reject-source.zova");

    var invalid_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_dest_path = try testingDbPath(&invalid_dest_buffer, tmp.sub_path[0..], "operations-reject.db");

    var existing_backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_backup_path = try testingDbPath(&existing_backup_buffer, tmp.sub_path[0..], "operations-existing-backup.zova");

    var existing_compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_compact_path = try testingDbPath(&existing_compact_buffer, tmp.sub_path[0..], "operations-existing-compact.zova");

    var existing_restore_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_restore_path = try testingDbPath(&existing_restore_buffer, tmp.sub_path[0..], "operations-existing-restore.zova");

    var missing_parent_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_parent_path = try std.fmt.bufPrintZ(&missing_parent_buffer, ".zig-cache/tmp/{s}/missing-parent/operations.zova", .{tmp.sub_path[0..]});

    {
        var db = try Database.create(source_path);
        defer db.deinit();
        _ = try db.putObject("copy me");

        try std.testing.expectError(error.NotZovaPath, db.backupTo(invalid_dest_path, .{}));
        try std.testing.expectError(error.NotZovaPath, db.compactTo(invalid_dest_path, .{}));
    }

    {
        var dest = try Database.create(existing_backup_path);
        defer dest.deinit();
    }
    {
        var dest = try Database.create(existing_compact_path);
        defer dest.deinit();
    }
    {
        var dest = try Database.create(existing_restore_path);
        defer dest.deinit();
    }

    var db = try Database.open(source_path);
    defer db.deinit();

    try std.testing.expectError(error.DestinationExists, db.backupTo(existing_backup_path, .{}));
    try std.testing.expectError(error.DestinationExists, db.compactTo(existing_compact_path, .{}));
    try std.testing.expectError(error.DestinationExists, restoreBackup(source_path, existing_restore_path, .{}));
    try std.testing.expectError(error.CantOpen, db.backupTo(missing_parent_path, .{}));
    try std.testing.expectError(error.NotZovaPath, restoreBackup(invalid_dest_path, existing_restore_path, .{}));
}

test "convert sqlite to zova rejects invalid destination path and existing destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "rejects.db");

    var invalid_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_dest_path = try testingDbPath(&invalid_dest_buffer, tmp.sub_path[0..], "rejects.db");

    var existing_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_dest_path = try testingDbPath(&existing_dest_buffer, tmp.sub_path[0..], "existing-dest.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table data (id integer primary key)");
    }

    try std.testing.expectError(error.NotZovaPath, convertSqliteToZova(source_path, invalid_dest_path));

    {
        var dest = try Database.create(existing_dest_path);
        defer dest.deinit();
    }

    try std.testing.expectError(error.DestinationExists, convertSqliteToZova(source_path, existing_dest_path));
}
