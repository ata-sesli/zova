//! Storage-format migration registry and per-file step tests.
//!
//! Covers the sequential adjacent migration registry and the exact
//! format 9 -> 10 transformation over the genuine released format-9 fixtures:
//! successful transforms reopen as valid current-format databases, refusals
//! leave sources byte-identical, and schema failures roll back completely so
//! the recorded format version never advances.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const test_support = @import("zova_test_support.zig");
const zova = @import("zova.zig");

const Database = zova.Database;

const fixture_dir = "tests/fixtures";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn fileSha256(path: []const u8) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn copyFixture(tmp_sub_path: []const u8, index: usize, name: []const u8) ![:0]const u8 {
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, "{s}/{s}", .{ fixture_dir, name });

    var copy_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const copy_path = try std.fmt.bufPrintZ(&copy_buffer, ".zig-cache/tmp/{s}/migration-{d}-{s}", .{ tmp_sub_path, index, name });

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), source_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);

    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = copy_path, .data = bytes });
    return try std.testing.allocator.dupeZ(u8, copy_path);
}

fn scalarCount(db: *sqlite.Database, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    return stmt.columnInt64(0);
}

fn expectScalarTextRaw(db: *sqlite.Database, sql: [:0]const u8, expected: []const u8) !void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings(expected, stmt.columnText(0));
}

test "migration registry only registers adjacent steps with exact version pairs" {
    for (&zova.migration_steps) |*step| {
        try std.testing.expectEqual(step.from_version + 1, step.to_version);
        try std.testing.expect(zova.findMigrationStep(step.from_version, step.to_version) != null);
    }

    // Exact pair matching: no skipping, no catch-all.
    try std.testing.expect(zova.findMigrationStep(9, 10) != null);
    try std.testing.expect(zova.findMigrationStep(8, 10) == null);
    try std.testing.expect(zova.findMigrationStep(8, 9) == null);
    try std.testing.expect(zova.findMigrationStep(10, 11) == null);
    try std.testing.expect(zova.findMigrationStep(9, 9) == null);
    try std.testing.expect(zova.findMigrationStep(7, 8) == null);
}

test "migration transforms genuine format-9 fixtures into valid format-10 databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Standalone mains transform and reopen through the full open path.
    const standalone_fixtures = [_][]const u8{
        "empty-main-format-9.zova",
        "format-9.zova",
    };

    inline for (standalone_fixtures, 0..) |name, index| {
        const copy_path = try copyFixture(tmp.sub_path[0..], index, name);
        defer std.testing.allocator.free(copy_path);

        const before_extension_rows = blk: {
            var raw = try sqlite.Database.openWithFlags(copy_path, .read_only);
            defer raw.deinit();
            break :blk scalarCount(&raw, "select count(*) from _zova_extensions");
        };

        var new_version: u32 = 0;
        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            new_version = try zova.runMigrationStep(&raw);

            // Version metadata is updated inside the same transaction.
            try expectScalarTextRaw(&raw, "select value from _zova_meta where key = 'format_version'", "10");
            try expectScalarTextRaw(&raw, "select value from _zova_meta where key = 'magic'", "zova");
        }
        try std.testing.expectEqual(@as(u32, 10), new_version);

        // The migrated file reopens through the full open path.
        var db = try Database.open(copy_path);
        defer db.deinit();

        // Extension records survive the transform unchanged.
        var raw = try sqlite.Database.openWithFlags(copy_path, .read_only);
        defer raw.deinit();
        try std.testing.expectEqual(try before_extension_rows, try scalarCount(&raw, "select count(*) from _zova_extensions"));
    }

    // Every member of the committed bound set transforms independently; the
    // migrated main then accepts its migrated stores through full open
    // validation including attach checks, using the recorded relative
    // sibling paths inside one directory.
    const bound_members = [_][]const u8{
        "bound-main-format-9.zova",
        "bound-main-format-9.objects.zova",
        "bound-main-format-9.vectors.zova",
        "bound-main-format-9.graphs.zova",
    };

    {
        var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const bound_dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/bound-set", .{tmp.sub_path[0..]});
        try std.Io.Dir.cwd().createDirPath(io(), bound_dir);
    }

    inline for (bound_members) |name| {
        var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const source_path = try std.fmt.bufPrintZ(&source_buffer, "{s}/{s}", .{ fixture_dir, name });

        var staged_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const staged_path = try std.fmt.bufPrintZ(&staged_buffer, ".zig-cache/tmp/{s}/bound-set/{s}", .{ tmp.sub_path[0..], name });

        const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), source_path, std.testing.allocator, .limited(64 * 1024 * 1024));
        defer std.testing.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = staged_path, .data = bytes });

        {
            var raw = try sqlite.Database.open(staged_path);
            defer raw.deinit();
            _ = try zova.runMigrationStep(&raw);
            try expectScalarTextRaw(&raw, "select value from _zova_meta where key = 'format_version'", "10");
        }
    }

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const staged_main = try std.fmt.bufPrintZ(&main_buffer, ".zig-cache/tmp/{s}/bound-set/bound-main-format-9.zova", .{tmp.sub_path[0..]});

    // The committed bound set records bare relative sibling names, which only
    // resolve from the exporter's working directory. Relocating a bound set is
    // the copy-forward orchestrator's job (#14): rewrite each binding path to
    // its relocated location before reopening. Here the rewrite emulates that
    // step so the migrated main is validated against its migrated stores.
    {
        var raw = try sqlite.Database.open(staged_main);
        defer raw.deinit();
        inline for (.{ "object_store", "vector_store", "graph_store" }) |role| {
            var update = try raw.prepare("update _zova_bound_stores set path = ?1 where role = ?2");
            defer update.deinit();
            var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const sibling = try std.fmt.bufPrintZ(
                &store_buffer,
                ".zig-cache/tmp/{s}/bound-set/bound-main-format-9.{s}.zova",
                .{ tmp.sub_path[0..], roleSuffix(role) },
            );
            try update.bindText(1, sibling);
            try update.bindText(2, role);
            _ = try update.step();
        }
    }

    var db = try Database.open(staged_main);
    defer db.deinit();

    var graph_info = (try db.boundGraphStore(std.testing.allocator)).?;
    defer graph_info.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 64), graph_info.store_id.len);
    try std.testing.expectEqual(@as(usize, 64), graph_info.bound_set_id.len);
}

fn roleSuffix(role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "object_store")) return "objects";
    if (std.mem.eql(u8, role, "vector_store")) return "vectors";
    if (std.mem.eql(u8, role, "graph_store")) return "graphs";
    unreachable;
}

test "migrated populated format-9 database preserves object vector graph and extension content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const copy_path = try copyFixture(tmp.sub_path[0..], 0, "format-9.zova");
    defer std.testing.allocator.free(copy_path);

    {
        var raw = try sqlite.Database.open(copy_path);
        defer raw.deinit();
        _ = try zova.runMigrationStep(&raw);
    }

    var db = try Database.open(copy_path);
    defer db.deinit();

    // Objects keep size and chunk topology across the transform.
    const expected_objects = [_]struct { size: i64, chunks: i64 }{
        .{ .size = 54, .chunks = 1 },
        .{ .size = 39, .chunks = 1 },
        .{ .size = 320 * 1024, .chunks = 32 },
    };
    inline for (expected_objects) |expected| {
        var stmt = try db.prepare("select chunk_count from _zova_objects where size_bytes = ?");
        defer stmt.deinit();
        try stmt.bindInt64(1, expected.size);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqual(expected.chunks, stmt.columnInt64(0));
    }

    // Vector collections keep all rows under their original names.
    var vectors = try db.prepare("select count(*) from _zova_vectors");
    defer vectors.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try vectors.step());
    try std.testing.expectEqual(@as(i64, 6), vectors.columnInt64(0));

    try std.testing.expect(try db.hasVectorCollection("embeddings_f32"));
    try std.testing.expect(try db.hasVectorCollection("embeddings_f16"));
    try std.testing.expect(try db.hasVectorCollection("embeddings_i8"));

    // Graphs keep names, nodes, typed edges, and payloads.
    try std.testing.expect(try db.hasGraph("social"));
    try std.testing.expect(try db.hasGraph("workflow"));
    try std.testing.expect(try db.hasGraphEdge("social", "alice", "knows", "bob"));

    // Bundled trgm extension record is intact.
    var extensions = try db.listExtensions(std.testing.allocator);
    defer extensions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), extensions.items.len);
    try std.testing.expectEqualStrings("trgm", extensions.items[0].name);

    // The migrated KV store exists and is empty.
    var kv_count = try db.prepare("select count(*) from _zova_kv");
    defer kv_count.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try kv_count.step());
    try std.testing.expectEqual(@as(i64, 0), kv_count.columnInt64(0));

    try test_support.testingQuickCheckOk(&db.sqlite_db);
}

test "migration refuses current pre-migratable and future formats without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Current format cannot migrate again; byte hash unchanged because the
    // refusal happens before any transaction begins.
    {
        var fresh_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const fresh_path = try std.fmt.bufPrintZ(&fresh_buffer, ".zig-cache/tmp/{s}/refuse-current.zova", .{tmp.sub_path[0..]});
        {
            var created = try Database.create(fresh_path);
            created.deinit();
        }

        const before = try fileSha256(fresh_path);
        {
            var raw = try sqlite.Database.open(fresh_path);
            defer raw.deinit();
            try std.testing.expectError(error.NoMigrationPath, zova.runMigrationStep(&raw));
        }
        const after = try fileSha256(fresh_path);
        try std.testing.expectEqualSlices(u8, &before, &after);
    }

    // Format 8 has no registered adjacent step (no skipping straight to 10)
    // and format 7 is likewise unmigratable; genuine fixture copies remain
    // byte-identical and still classify as unsupported legacy afterwards.
    const legacy_fixtures = [_][]const u8{
        "format-8.zova",
        "empty-format-7.zova",
    };
    inline for (legacy_fixtures, 0..) |name, index| {
        const copy_path = try copyFixture(tmp.sub_path[0..], 100 + index, name);
        defer std.testing.allocator.free(copy_path);

        const before = try fileSha256(copy_path);
        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            try std.testing.expectError(error.NoMigrationPath, zova.runMigrationStep(&raw));
        }
        const after = try fileSha256(copy_path);
        try std.testing.expectEqualSlices(u8, &before, &after);

        try std.testing.expectError(error.UnsupportedLegacyFormat, Database.open(copy_path));
    }

    // Future formats are never migratable.
    {
        var future_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const future_path = try std.fmt.bufPrintZ(&future_buffer, ".zig-cache/tmp/{s}/refuse-future.zova", .{tmp.sub_path[0..]});
        {
            var raw = try sqlite.Database.open(future_path);
            defer raw.deinit();
            try raw.exec(
                \\create table _zova_meta (key text primary key, value text not null);
                \\insert into _zova_meta (key, value) values ('magic', 'zova');
                \\insert into _zova_meta (key, value) values ('format_version', '11');
            );
        }

        const before = try fileSha256(future_path);
        {
            var raw = try sqlite.Database.open(future_path);
            defer raw.deinit();
            try std.testing.expectError(error.NoMigrationPath, zova.runMigrationStep(&raw));
        }
        const after = try fileSha256(future_path);
        try std.testing.expectEqualSlices(u8, &before, &after);
    }
}

test "migration rolls back completely when schema work fails and never advances the version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const copy_path = try copyFixture(tmp.sub_path[0..], 0, "format-9.zova");
    defer std.testing.allocator.free(copy_path);

    // Sabotage the step: a malformed pre-existing `_zova_kv` table makes the
    // authoritative CREATE fail mid-transaction.
    {
        var raw = try sqlite.Database.open(copy_path);
        defer raw.deinit();
        try raw.exec("create table _zova_kv (wrong text)");
    }

    {
        var raw = try sqlite.Database.open(copy_path);
        defer raw.deinit();
        try std.testing.expectError(error.SqliteError, zova.runMigrationStep(&raw));
    }

    // Rollback leaves the source exactly at format 9 with no partial schema
    // changes beyond the sabotaged table created by the test itself.
    var raw = try sqlite.Database.openWithFlags(copy_path, .read_only);
    defer raw.deinit();
    try expectScalarTextRaw(&raw, "select value from _zova_meta where key = 'format_version'", "9");
    try expectScalarTextRaw(&raw, "select count(*) from sqlite_master where type = 'table' and name = '_zova_kv'", "1");

    var quick_check = try raw.prepare("pragma quick_check");
    defer quick_check.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try quick_check.step());
    try std.testing.expectEqualStrings("ok", quick_check.columnText(0));
}
