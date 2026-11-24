//! Journal mode and WAL checkpoints for every member of a database set (#258).

const std = @import("std");
const sqlite = @import("../sqlite.zig");

const CheckpointMode = @import("types.zig").CheckpointMode;
const CheckpointedMember = @import("types.zig").CheckpointedMember;
const Error = @import("types.zig").Error;
const JournalMode = @import("types.zig").JournalMode;
const ProgressMember = @import("types.zig").ProgressMember;

/// One member file of a set: its progress identity and attached schema name.
pub const Member = struct {
    member: ProgressMember,
    schema: [:0]const u8,
};

/// Journal mode SQLite reports for one attached schema.
pub fn read(db: *sqlite.Database, schema: [:0]const u8) Error!JournalMode {
    var sql_buffer: [64]u8 = undefined;
    const sql = std.fmt.bufPrintSentinel(&sql_buffer, "pragma {s}.journal_mode", .{schema}, 0) catch return error.InvalidArgument;
    return pragmaMode(db, sql);
}

/// Ask SQLite to switch one schema and return the mode it reports afterwards.
/// SQLite returns the old mode, not an error, when it cannot switch (an
/// in-memory file, for example), so callers compare the result.
pub fn write(db: *sqlite.Database, schema: [:0]const u8, mode: JournalMode) Error!JournalMode {
    var sql_buffer: [80]u8 = undefined;
    const sql = std.fmt.bufPrintSentinel(&sql_buffer, "pragma {s}.journal_mode={s}", .{ schema, @tagName(mode) }, 0) catch return error.InvalidArgument;
    return pragmaMode(db, sql);
}

/// Switch every member, or restore the members already switched and fail.
/// The caller has checked that no transaction is open.
pub fn writeAll(db: *sqlite.Database, members: []const Member, mode: JournalMode) Error!void {
    std.debug.assert(mode.selectable());
    var previous: [4]JournalMode = undefined;
    for (members, 0..) |member, i| previous[i] = try read(db, member.schema);

    for (members, 0..) |member, i| {
        const actual = write(db, member.schema, mode) catch |err| {
            restore(db, members[0..i], previous[0..i]);
            return err;
        };
        if (actual != mode) {
            restore(db, members[0..i], previous[0..i]);
            // An in-memory or temporary file keeps `memory`; any other file
            // that refused the switch was held by another handle.
            return if (actual == .memory) error.InvalidArgument else error.Busy;
        }
    }
}

fn restore(db: *sqlite.Database, members: []const Member, modes: []const JournalMode) void {
    for (members, modes) |member, mode| _ = write(db, member.schema, mode) catch {};
}

/// Checkpoint one member. A member not in WAL mode reports zero frames.
pub fn checkpoint(db: *sqlite.Database, member: Member, mode: CheckpointMode) Error!CheckpointedMember {
    const journal_mode = try read(db, member.schema);
    const result = try db.walCheckpoint(member.schema, switch (mode) {
        .passive => .passive,
        .full => .full,
        .restart => .restart,
        .truncate => .truncate,
    });
    const wal = journal_mode == .wal;
    return .{
        .member = member.member,
        .journal_mode = journal_mode,
        .busy = wal and result.busy,
        .wal_frames = if (wal) frameCount(result.log_frames) else 0,
        .checkpointed_frames = if (wal) frameCount(result.checkpointed_frames) else 0,
    };
}

fn frameCount(value: c_int) u64 {
    return if (value < 0) 0 else @intCast(value);
}

fn pragmaMode(db: *sqlite.Database, sql: [:0]const u8) Error!JournalMode {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.SqliteError;
    const name = stmt.columnText(0);
    var lower_buffer: [16]u8 = undefined;
    if (name.len > lower_buffer.len) return error.SqliteError;
    const lower = std.ascii.lowerString(&lower_buffer, name);
    return std.meta.stringToEnum(JournalMode, lower) orelse error.SqliteError;
}
