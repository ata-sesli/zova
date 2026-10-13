const std = @import("std");
const builtin = @import("builtin");
const plugin = @import("extension_plugin.zig");
const extension = @import("extension.zig");
const sqlite = @import("sqlite.zig");
const dynamic = @import("extension_dynamic.zig");
const options = @import("plugin_fixture_options");

var maintenance_baseline: data_api.VectorView = .{};
var maintenance_page: data_api.VectorChangesPage = .{};
fn noChangeRows(_: ?*anyopaque, _: ?[*]const data_api.Value, _: u64) callconv(.c) i32 {
    return 0;
}
fn checkMaintenance(host: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const client = data_api.Client{ .host = host, .connection = raw };
    client.vectorView("v", &maintenance_baseline) catch return 1;
    client.vectorChanges(&.{ .name = .from("v"), .since = maintenance_baseline, .row_limit = 16, .byte_limit = 4096, .row = noChangeRows }, &maintenance_page) catch return 1;
    return 0;
}
test "extension_plugin negotiates vector maintenance with zeroed outputs" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    var d = descriptor();
    d.flags |= data_api.requires_vector_maintenance;
    d.check = checkMaintenance;
    _ = try plugin.validate(&d);
    try plugin.invoke(d, .check, &db.sqlite_db);
    try std.testing.expectEqual(@as(i64, 0), maintenance_baseline.revision);
    try std.testing.expectEqual(@as(u64, 0), maintenance_page.rows);
    var out: data_api.VectorView = maintenance_baseline;
    const legacy = data_api.Host{};
    try std.testing.expectError(error.Unsupported, (data_api.Client{ .host = &legacy, .connection = null }).vectorView("v", &out));
    try std.testing.expectEqual(data_api.VectorView{}, out);
}

const MaintenanceBase = struct { view: data_api.VectorView };
const MaintenanceProjection = struct {
    arena: std.heap.ArenaAllocator,
    ids: std.StringHashMapUnmanaged(bool) = .empty,
    fn row(raw: ?*anyopaque, values: ?[*]const data_api.Value, count: u64) callconv(.c) i32 {
        const self: *MaintenanceProjection = @ptrCast(@alignCast(raw.?));
        if (count != 4) return 3;
        const id = values.?[1].bytes.?[0..@intCast(values.?[1].bytes_len)];
        const key = self.arena.allocator().dupe(u8, id) catch return 2;
        self.ids.put(self.arena.allocator(), key, values.?[2].integer != 0) catch return 2;
        return 0;
    }
};
fn maintainedCount(host: *const plugin.Host, raw: ?*anyopaque, state: ?*anyopaque, call: *const data_api.OperationCall) callconv(.c) i32 {
    const base: *const MaintenanceBase = @ptrCast(@alignCast(state.?));
    const client = data_api.Client{ .host = host, .connection = raw };
    var projection: MaintenanceProjection = .{ .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator) };
    defer projection.arena.deinit();
    var request: data_api.VectorChangesRequest = .{ .name = .from("v"), .since = base.view, .row_limit = 16, .byte_limit = 4096, .row = MaintenanceProjection.row, .user_data = &projection };
    while (true) {
        var page: data_api.VectorChangesPage = .{};
        client.vectorChanges(&request, &page) catch |err| return if (err == error.HistoryUnavailable) 7 else if (err == error.SourceChanged) 8 else 1;
        if (page.has_more == 0) break;
        request.after_revision = page.next_revision;
    }
    var count: i64 = 0;
    var items = projection.ids.valueIterator();
    while (items.next()) |found| if (found.*) {
        count += 1;
    };
    const value: data_api.Value = .{ .kind = data_api.value_integer, .integer = count };
    return call.row.?(call.user_data, @ptrCast(&value), 1);
}
fn destroyMaintenanceBase(raw: ?*anyopaque) callconv(.c) void {
    std.heap.c_allocator.destroy(@as(*MaintenanceBase, @ptrCast(@alignCast(raw.?))));
}
fn registerMaintenanceCount(host: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const client = data_api.Client{ .host = host, .connection = raw };
    const state = std.heap.c_allocator.create(MaintenanceBase) catch return 2;
    client.vectorView("v", &state.view) catch {
        std.heap.c_allocator.destroy(state);
        return 1;
    };
    const operation: data_api.Operation = .{ .kind = data_api.operation_scalar, .flags = data_api.operation_exact, .name = .from("maintained_count"), .columns = &scalar_columns, .column_count = 1, .user_data = state, .destroy = destroyMaintenanceBase, .scalar = maintainedCount };
    client.registerOperation(&operation) catch {
        std.heap.c_allocator.destroy(state);
        return 1;
    };
    return 0;
}
test "extension_plugin automatic reconciliation sees inserts replacements deletes and rollback through SQL" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    var d = descriptor();
    d.flags |= data_api.requires_vector_maintenance;
    d.register_sql = registerMaintenanceCount;
    const ext = try plugin.validate(&d);
    try extension.install(&db.sqlite_db, .{ .extensions = &.{ext}, .plugins = &.{d} }, "c_test", null);
    try std.testing.expectEqual(@as(i64, 0), try scalarValue(&db.sqlite_db, "select zova_c_test_maintained_count()"));
    try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "select zova_c_test_maintained_count()"));
    try db.begin();
    try db.putVectors("v", &.{ .{ .id = "a", .values = .{ .f32 = &.{ 3, 4 } } }, .{ .id = "b", .values = .{ .f32 = &.{ 4, 5 } } } });
    try std.testing.expectEqual(@as(i64, 2), try scalarValue(&db.sqlite_db, "select zova_c_test_maintained_count()"));
    try db.savepoint("user");
    try db.deleteVector("v", "a");
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "select zova_c_test_maintained_count()"));
    try db.rollbackToSavepoint("user");
    try db.releaseSavepoint("user");
    try std.testing.expectEqual(@as(i64, 2), try scalarValue(&db.sqlite_db, "select zova_c_test_maintained_count()"));
    try db.rollback();
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "select zova_c_test_maintained_count()"));
    try db.deleteVector("v", "a");
    try std.testing.expectEqual(@as(i64, 0), try scalarValue(&db.sqlite_db, "select zova_c_test_maintained_count()"));
}

const scalar_columns = [_]data_api.OperationColumn{.{ .name = .from("value"), .kind = data_api.value_integer }};
const scalar_args = [_]data_api.OperationColumn{.{ .name = .from("input"), .kind = data_api.value_integer }};
fn plusOne(_: *const plugin.Host, _: ?*anyopaque, _: ?*anyopaque, call: *const data_api.OperationCall) callconv(.c) i32 {
    const value = data_api.Value{ .kind = data_api.value_integer, .integer = call.arguments.?[0].integer + 1 };
    return call.row.?(call.user_data, @ptrCast(&value), 1);
}
fn registerOperations(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const client = data_api.Client{ .host = base, .connection = raw };
    const operation: data_api.Operation = .{
        .kind = data_api.operation_scalar,
        .flags = data_api.operation_exact,
        .name = .from("plus_one"),
        .arguments = &scalar_args,
        .argument_count = 1,
        .columns = &scalar_columns,
        .column_count = 1,
        .scalar = plusOne,
    };
    client.registerOperation(&operation) catch return 1;
    return 0;
}

const RangeCursor = struct { index: i64 = 0, limit: i64 };
var range_closes: usize = 0;
var range_steps: usize = 0;
fn rangeOpen(_: *const plugin.Host, _: ?*anyopaque, _: ?*anyopaque, args: ?[*]const data_api.Value, _: u64, out: ?*?*anyopaque) callconv(.c) i32 {
    const cursor = std.heap.c_allocator.create(RangeCursor) catch return 2;
    cursor.* = .{ .limit = args.?[0].integer };
    out.?.* = cursor;
    if (cursor.limit == -1) return 2;
    return 0;
}
fn rangeNext(_: *const plugin.Host, _: ?*anyopaque, raw: ?*anyopaque, row: data_api.RowCallback, context: ?*anyopaque, has_row: ?*u32) callconv(.c) i32 {
    const cursor: *RangeCursor = @ptrCast(@alignCast(raw.?));
    range_steps += 1;
    has_row.?.* = 0;
    if (cursor.limit == -2) return 6;
    if (cursor.index >= cursor.limit) return 0;
    const value: data_api.Value = .{ .kind = data_api.value_integer, .integer = cursor.index };
    cursor.index += 1;
    has_row.?.* = 1;
    return row(context, @ptrCast(&value), 1);
}
fn rangeClose(raw: ?*anyopaque) callconv(.c) void {
    const cursor: *RangeCursor = @ptrCast(@alignCast(raw.?));
    std.heap.c_allocator.destroy(cursor);
    range_closes += 1;
}
fn registerRange(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const client = data_api.Client{ .host = base, .connection = raw };
    const operation: data_api.Operation = .{
        .kind = data_api.operation_table,
        .flags = data_api.operation_exact | data_api.operation_ordered,
        .name = .from("range"),
        .arguments = &scalar_args,
        .argument_count = 1,
        .columns = &scalar_columns,
        .column_count = 1,
        .open = rangeOpen,
        .next = rangeNext,
        .close = rangeClose,
    };
    client.registerOperation(&operation) catch return 1;
    return 0;
}
test "extension_plugin table operations stream and close at SQL LIMIT and reset" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    var d = descriptor();
    d.register_sql = registerRange;
    const ext = try plugin.validate(&d);
    const registry: extension.Registry = .{ .extensions = &.{ext}, .plugins = &.{d} };
    try extension.install(&db.sqlite_db, registry, "c_test", null);
    range_steps = 0;
    range_closes = 0;
    var stmt = try db.prepare("select value from zova_c_test_range(?1) limit 2");
    defer stmt.deinit();
    try stmt.bindInt64(1, 100000);
    for (0..2) |i| {
        try std.testing.expect(try stmt.step() == .row);
        try std.testing.expectEqual(@as(i64, @intCast(i)), stmt.columnInt64(0));
    }
    try std.testing.expect(try stmt.step() == .done);
    try std.testing.expectEqual(@as(usize, 2), range_steps);
    try std.testing.expectEqual(@as(usize, 1), range_closes);
    try stmt.reset();
    try stmt.bindInt64(1, 0);
    try std.testing.expect(try stmt.step() == .done);
    try std.testing.expectEqual(@as(usize, 2), range_closes);
    try std.testing.expectError(error.SqliteError, scalarValue(&db.sqlite_db, "select value from zova_c_test_range('2')"));
    try std.testing.expectError(error.SqliteError, db.prepare("select value from zova_c_test_range()"));
    try std.testing.expectEqual(@as(i64, 9), try scalarValue(&db.sqlite_db, "select count(*) from zova_c_test_range(3) a cross join zova_c_test_range(3) b"));
}

const huge_operation_result: [1024 * 1024]u8 = @splat(65);
const blob_operation_columns = [_]data_api.OperationColumn{.{ .name = .from("value"), .kind = data_api.value_blob }};
fn hugeScalar(_: *const plugin.Host, _: ?*anyopaque, _: ?*anyopaque, call: *const data_api.OperationCall) callconv(.c) i32 {
    const value: data_api.Value = .{ .kind = data_api.value_blob, .bytes = &huge_operation_result, .bytes_len = huge_operation_result.len };
    return call.row.?(call.user_data, @ptrCast(&value), 1);
}
fn registerHuge(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const d: data_api.Operation = .{ .kind = data_api.operation_scalar, .flags = data_api.operation_exact, .name = .from("huge"), .columns = &blob_operation_columns, .column_count = 1, .scalar = hugeScalar };
    (data_api.Client{ .host = base, .connection = raw }).registerOperation(&d) catch return 1;
    return 0;
}
test "extension_plugin scalar row budget includes Value records" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    var d = descriptor();
    d.register_sql = registerHuge;
    const ext = try plugin.validate(&d);
    try extension.install(&db.sqlite_db, .{ .extensions = &.{ext}, .plugins = &.{d} }, "c_test", null);
    try std.testing.expectError(error.SqliteError, scalarValue(&db.sqlite_db, "select zova_c_test_huge()"));
}

test "extension_plugin partial table opens cancellation and active cursors clean up safely" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    var d = descriptor();
    d.register_sql = registerRange;
    const ext = try plugin.validate(&d);
    const registry: extension.Registry = .{ .extensions = &.{ext}, .plugins = &.{d} };
    try extension.install(&db.sqlite_db, registry, "c_test", null);
    range_closes = 0;
    try std.testing.expectError(error.NoMemory, scalarValue(&db.sqlite_db, "select value from zova_c_test_range(-1)"));
    try std.testing.expectEqual(@as(usize, 1), range_closes);
    try std.testing.expectError(error.Interrupt, scalarValue(&db.sqlite_db, "select value from zova_c_test_range(-2)"));
    try std.testing.expectEqual(@as(usize, 2), range_closes);
    var stmt = try db.prepare("select value from zova_c_test_range(5)");
    try std.testing.expect(try stmt.step() == .row);
    try std.testing.expectError(error.Busy, extension.drop(&db.sqlite_db, registry, "c_test", null));
    try std.testing.expectError(error.Busy, extension.registerSqlForInstalled(&db.sqlite_db, registry));
    stmt.deinit();
    try std.testing.expectEqual(@as(usize, 3), range_closes);
    try extension.drop(&db.sqlite_db, registry, "c_test", null);
    try std.testing.expectError(error.SqliteError, db.prepare("select value from zova_c_test_range(5)"));
}

const NodeOperationCursor = struct { after: data_api.Cursor = .{} };
const NodeOperationDelivery = struct {
    row: data_api.RowCallback,
    context: ?*anyopaque,
    fn deliver(raw: ?*anyopaque, values: ?[*]const data_api.Value, _: u64) callconv(.c) i32 {
        const self: *NodeOperationDelivery = @ptrCast(@alignCast(raw.?));
        return self.row(self.context, values, 1);
    }
};
fn nodesOpen(_: *const plugin.Host, _: ?*anyopaque, _: ?*anyopaque, _: ?[*]const data_api.Value, _: u64, out: ?*?*anyopaque) callconv(.c) i32 {
    const cursor = std.heap.c_allocator.create(NodeOperationCursor) catch return 2;
    cursor.* = .{};
    out.?.* = cursor;
    return 0;
}
fn nodesNext(host: *const plugin.Host, raw: ?*anyopaque, state: ?*anyopaque, row: data_api.RowCallback, context: ?*anyopaque, has_row: ?*u32) callconv(.c) i32 {
    const cursor: *NodeOperationCursor = @ptrCast(@alignCast(state.?));
    const client = data_api.Client{ .host = host, .connection = raw };
    var delivery: NodeOperationDelivery = .{ .row = row, .context = context };
    var page: data_api.DataPage = .{};
    client.read(&.{ .operation = 1, .name = .from("topo"), .after = cursor.after, .row_limit = 1, .byte_limit = 4096, .row = NodeOperationDelivery.deliver, .user_data = &delivery }, &page) catch return 1;
    cursor.after = page.next;
    has_row.?.* = @intCast(page.rows);
    return 0;
}
fn nodesClose(raw: ?*anyopaque) callconv(.c) void {
    const cursor: *NodeOperationCursor = @ptrCast(@alignCast(raw.?));
    std.heap.c_allocator.destroy(cursor);
}
fn registerNodes(host: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const operation: data_api.Operation = .{ .kind = data_api.operation_table, .flags = data_api.operation_exact | data_api.operation_ordered, .name = .from("nodes"), .columns = &scalar_columns, .column_count = 1, .open = nodesOpen, .next = nodesNext, .close = nodesClose };
    (data_api.Client{ .host = host, .connection = raw }).registerOperation(&operation) catch return 1;
    return 0;
}
test "extension_plugin SQL streaming holds main and bound WAL snapshots" {
    const zova = @import("zova.zig");
    for ([_]bool{ false, true }) |bound| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const a = std.testing.allocator;
        const main = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/main.zova", .{tmp.sub_path}, 0);
        defer a.free(main);
        const store = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/graph.zova", .{tmp.sub_path}, 0);
        defer a.free(store);
        var db = try zova.Database.create(main);
        defer db.deinit();
        if (bound) {
            try zova.createGraphStore(store);
            try db.bindGraphStore(store);
        }
        try db.exec("pragma journal_mode=wal");
        if (bound) try db.exec("pragma graph_store.journal_mode=wal");
        try db.createGraph("topo");
        try db.putGraphNodes(&.{ .{ .graph_name = "topo", .node_id = "a", .kind = "node" }, .{ .graph_name = "topo", .node_id = "b", .kind = "node" } });
        // Open writer before recording the test extension; it needs no plugin.
        var writer = try zova.Database.open(main);
        defer writer.deinit();
        var d = descriptor();
        d.register_sql = registerNodes;
        const ext = try plugin.validate(&d);
        try extension.install(&db.sqlite_db, .{ .extensions = &.{ext}, .plugins = &.{d} }, "c_test", null);
        {
            var stmt = try db.prepare("select value from zova_c_test_nodes()");
            defer stmt.deinit();
            try std.testing.expect(try stmt.step() == .row);
            try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(0));
            try writer.putGraphNode(.{ .graph_name = "topo", .node_id = "c", .kind = "node" });
            try std.testing.expect(try stmt.step() == .row);
            try std.testing.expectEqual(@as(i64, 2), stmt.columnInt64(0));
            try std.testing.expect(try stmt.step() == .done);
        }
        try std.testing.expectEqual(@as(i64, 3), try scalarValue(&db.sqlite_db, "select count(*) from zova_c_test_nodes()"));
    }
}

test "extension_plugin live source cursors reject interleaved vector writes" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.createGraph("topo");
    try db.putGraphNodes(&.{ .{ .graph_name = "topo", .node_id = "a", .kind = "node" }, .{ .graph_name = "topo", .node_id = "b", .kind = "node" } });
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    var d = descriptor();
    d.register_sql = registerNodes;
    const ext = try plugin.validate(&d);
    try extension.install(&db.sqlite_db, .{ .extensions = &.{ext}, .plugins = &.{d} }, "c_test", null);
    var stmt = try db.prepare("select value from zova_c_test_nodes()");
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectError(error.Busy, db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } }));
    try stmt.reset();
    try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
}

test "extension_plugin live source cursors reject interleaved graph writes" {
    const zova = @import("zova.zig");
    for ([_]bool{ false, true }) |bound| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const a = std.testing.allocator;
        const main = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/main.zova", .{tmp.sub_path}, 0);
        defer a.free(main);
        const store = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/graph.zova", .{tmp.sub_path}, 0);
        defer a.free(store);
        var db = try zova.Database.create(main);
        defer db.deinit();
        if (bound) {
            try zova.createGraphStore(store);
            try db.bindGraphStore(store);
        }
        try db.createGraph("topo");
        try db.putGraphNodes(&.{ .{ .graph_name = "topo", .node_id = "a", .kind = "node" }, .{ .graph_name = "topo", .node_id = "b", .kind = "node" } });
        try db.putGraphEdge(.{ .graph_name = "topo", .from_node_id = "a", .edge_type = "to", .to_node_id = "b" });
        var d = descriptor();
        d.register_sql = registerNodes;
        const ext = try plugin.validate(&d);
        try extension.install(&db.sqlite_db, .{ .extensions = &.{ext}, .plugins = &.{d} }, "c_test", null);
        try db.exec("create table caller_work(x integer)");

        const node: zova.GraphNodeInput = .{ .graph_name = "topo", .node_id = "c", .kind = "node" };
        const edge: zova.GraphEdgeInput = .{ .graph_name = "topo", .from_node_id = "b", .edge_type = "to", .to_node_id = "a" };
        const existing: zova.GraphEdgeInput = .{ .graph_name = "topo", .from_node_id = "a", .edge_type = "to", .to_node_id = "b" };
        var keys: [1]i64 = undefined;

        // Rejection must precede mutation and keep earlier caller-transaction work.
        try db.exec("begin");
        try db.exec("insert into caller_work values (1)");
        {
            var stmt = try db.prepare("select value from zova_c_test_nodes()");
            defer stmt.deinit();
            try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
            try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(0));
            try std.testing.expectError(error.Busy, db.putGraphNode(node));
            try std.testing.expectError(error.Busy, db.putGraphNodes(&.{node}));
            try std.testing.expectError(error.Busy, db.putGraphNodesKeyed(&.{node}, &keys));
            try std.testing.expectError(error.Busy, db.deleteGraphNode("topo", "b"));
            try std.testing.expectError(error.Busy, db.deleteGraphNodes("topo", &.{"b"}));
            try std.testing.expectError(error.Busy, db.putGraphEdge(edge));
            try std.testing.expectError(error.Busy, db.putGraphEdges(&.{edge}));
            try std.testing.expectError(error.Busy, db.putGraphEdgesKeyed(&.{edge}, &keys));
            try std.testing.expectError(error.Busy, db.deleteGraphEdge(existing));
            try std.testing.expectError(error.Busy, db.deleteGraphEdges(&.{existing}));
            try std.testing.expectError(error.Busy, db.createGraph("other"));
            try std.testing.expectError(error.Busy, db.deleteGraph("topo"));
            // The stream still sees exactly the source it started with.
            try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
            try std.testing.expectEqual(@as(i64, 2), stmt.columnInt64(0));
            try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
            // EOF releases the source cursor.
            try db.putGraphNode(node);
            try stmt.reset();
            try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
            try std.testing.expectError(error.Busy, db.putGraphEdge(edge));
            try stmt.reset();
            try db.putGraphEdge(edge);
        }
        try db.exec("commit");
        try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "select count(*) from caller_work"));
        try std.testing.expectEqual(@as(i64, 3), try scalarValue(&db.sqlite_db, "select count(*) from zova_c_test_nodes()"));
        try std.testing.expect(try db.hasGraphEdge("topo", "a", "to", "b"));
        try std.testing.expect(try db.hasGraphEdge("topo", "b", "to", "a"));
        try std.testing.expect(!try db.hasGraph("other"));
        // Finalized statements leave ordinary graph behavior unchanged.
        try db.deleteGraphNodes("topo", &.{"c"});
        try db.deleteGraph("topo");
    }
}

test "extension_plugin SQL scalar registration has typed arguments and connection lifetime" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    var d = descriptor();
    d.register_sql = registerOperations;
    const ext = try plugin.validate(&d);
    const registry: extension.Registry = .{ .extensions = &.{ext}, .plugins = &.{d} };
    try extension.install(&db.sqlite_db, registry, "c_test", null);
    var stmt = try db.prepare("select zova_c_test_plus_one(?1)");
    defer stmt.deinit();
    try stmt.bindInt64(1, 41);
    try std.testing.expect(try stmt.step() == .row);
    try std.testing.expectEqual(@as(i64, 42), stmt.columnInt64(0));
    try stmt.reset();
    try stmt.bindText(1, "wrong type");
    try std.testing.expectError(error.SqliteError, stmt.step());
}

var operation_destroys: usize = 0;
const OwnedOperationState = struct { increment: i64 };
fn destroyOperation(raw: ?*anyopaque) callconv(.c) void {
    const state: *OwnedOperationState = @ptrCast(@alignCast(raw.?));
    std.heap.c_allocator.destroy(state);
    operation_destroys += 1;
}
fn ownedScalar(_: *const plugin.Host, _: ?*anyopaque, raw: ?*anyopaque, call: *const data_api.OperationCall) callconv(.c) i32 {
    const state: *OwnedOperationState = @ptrCast(@alignCast(raw.?));
    const value: data_api.Value = .{ .kind = data_api.value_integer, .integer = call.arguments.?[0].integer + state.increment };
    return call.row.?(call.user_data, @ptrCast(&value), 1);
}
fn registerOwnedValue(base: *const plugin.Host, raw: ?*anyopaque, increment: i64) i32 {
    const state = std.heap.c_allocator.create(OwnedOperationState) catch return 2;
    state.* = .{ .increment = increment };
    const operation: data_api.Operation = .{
        .kind = data_api.operation_scalar,
        .flags = data_api.operation_exact,
        .name = .from("owned"),
        .arguments = &scalar_args,
        .argument_count = 1,
        .columns = &scalar_columns,
        .column_count = 1,
        .scalar = ownedScalar,
        .user_data = state,
        .destroy = destroyOperation,
    };
    (data_api.Client{ .host = base, .connection = raw }).registerOperation(&operation) catch {
        destroyOperation(state);
        return 1;
    };
    return 0;
}
fn registerOwned(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    return registerOwnedValue(base, raw, 1);
}
fn registerOwnedUpgrade(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    return registerOwnedValue(base, raw, 2);
}
fn rejectCore(_: *sqlite.Database) !void {
    return error.InvalidArgument;
}
fn noUpgrade(_: *sqlite.Database, _: extension.Manifest) extension.Error!void {}
fn scalarValue(db: *sqlite.Database, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expect(try stmt.step() == .row);
    return stmt.columnInt64(0);
}
test "extension_plugin failed lifecycle discards callbacks and successful upgrade supports caller rollback" {
    operation_destroys = 0;
    {
        var db = try @import("zova.zig").Database.createMemory();
        defer db.deinit();
        var d = descriptor();
        d.register_sql = registerOwned;
        d.version = "1.0.0";
        const ext = try plugin.validate(&d);
        const old: extension.Registry = .{ .extensions = &.{ext}, .plugins = &.{d} };
        try std.testing.expectError(error.ExtensionInvalid, extension.install(&db.sqlite_db, old, "c_test", rejectCore));
        try std.testing.expectEqual(@as(usize, 1), operation_destroys);
        try std.testing.expectError(error.SqliteError, scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
        try extension.install(&db.sqlite_db, old, "c_test", null);
        try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
        var upgraded = d;
        upgraded.version = "2.0.0";
        upgraded.register_sql = registerOwnedUpgrade;
        const target = try plugin.validate(&upgraded);
        const next: extension.Registry = .{ .extensions = &.{target}, .plugins = &.{upgraded}, .upgrades = &.{.{ .name = "c_test", .from_version = "1.0.0", .to_version = "2.0.0", .hook = noUpgrade }} };
        try std.testing.expectError(error.ExtensionInvalid, extension.upgrade(std.testing.allocator, &db.sqlite_db, next, "c_test", rejectCore));
        try std.testing.expectEqual(@as(usize, 2), operation_destroys);
        try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
        try db.begin();
        try extension.upgrade(std.testing.allocator, &db.sqlite_db, next, "c_test", null);
        try std.testing.expectEqual(@as(i64, 43), try scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
        try db.rollback();
        try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
        try db.begin();
        try extension.drop(&db.sqlite_db, old, "c_test", null);
        try std.testing.expectError(error.SqliteError, scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
        try db.rollback();
        try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
    }
    try std.testing.expectEqual(@as(usize, 4), operation_destroys);
}

test "extension_plugin compatibility registrations use data versions across code changes and rollback" {
    operation_destroys = 0;
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    var d: plugin.CompatibilityDescriptor = .{ .base = .{ .base = descriptor(), .from_version = null, .upgrade = null }, .data_version = "1.0.0", .accepted_data_versions = "1.0.0" };
    d.base.base.struct_size = @sizeOf(plugin.CompatibilityDescriptor);
    d.base.base.flags = plugin.has_data_compatibility;
    d.base.base.version = "3.1.0";
    d.base.base.register_sql = registerOwned;
    const item = try plugin.validate(&d.base.base);
    const compatibility = (try plugin.compatibilityPath(&d.base.base)).?;
    const initial: extension.Registry = .{ .extensions = &.{item}, .plugins = &.{d.base.base}, .compatibilities = &.{compatibility} };
    try extension.install(&db.sqlite_db, initial, "c_test", null);
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));

    var next = d;
    next.base.base.version = "3.2.0";
    next.base.base.register_sql = registerOwnedUpgrade;
    next.base.base.flags |= plugin.has_upgrade;
    next.base.from_version = "1.0.0";
    next.base.upgrade = outOfMemory;
    next.data_version = "2.0.0";
    next.accepted_data_versions = "2.0.0";
    const next_item = try plugin.validate(&next.base.base);
    const next_compatibility = (try plugin.compatibilityPath(&next.base.base)).?;
    // The native no-op path isolates callback/metadata behavior, not algorithm changes.
    const upgraded: extension.Registry = .{ .extensions = &.{next_item}, .plugins = &.{next.base.base}, .compatibilities = &.{next_compatibility}, .upgrades = &.{.{ .name = "c_test", .from_version = "1.0.0", .to_version = "2.0.0", .hook = noUpgrade }} };
    try std.testing.expectError(error.ExtensionInvalid, extension.upgrade(std.testing.allocator, &db.sqlite_db, upgraded, "c_test", rejectCore));
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
    try db.begin();
    try extension.upgrade(std.testing.allocator, &db.sqlite_db, upgraded, "c_test", null);
    try std.testing.expectEqual(@as(i64, 43), try scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
    try db.rollback();
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
    // A code-only re-registration accepting the older data must tag that visible
    // version, not the preferred installation target or the new code version.
    next.accepted_data_versions = "1.0.0,2.0.0";
    const accepted = (try plugin.compatibilityPath(&next.base.base)).?;
    const code_only: extension.Registry = .{ .extensions = &.{next_item}, .plugins = &.{next.base.base}, .compatibilities = &.{accepted} };
    try extension.registerSqlForInstalled(&db.sqlite_db, code_only);
    try std.testing.expectEqual(@as(i64, 43), try scalarValue(&db.sqlite_db, "select zova_c_test_owned(41)"));
}

fn writeScalar(base: *const plugin.Host, raw: ?*anyopaque, _: ?*anyopaque, call: *const data_api.OperationCall) callconv(.c) i32 {
    const client = data_api.Client{ .host = base, .connection = raw };
    const sql = "insert into main._zova_ext_c_test_rows values (?1)";
    client.storage(&.{ .sql = sql, .sql_len = sql.len, .parameters = call.arguments, .parameter_count = 1, .row_limit = 1, .byte_limit = 1024, .row = cancelRows }) catch return 1;
    if (call.arguments.?[0].integer < 0) return 6;
    return call.row.?(call.user_data, call.arguments, 1);
}
fn registerWrites(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const client = data_api.Client{ .host = base, .connection = raw };
    var operation: data_api.Operation = .{ .kind = data_api.operation_scalar, .flags = data_api.operation_exact | data_api.operation_mutating, .name = .from("write"), .arguments = &scalar_args, .argument_count = 1, .columns = &scalar_columns, .column_count = 1, .scalar = writeScalar };
    client.registerOperation(&operation) catch return 1;
    operation.name = .from("readonly_write");
    operation.flags = data_api.operation_exact;
    client.registerOperation(&operation) catch return 1;
    return 0;
}

const text_operation_columns = [_]data_api.OperationColumn{.{ .name = .from("value"), .kind = data_api.value_text }};
fn writeTextScalar(base: *const plugin.Host, raw: ?*anyopaque, _: ?*anyopaque, call: *const data_api.OperationCall) callconv(.c) i32 {
    const sql = "insert into main._zova_ext_c_test_rows values (?1)";
    (data_api.Client{ .host = base, .connection = raw }).storage(&.{ .sql = sql, .sql_len = sql.len, .parameters = call.arguments, .parameter_count = 1, .row_limit = 1, .byte_limit = 1024, .row = cancelRows }) catch return 1;
    const text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const value: data_api.Value = .{ .kind = data_api.value_text, .bytes = text.ptr, .bytes_len = text.len };
    return call.row.?(call.user_data, @ptrCast(&value), 1);
}
fn registerWriteText(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const d: data_api.Operation = .{ .kind = data_api.operation_scalar, .flags = data_api.operation_exact | data_api.operation_mutating, .name = .from("write_text"), .arguments = &scalar_args, .argument_count = 1, .columns = &text_operation_columns, .column_count = 1, .scalar = writeTextScalar };
    (data_api.Client{ .host = base, .connection = raw }).registerOperation(&d) catch return 1;
    return 0;
}
test "extension_plugin SQLite result limits roll back a scalar write" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.exec("create table _zova_ext_c_test_rows(id integer)");
    var d = descriptor();
    d.register_sql = registerWriteText;
    const ext = try plugin.validate(&d);
    try extension.install(&db.sqlite_db, .{ .extensions = &.{ext}, .plugins = &.{d} }, "c_test", null);
    const old = sqlite.c.sqlite3_limit(db.sqlite_db.handle, sqlite.c.SQLITE_LIMIT_LENGTH, 50);
    defer _ = sqlite.c.sqlite3_limit(db.sqlite_db.handle, sqlite.c.SQLITE_LIMIT_LENGTH, old);
    try std.testing.expectError(error.SqliteError, scalarValue(&db.sqlite_db, "select zova_c_test_write_text(1)"));
    try std.testing.expectEqual(@as(i64, 0), try scalarValue(&db.sqlite_db, "select count(*) from _zova_ext_c_test_rows"));
}
test "extension_plugin operation registration preserves query-only bound-store protection" {
    const zova = @import("zova.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const main = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/main.zova", .{tmp.sub_path}, 0);
    defer allocator.free(main);
    const graphs = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/graphs.zova", .{tmp.sub_path}, 0);
    defer allocator.free(graphs);
    try zova.createGraphStore(graphs);
    var d = descriptor();
    d.register_sql = registerOperations;
    const ext = try plugin.validate(&d);
    const registry: extension.Registry = .{ .extensions = &.{ext}, .plugins = &.{d} };
    {
        var db = try zova.Database.createWithExtensions(main, registry);
        defer db.deinit();
        try db.bindGraphStore(graphs);
        try db.createGraph("source");
        try db.exec("create table graph_store.protected_rows(value integer)");
        try db.installExtension("c_test");
    }
    var db = try zova.Database.openWithOptionsAndExtensions(main, .{ .read_only = true }, registry);
    defer db.deinit();
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "select zova_c_test_plus_one(41)"));
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "pragma query_only"));
    try std.testing.expectError(error.ReadOnly, db.exec("create table forbidden(value integer)"));
    try std.testing.expectError(error.ReadOnly, db.exec("create table graph_store.forbidden(value integer)"));
    try std.testing.expectError(error.ReadOnly, db.exec("create temp table forbidden(value integer)"));
    // query_only can also be set by the caller on a writable connection. A
    // TEMP trigger must not redirect its host marker into persistent writes.
    var writable = try zova.Database.openWithOptionsAndExtensions(main, .{}, registry);
    defer writable.deinit();
    try writable.exec("create temp trigger redirect_marker before update on _zova_plugin_generations begin insert into protected_rows values(7); end; pragma query_only=on");
    try std.testing.expectError(error.SqliteError, extension.registerSqlForInstalled(&writable.sqlite_db, registry));
    try std.testing.expectEqual(@as(i64, 0), try scalarValue(&writable.sqlite_db, "select count(*) from graph_store.protected_rows"));
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&writable.sqlite_db, "pragma query_only"));
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&writable.sqlite_db, "select zova_c_test_plus_one(41)"));
}

test "extension_plugin scalar writes are atomic and read-only operations cannot mutate" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.exec("create table _zova_ext_c_test_rows(id integer)");
    var d = descriptor();
    d.register_sql = registerWrites;
    const ext = try plugin.validate(&d);
    const registry: extension.Registry = .{ .extensions = &.{ext}, .plugins = &.{d} };
    // The private table is owned once installation records the manifest.
    try extension.install(&db.sqlite_db, registry, "c_test", null);
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "select zova_c_test_write(1)"));
    try std.testing.expectError(error.Interrupt, scalarValue(&db.sqlite_db, "select zova_c_test_write(-1)"));
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "select count(*) from _zova_ext_c_test_rows"));
    try std.testing.expectError(error.SqliteError, scalarValue(&db.sqlite_db, "select zova_c_test_readonly_write(2)"));
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "select count(*) from _zova_ext_c_test_rows"));
    try db.begin();
    try db.exec("insert into _zova_ext_c_test_rows values(9)");
    try std.testing.expectError(error.Interrupt, scalarValue(&db.sqlite_db, "select zova_c_test_write(-2)"));
    try std.testing.expectEqual(@as(i64, 2), try scalarValue(&db.sqlite_db, "select count(*) from _zova_ext_c_test_rows"));
    try db.rollback();
    try db.exec("pragma query_only=on");
    try std.testing.expectError(error.SqliteError, scalarValue(&db.sqlite_db, "select zova_c_test_write(3)"));
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "select count(*) from _zova_ext_c_test_rows"));
}

fn dataServiceHook(base: *const plugin.Host, context: ?*anyopaque) callconv(.c) i32 {
    const host: *const plugin.ServiceHost = @ptrCast(base);
    var service: ?*const anyopaque = null;
    return host.get_service.?(context, 3, 1, 16, &service);
}

test "extension_plugin negotiates bounded authoritative data access" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    var d = descriptor();
    d.check = dataServiceHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
}

test "extension_plugin Zig data helper clears output on an older host" {
    const host = plugin.legacyHost();
    const client = data_api.Client{ .host = &host, .connection = null };
    var page: data_api.DataPage = .{ .rows = 9, .has_more = 1 };
    const request: data_api.DataRequest = .{ .operation = 1, .name = .from("g"), .row_limit = 1, .byte_limit = 1024, .row = cancelRows };
    try std.testing.expectError(error.Unsupported, client.read(&request, &page));
    try std.testing.expectEqualDeep(data_api.DataPage{}, page);
}

const data_api = @import("extension_plugin_api.zig");
const DataRows = struct {
    count: usize = 0,
    first: [16]i64 = @splat(0),
    second: [16]i64 = @splat(0),
    texts: [16][256]u8 = undefined,
    lengths: [16]usize = @splat(0),
    text_column: usize = 1,
    fn receive(raw: ?*anyopaque, values: ?[*]const plugin.Value, count: u64) callconv(.c) i32 {
        const self: *DataRows = @ptrCast(@alignCast(raw.?));
        if (self.count == self.first.len or count <= self.text_column) return 3;
        const row = values.?[0..@intCast(count)];
        self.first[self.count] = row[0].integer;
        self.second[self.count] = if (row.len > 1) row[1].integer else 0;
        const value = row[self.text_column];
        if (value.bytes_len > 256) return 3;
        self.lengths[self.count] = @intCast(value.bytes_len);
        if (value.bytes_len != 0) @memcpy(self.texts[self.count][0..@intCast(value.bytes_len)], value.bytes.?[0..@intCast(value.bytes_len)]);
        self.count += 1;
        return 0;
    }
};

fn exerciseData(base: *const plugin.Host, raw: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = raw };
    var rows: DataRows = .{};
    var request: data_api.DataRequest = .{ .operation = 1, .name = .from("topo"), .row_limit = 1, .byte_limit = 4096, .row = DataRows.receive, .user_data = &rows };
    var page: data_api.DataPage = .{};
    try client.read(&request, &page);
    try std.testing.expectEqual(@as(u32, 1), page.has_more);
    try std.testing.expectEqualStrings("z", rows.texts[0][0..rows.lengths[0]]);
    request.after = page.next;
    rows = .{};
    try client.read(&request, &page);
    try std.testing.expectEqual(@as(u32, 0), page.has_more);
    try std.testing.expectEqualStrings("a", rows.texts[0][0..rows.lengths[0]]);
    const keys = [_]i64{ 2, 999, 2, 3 };
    request.operation = 3;
    request.keys = &keys;
    request.key_count = keys.len;
    request.row_limit = keys.len;
    rows = .{ .text_column = 3 };
    try client.read(&request, &page);
    try std.testing.expectEqualSlices(i64, &.{ 0, 1, 2, 3 }, rows.first[0..4]);
    try std.testing.expectEqualSlices(i64, &.{ 1, 0, 1, 0 }, rows.second[0..4]);
    request.operation = 2;
    request.after = .{};
    rows = .{ .text_column = 2 };
    try client.read(&request, &page);
    try std.testing.expectEqual(@as(usize, 1), rows.count);
    try std.testing.expectEqualStrings("link", rows.texts[0][0..rows.lengths[0]]);
    request.operation = 5;
    request.node_id = .from("z");
    rows = .{ .text_column = 2 };
    try client.read(&request, &page);
    try std.testing.expectEqualStrings("a", rows.texts[0][0..rows.lengths[0]]);
    request.operation = 6;
    request.name = .from("vec");
    rows = .{ .text_column = 1 };
    try client.read(&request, &page);
    try std.testing.expectEqual(@as(i64, 2), rows.first[0]);
    try std.testing.expectEqualStrings("f32", rows.texts[0][0..rows.lengths[0]]);
    request.operation = 7;
    rows = .{ .text_column = 0 };
    try client.read(&request, &page);
    try std.testing.expectEqualStrings("v", rows.texts[0][0..rows.lengths[0]]);
    const ids = [_]data_api.Bytes{ .from("v"), .from("missing"), .from("v") };
    request.operation = 8;
    request.ids = &ids;
    request.id_count = ids.len;
    rows = .{ .text_column = 2 };
    try client.read(&request, &page);
    try std.testing.expectEqualSlices(i64, &.{ 1, 0, 1 }, rows.second[0..3]);
    const nul_ids = [_]data_api.Bytes{ .from("v\x00x"), .from("v\x00x") };
    request.ids = &nul_ids;
    request.id_count = nul_ids.len;
    rows = .{ .text_column = 2 };
    try client.read(&request, &page);
    try std.testing.expectEqualSlices(i64, &.{ 1, 1 }, rows.second[0..2]);
}

fn dataHook(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    exerciseData(base, raw) catch return 1;
    return 0;
}

test "extension_plugin graph vector pages and batches preserve identities" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try populateData(&db);
    var d = descriptor();
    d.check = dataHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
}

fn populateData(db: *@import("zova.zig").Database) !void {
    try db.createGraph("topo");
    try db.createGraph("other");
    try db.putGraphNodes(&.{
        .{ .graph_name = "topo", .node_id = "z", .kind = "node" },
        .{ .graph_name = "topo", .node_id = "a", .kind = "node" },
        .{ .graph_name = "other", .node_id = "a", .kind = "node" },
    });
    try db.putGraphEdges(&.{.{ .graph_name = "topo", .from_node_id = "z", .to_node_id = "a", .edge_type = "link" }});
    try db.createVectorCollection("vec", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("vec", "v", .{ .f32 = &.{ 1, 2 } });
    try db.putVector("vec", "v\x00x", .{ .f32 = &.{ 3, 4 } });
}

fn cancelRows(_: ?*anyopaque, _: ?[*]const plugin.Value, _: u64) callconv(.c) i32 {
    return 6;
}
fn oomRows(_: ?*anyopaque, _: ?[*]const plugin.Value, _: u64) callconv(.c) i32 {
    return 2;
}
fn limitsHook(base: *const plugin.Host, context: ?*anyopaque) callconv(.c) i32 {
    limitsExercise(base, context) catch return 1;
    return 0;
}
fn limitsExercise(base: *const plugin.Host, context: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = context };
    var rows: DataRows = .{};
    var req: data_api.DataRequest = .{ .operation = 1, .name = .from("topo"), .row_limit = 2, .byte_limit = 1, .row = DataRows.receive, .user_data = &rows };
    var page: data_api.DataPage = .{ .rows = 99, .has_more = 1 };
    try std.testing.expectError(error.Limit, client.read(&req, &page));
    try std.testing.expectEqualDeep(data_api.DataPage{}, page);
    try std.testing.expectEqual(@as(usize, 0), rows.count);
    req.byte_limit = 4096;
    req.row = cancelRows;
    try std.testing.expectError(error.Canceled, client.read(&req, &page));
    try std.testing.expectEqualDeep(data_api.DataPage{}, page);
    req.row = oomRows;
    try std.testing.expectError(error.OutOfMemory, client.read(&req, &page));
    req.row = DataRows.receive;
    req.row_limit = 0;
    try std.testing.expectError(error.InvalidArgument, client.read(&req, &page));
    req.row_limit = 4097;
    try std.testing.expectError(error.InvalidArgument, client.read(&req, &page));
    req.row_limit = 2;
    req.struct_size = 8;
    try std.testing.expectError(error.InvalidArgument, client.read(&req, &page));
    req.struct_size = @sizeOf(data_api.DataRequest);
    req.after = .{ .key = 1 };
    try std.testing.expectError(error.InvalidArgument, client.read(&req, &page));
    req.after = .{};
    req.operation = 3;
    req.key_count = 1;
    try std.testing.expectError(error.InvalidArgument, client.read(&req, &page));
    const invalid_keys = [_]i64{0};
    req.keys = &invalid_keys;
    try std.testing.expectError(error.InvalidArgument, client.read(&req, &page));
    req.keys = null;
    req.key_count = 0;
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, 0), page.rows);
    req.name = .from("missing");
    try std.testing.expectError(error.HostError, client.read(&req, &page));
    req.name = .from("topo");
    const edge_keys = [_]i64{ 1, 999, 1 };
    req.operation = 4;
    req.keys = &edge_keys;
    req.key_count = edge_keys.len;
    req.row_limit = 3;
    rows = .{ .text_column = 4 };
    try client.read(&req, &page);
    try std.testing.expectEqualSlices(i64, &.{ 0, 1, 2 }, rows.first[0..3]);
    try std.testing.expectEqualSlices(i64, &.{ 1, 0, 1 }, rows.second[0..3]);
    req.operation = 5;
    req.node_id = .from("a");
    req.direction = 1;
    req.edge_type = .from("link");
    rows = .{ .text_column = 2 };
    try client.read(&req, &page);
    try std.testing.expectEqualStrings("z", rows.texts[0][0..rows.lengths[0]]);
    req.edge_type = .from("absent");
    rows = .{};
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, 0), page.rows);
}
fn applicationTableHook(base: *const plugin.Host, context: ?*anyopaque) callconv(.c) i32 {
    const client = data_api.Client{ .host = base, .connection = context };
    var rows: DataRows = .{ .text_column = 1 };
    const sql = "SELECT id,body FROM main.app_notes WHERE id=?1";
    const parameters = [_]plugin.Value{.{ .kind = plugin.value_integer, .integer = 7 }};
    client.query(&.{ .sql = sql, .sql_len = sql.len, .parameters = &parameters, .parameter_count = 1, .row_limit = 2, .byte_limit = 1024, .row = DataRows.receive, .user_data = &rows }) catch return 1;
    if (rows.count != 1 or rows.first[0] != 7 or !std.mem.eql(u8, rows.texts[0][0..rows.lengths[0]], "seven")) return 1;
    // The query service stays read-only: application tables cannot be written.
    const write = "INSERT INTO main.app_notes VALUES(8,'eight')";
    client.query(&.{ .sql = write, .sql_len = write.len, .row_limit = 1, .byte_limit = 1024, .row = DataRows.receive, .user_data = &rows }) catch return 0;
    return 1;
}
fn noteBody(base: *const plugin.Host, raw: ?*anyopaque, _: ?*anyopaque, call: *const data_api.OperationCall) callconv(.c) i32 {
    if (applicationTableHook(base, raw) != 0) return 1;
    return call.row.?(call.user_data, call.arguments, 1);
}
fn registerNoteBody(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const client = data_api.Client{ .host = base, .connection = raw };
    client.registerOperation(&.{ .kind = data_api.operation_scalar, .flags = data_api.operation_exact, .name = .from("note"), .arguments = &scalar_args, .argument_count = 1, .columns = &scalar_columns, .column_count = 1, .scalar = noteBody }) catch return 1;
    return 0;
}
test "extension_plugin read-only operations may query application tables" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.exec("CREATE TABLE app_notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO app_notes VALUES(7,'seven')");
    var d = descriptor();
    d.register_sql = registerNoteBody;
    const ext = try plugin.validate(&d);
    try extension.install(&db.sqlite_db, .{ .extensions = &.{ext}, .plugins = &.{d} }, "c_test", null);
    // The operation reads the row and its attempted write is refused.
    try std.testing.expectEqual(@as(i64, 7), try scalarValue(&db.sqlite_db, "select zova_c_test_note(7)"));
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "SELECT count(*) FROM app_notes"));
}

test "extension_plugin read-only hooks may query application tables" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.exec("CREATE TABLE app_notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO app_notes VALUES(7,'seven')");
    var d = descriptor();
    d.check = applicationTableHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
    try std.testing.expectEqual(@as(i64, 1), try scalarValue(&db.sqlite_db, "SELECT count(*) FROM app_notes"));
}

const PayloadRows = struct {
    count: usize = 0,
    ordinals: [8]i64 = @splat(0),
    found: [8]i64 = @splat(0),
    keys: [8]i64 = @splat(0),
    kinds: [8]u32 = @splat(0),
    payloads: [8][8]u8 = undefined,
    lengths: [8]usize = @splat(0),
    fn receive(raw: ?*anyopaque, values: ?[*]const plugin.Value, count: u64) callconv(.c) i32 {
        const self: *PayloadRows = @ptrCast(@alignCast(raw.?));
        if (self.count == self.keys.len or count != 4) return 3;
        const row = values.?[0..4];
        self.ordinals[self.count] = row[0].integer;
        self.found[self.count] = row[1].integer;
        self.keys[self.count] = row[2].integer;
        self.kinds[self.count] = row[3].kind;
        if (row[3].bytes_len > 8) return 3;
        self.lengths[self.count] = @intCast(row[3].bytes_len);
        if (row[3].bytes_len != 0) @memcpy(self.payloads[self.count][0..@intCast(row[3].bytes_len)], row[3].bytes.?[0..@intCast(row[3].bytes_len)]);
        self.count += 1;
        return 0;
    }
};
// topo edge with a payload, topo edge without one, and an edge of another graph.
var payload_edge_keys: [3]i64 = @splat(0);
fn payloadHook(base: *const plugin.Host, context: ?*anyopaque) callconv(.c) i32 {
    payloadExercise(base, context) catch return 1;
    return 0;
}
fn payloadExercise(base: *const plugin.Host, context: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = context };
    const keys = [_]i64{ payload_edge_keys[0], 999, payload_edge_keys[1], payload_edge_keys[0], payload_edge_keys[2] };
    var rows: PayloadRows = .{};
    var req: data_api.DataRequest = .{ .operation = 9, .name = .from("topo"), .keys = &keys, .key_count = keys.len, .row_limit = keys.len, .byte_limit = 4096, .row = PayloadRows.receive, .user_data = &rows };
    var page: data_api.DataPage = .{};
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, keys.len), page.rows);
    try std.testing.expectEqual(@as(u32, 0), page.has_more);
    try std.testing.expectEqualSlices(i64, &.{ 0, 1, 2, 3, 4 }, rows.ordinals[0..5]);
    try std.testing.expectEqualSlices(i64, &.{ 1, 0, 1, 1, 0 }, rows.found[0..5]);
    try std.testing.expectEqualSlices(i64, &keys, rows.keys[0..5]);
    // An empty payload is a zero-length BLOB; a miss is NULL.
    try std.testing.expectEqualSlices(u32, &.{ plugin.value_blob, plugin.value_null, plugin.value_blob, plugin.value_blob, plugin.value_null }, rows.kinds[0..5]);
    try std.testing.expectEqualStrings("p\x00y", rows.payloads[0][0..rows.lengths[0]]);
    try std.testing.expectEqual(@as(usize, 0), rows.lengths[2]);
    try std.testing.expectEqualStrings("p\x00y", rows.payloads[3][0..rows.lengths[3]]);

    // Payload bytes count toward the byte budget and fail the whole call.
    rows = .{};
    req.byte_limit = 4 * @sizeOf(plugin.Value) + 2;
    page = .{ .rows = 99, .has_more = 1 };
    try std.testing.expectError(error.Limit, client.read(&req, &page));
    try std.testing.expectEqualDeep(data_api.DataPage{}, page);
    req.byte_limit = 4096;

    req.key_count = 0;
    req.keys = null;
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, 0), page.rows);
    req.keys = &keys;
    req.key_count = keys.len;
    req.row_limit = keys.len - 1;
    try std.testing.expectError(error.InvalidArgument, client.read(&req, &page));
    req.row_limit = keys.len;
    req.name = .from("missing");
    try std.testing.expectError(error.HostError, client.read(&req, &page));
    req.name = .from("topo");
    req.operation = 11;
    try std.testing.expectError(error.InvalidArgument, client.read(&req, &page));
}
test "extension_plugin edge payload batches preserve ordinals misses and budgets" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try populateData(&db);
    try db.putGraphEdges(&.{
        .{ .graph_name = "topo", .from_node_id = "a", .to_node_id = "z", .edge_type = "back" },
        .{ .graph_name = "other", .from_node_id = "a", .to_node_id = "a", .edge_type = "self" },
    });
    var stmt = try db.prepare("select e.edge_key from _zova_graph_edges e join _zova_graphs g on g.graph_key=e.graph_key order by g.name desc,e.edge_key");
    defer stmt.deinit();
    for (&payload_edge_keys) |*key| {
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        key.* = stmt.columnInt64(0);
    }
    try db.replaceGraphEdgePayloads("topo", &.{.{ .edge_key = payload_edge_keys[0], .payload = "p\x00y" }});
    var d = descriptor();
    d.check = payloadHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
}

const NeighborRows = struct {
    count: usize = 0,
    ordinals: [8]i64 = @splat(0),
    inputs: [8]i64 = @splat(0),
    edges: [8]i64 = @splat(0),
    neighbors: [8]i64 = @splat(0),
    types: [8]u8 = @splat(0),
    fn receive(raw: ?*anyopaque, values: ?[*]const plugin.Value, count: u64) callconv(.c) i32 {
        const self: *NeighborRows = @ptrCast(@alignCast(raw.?));
        if (self.count == self.ordinals.len or count != 6) return 3;
        const row = values.?[0..6];
        if (row[4].kind != plugin.value_text or row[4].bytes_len != 1 or row[5].integer <= 0) return 3;
        self.ordinals[self.count] = row[0].integer;
        self.inputs[self.count] = row[1].integer;
        self.edges[self.count] = row[2].integer;
        self.neighbors[self.count] = row[3].integer;
        self.types[self.count] = row[4].bytes.?[0];
        self.count += 1;
        return 0;
    }
};
// Nodes a, b, c of "hop" and node a of "other".
var neighbor_node_keys: [4]i64 = @splat(0);
fn neighborsHook(base: *const plugin.Host, context: ?*anyopaque) callconv(.c) i32 {
    neighborsExercise(base, context) catch return 1;
    return 0;
}
fn neighborsExercise(base: *const plugin.Host, context: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = context };
    const a = neighbor_node_keys[0];
    const b = neighbor_node_keys[1];
    const c = neighbor_node_keys[2];
    // Duplicates repeat; an unknown key and a key of another graph yield nothing.
    const keys = [_]i64{ a, 999, b, neighbor_node_keys[3], a };
    var rows: NeighborRows = .{};
    var req: data_api.DataRequest = .{ .operation = 10, .name = .from("hop"), .keys = &keys, .key_count = keys.len, .row_limit = 8, .byte_limit = 4096, .row = NeighborRows.receive, .user_data = &rows };
    var page: data_api.DataPage = .{};
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, 5), page.rows);
    try std.testing.expectEqual(@as(u32, 0), page.has_more);
    try std.testing.expectEqualSlices(i64, &.{ 0, 0, 2, 4, 4 }, rows.ordinals[0..5]);
    try std.testing.expectEqualSlices(i64, &.{ a, a, b, a, a }, rows.inputs[0..5]);
    try std.testing.expectEqualSlices(i64, &.{ b, c, c, b, c }, rows.neighbors[0..5]);
    try std.testing.expectEqualStrings("xyxxy", rows.types[0..5]);
    try std.testing.expectEqual(rows.edges[0], rows.edges[3]);

    rows = .{};
    req.edge_type = .from("x");
    try client.read(&req, &page);
    try std.testing.expectEqualSlices(i64, &.{ b, c, b }, rows.neighbors[0..rows.count]);
    rows = .{};
    req.edge_type = .from("absent");
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, 0), page.rows);
    req.edge_type = .{};

    rows = .{};
    req.direction = 1;
    req.keys = &.{ c, a };
    req.key_count = 2;
    try client.read(&req, &page);
    try std.testing.expectEqualSlices(i64, &.{ 0, 0 }, rows.ordinals[0..rows.count]);
    try std.testing.expectEqualSlices(i64, &.{ a, b }, rows.neighbors[0..rows.count]);
    req.direction = 0;

    // A full page stops inside or between keys; the cursor applies to keys[0].
    rows = .{};
    const pair = [_]i64{ a, b };
    req.keys = &pair;
    req.row_limit = 2;
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, 2), page.rows);
    try std.testing.expectEqual(@as(u32, 1), page.has_more);
    try std.testing.expectEqual(rows.edges[1], page.next.key);
    try std.testing.expectEqual(@as(i64, 0), rows.ordinals[1]);
    req.keys = pair[@intCast(rows.ordinals[1])..].ptr;
    req.after = page.next;
    rows = .{};
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, 1), page.rows);
    try std.testing.expectEqual(@as(u32, 0), page.has_more);
    try std.testing.expectEqualSlices(i64, &.{1}, rows.ordinals[0..1]);
    try std.testing.expectEqualSlices(i64, &.{c}, rows.neighbors[0..1]);
    req.after = .{};

    // An exactly full final page reports no further rows.
    req.keys = &.{a};
    req.key_count = 1;
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, 2), page.rows);
    try std.testing.expectEqual(@as(u32, 0), page.has_more);

    req.byte_limit = 6 * @sizeOf(plugin.Value);
    page = .{ .rows = 99, .has_more = 1 };
    try std.testing.expectError(error.Limit, client.read(&req, &page));
    try std.testing.expectEqualDeep(data_api.DataPage{}, page);
    req.byte_limit = 4096;
    req.name = .from("missing");
    try std.testing.expectError(error.HostError, client.read(&req, &page));
}
test "extension_plugin keyed adjacency batches group rows by input key and resume" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.createGraph("hop");
    try db.createGraph("other");
    try db.putGraphNodes(&.{
        .{ .graph_name = "hop", .node_id = "a", .kind = "node" },
        .{ .graph_name = "hop", .node_id = "b", .kind = "node" },
        .{ .graph_name = "hop", .node_id = "c", .kind = "node" },
        .{ .graph_name = "other", .node_id = "a", .kind = "node" },
    });
    try db.putGraphEdges(&.{
        .{ .graph_name = "hop", .from_node_id = "a", .to_node_id = "b", .edge_type = "x" },
        .{ .graph_name = "hop", .from_node_id = "a", .to_node_id = "c", .edge_type = "y" },
        .{ .graph_name = "hop", .from_node_id = "b", .to_node_id = "c", .edge_type = "x" },
        .{ .graph_name = "other", .from_node_id = "a", .to_node_id = "a", .edge_type = "x" },
    });
    var stmt = try db.prepare("select n.node_key from _zova_graph_nodes n join _zova_graphs g on g.graph_key=n.graph_key order by g.name,n.node_id");
    defer stmt.deinit();
    for (&neighbor_node_keys) |*key| {
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        key.* = stmt.columnInt64(0);
    }
    var d = descriptor();
    d.check = neighborsHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
}

test "extension_plugin data bounds cancellation empty and edge batch results" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try populateData(&db);
    var d = descriptor();
    d.check = limitsHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
}

fn allocateData(allocator: std.mem.Allocator, db: *sqlite.Database) !void {
    const ids = [_]data_api.Bytes{ .from("v"), .from("v"), .from("missing") };
    var rows: DataRows = .{ .text_column = 2 };
    const page = try @import("extension_data.zig").read(allocator, db, &.{ .operation = 8, .name = .from("vec"), .ids = &ids, .id_count = ids.len, .row_limit = 3, .byte_limit = 4096, .row = DataRows.receive, .user_data = &rows });
    try std.testing.expectEqual(@as(u64, 3), page.rows);
}
test "extension_plugin data allocation failures finalize all borrowed bindings" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try populateData(&db);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateData, .{&db.sqlite_db});
    try db.exec("vacuum");
}

fn storageAtomicExercise(base: *const plugin.Host, raw: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = raw };
    var rows: DataRows = .{ .text_column = 0 };
    var sql: []const u8 = "insert into _zova_ext_c_test_data values(42)";
    var req: plugin.QueryRequest = .{ .sql = sql.ptr, .sql_len = sql.len, .row_limit = 4, .byte_limit = 4096, .row = DataRows.receive, .user_data = &rows };
    try client.storage(&req);
    sql = "insert or fail into _zova_ext_c_test_data values(43),(42)";
    req.sql = sql.ptr;
    req.sql_len = sql.len;
    try std.testing.expectError(error.HostError, client.storage(&req));
    sql = "insert into _zova_ext_c_test_data values(44),(45) returning id";
    req.sql = sql.ptr;
    req.sql_len = sql.len;
    req.row = cancelRows;
    try std.testing.expectError(error.Canceled, client.storage(&req));
    sql = "select count(*) from main._zova_ext_c_test_data";
    req.sql = sql.ptr;
    req.sql_len = sql.len;
    req.row = DataRows.receive;
    try client.storage(&req);
    try std.testing.expectEqual(@as(i64, 1), rows.first[0]);
}
fn storageAtomicHook(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    storageAtomicExercise(base, raw) catch |err| {
        std.debug.print("storage atomic exercise failed: {t}\n", .{err});
        return 1;
    };
    return 0;
}

fn corruptDataHook(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    corruptDataExercise(base, raw) catch return 1;
    return 0;
}
fn corruptDataExercise(base: *const plugin.Host, raw: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = raw };
    var rows: DataRows = .{};
    const keys = [_]i64{1};
    var req: data_api.DataRequest = .{ .operation = 3, .name = .from("topo"), .keys = &keys, .key_count = 1, .row_limit = 4, .byte_limit = 4096, .row = DataRows.receive, .user_data = &rows };
    var page: data_api.DataPage = .{};
    try std.testing.expectError(error.HostError, client.read(&req, &page));
    try std.testing.expectEqualDeep(data_api.DataPage{}, page);
    req.operation = 7;
    req.name = .from("vec");
    rows = .{ .text_column = 0 };
    try std.testing.expectError(error.HostError, client.read(&req, &page));
    try std.testing.expectEqualDeep(data_api.DataPage{}, page);
}
test "extension_plugin rejects corrupt topology ordering and nonfinite vector bytes" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try populateData(&db);
    try db.exec("update _zova_graph_nodes set created_order=-1 where node_key=1; update _zova_vectors set \"values\"=x'0000807f00000000'");
    var d = descriptor();
    d.check = corruptDataHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
}
fn failedStorageHook(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    if (storageAtomicHook(base, raw) != 0) return 1;
    return 99;
}
test "extension_plugin SQL faults cancel hook failure and caller rollback are atomic" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.exec("create table _zova_ext_c_test_data(id integer unique); create table caller_work(id integer)");
    var d = descriptor();
    d.install = failedStorageHook;
    try db.begin();
    try db.exec("insert into caller_work values(7)");
    try std.testing.expectError(error.ExtensionInvalid, plugin.invoke(d, .install, &db.sqlite_db));
    var check = try db.prepare("select (select count(*) from _zova_ext_c_test_data),(select count(*) from caller_work)");
    try std.testing.expect(try check.step() == .row);
    try std.testing.expectEqual(@as(i64, 0), check.columnInt64(0));
    try std.testing.expectEqual(@as(i64, 1), check.columnInt64(1));
    check.deinit();
    d.install = storageAtomicHook;
    try plugin.invoke(d, .install, &db.sqlite_db);
    try db.rollback();
    check = try db.prepare("select count(*) from _zova_ext_c_test_data");
    defer check.deinit();
    try std.testing.expect(try check.step() == .row);
    try std.testing.expectEqual(@as(i64, 0), check.columnInt64(0));
}

test "extension_plugin source access follows bound stores and read only reopen" {
    const zova = @import("zova.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const main = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/main.zova", .{tmp.sub_path}, 0);
    defer allocator.free(main);
    const graphs = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/graphs.zova", .{tmp.sub_path}, 0);
    defer allocator.free(graphs);
    const vectors = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/vectors.zova", .{tmp.sub_path}, 0);
    defer allocator.free(vectors);
    try zova.createGraphStore(graphs);
    try zova.createVectorStore(vectors);
    var d = descriptor();
    d.check = dataHook;
    {
        var db = try zova.Database.create(main);
        defer db.deinit();
        try db.bindGraphStore(graphs);
        try db.bindVectorStore(vectors);
        try populateData(&db);
        try db.begin();
        try plugin.invoke(d, .check, &db.sqlite_db);
        try db.rollback();
    }
    var db = try zova.Database.openWithOptions(main, .{ .read_only = true });
    defer db.deinit();
    try plugin.invoke(d, .check, &db.sqlite_db);
}

fn readOnlyStorageHook(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    readOnlyStorageExercise(base, raw) catch return 1;
    return 0;
}
fn readOnlyStorageExercise(base: *const plugin.Host, raw: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = raw };
    var rows: DataRows = .{ .text_column = 0 };
    var sql: []const u8 = "select count(*) from main._zova_ext_c_test_data";
    var req: plugin.QueryRequest = .{ .sql = sql.ptr, .sql_len = sql.len, .row_limit = 1, .byte_limit = 1024, .row = DataRows.receive, .user_data = &rows };
    try client.storage(&req);
    try std.testing.expectEqual(@as(i64, 1), rows.first[0]);
    sql = "delete from main._zova_ext_c_test_data";
    req.sql = sql.ptr;
    req.sql_len = sql.len;
    try std.testing.expectError(error.InvalidArgument, client.storage(&req));
}
test "extension_plugin private reads work read only and writes fail without mutation" {
    const zova = @import("zova.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/readonly.zova", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(path);
    var d = descriptor();
    d.version = "1.0.0";
    d.install = installReadOnlyFixture;
    const item = try plugin.validate(&d);
    const registry: extension.Registry = .{ .extensions = &.{item}, .plugins = &.{d} };
    {
        var db = try zova.Database.createWithExtensions(path, registry);
        defer db.deinit();
        try db.installExtension("c_test");
    }
    d.check = readOnlyStorageHook;
    var db = try zova.Database.openWithOptionsAndExtensions(path, .{ .read_only = true }, registry);
    defer db.deinit();
    try plugin.invoke(d, .check, &db.sqlite_db);
}

fn installReadOnlyFixture(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const client = data_api.Client{ .host = base, .connection = raw };
    client.exec("create table _zova_ext_c_test_data(id integer); insert into _zova_ext_c_test_data values(1)") catch return 1;
    return 0;
}

const VectorRows = struct {
    expected: []const u8,
    seen: usize = 0,
    fn receive(raw: ?*anyopaque, values: ?[*]const plugin.Value, count: u64) callconv(.c) i32 {
        const self: *VectorRows = @ptrCast(@alignCast(raw.?));
        if (count != 2 or values.?[1].kind != plugin.value_blob) return 3;
        const value = values.?[1];
        if (!std.mem.eql(u8, self.expected, value.bytes.?[0..@intCast(value.bytes_len)])) return 3;
        self.seen += 1;
        return 0;
    }
};
fn rawVectorHook(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    rawVectorExercise(base, raw) catch return 1;
    return 0;
}
fn rawVectorExercise(base: *const plugin.Host, raw: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = raw };
    for ([_]struct { name: []const u8, encoded: []const u8 }{
        .{ .name = "half", .encoded = &.{ 0, 0x3c, 0, 0xc0 } },
        .{ .name = "signed", .encoded = &.{ 0xff, 2 } },
    }) |case| {
        var rows: VectorRows = .{ .expected = case.encoded };
        var page: data_api.DataPage = .{};
        try client.read(&.{ .operation = 7, .name = .from(case.name), .row_limit = 1, .byte_limit = 1024, .row = VectorRows.receive, .user_data = &rows }, &page);
        try std.testing.expectEqual(@as(usize, 1), rows.seen);
    }
}
test "extension_plugin delivers exact f16 and signed i8 without widening" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.createVectorCollection("half", .{ .dimensions = 2, .metric = .l2, .element_type = .f16 });
    try db.putVector("half", "v", .{ .f16 = &.{ 0x3c00, 0xc000 } });
    try db.createVectorCollection("signed", .{ .dimensions = 2, .metric = .dot, .element_type = .i8 });
    try db.putVector("signed", "v", .{ .i8 = &.{ -1, 2 } });
    var d = descriptor();
    d.check = rawVectorHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
}

var snapshot_writer: ?*@import("zova.zig").Database = null;
fn snapshotHook(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    snapshotExercise(base, raw) catch return 1;
    return 0;
}
fn snapshotExercise(base: *const plugin.Host, raw: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = raw };
    var rows: DataRows = .{};
    var req: data_api.DataRequest = .{ .operation = 1, .name = .from("topo"), .row_limit = 1, .byte_limit = 4096, .row = DataRows.receive, .user_data = &rows };
    var page: data_api.DataPage = .{};
    try client.read(&req, &page);
    try snapshot_writer.?.putGraphNode(.{ .graph_name = "topo", .node_id = "later", .kind = "node" });
    rows = .{};
    req.after = page.next;
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, 0), page.rows);
}

test "extension_plugin autocommit pages hold one WAL snapshot" {
    const zova = @import("zova.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/snapshot.zova", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(path);
    var db = try zova.Database.create(path);
    defer db.deinit();
    try db.exec("pragma journal_mode=wal");
    try db.createGraph("topo");
    try db.putGraphNode(.{ .graph_name = "topo", .node_id = "first", .kind = "node" });
    var writer = try zova.Database.open(path);
    defer writer.deinit();
    snapshot_writer = &writer;
    defer snapshot_writer = null;
    var d = descriptor();
    d.check = snapshotHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
    try std.testing.expect(try db.hasGraphNode("topo", "later"));
}

fn vectorSnapshotHook(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    vectorSnapshotExercise(base, raw) catch return 1;
    return 0;
}
fn vectorSnapshotExercise(base: *const plugin.Host, raw: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = raw };
    var rows: DataRows = .{ .text_column = 0 };
    var req: data_api.DataRequest = .{ .operation = 7, .name = .from("vec"), .row_limit = 1, .byte_limit = 1024, .row = DataRows.receive, .user_data = &rows };
    var page: data_api.DataPage = .{};
    try client.read(&req, &page);
    try std.testing.expectEqualStrings("a", rows.texts[0][0..rows.lengths[0]]);
    try snapshot_writer.?.putVector("vec", "later", .{ .f32 = &.{ 3, 4 } });
    req.after_id = .from("a");
    rows = .{ .text_column = 0 };
    try client.read(&req, &page);
    try std.testing.expectEqual(@as(u64, 0), page.rows);
}
test "extension_plugin main and bound vectors retain caller and autocommit WAL views" {
    const zova = @import("zova.zig");
    for ([_]bool{ false, true }) |bound| {
        for ([_]bool{ false, true }) |caller| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const allocator = std.testing.allocator;
            const main = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/snapshot.zova", .{tmp.sub_path}, 0);
            defer allocator.free(main);
            const store = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/vectors.zova", .{tmp.sub_path}, 0);
            defer allocator.free(store);
            var db = try zova.Database.create(main);
            defer db.deinit();
            try db.exec("pragma journal_mode=wal");
            if (bound) {
                try zova.createVectorStore(store);
                try db.bindVectorStore(store);
                try db.exec("pragma vector_store.journal_mode=wal");
            }
            try db.createVectorCollection("vec", .{ .dimensions = 2, .metric = .l2 });
            try db.putVector("vec", "a", .{ .f32 = &.{ 1, 2 } });
            var writer = try zova.Database.open(main);
            defer writer.deinit();
            snapshot_writer = &writer;
            defer snapshot_writer = null;
            var d = descriptor();
            d.check = vectorSnapshotHook;
            if (caller) try db.begin();
            try plugin.invoke(d, .check, &db.sqlite_db);
            if (caller) {
                // The first hook released its savepoint, not the outer view.
                try plugin.invoke(d, .check, &db.sqlite_db);
                try db.rollback();
            }
            var latest = try db.getVector(allocator, "vec", "later");
            defer latest.deinit(allocator);
            try std.testing.expectEqualSlices(f32, &.{ 3, 4 }, latest.values.f32);
        }
    }
}

fn storageExercise(base: *const plugin.Host, raw: ?*anyopaque) !void {
    const client = data_api.Client{ .host = base, .connection = raw };
    var rows: DataRows = .{ .text_column = 0 };
    const sql = "insert into _zova_ext_c_test_data values(?) returning id";
    const params = [_]plugin.Value{.{ .kind = plugin.value_integer, .integer = 42 }};
    var req: plugin.QueryRequest = .{ .sql = sql, .sql_len = sql.len, .parameters = &params, .parameter_count = 1, .row_limit = 1, .byte_limit = 4096, .row = DataRows.receive, .user_data = &rows };
    try client.storage(&req);
    try std.testing.expectEqual(@as(i64, 42), rows.first[0]);
    for ([_][]const u8{ "select * from _zova_meta", "delete from _zova_graph_nodes", "select * from _zova_ext_other_data", "pragma writable_schema=on", "begin", "attach ':memory:' as evil", "select load_extension('x')", "select * from sqlite_schema" }) |forbidden| {
        req.sql = forbidden.ptr;
        req.sql_len = forbidden.len;
        req.parameters = null;
        req.parameter_count = 0;
        client.storage(&req) catch |err| {
            if (err != error.InvalidArgument) std.debug.print("forbidden SQL returned {t}: {s}\n", .{ err, forbidden });
            try std.testing.expectEqual(error.InvalidArgument, err);
            continue;
        };
        return error.TestExpectedError;
    }
}
fn storageHook(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    storageExercise(base, raw) catch return 1;
    return 0;
}
test "extension_plugin parameterized private storage is owner scoped" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.exec("create table _zova_ext_c_test_data(id integer); create table _zova_ext_other_data(id integer)");
    var d = descriptor();
    d.install = storageHook;
    try plugin.invoke(d, .install, &db.sqlite_db);
}

fn shadowLower(context: ?*sqlite.c.sqlite3_context, _: c_int, _: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    sqlite.c.sqlite3_result_int(context, 123);
}
fn shadowStorageHook(base: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const client = data_api.Client{ .host = base, .connection = raw };
    const sql = "select lower('x')";
    var rows: DataRows = .{ .text_column = 0 };
    client.storage(&.{ .sql = sql, .sql_len = sql.len, .row_limit = 1, .byte_limit = 1024, .row = DataRows.receive, .user_data = &rows }) catch |err| {
        return if (err == error.InvalidArgument and rows.count == 0) 0 else 1;
    };
    return 1;
}
test "extension_plugin storage rejects user functions shadowing allowed builtins" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_create_function_v2(db.sqlite_db.handle, "lower", 1, sqlite.c.SQLITE_UTF8, null, shadowLower, null, null, null));
    var d = descriptor();
    d.check = shadowStorageHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
}

/// Bundle libraries use the platform dynamic-library naming convention so the
/// same bundle shape loads through `std.DynLib` and the Windows module loader.
fn fixtureLibraryName(allocator: std.mem.Allocator, base: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => try std.fmt.allocPrint(allocator, "{s}.dll", .{base}),
        .macos, .ios, .tvos, .watchos, .visionos => try std.fmt.allocPrint(allocator, "lib{s}.dylib", .{base}),
        else => try std.fmt.allocPrint(allocator, "lib{s}.so", .{base}),
    };
}

test "extension_plugin C application upgrade entrypoints validate null requests" {
    const api = @import("c_api_internal.zig");
    try std.testing.expectEqual(api.zova_status.INVALID_ARGUMENT, api.zova_database_open_for_extension_upgrade(null));
    try std.testing.expectEqual(api.zova_status.INVALID_ARGUMENT, api.zova_database_extension_upgrade(null));
}

test "extension_plugin trusted C upgrade through application ABI preserves rows" {
    if (comptime !dynamic.supports_dynamic_loading) return error.SkipZigTest;
    const api = @import("c_api_internal.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;
    for ([_]struct { source: []const u8, code: []const u8, needs_upgrade: bool }{
        .{ .source = options.plugin_upgrade_fixture, .code = "2.0.0", .needs_upgrade = true },
        .{ .source = options.plugin_compatibility_upgrade_fixture, .code = "3.2.0", .needs_upgrade = true },
        .{ .source = options.plugin_compatibility_c_fixture, .code = "3.1.0", .needs_upgrade = false },
        .{ .source = options.plugin_compatibility_cpp_fixture, .code = "3.1.0", .needs_upgrade = false },
        .{ .source = options.plugin_recovery_c_fixture, .code = "1.0.0", .needs_upgrade = false },
        .{ .source = options.plugin_recovery_cpp_fixture, .code = "1.0.0", .needs_upgrade = false },
    }) |target_bundle| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths: [2][:0]u8 = undefined;
        var initialized: usize = 0;
        defer for (paths[0..initialized]) |path| allocator.free(path);
        for ([_][]const u8{ options.plugin_c_fixture, target_bundle.source }, 0..) |source, i| {
            const directory = if (i == 0) "old.zovaext" else "new.zovaext";
            const library_name = try fixtureLibraryName(allocator, "plugin");
            defer allocator.free(library_name);
            try tmp.dir.createDir(io, directory, .default_dir);
            var dir = try tmp.dir.openDir(io, directory, .{});
            defer dir.close(io);
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(16 * 1024 * 1024));
            defer allocator.free(bytes);
            try dir.writeFile(io, .{ .sub_path = library_name, .data = bytes });
            const manifest = try std.fmt.allocPrint(allocator, "{{\"name\":\"c_test\",\"version\":\"{s}\",\"storage_prefix\":\"_zova_ext_c_test_\",\"zova_abi_min\":\"1.0.0\",\"capabilities\":\"\",\"library\":\"{s}\",\"entrypoint\":\"zova_plugin_entry_v1\"}}", .{ if (i == 0) "1.0.0" else target_bundle.code, library_name });
            defer allocator.free(manifest);
            try dir.writeFile(io, .{ .sub_path = "extension.json", .data = manifest });
            paths[i] = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, directory }, 0);
            initialized += 1;
        }
        const trust_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/trusted.json", .{tmp.sub_path}, 0);
        defer allocator.free(trust_path);
        const db_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/app.zova", .{tmp.sub_path}, 0);
        defer allocator.free(db_path);
        // Old fixture is a real persisted database, not a drop/reinstall simulation.
        {
            var bundle = try dynamic.LoadedBundle.load(allocator, paths[0]);
            defer bundle.deinit();
            var db = try @import("zova.zig").Database.createWithExtensions(db_path, bundle.registry());
            defer db.deinit();
            try db.installExtension("c_test");
            try db.exec("INSERT INTO _zova_ext_c_test_data VALUES(42)");
        }
        var trusted = try dynamic.trustBundle(allocator, paths[1], .{ .path = trust_path });
        defer trusted.deinit(allocator);
        const bundle_paths = [_]?[*:0]const u8{paths[1].ptr};
        var handle: ?*api.zova_database = null;
        var req: api.zova_database_open_extensions_request = .{
            .path = db_path.ptr,
            .extension_bundle_paths = &bundle_paths,
            .extension_bundle_count = 1,
            .trust_store_path = trust_path.ptr,
            .out_db = &handle,
            .out_error_message = null,
            .flags = 0,
            .busy_timeout_ms = 0,
        };
        if (target_bundle.needs_upgrade) {
            try std.testing.expectEqual(api.zova_status.EXTENSION_INCOMPATIBLE, api.zova_database_open_with_extensions(&req));
            try std.testing.expect(handle == null);
            req.flags = 1;
            try std.testing.expectEqual(api.zova_status.INVALID_ARGUMENT, api.zova_database_open_for_extension_upgrade(&req));
            req.flags = 0;
            try std.testing.expectEqual(api.zova_status.OK, api.zova_database_open_for_extension_upgrade(&req));
            try std.testing.expectEqual(api.zova_status.OK, api.zova_database_extension_upgrade(&.{ .db = handle, .name = "c_test" }));
            try std.testing.expectEqual(api.zova_status.OK, api.zova_database_close(handle));
            handle = null;
        }
        try std.testing.expectEqual(api.zova_status.OK, api.zova_database_open_with_extensions(&req));
        defer _ = api.zova_database_close(handle);
        if (std.mem.eql(u8, target_bundle.source, options.plugin_recovery_c_fixture) or std.mem.eql(u8, target_bundle.source, options.plugin_recovery_cpp_fixture)) {
            try std.testing.expectEqual(api.zova_status.OK, api.zova_database_extension_rebuild(&.{ .db = handle, .name = "c_test" }));
            var statement: ?*api.zova_statement = null;
            try std.testing.expectEqual(api.zova_status.OK, api.zova_database_prepare(&.{ .db = handle, .sql = "SELECT zova_c_test_cached()", .out_statement = &statement }));
            try std.testing.expectEqual(api.zova_status.MISUSE, api.zova_database_close(handle));
            try std.testing.expectEqual(api.zova_status.OK, api.zova_statement_finalize(statement));
            var read_only_handle: ?*api.zova_database = null;
            var read_only_request = req;
            read_only_request.flags = 1;
            read_only_request.out_db = &read_only_handle;
            try std.testing.expectEqual(api.zova_status.OK, api.zova_database_open_with_extensions(&read_only_request));
            try std.testing.expect(api.zova_database_extension_rebuild(&.{ .db = read_only_handle, .name = "c_test" }) != .OK);
            try std.testing.expectEqual(api.zova_status.OK, api.zova_database_close(read_only_handle));
        }
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();
        var info = try extension.loadInfo(allocator, &raw, "c_test");
        defer info.deinit(allocator);
        try std.testing.expectEqualStrings(if (target_bundle.needs_upgrade) "2.0.0" else "1.0.0", info.version);
        var stmt = try raw.prepare(if (target_bundle.needs_upgrade) "SELECT id, upgraded FROM _zova_ext_c_test_data" else "SELECT id, 9 FROM _zova_ext_c_test_data");
        defer stmt.deinit();
        try std.testing.expect(try stmt.step() == .row);
        try std.testing.expectEqual(@as(i64, 42), stmt.columnInt64(0));
        try std.testing.expectEqual(@as(i64, 9), stmt.columnInt64(1));
    }
}

test "extension_plugin C and C++ bundles load and dispatch through copied registries" {
    if (comptime !dynamic.supports_dynamic_loading) return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;
    for ([_][]const u8{ options.plugin_c_fixture, options.plugin_cpp_fixture, options.plugin_services_c_fixture, options.plugin_services_cpp_fixture, options.plugin_zig_fixture, options.plugin_compatibility_c_fixture, options.plugin_compatibility_cpp_fixture, options.plugin_recovery_c_fixture, options.plugin_recovery_cpp_fixture }) |path| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const library_name = try fixtureLibraryName(allocator, "plugin");
        defer allocator.free(library_name);
        try tmp.dir.createDir(io, "test.zovaext", .default_dir);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        const library_sub_path = try std.fmt.allocPrint(allocator, "test.zovaext/{s}", .{library_name});
        defer allocator.free(library_sub_path);
        try tmp.dir.writeFile(io, .{ .sub_path = library_sub_path, .data = bytes });
        const compatible = std.mem.eql(u8, path, options.plugin_compatibility_c_fixture) or std.mem.eql(u8, path, options.plugin_compatibility_cpp_fixture);
        const manifest = try std.fmt.allocPrint(allocator, "{{\"name\":\"c_test\",\"version\":\"{s}\",\"storage_prefix\":\"_zova_ext_c_test_\",\"zova_abi_min\":\"1.0.0\",\"capabilities\":\"\",\"library\":\"{s}\",\"entrypoint\":\"zova_plugin_entry_v1\"}}\n", .{ if (compatible) "3.1.0" else "1.0.0", library_name });
        defer allocator.free(manifest);
        try tmp.dir.writeFile(io, .{ .sub_path = "test.zovaext/extension.json", .data = manifest });
        const bundle_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/test.zovaext", .{tmp.sub_path});
        defer allocator.free(bundle_path);
        var bundle = try dynamic.LoadedBundle.load(allocator, bundle_path);
        defer bundle.deinit();
        const trust_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/trusted.json", .{tmp.sub_path});
        defer allocator.free(trust_path);
        try std.testing.expectError(error.ExtensionUntrusted, dynamic.DynamicExtensionSet.loadTrustedBundles(allocator, &.{bundle_path}, .{ .path = trust_path }));
        var record = try dynamic.trustBundle(allocator, bundle_path, .{ .path = trust_path });
        defer record.deinit(allocator);
        var set = try dynamic.DynamicExtensionSet.loadTrustedBundles(allocator, &.{bundle_path}, .{ .path = trust_path });
        defer set.deinit();
        var owned = try dynamic.OwnedRegistry.init(allocator, &.{set.registry()});
        defer owned.deinit();
        var db = try sqlite.Database.open(":memory:");
        defer db.deinit();
        try db.exec(extension.extensions_schema_sql);
        try extension.install(&db, owned.registry(), "c_test", null);
        if (std.mem.eql(u8, path, options.plugin_services_c_fixture) or std.mem.eql(u8, path, options.plugin_services_cpp_fixture)) {
            try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db, "SELECT zova_c_test_echo(42)"));
            try std.testing.expectEqual(@as(i64, 10), try scalarValue(&db, "SELECT sum(value) FROM zova_c_test_series(5)"));
            try extension.registerSqlForInstalled(&db, owned.registry());
            try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db, "SELECT zova_c_test_echo(42)"));
        }
        if (std.mem.eql(u8, path, options.plugin_zig_fixture)) {
            try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db, "SELECT zova_c_test_echo(42)"));
        }
        try db.exec("INSERT INTO _zova_ext_c_test_data VALUES(1)");
        if (std.mem.eql(u8, path, options.plugin_recovery_c_fixture) or std.mem.eql(u8, path, options.plugin_recovery_cpp_fixture)) {
            const plan = try extension.salvageInstalled(allocator, &db, null, bundle.registry(), .plan);
            try std.testing.expectEqual(@as(u64, 1), plan.copied_extensions);
            var destination = try sqlite.Database.open(":memory:");
            defer destination.deinit();
            try destination.exec(extension.extensions_schema_sql);
            _ = try extension.salvageInstalled(allocator, &db, &destination, bundle.registry(), .copy);
            try std.testing.expectEqual(@as(i64, 1), try scalarValue(&destination, "SELECT id FROM _zova_ext_c_test_data"));
        }
        try extension.check(&db, bundle.registry(), "c_test");
        try extension.drop(&db, bundle.registry(), "c_test", null);
        try std.testing.expectError(error.SqliteError, db.exec("SELECT * FROM _zova_ext_c_test_data"));
    }
}

fn descriptor() plugin.Descriptor {
    return .{ .struct_size = @sizeOf(plugin.Descriptor), .abi_version = 1, .name = "c_test", .version = "1", .storage_prefix = "_zova_ext_c_test_", .zova_abi_min = "1.0.0" };
}

test "extension_plugin rejects incompatible descriptors before hooks" {
    var d = descriptor();
    _ = try plugin.validate(&d);
    d.struct_size += 16;
    _ = try plugin.validate(&d);
    try std.testing.expectError(error.ExtensionInvalid, plugin.validate(null));
    d.struct_size = 8;
    try std.testing.expectError(error.ExtensionIncompatible, plugin.validate(&d));
    d = descriptor();
    d.abi_version = 2;
    try std.testing.expectError(error.ExtensionIncompatible, plugin.validate(&d));
    d = descriptor();
    d.flags = 1;
    try std.testing.expectError(error.ExtensionIncompatible, plugin.validate(&d));
    d = descriptor();
    d.name = null;
    try std.testing.expectError(error.ExtensionInvalid, plugin.validate(&d));
    d = descriptor();
    d.zova_abi_min = "99.0.0";
    try std.testing.expectError(error.ExtensionIncompatible, plugin.validate(&d));
    d = descriptor();
    d.zova_abi_min = "invalid";
    try std.testing.expectError(error.ExtensionInvalid, plugin.validate(&d));
    d = descriptor();
    d.capabilities = "";
    _ = try plugin.validate(&d);
}

fn outOfMemory(_: *const plugin.Host, _: ?*anyopaque) callconv(.c) i32 {
    return 2;
}

fn badSql(host: *const plugin.Host, db: ?*anyopaque) callconv(.c) i32 {
    const sql = "not SQL";
    return host.exec_sql.?(db, sql.ptr, sql.len);
}

fn lifecycleWrite(host: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const sql = "INSERT INTO _zova_ext_c_test_data VALUES(7)";
    return host.exec_sql.?(raw, sql.ptr, sql.len);
}
fn lifecycleCommit(host: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    return host.exec_sql.?(raw, "COMMIT", 6);
}

fn recoveryInstall(host: *const plugin.Host, raw: ?*anyopaque) callconv(.c) i32 {
    const sql = "CREATE TABLE _zova_ext_c_test_data(value INTEGER); INSERT INTO _zova_ext_c_test_data VALUES(42)";
    return host.exec_sql.?(raw, sql.ptr, sql.len);
}
fn recoveryRebuild(host: *const plugin.Host, raw: ?*anyopaque, version: data_api.Bytes) callconv(.c) i32 {
    if (!std.mem.eql(u8, version.data.?[0..@intCast(version.len)], "1.0.0")) return 3;
    const sql = "DELETE FROM _zova_ext_c_test_data; INSERT INTO _zova_ext_c_test_data VALUES(42)";
    return host.exec_sql.?(raw, sql.ptr, sql.len);
}
fn recoveryFail(host: *const plugin.Host, raw: ?*anyopaque, version: data_api.Bytes) callconv(.c) i32 {
    if (recoveryRebuild(host, raw, version) != 0) return 1;
    return 2;
}
fn recoveryMetadataWrite(host: *const plugin.Host, raw: ?*anyopaque, _: data_api.Bytes) callconv(.c) i32 {
    const sql = "UPDATE _zova_extensions SET version='9.0.0' WHERE name='c_test'";
    return host.exec_sql.?(raw, sql.ptr, sql.len);
}
fn recoveryForeignIndex(host: *const plugin.Host, raw: ?*anyopaque, _: data_api.Bytes) callconv(.c) i32 {
    const sql = "CREATE INDEX _zova_ext_c_test_foreign ON _zova_extensions(version)";
    return host.exec_sql.?(raw, sql.ptr, sql.len);
}
fn recoveryTempTable(host: *const plugin.Host, raw: ?*anyopaque, _: data_api.Bytes) callconv(.c) i32 {
    const sql = "CREATE TEMP TABLE _zova_ext_c_test_temporary(value INTEGER)";
    return host.exec_sql.?(raw, sql.ptr, sql.len);
}
fn recoverySalvage(source_host: *const plugin.Host, source: ?*anyopaque, destination_host: ?*const plugin.Host, destination: ?*anyopaque, req: *const plugin.SalvageRequest, out: *plugin.SalvageResult) callconv(.c) i32 {
    const client = data_api.Client{ .host = source_host, .connection = source };
    var rows: DataRows = .{ .text_column = 0 };
    const sql = "SELECT value FROM _zova_ext_c_test_data";
    client.query(&.{ .sql = sql, .sql_len = sql.len, .row_limit = 2, .byte_limit = 1024, .row = DataRows.receive, .user_data = &rows }) catch return 1;
    if (rows.count != 1 or rows.first[0] != 42) return 1;
    if (req.mode == plugin.salvage_copy) {
        if (destination_host == null) return 3;
        if (recoveryInstall(destination_host.?, destination) != 0) return 1;
        out.installed_in_destination = 1;
    } else if (destination_host != null or destination != null) return 3;
    out.copied_extensions = 1;
    out.copied_private_objects = 1;
    return 0;
}
test "extension_plugin recovery tail rebuilds and salvages atomically without implicit upgrades" {
    var d: plugin.RecoveryDescriptor = .{
        .base = .{ .base = .{ .base = descriptor(), .from_version = null, .upgrade = null }, .data_version = null, .accepted_data_versions = null },
        .rebuild = recoveryRebuild,
        .salvage = recoverySalvage,
    };
    d.base.base.base.version = "1.0.0";
    d.base.base.base.flags = plugin.has_recovery;
    try std.testing.expectError(error.ExtensionIncompatible, plugin.validate(&d.base.base.base));
    d.base.base.base.struct_size = @sizeOf(plugin.RecoveryDescriptor);
    d.base.base.base.install = recoveryInstall;
    const item = try plugin.validate(&d.base.base.base);
    const recovery = (try plugin.recoveryPath(&d.base.base.base)).?;
    const registry: extension.Registry = .{ .extensions = &.{item}, .plugins = &.{d.base.base.base}, .recoveries = &.{recovery} };
    var source = try @import("zova.zig").Database.createMemoryWithExtensions(registry);
    defer source.deinit();
    try source.installExtension("c_test");
    var forbidden_recovery = recovery;
    forbidden_recovery.rebuild = recoveryMetadataWrite;
    const forbidden: extension.Registry = .{ .extensions = &.{item}, .plugins = &.{d.base.base.base}, .recoveries = &.{forbidden_recovery} };
    try std.testing.expectError(error.ExtensionInvalid, extension.rebuild(std.testing.allocator, &source.sqlite_db, forbidden, "c_test", null));
    for ([_]data_api.RebuildHook{ recoveryForeignIndex, recoveryTempTable }) |hook| {
        forbidden_recovery.rebuild = hook;
        const foreign: extension.Registry = .{ .extensions = &.{item}, .plugins = &.{d.base.base.base}, .recoveries = &.{forbidden_recovery} };
        try std.testing.expectError(error.ExtensionInvalid, extension.rebuild(std.testing.allocator, &source.sqlite_db, foreign, "c_test", null));
    }
    var info = try source.extensionInfo(std.testing.allocator, "c_test");
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("1.0.0", info.version);
    try source.exec("DELETE FROM _zova_ext_c_test_data; BEGIN; CREATE TABLE earlier(value INTEGER)");
    var fail = recovery;
    fail.rebuild = recoveryFail;
    const failing: extension.Registry = .{ .extensions = &.{item}, .plugins = &.{d.base.base.base}, .recoveries = &.{fail} };
    try std.testing.expectError(error.OutOfMemory, extension.rebuild(std.testing.allocator, &source.sqlite_db, failing, "c_test", null));
    try std.testing.expectEqual(@as(i64, 0), try scalarValue(&source.sqlite_db, "SELECT count(*) FROM _zova_ext_c_test_data"));
    try source.rebuildExtension("c_test");
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&source.sqlite_db, "SELECT value FROM _zova_ext_c_test_data"));
    try source.rollback();
    try std.testing.expectEqual(@as(i64, 0), try scalarValue(&source.sqlite_db, "SELECT count(*) FROM _zova_ext_c_test_data"));
    try source.rebuildExtension("c_test");
    const plan = try extension.salvageInstalled(std.testing.allocator, &source.sqlite_db, null, registry, .plan);
    try std.testing.expectEqual(@as(u64, 1), plan.copied_extensions);
    var rejected = d.base.base.base;
    rejected.check = outOfMemory;
    const rejected_item = try plugin.validateBase(&rejected);
    const rejected_registry: extension.Registry = .{ .extensions = &.{rejected_item}, .plugins = &.{rejected}, .recoveries = &.{recovery} };
    var rejected_destination = try @import("zova.zig").Database.createMemory();
    defer rejected_destination.deinit();
    try rejected_destination.exec("BEGIN; CREATE TABLE earlier(value INTEGER)");
    try std.testing.expectError(error.OutOfMemory, extension.salvageInstalled(std.testing.allocator, &source.sqlite_db, &rejected_destination.sqlite_db, rejected_registry, .copy));
    try std.testing.expectError(error.SqliteError, rejected_destination.exec("SELECT * FROM _zova_ext_c_test_data"));
    try rejected_destination.exec("INSERT INTO earlier VALUES(1); COMMIT");
    var destination = try @import("zova.zig").Database.createMemoryWithExtensions(registry);
    defer destination.deinit();
    try destination.begin();
    const copied = try extension.salvageInstalled(std.testing.allocator, &source.sqlite_db, &destination.sqlite_db, registry, .copy);
    try std.testing.expect(copied.installed_in_destination);
    try destination.checkExtension("c_test");
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&destination.sqlite_db, "SELECT value FROM _zova_ext_c_test_data"));
    try destination.rollback();
    try std.testing.expectError(error.ExtensionNotFound, destination.extensionInfo(std.testing.allocator, "c_test"));
}

test "extension_plugin same-version rebuild callback generation follows caller rollback" {
    operation_destroys = 0;
    var d: plugin.RecoveryDescriptor = .{ .base = .{ .base = .{ .base = descriptor(), .from_version = null, .upgrade = null }, .data_version = null, .accepted_data_versions = null }, .rebuild = recoveryRebuild, .salvage = null };
    d.base.base.base.struct_size = @sizeOf(plugin.RecoveryDescriptor);
    d.base.base.base.flags = plugin.has_recovery;
    d.base.base.base.version = "1.0.0";
    d.base.base.base.install = recoveryInstall;
    d.base.base.base.register_sql = registerOwned;
    const item = try plugin.validate(&d.base.base.base);
    const recovery = (try plugin.recoveryPath(&d.base.base.base)).?;
    const initial: extension.Registry = .{ .extensions = &.{item}, .plugins = &.{d.base.base.base}, .recoveries = &.{recovery} };
    var db = try @import("zova.zig").Database.createMemoryWithExtensions(initial);
    defer db.deinit();
    try db.installExtension("c_test");
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "SELECT zova_c_test_owned(41)"));
    var next = d.base.base.base;
    next.register_sql = registerOwnedUpgrade;
    const changed: extension.Registry = .{ .extensions = &.{item}, .plugins = &.{next}, .recoveries = &.{recovery} };
    try db.exec("CREATE TEMP TRIGGER block_generation BEFORE UPDATE ON _zova_plugin_generations BEGIN SELECT RAISE(ABORT,'injected'); END");
    try std.testing.expectError(error.Constraint, extension.rebuild(std.testing.allocator, &db.sqlite_db, changed, "c_test", null));
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "SELECT zova_c_test_owned(41)"));
    try db.exec("DROP TRIGGER block_generation");
    try db.begin();
    try extension.rebuild(std.testing.allocator, &db.sqlite_db, changed, "c_test", null);
    try std.testing.expectEqual(@as(i64, 43), try scalarValue(&db.sqlite_db, "SELECT zova_c_test_owned(41)"));
    try db.rollback();
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "SELECT zova_c_test_owned(41)"));
}

fn allocationRecovery(allocator: std.mem.Allocator) !void {
    const item = extension.Extension{ .manifest = .{ .name = "c_test", .version = "1.0.0", .storage_prefix = "_zova_ext_c_test_", .zova_abi_min = "1.0.0" }, .install = extensionNoop, .check = extensionNoop, .drop = extensionNoop };
    const registry: extension.Registry = .{ .extensions = &.{item}, .recoveries = &.{.{ .name = "c_test", .rebuild = recoveryRebuild, .salvage = recoverySalvage }} };
    var source = try @import("zova.zig").Database.createMemoryWithExtensions(registry);
    defer source.deinit();
    // Use host-owned fixture SQL: lifecycle operations themselves use the
    // allocator under test, not a mock database or callback result.
    try source.exec("CREATE TABLE _zova_ext_c_test_data(value INTEGER); INSERT INTO _zova_ext_c_test_data VALUES(7); INSERT INTO _zova_extensions VALUES('c_test','1.0.0','_zova_ext_c_test_','1.0.0','',1,0,'')");
    try source.begin();
    extension.rebuild(allocator, &source.sqlite_db, registry, "c_test", null) catch |err| {
        try std.testing.expectEqual(@as(i64, 7), try scalarValue(&source.sqlite_db, "SELECT value FROM _zova_ext_c_test_data"));
        return err;
    };
    var destination = try @import("zova.zig").Database.createMemory();
    defer destination.deinit();
    try destination.begin();
    try destination.exec("CREATE TABLE earlier(value INTEGER); INSERT INTO earlier VALUES(1)");
    _ = extension.salvageInstalled(allocator, &source.sqlite_db, &destination.sqlite_db, registry, .copy) catch |err| {
        try std.testing.expectEqual(@as(i64, 1), try scalarValue(&destination.sqlite_db, "SELECT value FROM earlier"));
        try std.testing.expectError(error.ExtensionNotFound, destination.extensionInfo(std.testing.allocator, "c_test"));
        return err;
    };
    try destination.rollback();
    try source.rollback();
}
fn extensionNoop(_: *sqlite.Database, _: extension.Manifest) extension.Error!void {}
test "extension_plugin rebuild and salvage allocator failures release owned memory" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRecovery, .{});
}

fn rebuildWithData(host: *const plugin.Host, raw: ?*anyopaque, version: data_api.Bytes) callconv(.c) i32 {
    const client = data_api.Client{ .host = host, .connection = raw };
    var view: data_api.VectorView = .{};
    client.vectorView("vec", &view) catch return 1;
    var page: data_api.DataPage = .{};
    client.read(&.{ .operation = 1, .name = .from("topo"), .row_limit = 16, .byte_limit = 4096, .row = noChangeRows }, &page) catch return 1;
    if (view.revision == 0 or page.rows != 2) return 1;
    return recoveryRebuild(host, raw, version);
}
test "extension_plugin recovery preserves bound data backup restore and read-only initialization" {
    const zova = @import("zova.zig");
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: [5][:0]u8 = undefined;
    var initialized: usize = 0;
    defer for (paths[0..initialized]) |path| allocator.free(path);
    for ([_][]const u8{ "main", "graphs", "vectors", "backup", "restored" }, 0..) |name, i| {
        paths[i] = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/{s}.zova", .{ tmp.sub_path, name }, 0);
        initialized += 1;
    }
    var d: plugin.RecoveryDescriptor = .{ .base = .{ .base = .{ .base = descriptor(), .from_version = null, .upgrade = null }, .data_version = null, .accepted_data_versions = null }, .rebuild = rebuildWithData, .salvage = recoverySalvage };
    d.base.base.base.struct_size = @sizeOf(plugin.RecoveryDescriptor);
    d.base.base.base.flags = plugin.has_recovery | data_api.requires_data;
    d.base.base.base.version = "1.0.0";
    d.base.base.base.install = recoveryInstall;
    d.base.base.base.register_sql = registerOwned;
    const item = try plugin.validate(&d.base.base.base);
    const recovery = (try plugin.recoveryPath(&d.base.base.base)).?;
    const registry: extension.Registry = .{ .extensions = &.{item}, .plugins = &.{d.base.base.base}, .recoveries = &.{recovery} };
    try zova.createGraphStore(paths[1]);
    try zova.createVectorStore(paths[2]);
    {
        var db = try zova.Database.createWithExtensions(paths[0], registry);
        defer db.deinit();
        try db.bindGraphStore(paths[1]);
        try db.bindVectorStore(paths[2]);
        try populateData(&db);
        try db.installExtension("c_test");
        try db.rebuildExtension("c_test");
        try db.backupTo(paths[3], .{});
    }
    try zova.restoreBackupWithExtensions(paths[3], paths[4], .{}, registry);
    var db = try zova.Database.openWithOptionsAndExtensions(paths[4], .{ .read_only = true }, registry);
    defer db.deinit();
    try db.checkExtension("c_test");
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "SELECT zova_c_test_owned(41)"));
    try plugin.invoke(d.base.base.base, .check, &db.sqlite_db);
    try std.testing.expectError(error.ExtensionInvalid, db.rebuildExtension("c_test"));
    try std.testing.expectEqual(@as(i64, 42), try scalarValue(&db.sqlite_db, "SELECT value FROM _zova_ext_c_test_data"));
}
test "extension_plugin check and initialization cannot persist writes or escape transactions" {
    var db = try @import("zova.zig").Database.createMemory();
    defer db.deinit();
    try db.exec("CREATE TABLE _zova_ext_c_test_data(value INTEGER); BEGIN; CREATE TABLE earlier(value INTEGER)");
    var d = descriptor();
    d.check = lifecycleWrite;
    try std.testing.expectError(error.ExtensionInvalid, plugin.invoke(d, .check, &db.sqlite_db));
    try std.testing.expectEqual(@as(i64, 0), try scalarValue(&db.sqlite_db, "SELECT count(*) FROM _zova_ext_c_test_data"));
    d.register_sql = lifecycleWrite;
    try std.testing.expectError(error.ExtensionInvalid, plugin.invoke(d, .register_sql, &db.sqlite_db));
    d.install = lifecycleCommit;
    try std.testing.expectError(error.ExtensionInvalid, plugin.invoke(d, .install, &db.sqlite_db));
    try db.exec("INSERT INTO earlier VALUES(42); ROLLBACK");
    try std.testing.expectError(error.SqliteError, db.exec("SELECT * FROM earlier"));
}

test "extension_plugin host errors and status mapping" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    const host = plugin.legacyHost();
    try std.testing.expectEqual(@as(i32, 3), host.exec_sql.?(null, "SELECT 1", 8));
    try std.testing.expectEqual(@as(i32, 3), host.exec_sql.?(&db, null, 8));
    try std.testing.expectEqual(@as(i32, 3), host.exec_sql.?(&db, "", 0));
    try std.testing.expectEqual(@as(i32, 3), host.exec_sql.?(&db, "x", 1024 * 1024 + 1));
    try std.testing.expectEqual(@as(i32, 3), host.exec_sql.?(&db, "x\x00y", 3));
    var d = descriptor();
    d.check = outOfMemory;
    try std.testing.expectError(error.OutOfMemory, plugin.invoke(d, .check, &db));
    d.check = badSql;
    try std.testing.expectError(error.ExtensionInvalid, plugin.invoke(d, .check, &db));
    try db.exec("SELECT 1");
}

fn allocateRegistry(allocator: std.mem.Allocator) !void {
    var d = descriptor();
    d.flags |= plugin.has_data_compatibility;
    d.struct_size = @sizeOf(plugin.CompatibilityDescriptor);
    const ext = try plugin.validateBase(&d);
    d.flags |= plugin.has_recovery;
    d.struct_size = @sizeOf(plugin.RecoveryDescriptor);
    var owned = try dynamic.OwnedRegistry.init(allocator, &.{.{ .extensions = &.{ext}, .plugins = &.{d}, .compatibilities = &.{.{ .name = "c_test", .data_version = "1.0.0", .accepted_data_versions = "1.0.0" }}, .recoveries = &.{.{ .name = "c_test", .rebuild = recoveryRebuild }} }});
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), owned.registry().plugins.len);
    try std.testing.expectEqual(@as(usize, 1), owned.registry().compatibilities.len);
    try std.testing.expectEqual(@as(usize, 1), owned.registry().recoveries.len);
}

test "extension_plugin registry allocation failure cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateRegistry, .{});
}

test "extension_plugin upgrade tail requires flag size and a forward path" {
    var d: plugin.UpgradeDescriptor = .{ .base = descriptor(), .from_version = "1.0.0", .upgrade = outOfMemory };
    d.base.version = "2.0.0";
    d.base.flags = plugin.has_upgrade;
    try std.testing.expectError(error.ExtensionIncompatible, plugin.validate(&d.base));
    d.base.struct_size = @sizeOf(plugin.UpgradeDescriptor);
    d.base.flags |= plugin.requires_query | plugin.requires_diagnostics;
    _ = try plugin.validate(&d.base);
    const path = (try plugin.upgradePath(&d.base)).?;
    try std.testing.expectEqualStrings("1.0.0", path.from_version);
    d.upgrade = null;
    try std.testing.expectError(error.ExtensionInvalid, plugin.upgradePath(&d.base));
}

test "extension_plugin compatibility tail is explicit size checked and independent of code" {
    var d: plugin.CompatibilityDescriptor = .{ .base = .{ .base = descriptor(), .from_version = null, .upgrade = null }, .data_version = "1.0.0", .accepted_data_versions = "1.0.0,2.0.0" };
    d.base.base.version = "3.1.0";
    d.base.base.flags = plugin.has_data_compatibility;
    try std.testing.expectError(error.ExtensionIncompatible, plugin.validate(&d.base.base));
    d.base.base.struct_size = @sizeOf(plugin.CompatibilityDescriptor);
    const item = try plugin.validate(&d.base.base);
    const compatibility = (try plugin.compatibilityPath(&d.base.base)).?;
    try std.testing.expectEqualStrings("3.1.0", item.manifest.version);
    try std.testing.expectEqualStrings("1.0.0", compatibility.data_version);
    try std.testing.expect((try plugin.upgradePath(&d.base.base)) == null);
    d.base.base.flags |= plugin.has_upgrade;
    d.base.from_version = "0.9.0";
    d.base.upgrade = outOfMemory;
    const path = (try plugin.upgradePath(&d.base.base)).?;
    try std.testing.expectEqualStrings("1.0.0", path.to_version);
    d.accepted_data_versions = "2.0.0";
    try std.testing.expectError(error.ExtensionInvalid, plugin.validate(&d.base.base));
    d.accepted_data_versions = null;
    try std.testing.expectError(error.ExtensionInvalid, plugin.compatibilityPath(&d.base.base));
}

fn failInstall(host: *const plugin.Host, db: ?*anyopaque) callconv(.c) i32 {
    const sql = "create table _zova_ext_c_test_partial(id integer)";
    if (host.exec_sql.?(db, sql.ptr, sql.len) != 0) return 1;
    return 99;
}

test "extension_plugin optional hooks and error rollback preserve caller work" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(extension.extensions_schema_sql);
    var d = descriptor();
    var ext = try plugin.validate(&d);
    const registry = extension.Registry{ .extensions = &.{ext}, .plugins = &.{d} };
    try extension.install(&db, registry, "c_test", null);
    try extension.check(&db, registry, "c_test");
    try extension.drop(&db, registry, "c_test", null);
    try db.exec("begin; create table caller_work(id integer)");
    d.install = failInstall;
    ext = try plugin.validate(&d);
    try std.testing.expectError(error.ExtensionInvalid, extension.install(&db, .{ .extensions = &.{ext}, .plugins = &.{d} }, "c_test", null));
    try db.exec("insert into caller_work values (1)");
    try std.testing.expectError(error.SqliteError, db.exec("select * from _zova_ext_c_test_partial"));
    try db.exec("rollback");
}

fn checkNegotiation(base: *const plugin.Host, context: ?*anyopaque) !void {
    const host: *const plugin.ServiceHost = @ptrCast(base);
    var service: ?*const anyopaque = @ptrFromInt(1);
    try std.testing.expectEqual(plugin.status_unsupported, host.get_service.?(context, 999, 1, 0, &service));
    try std.testing.expect(service == null);
    try std.testing.expectEqual(plugin.status_unsupported, host.get_service.?(context, plugin.service_query, 2, 0, &service));
    try std.testing.expectEqual(plugin.status_unsupported, host.get_service.?(context, plugin.service_query, 1, @sizeOf(plugin.QueryService) + 1, &service));
    try std.testing.expectEqual(@as(i32, 3), host.get_service.?(null, plugin.service_query, 1, 0, &service));
    try std.testing.expectEqual(@as(i32, 0), host.get_service.?(context, plugin.service_query, 1, @sizeOf(plugin.QueryService), &service));
    try std.testing.expect(service != null);
}
fn negotiationHook(host: *const plugin.Host, context: ?*anyopaque) callconv(.c) i32 {
    checkNegotiation(host, context) catch return 1;
    return 0;
}
test "extension_plugin negotiated services preserve the v1 host prefix" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    const host = plugin.serviceHost();
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(plugin.ServiceHost, "base"));
    try std.testing.expectEqual(@as(u32, @sizeOf(plugin.ServiceHost)), host.base.struct_size);
    try plugin.invokeHook(negotiationHook, &db);
    var d = descriptor();
    d.flags = plugin.requires_query;
    _ = try plugin.validate(&d);
    try std.testing.expect((try plugin.upgradePath(&d)) == null);
    d.flags |= @as(u64, 1) << 63;
    try std.testing.expectError(error.ExtensionIncompatible, plugin.validate(&d));
}

const QueryRows = struct {
    count: usize = 0,
    valid: bool = true,
};

fn receiveValues(raw: ?*anyopaque, values: ?[*]const plugin.Value, count: u64) callconv(.c) i32 {
    const rows: *QueryRows = @ptrCast(@alignCast(raw.?));
    rows.count += 1;
    const row = values.?[0..@intCast(count)];
    rows.valid = rows.valid and count == 5 and row[0].kind == plugin.value_integer and row[0].integer == 42 and
        row[1].kind == plugin.value_float and row[1].real == 1.25 and row[2].kind == plugin.value_text and
        std.mem.eql(u8, row[2].bytes.?[0..@intCast(row[2].bytes_len)], "a\x00b") and
        row[3].kind == plugin.value_blob and row[3].bytes_len == 0 and row[4].kind == plugin.value_null;
    return 0;
}

fn receiveCount(raw: ?*anyopaque, _: ?[*]const plugin.Value, _: u64) callconv(.c) i32 {
    const rows: *QueryRows = @ptrCast(@alignCast(raw.?));
    rows.count += 1;
    return 0;
}

test "extension_plugin bounded query binds values and never retains inputs or statements" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    const parameters = [_]plugin.Value{
        .{ .kind = plugin.value_integer, .integer = 42 },
        .{ .kind = plugin.value_float, .real = 1.25 },
        .{ .kind = plugin.value_text, .bytes = "a\x00b", .bytes_len = 3 },
        .{ .kind = plugin.value_blob },
        .{},
    };
    var rows: QueryRows = .{};
    const sql = "SELECT ?, ?, ?, ?, ?";
    const request: plugin.QueryRequest = .{
        .sql = sql,
        .sql_len = sql.len,
        .parameters = &parameters,
        .parameter_count = parameters.len,
        .row_limit = 1,
        .byte_limit = 1024,
        .row = receiveValues,
        .user_data = &rows,
    };
    try plugin.executeQuery(std.testing.allocator, &db, &request);
    try std.testing.expectEqual(@as(usize, 1), rows.count);
    try std.testing.expect(rows.valid);
    try db.exec("VACUUM");
}

test "extension_plugin query rejects writes and incomplete requests before delivering rows" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec("CREATE TABLE data(id INTEGER)");
    var rows: QueryRows = .{};
    const sql = "INSERT INTO data VALUES(1) RETURNING id";
    var request: plugin.QueryRequest = .{ .sql = sql, .sql_len = sql.len, .row_limit = 4, .byte_limit = 1024, .row = receiveCount, .user_data = &rows };
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    const select = "SELECT count(*) FROM data";
    var stmt = try db.prepare(select);
    defer stmt.deinit();
    try std.testing.expect(try stmt.step() == .row);
    try std.testing.expectEqual(@as(i64, 0), stmt.columnInt64(0));
    for ([_][]const u8{ "", "-- comment", "BEGIN", "SELECT 1; SELECT 2" }) |invalid| {
        request.sql = invalid.ptr;
        request.sql_len = invalid.len;
        try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    }
    request.sql = "SELECT ?";
    request.sql_len = 8;
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    try std.testing.expectEqual(@as(usize, 0), rows.count);
}

test "extension_plugin query budgets and cancellation finalize statements" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    var rows: QueryRows = .{};
    const sql = "SELECT 1 UNION ALL SELECT 2";
    var request: plugin.QueryRequest = .{ .sql = sql, .sql_len = sql.len, .row_limit = 1, .byte_limit = 1024, .row = receiveCount, .user_data = &rows };
    try std.testing.expectError(error.PluginLimit, plugin.executeQuery(std.testing.allocator, &db, &request));
    try std.testing.expectEqual(@as(usize, 1), rows.count);
    rows.count = 0;
    request.row_limit = 2;
    request.byte_limit = 1;
    try std.testing.expectError(error.PluginLimit, plugin.executeQuery(std.testing.allocator, &db, &request));
    try std.testing.expectEqual(@as(usize, 0), rows.count);
    try db.exec("VACUUM");
}

fn queryAllocationFailure(allocator: std.mem.Allocator) !void {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    var rows: QueryRows = .{};
    const sql = "SELECT 1";
    try plugin.executeQuery(allocator, &db, &.{ .sql = sql, .sql_len = sql.len, .row_limit = 1, .byte_limit = 1024, .row = receiveCount, .user_data = &rows });
    try db.exec("VACUUM");
}

test "extension_plugin query allocation failure cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, queryAllocationFailure, .{});
}

test "extension_plugin query uses a strict single-statement SQLite wrapper" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    for ([_][:0]const u8{ "", "-- comment", "SELECT 1; SELECT 2", "SELECT 1; invalid" }) |sql| {
        try std.testing.expectError(error.InvalidArgument, db.prepareSingle(sql));
    }
    var stmt = try db.prepareSingle("SELECT 1; -- trailing comment\n /* comment */");
    defer stmt.deinit();
    try std.testing.expect(stmt.isReadOnly());
    try std.testing.expect(try stmt.step() == .row);
}

test "extension_plugin rejected trailing pragma cannot change connection settings during prepare" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec("PRAGMA foreign_keys=OFF");
    try std.testing.expectError(error.InvalidArgument, db.prepareSingle("SELECT 1; PRAGMA foreign_keys=ON"));
    var flag = try db.prepare("PRAGMA foreign_keys");
    defer flag.deinit();
    try std.testing.expect(try flag.step() == .row);
    try std.testing.expectEqual(@as(i64, 0), flag.columnInt64(0));
}

fn cancelRow(_: ?*anyopaque, _: ?[*]const plugin.Value, _: u64) callconv(.c) i32 {
    return plugin.status_canceled;
}

test "extension_plugin query cancellation and malformed values are safely cleaned up" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    const sql = "SELECT ?";
    var parameters = [_]plugin.Value{.{ .kind = plugin.value_integer, .integer = 1 }};
    var request: plugin.QueryRequest = .{ .sql = sql, .sql_len = sql.len, .parameters = &parameters, .parameter_count = 1, .row_limit = 1, .byte_limit = 1024, .row = cancelRow };
    try std.testing.expectError(error.PluginCanceled, plugin.executeQuery(std.testing.allocator, &db, &request));
    parameters[0].reserved = 1;
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    parameters[0] = .{ .kind = plugin.value_text, .bytes_len = 1 };
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    parameters[0] = .{ .kind = plugin.value_text, .bytes = "\xff", .bytes_len = 1 };
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    request.parameters = null;
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    try db.exec("VACUUM");
}

fn diagnosticsHook(host: *const plugin.Host, context: ?*anyopaque) callconv(.c) i32 {
    const extended: *const plugin.ServiceHost = @ptrCast(host);
    var raw: ?*const anyopaque = null;
    if (extended.get_service.?(context, plugin.service_diagnostics, 1, @sizeOf(plugin.DiagnosticsService), &raw) != 0) return 1;
    const service: *const plugin.DiagnosticsService = @ptrCast(@alignCast(raw.?));
    if (host.exec_sql.?(context, "not SQL", 7) != 1) return 1;
    var buffer: [1024]u8 = undefined;
    var written: u64 = 999;
    if (service.copy_sqlite_error.?(null, &buffer, buffer.len, &written) != 3 or written != 0) return 1;
    if (service.copy_sqlite_error.?(context, &buffer, 1, &written) != plugin.status_limit or written != 1) return 1;
    if (service.copy_sqlite_error.?(context, &buffer, buffer.len, &written) != 0 or written == 0) return 1;
    if (std.mem.indexOf(u8, buffer[0..@intCast(written)], "syntax") == null) return 1;
    if (service.copy_sqlite_error.?(context, null, 1, &written) != 3 or written != 0) return 1;
    const client: plugin.Client = .{ .host = host, .connection = context };
    const count = client.copySqliteError(&buffer) catch return 1;
    return if (count != 0) 0 else 1;
}
test "extension_plugin diagnostics copy bounded bytes without ownership transfer" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try plugin.invokeHook(diagnosticsHook, &db);
}

test "extension_plugin query rejects prepare-time PRAGMAs before changing connection state" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec("PRAGMA foreign_keys=OFF");
    const sql = "/* comment */ PRAGMA foreign_keys=ON";
    const request: plugin.QueryRequest = .{ .sql = sql, .sql_len = sql.len, .row_limit = 1, .byte_limit = 1024, .row = cancelRow };
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    var flag = try db.prepare("PRAGMA foreign_keys");
    defer flag.deinit();
    try std.testing.expect(try flag.step() == .row);
    try std.testing.expectEqual(@as(i64, 0), flag.columnInt64(0));
}

test "extension_plugin Zig author helper negotiates safely with old hosts" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    const legacy: plugin.Host = .{};
    const client: plugin.Client = .{ .host = &legacy, .connection = &db };
    try std.testing.expectError(error.Unsupported, client.query(&.{ .sql = "SELECT 1", .sql_len = 8, .row_limit = 1, .byte_limit = 1024, .row = cancelRow }));
}

// This substitutes only the external C host boundary, exercising Client's
// validation of replies from another compatible host implementation.
const TestHost = struct {
    status: i32 = 0,
    reply: enum { valid, missing, short, newer, no_callback } = .valid,
    const valid: plugin.QueryService = .{ .query = runQuery };
    const short: plugin.QueryService = .{ .struct_size = 8, .query = runQuery };
    const newer: plugin.QueryService = .{ .version = 2, .query = runQuery };
    const no_callback: plugin.QueryService = .{};
    const host: plugin.ServiceHost = .{ .get_service = lookup };

    fn lookup(context: ?*anyopaque, _: u32, _: u32, _: u32, output: ?*?*const anyopaque) callconv(.c) i32 {
        const self: *TestHost = @ptrCast(@alignCast(context.?));
        output.?.* = switch (self.reply) {
            .valid => &valid,
            .missing => null,
            .short => &short,
            .newer => &newer,
            .no_callback => &no_callback,
        };
        return 0;
    }
    fn runQuery(context: ?*anyopaque, _: ?*const plugin.QueryRequest) callconv(.c) i32 {
        const self: *TestHost = @ptrCast(@alignCast(context.?));
        return self.status;
    }
    fn client(self: *TestHost) plugin.Client {
        return .{ .host = &host.base, .connection = self };
    }
};

test "extension_plugin Zig client maps all service statuses and rejects unknown statuses" {
    var host: TestHost = .{};
    const request: plugin.QueryRequest = .{ .sql = "SELECT 1", .sql_len = 8, .row_limit = 1, .byte_limit = 1024, .row = cancelRow };
    try host.client().query(&request);
    const cases = [_]struct { status: i32, expected: plugin.Client.Error }{
        .{ .status = 1, .expected = error.HostError },
        .{ .status = 2, .expected = error.OutOfMemory },
        .{ .status = 3, .expected = error.InvalidArgument },
        .{ .status = 4, .expected = error.Unsupported },
        .{ .status = 5, .expected = error.Limit },
        .{ .status = 6, .expected = error.Canceled },
        .{ .status = -1, .expected = error.HostError },
        .{ .status = 999, .expected = error.HostError },
    };
    for (cases) |case| {
        host.status = case.status;
        try std.testing.expectError(case.expected, host.client().query(&request));
    }
}

test "extension_plugin Zig client rejects incomplete negotiated service replies" {
    var host: TestHost = .{ .reply = .missing };
    const request: plugin.QueryRequest = .{ .sql = "SELECT 1", .sql_len = 8, .row_limit = 1, .byte_limit = 1024, .row = cancelRow };
    try std.testing.expectError(error.HostError, host.client().query(&request));
    host.reply = .short;
    try std.testing.expectError(error.Unsupported, host.client().query(&request));
    host.reply = .newer;
    try std.testing.expectError(error.Unsupported, host.client().query(&request));
    host.reply = .no_callback;
    try std.testing.expectError(error.Unsupported, host.client().query(&request));
}

const Reentry = struct { host: *const plugin.Host, context: ?*anyopaque, rejected: bool = false };
fn reentryRow(raw: ?*anyopaque, _: ?[*]const plugin.Value, _: u64) callconv(.c) i32 {
    const state: *Reentry = @ptrCast(@alignCast(raw.?));
    const sql = "CREATE TABLE forbidden(id INTEGER)";
    state.rejected = state.host.exec_sql.?(state.context, sql, sql.len) == 3;
    const extended: *const plugin.ServiceHost = @ptrCast(state.host);
    var service: ?*const anyopaque = @ptrFromInt(1);
    state.rejected = state.rejected and extended.get_service.?(state.context, plugin.service_query, 1, @sizeOf(plugin.QueryService), &service) == 3 and service == null;
    return 0;
}
fn reentryHook(host: *const plugin.Host, context: ?*anyopaque) callconv(.c) i32 {
    const client: plugin.Client = .{ .host = host, .connection = context };
    var state: Reentry = .{ .host = host, .context = context };
    client.query(&.{ .sql = "SELECT 1", .sql_len = 8, .row_limit = 1, .byte_limit = 1024, .row = reentryRow, .user_data = &state }) catch return 1;
    // The temporary guard must be cleared after the query, including lookup.
    const extended: *const plugin.ServiceHost = @ptrCast(host);
    var service: ?*const anyopaque = null;
    if (extended.get_service.?(context, plugin.service_query, 1, @sizeOf(plugin.QueryService), &service) != 0 or service == null) return 1;
    return if (state.rejected) 0 else 1;
}
test "extension_plugin row callbacks cannot reenter the connection" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try plugin.invokeHook(reentryHook, &db);
    try std.testing.expectError(error.SqliteError, db.exec("SELECT * FROM forbidden"));
}

test "extension_plugin query validates request bounds before touching input memory" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    var request: plugin.QueryRequest = .{ .sql = null, .sql_len = 0, .row_limit = 1, .byte_limit = 1024, .row = cancelRow };
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    request.sql = @ptrFromInt(1);
    request.sql_len = 1024 * 1024 + 1;
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    request.sql_len = 1;
    request.row_limit = 4097;
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    request.row_limit = 1;
    request.byte_limit = 1024 * 1024 + 1;
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
    request.byte_limit = 1024;
    request.struct_size = 8;
    try std.testing.expectError(error.InvalidArgument, plugin.executeQuery(std.testing.allocator, &db, &request));
}
