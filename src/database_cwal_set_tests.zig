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
