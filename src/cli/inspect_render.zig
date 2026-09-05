//! Text and JSON rendering for read-only inspection commands.

const std = @import("std");
const zova = @import("zova");
const cli_options = @import("cli_options");
const sqlite = zova.sqlite;
const package_version = cli_options.package_version;

const ChunkDetail = @import("types.zig").ChunkDetail;
const ChunkList = @import("types.zig").ChunkList;
const ChunkReference = @import("types.zig").ChunkReference;
const DatabaseSummary = @import("types.zig").DatabaseSummary;
const ManifestRow = @import("types.zig").ManifestRow;
const ObjectDetail = @import("types.zig").ObjectDetail;
const ObjectList = @import("types.zig").ObjectList;
const StatsSummary = @import("types.zig").StatsSummary;
const TableList = @import("types.zig").TableList;
const TopChunkStats = @import("types.zig").TopChunkStats;
const TopObjectStats = @import("types.zig").TopObjectStats;
const VectorCollectionDetail = @import("types.zig").VectorCollectionDetail;
const VectorCollectionListSummary = @import("types.zig").VectorCollectionListSummary;
const VectorCollectionStats = @import("types.zig").VectorCollectionStats;
const cli_json_version = @import("common.zig").cli_json_version;
const graphDirectionText = @import("common.zig").graphDirectionText;
const graphTargetTypeText = @import("common.zig").graphTargetTypeText;
const writeJsonString = @import("render.zig").writeJsonString;
const writeNullableJsonString = @import("render.zig").writeNullableJsonString;
const writeStringArrayJson = @import("render.zig").writeStringArrayJson;

pub fn writeInfoText(stdout: *std.Io.Writer, path: []const u8, summary: DatabaseSummary) !void {
    try stdout.print(
        \\Zova database: {s}
        \\package_version: {s}
        \\sqlite_version: {s}
        \\format_version: {s}
        \\database_bytes: {d}
        \\wal_bytes: {d}
        \\journal_bytes: {d}
        \\page_count: {d}
        \\page_size: {d}
        \\freelist_count: {d}
        \\objects: {d}
        \\object_logical_bytes: {d}
        \\chunks: {d}
        \\manifest_rows: {d}
        \\loose_chunks: {d}
        \\stored_chunk_bytes: {d}
        \\vector_collections: {d}
        \\vectors: {d}
        \\kv_entries: {d}
        \\kv_logical_bytes: {d}
        \\kv_allocated_bytes: {d}
        \\user_tables: {d}
        \\private_tables: {d}
        \\
    , .{
        path,
        package_version,
        sqlite.version(),
        summary.format_version,
        summary.database_bytes,
        summary.wal_bytes,
        summary.journal_bytes,
        summary.page_count,
        summary.page_size,
        summary.freelist_count,
        summary.object_count,
        summary.object_logical_bytes,
        summary.chunk_count,
        summary.manifest_count,
        summary.loose_chunk_count,
        summary.chunk_bytes,
        summary.vector_collection_count,
        summary.vector_count,
        summary.kv_entry_count,
        summary.kv_key_bytes + summary.kv_value_bytes,
        summary.kv_allocated_bytes,
        summary.user_table_count,
        summary.private_table_count,
    });
}

pub fn writeInfoJson(stdout: *std.Io.Writer, summary: DatabaseSummary) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"info\",\n");
    try stdout.writeAll("  \"package_version\": ");
    try writeJsonString(stdout, package_version);
    try stdout.writeAll(",\n  \"sqlite_version\": ");
    try writeJsonString(stdout, sqlite.version());
    try stdout.writeAll(",\n  \"format_version\": ");
    try writeJsonString(stdout, summary.format_version);
    try stdout.writeAll(",\n");
    try stdout.print(
        \\  "files": {{
        \\    "database_bytes": {d},
        \\    "wal_bytes": {d},
        \\    "journal_bytes": {d}
        \\  }},
        \\  "sqlite": {{
        \\    "page_count": {d},
        \\    "page_size": {d},
        \\    "freelist_count": {d}
        \\  }},
        \\  "objects": {{
        \\    "count": {d},
        \\    "logical_bytes": {d}
        \\  }},
        \\  "chunks": {{
        \\    "count": {d},
        \\    "manifest_rows": {d},
        \\    "loose_count": {d},
        \\    "stored_bytes": {d}
        \\  }},
        \\  "vectors": {{
        \\    "collections": {d},
        \\    "rows": {d}
        \\  }},
        \\  "kv": {{
        \\    "entries": {d},
        \\    "logical_bytes": {d},
        \\    "allocated_bytes": {d}
        \\  }},
        \\  "tables": {{
        \\    "user": {d},
        \\    "private": {d}
        \\  }}
        \\}}
        \\
    , .{
        summary.database_bytes,
        summary.wal_bytes,
        summary.journal_bytes,
        summary.page_count,
        summary.page_size,
        summary.freelist_count,
        summary.object_count,
        summary.object_logical_bytes,
        summary.chunk_count,
        summary.manifest_count,
        summary.loose_chunk_count,
        summary.chunk_bytes,
        summary.vector_collection_count,
        summary.vector_count,
        summary.kv_entry_count,
        summary.kv_key_bytes + summary.kv_value_bytes,
        summary.kv_allocated_bytes,
        summary.user_table_count,
        summary.private_table_count,
    });
}

pub fn writeStatsText(stdout: *std.Io.Writer, path: []const u8, limit: usize, summary: StatsSummary) !void {
    try stdout.print(
        \\Zova stats: {s}
        \\package_version: {s}
        \\sqlite_version: {s}
        \\format_version: {s}
        \\database_bytes: {d}
        \\wal_bytes: {d}
        \\journal_bytes: {d}
        \\page_count: {d}
        \\page_size: {d}
        \\freelist_count: {d}
        \\objects: {d}
        \\object_logical_bytes: {d}
        \\object_size_min: {d}
        \\object_size_max: {d}
        \\object_size_avg: {d:.2}
        \\object_chunk_count_min: {d}
        \\object_chunk_count_max: {d}
        \\object_chunk_count_avg: {d:.2}
        \\chunks: {d}
        \\manifest_rows: {d}
        \\loose_chunks: {d}
        \\stored_chunk_bytes: {d}
        \\chunk_size_min: {d}
        \\chunk_size_max: {d}
        \\chunk_size_avg: {d:.2}
        \\loose_chunk_bytes: {d}
        \\deduped_bytes_saved: {d}
        \\vectors: {d}
        \\user_tables: {d}
        \\private_tables: {d}
        \\limit: {d}
        \\vector_collections:
        \\
    , .{
        path,
        package_version,
        sqlite.version(),
        summary.database.format_version,
        summary.database.database_bytes,
        summary.database.wal_bytes,
        summary.database.journal_bytes,
        summary.database.page_count,
        summary.database.page_size,
        summary.database.freelist_count,
        summary.database.object_count,
        summary.database.object_logical_bytes,
        summary.object_size_min,
        summary.object_size_max,
        summary.object_size_avg,
        summary.object_chunk_count_min,
        summary.object_chunk_count_max,
        summary.object_chunk_count_avg,
        summary.database.chunk_count,
        summary.database.manifest_count,
        summary.database.loose_chunk_count,
        summary.database.chunk_bytes,
        summary.chunk_size_min,
        summary.chunk_size_max,
        summary.chunk_size_avg,
        summary.loose_chunk_bytes,
        summary.deduped_bytes_saved,
        summary.database.vector_count,
        summary.database.user_table_count,
        summary.database.private_table_count,
        limit,
    });

    if (summary.vector_collections.len == 0) {
        try stdout.writeAll("  none\n");
    } else {
        for (summary.vector_collections) |item| {
            try stdout.print("  {s} dimensions={d} metric={s} vectors={d} stored_bytes={d}\n", .{
                item.name,
                item.dimensions,
                item.metric,
                item.vector_count,
                item.stored_bytes,
            });
        }
    }

    try stdout.writeAll("top_objects:\n");
    if (summary.top_objects.len == 0) {
        try stdout.writeAll("  none\n");
    } else {
        for (summary.top_objects) |item| {
            try stdout.print("  {s} size_bytes={d} chunk_count={d} chunker={s}\n", .{
                item.id_hex,
                item.size_bytes,
                item.chunk_count,
                item.chunker,
            });
        }
    }

    try stdout.writeAll("top_chunks:\n");
    if (summary.top_chunks.len == 0) {
        try stdout.writeAll("  none\n");
    } else {
        for (summary.top_chunks) |item| {
            try stdout.print("  {s} size_bytes={d} reference_count={d} is_unreferenced={}\n", .{
                item.id_hex,
                item.size_bytes,
                item.reference_count,
                item.loose,
            });
        }
    }
}

pub fn writeStatsJson(stdout: *std.Io.Writer, limit: usize, summary: StatsSummary) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"stats\",\n");
    try stdout.print("  \"limit\": {d},\n", .{limit});
    try stdout.writeAll("  \"package_version\": ");
    try writeJsonString(stdout, package_version);
    try stdout.writeAll(",\n  \"sqlite_version\": ");
    try writeJsonString(stdout, sqlite.version());
    try stdout.writeAll(",\n  \"format_version\": ");
    try writeJsonString(stdout, summary.database.format_version);
    try stdout.writeAll(",\n");
    try stdout.print(
        \\  "files": {{
        \\    "database_bytes": {d},
        \\    "wal_bytes": {d},
        \\    "journal_bytes": {d}
        \\  }},
        \\  "sqlite": {{
        \\    "page_count": {d},
        \\    "page_size": {d},
        \\    "freelist_count": {d}
        \\  }},
        \\  "objects": {{
        \\    "count": {d},
        \\    "logical_bytes": {d},
        \\    "size_min": {d},
        \\    "size_max": {d},
        \\    "size_avg": {d},
        \\    "chunk_count_min": {d},
        \\    "chunk_count_max": {d},
        \\    "chunk_count_avg": {d}
        \\  }},
        \\  "chunks": {{
        \\    "count": {d},
        \\    "manifest_rows": {d},
        \\    "loose_count": {d},
        \\    "stored_bytes": {d},
        \\    "size_min": {d},
        \\    "size_max": {d},
        \\    "size_avg": {d},
        \\    "loose_bytes": {d},
        \\    "deduped_bytes_saved": {d}
        \\  }},
        \\  "vectors": {{
        \\    "collections": {d},
        \\    "rows": {d}
        \\  }},
        \\  "tables": {{
        \\    "user": {d},
        \\    "private": {d}
        \\  }},
        \\  "vector_collections":
    , .{
        summary.database.database_bytes,
        summary.database.wal_bytes,
        summary.database.journal_bytes,
        summary.database.page_count,
        summary.database.page_size,
        summary.database.freelist_count,
        summary.database.object_count,
        summary.database.object_logical_bytes,
        summary.object_size_min,
        summary.object_size_max,
        summary.object_size_avg,
        summary.object_chunk_count_min,
        summary.object_chunk_count_max,
        summary.object_chunk_count_avg,
        summary.database.chunk_count,
        summary.database.manifest_count,
        summary.database.loose_chunk_count,
        summary.database.chunk_bytes,
        summary.chunk_size_min,
        summary.chunk_size_max,
        summary.chunk_size_avg,
        summary.loose_chunk_bytes,
        summary.deduped_bytes_saved,
        summary.database.vector_collection_count,
        summary.database.vector_count,
        summary.database.user_table_count,
        summary.database.private_table_count,
    });
    try stdout.writeByte(' ');
    try writeVectorCollectionStatsJson(stdout, summary.vector_collections);
    try stdout.writeAll(",\n");
    try stdout.print("  \"top_objects_truncated\": {},\n", .{summary.top_objects_truncated});
    try stdout.writeAll("  \"top_objects\": ");
    try writeTopObjectStatsJson(stdout, summary.top_objects);
    try stdout.writeAll(",\n");
    try stdout.print("  \"top_chunks_truncated\": {},\n", .{summary.top_chunks_truncated});
    try stdout.writeAll("  \"top_chunks\": ");
    try writeTopChunkStatsJson(stdout, summary.top_chunks);
    try stdout.writeAll("\n}\n");
}

pub fn writeObjectsText(stdout: *std.Io.Writer, path: []const u8, limit: usize, list: ObjectList) !void {
    try stdout.print(
        \\Zova objects: {s}
        \\limit: {d}
        \\truncated: {}
        \\
    , .{ path, limit, list.truncated });
    if (list.items.len == 0) {
        try stdout.writeAll("objects: none\n");
        return;
    }
    try stdout.writeAll("objects:\n");
    for (list.items) |item| {
        try stdout.print("  {s} size_bytes={d} chunk_count={d} chunker={s}\n", .{
            item.id_hex,
            item.size_bytes,
            item.chunk_count,
            item.chunker,
        });
    }
}

pub fn writeObjectsJson(stdout: *std.Io.Writer, limit: usize, list: ObjectList) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"objects\",\n");
    try stdout.print("  \"limit\": {d},\n", .{limit});
    try stdout.print("  \"truncated\": {},\n", .{list.truncated});
    try stdout.writeAll("  \"objects\": ");
    try writeObjectRowsJson(stdout, list.items);
    try stdout.writeAll("\n}\n");
}

pub fn writeObjectText(stdout: *std.Io.Writer, path: []const u8, limit: usize, detail: ObjectDetail) !void {
    try stdout.print(
        \\Zova object: {s}
        \\object_id: {s}
        \\size_bytes: {d}
        \\chunk_count: {d}
        \\chunker: {s}
        \\limit: {d}
        \\manifest_truncated: {}
        \\manifest:
        \\
    , .{
        path,
        detail.id_hex,
        detail.size_bytes,
        detail.chunk_count,
        detail.chunker,
        limit,
        detail.manifest_truncated,
    });
    if (detail.manifest.len == 0) {
        try stdout.writeAll("  none\n");
        return;
    }
    for (detail.manifest) |item| {
        try stdout.print("  index={d} chunk_hash={s} offset={d} size_bytes={d}\n", .{
            item.index,
            item.chunk_hash_hex,
            item.offset,
            item.size_bytes,
        });
    }
}

pub fn writeObjectJson(stdout: *std.Io.Writer, limit: usize, detail: ObjectDetail) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"object\",\n");
    try stdout.writeAll("  \"object_id\": ");
    try writeJsonString(stdout, detail.id_hex);
    try stdout.print(
        \\,
        \\  "size_bytes": {d},
        \\  "chunk_count": {d},
        \\  "chunker":
    , .{ detail.size_bytes, detail.chunk_count });
    try stdout.writeByte(' ');
    try writeJsonString(stdout, detail.chunker);
    try stdout.print(
        \\,
        \\  "limit": {d},
        \\  "manifest_truncated": {},
        \\  "manifest":
    , .{ limit, detail.manifest_truncated });
    try stdout.writeByte(' ');
    try writeManifestRowsJson(stdout, detail.manifest);
    try stdout.writeAll("\n}\n");
}

pub fn writeChunksText(stdout: *std.Io.Writer, path: []const u8, limit: usize, list: ChunkList) !void {
    try stdout.print(
        \\Zova chunks: {s}
        \\limit: {d}
        \\truncated: {}
        \\
    , .{ path, limit, list.truncated });
    if (list.items.len == 0) {
        try stdout.writeAll("chunks: none\n");
        return;
    }
    try stdout.writeAll("chunks:\n");
    for (list.items) |item| {
        try stdout.print("  {s} size_bytes={d} reference_count={d} is_unreferenced={}\n", .{
            item.id_hex,
            item.size_bytes,
            item.reference_count,
            item.loose,
        });
    }
}

pub fn writeChunksJson(stdout: *std.Io.Writer, limit: usize, list: ChunkList) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"chunks\",\n");
    try stdout.print("  \"limit\": {d},\n", .{limit});
    try stdout.print("  \"truncated\": {},\n", .{list.truncated});
    try stdout.writeAll("  \"chunks\": ");
    try writeChunkRowsJson(stdout, list.items);
    try stdout.writeAll("\n}\n");
}

pub fn writeChunkText(stdout: *std.Io.Writer, path: []const u8, limit: usize, detail: ChunkDetail) !void {
    try stdout.print(
        \\Zova chunk: {s}
        \\chunk_hash: {s}
        \\size_bytes: {d}
        \\reference_count: {d}
        \\is_unreferenced: {}
        \\limit: {d}
        \\references_truncated: {}
        \\references:
        \\
    , .{
        path,
        detail.id_hex,
        detail.size_bytes,
        detail.reference_count,
        detail.loose,
        limit,
        detail.references_truncated,
    });
    if (detail.references.len == 0) {
        try stdout.writeAll("  none\n");
        return;
    }
    for (detail.references) |item| {
        try stdout.print("  object_id={s} chunk_index={d} offset={d} size_bytes={d}\n", .{
            item.object_id_hex,
            item.chunk_index,
            item.offset,
            item.size_bytes,
        });
    }
}

pub fn writeChunkJson(stdout: *std.Io.Writer, limit: usize, detail: ChunkDetail) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"chunk\",\n");
    try stdout.writeAll("  \"chunk_hash\": ");
    try writeJsonString(stdout, detail.id_hex);
    try stdout.print(
        \\,
        \\  "chunk": {{
        \\    "size_bytes": {d},
        \\    "reference_count": {d},
        \\    "loose": {}
        \\  }},
        \\  "limit": {d},
        \\  "references_truncated": {},
        \\  "references":
    , .{
        detail.size_bytes,
        detail.reference_count,
        detail.loose,
        limit,
        detail.references_truncated,
    });
    try stdout.writeByte(' ');
    try writeChunkReferencesJson(stdout, detail.references);
    try stdout.writeAll("\n}\n");
}

pub fn writeVectorsText(stdout: *std.Io.Writer, path: []const u8, limit: usize, list: VectorCollectionListSummary) !void {
    try stdout.print(
        \\Zova vector collections: {s}
        \\limit: {d}
        \\truncated: {}
        \\
    , .{ path, limit, list.truncated });
    if (list.items.len == 0) {
        try stdout.writeAll("collections: none\n");
        return;
    }
    try stdout.writeAll("collections:\n");
    for (list.items) |item| {
        try stdout.print("  {s} dimensions={d} metric={s} vectors={d} stored_bytes={d}\n", .{
            item.name,
            item.dimensions,
            item.metric,
            item.vector_count,
            item.stored_bytes,
        });
    }
}

pub fn writeVectorsJson(stdout: *std.Io.Writer, limit: usize, list: VectorCollectionListSummary) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"vectors\",\n");
    try stdout.print("  \"limit\": {d},\n", .{limit});
    try stdout.print("  \"truncated\": {},\n", .{list.truncated});
    try stdout.writeAll("  \"collections\": ");
    try writeVectorCollectionStatsJson(stdout, list.items);
    try stdout.writeAll("\n}\n");
}

pub fn writeVectorCollectionText(stdout: *std.Io.Writer, path: []const u8, limit: usize, detail: VectorCollectionDetail) !void {
    try stdout.print(
        \\Zova vector collection: {s}
        \\name: {s}
        \\dimensions: {d}
        \\metric: {s}
        \\vector_count: {d}
        \\stored_bytes: {d}
        \\limit: {d}
        \\vector_ids_truncated: {}
        \\vector_ids:
        \\
    , .{
        path,
        detail.name,
        detail.dimensions,
        detail.metric,
        detail.vector_count,
        detail.stored_bytes,
        limit,
        detail.vector_ids_truncated,
    });
    if (detail.vector_ids.len == 0) {
        try stdout.writeAll("  none\n");
        return;
    }
    for (detail.vector_ids) |id| {
        try stdout.print("  {s}\n", .{id});
    }
}

pub fn writeVectorCollectionJson(stdout: *std.Io.Writer, limit: usize, detail: VectorCollectionDetail) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"vector-collection\",\n");
    try stdout.writeAll("  \"name\": ");
    try writeJsonString(stdout, detail.name);
    try stdout.print(
        \\,
        \\  "dimensions": {d},
        \\  "metric":
    , .{detail.dimensions});
    try stdout.writeByte(' ');
    try writeJsonString(stdout, detail.metric);
    try stdout.print(
        \\,
        \\  "vector_count": {d},
        \\  "stored_bytes": {d},
        \\  "limit": {d},
        \\  "vector_ids_truncated": {},
        \\  "vector_ids":
    , .{ detail.vector_count, detail.stored_bytes, limit, detail.vector_ids_truncated });
    try stdout.writeByte(' ');
    try writeStringArrayJson(stdout, detail.vector_ids);
    try stdout.writeAll("\n}\n");
}

pub fn writeGraphsText(stdout: *std.Io.Writer, path: []const u8, limit: usize, items: []const zova.GraphInfo, truncated: bool) !void {
    try stdout.print(
        \\Zova graphs: {s}
        \\limit: {d}
        \\truncated: {}
        \\
    , .{ path, limit, truncated });
    if (items.len == 0) {
        try stdout.writeAll("graphs: none\n");
        return;
    }
    try stdout.writeAll("graphs:\n");
    for (items) |item| {
        try stdout.print("  {s} nodes={d} edges={d}\n", .{ item.name, item.node_count, item.edge_count });
    }
}

pub fn writeGraphsJson(stdout: *std.Io.Writer, limit: usize, items: []const zova.GraphInfo, truncated: bool) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"graphs\",\n");
    try stdout.print("  \"limit\": {d},\n", .{limit});
    try stdout.print("  \"truncated\": {},\n", .{truncated});
    try stdout.writeAll("  \"graphs\": ");
    try writeGraphInfoArrayJson(stdout, items);
    try stdout.writeAll("\n}\n");
}

pub fn writeGraphText(stdout: *std.Io.Writer, path: []const u8, info: zova.GraphInfo) !void {
    try stdout.print(
        \\Zova graph: {s}
        \\graph: {s}
        \\nodes: {d}
        \\edges: {d}
        \\
    , .{ path, info.name, info.node_count, info.edge_count });
}

pub fn writeGraphJson(stdout: *std.Io.Writer, info: zova.GraphInfo) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"graph\",\n");
    try stdout.writeAll("  \"graph\": ");
    try writeJsonString(stdout, info.name);
    try stdout.print(
        \\,
        \\  "node_count": {d},
        \\  "edge_count": {d}
        \\
    , .{ info.node_count, info.edge_count });
    try stdout.writeAll("}\n");
}

pub fn writeGraphNodeText(stdout: *std.Io.Writer, path: []const u8, node: zova.GraphNode) !void {
    try stdout.print(
        \\Zova graph node: {s}
        \\graph: {s}
        \\node_id: {s}
        \\kind: {s}
        \\target_type: {s}
        \\
    , .{ path, node.graph_name, node.node_id, node.kind, graphTargetTypeText(node.target_type) });
    if (node.target_namespace) |value| try stdout.print("target_namespace: {s}\n", .{value});
    if (node.target_ref) |value| try stdout.print("target_ref: {s}\n", .{value});
}

pub fn writeGraphNodeJson(stdout: *std.Io.Writer, node: zova.GraphNode) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"graph-node\",\n");
    try stdout.writeAll("  \"graph\": ");
    try writeJsonString(stdout, node.graph_name);
    try stdout.writeAll(",\n  \"node_id\": ");
    try writeJsonString(stdout, node.node_id);
    try stdout.writeAll(",\n  \"kind\": ");
    try writeJsonString(stdout, node.kind);
    try stdout.writeAll(",\n  \"target_type\": ");
    try writeJsonString(stdout, graphTargetTypeText(node.target_type));
    try stdout.writeAll(",\n  \"target_namespace\": ");
    try writeNullableJsonString(stdout, node.target_namespace);
    try stdout.writeAll(",\n  \"target_ref\": ");
    try writeNullableJsonString(stdout, node.target_ref);
    try stdout.writeAll("\n}\n");
}

pub fn writeGraphNeighborsText(
    stdout: *std.Io.Writer,
    path: []const u8,
    graph_name: []const u8,
    node_id: []const u8,
    limit: usize,
    direction: zova.GraphNeighborDirection,
    items: []const zova.GraphNeighbor,
    truncated: bool,
) !void {
    try stdout.print(
        \\Zova graph neighbors: {s}
        \\graph: {s}
        \\node_id: {s}
        \\direction: {s}
        \\limit: {d}
        \\truncated: {}
        \\
    , .{ path, graph_name, node_id, graphDirectionText(direction), limit, truncated });
    if (items.len == 0) {
        try stdout.writeAll("neighbors: none\n");
        return;
    }
    try stdout.writeAll("neighbors:\n");
    for (items) |item| {
        try stdout.print("  {s} kind={s} edge_type={s}\n", .{ item.node_id, item.kind, item.edge_type });
    }
}

pub fn writeGraphNeighborsJson(
    stdout: *std.Io.Writer,
    graph_name: []const u8,
    node_id: []const u8,
    limit: usize,
    direction: zova.GraphNeighborDirection,
    items: []const zova.GraphNeighbor,
    truncated: bool,
) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"graph-neighbors\",\n");
    try stdout.writeAll("  \"graph\": ");
    try writeJsonString(stdout, graph_name);
    try stdout.writeAll(",\n  \"node_id\": ");
    try writeJsonString(stdout, node_id);
    try stdout.writeAll(",\n  \"direction\": ");
    try writeJsonString(stdout, graphDirectionText(direction));
    try stdout.print(",\n  \"limit\": {d},\n  \"truncated\": {},\n", .{ limit, truncated });
    try stdout.writeAll("  \"neighbors\": ");
    try writeGraphNeighborsArrayJson(stdout, items);
    try stdout.writeAll("\n}\n");
}

pub fn writeGraphWalkText(
    stdout: *std.Io.Writer,
    path: []const u8,
    graph_name: []const u8,
    node_id: []const u8,
    limit: usize,
    max_depth: u32,
    items: []const zova.GraphWalkItem,
    truncated: bool,
) !void {
    try stdout.print(
        \\Zova graph walk: {s}
        \\graph: {s}
        \\start_node_id: {s}
        \\max_depth: {d}
        \\limit: {d}
        \\truncated: {}
        \\
    , .{ path, graph_name, node_id, max_depth, limit, truncated });
    if (items.len == 0) {
        try stdout.writeAll("nodes: none\n");
        return;
    }
    try stdout.writeAll("nodes:\n");
    for (items) |item| {
        try stdout.print("  {s} kind={s} depth={d}", .{ item.node_id, item.kind, item.depth });
        if (item.predecessor_node_id) |value| try stdout.print(" predecessor={s}", .{value});
        if (item.edge_type) |value| try stdout.print(" edge_type={s}", .{value});
        try stdout.writeByte('\n');
    }
}

pub fn writeGraphWalkJson(
    stdout: *std.Io.Writer,
    graph_name: []const u8,
    node_id: []const u8,
    limit: usize,
    max_depth: u32,
    items: []const zova.GraphWalkItem,
    truncated: bool,
) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"graph-walk\",\n");
    try stdout.writeAll("  \"graph\": ");
    try writeJsonString(stdout, graph_name);
    try stdout.writeAll(",\n  \"start_node_id\": ");
    try writeJsonString(stdout, node_id);
    try stdout.print(",\n  \"max_depth\": {d},\n  \"limit\": {d},\n  \"truncated\": {},\n", .{ max_depth, limit, truncated });
    try stdout.writeAll("  \"nodes\": ");
    try writeGraphWalkArrayJson(stdout, items);
    try stdout.writeAll("\n}\n");
}

pub fn writeTablesText(stdout: *std.Io.Writer, path: []const u8, limit: usize, list: TableList) !void {
    try stdout.print(
        \\Zova tables: {s}
        \\limit: {d}
        \\user_table_count: {d}
        \\private_table_count: {d}
        \\user_tables_truncated: {}
        \\private_tables_truncated: {}
        \\user_tables:
        \\
    , .{
        path,
        limit,
        list.user_count,
        list.private_count,
        list.user_tables_truncated,
        list.private_tables_truncated,
    });
    if (list.user_tables.len == 0) {
        try stdout.writeAll("  none\n");
    } else {
        for (list.user_tables) |name| try stdout.print("  {s}\n", .{name});
    }
    try stdout.writeAll("private_tables:\n");
    if (list.private_tables.len == 0) {
        try stdout.writeAll("  none\n");
    } else {
        for (list.private_tables) |name| try stdout.print("  {s}\n", .{name});
    }
}

pub fn writeTablesJson(stdout: *std.Io.Writer, limit: usize, list: TableList) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"tables\",\n");
    try stdout.print(
        \\  "limit": {d},
        \\  "user_table_count": {d},
        \\  "private_table_count": {d},
        \\  "user_tables_truncated": {},
        \\  "private_tables_truncated": {},
        \\  "user_tables":
    , .{
        limit,
        list.user_count,
        list.private_count,
        list.user_tables_truncated,
        list.private_tables_truncated,
    });
    try stdout.writeByte(' ');
    try writeStringArrayJson(stdout, list.user_tables);
    try stdout.writeAll(",\n  \"private_tables\": ");
    try writeStringArrayJson(stdout, list.private_tables);
    try stdout.writeAll("\n}\n");
}

fn writeObjectRowsJson(stdout: *std.Io.Writer, items: []const TopObjectStats) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.writeAll("{\"object_id\": ");
        try writeJsonString(stdout, item.id_hex);
        try stdout.print(", \"size_bytes\": {d}, \"chunk_count\": {d}, \"chunker\": ", .{ item.size_bytes, item.chunk_count });
        try writeJsonString(stdout, item.chunker);
        try stdout.writeAll("}");
    }
    try stdout.writeAll("]");
}

fn writeManifestRowsJson(stdout: *std.Io.Writer, items: []const ManifestRow) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.print("{{\"chunk_index\": {d}, \"chunk_hash\": ", .{item.index});
        try writeJsonString(stdout, item.chunk_hash_hex);
        try stdout.print(", \"offset\": {d}, \"size_bytes\": {d}}}", .{ item.offset, item.size_bytes });
    }
    try stdout.writeAll("]");
}

fn writeChunkRowsJson(stdout: *std.Io.Writer, items: []const TopChunkStats) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.writeAll("{\"chunk_hash\": ");
        try writeJsonString(stdout, item.id_hex);
        try stdout.print(", \"size_bytes\": {d}, \"reference_count\": {d}, \"loose\": {}}}", .{
            item.size_bytes,
            item.reference_count,
            item.loose,
        });
    }
    try stdout.writeAll("]");
}

fn writeChunkReferencesJson(stdout: *std.Io.Writer, items: []const ChunkReference) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.writeAll("{\"object_id\": ");
        try writeJsonString(stdout, item.object_id_hex);
        try stdout.print(", \"chunk_index\": {d}, \"offset\": {d}, \"size_bytes\": {d}}}", .{
            item.chunk_index,
            item.offset,
            item.size_bytes,
        });
    }
    try stdout.writeAll("]");
}

fn writeVectorCollectionStatsJson(stdout: *std.Io.Writer, items: []const VectorCollectionStats) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.writeAll("{\"name\": ");
        try writeJsonString(stdout, item.name);
        try stdout.writeAll(", \"dimensions\": ");
        try stdout.print("{d}", .{item.dimensions});
        try stdout.writeAll(", \"metric\": ");
        try writeJsonString(stdout, item.metric);
        try stdout.print(", \"vector_count\": {d}, \"stored_bytes\": {d}}}", .{ item.vector_count, item.stored_bytes });
    }
    try stdout.writeAll("]");
}

fn writeGraphInfoArrayJson(stdout: *std.Io.Writer, items: []const zova.GraphInfo) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.writeAll("{\"name\": ");
        try writeJsonString(stdout, item.name);
        try stdout.print(", \"node_count\": {d}, \"edge_count\": {d}}}", .{ item.node_count, item.edge_count });
    }
    try stdout.writeAll("]");
}

fn writeGraphNeighborsArrayJson(stdout: *std.Io.Writer, items: []const zova.GraphNeighbor) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.writeAll("{\"node_id\": ");
        try writeJsonString(stdout, item.node_id);
        try stdout.writeAll(", \"kind\": ");
        try writeJsonString(stdout, item.kind);
        try stdout.writeAll(", \"edge_type\": ");
        try writeJsonString(stdout, item.edge_type);
        try stdout.writeAll("}");
    }
    try stdout.writeAll("]");
}

fn writeGraphWalkArrayJson(stdout: *std.Io.Writer, items: []const zova.GraphWalkItem) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.writeAll("{\"node_id\": ");
        try writeJsonString(stdout, item.node_id);
        try stdout.writeAll(", \"kind\": ");
        try writeJsonString(stdout, item.kind);
        try stdout.print(", \"depth\": {d}, \"predecessor_node_id\": ", .{item.depth});
        try writeNullableJsonString(stdout, item.predecessor_node_id);
        try stdout.writeAll(", \"edge_type\": ");
        try writeNullableJsonString(stdout, item.edge_type);
        try stdout.writeAll("}");
    }
    try stdout.writeAll("]");
}

fn writeTopObjectStatsJson(stdout: *std.Io.Writer, items: []const TopObjectStats) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.writeAll("{\"object_id\": ");
        try writeJsonString(stdout, item.id_hex);
        try stdout.print(", \"size_bytes\": {d}, \"chunk_count\": {d}, \"chunker\": ", .{ item.size_bytes, item.chunk_count });
        try writeJsonString(stdout, item.chunker);
        try stdout.writeAll("}");
    }
    try stdout.writeAll("]");
}

fn writeTopChunkStatsJson(stdout: *std.Io.Writer, items: []const TopChunkStats) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try stdout.writeAll("{\"chunk_hash\": ");
        try writeJsonString(stdout, item.id_hex);
        try stdout.print(", \"size_bytes\": {d}, \"reference_count\": {d}, \"loose\": {}}}", .{
            item.size_bytes,
            item.reference_count,
            item.loose,
        });
    }
    try stdout.writeAll("]");
}
