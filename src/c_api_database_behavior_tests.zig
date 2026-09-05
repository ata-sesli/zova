//! Public-only C ABI behavior tests. No private implementation helpers.

const ZOVA_OPEN_READ_ONLY = @import("c_api_internal.zig").ZOVA_OPEN_READ_ONLY;
const std = @import("std");
const zova_abi_version_major = @import("c_api_internal.zig").zova_abi_version_major;
const zova_abi_version_minor = @import("c_api_internal.zig").zova_abi_version_minor;
const zova_abi_version_patch = @import("c_api_internal.zig").zova_abi_version_patch;
const zova_abi_version_string = @import("c_api_internal.zig").zova_abi_version_string;
const zova_database = @import("c_api_internal.zig").zova_database;
const zova_database_begin_immediate = @import("c_api_internal.zig").zova_database_begin_immediate;
const zova_database_close = @import("c_api_internal.zig").zova_database_close;
const zova_database_commit = @import("c_api_internal.zig").zova_database_commit;
const zova_database_create = @import("c_api_internal.zig").zova_database_create;
const zova_database_create_with_extensions = @import("c_api_internal.zig").zova_database_create_with_extensions;
const zova_database_exec = @import("c_api_internal.zig").zova_database_exec;
const zova_database_format_info = @import("c_api_internal.zig").zova_database_format_info;
const zova_database_last_error_message = @import("c_api_internal.zig").zova_database_last_error_message;
const zova_database_migrate = @import("c_api_internal.zig").zova_database_migrate;
const zova_database_open_request = @import("c_api_internal.zig").zova_database_open_request;
const zova_database_open_with_extensions = @import("c_api_internal.zig").zova_database_open_with_extensions;
const zova_database_open_with_options = @import("c_api_internal.zig").zova_database_open_with_options;
const zova_database_prepare = @import("c_api_internal.zig").zova_database_prepare;
const zova_database_probe_format = @import("c_api_internal.zig").zova_database_probe_format;
const zova_database_release_savepoint = @import("c_api_internal.zig").zova_database_release_savepoint;
const zova_database_rollback = @import("c_api_internal.zig").zova_database_rollback;
const zova_database_rollback_to_savepoint = @import("c_api_internal.zig").zova_database_rollback_to_savepoint;
const zova_database_savepoint = @import("c_api_internal.zig").zova_database_savepoint;
const zova_extension_bundle_trust = @import("c_api_internal.zig").zova_extension_bundle_trust;
const zova_extension_bundle_untrust = @import("c_api_internal.zig").zova_extension_bundle_untrust;
const zova_extension_bundle_verify = @import("c_api_internal.zig").zova_extension_bundle_verify;
const zova_message = @import("c_api_internal.zig").zova_message;
const zova_message_free = @import("c_api_internal.zig").zova_message_free;
const zova_object_writer = @import("c_api_internal.zig").zova_object_writer;
const zova_object_writer_create = @import("c_api_internal.zig").zova_object_writer_create;
const zova_object_writer_destroy = @import("c_api_internal.zig").zova_object_writer_destroy;
const zova_statement = @import("c_api_internal.zig").zova_statement;
const zova_statement_column_int64 = @import("c_api_internal.zig").zova_statement_column_int64;
const zova_statement_finalize = @import("c_api_internal.zig").zova_statement_finalize;
const zova_statement_step = @import("c_api_internal.zig").zova_statement_step;
const zova_status = @import("c_api_internal.zig").zova_status;
const zova_status_name = @import("c_api_internal.zig").zova_status_name;
const zova_step_result = @import("c_api_internal.zig").zova_step_result;
const zova_version = @import("version.zig");

test "c abi status names and versions are stable" {
    try std.testing.expectEqual(zova_version.abi_version_major, zova_abi_version_major());
    try std.testing.expectEqual(zova_version.abi_version_minor, zova_abi_version_minor());
    try std.testing.expectEqual(zova_version.abi_version_patch, zova_abi_version_patch());
    try std.testing.expectEqualStrings(zova_version.abi_version_string, std.mem.span(zova_abi_version_string()));
    try std.testing.expectEqualStrings("ZOVA_OK", std.mem.span(zova_status_name(@intFromEnum(zova_status.OK))));
    try std.testing.expectEqualStrings("ZOVA_OBJECT_NOT_FOUND", std.mem.span(zova_status_name(@intFromEnum(zova_status.OBJECT_NOT_FOUND))));
    try std.testing.expectEqualStrings("ZOVA_BOUND_STORE_INVALID", std.mem.span(zova_status_name(@intFromEnum(zova_status.BOUND_STORE_INVALID))));
    try std.testing.expectEqualStrings("ZOVA_VECTOR_INVALID", std.mem.span(zova_status_name(@intFromEnum(zova_status.VECTOR_INVALID))));
    try std.testing.expectEqualStrings("ZOVA_GRAPH_INVALID", std.mem.span(zova_status_name(@intFromEnum(zova_status.GRAPH_INVALID))));
    try std.testing.expectEqualStrings("ZOVA_EXTENSION_UNAVAILABLE", std.mem.span(zova_status_name(@intFromEnum(zova_status.EXTENSION_UNAVAILABLE))));
    try std.testing.expectEqualStrings("ZOVA_MIGRATION_REQUIRED", std.mem.span(zova_status_name(@intFromEnum(zova_status.MIGRATION_REQUIRED))));
    try std.testing.expectEqualStrings("ZOVA_UNSUPPORTED_FUTURE_FORMAT", std.mem.span(zova_status_name(@intFromEnum(zova_status.UNSUPPORTED_FUTURE_FORMAT))));
    try std.testing.expectEqualStrings("ZOVA_UNSUPPORTED_LEGACY_FORMAT", std.mem.span(zova_status_name(@intFromEnum(zova_status.UNSUPPORTED_LEGACY_FORMAT))));
    try std.testing.expectEqualStrings("ZOVA_NO_MIGRATION_PATH", std.mem.span(zova_status_name(@intFromEnum(zova_status.NO_MIGRATION_PATH))));
    try std.testing.expectEqualStrings("ZOVA_UNKNOWN_STATUS", std.mem.span(zova_status_name(-1)));
}

test "c abi probe and migrate validate pointers paths flags and zero output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dummy_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/probe-dummy.zova", .{tmp.sub_path[0..]});

    // Probe: null out_info
    {
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        var out: zova_database_format_info = undefined;
        out.format_version = 0xdeadbeef;
        out.compatibility = 0x7fffffff;
        try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_probe_format(&.{
            .path = dummy_path,
            .out_info = null,
            .out_error_message = &msg,
        }));
    }
    // Probe: null path
    {
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        var out: zova_database_format_info = undefined;
        out.format_version = 0xdeadbeef;
        out.compatibility = 0x7fffffff;
        try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_probe_format(&.{
            .path = null,
            .out_info = &out,
            .out_error_message = &msg,
        }));
        try std.testing.expectEqual(@as(u32, 0), out.format_version);
        try std.testing.expectEqual(@as(c_int, 0), out.compatibility);
    }
    // Probe: path without .zova suffix -> NOT_ZOVA_PATH, zeroed
    {
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        var out: zova_database_format_info = undefined;
        out.format_version = 0xdeadbeef;
        out.compatibility = 0x7fffffff;
        var bad_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const bad_path = try std.fmt.bufPrintZ(&bad_buffer, ".zig-cache/tmp/{s}/bad.txt", .{tmp.sub_path[0..]});
        try std.testing.expectEqual(zova_status.NOT_ZOVA_PATH, zova_database_probe_format(&.{
            .path = bad_path,
            .out_info = &out,
            .out_error_message = &msg,
        }));
        try std.testing.expectEqual(@as(u32, 0), out.format_version);
        try std.testing.expectEqual(@as(c_int, 0), out.compatibility);
    }
    // Migrate: null source
    {
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_migrate(&.{
            .source_path = null,
            .destination_path = dummy_path,
            .flags = 0,
            .out_error_message = &msg,
        }));
    }
    // Migrate: null destination
    {
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_migrate(&.{
            .source_path = dummy_path,
            .destination_path = null,
            .flags = 0,
            .out_error_message = &msg,
        }));
    }
    // Migrate: invalid flags
    {
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_migrate(&.{
            .source_path = dummy_path,
            .destination_path = dummy_path,
            .flags = 0xdeadbeef,
            .out_error_message = &msg,
        }));
    }
}

test "c abi validates external extension bundle requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-external-extension-validation.zova", .{tmp.sub_path[0..]});
    var message = zova_message{ .data = null, .len = 0 };
    defer zova_message_free(&message);

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_extension_bundle_verify(&.{
        .bundle_path = null,
        .trust_store_path = null,
        .out_error_message = &message,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_extension_bundle_trust(&.{
        .bundle_path = null,
        .trust_store_path = null,
        .out_error_message = &message,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_extension_bundle_untrust(&.{
        .identifier = null,
        .trust_store_path = null,
        .out_removed = null,
        .out_error_message = &message,
    }));

    var db: ?*zova_database = null;
    const null_bundles = [_]?[*:0]const u8{null};
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_create_with_extensions(&.{
        .path = db_path,
        .flags = 0,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = null,
        .extension_bundle_count = 1,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_open_with_extensions(&.{
        .path = db_path,
        .flags = 0,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = &null_bundles,
        .extension_bundle_count = 1,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_create_with_extensions(&.{
        .path = db_path,
        .flags = ZOVA_OPEN_READ_ONLY,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = null,
        .extension_bundle_count = 0,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));

    try std.testing.expectEqual(zova_status.OK, zova_database_create_with_extensions(&.{
        .path = db_path,
        .flags = 0,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = null,
        .extension_bundle_count = 0,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));
    try std.testing.expect(db != null);
    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
    db = null;

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_open_with_extensions(&.{
        .path = db_path,
        .flags = 0xffff_ffff,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = null,
        .extension_bundle_count = 0,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_open_with_extensions(&.{
        .path = db_path,
        .flags = 0,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = null,
        .extension_bundle_count = 0,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));
    try std.testing.expect(db != null);
    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
}

test "c abi no-handle create error can return owned message" {
    var message = zova_message{ .data = null, .len = 0 };
    var db: ?*zova_database = null;
    const request = zova_database_open_request{
        .path = "not-zova.db",
        .out_db = &db,
        .out_error_message = &message,
    };
    try std.testing.expectEqual(zova_status.NOT_ZOVA_PATH, zova_database_create(&request));
    try std.testing.expect(db == null);
    try std.testing.expect(message.data != null);
    try std.testing.expect(message.len > 0);
    zova_message_free(&message);
}

test "c abi exposes savepoint helpers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-savepoint.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "create table notes (body text not null)" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "insert into notes (body) values ('outer')" }));

    try std.testing.expectEqual(zova_status.OK, zova_database_savepoint(&.{ .db = db, .name = "sp_one" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "insert into notes (body) values ('rolled back')" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_rollback_to_savepoint(&.{ .db = db, .name = "sp_one" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_release_savepoint(&.{ .db = db, .name = "sp_one" }));

    try std.testing.expectEqual(zova_status.OK, zova_database_savepoint(&.{ .db = db, .name = "sp_two" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "insert into notes (body) values ('released')" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_release_savepoint(&.{ .db = db, .name = "sp_two" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_commit(&.{ .db = db }));

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_savepoint(&.{ .db = db, .name = "bad name" }));
    try std.testing.expectEqual(zova_status.SQLITE_ERROR, zova_database_release_savepoint(&.{ .db = db, .name = "missing_sp" }));
    const message = std.mem.span(zova_database_last_error_message(db));
    try std.testing.expect(std.mem.indexOf(u8, message, "no such savepoint") != null);

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select count(*) from notes where body = 'rolled back'",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = stmt, .out_result = &step_result }));
    var count: i64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = stmt, .index = 0, .out_value = &count }));
    try std.testing.expectEqual(@as(i64, 0), count);
}

test "c abi rejects database close while statement or writer children are live" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-live-children.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select 1",
        .out_statement = &stmt,
    }));

    try std.testing.expectEqual(zova_status.MISUSE, zova_database_close(db));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zova_database_last_error_message(db)), "live child") != null);

    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{
        .statement = stmt,
        .out_result = &step_result,
    }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    try std.testing.expectEqual(zova_status.OK, zova_statement_finalize(stmt));

    var writer: ?*zova_object_writer = null;
    try std.testing.expectEqual(zova_status.OK, zova_object_writer_create(&.{
        .db = db,
        .out_writer = &writer,
    }));

    try std.testing.expectEqual(zova_status.MISUSE, zova_database_close(db));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zova_database_last_error_message(db)), "live child") != null);

    try std.testing.expectEqual(zova_status.OK, zova_object_writer_destroy(writer));
    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
}

test "c abi serializes concurrent sql calls on one database handle" {
    const Worker = struct {
        const inserts_per_worker = 24;

        db: ?*zova_database,
        worker_index: usize,
        status: zova_status = .OK,

        fn run(ctx: *@This()) void {
            var sql_buffer: [160]u8 = undefined;
            for (0..inserts_per_worker) |insert_index| {
                const sql = std.fmt.bufPrintZ(
                    &sql_buffer,
                    "insert into records (worker, item) values ({d}, {d})",
                    .{ ctx.worker_index, insert_index },
                ) catch {
                    ctx.status = .OUT_OF_MEMORY;
                    return;
                };
                const status = zova_database_exec(&.{ .db = ctx.db, .sql = sql.ptr });
                if (status != .OK) {
                    ctx.status = status;
                    return;
                }
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-threaded-sql.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "create table records (worker integer not null, item integer not null)" }));

    var contexts: [8]Worker = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    for (&contexts, 0..) |*context, index| {
        context.* = .{ .db = db, .worker_index = index };
    }
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{context});
    }
    for (threads) |thread| thread.join();
    for (contexts) |context| try std.testing.expectEqual(zova_status.OK, context.status);

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select count(*) from records",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);

    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);

    var count: i64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = stmt, .index = 0, .out_value = &count }));
    try std.testing.expectEqual(@as(i64, contexts.len * Worker.inserts_per_worker), count);
}

test "c abi multi-handle write contention returns busy or locked with short timeout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-multi-handle-busy.zova", .{tmp.sub_path[0..]});

    var first: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &first,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(first);
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = first, .sql = "create table records (body text not null)" }));

    var second: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_open_with_options(&.{
        .path = db_path,
        .flags = 0,
        .busy_timeout_ms = 1,
        .out_db = &second,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(second);

    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = first }));
    defer _ = zova_database_rollback(&.{ .db = first });

    const status = zova_database_begin_immediate(&.{ .db = second });
    try std.testing.expect(status == .BUSY or status == .LOCKED);
}

test "c abi last error remains useful after concurrent serialized failures" {
    const Worker = struct {
        db: ?*zova_database,
        status: zova_status = .OK,

        fn run(ctx: *@This()) void {
            ctx.status = zova_database_exec(&.{ .db = ctx.db, .sql = "select * from no_such_table" });
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-threaded-errors.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    var contexts: [6]Worker = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    for (&contexts) |*context| {
        context.* = .{ .db = db };
    }
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{context});
    }
    for (threads) |thread| thread.join();
    for (contexts) |context| try std.testing.expectEqual(zova_status.SQLITE_ERROR, context.status);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zova_database_last_error_message(db)), "no_such_table") != null);
}
