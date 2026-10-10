//! Portable plugin authoring types and helpers. No engine or SQLite dependency.
//! Binary layouts match include/zova_plugin.h.
pub const entrypoint = "zova_plugin_entry_v1";
pub const Hook = *const fn (*const Host, ?*anyopaque) callconv(.c) i32;
pub const Host = extern struct {
    struct_size: u32 = @sizeOf(Host),
    abi_version: u32 = 1,
    exec_sql: ?*const fn (?*anyopaque, ?[*]const u8, u64) callconv(.c) i32 = null,
};

pub const status_unsupported: i32 = 4;
pub const status_limit: i32 = 5;
pub const status_canceled: i32 = 6;
pub const service_query: u32 = 1;
pub const service_diagnostics: u32 = 2;
pub const requires_query: u64 = 2;
pub const requires_diagnostics: u64 = 4;

/// Append-only extension of Host. Legacy hooks keep the exact v1 prefix.
pub const ServiceHost = extern struct {
    base: Host = .{ .struct_size = @sizeOf(ServiceHost) },
    get_service: ?*const fn (?*anyopaque, u32, u32, u32, ?*?*const anyopaque) callconv(.c) i32 = null,
};

pub const value_null: u32 = 0;
pub const value_integer: u32 = 1;
pub const value_float: u32 = 2;
pub const value_text: u32 = 3;
pub const value_blob: u32 = 4;
pub const Value = extern struct {
    kind: u32 = value_null,
    reserved: u32 = 0,
    integer: i64 = 0,
    real: f64 = 0,
    bytes: ?[*]const u8 = null,
    bytes_len: u64 = 0,
};
pub const RowCallback = *const fn (?*anyopaque, ?[*]const Value, u64) callconv(.c) i32;
pub const QueryRequest = extern struct {
    struct_size: u32 = @sizeOf(QueryRequest),
    flags: u32 = 0,
    sql: ?[*]const u8,
    sql_len: u64,
    parameters: ?[*]const Value = null,
    parameter_count: u64 = 0,
    row_limit: u64,
    byte_limit: u64,
    row: ?RowCallback,
    user_data: ?*anyopaque = null,
};
pub const QueryService = extern struct {
    struct_size: u32 = @sizeOf(QueryService),
    version: u32 = 1,
    query: ?*const fn (?*anyopaque, ?*const QueryRequest) callconv(.c) i32 = null,
};
pub const DiagnosticsService = extern struct {
    struct_size: u32 = @sizeOf(DiagnosticsService),
    version: u32 = 1,
    copy_sqlite_error: ?*const fn (?*anyopaque, ?[*]u8, u64, ?*u64) callconv(.c) i32 = null,
};
/// Zig author convenience over the exact C layouts and calling convention.
/// This value borrows the current hook and must not escape it.
pub const Client = struct {
    host: *const Host,
    connection: ?*anyopaque,
    pub const Error = error{ HostError, OutOfMemory, InvalidArgument, Unsupported, Limit, Canceled };

    pub fn exec(self: Client, sql: []const u8) Error!void {
        if (self.host.struct_size < @sizeOf(Host) or self.host.abi_version != 1) return error.Unsupported;
        const call = self.host.exec_sql orelse return error.Unsupported;
        try result(call(self.connection, sql.ptr, sql.len));
    }

    pub fn query(self: Client, request: *const QueryRequest) Error!void {
        const service = try self.getService(QueryService, service_query);
        const call = service.query orelse return error.Unsupported;
        try result(call(self.connection, request));
    }

    pub fn copySqliteError(self: Client, buffer: []u8) Error!usize {
        const service = try self.getService(DiagnosticsService, service_diagnostics);
        const call = service.copy_sqlite_error orelse return error.Unsupported;
        var written: u64 = 0;
        const status = call(self.connection, buffer.ptr, buffer.len, &written);
        if (status != status_limit) try result(status);
        if (written > buffer.len) return error.HostError;
        return @intCast(written);
    }

    fn getService(self: Client, comptime T: type, id: u32) Error!*const T {
        if (self.host.abi_version != 1 or self.host.struct_size < @sizeOf(ServiceHost)) return error.Unsupported;
        const host: *const ServiceHost = @ptrCast(self.host);
        const call = host.get_service orelse return error.Unsupported;
        var raw: ?*const anyopaque = null;
        try result(call(self.connection, id, 1, @sizeOf(T), &raw));
        const ptr = raw orelse return error.HostError;
        if (@intFromPtr(ptr) % @alignOf(T) != 0) return error.HostError;
        const service: *const T = @ptrCast(@alignCast(ptr));
        if (service.struct_size < @sizeOf(T) or service.version != 1) return error.Unsupported;
        return service;
    }

    fn result(status: i32) Error!void {
        return switch (status) {
            0 => {},
            2 => error.OutOfMemory,
            3 => error.InvalidArgument,
            4 => error.Unsupported,
            5 => error.Limit,
            6 => error.Canceled,
            else => error.HostError,
        };
    }
};
pub const Descriptor = extern struct {
    struct_size: u32,
    abi_version: u32,
    flags: u64 = 0,
    name: ?[*:0]const u8,
    version: ?[*:0]const u8,
    storage_prefix: ?[*:0]const u8,
    zova_abi_min: ?[*:0]const u8,
    capabilities: ?[*:0]const u8 = null,
    install: ?Hook = null,
    check: ?Hook = null,
    drop: ?Hook = null,
    register_sql: ?Hook = null,
};
pub const has_upgrade: u64 = 1;
pub const UpgradeDescriptor = extern struct {
    base: Descriptor,
    from_version: ?[*:0]const u8,
    upgrade: ?Hook,
};
