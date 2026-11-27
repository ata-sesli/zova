//! A Zova set in the experimental cross-file commit protocol (CWAL): the open
//! path, and enabling and disabling the protocol
//! (notes/cwal-integration-260.md §3, §7, §8).
//!
//! Compiled in only with `-Dexperimental-cwal` on a 64-bit POSIX target
//! (`available`). Other builds refuse a CWAL set with
//! `UnsupportedZovaVersion` (commit_protocol.zig).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("zova_build_options");
const sqlite = @import("../sqlite.zig");

const StoreKind = @import("bound_stores.zig").StoreKind;
const commit_protocol = @import("commit_protocol.zig");
const loadBoundStoreRow = @import("bound_stores.zig").loadBoundStoreRow;
const setAttachedMetadataValue = @import("metadata.zig").setAttachedMetadataValue;
const Error = @import("types.zig").Error;
const OpenOptions = @import("types.zig").OpenOptions;
const mapSqliteResultCode = @import("metadata.zig").mapSqliteResultCode;
const paths = @import("paths.zig");

/// CWAL is compiled in. Build-option sets written outside build.zig
/// (generated C, WASM) do not declare `experimental_cwal`: off.
pub const available = @hasDecl(build_options, "experimental_cwal") and build_options.experimental_cwal and !paths.wasm_opfs and
    builtin.os.tag != .windows and @bitSizeOf(usize) == 64;

const cwal = if (available) @import("../cwal/cwal.zig") else struct {};

/// A CWAL set handle. It owns the SQLite connection that the Zova handle
/// borrows.
pub const Conn = if (available) cwal.Conn else opaque {};

const allocator = std.heap.c_allocator;

/// Members in their fixed order: main, then the bound stores in `StoreKind`
/// order (§3).
const max_set_members = 1 + std.meta.tags(StoreKind).len;

const Members = struct {
    len: usize = 0,
    paths: [max_set_members][:0]u8 = undefined,
    schemas: [max_set_members][:0]const u8 = undefined,

    fn deinit(self: *Members) void {
        for (self.paths[0..self.len]) |path| allocator.free(path);
    }

    fn add(self: *Members, path: []const u8, schema: [:0]const u8) Error!void {
        self.paths[self.len] = try allocator.dupeSentinel(u8, path, 0);
        self.schemas[self.len] = schema;
        self.len += 1;
    }
};

fn schemaNameZ(comptime kind: StoreKind) [:0]const u8 {
    return comptime std.fmt.comptimePrint("{s}", .{kind.schemaName()});
}

/// Read main's member list before anything opens the set: main's
/// `_zova_bound_stores` rows, read through an `immutable=1` connection that
/// takes no lock and neither reads nor maps `-wal` and `-shm`. A CWAL set's
/// membership changes only while every member is fully checkpointed, so the
/// database file holds the current list; the open path still compares it
/// with the list SQLite sees once the set is open
/// (`validateAttachedBoundStore`).
fn readMembers(main_path: [:0]const u8) Error!Members {
    var members: Members = .{};
    errdefer members.deinit();
    try members.add(main_path, "main");

    var db = try openImmutable(main_path);
    defer db.deinit();
    inline for (comptime std.meta.tags(StoreKind)) |kind| {
        if (try loadBoundStoreRow(allocator, &db, kind)) |found| {
            var row = found;
            defer row.deinit(allocator);
            if (!paths.isZovaPath(row.path)) return error.NotZovaPath;
            try paths.ensurePathExists(row.path);
            try members.add(row.path, schemaNameZ(kind));
        }
    }
    return members;
}

fn openImmutable(path: [:0]const u8) Error!sqlite.Database {
    var resolved_buffer: [std.c.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(path.ptr, &resolved_buffer) orelse return error.CantOpen;
    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(allocator);
    try uri.appendSlice(allocator, "file:");
    for (std.mem.span(resolved)) |byte| switch (byte) {
        '%', '?', '#' => try uri.print(allocator, "%{X:0>2}", .{byte}),
        else => try uri.append(allocator, byte),
    };
    try uri.appendSlice(allocator, "?immutable=1");
    try uri.append(allocator, 0);

    var raw: ?*sqlite.c.sqlite3 = null;
    const rc = sqlite.c.sqlite3_open_v2(uri.items.ptr, &raw, sqlite.c.SQLITE_OPEN_READONLY | sqlite.c.SQLITE_OPEN_URI, null);
    if (rc != sqlite.c.SQLITE_OK) {
        if (raw) |handle| _ = sqlite.c.sqlite3_close(handle);
        return mapSqliteResultCode(rc);
    }
    return .{ .handle = raw.? };
}

var registered = std.atomic.Value(u8).init(0);

/// Register the `cwal` VFS once per process.
fn ensureRegistered() void {
    if (registered.load(.acquire) == 2) return;
    if (registered.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        cwal.register();
        registered.store(2, .release);
        return;
    }
    while (registered.load(.acquire) != 2) std.atomic.spinLoopHint();
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.Sqlite => error.SqliteError,
        error.Io => error.CantOpen,
        error.Broken => error.CommitSetBroken,
        error.ProtocolViolation => error.CommitSetNeedsRepair,
        error.MemberOwned => error.MemberOwned,
        error.WriterBusy => error.Busy,
        else => error.SqliteError,
    };
}

/// Open the CWAL set whose main file is `path`: member ownership, the open
/// gate, recovery, then SQLite, with the bound stores attached under their
/// usual schema names. A read-write open is the set's one writer (a second
/// one gets `Busy`); a read-only open is a reader.
pub fn open(path: [:0]const u8, options: OpenOptions) Error!*Conn {
    if (!available) return error.UnsupportedZovaVersion;
    ensureRegistered();
    var members = try readMembers(path);
    defer members.deinit();
    var member_paths: [max_set_members][]const u8 = undefined;
    for (members.paths[0..members.len], 0..) |member, index| member_paths[index] = member;
    var cwal_options: cwal.Options = .{
        .mode = .cwal,
        .role = if (options.read_only) .reader else .writer,
        .schemas = members.schemas[0..members.len],
        .require_markers = true,
    };
    if (options.busy_timeout_ms != 0) cwal_options.busy_timeout_ms = std.math.cast(c_int, options.busy_timeout_ms) orelse std.math.maxInt(c_int);
    return cwal.Conn.open(member_paths[0..members.len], cwal_options) catch |err| mapError(err);
}

/// The SQLite connection a CWAL handle owns.
pub fn connection(conn: *Conn) sqlite.Database {
    return .{ .handle = conn.db.? };
}

/// Close a CWAL handle and the connection `db` borrowed from it.
pub fn close(conn: *Conn, db: *sqlite.Database) void {
    if (!available) unreachable;
    const cleanup = db.extension_sql_cleanup;
    const state = db.extension_sql_state;
    conn.close();
    if (cleanup) |run| run(state);
    db.extension_sql_state = null;
    db.extension_sql_cleanup = null;
}

pub fn isWriter(conn: *Conn) bool {
    if (!available) unreachable;
    return conn.role == .writer;
}

/// Transition steps, for tests that stop a transition where a crash could
/// (`test_stop`). A stopped transition leaves its durable state as it is and
/// sets its connection not to checkpoint on close, like a killed process.
pub const Step = enum {
    enable_key,
    enable_markers,
    enable_checkpoints,
    enable_flag_commit,
    disable_checkpoints,
    disable_flag_commit,
    disable_flag_checkpoint,
    disable_markers,
};

/// Test builds only: stop the next transition after this step.
pub var test_stop: ?Step = null;

fn stopAfter(db: *sqlite.Database, step: Step) Error!void {
    if (!builtin.is_test) return;
    if (test_stop != step) return;
    test_stop = null;
    _ = sqlite.c.sqlite3_db_config(db.handle, sqlite.c.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, @as(c_int, 1), @as(?*c_int, null));
    return error.Interrupt;
}

fn checkpointTruncate(db: *sqlite.Database, schema: [:0]const u8) Error!void {
    const result = try db.walCheckpoint(schema, .truncate);
    if (result.busy or result.log_frames != 0) return error.Busy;
}

fn execPrint(db: *sqlite.Database, comptime fmt: []const u8, args: anytype) Error!void {
    var buffer: [256]u8 = undefined;
    const sql = std.fmt.bufPrintSentinel(&buffer, fmt, args, 0) catch return error.Misuse;
    try db.exec(sql);
}

/// Enable CWAL on a plain set through its only connection, `db`, whose
/// attached members are `schemas` (main first). The caller then opens the
/// set again; it takes the CWAL path. Steps (§7, decision 9):
///
/// 1. Exclusive locking mode and one write transaction on every member: it
///    fails with `Busy` while any other connection has a member open. The
///    locks stay until the end, so no plain connection opens meanwhile.
/// 2. `commit_protocol` in main, then each member's marker table, each its
///    own synchronous commit: a marker table never exists without the key.
/// 3. A full TRUNCATE checkpoint of every member.
/// 4. `application_id` in main (one commit), then a TRUNCATE checkpoint of
///    main, so the raw header shows the flag. This is the commit point.
///
/// A crash before step 4's checkpoint leaves a plain set; one between its
/// commit and checkpoint is finished by the next open (`finishEnable`).
pub fn enable(db: *sqlite.Database, schemas: []const [:0]const u8) Error!void {
    if (!available) return error.UnsupportedZovaVersion;
    for (schemas) |schema| {
        var stmt = try db.prepare(blk: {
            var buffer: [96]u8 = undefined;
            break :blk std.fmt.bufPrintSentinel(&buffer, "pragma {s}.journal_mode", .{schema}, 0) catch return error.Misuse;
        });
        defer stmt.deinit();
        if (try stmt.step() != .row or !std.ascii.eqlIgnoreCase(stmt.columnText(0), "wal")) return error.Misuse;
    }

    try db.exec("pragma locking_mode=exclusive");
    defer {
        db.exec("pragma locking_mode=normal") catch {};
        // Normal mode releases the locks at the end of the next transaction.
        for (schemas) |schema| execPrint(db, "select count(*) from {s}.sqlite_schema", .{schema}) catch {};
    }
    for (schemas) |schema| try execPrint(db, "pragma {s}.synchronous=FULL", .{schema});

    try db.exec("begin immediate");
    {
        errdefer db.exec("rollback") catch {};
        try setAttachedMetadataValue(db, "main", commit_protocol.meta_key, commit_protocol.cwal_value);
        try db.exec("commit");
    }
    try stopAfter(db, .enable_key);

    for (schemas) |schema| {
        try db.exec("begin immediate");
        errdefer db.exec("rollback") catch {};
        try execPrint(db, "create table if not exists {s}._zova_cwal_marker(k integer primary key, txn integer not null, mask integer not null)", .{schema});
        try execPrint(db, "insert or ignore into {s}._zova_cwal_marker values (0, 0, 0)", .{schema});
        if (std.mem.eql(u8, schema, "main")) try db.exec("insert or ignore into main._zova_cwal_marker values (1, 0, 0)");
        try db.exec("commit");
    }
    try stopAfter(db, .enable_markers);

    for (schemas) |schema| try checkpointTruncate(db, schema);
    try stopAfter(db, .enable_checkpoints);

    try execPrint(db, "pragma main.application_id = {d}", .{commit_protocol.application_id});
    try stopAfter(db, .enable_flag_commit);
    try checkpointTruncate(db, "main");
}

/// Finish an enable that committed `application_id` but crashed before
/// checkpointing it (raw flag clear, SQLite flag set). No handle has opened
/// the set as CWAL, and every member was checkpointed with its marker
/// table, so a plain checkpoint of main is safe.
pub fn finishEnable(db: *sqlite.Database) Error!void {
    if (!available) return error.UnsupportedZovaVersion;
    try checkpointTruncate(db, "main");
}

/// Disable CWAL through the set's writer handle while no other handle has
/// the set open. The caller then opens the set again; it takes the plain
/// path. Steps (§7, decision 9):
///
/// 1. Hold `-alive` exclusively (`Busy` while another handle is open), and
///    run a full TRUNCATE checkpoint of every member. The writer handle
///    holds the writer lock, so no other handle can leave a torn commit.
/// 2. Clear `application_id` (one commit), then checkpoint main: the raw
///    flag is clear. This is the commit point.
/// 3. Drop every marker table, then clear `commit_protocol`.
///
/// A crash before step 2's checkpoint leaves a CWAL set; the next writer
/// open that finds the SQLite flag clear finishes the disable.
pub fn disable(conn: *Conn, db: *sqlite.Database) Error!void {
    if (!available) return error.UnsupportedZovaVersion;
    if (conn.role != .writer) return error.ReadOnly;
    if (!(conn.holdAlone() catch |err| return mapError(err))) return error.Busy;
    defer conn.releaseAlone() catch {};
    const schemas = conn.schemas[0..conn.nmembers];
    for (schemas) |schema| try checkpointTruncate(db, schema);
    try stopAfter(db, .disable_checkpoints);

    if (try commit_protocol.sqliteFlagSet(db)) try db.exec("pragma main.application_id = 0");
    try stopAfter(db, .disable_flag_commit);
    try checkpointTruncate(db, "main");
    try stopAfter(db, .disable_flag_checkpoint);

    for (schemas) |schema| {
        var buffer: [128]u8 = undefined;
        const sql = std.fmt.bufPrintSentinel(&buffer, "drop table if exists {s}._zova_cwal_marker", .{schema}, 0) catch return error.Misuse;
        conn.execInternal(sql) catch |err| return mapError(err);
    }
    try stopAfter(db, .disable_markers);
    try db.exec("delete from main._zova_meta where key = 'commit_protocol'");
}
