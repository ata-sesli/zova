//! Prepared statement execution, binding, and owned column results.

const std = @import("std");

const StatementHandle = @import("handles.zig").StatementHandle;
const allocator = @import("values.zig").allocator;
const bytesConst = @import("values.zig").bytesConst;
const columnTypeToAbi = @import("values.zig").columnTypeToAbi;
const databaseHandle = @import("handles.zig").databaseHandle;
const failDb = @import("errors.zig").failDb;
const okDb = @import("errors.zig").okDb;
const statementHandle = @import("handles.zig").statementHandle;
const zova_buffer_free = @import("results.zig").zova_buffer_free;
const zova_database_prepare_request = @import("types.zig").zova_database_prepare_request;
const zova_statement = @import("types.zig").zova_statement;
const zova_statement_bind_blob_request = @import("types.zig").zova_statement_bind_blob_request;
const zova_statement_bind_double_request = @import("types.zig").zova_statement_bind_double_request;
const zova_statement_bind_int64_request = @import("types.zig").zova_statement_bind_int64_request;
const zova_statement_bind_null_request = @import("types.zig").zova_statement_bind_null_request;
const zova_statement_bind_text_request = @import("types.zig").zova_statement_bind_text_request;
const zova_statement_column_blob_request = @import("types.zig").zova_statement_column_blob_request;
const zova_statement_column_count_request = @import("types.zig").zova_statement_column_count_request;
const zova_statement_column_double_request = @import("types.zig").zova_statement_column_double_request;
const zova_statement_column_int64_request = @import("types.zig").zova_statement_column_int64_request;
const zova_statement_column_name_request = @import("types.zig").zova_statement_column_name_request;
const zova_statement_column_text_request = @import("types.zig").zova_statement_column_text_request;
const zova_statement_column_type_request = @import("types.zig").zova_statement_column_type_request;
const zova_statement_parameter_count_request = @import("types.zig").zova_statement_parameter_count_request;
const zova_statement_parameter_index_request = @import("types.zig").zova_statement_parameter_index_request;
const zova_statement_step_request = @import("types.zig").zova_statement_step_request;
const zova_status = @import("types.zig").zova_status;
const zova_text_free = @import("results.zig").zova_text_free;

pub fn zova_database_prepare(request: ?*const zova_database_prepare_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const sql = req.sql orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_statement orelse return failDb(handle, error.InvalidArgument);
    out.* = null;

    const statement = handle.db.prepare(std.mem.span(sql)) catch |err| return failDb(handle, err);
    const statement_handle = allocator.create(StatementHandle) catch |err| {
        var cleanup = statement;
        cleanup.deinit();
        return failDb(handle, err);
    };
    statement_handle.* = .{ .db = handle, .statement = statement };
    handle.live_statements += 1;
    out.* = @ptrCast(statement_handle);
    return okDb(handle);
}

pub fn zova_statement_finalize(statement: ?*zova_statement) callconv(.c) zova_status {
    const handle = statementHandle(statement) orelse return .INVALID_ARGUMENT;
    const db_handle = handle.db;
    db_handle.mutex.lock();
    defer db_handle.mutex.unlock();
    handle.statement.deinit();
    std.debug.assert(db_handle.live_statements > 0);
    db_handle.live_statements -= 1;
    allocator.destroy(handle);
    return okDb(db_handle);
}

pub fn zova_statement_step(request: ?*const zova_statement_step_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_result orelse return failDb(handle.db, error.InvalidArgument);
    const result = handle.statement.step() catch |err| return failDb(handle.db, err);
    out.* = switch (result) {
        .row => .ROW,
        .done => .DONE,
    };
    return okDb(handle.db);
}

pub fn zova_statement_reset(statement: ?*zova_statement) callconv(.c) zova_status {
    const handle = statementHandle(statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.statement.reset() catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_clear_bindings(statement: ?*zova_statement) callconv(.c) zova_status {
    const handle = statementHandle(statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.statement.clearBindings() catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_bind_null(request: ?*const zova_statement_bind_null_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.statement.bindNull(req.index) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_bind_int64(request: ?*const zova_statement_bind_int64_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.statement.bindInt64(req.index, req.value) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_bind_double(request: ?*const zova_statement_bind_double_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.statement.bindDouble(req.index, req.value) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_bind_text(request: ?*const zova_statement_bind_text_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle.db, error.InvalidArgument);
    handle.statement.bindText(req.index, bytes) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_bind_blob(request: ?*const zova_statement_bind_blob_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle.db, error.InvalidArgument);
    handle.statement.bindBlob(req.index, bytes) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_parameter_count(request: ?*const zova_statement_parameter_count_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_count orelse return failDb(handle.db, error.InvalidArgument);
    out.* = handle.statement.parameterCount();
    return okDb(handle.db);
}

pub fn zova_statement_parameter_index(request: ?*const zova_statement_parameter_index_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const name = req.name orelse return failDb(handle.db, error.InvalidArgument);
    const out = req.out_index orelse return failDb(handle.db, error.InvalidArgument);
    out.* = handle.statement.parameterIndex(std.mem.span(name));
    return okDb(handle.db);
}

pub fn zova_statement_column_count(request: ?*const zova_statement_column_count_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_count orelse return failDb(handle.db, error.InvalidArgument);
    out.* = handle.statement.columnCount();
    return okDb(handle.db);
}

pub fn zova_statement_column_name(request: ?*const zova_statement_column_name_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_name orelse return failDb(handle.db, error.InvalidArgument);
    zova_text_free(out);

    const name = handle.statement.columnName(req.index) catch |err| return failDb(handle.db, err);
    const copy = allocator.alloc(u8, name.len + 1) catch |err| return failDb(handle.db, err);
    @memcpy(copy[0..name.len], name);
    copy[name.len] = 0;
    out.* = .{ .data = copy.ptr, .len = name.len };
    return okDb(handle.db);
}

pub fn zova_statement_column_type(request: ?*const zova_statement_column_type_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_type orelse return failDb(handle.db, error.InvalidArgument);
    out.* = columnTypeToAbi(handle.statement.columnType(req.index));
    return okDb(handle.db);
}

pub fn zova_statement_column_int64(request: ?*const zova_statement_column_int64_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_value orelse return failDb(handle.db, error.InvalidArgument);
    out.* = handle.statement.columnInt64(req.index);
    return okDb(handle.db);
}

pub fn zova_statement_column_double(request: ?*const zova_statement_column_double_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_value orelse return failDb(handle.db, error.InvalidArgument);
    out.* = handle.statement.columnDouble(req.index);
    return okDb(handle.db);
}

pub fn zova_statement_column_text(request: ?*const zova_statement_column_text_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_text orelse return failDb(handle.db, error.InvalidArgument);
    zova_text_free(out);

    if (handle.statement.columnType(req.index) == .null) return okDb(handle.db);
    const text = handle.statement.columnText(req.index);
    const copy = allocator.alloc(u8, text.len + 1) catch |err| return failDb(handle.db, err);
    @memcpy(copy[0..text.len], text);
    copy[text.len] = 0;
    out.* = .{ .data = copy.ptr, .len = text.len };
    return okDb(handle.db);
}

pub fn zova_statement_column_blob(request: ?*const zova_statement_column_blob_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_buffer orelse return failDb(handle.db, error.InvalidArgument);
    zova_buffer_free(out);

    if (handle.statement.columnType(req.index) == .null) return okDb(handle.db);
    const blob = handle.statement.columnBlob(req.index);
    if (blob.len == 0) return okDb(handle.db);

    const copy = allocator.alloc(u8, blob.len) catch |err| return failDb(handle.db, err);
    @memcpy(copy, blob);
    out.* = .{ .data = copy.ptr, .len = copy.len };
    return okDb(handle.db);
}
