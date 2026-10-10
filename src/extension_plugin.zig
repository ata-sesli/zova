//! Host-side adapter for the portable plugin ABI.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const extension = @import("extension.zig");
const api = @import("extension_plugin_api.zig");
pub const status_unsupported = api.status_unsupported;
pub const status_limit = api.status_limit;
pub const status_canceled = api.status_canceled;
pub const service_query = api.service_query;
pub const service_diagnostics = api.service_diagnostics;
pub const requires_query = api.requires_query;
pub const requires_diagnostics = api.requires_diagnostics;
pub const value_null = api.value_null;
pub const value_integer = api.value_integer;
pub const value_float = api.value_float;
pub const value_text = api.value_text;
pub const value_blob = api.value_blob;
pub const has_upgrade = api.has_upgrade;

pub const entrypoint = api.entrypoint;
pub const Hook = api.Hook;
pub const Host = api.Host;
pub const ServiceHost = api.ServiceHost;
pub const Value = api.Value;
pub const RowCallback = api.RowCallback;
pub const QueryRequest = api.QueryRequest;
pub const QueryService = api.QueryService;
pub const DiagnosticsService = api.DiagnosticsService;
pub const Client = api.Client;
pub const Descriptor = api.Descriptor;
pub const UpgradeDescriptor = api.UpgradeDescriptor;
pub const Phase = enum { install, check, drop, register_sql };
const supported_flags = has_upgrade | requires_query | requires_diagnostics;
const query_service: QueryService = .{ .query = query };
const diagnostics_service: DiagnosticsService = .{ .copy_sqlite_error = copySqliteError };
const Context = struct { db: *sqlite.Database, service_active: bool = false };

pub fn legacyHost() Host {
    return .{ .exec_sql = execSql };
}
pub fn serviceHost() ServiceHost {
    return .{ .base = .{ .struct_size = @sizeOf(ServiceHost), .exec_sql = execContextSql }, .get_service = getService };
}

pub fn upgradePath(d: *const Descriptor) extension.Error!?extension.Upgrade {
    if (d.flags & ~supported_flags != 0) return error.ExtensionIncompatible;
    if (d.flags & has_upgrade == 0) return null;
    if (d.struct_size < @sizeOf(UpgradeDescriptor)) return error.ExtensionIncompatible;
    const tail: *const UpgradeDescriptor = @ptrCast(d);
    return .{
        .name = try string(d.name, 64),
        .from_version = try string(tail.from_version, 64),
        .to_version = try string(d.version, 64),
        .plugin_hook = tail.upgrade orelse return error.ExtensionInvalid,
    };
}

fn string(ptr: ?[*:0]const u8, max: usize) extension.Error![]const u8 {
    const value = ptr orelse return error.ExtensionInvalid;
    for (0..max + 1) |i| if (value[i] == 0) return value[0..i];
    return error.ExtensionInvalid;
}

pub fn validate(ptr: ?*const Descriptor) extension.Error!extension.Extension {
    const d = ptr orelse return error.ExtensionInvalid;
    // Read only the fixed two-u32 prefix until size/version are accepted.
    if (d.struct_size < @sizeOf(Descriptor) or d.abi_version != 1) return error.ExtensionIncompatible;
    if (d.flags & ~supported_flags != 0) return error.ExtensionIncompatible;
    if (d.flags & has_upgrade != 0 and d.struct_size < @sizeOf(UpgradeDescriptor)) return error.ExtensionIncompatible;
    const manifest: extension.Manifest = .{
        .name = try string(d.name, 64),
        .version = try string(d.version, 64),
        .storage_prefix = try string(d.storage_prefix, 128),
        .zova_abi_min = try string(d.zova_abi_min, 64),
        .capabilities = if (d.capabilities != null) try string(d.capabilities, 512) else "",
    };
    try extension.validateManifest(manifest);
    return .{ .manifest = manifest, .install = unavailable, .check = unavailable, .drop = unavailable };
}

fn unavailable(_: *sqlite.Database, _: extension.Manifest) extension.Error!void {
    return error.ExtensionUnavailable;
}

pub fn invoke(d: Descriptor, phase: Phase, db: *sqlite.Database) extension.Error!void {
    const hook = switch (phase) {
        .install => d.install,
        .check => d.check,
        .drop => d.drop,
        .register_sql => d.register_sql,
    } orelse return;
    return invokeHook(hook, db);
}

pub fn invokeHook(hook: Hook, db: *sqlite.Database) extension.Error!void {
    const host = serviceHost();
    var context: Context = .{ .db = db };
    switch (hook(&host.base, &context)) {
        0 => {},
        2 => return error.OutOfMemory,
        else => return error.ExtensionInvalid,
    }
}

fn getService(context: ?*anyopaque, id: u32, version: u32, min_size: u32, output: ?*?*const anyopaque) callconv(.c) i32 {
    const out = output orelse return 3;
    out.* = null;
    if (context == null) return 3;
    const state: *Context = @ptrCast(@alignCast(context.?));
    if (state.service_active) return 3;
    if (version != 1) return status_unsupported;
    switch (id) {
        service_query => {
            if (min_size > @sizeOf(QueryService)) return status_unsupported;
            out.* = &query_service;
        },
        service_diagnostics => {
            if (min_size > @sizeOf(DiagnosticsService)) return status_unsupported;
            out.* = &diagnostics_service;
        },
        else => return status_unsupported,
    }
    return 0;
}

pub const QueryError = sqlite.Error || error{ OutOfMemory, PluginLimit, PluginCanceled };
const max_sql_bytes = 1024 * 1024;
const max_query_rows = 4096;
const max_query_columns = 128;
const max_query_parameters = 256;

/// Internal allocator-aware implementation, used by the C service and fault
/// tests. All parameters are borrowed until finalization; row bytes only until
/// the callback returns. No statement or allocation crosses the ABI.
pub fn executeQuery(allocator: std.mem.Allocator, db: *sqlite.Database, request: *const QueryRequest) QueryError!void {
    if (request.struct_size < @sizeOf(QueryRequest) or request.flags != 0) return error.InvalidArgument;
    if (request.sql_len == 0 or request.sql_len > max_sql_bytes or request.sql == null or request.row == null) return error.InvalidArgument;
    if (request.row_limit == 0 or request.row_limit > max_query_rows or request.byte_limit == 0 or request.byte_limit > max_sql_bytes) return error.InvalidArgument;
    if (request.parameter_count > max_query_parameters or (request.parameter_count != 0 and request.parameters == null)) return error.InvalidArgument;
    const sql = request.sql.?[0..@intCast(request.sql_len)];
    if (std.mem.indexOfScalar(u8, sql, 0) != null or !std.unicode.utf8ValidateSlice(sql)) return error.InvalidArgument;
    const parameters = if (request.parameters) |ptr| ptr[0..@intCast(request.parameter_count)] else &.{};
    var parameter_bytes: u64 = 0;
    for (parameters) |value| {
        if (value.reserved != 0 or value.kind > value_blob) return error.InvalidArgument;
        if (value.kind == value_text or value.kind == value_blob) {
            if (value.bytes_len > max_sql_bytes or (value.bytes_len != 0 and value.bytes == null)) return error.InvalidArgument;
            parameter_bytes += value.bytes_len;
            if (parameter_bytes > max_sql_bytes) return error.InvalidArgument;
            if (value.kind == value_text and !std.unicode.utf8ValidateSlice(valueBytes(value))) return error.InvalidArgument;
        } else if (value.bytes != null or value.bytes_len != 0) return error.InvalidArgument;
    }
    const terminated = try allocator.dupeSentinel(u8, sql, 0);
    defer allocator.free(terminated);
    var stmt = try db.prepareReadQuery(terminated);
    defer stmt.deinit();
    if (!stmt.isReadOnly() or stmt.columnCount() <= 0 or stmt.columnCount() > max_query_columns) return error.InvalidArgument;
    if (stmt.parameterCount() != parameters.len) return error.InvalidArgument;
    for (parameters, 1..) |value, index| {
        switch (value.kind) {
            value_null => try stmt.bindNull(@intCast(index)),
            value_integer => try stmt.bindInt64(@intCast(index), value.integer),
            value_float => try stmt.bindDouble(@intCast(index), value.real),
            value_text => try stmt.bindTextBorrowed(@intCast(index), valueBytes(value)),
            value_blob => try stmt.bindBlobBorrowed(@intCast(index), valueBytes(value)),
            else => unreachable,
        }
    }
    var values: [max_query_columns]Value = undefined;
    var rows: u64 = 0;
    var bytes: u64 = 0;
    while (try stmt.step() == .row) {
        if (rows == request.row_limit) return error.PluginLimit;
        const count: usize = @intCast(stmt.columnCount());
        // SQLite can reprepare after a concurrent schema change at step().
        if (count > values.len) return error.InvalidArgument;
        var row_bytes: u64 = count * @sizeOf(Value);
        for (values[0..count], 0..) |*value, index| {
            value.* = .{};
            const column: c_int = @intCast(index);
            switch (stmt.columnType(column)) {
                .null => {},
                .integer => value.* = .{ .kind = value_integer, .integer = stmt.columnInt64(column) },
                .float => value.* = .{ .kind = value_float, .real = stmt.columnDouble(column) },
                .text, .blob => |kind| {
                    const data = if (kind == .text) stmt.columnText(column) else stmt.columnBlob(column);
                    try stmt.checkColumnError();
                    value.* = .{ .kind = if (kind == .text) value_text else value_blob, .bytes = data.ptr, .bytes_len = data.len };
                    if (data.len > request.byte_limit -| row_bytes) return error.PluginLimit;
                    row_bytes += data.len;
                },
            }
        }
        if (row_bytes > request.byte_limit - bytes) return error.PluginLimit;
        bytes += row_bytes;
        rows += 1;
        switch (request.row.?(request.user_data, &values, count)) {
            0 => {},
            2 => return error.OutOfMemory,
            6 => return error.PluginCanceled,
            else => return error.InvalidArgument,
        }
    }
}

fn valueBytes(value: Value) []const u8 {
    return if (value.bytes) |ptr| ptr[0..@intCast(value.bytes_len)] else "";
}

fn query(context: ?*anyopaque, request: ?*const QueryRequest) callconv(.c) i32 {
    const state: *Context = @ptrCast(@alignCast(context orelse return 3));
    if (state.service_active) return 3;
    state.service_active = true;
    defer state.service_active = false;
    executeQuery(std.heap.c_allocator, state.db, request orelse return 3) catch |err| return switch (err) {
        error.OutOfMemory, error.NoMemory => 2,
        error.InvalidArgument => 3,
        error.PluginLimit => status_limit,
        error.PluginCanceled, error.Interrupt => status_canceled,
        else => 1,
    };
    return 0;
}

fn copySqliteError(context: ?*anyopaque, buffer: ?[*]u8, capacity: u64, written: ?*u64) callconv(.c) i32 {
    const out = written orelse return 3;
    out.* = 0;
    if (capacity > 1024 or (capacity != 0 and buffer == null)) return 3;
    const state: *Context = @ptrCast(@alignCast(context orelse return 3));
    if (state.service_active) return 3;
    const message = state.db.errorMessage();
    const count = @min(message.len, @as(usize, @intCast(capacity)));
    if (count != 0) @memcpy(buffer.?[0..count], message[0..count]);
    out.* = count;
    return if (count < message.len) status_limit else 0;
}

fn execContextSql(context: ?*anyopaque, sql: ?[*]const u8, len: u64) callconv(.c) i32 {
    const state: *Context = @ptrCast(@alignCast(context orelse return 3));
    if (state.service_active) return 3;
    state.service_active = true;
    defer state.service_active = false;
    return execSql(state.db, sql, len);
}

fn execSql(context: ?*anyopaque, sql: ?[*]const u8, len: u64) callconv(.c) i32 {
    const raw = context orelse return 3;
    const bytes = sql orelse return 3;
    const size = std.math.cast(usize, len) orelse return 3;
    // Bound the host service and reject embedded NUL (sqlite exec uses C strings).
    if (size == 0 or size > 1024 * 1024 or std.mem.indexOfScalar(u8, bytes[0..size], 0) != null) return 3;
    const db: *sqlite.Database = @ptrCast(@alignCast(raw));
    // Match the extension host allocator; page_allocator requires unsupported
    // memory.grow intrinsics in Zig's generated-C WASM backend.
    const terminated = std.heap.c_allocator.dupeSentinel(u8, bytes[0..size], 0) catch return 2;
    defer std.heap.c_allocator.free(terminated);
    db.exec(terminated) catch |err| return if (err == error.NoMemory) 2 else 1;
    return 0;
}
