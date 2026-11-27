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
    buf: [cwal.max_members + 1][256]u8 = undefined,
    list: [cwal.max_members + 1][]const u8 = undefined,
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

/// `pragma integrity_check` over every attached member reports "ok".
fn integrityOk(conn: *cwal.Conn) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(conn.db, "pragma integrity_check", -1, &stmt, null) != c.SQLITE_OK) return error.Sqlite;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.Sqlite;
    return std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)), "ok");
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

test "max_members matches the SQLite attach limit" {
    var db: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(db);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &db));
    try std.testing.expectEqual(@as(c_int, cwal.max_members - 1), c.sqlite3_limit(db, c.SQLITE_LIMIT_ATTACHED, -1));
}

test "a connection attaches exactly max_members - 1 databases" {
    var db: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(db);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &db));
    var buf: [64]u8 = undefined;
    for (1..cwal.max_members) |i| {
        const sql = try std.fmt.bufPrintSentinel(&buf, "attach ':memory:' as a{d}", .{i}, 0);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, sql.ptr, null, null, null));
    }
    try std.testing.expectEqual(c.SQLITE_ERROR, c.sqlite3_exec(db, "attach ':memory:' as one_too_many", null, null, null));
    try std.testing.expectEqualStrings("too many attached databases - max 30", std.mem.span(c.sqlite3_errmsg(db)));
}

test "a set with no members or more than max_members is refused" {
    registerOnce();
    const none: []const []const u8 = &.{};
    try expectOpenError(error.ProtocolViolation, none, writer);
    const many: [cwal.max_members + 1][]const u8 = @splat("unused.db");
    try expectOpenError(error.ProtocolViolation, &many, writer);
    const far_too_many: [4 * cwal.max_members][]const u8 = @splat("unused.db");
    try expectOpenError(error.ProtocolViolation, &far_too_many, reader);
}

test "a set of max_members commits across every member; one more is refused" {
    registerOnce();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    var name: [16]u8 = undefined;
    for (0..cwal.max_members + 1) |i| {
        try createMember(try paths.add(&tmp.sub_path, try std.fmt.bufPrint(&name, "m{d}.db", .{i})));
    }
    const all = paths.slice();
    const set = all[0..cwal.max_members];

    // One member too many is refused before anything is opened or locked.
    try expectOpenError(error.ProtocolViolation, all, writer);

    const conn = try cwal.Conn.open(set, writer);
    var sql: [96]u8 = undefined;
    try conn.exec("begin");
    for (0..cwal.max_members) |i| {
        const schema = if (i == 0) "main" else try std.fmt.bufPrint(&name, "m{d}", .{i});
        try conn.exec(try std.fmt.bufPrintSentinel(&sql, "insert into {s}.t values (1, 'x')", .{schema}, 0));
    }
    try conn.commit();
    const full_mask: i64 = (1 << cwal.max_members) - 1;
    try std.testing.expectEqual(full_mask, try count(conn, "select mask from main.cwal_marker where k = 0"));
    try std.testing.expectEqual(full_mask, try count(conn, "select mask from m30.cwal_marker where k = 0"));
    conn.close();

    cwal.last_recovery = "none";
    const again = try cwal.Conn.open(set, reader);
    defer again.close();
    try std.testing.expectEqualStrings("none", cwal.last_recovery);
    try std.testing.expectEqual(@as(i64, 1), try count(again, "select count(*) from m30.t"));
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

/// Copies the newest WAL frame for `page` in `wal_path` into the database
/// file, as a checkpointer does page by page. Nothing else changes: the
/// marker page stays, and the -shm and nBackfill are untouched.
fn copyFrameToDatabase(db_path: []const u8, wal_path: []const u8, page: u32) !void {
    const io = std.testing.io;
    const wal = try std.Io.Dir.cwd().readFileAlloc(io, wal_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(wal);
    const page_size = std.mem.readInt(u32, wal[8..12], .big);
    const frame_size = 24 + page_size;
    var newest: ?usize = null;
    var offset: usize = 32;
    while (offset + frame_size <= wal.len) : (offset += frame_size) {
        if (std.mem.readInt(u32, wal[offset..][0..4], .big) == page) newest = offset;
    }
    const at = newest orelse return error.TestPageNotInWal;
    const db = try std.Io.Dir.cwd().readFileAlloc(io, db_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(db);
    const start = (page - 1) * page_size;
    try std.testing.expect(db.len >= start + page_size);
    @memcpy(db[start..][0..page_size], wal[at + 24 ..][0..page_size]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = db_path, .data = db });
}

fn rootPage(conn: *cwal.Conn, comptime table: []const u8) !u32 {
    return @intCast(try count(conn, "select rootpage from main.sqlite_schema where name = '" ++ table ++ "'"));
}

/// The crash image of R6's partial-checkpoint case: main holds a torn
/// cross-file commit (transaction 2) in its WAL; s1 stops after transaction
/// 1. With `checkpoint_first`, main's WAL was emptied after transaction 1,
/// so no page of transaction 2 has an earlier copy in the WAL. Then an
/// outside checkpointer copied transaction 2's page of `t` into main's
/// database file and died before the marker page and before nBackfill.
fn partialCheckpointImage(tmp: *std.testing.TmpDir, image: *Paths, checkpoint_first: bool) !void {
    var paths: Paths = .{};
    const main_path = try paths.add(&tmp.sub_path, "main.db");
    const s1_path = try paths.add(&tmp.sub_path, "s1.db");
    try createMember(main_path);
    try createMember(s1_path);
    const image_main = try image.add(&tmp.sub_path, "image-main.db");
    const image_s1 = try image.add(&tmp.sub_path, "image-s1.db");
    var buf: [2][300]u8 = undefined;
    var t_root: u32 = 0;
    {
        const conn = try cwal.Conn.open(paths.slice(), writer);
        defer conn.close();
        try crossCommit(conn, 1);
        t_root = try rootPage(conn, "t");
        try std.testing.expect(t_root != try rootPage(conn, "cwal_marker"));
        if (checkpoint_first) try conn.exec("pragma main.wal_checkpoint(TRUNCATE)");
        try copyFile(s1_path, image_s1);
        try copyFile(try std.fmt.bufPrint(&buf[0], "{s}-wal", .{s1_path}), try std.fmt.bufPrint(&buf[1], "{s}-wal", .{image_s1}));
        try crossCommit(conn, 2);
        try copyFile(main_path, image_main);
        try copyFile(try std.fmt.bufPrint(&buf[0], "{s}-wal", .{main_path}), try std.fmt.bufPrint(&buf[1], "{s}-wal", .{image_main}));
    }
    try copyFrameToDatabase(image_main, try std.fmt.bufPrint(&buf[1], "{s}-wal", .{image_main}), t_root);
}

test "R6: a torn page checkpointed without an earlier WAL copy refuses recovery" {
    registerOnce();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var image: Paths = .{};
    try partialCheckpointImage(&tmp, &image, true);
    // Transaction 1's version of the page is gone from both the database
    // file and the WAL, so recovery cannot roll back main.
    try expectOpenError(error.ProtocolViolation, image.slice(), writer);
}

test "R6: a torn page checkpointed over an earlier WAL copy is rolled back" {
    registerOnce();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var image: Paths = .{};
    try partialCheckpointImage(&tmp, &image, false);
    // Transaction 1's copy of the page stays in the WAL and overrides the
    // database file, so the rollback is complete.
    cwal.last_recovery = "none";
    const conn = try cwal.Conn.open(image.slice(), writer);
    defer conn.close();
    try std.testing.expectEqualStrings("rollback", cwal.last_recovery);
    try std.testing.expectEqual(@as(i64, 1), try count(conn, "select count(*) from main.t"));
    try std.testing.expectEqual(@as(i64, 1), try count(conn, "select count(*) from m1.t"));
    try std.testing.expect(try integrityOk(conn));
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
