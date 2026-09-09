//! Issue #100 scope-audit tests. These assert that existing operations do not
//! repeat identity metadata lookups inside one operation/read scope; they do
//! not establish a cross-call data cache.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova = @import("zova.zig");

const Trace = struct {
    graph_key: usize = 0,
    node_resolution: usize = 0,
    object_metadata: usize = 0,
    object_manifest: usize = 0,

    fn callback(_: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const handle: *sqlite.c.sqlite3_stmt = @ptrCast(@alignCast(statement.?));
        const sql = std.mem.span(sqlite.c.sqlite3_sql(handle));
        if (std.mem.indexOf(u8, sql, "select graph_key from") != null) self.graph_key += 1;
        if (std.mem.indexOf(u8, sql, "_zova_graph_nodes") != null and std.mem.indexOf(u8, sql, "node_id") != null) self.node_resolution += 1;
        if (std.mem.indexOf(u8, sql, "select size_bytes, chunk_count, chunker") != null) self.object_metadata += 1;
        if (std.mem.indexOf(u8, sql, "_zova_object_chunks") != null) self.object_manifest += 1;
        return 0;
    }
};

test "graph read scopes resolve identity metadata at most once" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try db.createGraph("scope");
    try db.putGraphNodes(&.{
        .{ .graph_name = "scope", .node_id = "a", .kind = "node" },
        .{ .graph_name = "scope", .node_id = "b", .kind = "node" },
    });
    try db.putGraphEdge(.{ .graph_name = "scope", .from_node_id = "a", .to_node_id = "b", .edge_type = "link" });

    var warm = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "scope", .node_id = "a", .edge_type = "link", .limit = 4 });
    defer warm.deinit(std.testing.allocator);
    var trace: Trace = .{};
    _ = sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, sqlite.c.SQLITE_TRACE_STMT, Trace.callback, &trace);
    var result = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "scope", .node_id = "a", .edge_type = "link", .limit = 4 });
    result.deinit(std.testing.allocator);
    _ = sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);
    try std.testing.expectEqual(@as(usize, 1), trace.graph_key);
    try std.testing.expectEqual(@as(usize, 1), trace.node_resolution);
}

test "object reader loads metadata once before its active manifest scope" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    const bytes = [_]u8{0x4d} ** 8192;
    const id = try db.putObjectWithOptions(&bytes, .{ .profile = .streaming });
    var warm = try db.objectReader(id);
    var warm_buffer: [1024]u8 = undefined;
    while (try warm.read(&warm_buffer) != 0) {}
    warm.deinit();

    var trace: Trace = .{};
    _ = sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, sqlite.c.SQLITE_TRACE_STMT, Trace.callback, &trace);
    var reader = try db.objectReader(id);
    var buffer: [1024]u8 = undefined;
    while (try reader.read(&buffer) != 0) {}
    reader.deinit();
    _ = sqlite.c.sqlite3_trace_v2(db.sqlite_db.handle, 0, null, null);
    try std.testing.expectEqual(@as(usize, 1), trace.object_metadata);
    try std.testing.expectEqual(@as(usize, 1), trace.object_manifest);
}
