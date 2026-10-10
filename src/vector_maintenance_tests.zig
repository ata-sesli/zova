const std = @import("std");
const zova = @import("zova.zig");
const sqlite = @import("sqlite.zig");
const maintenance = @import("vector_maintenance.zig");
const api = @import("extension_plugin_api.zig");

fn count(db: *sqlite.Database, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    return stmt.columnInt64(0);
}

const Seen = struct {
    rows: usize = 0,
    found: usize = 0,
    last: i64 = 0,
    first_value: f32 = 0,
    fn row(raw: ?*anyopaque, values: ?[*]const api.Value, n: u64) callconv(.c) i32 {
        const self: *Seen = @ptrCast(@alignCast(raw.?));
        if (n != 4 or values == null or values.?[0].integer <= self.last) return 3;
        self.rows += 1;
        self.found += @intCast(values.?[2].integer);
        self.last = values.?[0].integer;
        if (values.?[2].integer != 0) self.first_value = @bitCast(std.mem.readInt(u32, values.?[3].bytes.?[0..4], .little));
        return 0;
    }
};

test "vector maintenance paginates final replacements deletes and callback failures" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    const base = try maintenance.view(&db.sqlite_db, "main.", "v");
    try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
    try db.putVector("v", "a", .{ .f32 = &.{ 9, 10 } });
    var seen: Seen = .{};
    var request: api.VectorChangesRequest = .{ .name = .from("v"), .since = base, .row_limit = 1, .byte_limit = 4096, .row = Seen.row, .user_data = &seen };
    const page = try maintenance.read(&db.sqlite_db, "main.", &request);
    try std.testing.expectEqual(@as(u32, 1), page.has_more);
    try std.testing.expectEqual(@as(f32, 9), seen.first_value);
    request.after_revision = page.next_revision;
    const last = try maintenance.read(&db.sqlite_db, "main.", &request);
    try std.testing.expectEqual(@as(u32, 0), last.has_more);
    try std.testing.expectEqual(@as(usize, 2), seen.rows);
    try std.testing.expectEqual(@as(f32, 9), seen.first_value);
    try db.deleteVector("v", "a");
    request.after_revision = 0;
    request.row_limit = 16;
    seen = .{};
    _ = try maintenance.read(&db.sqlite_db, "main.", &request);
    try std.testing.expectEqual(@as(usize, 3), seen.rows);
    try std.testing.expectEqual(@as(usize, 0), seen.found);
    request.byte_limit = 1;
    try std.testing.expectError(error.PluginLimit, maintenance.read(&db.sqlite_db, "main.", &request));
    request.byte_limit = 4096;
    request.row = struct {
        fn fail(_: ?*anyopaque, _: ?[*]const api.Value, _: u64) callconv(.c) i32 {
            return 2;
        }
    }.fail;
    try db.begin();
    try db.putVector("v", "earlier", .{ .f32 = &.{ 1, 1 } });
    try std.testing.expectError(error.OutOfMemory, maintenance.read(&db.sqlite_db, "main.", &request));
    try std.testing.expect(try db.hasVector("v", "earlier"));
    try db.rollback();
}

test "missing source tracking fails the authoritative vector statement atomically" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    try db.exec("delete from _zova_vector_sources");
    try std.testing.expectError(error.Constraint, db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } }));
    try std.testing.expect(!try db.hasVector("v", "a"));
}

test "vector source views refuse incomplete retained history" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
    try db.exec("delete from _zova_vector_changes");
    try std.testing.expectError(error.Corrupt, maintenance.view(&db.sqlite_db, "main.", "v"));
}

test "application randomblob overrides cannot reuse a rolled back source token" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    const callback = struct {
        fn constant(ctx: ?*sqlite.c.sqlite3_context, _: c_int, _: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
            sqlite.c.sqlite3_result_zeroblob(ctx, 16);
        }
    }.constant;
    try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_create_function_v2(db.sqlite_db.handle, "randomblob", 1, sqlite.c.SQLITE_UTF8, null, callback, null, null, null));
    try db.begin();
    try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
    const rolled_back = try maintenance.view(&db.sqlite_db, "main.", "v");
    try db.rollback();
    try db.putVector("v", "b", .{ .f32 = &.{ 3, 4 } });
    const current = try maintenance.view(&db.sqlite_db, "main.", "v");
    try std.testing.expect(!std.mem.eql(u8, &rolled_back.token, &current.token));
}

test "vector maintenance detects rollback branches recreation and bounded history" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    const initial = try maintenance.view(&db.sqlite_db, "main.", "v");
    try db.begin();
    try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
    const provisional = try maintenance.view(&db.sqlite_db, "main.", "v");
    try db.rollback();
    try db.putVector("v", "b", .{ .f32 = &.{ 2, 3 } });
    const current = try maintenance.view(&db.sqlite_db, "main.", "v");
    try std.testing.expectEqual(provisional.revision, current.revision);
    try std.testing.expect(!std.mem.eql(u8, &provisional.token, &current.token));
    var seen: Seen = .{};
    var request: api.VectorChangesRequest = .{ .name = .from("v"), .since = provisional, .row_limit = 4096, .byte_limit = 1024 * 1024, .row = Seen.row, .user_data = &seen };
    try std.testing.expectError(error.SourceChanged, maintenance.read(&db.sqlite_db, "main.", &request));
    request.since = initial;
    const page = try maintenance.read(&db.sqlite_db, "main.", &request);
    try std.testing.expectEqual(@as(u64, 1), page.rows);
    try std.testing.expectEqual(@as(usize, 1), seen.found);
    try db.begin();
    for (0..4600) |_| try db.putVector("v", "b", .{ .f32 = &.{ 2, 3 } });
    try db.commit();
    try std.testing.expect(try count(&db.sqlite_db, "select count(*) from _zova_vector_changes") <= maintenance.retained_changes + maintenance.retirement_block - 1);
    try std.testing.expectError(error.HistoryUnavailable, maintenance.read(&db.sqlite_db, "main.", &request));
    try db.deleteVectorCollection("v");
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    const recreated = try maintenance.view(&db.sqlite_db, "main.", "v");
    try std.testing.expect(!std.mem.eql(u8, &initial.incarnation, &recreated.incarnation));
    try std.testing.expectError(error.SourceChanged, maintenance.read(&db.sqlite_db, "main.", &request));
}

test "vector maintenance main and bound WAL readers keep their caller snapshots" {
    for ([_]bool{ false, true }) |bound| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const a = std.testing.allocator;
        const main = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/main.zova", .{tmp.sub_path}, 0);
        defer a.free(main);
        const store = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/vectors.zova", .{tmp.sub_path}, 0);
        defer a.free(store);
        var writer = try zova.Database.create(main);
        defer writer.deinit();
        if (bound) {
            try zova.createVectorStore(store);
            try writer.bindVectorStore(store);
        }
        try writer.exec("pragma journal_mode=wal");
        if (bound) try writer.exec("pragma vector_store.journal_mode=wal");
        try writer.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
        const prefix = if (bound) "vector_store." else "main.";
        const initial = try maintenance.view(&writer.sqlite_db, prefix, "v");
        var reader = try zova.Database.openWithOptions(main, .{ .read_only = true });
        defer reader.deinit();
        try reader.begin();
        const old = try maintenance.view(&reader.sqlite_db, prefix, "v");
        try writer.putVector("v", "new", .{ .f32 = &.{ 1, 2 } });
        var seen: Seen = .{};
        const request: api.VectorChangesRequest = .{ .name = .from("v"), .since = initial, .row_limit = 1, .byte_limit = 4096, .row = Seen.row, .user_data = &seen };
        const page = try maintenance.read(&reader.sqlite_db, prefix, &request);
        try std.testing.expectEqual(old, page.view);
        try std.testing.expectEqual(@as(u64, 0), page.rows);
        try reader.rollback();
        const fresh = try maintenance.read(&reader.sqlite_db, prefix, &request);
        try std.testing.expectEqual(@as(u64, 1), fresh.rows);
        try std.testing.expectEqual(@as(usize, 1), seen.found);
        try std.testing.expectEqual(@as(i64, 1), fresh.view.revision);
        const backup = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/backup.zova", .{tmp.sub_path}, 0);
        defer a.free(backup);
        try writer.backupTo(backup, .{});
        var copy = try zova.Database.open(backup);
        defer copy.deinit();
        try std.testing.expectEqual(fresh.view, try maintenance.view(&copy.sqlite_db, "main.", "v"));
        var restored = try zova.restoreBackupToMemory(backup, .{});
        defer restored.deinit();
        try std.testing.expectEqual(fresh.view, try maintenance.view(&restored.sqlite_db, "main.", "v"));
        var inlined = try zova.restoreBackupToMemory(main, .{});
        defer inlined.deinit();
        try std.testing.expectEqual(fresh.view, try maintenance.view(&inlined.sqlite_db, "main.", "v"));
        // Newer writers can retire history without changing an older reader's
        // already established WAL source/history snapshot.
        try reader.begin();
        _ = try maintenance.view(&reader.sqlite_db, prefix, "v");
        try writer.beginImmediate();
        for (0..4600) |_| try writer.putVector("v", "new", .{ .f32 = &.{ 3, 4 } });
        try writer.commit();
        const newest = try maintenance.view(&writer.sqlite_db, prefix, "v");
        var mismatch = request;
        mismatch.since = newest;
        try std.testing.expectError(error.SourceChanged, maintenance.read(&reader.sqlite_db, prefix, &mismatch));
        seen = .{};
        const pinned = try maintenance.read(&reader.sqlite_db, prefix, &request);
        try std.testing.expectEqual(fresh.view, pinned.view);
        try std.testing.expectEqual(@as(f32, 1), seen.first_value);
        try reader.rollback();
        try std.testing.expectError(error.HistoryUnavailable, maintenance.read(&reader.sqlite_db, prefix, &request));
    }
}

test "vector split preserves history coverage and source identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const main = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/split-main.zova", .{tmp.sub_path}, 0);
    defer a.free(main);
    const store = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/split-vectors.zova", .{tmp.sub_path}, 0);
    defer a.free(store);
    var db = try zova.Database.create(main);
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    const base = try maintenance.view(&db.sqlite_db, "main.", "v");
    try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
    const before = try maintenance.view(&db.sqlite_db, "main.", "v");
    _ = try db.splitVectorStore(store);
    try std.testing.expectEqual(before, try maintenance.view(&db.sqlite_db, "vector_store.", "v"));
    var seen: Seen = .{};
    const request: api.VectorChangesRequest = .{ .name = .from("v"), .since = base, .row_limit = 16, .byte_limit = 4096, .row = Seen.row, .user_data = &seen };
    const page = try maintenance.read(&db.sqlite_db, "vector_store.", &request);
    try std.testing.expectEqual(before, page.view);
    try std.testing.expectEqual(@as(u64, 1), page.rows);
    try std.testing.expectEqual(@as(f32, 1), seen.first_value);
}

test "vector source history is operation atomic and stores identities not payload copies" {
    var db = try zova.Database.createMemory();
    defer db.deinit();
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    try std.testing.expectEqual(@as(i64, 1), try count(&db.sqlite_db, "select count(*) from _zova_vector_sources where length(incarnation)=16 and revision=0 and token=incarnation"));
    try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
    try db.begin();
    try db.putVector("v", "b", .{ .f32 = &.{ 3, 4 } });
    try db.savepoint("user");
    try db.deleteVector("v", "a");
    try std.testing.expectEqual(@as(i64, 3), try count(&db.sqlite_db, "select revision from _zova_vector_sources"));
    try db.rollbackToSavepoint("user");
    try db.releaseSavepoint("user");
    try std.testing.expectEqual(@as(i64, 2), try count(&db.sqlite_db, "select revision from _zova_vector_sources"));
    try db.rollback();
    try std.testing.expectEqual(@as(i64, 1), try count(&db.sqlite_db, "select count(*) from _zova_vector_changes"));
    try std.testing.expectEqual(@as(i64, 1), try count(&db.sqlite_db, "select revision from _zova_vector_sources"));
    try std.testing.expectEqual(@as(i64, 0), try count(&db.sqlite_db, "select count(*) from pragma_table_info('_zova_vector_changes') where name='values'"));
    try db.exec("create trigger injected_vector_history_failure before insert on _zova_vector_changes when new.vector_id='bad' begin select raise(abort,'fault'); end");
    try db.begin();
    try db.putVector("v", "earlier", .{ .f32 = &.{ 1, 1 } });
    try std.testing.expectError(error.Constraint, db.putVectors("v", &.{ .{ .id = "first", .values = .{ .f32 = &.{ 1, 2 } } }, .{ .id = "bad", .values = .{ .f32 = &.{ 2, 3 } } } }));
    try std.testing.expect(!try db.hasVector("v", "first"));
    try std.testing.expect(try db.hasVector("v", "earlier"));
    try std.testing.expectEqual(@as(i64, 2), try count(&db.sqlite_db, "select revision from _zova_vector_sources"));
    try db.rollback();
}

test "bound vector epoch failures roll back a single source operation inside caller work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const main = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/main-epoch.zova", .{tmp.sub_path}, 0);
    defer a.free(main);
    const store = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/epoch-vectors.zova", .{tmp.sub_path}, 0);
    defer a.free(store);
    var db = try zova.Database.create(main);
    defer db.deinit();
    try zova.createVectorStore(store);
    try db.bindVectorStore(store);
    try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
    try db.begin();
    try db.putVector("v", "earlier", .{ .f32 = &.{ 1, 2 } });
    const before = try maintenance.view(&db.sqlite_db, "vector_store.", "v");
    try db.exec("create trigger injected_epoch_failure before update on _zova_bound_stores begin select raise(abort,'epoch fault'); end");
    try std.testing.expectError(error.Constraint, db.putVector("v", "bad", .{ .f32 = &.{ 3, 4 } }));
    try std.testing.expect(!try db.hasVector("v", "bad"));
    try std.testing.expect(try db.hasVector("v", "earlier"));
    try std.testing.expectEqual(before, try maintenance.view(&db.sqlite_db, "vector_store.", "v"));
    try db.rollback();
}
