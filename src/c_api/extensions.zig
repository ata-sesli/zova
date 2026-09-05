//! Extension lifecycle and bundle trust entrypoint implementations.

const std = @import("std");
const zova = @import("../zova.zig");

const allocator = @import("values.zig").allocator;
const clearMessage = @import("errors.zig").clearMessage;
const databaseHandle = @import("handles.zig").databaseHandle;
const emptyExtensionInfo = @import("results.zig").emptyExtensionInfo;
const emptyExtensionList = @import("results.zig").emptyExtensionList;
const failDb = @import("errors.zig").failDb;
const failMessage = @import("errors.zig").failMessage;
const fillExtensionInfo = @import("results.zig").fillExtensionInfo;
const fillExtensionList = @import("results.zig").fillExtensionList;
const okDb = @import("errors.zig").okDb;
const zova_database_extension_info_request = @import("types.zig").zova_database_extension_info_request;
const zova_database_extension_list_request = @import("types.zig").zova_database_extension_list_request;
const zova_database_extension_request = @import("types.zig").zova_database_extension_request;
const zova_database_simple_request = @import("types.zig").zova_database_simple_request;
const zova_extension_bundle_request = @import("types.zig").zova_extension_bundle_request;
const zova_extension_bundle_untrust_request = @import("types.zig").zova_extension_bundle_untrust_request;
const zova_status = @import("types.zig").zova_status;

pub fn zova_extension_bundle_verify(request: ?*const zova_extension_bundle_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const bundle_path = req.bundle_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    zova.extension_dynamic.verifyBundleEntrypoint(allocator, std.mem.span(bundle_path)) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    return .OK;
}

pub fn zova_extension_bundle_trust(request: ?*const zova_extension_bundle_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const bundle_path = req.bundle_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    var record = zova.extension_dynamic.trustBundle(allocator, std.mem.span(bundle_path), trustStoreOptions(req.trust_store_path)) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    record.deinit(allocator);
    return .OK;
}

pub fn zova_extension_bundle_untrust(request: ?*const zova_extension_bundle_untrust_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const identifier = req.identifier orelse return failMessage(req.out_error_message, error.InvalidArgument);
    const removed = zova.extension_dynamic.untrust(allocator, std.mem.span(identifier), trustStoreOptions(req.trust_store_path)) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    if (req.out_removed) |out| out.* = if (removed) 1 else 0;
    return .OK;
}

pub fn zova_database_extension_install(request: ?*const zova_database_extension_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    handle.db.installExtension(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_extension_list(request: ?*const zova_database_extension_list_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_list orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyExtensionList();
    var list = handle.db.listExtensions(allocator) catch |err| return failDb(handle, err);
    defer list.deinit(allocator);
    fillExtensionList(out, list.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_extension_info(request: ?*const zova_database_extension_info_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_info orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyExtensionInfo();
    var info = handle.db.extensionInfo(allocator, std.mem.span(name)) catch |err| return failDb(handle, err);
    defer info.deinit(allocator);
    fillExtensionInfo(out, info) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_extension_check(request: ?*const zova_database_extension_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    handle.db.checkExtension(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_extension_check_all(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    var list = handle.db.listExtensions(allocator) catch |err| return failDb(handle, err);
    defer list.deinit(allocator);
    for (list.items) |item| {
        handle.db.checkExtension(item.name) catch |err| return failDb(handle, err);
    }
    return okDb(handle);
}

pub fn zova_database_extension_drop(request: ?*const zova_database_extension_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    handle.db.dropExtension(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn bundlePathSlices(gpa: std.mem.Allocator, paths: ?[*]const ?[*:0]const u8, count: usize) ![]const []const u8 {
    if (count == 0) return try gpa.alloc([]const u8, 0);
    const raw_paths = paths orelse return error.InvalidArgument;
    const out = try gpa.alloc([]const u8, count);
    errdefer gpa.free(out);
    for (raw_paths[0..count], 0..) |path, index| {
        const path_z = path orelse return error.InvalidArgument;
        out[index] = std.mem.span(path_z);
    }
    return out;
}

pub fn trustStoreOptions(path: ?[*:0]const u8) zova.DynamicExtensionTrustStoreOptions {
    return .{ .path = if (path) |value| std.mem.span(value) else null };
}

// Opaque handles are just erased DatabaseHandle/WriterHandle pointers. Casts
// stay local to this module so the ABI can keep exposing incomplete C structs.
