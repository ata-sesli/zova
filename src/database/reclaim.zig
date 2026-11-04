//! Bounded free-page reclaim for incremental auto-vacuum files (#197).

const std = @import("std");
const sqlite = @import("../sqlite.zig");

const AutoVacuumMode = @import("types.zig").AutoVacuumMode;
const Error = @import("types.zig").Error;
const ProgressMember = @import("types.zig").ProgressMember;
const ReclaimedMember = @import("types.zig").ReclaimedMember;
const sqliteI64ToU64 = @import("metadata.zig").sqliteI64ToU64;

/// Pages `reclaimSpace` may still release; null means unbounded.
pub const Budget = struct {
    remaining: ?u64,

    pub fn init(max_pages: u64) Budget {
        return .{ .remaining = if (max_pages == 0) null else max_pages };
    }

    fn take(self: *Budget, wanted: u64) u64 {
        const remaining = self.remaining orelse return wanted;
        return @min(wanted, remaining);
    }

    fn spend(self: *Budget, pages: u64) void {
        if (self.remaining) |*remaining| remaining.* -= @min(pages, remaining.*);
    }
};

/// Release free pages of one attached schema in `step_pages` transactions.
/// A member that is not in incremental mode releases nothing.
pub fn reclaimSchema(
    db: *sqlite.Database,
    comptime schema: []const u8,
    member: ProgressMember,
    step_pages: u32,
    budget: *Budget,
) Error!ReclaimedMember {
    const mode: AutoVacuumMode = switch (try pragmaU64(db, "pragma " ++ schema ++ ".auto_vacuum")) {
        0 => .none,
        1 => .full,
        2 => .incremental,
        else => return error.Corrupt,
    };
    const page_size = std.math.cast(u32, try pragmaU64(db, "pragma " ++ schema ++ ".page_size")) orelse return error.Corrupt;

    var released: u64 = 0;
    if (mode == .incremental) {
        while (true) {
            const free = try pragmaU64(db, "pragma " ++ schema ++ ".freelist_count");
            const pages = budget.take(@min(free, step_pages));
            if (pages == 0) break;

            var sql_buffer: [96]u8 = undefined;
            const sql = std.fmt.bufPrintSentinel(&sql_buffer, "pragma " ++ schema ++ ".incremental_vacuum({d})", .{pages}, 0) catch unreachable;
            try db.beginImmediate();
            var committed = false;
            errdefer if (!committed) db.rollback() catch {};
            try db.exec(sql);
            try db.commit();
            committed = true;

            const left = try pragmaU64(db, "pragma " ++ schema ++ ".freelist_count");
            // Guard against a step that frees nothing, so the loop always ends.
            if (left >= free) break;
            released += free - left;
            budget.spend(free - left);
        }
    }

    return .{
        .member = member,
        .auto_vacuum = mode,
        .page_size = page_size,
        .pages_released = released,
        .free_pages_left = try pragmaU64(db, "pragma " ++ schema ++ ".freelist_count"),
    };
}

fn pragmaU64(db: *sqlite.Database, sql: [:0]const u8) Error!u64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.Corrupt;
    return try sqliteI64ToU64(stmt.columnInt64(0));
}
