//! Bound-store attachment, binding metadata, and transactional epoch helpers.

const std = @import("std");
const sqlite = @import("../sqlite.zig");

const BoundGraphStore = @import("types.zig").BoundGraphStore;
const BoundGraphStoreInfo = @import("types.zig").BoundGraphStoreInfo;
const BoundObjectStore = @import("types.zig").BoundObjectStore;
const BoundObjectStoreInfo = @import("types.zig").BoundObjectStoreInfo;
const BoundVectorStore = @import("types.zig").BoundVectorStore;
const BoundVectorStoreInfo = @import("types.zig").BoundVectorStoreInfo;
const Error = @import("types.zig").Error;
const OpenOptions = @import("types.zig").OpenOptions;
const attachedMetadataU64 = @import("metadata.zig").attachedMetadataU64;
const attachedMetadataValueAlloc = @import("metadata.zig").attachedMetadataValueAlloc;
const bound_graph_store_schema_name = @import("types.zig").bound_graph_store_schema_name;
const bound_object_store_schema_name = @import("types.zig").bound_object_store_schema_name;
const bound_stores_table = @import("types.zig").bound_stores_table;
const bound_vector_store_schema_name = @import("types.zig").bound_vector_store_schema_name;
const ensurePathExists = @import("paths.zig").ensurePathExists;
const isValidStoreId = @import("metadata.zig").isValidStoreId;
const isZovaPath = @import("paths.zig").isZovaPath;
const setAttachedMetadataValue = @import("metadata.zig").setAttachedMetadataValue;
const sqliteI64ToU64 = @import("metadata.zig").sqliteI64ToU64;
const tableExists = @import("metadata.zig").tableExists;
const validateAttachedGraphStoreAlloc = @import("validation.zig").validateAttachedGraphStoreAlloc;
const validateAttachedObjectStoreAlloc = @import("validation.zig").validateAttachedObjectStoreAlloc;
const validateAttachedVectorStoreAlloc = @import("validation.zig").validateAttachedVectorStoreAlloc;

/// The three kinds of bound store. Every per-kind difference in this module
/// is derived from this value, so each operation is written once.
pub const StoreKind = enum {
    object,
    vector,
    graph,

    /// Attached schema name, which is also the `role` stored in the binding row.
    pub fn schemaName(comptime self: StoreKind) []const u8 {
        return switch (self) {
            .object => bound_object_store_schema_name,
            .vector => bound_vector_store_schema_name,
            .graph => bound_graph_store_schema_name,
        };
    }

    /// Epoch column in the binding row and metadata key in the attached store.
    pub fn epochKey(comptime self: StoreKind) []const u8 {
        return @tagName(self) ++ "_epoch";
    }

    fn rowFilter(comptime self: StoreKind) []const u8 {
        return " where role = '" ++ self.schemaName() ++ "' and name = 'default'";
    }

    /// `object_epoch = <own>, vector_epoch = <other>, graph_epoch = <other>`
    /// style value list: `own` for this kind's epoch column, `null` for the rest.
    fn epochValues(comptime self: StoreKind, comptime assign: bool) []const u8 {
        comptime var text: []const u8 = "";
        inline for (std.meta.tags(StoreKind), 0..) |kind, index| {
            text = text ++ (if (index == 0) "" else ", ") ++
                (if (assign) kind.epochKey() ++ " = " else "") ++
                (if (kind == self) "0" else "null");
        }
        return text;
    }

    pub fn validateAttachedAlloc(comptime self: StoreKind, allocator: std.mem.Allocator, db: *sqlite.Database) Error![]u8 {
        return switch (self) {
            .object => validateAttachedObjectStoreAlloc(allocator, db, bound_object_store_schema_name),
            .vector => validateAttachedVectorStoreAlloc(allocator, db, bound_vector_store_schema_name),
            .graph => validateAttachedGraphStoreAlloc(allocator, db, bound_graph_store_schema_name),
        };
    }
};

/// The binding row shared by every store kind.
pub const BoundStoreRow = struct {
    path: []u8,
    store_id: []u8,
    bound_set_id: []u8,
    epoch: u64,

    pub fn deinit(self: *BoundStoreRow, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.store_id);
        allocator.free(self.bound_set_id);
    }
};

/// Attach and validate the store configured for `kind`. Returns false when
/// the main database has no binding of that kind.
pub fn openConfiguredBoundStore(db: *sqlite.Database, comptime kind: StoreKind, options: OpenOptions) Error!bool {
    var row = (try loadBoundStoreRow(std.heap.c_allocator, db, kind)) orelse return false;
    defer row.deinit(std.heap.c_allocator);

    const path_z = try std.heap.c_allocator.dupeSentinel(u8, row.path, 0);
    defer std.heap.c_allocator.free(path_z);

    try attachStore(db, kind, path_z, options.read_only);
    errdefer db.detachDatabase(kind.schemaName()) catch {};

    const actual_store_id = try kind.validateAttachedAlloc(std.heap.c_allocator, db);
    defer std.heap.c_allocator.free(actual_store_id);
    if (!std.mem.eql(u8, actual_store_id, row.store_id)) return error.BoundStoreInvalid;

    const actual_bound_set_id = (try attachedMetadataValueAlloc(std.heap.c_allocator, db, kind.schemaName(), "bound_set_id")) orelse return error.BoundStoreInvalid;
    defer std.heap.c_allocator.free(actual_bound_set_id);
    if (!std.mem.eql(u8, actual_bound_set_id, row.bound_set_id)) return error.BoundStoreInvalid;

    const actual_epoch = try attachedMetadataU64(db, kind.schemaName(), kind.epochKey());
    if (actual_epoch != row.epoch) return error.BoundStoreInvalid;
    return true;
}

pub fn attachStore(db: *sqlite.Database, comptime kind: StoreKind, path: []const u8, read_only: bool) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;
    try ensurePathExists(path);
    try db.attachDatabase(path, kind.schemaName());
    errdefer db.detachDatabase(kind.schemaName()) catch {};
    if (read_only) try db.setQueryOnly(true);
}

pub fn deleteBoundStoreRows(db: *sqlite.Database, comptime kind: StoreKind) Error!void {
    if (!try tableExists(db, bound_stores_table)) return;

    var stmt = try db.prepare(comptime "delete from _zova_bound_stores" ++ kind.rowFilter());
    defer stmt.deinit();
    try stmt.expectDone();
}

pub fn hasBoundStoreRow(db: *sqlite.Database, comptime kind: StoreKind) Error!bool {
    if (!try tableExists(db, bound_stores_table)) return false;

    var stmt = try db.prepare(comptime "select 1 from _zova_bound_stores" ++ kind.rowFilter() ++ " limit 1");
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .row => true,
        .done => false,
    };
}

pub fn loadBoundStoreRow(allocator: std.mem.Allocator, db: *sqlite.Database, comptime kind: StoreKind) Error!?BoundStoreRow {
    if (!try tableExists(db, bound_stores_table)) return null;

    var stmt = try db.prepare(comptime "select path, store_id, bound_set_id, " ++ kind.epochKey() ++
        " from _zova_bound_stores" ++ kind.rowFilter());
    defer stmt.deinit();

    switch (try stmt.step()) {
        .done => return null,
        .row => {
            const path = try allocator.dupe(u8, stmt.columnText(0));
            errdefer allocator.free(path);

            const store_id = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(store_id);
            if (!isValidStoreId(store_id)) return error.BoundStoreInvalid;

            const bound_set_id = try allocator.dupe(u8, stmt.columnText(2));
            errdefer allocator.free(bound_set_id);
            if (!isValidStoreId(bound_set_id)) return error.BoundStoreInvalid;

            const epoch = try sqliteI64ToU64(stmt.columnInt64(3));

            switch (try stmt.step()) {
                .done => {},
                .row => return error.BoundStoreInvalid,
            }

            return .{ .path = path, .store_id = store_id, .bound_set_id = bound_set_id, .epoch = epoch };
        },
    }
}

pub fn insertBoundStoreRow(db: *sqlite.Database, comptime kind: StoreKind, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(comptime "insert into _zova_bound_stores (role, name, path, store_id, bound_set_id, object_epoch, vector_epoch, graph_epoch, created_at_unix)" ++
        " values ('" ++ kind.schemaName() ++ "', 'default', ?, ?, ?, " ++ kind.epochValues(false) ++ ", unixepoch())");
    defer stmt.deinit();

    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    try stmt.expectDone();
}

pub fn updateBoundStoreRow(db: *sqlite.Database, comptime kind: StoreKind, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(comptime "update _zova_bound_stores set path = ?, store_id = ?, bound_set_id = ?, " ++
        kind.epochValues(true) ++ kind.rowFilter());
    defer stmt.deinit();

    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    try stmt.expectDone();
}

/// Advance the epoch in the main binding row and mirror it into the attached store.
pub fn incrementBoundEpoch(db: *sqlite.Database, comptime kind: StoreKind) Error!void {
    const key = comptime kind.epochKey();

    var update_main = try db.prepare(comptime "update _zova_bound_stores set " ++ key ++ " = " ++ key ++ " + 1" ++ kind.rowFilter());
    defer update_main.deinit();
    try update_main.expectDone();

    var read_epoch = try db.prepare(comptime "select " ++ key ++ " from _zova_bound_stores" ++ kind.rowFilter());
    defer read_epoch.deinit();
    const epoch = switch (try read_epoch.step()) {
        .done => return error.BoundStoreInvalid,
        .row => read_epoch.columnInt64(0),
    };
    if (epoch < 0) return error.BoundStoreInvalid;

    var epoch_buffer: [32]u8 = undefined;
    const epoch_text = std.fmt.bufPrint(&epoch_buffer, "{d}", .{epoch}) catch return error.BoundStoreInvalid;
    try setAttachedMetadataValue(db, kind.schemaName(), key, epoch_text);
}

// Per-kind entry points. The public `Bound*StoreInfo` types name their epoch
// field after the store, so the loaders translate the shared row.

pub fn openConfiguredBoundObjectStore(db: *sqlite.Database, options: OpenOptions) Error!?BoundObjectStore {
    return if (try openConfiguredBoundStore(db, .object, options)) .{} else null;
}

pub fn openConfiguredBoundVectorStore(db: *sqlite.Database, options: OpenOptions) Error!?BoundVectorStore {
    return if (try openConfiguredBoundStore(db, .vector, options)) .{} else null;
}

pub fn openConfiguredBoundGraphStore(db: *sqlite.Database, options: OpenOptions) Error!?BoundGraphStore {
    return if (try openConfiguredBoundStore(db, .graph, options)) .{} else null;
}

pub fn loadBoundObjectStoreInfo(allocator: std.mem.Allocator, db: *sqlite.Database) Error!?BoundObjectStoreInfo {
    const row = (try loadBoundStoreRow(allocator, db, .object)) orelse return null;
    return .{ .path = row.path, .store_id = row.store_id, .bound_set_id = row.bound_set_id, .object_epoch = row.epoch };
}

pub fn loadBoundVectorStoreInfo(allocator: std.mem.Allocator, db: *sqlite.Database) Error!?BoundVectorStoreInfo {
    const row = (try loadBoundStoreRow(allocator, db, .vector)) orelse return null;
    return .{ .path = row.path, .store_id = row.store_id, .bound_set_id = row.bound_set_id, .vector_epoch = row.epoch };
}

pub fn loadBoundGraphStoreInfo(allocator: std.mem.Allocator, db: *sqlite.Database) Error!?BoundGraphStoreInfo {
    const row = (try loadBoundStoreRow(allocator, db, .graph)) orelse return null;
    return .{ .path = row.path, .store_id = row.store_id, .bound_set_id = row.bound_set_id, .graph_epoch = row.epoch };
}

pub fn copyStoreId(value: []const u8) Error![64]u8 {
    if (!isValidStoreId(value)) return error.BoundStoreInvalid;
    var result: [64]u8 = undefined;
    @memcpy(result[0..], value);
    return result;
}

pub fn hasActiveTransaction(db: *sqlite.Database) bool {
    return sqlite.c.sqlite3_get_autocommit(db.handle) == 0 or
        sqlite.c.sqlite3_txn_state(db.handle, null) != sqlite.c.SQLITE_TXN_NONE;
}

pub fn rejectReservedZovaNames(db: *sqlite.Database) Error!void {
    var objects = try db.prepare("select name from sqlite_master where name is not null");
    defer objects.deinit();

    while ((try objects.step()) == .row) {
        const name = objects.columnText(0);
        if (isReservedZovaName(name)) return error.ZovaNameConflict;
    }
}

fn isReservedZovaName(name: []const u8) bool {
    const reserved_prefix = "_zova_";
    return name.len >= reserved_prefix.len and
        std.ascii.eqlIgnoreCase(name[0..reserved_prefix.len], reserved_prefix);
}
