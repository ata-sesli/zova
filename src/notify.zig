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

const NotificationQueue = struct {
    storage: []Notification = &.{},
    head: usize = 0,
    len: usize = 0,

    fn index(self: *const NotificationQueue, offset: usize) usize {
        const position = self.head + offset;
        return if (position >= self.storage.len) position - self.storage.len else position;
    }

    fn front(self: *NotificationQueue) *Notification {
        std.debug.assert(self.len > 0);
        return &self.storage[self.head];
    }

    fn pop(self: *NotificationQueue) Notification {
        const value = self.front().*;
        self.head = self.index(1);
        self.len -= 1;
        return value;
    }

    fn ensureUnusedCapacity(self: *NotificationQueue, allocator: std.mem.Allocator) !void {
        if (self.len < self.storage.len) return;
        std.debug.assert(self.len < queue_capacity);
        const capacity = @min(queue_capacity, @max(@as(usize, 8), self.storage.len * 2));
        const storage = try allocator.alloc(Notification, capacity);
        for (0..self.len) |i| storage[i] = self.storage[self.index(i)];
        allocator.free(self.storage);
        self.storage = storage;
        self.head = 0;
    }

    fn appendAssumeCapacity(self: *NotificationQueue, value: Notification) void {
        std.debug.assert(self.len < self.storage.len);
        self.storage[self.index(self.len)] = value;
        self.len += 1;
    }

    fn deinit(self: *NotificationQueue, allocator: std.mem.Allocator) void {
        while (self.len > 0) {
            var notification = self.pop();
            notification.deinit(allocator);
        }
        allocator.free(self.storage);
        self.* = .{};
    }
};

const SubscriptionState = struct {
    id: u64,
    channel: []u8,
    queue: NotificationQueue = .{},
    dropped_pending: u64 = 0,

    fn deinit(self: *SubscriptionState, allocator: std.mem.Allocator) void {
        allocator.free(self.channel);
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

test "failed receive allocation leaves the oldest notification available" {
    for (0..2) |fail_index| {
        var hub = Hub.init(std.testing.allocator);
        defer hub.deinit();
        var sub = try hub.listen("test");
        defer sub.deinit();
        try hub.notify("test", "payload");
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, sub.tryReceive(failing.allocator()));
        var retry = try sub.tryReceive(std.testing.allocator);
        try std.testing.expect(retry != null);
        defer retry.?.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u64, 1), retry.?.sequence);
        try std.testing.expectEqualStrings("payload", retry.?.payload);
    }
}

test "notification queue wraps and repeatedly transfers overflow counts" {
    var hub = Hub.init(std.testing.allocator);
    defer hub.deinit();
    var sub = try hub.listen("test");
    defer sub.deinit();
    for (0..3) |round| {
        const base = round * 2024;
        for (0..1024) |_| try hub.notify("test", "payload");
        for (0..700) |i| {
            var note = (try sub.tryReceive(std.testing.allocator)).?;
            defer note.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u64, base + i + 1), note.sequence);
            try std.testing.expectEqual(@as(u64, 0), note.dropped_before);
        }
        for (0..1000) |_| try hub.notify("test", "payload");
        for (0..1024) |i| {
            var note = (try sub.tryReceive(std.testing.allocator)).?;
            defer note.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u64, base + 1001 + i), note.sequence);
            try std.testing.expectEqual(@as(u64, if (i == 0) 300 else 0), note.dropped_before);
        }
        try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    }
    sub.deinit();
    try std.testing.expectError(error.InvalidArgument, sub.tryReceive(std.testing.allocator));
}

test "wrapped queue growth failure preserves live entries and ownership" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var hub = Hub.init(failing.allocator());
    defer hub.deinit();
    var sub = try hub.listen("test");
    defer sub.deinit();
    for (0..8) |_| try hub.notify("test", "payload");
    for (0..3) |_| {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        note.deinit(std.testing.allocator);
    }
    for (0..3) |_| try hub.notify("test", "payload");
    // makeNotification + delivery clone allocate twice each; fail the grow.
    failing.fail_index = failing.alloc_index + 4;
    try std.testing.expectError(error.OutOfMemory, hub.notify("test", "failed"));
    failing.fail_index = std.math.maxInt(usize);
    try hub.notify("test", "retry");
    for (0..9) |i| {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u64, if (i < 8) i + 4 else 13), note.sequence);
        try std.testing.expectEqual(@as(u64, 0), note.dropped_before);
    }
    // Destruction also frees unread entries when the head is not zero.
    for (0..10) |_| try hub.notify("test", "unread");
}

test "commit allocation failure is reported on the next notification" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var hub = Hub.init(failing.allocator());
    defer hub.deinit();
    var sub = try hub.listen("test");
    defer sub.deinit();
    try hub.begin();
    try hub.notify("test", "pending");
    failing.fail_index = failing.alloc_index;
    hub.commit();
    failing.fail_index = std.math.maxInt(usize);
    try hub.notify("test", "next");
    var note = (try sub.tryReceive(std.testing.allocator)).?;
    defer note.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), note.sequence);
    try std.testing.expectEqual(@as(u64, 1), note.dropped_before);
    try std.testing.expectEqualStrings("next", note.payload);
}

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
        if (subscription.queue.len == 0) return null;
        // The caller may use a different allocator. Clone before consuming so
        // either allocation can fail without losing the notification or owner.
        const clone = try cloneNotification(allocator, subscription.queue.front().*);
        var notification = subscription.queue.pop();
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

        if (subscription.queue.len < queue_capacity) {
            try subscription.queue.ensureUnusedCapacity(self.allocator);
        }

        if (subscription.dropped_pending != 0) {
            queued.dropped_before +|= subscription.dropped_pending;
            subscription.dropped_pending = 0;
        }

        if (subscription.queue.len >= queue_capacity) {
            var dropped = subscription.queue.pop();
            const dropped_before_next = dropped.dropped_before + 1;
            dropped.deinit(self.allocator);
            if (subscription.queue.len > 0) {
                subscription.queue.front().dropped_before += dropped_before_next;
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
