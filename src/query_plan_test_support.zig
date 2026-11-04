//! Shared helpers for batch-driven statement query-plan regression tests.
//!
//! A test installs a `sqlite3_trace_v2` statement callback, calls the public
//! operation, then explains the SQL SQLite actually ran. That keeps the plan
//! assertions tied to production statements instead of a copied query.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova = @import("zova.zig");

pub const max_sql_bytes = 8192;

/// Captures the last statement whose text contains `needle`.
pub const Capture = struct {
    needle: []const u8 = "",
    sql_bytes: [max_sql_bytes]u8 = undefined,
    sql_len: usize = 0,
    statements: usize = 0,

    pub fn install(self: *Capture, db: *sqlite.Database) void {
        _ = sqlite.c.sqlite3_trace_v2(db.handle, sqlite.c.SQLITE_TRACE_STMT, Capture.callback, self);
    }

    pub fn remove(self: *Capture, db: *sqlite.Database) void {
        _ = self;
        _ = sqlite.c.sqlite3_trace_v2(db.handle, 0, null, null);
    }

    pub fn reset(self: *Capture, needle: []const u8) void {
        self.needle = needle;
        self.sql_len = 0;
        self.statements = 0;
    }

    pub fn sql(self: *const Capture) []const u8 {
        return self.sql_bytes[0..self.sql_len];
    }

    pub fn expectPlan(self: *const Capture, db: *sqlite.Database, expect: Expect) !void {
        try std.testing.expect(self.statements != 0);
        try std.testing.expect(self.sql_len != 0);

        var buffer: [max_sql_bytes + 32]u8 = undefined;
        const statement = std.fmt.bufPrintSentinel(
            &buffer,
            "explain query plan {s}",
            .{self.sql()},
            0,
        ) catch return error.TestUnexpectedResult;
        var plan = try Plan.fromSql(db, statement);
        try plan.expect(expect);
    }

    fn callback(mask: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        if (mask != sqlite.c.SQLITE_TRACE_STMT or context == null or statement == null) return 0;
        const stmt: *sqlite.c.sqlite3_stmt = @ptrCast(@alignCast(statement.?));
        const text = std.mem.span(sqlite.c.sqlite3_sql(stmt) orelse return 0);
        const capture: *Capture = @ptrCast(@alignCast(context.?));
        if (capture.needle.len != 0 and std.mem.indexOf(u8, text, capture.needle) == null) return 0;
        if (text.len > capture.sql_bytes.len) return 0;
        @memcpy(capture.sql_bytes[0..text.len], text);
        capture.sql_len = text.len;
        capture.statements += 1;
        return 0;
    }
};

pub const BoundedAccess = struct {
    alias: []const u8,
    partition: []const u8,
};

pub const IndexedAccess = struct {
    alias: []const u8,
    index: []const u8,
    key: []const u8,
};

pub const Expect = struct {
    /// The first plan row scans this carray/temp table alias or name.
    outer: ?[]const u8 = null,
    /// Every access to `alias` must be a bounded indexed or rowid search.
    bounded: []const BoundedAccess = &.{},
    /// Whole-partition reads that are accepted and documented exceptions.
    partition_only: []const BoundedAccess = &.{},
    /// The named access must use a specific index and key term.
    indexed: ?IndexedAccess = null,
    /// A staged batch table must be probed through the IN-operator index.
    in_operator: ?[]const u8 = null,
    no_sort: bool = true,
};

const Access = struct {
    verb: []const u8,
    target: []const u8,
};

pub const Plan = struct {
    pub const max_rows = 32;
    pub const max_detail = 256;

    details: [max_rows][max_detail]u8 = undefined,
    lengths: [max_rows]usize = @splat(0),
    count: usize = 0,

    pub fn fromSql(db: *sqlite.Database, sql: [:0]const u8) !Plan {
        var plan: Plan = .{};
        var stmt = try db.prepare(sql);
        defer stmt.deinit();
        while (try stmt.step() == .row) {
            try std.testing.expect(plan.count < max_rows);
            const detail = stmt.columnText(3);
            try std.testing.expect(detail.len <= max_detail);
            @memcpy(plan.details[plan.count][0..detail.len], detail);
            plan.lengths[plan.count] = detail.len;
            plan.count += 1;
        }
        return plan;
    }

    pub fn row(self: *const Plan, index: usize) []const u8 {
        return self.details[index][0..self.lengths[index]];
    }

    fn expect(self: *const Plan, options: Expect) !void {
        if (options.outer) |outer| try self.expectOuterScan(outer);
        for (options.bounded) |access| try self.expectBoundedAccess(access);
        for (options.partition_only) |access| try self.expectPartitionAccess(access);
        if (options.indexed) |access| try self.expectIndexedAccess(access);
        if (options.in_operator) |batch| try self.expectInOperator(batch);
        if (options.no_sort) try self.expectNoSort();
    }

    pub fn expectOuterScan(self: *const Plan, table: []const u8) !void {
        try std.testing.expect(self.count != 0);
        const access = splitAccess(self.row(0)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("SCAN", access.verb);
        try std.testing.expectEqualStrings(table, access.target);
    }

    pub fn expectBoundedAccess(self: *const Plan, expected: BoundedAccess) !void {
        var saw_access = false;
        for (0..self.count) |index| {
            const access = splitAccess(self.row(index)) orelse continue;
            if (!std.mem.eql(u8, access.target, expected.alias)) continue;
            saw_access = true;
            try std.testing.expectEqualStrings("SEARCH", access.verb);
            const detail = self.row(index);
            if (std.mem.indexOf(u8, detail, "USING INTEGER PRIMARY KEY") != null) continue;
            const qualifier = accessQualifier(detail) orelse return error.TestUnexpectedResult;
            try std.testing.expect(countNeedle(qualifier, "=?") >= 2);
            var key_buffer: [256]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "{s}=?", .{expected.partition});
            try std.testing.expect(std.mem.indexOf(u8, qualifier, key) != null);
        }
        try std.testing.expect(saw_access);
    }

    pub fn expectPartitionAccess(self: *const Plan, expected: BoundedAccess) !void {
        var saw_access = false;
        for (0..self.count) |index| {
            const access = splitAccess(self.row(index)) orelse continue;
            if (!std.mem.eql(u8, access.target, expected.alias)) continue;
            saw_access = true;
            try std.testing.expectEqualStrings("SEARCH", access.verb);
            const qualifier = accessQualifier(self.row(index)) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), countNeedle(qualifier, "=?"));
            var key_buffer: [256]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "{s}=?", .{expected.partition});
            try std.testing.expect(std.mem.indexOf(u8, qualifier, key) != null);
        }
        try std.testing.expect(saw_access);
    }

    pub fn expectIndexedAccess(self: *const Plan, expected: IndexedAccess) !void {
        var saw_access = false;
        for (0..self.count) |index| {
            const access = splitAccess(self.row(index)) orelse continue;
            if (!std.mem.eql(u8, access.target, expected.alias)) continue;
            saw_access = true;
            try std.testing.expectEqualStrings("SEARCH", access.verb);
            const detail = self.row(index);
            try std.testing.expect(std.mem.indexOf(u8, detail, expected.index) != null);
            var key_buffer: [256]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "{s}=?", .{expected.key});
            try std.testing.expect(std.mem.indexOf(u8, detail, key) != null);
        }
        try std.testing.expect(saw_access);
    }

    pub fn expectInOperator(self: *const Plan, batch_table: []const u8) !void {
        for (0..self.count) |index| {
            const detail = self.row(index);
            if (std.mem.indexOf(u8, detail, "FOR IN-OPERATOR") != null and
                std.mem.indexOf(u8, detail, batch_table) != null) return;
        }
        return error.TestUnexpectedResult;
    }

    pub fn expectNoSort(self: *const Plan) !void {
        for (0..self.count) |index| {
            try std.testing.expect(std.mem.indexOf(u8, self.row(index), "USE TEMP B-TREE FOR ORDER BY") == null);
        }
    }
};

fn splitAccess(detail: []const u8) ?Access {
    var tokens = std.mem.tokenizeScalar(u8, detail, ' ');
    const verb = tokens.next() orelse return null;
    if (!std.mem.eql(u8, verb, "SCAN") and !std.mem.eql(u8, verb, "SEARCH")) return null;
    const target = tokens.next() orelse return null;
    return .{ .verb = verb, .target = target };
}

fn accessQualifier(detail: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, detail, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, detail, ')') orelse return null;
    if (close <= open) return null;
    return detail[open + 1 .. close];
}

fn countNeedle(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |found| {
        count += 1;
        offset = found + needle.len;
    }
    return count;
}

/// Graph fixture shared by plan tests: one graph with `node_count` nodes and
/// two typed edges per node. Build it once per test file.
pub const GraphFixture = struct {
    db: zova.Database,
    node_keys: []i64,
    edge_keys: []i64,

    pub fn deinit(self: *GraphFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.edge_keys);
        allocator.free(self.node_keys);
        self.db.deinit();
    }
};

pub fn createGraphFixture(allocator: std.mem.Allocator, node_count: usize) !GraphFixture {
    std.debug.assert(node_count >= 3);
    var db = try zova.Database.createMemory();
    errdefer db.deinit();
    try db.createGraph("plan");

    const id_storage = try allocator.alloc(u8, node_count * 16);
    defer allocator.free(id_storage);
    const id_lengths = try allocator.alloc(usize, node_count);
    defer allocator.free(id_lengths);
    const node_inputs = try allocator.alloc(zova.GraphNodeInput, node_count);
    defer allocator.free(node_inputs);
    for (0..node_count) |index| {
        const buffer = id_storage[index * 16 ..][0..16];
        const id = try std.fmt.bufPrint(buffer, "n{d}", .{index});
        id_lengths[index] = id.len;
        node_inputs[index] = .{ .graph_name = "plan", .node_id = id, .kind = "kind" };
    }
    const node_keys = try allocator.alloc(i64, node_count);
    errdefer allocator.free(node_keys);
    try db.putGraphNodesKeyed(node_inputs, node_keys);

    const edge_inputs = try allocator.alloc(zova.GraphEdgeInput, node_count * 2);
    defer allocator.free(edge_inputs);
    for (0..node_count) |index| {
        const from = id_storage[index * 16 ..][0..id_lengths[index]];
        const first = (index + 1) % node_count;
        const second = (index + 2) % node_count;
        const first_to = id_storage[first * 16 ..][0..id_lengths[first]];
        const second_to = id_storage[second * 16 ..][0..id_lengths[second]];
        edge_inputs[index * 2] = .{
            .graph_name = "plan",
            .from_node_id = from,
            .edge_type = "calls",
            .to_node_id = first_to,
        };
        edge_inputs[index * 2 + 1] = .{
            .graph_name = "plan",
            .from_node_id = from,
            .edge_type = "imports",
            .to_node_id = second_to,
        };
    }
    const edge_keys = try allocator.alloc(i64, node_count * 2);
    errdefer allocator.free(edge_keys);
    try db.putGraphEdgesKeyed(edge_inputs, edge_keys);
    return .{ .db = db, .node_keys = node_keys, .edge_keys = edge_keys };
}
