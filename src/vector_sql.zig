//! Private SQL integration for Zova vectors.
//!
//! This module registers read-only SQLite functions and an eponymous-only
//! virtual table on Zova-owned database connections. It intentionally stays
//! private: callers use ordinary SQL through `zova.Database.prepare` or the C
//! ABI prepared-statement layer.

const std = @import("std");
const sqlite = @import("sqlite.zig");

const c = sqlite.c;
const allocator = std.heap.c_allocator;

const max_vector_dimensions: u32 = 16_384;
const max_vector_collection_name_bytes: usize = 255;

const Error = sqlite.Error || error{
    InvalidArgument,
    VectorCollectionNotFound,
    VectorNotFound,
    VectorDimensionMismatch,
    VectorCorrupt,
    VectorInvalid,
    OutOfMemory,
};

const VectorMetric = enum {
    cosine,
    l2,
    dot,
};

const Collection = struct {
    dimensions: u32,
    metric: VectorMetric,
};

const SearchRow = extern struct {
    id: ?[*]u8 = null,
    id_len: usize = 0,
    distance: f64 = 0,
};

const SearchTable = extern struct {
    base: c.sqlite3_vtab,
    db: ?*c.sqlite3,
};

const SearchCursor = extern struct {
    base: c.sqlite3_vtab_cursor,
    db: ?*c.sqlite3,
    rows: ?[*]SearchRow = null,
    rows_len: usize = 0,
    index: usize = 0,
};

const ConstraintBits = packed struct(u8) {
    collection: bool = false,
    query_vector: bool = false,
    source_vector_id: bool = false,
    top_k: bool = false,
    max_distance: bool = false,
    _: u3 = 0,
};

const Column = enum(c_int) {
    rank = 0,
    vector_id = 1,
    distance = 2,
    collection = 3,
    query_vector = 4,
    source_vector_id = 5,
    top_k = 6,
    max_distance = 7,
};

/// Register v0.12 SQL vector integration on one Zova-owned SQLite connection.
pub fn register(db: *sqlite.Database) sqlite.Error!void {
    const flags = c.SQLITE_UTF8 | c.SQLITE_INNOCUOUS;

    var rc = c.sqlite3_create_function_v2(
        db.handle,
        "zova_vector_distance",
        3,
        flags,
        null,
        vectorDistanceFunc,
        null,
        null,
        null,
    );
    if (rc != c.SQLITE_OK) return mapResultCode(rc);

    rc = c.sqlite3_create_function_v2(
        db.handle,
        "zova_vector_distance_by_id",
        3,
        flags,
        null,
        vectorDistanceByIdFunc,
        null,
        null,
        null,
    );
    if (rc != c.SQLITE_OK) return mapResultCode(rc);

    rc = c.sqlite3_create_module_v2(
        db.handle,
        "zova_vector_search",
        &vector_search_module,
        db.handle,
        null,
    );
    if (rc != c.SQLITE_OK) return mapResultCode(rc);
}

fn vectorDistanceFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    if (ctx == null) return;
    if (argc != 3) {
        resultError(ctx.?, "zova_vector_distance expects 3 arguments");
        return;
    }

    const result = computeScalarDistance(ctx.?, argv, false) catch |err| {
        resultError(ctx.?, errorMessage(err));
        return;
    };
    c.sqlite3_result_double(ctx.?, result);
}

fn vectorDistanceByIdFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    if (ctx == null) return;
    if (argc != 3) {
        resultError(ctx.?, "zova_vector_distance_by_id expects 3 arguments");
        return;
    }

    const result = computeScalarDistance(ctx.?, argv, true) catch |err| {
        resultError(ctx.?, errorMessage(err));
        return;
    };
    c.sqlite3_result_double(ctx.?, result);
}

fn computeScalarDistance(ctx: *c.sqlite3_context, argv: [*c]?*c.sqlite3_value, by_id: bool) Error!f64 {
    const db = c.sqlite3_context_db_handle(ctx) orelse return error.SqliteError;
    const collection_name = try valueText(argv[0] orelse return error.InvalidArgument);
    const vector_id = try valueText(argv[1] orelse return error.InvalidArgument);

    var wrapper = sqlite.Database{ .handle = db };
    const collection = try loadCollection(&wrapper, collection_name);

    var query: []f32 = undefined;
    if (by_id) {
        const source_vector_id = try valueText(argv[2] orelse return error.InvalidArgument);
        query = try loadVectorValues(&wrapper, collection_name, source_vector_id, collection);
    } else {
        const query_blob = try valueBlob(argv[2] orelse return error.InvalidArgument);
        query = try decodeQueryBlob(query_blob, collection);
    }
    defer allocator.free(query);

    const encoded = try loadVectorEncoded(&wrapper, collection_name, vector_id, collection);
    defer allocator.free(encoded);

    return try vectorDistanceFromEncoded(collection.metric, query, encoded, collection.dimensions);
}

const vector_search_module = c.sqlite3_module{
    .iVersion = 3,
    .xCreate = null,
    .xConnect = searchConnect,
    .xBestIndex = searchBestIndex,
    .xDisconnect = searchDisconnect,
    .xDestroy = null,
    .xOpen = searchOpen,
    .xClose = searchClose,
    .xFilter = searchFilter,
    .xNext = searchNext,
    .xEof = searchEof,
    .xColumn = searchColumn,
    .xRowid = searchRowid,
    .xUpdate = null,
    .xBegin = null,
    .xSync = null,
    .xCommit = null,
    .xRollback = null,
    .xFindFunction = null,
    .xRename = null,
    .xSavepoint = null,
    .xRelease = null,
    .xRollbackTo = null,
    .xShadowName = null,
    .xIntegrity = null,
};

fn searchConnect(
    db: ?*c.sqlite3,
    p_aux: ?*anyopaque,
    argc: c_int,
    argv: [*c]const [*c]const u8,
    pp_vtab: [*c][*c]c.sqlite3_vtab,
    pz_err: [*c][*c]u8,
) callconv(.c) c_int {
    _ = argc;
    _ = argv;
    _ = pz_err;

    const raw_db = db orelse return c.SQLITE_ERROR;
    const aux_db: ?*c.sqlite3 = if (p_aux) |ptr| @ptrCast(ptr) else raw_db;

    const rc = c.sqlite3_declare_vtab(raw_db,
        \\create table zova_vector_search(
        \\  rank integer,
        \\  vector_id text,
        \\  distance real,
        \\  collection text hidden,
        \\  query_vector blob hidden,
        \\  source_vector_id text hidden,
        \\  top_k integer hidden,
        \\  max_distance real hidden
        \\)
    );
    if (rc != c.SQLITE_OK) return rc;

    const table = allocator.create(SearchTable) catch return c.SQLITE_NOMEM;
    table.* = .{
        .base = .{ .pModule = &vector_search_module, .nRef = 0, .zErrMsg = null },
        .db = aux_db,
    };
    pp_vtab.* = &table.base;
    return c.SQLITE_OK;
}

fn searchBestIndex(vtab: ?*c.sqlite3_vtab, info: ?*c.sqlite3_index_info) callconv(.c) c_int {
    _ = vtab;
    const idx = info orelse return c.SQLITE_ERROR;

    var bits: ConstraintBits = .{};
    var argv_index: c_int = 1;

    bits.collection = assignConstraint(idx, .collection, &argv_index);
    bits.query_vector = assignConstraint(idx, .query_vector, &argv_index);
    bits.source_vector_id = assignConstraint(idx, .source_vector_id, &argv_index);
    bits.top_k = assignConstraint(idx, .top_k, &argv_index);
    bits.max_distance = assignConstraint(idx, .max_distance, &argv_index);

    if (!bits.collection) return c.SQLITE_CONSTRAINT;
    if (bits.query_vector == bits.source_vector_id) return c.SQLITE_CONSTRAINT;
    if (!bits.top_k and !bits.max_distance) return c.SQLITE_CONSTRAINT;

    idx.idxNum = @intCast(@as(u8, @bitCast(bits)));
    idx.estimatedCost = 1000;
    idx.estimatedRows = if (bits.top_k) 10 else 1000;

    if (idx.nOrderBy == 1) {
        const order_by = idx.aOrderBy[0];
        if (order_by.iColumn == @intFromEnum(Column.rank) and order_by.desc == 0) {
            idx.orderByConsumed = 1;
        }
    }

    return c.SQLITE_OK;
}

fn assignConstraint(idx: *c.sqlite3_index_info, column: Column, argv_index: *c_int) bool {
    const constraints = idx.aConstraint[0..@intCast(idx.nConstraint)];
    const usages = idx.aConstraintUsage[0..@intCast(idx.nConstraint)];
    for (constraints, usages) |constraint, *usage| {
        if (constraint.usable == 0 or constraint.op != c.SQLITE_INDEX_CONSTRAINT_EQ) continue;
        if (constraint.iColumn != @intFromEnum(column)) continue;

        usage.argvIndex = argv_index.*;
        usage.omit = 1;
        argv_index.* += 1;
        return true;
    }
    return false;
}

fn searchDisconnect(vtab: ?*c.sqlite3_vtab) callconv(.c) c_int {
    if (vtab) |raw| {
        const table: *SearchTable = @fieldParentPtr("base", raw);
        if (table.base.zErrMsg) |msg| c.sqlite3_free(msg);
        allocator.destroy(table);
    }
    return c.SQLITE_OK;
}

fn searchOpen(vtab: ?*c.sqlite3_vtab, pp_cursor: [*c]?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = vtab orelse return c.SQLITE_ERROR;
    const table: *SearchTable = @fieldParentPtr("base", raw);
    const cursor = allocator.create(SearchCursor) catch return c.SQLITE_NOMEM;
    cursor.* = .{
        .base = .{ .pVtab = raw },
        .db = table.db,
        .rows = null,
        .rows_len = 0,
        .index = 0,
    };
    pp_cursor.* = &cursor.base;
    return c.SQLITE_OK;
}

fn searchClose(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    if (cursor) |raw| {
        const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
        freeRows(search_cursor.rows, search_cursor.rows_len);
        allocator.destroy(search_cursor);
    }
    return c.SQLITE_OK;
}

fn searchFilter(
    cursor: ?*c.sqlite3_vtab_cursor,
    idx_num: c_int,
    idx_str: [*c]const u8,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) c_int {
    _ = idx_str;
    const raw = cursor orelse return c.SQLITE_ERROR;
    const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
    freeRows(search_cursor.rows, search_cursor.rows_len);
    search_cursor.rows = null;
    search_cursor.rows_len = 0;
    search_cursor.index = 0;

    const bits: ConstraintBits = @bitCast(@as(u8, @intCast(idx_num)));
    const expected_argc: c_int = @intCast(@as(u8, @intFromBool(bits.collection)) +
        @as(u8, @intFromBool(bits.query_vector)) +
        @as(u8, @intFromBool(bits.source_vector_id)) +
        @as(u8, @intFromBool(bits.top_k)) +
        @as(u8, @intFromBool(bits.max_distance)));
    if (argc != expected_argc) return setCursorError(search_cursor, "invalid zova_vector_search argument plan");

    var arg_index: usize = 0;
    const collection_name = valueText(argv[arg_index] orelse return setCursorError(search_cursor, "missing collection")) catch |err| return setCursorError(search_cursor, errorMessage(err));
    arg_index += 1;

    const db = search_cursor.db orelse return c.SQLITE_ERROR;
    var wrapper = sqlite.Database{ .handle = db };
    const collection = loadCollection(&wrapper, collection_name) catch |err| return setCursorError(search_cursor, errorMessage(err));

    var query: []f32 = undefined;
    if (bits.query_vector) {
        const query_blob = valueBlob(argv[arg_index] orelse return setCursorError(search_cursor, "missing query_vector")) catch |err| return setCursorError(search_cursor, errorMessage(err));
        query = decodeQueryBlob(query_blob, collection) catch |err| return setCursorError(search_cursor, errorMessage(err));
        arg_index += 1;
    } else {
        const source_vector_id = valueText(argv[arg_index] orelse return setCursorError(search_cursor, "missing source_vector_id")) catch |err| return setCursorError(search_cursor, errorMessage(err));
        query = loadVectorValues(&wrapper, collection_name, source_vector_id, collection) catch |err| return setCursorError(search_cursor, errorMessage(err));
        arg_index += 1;
    }
    defer allocator.free(query);

    var top_k: ?usize = null;
    if (bits.top_k) {
        top_k = parseTopK(argv[arg_index] orelse return setCursorError(search_cursor, "missing top_k")) catch |err| return setCursorError(search_cursor, errorMessage(err));
        arg_index += 1;
    }

    var max_distance: ?f64 = null;
    if (bits.max_distance) {
        max_distance = parseMaxDistance(argv[arg_index] orelse return setCursorError(search_cursor, "missing max_distance")) catch |err| return setCursorError(search_cursor, errorMessage(err));
        arg_index += 1;
    }

    const rows = searchAll(&wrapper, collection_name, collection, query, top_k, max_distance, if (bits.source_vector_id) querySourceId(argv, bits) else null) catch |err| {
        return setCursorError(search_cursor, errorMessage(err));
    };
    search_cursor.rows = rows.ptr;
    search_cursor.rows_len = rows.len;
    return c.SQLITE_OK;
}

fn querySourceId(argv: [*c]?*c.sqlite3_value, bits: ConstraintBits) ?[]const u8 {
    if (!bits.source_vector_id) return null;
    const index: usize = 1;
    return valueText(argv[index] orelse return null) catch null;
}

fn searchNext(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
    if (search_cursor.index < search_cursor.rows_len) search_cursor.index += 1;
    return c.SQLITE_OK;
}

fn searchEof(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = cursor orelse return 1;
    const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
    return if (search_cursor.index >= search_cursor.rows_len) 1 else 0;
}

fn searchColumn(cursor: ?*c.sqlite3_vtab_cursor, ctx: ?*c.sqlite3_context, column_index: c_int) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const context = ctx orelse return c.SQLITE_ERROR;
    const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
    if (search_cursor.index >= search_cursor.rows_len) {
        c.sqlite3_result_null(context);
        return c.SQLITE_OK;
    }

    const row = search_cursor.rows.?[search_cursor.index];
    switch (@as(Column, @enumFromInt(column_index))) {
        .rank => c.sqlite3_result_int64(context, @intCast(search_cursor.index + 1)),
        .vector_id => {
            if (row.id) |id| {
                c.sqlite3_result_text(context, id, @intCast(row.id_len), null);
            } else {
                c.sqlite3_result_null(context);
            }
        },
        .distance => c.sqlite3_result_double(context, row.distance),
        else => c.sqlite3_result_null(context),
    }
    return c.SQLITE_OK;
}

fn searchRowid(cursor: ?*c.sqlite3_vtab_cursor, rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
    rowid.* = @intCast(search_cursor.index + 1);
    return c.SQLITE_OK;
}

fn loadCollection(db: *sqlite.Database, name: []const u8) Error!Collection {
    try validateName(name);

    var stmt = try db.prepare(
        \\select dimensions, metric, element_type
        \\from _zova_vector_collections
        \\where name = ?
    );
    defer stmt.deinit();

    try stmt.bindText(1, name);
    return switch (try stmt.step()) {
        .done => error.VectorCollectionNotFound,
        .row => {
            const dimensions_i64 = stmt.columnInt64(0);
            if (dimensions_i64 <= 0 or dimensions_i64 > max_vector_dimensions) return error.VectorCorrupt;
            if (!std.mem.eql(u8, stmt.columnText(2), "f32")) return error.VectorCorrupt;
            return .{
                .dimensions = @intCast(dimensions_i64),
                .metric = try metricFromText(stmt.columnText(1)),
            };
        },
    };
}

fn loadVectorEncoded(db: *sqlite.Database, collection_name: []const u8, vector_id: []const u8, collection: Collection) Error![]u8 {
    try validateName(vector_id);

    var stmt = try db.prepare(
        \\select dimensions, "values"
        \\from _zova_vectors
        \\where collection_name = ? and vector_id = ?
    );
    defer stmt.deinit();

    try stmt.bindText(1, collection_name);
    try stmt.bindText(2, vector_id);
    return switch (try stmt.step()) {
        .done => error.VectorNotFound,
        .row => {
            try validateStoredDimensions(collection.dimensions, stmt.columnInt64(0));
            const blob = stmt.columnBlob(1);
            if (blob.len != vectorByteLen(collection.dimensions)) return error.VectorCorrupt;
            return allocator.dupe(u8, blob) catch return error.OutOfMemory;
        },
    };
}

fn loadVectorValues(db: *sqlite.Database, collection_name: []const u8, vector_id: []const u8, collection: Collection) Error![]f32 {
    const encoded = try loadVectorEncoded(db, collection_name, vector_id, collection);
    defer allocator.free(encoded);
    const values = try decodeF32Le(encoded, collection.dimensions, .corrupt);
    try validateStoredValues(collection.metric, values);
    return values;
}

fn searchAll(
    db: *sqlite.Database,
    collection_name: []const u8,
    collection: Collection,
    query: []const f32,
    top_k: ?usize,
    max_distance: ?f64,
    exclude_id: ?[]const u8,
) Error![]SearchRow {
    var rows: std.ArrayList(SearchRow) = .empty;
    errdefer {
        freeRowIds(rows.items);
        rows.deinit(allocator);
    }

    if (top_k) |limit| {
        if (limit == 0) return try rows.toOwnedSlice(allocator);
    }

    var stmt = try db.prepare(
        \\select vector_id, dimensions, "values"
        \\from _zova_vectors
        \\where collection_name = ?
    );
    defer stmt.deinit();

    try stmt.bindText(1, collection_name);
    while ((try stmt.step()) == .row) {
        const vector_id = stmt.columnText(0);
        if (exclude_id) |excluded| {
            if (std.mem.eql(u8, vector_id, excluded)) continue;
        }

        try validateStoredDimensions(collection.dimensions, stmt.columnInt64(1));
        const distance = try vectorDistanceFromEncoded(collection.metric, query, stmt.columnBlob(2), collection.dimensions);
        if (!within(distance, max_distance)) continue;
        try maybeInsertRow(&rows, top_k, vector_id, distance);
    }

    const slice = try rows.toOwnedSlice(allocator);
    std.mem.sort(SearchRow, slice, {}, rowLessThan);
    return slice;
}

fn maybeInsertRow(rows: *std.ArrayList(SearchRow), top_k: ?usize, id: []const u8, distance: f64) Error!void {
    if (top_k) |limit| {
        if (limit == 0) return;
        if (rows.items.len >= limit) {
            const worst_index = worstRowIndex(rows.items);
            if (!candidateLessThan(id, distance, rows.items[worst_index])) return;
            const replacement = try makeRow(id, distance);
            if (rows.items[worst_index].id) |old_id| allocator.free(old_id[0 .. rows.items[worst_index].id_len + 1]);
            rows.items[worst_index] = replacement;
            return;
        }
    }

    const row = try makeRow(id, distance);
    errdefer if (row.id) |row_id| allocator.free(row_id[0 .. row.id_len + 1]);
    try rows.append(allocator, row);
}

fn makeRow(id: []const u8, distance: f64) Error!SearchRow {
    const id_copy = try allocator.alloc(u8, id.len + 1);
    @memcpy(id_copy[0..id.len], id);
    id_copy[id.len] = 0;
    return .{
        .id = id_copy.ptr,
        .id_len = id.len,
        .distance = distance,
    };
}

fn worstRowIndex(rows: []const SearchRow) usize {
    var worst_index: usize = 0;
    for (rows[1..], 1..) |row, index| {
        if (rowLessThan({}, rows[worst_index], row)) worst_index = index;
    }
    return worst_index;
}

fn rowLessThan(_: void, lhs: SearchRow, rhs: SearchRow) bool {
    if (lhs.distance < rhs.distance) return true;
    if (lhs.distance > rhs.distance) return false;
    return std.mem.order(u8, rowId(lhs), rowId(rhs)) == .lt;
}

fn candidateLessThan(id: []const u8, distance: f64, existing: SearchRow) bool {
    if (distance < existing.distance) return true;
    if (distance > existing.distance) return false;
    return std.mem.order(u8, id, rowId(existing)) == .lt;
}

fn rowId(row: SearchRow) []const u8 {
    if (row.id) |id| return id[0..row.id_len];
    return "";
}

fn freeRows(rows_ptr: ?[*]SearchRow, rows_len: usize) void {
    if (rows_ptr) |ptr| {
        const rows = ptr[0..rows_len];
        freeRowIds(rows);
        allocator.free(rows);
    }
}

fn freeRowIds(rows: []const SearchRow) void {
    for (rows) |row| {
        if (row.id) |id| allocator.free(id[0 .. row.id_len + 1]);
    }
}

fn decodeQueryBlob(blob: []const u8, collection: Collection) Error![]f32 {
    if (blob.len != vectorByteLen(collection.dimensions)) return error.VectorDimensionMismatch;
    const values = try decodeF32Le(blob, collection.dimensions, .invalid);
    errdefer allocator.free(values);
    try validateQueryValues(collection.metric, values);
    return values;
}

const DecodeErrorKind = enum {
    invalid,
    corrupt,
};

fn decodeF32Le(bytes: []const u8, dimensions: u32, error_kind: DecodeErrorKind) Error![]f32 {
    if (bytes.len != vectorByteLen(dimensions)) return decodeError(error_kind);
    const values = allocator.alloc(f32, dimensions) catch return error.OutOfMemory;
    errdefer allocator.free(values);
    for (values, 0..) |*value, index| {
        const bits = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
        value.* = @bitCast(bits);
        if (std.math.isNan(value.*) or std.math.isInf(value.*)) return decodeError(error_kind);
    }
    return values;
}

fn decodeError(error_kind: DecodeErrorKind) Error {
    return switch (error_kind) {
        .invalid => error.VectorInvalid,
        .corrupt => error.VectorCorrupt,
    };
}

fn vectorDistanceFromEncoded(metric: VectorMetric, query: []const f32, encoded_values: []const u8, dimensions: u32) Error!f64 {
    if (encoded_values.len != vectorByteLen(dimensions)) return error.VectorCorrupt;
    return switch (metric) {
        .cosine => cosineDistanceFromEncoded(query, encoded_values),
        .l2 => l2DistanceFromEncoded(query, encoded_values),
        .dot => dotDistanceFromEncoded(query, encoded_values),
    };
}

fn cosineDistanceFromEncoded(query: []const f32, encoded_values: []const u8) Error!f64 {
    var dot: f64 = 0;
    var query_norm: f64 = 0;
    var stored_norm: f64 = 0;

    for (query, 0..) |query_value, index| {
        const stored_value = decodeF32LeAt(encoded_values, index);
        if (std.math.isNan(stored_value) or std.math.isInf(stored_value)) return error.VectorCorrupt;
        const query_f64: f64 = @floatCast(query_value);
        const stored_f64: f64 = @floatCast(stored_value);
        dot += query_f64 * stored_f64;
        query_norm += query_f64 * query_f64;
        stored_norm += stored_f64 * stored_f64;
    }

    if (query_norm == 0 or stored_norm == 0) return error.VectorCorrupt;
    return 1.0 - (dot / (@sqrt(query_norm) * @sqrt(stored_norm)));
}

fn l2DistanceFromEncoded(query: []const f32, encoded_values: []const u8) Error!f64 {
    var sum: f64 = 0;
    for (query, 0..) |query_value, index| {
        const stored_value = decodeF32LeAt(encoded_values, index);
        if (std.math.isNan(stored_value) or std.math.isInf(stored_value)) return error.VectorCorrupt;
        const diff = @as(f64, @floatCast(query_value)) - @as(f64, @floatCast(stored_value));
        sum += diff * diff;
    }
    return @sqrt(sum);
}

fn dotDistanceFromEncoded(query: []const f32, encoded_values: []const u8) Error!f64 {
    var dot: f64 = 0;
    for (query, 0..) |query_value, index| {
        const stored_value = decodeF32LeAt(encoded_values, index);
        if (std.math.isNan(stored_value) or std.math.isInf(stored_value)) return error.VectorCorrupt;
        dot += @as(f64, @floatCast(query_value)) * @as(f64, @floatCast(stored_value));
    }
    return -dot;
}

fn decodeF32LeAt(bytes: []const u8, index: usize) f32 {
    const bits = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    return @bitCast(bits);
}

fn validateQueryValues(metric: VectorMetric, values: []const f32) Error!void {
    var norm_squared: f64 = 0;
    for (values) |value| {
        if (std.math.isNan(value) or std.math.isInf(value)) return error.VectorInvalid;
        const value_f64: f64 = @floatCast(value);
        norm_squared += value_f64 * value_f64;
    }
    if (metric == .cosine and norm_squared == 0) return error.VectorInvalid;
}

fn validateStoredValues(metric: VectorMetric, values: []const f32) Error!void {
    var norm_squared: f64 = 0;
    for (values) |value| {
        if (std.math.isNan(value) or std.math.isInf(value)) return error.VectorCorrupt;
        const value_f64: f64 = @floatCast(value);
        norm_squared += value_f64 * value_f64;
    }
    if (metric == .cosine and norm_squared == 0) return error.VectorCorrupt;
}

fn validateStoredDimensions(expected: u32, stored: i64) Error!void {
    if (stored < 0) return error.VectorCorrupt;
    if (@as(u64, @intCast(stored)) != expected) return error.VectorCorrupt;
}

fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_vector_collection_name_bytes) return error.VectorInvalid;
    if (!std.unicode.utf8ValidateSlice(name)) return error.VectorInvalid;
    if (isReservedZovaName(name)) return error.VectorInvalid;
}

fn isReservedZovaName(name: []const u8) bool {
    return name.len >= "_zova_".len and std.ascii.eqlIgnoreCase(name[0.."_zova_".len], "_zova_");
}

fn metricFromText(text: []const u8) Error!VectorMetric {
    if (std.mem.eql(u8, text, "cosine")) return .cosine;
    if (std.mem.eql(u8, text, "l2")) return .l2;
    if (std.mem.eql(u8, text, "dot")) return .dot;
    return error.VectorCorrupt;
}

fn vectorByteLen(dimensions: u32) usize {
    return @as(usize, @intCast(dimensions)) * @sizeOf(f32);
}

fn within(distance: f64, max_distance: ?f64) bool {
    if (max_distance) |threshold| return distance <= threshold;
    return true;
}

fn valueText(value: *c.sqlite3_value) Error![]const u8 {
    if (c.sqlite3_value_type(value) != c.SQLITE_TEXT) return error.InvalidArgument;
    const ptr = c.sqlite3_value_text(value) orelse return "";
    const len = c.sqlite3_value_bytes(value);
    if (len < 0) return error.InvalidArgument;
    const many: [*]const u8 = @ptrCast(ptr);
    return many[0..@intCast(len)];
}

fn valueBlob(value: *c.sqlite3_value) Error![]const u8 {
    if (c.sqlite3_value_type(value) != c.SQLITE_BLOB) return error.InvalidArgument;
    const len = c.sqlite3_value_bytes(value);
    if (len < 0) return error.InvalidArgument;
    const ptr = c.sqlite3_value_blob(value);
    if (ptr == null) {
        if (len == 0) return "";
        return error.InvalidArgument;
    }
    const many: [*]const u8 = @ptrCast(ptr.?);
    return many[0..@intCast(len)];
}

fn parseTopK(value: *c.sqlite3_value) Error!usize {
    if (c.sqlite3_value_type(value) != c.SQLITE_INTEGER) return error.InvalidArgument;
    const raw = c.sqlite3_value_int64(value);
    if (raw < 0) return error.InvalidArgument;
    return @intCast(raw);
}

fn parseMaxDistance(value: *c.sqlite3_value) Error!f64 {
    const value_type = c.sqlite3_value_type(value);
    if (value_type != c.SQLITE_INTEGER and value_type != c.SQLITE_FLOAT) return error.InvalidArgument;
    const distance = c.sqlite3_value_double(value);
    if (std.math.isNan(distance) or std.math.isInf(distance)) return error.VectorInvalid;
    return distance;
}

fn resultError(ctx: *c.sqlite3_context, message: []const u8) void {
    c.sqlite3_result_error(ctx, message.ptr, @intCast(message.len));
}

fn setCursorError(cursor: *SearchCursor, message: []const u8) c_int {
    const vtab: *c.sqlite3_vtab = @ptrCast(cursor.base.pVtab);
    const table: *SearchTable = @fieldParentPtr("base", vtab);
    setVtabError(table, message);
    return c.SQLITE_ERROR;
}

fn setVtabError(table: *SearchTable, message: []const u8) void {
    if (table.base.zErrMsg) |old| c.sqlite3_free(old);
    table.base.zErrMsg = null;

    const raw = c.sqlite3_malloc64(@intCast(message.len + 1)) orelse return;
    const copy: [*]u8 = @ptrCast(raw);
    @memcpy(copy[0..message.len], message);
    copy[message.len] = 0;
    table.base.zErrMsg = copy;
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArgument => "invalid Zova vector SQL argument",
        error.VectorCollectionNotFound => "Zova vector collection not found",
        error.VectorNotFound => "Zova vector not found",
        error.VectorDimensionMismatch => "Zova vector dimension mismatch",
        error.VectorCorrupt => "Zova vector row is corrupt",
        error.VectorInvalid => "invalid Zova vector value",
        error.NoMemory, error.OutOfMemory => "out of memory",
        else => "Zova vector SQL error",
    };
}

fn mapResultCode(rc: c_int) sqlite.Error {
    return switch (rc) {
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_NOMEM => error.NoMemory,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_CORRUPT => error.Corrupt,
        c.SQLITE_MISUSE => error.Misuse,
        else => error.SqliteError,
    };
}
