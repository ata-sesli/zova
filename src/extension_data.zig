//! Bounded streaming adapter over authoritative graph/vector storage.
//! No statement, private key layout, or SQLite pointer crosses the plugin ABI.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const array = @import("sqlite_array.zig");
const graph = @import("graph.zig");
const vector = @import("vector.zig");
const api = @import("extension_plugin_api.zig");
pub const Error = sqlite.Error || error{ OutOfMemory, PluginLimit, PluginCanceled, SourceNotFound, Corrupt };
pub const max_rows = 4096;
pub const max_bytes = 1024 * 1024;

pub fn bytes(value: api.Bytes) Error![]const u8 {
    if (value.len > max_bytes or (value.len != 0 and value.data == null)) return error.InvalidArgument;
    return if (value.data) |ptr| ptr[0..@intCast(value.len)] else "";
}

fn text(value: api.Bytes, required: bool) Error![]const u8 {
    const data = try bytes(value);
    if ((required and data.len == 0) or data.len > 512 or !std.unicode.utf8ValidateSlice(data)) return error.InvalidArgument;
    return data;
}

/// Match the existing SQL graph/vector routing: an attached authoritative store
/// replaces main storage. Preparation failure other than a missing attachment
/// must not silently redirect a source to main.
pub fn schema(db: *sqlite.Database, comptime store: []const u8) sqlite.Error![]const u8 {
    var stmt = try db.prepare("pragma database_list");
    defer stmt.deinit();
    while (try stmt.step() == .row) {
        if (std.mem.eql(u8, stmt.columnText(1), store)) return store ++ ".";
    }
    return "main.";
}

fn prepare(db: *sqlite.Database, buffer: []u8, comptime template: []const u8, args: anytype) Error!sqlite.Statement {
    const sql = std.fmt.bufPrintSentinel(buffer, template, args, 0) catch return error.InvalidArgument;
    return db.prepare(sql);
}

pub fn read(allocator: std.mem.Allocator, db: *sqlite.Database, r: *const api.DataRequest) Error!api.DataPage {
    if (r.struct_size < @sizeOf(api.DataRequest) or r.reserved != 0 or r.direction > 1 or r.row == null) return error.InvalidArgument;
    if (r.row_limit == 0 or r.row_limit > max_rows or r.byte_limit == 0 or r.byte_limit > max_bytes) return error.InvalidArgument;
    if (r.key_count > r.row_limit or r.id_count > r.row_limit or (r.key_count != 0 and r.keys == null) or (r.id_count != 0 and r.ids == null)) return error.InvalidArgument;
    const op = std.enums.fromInt(api.DataOperation, r.operation) orelse return error.InvalidArgument;
    const name = try text(r.name, true);
    if (name.len > 255) return error.InvalidArgument;
    const keys = if (r.keys) |ptr| ptr[0..@intCast(r.key_count)] else &.{};
    for (keys) |key| if (key <= 0) return error.InvalidArgument;
    const ids = if (r.ids) |ptr| ptr[0..@intCast(r.id_count)] else &.{};
    var input_bytes: u64 = name.len;
    for (ids) |id| {
        const value = try text(id, true);
        if (value.len > 255) return error.InvalidArgument;
        input_bytes += value.len;
        if (input_bytes > max_bytes) return error.InvalidArgument;
    }
    if ((r.after.created_order == 0) != (r.after.key == 0) or r.after.created_order < 0 or r.after.key < 0) return error.InvalidArgument;
    const after_id = try text(r.after_id, false);
    const node_id = try text(r.node_id, op == .graph_neighbors);
    const edge_type = try text(r.edge_type, false);
    const is_graph = r.operation <= @backingInt(api.DataOperation.graph_neighbors);
    if (is_graph) graph.validateGraphName(name) catch return error.InvalidArgument;
    if (!is_graph) {
        vector.validateVectorCollectionName(name) catch return error.InvalidArgument;
        if (after_id.len > 255) return error.InvalidArgument;
        for (ids) |id| vector.validateVectorId(try bytes(id)) catch return error.InvalidArgument;
    }
    if (op == .graph_neighbors) {
        graph.validateNodeId(node_id) catch return error.InvalidArgument;
        if (edge_type.len != 0) graph.validateEdgeType(edge_type) catch return error.InvalidArgument;
    }
    const prefix = if (is_graph) try schema(db, "graph_store") else try schema(db, "vector_store");
    var buffer: [4096]u8 = undefined;
    var source = if (is_graph)
        try prepare(db, &buffer, "select graph_key from {s}_zova_graphs where name=?1", .{prefix})
    else
        try prepare(db, &buffer, "select collection_key,dimensions,element_type,metric from {s}_zova_vector_collections where name=?1", .{prefix});
    defer source.deinit();
    try source.bindTextBorrowed(1, name);
    if (try source.step() != .row) return error.SourceNotFound;
    const source_key = source.columnInt64(0);
    var dimensions: usize = 0;
    var element_size: usize = 0;
    var vector_type: vector.VectorElementType = .f32;
    var vector_metric: vector.VectorMetric = .l2;
    if (!is_graph) {
        const dims = source.columnInt64(1);
        if (dims <= 0 or dims > 16384) return error.Corrupt;
        dimensions = @intCast(dims);
        const element = source.columnText(2);
        element_size = if (std.mem.eql(u8, element, "f32")) 4 else if (std.mem.eql(u8, element, "f16")) 2 else if (std.mem.eql(u8, element, "i8")) 1 else return error.Corrupt;
        vector_type = std.meta.stringToEnum(vector.VectorElementType, element) orelse return error.Corrupt;
        vector_metric = std.meta.stringToEnum(vector.VectorMetric, source.columnText(3)) orelse return error.Corrupt;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var stmt = switch (op) {
        .graph_nodes_scan => try prepare(db, &buffer, "select node_key,node_id,kind,created_order from {s}_zova_graph_nodes where graph_key=?1 and (created_order,node_key)>(?2,?3) order by created_order,node_key limit ?4", .{prefix}),
        .graph_edges_scan => try prepare(db, &buffer, "select e.edge_key,e.from_node_key,t.name,e.to_node_key,e.created_order from {s}_zova_graph_edges e join {s}_zova_graph_edge_types t on t.edge_type_key=e.edge_type_key where e.graph_key=?1 and (e.created_order,e.edge_key)>(?2,?3) order by e.created_order,e.edge_key limit ?4", .{ prefix, prefix }),
        .graph_nodes_get => try prepare(db, &buffer, "select b.rowid-1,n.node_key is not null,b.value,n.node_id,n.kind,n.created_order from carray(?2) b left join {s}_zova_graph_nodes n on n.graph_key=?1 and n.node_key=b.value", .{prefix}),
        .graph_edges_get => try prepare(db, &buffer, "select b.rowid-1,e.edge_key is not null,b.value,e.from_node_key,t.name,e.to_node_key,e.created_order from carray(?2) b left join {s}_zova_graph_edges e on e.graph_key=?1 and e.edge_key=b.value left join {s}_zova_graph_edge_types t on t.edge_type_key=e.edge_type_key", .{ prefix, prefix }),
        .graph_neighbors => try prepareNeighbors(db, &buffer, prefix, r.direction, edge_type.len != 0),
        .vector_metadata => try prepare(db, &buffer, "select dimensions,element_type,metric,(select count(*) from {s}_zova_vectors where collection_key=?1) from {s}_zova_vector_collections where collection_key=?1", .{ prefix, prefix }),
        .vectors_scan => try prepare(db, &buffer, "select vector_id,\"values\" from {s}_zova_vectors where collection_key=?1 and vector_id collate binary>?2 order by vector_id collate binary limit ?3", .{prefix}),
        .vectors_get => try prepare(db, &buffer, "select b.rowid-1,v.vector_id is not null,cast(b.value as text),v.\"values\" from carray(?2) b left join {s}_zova_vectors v on v.collection_key=?1 and v.vector_id=cast(b.value as text)", .{prefix}),
    };
    defer stmt.deinit();
    try stmt.bindInt64(1, source_key);
    switch (op) {
        .graph_nodes_scan, .graph_edges_scan => {
            try stmt.bindInt64(2, r.after.created_order);
            try stmt.bindInt64(3, r.after.key);
            try stmt.bindInt64(4, @intCast(r.row_limit + 1));
        },
        .graph_nodes_get, .graph_edges_get => try array.bindInt64Borrowed(&stmt, 2, keys),
        .graph_neighbors => {
            try stmt.bindTextBorrowed(2, node_id);
            try stmt.bindTextBorrowed(3, edge_type);
            try stmt.bindInt64(4, r.after.created_order);
            try stmt.bindInt64(5, r.after.key);
            try stmt.bindInt64(6, @intCast(r.row_limit + 1));
            var exists = try prepare(db, &buffer, "select 1 from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2", .{prefix});
            defer exists.deinit();
            try exists.bindInt64(1, source_key);
            try exists.bindTextBorrowed(2, node_id);
            if (try exists.step() != .row) return error.SourceNotFound;
        },
        .vector_metadata => {},
        .vectors_scan => {
            try stmt.bindTextBorrowed(2, after_id);
            try stmt.bindInt64(3, @intCast(r.row_limit + 1));
        },
        .vectors_get => {
            // BLOB iovecs preserve length-delimited IDs, including embedded NUL.
            // Match carray's documented iovec (including its Windows definition).
            // Only descriptors allocate: all ID bytes remain borrowed.
            const Iovec = extern struct { base: ?[*]const u8, len: usize };
            const entries = try arena.allocator().alloc(Iovec, ids.len);
            for (ids, entries) |id, *entry| entry.* = .{ .base = id.data, .len = @intCast(id.len) };
            const rc = sqlite.c.sqlite3_carray_bind(stmt.handle, 2, @ptrCast(entries.ptr), @intCast(entries.len), sqlite.c.SQLITE_CARRAY_BLOB, null);
            if (rc != sqlite.c.SQLITE_OK) return if (rc == sqlite.c.SQLITE_NOMEM) error.NoMemory else error.SqliteError;
        },
    }
    var page: api.DataPage = .{};
    var delivered: u64 = 0;
    while (try stmt.step() == .row) {
        if (page.rows == r.row_limit) {
            page.has_more = 1;
            break;
        }
        var values: [8]api.Value = undefined;
        const count: usize = @intCast(stmt.columnCount());
        if (count > values.len) return error.Corrupt;
        const row_bytes = try readRow(&stmt, values[0..count]);
        if (row_bytes > r.byte_limit - delivered) return error.PluginLimit;
        if (op == .vectors_scan or (op == .vectors_get and values[1].integer != 0)) {
            const column: usize = if (op == .vectors_scan) 1 else 3;
            if (values[column].kind != api.value_blob or values[column].bytes_len != dimensions * element_size) return error.Corrupt;
            vector.validateEncodedValues(vector_type, vector_metric, @intCast(dimensions), values[column].bytes.?[0..@intCast(values[column].bytes_len)]) catch return error.Corrupt;
        }
        if (is_graph) try validateGraphRow(op, values[0..count]);
        try callback(r.row.?, r.user_data, values[0..count]);
        delivered += row_bytes;
        page.rows += 1;
        if (op == .graph_nodes_scan or op == .graph_edges_scan or op == .graph_neighbors) {
            page.next = .{ .created_order = values[count - 1].integer, .key = values[0].integer };
        }
    }
    return page;
}

fn prepareNeighbors(db: *sqlite.Database, buffer: []u8, prefix: []const u8, direction: u32, typed: bool) Error!sqlite.Statement {
    // Exact equality preserves the typed adjacency index search prefix; an OR
    // around the filter would instead scan/filter the untyped adjacency range.
    var filter_buffer: [256]u8 = undefined;
    const filter_sql = if (typed)
        std.fmt.bufPrint(&filter_buffer, "e.edge_type_key=(select edge_type_key from {s}_zova_graph_edge_types where graph_key=?1 and name=?3)", .{prefix}) catch return error.InvalidArgument
    else
        "?3=''";
    return prepare(db, buffer, "select e.edge_key,n.node_key,n.node_id,n.kind,t.name,e.created_order from {s}_zova_graph_edges e join {s}_zova_graph_nodes n on n.graph_key=e.graph_key and n.node_key=e.{s} left join {s}_zova_graph_edge_types t on t.graph_key=e.graph_key and t.edge_type_key=e.edge_type_key where e.graph_key=?1 and e.{s}=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2) and {s} and (e.created_order,e.edge_key)>(?4,?5) order by e.created_order,n.node_id collate binary,n.node_key limit ?6", .{ prefix, prefix, if (direction == 0) "to_node_key" else "from_node_key", prefix, if (direction == 0) "from_node_key" else "to_node_key", prefix, filter_sql });
}

fn validateGraphRow(op: api.DataOperation, values: []const api.Value) Error!void {
    const batch = op == .graph_nodes_get or op == .graph_edges_get;
    if (batch and values[1].integer == 0) return;
    if (values[if (batch) 2 else 0].integer <= 0 or values[values.len - 1].integer <= 0) return error.Corrupt;
    const node = op == .graph_nodes_scan or op == .graph_nodes_get or op == .graph_neighbors;
    if (node) {
        const column: usize = switch (op) {
            .graph_nodes_scan => 1,
            .graph_nodes_get => 3,
            else => 2,
        };
        if (values[column].kind != api.value_text or values[column + 1].kind != api.value_text) return error.Corrupt;
        graph.validateNodeId(values[column].bytes.?[0..@intCast(values[column].bytes_len)]) catch return error.Corrupt;
        graph.validateEdgeType(values[column + 1].bytes.?[0..@intCast(values[column + 1].bytes_len)]) catch return error.Corrupt;
        if (op == .graph_neighbors and values[1].integer <= 0) return error.Corrupt;
    } else {
        if (values[if (batch) 3 else 1].integer <= 0 or values[values.len - 2].integer <= 0) return error.Corrupt;
    }
    if (op != .graph_nodes_scan and op != .graph_nodes_get) {
        const column: usize = switch (op) {
            .graph_edges_scan => 2,
            .graph_edges_get, .graph_neighbors => 4,
            else => unreachable,
        };
        if (values[column].kind != api.value_text) return error.Corrupt;
        graph.validateEdgeType(values[column].bytes.?[0..@intCast(values[column].bytes_len)]) catch return error.Corrupt;
    }
}

/// Shared, allocation-free conversion used by SQL and authoritative services.
pub fn readRow(stmt: *sqlite.Statement, values: []api.Value) sqlite.Error!u64 {
    var row_bytes: u64 = values.len * @sizeOf(api.Value);
    for (values, 0..) |*value, index| {
        value.* = .{};
        const column: c_int = @intCast(index);
        switch (stmt.columnType(column)) {
            .null => {},
            .integer => value.* = .{ .kind = api.value_integer, .integer = stmt.columnInt64(column) },
            .float => value.* = .{ .kind = api.value_float, .real = stmt.columnDouble(column) },
            .text, .blob => |kind| {
                const data = if (kind == .text) stmt.columnText(column) else stmt.columnBlob(column);
                try stmt.checkColumnError();
                value.* = .{ .kind = if (kind == .text) api.value_text else api.value_blob, .bytes = data.ptr, .bytes_len = data.len };
                row_bytes += data.len;
            },
        }
    }
    return row_bytes;
}

pub fn callback(call: api.RowCallback, user: ?*anyopaque, values: []const api.Value) error{ OutOfMemory, PluginCanceled, InvalidArgument }!void {
    return switch (call(user, values.ptr, values.len)) {
        0 => {},
        2 => error.OutOfMemory,
        6 => error.PluginCanceled,
        else => error.InvalidArgument,
    };
}
