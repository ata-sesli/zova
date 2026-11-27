//! On-disk markers of the experimental cross-file commit protocol (CWAL).
//!
//! A set in CWAL mode carries three durable markers (notes/cwal-integration-260.md §7):
//! the `_zova_cwal_marker` table in every member, `_zova_meta` key
//! `commit_protocol = 'cwal-1'` in main, and SQLite's `application_id` header
//! field in main, which is readable before SQLite opens the file.
//!
//! Enabling sets `commit_protocol` before it creates any marker table, and
//! disabling drops every marker table before it clears the key. So a marker
//! table never exists without the key, at any crash point, and validation can
//! require the key. The key without marker tables is an interrupted transition
//! and stays valid.
//!
//! The CWAL open path is not integrated yet. Until it is, every build refuses
//! a set whose `application_id` holds the CWAL value with
//! `UnsupportedZovaVersion`, without letting SQLite checkpoint it, because a
//! plain open would act as an outsider and could checkpoint a torn commit.

const std = @import("std");
const sqlite = @import("../sqlite.zig");

const Error = @import("types.zig").Error;
const metadataValueAlloc = @import("metadata.zig").metadataValueAlloc;
const prepareSchemaSql = @import("metadata.zig").prepareSchemaSql;
const schemaSqlEqual = @import("metadata.zig").schemaSqlEqual;
const wasm_opfs = @import("paths.zig").wasm_opfs;

/// First storage format that knows the protocol.
pub const first_format_version: u32 = 15;

/// `_zova_meta` key in main that names the commit protocol.
pub const meta_key = "commit_protocol";
/// The only protocol value format 15 defines.
pub const cwal_value = "cwal-1";

pub const marker_table = "_zova_cwal_marker";
/// Row 0 holds `(txn, mask)` in every member; row 1 holds main's writer epoch.
pub const marker_schema_sql = "create table _zova_cwal_marker(k integer primary key, txn integer not null, mask integer not null)";

/// SQLite `application_id` of a CWAL set's main file: ASCII "ZCW1".
pub const application_id: i32 = 0x5A435731;

const sqlite_header_magic = "SQLite format 3\x00";
const application_id_offset = 68;

/// Whether main's raw database header holds the CWAL `application_id`.
///
/// Reads the first 100 bytes without SQLite, so it sees only checkpointed
/// content. A file shorter than a SQLite header, or one without SQLite's
/// magic, is not a CWAL set; SQLite reports what it is.
pub fn rawFlagSet(path: [:0]const u8) Error!bool {
    if (wasm_opfs) return false;
    const io = @import("paths.zig").defaultIo();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.CantOpen,
    };
    defer file.close(io);
    var header: [100]u8 = undefined;
    const read = file.readPositional(io, &.{&header}, 0) catch return error.CantOpen;
    if (read < header.len) return false;
    return headerHasFlag(&header);
}

pub fn headerHasFlag(header: *const [100]u8) bool {
    if (!std.mem.eql(u8, header[0..sqlite_header_magic.len], sqlite_header_magic)) return false;
    return std.mem.readInt(i32, header[application_id_offset..][0..4], .big) == application_id;
}

/// Refuse a CWAL set before SQLite opens it.
pub fn refuseRawFlag(path: [:0]const u8) Error!void {
    if (try rawFlagSet(path)) return error.UnsupportedZovaVersion;
}

/// Refuse a CWAL set whose flag SQLite sees, including a flag that is still
/// only in the WAL. The connection is set not to checkpoint when it closes,
/// so refusing never copies WAL content into the database file.
pub fn refuseSqliteFlag(db: *sqlite.Database) Error!void {
    const value = readApplicationId(db) catch |err| switch (err) {
        error.SqliteError => return error.NotZovaDatabase,
        else => return err,
    };
    if (value != application_id) return;
    _ = sqlite.c.sqlite3_db_config(db.handle, sqlite.c.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, @as(c_int, 1), @as(?*c_int, null));
    return error.UnsupportedZovaVersion;
}

/// Whether main's `application_id`, as SQLite sees it (including a value
/// still only in the WAL), is the CWAL flag.
pub fn sqliteFlagSet(db: *sqlite.Database) Error!bool {
    const value = readApplicationId(db) catch |err| switch (err) {
        error.SqliteError => return error.NotZovaDatabase,
        else => return err,
    };
    return value == application_id;
}

/// Remove what an enable that never committed its flag, or a disable that
/// committed it, left on a plain set: every member's marker table, then
/// main's key (decision 9 keeps "no marker table without the key").
/// `schemas` are the attached members, main first.
pub fn removeLeftovers(db: *sqlite.Database, schemas: []const [:0]const u8) Error!void {
    for (schemas) |schema| {
        var buffer: [96]u8 = undefined;
        const sql = std.fmt.bufPrintSentinel(&buffer, "drop table if exists {s}." ++ marker_table, .{schema}, 0) catch return error.Misuse;
        try db.exec(sql);
    }
    try db.exec("delete from main._zova_meta where key = '" ++ meta_key ++ "'");
}

fn readApplicationId(db: *sqlite.Database) Error!i64 {
    var stmt = try db.prepare("pragma main.application_id");
    defer stmt.deinit();
    if (try stmt.step() != .row) return error.NotZovaDatabase;
    return stmt.columnInt64(0);
}

/// Whether main's `_zova_meta` declares the CWAL protocol. Any other value is
/// not a format-15 file.
pub fn mainDeclaresProtocol(db: *sqlite.Database) Error!bool {
    const value = try metadataValueAlloc(std.heap.c_allocator, db, meta_key) orelse return false;
    defer std.heap.c_allocator.free(value);
    if (!std.mem.eql(u8, value, cwal_value)) return error.NotZovaDatabase;
    return true;
}

/// Validate main's protocol key and the marker table of member `schema_name`
/// (`main` or an attached store). A marker table needs main's key and the
/// exact definition.
pub fn validateMember(db: *sqlite.Database, comptime schema_name: []const u8) Error!void {
    const declared = try mainDeclaresProtocol(db);
    var stmt = try prepareSchemaSql(db, "select sql from {s}.sqlite_schema where name = ?1", .{schema_name});
    defer stmt.deinit();
    try stmt.bindTextBorrowed(1, marker_table);
    switch (try stmt.step()) {
        .done => {},
        .row => {
            if (!declared) return error.NotZovaDatabase;
            if (!schemaSqlEqual(stmt.columnText(0), marker_schema_sql)) return error.NotZovaDatabase;
            if (try stmt.step() != .done) return error.NotZovaDatabase;
        },
    }
}

/// Validate the marker table of a store file opened alone. Main is not
/// visible, so only the definition is checked.
pub fn validateStandaloneStore(db: *sqlite.Database) Error!void {
    if (try metadataValueAlloc(std.heap.c_allocator, db, meta_key)) |value| {
        std.heap.c_allocator.free(value);
        return error.NotZovaDatabase;
    }
    var stmt = try db.prepare("select sql from main.sqlite_schema where name = ?1");
    defer stmt.deinit();
    try stmt.bindTextBorrowed(1, marker_table);
    switch (try stmt.step()) {
        .done => {},
        .row => if (!schemaSqlEqual(stmt.columnText(0), marker_schema_sql)) return error.NotZovaDatabase,
    }
}
