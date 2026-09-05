//! One bounded sample. Pass a new external-disk .zova path.
const std = @import("std");
const zova = @import("zova");
const sqlite = zova.sqlite;
const repeats = 2000;
const get_sql = "select value from _zova_kv where namespace = ? and key = ?";
const put_sql = "insert into _zova_kv (namespace, key, value) values (?, ?, ?) on conflict(namespace, key) do update set value = excluded.value";

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn report(name: []const u8, start: std.Io.Timestamp, count: usize) void {
    const ns = start.durationTo(now()).toNanoseconds();
    std.debug.print("{s}_us={d:.6}\n", .{ name, @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(count)) / 1000 });
}

fn statementBytes(db: *sqlite.Database) !c_int {
    var current: c_int = 0;
    var high: c_int = 0;
    if (sqlite.c.sqlite3_db_status(db.handle, sqlite.c.SQLITE_DBSTATUS_STMT_USED, &current, &high, 0) != sqlite.c.SQLITE_OK) return error.SqliteError;
    return current;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArgument;
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try db.kvPut("ns", "key", "small-value");
    for ([_][]const u8{ "key", "missing" }) |key| {
        const start = now();
        for (0..repeats) |_| {
            const result = try db.kvGet(std.heap.c_allocator, "ns", key);
            defer result.deinit(std.heap.c_allocator);
            if (result.found != std.mem.eql(u8, key, "key")) return error.BadResult;
            if (result.found and !std.mem.eql(u8, result.value, "small-value")) return error.BadResult;
        }
        report(if (key.len == 3) "get_hit" else "get_miss", start, repeats);
    }
    var start = now();
    for (0..repeats) |_| try db.kvPut("ns", "key", "small-value");
    report("put_memory_owned", start, repeats);
    try db.begin();
    start = now();
    for (0..repeats) |_| try db.kvPut("ns", "key", "small-value");
    report("put_memory_savepoint", start, repeats);
    try db.rollback();
    std.debug.print("retained_statement_bytes={d}\n", .{try statementBytes(&db.sqlite_db)});

    // Controls exclude facade work: prepare/finalize; bind/step/reset/clear;
    // and empty transaction overhead. Do not sum these as an exact profile.
    for ([_][:0]const u8{ get_sql, put_sql }, 0..) |sql, index| {
        start = now();
        for (0..repeats) |_| {
            var stmt = try db.sqlite_db.prepare(sql);
            stmt.deinit();
        }
        report(if (index == 0) "prepare_get" else "prepare_put", start, repeats);
        var stmt = try db.sqlite_db.prepare(sql);
        defer stmt.deinit();
        start = now();
        for (0..repeats) |_| {
            try stmt.bindBlob(1, "ns");
            try stmt.bindBlob(2, "key");
            if (index == 1) try stmt.bindBlob(3, "small-value");
            const result = try stmt.step();
            if (index == 0 and (result != .row or stmt.columnBlob(0).len != 11)) return error.BadResult;
            if (index == 1 and result != .done) return error.BadResult;
            try stmt.reset();
            try stmt.clearBindings();
        }
        report(if (index == 0) "execute_get" else "execute_put_autocommit", start, repeats);
    }
    start = now();
    for (0..repeats) |_| {
        try db.sqlite_db.beginImmediate();
        try db.sqlite_db.commit();
    }
    report("empty_transaction", start, repeats);
    var disk = try zova.Database.create(try init.arena.allocator().dupeZ(u8, args[1]));
    defer disk.deinit();
    try disk.kvPut("ns", "key", "small-value");
    start = now();
    for (0..16) |i| try disk.kvPut("ns", "key", if (i % 2 == 0) "other-value" else "small-value");
    report("put_disk_owned", start, 16);
}
