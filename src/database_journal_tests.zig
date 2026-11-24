//! Journal mode and checkpoint calls over a whole database set (#258).

const Database = @import("zova.zig").Database;
const JournalMode = @import("zova.zig").JournalMode;
const JournalModeReport = @import("zova.zig").JournalModeReport;
const createGraphStore = @import("zova.zig").createGraphStore;
const createObjectStore = @import("zova.zig").createObjectStore;
const createVectorStore = @import("zova.zig").createVectorStore;
const sqlite = @import("sqlite.zig");
const std = @import("std");
const testingCount = @import("zova_test_support.zig").testingCount;
const testingDbPath = @import("zova_test_support.zig").testingDbPath;

const Paths = struct {
    main_buffer: [std.fs.max_path_bytes]u8 = undefined,
    object_buffer: [std.fs.max_path_bytes]u8 = undefined,
    vector_buffer: [std.fs.max_path_bytes]u8 = undefined,
    graph_buffer: [std.fs.max_path_bytes]u8 = undefined,
    main: [:0]u8 = undefined,
    graph: [:0]u8 = undefined,
};

/// Create a main database with one bound store of each kind.
fn createBoundSet(paths: *Paths, sub_path: []const u8) !Database {
    paths.main = try testingDbPath(&paths.main_buffer, sub_path, "main.zova");
    const object_path = try testingDbPath(&paths.object_buffer, sub_path, "objects.zova");
    const vector_path = try testingDbPath(&paths.vector_buffer, sub_path, "vectors.zova");
    paths.graph = try testingDbPath(&paths.graph_buffer, sub_path, "graphs.zova");
    var db = try Database.create(paths.main);
    errdefer db.deinit();
    try createObjectStore(object_path);
    try createVectorStore(vector_path);
    try createGraphStore(paths.graph);
    try db.bindObjectStore(object_path);
    try db.bindVectorStore(vector_path);
    try db.bindGraphStore(paths.graph);
    return db;
}

fn expectModes(report: JournalModeReport, expected: JournalMode, count: usize) !void {
    try std.testing.expectEqual(count, report.members().len);
    for (report.members()) |entry| try std.testing.expectEqual(expected, entry.journal_mode);
    try std.testing.expect(report.uniform());
}

test "journal modes report every member of a bound set in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    var db = try createBoundSet(&paths, tmp.sub_path[0..]);
    defer db.deinit();

    const report = try db.journalModes();
    try expectModes(report, .delete, 4);
    try std.testing.expectEqual(.main, report.members()[0].member);
    try std.testing.expectEqual(.object_store, report.members()[1].member);
    try std.testing.expectEqual(.vector_store, report.members()[2].member);
    try std.testing.expectEqual(.graph_store, report.members()[3].member);
}

test "setJournalMode switches every member and WAL persists across handles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    {
        var db = try createBoundSet(&paths, tmp.sub_path[0..]);
        defer db.deinit();
        try expectModes(try db.setJournalMode(.wal), .wal, 4);
        try expectModes(try db.journalModes(), .wal, 4);
    }
    {
        var db = try Database.open(paths.main);
        defer db.deinit();
        try expectModes(try db.journalModes(), .wal, 4);
        try expectModes(try db.setJournalMode(.truncate), .truncate, 4);
        try expectModes(try db.setJournalMode(.delete), .delete, 4);
    }
    {
        var db = try Database.open(paths.main);
        defer db.deinit();
        try expectModes(try db.journalModes(), .delete, 4);
    }
}

test "setJournalMode restores switched members when a later member refuses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    var db = try createBoundSet(&paths, tmp.sub_path[0..]);
    defer db.deinit();
    _ = try db.setJournalMode(.wal);

    // A second connection reading only the graph store keeps that file in WAL
    // mode, so leaving WAL fails at the last member.
    var other = try sqlite.Database.open(paths.graph);
    defer other.deinit();
    try other.exec("select count(*) from sqlite_master");

    try std.testing.expectError(error.Busy, db.setJournalMode(.delete));
    try expectModes(try db.journalModes(), .wal, 4);
}

test "journal modes detect a set whose members differ" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    var db = try createBoundSet(&paths, tmp.sub_path[0..]);
    defer db.deinit();
    try db.exec("pragma graph_store.journal_mode=wal");

    const report = try db.journalModes();
    try std.testing.expect(!report.uniform());
    try std.testing.expectEqual(JournalMode.delete, report.members()[0].journal_mode);
    try std.testing.expectEqual(JournalMode.wal, report.members()[3].journal_mode);
}

test "checkpoint reports WAL frames per member" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    var db = try createBoundSet(&paths, tmp.sub_path[0..]);
    defer db.deinit();

    // Not in WAL mode: every member reports zero frames.
    const rollback = try db.checkpoint(.passive);
    try std.testing.expectEqual(@as(usize, 4), rollback.members().len);
    for (rollback.members()) |entry| {
        try std.testing.expectEqual(JournalMode.delete, entry.journal_mode);
        try std.testing.expect(!entry.busy);
        try std.testing.expectEqual(@as(u64, 0), entry.wal_frames);
        try std.testing.expectEqual(@as(u64, 0), entry.checkpointed_frames);
    }

    _ = try db.setJournalMode(.wal);
    try db.exec("create table records(id integer primary key, body text)");
    try db.exec("insert into records(body) values('one')");
    _ = try db.putObject("object body");
    try db.kvPut("ns", "key", "value");

    const passive = try db.checkpoint(.passive);
    const main = passive.members()[0];
    try std.testing.expectEqual(JournalMode.wal, main.journal_mode);
    try std.testing.expect(!main.busy);
    try std.testing.expect(main.wal_frames > 0);
    try std.testing.expectEqual(main.wal_frames, main.checkpointed_frames);
    try std.testing.expect(passive.members()[1].wal_frames > 0);

    const truncated = try db.checkpoint(.truncate);
    for (truncated.members()) |entry| {
        try std.testing.expect(!entry.busy);
        try std.testing.expectEqual(@as(u64, 0), entry.wal_frames);
    }
}

test "create option selects the journal mode of a new file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testingDbPath(&buffer, tmp.sub_path[0..], "wal.zova");
    {
        var db = try Database.createWithOptions(path, .{ .page_size = 8192, .journal_mode = .wal });
        defer db.deinit();
        try expectModes(try db.journalModes(), .wal, 1);
    }
    {
        var db = try Database.open(path);
        defer db.deinit();
        try expectModes(try db.journalModes(), .wal, 1);
        try std.testing.expectEqual(@as(i64, 8192), try testingCount(&db, "pragma page_size"));
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "pragma auto_vacuum"));
    }

    var other_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const rejected = try testingDbPath(&other_buffer, tmp.sub_path[0..], "off.zova");
    try std.testing.expectError(error.InvalidArgument, Database.createWithOptions(rejected, .{ .journal_mode = .off }));
    try std.testing.expectError(error.InvalidArgument, Database.createWithOptions(":memory:", .{ .journal_mode = .wal }));
}

test "journal calls reject unsupported modes, transactions, read-only and memory handles" {
    var memory = try Database.createWithOptions(":memory:", .{});
    defer memory.deinit();
    try expectModes(try memory.journalModes(), .memory, 1);
    try std.testing.expectError(error.InvalidArgument, memory.setJournalMode(.wal));
    try std.testing.expectError(error.InvalidArgument, memory.setJournalMode(.off));
    try std.testing.expectError(error.InvalidArgument, memory.setJournalMode(.memory));
    try expectModes(try memory.journalModes(), .memory, 1);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: Paths = .{};
    var db = try createBoundSet(&paths, tmp.sub_path[0..]);
    defer db.deinit();

    try db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.setJournalMode(.wal));
    try std.testing.expectError(error.ObjectTransactionActive, db.checkpoint(.passive));
    try expectModes(try db.journalModes(), .delete, 4);
    try db.rollback();

    var reader = try Database.openWithOptions(paths.main, .{ .read_only = true });
    defer reader.deinit();
    try std.testing.expectError(error.ReadOnly, reader.setJournalMode(.wal));
    try expectModes(try reader.journalModes(), .delete, 4);
    _ = try reader.checkpoint(.passive);
}
