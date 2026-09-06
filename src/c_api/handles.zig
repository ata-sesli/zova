//! Private C ABI handle state, mutexes, and checked handle conversion.

const std = @import("std");
const zova = @import("../zova.zig");
const sqlite = @import("../sqlite.zig");

const allocator = @import("values.zig").allocator;
const zova_database = @import("types.zig").zova_database;
const zova_fresh_build = @import("types.zig").zova_fresh_build;
const zova_fresh_build_profile = @import("types.zig").zova_fresh_build_profile;
const zova_object_reader = @import("types.zig").zova_object_reader;
const zova_object_writer = @import("types.zig").zova_object_writer;
const zova_sql_destroy_callback = @import("types.zig").zova_sql_destroy_callback;
const zova_sql_function_call = @import("types.zig").zova_sql_function_call;
const zova_sql_result = @import("types.zig").zova_sql_result;
const zova_statement = @import("types.zig").zova_statement;
const zova_subscription = @import("types.zig").zova_subscription;

// This mode is private to the single-worker Emscripten build. Native callers
// always retain per-handle serialization.
const AbiMutex = if (@import("builtin").os.tag == .emscripten) struct {
    pub fn lock(_: *@This()) void {}
    pub fn unlock(_: *@This()) void {}
} else struct {
    state: std.Io.Mutex = .init,

    pub fn lock(self: *AbiMutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    pub fn unlock(self: *AbiMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

// These opaque declarations match `include/zova.h`. The real state lives in
// DatabaseHandle and WriterHandle below so C callers cannot depend on layout.

pub const DatabaseHandle = struct {
    db: zova.Database,
    dynamic_extensions: ?zova.DynamicExtensionSet = null,
    extension_registry: ?zova.DynamicExtensionOwnedRegistry = null,
    // One C ABI database handle is internally serialized. This mutex protects
    // the SQLite/Zova handle, child-handle counts, and connection-scoped error
    // message. It is intentionally per-handle, not global; separate handles can
    // still run independently and follow normal SQLite locking behavior.
    mutex: AbiMutex = .{},
    live_statements: usize = 0,
    live_writers: usize = 0,
    live_readers: usize = 0,
    live_subscriptions: usize = 0,
    fresh_build_active: bool = false,
    sql_functions: std.ArrayList(SqlFunctionRegistration) = .empty,
    // Connection-scoped diagnostic text. This mirrors SQLite's model closely:
    // callers can ask the database handle for the most recent useful message,
    // and the pointer is borrowed until another call on the handle replaces it.
    last_error: ?[:0]u8 = null,
};

pub const DeferredFreshIndex = struct {
    name: [:0]u8,
    sql: [:0]u8,
};

pub const FreshBuildCachePolicy = enum {
    graph_only,
    session,
    graph_and_deferred_indexes,
};

pub const FreshBuildCacheDiagnostics = struct {
    deferred_index_ms: f64 = 0,
    cache_restore_ms: f64 = 0,
    transaction_finish_ms: f64 = 0,
    baseline_foreign_key_check_ms: f64 = 0,
    baseline_foreign_key_check_ran: bool = false,
    foreign_key_check_ms: f64 = 0,
    foreign_key_check_ran: bool = false,
    deferred_foreign_keys_pending: bool = false,
    validation_fast_path: bool = false,
};

const FreshBuildValidationEvidence = struct {
    foreign_keys_enforced: bool,
    baseline_foreign_keys_validated: bool,
};

pub const FreshBuildHandle = struct {
    database: *DatabaseHandle,
    owns_transaction: bool,
    previous_cache_size: ?i64 = null,
    active: bool = true,
    deferred_indexes: std.ArrayList(DeferredFreshIndex) = .empty,
    prepared_tables: std.ArrayList([]u8) = .empty,
    node_keys: []i64 = &.{},
    edge_keys: []i64 = &.{},
    graph_loaded: bool = false,
    validation: FreshBuildValidationEvidence,
    profile: zova_fresh_build_profile = .{},
    cache_diagnostics: FreshBuildCacheDiagnostics = .{},

    pub fn deinit(self: *FreshBuildHandle) void {
        for (self.deferred_indexes.items) |item| {
            allocator.free(item.name);
            allocator.free(item.sql);
        }
        self.deferred_indexes.deinit(allocator);
        for (self.prepared_tables.items) |name| allocator.free(name);
        self.prepared_tables.deinit(allocator);
        if (self.node_keys.len != 0) allocator.free(self.node_keys);
        if (self.edge_keys.len != 0) allocator.free(self.edge_keys);
    }
};

const SqlFunctionRegistration = struct {
    name: [:0]u8,
    arity: c_int,

    pub fn deinit(self: *SqlFunctionRegistration) void {
        allocator.free(self.name);
    }
};

pub const SqlScalarFunctionContext = struct {
    user_data: ?*anyopaque,
    callback: *const fn (?*anyopaque, ?*const zova_sql_function_call, ?*zova_sql_result) callconv(.c) void,
    destroy: zova_sql_destroy_callback,
};

pub const WriterHandle = struct {
    // Writers are child handles tied to one database handle. Writer methods
    // serialize through the parent database mutex.
    db: *DatabaseHandle,
    writer: zova.ObjectWriter,
};

pub const ReaderHandle = struct {
    // Readers retain a manifest statement and therefore borrow the parent
    // database handle for their entire lifetime. Reader calls serialize
    // through the same parent mutex as statements and writers.
    db: *DatabaseHandle,
    reader: zova.ObjectReader,
};

pub const StatementHandle = struct {
    // Statements borrow their parent database handle and must be finalized
    // before closing the database. Statement methods serialize through the
    // parent database mutex.
    db: *DatabaseHandle,
    statement: sqlite.Statement,
};

pub const SubscriptionHandle = struct {
    // Subscriptions are child handles tied to one database handle. Receive and
    // close operations serialize through the parent database mutex.
    db: *DatabaseHandle,
    subscription: zova.NotificationSubscription,
};

// Keep these numeric values synchronized with `include/zova.h`. Existing values
// should be treated as ABI surface once a release containing them is published.

pub fn databaseHandle(db: ?*zova_database) ?*DatabaseHandle {
    const ptr = db orelse return null;
    const handle: *DatabaseHandle = @ptrCast(@alignCast(ptr));
    if (handle.fresh_build_active) return null;
    return handle;
}

pub fn databaseHandleRaw(db: ?*zova_database) ?*DatabaseHandle {
    const ptr = db orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn freshBuildHandle(build: ?*zova_fresh_build) ?*FreshBuildHandle {
    const ptr = build orelse return null;
    const handle: *FreshBuildHandle = @ptrCast(@alignCast(ptr));
    if (!handle.active) return null;
    return handle;
}

pub fn writerHandle(writer: ?*zova_object_writer) ?*WriterHandle {
    const ptr = writer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn readerHandle(reader: ?*zova_object_reader) ?*ReaderHandle {
    const ptr = reader orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn statementHandle(statement: ?*zova_statement) ?*StatementHandle {
    const ptr = statement orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn subscriptionHandle(subscription: ?*zova_subscription) ?*SubscriptionHandle {
    const ptr = subscription orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// A null pointer is valid only for empty byte slices. That keeps empty objects
// and zero-length range buffers ergonomic while still catching bad lengths.
