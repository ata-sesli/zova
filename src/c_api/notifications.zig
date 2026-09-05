//! Notification subscription and delivery entrypoint implementations.

const std = @import("std");

const SubscriptionHandle = @import("handles.zig").SubscriptionHandle;
const allocator = @import("values.zig").allocator;
const bytesConst = @import("values.zig").bytesConst;
const databaseHandle = @import("handles.zig").databaseHandle;
const failDb = @import("errors.zig").failDb;
const fillNotification = @import("results.zig").fillNotification;
const okDb = @import("errors.zig").okDb;
const subscriptionHandle = @import("handles.zig").subscriptionHandle;
const zova_database_listen_request = @import("types.zig").zova_database_listen_request;
const zova_database_notify_request = @import("types.zig").zova_database_notify_request;
const zova_notification_free = @import("results.zig").zova_notification_free;
const zova_status = @import("types.zig").zova_status;
const zova_subscription = @import("types.zig").zova_subscription;
const zova_subscription_try_receive_request = @import("types.zig").zova_subscription_try_receive_request;

pub fn zova_database_notify(request: ?*const zova_database_notify_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const channel = req.channel orelse return failDb(handle, error.InvalidArgument);
    const payload = bytesConst(req.payload, req.payload_len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.notify(std.mem.span(channel), payload) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_listen(request: ?*const zova_database_listen_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const channel = req.channel orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_subscription orelse return failDb(handle, error.InvalidArgument);
    out.* = null;

    const subscription = handle.db.listen(std.mem.span(channel)) catch |err| return failDb(handle, err);
    const subscription_handle = allocator.create(SubscriptionHandle) catch |err| {
        var cleanup = subscription;
        cleanup.deinit();
        return failDb(handle, err);
    };
    subscription_handle.* = .{ .db = handle, .subscription = subscription };
    handle.live_subscriptions += 1;
    out.* = @ptrCast(subscription_handle);
    return okDb(handle);
}

pub fn zova_subscription_try_receive(request: ?*const zova_subscription_try_receive_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = subscriptionHandle(req.subscription) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out_notification = req.out_notification orelse return failDb(handle.db, error.InvalidArgument);
    const out_has_notification = req.out_has_notification orelse return failDb(handle.db, error.InvalidArgument);

    zova_notification_free(out_notification);
    out_has_notification.* = 0;
    var notification = handle.subscription.tryReceive(allocator) catch |err| return failDb(handle.db, err);
    if (notification) |*value| {
        defer value.deinit(allocator);
        fillNotification(out_notification, value.*) catch |err| return failDb(handle.db, err);
        out_has_notification.* = 1;
    }
    return okDb(handle.db);
}

pub fn zova_subscription_close(subscription: ?*zova_subscription) callconv(.c) zova_status {
    const handle = subscriptionHandle(subscription) orelse return .INVALID_ARGUMENT;
    const db_handle = handle.db;
    db_handle.mutex.lock();
    defer db_handle.mutex.unlock();
    handle.subscription.deinit();
    std.debug.assert(db_handle.live_subscriptions > 0);
    db_handle.live_subscriptions -= 1;
    allocator.destroy(handle);
    return okDb(db_handle);
}
