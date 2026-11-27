//! Behavior tests for the experimental CWAL module (integration phase 2).
//! Process crashes, power loss and races stay in the prototype's torture
//! suite until it is ported (phase 7).
const std = @import("std");
const cwal = @import("cwal.zig");
const c = @import("sqlite_c");

var registered = false;

fn registerOnce() void {
    if (registered) return;
    cwal.register();
    registered = true;
}

const Paths = struct {
    buf: [4][256]u8 = undefined,
    list: [4][]const u8 = undefined,
    len: usize = 0,

    fn add(paths: *Paths, sub_path: []const u8, name: []const u8) ![:0]const u8 {
        const z = try std.fmt.bufPrintSentinel(&paths.buf[paths.len], ".zig-cache/tmp/{s}/{s}", .{ sub_path, name }, 0);
        paths.list[paths.len] = z;
        paths.len += 1;
        return z;
    }

    fn slice(paths: *const Paths) []const []const u8 {
        return paths.list[0..paths.len];
    }
};

/// Creates a WAL-mode database with table `t(k integer primary key, v)`.
fn createMember(path: [:0]const u8) !void {
    var db: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(db);
    if (c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK) return error.Sqlite;
    if (c.sqlite3_exec(db, "pragma journal_mode=wal; create table t(k integer primary key, v text)", null, null, null) != c.SQLITE_OK) return error.Sqlite;
}

fn count(conn: *cwal.Conn, comptime sql: [:0]const u8) !i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Sqlite;
    return c.sqlite3_column_int64(stmt, 0);
}

fn crossCommit(conn: *cwal.Conn, k: i64) !void {
    var buf: [160]u8 = undefined;
    try conn.exec("begin");
    errdefer conn.rollbackOpen();
    try conn.exec(try std.fmt.bufPrintSentinel(&buf, "insert into main.t values ({d}, 'x')", .{k}, 0));
    try conn.exec(try std.fmt.bufPrintSentinel(&buf, "insert into m1.t values ({d}, 'x')", .{k}, 0));
    try conn.commit();
}

fn copyFile(source: []const u8, dest: []const u8) !void {
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = bytes });
}

const writer: cwal.Options = .{ .mode = .cwal, .role = .writer };
const reader: cwal.Options = .{ .mode = .cwal, .role = .reader };

/// Not expectError: its failure message would format the whole Conn,
/// and an unexpected Conn must be closed.
fn expectOpenError(expected: anyerror, paths: []const []const u8, options: cwal.Options) !void {
    if (cwal.Conn.open(paths, options)) |unexpected| {
        unexpected.close();
        return error.TestUnexpectedOpen;
    } else |err| try std.testing.expectEqual(expected, err);
}

test "register adds the cwal VFS without changing the default" {
    const before = c.sqlite3_vfs_find(null);
    registerOnce();
    try std.testing.expect(c.sqlite3_vfs_find("cwal") != null);
    try std.testing.expectEqual(before, c.sqlite3_vfs_find(null));
    try std.testing.expectEqualStrings("unix", std.mem.span(c.sqlite3_vfs_find(null).*.zName));
}

test "a cross-file commit writes both members and their markers" {
    registerOnce();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try createMember(try paths.add(&tmp.sub_path, "main.db"));
    try createMember(try paths.add(&tmp.sub_path, "s1.db"));

    const conn = try cwal.Conn.open(paths.slice(), writer);
    try crossCommit(conn, 1);
    try crossCommit(conn, 2);
    try conn.autocommit("insert into main.t values (3, 'solo')");
    try std.testing.expectEqual(@as(i64, 3), try count(conn, "select count(*) from main.t"));
    try std.testing.expectEqual(@as(i64, 2), try count(conn, "select count(*) from m1.t"));
    // Both members carry the newest cross-file transaction's marker. The
    // low 32 bits count transactions; the high bits hold the writer epoch.
    try std.testing.expectEqual(@as(i64, 2), try count(conn, "select txn & 4294967295 from main.cwal_marker where k = 0"));
    try std.testing.expectEqual(@as(i64, 2), try count(conn, "select txn & 4294967295 from m1.cwal_marker where k = 0"));
    try std.testing.expectEqual(@as(i64, 3), try count(conn, "select mask from m1.cwal_marker where k = 0"));
    conn.close();

    // A later open sees everything and runs no recovery.
    cwal.last_recovery = "none";
    const again = try cwal.Conn.open(paths.slice(), reader);
    defer again.close();
    try std.testing.expectEqual(@as(i64, 3), try count(again, "select count(*) from main.t"));
    try std.testing.expectEqual(@as(i64, 2), try count(again, "select count(*) from m1.t"));
    try std.testing.expectEqualStrings("none", cwal.last_recovery);
}

test "a member open in one set is refused to another set" {
    registerOnce();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: Paths = .{};
    try createMember(try a.add(&tmp.sub_path, "a.db"));
    try createMember(try a.add(&tmp.sub_path, "shared.db"));
    var b: Paths = .{};
    try createMember(try b.add(&tmp.sub_path, "b.db"));
    _ = try b.add(&tmp.sub_path, "shared.db");

    const first = try cwal.Conn.open(a.slice(), writer);
    try expectOpenError(error.MemberOwned, b.slice(), reader);
    // Another handle of the same set may join.
    const same = try cwal.Conn.open(a.slice(), reader);
    same.close();
    first.close();
    // Once the first set is closed, the other set may take the member.
    const second = try cwal.Conn.open(b.slice(), writer);
    second.close();
}

test "a member listed twice in one set is a protocol violation" {
    registerOnce();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try createMember(try paths.add(&tmp.sub_path, "main.db"));
    _ = try paths.add(&tmp.sub_path, "main.db");
    try expectOpenError(error.ProtocolViolation, paths.slice(), writer);
}

test "recovery rolls back a cross-file commit that reached only one member" {
    registerOnce();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    const main_path = try paths.add(&tmp.sub_path, "main.db");
    const s1_path = try paths.add(&tmp.sub_path, "s1.db");
    try createMember(main_path);
    try createMember(s1_path);

    // The crash image: main after transactions 1 and 2, s1 after 1 only, as
    // if the process died after main's WAL sync of transaction 2.
    var image: Paths = .{};
    const image_main = try image.add(&tmp.sub_path, "image-main.db");
    const image_s1 = try image.add(&tmp.sub_path, "image-s1.db");
    var buf: [2][300]u8 = undefined;
    {
        const conn = try cwal.Conn.open(paths.slice(), writer);
        defer conn.close();
        try crossCommit(conn, 1);
        try copyFile(s1_path, image_s1);
        try copyFile(try std.fmt.bufPrint(&buf[0], "{s}-wal", .{s1_path}), try std.fmt.bufPrint(&buf[1], "{s}-wal", .{image_s1}));
        try crossCommit(conn, 2);
        try copyFile(main_path, image_main);
        try copyFile(try std.fmt.bufPrint(&buf[0], "{s}-wal", .{main_path}), try std.fmt.bufPrint(&buf[1], "{s}-wal", .{image_main}));
    }

    cwal.last_recovery = "none";
    const conn = try cwal.Conn.open(image.slice(), writer);
    defer conn.close();
    try std.testing.expectEqualStrings("rollback", cwal.last_recovery);
    try std.testing.expectEqual(@as(i64, 1), try count(conn, "select count(*) from main.t"));
    try std.testing.expectEqual(@as(i64, 1), try count(conn, "select count(*) from m1.t"));
    try std.testing.expectEqual(@as(i64, 1), try count(conn, "select txn & 4294967295 from main.cwal_marker where k = 0"));
    // The set accepts new cross-file commits after the repair.
    try crossCommit(conn, 3);
    try std.testing.expectEqual(@as(i64, 2), try count(conn, "select count(*) from m1.t"));
}

test "plain mode commits across members without the protocol" {
    registerOnce();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try createMember(try paths.add(&tmp.sub_path, "main.db"));
    try createMember(try paths.add(&tmp.sub_path, "s1.db"));
    const conn = try cwal.Conn.open(paths.slice(), .{ .mode = .plain, .role = .writer });
    defer conn.close();
    try crossCommit(conn, 1);
    try std.testing.expectEqual(@as(i64, 1), try count(conn, "select count(*) from m1.t"));
}

test "test hooks are compiled in only when the build asks for them" {
    try std.testing.expectEqual(@import("cwal_options").test_hooks, cwal.hooks);
    if (!cwal.hooks) {
        try std.testing.expect(!cwal.fault.mutated("no-gate"));
        try std.testing.expect(!cwal.fault.shouldFail("write-wal"));
        try std.testing.expect(!cwal.fault.powerLoss());
    }
}
