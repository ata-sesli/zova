//! Progress reporting for migration, backup, and compaction: event shape per
//! phase and member, bounded backup steps, and cancellation through the
//! callback leaving the same state as a failure at that point.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const test_support = @import("zova_test_support.zig");
const zova = @import("zova.zig");

const Database = zova.Database;
const Progress = zova.Progress;

const fixture_dir = "tests/fixtures";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Records every event and optionally fails with `error.Interrupt` at one
/// event index.
const Recorder = struct {
    events: std.ArrayList(Progress) = .empty,
    cancel_at: ?usize = null,
    /// Run once at the first event, for concurrent-writer checks.
    on_first: ?*const fn () anyerror!void = null,

    fn deinit(self: *Recorder) void {
        self.events.deinit(std.testing.allocator);
    }

    fn callback(self: *Recorder) zova.ProgressCallback {
        return .{ .context = self, .report = report };
    }

    fn report(context: ?*anyopaque, progress: Progress) zova.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        const index = self.events.items.len;
        self.events.append(std.testing.allocator, progress) catch return error.NoMemory;
        if (index == 0) if (self.on_first) |hook| hook() catch return error.SqliteError;
        if (self.cancel_at) |cancel| if (cancel == index) return error.Interrupt;
    }

    fn count(self: *const Recorder, phase: zova.ProgressPhase, member: ?zova.ProgressMember) usize {
        var n: usize = 0;
        for (self.events.items) |event| {
            if (event.phase == phase and event.member == member) n += 1;
        }
        return n;
    }

    fn last(self: *const Recorder, phase: zova.ProgressPhase, member: ?zova.ProgressMember) ?Progress {
        var found: ?Progress = null;
        for (self.events.items) |event| {
            if (event.phase == phase and event.member == member) found = event;
        }
        return found;
    }
};

const Group = struct { phase: zova.ProgressPhase, member: ?zova.ProgressMember, first: usize, last: usize };

/// Split events into consecutive (phase, member) groups and check each group
/// keeps `total` fixed, never decreases `done`, and ends with `done == total`.
fn expectWellFormedGroups(events: []const Progress, groups: []Group) !usize {
    var count: usize = 0;
    for (events, 0..) |event, index| {
        if (count == 0 or groups[count - 1].phase != event.phase or groups[count - 1].member != event.member) {
            groups[count] = .{ .phase = event.phase, .member = event.member, .first = index, .last = index };
            count += 1;
        } else {
            const group = &groups[count - 1];
            const previous = events[group.last];
            try std.testing.expectEqual(previous.total, event.total);
            try std.testing.expect(event.done >= previous.done);
            group.last = index;
        }
        try std.testing.expect(event.done <= event.total);
    }
    for (groups[0..count]) |group| {
        const end = events[group.last];
        try std.testing.expectEqual(end.total, end.done);
    }
    return count;
}

fn fileSha256(path: []const u8) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

const bound_members = [_][]const u8{
    "bound-main-format-9.zova",
    "bound-main-format-9.objects.zova",
    "bound-main-format-9.vectors.zova",
    "bound-main-format-9.graphs.zova",
};

/// Copy the format-9 bound fixture set into `set_dir` and point its bindings
/// at the copies.
fn stageBoundFixture(set_dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io(), set_dir);
    inline for (bound_members) |name| {
        var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const source = try std.fmt.bufPrint(&source_buffer, "{s}/{s}", .{ fixture_dir, name });
        var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const member = try std.fmt.bufPrint(&member_buffer, "{s}/{s}", .{ set_dir, name });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), source, std.testing.allocator, .limited(64 * 1024 * 1024));
        defer std.testing.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = member, .data = bytes });
    }
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main = try std.fmt.bufPrintSentinel(&main_buffer, "{s}/bound-main-format-9.zova", .{set_dir}, 0);
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
        const sibling = try std.fmt.bufPrintSentinel(&sibling_buffer, "{s}/bound-main-format-9.{s}.zova", .{ set_dir, entry.suffix }, 0);
        try update.bindText(1, sibling);
        try update.bindText(2, entry.role);
        _ = try update.step();
    }
}

fn migrateBoundFixture(set_dir: []const u8, recorder: *Recorder) !void {
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source = try std.fmt.bufPrintSentinel(&source_buffer, "{s}/bound-main-format-9.zova", .{set_dir}, 0);
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest = try std.fmt.bufPrintSentinel(&dest_buffer, "{s}/migrated-set.zova", .{set_dir}, 0);
    try zova.migrateDatabaseInternal(std.testing.allocator, source, dest, .{ .progress = recorder.callback() }, zova.bundledExtensionRegistry(), null);
}

test "migration reports copy, migrate, verify, and publish progress per member" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const set_dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/events", .{tmp.sub_path[0..]});
    try stageBoundFixture(set_dir);

    var recorder = Recorder{};
    defer recorder.deinit();
    try migrateBoundFixture(set_dir, &recorder);

    var groups: [64]Group = undefined;
    const group_count = try expectWellFormedGroups(recorder.events.items, &groups);

    const expected = [_]struct { zova.ProgressPhase, ?zova.ProgressMember }{
        .{ .copy, .main },         .{ .migrate, .main },
        .{ .copy, .object_store }, .{ .migrate, .object_store },
        .{ .copy, .vector_store }, .{ .migrate, .vector_store },
        .{ .copy, .graph_store },  .{ .migrate, .graph_store },
        .{ .verify, null },        .{ .publish, null },
    };
    try std.testing.expectEqual(expected.len, group_count);
    for (expected, groups[0..group_count]) |want, got| {
        try std.testing.expectEqual(want[0], got.phase);
        try std.testing.expectEqual(want[1], got.member);
    }

    const format_steps: u64 = (try std.fmt.parseInt(u64, @import("version.zig").format_version, 10)) - 9;
    for ([_]zova.ProgressMember{ .main, .object_store, .vector_store, .graph_store }) |member| {
        // One event before the first step, then one per committed step.
        try std.testing.expectEqual(format_steps + 1, recorder.count(.migrate, member));
        try std.testing.expectEqual(format_steps, recorder.last(.migrate, member).?.total);
        try std.testing.expect(recorder.last(.copy, member).?.total > 0);
    }
    try std.testing.expect(recorder.last(.verify, null).?.total > 0);
    try std.testing.expectEqual(@as(u64, 0), recorder.events.items[groups[8].first].done);
    // One event per published file: three stores, then the main database.
    const publish = recorder.events.items[groups[9].first .. groups[9].last + 1];
    try std.testing.expectEqual(@as(usize, 4), publish.len);
    for (publish, 1..) |event, done| {
        try std.testing.expectEqual(@as(u64, done), event.done);
        try std.testing.expectEqual(@as(u64, 4), event.total);
    }
}

test "cancelling migration at each phase boundary leaves the state of a failure there" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Record a complete run to learn every boundary event index.
    var full = Recorder{};
    defer full.deinit();
    {
        var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const set_dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/full", .{tmp.sub_path[0..]});
        try stageBoundFixture(set_dir);
        try migrateBoundFixture(set_dir, &full);
    }
    var groups: [64]Group = undefined;
    const group_count = try expectWellFormedGroups(full.events.items, &groups);
    const final_event = full.events.items.len - 1;

    var boundaries: [128]usize = undefined;
    var boundary_count: usize = 0;
    for (groups[0..group_count]) |group| {
        // Each publish event follows one file's publication, like the
        // per-store `after_store_publication` fault point.
        if (group.phase == .publish) {
            for (group.first..group.last + 1) |index| {
                boundaries[boundary_count] = index;
                boundary_count += 1;
            }
            continue;
        }
        boundaries[boundary_count] = group.first;
        boundary_count += 1;
        if (group.last != group.first) {
            boundaries[boundary_count] = group.last;
            boundary_count += 1;
        }
    }

    for (boundaries[0..boundary_count]) |cancel_at| {
        var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const set_dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/cancel-{d}", .{ tmp.sub_path[0..], cancel_at });
        try stageBoundFixture(set_dir);

        var hashes: [bound_members.len][32]u8 = undefined;
        inline for (bound_members, 0..) |name, index| {
            var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
            hashes[index] = try fileSha256(try std.fmt.bufPrint(&member_buffer, "{s}/{s}", .{ set_dir, name }));
        }

        var recorder = Recorder{ .cancel_at = cancel_at };
        defer recorder.deinit();
        const result = migrateBoundFixture(set_dir, &recorder);

        var dir = try std.Io.Dir.cwd().openDir(io(), set_dir, .{ .iterate = true });
        defer dir.close(io());
        var seen: usize = 0;
        var iterator = dir.iterate();
        while (try iterator.next(io())) |_| seen += 1;

        if (cancel_at == final_event) {
            // The final publish event follows the commit and cannot cancel it.
            try result;
            try std.testing.expectEqual(bound_members.len * 2, seen);
            continue;
        }
        if (result) |_| {
            return error.TestExpectedError;
        } else |err| if (err != error.Interrupt) {
            std.debug.print("cancel at event {d}: {s}\n", .{ cancel_at, @errorName(err) });
            return err;
        }

        // Same assertions as the fault-point test: sources byte-identical and
        // nothing else left behind.
        inline for (bound_members, 0..) |name, index| {
            var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const after = try fileSha256(try std.fmt.bufPrint(&member_buffer, "{s}/{s}", .{ set_dir, name }));
            try std.testing.expectEqualSlices(u8, &hashes[index], &after);
        }
        std.testing.expectEqual(bound_members.len, seen) catch |err| {
            std.debug.print("cancel at event {d}: {d} files\n", .{ cancel_at, seen });
            return err;
        };
    }
}

/// Fill a database past several backup steps with incompressible object data.
fn createLargeDatabase(path: [:0]const u8) !void {
    var db = try Database.create(path);
    defer db.deinit();
    const bytes = try std.testing.allocator.alloc(u8, 6 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    var prng = std.Random.DefaultPrng.init(199);
    prng.random().bytes(bytes);
    _ = try db.putObject(bytes);
    try db.kvPut("ns", "key", "value");
}

fn fileExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io(), path, .{}) catch return false;
    return true;
}

test "backup copies in bounded page steps and reports verify progress" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try test_support.testingDbPath(&path_buffer, tmp.sub_path[0..], "large.zova");
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try test_support.testingDbPath(&backup_buffer, tmp.sub_path[0..], "large-backup.zova");
    var unverified_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const unverified_path = try test_support.testingDbPath(&unverified_buffer, tmp.sub_path[0..], "large-unverified.zova");
    try createLargeDatabase(path);

    var db = try Database.open(path);
    defer db.deinit();

    var recorder = Recorder{};
    defer recorder.deinit();
    try db.backupTo(backup_path, .{ .progress = recorder.callback() });

    var groups: [8]Group = undefined;
    const group_count = try expectWellFormedGroups(recorder.events.items, &groups);
    try std.testing.expectEqual(@as(usize, 2), group_count);
    try std.testing.expectEqual(zova.ProgressPhase.copy, groups[0].phase);
    try std.testing.expectEqual(zova.ProgressPhase.verify, groups[1].phase);

    const pages = recorder.last(.copy, .main).?.total;
    const steps = (pages + @import("database/backup.zig").backup_step_pages - 1) / @import("database/backup.zig").backup_step_pages;
    try std.testing.expect(steps >= 2);
    try std.testing.expectEqual(steps, recorder.count(.copy, .main));
    for (recorder.events.items[groups[0].first .. groups[0].last + 1]) |event| {
        try std.testing.expect(event.done == event.total or event.done % @import("database/backup.zig").backup_step_pages == 0);
    }

    // One object, its chunks, and one KV entry, after a 0 event.
    var chunk_count: u64 = 0;
    {
        var stmt = try db.prepare("select count(*) from _zova_chunks");
        defer stmt.deinit();
        _ = try stmt.step();
        chunk_count = @intCast(stmt.columnInt64(0));
    }
    try std.testing.expectEqual(1 + chunk_count + 1, recorder.last(.verify, null).?.total);
    try std.testing.expectEqual(1 + chunk_count + 1 + 1, recorder.count(.verify, null));

    var unverified = Recorder{};
    defer unverified.deinit();
    try db.backupTo(unverified_path, .{ .verify = false, .progress = unverified.callback() });
    try std.testing.expectEqual(@as(usize, 0), unverified.count(.verify, null));
    try std.testing.expectEqual(steps, unverified.count(.copy, .main));
}

var concurrent_source: [:0]const u8 = undefined;

fn writeFromAnotherConnection() anyerror!void {
    var other = try Database.open(concurrent_source);
    defer other.deinit();
    try other.kvPut("ns", "concurrent", "value");
}

test "stepped backup copies one snapshot while another connection writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try test_support.testingDbPath(&path_buffer, tmp.sub_path[0..], "wal.zova");
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try test_support.testingDbPath(&backup_buffer, tmp.sub_path[0..], "wal-backup.zova");
    try createLargeDatabase(path);
    {
        var raw = try sqlite.Database.open(path);
        defer raw.deinit();
        try raw.exec("pragma journal_mode=wal");
    }

    var db = try Database.open(path);
    defer db.deinit();
    concurrent_source = path;
    var recorder = Recorder{ .on_first = writeFromAnotherConnection };
    defer recorder.deinit();
    try db.backupTo(backup_path, .{ .progress = recorder.callback() });

    // The write landed in the source, the copy never restarted, and the copy
    // holds the snapshot from before the write.
    var groups: [8]Group = undefined;
    _ = try expectWellFormedGroups(recorder.events.items, &groups);
    var source_value = try db.kvGet(std.testing.allocator, "ns", "concurrent");
    defer source_value.deinit(std.testing.allocator);
    try std.testing.expect(source_value.found);

    var copy = try Database.open(backup_path);
    defer copy.deinit();
    var copy_value = try copy.kvGet(std.testing.allocator, "ns", "concurrent");
    defer copy_value.deinit(std.testing.allocator);
    try std.testing.expect(!copy_value.found);
}

test "cancelling backup or compact removes the destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try test_support.testingDbPath(&path_buffer, tmp.sub_path[0..], "cancel.zova");
    try createLargeDatabase(path);

    var db = try Database.open(path);
    defer db.deinit();

    // Learn the event sequence of each operation, then cancel at every event
    // of the short ones and at each boundary of the copy.
    for ([_]bool{ false, true }) |compact| {
        var full = Recorder{};
        defer full.deinit();
        {
            var full_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = try test_support.testingDbPath(&full_buffer, tmp.sub_path[0..], if (compact) "full-compact.zova" else "full-backup.zova");
            if (compact) try db.compactTo(full_path, .{ .progress = full.callback() }) else try db.backupTo(full_path, .{ .progress = full.callback() });
        }
        var groups: [8]Group = undefined;
        const group_count = try expectWellFormedGroups(full.events.items, &groups);
        try std.testing.expectEqual(@as(usize, 2), group_count);
        if (compact) try std.testing.expectEqual(@as(usize, 2), full.count(.copy, .main));

        const boundaries = [_]usize{ groups[0].first, groups[0].last, groups[1].first, groups[1].last };
        for (boundaries) |cancel_at| {
            var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
            var name_buffer: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "{s}-{d}.zova", .{ if (compact) "compact" else "backup", cancel_at });
            const dest = try test_support.testingDbPath(&dest_buffer, tmp.sub_path[0..], name);
            var recorder = Recorder{ .cancel_at = cancel_at };
            defer recorder.deinit();
            const result = if (compact) db.compactTo(dest, .{ .progress = recorder.callback() }) else db.backupTo(dest, .{ .progress = recorder.callback() });
            try std.testing.expectError(error.Interrupt, result);
            try std.testing.expect(!fileExists(dest));
        }
    }

    // The source is still usable for writes: no read transaction leaked.
    try db.kvPut("ns", "after", "value");
}

test "backup and compact report inlined bound stores as copy boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try test_support.testingDbPath(&path_buffer, tmp.sub_path[0..], "bound.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try test_support.testingDbPath(&store_buffer, tmp.sub_path[0..], "bound.objects.zova");

    var db = try Database.create(path);
    defer db.deinit();
    try zova.createObjectStore(store_path);
    try db.bindObjectStore(store_path);
    _ = try db.putObject("bound object bytes");

    for ([_]bool{ false, true }) |compact| {
        var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const dest = try test_support.testingDbPath(&dest_buffer, tmp.sub_path[0..], if (compact) "bound-compact.zova" else "bound-backup.zova");
        var recorder = Recorder{};
        defer recorder.deinit();
        if (compact) try db.compactTo(dest, .{ .progress = recorder.callback() }) else try db.backupTo(dest, .{ .progress = recorder.callback() });

        var groups: [8]Group = undefined;
        const group_count = try expectWellFormedGroups(recorder.events.items, &groups);
        try std.testing.expectEqual(@as(usize, 3), group_count);
        try std.testing.expectEqual(zova.ProgressMember.main, groups[0].member.?);
        try std.testing.expectEqual(zova.ProgressMember.object_store, groups[1].member.?);
        try std.testing.expectEqual(zova.ProgressPhase.copy, groups[1].phase);
        try std.testing.expectEqual(@as(usize, 2), recorder.count(.copy, .object_store));
        try std.testing.expectEqual(@as(u64, 0), recorder.events.items[groups[1].first].done);
        try std.testing.expectEqual(zova.ProgressPhase.verify, groups[2].phase);
    }
}
