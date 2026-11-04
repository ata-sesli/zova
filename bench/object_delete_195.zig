//! One bounded object put/delete/reclaim sample for issues #195 and #197.
//! Usage: binary NEW_DATABASE_PATH index|no-index incremental|none
//!        BACKGROUND_ROWS deduplication|streaming PAYLOAD_BYTES [SQL ...]
//! Each optional SQL argument (for example `pragma synchronous = off`) runs
//! after `auto_vacuum` is set and before the schema is created, so a cell can
//! vary one connection setting with everything else fixed.
//! Fixture: default rollback journal, 4 KiB pages, `foreign_keys = on`.
//! `index` adds the format-13 `chunk_hash` index; `no-index` is the format-12
//! schema. BACKGROUND_ROWS manifest rows (1,000 per object, one 1-byte chunk
//! each) are loaded untimed before the measured object, so chunk-reference
//! checks have a realistic table to search. Timed regions:
//! - put: every `ObjectWriter.write` call and `finish` (payload generation is
//!   untimed);
//! - delete: `deleteObject` of that object;
//! - reclaim (incremental only): `incremental_vacuum` in 1,024-page
//!   transactions until the freelist is empty, the same loop `reclaimSpace`
//!   runs.
const std = @import("std");
const objects = @import("object_impl");

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn seconds(start: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(now()).toNanoseconds())) / 1_000_000_000;
}

fn pragmaU64(db: *objects.sqlite.Database, sql: [:0]const u8) !u64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.NoRow;
    return @intCast(stmt.columnInt64(0));
}

const DbStatus = struct {
    fn read(db: *objects.sqlite.Database, op: c_int) i64 {
        var current: c_int = 0;
        var high: c_int = 0;
        _ = objects.sqlite.c.sqlite3_db_status(db.handle, op, &current, &high, 0);
        return current;
    }
};

/// Size of `path`, or 0 when it does not exist (a deleted rollback journal).
fn fileSize(path: []const u8) u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return stat.size;
}

fn loadBackground(db: *objects.sqlite.Database, rows: u64) !void {
    if (rows == 0) return;
    if (rows % 1000 != 0) return error.InvalidArgument;
    var sql_buffer: [1024]u8 = undefined;
    try db.exec("begin immediate");
    // Keys come from integers so the load is deterministic; the high bit keeps
    // them apart from SHA-256 ids of the measured payload in practice.
    const chunks = try std.fmt.bufPrintSentinel(&sql_buffer,
        \\with recursive n(i) as (select 0 union all select i + 1 from n where i + 1 < {d})
        \\insert into _zova_chunks(chunk_hash, size_bytes, data)
        \\select unhex(printf('ff%062x', i)), 1, x'00' from n
    , .{rows}, 0);
    try db.exec(chunks);
    const objects_sql = try std.fmt.bufPrintSentinel(&sql_buffer,
        \\with recursive n(i) as (select 0 union all select i + 1 from n where i + 1 < {d})
        \\insert into _zova_objects(object_id, size_bytes, chunk_count, chunker)
        \\select unhex(printf('fe%062x', i)), 1000, 1000, 'fastcdc-v1' from n
    , .{rows / 1000}, 0);
    try db.exec(objects_sql);
    const manifest = try std.fmt.bufPrintSentinel(&sql_buffer,
        \\with recursive n(i) as (select 0 union all select i + 1 from n where i + 1 < {d})
        \\insert into _zova_object_chunks(object_id, chunk_index, chunk_hash, offset, size_bytes)
        \\select unhex(printf('fe%062x', i / 1000)), i % 1000, unhex(printf('ff%062x', i)), i % 1000, 1 from n
    , .{rows}, 0);
    try db.exec(manifest);
    try db.exec("commit");
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 7) return error.InvalidArgument;
    const with_index = if (std.mem.eql(u8, args[2], "index")) true else if (std.mem.eql(u8, args[2], "no-index")) false else return error.InvalidArgument;
    const incremental = if (std.mem.eql(u8, args[3], "incremental")) true else if (std.mem.eql(u8, args[3], "none")) false else return error.InvalidArgument;
    const background_rows = try std.fmt.parseInt(u64, args[4], 10);
    const profile = std.meta.stringToEnum(objects.ObjectStorageProfile, args[5]) orelse return error.InvalidArgument;
    const total_bytes = try std.fmt.parseInt(usize, args[6], 10);
    if (total_bytes == 0 or total_bytes > 1024 * 1024 * 1024) return error.InvalidArgument;

    const payload = try std.heap.c_allocator.alloc(u8, total_bytes);
    defer std.heap.c_allocator.free(payload);
    var state: u64 = 0x5a6f7661;
    for (payload) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 32);
    }

    var raw = try objects.sqlite.Database.open(try arena.dupeSentinel(u8, args[1], 0));
    defer raw.deinit();
    if (incremental) try raw.exec("pragma auto_vacuum = incremental");
    try raw.exec("pragma foreign_keys = on");
    for (args[7..]) |sql| try raw.exec(try arena.dupeSentinel(u8, sql, 0));
    try raw.exec(objects.objects_schema_sql ++ ";" ++ objects.chunks_schema_sql ++ ";" ++ objects.object_chunks_schema_sql ++ ";");
    if (with_index) try raw.exec(objects.object_chunks_chunk_hash_index_sql);
    try loadBackground(&raw, background_rows);
    var db = objects.Database.initForPrototype(&raw, .main);

    const pages_before = try pragmaU64(&raw, "pragma page_count");
    var cache_write = DbStatus.read(&raw, objects.sqlite.c.SQLITE_DBSTATUS_CACHE_WRITE);
    var cache_spill = DbStatus.read(&raw, objects.sqlite.c.SQLITE_DBSTATUS_CACHE_SPILL);
    const put_start = now();
    var writer = try db.objectWriterWithOptions(std.heap.c_allocator, .{ .profile = profile });
    defer writer.deinit();
    const write_bytes = 1024 * 1024;
    var offset: usize = 0;
    while (offset < payload.len) {
        const len = @min(write_bytes, payload.len - offset);
        try writer.write(payload[offset .. offset + len]);
        offset += len;
    }
    const write_seconds = seconds(put_start);
    const id = try writer.finish();
    const put_seconds = seconds(put_start);
    cache_write = DbStatus.read(&raw, objects.sqlite.c.SQLITE_DBSTATUS_CACHE_WRITE) - cache_write;
    cache_spill = DbStatus.read(&raw, objects.sqlite.c.SQLITE_DBSTATUS_CACHE_SPILL) - cache_spill;
    const pages_after = try pragmaU64(&raw, "pragma page_count");
    const journal_bytes = fileSize(try std.fmt.allocPrint(arena, "{s}-journal", .{args[1]}));
    if (!std.mem.eql(u8, &objects.objectId(payload), &id)) return error.HashMismatch;

    const manifest_rows = try pragmaU64(&raw, "select count(*) from _zova_object_chunks");
    const index_bytes: u64 = if (with_index)
        try pragmaU64(&raw, "select coalesce(sum(pgsize), 0) from dbstat where name = '_zova_object_chunks_chunk_hash_idx'")
    else
        0;

    const delete_start = now();
    try db.deleteObject(id);
    const delete_seconds = seconds(delete_start);
    const free_pages = try pragmaU64(&raw, "pragma freelist_count");

    var reclaim_seconds: f64 = 0;
    var released: u64 = 0;
    if (incremental) {
        const reclaim_start = now();
        while (true) {
            const free = try pragmaU64(&raw, "pragma freelist_count");
            if (free == 0) break;
            var sql_buffer: [64]u8 = undefined;
            const sql = try std.fmt.bufPrintSentinel(&sql_buffer, "pragma incremental_vacuum({d})", .{@min(free, 1024)}, 0);
            try raw.exec("begin immediate");
            try raw.exec(sql);
            try raw.exec("commit");
            const left = try pragmaU64(&raw, "pragma freelist_count");
            if (left >= free) break;
            released += free - left;
        }
        reclaim_seconds = seconds(reclaim_start);
    }

    std.debug.print(
        "index={s} auto_vacuum={s} background_rows={d} profile={s} payload_bytes={d} manifest_rows={d} index_bytes={d} put_seconds={d:.4} delete_seconds={d:.4} free_pages={d} reclaim_pages={d} reclaim_seconds={d:.4} write_seconds={d:.4} finish_seconds={d:.4} pages_before_put={d} pages_after_put={d} put_cache_write={d} put_cache_spill={d} journal_bytes_after_put={d}\n",
        .{ args[2], args[3], background_rows, args[5], total_bytes, manifest_rows, index_bytes, put_seconds, delete_seconds, free_pages, released, reclaim_seconds, write_seconds, put_seconds - write_seconds, pages_before, pages_after, cache_write, cache_spill, journal_bytes },
    );
}
