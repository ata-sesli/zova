//! Public-only C ABI behavior tests. No private implementation helpers.

const std = @import("std");
const zova_database = @import("c_api_internal.zig").zova_database;
const zova_database_close = @import("c_api_internal.zig").zova_database_close;
const zova_database_create = @import("c_api_internal.zig").zova_database_create;
const zova_database_begin = @import("c_api_internal.zig").zova_database_begin;
const zova_database_begin_immediate = @import("c_api_internal.zig").zova_database_begin_immediate;
const zova_database_commit = @import("c_api_internal.zig").zova_database_commit;
const zova_database_exec = @import("c_api_internal.zig").zova_database_exec;
const zova_database_rollback = @import("c_api_internal.zig").zova_database_rollback;
const zova_database_simple_request = @import("c_api_internal.zig").zova_database_simple_request;
const zova_object_chunk_id = @import("c_api_internal.zig").zova_object_chunk_id;
const zova_object_chunk_id_from_bytes = @import("c_api_internal.zig").zova_object_chunk_id_from_bytes;
const zova_object_chunk_put_with_options = @import("c_api_internal.zig").zova_object_chunk_put_with_options;
const zova_object_id = @import("c_api_internal.zig").zova_object_id;
const zova_object_manifest = @import("c_api_internal.zig").zova_object_manifest;
const zova_object_manifest_free = @import("c_api_internal.zig").zova_object_manifest_free;
const zova_object_manifest_get = @import("c_api_internal.zig").zova_object_manifest_get;
const zova_object_exists = @import("c_api_internal.zig").zova_object_exists;
const zova_object_put = @import("c_api_internal.zig").zova_object_put;
const zova_object_put_with_options = @import("c_api_internal.zig").zova_object_put_with_options;
const zova_object_reader = @import("c_api_internal.zig").zova_object_reader;
const zova_object_reader_create = @import("c_api_internal.zig").zova_object_reader_create;
const zova_object_reader_destroy = @import("c_api_internal.zig").zova_object_reader_destroy;
const zova_object_reader_read = @import("c_api_internal.zig").zova_object_reader_read;
const zova_object_size = @import("c_api_internal.zig").zova_object_size;
const zova_object_storage_profile = @import("c_api_internal.zig").zova_object_storage_profile;
const zova_object_writer = @import("c_api_internal.zig").zova_object_writer;
const zova_object_writer_create = @import("c_api_internal.zig").zova_object_writer_create;
const zova_object_writer_create_with_options = @import("c_api_internal.zig").zova_object_writer_create_with_options;
const zova_object_writer_destroy = @import("c_api_internal.zig").zova_object_writer_destroy;
const zova_object_writer_finish = @import("c_api_internal.zig").zova_object_writer_finish;
const zova_object_writer_write = @import("c_api_internal.zig").zova_object_writer_write;
const zova_status = @import("c_api_internal.zig").zova_status;

test "c abi object profile options and sequential reader preserve compatibility" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-object-options.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    const bytes = "option-bearing object payload";
    var id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.OK, zova_object_put_with_options(&.{
        .db = db,
        .data = bytes,
        .len = bytes.len,
        .options = .{ .profile = @intFromEnum(zova_object_storage_profile.DEDUPLICATION) },
        .out_id = &id,
    }));

    var manifest = std.mem.zeroes(zova_object_manifest);
    defer zova_object_manifest_free(&manifest);
    try std.testing.expectEqual(zova_status.OK, zova_object_manifest_get(&.{
        .db = db,
        .id = id,
        .out_manifest = &manifest,
    }));
    try std.testing.expectEqualStrings("fastcdc-v1", std.mem.span(manifest.chunker.?));

    var reader: ?*zova_object_reader = null;
    try std.testing.expectEqual(zova_status.OK, zova_object_reader_create(&.{
        .db = db,
        .id = id,
        .out_reader = &reader,
    }));
    try std.testing.expect(reader != null);

    var output: [bytes.len]u8 = undefined;
    var copied: usize = 0;
    try std.testing.expectEqual(zova_status.OK, zova_object_reader_read(&.{
        .reader = reader,
        .buffer = &output,
        .buffer_len = output.len,
        .out_read = &copied,
    }));
    try std.testing.expectEqual(bytes.len, copied);
    try std.testing.expectEqualStrings(bytes, &output);
    try std.testing.expectEqual(zova_status.MISUSE, zova_database_close(db));
    try std.testing.expectEqual(zova_status.OK, zova_object_reader_destroy(&.{ .reader = &reader }));
    try std.testing.expectEqual(zova_status.OK, zova_object_reader_destroy(&.{ .reader = &reader }));

    const loose = "option-bearing loose chunk";
    var loose_hash = zova_object_chunk_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.OK, zova_object_chunk_id_from_bytes(loose, loose.len, &loose_hash));
    try std.testing.expectEqual(zova_status.OK, zova_object_chunk_put_with_options(&.{
        .db = db,
        .expected_hash = loose_hash,
        .data = loose,
        .len = loose.len,
        .options = .{ .profile = @intFromEnum(zova_object_storage_profile.DEDUPLICATION) },
    }));

    var writer: ?*zova_object_writer = null;
    try std.testing.expectEqual(zova_status.OK, zova_object_writer_create_with_options(&.{
        .db = db,
        .options = .{ .profile = @intFromEnum(zova_object_storage_profile.DEDUPLICATION) },
        .out_writer = &writer,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_object_writer_write(&.{
        .writer = writer,
        .data = bytes,
        .len = bytes.len,
    }));
    var writer_id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.OK, zova_object_writer_finish(&.{
        .writer = writer,
        .out_id = &writer_id,
    }));
    try std.testing.expectEqual(id, writer_id);
    try std.testing.expectEqual(zova_status.OK, zova_object_writer_destroy(writer));

    var invalid_id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_object_put_with_options(&.{
        .db = db,
        .data = bytes,
        .len = bytes.len,
        .options = .{ .profile = 99 },
        .out_id = &invalid_id,
    }));
    try std.testing.expectEqual(@as(zova_object_id, .{ .bytes = [_]u8{0} ** 32 }), invalid_id);
}

test "c abi serializes concurrent object writer writes on one writer" {
    const Worker = struct {
        const payload = "x";
        const writes_per_worker = 64;

        writer: ?*zova_object_writer,
        status: zova_status = .OK,

        fn run(ctx: *@This()) void {
            for (0..writes_per_worker) |_| {
                ctx.status = zova_object_writer_write(&.{
                    .writer = ctx.writer,
                    .data = payload.ptr,
                    .len = payload.len,
                });
                if (ctx.status != .OK) return;
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-threaded-writer.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    var writer: ?*zova_object_writer = null;
    try std.testing.expectEqual(zova_status.OK, zova_object_writer_create(&.{
        .db = db,
        .out_writer = &writer,
    }));
    defer _ = zova_object_writer_destroy(writer);

    var contexts: [8]Worker = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    for (&contexts) |*context| {
        context.* = .{ .writer = writer };
    }
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{context});
    }
    for (threads) |thread| thread.join();
    for (contexts) |context| try std.testing.expectEqual(zova_status.OK, context.status);

    var object_id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.OK, zova_object_writer_finish(&.{
        .writer = writer,
        .out_id = &object_id,
    }));

    var size: u64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_object_size(&.{
        .db = db,
        .id = object_id,
        .out_size = &size,
    }));
    try std.testing.expectEqual(@as(u64, contexts.len * Worker.writes_per_worker * Worker.payload.len), size);
}

test "c abi object put commits atomically with a caller sql transaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-object-transaction.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    const simple = zova_database_simple_request{ .db = db };
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "create table committed_refs (object_id blob not null)",
    }));
    const exists = struct {
        fn check(handle: *zova_database, id: zova_object_id) !bool {
            var found: u8 = 1;
            try std.testing.expectEqual(zova_status.OK, zova_object_exists(&.{
                .db = handle,
                .id = id,
                .out_exists = &found,
            }));
            return found != 0;
        }
    }.check;

    const Profiles = struct { name: [:0]const u8, profile: zova_object_storage_profile };
    for ([_]Profiles{
        .{ .name = "committed fastcdc", .profile = .DEDUPLICATION },
        .{ .name = "committed fixed", .profile = .STREAMING },
    }) |case| {
        // The object and the caller's SQL reference commit together.
        try std.testing.expectEqual(zova_status.OK, zova_database_begin(&simple));
        var id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
        try std.testing.expectEqual(zova_status.OK, zova_object_put_with_options(&.{
            .db = db,
            .data = case.name.ptr,
            .len = case.name.len,
            .options = .{ .profile = @intFromEnum(case.profile) },
            .out_id = &id,
        }));
        try std.testing.expectEqual(zova_status.OK, zova_database_commit(&simple));
        try std.testing.expect(try exists(db.?, id));
    }

    // A caller rollback removes the object written in that transaction.
    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&simple));
    var rolled_back = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.OK, zova_object_put(&.{
        .db = db,
        .data = "rolled back object",
        .len = "rolled back object".len,
        .out_id = &rolled_back,
    }));
    try std.testing.expect(try exists(db.?, rolled_back));
    try std.testing.expectEqual(zova_status.OK, zova_database_rollback(&simple));
    try std.testing.expect(!try exists(db.?, rolled_back));

    // A failing object put discards only its own partial work: the caller's
    // earlier SQL survives, the caller transaction stays open, and nothing of
    // the failed object remains after the caller commits.
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "create trigger reject_manifest before insert on _zova_object_chunks " ++
            "begin select raise(abort, 'injected manifest failure'); end",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&simple));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "create table caller_work (id integer primary key)",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "insert into caller_work (id) values (1)",
    }));
    var failed = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.CONSTRAINT, zova_object_put(&.{
        .db = db,
        .data = "partially written object",
        .len = "partially written object".len,
        .out_id = &failed,
    }));
    // The caller transaction is still open, so its commit still succeeds.
    try std.testing.expectEqual(zova_status.OK, zova_database_commit(&simple));
    try std.testing.expect(!try exists(db.?, failed));

    // The caller's earlier work survived the failed object put.
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "insert into caller_work (id) values (2)",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "drop trigger reject_manifest",
    }));
}
