//! Storage format 13: the chunk-reference index (#195), incremental
//! auto-vacuum for new files, and bounded space reclaim (#197).

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova = @import("zova.zig");
const object_impl = @import("object.zig");
const query_plan = @import("query_plan_test_support.zig");
const testingDbPath = @import("zova_test_support.zig").testingDbPath;
const testingIntegrityCheckOk = @import("zova_test_support.zig").testingIntegrityCheckOk;

const Database = zova.Database;

const auto_vacuum_none: i64 = 0;
const auto_vacuum_incremental: i64 = 2;

fn pragmaInt(db: *sqlite.Database, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    return stmt.columnInt64(0);
}

fn fileAutoVacuum(path: [:0]const u8) !i64 {
    var raw = try sqlite.Database.open(path);
    defer raw.deinit();
    return pragmaInt(&raw, "pragma auto_vacuum");
}

fn expectChunkIndex(db: *sqlite.Database, comptime schema: []const u8) !void {
    var stmt = try db.prepare("select tbl_name, sql from " ++ schema ++ ".sqlite_schema where type = 'index' and name = '_zova_object_chunks_chunk_hash_idx'");
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("_zova_object_chunks", stmt.columnText(0));
    try std.testing.expect(@import("database/metadata.zig").schemaSqlEqual(stmt.columnText(1), object_impl.object_chunks_chunk_hash_index_sql));
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

fn expectFileChunkIndex(path: [:0]const u8) !void {
    var raw = try sqlite.Database.open(path);
    defer raw.deinit();
    try expectChunkIndex(&raw, "main");
}

fn deterministicBytes(buffer: []u8, seed: u64) void {
    var state = seed;
    for (buffer) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }
}

/// Store `mib` MiB through the streaming profile (1 MiB chunks).
fn putStreamingObject(db: *Database, mib: usize, seed: u64) !zova.ObjectId {
    var writer = try db.objectWriterWithOptions(std.testing.allocator, .{ .profile = .streaming });
    defer writer.deinit();
    const block = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(block);
    for (0..mib) |index| {
        deterministicBytes(block, seed +% index);
        try writer.write(block);
    }
    return try writer.finish();
}

test "format 13 files carry the exact chunk-reference index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffers: [4][std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&buffers[0], tmp.sub_path[0..], "main.zova");
    const object_path = try testingDbPath(&buffers[1], tmp.sub_path[0..], "objects.zova");
    const vector_path = try testingDbPath(&buffers[2], tmp.sub_path[0..], "vectors.zova");
    const graph_path = try testingDbPath(&buffers[3], tmp.sub_path[0..], "graphs.zova");

    {
        var db = try Database.create(main_path);
        db.deinit();
    }
    try zova.createObjectStore(object_path);
    try zova.createVectorStore(vector_path);
    try zova.createGraphStore(graph_path);
    for ([_][:0]const u8{ main_path, object_path, vector_path, graph_path }) |path| try expectFileChunkIndex(path);

    var memory = try Database.createMemory();
    defer memory.deinit();
    try expectChunkIndex(&memory.sqlite_db, "main");
}

test "open rejects a missing or altered chunk-reference index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "index-drift.zova");

    {
        var db = try Database.create(db_path);
        db.deinit();
    }
    const drifts = [_][:0]const u8{
        "drop index _zova_object_chunks_chunk_hash_idx",
        "drop index _zova_object_chunks_chunk_hash_idx; create index _zova_object_chunks_chunk_hash_idx on _zova_object_chunks(chunk_hash, object_id)",
        "drop index _zova_object_chunks_chunk_hash_idx; create index _zova_object_chunks_chunk_hash_idx on _zova_object_chunks(chunk_hash) where chunk_index > 0",
    };
    for (drifts) |drift| {
        {
            var raw = try sqlite.Database.open(db_path);
            defer raw.deinit();
            try raw.exec("drop index if exists _zova_object_chunks_chunk_hash_idx; " ++ object_impl.object_chunks_chunk_hash_index_sql);
            try raw.exec(drift);
        }
        try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
    }

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();
        try raw.exec("drop index if exists _zova_object_chunks_chunk_hash_idx; " ++ object_impl.object_chunks_chunk_hash_index_sql);
    }
    var restored = try Database.open(db_path);
    restored.deinit();
}

test "open rejects a bound object store without the chunk-reference index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffers: [2][std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&buffers[0], tmp.sub_path[0..], "main.zova");
    const store_path = try testingDbPath(&buffers[1], tmp.sub_path[0..], "main.objects.zova");

    {
        var db = try Database.create(main_path);
        defer db.deinit();
        _ = try db.splitObjectStore(store_path);
    }
    try expectFileChunkIndex(store_path);
    {
        var raw = try sqlite.Database.open(store_path);
        defer raw.deinit();
        try raw.exec("drop index _zova_object_chunks_chunk_hash_idx");
    }
    try std.testing.expectError(error.NotZovaDatabase, Database.open(main_path));
}

test "chunk-reference checks search the chunk-hash index in main and bound stores" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffers: [2][std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&buffers[0], tmp.sub_path[0..], "plans.zova");
    const store_path = try testingDbPath(&buffers[1], tmp.sub_path[0..], "plans.objects.zova");

    var db = try Database.create(main_path);
    defer db.deinit();

    for ([_]bool{ false, true }) |bound| {
        if (bound) _ = try db.splitObjectStore(store_path);
        const alias = if (bound) "object_store._zova_object_chunks" else "main._zova_object_chunks";

        const id = try putStreamingObject(&db, 2, if (bound) 7 else 3);
        const loose = zova.objectChunkId("loose chunk");
        try db.putObjectChunk(loose, "loose chunk");

        var capture: query_plan.Capture = .{};
        capture.install(&db.sqlite_db);
        defer capture.remove(&db.sqlite_db);

        capture.reset("not exists");
        try std.testing.expect(try db.deleteObjectChunk(loose));
        try capture.expectPlan(&db.sqlite_db, .{ .indexed = .{ .alias = alias, .index = "COVERING INDEX _zova_object_chunks_chunk_hash_idx", .key = "chunk_hash" } });

        capture.reset("not exists");
        try db.deleteObject(id);
        try capture.expectPlan(&db.sqlite_db, .{ .indexed = .{ .alias = alias, .index = "COVERING INDEX _zova_object_chunks_chunk_hash_idx", .key = "chunk_hash" } });
    }
}

test "deleting with the index keeps shared chunks and collects unreferenced ones" {
    var db = try Database.createMemory();
    defer db.deinit();

    const shared = try putStreamingObject(&db, 2, 11);
    // Same first MiB, different second MiB: exactly one chunk is shared.
    var writer = try db.objectWriterWithOptions(std.testing.allocator, .{ .profile = .streaming });
    defer writer.deinit();
    const block = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(block);
    deterministicBytes(block, 11);
    try writer.write(block);
    deterministicBytes(block, 99);
    try writer.write(block);
    const other = try writer.finish();

    try std.testing.expectEqual(@as(i64, 3), try pragmaInt(&db.sqlite_db, "select count(*) from _zova_chunks"));
    try db.deleteObject(shared);
    try std.testing.expectEqual(@as(i64, 2), try pragmaInt(&db.sqlite_db, "select count(*) from _zova_chunks"));

    try db.begin();
    try db.deleteObject(other);
    try std.testing.expectEqual(@as(i64, 0), try pragmaInt(&db.sqlite_db, "select count(*) from _zova_chunks"));
    try db.rollback();
    try std.testing.expectEqual(@as(i64, 2), try pragmaInt(&db.sqlite_db, "select count(*) from _zova_chunks"));
    try std.testing.expect(try db.hasObject(other));
}

test "new files use incremental auto-vacuum and keep a custom page size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffers: [5][std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&buffers[0], tmp.sub_path[0..], "main.zova");
    const sized_path = try testingDbPath(&buffers[1], tmp.sub_path[0..], "sized.zova");
    const object_path = try testingDbPath(&buffers[2], tmp.sub_path[0..], "objects.zova");
    const vector_path = try testingDbPath(&buffers[3], tmp.sub_path[0..], "vectors.zova");
    const graph_path = try testingDbPath(&buffers[4], tmp.sub_path[0..], "graphs.zova");

    {
        var db = try Database.create(main_path);
        db.deinit();
    }
    {
        var db = try Database.createWithOptions(sized_path, .{ .page_size = 16384 });
        defer db.deinit();
        try std.testing.expectEqual(@as(i64, 16384), try pragmaInt(&db.sqlite_db, "pragma page_size"));
    }
    try zova.createObjectStore(object_path);
    try zova.createVectorStore(vector_path);
    try zova.createGraphStore(graph_path);
    for ([_][:0]const u8{ main_path, sized_path, object_path, vector_path, graph_path }) |path| {
        try std.testing.expectEqual(auto_vacuum_incremental, try fileAutoVacuum(path));
    }

    var memory = try Database.createMemory();
    defer memory.deinit();
    try std.testing.expectEqual(auto_vacuum_incremental, try pragmaInt(&memory.sqlite_db, "pragma auto_vacuum"));
}

test "split stores and compact copies are incremental, backups keep the source mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffers: [8][std.fs.max_path_bytes]u8 = undefined;
    const legacy_path = try testingDbPath(&buffers[0], tmp.sub_path[0..], "legacy.zova");
    const backup_path = try testingDbPath(&buffers[1], tmp.sub_path[0..], "legacy-backup.zova");
    const restored_path = try testingDbPath(&buffers[2], tmp.sub_path[0..], "legacy-restored.zova");
    const compact_path = try testingDbPath(&buffers[3], tmp.sub_path[0..], "legacy-compact.zova");
    const object_path = try testingDbPath(&buffers[4], tmp.sub_path[0..], "legacy.objects.zova");
    const vector_path = try testingDbPath(&buffers[5], tmp.sub_path[0..], "legacy.vectors.zova");
    const graph_path = try testingDbPath(&buffers[6], tmp.sub_path[0..], "legacy.graphs.zova");
    const source_sqlite = try testingDbPath(&buffers[7], tmp.sub_path[0..], "plain.sqlite");

    {
        // A format-13 file whose mode is still `none`, as a migrated file is.
        var db = try Database.create(legacy_path);
        defer db.deinit();
        try db.exec("pragma auto_vacuum = none; vacuum");
    }
    try std.testing.expectEqual(auto_vacuum_none, try fileAutoVacuum(legacy_path));

    {
        var db = try Database.open(legacy_path);
        defer db.deinit();
        try db.backupTo(backup_path, .{});
        try db.compactTo(compact_path, .{});
        _ = try db.splitObjectStore(object_path);
        _ = try db.splitVectorStore(vector_path);
        _ = try db.splitGraphStore(graph_path);
    }
    try zova.restoreBackup(backup_path, restored_path, .{});

    try std.testing.expectEqual(auto_vacuum_none, try fileAutoVacuum(backup_path));
    try std.testing.expectEqual(auto_vacuum_none, try fileAutoVacuum(restored_path));
    try std.testing.expectEqual(auto_vacuum_incremental, try fileAutoVacuum(compact_path));
    for ([_][:0]const u8{ object_path, vector_path, graph_path }) |path| {
        try std.testing.expectEqual(auto_vacuum_incremental, try fileAutoVacuum(path));
    }

    // Converting a plain SQLite file keeps that file's mode.
    {
        var raw = try sqlite.Database.open(source_sqlite);
        defer raw.deinit();
        try raw.exec("create table app_rows (id integer primary key)");
    }
    var convert_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const converted_path = try testingDbPath(&convert_buffer, tmp.sub_path[0..], "converted.zova");
    try zova.convertSqliteToZova(source_sqlite, converted_path);
    try std.testing.expectEqual(auto_vacuum_none, try fileAutoVacuum(converted_path));
    try expectFileChunkIndex(converted_path);
}

test "reclaimSpace releases freed object pages in bounded steps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "reclaim.zova");

    var db = try Database.create(db_path);
    defer db.deinit();
    const kept = try putStreamingObject(&db, 2, 21);
    const removed = try putStreamingObject(&db, 16, 22);
    const pages_before_delete = try pragmaInt(&db.sqlite_db, "pragma page_count");
    try db.deleteObject(removed);
    const free_after_delete: u64 = @intCast(try pragmaInt(&db.sqlite_db, "pragma freelist_count"));
    try std.testing.expect(free_after_delete > 16 * 256 / 2);
    try std.testing.expectEqual(pages_before_delete, try pragmaInt(&db.sqlite_db, "pragma page_count"));

    try std.testing.expectError(error.InvalidArgument, db.reclaimSpace(.{ .step_pages = 0 }));

    // A bounded call releases exactly `max_pages`.
    const bounded = try db.reclaimSpace(.{ .max_pages = 100, .step_pages = 30 });
    try std.testing.expectEqual(@as(usize, 1), bounded.members().len);
    const first = bounded.members()[0];
    try std.testing.expectEqual(zova.ProgressMember.main, first.member);
    try std.testing.expectEqual(zova.AutoVacuumMode.incremental, first.auto_vacuum);
    try std.testing.expectEqual(@as(u32, 4096), first.page_size);
    try std.testing.expectEqual(@as(u64, 100), first.pages_released);
    try std.testing.expectEqual(free_after_delete - 100, first.free_pages_left);

    // An open reader keeps reading verified bytes while pages move.
    var reader = try db.objectReader(kept);
    defer reader.deinit();
    var head: [4096]u8 = undefined;
    try std.testing.expectEqual(head.len, try reader.read(&head));

    const rest = try db.reclaimSpace(.{ .step_pages = 512 });
    try std.testing.expectEqual(free_after_delete - 100, rest.members()[0].pages_released);
    try std.testing.expectEqual(@as(u64, 0), rest.members()[0].free_pages_left);
    try std.testing.expectEqual(@as(i64, 0), try pragmaInt(&db.sqlite_db, "pragma freelist_count"));
    try std.testing.expect(try pragmaInt(&db.sqlite_db, "pragma page_count") < pages_before_delete - @as(i64, @intCast(free_after_delete / 2)));

    var buffer: [64 * 1024]u8 = undefined;
    while (try reader.read(&buffer) != 0) {}
    try testingIntegrityCheckOk(&db);

    try db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.reclaimSpace(.{}));
    try db.rollback();
}

test "reclaimSpace covers bound stores and reports members without incremental mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffers: [3][std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&buffers[0], tmp.sub_path[0..], "bound.zova");
    const store_path = try testingDbPath(&buffers[1], tmp.sub_path[0..], "bound.objects.zova");
    const vector_path = try testingDbPath(&buffers[2], tmp.sub_path[0..], "bound.vectors.zova");

    {
        var db = try Database.create(main_path);
        defer db.deinit();
        try db.exec("pragma auto_vacuum = none; vacuum");
        _ = try db.splitObjectStore(store_path);
        _ = try db.splitVectorStore(vector_path);
    }

    var db = try Database.open(main_path);
    defer db.deinit();
    const id = try putStreamingObject(&db, 8, 31);
    try db.deleteObject(id);

    const result = try db.reclaimSpace(.{});
    const members = result.members();
    try std.testing.expectEqual(@as(usize, 3), members.len);
    try std.testing.expectEqual(zova.ProgressMember.main, members[0].member);
    try std.testing.expectEqual(zova.AutoVacuumMode.none, members[0].auto_vacuum);
    try std.testing.expectEqual(@as(u64, 0), members[0].pages_released);
    try std.testing.expectEqual(zova.ProgressMember.object_store, members[1].member);
    try std.testing.expectEqual(zova.AutoVacuumMode.incremental, members[1].auto_vacuum);
    try std.testing.expect(members[1].pages_released >= 8 * 256 / 2);
    try std.testing.expectEqual(@as(u64, 0), members[1].free_pages_left);
    try std.testing.expectEqual(zova.ProgressMember.vector_store, members[2].member);
    try std.testing.expectEqual(@as(i64, 0), try pragmaInt(&db.sqlite_db, "pragma object_store.freelist_count"));
    try testingIntegrityCheckOk(&db);
}
