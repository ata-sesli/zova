const std = @import("std");
const kv_impl = @import("kv.zig");
const sqlite = @import("sqlite.zig");
const test_support = @import("zova_test_support.zig");
const zova = @import("zova.zig");

const Database = zova.Database;
const kv_table = kv_impl.kv_table;

const testingCount = test_support.testingCount;
const testingDbPath = test_support.testingDbPath;
const testingIntegrityCheckOk = test_support.testingIntegrityCheckOk;
const testingQuickCheckOk = test_support.testingQuickCheckOk;

test "kv schema is created for every database and is private" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "kv-schema.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try testingExpectTableCount(&db.sqlite_db, kv_table, 1);
    try testingQuickCheckOk(&db);
    try testingIntegrityCheckOk(&db);
}

test "kv put get delete count roundtrip with binary and empty bytes" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.kvPut("", "", "");
    var result = try db.kvGet(std.testing.allocator, "", "");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.found);
    try std.testing.expectEqualSlices(u8, "", result.value);

    const binary_namespace = [_]u8{ 0x00, 0xff, 'n', 0, 's' };
    const binary_key = [_]u8{ 0x01, 0x02, 0x00, 0xfe };
    const binary_value = [_]u8{ 'v', 0, 0xff, 'w', 0x10 };

    try db.kvPut(&binary_namespace, &binary_key, &binary_value);
    var bin = try db.kvGet(std.testing.allocator, &binary_namespace, &binary_key);
    defer bin.deinit(std.testing.allocator);
    try std.testing.expect(bin.found);
    try std.testing.expectEqualSlices(u8, &binary_value, bin.value);

    try std.testing.expectEqual(@as(u64, 1), try db.kvCount(""));
    try std.testing.expectEqual(@as(u64, 1), try db.kvCount(&binary_namespace));

    try db.kvDelete(&binary_namespace, &binary_key);
    var missing = try db.kvGet(std.testing.allocator, &binary_namespace, &binary_key);
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!missing.found);
    try std.testing.expectEqual(@as(u64, 0), try db.kvCount(&binary_namespace));
}

test "kv put replaces existing value and delete ignores missing keys" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.kvPut("n", "k", "v1");
    try db.kvPut("n", "k", "v2");
    var result = try db.kvGet(std.testing.allocator, "n", "k");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.found);
    try std.testing.expectEqualSlices(u8, "v2", result.value);
    try std.testing.expectEqual(@as(u64, 1), try db.kvCount("n"));

    try db.kvDelete("n", "absent");
    try std.testing.expectEqual(@as(u64, 1), try db.kvCount("n"));
    try db.kvDelete("n", "k");
    try std.testing.expectEqual(@as(u64, 0), try db.kvCount("n"));
    try db.kvDelete("n", "k");
    try std.testing.expectEqual(@as(u64, 0), try db.kvCount("n"));
}

test "kv get_many aligns with input order and preserves duplicate keys" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.kvPut("n", "a", "1");
    try db.kvPut("n", "b", "2");
    try db.kvPut("n", "c", "3");

    const keys = [_][]const u8{ "c", "absent", "a", "b", "absent", "a" };
    const results = try db.kvGetMany(std.testing.allocator, "n", &keys);
    defer {
        for (results) |item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(keys.len, results.len);
    try std.testing.expect(results[0].found);
    try std.testing.expectEqualSlices(u8, "3", results[0].value);
    try std.testing.expect(!results[1].found);
    try std.testing.expect(results[2].found);
    try std.testing.expectEqualSlices(u8, "1", results[2].value);
    try std.testing.expect(results[3].found);
    try std.testing.expectEqualSlices(u8, "2", results[3].value);
    try std.testing.expect(!results[4].found);
    try std.testing.expect(results[5].found);
    try std.testing.expectEqualSlices(u8, "1", results[5].value);
}

test "kv empty get_many returns an empty aligned result" {
    var db = try Database.createMemory();
    defer db.deinit();

    const keys = [_][]const u8{};
    const results = try db.kvGetMany(std.testing.allocator, "n", &keys);
    defer {
        for (results) |item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "kv put_many and delete_many batches validate completely and mutate atomically" {
    var db = try Database.createMemory();
    defer db.deinit();

    const entries = [_]kv_impl.PutEntry{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "10" },
        .{ .key = "b", .value = "20" },
    };
    try db.kvPutMany("n", &entries);
    try std.testing.expectEqual(@as(u64, 2), try db.kvCount("n"));

    var a = try db.kvGet(std.testing.allocator, "n", "a");
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "10", a.value);

    const delete_keys = [_][]const u8{ "a", "absent", "b", "absent" };
    try db.kvDeleteMany("n", &delete_keys);
    try std.testing.expectEqual(@as(u64, 0), try db.kvCount("n"));

    try db.kvPutMany("n", &.{});
    try std.testing.expectEqual(@as(u64, 0), try db.kvCount("n"));
    try db.kvDeleteMany("n", &.{});
    try std.testing.expectEqual(@as(u64, 0), try db.kvCount("n"));
}

test "kv clear_namespace removes only the target namespace" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.kvPut("alpha", "a", "1");
    try db.kvPut("alpha", "b", "2");
    try db.kvPut("beta", "a", "3");

    try db.kvClearNamespace("alpha");
    try std.testing.expectEqual(@as(u64, 0), try db.kvCount("alpha"));
    try std.testing.expectEqual(@as(u64, 1), try db.kvCount("beta"));
    var beta = try db.kvGet(std.testing.allocator, "beta", "a");
    defer beta.deinit(std.testing.allocator);
    try std.testing.expect(beta.found);
    try std.testing.expectEqualSlices(u8, "3", beta.value);

    try db.kvClearNamespace("empty");
    try std.testing.expectEqual(@as(u64, 1), try db.kvCount("beta"));
}

test "kv operations join a caller-owned transaction and rollback together" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.kvPut("n", "k", "before");
    try db.begin();
    try db.kvPut("n", "k", "inside");
    try db.kvPut("n", "other", "row");
    try db.exec("insert into _zova_meta (key, value) values ('kv_test_sql', 'joined')");
    try db.rollback();

    var rolled_back = try db.kvGet(std.testing.allocator, "n", "k");
    defer rolled_back.deinit(std.testing.allocator);
    try std.testing.expect(rolled_back.found);
    try std.testing.expectEqualSlices(u8, "before", rolled_back.value);
    try std.testing.expectEqual(@as(u64, 1), try db.kvCount("n"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_meta where key = 'kv_test_sql'"));

    try db.begin();
    try db.kvPutMany("n", &.{ .{ .key = "batch1", .value = "x" }, .{ .key = "batch2", .value = "y" } });
    try db.commit();
    try std.testing.expectEqual(@as(u64, 3), try db.kvCount("n"));
}

test "kv participates in savepoint rollback alongside SQL" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.kvPut("n", "k", "original");
    try db.savepoint("kv_sp");
    try db.kvPut("n", "k", "changed");
    try db.kvPut("n", "extra", "value");
    try db.exec("insert into _zova_meta (key, value) values ('kv_sp_sql', 'inside')");
    try db.rollbackToSavepoint("kv_sp");
    try db.releaseSavepoint("kv_sp");

    var restored = try db.kvGet(std.testing.allocator, "n", "k");
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "original", restored.value);
    try std.testing.expectEqual(@as(u64, 1), try db.kvCount("n"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_meta where key = 'kv_sp_sql'"));
}

test "kv persists across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "kv-reopen.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
        try db.kvPut("n", "a", "1");
        try db.kvPut("n", "b", "2");
        try db.kvPutMany("n", &.{ .{ .key = "c", .value = "3" }, .{ .key = "d", .value = "4" } });
    }

    {
        var db = try Database.open(db_path);
        defer db.deinit();
        try std.testing.expectEqual(@as(u64, 4), try db.kvCount("n"));
        var a = try db.kvGet(std.testing.allocator, "n", "a");
        defer a.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "1", a.value);
        try testingIntegrityCheckOk(&db);
    }
}

test "kv survives backup restore and in-memory restore with parity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "kv-backup.zova");
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "kv-backup-copy.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.kvPut("n", "a", "1");
    try db.kvPut("n", "b", "2");
    try db.kvPut("other", "x", "9");

    try db.backupTo(backup_path, .{});

    var restored = try Database.open(backup_path);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 2), try restored.kvCount("n"));
    try std.testing.expectEqual(@as(u64, 1), try restored.kvCount("other"));
    var a = try restored.kvGet(std.testing.allocator, "n", "a");
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "1", a.value);

    var memory = try zova.restoreBackupToMemory(db_path, .{});
    defer memory.deinit();
    try std.testing.expectEqual(@as(u64, 2), try memory.kvCount("n"));
    var mem_a = try memory.kvGet(std.testing.allocator, "n", "a");
    defer mem_a.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "1", mem_a.value);
    try testingIntegrityCheckOk(&memory);
}

test "kv survives in-memory-to-file backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "kv-memory-backup.zova");

    var db = try Database.createMemory();
    defer db.deinit();

    try db.kvPut("n", "k", "memory-value");
    try db.backupTo(db_path, .{});

    var file_db = try Database.open(db_path);
    defer file_db.deinit();
    try std.testing.expectEqual(@as(u64, 1), try file_db.kvCount("n"));
    var value = try file_db.kvGet(std.testing.allocator, "n", "k");
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "memory-value", value.value);
    try testingIntegrityCheckOk(&file_db);
}

test "kv namespaces are fully isolated" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.kvPut("one", "shared", "1");
    try db.kvPut("two", "shared", "2");

    var one = try db.kvGet(std.testing.allocator, "one", "shared");
    defer one.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "1", one.value);
    var two = try db.kvGet(std.testing.allocator, "two", "shared");
    defer two.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "2", two.value);

    try db.kvDelete("one", "shared");
    try std.testing.expectEqual(@as(u64, 0), try db.kvCount("one"));
    try std.testing.expectEqual(@as(u64, 1), try db.kvCount("two"));

    var two_again = try db.kvGet(std.testing.allocator, "two", "shared");
    defer two_again.deinit(std.testing.allocator);
    try std.testing.expect(two_again.found);
}

test "kv empty values are zero-length blobs not null" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.kvPut("n", "empty-value", "");
    try db.kvPut("n", "null-bytes", "\x00\x00\x00");

    var empty = try db.kvGet(std.testing.allocator, "n", "empty-value");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(empty.found);
    try std.testing.expectEqualSlices(u8, "", empty.value);

    var nulls = try db.kvGet(std.testing.allocator, "n", "null-bytes");
    defer nulls.deinit(std.testing.allocator);
    try std.testing.expect(nulls.found);
    try std.testing.expectEqualSlices(u8, "\x00\x00\x00", nulls.value);

    try std.testing.expectEqual(@as(i64, 1), try countKvBlob(&db,
        \\select count(*) from _zova_kv
        \\where namespace = ? and key = ? and value = x''
    , "n", "empty-value"));
}

fn countKvBlob(db: anytype, comptime sql: [:0]const u8, namespace: []const u8, key: []const u8) !i64 {
    var count = try db.prepare(sql);
    defer count.deinit();

    try count.bindBlob(1, namespace);
    try count.bindBlob(2, key);
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    return count.columnInt64(0);
}

test "kv batch validate rejects too-large entries before mutation" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.kvPut("n", "existing", "value");

    const huge_len = std.math.maxInt(usize);
    const entries = [_]kv_impl.PutEntry{
        .{ .key = "ok", .value = "fine" },
        .{ .key = "bad", .value = (&[_]u8{}).ptr[0..huge_len] },
    };

    try std.testing.expectError(error.KvTooLarge, db.kvPutMany("n", &entries));
    try std.testing.expectEqual(@as(u64, 1), try db.kvCount("n"));
    var existing = try db.kvGet(std.testing.allocator, "n", "existing");
    defer existing.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "value", existing.value);
}

test "kv all methods reject empty keys and values correctly under transaction" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.begin();
    try db.kvPut("", "a", "1");
    try db.kvPut("", "b", "");
    try db.kvPutMany("", &.{ .{ .key = "c", .value = "" }, .{ .key = "d", .value = "4" } });
    try db.commit();

    try std.testing.expectEqual(@as(u64, 4), try db.kvCount(""));

    try db.begin();
    try db.kvDeleteMany("", &.{ "a", "b", "c", "d" });
    try db.rollback();
    try std.testing.expectEqual(@as(u64, 4), try db.kvCount(""));

    try db.begin();
    try db.kvClearNamespace("");
    try db.rollback();
    try std.testing.expectEqual(@as(u64, 4), try db.kvCount(""));
}

fn testingExpectTableCount(db: *sqlite.Database, table_name: []const u8, expected: i64) !void {
    var count = try db.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table' and name = ?
    );
    defer count.deinit();

    try count.bindText(1, table_name);
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    try std.testing.expectEqual(expected, count.columnInt64(0));
}