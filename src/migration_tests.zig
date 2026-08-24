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

fn writeForgedDatabase(
    tmp_sub_path: []const u8,
    file_name: []const u8,
    magic_row: ?[]const u8,
    version_row: ?[]const u8,
) ![:0]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp_sub_path, file_name });

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();
    try raw.exec("create table _zova_meta (key text primary key, value text not null)");

    if (magic_row) |magic| {
        var insert = try raw.prepare("insert into _zova_meta (key, value) values ('magic', ?1)");
        defer insert.deinit();
        try insert.bindText(1, magic);
        _ = try insert.step();
    }
    if (version_row) |version| {
        var insert = try raw.prepare("insert into _zova_meta (key, value) values ('format_version', ?1)");
        defer insert.deinit();
        try insert.bindText(1, version);
        _ = try insert.step();
    }

    return try std.testing.allocator.dupeZ(u8, db_path);
}

fn expectSourceRejectedWithoutKv(
    db_path: [:0]const u8,
    expected_version: ?[]const u8,
    expected_error: anyerror,
) !void {
    // The step must fail as a non-Zova database and never create the KV
    // table; the file must remain structurally sound.
    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();
        try std.testing.expectError(expected_error, zova.runMigrationStep(&raw));
    }

    var raw = try sqlite.Database.openWithFlags(db_path, .read_only);
    defer raw.deinit();
    if (expected_version) |version| {
        try expectScalarTextRaw(&raw, "select value from _zova_meta where key = 'format_version'", version);
    } else {
        var missing = try raw.prepare("select count(*) from _zova_meta where key = 'format_version'");
        defer missing.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try missing.step());
        try std.testing.expectEqual(@as(i64, 0), missing.columnInt64(0));
    }
    try expectScalarTextRaw(&raw, "select count(*) from sqlite_master where type = 'table' and name = '_zova_kv'", "0");

    var quick_check = try raw.prepare("pragma quick_check");
    defer quick_check.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try quick_check.step());
    try std.testing.expectEqualStrings("ok", quick_check.columnText(0));
}

test "migration rejects forged format-9 files with bad or missing identity metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct { name: []const u8, magic: ?[]const u8, version: ?[]const u8 }{
        .{ .name = "forged-wrong-magic.zova", .magic = "not-zova", .version = "9" },
        .{ .name = "forged-missing-magic.zova", .magic = null, .version = "9" },
        .{ .name = "forged-missing-version.zova", .magic = "zova", .version = null },
    };

    inline for (cases) |case| {
        const db_path = try writeForgedDatabase(tmp.sub_path[0..], case.name, case.magic, case.version);
        defer std.testing.allocator.free(db_path);
        try expectSourceRejectedWithoutKv(db_path, case.version, error.NotZovaDatabase);
    }
}

test "migration rejects format-9 sources with malformed required tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A main database missing a required private schema.
    {
        const copy_path = try copyFixture(tmp.sub_path[0..], 0, "format-9.zova");
        defer std.testing.allocator.free(copy_path);

        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            try raw.exec("drop table _zova_objects");
        }

        try expectSourceRejectedWithoutKv(copy_path, "9", error.NotZovaDatabase);
    }

    // A main database whose required table exists but lost its shape.
    {
        const copy_path = try copyFixture(tmp.sub_path[0..], 1, "format-9.zova");
        defer std.testing.allocator.free(copy_path);

        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            try raw.exec(
                \\drop table _zova_object_chunks;
                \\create table _zova_object_chunks (
                \\  object_id blob not null,
                \\  chunk_index integer not null,
                \\  chunk_hash blob not null
                \\);
            );
        }

        try expectSourceRejectedWithoutKv(copy_path, "9", error.NotZovaDatabase);
    }

    // A store file whose role-required schema is broken.
    {
        const copy_path = try copyFixture(tmp.sub_path[0..], 2, "empty-vector-store-format-9.zova");
        defer std.testing.allocator.free(copy_path);

        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            try raw.exec("drop table _zova_vectors");
        }

        try expectSourceRejectedWithoutKv(copy_path, "9", error.NotZovaDatabase);
    }
}

test "migration rejects unknown store roles and store roles without their schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Unknown store_role value.
    {
        const copy_path = try copyFixture(tmp.sub_path[0..], 0, "empty-graph-store-format-9.zova");
        defer std.testing.allocator.free(copy_path);

        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            try raw.exec("update _zova_meta set value = 'quarantine' where key = 'store_role'");
        }

        try expectSourceRejectedWithoutKv(copy_path, "9", error.NotZovaDatabase);
    }

    // Role/schema mismatch: claims to be a graph store but its graph tables
    // were replaced by malformed shapes.
    {
        const copy_path = try copyFixture(tmp.sub_path[0..], 1, "empty-graph-store-format-9.zova");
        defer std.testing.allocator.free(copy_path);

        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            try raw.exec(
                \\drop table _zova_graph_edges;
                \\create table _zova_graph_edges (edge_key integer);
            );
        }

        try expectSourceRejectedWithoutKv(copy_path, "9", error.NotZovaDatabase);
    }
}

test "migration rejects mains with a malformed bound-store table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A format-9 main whose optional _zova_bound_stores table lost its shape
    // must not be transformed; open-time validation would reject it too.
    {
        const copy_path = try copyFixture(tmp.sub_path[0..], 0, "bound-main-format-9.zova");
        defer std.testing.allocator.free(copy_path);

        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            try raw.exec(
                \\drop table _zova_bound_stores;
                \\create table _zova_bound_stores (role text);
            );
        }

        try expectSourceRejectedWithoutKv(copy_path, "9", error.NotZovaDatabase);
    }

    // Same for a populated single-file main carrying a malformed table.
    {
        const copy_path = try copyFixture(tmp.sub_path[0..], 1, "format-9.zova");
        defer std.testing.allocator.free(copy_path);

        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            try raw.exec("create table _zova_bound_stores (role text)");
        }

        try expectSourceRejectedWithoutKv(copy_path, "9", error.NotZovaDatabase);
    }
}

test "migration rejects stores with missing or invalid store identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Missing store_id row on a vector store.
    {
        const copy_path = try copyFixture(tmp.sub_path[0..], 0, "empty-vector-store-format-9.zova");
        defer std.testing.allocator.free(copy_path);

        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            try raw.exec("delete from _zova_meta where key = 'store_id'");
        }

        try expectSourceRejectedWithoutKv(copy_path, "9", error.BoundStoreInvalid);
    }

    // Malformed store_id (wrong length) on a graph store.
    {
        const copy_path = try copyFixture(tmp.sub_path[0..], 1, "empty-graph-store-format-9.zova");
        defer std.testing.allocator.free(copy_path);

        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            try raw.exec("update _zova_meta set value = 'deadbeef' where key = 'store_id'");
        }

        try expectSourceRejectedWithoutKv(copy_path, "9", error.BoundStoreInvalid);
    }

    // Non-hex store_id characters on an object store.
    {
        const copy_path = try copyFixture(tmp.sub_path[0..], 2, "bound-main-format-9.objects.zova");
        defer std.testing.allocator.free(copy_path);

        {
            var raw = try sqlite.Database.open(copy_path);
            defer raw.deinit();
            var update = try raw.prepare("update _zova_meta set value = ?1 where key = 'store_id'");
            defer update.deinit();
            try update.bindText(1, "zzzz" ** 16);
            _ = try update.step();
        }

        try expectSourceRejectedWithoutKv(copy_path, "9", error.BoundStoreInvalid);
    }
}

// ---------------------------------------------------------------------------
// migrateDatabase: offline copy-forward migration of a main database and its
// bound stores.
// ---------------------------------------------------------------------------

fn expectMigratedSetParity(allocator: std.mem.Allocator, destination_path: []const u8, with_stores: bool) !void {
    // The published main reopens through the full open path and every public
    // meaning of the source survives the round trip.
    const owned_destination = try allocator.dupeZ(u8, destination_path);
    defer allocator.free(owned_destination);
    var db = try zova.Database.open(owned_destination);
    defer db.deinit();

    if (!with_stores) {
        // Objects keep size and chunk topology.
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

        var vectors = try db.prepare("select count(*) from _zova_vectors");
        defer vectors.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try vectors.step());
        try std.testing.expectEqual(@as(i64, 6), vectors.columnInt64(0));

        try std.testing.expect(try db.hasVectorCollection("embeddings_i8"));
        try std.testing.expect(try db.hasGraphEdge("social", "alice", "knows", "bob"));

        var extensions = try db.listExtensions(allocator);
        defer extensions.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), extensions.items.len);

        var kv_count = try db.prepare("select count(*) from _zova_kv");
        defer kv_count.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try kv_count.step());
        try std.testing.expectEqual(@as(i64, 0), kv_count.columnInt64(0));
        return;
    }

    // Bound set: store identity and epochs survive; binding paths point at
    // the published siblings; stores carry migrated KV schemas.
    var info = (try db.boundObjectStore(allocator)).?;
    defer info.deinit(allocator);
    try std.testing.expectEqualStrings("migrated-set.objects.zova", basenameOf(info.path));

    var graph_info = (try db.boundGraphStore(allocator)).?;
    defer graph_info.deinit(allocator);
    try std.testing.expectEqualStrings("migrated-set.graphs.zova", basenameOf(graph_info.path));

    var vector_info = (try db.boundVectorStore(allocator)).?;
    defer vector_info.deinit(allocator);
    try std.testing.expectEqualStrings("migrated-set.vectors.zova", basenameOf(vector_info.path));

    const stem = destination_path[0 .. destination_path.len - ".zova".len];
    inline for (.{ "objects", "vectors", "graphs" }) |suffix| {
        var sibling_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const sibling = try std.fmt.bufPrintZ(&sibling_buffer, "{s}.{s}.zova", .{ stem, suffix });
        var store_db = try sqlite.Database.openWithFlags(sibling, .read_only);
        defer store_db.deinit();
        try expectScalarTextRaw(&store_db, "select value from _zova_meta where key = 'format_version'", "10");
        try expectScalarTextRaw(&store_db, "select count(*) from sqlite_master where type = 'table' and name = '_zova_kv'", "1");
    }
}

fn basenameOf(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

test "migrateDatabase copies and migrates a single-file format-9 database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, ".zig-cache/tmp/{s}/migrate-single-source.zova", .{tmp.sub_path[0..]});
    try copyFixtureInto(source_path, "format-9.zova");
    const source_before = try fileSha256(source_path);

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrintZ(&dest_buffer, ".zig-cache/tmp/{s}/migrated-set.zova", .{tmp.sub_path[0..]});

    try zova.migrateDatabase(source_path, dest_path, .{});
    const source_after = try fileSha256(source_path);

    // Source preservation on success.
    try std.testing.expectEqualSlices(u8, &source_before, &source_after);
    // The source remains a rejected format-9 file.
    try std.testing.expectError(error.MigrationRequired, Database.open(source_path));

    // Destination is current-format and preserves public meaning.
    try expectMigratedSetParity(std.testing.allocator, dest_path, false);

    // Re-migrating the migrated destination is refused without mutation.
    const dest_hash = try fileSha256(dest_path);
    try std.testing.expectError(error.NoMigrationPath, zova.migrateDatabase(dest_path, source_path, .{}));
    const dest_after = try fileSha256(dest_path);
    try std.testing.expectEqualSlices(u8, &dest_hash, &dest_after);
}

test "migrateDatabase copies and migrates the full bound-store set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Stage the whole committed bound set under one directory so its
    // relative sibling bindings resolve.
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const set_dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/migrate-bound", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().createDirPath(io(), set_dir);

    const members = [_][]const u8{
        "bound-main-format-9.zova",
        "bound-main-format-9.objects.zova",
        "bound-main-format-9.vectors.zova",
        "bound-main-format-9.graphs.zova",
    };
    inline for (members) |name| {
        var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const member_path = try std.fmt.bufPrintZ(&member_buffer, "{s}/{s}", .{ set_dir, name });
        try copyFixtureInto(member_path, name);
    }

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_main = try std.fmt.bufPrintZ(&source_buffer, "{s}/bound-main-format-9.zova", .{set_dir});

    // Relocate the recorded sibling bindings to this test directory, exactly
    // like the #13 bound-set test: relative names only resolve from their
    // original working directory, and relocation is a caller concern before
    // migration begins.
    {
        var raw = try sqlite.Database.open(source_main);
        defer raw.deinit();
        inline for (.{
            .{ .role = "object_store", .suffix = "objects" },
            .{ .role = "vector_store", .suffix = "vectors" },
            .{ .role = "graph_store", .suffix = "graphs" },
        }) |entry| {
            var update = try raw.prepare("update _zova_bound_stores set path = ?1 where role = ?2");
            defer update.deinit();
            var sibling_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const sibling = try std.fmt.bufPrintZ(&sibling_buffer, "{s}/bound-main-format-9.{s}.zova", .{ set_dir, entry.suffix });
            try update.bindText(1, sibling);
            try update.bindText(2, entry.role);
            _ = try update.step();
        }
    }

    var hashes_before: [members.len][32]u8 = undefined;
    inline for (members, 0..) |name, index| {
        var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const member_path = try std.fmt.bufPrintZ(&member_buffer, "{s}/{s}", .{ set_dir, name });
        hashes_before[index] = try fileSha256(member_path);
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_main = try std.fmt.bufPrintZ(&dest_buffer, "{s}/migrated-set.zova", .{set_dir});

    try zova.migrateDatabase(source_main, dest_main, .{});

    // Every source file is byte-identical after a successful migration.
    inline for (members, 0..) |name, index| {
        var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const member_path = try std.fmt.bufPrintZ(&member_buffer, "{s}/{s}", .{ set_dir, name });
        const member_after = try fileSha256(member_path);
        try std.testing.expectEqualSlices(u8, &hashes_before[index], &member_after);
    }

    try expectMigratedSetParity(std.testing.allocator, dest_main, true);

    // No staging files remain in the set directory.
    var dir = try std.Io.Dir.cwd().openDir(io(), set_dir, .{ .iterate = true });
    defer dir.close(io());
    var iterator = dir.iterate();
    while (try iterator.next(io())) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".migrate-") == null);
    }
}

test "migrateDatabase rejects existing destinations before any mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, ".zig-cache/tmp/{s}/conflict-source.zova", .{tmp.sub_path[0..]});
    try copyFixtureInto(source_path, "format-9.zova");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrintZ(&dest_buffer, ".zig-cache/tmp/{s}/taken.zova", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = dest_path, .data = "occupied" });
    const dest_before = try fileSha256(dest_path);

    try std.testing.expectError(error.DestinationExists, zova.migrateDatabase(source_path, dest_path, .{}));

    // The occupied destination was not touched.
    const dest_conflict_after = try fileSha256(dest_path);
    try std.testing.expectEqualSlices(u8, &dest_before, &dest_conflict_after);
    // The source still classifies exactly as before.
    try std.testing.expectError(error.MigrationRequired, Database.open(source_path));
}

test "migrateDatabase cleans every created file when migration fails mid-flight" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, ".zig-cache/tmp/{s}/fail-source.zova", .{tmp.sub_path[0..]});
    try copyFixtureInto(source_path, "format-9.zova");

    // Inject a mid-step fault: the staged main's version update touches
    // _zova_meta, where this trigger aborts the step after KV creation. The
    // trigger lives only in this throwaway copy; installing it changes the
    // copy's bytes, so the preservation baseline is taken after injection.
    {
        var raw = try sqlite.Database.open(source_path);
        defer raw.deinit();
        try raw.exec(
            \\create trigger migration_fault before update on _zova_meta
            \\when new.value = '10' and old.key = 'format_version'
            \\begin select raise(abort,'injected migration failure'); end
        );
    }
    const source_before = try fileSha256(source_path);

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrintZ(&dest_buffer, ".zig-cache/tmp/{s}/never-published.zova", .{tmp.sub_path[0..]});

    try std.testing.expectError(error.Constraint, zova.migrateDatabase(source_path, dest_path, .{}));

    // The source hash is unchanged and nothing was published.
    const source_fail_after = try fileSha256(source_path);
    try std.testing.expectEqualSlices(u8, &source_before, &source_fail_after);
    const dest_exists = blk: {
        std.Io.Dir.cwd().access(io(), dest_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    try std.testing.expect(!dest_exists);

    // No staging leftovers either.
    var dir_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var dir = try std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true });
    defer dir.close(io());
    var iterator = dir.iterate();
    while (try iterator.next(io())) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".migrate-") == null);
    }
}

fn copyFixtureInto(destination_path: [:0]const u8, fixture_name: []const u8) !void {
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, "{s}/{s}", .{ fixture_dir, fixture_name });

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), source_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = destination_path, .data = bytes });
}

test "migrateDatabase cleans up after a fault at every phase boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const points = [_]zova.MigrateFaultPoint{
        .after_main_copy,
        .after_main_migration,
        .after_store_copy,
        .after_store_migration,
        .after_validation,
        .after_store_publication,
        .before_main_publication,
    };

    const FaultHook = struct {
        var target: ?zova.MigrateFaultPoint = null;
        var target_occurrence: usize = 1;
        var counter: usize = 0;

        fn fire(point: zova.MigrateFaultPoint) zova.Error!void {
            if (target != null and target.? == point) {
                counter += 1;
                if (counter == target_occurrence) return error.CantOpen;
            }
        }

        fn reset(occurrence: usize) void {
            target_occurrence = occurrence;
            counter = 0;
        }
    };

    for (points) |point| {
        const is_per_store = point == .after_store_copy or point == .after_store_migration or point == .after_store_publication;
        const max_occurrence: usize = if (is_per_store) 3 else 1;
        for (1..max_occurrence + 1) |occurrence| {
            // Per-point staging directory so leftover assertions are exact.
            var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const set_dir = if (is_per_store)
                try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/fault-{s}-{d}", .{
                    tmp.sub_path[0..],
                    @tagName(point),
                    occurrence,
                })
            else
                try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/fault-{s}", .{
                    tmp.sub_path[0..],
                    @tagName(point),
                });
            try std.Io.Dir.cwd().createDirPath(io(), set_dir);

            const members = [_][]const u8{
                "bound-main-format-9.zova",
                "bound-main-format-9.objects.zova",
                "bound-main-format-9.vectors.zova",
                "bound-main-format-9.graphs.zova",
            };
            inline for (members) |name| {
                var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const member_path = try std.fmt.bufPrintZ(&member_buffer, "{s}/{s}", .{ set_dir, name });
                try copyFixtureInto(member_path, name);
            }

            var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const source_main = try std.fmt.bufPrintZ(&source_buffer, "{s}/bound-main-format-9.zova", .{set_dir});

            // Relocate bindings into this directory (caller concern before migration).
            {
                var raw = try sqlite.Database.open(source_main);
                defer raw.deinit();
                inline for (.{
                    .{ .role = "object_store", .suffix = "objects" },
                    .{ .role = "vector_store", .suffix = "vectors" },
                    .{ .role = "graph_store", .suffix = "graphs" },
                }) |entry| {
                    var update = try raw.prepare("update _zova_bound_stores set path = ?1 where role = ?2");
                    defer update.deinit();
                    var sibling_buffer: [std.fs.max_path_bytes]u8 = undefined;
                    const sibling = try std.fmt.bufPrintZ(&sibling_buffer, "{s}/bound-main-format-9.{s}.zova", .{ set_dir, entry.suffix });
                    try update.bindText(1, sibling);
                    try update.bindText(2, entry.role);
                    _ = try update.step();
                }
            }

            var hashes: [members.len][32]u8 = undefined;
            inline for (members, 0..) |name, index| {
                var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const member_path = try std.fmt.bufPrintZ(&member_buffer, "{s}/{s}", .{ set_dir, name });
                hashes[index] = try fileSha256(member_path);
            }

            var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const dest_main = try std.fmt.bufPrintZ(&dest_buffer, "{s}/migrated-set.zova", .{set_dir});

            FaultHook.reset(occurrence);
            FaultHook.target = point;

            try std.testing.expectError(
                error.CantOpen,
                zova.migrateDatabaseInternal(source_main, dest_main, .{}, zova.bundledExtensionRegistry(), FaultHook.fire),
            );

            FaultHook.target = null;

            // Every source file is byte-identical after the failed attempt.
            inline for (members, 0..) |name, index| {
                var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const member_path = try std.fmt.bufPrintZ(&member_buffer, "{s}/{s}", .{ set_dir, name });
                const member_after = try fileSha256(member_path);
                try std.testing.expectEqualSlices(u8, &hashes[index], &member_after);
            }

            // The directory contains exactly the four sources: no destination
            // main, no published stores or placeholders, no staging leftovers.
            var dir = try std.Io.Dir.cwd().openDir(io(), set_dir, .{ .iterate = true });
            defer dir.close(io());
            var seen: usize = 0;
            var iterator = dir.iterate();
            while (try iterator.next(io())) |entry| {
                seen += 1;
                var matched = false;
                inline for (members) |name| {
                    if (std.mem.eql(u8, entry.name, name)) matched = true;
                }
                try std.testing.expect(matched);
            }
            try std.testing.expectEqual(@as(usize, members.len), seen);
        }
    }
}

test "migration rejects bound stores whose role mismatches the binding with verify disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const set_dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/role-mismatch", .{tmp.sub_path[0..]});
    try std.Io.Dir.cwd().createDirPath(io(), set_dir);

    const members = [_][]const u8{
        "bound-main-format-9.zova",
        "bound-main-format-9.objects.zova",
        "bound-main-format-9.vectors.zova",
        "bound-main-format-9.graphs.zova",
    };
    inline for (members) |name| {
        var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const member_path = try std.fmt.bufPrintZ(&member_buffer, "{s}/{s}", .{ set_dir, name });
        try copyFixtureInto(member_path, name);
    }

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_main = try std.fmt.bufPrintZ(&source_buffer, "{s}/bound-main-format-9.zova", .{set_dir});

    // Relocate bindings into this directory.
    {
        var raw = try sqlite.Database.open(source_main);
        defer raw.deinit();
        inline for (.{
            .{ .role = "object_store", .suffix = "objects" },
            .{ .role = "vector_store", .suffix = "vectors" },
            .{ .role = "graph_store", .suffix = "graphs" },
        }) |entry| {
            var update = try raw.prepare("update _zova_bound_stores set path = ?1 where role = ?2");
            defer update.deinit();
            var sibling_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const sibling = try std.fmt.bufPrintZ(&sibling_buffer, "{s}/bound-main-format-9.{s}.zova", .{ set_dir, entry.suffix });
            try update.bindText(1, sibling);
            try update.bindText(2, entry.role);
            _ = try update.step();
        }
    }

    // Tamper the objects store to claim it is a vector_store. The store files
    // carry every private schema, so self-validation would still pass, but the
    // binding requires object_store. With verify = false the mismatch must
    // still be caught in preflight under the lock.
    {
        var tamper_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const tamper_path = try std.fmt.bufPrintZ(&tamper_buffer, "{s}/bound-main-format-9.objects.zova", .{set_dir});
        var raw = try sqlite.Database.open(tamper_path);
        defer raw.deinit();
        try raw.exec("update _zova_meta set value = 'vector_store' where key = 'store_role'");
    }

    var hash_buffer: [members.len][32]u8 = undefined;
    inline for (members, 0..) |name, index| {
        var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const member_path = try std.fmt.bufPrintZ(&member_buffer, "{s}/{s}", .{ set_dir, name });
        hash_buffer[index] = try fileSha256(member_path);
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_main = try std.fmt.bufPrintZ(&dest_buffer, "{s}/migrated-set.zova", .{set_dir});

    try std.testing.expectError(
        error.BoundStoreInvalid,
        zova.migrateDatabaseInternal(source_main, dest_main, .{ .verify = false }, zova.bundledExtensionRegistry(), null),
    );

    // Source hashes unchanged, nothing published, no staging leftovers.
    inline for (members, 0..) |name, index| {
        var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const member_path = try std.fmt.bufPrintZ(&member_buffer, "{s}/{s}", .{ set_dir, name });
        const after = try fileSha256(member_path);
        try std.testing.expectEqualSlices(u8, &hash_buffer[index], &after);
    }

    var dir = try std.Io.Dir.cwd().openDir(io(), set_dir, .{ .iterate = true });
    defer dir.close(io());
    var seen: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io())) |entry| {
        seen += 1;
        var matched = false;
        inline for (members) |name| {
            if (std.mem.eql(u8, entry.name, name)) matched = true;
        }
        try std.testing.expect(matched);
    }
    try std.testing.expectEqual(@as(usize, members.len), seen);
}
