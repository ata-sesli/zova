//! Release gate for the Zova 1.x storage compatibility policy.
//!
//! Verifies the promises published in `docs/storage-compatibility.md` against
//! the retained fixtures in `tests/fixtures`:
//!
//!   * every pinned fixture is byte-identical to its recorded hash;
//!   * every fixture classifies exactly as the policy requires, with the
//!     expectation derived from `version.format_version` and
//!     `zova.minimum_migratable_format` rather than from a hardcoded list, so
//!     widening or narrowing the promise fails loudly;
//!   * a complete chain of adjacent migration steps exists from every promised
//!     format up to the current format;
//!   * every promised format migrates to the current format and reopens, with
//!     its source left byte-identical; and
//!   * every migratable main database is covered by the migration matrix, so a
//!     newly retained format cannot be promised without evidence that it works.
//!
//! Run it with `zig build check-storage-compat`.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const version = @import("version.zig");
const zova = @import("zova.zig");

const fixture_dir = "tests/fixtures";
const manifest_name = "fixtures.sha256";
const scratch_root = ".zig-cache/tmp/check-storage-compat";

/// One logical migration set. `members[0]` is the main database; the remaining
/// members are its bound stores.
const MigrationSet = struct {
    format: u32,
    members: []const []const u8,
};

/// Migratable main databases retained for the release check. Bound stores are
/// covered by the set that owns them, and standalone store files are covered by
/// the probe matrix: only a main database can be migrated on its own.
const migration_sets = [_]MigrationSet{
    .{ .format = 9, .members = &.{"empty-main-format-9.zova"} },
    .{ .format = 9, .members = &.{"format-9.zova"} },
    .{
        .format = 9,
        .members = &.{
            "bound-main-format-9.zova",
            "bound-main-format-9.objects.zova",
            "bound-main-format-9.vectors.zova",
            "bound-main-format-9.graphs.zova",
        },
    },
};

const store_suffixes = [_][2][]const u8{
    .{ "object_store", "objects" },
    .{ "vector_store", "vectors" },
    .{ "graph_store", "graphs" },
};

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

const Check = struct {
    failures: usize = 0,
    checks: usize = 0,

    fn record(self: *Check, ok: bool, comptime fmt: []const u8, args: anytype) void {
        self.checks += 1;
        if (ok) {
            std.debug.print("  ok    " ++ fmt ++ "\n", args);
        } else {
            self.failures += 1;
            std.debug.print("  FAIL  " ++ fmt ++ "\n", args);
        }
    }

    fn fail(self: *Check, comptime fmt: []const u8, args: anytype) void {
        self.failures += 1;
        std.debug.print("  FAIL  " ++ fmt ++ "\n", args);
    }

    fn note(self: *Check, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print("        " ++ fmt ++ "\n", args);
    }

    fn heading(self: *Check, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print("\n" ++ fmt ++ "\n", args);
    }
};

fn pathJoin(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    return allocator.dupeZ(u8, try std.fmt.allocPrint(allocator, fmt, args));
}

fn fixturePath(allocator: std.mem.Allocator, name: []const u8) ![:0]u8 {
    return pathJoin(allocator, "{s}/{s}", .{ fixture_dir, name });
}

fn fileSha256(allocator: std.mem.Allocator, path: []const u8) ![32]u8 {
    const bytes = try cwd().readFileAlloc(io(), path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn fileSize(path: []const u8) !u64 {
    return (try cwd().statFile(io(), path, .{})).size;
}

fn fileExists(path: []const u8) bool {
    cwd().access(io(), path, .{ .read = true }) catch return false;
    return true;
}

fn hexDigest(digest: [32]u8) [64]u8 {
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{digest}) catch unreachable;
    return out;
}

/// A database records `store_role` only when it is a bound store file; main
/// databases leave it absent.
fn hasStoreRole(path: [:0]const u8) !bool {
    var raw = try sqlite.Database.openWithFlags(path, .read_only);
    defer raw.deinit();

    var stmt = raw.prepare("select value from _zova_meta where key = 'store_role'") catch |err| switch (err) {
        error.SqliteError => return false,
        else => return err,
    };
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .done => false,
        .row => stmt.columnText(0).len > 0,
    };
}

fn compatibilityName(compatibility: zova.FormatCompatibility) []const u8 {
    return switch (compatibility) {
        .current => "current",
        .migratable => "migratable",
        .unsupported_legacy => "unsupported_legacy",
        .unsupported_future => "unsupported_future",
    };
}

/// Assert that a complete chain of adjacent steps runs from `from` up to `to`.
fn expectStepChain(check: *Check, from: u32, to: u32) void {
    var step = from;
    while (step < to) : (step += 1) {
        check.record(
            zova.findMigrationStep(step, step + 1) != null,
            "migration step {d} -> {d} registered",
            .{ step, step + 1 },
        );
    }
}

const ManifestEntry = struct {
    name: []u8,
    expected_hex: []const u8,
};

fn readManifest(allocator: std.mem.Allocator, entries: *std.ArrayListUnmanaged(ManifestEntry)) !void {
    const manifest_path = try pathJoin(allocator, "{s}/{s}", .{ fixture_dir, manifest_name });
    const bytes = try cwd().readFileAlloc(io(), manifest_path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const hash_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return error.MalformedManifest;
        const remainder = std.mem.trim(u8, trimmed[hash_end..], " ");
        const name = if (std.mem.startsWith(u8, remainder, "*")) remainder[1..] else remainder;

        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .expected_hex = try allocator.dupe(u8, trimmed[0..hash_end]),
        });
    }
}

fn copyFixtureInto(allocator: std.mem.Allocator, name: []const u8, destination: []const u8) !void {
    const source = try fixturePath(allocator, name);
    const bytes = try cwd().readFileAlloc(io(), source, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    try cwd().writeFile(io(), .{ .sub_path = destination, .data = bytes });
}

/// Point a main database's bound-store rows at their relocated siblings. The
/// committed fixtures record bare relative names that only resolve from
/// `tests/fixtures`, so relocating a set is the caller's job.
fn rewriteBoundStorePaths(allocator: std.mem.Allocator, main_path: [:0]const u8, dir: []const u8, main_name: []const u8) !void {
    const stem = main_name[0 .. main_name.len - ".zova".len];
    var raw = try sqlite.Database.open(main_path);
    defer raw.deinit();

    inline for (store_suffixes) |entry| {
        var update = try raw.prepare("update _zova_bound_stores set path = ?1 where role = ?2");
        defer update.deinit();
        const sibling = try pathJoin(allocator, "{s}/{s}.{s}.zova", .{ dir, stem, entry[1] });
        try update.bindText(1, sibling);
        try update.bindText(2, entry[0]);
        _ = try update.step();
    }
}

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(io());
}

fn elapsedMs(start: std.Io.Timestamp) f64 {
    const ns = start.durationTo(now()).toNanoseconds();
    return if (ns <= 0) 0 else @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const current_format = try std.fmt.parseInt(u32, version.format_version, 10);
    const minimum_format = try std.fmt.parseInt(u32, zova.minimum_migratable_format, 10);

    var check: Check = .{};

    std.debug.print("storage compatibility check\n", .{});
    std.debug.print("  zova {s}  format {d}  migratable from {d}  sqlite {s}\n", .{
        version.package_version, current_format, minimum_format, version.sqlite_version,
    });

    check.heading("declared compatibility policy", .{});
    check.record(minimum_format <= current_format, "minimum_migratable_format {d} <= format_version {d}", .{ minimum_format, current_format });

    check.heading("migration registry", .{});
    for (&zova.migration_steps) |*step| {
        check.record(step.from_version + 1 == step.to_version, "step {d} -> {d} is adjacent", .{ step.from_version, step.to_version });
        check.record(zova.findMigrationStep(step.from_version, step.to_version) != null, "step {d} -> {d} resolves exactly", .{ step.from_version, step.to_version });
    }
    expectStepChain(&check, minimum_format, current_format);

    var entries: std.ArrayListUnmanaged(ManifestEntry) = .empty;
    try readManifest(allocator, &entries);

    check.heading("retained fixtures ({d} pinned)", .{entries.items.len});

    var migratable_mains: std.ArrayListUnmanaged([]const u8) = .empty;
    var probed_formats: std.ArrayListUnmanaged(u32) = .empty;
    var covered_mains: std.ArrayListUnmanaged(bool) = .empty;

    for (entries.items) |entry| {
        const path = try fixturePath(allocator, entry.name);

        const actual = fileSha256(allocator, path) catch |err| {
            check.fail("{s}: cannot hash ({s})", .{ entry.name, @errorName(err) });
            continue;
        };
        const actual_hex = hexDigest(actual);
        check.record(std.mem.eql(u8, &actual_hex, entry.expected_hex), "{s}: hash {s}", .{ entry.name, actual_hex[0..12] });

        const info = zova.probeDatabaseFormat(path) catch |err| {
            check.fail("{s}: probe failed ({s})", .{ entry.name, @errorName(err) });
            continue;
        };

        const expected = if (info.format_version == current_format)
            zova.FormatCompatibility.current
        else if (info.format_version >= minimum_format)
            zova.FormatCompatibility.migratable
        else
            zova.FormatCompatibility.unsupported_legacy;

        check.record(
            expected == info.compatibility,
            "{s}: format {d} classifies as {s}",
            .{ entry.name, info.format_version, compatibilityName(info.compatibility) },
        );

        try probed_formats.append(allocator, info.format_version);

        if (info.compatibility == .migratable and !try hasStoreRole(path)) {
            try migratable_mains.append(allocator, entry.name);
        }
    }

    // Every promised format needs retained evidence: widening the promise
    // without a fixture would otherwise leave the migration path untested.
    check.heading("promised format coverage", .{});
    var promised = minimum_format;
    while (promised < current_format) : (promised += 1) {
        var retained = false;
        for (probed_formats.items) |format| {
            if (format == promised) retained = true;
        }
        check.record(retained, "format {d} has a retained fixture", .{promised});
    }

    // Every migratable main database must be covered by the migration matrix,
    // so retaining a new format without migration evidence fails the release.
    try covered_mains.appendNTimes(allocator, false, migratable_mains.items.len);
    for (migration_sets) |set| {
        for (migratable_mains.items, 0..) |name, index| {
            if (std.mem.eql(u8, name, set.members[0])) covered_mains.items[index] = true;
        }
    }
    check.heading("migration matrix coverage", .{});
    for (migratable_mains.items, covered_mains.items) |name, covered| {
        check.record(covered, "migratable main {s} has a migration set", .{name});
    }

    cwd().deleteTree(io(), scratch_root) catch {};
    try cwd().createDirPath(io(), scratch_root);

    check.heading("migration and reopen", .{});
    for (migration_sets, 0..) |set, set_index| {
        const dir = try pathJoin(allocator, "{s}/set-{d}-format-{d}", .{ scratch_root, set_index, set.format });
        try cwd().createDirPath(io(), dir);

        for (set.members) |name| {
            const staged = try pathJoin(allocator, "{s}/{s}", .{ dir, name });
            try copyFixtureInto(allocator, name, staged);
        }

        const main_path = try pathJoin(allocator, "{s}/{s}", .{ dir, set.members[0] });
        if (set.members.len > 1) {
            try rewriteBoundStorePaths(allocator, main_path, dir, set.members[0]);
        }

        // Snapshot after relocation: rebinding is the caller's job before
        // migration, so only the migration itself must leave the set untouched.
        var source_hashes = try allocator.alloc([32]u8, set.members.len);
        for (set.members, 0..) |name, index| {
            const staged = try pathJoin(allocator, "{s}/{s}", .{ dir, name });
            source_hashes[index] = try fileSha256(allocator, staged);
        }

        const destination = try pathJoin(allocator, "{s}/migrated-{d}-{s}", .{ dir, set_index, set.members[0] });
        const started = now();
        zova.migrateDatabase(main_path, destination, .{}) catch |err| {
            check.fail("{s}: migration failed ({s})", .{ set.members[0], @errorName(err) });
            continue;
        };
        const elapsed = elapsedMs(started);

        // The source set must be byte-identical after migration.
        for (set.members, 0..) |name, index| {
            const staged = try pathJoin(allocator, "{s}/{s}", .{ dir, name });
            const after = try fileSha256(allocator, staged);
            check.record(
                std.mem.eql(u8, &source_hashes[index], &after),
                "{s}: source unchanged after migration",
                .{name},
            );
        }

        const destination_info = zova.probeDatabaseFormat(destination) catch |err| {
            check.fail("{s}: destination probe failed ({s})", .{ set.members[0], @errorName(err) });
            continue;
        };
        check.record(
            destination_info.compatibility == .current and destination_info.format_version == current_format,
            "{s}: migrated to format {d}",
            .{ set.members[0], destination_info.format_version },
        );

        // Bound-store destinations are published before the main database.
        if (set.members.len > 1) {
            const stem = destination[0 .. destination.len - ".zova".len];
            inline for (store_suffixes) |entry| {
                const sibling = try pathJoin(allocator, "{s}.{s}.zova", .{ stem, entry[1] });
                check.record(fileExists(sibling), "{s}: bound {s} store published", .{ set.members[0], entry[1] });
            }
        }

        var migrated = zova.Database.open(destination) catch |err| {
            check.fail("{s}: destination does not reopen ({s})", .{ set.members[0], @errorName(err) });
            continue;
        };
        defer migrated.deinit();
        check.record(true, "{s}: destination reopens", .{set.members[0]});

        if (set.members.len > 1) {
            var objects = try migrated.boundObjectStore(allocator);
            var vectors = try migrated.boundVectorStore(allocator);
            var graphs = try migrated.boundGraphStore(allocator);
            check.record(
                objects != null and vectors != null and graphs != null,
                "{s}: bound stores resolve after migration",
                .{set.members[0]},
            );
            if (objects) |*info| info.deinit(allocator);
            if (vectors) |*info| info.deinit(allocator);
            if (graphs) |*info| info.deinit(allocator);
        }

        const source_size = try fileSize(main_path);
        const destination_size = try fileSize(destination);
        check.note("source {d} bytes, destination {d} bytes, {d:.2} ms, verify on", .{ source_size, destination_size, elapsed });
    }

    cwd().deleteTree(io(), scratch_root) catch {};

    check.heading("summary", .{});
    std.debug.print("  {d} checks, {d} failures\n", .{ check.checks, check.failures });
    if (check.failures > 0) {
        std.debug.print("storage compatibility check FAILED\n", .{});
        std.process.exit(1);
    }
    std.debug.print("storage compatibility check ok: format {d}, migratable from {d}\n", .{ current_format, minimum_format });
}
