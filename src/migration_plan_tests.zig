//! Migration dry-run planning tests.
//!
//! `planMigration` must report the same outcome a real migration would reach
//! through its classification, destination and preflight checks, plus the
//! per-member copy sizes and extension needs, while creating and modifying
//! nothing.

const std = @import("std");
const ext = @import("extension.zig");
const sqlite = @import("sqlite.zig");
const zova = @import("zova.zig");
const version = @import("version.zig");

const fixture_dir = "tests/fixtures";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn copyFixtureInto(destination_path: []const u8, fixture_name: []const u8) !void {
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_buffer, "{s}/{s}", .{ fixture_dir, fixture_name });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), source_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = destination_path, .data = bytes });
}

fn fileSha256(path: []const u8) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn fileSize(path: []const u8) !u64 {
    const stat = try std.Io.Dir.cwd().statFile(io(), path, .{});
    return stat.size;
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}

fn entryCount(dir_path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true });
    defer dir.close(io());
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io())) |_| count += 1;
    return count;
}

fn currentFormat() u32 {
    return std.fmt.parseInt(u32, version.format_version, 10) catch unreachable;
}

/// Copy a committed bound set into `set_dir` and point its bindings at the
/// copies, as the bound-set migration tests do.
fn stageBoundSet(set_dir: []const u8, comptime format: []const u8) ![:0]u8 {
    const stem = "bound-main-format-" ++ format;
    inline for (.{ "", ".objects", ".vectors", ".graphs" }) |suffix| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "{s}/" ++ stem ++ suffix ++ ".zova", .{set_dir});
        try copyFixtureInto(path, stem ++ suffix ++ ".zova");
    }
    const main = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/" ++ stem ++ ".zova", .{set_dir}, 0);
    errdefer std.testing.allocator.free(main);
    var raw = try sqlite.Database.open(main);
    defer raw.deinit();
    inline for (.{
        .{ .role = "object_store", .suffix = "objects" },
        .{ .role = "vector_store", .suffix = "vectors" },
        .{ .role = "graph_store", .suffix = "graphs" },
    }) |entry| {
        var update = try raw.prepare("update _zova_bound_stores set path = ?1 where role = ?2");
        defer update.deinit();
        var sibling_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const sibling = try std.fmt.bufPrintSentinel(&sibling_buffer, "{s}/" ++ stem ++ ".{s}.zova", .{ set_dir, entry.suffix }, 0);
        try update.bindText(1, sibling);
        try update.bindText(2, entry.role);
        _ = try update.step();
    }
    return main;
}

test "planMigration reports a single-file plan and creates nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source = try std.fmt.bufPrintSentinel(&source_buffer, "{s}/plan-source.zova", .{dir}, 0);
    try copyFixtureInto(source, "format-9.zova");
    const source_before = try fileSha256(source);
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination = try std.fmt.bufPrintSentinel(&dest_buffer, "{s}/plan-destination.zova", .{dir}, 0);

    var plan = try zova.planMigration(std.testing.allocator, source, destination, .{}, zova.bundledExtensionRegistry());
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 9), plan.source_format);
    try std.testing.expectEqual(currentFormat(), plan.target_format);
    try std.testing.expectEqual(zova.FormatCompatibility.migratable, plan.compatibility);
    try std.testing.expect(plan.verify);
    try std.testing.expectEqual(@as(?zova.Error, null), plan.failure);
    try std.testing.expectEqual(zova.MigrationPreflight.passed, plan.preflight);

    try std.testing.expectEqual(@as(usize, 1), plan.members.len);
    const main = plan.members[0];
    try std.testing.expectEqualStrings("main", main.role);
    try std.testing.expectEqualStrings(source, main.source_path);
    try std.testing.expectEqualStrings(destination, main.destination_path);
    try std.testing.expect(!main.destination_exists);
    const sizes = main.sizes.?;
    try std.testing.expect(sizes.page_size > 0);
    try std.testing.expectEqual(try fileSize(source), sizes.copyBytes());
    try std.testing.expectEqual(sizes.freelist_count * sizes.page_size, sizes.freeBytes());
    try std.testing.expectEqual(try fileSize(source), plan.copyBytes());

    var recovery_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const recovery = try std.fmt.bufPrint(&recovery_buffer, "{s}.migration-recovery", .{destination});
    try std.testing.expectEqualStrings(recovery, plan.recovery_directory);
    try std.testing.expect(!plan.recovery_directory_exists);

    // The format-9 fixture carries the bundled trigram extension.
    try std.testing.expectEqual(@as(usize, 1), plan.extensions.len);
    try std.testing.expectEqualStrings("trgm", plan.extensions[0].name);
    try std.testing.expect(plan.extensions[0].bundled);
    try std.testing.expectEqual(@as(?zova.Error, null), plan.extensions[0].availability);

    // Nothing was created and the source is byte-identical.
    try std.testing.expectEqual(@as(usize, 1), try entryCount(dir));
    try std.testing.expectEqualSlices(u8, &source_before, &(try fileSha256(source)));
}

test "planMigration plans every bound store and flags existing destinations like migrateDatabase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const source = try stageBoundSet(dir, "11");
    defer std.testing.allocator.free(source);
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination = try std.fmt.bufPrintSentinel(&dest_buffer, "{s}/migrated.zova", .{dir}, 0);

    {
        var plan = try zova.planMigration(std.testing.allocator, source, destination, .{}, zova.bundledExtensionRegistry());
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 11), plan.source_format);
        try std.testing.expectEqual(@as(?zova.Error, null), plan.failure);
        try std.testing.expectEqual(zova.MigrationPreflight.passed, plan.preflight);
        try std.testing.expectEqual(@as(usize, 4), plan.members.len);
        var total: u64 = 0;
        inline for (.{ "main", "objects", "vectors", "graphs" }, 0..) |role, index| {
            const member = plan.members[index];
            try std.testing.expectEqualStrings(role, member.role);
            try std.testing.expect(!member.destination_exists);
            try std.testing.expectEqual(try fileSize(member.source_path), member.sizes.?.copyBytes());
            total += member.sizes.?.copyBytes();
        }
        try std.testing.expectEqualStrings(destination, plan.members[0].destination_path);
        var sibling_buffer: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&sibling_buffer, "{s}/migrated.vectors.zova", .{dir}),
            plan.members[2].destination_path,
        );
        try std.testing.expectEqual(total, plan.copyBytes());
    }
    try std.testing.expectEqual(@as(usize, 4), try entryCount(dir));

    // An existing sibling destination fails the plan exactly as it fails a
    // real migration.
    var sibling_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sibling = try std.fmt.bufPrint(&sibling_buffer, "{s}/migrated.vectors.zova", .{dir});
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = sibling, .data = "occupied" });
    {
        var plan = try zova.planMigration(std.testing.allocator, source, destination, .{}, zova.bundledExtensionRegistry());
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?zova.Error, error.DestinationExists), plan.failure);
        try std.testing.expect(plan.members[2].destination_exists);
        try std.testing.expect(!plan.members[0].destination_exists);
    }
    try std.testing.expectError(error.DestinationExists, zova.migrateDatabase(source, destination, .{}));
    try std.Io.Dir.cwd().deleteFile(io(), sibling);

    // So does a leftover recovery directory.
    var recovery_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const recovery = try std.fmt.bufPrint(&recovery_buffer, "{s}.migration-recovery", .{destination});
    try std.Io.Dir.cwd().createDir(io(), recovery, .default_dir);
    {
        var plan = try zova.planMigration(std.testing.allocator, source, destination, .{}, zova.bundledExtensionRegistry());
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?zova.Error, error.DestinationExists), plan.failure);
        try std.testing.expect(plan.recovery_directory_exists);
    }
    try std.testing.expectError(error.DestinationExists, zova.migrateDatabase(source, destination, .{}));
}

test "planMigration runs the same source and bound-store preflight as migrateDatabase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const source = try stageBoundSet(dir, "10");
    defer std.testing.allocator.free(source);
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination = try std.fmt.bufPrintSentinel(&dest_buffer, "{s}/migrated.zova", .{dir}, 0);

    // A binding whose recorded store identity no longer matches the store.
    {
        var raw = try sqlite.Database.open(source);
        defer raw.deinit();
        try raw.exec("update _zova_bound_stores set store_id = printf('%064d', 0) where role = 'graph_store'");
    }
    {
        var plan = try zova.planMigration(std.testing.allocator, source, destination, .{}, zova.bundledExtensionRegistry());
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?zova.Error, error.BoundStoreInvalid), plan.failure);
        try std.testing.expectEqual(zova.MigrationPreflight.failed, plan.preflight);
        try std.testing.expectEqual(@as(usize, 4), plan.members.len);
    }
    try std.testing.expectError(error.BoundStoreInvalid, zova.migrateDatabase(source, destination, .{}));
    try std.testing.expectEqual(@as(usize, 4), try entryCount(dir));

    // A current-format source has no migration path; preflight is skipped.
    var current_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const current = try std.fmt.bufPrintSentinel(&current_buffer, "{s}/current.zova", .{dir}, 0);
    {
        var db = try zova.Database.create(current);
        db.deinit();
    }
    var plan = try zova.planMigration(std.testing.allocator, current, destination, .{}, zova.bundledExtensionRegistry());
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?zova.Error, error.NoMigrationPath), plan.failure);
    try std.testing.expectEqual(zova.FormatCompatibility.current, plan.compatibility);
    try std.testing.expectEqual(zova.MigrationPreflight.skipped, plan.preflight);
}

fn installPlanTest(db: *sqlite.Database, _: ext.Manifest) ext.Error!void {
    try db.exec("CREATE TABLE _zova_ext_plan_test_data(value INTEGER)");
}
fn checkPlanTest(db: *sqlite.Database, _: ext.Manifest) ext.Error!void {
    try db.exec("SELECT value FROM _zova_ext_plan_test_data");
}
fn noopPlanTest(_: *sqlite.Database, _: ext.Manifest) ext.Error!void {}

const plan_test_extensions = [_]ext.Extension{.{
    .manifest = .{ .name = "plan_test", .version = "1.0.0", .storage_prefix = "_zova_ext_plan_test_", .zova_abi_min = "1.0.0" },
    .install = installPlanTest,
    .check = checkPlanTest,
    .drop = noopPlanTest,
}};

test "planMigration reports installed extensions that need code for verification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source = try std.fmt.bufPrintSentinel(&source_buffer, "{s}/ext-source.zova", .{dir}, 0);
    try copyFixtureInto(source, "format-11.zova");
    const plan_test_registry = ext.Registry.init(&plan_test_extensions);
    {
        // Install into the genuine format-11 file the way a 1.1.0 host would have.
        var raw = try sqlite.Database.open(source);
        defer raw.deinit();
        try ext.install(&raw, plan_test_registry, "plan_test", null);
    }
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination = try std.fmt.bufPrintSentinel(&dest_buffer, "{s}/ext-destination.zova", .{dir}, 0);

    {
        var plan = try zova.planMigration(std.testing.allocator, source, destination, .{}, zova.bundledExtensionRegistry());
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?zova.Error, error.ExtensionUnavailable), plan.failure);
        try std.testing.expectEqual(zova.MigrationPreflight.passed, plan.preflight);
        var found = false;
        for (plan.extensions) |item| {
            if (!std.mem.eql(u8, item.name, "plan_test")) continue;
            found = true;
            try std.testing.expect(!item.bundled);
            try std.testing.expectEqualStrings("1.0.0", item.version);
            try std.testing.expectEqual(@as(?zova.Error, error.ExtensionUnavailable), item.availability);
        }
        try std.testing.expect(found);
    }
    try std.testing.expectError(error.ExtensionUnavailable, zova.migrateDatabase(source, destination, .{}));

    // Without verification the real migration never loads extension code.
    {
        var plan = try zova.planMigration(std.testing.allocator, source, destination, .{ .verify = false }, zova.bundledExtensionRegistry());
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(?zova.Error, null), plan.failure);
    }

    // Supplying the extension's code satisfies the plan.
    var owned = try zova.DynamicExtensionOwnedRegistry.init(std.testing.allocator, &.{ zova.bundledExtensionRegistry(), plan_test_registry });
    defer owned.deinit();
    var plan = try zova.planMigration(std.testing.allocator, source, destination, .{}, owned.registry());
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?zova.Error, null), plan.failure);
    for (plan.extensions) |item| try std.testing.expectEqual(@as(?zova.Error, null), item.availability);
    try std.testing.expectEqual(@as(usize, 1), try entryCount(dir));
}

fn planBoundSetForAllocationFailure(allocator: std.mem.Allocator, source: [:0]const u8, destination: [:0]const u8) !void {
    var plan = try zova.planMigration(allocator, source, destination, .{}, zova.bundledExtensionRegistry());
    plan.deinit(allocator);
}

test "planMigration releases everything on every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    const source = try stageBoundSet(dir, "11");
    defer std.testing.allocator.free(source);
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const destination = try std.fmt.bufPrintSentinel(&dest_buffer, "{s}/migrated.zova", .{dir}, 0);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, planBoundSetForAllocationFailure, .{ source, destination });
    try std.testing.expectEqual(@as(usize, 4), try entryCount(dir));
}
