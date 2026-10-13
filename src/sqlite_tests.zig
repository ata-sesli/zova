const std = @import("std");
const sqlite = @import("sqlite.zig");
const testingDbPath = @import("zova_test_support.zig").testingDbPath;
const Database = sqlite.Database;
const c = @import("sqlite_c");
const Blob = sqlite.Blob;
const Step = sqlite.Step;
const resultBlob = sqlite.resultBlob;
const resultText = sqlite.resultText;
const version = sqlite.version;
const ColumnType = sqlite.ColumnType;

test "database opens memory database and exposes sqlite version" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try std.testing.expect(version().len > 0);
}

test "database can open an existing file read-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "readonly.db");

    {
        var setup = try Database.open(db_path);
        defer setup.deinit();
        try setup.exec("create table items (id integer primary key, name text not null)");
        try setup.exec("insert into items (name) values ('stored')");
    }

    var db = try Database.openWithFlags(db_path, .read_only);
    defer db.deinit();

    var stmt = try db.prepare("select name from items where id = 1");
    defer stmt.deinit();
    try std.testing.expectEqual(Step.row, try stmt.step());
    try std.testing.expectEqualStrings("stored", stmt.columnText(0));
    try std.testing.expectError(error.ReadOnly, db.exec("insert into items (name) values ('blocked')"));
}

test "database busy timeout can be set and cleared" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.setBusyTimeout(1);
    try db.setBusyTimeout(0);
}

test "database exec creates table and writes row" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table messages (id integer primary key, body text not null)");
    try db.exec("insert into messages (body) values ('hello')");

    try std.testing.expectEqual(@as(i64, 1), db.changes());
    try std.testing.expectEqual(@as(i64, 1), db.totalChanges());
    try std.testing.expectEqual(@as(i64, 1), db.lastInsertRowId());
}

test "database exec runs multiline schema sql unchanged" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec(
        \\create table accounts (
        \\  id integer primary key,
        \\  email text not null unique
        \\);
        \\create index accounts_email_idx on accounts (email);
        \\create view active_accounts as
        \\  select id, email from accounts;
    );

    var objects = try db.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where name in ('accounts', 'accounts_email_idx', 'active_accounts')
    );
    defer objects.deinit();

    try std.testing.expectEqual(Step.row, try objects.step());
    try std.testing.expectEqual(@as(i64, 3), objects.columnInt64(0));
}

test "read-only blob handles read, reopen, bounds, and idempotent cleanup" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table payloads (data blob not null)");
    try db.exec("insert into payloads (data) values (x'616263646566')");
    try db.exec("insert into payloads (data) values (x'313233')");

    var blob = try Blob.open(&db, "main", "payloads", "data", 1);
    try std.testing.expectEqual(@as(usize, 6), try blob.bytes());

    var bytes: [3]u8 = undefined;
    try blob.read(&bytes, 1);
    try std.testing.expectEqualSlices(u8, "bcd", &bytes);
    try std.testing.expectError(error.InvalidArgument, blob.read(&bytes, 4));

    try blob.reopen(2);
    try std.testing.expectEqual(@as(usize, 3), try blob.bytes());
    var replacement: [3]u8 = undefined;
    try blob.read(&replacement, 0);
    try std.testing.expectEqualSlices(u8, "123", &replacement);

    blob.deinit();
    blob.deinit();
}

test "read-only blob handles address attached schemas" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "blob-store.zova");
    var store = try Database.open(db_path);
    defer store.deinit();
    try store.exec("create table payloads (data blob not null)");
    try store.exec("insert into payloads (data) values (x'6174746163686564')");

    var db = try Database.open(":memory:");
    defer db.deinit();
    try db.attachDatabase(db_path, "object_store");

    var blob = try Blob.open(&db, "object_store", "payloads", "data", 1);
    defer blob.deinit();
    try std.testing.expectEqual(@as(usize, 8), try blob.bytes());
    var bytes: [8]u8 = undefined;
    try blob.read(&bytes, 0);
    try std.testing.expectEqualSlices(u8, "attached", &bytes);
}

test "vendored sqlite supports built in json functions" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var json = try db.prepare("select json_extract('{\"zova\":\"sqlite\"}', '$.zova') as value");
    defer json.deinit();

    try std.testing.expectEqual(Step.row, try json.step());
    try std.testing.expectEqualStrings("value", try json.columnName(0));
    try std.testing.expectEqualStrings("sqlite", json.columnText(0));
    try std.testing.expectError(error.Misuse, json.columnName(1));
}

test "vendored sqlite supports fts5 virtual tables" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create virtual table docs using fts5(body)");
    try db.exec("insert into docs (body) values ('zova wraps sqlite')");

    var search = try db.prepare("select body from docs where docs match 'sqlite'");
    defer search.deinit();

    try std.testing.expectEqual(Step.row, try search.step());
    try std.testing.expectEqualStrings("zova wraps sqlite", search.columnText(0));
    try std.testing.expectEqual(Step.done, try search.step());
}

test "result helpers copy text and blob for extension sql callbacks" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_create_function_v2(
        db.handle,
        "zova_test_result_text",
        0,
        c.SQLITE_UTF8,
        null,
        testResultTextFunc,
        null,
        null,
        null,
    ));
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_create_function_v2(
        db.handle,
        "zova_test_result_blob",
        0,
        c.SQLITE_UTF8,
        null,
        testResultBlobFunc,
        null,
        null,
        null,
    ));

    var row = try db.prepare("select zova_test_result_text(), zova_test_result_blob()");
    defer row.deinit();

    try std.testing.expectEqual(Step.row, try row.step());
    try std.testing.expectEqualStrings("owned text", row.columnText(0));
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, row.columnBlob(1));
    try std.testing.expectEqual(Step.done, try row.step());
}

fn testResultTextFunc(context: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    _ = argc;
    _ = argv;
    resultText(context.?, "owned text");
}

fn testResultBlobFunc(context: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    _ = argc;
    _ = argv;
    resultBlob(context.?, &.{ 0xde, 0xad, 0xbe, 0xef });
}

test "database open leaves user controlled pragmas alone" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var foreign_keys = try db.prepare("pragma foreign_keys");
    defer foreign_keys.deinit();

    try std.testing.expectEqual(Step.row, try foreign_keys.step());
    try std.testing.expectEqual(@as(i64, 0), foreign_keys.columnInt64(0));
}

test "raw sqlite escape hatch can use public database handle" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table messages (id integer primary key, body text not null)");
    try db.exec("insert into messages (body) values ('hello')");

    try std.testing.expectEqual(@as(i64, 1), c.sqlite3_total_changes64(db.handle));
}

test "database open maps missing parent directory to CantOpen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(
        &path_buffer,
        ".zig-cache/tmp/{s}/missing-parent/missing.db",
        .{tmp.sub_path[0..]},
        0,
    );

    try std.testing.expectError(error.CantOpen, Database.open(db_path));
}

test "file-backed database persists rows across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "persist.db");

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        try db.exec("create table messages (id integer primary key, body text not null)");
        try db.exec("insert into messages (body) values ('alpha')");
        try db.exec("insert into messages (body) values ('beta')");
    }

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        var select = try db.prepare("select id, body from messages order by id");
        defer select.deinit();

        try std.testing.expectEqual(Step.row, try select.step());
        try std.testing.expectEqual(@as(i64, 1), select.columnInt64(0));
        try std.testing.expectEqualStrings("alpha", select.columnText(1));

        try std.testing.expectEqual(Step.row, try select.step());
        try std.testing.expectEqual(@as(i64, 2), select.columnInt64(0));
        try std.testing.expectEqualStrings("beta", select.columnText(1));

        try std.testing.expectEqual(Step.done, try select.step());
    }
}

test "existing sqlite file remains usable through zova" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "existing.db");

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        try db.exec("create table settings (key text primary key, value text not null)");
        try db.exec("insert into settings (key, value) values ('theme', 'light')");
    }

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        try db.exec("insert into settings (key, value) values ('density', 'compact')");

        var count = try db.prepare("select count(*) from settings");
        defer count.deinit();
        try std.testing.expectEqual(Step.row, try count.step());
        try std.testing.expectEqual(@as(i64, 2), count.columnInt64(0));
    }
}

test "database error message describes failing sql" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try std.testing.expectError(error.SqliteError, db.exec("select * from missing_table"));
    try std.testing.expect(std.mem.indexOf(u8, db.errorMessage(), "no such table") != null);
}

test "database open does not create zova schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "schema.db");

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        try db.exec("create table app_data (id integer primary key, value text not null)");
    }

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        var user_tables = try db.prepare(
            \\select name
            \\from sqlite_master
            \\where type = 'table' and name not like 'sqlite_%'
            \\order by name
        );
        defer user_tables.deinit();

        try std.testing.expectEqual(Step.row, try user_tables.step());
        try std.testing.expectEqualStrings("app_data", user_tables.columnText(0));
        try std.testing.expectEqual(Step.done, try user_tables.step());

        var zova_tables = try db.prepare(
            \\select count(*)
            \\from sqlite_master
            \\where type = 'table' and (name like 'zova%' or name like '_zova%')
        );
        defer zova_tables.deinit();

        try std.testing.expectEqual(Step.row, try zova_tables.step());
        try std.testing.expectEqual(@as(i64, 0), zova_tables.columnInt64(0));
    }
}

test "statement binds values and reads a row" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table messages (id integer primary key, body text not null)");

    var insert = try db.prepare("insert into messages (body) values (?)");
    defer insert.deinit();
    try insert.bindText(1, "hello");
    try std.testing.expectEqual(Step.done, try insert.step());

    var select = try db.prepare("select id, body from messages where body = ?");
    defer select.deinit();
    try select.bindText(1, "hello");
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqual(@as(i64, 1), select.columnInt64(0));
    try std.testing.expectEqualStrings("hello", select.columnText(1));
    try std.testing.expectEqual(Step.done, try select.step());
}

test "statement cleanup tolerates previous step error" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table users (email text not null unique)");
    try db.exec("insert into users (email) values ('a@example.com')");

    var duplicate = try db.prepare("insert into users (email) values (?)");
    defer duplicate.deinit();
    try duplicate.bindText(1, "a@example.com");
    try std.testing.expectError(error.Constraint, duplicate.step());
}

test "constraint errors are recoverable" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table users (email text not null unique)");
    try db.exec("insert into users (email) values ('a@example.com')");

    var duplicate = try db.prepare("insert into users (email) values (?)");
    defer duplicate.deinit();
    try duplicate.bindText(1, "a@example.com");
    try std.testing.expectError(error.Constraint, duplicate.step());

    try db.exec("insert into users (email) values ('b@example.com')");

    var count = try db.prepare("select count(*) from users");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 2), count.columnInt64(0));
}

test "column text reads converted values" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var select = try db.prepare("select 42");
    defer select.deinit();
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("42", select.columnText(0));
}

test "statement binds and reads scalar and blob values" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec(
        \\create table samples (
        \\  i integer,
        \\  r real,
        \\  b blob,
        \\  empty_blob blob,
        \\  n text
        \\)
    );

    var insert = try db.prepare("insert into samples (i, r, b, empty_blob, n) values (?, ?, ?, ?, ?)");
    defer insert.deinit();
    try insert.bindInt64(1, -42);
    try insert.bindDouble(2, 3.25);
    try insert.bindBlob(3, &.{ 0x01, 0x02, 0x03 });
    try insert.bindBlob(4, &.{});
    try insert.bindNull(5);
    try std.testing.expectEqual(Step.done, try insert.step());

    var select = try db.prepare("select i, r, b, empty_blob, n from samples");
    defer select.deinit();
    try std.testing.expectEqual(@as(c_int, 5), select.columnCount());
    try std.testing.expectEqual(Step.row, try select.step());

    try std.testing.expectEqual(ColumnType.integer, select.columnType(0));
    try std.testing.expectEqual(ColumnType.float, select.columnType(1));
    try std.testing.expectEqual(ColumnType.blob, select.columnType(2));
    try std.testing.expectEqual(ColumnType.blob, select.columnType(3));
    try std.testing.expectEqual(ColumnType.null, select.columnType(4));

    try std.testing.expectEqual(@as(i64, -42), select.columnInt64(0));
    try std.testing.expectEqual(@as(f64, 3.25), select.columnDouble(1));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03 }, select.columnBlob(2));
    try std.testing.expectEqual(@as(usize, 0), select.columnBlob(3).len);
}

test "bound text and blob are copied from caller buffers" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table payloads (body text not null, bytes blob not null)");

    var body = [_]u8{ 'a', 'l', 'p', 'h', 'a' };
    var bytes = [_]u8{ 0x01, 0x02, 0x03 };

    var insert = try db.prepare("insert into payloads (body, bytes) values (?, ?)");
    defer insert.deinit();
    try insert.bindText(1, body[0..]);
    try insert.bindBlob(2, bytes[0..]);

    @memcpy(body[0..], "omega");
    @memset(bytes[0..], 0xff);

    try std.testing.expectEqual(Step.done, try insert.step());

    var select = try db.prepare("select body, bytes from payloads");
    defer select.deinit();
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("alpha", select.columnText(0));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03 }, select.columnBlob(1));
}

test "borrowed blob binding remains active through reset and ends on rebind" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var first = [_]u8{ 1, 2, 3 };
    var second = [_]u8{ 4, 5, 6 };
    var select = try db.prepare("select ?1");

    try select.bindBlobBorrowed(1, &first);
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualSlices(u8, &first, select.columnBlob(0));
    try select.reset();
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualSlices(u8, &first, select.columnBlob(0));

    try select.reset();
    try select.bindBlobBorrowed(1, &second);
    @memset(first[0..], 0xff);
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualSlices(u8, &second, select.columnBlob(0));

    try select.reset();
    try select.bindBlobBorrowed(1, &.{});
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqual(@as(usize, 0), select.columnBlob(0).len);
    select.deinit();
    @memset(second[0..], 0xee);
}

test "borrowed text binding remains active through reset and ends on rebind" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var first = [_]u8{ 'a', 'l', 'p', 'h', 'a' };
    var second = [_]u8{ 'o', 'm', 'e', 'g', 'a' };
    var select = try db.prepare("select ?1");
    defer select.deinit();

    try select.bindTextBorrowed(1, &first);
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("alpha", select.columnText(0));

    try select.reset();
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("alpha", select.columnText(0));

    try select.reset();
    try select.bindTextBorrowed(1, &second);
    @memset(first[0..], 'x');
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("omega", select.columnText(0));

    try select.reset();
    try select.clearBindings();
    @memset(second[0..], 'y');
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqual(ColumnType.null, select.columnType(0));

    try select.reset();
    try select.bindTextBorrowed(1, "");
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("", select.columnText(0));
}

test "bundled sqlite exposes dbstat for storage diagnostics" {
    var db = try Database.open(":memory:");
    defer db.deinit();
    try db.exec("create table measured (id integer primary key, value text not null)");

    var compile_option = try db.prepare("select sqlite_compileoption_used('ENABLE_DBSTAT_VTAB')");
    defer compile_option.deinit();
    try std.testing.expectEqual(Step.row, try compile_option.step());
    try std.testing.expectEqual(@as(i64, 1), compile_option.columnInt64(0));

    var pages = try db.prepare("select count(*) from dbstat where name='measured'");
    defer pages.deinit();
    try std.testing.expectEqual(Step.row, try pages.step());
    try std.testing.expect(pages.columnInt64(0) > 0);
}

test "statement reports parameter count and named parameter index" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var select = try db.prepare("select ?, :name, ?");
    defer select.deinit();

    try std.testing.expectEqual(@as(c_int, 3), select.parameterCount());
    try std.testing.expectEqual(@as(c_int, 2), select.parameterIndex(":name"));
}

test "invalid parameter indexes map to generic sqlite error" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var select = try db.prepare("select ?");
    defer select.deinit();

    try std.testing.expectError(error.SqliteError, select.bindInt64(0, 1));
    try std.testing.expectError(error.SqliteError, select.bindInt64(2, 1));
    try std.testing.expectError(error.SqliteError, select.bindTextBorrowed(0, "value"));
    try std.testing.expectError(error.SqliteError, select.bindTextBorrowed(2, "value"));
    try std.testing.expectError(error.SqliteError, select.bindBlobBorrowed(0, &.{1}));
    try std.testing.expectError(error.SqliteError, select.bindBlobBorrowed(2, &.{1}));
}

test "statement reset and clear bindings prevent stale values" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    var select = try db.prepare("select coalesce(?1, 'fallback')");
    defer select.deinit();

    try select.bindText(1, "first");
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("first", select.columnText(0));

    try select.reset();
    try select.clearBindings();
    try std.testing.expectEqual(Step.row, try select.step());
    try std.testing.expectEqualStrings("fallback", select.columnText(0));
}

test "deferred transaction begin commits writes" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.begin();
    try db.exec("insert into items (name) values ('deferred')");
    try db.commit();

    var count = try db.prepare("select count(*) from items where name = 'deferred'");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}

test "immediate transaction begin commits writes" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.beginImmediate();
    try db.exec("insert into items (name) values ('immediate')");
    try db.commit();

    var count = try db.prepare("select count(*) from items where name = 'immediate'");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}

test "transaction commit keeps writes" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.beginImmediate();
    try db.exec("insert into items (name) values ('committed')");
    try db.commit();

    var count = try db.prepare("select count(*) from items");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}

test "transaction rollback discards writes" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.beginImmediate();
    try db.exec("insert into items (name) values ('rolled back')");
    try db.rollback();

    var count = try db.prepare("select count(*) from items");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 0), count.columnInt64(0));
}

test "savepoint rollback and release follow sqlite semantics" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.beginImmediate();
    try db.exec("insert into items (name) values ('outer')");

    try db.savepoint("sp_one");
    try db.exec("insert into items (name) values ('rolled back')");
    try db.rollbackToSavepoint("sp_one");
    try db.releaseSavepoint("sp_one");

    try db.savepoint("sp_two");
    try db.exec("insert into items (name) values ('released')");
    try db.releaseSavepoint("sp_two");

    {
        var scan = try db.prepare("select name from items order by id");
        defer scan.deinit();
        try std.testing.expectEqual(Step.row, try scan.step());
        try std.testing.expectEqualStrings("outer", scan.columnText(0));
        try db.savepoint("sp_scan");
        try db.releaseSavepoint("sp_scan");
        try std.testing.expectEqual(Step.row, try scan.step());
        try std.testing.expectEqualStrings("released", scan.columnText(0));
    }

    try db.commit();

    var count = try db.prepare("select count(*) from items");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 2), count.columnInt64(0));

    var missing = try db.prepare("select count(*) from items where name = 'rolled back'");
    defer missing.deinit();
    try std.testing.expectEqual(Step.row, try missing.step());
    try std.testing.expectEqual(@as(i64, 0), missing.columnInt64(0));
}

test "savepoint names are strict identifiers" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    const invalid_names = [_][]const u8{
        "",
        "1starts_with_digit",
        "has space",
        "has'quote",
        "has;semicolon",
        "_zova_internal",
        "_ZoVa_internal",
        "emoji_\xF0\x9F\x98\x80",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };

    for (invalid_names) |name| {
        try std.testing.expectError(error.InvalidArgument, db.savepoint(name));
    }
}

test "commit without active transaction maps to generic sqlite error" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try std.testing.expectError(error.SqliteError, db.commit());
    try std.testing.expect(std.mem.indexOf(u8, db.errorMessage(), "no transaction is active") != null);
}

test "rollback without active transaction maps to generic sqlite error" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try std.testing.expectError(error.SqliteError, db.rollback());
    try std.testing.expect(std.mem.indexOf(u8, db.errorMessage(), "no transaction is active") != null);
}

test "nested transaction keeps sqlite semantics and leaves connection usable" {
    var db = try Database.open(":memory:");
    defer db.deinit();

    try db.exec("create table items (id integer primary key, name text not null)");
    try db.begin();
    try std.testing.expectError(error.SqliteError, db.begin());
    try std.testing.expect(std.mem.indexOf(u8, db.errorMessage(), "within a transaction") != null);
    try db.rollback();

    try db.exec("insert into items (name) values ('usable')");
    var count = try db.prepare("select count(*) from items where name = 'usable'");
    defer count.deinit();
    try std.testing.expectEqual(Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}

test "beginImmediate maps busy when another connection holds write lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "busy.db");

    {
        var setup = try Database.open(db_path);
        defer setup.deinit();
        try setup.exec("create table items (id integer primary key, name text not null)");
    }

    var first = try Database.open(db_path);
    defer first.deinit();
    var second = try Database.open(db_path);
    defer second.deinit();

    try first.beginImmediate();
    defer first.rollback() catch {};

    try std.testing.expectError(error.Busy, second.beginImmediate());
}
