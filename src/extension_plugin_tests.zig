const std = @import("std");
const plugin = @import("extension_plugin.zig");
const extension = @import("extension.zig");
const sqlite = @import("sqlite.zig");
const dynamic = @import("extension_dynamic.zig");
const options = @import("plugin_fixture_options");

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
            \\{"name":"c_test","version":"1","storage_prefix":"_zova_ext_c_test_","zova_abi_min":"1.0.0","capabilities":"","library":"plugin","entrypoint":"zova_plugin_entry_v1"}
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
