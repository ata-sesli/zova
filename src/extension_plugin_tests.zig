const std = @import("std");
const builtin = @import("builtin");
const plugin = @import("extension_plugin.zig");
const extension = @import("extension.zig");
const sqlite = @import("sqlite.zig");
const dynamic = @import("extension_dynamic.zig");
const options = @import("plugin_fixture_options");

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

test "extension_plugin negotiated services preserve the v1 host prefix" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    const host = plugin.serviceHost();
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(plugin.ServiceHost, "base"));
    try std.testing.expectEqual(@as(u32, @sizeOf(plugin.ServiceHost)), host.base.struct_size);
    var service: ?*const anyopaque = @ptrFromInt(1);
    try std.testing.expectEqual(plugin.status_unsupported, host.get_service.?(&db, 999, 1, 0, &service));
    try std.testing.expect(service == null);
    try std.testing.expectEqual(plugin.status_unsupported, host.get_service.?(&db, plugin.service_query, 2, 0, &service));
    try std.testing.expectEqual(plugin.status_unsupported, host.get_service.?(&db, plugin.service_query, 1, @sizeOf(plugin.QueryService) + 1, &service));
    try std.testing.expectEqual(@as(i32, 3), host.get_service.?(null, plugin.service_query, 1, 0, &service));
    try std.testing.expectEqual(@as(i32, 0), host.get_service.?(&db, plugin.service_query, 1, @sizeOf(plugin.QueryService), &service));
    try std.testing.expect(service != null);
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

const Reentry = struct { host: *const plugin.Host, context: ?*anyopaque, rejected: bool = false };
fn reentryRow(raw: ?*anyopaque, _: ?[*]const plugin.Value, _: u64) callconv(.c) i32 {
    const state: *Reentry = @ptrCast(@alignCast(raw.?));
    const sql = "CREATE TABLE forbidden(id INTEGER)";
    state.rejected = state.host.exec_sql.?(state.context, sql, sql.len) == 3;
    return 0;
}
fn reentryHook(host: *const plugin.Host, context: ?*anyopaque) callconv(.c) i32 {
    const client: plugin.Client = .{ .host = host, .connection = context };
    var state: Reentry = .{ .host = host, .context = context };
    client.query(&.{ .sql = "SELECT 1", .sql_len = 8, .row_limit = 1, .byte_limit = 1024, .row = reentryRow, .user_data = &state }) catch return 1;
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
