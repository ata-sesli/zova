//! Key-value batch and single-operation entrypoint implementations.

const allocator = @import("values.zig").allocator;
const bytesConst = @import("values.zig").bytesConst;
const databaseHandle = @import("handles.zig").databaseHandle;
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
const zova_status = @import("types.zig").zova_status;

pub fn zova_kv_get(request: ?*const zova_kv_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
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
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
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
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const key = bytesConst(req.key.data, req.key.len) orelse return failDb(handle, error.InvalidArgument);
    const value = bytesConst(req.value.data, req.value.len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.kvPut(namespace, key, value) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_put_many(request: ?*const zova_kv_put_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const entries = kvPutEntrySlices(req.entries, req.entries_len) catch |err| return failDb(handle, err);
    defer allocator.free(entries);
    handle.db.kvPutMany(namespace, entries) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_delete(request: ?*const zova_kv_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const key = bytesConst(req.key.data, req.key.len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.kvDelete(namespace, key) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_delete_many(request: ?*const zova_kv_delete_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    const keys = kvKeySlices(req.keys, req.keys_len) catch |err| return failDb(handle, err);
    defer allocator.free(keys);
    handle.db.kvDeleteMany(namespace, keys) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_count(request: ?*const zova_kv_count_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_count orelse return failDb(handle, error.InvalidArgument);
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.kvCount(namespace) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_kv_clear_namespace(request: ?*const zova_kv_clear_namespace_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const namespace = bytesConst(req.ns.data, req.ns.len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.kvClearNamespace(namespace) catch |err| return failDb(handle, err);
    return okDb(handle);
}
