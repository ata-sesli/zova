//! Private SQL integration for Zova vectors.
//!
//! This module registers read-only SQLite functions and an eponymous-only
//! virtual table on Zova-owned database connections. It intentionally stays
//! private: callers use ordinary SQL through `zova.Database.prepare` or the C
//! ABI prepared-statement layer.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const vector_storage = @import("vector.zig");

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

const VectorElementType = vector_storage.VectorElementType;

const VectorValuesConst = union(VectorElementType) {
    f32: []const f32,
    f16: []const u16,
    i8: []const i8,
};

const VectorValuesOwned = union(VectorElementType) {
    f32: []f32,
    f16: []u16,
    i8: []i8,

    fn asConst(self: VectorValuesOwned) VectorValuesConst {
        return switch (self) {
            .f32 => |values| .{ .f32 = values },
            .f16 => |values| .{ .f16 = values },
            .i8 => |values| .{ .i8 = values },
        };
    }

    fn deinit(self: VectorValuesOwned) void {
        switch (self) {
            .f32 => |values| allocator.free(values),
            .f16 => |values| allocator.free(values),
            .i8 => |values| allocator.free(values),
        }
    }
};

const Collection = struct {
    collection_key: i64,
    dimensions: u32,
    metric: VectorMetric,
    element_type: VectorElementType,
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

    rc = c.sqlite3_create_function_v2(
        db.handle,
        "zova_vector_encode_f16",
        1,
        flags,
        null,
        vectorEncodeF16Func,
        null,
        null,
        null,
    );
    if (rc != c.SQLITE_OK) return mapResultCode(rc);

    rc = c.sqlite3_create_function_v2(
        db.handle,
        "zova_vector_encode_i8",
        1,
        flags,
        null,
        vectorEncodeI8Func,
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

fn vectorEncodeF16Func(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    if (ctx == null) return;
    if (argc != 1) {
        resultError(ctx.?, "zova_vector_encode_f16 expects 1 argument");
        return;
    }
    const blob = valueBlob(argv[0] orelse {
        resultError(ctx.?, errorMessage(error.InvalidArgument));
        return;
    }) catch |err| {
        resultError(ctx.?, errorMessage(err));
        return;
    };
    if (blob.len % @sizeOf(u16) != 0) {
        resultError(ctx.?, errorMessage(error.VectorDimensionMismatch));
        return;
    }
    var index: usize = 0;
    while (index < blob.len) : (index += @sizeOf(u16)) {
        const bits = std.mem.readInt(u16, blob[index..][0..2], .little);
        if (!f16BitsFinite(bits)) {
            resultError(ctx.?, errorMessage(error.VectorInvalid));
            return;
        }
    }
    resultBlob(ctx.?, blob);
}

fn vectorEncodeI8Func(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    if (ctx == null) return;
    if (argc != 1) {
        resultError(ctx.?, "zova_vector_encode_i8 expects 1 argument");
        return;
    }
    const blob = valueBlob(argv[0] orelse {
        resultError(ctx.?, errorMessage(error.InvalidArgument));
        return;
    }) catch |err| {
        resultError(ctx.?, errorMessage(err));
        return;
    };
    resultBlob(ctx.?, blob);
}

fn computeScalarDistance(ctx: *c.sqlite3_context, argv: [*c]?*c.sqlite3_value, by_id: bool) Error!f64 {
    const db = c.sqlite3_context_db_handle(ctx) orelse return error.SqliteError;
    const collection_name = try valueText(argv[0] orelse return error.InvalidArgument);
    const vector_id = try valueText(argv[1] orelse return error.InvalidArgument);

    var wrapper = sqlite.Database{ .handle = db };
    const collection = try loadCollection(&wrapper, collection_name);

    var query: VectorValuesOwned = undefined;
    if (by_id) {
        const source_vector_id = try valueText(argv[2] orelse return error.InvalidArgument);
        query = try loadVectorValues(&wrapper, collection_name, source_vector_id, collection);
    } else {
        const query_blob = try valueBlob(argv[2] orelse return error.InvalidArgument);
        query = try decodeQueryBlob(query_blob, collection);
    }
    defer query.deinit();

    const encoded = try loadVectorEncoded(&wrapper, collection_name, vector_id, collection);
    defer allocator.free(encoded);

    return try vectorDistanceFromEncoded(collection.element_type, collection.metric, query.asConst(), encoded, collection.dimensions);
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

    var query: VectorValuesOwned = undefined;
    if (bits.query_vector) {
        const query_blob = valueBlob(argv[arg_index] orelse return setCursorError(search_cursor, "missing query_vector")) catch |err| return setCursorError(search_cursor, errorMessage(err));
        query = decodeQueryBlob(query_blob, collection) catch |err| return setCursorError(search_cursor, errorMessage(err));
        arg_index += 1;
    } else {
        const source_vector_id = valueText(argv[arg_index] orelse return setCursorError(search_cursor, "missing source_vector_id")) catch |err| return setCursorError(search_cursor, errorMessage(err));
        query = loadVectorValues(&wrapper, collection_name, source_vector_id, collection) catch |err| return setCursorError(search_cursor, errorMessage(err));
        arg_index += 1;
    }
    defer query.deinit();

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

    const rows = searchAll(&wrapper, collection_name, collection, query.asConst(), top_k, max_distance, if (bits.source_vector_id) querySourceId(argv, bits) else null) catch |err| {
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

fn vectorSchemaPrefix(db: *sqlite.Database) []const u8 {
    var stmt = db.prepare("select 1 from vector_store.sqlite_master limit 1") catch return "";
    defer stmt.deinit();
    return "vector_store.";
}

fn prepareSchema(db: *sqlite.Database, comptime sql_format: []const u8, args: anytype) Error!sqlite.Statement {
    var sql_buffer: [4096]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&sql_buffer, sql_format, args) catch return error.SqliteError;
    return try db.prepare(sql);
}

fn loadCollection(db: *sqlite.Database, name: []const u8) Error!Collection {
    try validateName(name);

    const prefix = vectorSchemaPrefix(db);
    var stmt = try prepareSchema(db,
        \\select collection_key, dimensions, metric, element_type
        \\from {s}_zova_vector_collections
        \\where name = ?
    , .{prefix});
    defer stmt.deinit();

    try stmt.bindText(1, name);
    return switch (try stmt.step()) {
        .done => error.VectorCollectionNotFound,
        .row => {
            const dimensions_i64 = stmt.columnInt64(1);
            if (dimensions_i64 <= 0 or dimensions_i64 > max_vector_dimensions) return error.VectorCorrupt;
            return .{
                .collection_key = stmt.columnInt64(0),
                .dimensions = @intCast(dimensions_i64),
                .metric = try metricFromText(stmt.columnText(2)),
                .element_type = try elementTypeFromText(stmt.columnText(3)),
            };
        },
    };
}

fn loadVectorEncoded(db: *sqlite.Database, collection_name: []const u8, vector_id: []const u8, collection: Collection) Error![]u8 {
    try validateName(vector_id);

    const prefix = vectorSchemaPrefix(db);
    var stmt = try prepareSchema(db,
        \\select "values"
        \\from {s}_zova_vectors
        \\where collection_key = ? and vector_id = ?
    , .{prefix});
    defer stmt.deinit();

    _ = collection_name;
    try stmt.bindInt64(1, collection.collection_key);
    try stmt.bindText(2, vector_id);
    return switch (try stmt.step()) {
        .done => error.VectorNotFound,
        .row => {
            const blob = stmt.columnBlob(0);
            if (blob.len != vectorByteLen(collection.element_type, collection.dimensions)) return error.VectorCorrupt;
            return allocator.dupe(u8, blob) catch return error.OutOfMemory;
        },
    };
}

fn loadVectorValues(db: *sqlite.Database, collection_name: []const u8, vector_id: []const u8, collection: Collection) Error!VectorValuesOwned {
    const encoded = try loadVectorEncoded(db, collection_name, vector_id, collection);
    defer allocator.free(encoded);
    const values = try decodeValuesLe(encoded, collection.element_type, collection.dimensions, .corrupt);
    errdefer values.deinit();
    try validateStoredValues(collection, values.asConst());
    return values;
}

fn searchAll(
    db: *sqlite.Database,
    collection_name: []const u8,
    collection: Collection,
    query: VectorValuesConst,
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

    const prefix = vectorSchemaPrefix(db);
    var stmt = try prepareSchema(db,
        \\select vector_id, "values"
        \\from {s}_zova_vectors
        \\where collection_key = ?
    , .{prefix});
    defer stmt.deinit();

    _ = collection_name;
    try stmt.bindInt64(1, collection.collection_key);
    while ((try stmt.step()) == .row) {
        const vector_id = stmt.columnText(0);
        if (exclude_id) |excluded| {
            if (std.mem.eql(u8, vector_id, excluded)) continue;
        }

        const distance = try vectorDistanceFromEncoded(collection.element_type, collection.metric, query, stmt.columnBlob(1), collection.dimensions);
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

fn decodeQueryBlob(blob: []const u8, collection: Collection) Error!VectorValuesOwned {
    if (blob.len != vectorByteLen(collection.element_type, collection.dimensions)) return error.VectorDimensionMismatch;
    const values = try decodeValuesLe(blob, collection.element_type, collection.dimensions, .invalid);
    errdefer values.deinit();
    try validateQueryValues(collection, values.asConst());
    return values;
}

const DecodeErrorKind = enum {
    invalid,
    corrupt,
};

fn decodeF32Le(bytes: []const u8, dimensions: u32, error_kind: DecodeErrorKind) Error![]f32 {
    if (bytes.len != vectorByteLen(.f32, dimensions)) return decodeError(error_kind);
    const values = allocator.alloc(f32, dimensions) catch return error.OutOfMemory;
    errdefer allocator.free(values);
    for (values, 0..) |*value, index| {
        const bits = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
        value.* = @bitCast(bits);
        if (std.math.isNan(value.*) or std.math.isInf(value.*)) return decodeError(error_kind);
    }
    return values;
}

fn decodeValuesLe(bytes: []const u8, element_type: VectorElementType, dimensions: u32, error_kind: DecodeErrorKind) Error!VectorValuesOwned {
    return switch (element_type) {
        .f32 => .{ .f32 = try decodeF32Le(bytes, dimensions, error_kind) },
        .f16 => .{ .f16 = try decodeF16Le(bytes, dimensions, error_kind) },
        .i8 => .{ .i8 = try decodeI8(bytes, dimensions, error_kind) },
    };
}

fn decodeF16Le(bytes: []const u8, dimensions: u32, error_kind: DecodeErrorKind) Error![]u16 {
    if (bytes.len != vectorByteLen(.f16, dimensions)) return decodeError(error_kind);
    const values = allocator.alloc(u16, dimensions) catch return error.OutOfMemory;
    errdefer allocator.free(values);
    for (values, 0..) |*value, index| {
        value.* = std.mem.readInt(u16, bytes[index * 2 ..][0..2], .little);
        if (!f16BitsFinite(value.*)) return decodeError(error_kind);
    }
    return values;
}

fn decodeI8(bytes: []const u8, dimensions: u32, error_kind: DecodeErrorKind) Error![]i8 {
    if (bytes.len != vectorByteLen(.i8, dimensions)) return decodeError(error_kind);
    const values = allocator.alloc(i8, dimensions) catch return error.OutOfMemory;
    errdefer allocator.free(values);
    for (values, 0..) |*value, index| {
        value.* = @bitCast(bytes[index]);
    }
    return values;
}

fn decodeError(error_kind: DecodeErrorKind) Error {
    return switch (error_kind) {
        .invalid => error.VectorInvalid,
        .corrupt => error.VectorCorrupt,
    };
}

fn vectorDistanceFromEncoded(element_type: VectorElementType, metric: VectorMetric, query: VectorValuesConst, encoded_values: []const u8, dimensions: u32) Error!f64 {
    if (vectorValuesElementType(query) != element_type) return error.VectorInvalid;
    if (vectorValuesLen(query) != dimensions) return error.VectorDimensionMismatch;
    if (encoded_values.len != vectorByteLen(element_type, dimensions)) return error.VectorCorrupt;
    return switch (metric) {
        .cosine => cosineDistanceFromEncoded(element_type, query, encoded_values),
        .l2 => l2DistanceFromEncoded(element_type, query, encoded_values),
        .dot => dotDistanceFromEncoded(element_type, query, encoded_values),
    };
}

fn cosineDistanceFromEncoded(element_type: VectorElementType, query: VectorValuesConst, encoded_values: []const u8) Error!f64 {
    var dot: f64 = 0;
    var query_norm: f64 = 0;
    var stored_norm: f64 = 0;

    for (0..vectorValuesLen(query)) |index| {
        const query_f64 = try inputValueAsF64(query, index);
        const stored_f64 = try encodedValueAsF64(element_type, encoded_values, index);
        dot += query_f64 * stored_f64;
        query_norm += query_f64 * query_f64;
        stored_norm += stored_f64 * stored_f64;
    }

    if (query_norm == 0) return error.VectorInvalid;
    if (stored_norm == 0) return error.VectorCorrupt;
    return 1.0 - (dot / (@sqrt(query_norm) * @sqrt(stored_norm)));
}

fn l2DistanceFromEncoded(element_type: VectorElementType, query: VectorValuesConst, encoded_values: []const u8) Error!f64 {
    var sum: f64 = 0;
    for (0..vectorValuesLen(query)) |index| {
        const query_f64 = try inputValueAsF64(query, index);
        const stored_f64 = try encodedValueAsF64(element_type, encoded_values, index);
        const diff = query_f64 - stored_f64;
        sum += diff * diff;
    }
    return @sqrt(sum);
}

fn dotDistanceFromEncoded(element_type: VectorElementType, query: VectorValuesConst, encoded_values: []const u8) Error!f64 {
    var dot: f64 = 0;
    for (0..vectorValuesLen(query)) |index| {
        dot += try inputValueAsF64(query, index) * try encodedValueAsF64(element_type, encoded_values, index);
    }
    return -dot;
}

fn decodeF32LeAt(bytes: []const u8, index: usize) f32 {
    const bits = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    return @bitCast(bits);
}

fn validateQueryValues(collection: Collection, values: VectorValuesConst) Error!void {
    if (vectorValuesElementType(values) != collection.element_type) return error.VectorInvalid;
    if (vectorValuesLen(values) != collection.dimensions) return error.VectorDimensionMismatch;
    var norm_squared: f64 = 0;
    for (0..vectorValuesLen(values)) |index| {
        const value_f64 = try inputValueAsF64(values, index);
        norm_squared += value_f64 * value_f64;
    }
    if (collection.metric == .cosine and norm_squared == 0) return error.VectorInvalid;
}

fn validateStoredValues(collection: Collection, values: VectorValuesConst) Error!void {
    if (vectorValuesElementType(values) != collection.element_type) return error.VectorCorrupt;
    if (vectorValuesLen(values) != collection.dimensions) return error.VectorCorrupt;
    var norm_squared: f64 = 0;
    for (0..vectorValuesLen(values)) |index| {
        const value_f64 = inputValueAsF64(values, index) catch return error.VectorCorrupt;
        norm_squared += value_f64 * value_f64;
    }
    if (collection.metric == .cosine and norm_squared == 0) return error.VectorCorrupt;
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

fn elementTypeFromText(text: []const u8) Error!VectorElementType {
    if (std.mem.eql(u8, text, "f32")) return .f32;
    if (std.mem.eql(u8, text, "f16")) return .f16;
    if (std.mem.eql(u8, text, "i8")) return .i8;
    return error.VectorCorrupt;
}

fn vectorByteLen(element_type: VectorElementType, dimensions: u32) usize {
    const element_size: usize = switch (element_type) {
        .f32 => @sizeOf(f32),
        .f16 => @sizeOf(u16),
        .i8 => @sizeOf(i8),
    };
    return @as(usize, @intCast(dimensions)) * element_size;
}

fn vectorValuesElementType(values: VectorValuesConst) VectorElementType {
    return switch (values) {
        .f32 => .f32,
        .f16 => .f16,
        .i8 => .i8,
    };
}

fn vectorValuesLen(values: VectorValuesConst) usize {
    return switch (values) {
        .f32 => |typed| typed.len,
        .f16 => |typed| typed.len,
        .i8 => |typed| typed.len,
    };
}

fn inputValueAsF64(values: VectorValuesConst, index: usize) Error!f64 {
    return switch (values) {
        .f32 => |typed| {
            const value = typed[index];
            if (std.math.isNan(value) or std.math.isInf(value)) return error.VectorInvalid;
            return vector_storage.f32ToF64(value);
        },
        .f16 => |typed| {
            const value = typed[index];
            if (!f16BitsFinite(value)) return error.VectorInvalid;
            return f16BitsToF64(value);
        },
        .i8 => |typed| vector_storage.i8ToF64(typed[index]),
    };
}

fn encodedValueAsF64(element_type: VectorElementType, encoded_values: []const u8, index: usize) Error!f64 {
    return switch (element_type) {
        .f32 => {
            const value = decodeF32LeAt(encoded_values, index);
            if (std.math.isNan(value) or std.math.isInf(value)) return error.VectorCorrupt;
            return vector_storage.f32ToF64(value);
        },
        .f16 => {
            const offset = index * @sizeOf(u16);
            const bits = std.mem.readInt(u16, encoded_values[offset..][0..2], .little);
            if (!f16BitsFinite(bits)) return error.VectorCorrupt;
            return f16BitsToF64(bits);
        },
        .i8 => vector_storage.i8ToF64(@as(i8, @bitCast(encoded_values[index]))),
    };
}

fn f16BitsFinite(bits: u16) bool {
    return ((bits >> 10) & 0x1f) != 0x1f;
}

fn f16BitsToF64(bits: u16) f64 {
    const sign = @as(u64, bits >> 15) << 63;
    const exponent = (bits >> 10) & 0x1f;
    const fraction = bits & 0x03ff;

    if (exponent == 0x1f) {
        const quiet_nan = if (fraction == 0) 0 else @as(u64, 1) << 51;
        return @bitCast(sign | (@as(u64, 0x7ff) << 52) | (@as(u64, fraction) << 42) | quiet_nan);
    }

    if (exponent == 0) {
        if (fraction == 0) return @bitCast(sign);
        const top_bit: u4 = @intCast(15 - @clz(fraction));
        const exponent64 = @as(u64, top_bit) + 999;
        const mantissa_source = @as(u64, fraction) - (@as(u64, 1) << top_bit);
        const shift: u6 = @intCast(52 - @as(u6, top_bit));
        const mantissa = mantissa_source << shift;
        return @bitCast(sign | (exponent64 << 52) | mantissa);
    }

    const exponent64 = @as(u64, exponent) + 1008;
    const mantissa = @as(u64, fraction) << 42;
    return @bitCast(sign | (exponent64 << 52) | mantissa);
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

fn resultBlob(ctx: *c.sqlite3_context, blob: []const u8) void {
    if (blob.len == 0) {
        _ = c.sqlite3_result_zeroblob64(ctx, 0);
        return;
    }

    const raw_copy = c.sqlite3_malloc64(@intCast(blob.len)) orelse {
        c.sqlite3_result_error_nomem(ctx);
        return;
    };
    const copy: [*]u8 = @ptrCast(raw_copy);
    @memcpy(copy[0..blob.len], blob);
    c.sqlite3_result_blob64(ctx, copy, @intCast(blob.len), c.sqlite3_free);
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
