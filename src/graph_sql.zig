//! Private SQL integration for Zova graphs.
//!
//! This module registers read-only eponymous-only virtual tables on Zova-owned
//! SQLite connections. It intentionally stays private: callers use ordinary SQL
//! through `zova.Database.prepare` or the existing prepared-statement bindings.

const std = @import("std");
const graph = @import("graph.zig");
const sqlite = @import("sqlite.zig");

const c = sqlite.c;
const allocator = std.heap.c_allocator;

const Error = sqlite.Error || graph.Error || error{
    InvalidArgument,
    OutOfMemory,
};

const default_sql_limit: usize = 10;

const NeighborTable = extern struct {
    base: c.sqlite3_vtab,
    db: ?*c.sqlite3,
};

const NeighborCursor = extern struct {
    base: c.sqlite3_vtab_cursor,
    db: ?*c.sqlite3,
    rows: ?[*]graph.GraphNeighbor = null,
    rows_len: usize = 0,
    index: usize = 0,
};

const NeighborConstraintBits = packed struct(u8) {
    graph_name: bool = false,
    source_node_id: bool = false,
    direction: bool = false,
    edge_type_filter: bool = false,
    limit: bool = false,
    _: u3 = 0,
};

const NeighborColumn = enum(c_int) {
    rank = 0,
    node_id = 1,
    kind = 2,
    edge_type = 3,
    graph_name = 4,
    source_node_id = 5,
    direction = 6,
    edge_type_filter = 7,
    limit = 8,
};

const WalkTable = extern struct {
    base: c.sqlite3_vtab,
    db: ?*c.sqlite3,
};

const WalkCursor = extern struct {
    base: c.sqlite3_vtab_cursor,
    db: ?*c.sqlite3,
    rows: ?[*]graph.GraphWalkItem = null,
    rows_len: usize = 0,
    index: usize = 0,
};

const WalkConstraintBits = packed struct(u8) {
    graph_name: bool = false,
    start_node_id: bool = false,
    edge_type_filter: bool = false,
    max_depth: bool = false,
    limit: bool = false,
    _: u3 = 0,
};

const WalkColumn = enum(c_int) {
    rank = 0,
    node_id = 1,
    kind = 2,
    depth = 3,
    predecessor_node_id = 4,
    edge_type = 5,
    graph_name = 6,
    start_node_id = 7,
    edge_type_filter = 8,
    max_depth = 9,
    limit = 10,
};

/// Register v0.20 SQL graph integration on one Zova-owned SQLite connection.
pub fn register(db: *sqlite.Database) sqlite.Error!void {
    var rc = c.sqlite3_create_module_v2(
        db.handle,
        "zova_graph_neighbors",
        &graph_neighbors_module,
        db.handle,
        null,
    );
    if (rc != c.SQLITE_OK) return mapResultCode(rc);

    rc = c.sqlite3_create_module_v2(
        db.handle,
        "zova_graph_walk",
        &graph_walk_module,
        db.handle,
        null,
    );
    if (rc != c.SQLITE_OK) return mapResultCode(rc);
}

const graph_neighbors_module = c.sqlite3_module{
    .iVersion = 3,
    .xCreate = null,
    .xConnect = neighborsConnect,
    .xBestIndex = neighborsBestIndex,
    .xDisconnect = neighborsDisconnect,
    .xDestroy = null,
    .xOpen = neighborsOpen,
    .xClose = neighborsClose,
    .xFilter = neighborsFilter,
    .xNext = neighborsNext,
    .xEof = neighborsEof,
    .xColumn = neighborsColumn,
    .xRowid = neighborsRowid,
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

const graph_walk_module = c.sqlite3_module{
    .iVersion = 3,
    .xCreate = null,
    .xConnect = walkConnect,
    .xBestIndex = walkBestIndex,
    .xDisconnect = walkDisconnect,
    .xDestroy = null,
    .xOpen = walkOpen,
    .xClose = walkClose,
    .xFilter = walkFilter,
    .xNext = walkNext,
    .xEof = walkEof,
    .xColumn = walkColumn,
    .xRowid = walkRowid,
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

fn neighborsConnect(
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
        \\create table zova_graph_neighbors(
        \\  rank integer,
        \\  node_id text,
        \\  kind text,
        \\  edge_type text,
        \\  graph_name text hidden,
        \\  source_node_id text hidden,
        \\  direction text hidden,
        \\  edge_type_filter text hidden,
        \\  "limit" integer hidden
        \\)
    );
    if (rc != c.SQLITE_OK) return rc;

    const table = allocator.create(NeighborTable) catch return c.SQLITE_NOMEM;
    table.* = .{
        .base = .{ .pModule = &graph_neighbors_module, .nRef = 0, .zErrMsg = null },
        .db = aux_db,
    };
    pp_vtab.* = &table.base;
    return c.SQLITE_OK;
}

fn neighborsBestIndex(vtab: ?*c.sqlite3_vtab, info: ?*c.sqlite3_index_info) callconv(.c) c_int {
    _ = vtab;
    const idx = info orelse return c.SQLITE_ERROR;

    var bits: NeighborConstraintBits = .{};
    var argv_index: c_int = 1;
    bits.graph_name = assignConstraint(idx, @intFromEnum(NeighborColumn.graph_name), &argv_index);
    bits.source_node_id = assignConstraint(idx, @intFromEnum(NeighborColumn.source_node_id), &argv_index);
    bits.direction = assignConstraint(idx, @intFromEnum(NeighborColumn.direction), &argv_index);
    bits.edge_type_filter = assignConstraint(idx, @intFromEnum(NeighborColumn.edge_type_filter), &argv_index);
    bits.limit = assignConstraint(idx, @intFromEnum(NeighborColumn.limit), &argv_index);

    if (!bits.graph_name or !bits.source_node_id) return c.SQLITE_CONSTRAINT;

    idx.idxNum = @intCast(@as(u8, @bitCast(bits)));
    idx.estimatedCost = 100;
    idx.estimatedRows = if (bits.limit) 10 else default_sql_limit;
    if (idx.nOrderBy == 1) {
        const order_by = idx.aOrderBy[0];
        if (order_by.iColumn == @intFromEnum(NeighborColumn.rank) and order_by.desc == 0) {
            idx.orderByConsumed = 1;
        }
    }
    return c.SQLITE_OK;
}

fn neighborsDisconnect(vtab: ?*c.sqlite3_vtab) callconv(.c) c_int {
    if (vtab) |raw| {
        const table: *NeighborTable = @fieldParentPtr("base", raw);
        if (table.base.zErrMsg) |msg| c.sqlite3_free(msg);
        allocator.destroy(table);
    }
    return c.SQLITE_OK;
}

fn neighborsOpen(vtab: ?*c.sqlite3_vtab, pp_cursor: [*c]?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = vtab orelse return c.SQLITE_ERROR;
    const table: *NeighborTable = @fieldParentPtr("base", raw);
    const cursor = allocator.create(NeighborCursor) catch return c.SQLITE_NOMEM;
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

fn neighborsClose(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    if (cursor) |raw| {
        const neighbor_cursor: *NeighborCursor = @fieldParentPtr("base", raw);
        freeNeighborRows(neighbor_cursor.rows, neighbor_cursor.rows_len);
        allocator.destroy(neighbor_cursor);
    }
    return c.SQLITE_OK;
}

fn neighborsFilter(
    cursor: ?*c.sqlite3_vtab_cursor,
    idx_num: c_int,
    idx_str: [*c]const u8,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) c_int {
    _ = idx_str;
    const raw = cursor orelse return c.SQLITE_ERROR;
    const neighbor_cursor: *NeighborCursor = @fieldParentPtr("base", raw);
    freeNeighborRows(neighbor_cursor.rows, neighbor_cursor.rows_len);
    neighbor_cursor.rows = null;
    neighbor_cursor.rows_len = 0;
    neighbor_cursor.index = 0;

    const bits: NeighborConstraintBits = @bitCast(@as(u8, @intCast(idx_num)));
    const expected_argc: c_int = @intCast(@as(u8, @intFromBool(bits.graph_name)) +
        @as(u8, @intFromBool(bits.source_node_id)) +
        @as(u8, @intFromBool(bits.direction)) +
        @as(u8, @intFromBool(bits.edge_type_filter)) +
        @as(u8, @intFromBool(bits.limit)));
    if (argc != expected_argc) return setNeighborCursorError(neighbor_cursor, "invalid zova_graph_neighbors argument plan");

    var arg_index: usize = 0;
    const graph_name = valueText(argv[arg_index] orelse return setNeighborCursorError(neighbor_cursor, "missing graph_name")) catch |err| return setNeighborCursorError(neighbor_cursor, errorMessage(err));
    arg_index += 1;
    const source_node_id = valueText(argv[arg_index] orelse return setNeighborCursorError(neighbor_cursor, "missing source_node_id")) catch |err| return setNeighborCursorError(neighbor_cursor, errorMessage(err));
    arg_index += 1;

    var direction: graph.GraphNeighborDirection = .outgoing;
    if (bits.direction) {
        const direction_text = valueText(argv[arg_index] orelse return setNeighborCursorError(neighbor_cursor, "missing direction")) catch |err| return setNeighborCursorError(neighbor_cursor, errorMessage(err));
        direction = parseDirection(direction_text) catch |err| return setNeighborCursorError(neighbor_cursor, errorMessage(err));
        arg_index += 1;
    }

    var edge_type_filter: ?[]const u8 = null;
    if (bits.edge_type_filter) {
        edge_type_filter = valueText(argv[arg_index] orelse return setNeighborCursorError(neighbor_cursor, "missing edge_type_filter")) catch |err| return setNeighborCursorError(neighbor_cursor, errorMessage(err));
        arg_index += 1;
    }

    var limit: usize = default_sql_limit;
    if (bits.limit) {
        limit = parseLimit(argv[arg_index] orelse return setNeighborCursorError(neighbor_cursor, "missing limit")) catch |err| return setNeighborCursorError(neighbor_cursor, errorMessage(err));
        arg_index += 1;
    }

    const db = neighbor_cursor.db orelse return c.SQLITE_ERROR;
    var wrapper = sqlite.Database{ .handle = db };
    var graph_db = graph.Database{ .sqlite_db = &wrapper };
    const rows = graph_db.graphNeighbors(allocator, .{
        .graph_name = graph_name,
        .node_id = source_node_id,
        .direction = direction,
        .edge_type = edge_type_filter,
        .limit = limit,
    }) catch |err| return setNeighborCursorError(neighbor_cursor, errorMessage(err));

    if (rows.items.len == 0) {
        var empty_rows = rows;
        empty_rows.deinit(allocator);
        return c.SQLITE_OK;
    }
    neighbor_cursor.rows = rows.items.ptr;
    neighbor_cursor.rows_len = rows.items.len;
    return c.SQLITE_OK;
}

fn neighborsNext(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const neighbor_cursor: *NeighborCursor = @fieldParentPtr("base", raw);
    if (neighbor_cursor.index < neighbor_cursor.rows_len) neighbor_cursor.index += 1;
    return c.SQLITE_OK;
}

fn neighborsEof(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = cursor orelse return 1;
    const neighbor_cursor: *NeighborCursor = @fieldParentPtr("base", raw);
    return if (neighbor_cursor.index >= neighbor_cursor.rows_len) 1 else 0;
}

fn neighborsColumn(cursor: ?*c.sqlite3_vtab_cursor, ctx: ?*c.sqlite3_context, column_index: c_int) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const context = ctx orelse return c.SQLITE_ERROR;
    const neighbor_cursor: *NeighborCursor = @fieldParentPtr("base", raw);
    if (neighbor_cursor.index >= neighbor_cursor.rows_len) {
        c.sqlite3_result_null(context);
        return c.SQLITE_OK;
    }

    const row = neighbor_cursor.rows.?[neighbor_cursor.index];
    switch (@as(NeighborColumn, @enumFromInt(column_index))) {
        .rank => c.sqlite3_result_int64(context, @intCast(neighbor_cursor.index + 1)),
        .node_id => resultText(context, row.node_id),
        .kind => resultText(context, row.kind),
        .edge_type => resultText(context, row.edge_type),
        else => c.sqlite3_result_null(context),
    }
    return c.SQLITE_OK;
}

fn neighborsRowid(cursor: ?*c.sqlite3_vtab_cursor, rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const neighbor_cursor: *NeighborCursor = @fieldParentPtr("base", raw);
    rowid.* = @intCast(neighbor_cursor.index + 1);
    return c.SQLITE_OK;
}

fn walkConnect(
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
        \\create table zova_graph_walk(
        \\  rank integer,
        \\  node_id text,
        \\  kind text,
        \\  depth integer,
        \\  predecessor_node_id text,
        \\  edge_type text,
        \\  graph_name text hidden,
        \\  start_node_id text hidden,
        \\  edge_type_filter text hidden,
        \\  max_depth integer hidden,
        \\  "limit" integer hidden
        \\)
    );
    if (rc != c.SQLITE_OK) return rc;

    const table = allocator.create(WalkTable) catch return c.SQLITE_NOMEM;
    table.* = .{
        .base = .{ .pModule = &graph_walk_module, .nRef = 0, .zErrMsg = null },
        .db = aux_db,
    };
    pp_vtab.* = &table.base;
    return c.SQLITE_OK;
}

fn walkBestIndex(vtab: ?*c.sqlite3_vtab, info: ?*c.sqlite3_index_info) callconv(.c) c_int {
    _ = vtab;
    const idx = info orelse return c.SQLITE_ERROR;

    var bits: WalkConstraintBits = .{};
    var argv_index: c_int = 1;
    bits.graph_name = assignConstraint(idx, @intFromEnum(WalkColumn.graph_name), &argv_index);
    bits.start_node_id = assignConstraint(idx, @intFromEnum(WalkColumn.start_node_id), &argv_index);
    bits.edge_type_filter = assignConstraint(idx, @intFromEnum(WalkColumn.edge_type_filter), &argv_index);
    bits.max_depth = assignConstraint(idx, @intFromEnum(WalkColumn.max_depth), &argv_index);
    bits.limit = assignConstraint(idx, @intFromEnum(WalkColumn.limit), &argv_index);

    if (!bits.graph_name or !bits.start_node_id or !bits.max_depth) return c.SQLITE_CONSTRAINT;

    idx.idxNum = @intCast(@as(u8, @bitCast(bits)));
    idx.estimatedCost = 1000;
    idx.estimatedRows = if (bits.limit) 10 else default_sql_limit;
    if (idx.nOrderBy == 1) {
        const order_by = idx.aOrderBy[0];
        if (order_by.iColumn == @intFromEnum(WalkColumn.rank) and order_by.desc == 0) {
            idx.orderByConsumed = 1;
        }
    }
    return c.SQLITE_OK;
}

fn walkDisconnect(vtab: ?*c.sqlite3_vtab) callconv(.c) c_int {
    if (vtab) |raw| {
        const table: *WalkTable = @fieldParentPtr("base", raw);
        if (table.base.zErrMsg) |msg| c.sqlite3_free(msg);
        allocator.destroy(table);
    }
    return c.SQLITE_OK;
}

fn walkOpen(vtab: ?*c.sqlite3_vtab, pp_cursor: [*c]?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = vtab orelse return c.SQLITE_ERROR;
    const table: *WalkTable = @fieldParentPtr("base", raw);
    const cursor = allocator.create(WalkCursor) catch return c.SQLITE_NOMEM;
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

fn walkClose(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    if (cursor) |raw| {
        const walk_cursor: *WalkCursor = @fieldParentPtr("base", raw);
        freeWalkRows(walk_cursor.rows, walk_cursor.rows_len);
        allocator.destroy(walk_cursor);
    }
    return c.SQLITE_OK;
}

fn walkFilter(
    cursor: ?*c.sqlite3_vtab_cursor,
    idx_num: c_int,
    idx_str: [*c]const u8,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) c_int {
    _ = idx_str;
    const raw = cursor orelse return c.SQLITE_ERROR;
    const walk_cursor: *WalkCursor = @fieldParentPtr("base", raw);
    freeWalkRows(walk_cursor.rows, walk_cursor.rows_len);
    walk_cursor.rows = null;
    walk_cursor.rows_len = 0;
    walk_cursor.index = 0;

    const bits: WalkConstraintBits = @bitCast(@as(u8, @intCast(idx_num)));
    const expected_argc: c_int = @intCast(@as(u8, @intFromBool(bits.graph_name)) +
        @as(u8, @intFromBool(bits.start_node_id)) +
        @as(u8, @intFromBool(bits.edge_type_filter)) +
        @as(u8, @intFromBool(bits.max_depth)) +
        @as(u8, @intFromBool(bits.limit)));
    if (argc != expected_argc) return setWalkCursorError(walk_cursor, "invalid zova_graph_walk argument plan");

    var arg_index: usize = 0;
    const graph_name = valueText(argv[arg_index] orelse return setWalkCursorError(walk_cursor, "missing graph_name")) catch |err| return setWalkCursorError(walk_cursor, errorMessage(err));
    arg_index += 1;
    const start_node_id = valueText(argv[arg_index] orelse return setWalkCursorError(walk_cursor, "missing start_node_id")) catch |err| return setWalkCursorError(walk_cursor, errorMessage(err));
    arg_index += 1;

    var edge_type_filter: ?[]const u8 = null;
    if (bits.edge_type_filter) {
        edge_type_filter = valueText(argv[arg_index] orelse return setWalkCursorError(walk_cursor, "missing edge_type_filter")) catch |err| return setWalkCursorError(walk_cursor, errorMessage(err));
        arg_index += 1;
    }

    const max_depth = parseMaxDepth(argv[arg_index] orelse return setWalkCursorError(walk_cursor, "missing max_depth")) catch |err| return setWalkCursorError(walk_cursor, errorMessage(err));
    arg_index += 1;

    var limit: usize = default_sql_limit;
    if (bits.limit) {
        limit = parseLimit(argv[arg_index] orelse return setWalkCursorError(walk_cursor, "missing limit")) catch |err| return setWalkCursorError(walk_cursor, errorMessage(err));
        arg_index += 1;
    }

    const db = walk_cursor.db orelse return c.SQLITE_ERROR;
    var wrapper = sqlite.Database{ .handle = db };
    var graph_db = graph.Database{ .sqlite_db = &wrapper };
    const rows = graph_db.graphWalk(allocator, .{
        .graph_name = graph_name,
        .start_node_id = start_node_id,
        .edge_type = edge_type_filter,
        .max_depth = max_depth,
        .limit = limit,
    }) catch |err| return setWalkCursorError(walk_cursor, errorMessage(err));

    if (rows.items.len == 0) {
        var empty_rows = rows;
        empty_rows.deinit(allocator);
        return c.SQLITE_OK;
    }
    walk_cursor.rows = rows.items.ptr;
    walk_cursor.rows_len = rows.items.len;
    return c.SQLITE_OK;
}

fn walkNext(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const walk_cursor: *WalkCursor = @fieldParentPtr("base", raw);
    if (walk_cursor.index < walk_cursor.rows_len) walk_cursor.index += 1;
    return c.SQLITE_OK;
}

fn walkEof(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = cursor orelse return 1;
    const walk_cursor: *WalkCursor = @fieldParentPtr("base", raw);
    return if (walk_cursor.index >= walk_cursor.rows_len) 1 else 0;
}

fn walkColumn(cursor: ?*c.sqlite3_vtab_cursor, ctx: ?*c.sqlite3_context, column_index: c_int) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const context = ctx orelse return c.SQLITE_ERROR;
    const walk_cursor: *WalkCursor = @fieldParentPtr("base", raw);
    if (walk_cursor.index >= walk_cursor.rows_len) {
        c.sqlite3_result_null(context);
        return c.SQLITE_OK;
    }

    const row = walk_cursor.rows.?[walk_cursor.index];
    switch (@as(WalkColumn, @enumFromInt(column_index))) {
        .rank => c.sqlite3_result_int64(context, @intCast(walk_cursor.index + 1)),
        .node_id => resultText(context, row.node_id),
        .kind => resultText(context, row.kind),
        .depth => c.sqlite3_result_int64(context, @intCast(row.depth)),
        .predecessor_node_id => if (row.predecessor_node_id) |value| resultText(context, value) else c.sqlite3_result_null(context),
        .edge_type => if (row.edge_type) |value| resultText(context, value) else c.sqlite3_result_null(context),
        else => c.sqlite3_result_null(context),
    }
    return c.SQLITE_OK;
}

fn walkRowid(cursor: ?*c.sqlite3_vtab_cursor, rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const walk_cursor: *WalkCursor = @fieldParentPtr("base", raw);
    rowid.* = @intCast(walk_cursor.index + 1);
    return c.SQLITE_OK;
}

fn assignConstraint(idx: *c.sqlite3_index_info, column_index: c_int, argv_index: *c_int) bool {
    const constraints = idx.aConstraint[0..@intCast(idx.nConstraint)];
    const usages = idx.aConstraintUsage[0..@intCast(idx.nConstraint)];
    for (constraints, usages) |constraint, *usage| {
        if (constraint.usable == 0 or constraint.op != c.SQLITE_INDEX_CONSTRAINT_EQ) continue;
        if (constraint.iColumn != column_index) continue;

        usage.argvIndex = argv_index.*;
        usage.omit = 1;
        argv_index.* += 1;
        return true;
    }
    return false;
}

fn valueText(value: *c.sqlite3_value) Error![]const u8 {
    if (c.sqlite3_value_type(value) != c.SQLITE_TEXT) return error.InvalidArgument;
    const ptr = c.sqlite3_value_text(value) orelse return "";
    const len = c.sqlite3_value_bytes(value);
    if (len < 0) return error.InvalidArgument;
    const many: [*]const u8 = @ptrCast(ptr);
    return many[0..@intCast(len)];
}

fn parseDirection(value: []const u8) Error!graph.GraphNeighborDirection {
    if (std.mem.eql(u8, value, "outgoing")) return .outgoing;
    if (std.mem.eql(u8, value, "incoming")) return .incoming;
    return error.InvalidArgument;
}

fn parseLimit(value: *c.sqlite3_value) Error!usize {
    if (c.sqlite3_value_type(value) != c.SQLITE_INTEGER) return error.InvalidArgument;
    const raw = c.sqlite3_value_int64(value);
    if (raw < 0) return error.InvalidArgument;
    return @intCast(raw);
}

fn parseMaxDepth(value: *c.sqlite3_value) Error!u32 {
    if (c.sqlite3_value_type(value) != c.SQLITE_INTEGER) return error.InvalidArgument;
    const raw = c.sqlite3_value_int64(value);
    if (raw < 0) return error.InvalidArgument;
    return std.math.cast(u32, raw) orelse error.InvalidArgument;
}

fn resultText(ctx: *c.sqlite3_context, value: []const u8) void {
    c.sqlite3_result_text(ctx, value.ptr, @intCast(value.len), null);
}

fn freeNeighborRows(rows_ptr: ?[*]graph.GraphNeighbor, rows_len: usize) void {
    if (rows_ptr) |ptr| {
        var rows = graph.GraphNeighborList{ .items = ptr[0..rows_len] };
        rows.deinit(allocator);
    }
}

fn freeWalkRows(rows_ptr: ?[*]graph.GraphWalkItem, rows_len: usize) void {
    if (rows_ptr) |ptr| {
        var rows = graph.GraphWalk{ .items = ptr[0..rows_len] };
        rows.deinit(allocator);
    }
}

fn setNeighborCursorError(cursor: *NeighborCursor, message: []const u8) c_int {
    const vtab: *c.sqlite3_vtab = @ptrCast(cursor.base.pVtab);
    const table: *NeighborTable = @fieldParentPtr("base", vtab);
    setVtabError(&table.base, message);
    return c.SQLITE_ERROR;
}

fn setWalkCursorError(cursor: *WalkCursor, message: []const u8) c_int {
    const vtab: *c.sqlite3_vtab = @ptrCast(cursor.base.pVtab);
    const table: *WalkTable = @fieldParentPtr("base", vtab);
    setVtabError(&table.base, message);
    return c.SQLITE_ERROR;
}

fn setVtabError(base: *c.sqlite3_vtab, message: []const u8) void {
    if (base.zErrMsg) |old| c.sqlite3_free(old);
    base.zErrMsg = null;

    const raw = c.sqlite3_malloc64(@intCast(message.len + 1)) orelse return;
    const copy: [*]u8 = @ptrCast(raw);
    @memcpy(copy[0..message.len], message);
    copy[message.len] = 0;
    base.zErrMsg = copy;
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArgument => "invalid Zova graph SQL argument",
        error.GraphExists => "Zova graph already exists",
        error.GraphNotFound => "Zova graph not found",
        error.GraphNodeNotFound => "Zova graph node not found",
        error.GraphEdgeNotFound => "Zova graph edge not found",
        error.GraphInvalid => "invalid Zova graph value",
        error.NoMemory, error.OutOfMemory => "out of memory",
        else => "Zova graph SQL error",
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
