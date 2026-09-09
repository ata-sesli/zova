//! Issue #98 regression coverage for the bounded read-statement cache.
//!
//! These tests cover the reuse contract itself plus the situations that make
//! statement reuse unsafe: in-flight statements, borrowed input, failed
//! cleanup, schema changes, bound-store rebinding and vacuum.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const statement_cache = @import("statement_cache.zig");
const test_support = @import("zova_test_support.zig");
const zova = @import("zova.zig");

const Database = zova.Database;
const createObjectStore = zova.createObjectStore;
const testingDbPath = test_support.testingDbPath;

fn putObjectRangeReadFixture(db: *Database, allocator: std.mem.Allocator, bytes: []const u8) !zova.ObjectId {
    _ = allocator;
    return db.putObjectWithOptions(bytes, .{ .profile = .streaming });
}

fn countLiveStatements(db: *Database) usize {
    var count: usize = 0;
    var stmt = sqlite.c.sqlite3_next_stmt(db.sqlite_db.handle, null);
    while (stmt) |handle| : (stmt = sqlite.c.sqlite3_next_stmt(db.sqlite_db.handle, handle)) {
        count += 1;
        // Every retained statement must be idle and free of borrowed input.
        std.testing.expectEqual(@as(c_int, 0), sqlite.c.sqlite3_stmt_busy(handle)) catch @panic("retained statement is busy");
        const expanded = sqlite.c.sqlite3_expanded_sql(handle) orelse @panic("out of memory");
        defer sqlite.c.sqlite3_free(expanded);
        const text = std.mem.span(expanded);
        std.testing.expect(std.mem.indexOf(u8, text, "x'") == null) catch @panic("retained statement kept a bound value");
    }
    return count;
}

test "object and graph read paths reuse one bounded set of idle statements" {
    var db = try Database.createMemory();
    defer db.deinit();

    const bytes = [_]u8{0x5a} ** (64 * 1024);
    const id = try putObjectRangeReadFixture(&db, std.testing.allocator, &bytes);
    try db.createGraph("cache");
    try db.putGraphNode(.{ .graph_name = "cache", .node_id = "a", .kind = "node" });
    try db.putGraphNode(.{ .graph_name = "cache", .node_id = "b", .kind = "node" });
    try db.putGraphEdge(.{ .graph_name = "cache", .from_node_id = "a", .to_node_id = "b", .edge_type = "link" });

    for (0..8) |_| {
        var buffer: [4096]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 4096), try db.readObjectRange(id, 1024, &buffer));
        try std.testing.expectEqualSlices(u8, bytes[1024..][0..4096], &buffer);
        try std.testing.expect(try db.hasObject(id));
        var neighbors = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "cache", .node_id = "a", .limit = 8 });
        defer neighbors.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), neighbors.items.len);
        try std.testing.expectEqual(@as(u64, 1), try db.graphDegree(.{ .graph_name = "cache", .node_id = "a" }));
        try std.testing.expect(try db.hasGraphEdge("cache", "a", "link", "b"));
    }

    try std.testing.expect(db.read_statements.reuses > 0);
    try std.testing.expect(db.read_statements.prepares > 0);
    try std.testing.expect(db.read_statements.retained() <= statement_cache.capacity);
    try std.testing.expectEqual(db.read_statements.retained(), countLiveStatements(&db));
    try db.vacuum();
}

test "read statement leases do not share an in-flight statement with a nested read" {
    const Trace = struct {
        db: *Database,
        id: zova.ObjectId,
        entered: bool = false,
        called: bool = false,
        failed: bool = false,
        expected: []const u8,

        fn callback(_: c_uint, context: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.entered) return 0;
            self.entered = true;
            defer self.entered = false;
            self.called = true;
            var buffer: [64]u8 = undefined;
            const read = self.db.readObjectRange(self.id, 0, &buffer) catch {
                self.failed = true;
                return 0;
            };
            if (read != 64 or !std.mem.eql(u8, self.expected[0..64], buffer[0..64])) self.failed = true;
            return 0;
        }
    };

    var db = try Database.createMemory();
    defer db.deinit();
    var bytes: [4096]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast((index * 31 + 5) % 251);
    const id = try db.putObjectWithOptions(&bytes, .{ .profile = .streaming });

    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try db.readObjectRange(id, 0, &buffer));
    var trace = Trace{ .db = &db, .id = id, .expected = &bytes };
    try std.testing.expectEqual(
        @as(c_int, sqlite.c.SQLITE_OK),
        sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, sqlite.c.SQLITE_TRACE_STMT, Trace.callback, &trace),
    );
    var outer: [4096]u8 = undefined;
    const read = try db.readObjectRange(id, 0, &outer);
    _ = sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);
    try std.testing.expect(trace.called and !trace.failed);
    try std.testing.expectEqualSlices(u8, &bytes, outer[0..read]);
    try db.vacuum();
}

test "read statement reuse survives allocation failures and schema changes" {
    var db = try Database.createMemory();
    defer db.deinit();
    try db.createGraph("cache");
    try db.putGraphNode(.{ .graph_name = "cache", .node_id = "a", .kind = "node" });
    try db.putGraphNode(.{ .graph_name = "cache", .node_id = "b", .kind = "node" });
    try db.putGraphEdge(.{ .graph_name = "cache", .from_node_id = "a", .to_node_id = "b", .edge_type = "link" });

    var first = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "cache", .node_id = "a", .limit = 4 });
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.items.len);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, db.graphNeighbors(failing.allocator(), .{ .graph_name = "cache", .node_id = "a", .limit = 4 }));

    // A schema change invalidates the cached statement; SQLite recompiles the
    // next execution and the graph layer must not keep a statement that failed
    // to reset after the error.
    try db.exec("drop table _zova_graph_nodes");
    try std.testing.expectError(error.SqliteError, db.graphDegree(.{ .graph_name = "cache", .node_id = "a" }));
    try std.testing.expectError(error.SqliteError, db.graphNeighbors(std.testing.allocator, .{ .graph_name = "cache", .node_id = "a", .limit = 4 }));
    _ = db.hasGraph("cache") catch {};

    var db2 = try Database.createMemory();
    defer db2.deinit();
    try db2.createGraph("cache");
    try db2.putGraphNode(.{ .graph_name = "cache", .node_id = "a", .kind = "node" });
    try std.testing.expectEqual(@as(u64, 0), try db2.graphDegree(.{ .graph_name = "cache", .node_id = "a" }));
    try db2.vacuum();
    var retry = try db2.graphNeighbors(std.testing.allocator, .{ .graph_name = "cache", .node_id = "a", .limit = 4 });
    defer retry.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), retry.items.len);
}

test "main and bound store read statements stay distinct and are disposed before rebind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var other_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "stmt-main.zova");
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "stmt-store.zova");
    const other_path = try testingDbPath(&other_buffer, tmp.sub_path[0..], "stmt-other.zova");
    try createObjectStore(store_path);
    try createObjectStore(other_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    const bytes = [_]u8{0x11} ** 8192;
    var buffer: [512]u8 = undefined;

    // Main object storage must be empty before a store can be bound.
    try db.bindObjectStore(store_path);
    const bound_id = try db.putObjectWithOptions(&bytes, .{ .profile = .streaming });
    try std.testing.expectEqual(@as(usize, 512), try db.readObjectRange(bound_id, 0, &buffer));
    try std.testing.expectEqual(@as(usize, 0), db.read_statements.countFor(.object_metadata, false));
    try std.testing.expectEqual(@as(usize, 1), db.read_statements.countFor(.object_metadata, true));

    // Replacing the store must not leave statements pointing at the old schema.
    try db.bindObjectStore(other_path);
    try std.testing.expectEqual(@as(usize, 0), db.read_statements.retained());
    const rebound_id = try db.putObjectWithOptions(&bytes, .{ .profile = .streaming });
    try std.testing.expectEqual(@as(usize, 512), try db.readObjectRange(rebound_id, 0, &buffer));

    try db.unbindObjectStore();
    try std.testing.expectEqual(@as(usize, 0), db.read_statements.retained());
    const main_id = try db.putObjectWithOptions(&bytes, .{ .profile = .streaming });
    try std.testing.expectEqual(@as(usize, 512), try db.readObjectRange(main_id, 0, &buffer));
    try std.testing.expectEqual(@as(usize, 1), db.read_statements.countFor(.object_metadata, false));
    try std.testing.expectEqual(@as(usize, 0), db.read_statements.countFor(.object_metadata, true));
    try db.vacuum();
}

test "read statement cache retains at most the bounded number of idle statements" {
    var db = try Database.createMemory();
    defer db.deinit();
    try db.createGraph("cache");
    for (0..4) |index| {
        var name: [8]u8 = undefined;
        const node_id = try std.fmt.bufPrint(&name, "n{d}", .{index});
        try db.putGraphNode(.{ .graph_name = "cache", .node_id = node_id, .kind = "node" });
    }
    try db.putGraphEdge(.{ .graph_name = "cache", .from_node_id = "n0", .to_node_id = "n1", .edge_type = "link" });

    const bytes = [_]u8{0x77} ** 4096;
    const id = try db.putObjectWithOptions(&bytes, .{ .profile = .streaming });

    // Touch every cached variant, then confirm the ceiling still holds.
    for (0..3) |_| {
        var buffer: [256]u8 = undefined;
        _ = try db.readObjectRange(id, 128, &buffer);
        _ = try db.hasObject(id);
        for ([_][]const u8{ "n0", "n1", "n2" }) |node_id| {
            for ([_]?[]const u8{ null, "link" }) |edge_type| {
                for ([_]zova.GraphNeighborDirection{ .outgoing, .incoming }) |direction| {
                    var neighbors = try db.graphNeighbors(std.testing.allocator, .{
                        .graph_name = "cache",
                        .node_id = node_id,
                        .direction = direction,
                        .edge_type = edge_type,
                        .limit = 4,
                    });
                    neighbors.deinit(std.testing.allocator);
                    _ = try db.graphDegree(.{
                        .graph_name = "cache",
                        .node_id = node_id,
                        .direction = direction,
                        .edge_type = edge_type,
                    });
                }
            }
        }
        _ = try db.hasGraphEdge("cache", "n0", "link", "n1");
    }

    try std.testing.expect(db.read_statements.retained() <= statement_cache.capacity);
    try std.testing.expectEqual(db.read_statements.retained(), countLiveStatements(&db));
    try db.vacuum();
}

test "fresh graph builds work while read statements are cached" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "stmt-fresh.zova");

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.createGraph("cache");
    try db.putGraphNode(.{ .graph_name = "cache", .node_id = "a", .kind = "node" });
    _ = try db.graphDegree(.{ .graph_name = "cache", .node_id = "a" });
    try db.deleteGraph("cache");

    const nodes = [_]zova.FreshGraphNodeInput{
        .{ .node_id = "x", .kind = "node" },
        .{ .node_id = "y", .kind = "node" },
    };
    const edges = [_]zova.FreshGraphEdgeInput{
        .{ .from_node_ordinal = 0, .edge_type = "link", .to_node_ordinal = 1 },
    };
    var node_keys: [2]i64 = undefined;
    var edge_keys: [1]i64 = undefined;
    try db.buildFreshGraphKeyed("fresh", &nodes, &edges, &node_keys, &edge_keys);

    try std.testing.expect(try db.hasGraphNode("fresh", "y"));
    var neighbors = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "fresh", .node_id = "x", .limit = 4 });
    defer neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), neighbors.items.len);
    try db.vacuum();
}
