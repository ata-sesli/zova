//! Experimental CWAL sets (database/cwal_set.zig): the open path, enabling
//! and disabling the protocol, and every state a stopped transition leaves
//! (notes/cwal-integration-260.md §7). Real process kills are phase 7.

const std = @import("std");
const zova = @import("zova.zig");
const commit_protocol = @import("database/commit_protocol.zig");
const cwal_set = @import("database/cwal_set.zig");
const sqlite = @import("sqlite.zig");
const testingDbPath = @import("zova_test_support.zig").testingDbPath;

const Database = zova.Database;

const Paths = struct {
    main_buffer: [std.fs.max_path_bytes]u8 = undefined,
    store_buffer: [std.fs.max_path_bytes]u8 = undefined,
    main: [:0]const u8 = undefined,
    store: [:0]const u8 = undefined,

    fn init(self: *Paths, tmp: *std.testing.TmpDir) !void {
        self.main = try testingDbPath(&self.main_buffer, tmp.sub_path[0..], "main.zova");
        self.store = try testingDbPath(&self.store_buffer, tmp.sub_path[0..], "store.zova");
    }
};

/// A main file bound to a vector store, both in WAL mode, closed.
fn createWalSet(paths: *const Paths) !void {
    try zova.createVectorStore(paths.store);
    var db = try Database.create(paths.main);
    defer db.deinit();
    try db.bindVectorStore(paths.store);
    _ = try db.setJournalMode(.wal);
    try db.exec("create table t(x)");
}

/// `createWalSet`, then CWAL enabled.
fn createCwalSet(paths: *const Paths) !void {
    try createWalSet(paths);
    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.setCommitProtocol(.cwal);
}

fn queryCount(db: *Database, sql: [:0]const u8) !i64 {
    var stmt = try db.sqlite_db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expect(try stmt.step() == .row);
    return stmt.columnInt64(0);
}

fn markerTables(db: *Database) !i64 {
    return try queryCount(db, "select count(*) from main.sqlite_schema where name = '_zova_cwal_marker'") +
        try queryCount(db, "select count(*) from vector_store.sqlite_schema where name = '_zova_cwal_marker'");
}

/// The set opens read-write as a plain set, with nothing of CWAL left once
/// that open has finished or undone a stopped transition.
fn expectPlainAndClean(paths: *const Paths) !void {
    var db = try Database.open(paths.main);
    defer db.deinit();
    try std.testing.expect(!try commit_protocol.rawFlagSet(paths.main));
    try std.testing.expectEqual(Database.CommitProtocol.none, db.commitProtocol());
    try std.testing.expect(!try commit_protocol.mainDeclaresProtocol(&db.sqlite_db));
    try std.testing.expectEqual(@as(i64, 0), try markerTables(&db));
    try std.testing.expect(!try commit_protocol.sqliteFlagSet(&db.sqlite_db));
}

/// The set opens read-write as a CWAL set, once that open has finished a
/// stopped enable.
fn expectCwal(paths: *const Paths) !void {
    var db = try Database.open(paths.main);
    defer db.deinit();
    try std.testing.expect(try commit_protocol.rawFlagSet(paths.main));
    try std.testing.expectEqual(Database.CommitProtocol.cwal, db.commitProtocol());
    try std.testing.expectEqual(@as(i64, 2), try markerTables(&db));
}

test "a set enables CWAL, opens one writer and readers, and disables" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createWalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.setCommitProtocol(.cwal);
    try std.testing.expectEqual(Database.CommitProtocol.cwal, db.commitProtocol());
    try std.testing.expect(try commit_protocol.rawFlagSet(paths.main));
    try std.testing.expectEqual(@as(i64, 2), try markerTables(&db));
    try db.exec("insert into t values (1)");

    // One writer per set; readers share it.
    try std.testing.expectError(error.Busy, Database.open(paths.main));
    {
        var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
        defer reader.deinit();
        try std.testing.expectEqual(Database.CommitProtocol.cwal, reader.commitProtocol());
        try std.testing.expectEqual(@as(i64, 1), try queryCount(&reader, "select count(*) from t"));
        try std.testing.expectError(error.ReadOnly, reader.exec("insert into t values (2)"));
        try std.testing.expectError(error.ReadOnly, reader.setCommitProtocol(.none));
        // A membership change waits for disable.
        try std.testing.expectError(error.Misuse, db.unbindVectorStore());
        // Disable needs the set to itself.
        try std.testing.expectError(error.Busy, db.setCommitProtocol(.none));
    }

    try db.setCommitProtocol(.none);
    try std.testing.expectEqual(Database.CommitProtocol.none, db.commitProtocol());
    try std.testing.expectEqual(@as(i64, 1), try queryCount(&db, "select count(*) from t"));
    try std.testing.expectEqual(@as(i64, 0), try markerTables(&db));
    try std.testing.expect(!try commit_protocol.mainDeclaresProtocol(&db.sqlite_db));
    try std.testing.expect(!try commit_protocol.rawFlagSet(paths.main));
}

test "enable is refused while another handle has the set open" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createWalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    {
        var other = try Database.open(paths.main);
        defer other.deinit();
        try std.testing.expectError(error.Busy, db.setCommitProtocol(.cwal));
        try other.exec("insert into t values (1)");
    }
    try db.exec("begin");
    try std.testing.expectError(error.ObjectTransactionActive, db.setCommitProtocol(.cwal));
    try db.exec("rollback");
    try std.testing.expectEqual(Database.CommitProtocol.none, db.commitProtocol());
    try std.testing.expect(!try commit_protocol.mainDeclaresProtocol(&db.sqlite_db));
    try db.exec("insert into t values (2)");
    try db.setCommitProtocol(.cwal);
    try std.testing.expectEqual(@as(i64, 2), try queryCount(&db, "select count(*) from t"));
}

test "enable needs WAL mode on every member" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try zova.createVectorStore(paths.store);
    var db = try Database.create(paths.main);
    defer db.deinit();
    try db.bindVectorStore(paths.store);
    try std.testing.expectError(error.Misuse, db.setCommitProtocol(.cwal));
    try std.testing.expect(!try commit_protocol.mainDeclaresProtocol(&db.sqlite_db));
}

test "a flagged set without marker tables needs repair" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createWalSet(&paths);
    {
        var raw = try sqlite.Database.open(paths.main);
        defer raw.deinit();
        try raw.exec("pragma main.application_id = 1514362673; pragma wal_checkpoint(truncate)");
    }
    try std.testing.expectError(error.CommitSetNeedsRepair, Database.open(paths.main));
    try std.testing.expectError(error.CommitSetNeedsRepair, Database.openWithOptions(paths.main, .{ .read_only = true }));
}

test "an enable stopped at each step leaves a state the next open completes or undoes" {
    if (!cwal_set.available) return error.SkipZigTest;
    inline for (.{ .enable_key, .enable_markers, .enable_checkpoints, .enable_flag_commit }) |step| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths: Paths = .{};
        try paths.init(&tmp);
        try createWalSet(&paths);
        {
            var db = try Database.open(paths.main);
            defer db.deinit();
            cwal_set.test_stop = step;
            try std.testing.expectError(error.Interrupt, db.setCommitProtocol(.cwal));
        }
        try std.testing.expect(!try commit_protocol.rawFlagSet(paths.main));
        if (step == .enable_flag_commit) {
            // Past the commit point: a reader cannot finish it, a writer does.
            try std.testing.expectError(error.CommitSetNeedsRepair, Database.openWithOptions(paths.main, .{ .read_only = true }));
            try expectCwal(&paths);
        } else {
            try expectPlainAndClean(&paths);
            var db = try Database.open(paths.main);
            defer db.deinit();
            try db.setCommitProtocol(.cwal);
        }
    }
}

test "a disable stopped at each step leaves a state the next open completes or keeps" {
    if (!cwal_set.available) return error.SkipZigTest;
    inline for (.{ .disable_checkpoints, .disable_flag_commit, .disable_flag_checkpoint, .disable_markers }) |step| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths: Paths = .{};
        try paths.init(&tmp);
        try createCwalSet(&paths);
        {
            var db = try Database.open(paths.main);
            defer db.deinit();
            try db.exec("insert into t values (1)");
            cwal_set.test_stop = step;
            try std.testing.expectError(error.Interrupt, db.setCommitProtocol(.none));
        }
        switch (step) {
            .disable_checkpoints => try expectCwal(&paths),
            .disable_flag_commit => {
                // Before the commit point on disk: a reader opens the CWAL
                // set, the next writer alone finishes the disable.
                try std.testing.expect(try commit_protocol.rawFlagSet(paths.main));
                {
                    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
                    defer reader.deinit();
                    try std.testing.expectEqual(Database.CommitProtocol.cwal, reader.commitProtocol());
                }
                try expectPlainAndClean(&paths);
            },
            else => try expectPlainAndClean(&paths),
        }
        var db = try Database.open(paths.main);
        defer db.deinit();
        try std.testing.expectEqual(@as(i64, 1), try queryCount(&db, "select count(*) from t"));
    }
}

/// Row 0 of a member's marker table: the last cross-file transaction that
/// wrote it, and that transaction's member set.
fn marker(db: *Database, comptime schema: []const u8) ![2]i64 {
    var stmt = try db.sqlite_db.prepare("select txn, mask from " ++ schema ++ "._zova_cwal_marker where k = 0");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step() == .row);
    return .{ stmt.columnInt64(0), stmt.columnInt64(1) };
}

/// Both members carry the same new marker, for main and the vector store.
fn expectNewMarker(db: *Database, previous: i64) !i64 {
    const main_marker = try marker(db, "main");
    try std.testing.expectEqual(main_marker, try marker(db, "vector_store"));
    try std.testing.expectEqual(@as(i64, 0b11), main_marker[1]);
    try std.testing.expect(main_marker[0] > previous);
    return main_marker[0];
}

test "Zova's commit points write markers in every member a transaction writes" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    {
        var db = try Database.open(paths.main);
        defer db.deinit();
        // An internal immediate transaction: the collection and main's
        // bound-store epoch.
        try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
        var txn = try expectNewMarker(&db, 0);

        // A caller transaction, committed.
        try db.begin();
        try db.exec("insert into t values (1)");
        try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
        try db.commit();
        txn = try expectNewMarker(&db, txn);

        // An outermost savepoint, released.
        try db.savepoint("outer");
        try db.exec("insert into t values (2)");
        try db.putVector("v", "b", .{ .f32 = &.{ 3, 4 } });
        try db.releaseSavepoint("outer");
        txn = try expectNewMarker(&db, txn);

        // A single-file write needs no markers.
        try db.exec("insert into t values (3)");
        try std.testing.expectEqual(txn, (try marker(&db, "main"))[0]);
    }
    var db = try Database.open(paths.main);
    defer db.deinit();
    try std.testing.expectEqual(@as(i64, 3), try queryCount(&db, "select count(*) from t"));
    try std.testing.expect(try db.hasVector("v", "a"));
    try std.testing.expect(try db.hasVector("v", "b"));
}

test "a cross-file write committed by SQL text is refused and rolled back" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    try db.exec("begin");
    try db.exec("insert into t values (1)");
    try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
    try std.testing.expectError(error.Misuse, db.exec("commit"));
    try std.testing.expect(sqlite.c.sqlite3_get_autocommit(db.sqlite_db.handle) != 0);
    try std.testing.expectEqual(@as(i64, 0), try queryCount(&db, "select count(*) from t"));
    try std.testing.expect(!try db.hasVector("v", "a"));

    // Single-file transactions in SQL text commit as before.
    try db.exec("begin; insert into t values (2); commit");
    try std.testing.expectEqual(@as(i64, 1), try queryCount(&db, "select count(*) from t"));
}

test "a reader's transaction sees every member at one commit" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
    defer reader.deinit();
    try std.testing.expectError(error.ReadOnly, reader.beginImmediate());

    try reader.begin();
    try db.begin();
    try db.exec("insert into t values (1)");
    try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
    try db.commit();
    // The reader's transaction started before that commit, on both members.
    try std.testing.expect(!try reader.hasVector("v", "a"));
    try std.testing.expectEqual(@as(i64, 0), try queryCount(&reader, "select count(*) from t"));
    try reader.commit();
    try std.testing.expect(try reader.hasVector("v", "a"));
    try std.testing.expectEqual(@as(i64, 1), try queryCount(&reader, "select count(*) from t"));
}

var inner_calls: usize = 0;

/// Denies inserts into `t`, counting every call.
fn denyInsertsIntoT(_: ?*anyopaque, action: c_int, first: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    inner_calls += 1;
    if (action == sqlite.c.SQLITE_INSERT and first != null and std.mem.eql(u8, std.mem.span(first), "t")) return sqlite.c.SQLITE_DENY;
    return sqlite.c.SQLITE_OK;
}

test "an authorizer set on a CWAL handle runs after CWAL's checks, which stay" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    const marker_write = "update main._zova_cwal_marker set txn = 0 where k = 0";
    try std.testing.expectError(error.SqliteError, db.exec(marker_write));

    // A statement prepared before the authorizer changes is authorized
    // again when it next runs.
    var insert = try db.sqlite_db.prepare("insert into t values (1)");
    defer insert.deinit();
    inner_calls = 0;
    // Through a fresh wrapper, as extension code builds one.
    var wrapper: sqlite.Database = .{ .handle = db.sqlite_db.handle };
    try wrapper.setAuthorizer(denyInsertsIntoT, null);
    try std.testing.expectError(error.SqliteError, insert.step());
    try std.testing.expect(inner_calls > 0);
    try std.testing.expectError(error.SqliteError, db.exec(marker_write));
    try std.testing.expectEqual(@as(i64, 0), try queryCount(&db, "select count(*) from t"));

    try wrapper.setAuthorizer(null, null);
    insert.reset() catch {};
    try std.testing.expect(try insert.step() == .done);
    try std.testing.expectError(error.SqliteError, db.exec(marker_write));
    try std.testing.expectError(error.SqliteError, db.exec("pragma journal_mode = delete"));
    try std.testing.expectEqual(@as(i64, 1), try queryCount(&db, "select count(*) from t"));
}

/// One cross-file transaction on the writer: row `i` in `t` and vector `i`.
fn crossCommit(db: *Database, i: u32) !void {
    var sql_buffer: [64]u8 = undefined;
    var id_buffer: [16]u8 = undefined;
    try db.begin();
    errdefer db.rollback() catch {};
    try db.exec(try std.fmt.bufPrintSentinel(&sql_buffer, "insert into t values ({d})", .{i}, 0));
    try db.putVector("v", try std.fmt.bufPrint(&id_buffer, "{d}", .{i}), .{ .f32 = &.{ 1, 2 } });
    try db.commit();
}

/// Whether row `i` of `t` and vector `i` are both present or both absent.
fn expectWhole(db: *Database, i: u32) !bool {
    var sql_buffer: [64]u8 = undefined;
    var id_buffer: [16]u8 = undefined;
    const row = try queryCount(db, try std.fmt.bufPrintSentinel(&sql_buffer, "select count(*) from t where x = {d}", .{i}, 0)) == 1;
    const vector = try db.hasVector("v", try std.fmt.bufPrint(&id_buffer, "{d}", .{i}));
    try std.testing.expectEqual(row, vector);
    return row;
}

test "a reader savepoint reads every member at one commit" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
    defer reader.deinit();

    try reader.savepoint("r");
    // Reading main first: SQLite would start the store's read only later.
    try std.testing.expectEqual(@as(i64, 0), try queryCount(&reader, "select count(*) from t"));
    try crossCommit(&db, 1);
    try std.testing.expect(!try expectWhole(&reader, 1));
    try reader.releaseSavepoint("r");
    try std.testing.expect(try expectWhole(&reader, 1));
}

var peek_writer: ?*Database = null;
var peek_reader: ?*Database = null;

/// SQL function for the test below: commit a cross-file transaction on the
/// writer, then report whether the reader sees its vector. The statement
/// that calls it has already started its read of main.
fn commitThenPeek(context: ?*sqlite.c.sqlite3_context, _: c_int, _: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    crossCommit(peek_writer.?, 1) catch return sqlite.c.sqlite3_result_error(context, "commit failed", -1);
    const seen = peek_reader.?.hasVector("v", "1") catch return sqlite.c.sqlite3_result_error(context, "peek failed", -1);
    sqlite.c.sqlite3_result_int(context, @intFromBool(seen));
}

test "an autocommit select on a reader reads every member at one commit" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
    defer reader.deinit();
    peek_writer = &db;
    peek_reader = &reader;
    defer peek_writer = null;
    defer peek_reader = null;
    try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_create_function_v2(reader.sqlite_db.handle, "cwal_test_commit_then_peek", 0, sqlite.c.SQLITE_UTF8, null, commitThenPeek, null, null, null));

    var stmt = try reader.sqlite_db.prepare("select (select count(*) from main.t), cwal_test_commit_then_peek()");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step() == .row);
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt64(0));
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt64(1));
    try std.testing.expect(try stmt.step() == .done);
    try std.testing.expect(sqlite.c.sqlite3_get_autocommit(reader.sqlite_db.handle) != 0);
    try std.testing.expect(try expectWhole(&reader, 1));
}

const BackupCommits = struct {
    writer: *Database,
    next: u32 = 0,

    fn report(context: ?*anyopaque, progress: @import("database/types.zig").Progress) zova.Error!void {
        const self: *BackupCommits = @ptrCast(@alignCast(context.?));
        if (progress.phase != .copy) return;
        crossCommit(self.writer, self.next) catch return error.SqliteError;
        self.next += 1;
    }
};

test "a backup taken during cross-file commits holds each commit whole" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "backup.zova");

    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    var commits: BackupCommits = .{ .writer = &db };
    try crossCommit(&db, commits.next);
    commits.next += 1;
    {
        var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
        defer reader.deinit();
        try reader.backupTo(backup_path, .{ .progress = .{ .context = &commits, .report = BackupCommits.report } });
    }
    // Commits ran while the copy was in progress.
    try std.testing.expect(commits.next > 2);

    var copy = try Database.open(backup_path);
    defer copy.deinit();
    var present: u32 = 0;
    for (0..commits.next) |i| present += @intFromBool(try expectWhole(&copy, @intCast(i)));
    try std.testing.expect(present >= 1);
}

test "raw SQL VACUUM on a CWAL handle fails and leaves the set valid" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);
    var into_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const into_path = try testingDbPath(&into_buffer, tmp.sub_path[0..], "into.zova");
    var into_sql_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const into_sql = try std.fmt.bufPrintSentinel(&into_sql_buffer, "vacuum into '{s}'", .{into_path}, 0);

    {
        var db = try Database.open(paths.main);
        defer db.deinit();
        try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
        try crossCommit(&db, 1);
        try std.testing.expectError(error.SqliteError, db.exec("vacuum"));
        try std.testing.expectError(error.SqliteError, db.exec("vacuum vector_store"));
        try std.testing.expectError(error.SqliteError, db.exec(into_sql));
        try std.testing.expect(sqlite.c.sqlite3_get_autocommit(db.sqlite_db.handle) != 0);
        var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
        defer reader.deinit();
        try std.testing.expectError(error.SqliteError, reader.exec("vacuum"));
        try std.testing.expectError(error.SqliteError, reader.exec(into_sql));
    }
    try std.testing.expect(std.c.access(into_path.ptr, 0) != 0);
    try expectCwal(&paths);
    var db = try Database.open(paths.main);
    defer db.deinit();
    try std.testing.expect(try expectWhole(&db, 1));
    for ([_][:0]const u8{ "pragma main.integrity_check", "pragma vector_store.integrity_check" }) |sql| {
        var check = try db.sqlite_db.prepare(sql);
        defer check.deinit();
        try std.testing.expect(try check.step() == .row);
        try std.testing.expectEqualStrings("ok", check.columnText(0));
    }
    try crossCommit(&db, 2);
}

test "a refused cross-file commit returns Misuse through exec and through a statement" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    for (0..2) |way| {
        try db.exec("begin");
        try db.exec("insert into t values (1)");
        try db.putVector("v", "1", .{ .f32 = &.{ 1, 2 } });
        if (way == 0) {
            try std.testing.expectError(error.Misuse, db.exec("commit"));
        } else {
            var commit = try db.sqlite_db.prepare("commit");
            defer commit.deinit();
            try std.testing.expectError(error.Misuse, commit.step());
        }
        try std.testing.expect(sqlite.c.sqlite3_get_autocommit(db.sqlite_db.handle) != 0);
        try std.testing.expect(!try expectWhole(&db, 1));
    }
}


fn expectIntegrity(db: *Database) !void {
    for ([_][:0]const u8{ "pragma main.integrity_check", "pragma vector_store.integrity_check" }) |sql| {
        var check = try db.sqlite_db.prepare(sql);
        defer check.deinit();
        try std.testing.expect(try check.step() == .row);
        try std.testing.expectEqualStrings("ok", check.columnText(0));
    }
}

test "checkpoint copies frames on the writer and reports busy on a reader" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    try crossCommit(&db, 1);
    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
    defer reader.deinit();

    for ([_]zova.CheckpointMode{ .passive, .truncate }) |mode| {
        const refused = try reader.checkpoint(mode);
        try std.testing.expectEqual(@as(usize, 2), refused.count);
        for (refused.members()) |member| {
            try std.testing.expect(member.busy);
            try std.testing.expectEqual(@as(u64, 0), member.checkpointed_frames);
        }
    }
    const done = try db.checkpoint(.passive);
    try std.testing.expectEqual(@as(usize, 2), done.count);
    for (done.members()) |member| {
        try std.testing.expect(!member.busy);
        try std.testing.expect(member.wal_frames > 0);
        try std.testing.expectEqual(member.wal_frames, member.checkpointed_frames);
    }
    try std.testing.expect(try expectWhole(&reader, 1));
}

test "reclaimSpace releases free pages on the writer and is read-only on a reader" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    try crossCommit(&db, 1);
    try db.exec("create table big(b)");
    try db.exec("insert into big values (zeroblob(400000))");
    try db.exec("drop table big");
    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
    defer reader.deinit();

    try std.testing.expectError(error.ReadOnly, reader.reclaimSpace(.{}));
    const result = try db.reclaimSpace(.{});
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expect(result.members()[0].pages_released > 0);
    for (result.members()) |member| try std.testing.expectEqual(@as(u64, 0), member.free_pages_left);
    try std.testing.expect(try expectWhole(&reader, 1));
    try crossCommit(&db, 2);
}

test "setJournalMode on a CWAL set keeps WAL and refuses other modes" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    var db = try Database.open(paths.main);
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
    defer reader.deinit();

    const report = try db.setJournalMode(.wal);
    try std.testing.expectEqual(@as(usize, 2), report.count);
    for (report.members()) |member| try std.testing.expectEqual(zova.JournalMode.wal, member.journal_mode);
    for ([_]zova.JournalMode{ .delete, .truncate, .persist }) |mode| {
        try std.testing.expectError(error.Misuse, db.setJournalMode(mode));
        try std.testing.expectError(error.ReadOnly, reader.setJournalMode(mode));
    }
    try std.testing.expectError(error.ReadOnly, reader.setJournalMode(.wal));
    for ((try db.journalModes()).members()) |member| try std.testing.expectEqual(zova.JournalMode.wal, member.journal_mode);
    try crossCommit(&db, 1);
    try std.testing.expect(try expectWhole(&reader, 1));
}

test "vacuum on the writer rebuilds main as one single-file commit" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    {
        var db = try Database.open(paths.main);
        defer db.deinit();
        try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
        for (1..4) |i| try crossCommit(&db, @intCast(i));
        try db.exec("create table big(b)");
        try db.exec("insert into big values (zeroblob(400000))");
        try db.exec("drop table big");
        var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
        defer reader.deinit();
        try std.testing.expect(try queryCount(&db, "pragma main.freelist_count") > 0);

        try std.testing.expectError(error.ReadOnly, reader.vacuum());
        // Inside a transaction SQLite refuses VACUUM; the next commit still
        // goes through the commit hook.
        try db.begin();
        try std.testing.expectError(error.SqliteError, db.vacuum());
        try db.rollback();
        try crossCommit(&db, 4);

        const conn = db.cwal_conn.?;
        const commits = conn.stats.commits;
        try db.vacuum();
        try std.testing.expectEqual(commits + 1, conn.stats.commits);
        try std.testing.expect(!conn.in_commit and !conn.window_open);
        try std.testing.expectEqual(@as(i64, 0), try queryCount(&db, "pragma main.freelist_count"));
        for (1..5) |i| try std.testing.expect(try expectWhole(&reader, @intCast(i)));
        // VACUUM may move the marker table: later cross-file commits and
        // recovery read its root page again.
        try crossCommit(&db, 5);
        try std.testing.expect(try expectWhole(&reader, 5));
    }
    try expectCwal(&paths);
    var db = try Database.open(paths.main);
    defer db.deinit();
    for (1..6) |i| try std.testing.expect(try expectWhole(&db, @intCast(i)));
    try expectIntegrity(&db);
}

test "compactTo on the writer writes a standalone plain copy" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);
    var out_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const out = try testingDbPath(&out_buffer, tmp.sub_path[0..], "compact.zova");
    var reader_out_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const reader_out = try testingDbPath(&reader_out_buffer, tmp.sub_path[0..], "reader-compact.zova");

    {
        var db = try Database.open(paths.main);
        defer db.deinit();
        try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
        for (1..3) |i| try crossCommit(&db, @intCast(i));
        var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
        defer reader.deinit();
        // VACUUM INTO cannot run inside the read that would hold the
        // members at one commit.
        try std.testing.expectError(error.ReadOnly, reader.compactTo(reader_out, .{}));
        try std.testing.expect(std.c.access(reader_out.ptr, 0) != 0);

        try db.compactTo(out, .{});
        try crossCommit(&db, 3);
    }
    try expectCwal(&paths);
    try std.testing.expect(!try commit_protocol.rawFlagSet(out));
    var copy = try Database.open(out);
    defer copy.deinit();
    try std.testing.expectEqual(Database.CommitProtocol.none, copy.commitProtocol());
    try std.testing.expect(!try commit_protocol.mainDeclaresProtocol(&copy.sqlite_db));
    try std.testing.expectEqual(@as(i64, 0), try queryCount(&copy, "select count(*) from sqlite_schema where name = '_zova_cwal_marker'"));
    try std.testing.expectEqual(@as(i64, 2), try queryCount(&copy, "select count(*) from t"));
    try std.testing.expect(try copy.hasVector("v", "1"));
    try std.testing.expect(try copy.hasVector("v", "2"));
    try std.testing.expect(!try copy.hasVector("v", "3"));
}

test "migrating a CWAL set finds no migration path" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);
    var out_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const out = try testingDbPath(&out_buffer, tmp.sub_path[0..], "migrated.zova");

    try std.testing.expectError(error.NoMigrationPath, zova.migrateDatabase(paths.main, out, .{}));
    try std.testing.expect(std.c.access(out.ptr, 0) != 0);
    try expectCwal(&paths);
}

test "markers are torn when a member lists another member with an older marker" {
    const Member = cwal_set.MemberState;
    const whole = [_]Member{
        .{ .schema = "main", .marker_txn = 3, .marker_mask = 0b11 },
        .{ .schema = "vector_store", .marker_txn = 3, .marker_mask = 0b11 },
    };
    try std.testing.expect(!cwal_set.markersTorn(&whole));
    // A later single-member commit leaves the markers as they were; a later
    // cross-file commit of other members raises only theirs.
    const later = [_]Member{
        .{ .schema = "main", .marker_txn = 5, .marker_mask = 0b101 },
        .{ .schema = "object_store", .marker_txn = 3, .marker_mask = 0b011 },
        .{ .schema = "vector_store", .marker_txn = 5, .marker_mask = 0b101 },
    };
    try std.testing.expect(!cwal_set.markersTorn(&later));
    const torn = [_]Member{
        .{ .schema = "main", .marker_txn = 3, .marker_mask = 0b11 },
        .{ .schema = "vector_store", .marker_txn = 2, .marker_mask = 0b11 },
    };
    try std.testing.expect(cwal_set.markersTorn(&torn));
}

test "cwalState reports a reader beside the writer, and null on a plain set" {
    if (!cwal_set.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    try paths.init(&tmp);
    try createCwalSet(&paths);

    var writer = try Database.open(paths.main);
    defer writer.deinit();
    try writer.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    try crossCommit(&writer, 1);
    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
    defer reader.deinit();

    const state = (try reader.cwalState()).?;
    try std.testing.expect(!state.writer and state.writer_present);
    try std.testing.expect(!state.window_open and !state.broken and !state.torn);
    const members = state.memberSlice();
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("main", members[0].schema);
    try std.testing.expectEqualStrings("vector_store", members[1].schema);
    try std.testing.expectEqual(members[0].marker_txn, members[1].marker_txn);
    try std.testing.expectEqual(@as(i64, 0b11), members[1].marker_mask);
    try std.testing.expect((try writer.cwalState()).?.writer);

    var plain_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const plain_path = try testingDbPath(&plain_buffer, tmp.sub_path[0..], "plain.zova");
    var plain = try Database.create(plain_path);
    defer plain.deinit();
    try std.testing.expect(try plain.cwalState() == null);
    try std.testing.expectEqual(Database.CommitProtocol.cwal, try zova.probeCommitProtocol(paths.main));
    try std.testing.expectEqual(Database.CommitProtocol.none, try zova.probeCommitProtocol(plain_path));
}
