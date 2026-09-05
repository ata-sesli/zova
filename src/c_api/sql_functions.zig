//! Application SQL callback registration, invocation, and result conversion.

const std = @import("std");
const sqlite = @import("../sqlite.zig");

const DatabaseHandle = @import("handles.zig").DatabaseHandle;
const SqlScalarFunctionContext = @import("handles.zig").SqlScalarFunctionContext;
const ZOVA_SQL_FUNCTION_DETERMINISTIC = @import("types.zig").ZOVA_SQL_FUNCTION_DETERMINISTIC;
const ZOVA_SQL_FUNCTION_DIRECT_ONLY = @import("types.zig").ZOVA_SQL_FUNCTION_DIRECT_ONLY;
const ZOVA_SQL_FUNCTION_INNOCUOUS = @import("types.zig").ZOVA_SQL_FUNCTION_INNOCUOUS;
const allocator = @import("values.zig").allocator;
const databaseHandle = @import("handles.zig").databaseHandle;
const failDb = @import("errors.zig").failDb;
const failDbSqliteResult = @import("errors.zig").failDbSqliteResult;
const okDb = @import("errors.zig").okDb;
const zova_sql_function_call = @import("types.zig").zova_sql_function_call;
const zova_sql_function_register_request = @import("types.zig").zova_sql_function_register_request;
const zova_sql_result = @import("types.zig").zova_sql_result;
const zova_sql_result_type = @import("types.zig").zova_sql_result_type;
const zova_sql_value = @import("types.zig").zova_sql_value;
const zova_status = @import("types.zig").zova_status;

pub fn zova_database_register_function(request: ?*const zova_sql_function_register_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();

    const name_z = req.name orelse return failDb(handle, error.InvalidArgument);
    const name = std.mem.span(name_z);
    validateSqlFunctionName(name) catch |err| return failDb(handle, err);
    if (!isValidSqlFunctionArity(req.arity)) return failDb(handle, error.InvalidArgument);
    if ((req.flags & ~allowed_sql_function_flags) != 0) return failDb(handle, error.InvalidArgument);
    const callback = req.callback orelse return failDb(handle, error.InvalidArgument);
    if (hasRegisteredSqlFunction(handle, name, req.arity)) return failDb(handle, error.InvalidArgument);

    handle.sql_functions.ensureUnusedCapacity(allocator, 1) catch |err| return failDb(handle, err);

    const context = allocator.create(SqlScalarFunctionContext) catch |err| return failDb(handle, err);
    context.* = .{
        .user_data = req.user_data,
        .callback = callback,
        .destroy = req.destroy,
    };

    const name_copy = allocator.dupeZ(u8, name) catch |err| {
        destroySqlScalarContext(@ptrCast(context));
        return failDb(handle, err);
    };

    const rc = sqlite.c.sqlite3_create_function_v2(
        handle.db.sqlite_db.handle,
        name_z,
        req.arity,
        sqlFunctionFlagsToSqlite(req.flags),
        context,
        sqlScalarTrampoline,
        null,
        null,
        destroySqlScalarContext,
    );
    if (rc != sqlite.c.SQLITE_OK) {
        allocator.free(name_copy);
        return failDbSqliteResult(handle, rc);
    }

    handle.sql_functions.appendAssumeCapacity(.{ .name = name_copy, .arity = req.arity });

    return okDb(handle);
}

const allowed_sql_function_flags =
    ZOVA_SQL_FUNCTION_DETERMINISTIC |
    ZOVA_SQL_FUNCTION_DIRECT_ONLY |
    ZOVA_SQL_FUNCTION_INNOCUOUS;

fn validateSqlFunctionName(name: []const u8) error{InvalidArgument}!void {
    if (name.len == 0 or name.len > 64) return error.InvalidArgument;
    if (hasAsciiInsensitivePrefix(name, "zova_") or hasAsciiInsensitivePrefix(name, "_zova_")) return error.InvalidArgument;
    if (!isAsciiIdentStart(name[0])) return error.InvalidArgument;
    for (name[1..]) |byte| {
        if (!isAsciiIdentContinue(byte)) return error.InvalidArgument;
    }
}

fn isValidSqlFunctionArity(arity: c_int) bool {
    return arity == -1 or (arity >= 0 and arity <= 127);
}

fn hasRegisteredSqlFunction(handle: *DatabaseHandle, name: []const u8, arity: c_int) bool {
    for (handle.sql_functions.items) |item| {
        if (item.arity == arity and asciiInsensitiveEql(item.name, name)) return true;
    }
    return false;
}

fn sqlFunctionFlagsToSqlite(flags: u32) c_int {
    var sqlite_flags: c_int = sqlite.c.SQLITE_UTF8;
    if ((flags & ZOVA_SQL_FUNCTION_DETERMINISTIC) != 0) sqlite_flags |= sqlite.c.SQLITE_DETERMINISTIC;
    if ((flags & ZOVA_SQL_FUNCTION_DIRECT_ONLY) != 0) sqlite_flags |= sqlite.c.SQLITE_DIRECTONLY;
    if ((flags & ZOVA_SQL_FUNCTION_INNOCUOUS) != 0) sqlite_flags |= sqlite.c.SQLITE_INNOCUOUS;
    return sqlite_flags;
}

pub fn deinitSqlFunctionRegistrations(handle: *DatabaseHandle) void {
    for (handle.sql_functions.items) |*item| item.deinit();
    handle.sql_functions.deinit(allocator);
}

fn destroySqlScalarContext(user_data: ?*anyopaque) callconv(.c) void {
    const context_ptr = user_data orelse return;
    const context: *SqlScalarFunctionContext = @ptrCast(@alignCast(context_ptr));
    if (context.destroy) |destroy| destroy(context.user_data);
    allocator.destroy(context);
}

fn sqlScalarTrampoline(
    sqlite_context: ?*sqlite.c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*sqlite.c.sqlite3_value,
) callconv(.c) void {
    const raw_context = sqlite_context orelse return;
    const user_data = sqlite.c.sqlite3_user_data(raw_context) orelse {
        sqlite.c.sqlite3_result_error(raw_context, "missing zova sql callback context", -1);
        return;
    };
    const context: *SqlScalarFunctionContext = @ptrCast(@alignCast(user_data));
    if (argc < 0) {
        sqlite.c.sqlite3_result_error(raw_context, "invalid zova sql callback argc", -1);
        return;
    }

    const count: usize = @intCast(argc);
    const values = allocator.alloc(zova_sql_value, count) catch {
        sqlite.c.sqlite3_result_error_nomem(raw_context);
        return;
    };
    defer allocator.free(values);

    for (values, 0..) |*value, index| {
        const sqlite_value = argv[index] orelse {
            sqlite.c.sqlite3_result_error(raw_context, "invalid zova sql callback argv", -1);
            return;
        };
        value.* = sqlValueFromSqlite(sqlite_value);
    }

    var call = zova_sql_function_call{
        .user_data = context.user_data,
        .argc = count,
        .argv = if (values.len == 0) null else values.ptr,
    };
    var result = zova_sql_result{};
    context.callback(context.user_data, &call, &result);
    applySqlResult(raw_context, result);
}

fn sqlValueFromSqlite(value: *sqlite.c.sqlite3_value) zova_sql_value {
    return switch (sqlite.c.sqlite3_value_type(value)) {
        sqlite.c.SQLITE_INTEGER => .{
            .value_type = .INTEGER,
            .int64_value = sqlite.c.sqlite3_value_int64(value),
        },
        sqlite.c.SQLITE_FLOAT => .{
            .value_type = .FLOAT,
            .double_value = sqlite.c.sqlite3_value_double(value),
        },
        sqlite.c.SQLITE_TEXT => textSqlValue(value),
        sqlite.c.SQLITE_BLOB => blobSqlValue(value),
        sqlite.c.SQLITE_NULL => .{ .value_type = .NULL },
        else => .{ .value_type = .NULL },
    };
}

fn textSqlValue(value: *sqlite.c.sqlite3_value) zova_sql_value {
    const len_raw = sqlite.c.sqlite3_value_bytes(value);
    const len: usize = if (len_raw <= 0) 0 else @intCast(len_raw);
    const ptr = sqlite.c.sqlite3_value_text(value);
    return .{
        .value_type = .TEXT,
        .data = if (ptr == null) null else @ptrCast(ptr),
        .data_len = len,
    };
}

fn blobSqlValue(value: *sqlite.c.sqlite3_value) zova_sql_value {
    const len_raw = sqlite.c.sqlite3_value_bytes(value);
    const len: usize = if (len_raw <= 0) 0 else @intCast(len_raw);
    const ptr = sqlite.c.sqlite3_value_blob(value);
    return .{
        .value_type = .BLOB,
        .data = if (ptr == null) null else @ptrCast(ptr),
        .data_len = len,
    };
}

fn applySqlResult(sqlite_context: *sqlite.c.sqlite3_context, result: zova_sql_result) void {
    switch (result.result_type) {
        @intFromEnum(zova_sql_result_type.NULL) => sqlite.c.sqlite3_result_null(sqlite_context),
        @intFromEnum(zova_sql_result_type.INTEGER) => sqlite.c.sqlite3_result_int64(sqlite_context, result.int64_value),
        @intFromEnum(zova_sql_result_type.FLOAT) => sqlite.c.sqlite3_result_double(sqlite_context, result.double_value),
        @intFromEnum(zova_sql_result_type.TEXT) => applySqlTextResult(sqlite_context, result.data, result.data_len),
        @intFromEnum(zova_sql_result_type.BLOB) => applySqlBlobResult(sqlite_context, result.data, result.data_len),
        @intFromEnum(zova_sql_result_type.ERROR) => applySqlErrorResult(sqlite_context, result.error_message, result.error_message_len),
        else => sqlite.c.sqlite3_result_error(sqlite_context, "invalid zova sql callback result type", -1),
    }
}

fn applySqlTextResult(sqlite_context: *sqlite.c.sqlite3_context, data: ?*const anyopaque, len: usize) void {
    const copy = copySqlResultBytes(sqlite_context, data, len, true) orelse return;
    sqlite.c.sqlite3_result_text64(sqlite_context, @ptrCast(copy), @intCast(len), sqlite.c.sqlite3_free, sqlite.c.SQLITE_UTF8);
}

fn applySqlBlobResult(sqlite_context: *sqlite.c.sqlite3_context, data: ?*const anyopaque, len: usize) void {
    const copy = copySqlResultBytes(sqlite_context, data, len, false) orelse return;
    sqlite.c.sqlite3_result_blob64(sqlite_context, copy, @intCast(len), sqlite.c.sqlite3_free);
}

fn applySqlErrorResult(sqlite_context: *sqlite.c.sqlite3_context, message: ?[*]const u8, len: usize) void {
    if (message == null or len == 0) {
        sqlite.c.sqlite3_result_error(sqlite_context, "zova sql callback error", -1);
        return;
    }
    if (len > std.math.maxInt(c_int)) {
        sqlite.c.sqlite3_result_error(sqlite_context, "zova sql callback error too large", -1);
        return;
    }
    sqlite.c.sqlite3_result_error(sqlite_context, @ptrCast(message), @intCast(len));
}

fn copySqlResultBytes(sqlite_context: *sqlite.c.sqlite3_context, data: ?*const anyopaque, len: usize, nul_terminate: bool) ?*anyopaque {
    if (data == null and len != 0) {
        sqlite.c.sqlite3_result_error(sqlite_context, "zova sql callback result has null data", -1);
        return null;
    }
    const extra: usize = if (nul_terminate) 1 else 0;
    const alloc_len = std.math.add(usize, len, extra) catch {
        sqlite.c.sqlite3_result_error_nomem(sqlite_context);
        return null;
    };
    const effective_alloc_len = @max(alloc_len, 1);
    const copy = sqlite.c.sqlite3_malloc64(@intCast(effective_alloc_len)) orelse {
        sqlite.c.sqlite3_result_error_nomem(sqlite_context);
        return null;
    };
    const dest: [*]u8 = @ptrCast(copy);
    if (len != 0) {
        const src: [*]const u8 = @ptrCast(data.?);
        @memcpy(dest[0..len], src[0..len]);
    }
    if (nul_terminate) dest[len] = 0;
    return copy;
}

fn isAsciiIdentStart(byte: u8) bool {
    return byte == '_' or (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}

fn isAsciiIdentContinue(byte: u8) bool {
    return isAsciiIdentStart(byte) or (byte >= '0' and byte <= '9');
}

fn hasAsciiInsensitivePrefix(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return asciiInsensitiveEql(value[0..prefix.len], prefix);
}

fn asciiInsensitiveEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (asciiLower(left) != asciiLower(right)) return false;
    }
    return true;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}
