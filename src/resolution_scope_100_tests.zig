//! Issue #100 scope-audit tests. These assert that existing operations do not
//! repeat identity resolution inside one operation/read scope; they do not
//! establish a cross-call data cache.
//!
//! Classification uses the stable private `zova_trace:*` SQL comments in the
//! resolver statements (src/graph.zig, src/object.zig), so adjacency SQL that
//! merely returns public ids cannot be confused with identity resolution.
//! SQLITE_TRACE_STMT counts statement executions, not rows; row counts are
//! asserted from returned results instead.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova = @import("zova.zig");
const test_support = @import("zova_test_support.zig");

const Trace = struct {
    statements: usize = 0,
    graph_key: usize = 0,
    node_resolution: usize = 0,
    edge_resolution: usize = 0,
    adjacency: usize = 0,
    walk_adjacency: usize = 0,
    edge_type: usize = 0,
    object_metadata: usize = 0,
    object_exists: usize = 0,
    object_range: usize = 0,
    object_reader_manifest: usize = 0,

    fn reset(self: *@This()) void {
        self.* = .{};
    }
    fn callback(_: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const handle: *sqlite.c.sqlite3_stmt = @ptrCast(@alignCast(statement.?));
        const sql = std.mem.span(sqlite.c.sqlite3_sql(handle));
        self.statements += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:graph_key") != null) self.graph_key += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:graph_node_resolve") != null) self.node_resolution += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:graph_edge_resolve") != null) self.edge_resolution += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:graph_adjacency") != null) self.adjacency += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:walk_adjacency") != null) self.walk_adjacency += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:edge_type_resolve") != null) self.edge_type += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:object_metadata") != null) self.object_metadata += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:object_exists") != null) self.object_exists += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:object_range") != null) self.object_range += 1;
        if (std.mem.indexOf(u8, sql, "zova_trace:object_reader_manifest") != null) self.object_reader_manifest += 1;
        return 0;
    }
};

fn beginTrace(db: *zova.Database, trace: *Trace) void {
    _ = sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, sqlite.c.SQLITE_TRACE_STMT, Trace.callback, trace);
}

fn endTrace(db: *zova.Database) void {
    _ = sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);
}

const Fixture = struct {
    graph: bool = false,

    fn seed(self: Fixture, db: *zova.Database) !void {
        try db.createGraph("scope");
        try db.putGraphNodes(&.{
            .{ .graph_name = "scope", .node_id = "a", .kind = "node" },
            .{ .graph_name = "scope", .node_id = "b", .kind = "node" },
            .{ .graph_name = "scope", .node_id = "c", .kind = "node" },
        });
        try db.putGraphEdge(.{ .graph_name = "scope", .from_node_id = "a", .to_node_id = "b", .edge_type = "link" });
        try db.putGraphEdge(.{ .graph_name = "scope", .from_node_id = "b", .to_node_id = "c", .edge_type = "link" });
        if (!self.graph) {
            var bytes: [8192]u8 = @splat(0x4d);
            _ = try db.putObjectWithOptions(&bytes, .{ .profile = .streaming });
        }
    }
};

test "typed neighbors resolve identity once and return correct rows on main and bound stores" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    const fixture = Fixture{ .graph = true };
    try fixture.seed(&db);

    var warm = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "scope", .node_id = "a", .edge_type = "link", .limit = 4 });
    defer warm.deinit(std.testing.allocator);

    var trace: Trace = .{};
    beginTrace(&db, &trace);
    var result = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "scope", .node_id = "a", .edge_type = "link", .limit = 4 });
    defer result.deinit(std.testing.allocator);
    endTrace(&db);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("b", result.items[0].node_id);
    try std.testing.expectEqualStrings("link", result.items[0].edge_type);
    try std.testing.expectEqual(@as(usize, 2), trace.statements);
    try std.testing.expectEqual(@as(usize, 1), trace.graph_key);
    try std.testing.expectEqual(@as(usize, 1), trace.node_resolution);
    try std.testing.expectEqual(@as(usize, 1), trace.adjacency);
    try std.testing.expectEqual(@as(usize, 0), trace.edge_resolution);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try test_support.testingDbPath(&main_buffer, tmp.sub_path[0..], "scope-typed-neighbors-main.zova");
    const store_path = try test_support.testingDbPath(&path_buffer, tmp.sub_path[0..], "scope-typed-neighbors.zova");
    try zova.createGraphStore(store_path);
    var bound = try zova.Database.create(main_path);
    defer bound.deinit();
    try bound.bindGraphStore(store_path);
    const fixture_bound = Fixture{ .graph = true };
    try fixture_bound.seed(&bound);
    var warm_bound = try bound.graphNeighbors(std.testing.allocator, .{ .graph_name = "scope", .node_id = "a", .edge_type = "link", .limit = 4 });
    defer warm_bound.deinit(std.testing.allocator);

    var trace_bound: Trace = .{};
    beginTrace(&bound, &trace_bound);
    var result_bound = try bound.graphNeighbors(std.testing.allocator, .{ .graph_name = "scope", .node_id = "a", .edge_type = "link", .limit = 4 });
    defer result_bound.deinit(std.testing.allocator);
    endTrace(&bound);
    try std.testing.expectEqual(@as(usize, 1), result_bound.items.len);
    try std.testing.expectEqualStrings("b", result_bound.items[0].node_id);
    try std.testing.expectEqual(@as(usize, 1), trace_bound.graph_key);
    try std.testing.expectEqual(@as(usize, 1), trace_bound.node_resolution);
    try std.testing.expectEqual(@as(usize, 1), trace_bound.adjacency);
}

test "untyped neighbors resolve identity once with adjacency counted separately" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    const fixture = Fixture{ .graph = true };
    try fixture.seed(&db);

    var warm = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "scope", .node_id = "a", .limit = 4 });
    defer warm.deinit(std.testing.allocator);

    var trace: Trace = .{};
    beginTrace(&db, &trace);
    var result = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "scope", .node_id = "a", .limit = 4 });
    defer result.deinit(std.testing.allocator);
    endTrace(&db);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("b", result.items[0].node_id);
    try std.testing.expectEqual(@as(usize, 1), trace.graph_key);
    try std.testing.expectEqual(@as(usize, 1), trace.node_resolution);
    try std.testing.expectEqual(@as(usize, 1), trace.adjacency);
    try std.testing.expectEqual(@as(usize, 0), trace.walk_adjacency);
    try std.testing.expectEqual(@as(usize, 0), trace.edge_type);
}

test "degree resolves identity at most once for untyped and typed calls" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    const fixture = Fixture{ .graph = true };
    try fixture.seed(&db);

    var warm_untyped = try db.graphDegree(.{ .graph_name = "scope", .node_id = "a" });
    var warm_typed = try db.graphDegree(.{ .graph_name = "scope", .node_id = "a", .edge_type = "link" });
    std.mem.doNotOptimizeAway(&warm_untyped);
    std.mem.doNotOptimizeAway(&warm_typed);

    var trace: Trace = .{};
    beginTrace(&db, &trace);
    try std.testing.expectEqual(@as(u64, 1), try db.graphDegree(.{ .graph_name = "scope", .node_id = "a" }));
    try std.testing.expectEqual(@as(u64, 1), try db.graphDegree(.{ .graph_name = "scope", .node_id = "a", .edge_type = "link" }));
    endTrace(&db);
    try std.testing.expectEqual(@as(usize, 2), trace.graph_key);
    try std.testing.expectEqual(@as(usize, 2), trace.node_resolution);
    try std.testing.expectEqual(@as(usize, 0), trace.edge_type);
    try std.testing.expectEqual(@as(usize, 2), trace.adjacency);
    try std.testing.expectEqual(@as(usize, 0), trace.walk_adjacency);
}

test "walk resolves the root at most once and expands adjacency per frontier node" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    const fixture = Fixture{ .graph = true };
    try fixture.seed(&db);

    var warm = try db.graphWalk(std.testing.allocator, .{ .graph_name = "scope", .start_node_id = "a", .max_depth = 2, .limit = 8 });
    defer warm.deinit(std.testing.allocator);

    var trace: Trace = .{};
    beginTrace(&db, &trace);
    var walk = try db.graphWalk(std.testing.allocator, .{ .graph_name = "scope", .start_node_id = "a", .max_depth = 2, .limit = 8 });
    defer walk.deinit(std.testing.allocator);
    endTrace(&db);
    try std.testing.expectEqual(@as(usize, 3), walk.items.len);
    try std.testing.expectEqualStrings("a", walk.items[0].node_id);
    try std.testing.expectEqualStrings("b", walk.items[1].node_id);
    try std.testing.expectEqualStrings("c", walk.items[2].node_id);
    try std.testing.expectEqual(@as(u32, 0), walk.items[0].depth);
    try std.testing.expectEqual(@as(u32, 1), walk.items[1].depth);
    try std.testing.expectEqual(@as(u32, 2), walk.items[2].depth);
    try std.testing.expectEqual(@as(usize, 0), trace.graph_key);
    try std.testing.expectEqual(@as(usize, 1), trace.node_resolution);
    try std.testing.expectEqual(@as(usize, 2), trace.walk_adjacency);
    try std.testing.expectEqual(@as(usize, 0), trace.adjacency);
}

test "hasObject resolves existence at most once per call" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    const bytes = [_]u8{0x4d} ** 8192;
    const id = try db.putObjectWithOptions(&bytes, .{ .profile = .streaming });

    _ = try db.hasObject(id);

    var trace: Trace = .{};
    beginTrace(&db, &trace);
    try std.testing.expect(try db.hasObject(id));
    endTrace(&db);
    try std.testing.expectEqual(@as(usize, 1), trace.statements);
    try std.testing.expectEqual(@as(usize, 1), trace.object_exists);
    try std.testing.expectEqual(@as(usize, 0), trace.object_metadata);
    try std.testing.expectEqual(@as(usize, 0), trace.object_range);
    try std.testing.expectEqual(@as(usize, 0), trace.object_reader_manifest);
}

test "readObjectRange loads metadata once and returns correct bytes on main and bound stores" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    const bytes = [_]u8{0x4d} ** 8192;
    const id = try db.putObjectWithOptions(&bytes, .{ .profile = .streaming });

    var warm: [4096]u8 = undefined;
    _ = try db.readObjectRange(id, 0, &warm);

    var trace: Trace = .{};
    beginTrace(&db, &trace);
    var buffer: [4096]u8 = undefined;
    const read = try db.readObjectRange(id, 4096, &buffer);
    endTrace(&db);
    try std.testing.expectEqual(buffer.len, read);
    try std.testing.expectEqualSlices(u8, bytes[4096..], buffer[0..read]);
    try std.testing.expectEqual(@as(usize, 1), trace.object_metadata);
    try std.testing.expectEqual(@as(usize, 1), trace.object_range);
    try std.testing.expectEqual(@as(usize, 0), trace.object_reader_manifest);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try test_support.testingDbPath(&main_buffer, tmp.sub_path[0..], "scope-range-main.zova");
    const store_path = try test_support.testingDbPath(&store_buffer, tmp.sub_path[0..], "scope-range-objects.zova");
    try zova.createObjectStore(store_path);
    var bound = try zova.Database.create(main_path);
    defer bound.deinit();
    try bound.bindObjectStore(store_path);
    const bound_id = try bound.putObjectWithOptions(&bytes, .{ .profile = .streaming });
    var warm_bound: [4096]u8 = undefined;
    _ = try bound.readObjectRange(bound_id, 0, &warm_bound);

    var trace_bound: Trace = .{};
    beginTrace(&bound, &trace_bound);
    var bound_buffer: [4096]u8 = undefined;
    const bound_read = try bound.readObjectRange(bound_id, 4096, &bound_buffer);
    endTrace(&bound);
    try std.testing.expectEqual(bound_buffer.len, bound_read);
    try std.testing.expectEqualSlices(u8, bytes[4096..], bound_buffer[0..bound_read]);
    try std.testing.expectEqual(@as(usize, 1), trace_bound.object_metadata);
    try std.testing.expectEqual(@as(usize, 1), trace_bound.object_range);
}

test "object reader loads metadata and its manifest once before the read scope" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    const bytes = [_]u8{0x4d} ** 8192;
    const id = try db.putObjectWithOptions(&bytes, .{ .profile = .streaming });
    var warm = try db.objectReader(id);
    var warm_buffer: [1024]u8 = undefined;
    while (try warm.read(&warm_buffer) != 0) {}
    warm.deinit();

    var trace: Trace = .{};
    beginTrace(&db, &trace);
    var reader = try db.objectReader(id);
    defer reader.deinit();
    var buffer: [4096]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const read = try reader.read(&buffer);
        if (read == 0) break;
        total += read;
    }
    endTrace(&db);
    try std.testing.expectEqual(bytes.len, total);
    try std.testing.expectEqual(@as(usize, 1), trace.object_metadata);
    try std.testing.expectEqual(@as(usize, 1), trace.object_reader_manifest);
    try std.testing.expectEqual(@as(usize, 0), trace.object_range);
    try std.testing.expectEqual(@as(usize, 0), trace.object_exists);
}
