//! Same-process, per-handle app notifications for Zova.
//!
//! Notifications are explicit and in-memory. They are queued on subscriptions
//! only after the surrounding Zova transaction/savepoint scope commits.

const std = @import("std");
const sqlite = @import("sqlite.zig");

const c = sqlite.c;

pub const max_channel_len = 128;
pub const max_payload_len = 64 * 1024;
pub const queue_capacity = 1024;

pub const Error = sqlite.Error || error{
    InvalidArgument,
    OutOfMemory,
};

pub const Notification = struct {
    channel: []u8,
    payload: []u8,
    sequence: u64,
    dropped_before: u64,

    pub fn deinit(self: *Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.channel);
        allocator.free(self.payload);
        self.* = .{
            .channel = &.{},
            .payload = &.{},
            .sequence = 0,
            .dropped_before = 0,
        };
    }
};

pub const NotificationSubscription = struct {
    hub: *Hub,
    id: u64,
    closed: bool = false,

    pub fn tryReceive(self: *NotificationSubscription, allocator: std.mem.Allocator) Error!?Notification {
        if (self.closed) return error.InvalidArgument;
        return try self.hub.tryReceive(allocator, self.id);
    }

    pub fn deinit(self: *NotificationSubscription) void {
        if (self.closed) return;
        self.hub.closeSubscription(self.id);
        self.closed = true;
    }
};

const SubscriptionState = struct {
    id: u64,
    channel: []u8,
    queue: std.ArrayList(Notification) = .empty,
    dropped_pending: u64 = 0,

    fn deinit(self: *SubscriptionState, allocator: std.mem.Allocator) void {
        allocator.free(self.channel);
        for (self.queue.items) |*notification| {
            notification.deinit(allocator);
        }
        self.queue.deinit(allocator);
        self.* = .{ .id = 0, .channel = &.{} };
    }
};

const PendingScope = struct {
    name: ?[]u8 = null,
    notifications: std.ArrayList(Notification) = .empty,

    fn clearNotifications(self: *PendingScope, allocator: std.mem.Allocator) void {
        for (self.notifications.items) |*notification| {
            notification.deinit(allocator);
        }
        self.notifications.clearRetainingCapacity();
    }

    fn deinit(self: *PendingScope, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        self.clearNotifications(allocator);
        self.notifications.deinit(allocator);
        self.* = .{};
    }
};

pub const Hub = struct {
    allocator: std.mem.Allocator,
    subscriptions: std.ArrayList(SubscriptionState) = .empty,
    scopes: std.ArrayList(PendingScope) = .empty,
    next_subscription_id: u64 = 1,
    next_sequence: u64 = 1,
    sqlite_handle: ?*c.sqlite3 = null,

    pub fn init(allocator: std.mem.Allocator) Hub {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Hub) void {
        for (self.subscriptions.items) |*subscription| {
            subscription.deinit(self.allocator);
        }
        self.subscriptions.deinit(self.allocator);
        for (self.scopes.items) |*scope| {
            scope.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn listen(self: *Hub, channel: []const u8) Error!NotificationSubscription {
        try validateChannel(channel);
        const id = self.next_subscription_id;
        self.next_subscription_id +%= 1;
        const copy = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(copy);
        try self.subscriptions.append(self.allocator, .{
            .id = id,
            .channel = copy,
        });
        return .{ .hub = self, .id = id };
    }

    pub fn notify(self: *Hub, channel: []const u8, payload: []const u8) Error!void {
        try validateChannel(channel);
        try validatePayload(payload);

        var notification = try self.makeNotification(channel, payload);
        errdefer notification.deinit(self.allocator);

        if (self.scopes.items.len > 0) {
            try self.scopes.items[self.scopes.items.len - 1].notifications.append(self.allocator, notification);
        } else {
            try self.deliver(notification);
            notification.deinit(self.allocator);
        }
    }

    pub fn notifyFromSql(self: *Hub, channel: []const u8, payload: []const u8) Error!void {
        if (self.scopes.items.len == 0) {
            if (self.sqlite_handle) |handle| {
                if (c.sqlite3_get_autocommit(handle) == 0) return error.InvalidArgument;
            }
        }
        try self.notify(channel, payload);
    }

    pub fn begin(self: *Hub) Error!void {
        try self.scopes.append(self.allocator, .{});
    }

    pub fn commit(self: *Hub) void {
        if (self.scopes.items.len == 0) return;

        for (self.scopes.items) |*scope| {
            for (scope.notifications.items) |notification| {
                self.deliverBestEffort(notification);
            }
            scope.deinit(self.allocator);
        }
        self.scopes.items.len = 0;
    }

    pub fn rollback(self: *Hub) void {
        self.clearScopes();
    }

    pub fn savepoint(self: *Hub, name: []const u8) Error!void {
        const copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(copy);
        try self.scopes.append(self.allocator, .{ .name = copy });
    }

    pub fn rollbackToSavepoint(self: *Hub, name: []const u8) void {
        const index = self.findSavepoint(name) orelse return;
        var cursor = self.scopes.items.len;
        while (cursor > index + 1) {
            cursor -= 1;
            self.scopes.items[cursor].deinit(self.allocator);
        }
        self.scopes.items[index].clearNotifications(self.allocator);
        self.scopes.items.len = index + 1;
    }

    pub fn cancelLatestSavepoint(self: *Hub, name: []const u8) void {
        if (self.scopes.items.len == 0) return;
        const index = self.scopes.items.len - 1;
        const scope_name = self.scopes.items[index].name orelse return;
        if (!std.mem.eql(u8, scope_name, name)) return;
        self.scopes.items[index].deinit(self.allocator);
        self.scopes.items.len -= 1;
    }

    pub fn prepareReleaseSavepoint(self: *Hub, name: []const u8) Error!void {
        const index = self.findSavepoint(name) orelse return;
        if (index == 0) return;
        const child_len = self.scopes.items[index].notifications.items.len;
        try self.scopes.items[index - 1].notifications.ensureUnusedCapacity(self.allocator, child_len);
    }

    pub fn releaseSavepoint(self: *Hub, name: []const u8) void {
        const index = self.findSavepoint(name) orelse return;

        if (index == 0) {
            for (self.scopes.items[index].notifications.items) |notification| {
                self.deliverBestEffort(notification);
            }
        } else {
            moveNotificationsAssumeCapacity(&self.scopes.items[index - 1].notifications, &self.scopes.items[index].notifications);
        }

        self.scopes.items[index].deinit(self.allocator);
        std.mem.copyForwards(PendingScope, self.scopes.items[index .. self.scopes.items.len - 1], self.scopes.items[index + 1 .. self.scopes.items.len]);
        self.scopes.items.len -= 1;
    }

    pub fn tryReceive(self: *Hub, allocator: std.mem.Allocator, id: u64) Error!?Notification {
        const subscription = self.findSubscription(id) orelse return error.InvalidArgument;
        if (subscription.queue.items.len == 0) return null;
        var notification = subscription.queue.items[0];
        if (subscription.queue.items.len > 1) {
            std.mem.copyForwards(Notification, subscription.queue.items[0 .. subscription.queue.items.len - 1], subscription.queue.items[1..subscription.queue.items.len]);
        }
        subscription.queue.items.len -= 1;

        const clone = try cloneNotification(allocator, notification);
        notification.deinit(self.allocator);
        return clone;
    }

    pub fn closeSubscription(self: *Hub, id: u64) void {
        const index = self.findSubscriptionIndex(id) orelse return;
        self.subscriptions.items[index].deinit(self.allocator);
        if (self.subscriptions.items.len > index + 1) {
            std.mem.copyForwards(SubscriptionState, self.subscriptions.items[index .. self.subscriptions.items.len - 1], self.subscriptions.items[index + 1 .. self.subscriptions.items.len]);
        }
        self.subscriptions.items.len -= 1;
    }

    fn makeNotification(self: *Hub, channel: []const u8, payload: []const u8) Error!Notification {
        const channel_copy = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(channel_copy);
        const payload_copy = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(payload_copy);

        const sequence = self.next_sequence;
        self.next_sequence +%= 1;
        return .{
            .channel = channel_copy,
            .payload = payload_copy,
            .sequence = sequence,
            .dropped_before = 0,
        };
    }

    fn deliver(self: *Hub, notification: Notification) Error!void {
        for (self.subscriptions.items) |*subscription| {
            if (!std.mem.eql(u8, subscription.channel, notification.channel)) continue;
            const clone = try cloneNotification(self.allocator, notification);
            try self.enqueueNotification(subscription, clone);
        }
    }

    fn deliverBestEffort(self: *Hub, notification: Notification) void {
        for (self.subscriptions.items) |*subscription| {
            if (!std.mem.eql(u8, subscription.channel, notification.channel)) continue;
            const clone = cloneNotification(self.allocator, notification) catch {
                subscription.dropped_pending +|= 1;
                continue;
            };
            self.enqueueNotification(subscription, clone) catch {
                subscription.dropped_pending +|= 1;
            };
        }
    }

    fn enqueueNotification(self: *Hub, subscription: *SubscriptionState, clone: Notification) Error!void {
        var queued = clone;
        errdefer queued.deinit(self.allocator);

        if (subscription.queue.items.len < queue_capacity) {
            try subscription.queue.ensureUnusedCapacity(self.allocator, 1);
        }

        if (subscription.dropped_pending != 0) {
            queued.dropped_before +|= subscription.dropped_pending;
            subscription.dropped_pending = 0;
        }

        if (subscription.queue.items.len >= queue_capacity) {
            var dropped = subscription.queue.items[0];
            const dropped_before_next = dropped.dropped_before + 1;
            if (subscription.queue.items.len > 1) {
                std.mem.copyForwards(Notification, subscription.queue.items[0 .. subscription.queue.items.len - 1], subscription.queue.items[1..subscription.queue.items.len]);
            }
            subscription.queue.items.len -= 1;
            dropped.deinit(self.allocator);
            if (subscription.queue.items.len > 0) {
                subscription.queue.items[0].dropped_before += dropped_before_next;
            } else {
                queued.dropped_before += dropped_before_next;
            }
        }
        subscription.queue.appendAssumeCapacity(queued);
    }

    fn findSubscription(self: *Hub, id: u64) ?*SubscriptionState {
        for (self.subscriptions.items) |*subscription| {
            if (subscription.id == id) return subscription;
        }
        return null;
    }

    fn findSubscriptionIndex(self: *Hub, id: u64) ?usize {
        for (self.subscriptions.items, 0..) |subscription, index| {
            if (subscription.id == id) return index;
        }
        return null;
    }

    fn findSavepoint(self: *Hub, name: []const u8) ?usize {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (self.scopes.items[index].name) |scope_name| {
                if (std.mem.eql(u8, scope_name, name)) return index;
            }
        }
        return null;
    }

    fn clearScopes(self: *Hub) void {
        for (self.scopes.items) |*scope| {
            scope.deinit(self.allocator);
        }
        self.scopes.items.len = 0;
    }
};

pub fn validateChannel(channel: []const u8) Error!void {
    if (channel.len == 0 or channel.len > max_channel_len) return error.InvalidArgument;
    if (hasReservedZovaPrefix(channel)) return error.InvalidArgument;
    for (channel) |byte| {
        if (!isChannelByte(byte)) return error.InvalidArgument;
    }
}

pub fn validatePayload(payload: []const u8) Error!void {
    if (payload.len > max_payload_len) return error.InvalidArgument;
    if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidArgument;
}

pub fn registerSql(db: *sqlite.Database, hub: *Hub) sqlite.Error!void {
    hub.sqlite_handle = db.handle;
    const flags = c.SQLITE_UTF8;
    const rc = c.sqlite3_create_function_v2(
        db.handle,
        "zova_notify",
        2,
        flags,
        hub,
        zovaNotifyFunc,
        null,
        null,
        null,
    );
    if (rc != c.SQLITE_OK) return mapResultCode(rc);
}

fn zovaNotifyFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const context = ctx orelse return;
    if (argc != 2) {
        resultError(context, "zova_notify expects 2 arguments");
        return;
    }

    const hub_ptr = c.sqlite3_user_data(context) orelse {
        resultError(context, "zova notification hub missing");
        return;
    };
    const hub: *Hub = @ptrCast(@alignCast(hub_ptr));

    const channel = valueText(argv[0] orelse {
        resultError(context, "invalid notification channel");
        return;
    }) catch |err| {
        resultError(context, errorMessage(err));
        return;
    };
    const payload = valueText(argv[1] orelse {
        resultError(context, "invalid notification payload");
        return;
    }) catch |err| {
        resultError(context, errorMessage(err));
        return;
    };

    hub.notifyFromSql(channel, payload) catch |err| {
        resultError(context, errorMessage(err));
        return;
    };
    c.sqlite3_result_int(context, 1);
}

fn valueText(value: *c.sqlite3_value) Error![]const u8 {
    if (c.sqlite3_value_type(value) == c.SQLITE_NULL) return error.InvalidArgument;
    const len = c.sqlite3_value_bytes(value);
    const ptr = c.sqlite3_value_text(value) orelse return error.InvalidArgument;
    return ptr[0..@intCast(len)];
}

fn resultError(ctx: *c.sqlite3_context, message: [:0]const u8) void {
    c.sqlite3_result_error(ctx, message.ptr, -1);
}

fn errorMessage(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.InvalidArgument => "invalid notification channel or payload",
        error.OutOfMemory => "out of memory",
        else => "zova notify failed",
    };
}

fn cloneNotification(allocator: std.mem.Allocator, notification: Notification) Error!Notification {
    const channel = try allocator.dupe(u8, notification.channel);
    errdefer allocator.free(channel);
    const payload = try allocator.dupe(u8, notification.payload);
    errdefer allocator.free(payload);
    return .{
        .channel = channel,
        .payload = payload,
        .sequence = notification.sequence,
        .dropped_before = notification.dropped_before,
    };
}

fn moveNotificationsAssumeCapacity(
    destination: *std.ArrayList(Notification),
    source: *std.ArrayList(Notification),
) void {
    for (source.items) |notification| {
        destination.appendAssumeCapacity(notification);
    }
    source.items.len = 0;
}

fn hasReservedZovaPrefix(value: []const u8) bool {
    const reserved = "_zova_";
    if (value.len < reserved.len) return false;
    for (reserved, 0..) |expected, index| {
        if (asciiLower(value[index]) != expected) return false;
    }
    return true;
}

fn isChannelByte(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or
        byte == '_' or byte == '.' or byte == ':' or byte == '-';
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn mapResultCode(rc: c_int) sqlite.Error {
    return switch (rc) {
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_NOMEM => error.NoMemory,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_CORRUPT => error.Corrupt,
        else => error.SqliteError,
    };
}
