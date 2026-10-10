//! Host-side adapter for the portable plugin ABI.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const extension = @import("extension.zig");
const api = @import("extension_plugin_api.zig");
const data_access = @import("extension_data.zig");
pub const operations = @import("extension_operations.zig");
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
const supported_flags = has_upgrade | requires_query | requires_diagnostics | api.requires_data | api.requires_storage | api.requires_operations | api.requires_vector_maintenance;
const query_service: QueryService = .{ .query = query };
const data_service: api.DataService = .{ .read = readData };
const storage_service: api.StorageService = .{ .execute = storage };
const diagnostics_service: DiagnosticsService = .{ .copy_sqlite_error = copySqliteError };
const operation_service: api.OperationService = .{ .register_operation = registerOperation };
const vector_maintenance_service: api.VectorMaintenanceService = .{ .view = vectorView, .read_changes = vectorChanges };
const storage_function_names = [_][]const u8{ "count", "sum", "avg", "min", "max", "total", "coalesce", "ifnull", "nullif", "length", "octet_length", "typeof", "abs", "lower", "upper", "hex", "unhex", "substr", "substring", "round" };
const Context = struct {
    db: *sqlite.Database,
    storage_prefix: []const u8 = "",
    service_active: bool = false,
    storage_functions: ?u32 = null,
    registration_allowed: bool = false,
    registration_version: []const u8 = "",
    operation: bool = false,
    read_only_operation: bool = false,
};

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
    if (phase == .register_sql) {
        const scope = try operations.begin(db, std.mem.span(d.name.?));
        var success = false;
        defer scope.finish(success);
        try invokeContextHook(hook, db, std.mem.span(d.storage_prefix.?), std.mem.span(d.version.?));
        success = true;
        return;
    }
    return invokeOwnedHook(hook, db, std.mem.span(d.storage_prefix.?));
}

pub fn invokeHook(hook: Hook, db: *sqlite.Database) extension.Error!void {
    return invokeOwnedHook(hook, db, "");
}

pub fn invokeOwnedHook(hook: Hook, db: *sqlite.Database, storage_prefix: []const u8) extension.Error!void {
    return invokeContextHook(hook, db, storage_prefix, "");
}
fn invokeContextHook(hook: Hook, db: *sqlite.Database, storage_prefix: []const u8, registration_version: []const u8) extension.Error!void {
    const host = serviceHost();
    // Scope both related source pages and private writes. On failure preserve
    // earlier caller work, including when lifecycle already owns a savepoint.
    try db.savepoint("zova_plugin_hook");
    var released = false;
    defer if (!released) {
        db.rollbackToSavepoint("zova_plugin_hook") catch {};
        db.releaseSavepoint("zova_plugin_hook") catch {};
    };
    for ([_][]const u8{ "main.", try data_access.schema(db, "graph_store"), try data_access.schema(db, "vector_store") }) |prefix| {
        var buffer: [128]u8 = undefined;
        const sql = std.fmt.bufPrintSentinel(&buffer, "select 1 from {s}sqlite_schema limit 1", .{prefix}, 0) catch return error.ExtensionInvalid;
        var pin = try db.prepare(sql);
        defer pin.deinit();
        _ = try pin.step();
    }
    var context: Context = .{ .db = db, .storage_prefix = storage_prefix, .registration_allowed = registration_version.len != 0, .registration_version = registration_version };
    switch (hook(&host.base, &context)) {
        0 => {},
        2 => return error.OutOfMemory,
        else => return error.ExtensionInvalid,
    }
    try db.releaseSavepoint("zova_plugin_hook");
    released = true;
}

pub const OperationRunner = *const fn (*const Host, ?*anyopaque, ?*anyopaque) callconv(.c) i32;
/// Authorized callback scope, already inside the connection's SQL execution.
/// Never reacquire public handle locks. Scalar writes roll back on all failures.
pub fn callOperation(db: *sqlite.Database, prefix: []const u8, mutating: bool, runner: OperationRunner, state: ?*anyopaque) i32 {
    if (mutating) db.savepoint("zova_plugin_operation") catch |err| return serviceStatus(err);
    var success = false;
    defer if (mutating and !success) {
        db.rollbackToSavepoint("zova_plugin_operation") catch {};
        db.releaseSavepoint("zova_plugin_operation") catch {};
    };
    var pins: [3]?sqlite.Statement = @splat(null);
    defer for (&pins) |*pin| if (pin.*) |*stmt| stmt.deinit();
    for ([_][]const u8{ "main.", data_access.schema(db, "graph_store") catch |err| return serviceStatus(err), data_access.schema(db, "vector_store") catch |err| return serviceStatus(err) }, 0..) |schema_prefix, i| {
        var buffer: [128]u8 = undefined;
        const sql = std.fmt.bufPrintSentinel(&buffer, "select 1 from {s}sqlite_schema limit 1", .{schema_prefix}, 0) catch return 3;
        pins[i] = db.prepare(sql) catch |err| return serviceStatus(err);
        _ = pins[i].?.step() catch |err| return serviceStatus(err);
    }
    if (mutating and sqlite.c.sqlite3_db_readonly(db.handle, "main") != 0) return 1;
    var context: Context = .{ .db = db, .storage_prefix = prefix, .operation = true, .read_only_operation = !mutating };
    const host = serviceHost();
    const rc = runner(&host.base, &context, state);
    if (rc != 0) return if (rc >= 1 and rc <= 8) rc else 1;
    // Finalize pins before a mutating release can commit its owned savepoint.
    for (&pins) |*pin| {
        if (pin.*) |*stmt| stmt.deinit();
        pin.* = null;
    }
    if (mutating) db.releaseSavepoint("zova_plugin_operation") catch |err| return serviceStatus(err);
    success = true;
    return 0;
}

fn registerOperation(raw: ?*anyopaque, descriptor: ?*const api.Operation) callconv(.c) i32 {
    const state: *Context = @ptrCast(@alignCast(raw orelse return 3));
    if (state.service_active or !state.registration_allowed or state.storage_prefix.len < "_zova_ext__".len) return 3;
    state.service_active = true;
    defer state.service_active = false;
    const owner = state.storage_prefix["_zova_ext_".len .. state.storage_prefix.len - 1];
    operations.register(state.db, owner, state.storage_prefix, state.registration_version, descriptor orelse return 3) catch |err| return serviceStatus(err);
    state.storage_functions = null;
    return 0;
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
        api.service_data => {
            if (min_size > @sizeOf(api.DataService)) return status_unsupported;
            out.* = &data_service;
        },
        api.service_storage => {
            if (state.storage_prefix.len == 0 or min_size > @sizeOf(api.StorageService)) return status_unsupported;
            out.* = &storage_service;
        },
        api.service_operations => {
            if (!state.registration_allowed or min_size > @sizeOf(api.OperationService)) return status_unsupported;
            out.* = &operation_service;
        },
        api.service_vector_maintenance => {
            if (min_size > @sizeOf(api.VectorMaintenanceService)) return status_unsupported;
            out.* = &vector_maintenance_service;
        },
        else => return status_unsupported,
    }
    return 0;
}

fn vectorView(raw: ?*anyopaque, name: api.Bytes, output: ?*api.VectorView) callconv(.c) i32 {
    const out = output orelse return 3;
    out.* = .{};
    const state: *Context = @ptrCast(@alignCast(raw orelse return 3));
    if (state.service_active) return 3;
    state.service_active = true;
    defer state.service_active = false;
    const prefix = data_access.schema(state.db, "vector_store") catch |err| return serviceStatus(err);
    const text = data_access.bytes(name) catch |err| return serviceStatus(err);
    out.* = @import("vector_maintenance.zig").view(state.db, prefix, text) catch |err| return serviceStatus(err);
    return 0;
}

fn vectorChanges(raw: ?*anyopaque, request: ?*const api.VectorChangesRequest, output: ?*api.VectorChangesPage) callconv(.c) i32 {
    const out = output orelse return 3;
    out.* = .{};
    const state: *Context = @ptrCast(@alignCast(raw orelse return 3));
    if (state.service_active) return 3;
    state.service_active = true;
    defer state.service_active = false;
    const prefix = data_access.schema(state.db, "vector_store") catch |err| return serviceStatus(err);
    out.* = @import("vector_maintenance.zig").read(state.db, prefix, request orelse return 3) catch |err| return serviceStatus(err);
    return 0;
}

fn readData(context: ?*anyopaque, request: ?*const api.DataRequest, output: ?*api.DataPage) callconv(.c) i32 {
    const out = output orelse return 3;
    out.* = .{};
    const state: *Context = @ptrCast(@alignCast(context orelse return 3));
    if (state.service_active) return 3;
    state.service_active = true;
    defer state.service_active = false;
    out.* = data_access.read(std.heap.c_allocator, state.db, request orelse return 3) catch |err| return serviceStatus(err);
    return 0;
}

fn serviceStatus(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory, error.NoMemory => 2,
        error.InvalidArgument => 3,
        error.PluginLimit => status_limit,
        error.PluginCanceled, error.Interrupt => status_canceled,
        error.HistoryUnavailable => api.status_history_unavailable,
        error.SourceChanged => api.status_source_changed,
        else => 1,
    };
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
    return executeSql(allocator, db, request, false);
}

fn executeSql(allocator: std.mem.Allocator, db: *sqlite.Database, request: *const QueryRequest, allow_write: bool) QueryError!void {
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
    var stmt = if (allow_write)
        db.prepareDml(terminated) catch |err| return if (err == error.SqliteError) error.InvalidArgument else err
    else
        try db.prepareReadQuery(terminated);
    defer stmt.deinit();
    if ((!allow_write and (!stmt.isReadOnly() or stmt.columnCount() <= 0)) or stmt.columnCount() > max_query_columns) return error.InvalidArgument;
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
        const row_bytes = try data_access.readRow(&stmt, values[0..count]);
        if (row_bytes > request.byte_limit - bytes) return error.PluginLimit;
        bytes += row_bytes;
        rows += 1;
        try data_access.callback(request.row.?, request.user_data, values[0..count]);
    }
}

fn storage(context: ?*anyopaque, request: ?*const QueryRequest) callconv(.c) i32 {
    const state: *Context = @ptrCast(@alignCast(context orelse return 3));
    if (state.service_active or state.storage_prefix.len == 0) return 3;
    const r = request orelse return 3;
    state.service_active = true;
    defer state.service_active = false;
    if (state.storage_functions == null) {
        state.storage_functions = builtinFunctionMask(state.db) catch |err| return serviceStatus(err);
    }
    state.db.savepoint("zova_plugin_storage") catch |err| return serviceStatus(err);
    var released = false;
    defer if (!released) {
        state.db.rollbackToSavepoint("zova_plugin_storage") catch {};
        state.db.releaseSavepoint("zova_plugin_storage") catch {};
    };
    {
        // Keep the authorizer through step/reprepare and finalize, then remove
        // it before our own savepoint commands. Never authorize by SQL spelling.
        state.db.setAuthorizer(storageAuthorizer, state) catch |err| return serviceStatus(err);
        defer state.db.setAuthorizer(null, null) catch {};
        executeSql(std.heap.c_allocator, state.db, r, !state.read_only_operation) catch |err| {
            if (sqlite.c.sqlite3_errcode(state.db.handle) == sqlite.c.SQLITE_AUTH) return 3;
            return serviceStatus(err);
        };
    }
    state.db.releaseSavepoint("zova_plugin_storage") catch |err| return serviceStatus(err);
    released = true;
    return 0;
}

fn builtinFunctionMask(db: *sqlite.Database) sqlite.Error!u32 {
    // Snapshot once per exclusively owned hook. No permitted service changes
    // registrations. Future registration services must invalidate this cache.
    var mask: u32 = std.math.maxInt(u32);
    var stmt = try db.prepare("pragma function_list");
    defer stmt.deinit();
    while (try stmt.step() == .row) {
        if (stmt.columnInt64(1) != 0) continue;
        for (storage_function_names, 0..) |name, index| {
            if (std.ascii.eqlIgnoreCase(stmt.columnText(0), name)) mask &= ~(@as(u32, 1) << @intCast(index));
        }
    }
    return mask;
}

fn storageAuthorizer(raw: ?*anyopaque, action: c_int, first: [*c]const u8, second: [*c]const u8, schema_name: [*c]const u8, origin: [*c]const u8) callconv(.c) c_int {
    const state: *Context = @ptrCast(@alignCast(raw.?));
    const c = sqlite.c;
    // No triggers/views: their SQL and side effects are not an owner service.
    if (origin != null) return c.SQLITE_DENY;
    switch (action) {
        c.SQLITE_SELECT, c.SQLITE_RECURSIVE => return c.SQLITE_OK,
        c.SQLITE_READ, c.SQLITE_INSERT, c.SQLITE_UPDATE, c.SQLITE_DELETE => {
            // SQLite leaves schema_name NULL for an unqualified count(*) table.
            // Require main qualification there; guessing main could authorize a
            // same-named TEMP/attached table. Ordinary column reads are resolved.
            if (schema_name == null or !std.mem.eql(u8, std.mem.span(schema_name), "main") or first == null) return c.SQLITE_DENY;
            return if (std.mem.startsWith(u8, std.mem.span(first), state.storage_prefix)) c.SQLITE_OK else c.SQLITE_DENY;
        },
        c.SQLITE_FUNCTION => {
            if (second == null) return c.SQLITE_DENY;
            for (storage_function_names, 0..) |name, index| {
                if (std.ascii.eqlIgnoreCase(std.mem.span(second), name)) {
                    return if ((state.storage_functions orelse 0) & (@as(u32, 1) << @intCast(index)) != 0) c.SQLITE_OK else c.SQLITE_DENY;
                }
            }
            return c.SQLITE_DENY;
        },
        else => return c.SQLITE_DENY,
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
    if (state.service_active or state.operation) return 3;
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
