//! Key-value batch and single-operation entrypoint implementations.

const allocator = @import("values.zig").allocator;
const bytesConst = @import("values.zig").bytesConst;
const lockDatabaseHandle = @import("handles.zig").lockDatabaseHandle;
const failDb = @import("errors.zig").failDb;
const kvKeySlices = @import("values.zig").kvKeySlices;
const kvPutEntrySlices = @import("values.zig").kvPutEntrySlices;
const okDb = @import("errors.zig").okDb;
const zova_kv_clear_namespace_request = @import("types.zig").zova_kv_clear_namespace_request;
const zova_kv_count_request = @import("types.zig").zova_kv_count_request;
const zova_kv_delete_many_request = @import("types.zig").zova_kv_delete_many_request;
const zova_kv_delete_request = @import("types.zig").zova_kv_delete_request;
const zova_kv_get_many_request = @import("types.zig").zova_kv_get_many_request;
const zova_kv_get_request = @import("types.zig").zova_kv_get_request;
const zova_kv_get_result = @import("types.zig").zova_kv_get_result;
const zova_kv_put_many_request = @import("types.zig").zova_kv_put_many_request;
const zova_kv_put_request = @import("types.zig").zova_kv_put_request;
const zova_kv_compare_and_delete_request = @import("types.zig").zova_kv_compare_and_delete_request;
const zova_kv_compare_and_put_request = @import("types.zig").zova_kv_compare_and_put_request;
const zova_kv_entry = @import("types.zig").zova_kv_entry;
const zova_kv_put_if_absent_request = @import("types.zig").zova_kv_put_if_absent_request;
const zova_kv_scan_request = @import("types.zig").zova_kv_scan_request;
const zova_status = @import("types.zig").zova_status;

pub fn zova_kv_get(request: ?*const zova_kv_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_result orelse return failDb(handle, error.InvalidArgument);
    out.* = .{ .found = 0, .value = .{ .data = null, .len = 0 } };

    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const key = bytesConst(req.key.data, req.key.len) orelse return failDb(handle, error.InvalidArgument);

    var result = handle.db.kvGet(allocator, namespace, key) catch |err| return failDb(handle, err);
    // Transfer ownership of the allocation from kv_impl.GetResult to zova_kv_get_result.
    out.* = .{ .found = if (result.found) 1 else 0, .value = .{ .data = result.value.ptr, .len = result.value.len } };
    result.value = &.{};
    return okDb(handle);
}

pub fn zova_kv_get_many(request: ?*const zova_kv_get_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = .{ .items = null, .len = 0 };

    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const keys = kvKeySlices(req.keys, req.keys_len) catch |err| return failDb(handle, err);
    defer allocator.free(keys);

    const results = handle.db.kvGetMany(allocator, namespace, keys) catch |err| return failDb(handle, err);
    errdefer {
        for (results) |item| item.deinit(allocator);
        allocator.free(results);
    }

    const items = allocator.alloc(zova_kv_get_result, results.len) catch |err| return failDb(handle, err);
    for (results, items) |*result, *item| {
        item.* = .{ .found = if (result.found) 1 else 0, .value = .{ .data = result.value.ptr, .len = result.value.len } };
        result.value = &.{};
    }
    allocator.free(results);
    out.* = .{ .items = items.ptr, .len = items.len };
    return okDb(handle);
}

pub fn zova_kv_put(request: ?*const zova_kv_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const key = bytesConst(req.key.data, req.key.len) orelse return failDb(handle, error.InvalidArgument);
    const value = bytesConst(req.value.data, req.value.len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.kvPut(namespace, key, value) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_put_many(request: ?*const zova_kv_put_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const entries = kvPutEntrySlices(req.entries, req.entries_len) catch |err| return failDb(handle, err);
    defer allocator.free(entries);
    handle.db.kvPutMany(namespace, entries) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_delete(request: ?*const zova_kv_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const key = bytesConst(req.key.data, req.key.len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.kvDelete(namespace, key) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_delete_many(request: ?*const zova_kv_delete_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const keys = kvKeySlices(req.keys, req.keys_len) catch |err| return failDb(handle, err);
    defer allocator.free(keys);
    handle.db.kvDeleteMany(namespace, keys) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_count(request: ?*const zova_kv_count_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_count orelse return failDb(handle, error.InvalidArgument);
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.kvCount(namespace) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_clear_namespace(request: ?*const zova_kv_clear_namespace_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.kvClearNamespace(namespace) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_scan(request: ?*const zova_kv_scan_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = .{ .items = null, .len = 0, .has_more = 0 };

    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const prefix = bytesConst(req.prefix.data, req.prefix.len) orelse return failDb(handle, error.InvalidArgument);
    const start = optionalBytes(req.start, req.has_start) catch |err| return failDb(handle, err);
    const end = optionalBytes(req.end, req.has_end) catch |err| return failDb(handle, err);
    const after = optionalBytes(req.after, req.has_after) catch |err| return failDb(handle, err);

    const result = handle.db.kvScan(allocator, namespace, .{
        .prefix = prefix,
        .start = start,
        .end = end,
        .after = after,
        .limit = req.limit,
        .keys_only = req.keys_only != 0,
    }) catch |err| return failDb(handle, err);
    const items = allocator.alloc(zova_kv_entry, result.entries.len) catch |err| {
        result.deinit(allocator);
        return failDb(handle, err);
    };
    // Transfer each key and value allocation to the C result.
    for (result.entries, items) |entry, *item| {
        item.* = .{
            .key = .{ .data = entry.key.ptr, .len = entry.key.len },
            .value = .{ .data = entry.value.ptr, .len = entry.value.len },
        };
    }
    allocator.free(result.entries);
    out.* = .{ .items = items.ptr, .len = items.len, .has_more = if (result.has_more) 1 else 0 };
    return okDb(handle);
}

pub fn zova_kv_put_if_absent(request: ?*const zova_kv_put_if_absent_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_applied orelse return failDb(handle, error.InvalidArgument);
    out.* = 0;
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const key = bytesConst(req.key.data, req.key.len) orelse return failDb(handle, error.InvalidArgument);
    const value = bytesConst(req.value.data, req.value.len) orelse return failDb(handle, error.InvalidArgument);
    const applied = handle.db.kvPutIfAbsent(namespace, key, value) catch |err| return failDb(handle, err);
    out.* = if (applied) 1 else 0;
    return okDb(handle);
}

pub fn zova_kv_compare_and_put(request: ?*const zova_kv_compare_and_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_applied orelse return failDb(handle, error.InvalidArgument);
    out.* = 0;
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const key = bytesConst(req.key.data, req.key.len) orelse return failDb(handle, error.InvalidArgument);
    const expected = bytesConst(req.expected.data, req.expected.len) orelse return failDb(handle, error.InvalidArgument);
    const value = bytesConst(req.value.data, req.value.len) orelse return failDb(handle, error.InvalidArgument);
    const applied = handle.db.kvCompareAndPut(namespace, key, expected, value) catch |err| return failDb(handle, err);
    out.* = if (applied) 1 else 0;
    return okDb(handle);
}

pub fn zova_kv_compare_and_delete(request: ?*const zova_kv_compare_and_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_applied orelse return failDb(handle, error.InvalidArgument);
    out.* = 0;
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const key = bytesConst(req.key.data, req.key.len) orelse return failDb(handle, error.InvalidArgument);
    const expected = bytesConst(req.expected.data, req.expected.len) orelse return failDb(handle, error.InvalidArgument);
    const applied = handle.db.kvCompareAndDelete(namespace, key, expected) catch |err| return failDb(handle, err);
    out.* = if (applied) 1 else 0;
    return okDb(handle);
}

fn optionalBytes(bytes: @import("types.zig").zova_kv_bytes, present: u8) error{InvalidArgument}!?[]const u8 {
    if (present == 0) return null;
    return bytesConst(bytes.data, bytes.len) orelse error.InvalidArgument;
}
