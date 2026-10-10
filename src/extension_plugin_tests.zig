const std = @import("std");
const builtin = @import("builtin");
const plugin = @import("extension_plugin.zig");
const extension = @import("extension.zig");
const sqlite = @import("sqlite.zig");
const dynamic = @import("extension_dynamic.zig");
const options = @import("plugin_fixture_options");

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
    d.check = failedStorageHook;
    try db.begin();
    try db.exec("insert into caller_work values(7)");
    try std.testing.expectError(error.ExtensionInvalid, plugin.invoke(d, .check, &db.sqlite_db));
    var check = try db.prepare("select (select count(*) from _zova_ext_c_test_data),(select count(*) from caller_work)");
    try std.testing.expect(try check.step() == .row);
    try std.testing.expectEqual(@as(i64, 0), check.columnInt64(0));
    try std.testing.expectEqual(@as(i64, 1), check.columnInt64(1));
    check.deinit();
    d.check = storageAtomicHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
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
    try std.testing.expectError(error.HostError, client.storage(&req));
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
    d.check = storageHook;
    try plugin.invoke(d, .check, &db.sqlite_db);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: [2][:0]u8 = undefined;
    var initialized: usize = 0;
    defer for (paths[0..initialized]) |path| allocator.free(path);
    for ([_][]const u8{ options.plugin_c_fixture, options.plugin_upgrade_fixture }, 0..) |source, i| {
        const directory = if (i == 0) "old.zovaext" else "new.zovaext";
        const library_name = try fixtureLibraryName(allocator, "plugin");
        defer allocator.free(library_name);
        try tmp.dir.createDir(io, directory, .default_dir);
        var dir = try tmp.dir.openDir(io, directory, .{});
        defer dir.close(io);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        try dir.writeFile(io, .{ .sub_path = library_name, .data = bytes });
        const manifest = try std.fmt.allocPrint(allocator, "{{\"name\":\"c_test\",\"version\":\"{s}\",\"storage_prefix\":\"_zova_ext_c_test_\",\"zova_abi_min\":\"1.0.0\",\"capabilities\":\"\",\"library\":\"{s}\",\"entrypoint\":\"zova_plugin_entry_v1\"}}", .{ if (i == 0) "1.0.0" else "2.0.0", library_name });
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
    try std.testing.expectEqual(api.zova_status.EXTENSION_INCOMPATIBLE, api.zova_database_open_with_extensions(&req));
    try std.testing.expect(handle == null);
    req.flags = 1;
    try std.testing.expectEqual(api.zova_status.INVALID_ARGUMENT, api.zova_database_open_for_extension_upgrade(&req));
    req.flags = 0;
    try std.testing.expectEqual(api.zova_status.OK, api.zova_database_open_for_extension_upgrade(&req));
    try std.testing.expectEqual(api.zova_status.OK, api.zova_database_extension_upgrade(&.{ .db = handle, .name = "c_test" }));
    try std.testing.expectEqual(api.zova_status.OK, api.zova_database_close(handle));
    handle = null;
    try std.testing.expectEqual(api.zova_status.OK, api.zova_database_open_with_extensions(&req));
    defer _ = api.zova_database_close(handle);
    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();
    var stmt = try raw.prepare("SELECT id, upgraded FROM _zova_ext_c_test_data");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step() == .row);
    try std.testing.expectEqual(@as(i64, 42), stmt.columnInt64(0));
    try std.testing.expectEqual(@as(i64, 9), stmt.columnInt64(1));
}

test "extension_plugin C and C++ bundles load and dispatch through copied registries" {
    if (comptime !dynamic.supports_dynamic_loading) return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;
    for ([_][]const u8{ options.plugin_c_fixture, options.plugin_cpp_fixture, options.plugin_services_c_fixture, options.plugin_services_cpp_fixture, options.plugin_zig_fixture }) |path| {
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
        const manifest = try std.fmt.allocPrint(allocator, "{{\"name\":\"c_test\",\"version\":\"1.0.0\",\"storage_prefix\":\"_zova_ext_c_test_\",\"zova_abi_min\":\"1.0.0\",\"capabilities\":\"\",\"library\":\"{s}\",\"entrypoint\":\"zova_plugin_entry_v1\"}}\n", .{library_name});
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
        try db.exec("INSERT INTO _zova_ext_c_test_data VALUES(1)");
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
    const d = descriptor();
    const ext = try plugin.validate(&d);
    var owned = try dynamic.OwnedRegistry.init(allocator, &.{.{ .extensions = &.{ext}, .plugins = &.{d} }});
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), owned.registry().plugins.len);
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
