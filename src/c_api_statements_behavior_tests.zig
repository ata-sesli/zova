//! Public-only C ABI behavior tests. No private implementation helpers.

const std = @import("std");
const zova = @import("zova.zig");
const zova_buffer = @import("c_api_internal.zig").zova_buffer;
const zova_buffer_free = @import("c_api_internal.zig").zova_buffer_free;
const zova_column_type = @import("c_api_internal.zig").zova_column_type;
const zova_database = @import("c_api_internal.zig").zova_database;
const zova_database_changes = @import("c_api_internal.zig").zova_database_changes;
const zova_database_close = @import("c_api_internal.zig").zova_database_close;
const zova_database_create = @import("c_api_internal.zig").zova_database_create;
const zova_database_exec = @import("c_api_internal.zig").zova_database_exec;
const zova_database_last_error_message = @import("c_api_internal.zig").zova_database_last_error_message;
const zova_database_last_insert_rowid = @import("c_api_internal.zig").zova_database_last_insert_rowid;
const zova_database_open = @import("c_api_internal.zig").zova_database_open;
const zova_database_open_request = @import("c_api_internal.zig").zova_database_open_request;
const zova_database_prepare = @import("c_api_internal.zig").zova_database_prepare;
const zova_database_prepare_request = @import("c_api_internal.zig").zova_database_prepare_request;
const zova_database_total_changes = @import("c_api_internal.zig").zova_database_total_changes;
const zova_statement = @import("c_api_internal.zig").zova_statement;
const zova_statement_bind_blob = @import("c_api_internal.zig").zova_statement_bind_blob;
const zova_statement_bind_double = @import("c_api_internal.zig").zova_statement_bind_double;
const zova_statement_bind_int64 = @import("c_api_internal.zig").zova_statement_bind_int64;
const zova_statement_bind_null = @import("c_api_internal.zig").zova_statement_bind_null;
const zova_statement_bind_text = @import("c_api_internal.zig").zova_statement_bind_text;
const zova_statement_clear_bindings = @import("c_api_internal.zig").zova_statement_clear_bindings;
const zova_statement_column_blob = @import("c_api_internal.zig").zova_statement_column_blob;
const zova_statement_column_count = @import("c_api_internal.zig").zova_statement_column_count;
const zova_statement_column_double = @import("c_api_internal.zig").zova_statement_column_double;
const zova_statement_column_int64 = @import("c_api_internal.zig").zova_statement_column_int64;
const zova_statement_column_name = @import("c_api_internal.zig").zova_statement_column_name;
const zova_statement_column_text = @import("c_api_internal.zig").zova_statement_column_text;
const zova_statement_column_type = @import("c_api_internal.zig").zova_statement_column_type;
const zova_statement_finalize = @import("c_api_internal.zig").zova_statement_finalize;
const zova_statement_parameter_count = @import("c_api_internal.zig").zova_statement_parameter_count;
const zova_statement_parameter_index = @import("c_api_internal.zig").zova_statement_parameter_index;
const zova_statement_reset = @import("c_api_internal.zig").zova_statement_reset;
const zova_statement_step = @import("c_api_internal.zig").zova_statement_step;
const zova_status = @import("c_api_internal.zig").zova_status;
const zova_step_result = @import("c_api_internal.zig").zova_step_result;
const zova_text = @import("c_api_internal.zig").zova_text;
const zova_text_free = @import("c_api_internal.zig").zova_text_free;

test "c abi exposes sql record helper functions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-record-helpers.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "create table records (id integer primary key, name text not null)" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "insert into records (name) values ('one')" }));

    var rowid: i64 = 0;
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_last_insert_rowid(&.{ .db = db, .out_rowid = null }));
    try std.testing.expectEqual(zova_status.OK, zova_database_last_insert_rowid(&.{ .db = db, .out_rowid = &rowid }));
    try std.testing.expectEqual(@as(i64, 1), rowid);

    var changes: i64 = 0;
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_changes(&.{ .db = db, .out_changes = null }));
    try std.testing.expectEqual(zova_status.OK, zova_database_changes(&.{ .db = db, .out_changes = &changes }));
    try std.testing.expectEqual(@as(i64, 1), changes);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "update records set name = 'two' where id = 1" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_changes(&.{ .db = db, .out_changes = &changes }));
    try std.testing.expectEqual(@as(i64, 1), changes);

    var total_changes: i64 = 0;
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_total_changes(&.{ .db = db, .out_total_changes = null }));
    try std.testing.expectEqual(zova_status.OK, zova_database_total_changes(&.{ .db = db, .out_total_changes = &total_changes }));
    try std.testing.expect(total_changes >= 2);

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select id as record_id, name from records",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);

    var name = zova_text{ .data = null, .len = 0 };
    defer zova_text_free(&name);
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_column_name(&.{ .statement = stmt, .index = 0, .out_name = null }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_name(&.{ .statement = stmt, .index = 0, .out_name = &name }));
    try std.testing.expectEqualStrings("record_id", name.data.?[0..name.len]);
    zova_text_free(&name);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_name(&.{ .statement = stmt, .index = 1, .out_name = &name }));
    try std.testing.expectEqualStrings("name", name.data.?[0..name.len]);
    try std.testing.expectEqual(zova_status.MISUSE, zova_statement_column_name(&.{ .statement = stmt, .index = 2, .out_name = &name }));
}

test "c abi exposes prepared statement sql lifecycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-statements.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));
    defer _ = zova_database_close(db);

    var bad_stmt: ?*zova_statement = null;
    const bad_prepare = zova_database_prepare_request{
        .db = db,
        .sql = "select from definitely invalid sql",
        .out_statement = &bad_stmt,
    };
    try std.testing.expectEqual(zova_status.SQLITE_ERROR, zova_database_prepare(&bad_prepare));
    try std.testing.expect(bad_stmt == null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zova_database_last_error_message(db)), "syntax") != null);

    var create_stmt: ?*zova_statement = null;
    const prepare_create = zova_database_prepare_request{
        .db = db,
        .sql = "create table records (id integer primary key, i integer, r real, t text, b blob, n text)",
        .out_statement = &create_stmt,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&prepare_create));
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{
        .statement = create_stmt,
        .out_result = &step_result,
    }));
    try std.testing.expectEqual(zova_step_result.DONE, step_result);
    try std.testing.expectEqual(zova_status.OK, zova_statement_finalize(create_stmt));

    var insert_stmt: ?*zova_statement = null;
    const prepare_insert = zova_database_prepare_request{
        .db = db,
        .sql = "insert into records (i, r, t, b, n) values (:i, :r, :t, :b, :n)",
        .out_statement = &insert_stmt,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&prepare_insert));
    defer _ = zova_statement_finalize(insert_stmt);

    var param_count: i32 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_parameter_count(&.{
        .statement = insert_stmt,
        .out_count = &param_count,
    }));
    try std.testing.expectEqual(@as(i32, 5), param_count);

    var text_index: i32 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_parameter_index(&.{
        .statement = insert_stmt,
        .name = ":t",
        .out_index = &text_index,
    }));
    try std.testing.expectEqual(@as(i32, 3), text_index);

    const text = "hello";
    const blob = [_]u8{ 0, 1, 2, 3 };
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_int64(&.{ .statement = insert_stmt, .index = 1, .value = 42 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_double(&.{ .statement = insert_stmt, .index = 2, .value = 3.5 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_text(&.{ .statement = insert_stmt, .index = 3, .data = text.ptr, .len = text.len }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_blob(&.{ .statement = insert_stmt, .index = 4, .data = &blob, .len = blob.len }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_null(&.{ .statement = insert_stmt, .index = 5 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = insert_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.DONE, step_result);

    try std.testing.expectEqual(zova_status.OK, zova_statement_reset(insert_stmt));
    try std.testing.expectEqual(zova_status.OK, zova_statement_clear_bindings(insert_stmt));
    const empty = "";
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_int64(&.{ .statement = insert_stmt, .index = 1, .value = 7 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_double(&.{ .statement = insert_stmt, .index = 2, .value = 0.25 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_text(&.{ .statement = insert_stmt, .index = 3, .data = empty.ptr, .len = 0 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_blob(&.{ .statement = insert_stmt, .index = 4, .data = empty.ptr, .len = 0 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_null(&.{ .statement = insert_stmt, .index = 5 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = insert_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.DONE, step_result);

    var select_stmt: ?*zova_statement = null;
    const prepare_select = zova_database_prepare_request{
        .db = db,
        .sql = "select i, r, t, b, n from records order by id",
        .out_statement = &select_stmt,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&prepare_select));
    defer _ = zova_statement_finalize(select_stmt);

    var column_count: i32 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_count(&.{ .statement = select_stmt, .out_count = &column_count }));
    try std.testing.expectEqual(@as(i32, 5), column_count);

    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = select_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);

    var column_type: zova_column_type = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_type(&.{ .statement = select_stmt, .index = 0, .out_type = &column_type }));
    try std.testing.expectEqual(zova_column_type.INTEGER, column_type);

    var int_value: i64 = 0;
    var double_value: f64 = 0;
    var text_value = zova_text{ .data = null, .len = 0 };
    var blob_value = zova_buffer{ .data = null, .len = 0 };
    defer zova_text_free(&text_value);
    defer zova_buffer_free(&blob_value);

    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = select_stmt, .index = 0, .out_value = &int_value }));
    try std.testing.expectEqual(@as(i64, 42), int_value);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_double(&.{ .statement = select_stmt, .index = 1, .out_value = &double_value }));
    try std.testing.expectEqual(@as(f64, 3.5), double_value);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_text(&.{ .statement = select_stmt, .index = 2, .out_text = &text_value }));
    try std.testing.expectEqualStrings("hello", text_value.data.?[0..text_value.len]);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_blob(&.{ .statement = select_stmt, .index = 3, .out_buffer = &blob_value }));
    try std.testing.expectEqualSlices(u8, &blob, blob_value.data.?[0..blob_value.len]);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_type(&.{ .statement = select_stmt, .index = 4, .out_type = &column_type }));
    try std.testing.expectEqual(zova_column_type.NULL, column_type);

    zova_text_free(&text_value);
    zova_buffer_free(&blob_value);
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = select_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_text(&.{ .statement = select_stmt, .index = 2, .out_text = &text_value }));
    try std.testing.expect(text_value.data != null);
    try std.testing.expectEqual(@as(usize, 0), text_value.len);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_blob(&.{ .statement = select_stmt, .index = 3, .out_buffer = &blob_value }));
    try std.testing.expectEqual(@as(usize, 0), blob_value.len);
}

test "c abi serializes concurrent statement metadata calls on one statement" {
    const Worker = struct {
        const calls_per_worker = 32;

        statement: ?*zova_statement,
        status: zova_status = .OK,

        fn run(ctx: *@This()) void {
            for (0..calls_per_worker) |_| {
                var column_count: i32 = 0;
                var column_name = zova_text{ .data = null, .len = 0 };
                defer zova_text_free(&column_name);

                ctx.status = zova_statement_column_count(&.{
                    .statement = ctx.statement,
                    .out_count = &column_count,
                });
                if (ctx.status != .OK) return;
                if (column_count != 2) {
                    ctx.status = .MISUSE;
                    return;
                }

                ctx.status = zova_statement_column_name(&.{
                    .statement = ctx.statement,
                    .index = 0,
                    .out_name = &column_name,
                });
                if (ctx.status != .OK) return;
                if (!std.mem.eql(u8, column_name.data.?[0..column_name.len], "one")) {
                    ctx.status = .MISUSE;
                    return;
                }
                zova_text_free(&column_name);
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-threaded-statement.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select 1 as one, 2 as two",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);

    var contexts: [8]Worker = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    for (&contexts) |*context| {
        context.* = .{ .statement = stmt };
    }
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{context});
    }
    for (threads) |thread| thread.join();
    for (contexts) |context| try std.testing.expectEqual(zova_status.OK, context.status);
}

test "c abi can query bundled trgm SQL surface through prepared statements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-trgm.zova", .{tmp.sub_path[0..]});

    {
        var native = try zova.Database.create(db_path);
        defer native.deinit();
        try native.installExtension("trgm");
    }

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_open(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "select zova_trgm_create_index('docs')",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "select zova_trgm_put('docs', 'doc:1', 'record', 'messages', '1', 'attachment upload failed')",
    }));

    var similarity_stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select zova_trgm_similarity('attachment', 'attachement')",
        .out_statement = &similarity_stmt,
    }));
    defer _ = zova_statement_finalize(similarity_stmt);
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = similarity_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    var score: f64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_double(&.{ .statement = similarity_stmt, .index = 0, .out_value = &score }));
    try std.testing.expect(score > 0.5);

    var search_stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql =
        \\select document_id, score
        \\from zova_trgm_search
        \\where index_name = 'docs'
        \\  and query = 'attachement failed'
        \\  and "limit" = 1
        \\order by rank
        ,
        .out_statement = &search_stmt,
    }));
    defer _ = zova_statement_finalize(search_stmt);
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = search_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    var document_id = zova_text{ .data = null, .len = 0 };
    defer zova_text_free(&document_id);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_text(&.{ .statement = search_stmt, .index = 0, .out_text = &document_id }));
    try std.testing.expectEqualStrings("doc:1", document_id.data.?[0..document_id.len]);
}
