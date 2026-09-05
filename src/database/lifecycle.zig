//! Private schema initialization and standalone store creation.

const std = @import("std");
const extension_impl = @import("../extension.zig");
const graph_impl = @import("../graph.zig");
const kv_impl = @import("../kv.zig");
const object_impl = @import("../object.zig");
const sqlite = @import("../sqlite.zig");
const vector_impl = @import("../vector.zig");

const CreateOptions = @import("types.zig").CreateOptions;
const Error = @import("types.zig").Error;
const bound_graph_store_role = @import("types.zig").bound_graph_store_role;
const bound_object_store_role = @import("types.zig").bound_object_store_role;
const bound_stores_schema_sql = @import("types.zig").bound_stores_schema_sql;
const bound_stores_table = @import("types.zig").bound_stores_table;
const bound_vector_store_role = @import("types.zig").bound_vector_store_role;
const defaultIo = @import("paths.zig").defaultIo;
const deleteBoundGraphStoreRows = @import("bound_stores.zig").deleteBoundGraphStoreRows;
const deleteBoundObjectStoreRows = @import("bound_stores.zig").deleteBoundObjectStoreRows;
const deleteBoundVectorStoreRows = @import("bound_stores.zig").deleteBoundVectorStoreRows;
const format_version = @import("types.zig").format_version;
const isZovaPath = @import("paths.zig").isZovaPath;
const lowerHexInto = @import("metadata.zig").lowerHexInto;
const randomHex64 = @import("metadata.zig").randomHex64;
const tableExists = @import("metadata.zig").tableExists;
const validateBoundStoreTable = @import("validation.zig").validateBoundStoreTable;

/// Create a standalone object-store `.zova` file.
///
/// This is opt-in storage for a main database that later calls
/// `Database.bindObjectStore`. Normal `.zova` files remain single-file by
/// default, and object-store files are rejected by `Database.open` as main
/// databases.
pub fn createObjectStore(path: [:0]const u8) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;

    const io = defaultIo();
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DestinationExists,
        else => return error.CantOpen,
    };
    file.close(io);

    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var raw = try sqlite.Database.open(path);
    defer raw.deinit();

    try initializeZovaSchema(&raw);
    try markAsObjectStore(&raw);
}

/// Create a standalone vector-store `.zova` file.
///
/// This is opt-in storage for a main database that later calls
/// `Database.bindVectorStore`. Normal `.zova` files remain single-file by
/// default, and vector-store files are rejected by `Database.open` as main
/// databases.
pub fn createVectorStore(path: [:0]const u8) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;

    const io = defaultIo();
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DestinationExists,
        else => return error.CantOpen,
    };
    file.close(io);

    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var raw = try sqlite.Database.open(path);
    defer raw.deinit();

    try initializeZovaSchema(&raw);
    try markAsVectorStore(&raw);
}

/// Create a standalone graph-store `.zova` file.
pub fn createGraphStore(path: [:0]const u8) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;

    const io = defaultIo();
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DestinationExists,
        else => return error.CantOpen,
    };
    file.close(io);

    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var raw = try sqlite.Database.open(path);
    defer raw.deinit();

    try initializeZovaSchema(&raw);
    try markAsGraphStore(&raw);
}

pub fn validateCreateOptions(options: CreateOptions) Error!void {
    if (options.page_size == 0) return;
    if (options.page_size < 512 or options.page_size > 65536 or
        !std.math.isPowerOfTwo(options.page_size))
    {
        return error.InvalidArgument;
    }
}

pub fn applyCreateOptions(db: *sqlite.Database, options: CreateOptions) Error!void {
    if (options.page_size == 0) return;

    var sql_buffer: [64]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&sql_buffer, "pragma page_size={d}", .{options.page_size}) catch
        return error.InvalidArgument;
    try db.exec(sql);

    var query = try db.prepare("pragma page_size");
    defer query.deinit();
    if (try query.step() != .row or query.columnInt64(0) != options.page_size or
        try query.step() != .done)
    {
        return error.SqliteError;
    }
}

pub fn initializeZovaSchema(db: *sqlite.Database) sqlite.Error!void {
    try initializeMetadata(db);
    try initializeExtensionSchema(db);
    try initializeObjectSchema(db);
    try initializeVectorSchema(db);
    try initializeGraphSchema(db);
    try initializeKvSchema(db);
}

pub fn enableForeignKeys(db: *sqlite.Database) sqlite.Error!void {
    try db.exec("pragma foreign_keys = on");
}

fn initializeMetadata(db: *sqlite.Database) sqlite.Error!void {
    var random_bytes: [32]u8 = undefined;
    sqlite.c.sqlite3_randomness(random_bytes.len, &random_bytes);

    var database_id: [64]u8 = undefined;
    lowerHexInto(&database_id, &random_bytes);

    try db.exec(
        \\create table _zova_meta (
        \\  key text primary key,
        \\  value text not null
        \\);
        \\insert into _zova_meta (key, value) values ('magic', 'zova');
    );

    var insert_format = try db.prepare("insert into _zova_meta (key, value) values ('format_version', ?)");
    defer insert_format.deinit();
    try insert_format.bindText(1, format_version);
    std.debug.assert((try insert_format.step()) == .done);

    var insert_id = try db.prepare("insert into _zova_meta (key, value) values ('database_id', ?)");
    defer insert_id.deinit();
    try insert_id.bindText(1, &database_id);
    std.debug.assert((try insert_id.step()) == .done);
}

fn initializeExtensionSchema(db: *sqlite.Database) sqlite.Error!void {
    try db.exec(extension_impl.extensions_schema_sql ++ ";");
}

fn initializeObjectSchema(db: *sqlite.Database) sqlite.Error!void {
    try db.exec(object_impl.objects_schema_sql ++ ";");
    try db.exec(object_impl.chunks_schema_sql ++ ";");
    try db.exec(object_impl.object_chunks_schema_sql ++ ";");
}

fn initializeVectorSchema(db: *sqlite.Database) sqlite.Error!void {
    try db.exec(vector_impl.collections_schema_sql ++ ";");
    try db.exec(vector_impl.vectors_schema_sql ++ ";");
}

fn initializeGraphSchema(db: *sqlite.Database) sqlite.Error!void {
    try db.exec(graph_impl.graphs_schema_sql ++ ";");
    try db.exec(graph_impl.graph_nodes_schema_sql ++ ";");
    try db.exec(graph_impl.graph_edge_types_schema_sql ++ ";");
    try db.exec(graph_impl.graph_edges_schema_sql ++ ";");
    try db.exec(graph_impl.graph_edges_topology_index_sql ++ ";");
    try db.exec(graph_impl.graph_nodes_created_order_index_sql ++ ";");
    try db.exec(graph_impl.graph_edges_created_order_index_sql ++ ";");
    try db.exec(graph_impl.graph_edges_from_node_index_sql ++ ";");
    try db.exec(graph_impl.graph_edges_from_node_type_index_sql ++ ";");
    try db.exec(graph_impl.graph_edges_to_node_index_sql ++ ";");
    try db.exec(graph_impl.graph_edges_to_node_type_index_sql ++ ";");
}

fn initializeKvSchema(db: *sqlite.Database) sqlite.Error!void {
    try db.exec(kv_impl.kv_schema_sql ++ ";");
}

fn markAsObjectStore(db: *sqlite.Database) Error!void {
    var store_id: [64]u8 = undefined;
    randomHex64(&store_id);

    var insert_role = try db.prepare("insert into _zova_meta (key, value) values ('store_role', ?)");
    defer insert_role.deinit();
    try insert_role.bindText(1, bound_object_store_role);
    std.debug.assert((try insert_role.step()) == .done);

    var insert_id = try db.prepare("insert into _zova_meta (key, value) values ('store_id', ?)");
    defer insert_id.deinit();
    try insert_id.bindText(1, &store_id);
    std.debug.assert((try insert_id.step()) == .done);

    var insert_epoch = try db.prepare("insert into _zova_meta (key, value) values ('object_epoch', '0')");
    defer insert_epoch.deinit();
    std.debug.assert((try insert_epoch.step()) == .done);
}

fn markAsVectorStore(db: *sqlite.Database) Error!void {
    var store_id: [64]u8 = undefined;
    randomHex64(&store_id);

    var insert_role = try db.prepare("insert into _zova_meta (key, value) values ('store_role', ?)");
    defer insert_role.deinit();
    try insert_role.bindText(1, bound_vector_store_role);
    std.debug.assert((try insert_role.step()) == .done);

    var insert_id = try db.prepare("insert into _zova_meta (key, value) values ('store_id', ?)");
    defer insert_id.deinit();
    try insert_id.bindText(1, &store_id);
    std.debug.assert((try insert_id.step()) == .done);

    var insert_epoch = try db.prepare("insert into _zova_meta (key, value) values ('vector_epoch', '0')");
    defer insert_epoch.deinit();
    std.debug.assert((try insert_epoch.step()) == .done);
}

fn markAsGraphStore(db: *sqlite.Database) Error!void {
    try deleteBoundObjectStoreRows(db);
    try deleteBoundVectorStoreRows(db);
    try deleteBoundGraphStoreRows(db);
    try db.exec(
        \\delete from _zova_meta
        \\where key in ('store_role', 'store_id', 'bound_set_id', 'object_epoch', 'vector_epoch', 'graph_epoch');
    );

    var store_id: [64]u8 = undefined;
    randomHex64(&store_id);

    var insert_role = try db.prepare("insert into _zova_meta (key, value) values ('store_role', ?)");
    defer insert_role.deinit();
    try insert_role.bindText(1, bound_graph_store_role);
    std.debug.assert((try insert_role.step()) == .done);

    var insert_id = try db.prepare("insert into _zova_meta (key, value) values ('store_id', ?)");
    defer insert_id.deinit();
    try insert_id.bindText(1, &store_id);
    std.debug.assert((try insert_id.step()) == .done);

    var insert_epoch = try db.prepare("insert into _zova_meta (key, value) values ('graph_epoch', '0')");
    defer insert_epoch.deinit();
    std.debug.assert((try insert_epoch.step()) == .done);
}

pub fn ensureBoundStoreTable(db: *sqlite.Database) Error!void {
    if (try tableExists(db, bound_stores_table)) {
        try validateBoundStoreTable(db);
        return;
    }
    try db.exec(bound_stores_schema_sql ++ ";");
}
