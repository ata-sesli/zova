const std = @import("std");
const ext = @import("extension.zig");
const sqlite = @import("sqlite.zig");
const zova = @import("zova.zig");

fn install(db: *sqlite.Database, _: ext.Manifest) ext.Error!void {
    try db.exec("CREATE TABLE _zova_ext_upgrade_data(value TEXT); INSERT INTO _zova_ext_upgrade_data VALUES('retained')");
}
fn check(db: *sqlite.Database, _: ext.Manifest) ext.Error!void {
    try db.exec("SELECT value, added FROM _zova_ext_upgrade_data");
}
fn noop(_: *sqlite.Database, _: ext.Manifest) ext.Error!void {}
fn dropData(db: *sqlite.Database, _: ext.Manifest) ext.Error!void {
    try db.exec("DROP TABLE _zova_ext_upgrade_data");
}
fn upgrade(db: *sqlite.Database, _: ext.Manifest) ext.Error!void {
    try db.exec("ALTER TABLE _zova_ext_upgrade_data ADD COLUMN added INTEGER DEFAULT 7");
}
fn fail(db: *sqlite.Database, manifest: ext.Manifest) ext.Error!void {
    try upgrade(db, manifest);
    return error.OutOfMemory;
}
fn failSql(db: *sqlite.Database, manifest: ext.Manifest) ext.Error!void {
    try upgrade(db, manifest);
    try db.exec("INSERT INTO missing_table VALUES(1)");
}
fn rejectCore(_: *sqlite.Database) anyerror!void {
    return error.ExtensionInvalid;
}
fn old() ext.Extension {
    return .{ .manifest = .{ .name = "upgrade", .version = "1.0.0", .storage_prefix = "_zova_ext_upgrade_", .zova_abi_min = "1.0.0" }, .install = install, .check = noop, .drop = noop };
}
fn target() ext.Extension {
    var value = old();
    value.manifest.version = "2.0.0";
    value.check = check;
    return value;
}
fn registry(comptime hook: ext.Hook) ext.Registry {
    return comptime .{ .extensions = &.{target()}, .upgrades = &.{.{ .name = "upgrade", .from_version = "1.0.0", .to_version = "2.0.0", .hook = hook }} };
}
fn expectVersion(db: *sqlite.Database, version: []const u8) !void {
    var info = try ext.loadInfo(std.testing.allocator, db, "upgrade");
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(version, info.version);
}

fn compatibleRegistry(comptime data_version: []const u8, comptime accepted: []const u8) ext.Registry {
    return comptime blk: {
        var item = old();
        item.manifest.version = "3.1.0";
        item.drop = dropData;
        break :blk .{ .extensions = &.{item}, .compatibilities = &.{.{ .name = "upgrade", .data_version = data_version, .accepted_data_versions = accepted }} };
    };
}

fn compatibleUpgradeRegistry(comptime hook: ext.Hook) ext.Registry {
    return comptime blk: {
        var item = target();
        item.manifest.version = "3.2.0";
        break :blk .{
            .extensions = &.{item},
            .compatibilities = &.{.{ .name = "upgrade", .data_version = "2.0.0", .accepted_data_versions = "2.0.0" }},
            .upgrades = &.{.{ .name = "upgrade", .from_version = "1.0.0", .to_version = "2.0.0", .hook = hook }},
        };
    };
}

fn compatibleSalvage(context: ext.SalvageContext, manifest: ext.Manifest) ext.Error!ext.SalvageResult {
    if (!std.mem.eql(u8, manifest.version, "3.1.0")) return error.ExtensionInvalid;
    if (context.mode == .plan) return .{ .copied_extensions = 1, .copied_private_objects = 1 };
    const destination = context.destination orelse return error.ExtensionInvalid;
    try destination.exec("CREATE TABLE _zova_ext_upgrade_data(value TEXT)");
    var read = try context.source.prepare("SELECT value FROM _zova_ext_upgrade_data");
    defer read.deinit();
    var write = try destination.prepare("INSERT INTO _zova_ext_upgrade_data VALUES(?)");
    defer write.deinit();
    while (try read.step() == .row) {
        try write.bindText(1, read.columnText(0));
        std.debug.assert(try write.step() == .done);
        try write.reset();
        try write.clearBindings();
    }
    return .{ .copied_extensions = 1, .copied_private_objects = 1, .installed_in_destination = true };
}

test "extension_upgrade compatible salvage preserves source data version and code manifest" {
    var source = try sqlite.Database.open(":memory:");
    defer source.deinit();
    var destination = try sqlite.Database.open(":memory:");
    defer destination.deinit();
    try source.exec(ext.extensions_schema_sql);
    try destination.exec(ext.extensions_schema_sql);
    try ext.install(&source, ext.Registry.init(&.{old()}), "upgrade", null);
    var item = old();
    item.manifest.version = "3.1.0";
    item.salvage = compatibleSalvage;
    const compatible: ext.Registry = .{
        .extensions = &.{item},
        .compatibilities = &.{.{ .name = "upgrade", .data_version = "2.0.0", .accepted_data_versions = "1.0.0,2.0.0" }},
    };
    const planned = try ext.salvageInstalled(std.testing.allocator, &source, null, compatible, .plan);
    try std.testing.expectEqual(@as(u64, 1), planned.copied_extensions);
    const copied = try ext.salvageInstalled(std.testing.allocator, &source, &destination, compatible, .copy);
    try std.testing.expectEqual(@as(u64, 1), copied.copied_extensions);
    try expectVersion(&destination, "1.0.0");
    try ext.check(&destination, compatible, "upgrade");
}

test "extension_upgrade compatibility accepts code-only changes without metadata mutation" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(ext.extensions_schema_sql);
    try ext.install(&db, ext.Registry.init(&.{old()}), "upgrade", null);
    try db.exec("CREATE TRIGGER no_metadata_update BEFORE UPDATE ON _zova_extensions BEGIN SELECT RAISE(ABORT, 'no implicit upgrade'); END");
    try ext.check(&db, compatibleRegistry("1.0.0", "1.0.0"), "upgrade");
    try ext.registerSqlForInstalled(&db, compatibleRegistry("1.0.0", "1.0.0"));
    try expectVersion(&db, "1.0.0");
    try std.testing.expectError(error.ExtensionIncompatible, ext.check(&db, compatibleRegistry("2.0.0", "2.0.0"), "upgrade"));
    try ext.drop(&db, compatibleRegistry("1.0.0", "1.0.0"), "upgrade", null);
}

test "extension_upgrade compatibility installs target data version independently of code" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(ext.extensions_schema_sql);
    try ext.install(&db, compatibleRegistry("1.0.0", "1.0.0,2.0.0"), "upgrade", null);
    try expectVersion(&db, "1.0.0");
    try std.testing.expectError(error.ExtensionInvalid, compatibleRegistry("1.0.0", "2.0.0").validate());
    try std.testing.expectError(error.ExtensionInvalid, compatibleRegistry("1.0.0", "1.0.0,").validate());
}

test "extension_upgrade compatibility keeps data metadata and caller work atomic" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(ext.extensions_schema_sql);
    try ext.install(&db, ext.Registry.init(&.{old()}), "upgrade", null);
    const next = compatibleUpgradeRegistry(upgrade);
    try db.exec("BEGIN; CREATE TABLE earlier(id INTEGER); INSERT INTO earlier VALUES(42)");
    try std.testing.expectError(error.OutOfMemory, ext.upgrade(std.testing.allocator, &db, compatibleUpgradeRegistry(fail), "upgrade", null));
    try expectVersion(&db, "1.0.0");
    try std.testing.expectError(error.SqliteError, db.exec("SELECT added FROM _zova_ext_upgrade_data"));
    try std.testing.expectError(error.ExtensionInvalid, ext.upgrade(std.testing.allocator, &db, next, "upgrade", rejectCore));
    try expectVersion(&db, "1.0.0");
    try db.exec("CREATE TRIGGER block_upgrade BEFORE UPDATE ON _zova_extensions BEGIN SELECT RAISE(ABORT, 'injected'); END");
    try std.testing.expectError(error.Constraint, ext.upgrade(std.testing.allocator, &db, next, "upgrade", null));
    try expectVersion(&db, "1.0.0");
    try db.exec("DROP TRIGGER block_upgrade; COMMIT; BEGIN");
    try ext.upgrade(std.testing.allocator, &db, next, "upgrade", null);
    try expectVersion(&db, "2.0.0");
    try ext.check(&db, next, "upgrade");
    try db.exec("ROLLBACK; SELECT id FROM earlier");
    try expectVersion(&db, "1.0.0");
    try std.testing.expectError(error.SqliteError, db.exec("SELECT added FROM _zova_ext_upgrade_data"));
    try ext.upgrade(std.testing.allocator, &db, next, "upgrade", null);
    try expectVersion(&db, "2.0.0");
    // Older code can be selected only if it explicitly accepts this data.
    try ext.check(&db, compatibleRegistry("1.0.0", "1.0.0,2.0.0"), "upgrade");
    try std.testing.expectError(error.ExtensionIncompatible, ext.upgrade(std.testing.allocator, &db, compatibleRegistry("1.0.0", "1.0.0,2.0.0"), "upgrade", null));
    try std.testing.expectError(error.ExtensionIncompatible, ext.check(&db, ext.Registry.init(&.{old()}), "upgrade"));
}

test "extension_upgrade compatible code survives backup restore and read-only reopen" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/compatible.zova", .{tmp.sub_path}, 0);
    defer allocator.free(path);
    const backup = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/backup.zova", .{tmp.sub_path}, 0);
    defer allocator.free(backup);
    const restored = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/restored.zova", .{tmp.sub_path}, 0);
    defer allocator.free(restored);
    {
        var db = try zova.Database.createWithExtensions(path, ext.Registry.init(&.{old()}));
        defer db.deinit();
        try db.installExtension("upgrade");
    }
    const compatible = compatibleRegistry("1.0.0", "1.0.0");
    {
        var db = try zova.Database.openWithExtensions(path, compatible);
        defer db.deinit();
        try expectVersion(&db.sqlite_db, "1.0.0");
        try db.backupTo(backup, .{});
    }
    try zova.restoreBackupWithExtensions(backup, restored, .{}, compatible);
    var db = try zova.Database.openWithOptionsAndExtensions(restored, .{ .read_only = true }, compatible);
    defer db.deinit();
    try db.checkExtension("upgrade");
    try expectVersion(&db.sqlite_db, "1.0.0");
    try std.testing.expectError(error.ExtensionIncompatible, zova.Database.openWithExtensions(restored, compatibleRegistry("2.0.0", "2.0.0")));
}

test "extension_upgrade preserves data and supports caller rollback" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(ext.extensions_schema_sql);
    try ext.install(&db, ext.Registry.init(&.{old()}), "upgrade", null);
    try std.testing.expectError(error.ExtensionIncompatible, ext.check(&db, registry(upgrade), "upgrade"));
    try db.exec("BEGIN; CREATE TABLE earlier(id INTEGER)");
    try ext.upgrade(std.testing.allocator, &db, registry(upgrade), "upgrade", null);
    try expectVersion(&db, "2.0.0");
    try ext.check(&db, registry(upgrade), "upgrade");
    var stmt = try db.prepare("SELECT value, added FROM _zova_ext_upgrade_data");
    defer stmt.deinit();
    try std.testing.expect(try stmt.step() == .row);
    try std.testing.expectEqualStrings("retained", stmt.columnText(0));
    try std.testing.expectEqual(@as(i64, 7), stmt.columnInt64(1));
    try stmt.reset();
    try db.exec("ROLLBACK");
    try expectVersion(&db, "1.0.0");
    try ext.upgrade(std.testing.allocator, &db, registry(upgrade), "upgrade", null);
    try expectVersion(&db, "2.0.0");
}

test "extension_upgrade failed hook leaves earlier caller work and metadata intact" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(ext.extensions_schema_sql);
    try ext.install(&db, ext.Registry.init(&.{old()}), "upgrade", null);
    try db.exec("BEGIN; CREATE TABLE earlier(id INTEGER)");
    try std.testing.expectError(error.OutOfMemory, ext.upgrade(std.testing.allocator, &db, registry(fail), "upgrade", null));
    try expectVersion(&db, "1.0.0");
    try std.testing.expectError(error.SqliteError, db.exec("SELECT added FROM _zova_ext_upgrade_data"));
    try db.exec("INSERT INTO earlier VALUES(1); COMMIT");
}

fn allocationUpgrade(allocator: std.mem.Allocator) !void {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(ext.extensions_schema_sql);
    try ext.install(&db, ext.Registry.init(&.{old()}), "upgrade", null);
    ext.upgrade(allocator, &db, registry(upgrade), "upgrade", null) catch |err| {
        try expectVersion(&db, "1.0.0");
        try std.testing.expectError(error.SqliteError, db.exec("SELECT added FROM _zova_ext_upgrade_data"));
        return err;
    };
    try expectVersion(&db, "2.0.0");
}

fn allocationCompatibleUpgrade(allocator: std.mem.Allocator) !void {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(ext.extensions_schema_sql);
    try ext.install(&db, ext.Registry.init(&.{old()}), "upgrade", null);
    try db.exec("BEGIN; CREATE TABLE earlier(id INTEGER)");
    ext.upgrade(allocator, &db, compatibleUpgradeRegistry(upgrade), "upgrade", null) catch |err| {
        try expectVersion(&db, "1.0.0");
        try std.testing.expectError(error.SqliteError, db.exec("SELECT added FROM _zova_ext_upgrade_data"));
        try db.exec("INSERT INTO earlier VALUES(1); COMMIT");
        return err;
    };
    try expectVersion(&db, "2.0.0");
    try db.exec("ROLLBACK");
    try expectVersion(&db, "1.0.0");
}

test "extension_upgrade allocation failures roll back and release all allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationUpgrade, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCompatibleUpgrade, .{});
}

test "extension_upgrade SQL validation and metadata-write faults are atomic" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(ext.extensions_schema_sql);
    try ext.install(&db, ext.Registry.init(&.{old()}), "upgrade", null);
    try std.testing.expectError(error.SqliteError, ext.upgrade(std.testing.allocator, &db, registry(failSql), "upgrade", null));
    try expectVersion(&db, "1.0.0");
    try std.testing.expectError(error.ExtensionInvalid, ext.upgrade(std.testing.allocator, &db, registry(upgrade), "upgrade", rejectCore));
    try expectVersion(&db, "1.0.0");
    // A target check failure also rolls back the attempted schema changes.
    try std.testing.expectError(error.SqliteError, ext.upgrade(std.testing.allocator, &db, registry(noop), "upgrade", null));
    try db.exec("CREATE TRIGGER block_upgrade BEFORE UPDATE ON _zova_extensions BEGIN SELECT RAISE(ABORT, 'injected'); END");
    try std.testing.expectError(error.Constraint, ext.upgrade(std.testing.allocator, &db, registry(upgrade), "upgrade", null));
    try expectVersion(&db, "1.0.0");
    try std.testing.expectError(error.SqliteError, db.exec("SELECT added FROM _zova_ext_upgrade_data"));
}

test "extension_upgrade rejects undeclared paths and downgrades" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(ext.extensions_schema_sql);
    try ext.install(&db, ext.Registry.init(&.{old()}), "upgrade", null);
    try std.testing.expectError(error.ExtensionUnavailable, ext.upgrade(std.testing.allocator, &db, .{}, "upgrade", null));
    try std.testing.expectError(error.ExtensionIncompatible, ext.upgrade(std.testing.allocator, &db, ext.Registry.init(&.{target()}), "upgrade", null));
    try ext.upgrade(std.testing.allocator, &db, registry(upgrade), "upgrade", null);
    try std.testing.expectError(error.ExtensionIncompatible, ext.upgrade(std.testing.allocator, &db, registry(upgrade), "upgrade", null));
    const down: ext.Registry = .{ .extensions = &.{old()}, .upgrades = &.{.{ .name = "upgrade", .from_version = "2.0.0", .to_version = "1.0.0", .hook = noop }} };
    try std.testing.expectError(error.ExtensionIncompatible, ext.upgrade(std.testing.allocator, &db, down, "upgrade", null));
    try expectVersion(&db, "2.0.0");
}

test "extension_upgrade validates source ABI and preserves legacy ABI compatibility" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(ext.extensions_schema_sql);
    try ext.install(&db, ext.Registry.init(&.{old()}), "upgrade", null);
    try db.exec("UPDATE _zova_extensions SET zova_abi_min='99.0.0'");
    try std.testing.expectError(error.ExtensionIncompatible, ext.upgrade(std.testing.allocator, &db, registry(upgrade), "upgrade", null));
    try expectVersion(&db, "1.0.0");
    try db.exec("UPDATE _zova_extensions SET zova_abi_min='0.26.0'");
    try ext.upgrade(std.testing.allocator, &db, registry(upgrade), "upgrade", null);
    try expectVersion(&db, "2.0.0");
}

test "extension_upgrade explicit maintenance open backup restore and reopen" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/app.zova", .{tmp.sub_path}, 0);
    defer allocator.free(path);
    const backup = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/backup.zova", .{tmp.sub_path}, 0);
    defer allocator.free(backup);
    const restored = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/restored.zova", .{tmp.sub_path}, 0);
    defer allocator.free(restored);
    {
        var db = try zova.Database.createWithExtensions(path, ext.Registry.init(&.{old()}));
        defer db.deinit();
        try db.installExtension("upgrade");
    }
    try std.testing.expectError(error.ExtensionIncompatible, zova.Database.openWithExtensions(path, registry(upgrade)));
    {
        var db = try zova.Database.openForExtensionUpgradeWithExtensions(path, .{}, registry(upgrade));
        defer db.deinit();
        try db.upgradeExtension("upgrade");
    }
    {
        var db = try zova.Database.openWithExtensions(path, registry(upgrade));
        defer db.deinit();
        try db.backupTo(backup, .{});
    }
    try zova.restoreBackupWithExtensions(backup, restored, .{}, registry(upgrade));
    var db = try zova.Database.openWithExtensions(restored, registry(upgrade));
    defer db.deinit();
    try expectVersion(&db.sqlite_db, "2.0.0");
    try db.checkExtension("upgrade");
    const skipped = try ext.salvageInstalled(allocator, &db.sqlite_db, null, ext.Registry.init(&.{old()}), .plan);
    try std.testing.expectEqual(@as(u64, 1), skipped.skipped_extensions);
}
