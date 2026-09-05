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
const expectDone = @import("metadata.zig").expectDone;
const isValidStoreId = @import("metadata.zig").isValidStoreId;
const isZovaPath = @import("paths.zig").isZovaPath;
const setAttachedMetadataValue = @import("metadata.zig").setAttachedMetadataValue;
const sqliteI64ToU64 = @import("metadata.zig").sqliteI64ToU64;
const tableExists = @import("metadata.zig").tableExists;
const validateAttachedGraphStoreAlloc = @import("validation.zig").validateAttachedGraphStoreAlloc;
const validateAttachedObjectStoreAlloc = @import("validation.zig").validateAttachedObjectStoreAlloc;
const validateAttachedVectorStoreAlloc = @import("validation.zig").validateAttachedVectorStoreAlloc;

pub fn openConfiguredBoundObjectStore(db: *sqlite.Database, options: OpenOptions) Error!?BoundObjectStore {
    if (!try tableExists(db, bound_stores_table)) return null;

    var info = (try loadBoundObjectStoreInfo(std.heap.c_allocator, db)) orelse return null;
    defer info.deinit(std.heap.c_allocator);

    const path_z = try std.heap.c_allocator.dupeZ(u8, info.path);
    defer std.heap.c_allocator.free(path_z);

    try attachObjectStore(db, path_z, options.read_only);
    errdefer db.detachDatabase(bound_object_store_schema_name) catch {};

    const actual_store_id = try validateAttachedObjectStoreAlloc(std.heap.c_allocator, db, bound_object_store_schema_name);
    defer std.heap.c_allocator.free(actual_store_id);
    if (!std.mem.eql(u8, actual_store_id, info.store_id)) return error.BoundStoreInvalid;

    const actual_bound_set_id = (try attachedMetadataValueAlloc(std.heap.c_allocator, db, bound_object_store_schema_name, "bound_set_id")) orelse return error.BoundStoreInvalid;
    defer std.heap.c_allocator.free(actual_bound_set_id);
    if (!std.mem.eql(u8, actual_bound_set_id, info.bound_set_id)) return error.BoundStoreInvalid;

    const actual_epoch = try attachedMetadataU64(db, bound_object_store_schema_name, "object_epoch");
    if (actual_epoch != info.object_epoch) return error.BoundStoreInvalid;

    return .{};
}

pub fn openConfiguredBoundVectorStore(db: *sqlite.Database, options: OpenOptions) Error!?BoundVectorStore {
    if (!try tableExists(db, bound_stores_table)) return null;

    var info = (try loadBoundVectorStoreInfo(std.heap.c_allocator, db)) orelse return null;
    defer info.deinit(std.heap.c_allocator);

    const path_z = try std.heap.c_allocator.dupeZ(u8, info.path);
    defer std.heap.c_allocator.free(path_z);

    try attachVectorStore(db, path_z, options.read_only);
    errdefer db.detachDatabase(bound_vector_store_schema_name) catch {};

    const actual_store_id = try validateAttachedVectorStoreAlloc(std.heap.c_allocator, db, bound_vector_store_schema_name);
    defer std.heap.c_allocator.free(actual_store_id);
    if (!std.mem.eql(u8, actual_store_id, info.store_id)) return error.BoundStoreInvalid;

    const actual_bound_set_id = (try attachedMetadataValueAlloc(std.heap.c_allocator, db, bound_vector_store_schema_name, "bound_set_id")) orelse return error.BoundStoreInvalid;
    defer std.heap.c_allocator.free(actual_bound_set_id);
    if (!std.mem.eql(u8, actual_bound_set_id, info.bound_set_id)) return error.BoundStoreInvalid;

    const actual_epoch = try attachedMetadataU64(db, bound_vector_store_schema_name, "vector_epoch");
    if (actual_epoch != info.vector_epoch) return error.BoundStoreInvalid;

    return .{};
}

pub fn openConfiguredBoundGraphStore(db: *sqlite.Database, options: OpenOptions) Error!?BoundGraphStore {
    if (!try tableExists(db, bound_stores_table)) return null;

    var info = (try loadBoundGraphStoreInfo(std.heap.c_allocator, db)) orelse return null;
    defer info.deinit(std.heap.c_allocator);

    const path_z = try std.heap.c_allocator.dupeZ(u8, info.path);
    defer std.heap.c_allocator.free(path_z);

    try attachGraphStore(db, path_z, options.read_only);
    errdefer db.detachDatabase(bound_graph_store_schema_name) catch {};

    const actual_store_id = try validateAttachedGraphStoreAlloc(std.heap.c_allocator, db, bound_graph_store_schema_name);
    defer std.heap.c_allocator.free(actual_store_id);
    if (!std.mem.eql(u8, actual_store_id, info.store_id)) return error.BoundStoreInvalid;

    const actual_bound_set_id = (try attachedMetadataValueAlloc(std.heap.c_allocator, db, bound_graph_store_schema_name, "bound_set_id")) orelse return error.BoundStoreInvalid;
    defer std.heap.c_allocator.free(actual_bound_set_id);
    if (!isValidStoreId(actual_bound_set_id) or !std.mem.eql(u8, actual_bound_set_id, info.bound_set_id)) return error.BoundStoreInvalid;

    const actual_epoch = try attachedMetadataU64(db, bound_graph_store_schema_name, "graph_epoch");
    if (actual_epoch != info.graph_epoch) return error.BoundStoreInvalid;

    return .{};
}

pub fn attachObjectStore(db: *sqlite.Database, path: []const u8, read_only: bool) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;
    try ensurePathExists(path);
    try db.attachDatabase(path, bound_object_store_schema_name);
    errdefer db.detachDatabase(bound_object_store_schema_name) catch {};
    if (read_only) try db.setQueryOnly(true);
}

pub fn attachVectorStore(db: *sqlite.Database, path: []const u8, read_only: bool) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;
    try ensurePathExists(path);
    try db.attachDatabase(path, bound_vector_store_schema_name);
    errdefer db.detachDatabase(bound_vector_store_schema_name) catch {};
    if (read_only) try db.setQueryOnly(true);
}

pub fn attachGraphStore(db: *sqlite.Database, path: []const u8, read_only: bool) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;
    try ensurePathExists(path);
    try db.attachDatabase(path, bound_graph_store_schema_name);
    errdefer db.detachDatabase(bound_graph_store_schema_name) catch {};
    if (read_only) try db.setQueryOnly(true);
}

pub fn deleteBoundObjectStoreRows(db: *sqlite.Database) Error!void {
    if (!try tableExists(db, bound_stores_table)) return;

    var stmt = try db.prepare(
        \\delete from _zova_bound_stores
        \\where role = 'object_store' and name = 'default'
    );
    defer stmt.deinit();
    std.debug.assert((try stmt.step()) == .done);
}

pub fn deleteBoundVectorStoreRows(db: *sqlite.Database) Error!void {
    if (!try tableExists(db, bound_stores_table)) return;

    var stmt = try db.prepare(
        \\delete from _zova_bound_stores
        \\where role = 'vector_store' and name = 'default'
    );
    defer stmt.deinit();
    std.debug.assert((try stmt.step()) == .done);
}

pub fn deleteBoundGraphStoreRows(db: *sqlite.Database) Error!void {
    if (!try tableExists(db, bound_stores_table)) return;

    var stmt = try db.prepare(
        \\delete from _zova_bound_stores
        \\where role = 'graph_store' and name = 'default'
    );
    defer stmt.deinit();
    std.debug.assert((try stmt.step()) == .done);
}

pub fn hasBoundObjectStoreRow(db: *sqlite.Database) Error!bool {
    if (!try tableExists(db, bound_stores_table)) return false;

    var stmt = try db.prepare(
        \\select 1
        \\from _zova_bound_stores
        \\where role = 'object_store' and name = 'default'
        \\limit 1
    );
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .row => true,
        .done => false,
    };
}

pub fn hasBoundVectorStoreRow(db: *sqlite.Database) Error!bool {
    if (!try tableExists(db, bound_stores_table)) return false;

    var stmt = try db.prepare(
        \\select 1
        \\from _zova_bound_stores
        \\where role = 'vector_store' and name = 'default'
        \\limit 1
    );
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .row => true,
        .done => false,
    };
}

pub fn hasBoundGraphStoreRow(db: *sqlite.Database) Error!bool {
    if (!try tableExists(db, bound_stores_table)) return false;

    var stmt = try db.prepare(
        \\select 1
        \\from _zova_bound_stores
        \\where role = 'graph_store' and name = 'default'
        \\limit 1
    );
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .row => true,
        .done => false,
    };
}

pub fn loadBoundObjectStoreInfo(allocator: std.mem.Allocator, db: *sqlite.Database) Error!?BoundObjectStoreInfo {
    if (!try tableExists(db, bound_stores_table)) return null;

    var stmt = try db.prepare(
        \\select path, store_id, bound_set_id, object_epoch
        \\from _zova_bound_stores
        \\where role = 'object_store' and name = 'default'
    );
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

            const object_epoch = try sqliteI64ToU64(stmt.columnInt64(3));

            switch (try stmt.step()) {
                .done => {},
                .row => return error.BoundStoreInvalid,
            }

            return .{ .path = path, .store_id = store_id, .bound_set_id = bound_set_id, .object_epoch = object_epoch };
        },
    }
}

pub fn loadBoundVectorStoreInfo(allocator: std.mem.Allocator, db: *sqlite.Database) Error!?BoundVectorStoreInfo {
    if (!try tableExists(db, bound_stores_table)) return null;

    var stmt = try db.prepare(
        \\select path, store_id, bound_set_id, vector_epoch
        \\from _zova_bound_stores
        \\where role = 'vector_store' and name = 'default'
    );
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

            const vector_epoch = try sqliteI64ToU64(stmt.columnInt64(3));

            switch (try stmt.step()) {
                .done => {},
                .row => return error.BoundStoreInvalid,
            }

            return .{ .path = path, .store_id = store_id, .bound_set_id = bound_set_id, .vector_epoch = vector_epoch };
        },
    }
}

pub fn loadBoundGraphStoreInfo(allocator: std.mem.Allocator, db: *sqlite.Database) Error!?BoundGraphStoreInfo {
    if (!try tableExists(db, bound_stores_table)) return null;

    var stmt = try db.prepare(
        \\select path, store_id, bound_set_id, graph_epoch
        \\from _zova_bound_stores
        \\where role = 'graph_store' and name = 'default'
    );
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

            const graph_epoch = try sqliteI64ToU64(stmt.columnInt64(3));
            switch (try stmt.step()) {
                .done => {},
                .row => return error.BoundStoreInvalid,
            }
            return .{ .path = path, .store_id = store_id, .bound_set_id = bound_set_id, .graph_epoch = graph_epoch };
        },
    }
}

pub fn insertBoundObjectStoreRow(db: *sqlite.Database, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_bound_stores (role, name, path, store_id, bound_set_id, object_epoch, vector_epoch, graph_epoch, created_at_unix)
        \\values ('object_store', 'default', ?, ?, ?, 0, null, null, unixepoch())
    );
    defer stmt.deinit();

    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    std.debug.assert((try stmt.step()) == .done);
}

pub fn updateBoundObjectStoreRow(db: *sqlite.Database, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(
        \\update _zova_bound_stores
        \\set path = ?, store_id = ?, bound_set_id = ?, object_epoch = 0, vector_epoch = null, graph_epoch = null
        \\where role = 'object_store' and name = 'default'
    );
    defer stmt.deinit();

    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    std.debug.assert((try stmt.step()) == .done);
}

pub fn insertBoundVectorStoreRow(db: *sqlite.Database, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_bound_stores (role, name, path, store_id, bound_set_id, object_epoch, vector_epoch, graph_epoch, created_at_unix)
        \\values ('vector_store', 'default', ?, ?, ?, null, 0, null, unixepoch())
    );
    defer stmt.deinit();

    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    std.debug.assert((try stmt.step()) == .done);
}

pub fn updateBoundVectorStoreRow(db: *sqlite.Database, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(
        \\update _zova_bound_stores
        \\set path = ?, store_id = ?, bound_set_id = ?, object_epoch = null, vector_epoch = 0, graph_epoch = null
        \\where role = 'vector_store' and name = 'default'
    );
    defer stmt.deinit();

    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    std.debug.assert((try stmt.step()) == .done);
}

pub fn insertBoundGraphStoreRow(db: *sqlite.Database, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_bound_stores (role, name, path, store_id, bound_set_id, object_epoch, vector_epoch, graph_epoch, created_at_unix)
        \\values ('graph_store', 'default', ?, ?, ?, null, null, 0, unixepoch())
    );
    defer stmt.deinit();
    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    try expectDone(&stmt);
}

pub fn updateBoundGraphStoreRow(db: *sqlite.Database, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(
        \\update _zova_bound_stores
        \\set path = ?, store_id = ?, bound_set_id = ?, object_epoch = null, vector_epoch = null, graph_epoch = 0
        \\where role = 'graph_store' and name = 'default'
    );
    defer stmt.deinit();
    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    try expectDone(&stmt);
}

pub fn incrementBoundObjectEpoch(db: *sqlite.Database) Error!void {
    var update_main = try db.prepare(
        \\update _zova_bound_stores
        \\set object_epoch = object_epoch + 1
        \\where role = 'object_store' and name = 'default'
    );
    defer update_main.deinit();
    std.debug.assert((try update_main.step()) == .done);

    var read_epoch = try db.prepare(
        \\select object_epoch
        \\from _zova_bound_stores
        \\where role = 'object_store' and name = 'default'
    );
    defer read_epoch.deinit();
    const epoch = switch (try read_epoch.step()) {
        .done => return error.BoundStoreInvalid,
        .row => read_epoch.columnInt64(0),
    };
    if (epoch < 0) return error.BoundStoreInvalid;

    var epoch_buffer: [32]u8 = undefined;
    const epoch_text = std.fmt.bufPrint(&epoch_buffer, "{d}", .{epoch}) catch return error.BoundStoreInvalid;
    try setAttachedMetadataValue(db, bound_object_store_schema_name, "object_epoch", epoch_text);
}

pub fn incrementBoundVectorEpoch(db: *sqlite.Database) Error!void {
    var update_main = try db.prepare(
        \\update _zova_bound_stores
        \\set vector_epoch = vector_epoch + 1
        \\where role = 'vector_store' and name = 'default'
    );
    defer update_main.deinit();
    std.debug.assert((try update_main.step()) == .done);

    var read_epoch = try db.prepare(
        \\select vector_epoch
        \\from _zova_bound_stores
        \\where role = 'vector_store' and name = 'default'
    );
    defer read_epoch.deinit();
    const epoch = switch (try read_epoch.step()) {
        .done => return error.BoundStoreInvalid,
        .row => read_epoch.columnInt64(0),
    };
    if (epoch < 0) return error.BoundStoreInvalid;

    var epoch_buffer: [32]u8 = undefined;
    const epoch_text = std.fmt.bufPrint(&epoch_buffer, "{d}", .{epoch}) catch return error.BoundStoreInvalid;
    try setAttachedMetadataValue(db, bound_vector_store_schema_name, "vector_epoch", epoch_text);
}

pub fn incrementBoundGraphEpoch(db: *sqlite.Database) Error!void {
    var update_main = try db.prepare(
        \\update _zova_bound_stores set graph_epoch = graph_epoch + 1
        \\where role = 'graph_store' and name = 'default'
    );
    defer update_main.deinit();
    try expectDone(&update_main);

    var read_epoch = try db.prepare(
        \\select graph_epoch from _zova_bound_stores
        \\where role = 'graph_store' and name = 'default'
    );
    defer read_epoch.deinit();
    const epoch = switch (try read_epoch.step()) {
        .done => return error.BoundStoreInvalid,
        .row => read_epoch.columnInt64(0),
    };
    if (epoch < 0) return error.BoundStoreInvalid;
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{epoch}) catch return error.BoundStoreInvalid;
    try setAttachedMetadataValue(db, bound_graph_store_schema_name, "graph_epoch", text);
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
