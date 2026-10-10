//! Connection-local SQL operation ownership. SQLite keeps stable host slots;
//! plugin state is published only after the enclosing lifecycle succeeds.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const api = @import("extension_plugin_api.zig");
const plugin = @import("extension_plugin.zig");
const data_access = @import("extension_data.zig");
const c = sqlite.c;
const allocator = std.heap.c_allocator;
const Error = sqlite.Error || error{OutOfMemory};

const Stored = struct {
    arena: std.heap.ArenaAllocator,
    descriptor: api.Operation,
    version: []const u8,
    fn deinit(self: *Stored) void {
        if (self.descriptor.destroy) |destroy| destroy(self.descriptor.user_data);
        self.arena.deinit();
        allocator.destroy(self);
    }
};
const Slot = struct {
    registry: *Registry,
    name: [:0]const u8,
    owner: []const u8,
    prefix: []const u8,
    kind: u32,
    current: ?*Stored = null,
    pending: ?*Stored = null,
    retired: std.ArrayList(*Stored) = .empty,
    layout_arena: std.heap.ArenaAllocator,
    arguments: []const api.OperationColumn,
    columns: []const api.OperationColumn,
    flags: u64,
    fn selected(self: *Slot) ?*Stored {
        var db: sqlite.Database = .{ .handle = self.registry.handle };
        var stmt = db.prepare("select version from _zova_extensions where name=?1 and storage_prefix=?2") catch return null;
        defer stmt.deinit();
        stmt.bindTextBorrowed(1, self.owner) catch return null;
        stmt.bindTextBorrowed(2, self.prefix) catch return null;
        if ((stmt.step() catch return null) != .row) return null;
        if (self.registry.scope_owner != null and self.pending != null) return self.pending;
        const version = stmt.columnText(0);
        if (self.current) |current| if (std.mem.eql(u8, current.version, version)) return current;
        var i = self.retired.items.len;
        while (i != 0) {
            i -= 1;
            const old = self.retired.items[i];
            if (std.mem.eql(u8, old.version, version)) return old;
        }
        return null;
    }
};
const Registry = struct {
    handle: *c.sqlite3,
    slots: std.ArrayList(*Slot) = .empty,
    scope_owner: ?[]const u8 = null,
    active: usize = 0,
    invoking: bool = false,
};

fn registry(db: *sqlite.Database) Error!*Registry {
    if (db.extension_sql_state) |raw| return @ptrCast(@alignCast(raw));
    const r = try allocator.create(Registry);
    r.* = .{ .handle = db.handle };
    db.extension_sql_state = r;
    db.extension_sql_cleanup = destroyRegistry;
    return r;
}
/// Do not invalidate a live plugin source cursor on the same connection.
/// No registry allocation occurs on databases without plugin operations.
pub fn requireSourceIdle(db: *sqlite.Database) error{Busy}!void {
    if (db.extension_sql_state) |raw| {
        const r: *Registry = @ptrCast(@alignCast(raw));
        if (r.active != 0) return error.Busy;
    }
}
fn destroyRegistry(raw: ?*anyopaque) void {
    const r: *Registry = @ptrCast(@alignCast(raw.?));
    for (r.slots.items) |slot| {
        if (slot.pending) |stored| stored.deinit();
        if (slot.current) |stored| stored.deinit();
        for (slot.retired.items) |stored| stored.deinit();
        slot.retired.deinit(allocator);
        slot.layout_arena.deinit();
        allocator.free(slot.name);
        allocator.free(slot.owner);
        allocator.free(slot.prefix);
        allocator.destroy(slot);
    }
    r.slots.deinit(allocator);
    allocator.destroy(r);
}

pub const Scope = struct {
    r: *Registry,
    owns: bool,
    pub fn finish(self: Scope, success: bool) void {
        if (!self.owns) return;
        for (self.r.slots.items) |slot| {
            if (slot.pending) |pending| {
                if (success) {
                    // Retain old code state for caller rollback of an upgrade.
                    // Capacity was reserved before accepting the new state.
                    if (slot.current) |old| slot.retired.appendAssumeCapacity(old);
                    slot.current = pending;
                } else pending.deinit();
                slot.pending = null;
            }
        }
        self.r.scope_owner = null;
    }
};
pub fn begin(db: *sqlite.Database, owner: []const u8) Error!Scope {
    const r = try registry(db);
    if (r.active != 0) return error.Busy;
    if (r.scope_owner) |existing| {
        if (!std.mem.eql(u8, existing, owner)) return error.InvalidArgument;
        return .{ .r = r, .owns = false };
    }
    r.scope_owner = owner;
    return .{ .r = r, .owns = true };
}
fn identifier(value: api.Bytes) Error![]const u8 {
    if (value.data == null or value.len == 0 or value.len > 63) return error.InvalidArgument;
    const name = value.data.?[0..@intCast(value.len)];
    for (name, 0..) |byte, i| if (!(byte >= 'a' and byte <= 'z') and byte != '_' and !(i != 0 and byte >= '0' and byte <= '9')) return error.InvalidArgument;
    return name;
}
fn validateColumns(columns: []const api.OperationColumn) Error!void {
    for (columns, 0..) |column, i| {
        const name = try identifier(column.name);
        if (column.kind < api.value_integer or column.kind > api.value_blob or column.nullable > 1) return error.InvalidArgument;
        for (columns[0..i]) |previous| if (std.mem.eql(u8, name, previous.name.data.?[0..@intCast(previous.name.len)])) return error.InvalidArgument;
    }
}
fn cloneColumns(a: std.mem.Allocator, columns: []const api.OperationColumn) Error![]api.OperationColumn {
    const result = try a.dupe(api.OperationColumn, columns);
    for (result) |*column| {
        const name = try a.dupe(u8, column.name.data.?[0..@intCast(column.name.len)]);
        column.name = .from(name);
    }
    return result;
}
fn sameColumns(a: []const api.OperationColumn, b: []const api.OperationColumn) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.kind != y.kind or x.nullable != y.nullable or !std.mem.eql(u8, x.name.data.?[0..@intCast(x.name.len)], y.name.data.?[0..@intCast(y.name.len)])) return false;
    }
    return true;
}
pub fn register(db: *sqlite.Database, owner: []const u8, prefix: []const u8, version: []const u8, descriptor: *const api.Operation) Error!void {
    const d = descriptor;
    if (d.struct_size < @sizeOf(api.Operation) or d.flags & ~@as(u64, 15) != 0 or (d.flags & 3 != api.operation_exact and d.flags & 3 != api.operation_approximate)) return error.InvalidArgument;
    if (d.argument_count > 32 or (d.argument_count != 0 and d.arguments == null) or d.column_count == 0 or d.column_count > 64 or d.columns == null) return error.InvalidArgument;
    if (d.kind == api.operation_scalar) {
        if (d.column_count != 1 or d.scalar == null or d.open != null or d.next != null or d.close != null or d.flags & api.operation_ordered != 0) return error.InvalidArgument;
    } else if (d.kind == api.operation_table) {
        if (d.scalar != null or d.open == null or d.next == null or d.close == null or d.flags & api.operation_mutating != 0) return error.InvalidArgument;
    } else return error.InvalidArgument;
    const local_name = try identifier(d.name);
    const arguments = if (d.arguments) |ptr| ptr[0..d.argument_count] else &.{};
    const columns = d.columns.?[0..d.column_count];
    try validateColumns(arguments);
    try validateColumns(columns);
    for (arguments) |arg| for (columns) |column| {
        if (std.mem.eql(u8, arg.name.data.?[0..@intCast(arg.name.len)], column.name.data.?[0..@intCast(column.name.len)])) return error.InvalidArgument;
    };
    const r = try registry(db);
    const scope_owner = r.scope_owner orelse return error.InvalidArgument;
    if (r.active != 0 or !std.mem.eql(u8, scope_owner, owner)) return error.InvalidArgument;
    const name = try std.fmt.allocPrintSentinel(allocator, "zova_{s}_{s}", .{ owner, local_name }, 0);
    defer allocator.free(name);
    var existing: ?*Slot = null;
    for (r.slots.items) |slot| if (std.ascii.eqlIgnoreCase(slot.name, name)) {
        existing = slot;
        break;
    };
    if (existing) |slot| {
        if (slot.pending != null or !std.mem.eql(u8, slot.owner, owner) or slot.kind != d.kind) return error.InvalidArgument;
        if (slot.flags != d.flags or !sameColumns(slot.columns, columns) or !sameColumns(slot.arguments, arguments) or slot.retired.items.len >= 64) return error.InvalidArgument;
        try slot.retired.ensureUnusedCapacity(allocator, 1);
    } else {
        // Never replace another SQL function, module or stored table/view.
        var names = try db.prepare("select name from pragma_function_list union all select name from pragma_module_list union all select name from sqlite_schema union all select name from sqlite_temp_schema");
        defer names.deinit();
        while (try names.step() == .row) if (std.ascii.eqlIgnoreCase(names.columnText(0), name)) return error.InvalidArgument;
    }
    const stored = try allocator.create(Stored);
    var arena = std.heap.ArenaAllocator.init(allocator);
    var transferred = false;
    defer if (!transferred) {
        arena.deinit();
        allocator.destroy(stored);
    };
    var copy = d.*;
    copy.arguments = (try cloneColumns(arena.allocator(), arguments)).ptr;
    copy.columns = (try cloneColumns(arena.allocator(), columns)).ptr;
    copy.name = .from(try arena.allocator().dupe(u8, local_name));
    const owned_version = try arena.allocator().dupe(u8, version);
    stored.* = .{ .arena = arena, .descriptor = copy, .version = owned_version };
    if (existing) |slot| {
        slot.pending = stored;
    } else {
        const slot = try allocator.create(Slot);
        var installed = false;
        defer if (!installed) allocator.destroy(slot);
        const owned_name = try allocator.dupeSentinel(u8, name, 0);
        const owned_owner = allocator.dupe(u8, owner) catch {
            allocator.free(owned_name);
            return error.OutOfMemory;
        };
        const owned_prefix = allocator.dupe(u8, prefix) catch {
            allocator.free(owned_name);
            allocator.free(owned_owner);
            return error.OutOfMemory;
        };
        var registered = false;
        defer if (!registered) {
            allocator.free(owned_name);
            allocator.free(owned_owner);
            allocator.free(owned_prefix);
        };
        try r.slots.ensureUnusedCapacity(allocator, 1);
        var layout_arena = std.heap.ArenaAllocator.init(allocator);
        defer if (!installed) layout_arena.deinit();
        const layout_args = try cloneColumns(layout_arena.allocator(), arguments);
        const layout_columns = try cloneColumns(layout_arena.allocator(), columns);
        slot.* = .{ .registry = r, .name = owned_name, .owner = owned_owner, .prefix = owned_prefix, .kind = d.kind, .layout_arena = layout_arena, .arguments = layout_args, .columns = layout_columns, .flags = d.flags };
        const rc = if (d.kind == api.operation_scalar)
            c.sqlite3_create_function_v2(db.handle, owned_name.ptr, @intCast(d.argument_count), c.SQLITE_UTF8 | c.SQLITE_DIRECTONLY, slot, scalar, null, null, null)
        else
            c.sqlite3_create_module_v2(db.handle, owned_name.ptr, &table_module, slot, null);
        if (rc != c.SQLITE_OK) return if (rc == c.SQLITE_NOMEM) error.NoMemory else error.SqliteError;
        registered = true;
        installed = true;
        r.slots.appendAssumeCapacity(slot);
        slot.pending = stored;
    }
    transferred = true;
}

fn readValue(value: *c.sqlite3_value) api.Value {
    return switch (c.sqlite3_value_type(value)) {
        c.SQLITE_INTEGER => .{ .kind = api.value_integer, .integer = c.sqlite3_value_int64(value) },
        c.SQLITE_FLOAT => .{ .kind = api.value_float, .real = c.sqlite3_value_double(value) },
        c.SQLITE_TEXT => .{ .kind = api.value_text, .bytes = @ptrCast(c.sqlite3_value_text(value)), .bytes_len = @intCast(c.sqlite3_value_bytes(value)) },
        c.SQLITE_BLOB => .{ .kind = api.value_blob, .bytes = @ptrCast(c.sqlite3_value_blob(value)), .bytes_len = @intCast(c.sqlite3_value_bytes(value)) },
        else => .{},
    };
}
fn validValue(value: api.Value, column: api.OperationColumn) bool {
    if (value.reserved != 0 or value.bytes_len > 1024 * 1024 or (value.bytes_len != 0 and value.bytes == null)) return false;
    if (value.kind == api.value_null) return column.nullable != 0 and value.bytes == null and value.bytes_len == 0;
    if (value.kind != column.kind) return false;
    if (value.kind == api.value_float and !std.math.isFinite(value.real)) return false;
    if (value.kind == api.value_text) return std.unicode.utf8ValidateSlice(if (value.bytes) |ptr| ptr[0..@intCast(value.bytes_len)] else "");
    return value.kind == api.value_blob or (value.bytes == null and value.bytes_len == 0);
}
fn readArguments(d: api.Operation, argc: c_int, argv: [*c]?*c.sqlite3_value, out: []api.Value) bool {
    if (argc != d.argument_count or argc < 0) return false;
    var bytes: u64 = @as(u64, @intCast(argc)) * @sizeOf(api.Value);
    for (out[0..@intCast(argc)], 0..) |*value, i| {
        value.* = readValue(argv[i] orelse return false);
        if (!validValue(value.*, d.arguments.?[i])) return false;
        bytes += value.bytes_len;
        if (bytes > 1024 * 1024) return false;
    }
    return true;
}
fn resultValue(ctx: *c.sqlite3_context, value: api.Value) i32 {
    // A result allocation/SQLite limit failure must be reported before a
    // mutating callback's savepoint is released, not at the later outer step.
    if (value.kind == api.value_text or value.kind == api.value_blob) {
        const limit = c.sqlite3_limit(c.sqlite3_context_db_handle(ctx), c.SQLITE_LIMIT_LENGTH, -1);
        if (value.bytes_len > @as(u64, @intCast(@max(limit, 0)))) return api.status_limit;
        if (value.kind == api.value_blob and value.bytes_len == 0) {
            _ = c.sqlite3_result_zeroblob64(ctx, 0);
            return 0;
        }
        const raw = c.sqlite3_malloc64(value.bytes_len + 1) orelse return 2;
        const bytes: [*]u8 = @ptrCast(raw);
        const len: usize = @intCast(value.bytes_len);
        if (len != 0) @memcpy(bytes[0..len], value.bytes.?[0..len]);
        bytes[len] = 0;
        if (value.kind == api.value_text) {
            c.sqlite3_result_text64(ctx, bytes, value.bytes_len, c.sqlite3_free, c.SQLITE_UTF8);
        } else {
            c.sqlite3_result_blob64(ctx, bytes, value.bytes_len, c.sqlite3_free);
        }
        return 0;
    }
    switch (value.kind) {
        api.value_null => c.sqlite3_result_null(ctx),
        api.value_integer => c.sqlite3_result_int64(ctx, value.integer),
        api.value_float => c.sqlite3_result_double(ctx, value.real),
        else => unreachable,
    }
    return 0;
}
const ScalarCall = struct {
    ctx: *c.sqlite3_context,
    d: api.Operation,
    args: []const api.Value,
    rows: usize = 0,
    invalid: bool = false,
    failure: i32 = 0,
    fn emit(raw: ?*anyopaque, values: ?[*]const api.Value, count: u64) callconv(.c) i32 {
        const self: *ScalarCall = @ptrCast(@alignCast(raw.?));
        if (count != 1 or values == null or self.rows != 0 or !validValue(values.?[0], self.d.columns.?[0])) {
            self.invalid = true;
            return 3;
        }
        if (values.?[0].bytes_len > 1024 * 1024 - @sizeOf(api.Value)) {
            self.failure = api.status_limit;
            self.invalid = true;
            return api.status_limit;
        }
        const status = resultValue(self.ctx, values.?[0]);
        if (status != 0) {
            self.failure = status;
            self.invalid = true;
            return status;
        }
        self.rows = 1;
        return 0;
    }
    fn run(base: *const api.Host, context: ?*anyopaque, raw: ?*anyopaque) callconv(.c) i32 {
        const self: *ScalarCall = @ptrCast(@alignCast(raw.?));
        const call: api.OperationCall = .{ .arguments = self.args.ptr, .argument_count = self.args.len, .row = emit, .user_data = self };
        const rc = self.d.scalar.?(base, context, self.d.user_data, &call);
        if (self.failure != 0) return self.failure;
        return if (rc == 0 and (self.rows != 1 or self.invalid)) 3 else rc;
    }
};
fn scalar(raw: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const ctx = raw orelse return;
    const slot: *Slot = @ptrCast(@alignCast(c.sqlite3_user_data(ctx).?));
    const stored = slot.selected() orelse {
        c.sqlite3_result_error(ctx, "plugin operation unavailable", -1);
        return;
    };
    if (slot.registry.invoking) {
        c.sqlite3_result_error(ctx, "plugin operation unavailable or recursive", -1);
        return;
    }
    var args: [32]api.Value = undefined;
    if (!readArguments(stored.descriptor, argc, argv, &args)) {
        c.sqlite3_result_error(ctx, "invalid plugin arguments", -1);
        return;
    }
    slot.registry.active += 1;
    defer slot.registry.active -= 1;
    slot.registry.invoking = true;
    defer slot.registry.invoking = false;
    var db: sqlite.Database = .{ .handle = slot.registry.handle };
    var call: ScalarCall = .{ .ctx = ctx, .d = stored.descriptor, .args = args[0..@intCast(argc)] };
    const status = plugin.callOperation(&db, slot.prefix, stored.descriptor.flags & api.operation_mutating != 0, ScalarCall.run, &call);
    if (status != 0) {
        c.sqlite3_result_error(ctx, statusMessage(status), -1);
        c.sqlite3_result_error_code(ctx, statusCode(status));
    }
}
fn statusMessage(status: i32) [*:0]const u8 {
    return switch (status) {
        7 => "plugin vector history unavailable; reconstruct against the current snapshot",
        8 => "plugin vector source changed; discard the incompatible generation",
        else => "plugin operation failed",
    };
}
fn statusCode(status: i32) c_int {
    return switch (status) {
        2 => c.SQLITE_NOMEM,
        5 => c.SQLITE_TOOBIG,
        6 => c.SQLITE_INTERRUPT,
        else => c.SQLITE_ERROR,
    };
}

const Table = extern struct { base: c.sqlite3_vtab, slot: *Slot };
const TableCursor = struct {
    base: c.sqlite3_vtab_cursor,
    slot: *Slot,
    db: sqlite.Database,
    state: ?*anyopaque = null,
    stored: ?*Stored = null,
    opened: bool = false,
    active: bool = false,
    eof: bool = true,
    index: i64 = 0,
    args_arena: std.heap.ArenaAllocator,
    row_arena: std.heap.ArenaAllocator,
    args: []api.Value = &.{},
    values: [64]api.Value = undefined,
    rows: usize = 0,
    invalid: bool = false,
    pins: [3]?sqlite.Statement = @splat(null),
    fn clear(self: *TableCursor) void {
        if (self.opened) {
            self.stored.?.descriptor.close.?(self.state);
            self.opened = false;
        }
        self.state = null;
        self.stored = null;
        for (&self.pins) |*pin| {
            if (pin.*) |*stmt| stmt.deinit();
            pin.* = null;
        }
        if (self.active) {
            self.slot.registry.active -= 1;
            self.active = false;
        }
        _ = self.args_arena.reset(.free_all);
        _ = self.row_arena.reset(.free_all);
        self.args = &.{};
        self.eof = true;
        self.index = 0;
    }
    fn emit(raw: ?*anyopaque, values: ?[*]const api.Value, count: u64) callconv(.c) i32 {
        const self: *TableCursor = @ptrCast(@alignCast(raw.?));
        const d = self.stored.?.descriptor;
        if (count != d.column_count or values == null or self.rows != 0) {
            self.invalid = true;
            return 3;
        }
        var bytes: u64 = count * @sizeOf(api.Value);
        for (values.?[0..@intCast(count)], d.columns.?[0..d.column_count]) |value, column| {
            if (!validValue(value, column)) {
                self.invalid = true;
                return 3;
            }
            bytes += value.bytes_len;
            if (bytes > 1024 * 1024) {
                self.invalid = true;
                return 5;
            }
        }
        for (values.?[0..@intCast(count)], self.values[0..@intCast(count)]) |value, *copy| {
            copy.* = value;
            if (value.bytes_len != 0) {
                const data = self.row_arena.allocator().dupe(u8, value.bytes.?[0..@intCast(value.bytes_len)]) catch {
                    self.invalid = true;
                    return 2;
                };
                copy.bytes = data.ptr;
            }
        }
        self.rows = 1;
        return 0;
    }
    fn openCall(host: *const api.Host, context: ?*anyopaque, raw: ?*anyopaque) callconv(.c) i32 {
        const self: *TableCursor = @ptrCast(@alignCast(raw.?));
        const d = self.stored.?.descriptor;
        const rc = d.open.?(host, context, d.user_data, self.args.ptr, self.args.len, &self.state);
        // Even a partially allocated cursor returned with an error is closed.
        self.opened = rc == 0 or self.state != null;
        return rc;
    }
    fn nextCall(host: *const api.Host, context: ?*anyopaque, raw: ?*anyopaque) callconv(.c) i32 {
        const self: *TableCursor = @ptrCast(@alignCast(raw.?));
        var has_row: u32 = 0;
        const rc = self.stored.?.descriptor.next.?(host, context, self.state, emit, self, &has_row);
        if (rc != 0) return rc;
        if (has_row > 1 or has_row != self.rows or self.invalid) return 3;
        self.eof = has_row == 0;
        return 0;
    }
};
const table_module: c.sqlite3_module = .{
    .iVersion = 3,
    .xCreate = null,
    .xConnect = tableConnect,
    .xBestIndex = tableBestIndex,
    .xDisconnect = tableDisconnect,
    .xDestroy = null,
    .xOpen = tableOpen,
    .xClose = tableClose,
    .xFilter = tableFilter,
    .xNext = tableNext,
    .xEof = tableEof,
    .xColumn = tableColumn,
    .xRowid = tableRowid,
    .xUpdate = null,
    .xBegin = null,
    .xSync = null,
    .xCommit = null,
    .xRollback = null,
    .xFindFunction = null,
    .xRename = null,
    .xSavepoint = null,
    .xRelease = null,
    .xRollbackTo = null,
    .xShadowName = null,
    .xIntegrity = null,
};
fn tableConnect(db: ?*c.sqlite3, raw: ?*anyopaque, _: c_int, _: [*c]const [*c]const u8, out: [*c][*c]c.sqlite3_vtab, _: [*c][*c]u8) callconv(.c) c_int {
    const slot: *Slot = @ptrCast(@alignCast(raw.?));
    const stored = slot.selected() orelse return c.SQLITE_ERROR;
    var buffer: [8192]u8 = undefined;
    var used: usize = 0;
    const start = std.fmt.bufPrint(buffer[used..], "create table x(", .{}) catch return c.SQLITE_ERROR;
    used += start.len;
    const d = stored.descriptor;
    for (0..@as(usize, d.column_count) + d.argument_count) |i| {
        const hidden = i >= d.column_count;
        const column = if (hidden) d.arguments.?[i - d.column_count] else d.columns.?[i];
        const kind = switch (column.kind) {
            api.value_integer => "integer",
            api.value_float => "real",
            api.value_text => "text",
            api.value_blob => "blob",
            else => return c.SQLITE_ERROR,
        };
        const part = std.fmt.bufPrint(buffer[used..], "{s}\"{s}\" {s}{s}", .{ if (i == 0) "" else ",", column.name.data.?[0..@intCast(column.name.len)], kind, if (hidden) " hidden" else "" }) catch return c.SQLITE_ERROR;
        used += part.len;
    }
    const schema = std.fmt.bufPrintSentinel(buffer[used..], ")", .{}, 0) catch return c.SQLITE_ERROR;
    _ = schema;
    const rc = c.sqlite3_declare_vtab(db.?, &buffer);
    if (rc != c.SQLITE_OK) return rc;
    const direct = c.sqlite3_vtab_config(db.?, c.SQLITE_VTAB_DIRECTONLY);
    if (direct != c.SQLITE_OK) return direct;
    const table = allocator.create(Table) catch return c.SQLITE_NOMEM;
    table.* = .{ .base = .{ .pModule = &table_module, .nRef = 0, .zErrMsg = null }, .slot = slot };
    out.* = &table.base;
    return c.SQLITE_OK;
}
fn tableDisconnect(raw: ?*c.sqlite3_vtab) callconv(.c) c_int {
    const table: *Table = @fieldParentPtr("base", raw.?);
    allocator.destroy(table);
    return c.SQLITE_OK;
}
fn tableBestIndex(raw: ?*c.sqlite3_vtab, raw_info: ?*c.sqlite3_index_info) callconv(.c) c_int {
    const table: *Table = @fieldParentPtr("base", raw.?);
    const stored = table.slot.selected() orelse return c.SQLITE_ERROR;
    const info = raw_info.?;
    const d = stored.descriptor;
    for (0..d.argument_count) |arg| {
        var found = false;
        for (0..@intCast(info.nConstraint)) |i| {
            const constraint = info.aConstraint[i];
            if (constraint.iColumn == d.column_count + arg and constraint.op == c.SQLITE_INDEX_CONSTRAINT_EQ and constraint.usable != 0) {
                info.aConstraintUsage[i].argvIndex = @intCast(arg + 1);
                info.aConstraintUsage[i].omit = 1;
                found = true;
                break;
            }
        }
        if (!found) return c.SQLITE_CONSTRAINT;
    }
    info.estimatedCost = 1000;
    info.estimatedRows = 1000;
    return c.SQLITE_OK;
}
fn tableOpen(raw: ?*c.sqlite3_vtab, out: [*c][*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const table: *Table = @fieldParentPtr("base", raw.?);
    const cursor = allocator.create(TableCursor) catch return c.SQLITE_NOMEM;
    cursor.* = .{ .base = .{ .pVtab = &table.base }, .slot = table.slot, .db = .{ .handle = table.slot.registry.handle }, .args_arena = std.heap.ArenaAllocator.init(allocator), .row_arena = std.heap.ArenaAllocator.init(allocator) };
    // SQLite returns this base pointer to callbacks. The allocation retains
    // TableCursor alignment even on targets where the C base is less aligned.
    out.* = &cursor.base;
    return c.SQLITE_OK;
}
fn tableClose(raw: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cursor: *TableCursor = @alignCast(@fieldParentPtr("base", raw.?));
    cursor.clear();
    cursor.args_arena.deinit();
    cursor.row_arena.deinit();
    allocator.destroy(cursor);
    return c.SQLITE_OK;
}
fn tableError(cursor: *TableCursor, status: i32) c_int {
    if (status == 7 or status == 8) {
        const table = cursor.base.pVtab;
        c.sqlite3_free(table.*.zErrMsg);
        table.*.zErrMsg = c.sqlite3_mprintf("%s", statusMessage(status));
    }
    cursor.clear();
    return statusCode(status);
}
fn tableFilter(raw: ?*c.sqlite3_vtab_cursor, _: c_int, _: [*c]const u8, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) c_int {
    const cursor: *TableCursor = @alignCast(@fieldParentPtr("base", raw.?));
    cursor.clear();
    const slot = cursor.slot;
    const stored = slot.selected() orelse return c.SQLITE_ERROR;
    if (slot.registry.invoking) return c.SQLITE_ERROR;
    var args: [32]api.Value = undefined;
    if (!readArguments(stored.descriptor, argc, argv, &args)) return c.SQLITE_ERROR;
    cursor.args = cursor.args_arena.allocator().dupe(api.Value, args[0..@intCast(argc)]) catch return c.SQLITE_NOMEM;
    for (cursor.args) |*arg| {
        if (arg.bytes_len != 0) {
            const data = cursor.args_arena.allocator().dupe(u8, arg.bytes.?[0..@intCast(arg.bytes_len)]) catch return tableError(cursor, 2);
            arg.bytes = data.ptr;
        }
    }
    // Keep source reads alive for this SQL cursor, including attached stores.
    // Later pull callbacks share these snapshots until LIMIT/reset/finalize.
    const schemas = [_][]const u8{ "main.", data_access.schema(&cursor.db, "graph_store") catch return tableError(cursor, 1), data_access.schema(&cursor.db, "vector_store") catch return tableError(cursor, 1) };
    for (schemas, 0..) |prefix, i| {
        var buffer: [128]u8 = undefined;
        const sql = std.fmt.bufPrintSentinel(&buffer, "select 1 from {s}sqlite_schema limit 1", .{prefix}, 0) catch return tableError(cursor, 3);
        cursor.pins[i] = cursor.db.prepare(sql) catch return tableError(cursor, 1);
        _ = cursor.pins[i].?.step() catch return tableError(cursor, 1);
    }
    slot.registry.active += 1;
    cursor.active = true;
    cursor.stored = stored;
    slot.registry.invoking = true;
    const status = plugin.callOperation(&cursor.db, slot.prefix, false, TableCursor.openCall, cursor);
    slot.registry.invoking = false;
    if (status != 0) return tableError(cursor, status);
    return tableNext(raw);
}
fn tableNext(raw: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cursor: *TableCursor = @alignCast(@fieldParentPtr("base", raw.?));
    if (cursor.slot.registry.invoking or !cursor.active) return c.SQLITE_ERROR;
    _ = cursor.row_arena.reset(.free_all);
    cursor.rows = 0;
    cursor.invalid = false;
    cursor.slot.registry.invoking = true;
    const status = plugin.callOperation(&cursor.db, cursor.slot.prefix, false, TableCursor.nextCall, cursor);
    cursor.slot.registry.invoking = false;
    if (status != 0) return tableError(cursor, status);
    if (cursor.eof) {
        cursor.clear();
        return c.SQLITE_OK;
    }
    if (cursor.index == std.math.maxInt(i64)) return tableError(cursor, 5);
    cursor.index += 1;
    return c.SQLITE_OK;
}
fn tableEof(raw: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cursor: *TableCursor = @alignCast(@fieldParentPtr("base", raw.?));
    return @intFromBool(cursor.eof);
}
fn tableColumn(raw: ?*c.sqlite3_vtab_cursor, context: ?*c.sqlite3_context, column: c_int) callconv(.c) c_int {
    const cursor: *TableCursor = @alignCast(@fieldParentPtr("base", raw.?));
    const d = cursor.stored.?.descriptor;
    if (column < 0) return c.SQLITE_ERROR;
    if (column < d.column_count) {
        const rc = resultValue(context.?, cursor.values[@intCast(column)]);
        if (rc != 0) return statusCode(rc);
    } else if (column < d.column_count + d.argument_count) {
        const rc = resultValue(context.?, cursor.args[@as(usize, @intCast(column)) - d.column_count]);
        if (rc != 0) return statusCode(rc);
    } else return c.SQLITE_ERROR;
    return c.SQLITE_OK;
}
fn tableRowid(raw: ?*c.sqlite3_vtab_cursor, output: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const cursor: *TableCursor = @alignCast(@fieldParentPtr("base", raw.?));
    output.* = cursor.index;
    return c.SQLITE_OK;
}
