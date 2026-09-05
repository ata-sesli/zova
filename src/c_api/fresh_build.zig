//! Atomic fresh-build sessions, deferred indexes, and session diagnostics.

const std = @import("std");
const zova = @import("../zova.zig");
const graph = @import("../graph.zig");
const sqlite = @import("../sqlite.zig");

const DatabaseHandle = @import("handles.zig").DatabaseHandle;
const DeferredFreshIndex = @import("handles.zig").DeferredFreshIndex;
const FreshBuildCacheDiagnostics = @import("handles.zig").FreshBuildCacheDiagnostics;
const FreshBuildCachePolicy = @import("handles.zig").FreshBuildCachePolicy;
const FreshBuildHandle = @import("handles.zig").FreshBuildHandle;
const allocator = @import("values.zig").allocator;
const databaseHandleRaw = @import("handles.zig").databaseHandleRaw;
const failDb = @import("errors.zig").failDb;
const freshBuildHandle = @import("handles.zig").freshBuildHandle;
const freshGraphEdgePayloadInputSlices = @import("values.zig").freshGraphEdgePayloadInputSlices;
const freshGraphNodeInputSlices = @import("values.zig").freshGraphNodeInputSlices;
const okDb = @import("errors.zig").okDb;
const vectorInputSlices = @import("values.zig").vectorInputSlices;
const zova_fresh_build = @import("types.zig").zova_fresh_build;
const zova_fresh_build_begin_request = @import("types.zig").zova_fresh_build_begin_request;
const zova_fresh_build_finish_request = @import("types.zig").zova_fresh_build_finish_request;
const zova_fresh_build_graph_request = @import("types.zig").zova_fresh_build_graph_request;
const zova_fresh_build_rows_request = @import("types.zig").zova_fresh_build_rows_request;
const zova_fresh_build_vectors_request = @import("types.zig").zova_fresh_build_vectors_request;
const zova_fresh_value = @import("types.zig").zova_fresh_value;
const zova_status = @import("types.zig").zova_status;

var fresh_build_cache_policy: FreshBuildCachePolicy = .graph_and_deferred_indexes;

/// Internal benchmark control. This is intentionally not exported through the C ABI.
pub fn setFreshBuildCachePolicyForBenchmark(policy: FreshBuildCachePolicy) void {
    fresh_build_cache_policy = policy;
}

/// Internal benchmark diagnostics. The build handle remains owned until destroy.
pub fn freshBuildCacheDiagnostics(build_ptr: ?*zova_fresh_build) ?FreshBuildCacheDiagnostics {
    const ptr = build_ptr orelse return null;
    const build: *FreshBuildHandle = @ptrCast(@alignCast(ptr));
    return build.cache_diagnostics;
}

fn freshBuildTimestamp() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn freshBuildElapsedMs(start: std.Io.Timestamp) f64 {
    const elapsed_ns = start.durationTo(freshBuildTimestamp()).toNanoseconds();
    if (elapsed_ns <= 0) return 0;
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms);
}

fn validateFreshIdentifier(name: []const u8, reject_private: bool) error{InvalidArgument}!void {
    if (name.len == 0 or name.len > 128) return error.InvalidArgument;
    if (reject_private and name.len >= 6 and std.ascii.eqlIgnoreCase(name[0..6], "_zova_")) return error.InvalidArgument;
    for (name, 0..) |byte, index| {
        const valid = std.ascii.isAlphabetic(byte) or byte == '_' or (index != 0 and std.ascii.isDigit(byte));
        if (!valid) return error.InvalidArgument;
    }
}

fn appendFreshQuotedIdentifier(buffer: *std.ArrayList(u8), name: []const u8) !void {
    try buffer.append(allocator, '"');
    try buffer.appendSlice(allocator, name);
    try buffer.append(allocator, '"');
}

fn freshBuildPrepareTable(build: *FreshBuildHandle, table_name: []const u8) !void {
    try validateFreshIdentifier(table_name, true);
    for (build.prepared_tables.items) |existing| if (std.mem.eql(u8, existing, table_name)) return;

    var count_sql: std.ArrayList(u8) = .empty;
    defer count_sql.deinit(allocator);
    try count_sql.appendSlice(allocator, "select count(*) from ");
    try appendFreshQuotedIdentifier(&count_sql, table_name);
    try count_sql.append(allocator, 0);
    {
        var count = try build.database.db.prepare(count_sql.items[0 .. count_sql.items.len - 1 :0]);
        defer count.deinit();
        if ((try count.step()) != .row or count.columnInt64(0) != 0) return error.InvalidArgument;
    }

    var captured: std.ArrayList(DeferredFreshIndex) = .empty;
    defer captured.deinit(allocator);
    errdefer for (captured.items) |item| {
        allocator.free(item.name);
        allocator.free(item.sql);
    };
    {
        var indexes = try build.database.db.prepare("select name,sql from sqlite_schema where type='index' and tbl_name=?1 and sql is not null order by name");
        defer indexes.deinit();
        try indexes.bindText(1, table_name);
        while ((try indexes.step()) == .row) {
            const name = try allocator.dupeZ(u8, indexes.columnText(0));
            errdefer allocator.free(name);
            const sql = try allocator.dupeZ(u8, indexes.columnText(1));
            try captured.append(allocator, .{ .name = name, .sql = sql });
        }
    }
    for (captured.items) |item| {
        var drop_sql: std.ArrayList(u8) = .empty;
        defer drop_sql.deinit(allocator);
        try drop_sql.appendSlice(allocator, "drop index ");
        try appendFreshQuotedIdentifier(&drop_sql, item.name);
        try drop_sql.append(allocator, 0);
        try build.database.db.exec(drop_sql.items[0 .. drop_sql.items.len - 1 :0]);
        try build.deferred_indexes.append(allocator, item);
    }
    captured.clearRetainingCapacity();
    try build.prepared_tables.append(allocator, try allocator.dupe(u8, table_name));
}

fn freshBuildLoadRows(build: *FreshBuildHandle, request: *const zova_fresh_build_rows_request, fts: bool) !void {
    const table_name_ptr = request.table_name orelse return error.InvalidArgument;
    if (request.column_count == 0) return error.InvalidArgument;
    const column_ptrs = request.column_names orelse return error.InvalidArgument;
    const value_count = std.math.mul(usize, request.row_count, request.column_count) catch return error.InvalidArgument;
    if (value_count != 0 and request.values == null) return error.InvalidArgument;
    const table_name = std.mem.span(table_name_ptr);
    for (column_ptrs[0..request.column_count], 0..) |column_ptr, index| {
        const column = std.mem.span(column_ptr orelse return error.InvalidArgument);
        try validateFreshIdentifier(column, false);
        for (column_ptrs[0..index]) |prior_ptr| {
            if (std.mem.eql(u8, column, std.mem.span(prior_ptr orelse return error.InvalidArgument))) return error.InvalidArgument;
        }
    }
    const values: []const zova_fresh_value = if (value_count == 0) &.{} else request.values.?[0..value_count];
    for (values) |value| switch (value.value_type) {
        0, 1, 2 => if (value.bytes != null or value.bytes_len != 0) return error.InvalidArgument,
        3 => {
            if (value.bytes_len != 0 and value.bytes == null) return error.InvalidArgument;
            const bytes: []const u8 = if (value.bytes_len == 0) &.{} else value.bytes.?[0..value.bytes_len];
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidArgument;
        },
        4 => if (value.bytes_len != 0 and value.bytes == null) return error.InvalidArgument,
        else => return error.InvalidArgument,
    };
    try freshBuildPrepareTable(build, table_name);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "insert into ");
    try appendFreshQuotedIdentifier(&sql, table_name);
    try sql.append(allocator, '(');
    for (column_ptrs[0..request.column_count], 0..) |column_ptr, index| {
        const column = std.mem.span(column_ptr orelse return error.InvalidArgument);
        try validateFreshIdentifier(column, false);
        if (index != 0) try sql.append(allocator, ',');
        try appendFreshQuotedIdentifier(&sql, column);
    }
    try sql.appendSlice(allocator, ") values(");
    for (0..request.column_count) |index| {
        if (index != 0) try sql.append(allocator, ',');
        try sql.append(allocator, '?');
    }
    try sql.appendSlice(allocator, ")");
    try sql.append(allocator, 0);

    var stmt = try build.database.db.prepare(sql.items[0 .. sql.items.len - 1 :0]);
    defer stmt.deinit();
    for (0..request.row_count) |row| {
        for (values[row * request.column_count ..][0..request.column_count], 0..) |value, column| {
            const index: c_int = @intCast(column + 1);
            switch (value.value_type) {
                0 => try stmt.bindNull(index),
                1 => try stmt.bindInt64(index, value.int64_value),
                2 => try stmt.bindDouble(index, value.float64_value),
                3 => {
                    if (value.bytes_len != 0 and value.bytes == null) return error.InvalidArgument;
                    const bytes: []const u8 = if (value.bytes_len == 0) &.{} else value.bytes.?[0..value.bytes_len];
                    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidArgument;
                    try stmt.bindText(index, bytes);
                },
                4 => {
                    if (value.bytes_len != 0 and value.bytes == null) return error.InvalidArgument;
                    const bytes: []const u8 = if (value.bytes_len == 0) &.{} else value.bytes.?[0..value.bytes_len];
                    try stmt.bindBlobBorrowed(index, bytes);
                },
                else => return error.InvalidArgument,
            }
        }
        if ((try stmt.step()) != .done) return error.InvalidArgument;
        try stmt.reset();
        try stmt.clearBindings();
    }
    const rows: u64 = @intCast(request.row_count);
    if (fts) build.profile.fts_rows = std.math.add(u64, build.profile.fts_rows, rows) catch return error.InvalidArgument else build.profile.table_rows = std.math.add(u64, build.profile.table_rows, rows) catch return error.InvalidArgument;
}

fn freshBuildRunForeignKeyCheck(database: *DatabaseHandle) !void {
    var foreign_keys = try database.db.prepare("pragma foreign_key_check");
    defer foreign_keys.deinit();
    if ((try foreign_keys.step()) != .done) return error.InvalidArgument;
}

fn freshBuildForeignKeysEnabled(database: *DatabaseHandle) !bool {
    var foreign_keys = try database.db.prepare("pragma foreign_keys");
    defer foreign_keys.deinit();
    if ((try foreign_keys.step()) != .row) return error.SqliteError;
    return foreign_keys.columnInt64(0) != 0;
}

fn freshBuildDeferredForeignKeysPending(database: *DatabaseHandle) !bool {
    var current: c_int = 0;
    var highwater: c_int = 0;
    const rc = sqlite.c.sqlite3_db_status(
        database.db.sqlite_db.handle,
        sqlite.c.SQLITE_DBSTATUS_DEFERRED_FKS,
        &current,
        &highwater,
        0,
    );
    if (rc != sqlite.c.SQLITE_OK) return error.SqliteError;
    return current != 0;
}

fn freshBuildRollback(build: *FreshBuildHandle) void {
    if (!build.active) return;
    if (build.owns_transaction) {
        build.database.db.rollback() catch {};
    } else {
        build.database.db.rollbackToSavepoint("fresh_build_session") catch {};
        build.database.db.releaseSavepoint("fresh_build_session") catch {};
    }
    freshBuildRestoreCache(build);
    build.database.fresh_build_active = false;
    build.active = false;
}

fn freshBuildRestoreCache(build: *FreshBuildHandle) void {
    if (build.previous_cache_size == null) return;
    const start = freshBuildTimestamp();
    graph.restoreFreshBuildCache(&build.database.db.sqlite_db, build.previous_cache_size) catch {};
    build.cache_diagnostics.cache_restore_ms += freshBuildElapsedMs(start);
    build.previous_cache_size = null;
}

pub fn zova_fresh_build_begin(request: ?*const zova_fresh_build_begin_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const out = req.out_build orelse return .INVALID_ARGUMENT;
    out.* = null;
    const database = databaseHandleRaw(req.db) orelse return .INVALID_ARGUMENT;
    database.mutex.lock();
    defer database.mutex.unlock();
    if (database.fresh_build_active or database.live_statements != 0 or database.live_writers != 0) return failDb(database, error.InvalidArgument);
    const start = freshBuildTimestamp();
    const foreign_keys_enforced = freshBuildForeignKeysEnabled(database) catch |err| return failDb(database, err);
    if (!foreign_keys_enforced) return failDb(database, error.InvalidArgument);
    var empty = database.db.prepare(
        "select (select count(*) from _zova_objects)+(select count(*) from _zova_chunks)+(select count(*) from _zova_object_chunks)+(select count(*) from _zova_vectors)+(select count(*) from _zova_graphs)+(select count(*) from _zova_graph_nodes)+(select count(*) from _zova_graph_edges)",
    ) catch |err| return failDb(database, err);
    defer empty.deinit();
    if ((empty.step() catch |err| return failDb(database, err)) != .row or empty.columnInt64(0) != 0) return failDb(database, error.InvalidArgument);
    const owns_transaction = sqlite.c.sqlite3_get_autocommit(database.db.sqlite_db.handle) != 0;
    if (owns_transaction) database.db.beginImmediate() catch |err| return failDb(database, err) else database.db.savepoint("fresh_build_session") catch |err| return failDb(database, err);
    const baseline_foreign_key_check_start = freshBuildTimestamp();
    freshBuildRunForeignKeyCheck(database) catch |err| {
        if (owns_transaction) database.db.rollback() catch {} else {
            database.db.rollbackToSavepoint("fresh_build_session") catch {};
            database.db.releaseSavepoint("fresh_build_session") catch {};
        }
        return failDb(database, err);
    };
    const baseline_foreign_key_check_ms = freshBuildElapsedMs(baseline_foreign_key_check_start);
    const previous_cache_size = if (fresh_build_cache_policy == .session)
        graph.increaseFreshBuildCache(&database.db.sqlite_db) catch |err| {
            if (owns_transaction) database.db.rollback() catch {} else {
                database.db.rollbackToSavepoint("fresh_build_session") catch {};
                database.db.releaseSavepoint("fresh_build_session") catch {};
            }
            return failDb(database, err);
        }
    else
        null;
    const build = allocator.create(FreshBuildHandle) catch |err| {
        graph.restoreFreshBuildCache(&database.db.sqlite_db, previous_cache_size) catch {};
        if (owns_transaction) database.db.rollback() catch {} else {
            database.db.rollbackToSavepoint("fresh_build_session") catch {};
            database.db.releaseSavepoint("fresh_build_session") catch {};
        }
        return failDb(database, err);
    };
    build.* = .{
        .database = database,
        .owns_transaction = owns_transaction,
        .previous_cache_size = previous_cache_size,
        .validation = .{
            .foreign_keys_enforced = foreign_keys_enforced,
            .baseline_foreign_keys_validated = true,
        },
    };
    build.cache_diagnostics.baseline_foreign_key_check_ms = baseline_foreign_key_check_ms;
    build.cache_diagnostics.baseline_foreign_key_check_ran = true;
    build.profile.validation_ms = freshBuildElapsedMs(start);
    database.fresh_build_active = true;
    out.* = @ptrCast(build);
    return okDb(database);
}

pub fn zova_fresh_build_table_rows(request: ?*const zova_fresh_build_rows_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const build = freshBuildHandle(req.build) orelse return .INVALID_ARGUMENT;
    const database = build.database;
    database.mutex.lock();
    defer database.mutex.unlock();
    const start = freshBuildTimestamp();
    freshBuildLoadRows(build, req, false) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    build.profile.table_load_ms += freshBuildElapsedMs(start);
    return okDb(database);
}

pub fn zova_fresh_build_fts_rows(request: ?*const zova_fresh_build_rows_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const build = freshBuildHandle(req.build) orelse return .INVALID_ARGUMENT;
    const database = build.database;
    database.mutex.lock();
    defer database.mutex.unlock();
    const start = freshBuildTimestamp();
    freshBuildLoadRows(build, req, true) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    build.profile.fts_load_ms += freshBuildElapsedMs(start);
    return okDb(database);
}

pub fn zova_fresh_build_graph(request: ?*const zova_fresh_build_graph_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const build = freshBuildHandle(req.build) orelse return .INVALID_ARGUMENT;
    const database = build.database;
    database.mutex.lock();
    defer database.mutex.unlock();
    if ((req.out_node_keys == null and req.out_node_keys_capacity != 0) or
        (req.out_node_keys != null and req.out_node_keys_capacity < req.nodes_len) or
        (req.out_edge_keys == null and req.out_edge_keys_capacity != 0) or
        (req.out_edge_keys != null and req.out_edge_keys_capacity < req.edges_len))
    {
        freshBuildRollback(build);
        return failDb(database, error.InvalidArgument);
    }
    if (build.graph_loaded) {
        freshBuildRollback(build);
        return failDb(database, error.InvalidArgument);
    }
    const graph_name = req.graph_name orelse {
        freshBuildRollback(build);
        return failDb(database, error.InvalidArgument);
    };
    const nodes = freshGraphNodeInputSlices(req.nodes, req.nodes_len) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    defer if (nodes.len != 0) allocator.free(nodes);
    const edges = freshGraphEdgePayloadInputSlices(req.edges, req.edges_len) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    defer if (edges.len != 0) allocator.free(edges);
    build.node_keys = allocator.alloc(i64, nodes.len) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    build.edge_keys = allocator.alloc(i64, edges.len) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    var profile: zova.FreshGraphBuildProfile = .{};
    database.db.buildFreshGraphPreparedKeyedProfiled(std.mem.span(graph_name), nodes, edges, build.node_keys, build.edge_keys, &profile) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    build.profile.graph_load_ms += profile.graph_and_types_ms + profile.node_load_ms + profile.edge_load_ms;
    build.profile.graph_validation_ms += profile.validation_ms;
    build.profile.graph_key_generation_ms += profile.key_generation_ms;
    build.profile.graph_node_load_ms += profile.node_load_ms;
    build.profile.graph_edge_load_ms += profile.edge_load_ms;
    build.profile.index_build_ms += profile.index_build_ms;
    build.profile.payload_bytes = profile.payload_bytes;
    build.graph_loaded = true;
    if (req.out_node_keys) |out| @memcpy(out[0..build.node_keys.len], build.node_keys);
    if (req.out_edge_keys) |out| @memcpy(out[0..build.edge_keys.len], build.edge_keys);
    return okDb(database);
}

pub fn zova_fresh_build_vectors(request: ?*const zova_fresh_build_vectors_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const build = freshBuildHandle(req.build) orelse return .INVALID_ARGUMENT;
    const database = build.database;
    database.mutex.lock();
    defer database.mutex.unlock();
    const collection_name = req.collection_name orelse {
        freshBuildRollback(build);
        return failDb(database, error.InvalidArgument);
    };
    const vectors = vectorInputSlices(req.vectors, req.vectors_len) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    defer if (vectors.len != 0) allocator.free(vectors);
    const start = freshBuildTimestamp();
    database.db.putVectors(std.mem.span(collection_name), vectors) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    build.profile.vector_load_ms += freshBuildElapsedMs(start);
    build.profile.vector_rows = std.math.add(u64, build.profile.vector_rows, vectors.len) catch {
        freshBuildRollback(build);
        return failDb(database, error.InvalidArgument);
    };
    return okDb(database);
}

pub fn zova_fresh_build_finish(request: ?*const zova_fresh_build_finish_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const build = freshBuildHandle(req.build) orelse return .INVALID_ARGUMENT;
    const database = build.database;
    database.mutex.lock();
    defer database.mutex.unlock();
    if (req.out_node_keys_capacity < build.node_keys.len or req.out_edge_keys_capacity < build.edge_keys.len or
        (build.node_keys.len != 0 and req.out_node_keys == null) or (build.edge_keys.len != 0 and req.out_edge_keys == null))
    {
        freshBuildRollback(build);
        return failDb(database, error.InvalidArgument);
    }
    if (fresh_build_cache_policy == .graph_and_deferred_indexes) {
        build.previous_cache_size = graph.increaseFreshBuildCache(&database.db.sqlite_db) catch |err| {
            freshBuildRollback(build);
            return failDb(database, err);
        };
    }
    const indexes_start = freshBuildTimestamp();
    for (build.deferred_indexes.items) |item| database.db.exec(item.sql) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    const deferred_index_ms = freshBuildElapsedMs(indexes_start);
    build.profile.index_build_ms += deferred_index_ms;
    build.cache_diagnostics.deferred_index_ms = deferred_index_ms;
    if (fresh_build_cache_policy == .graph_and_deferred_indexes) freshBuildRestoreCache(build);
    const validation_start = freshBuildTimestamp();
    const deferred_foreign_keys_pending = freshBuildDeferredForeignKeysPending(database) catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    build.cache_diagnostics.deferred_foreign_keys_pending = deferred_foreign_keys_pending;
    if (build.validation.foreign_keys_enforced and build.validation.baseline_foreign_keys_validated and !deferred_foreign_keys_pending) {
        build.cache_diagnostics.validation_fast_path = true;
    } else {
        const foreign_key_check_start = freshBuildTimestamp();
        build.cache_diagnostics.foreign_key_check_ran = true;
        freshBuildRunForeignKeyCheck(database) catch |err| {
            build.cache_diagnostics.foreign_key_check_ms = freshBuildElapsedMs(foreign_key_check_start);
            freshBuildRollback(build);
            return failDb(database, err);
        };
        build.cache_diagnostics.foreign_key_check_ms = freshBuildElapsedMs(foreign_key_check_start);
    }
    build.profile.validation_ms += freshBuildElapsedMs(validation_start);
    const commit_start = freshBuildTimestamp();
    if (build.owns_transaction) database.db.commit() catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    } else database.db.releaseSavepoint("fresh_build_session") catch |err| {
        freshBuildRollback(build);
        return failDb(database, err);
    };
    build.profile.commit_ms = freshBuildElapsedMs(commit_start);
    build.cache_diagnostics.transaction_finish_ms = build.profile.commit_ms;
    freshBuildRestoreCache(build);
    if (build.node_keys.len != 0) @memcpy(req.out_node_keys.?[0..build.node_keys.len], build.node_keys);
    if (build.edge_keys.len != 0) @memcpy(req.out_edge_keys.?[0..build.edge_keys.len], build.edge_keys);
    if (req.out_profile) |profile| profile.* = build.profile;
    build.active = false;
    database.fresh_build_active = false;
    return okDb(database);
}

pub fn zova_fresh_build_abort(build_ptr: ?*zova_fresh_build) callconv(.c) zova_status {
    const build = freshBuildHandle(build_ptr) orelse return .INVALID_ARGUMENT;
    const database = build.database;
    database.mutex.lock();
    defer database.mutex.unlock();
    freshBuildRollback(build);
    return okDb(database);
}

pub fn zova_fresh_build_destroy(build_ptr: ?*zova_fresh_build) callconv(.c) void {
    const ptr = build_ptr orelse return;
    const build: *FreshBuildHandle = @ptrCast(@alignCast(ptr));
    const database = build.database;
    database.mutex.lock();
    defer database.mutex.unlock();
    freshBuildRollback(build);
    build.deinit();
    allocator.destroy(build);
}
