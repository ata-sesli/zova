//! Storage-format classification and non-mutating open behavior tests.
//!
//! These tests define the contract established by the storage-format migration
//! epic: format 9 is migratable, formats below the minimum migratable format
//! are unsupported legacy, formats above the current format are unsupported
//! future, malformed inputs are rejected, and every open attempt leaves the
//! source byte-identical. They run in the default test suite.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const version = @import("version.zig");
const zova = @import("zova.zig");

const Database = zova.Database;

const fixture_dir = "tests/fixtures";

const format_9_main_fixtures = [_][]const u8{
    "empty-main-format-9.zova",
    "format-9.zova",
    "bound-main-format-9.zova",
};

const format_9_store_fixtures = [_][]const u8{
    "bound-main-format-9.objects.zova",
    "bound-main-format-9.vectors.zova",
    "bound-main-format-9.graphs.zova",
    "empty-vector-store-format-9.zova",
    "empty-graph-store-format-9.zova",
};

const format_10_main_fixtures = [_][]const u8{
    "empty-main-format-10.zova",
    "format-10.zova",
    "bound-main-format-10.zova",
};

const format_10_store_fixtures = [_][]const u8{
    "bound-main-format-10.objects.zova",
    "bound-main-format-10.vectors.zova",
    "bound-main-format-10.graphs.zova",
    "empty-vector-store-format-10.zova",
    "empty-graph-store-format-10.zova",
};

const legacy_fixtures = [_][]const u8{
    "empty-format-7.zova",
    "format-8.zova",
    "empty-vector-store-format-7.zova",
    "empty-graph-store-format-7.zova",
    "empty-vector-store-format-8.zova",
    "empty-graph-store-format-8.zova",
};

/// Every retained fixture, and therefore every entry the pinned manifest must
/// contain.
const all_declared_fixtures = format_9_main_fixtures ++ format_9_store_fixtures ++ format_10_main_fixtures ++ format_10_store_fixtures ++ legacy_fixtures;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn fixturePath(buffer: []u8, name: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ fixture_dir, name });
}

fn fileSha256(path: []const u8) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn expectManifestHash(name: []const u8, expected_hex: []const u8) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try fixturePath(&path_buffer, name);

    const actual = try fileSha256(path);
    var actual_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&actual_hex, "{x}", .{actual}) catch unreachable;

    if (!std.mem.eql(u8, &actual_hex, expected_hex)) {
        std.debug.print("fixture hash mismatch for {s}\nexpected: {s}\nactual:   {s}\n", .{ name, expected_hex, actual_hex });
        return error.TestUnexpectedResult;
    }
}

test "fixture manifest matches recorded hashes and declared fixtures" {
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io(),
        fixture_dir ++ "/fixtures.sha256",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(manifest_bytes);

    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const hash_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return error.TestUnexpectedResult;
        const expected_hex = trimmed[0..hash_end];
        const remainder = std.mem.trim(u8, trimmed[hash_end..], " ");
        const name = if (std.mem.startsWith(u8, remainder, "*")) remainder[1..] else remainder;

        // Every pinned fixture must also be declared above, so a fixture added
        // to tests/fixtures/ cannot silently escape the classification tests.
        var declared = false;
        for (all_declared_fixtures) |declared_name| {
            if (std.mem.eql(u8, declared_name, name)) declared = true;
        }
        if (!declared) {
            std.debug.print("fixture {s} is pinned but not declared\n", .{name});
            return error.TestUnexpectedResult;
        }

        try expectManifestHash(name, expected_hex);
        checked += 1;
    }

    try std.testing.expectEqual(all_declared_fixtures.len, checked);
}

fn copyFixture(tmp_sub_path: []const u8, index: usize, name: []const u8) ![:0]const u8 {
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try fixturePath(&source_buffer, name);

    var copy_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const copy_path = try std.fmt.bufPrintZ(&copy_buffer, ".zig-cache/tmp/{s}/migration-red-{d}-{s}", .{ tmp_sub_path, index, name });

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), source_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);

    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = copy_path, .data = bytes });
    return try std.testing.allocator.dupeZ(u8, copy_path);
}

/// Assert that an open attempt fails with `expected_error` and never mutates
/// the source database bytes.
fn expectRejectedWithoutMutation(
    tmp_sub_path: []const u8,
    index: usize,
    fixture_name: []const u8,
    expected_error: anyerror,
) !void {
    const copy_path = try copyFixture(tmp_sub_path, index, fixture_name);
    defer std.testing.allocator.free(copy_path);

    const before = try fileSha256(copy_path);
    try std.testing.expectError(expected_error, Database.open(copy_path));
    const after = try fileSha256(copy_path);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "open classifies format-9 main databases as migratable without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (format_9_main_fixtures, 0..) |name, index| {
        try expectRejectedWithoutMutation(tmp.sub_path[0..], index, name, error.MigrationRequired);
    }
}

test "open classifies format-9 store files passed as main databases as migratable without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (format_9_store_fixtures, 0..) |name, index| {
        try expectRejectedWithoutMutation(tmp.sub_path[0..], index, name, error.MigrationRequired);
    }
}

test "open classifies pre-migratable formats as unsupported legacy without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (legacy_fixtures, 0..) |name, index| {
        try expectRejectedWithoutMutation(tmp.sub_path[0..], index, name, error.UnsupportedLegacyFormat);
    }
}

fn writeSyntheticFormatDatabase(
    tmp_sub_path: []const u8,
    file_name: []const u8,
    version_row: ?[]const u8,
    magic_row: []const u8,
) ![:0]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp_sub_path, file_name });
    const owned_path = try std.testing.allocator.dupeZ(u8, db_path);

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try raw.exec("create table _zova_meta (key text primary key, value text not null)");
        var insert = try raw.prepare("insert into _zova_meta (key, value) values (?1, ?2)");
        defer insert.deinit();

        try insert.bindText(1, "magic");
        try insert.bindText(2, magic_row);
        _ = try insert.step();

        if (version_row) |version_value| {
            try insert.reset();
            try insert.bindText(1, "format_version");
            try insert.bindText(2, version_value);
            _ = try insert.step();
        }
    }

    return owned_path;
}

test "open classifies future format versions as unsupported future without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const future_versions = [_][]const u8{ "12", "13", "999" };
    for (future_versions, 0..) |version_value, index| {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&path_buffer, "future-{d}.zova", .{index});

        const db_path = try writeSyntheticFormatDatabase(tmp.sub_path[0..], file_name, version_value, "zova");
        defer std.testing.allocator.free(db_path);

        const before = try fileSha256(db_path);
        try std.testing.expectError(error.UnsupportedFutureFormat, Database.open(db_path));
        const after = try fileSha256(db_path);
        try std.testing.expectEqualSlices(u8, &before, &after);
    }
}

test "open rejects malformed format versions without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const malformed_versions = [_][]const u8{ "", "ten", "Ten", "9x", "x9", "+9", "-1", " 10", "10 ", "4294967296", "0x9" };
    for (malformed_versions, 0..) |version_value, index| {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&path_buffer, "malformed-{d}.zova", .{index});

        const db_path = try writeSyntheticFormatDatabase(tmp.sub_path[0..], file_name, version_value, "zova");
        defer std.testing.allocator.free(db_path);

        const before = try fileSha256(db_path);
        try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
        const after = try fileSha256(db_path);
        try std.testing.expectEqualSlices(u8, &before, &after);
    }
}

test "open rejects missing metadata without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Missing _zova_meta table entirely.
    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/no-meta-table.zova", .{tmp.sub_path});

        {
            var raw = try sqlite.Database.open(db_path);
            defer raw.deinit();
            try raw.exec("create table user_data (id integer primary key)");
        }

        const before = try fileSha256(db_path);
        try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
        const after = try fileSha256(db_path);
        try std.testing.expectEqualSlices(u8, &before, &after);
    }

    // Missing format_version row.
    {
        const db_path = try writeSyntheticFormatDatabase(tmp.sub_path[0..], "no-version-row.zova", null, "zova");
        defer std.testing.allocator.free(db_path);

        const before = try fileSha256(db_path);
        try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
        const after = try fileSha256(db_path);
        try std.testing.expectEqualSlices(u8, &before, &after);
    }
}

test "open rejects non-zova inputs without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Text file wearing a .zova extension.
    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/not-a-database.zova", .{tmp.sub_path});
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = file_path, .data = "definitely not a sqlite database\n" });

        const before = try fileSha256(file_path);
        try std.testing.expectError(error.NotZovaDatabase, Database.open(file_path));
        const after = try fileSha256(file_path);
        try std.testing.expectEqualSlices(u8, &before, &after);
    }

    // Plain SQLite database without Zova identity.
    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/plain-sqlite.zova", .{tmp.sub_path});

        {
            var raw = try sqlite.Database.open(db_path);
            defer raw.deinit();
            try raw.exec("create table user_data (id integer primary key)");
        }

        const before = try fileSha256(db_path);
        try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
        const after = try fileSha256(db_path);
        try std.testing.expectEqualSlices(u8, &before, &after);
    }
}

fn expectProbeInfo(
    tmp_sub_path: []const u8,
    index: usize,
    fixture_name: []const u8,
    expected_compatibility: zova.FormatCompatibility,
) !void {
    const copy_path = try copyFixture(tmp_sub_path, index, fixture_name);
    defer std.testing.allocator.free(copy_path);

    const before = try fileSha256(copy_path);
    const info = try zova.probeDatabaseFormat(copy_path);
    const after = try fileSha256(copy_path);

    try std.testing.expectEqual(@as(u32, 9), info.format_version);
    try std.testing.expectEqual(expected_compatibility, info.compatibility);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "probe reports migratable format information for every format-9 fixture without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (format_9_main_fixtures, 0..) |name, index| {
        try expectProbeInfo(tmp.sub_path[0..], index, name, .migratable);
    }
    inline for (format_9_store_fixtures, 0..) |name, index| {
        try expectProbeInfo(tmp.sub_path[0..], format_9_main_fixtures.len + index, name, .migratable);
    }
}

test "probe and open agree on classification for synthetic databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A genuinely created database probes as current and opens.
    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/probe-current.zova", .{tmp.sub_path});
        {
            var db = try Database.create(db_path);
            db.deinit();
        }

        const expected_current = try std.fmt.parseInt(u32, version.format_version, 10);
        const info = try zova.probeDatabaseFormat(db_path);
        try std.testing.expectEqual(expected_current, info.format_version);
        try std.testing.expectEqual(zova.FormatCompatibility.current, info.compatibility);

        var reopened = try Database.open(db_path);
        reopened.deinit();
    }

    const AgreementCase = struct {
        version_value: []const u8,
        compatibility: zova.FormatCompatibility,
        open_error: anyerror,
    };

    const cases = [_]AgreementCase{
        .{ .version_value = "9", .compatibility = .migratable, .open_error = error.MigrationRequired },
        .{ .version_value = "8", .compatibility = .unsupported_legacy, .open_error = error.UnsupportedLegacyFormat },
        .{ .version_value = "2", .compatibility = .unsupported_legacy, .open_error = error.UnsupportedLegacyFormat },
        .{ .version_value = "12", .compatibility = .unsupported_future, .open_error = error.UnsupportedFutureFormat },
    };

    for (cases, 0..) |case, index| {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&path_buffer, "probe-agree-{d}.zova", .{index});

        const db_path = try writeSyntheticFormatDatabase(tmp.sub_path[0..], file_name, case.version_value, "zova");
        defer std.testing.allocator.free(db_path);

        const info = try zova.probeDatabaseFormat(db_path);
        try std.testing.expectEqual(case.compatibility, info.compatibility);
        try std.testing.expectError(case.open_error, Database.open(db_path));
    }

    // Malformed versions reject both probe and open identically.
    const malformed_versions = [_][]const u8{ "", "ten", "9x", "+9", "-1", " 10", "4294967296" };
    for (malformed_versions, 0..) |version_value, index| {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&path_buffer, "probe-malformed-{d}.zova", .{index});

        const db_path = try writeSyntheticFormatDatabase(tmp.sub_path[0..], file_name, version_value, "zova");
        defer std.testing.allocator.free(db_path);

        try std.testing.expectError(error.NotZovaDatabase, zova.probeDatabaseFormat(db_path));
        try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
    }
}

test "probe rejects non-zova inputs without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Text file wearing a .zova extension.
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/not-a-database-probe.zova", .{tmp.sub_path});
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = file_path, .data = "definitely not a sqlite database\n" });

    const before = try fileSha256(file_path);
    try std.testing.expectError(error.NotZovaDatabase, zova.probeDatabaseFormat(file_path));
    const after = try fileSha256(file_path);
    try std.testing.expectEqualSlices(u8, &before, &after);

    // Missing database file.
    var missing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_path = try std.fmt.bufPrintZ(&missing_buffer, ".zig-cache/tmp/{s}/does-not-exist.zova", .{tmp.sub_path});
    try std.testing.expectError(error.NotZovaDatabase, zova.probeDatabaseFormat(missing_path));
}
