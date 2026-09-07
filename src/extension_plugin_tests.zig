const std = @import("std");
const plugin = @import("extension_plugin.zig");
const extension = @import("extension.zig");
const sqlite = @import("sqlite.zig");
const dynamic = @import("extension_dynamic.zig");
const options = @import("plugin_fixture_options");

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
        try tmp.dir.createDir(io, directory, .default_dir);
        var dir = try tmp.dir.openDir(io, directory, .{});
        defer dir.close(io);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        try dir.writeFile(io, .{ .sub_path = "plugin", .data = bytes });
        const manifest = try std.fmt.allocPrint(allocator, "{{\"name\":\"c_test\",\"version\":\"{s}\",\"storage_prefix\":\"_zova_ext_c_test_\",\"zova_abi_min\":\"1.0.0\",\"capabilities\":\"\",\"library\":\"plugin\",\"entrypoint\":\"zova_plugin_entry_v1\"}}", .{if (i == 0) "1.0.0" else "2.0.0"});
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
    for ([_][]const u8{ options.plugin_c_fixture, options.plugin_cpp_fixture }) |path| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(io, "test.zovaext", .default_dir);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = "test.zovaext/plugin", .data = bytes });
        try tmp.dir.writeFile(io, .{ .sub_path = "test.zovaext/extension.json", .data =
            \\{"name":"c_test","version":"1.0.0","storage_prefix":"_zova_ext_c_test_","zova_abi_min":"1.0.0","capabilities":"","library":"plugin","entrypoint":"zova_plugin_entry_v1"}
        });
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
    const host: plugin.Host = .{};
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
