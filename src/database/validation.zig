//! Exact main and attached-store schema and identity validation.

const std = @import("std");
const extension_impl = @import("../extension.zig");
const graph_impl = @import("../graph.zig");
const kv_impl = @import("../kv.zig");
const object_impl = @import("../object.zig");
const sqlite = @import("../sqlite.zig");
const vector_impl = @import("../vector.zig");

const Error = @import("types.zig").Error;
const attachedObjectStoreIdAlloc = @import("metadata.zig").attachedObjectStoreIdAlloc;
const attachedTableColumnExists = @import("metadata.zig").attachedTableColumnExists;
const attachedTableExists = @import("metadata.zig").attachedTableExists;
const bound_graph_store_role = @import("types.zig").bound_graph_store_role;
const bound_object_store_role = @import("types.zig").bound_object_store_role;
const bound_stores_schema_sql = @import("types.zig").bound_stores_schema_sql;
const bound_stores_table = @import("types.zig").bound_stores_table;
const bound_vector_store_role = @import("types.zig").bound_vector_store_role;
const expectAttachedMetadataValue = @import("metadata.zig").expectAttachedMetadataValue;
const expectMetadataValue = @import("metadata.zig").expectMetadataValue;
const format_version = @import("types.zig").format_version;
const magic_value = @import("types.zig").magic_value;
const metadataValueAlloc = @import("metadata.zig").metadataValueAlloc;
const objectStoreIdAlloc = @import("metadata.zig").objectStoreIdAlloc;
const parseFormatVersion = @import("format.zig").parseFormatVersion;
const prepareSchemaSql = @import("metadata.zig").prepareSchemaSql;
const readFormatClassification = @import("format.zig").readFormatClassification;
const schemaSqlEqual = @import("metadata.zig").schemaSqlEqual;
const tableColumnExists = @import("metadata.zig").tableColumnExists;
const tableExists = @import("metadata.zig").tableExists;

pub fn validateOptionalBoundStoreSchema(db: *sqlite.Database) Error!void {
    if (try tableExists(db, bound_stores_table)) try validateBoundStoreTable(db);
}

pub fn validateBoundStoreTable(db: *sqlite.Database) Error!void {
    const columns = [_][]const u8{
        "role",
        "name",
        "path",
        "store_id",
        "bound_set_id",
        "object_epoch",
        "vector_epoch",
        "graph_epoch",
        "created_at_unix",
    };
    try validateRequiredTable(db, bound_stores_table, &columns, bound_stores_schema_sql);
}

pub fn ensureMainDatabaseRole(db: *sqlite.Database) Error!void {
    if (try metadataValueAlloc(std.heap.c_allocator, db, "store_role")) |role| {
        defer std.heap.c_allocator.free(role);
        if (std.mem.eql(u8, role, bound_object_store_role)) return error.BoundStoreInvalid;
        if (std.mem.eql(u8, role, bound_vector_store_role)) return error.BoundStoreInvalid;
        if (std.mem.eql(u8, role, bound_graph_store_role)) return error.BoundStoreInvalid;
        return error.NotZovaDatabase;
    }
}

pub fn validateObjectStoreDatabaseExpected(db: *sqlite.Database, expected_format: []const u8) Error!void {
    try expectMetadataValue(db, "magic", magic_value, .magic);
    try expectMetadataValue(db, "format_version", expected_format, .format_version);
    try expectMetadataValue(db, "store_role", bound_object_store_role, .magic);
    const store_id = try objectStoreIdAlloc(std.heap.c_allocator, db);
    defer std.heap.c_allocator.free(store_id);
    try validateExtensionSchema(db);
    try validateObjectSchemaExpected(db, expected_format);
}

fn validateObjectStoreDatabase(db: *sqlite.Database) Error!void {
    try validateObjectStoreDatabaseExpected(db, format_version);
}

pub fn validateAttachedObjectStoreAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    comptime schema_name: []const u8,
) Error![]u8 {
    try expectAttachedMetadataValue(db, schema_name, "magic", magic_value, .magic);
    try expectAttachedMetadataValue(db, schema_name, "format_version", format_version, .format_version);
    try expectAttachedMetadataValue(db, schema_name, "store_role", bound_object_store_role, .magic);
    const store_id = try attachedObjectStoreIdAlloc(allocator, db, schema_name);
    errdefer allocator.free(store_id);
    try validateAttachedExtensionSchema(db, schema_name);
    try validateAttachedObjectSchema(db, schema_name);
    return store_id;
}

pub fn validateVectorStoreDatabaseExpected(db: *sqlite.Database, expected_format: []const u8) Error!void {
    try expectMetadataValue(db, "magic", magic_value, .magic);
    try expectMetadataValue(db, "format_version", expected_format, .format_version);
    try expectMetadataValue(db, "store_role", bound_vector_store_role, .magic);
    const store_id = try objectStoreIdAlloc(std.heap.c_allocator, db);
    defer std.heap.c_allocator.free(store_id);
    try validateExtensionSchema(db);
    try validateVectorSchema(db);
}

fn validateVectorStoreDatabase(db: *sqlite.Database) Error!void {
    try validateVectorStoreDatabaseExpected(db, format_version);
}

pub fn validateAttachedVectorStoreAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    comptime schema_name: []const u8,
) Error![]u8 {
    try expectAttachedMetadataValue(db, schema_name, "magic", magic_value, .magic);
    try expectAttachedMetadataValue(db, schema_name, "format_version", format_version, .format_version);
    try expectAttachedMetadataValue(db, schema_name, "store_role", bound_vector_store_role, .magic);
    const store_id = try attachedObjectStoreIdAlloc(allocator, db, schema_name);
    errdefer allocator.free(store_id);
    try validateAttachedExtensionSchema(db, schema_name);
    try validateAttachedVectorSchema(db, schema_name);
    return store_id;
}

pub fn validateGraphStoreDatabaseExpected(db: *sqlite.Database, expected_format: []const u8) Error!void {
    try expectMetadataValue(db, "magic", magic_value, .magic);
    try expectMetadataValue(db, "format_version", expected_format, .format_version);
    try expectMetadataValue(db, "store_role", bound_graph_store_role, .magic);
    const store_id = try objectStoreIdAlloc(std.heap.c_allocator, db);
    defer std.heap.c_allocator.free(store_id);
    try validateExtensionSchema(db);
    try validateGraphSchema(db);
}

fn validateGraphStoreDatabase(db: *sqlite.Database) Error!void {
    try validateGraphStoreDatabaseExpected(db, format_version);
}

pub fn validateAttachedGraphStoreAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    comptime schema_name: []const u8,
) Error![]u8 {
    try expectAttachedMetadataValue(db, schema_name, "magic", magic_value, .magic);
    try expectAttachedMetadataValue(db, schema_name, "format_version", format_version, .format_version);
    try expectAttachedMetadataValue(db, schema_name, "store_role", bound_graph_store_role, .magic);
    const store_id = try attachedObjectStoreIdAlloc(allocator, db, schema_name);
    errdefer allocator.free(store_id);
    try validateAttachedExtensionSchema(db, schema_name);
    try validateAttachedGraphSchema(db, schema_name);
    return store_id;
}

fn validateAttachedObjectSchema(db: *sqlite.Database, comptime schema_name: []const u8) Error!void {
    const object_columns = [_][]const u8{
        "object_id",
        "size_bytes",
        "chunk_count",
        "chunker",
    };
    try validateAttachedRequiredTable(db, schema_name, object_impl.objects_table, &object_columns, object_impl.objects_schema_sql);

    const chunk_columns = [_][]const u8{
        "chunk_hash",
        "size_bytes",
        "data",
    };
    try validateAttachedRequiredTable(db, schema_name, object_impl.chunks_table, &chunk_columns, object_impl.chunks_schema_sql);

    const object_chunk_columns = [_][]const u8{
        "object_id",
        "chunk_index",
        "chunk_hash",
        "offset",
        "size_bytes",
    };
    try validateAttachedRequiredTable(db, schema_name, object_impl.object_chunks_table, &object_chunk_columns, object_impl.object_chunks_schema_sql);
}

fn validateAttachedVectorSchema(db: *sqlite.Database, comptime schema_name: []const u8) Error!void {
    if (try attachedTableExists(db, schema_name, "_zova_vector_norms")) return error.NotZovaDatabase;
    const vector_collection_columns = [_][]const u8{
        "collection_key",
        "name",
        "dimensions",
        "metric",
        "element_type",
    };
    try validateAttachedRequiredTable(db, schema_name, vector_impl.vector_collections_table, &vector_collection_columns, vector_impl.collections_schema_sql);

    const vector_columns = [_][]const u8{
        "vector_key",
        "collection_key",
        "vector_id",
        "values",
        "norm_squared",
    };
    try validateAttachedRequiredTable(db, schema_name, vector_impl.vectors_table, &vector_columns, vector_impl.vectors_schema_sql);
}

fn validateAttachedGraphSchema(db: *sqlite.Database, comptime schema_name: []const u8) Error!void {
    const graph_columns = [_][]const u8{ "graph_key", "name", "created_order" };
    try validateAttachedRequiredTable(db, schema_name, graph_impl.graphs_table, &graph_columns, graph_impl.graphs_schema_sql);

    const node_columns = [_][]const u8{ "node_key", "graph_key", "node_id", "kind", "target_type", "target_namespace", "target_ref", "created_order" };
    try validateAttachedRequiredTable(db, schema_name, graph_impl.graph_nodes_table, &node_columns, graph_impl.graph_nodes_schema_sql);

    const edge_type_columns = [_][]const u8{ "edge_type_key", "graph_key", "name" };
    try validateAttachedRequiredTable(db, schema_name, graph_impl.graph_edge_types_table, &edge_type_columns, graph_impl.graph_edge_types_schema_sql);

    const edge_columns = [_][]const u8{ "edge_key", "graph_key", "from_node_key", "edge_type_key", "to_node_key", "created_order", "payload" };
    try validateAttachedRequiredTable(db, schema_name, graph_impl.graph_edges_table, &edge_columns, graph_impl.graph_edges_schema_sql);
}

fn validateAttachedExtensionSchema(db: *sqlite.Database, comptime schema_name: []const u8) Error!void {
    const extension_columns = [_][]const u8{
        "name",
        "version",
        "storage_prefix",
        "zova_abi_min",
        "capabilities",
        "required",
        "installed_at_unix",
        "manifest_json",
    };
    try validateAttachedRequiredTable(db, schema_name, extension_impl.extensions_table, &extension_columns, extension_impl.extensions_schema_sql);
}

fn validateAttachedRequiredTable(
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    table_name: []const u8,
    required_columns: []const []const u8,
    expected_sql: []const u8,
) Error!void {
    if (!try attachedTableExists(db, schema_name, table_name)) return error.NotZovaDatabase;

    for (required_columns) |column_name| {
        if (!try attachedTableColumnExists(db, schema_name, table_name, column_name)) return error.NotZovaDatabase;
    }

    var table_sql = try prepareSchemaSql(db,
        \\select sql
        \\from {s}.sqlite_master
        \\where type = 'table' and name = ?
    , .{schema_name});
    defer table_sql.deinit();

    try table_sql.bindText(1, table_name);

    switch (try table_sql.step()) {
        .done => return error.NotZovaDatabase,
        .row => {
            const sql_text = table_sql.columnText(0);
            if (!schemaSqlEqual(sql_text, expected_sql)) return error.NotZovaDatabase;
        },
    }
}

pub fn validateZovaSchema(db: *sqlite.Database) Error!void {
    try expectMetadataValue(db, "magic", magic_value, .magic);
    // Classify the storage format before role and schema validation so
    // recognized but incompatible databases receive the precise migration
    // error instead of a generic schema mismatch.
    switch ((try readFormatClassification(db)).compatibility) {
        .current => {},
        .migratable => return error.MigrationRequired,
        .unsupported_legacy => return error.UnsupportedLegacyFormat,
        .unsupported_future => return error.UnsupportedFutureFormat,
    }
    try ensureMainDatabaseRole(db);
    try validateExtensionSchema(db);
    try validateObjectSchema(db);
    try validateVectorSchema(db);
    try validateGraphSchema(db);
    try validateKvSchema(db);
    try validateOptionalBoundStoreSchema(db);
}

pub fn validateExtensionLifecycleCore(db: *sqlite.Database) anyerror!void {
    try validateZovaSchema(db);
}

pub fn validateExtensionSchema(db: *sqlite.Database) Error!void {
    const extension_columns = [_][]const u8{
        "name",
        "version",
        "storage_prefix",
        "zova_abi_min",
        "capabilities",
        "required",
        "installed_at_unix",
        "manifest_json",
    };
    try validateRequiredTable(db, extension_impl.extensions_table, &extension_columns, extension_impl.extensions_schema_sql);
}

pub fn validateObjectSchema(db: *sqlite.Database) Error!void {
    return validateObjectSchemaSql(
        db,
        object_impl.objects_schema_sql,
        object_impl.chunks_schema_sql,
        object_impl.object_chunks_schema_sql,
    );
}

pub fn validateObjectSchemaExpected(db: *sqlite.Database, expected_format: []const u8) Error!void {
    const expected_version = parseFormatVersion(expected_format) orelse return error.NotZovaDatabase;
    if (expected_version <= 10) {
        return validateObjectSchemaSql(
            db,
            object_impl.format10_objects_schema_sql,
            object_impl.format10_chunks_schema_sql,
            object_impl.format10_object_chunks_schema_sql,
        );
    }
    if (expected_version == 11) return validateObjectSchema(db);
    return error.NotZovaDatabase;
}

fn validateObjectSchemaSql(
    db: *sqlite.Database,
    expected_objects_sql: []const u8,
    expected_chunks_sql: []const u8,
    expected_object_chunks_sql: []const u8,
) Error!void {
    const object_columns = [_][]const u8{
        "object_id",
        "size_bytes",
        "chunk_count",
        "chunker",
    };
    try validateRequiredTable(db, object_impl.objects_table, &object_columns, expected_objects_sql);

    const chunk_columns = [_][]const u8{
        "chunk_hash",
        "size_bytes",
        "data",
    };
    try validateRequiredTable(db, object_impl.chunks_table, &chunk_columns, expected_chunks_sql);

    const object_chunk_columns = [_][]const u8{
        "object_id",
        "chunk_index",
        "chunk_hash",
        "offset",
        "size_bytes",
    };
    try validateRequiredTable(db, object_impl.object_chunks_table, &object_chunk_columns, expected_object_chunks_sql);
}

pub fn validateVectorSchema(db: *sqlite.Database) Error!void {
    if (try tableExists(db, "_zova_vector_norms")) return error.NotZovaDatabase;
    const vector_collection_columns = [_][]const u8{
        "collection_key",
        "name",
        "dimensions",
        "metric",
        "element_type",
    };
    try validateRequiredTable(db, "_zova_vector_collections", &vector_collection_columns, vector_impl.collections_schema_sql);

    const vector_columns = [_][]const u8{
        "vector_key",
        "collection_key",
        "vector_id",
        "values",
        "norm_squared",
    };
    try validateRequiredTable(db, "_zova_vectors", &vector_columns, vector_impl.vectors_schema_sql);
}

pub fn validateGraphSchema(db: *sqlite.Database) Error!void {
    const graph_columns = [_][]const u8{
        "graph_key",
        "name",
        "created_order",
    };
    try validateRequiredTable(db, graph_impl.graphs_table, &graph_columns, graph_impl.graphs_schema_sql);

    const node_columns = [_][]const u8{
        "node_key",
        "graph_key",
        "node_id",
        "kind",
        "target_type",
        "target_namespace",
        "target_ref",
        "created_order",
    };
    try validateRequiredTable(db, graph_impl.graph_nodes_table, &node_columns, graph_impl.graph_nodes_schema_sql);

    const edge_type_columns = [_][]const u8{
        "edge_type_key",
        "graph_key",
        "name",
    };
    try validateRequiredTable(db, graph_impl.graph_edge_types_table, &edge_type_columns, graph_impl.graph_edge_types_schema_sql);

    const edge_columns = [_][]const u8{
        "edge_key",
        "graph_key",
        "from_node_key",
        "edge_type_key",
        "to_node_key",
        "created_order",
        "payload",
    };
    try validateRequiredTable(db, graph_impl.graph_edges_table, &edge_columns, graph_impl.graph_edges_schema_sql);
}

pub fn validateKvSchema(db: *sqlite.Database) Error!void {
    const kv_columns = [_][]const u8{
        "namespace",
        "key",
        "value",
    };
    try validateRequiredTable(db, kv_impl.kv_table, &kv_columns, kv_impl.kv_schema_sql);
}

fn validateRequiredTable(
    db: *sqlite.Database,
    table_name: []const u8,
    required_columns: []const []const u8,
    expected_sql: []const u8,
) Error!void {
    if (!try tableExists(db, table_name)) return error.NotZovaDatabase;

    for (required_columns) |column_name| {
        if (!try tableColumnExists(db, table_name, column_name)) return error.NotZovaDatabase;
    }

    var table_sql = try db.prepare(
        \\select sql
        \\from sqlite_master
        \\where type = 'table' and name = ?
    );
    defer table_sql.deinit();

    try table_sql.bindText(1, table_name);

    switch (try table_sql.step()) {
        .done => return error.NotZovaDatabase,
        .row => {
            const sql_text = table_sql.columnText(0);
            if (!schemaSqlEqual(sql_text, expected_sql)) return error.NotZovaDatabase;
        },
    }
}
