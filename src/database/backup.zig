//! Raw SQLite backup and object, vector, and graph storage copying.

const std = @import("std");
const graph_impl = @import("../graph.zig");
const object_impl = @import("../object.zig");
const sqlite = @import("../sqlite.zig");
const vector_impl = @import("../vector.zig");

const Error = @import("types.zig").Error;
const ObjectChunkId = @import("types.zig").ObjectChunkId;
const ObjectId = @import("types.zig").ObjectId;
const SplitGraphStoreCounts = @import("types.zig").SplitGraphStoreCounts;
const SplitObjectStoreCounts = @import("types.zig").SplitObjectStoreCounts;
const SplitVectorStoreCounts = @import("types.zig").SplitVectorStoreCounts;
const mapSqliteResultCode = @import("metadata.zig").mapSqliteResultCode;
const prepareSchemaSql = @import("metadata.zig").prepareSchemaSql;
const sqliteI64ToU64 = @import("metadata.zig").sqliteI64ToU64;

pub fn copyObjectStorage(
    source: *sqlite.Database,
    source_schema: object_impl.StorageSchema,
    destination: *sqlite.Database,
    destination_schema: object_impl.StorageSchema,
) Error!void {
    var source_objects = object_impl.Database{
        .sqlite_db = source,
        .storage_schema = source_schema,
        .allow_active_transactions = false,
    };

    var chunks = try prepareObjectSchemaSql(source, source_schema,
        \\select chunk_hash, size_bytes, data
        \\from {s}_zova_chunks
        \\order by hex(chunk_hash)
    , .{source_schema.prefix()});
    defer chunks.deinit();

    var insert_chunk = try prepareObjectSchemaSql(destination, destination_schema,
        \\insert into {s}_zova_chunks (chunk_hash, size_bytes, data)
        \\values (?, ?, ?)
    , .{destination_schema.prefix()});
    defer insert_chunk.deinit();

    while ((try chunks.step()) == .row) {
        const raw_hash = chunks.columnBlob(0);
        if (raw_hash.len != @sizeOf(ObjectChunkId)) return error.ObjectCorrupt;

        var hash: ObjectChunkId = undefined;
        @memcpy(hash[0..], raw_hash);

        var chunk = try source_objects.getObjectChunk(std.heap.c_allocator, hash);
        chunk.deinit(std.heap.c_allocator);

        try insert_chunk.bindBlob(1, raw_hash);
        try insert_chunk.bindInt64(2, chunks.columnInt64(1));
        try insert_chunk.bindBlob(3, chunks.columnBlob(2));
        std.debug.assert((try insert_chunk.step()) == .done);
        try insert_chunk.reset();
        try insert_chunk.clearBindings();
    }

    var objects = try prepareObjectSchemaSql(
        source,
        source_schema,
        "select object_id, size_bytes, chunk_count, chunker from {s}_zova_objects order by hex(object_id)",
        .{source_schema.prefix()},
    );
    defer objects.deinit();

    var insert_object = try prepareObjectSchemaSql(destination, destination_schema,
        \\insert into {s}_zova_objects (object_id, size_bytes, chunk_count, chunker)
        \\values (?, ?, ?, ?)
    , .{destination_schema.prefix()});
    defer insert_object.deinit();

    while ((try objects.step()) == .row) {
        const raw_id = objects.columnBlob(0);
        if (raw_id.len != @sizeOf(ObjectId)) return error.ObjectCorrupt;

        var id: ObjectId = undefined;
        @memcpy(id[0..], raw_id);

        var object = try source_objects.getObject(std.heap.c_allocator, id);
        object.deinit(std.heap.c_allocator);

        var manifest = try source_objects.objectManifest(std.heap.c_allocator, id);
        manifest.deinit(std.heap.c_allocator);

        try insert_object.bindBlob(1, raw_id);
        try insert_object.bindInt64(2, objects.columnInt64(1));
        try insert_object.bindInt64(3, objects.columnInt64(2));
        try insert_object.bindText(4, objects.columnText(3));
        std.debug.assert((try insert_object.step()) == .done);
        try insert_object.reset();
        try insert_object.clearBindings();
    }

    var manifest_rows = try prepareObjectSchemaSql(source, source_schema,
        \\select object_id, chunk_index, chunk_hash, offset, size_bytes
        \\from {s}_zova_object_chunks
        \\order by hex(object_id), chunk_index
    , .{source_schema.prefix()});
    defer manifest_rows.deinit();

    var insert_manifest = try prepareObjectSchemaSql(destination, destination_schema,
        \\insert into {s}_zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
        \\values (?, ?, ?, ?, ?)
    , .{destination_schema.prefix()});
    defer insert_manifest.deinit();

    while ((try manifest_rows.step()) == .row) {
        try insert_manifest.bindBlob(1, manifest_rows.columnBlob(0));
        try insert_manifest.bindInt64(2, manifest_rows.columnInt64(1));
        try insert_manifest.bindBlob(3, manifest_rows.columnBlob(2));
        try insert_manifest.bindInt64(4, manifest_rows.columnInt64(3));
        try insert_manifest.bindInt64(5, manifest_rows.columnInt64(4));
        std.debug.assert((try insert_manifest.step()) == .done);
        try insert_manifest.reset();
        try insert_manifest.clearBindings();
    }
}

pub fn copyVectorStorage(
    source: *sqlite.Database,
    source_schema: vector_impl.StorageSchema,
    destination: *sqlite.Database,
    destination_schema: vector_impl.StorageSchema,
) Error!void {
    var source_vectors = vector_impl.Database{
        .sqlite_db = source,
        .storage_schema = source_schema,
    };
    var destination_vectors = vector_impl.Database{
        .sqlite_db = destination,
        .storage_schema = destination_schema,
    };

    var collections = try source_vectors.listVectorCollections(std.heap.c_allocator);
    defer collections.deinit(std.heap.c_allocator);

    for (collections.items) |collection| {
        const destination_has_collection = try destination_vectors.hasVectorCollection(collection.name);
        if (destination_has_collection) {
            var destination_info = try destination_vectors.vectorCollectionInfo(std.heap.c_allocator, collection.name);
            defer destination_info.deinit(std.heap.c_allocator);
            if (destination_info.dimensions != collection.dimensions or
                destination_info.metric != collection.metric or
                destination_info.element_type != collection.element_type)
            {
                return error.VectorCollectionExists;
            }
        } else {
            try destination_vectors.createVectorCollection(collection.name, .{
                .dimensions = collection.dimensions,
                .metric = collection.metric,
                .element_type = collection.element_type,
            });
        }

        var rows = try prepareSchemaSql(source,
            \\select v.vector_id
            \\from {s}_zova_vectors v
            \\join {s}_zova_vector_collections c on c.collection_key = v.collection_key
            \\where c.name = ?
            \\order by v.vector_id
        , .{ source_schema.prefix(), source_schema.prefix() });
        defer rows.deinit();

        try rows.bindText(1, collection.name);
        while ((try rows.step()) == .row) {
            const vector_id = try std.heap.c_allocator.dupe(u8, rows.columnText(0));
            defer std.heap.c_allocator.free(vector_id);

            var vector = try source_vectors.getVector(std.heap.c_allocator, collection.name, vector_id);
            defer vector.deinit(std.heap.c_allocator);

            try destination_vectors.putVector(collection.name, vector.id, vector.values.asConst());
        }
    }
}

pub fn copyGraphStorage(
    source: *sqlite.Database,
    source_schema: graph_impl.StorageSchema,
    destination: *sqlite.Database,
    destination_schema: graph_impl.StorageSchema,
) Error!void {
    var destination_graphs = graph_impl.Database{
        .sqlite_db = destination,
        .storage_schema = destination_schema,
    };

    var graphs = try prepareSchemaSql(source,
        \\select name, created_order
        \\from {s}_zova_graphs
        \\order by created_order, name
    , .{source_schema.prefix()});
    defer graphs.deinit();
    var insert_graph = try prepareSchemaSql(
        destination,
        "insert into {s}_zova_graphs (name, created_order) values (?, ?)",
        .{destination_schema.prefix()},
    );
    defer insert_graph.deinit();
    while ((try graphs.step()) == .row) {
        try insert_graph.bindText(1, graphs.columnText(0));
        try insert_graph.bindInt64(2, graphs.columnInt64(1));
        std.debug.assert((try insert_graph.step()) == .done);
        try insert_graph.reset();
        try insert_graph.clearBindings();

        var info = try destination_graphs.graphInfo(std.heap.c_allocator, graphs.columnText(0));
        const info_matches = std.mem.eql(u8, info.name, graphs.columnText(0));
        info.deinit(std.heap.c_allocator);
        if (!info_matches) return error.GraphInvalid;
    }

    var nodes = try prepareSchemaSql(source,
        \\select g.name, n.node_id, n.kind, n.target_type, n.target_namespace, n.target_ref, n.created_order
        \\from {s}_zova_graph_nodes n
        \\join {s}_zova_graphs g on g.graph_key = n.graph_key
        \\order by g.name, n.created_order, n.node_id
    , .{ source_schema.prefix(), source_schema.prefix() });
    defer nodes.deinit();
    var insert_node = try prepareSchemaSql(destination,
        \\insert into {s}_zova_graph_nodes
        \\  (graph_key, node_id, kind, target_type, target_namespace, target_ref, created_order)
        \\values ((select graph_key from {s}_zova_graphs where name = ?), ?, ?, ?, ?, ?, ?)
    , .{ destination_schema.prefix(), destination_schema.prefix() });
    defer insert_node.deinit();
    while ((try nodes.step()) == .row) {
        try insert_node.bindText(1, nodes.columnText(0));
        try insert_node.bindText(2, nodes.columnText(1));
        try insert_node.bindText(3, nodes.columnText(2));
        try insert_node.bindText(4, nodes.columnText(3));
        if (nodes.columnType(4) == .null) try insert_node.bindNull(5) else try insert_node.bindText(5, nodes.columnText(4));
        if (nodes.columnType(5) == .null) try insert_node.bindNull(6) else try insert_node.bindText(6, nodes.columnText(5));
        try insert_node.bindInt64(7, nodes.columnInt64(6));
        std.debug.assert((try insert_node.step()) == .done);
        try insert_node.reset();
        try insert_node.clearBindings();

        var node = try destination_graphs.getGraphNode(std.heap.c_allocator, nodes.columnText(0), nodes.columnText(1));
        const node_matches = std.mem.eql(u8, node.graph_name, nodes.columnText(0)) and
            std.mem.eql(u8, node.node_id, nodes.columnText(1)) and
            std.mem.eql(u8, node.kind, nodes.columnText(2)) and
            std.mem.eql(u8, @tagName(node.target_type), nodes.columnText(3)) and
            optionalTextMatchesColumn(node.target_namespace, &nodes, 4) and
            optionalTextMatchesColumn(node.target_ref, &nodes, 5);
        node.deinit(std.heap.c_allocator);
        if (!node_matches) return error.GraphInvalid;
    }

    var edges = try prepareSchemaSql(source,
        \\select g.name, from_node.node_id, et.name, to_node.node_id, e.created_order, e.payload
        \\from {s}_zova_graph_edges e
        \\join {s}_zova_graphs g on g.graph_key = e.graph_key
        \\join {s}_zova_graph_edge_types et on et.graph_key=e.graph_key and et.edge_type_key=e.edge_type_key
        \\join {s}_zova_graph_nodes from_node on from_node.graph_key = e.graph_key and from_node.node_key = e.from_node_key
        \\join {s}_zova_graph_nodes to_node on to_node.graph_key = e.graph_key and to_node.node_key = e.to_node_key
        \\order by g.name, e.created_order, from_node.node_id, et.name, to_node.node_id
    , .{ source_schema.prefix(), source_schema.prefix(), source_schema.prefix(), source_schema.prefix(), source_schema.prefix() });
    defer edges.deinit();
    var insert_edge = try prepareSchemaSql(destination,
        \\insert into {s}_zova_graph_edges
        \\  (graph_key, from_node_key, edge_type_key, to_node_key, created_order, payload)
        \\select g.graph_key, from_node.node_key,
        \\  (select edge_type_key from {s}_zova_graph_edge_types where graph_key=g.graph_key and name=?),
        \\  to_node.node_key, ?, ?
        \\from {s}_zova_graphs g
        \\join {s}_zova_graph_nodes from_node on from_node.graph_key = g.graph_key and from_node.node_id = ?
        \\join {s}_zova_graph_nodes to_node on to_node.graph_key = g.graph_key and to_node.node_id = ?
        \\where g.name = ?
    , .{ destination_schema.prefix(), destination_schema.prefix(), destination_schema.prefix(), destination_schema.prefix(), destination_schema.prefix() });
    defer insert_edge.deinit();
    var insert_type = try prepareSchemaSql(
        destination,
        "insert into {s}_zova_graph_edge_types(graph_key,name) values((select graph_key from {s}_zova_graphs where name=?),?) on conflict(graph_key,name) do nothing",
        .{ destination_schema.prefix(), destination_schema.prefix() },
    );
    defer insert_type.deinit();
    while ((try edges.step()) == .row) {
        try insert_type.bindText(1, edges.columnText(0));
        try insert_type.bindText(2, edges.columnText(2));
        std.debug.assert((try insert_type.step()) == .done);
        try insert_type.reset();
        try insert_type.clearBindings();

        try insert_edge.bindText(1, edges.columnText(2));
        try insert_edge.bindInt64(2, edges.columnInt64(4));
        try insert_edge.bindBlobBorrowed(3, edges.columnBlob(5));
        try insert_edge.bindText(4, edges.columnText(1));
        try insert_edge.bindText(5, edges.columnText(3));
        try insert_edge.bindText(6, edges.columnText(0));
        std.debug.assert((try insert_edge.step()) == .done);
        try insert_edge.reset();
        try insert_edge.clearBindings();

        var edge = try destination_graphs.getGraphEdge(std.heap.c_allocator, edges.columnText(0), edges.columnText(1), edges.columnText(2), edges.columnText(3));
        const edge_matches = std.mem.eql(u8, edge.graph_name, edges.columnText(0)) and
            std.mem.eql(u8, edge.from_node_id, edges.columnText(1)) and
            std.mem.eql(u8, edge.edge_type, edges.columnText(2)) and
            std.mem.eql(u8, edge.to_node_id, edges.columnText(3));
        edge.deinit(std.heap.c_allocator);
        if (!edge_matches) return error.GraphInvalid;
    }

    const source_counts = try graphStorageCounts(source, source_schema);
    const destination_counts = try graphStorageCounts(destination, destination_schema);
    if (source_counts.graphs != destination_counts.graphs or
        source_counts.nodes != destination_counts.nodes or
        source_counts.edges != destination_counts.edges)
    {
        return error.GraphInvalid;
    }
}

fn optionalTextMatchesColumn(value: ?[]const u8, row: *sqlite.Statement, column: c_int) bool {
    if (row.columnType(column) == .null) return value == null;
    return if (value) |text| std.mem.eql(u8, text, row.columnText(column)) else false;
}

pub fn clearMainObjectStorage(db: *sqlite.Database) Error!void {
    try db.exec(
        \\delete from _zova_object_chunks;
        \\delete from _zova_objects;
        \\delete from _zova_chunks;
    );
}

pub fn clearMainVectorStorage(db: *sqlite.Database) Error!void {
    try db.exec(
        \\delete from _zova_vectors;
        \\delete from _zova_vector_collections;
    );
}

pub fn clearMainGraphStorage(db: *sqlite.Database) Error!void {
    try db.exec(
        \\delete from _zova_graph_edges;
        \\delete from _zova_graph_edge_types;
        \\delete from _zova_graph_nodes;
        \\delete from _zova_graphs;
    );
}

pub fn mainObjectStorageHasRows(db: *sqlite.Database) Error!bool {
    const counts = try objectStorageCounts(db, .main);
    return counts.objects != 0 or counts.chunks != 0 or counts.manifest_rows != 0;
}

pub fn mainVectorStorageHasRows(db: *sqlite.Database) Error!bool {
    const counts = try vectorStorageCounts(db, .main);
    return counts.vector_collections != 0 or counts.vectors != 0;
}

pub fn mainGraphStorageHasRows(db: *sqlite.Database) Error!bool {
    return try countStorageRows(db, "select count(*) from {s}_zova_graphs", .{""}) != 0 or
        try countStorageRows(db, "select count(*) from {s}_zova_graph_nodes", .{""}) != 0 or
        try countStorageRows(db, "select count(*) from {s}_zova_graph_edge_types", .{""}) != 0 or
        try countStorageRows(db, "select count(*) from {s}_zova_graph_edges", .{""}) != 0;
}

pub fn objectStorageCounts(db: *sqlite.Database, storage_schema: object_impl.StorageSchema) Error!SplitObjectStoreCounts {
    return .{
        .objects = try countStorageRows(db, "select count(*) from {s}_zova_objects", .{storage_schema.prefix()}),
        .chunks = try countStorageRows(db, "select count(*) from {s}_zova_chunks", .{storage_schema.prefix()}),
        .manifest_rows = try countStorageRows(db, "select count(*) from {s}_zova_object_chunks", .{storage_schema.prefix()}),
    };
}

pub fn vectorStorageCounts(db: *sqlite.Database, storage_schema: vector_impl.StorageSchema) Error!SplitVectorStoreCounts {
    return .{
        .vector_collections = try countStorageRows(db, "select count(*) from {s}_zova_vector_collections", .{storage_schema.prefix()}),
        .vectors = try countStorageRows(db, "select count(*) from {s}_zova_vectors", .{storage_schema.prefix()}),
    };
}

pub fn graphStorageCounts(db: *sqlite.Database, storage_schema: graph_impl.StorageSchema) Error!SplitGraphStoreCounts {
    return .{
        .graphs = try countStorageRows(db, "select count(*) from {s}_zova_graphs", .{storage_schema.prefix()}),
        .nodes = try countStorageRows(db, "select count(*) from {s}_zova_graph_nodes", .{storage_schema.prefix()}),
        .edges = try countStorageRows(db, "select count(*) from {s}_zova_graph_edges", .{storage_schema.prefix()}),
    };
}

fn countStorageRows(db: *sqlite.Database, comptime sql_format: []const u8, args: anytype) Error!u64 {
    var stmt = try prepareSchemaSql(db, sql_format, args);
    defer stmt.deinit();
    std.debug.assert((try stmt.step()) == .row);
    return try sqliteI64ToU64(stmt.columnInt64(0));
}

fn prepareObjectSchemaSql(
    db: *sqlite.Database,
    storage_schema: object_impl.StorageSchema,
    comptime sql_format: []const u8,
    args: anytype,
) Error!sqlite.Statement {
    _ = storage_schema;
    return try prepareSchemaSql(db, sql_format, args);
}

pub fn backupMainDatabase(source: *sqlite.Database, dest: *sqlite.Database) Error!void {
    const backup = sqlite.c.sqlite3_backup_init(dest.handle, "main", source.handle, "main") orelse {
        return mapSqliteResultCode(sqlite.c.sqlite3_errcode(dest.handle));
    };

    const step_rc = sqlite.c.sqlite3_backup_step(backup, -1);
    const finish_rc = sqlite.c.sqlite3_backup_finish(backup);

    if (step_rc != sqlite.c.SQLITE_DONE) return mapSqliteResultCode(step_rc);
    if (finish_rc != sqlite.c.SQLITE_OK) return mapSqliteResultCode(finish_rc);
}

pub fn verifyQuickCheckMain(db: *sqlite.Database) Error!void {
    var stmt = try db.prepare("pragma quick_check");
    defer stmt.deinit();
    try expectQuickCheckOk(&stmt);
}

pub fn verifyQuickCheckAttached(db: *sqlite.Database, comptime schema_name: []const u8) Error!void {
    var stmt = try prepareSchemaSql(db, "pragma {s}.quick_check", .{schema_name});
    defer stmt.deinit();
    try expectQuickCheckOk(&stmt);
}

fn expectQuickCheckOk(stmt: *sqlite.Statement) Error!void {
    switch (try stmt.step()) {
        .done => return error.Corrupt,
        .row => {
            if (!std.mem.eql(u8, stmt.columnText(0), "ok")) return error.Corrupt;
        },
    }

    switch (try stmt.step()) {
        .done => {},
        .row => return error.Corrupt,
    }
}
