//! Read-only inspection commands and their data loading.

const std = @import("std");
const zova = @import("zova");

const ChunkDetail = @import("types.zig").ChunkDetail;
const ChunkList = @import("types.zig").ChunkList;
const ChunkReference = @import("types.zig").ChunkReference;
const CommandContext = @import("types.zig").CommandContext;
const DatabaseSummary = @import("types.zig").DatabaseSummary;
const ExitCode = @import("common.zig").ExitCode;
const ManifestRow = @import("types.zig").ManifestRow;
const NumericStats = @import("types.zig").NumericStats;
const ObjectDetail = @import("types.zig").ObjectDetail;
const ObjectList = @import("types.zig").ObjectList;
const OutputFormat = @import("types.zig").OutputFormat;
const StatsSummary = @import("types.zig").StatsSummary;
const TableList = @import("types.zig").TableList;
const TopChunkStats = @import("types.zig").TopChunkStats;
const TopObjectStats = @import("types.zig").TopObjectStats;
const VectorCollectionDetail = @import("types.zig").VectorCollectionDetail;
const VectorCollectionListSummary = @import("types.zig").VectorCollectionListSummary;
const VectorCollectionStats = @import("types.zig").VectorCollectionStats;
const boundedCommandErrorFormat = @import("parse.zig").boundedCommandErrorFormat;
const boundedCommandUsageMessage = @import("parse.zig").boundedCommandUsageMessage;
const default_list_limit = @import("common.zig").default_list_limit;
const fileSize = @import("common.zig").fileSize;
const fileSizeWithSuffix = @import("common.zig").fileSizeWithSuffix;
const graphCommandErrorFormat = @import("parse.zig").graphCommandErrorFormat;
const graphCommandUsageMessage = @import("parse.zig").graphCommandUsageMessage;
const graphInspectErrorFormat = @import("render.zig").graphInspectErrorFormat;
const inspectErrorFormat = @import("render.zig").inspectErrorFormat;
const isValidCliVectorName = @import("common.zig").isValidCliVectorName;
const lowerHexAlloc = @import("common.zig").lowerHexAlloc;
const max_list_limit = @import("common.zig").max_list_limit;
const openDatabase = @import("common.zig").openDatabase;
const openErrorFormat = @import("render.zig").openErrorFormat;
const parseBoundedCommandArgs = @import("parse.zig").parseBoundedCommandArgs;
const parseGraphNeighborsCommandArgs = @import("parse.zig").parseGraphNeighborsCommandArgs;
const parseGraphNodeCommandArgs = @import("parse.zig").parseGraphNodeCommandArgs;
const parseGraphWalkCommandArgs = @import("parse.zig").parseGraphWalkCommandArgs;
const parseHex32 = @import("parse.zig").parseHex32;
const parseLimit = @import("parse.zig").parseLimit;
const scalarTextAlloc = @import("common.zig").scalarTextAlloc;
const scalarU64 = @import("common.zig").scalarU64;
const usageErrorFormat = @import("render.zig").usageErrorFormat;
const vectorInspectErrorFormat = @import("render.zig").vectorInspectErrorFormat;
const writeChunkJson = @import("inspect_render.zig").writeChunkJson;
const writeChunkText = @import("inspect_render.zig").writeChunkText;
const writeChunksJson = @import("inspect_render.zig").writeChunksJson;
const writeChunksText = @import("inspect_render.zig").writeChunksText;
const writeGraphJson = @import("inspect_render.zig").writeGraphJson;
const writeGraphNeighborsJson = @import("inspect_render.zig").writeGraphNeighborsJson;
const writeGraphNeighborsText = @import("inspect_render.zig").writeGraphNeighborsText;
const writeGraphNodeJson = @import("inspect_render.zig").writeGraphNodeJson;
const writeGraphNodeText = @import("inspect_render.zig").writeGraphNodeText;
const writeGraphText = @import("inspect_render.zig").writeGraphText;
const writeGraphWalkJson = @import("inspect_render.zig").writeGraphWalkJson;
const writeGraphWalkText = @import("inspect_render.zig").writeGraphWalkText;
const writeGraphsJson = @import("inspect_render.zig").writeGraphsJson;
const writeGraphsText = @import("inspect_render.zig").writeGraphsText;
const writeInfoJson = @import("inspect_render.zig").writeInfoJson;
const writeInfoText = @import("inspect_render.zig").writeInfoText;
const writeObjectJson = @import("inspect_render.zig").writeObjectJson;
const writeObjectText = @import("inspect_render.zig").writeObjectText;
const writeObjectsJson = @import("inspect_render.zig").writeObjectsJson;
const writeObjectsText = @import("inspect_render.zig").writeObjectsText;
const writeStatsJson = @import("inspect_render.zig").writeStatsJson;
const writeStatsText = @import("inspect_render.zig").writeStatsText;
const writeTablesJson = @import("inspect_render.zig").writeTablesJson;
const writeTablesText = @import("inspect_render.zig").writeTablesText;
const writeVectorCollectionJson = @import("inspect_render.zig").writeVectorCollectionJson;
const writeVectorCollectionText = @import("inspect_render.zig").writeVectorCollectionText;
const writeVectorsJson = @import("inspect_render.zig").writeVectorsJson;
const writeVectorsText = @import("inspect_render.zig").writeVectorsText;

pub fn infoCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var format: OutputFormat = .text;
    var path_arg: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return usageErrorFormat(stderr, "info", format, "duplicate --json");
            format = .json;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErrorFormat(stderr, "info", format, "unknown flag");
        } else if (path_arg == null) {
            path_arg = arg;
        } else {
            return usageErrorFormat(stderr, "info", format, "info accepts only [--json] <file.zova>");
        }
    }

    const raw_path = path_arg orelse return usageErrorFormat(stderr, "info", format, "info requires <file.zova>");
    const path = try allocator.dupeZ(u8, raw_path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "info", format, err);
    defer db.deinit();

    var summary = try loadDatabaseSummary(allocator, &db, path);
    defer summary.deinit(allocator);

    switch (format) {
        .text => try writeInfoText(stdout, raw_path, summary),
        .json => try writeInfoJson(stdout, summary),
    }
    return ExitCode.ok;
}

pub fn statsCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var format: OutputFormat = .text;
    var limit: usize = default_list_limit;
    var saw_limit = false;
    var path_arg: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return usageErrorFormat(stderr, "stats", format, "duplicate --json");
            format = .json;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            if (saw_limit) return usageErrorFormat(stderr, "stats", format, "duplicate --limit");
            saw_limit = true;
            index += 1;
            if (index >= args.len) return usageErrorFormat(stderr, "stats", format, "--limit requires a value");
            limit = parseLimit(args[index], max_list_limit) catch return usageErrorFormat(stderr, "stats", format, "invalid --limit");
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErrorFormat(stderr, "stats", format, "unknown flag");
        } else if (path_arg == null) {
            path_arg = arg;
        } else {
            return usageErrorFormat(stderr, "stats", format, "stats accepts only [--json] [--limit <n>] <file.zova>");
        }
    }

    const raw_path = path_arg orelse return usageErrorFormat(stderr, "stats", format, "stats requires <file.zova>");
    const path = try allocator.dupeZ(u8, raw_path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "stats", format, err);
    defer db.deinit();

    var summary = try loadStatsSummary(allocator, &db, path, limit);
    defer summary.deinit(allocator);

    switch (format) {
        .text => try writeStatsText(stdout, raw_path, limit, summary),
        .json => try writeStatsJson(stdout, limit, summary),
    }
    return ExitCode.ok;
}

pub fn objectsCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "objects", boundedCommandErrorFormat(args), boundedCommandUsageMessage("objects", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "objects", parsed.format, err);
    defer db.deinit();

    var list = try loadObjectList(allocator, &db, parsed.limit);
    defer list.deinit(allocator);

    switch (parsed.format) {
        .text => try writeObjectsText(stdout, parsed.path, parsed.limit, list),
        .json => try writeObjectsJson(stdout, parsed.limit, list),
    }
    return ExitCode.ok;
}

pub fn objectCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, true) catch |err| return usageErrorFormat(stderr, "object", boundedCommandErrorFormat(args), boundedCommandUsageMessage("object", err));
    const id_text = parsed.id orelse return usageErrorFormat(stderr, "object", parsed.format, "object requires <file.zova> <object-id>");
    const id = parseHex32(id_text) catch return usageErrorFormat(stderr, "object", parsed.format, "object id must be 64 hex characters");
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "object", parsed.format, err);
    defer db.deinit();

    var detail = loadObjectDetail(allocator, &db, id, parsed.limit) catch |err| return inspectErrorFormat(stderr, "object", parsed.format, err);
    defer detail.deinit(allocator);

    switch (parsed.format) {
        .text => try writeObjectText(stdout, parsed.path, parsed.limit, detail),
        .json => try writeObjectJson(stdout, parsed.limit, detail),
    }
    return ExitCode.ok;
}

pub fn chunksCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "chunks", boundedCommandErrorFormat(args), boundedCommandUsageMessage("chunks", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "chunks", parsed.format, err);
    defer db.deinit();

    var list = try loadChunkList(allocator, &db, parsed.limit);
    defer list.deinit(allocator);

    switch (parsed.format) {
        .text => try writeChunksText(stdout, parsed.path, parsed.limit, list),
        .json => try writeChunksJson(stdout, parsed.limit, list),
    }
    return ExitCode.ok;
}

pub fn chunkCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, true) catch |err| return usageErrorFormat(stderr, "chunk", boundedCommandErrorFormat(args), boundedCommandUsageMessage("chunk", err));
    const id_text = parsed.id orelse return usageErrorFormat(stderr, "chunk", parsed.format, "chunk requires <file.zova> <chunk-id>");
    const id = parseHex32(id_text) catch return usageErrorFormat(stderr, "chunk", parsed.format, "chunk id must be 64 hex characters");
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "chunk", parsed.format, err);
    defer db.deinit();

    var detail = loadChunkDetail(allocator, &db, id, parsed.limit) catch |err| return inspectErrorFormat(stderr, "chunk", parsed.format, err);
    defer detail.deinit(allocator);

    switch (parsed.format) {
        .text => try writeChunkText(stdout, parsed.path, parsed.limit, detail),
        .json => try writeChunkJson(stdout, parsed.limit, detail),
    }
    return ExitCode.ok;
}

pub fn vectorsCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "vectors", boundedCommandErrorFormat(args), boundedCommandUsageMessage("vectors", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "vectors", parsed.format, err);
    defer db.deinit();

    var list = try loadVectorCollectionList(allocator, &db, parsed.limit);
    defer list.deinit(allocator);

    switch (parsed.format) {
        .text => try writeVectorsText(stdout, parsed.path, parsed.limit, list),
        .json => try writeVectorsJson(stdout, parsed.limit, list),
    }
    return ExitCode.ok;
}

pub fn vectorCollectionCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, true) catch |err| return usageErrorFormat(stderr, "vector-collection", boundedCommandErrorFormat(args), boundedCommandUsageMessage("vector-collection", err));
    const name = parsed.id orelse return usageErrorFormat(stderr, "vector-collection", parsed.format, "vector-collection requires <file.zova> <name>");
    if (!isValidCliVectorName(name)) {
        return usageErrorFormat(stderr, "vector-collection", parsed.format, "vector collection name is invalid");
    }

    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "vector-collection", parsed.format, err);
    defer db.deinit();

    var detail = loadVectorCollectionDetail(allocator, &db, name, parsed.limit) catch |err| return vectorInspectErrorFormat(stderr, "vector-collection", parsed.format, err);
    defer detail.deinit(allocator);

    switch (parsed.format) {
        .text => try writeVectorCollectionText(stdout, parsed.path, parsed.limit, detail),
        .json => try writeVectorCollectionJson(stdout, parsed.limit, detail),
    }
    return ExitCode.ok;
}

pub fn graphsCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "graphs", boundedCommandErrorFormat(args), boundedCommandUsageMessage("graphs", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "graphs", parsed.format, err);
    defer db.deinit();

    var list = try db.listGraphs(allocator);
    defer list.deinit(allocator);
    const visible_len = @min(parsed.limit, list.items.len);
    const visible = list.items[0..visible_len];
    const truncated = list.items.len > parsed.limit;

    switch (parsed.format) {
        .text => try writeGraphsText(stdout, parsed.path, parsed.limit, visible, truncated),
        .json => try writeGraphsJson(stdout, parsed.limit, visible, truncated),
    }
    return ExitCode.ok;
}

pub fn graphCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, true) catch |err| return usageErrorFormat(stderr, "graph", boundedCommandErrorFormat(args), boundedCommandUsageMessage("graph", err));
    const graph_name = parsed.id orelse return usageErrorFormat(stderr, "graph", parsed.format, "graph requires <file.zova> <graph>");
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "graph", parsed.format, err);
    defer db.deinit();

    var info = db.graphInfo(allocator, graph_name) catch |err| return graphInspectErrorFormat(stderr, "graph", parsed.format, err);
    defer info.deinit(allocator);

    switch (parsed.format) {
        .text => try writeGraphText(stdout, parsed.path, info),
        .json => try writeGraphJson(stdout, info),
    }
    return ExitCode.ok;
}

pub fn graphNodeCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseGraphNodeCommandArgs(args) catch |err| return usageErrorFormat(stderr, "graph-node", graphCommandErrorFormat(args), graphCommandUsageMessage("graph-node", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "graph-node", parsed.format, err);
    defer db.deinit();

    var node = db.getGraphNode(allocator, parsed.graph_name, parsed.node_id) catch |err| return graphInspectErrorFormat(stderr, "graph-node", parsed.format, err);
    defer node.deinit(allocator);

    switch (parsed.format) {
        .text => try writeGraphNodeText(stdout, parsed.path, node),
        .json => try writeGraphNodeJson(stdout, node),
    }
    return ExitCode.ok;
}

pub fn graphNeighborsCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseGraphNeighborsCommandArgs(args) catch |err| return usageErrorFormat(stderr, "graph-neighbors", graphCommandErrorFormat(args), graphCommandUsageMessage("graph-neighbors", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "graph-neighbors", parsed.format, err);
    defer db.deinit();

    const requested_limit = if (parsed.limit == std.math.maxInt(usize)) parsed.limit else parsed.limit + 1;
    var neighbors = db.graphNeighbors(allocator, .{
        .graph_name = parsed.graph_name,
        .node_id = parsed.node_id,
        .direction = if (parsed.incoming) .incoming else .outgoing,
        .edge_type = parsed.edge_type,
        .limit = requested_limit,
    }) catch |err| return graphInspectErrorFormat(stderr, "graph-neighbors", parsed.format, err);
    defer neighbors.deinit(allocator);

    const visible_len = @min(parsed.limit, neighbors.items.len);
    const visible = neighbors.items[0..visible_len];
    const truncated = neighbors.items.len > parsed.limit;

    switch (parsed.format) {
        .text => try writeGraphNeighborsText(stdout, parsed.path, parsed.graph_name, parsed.node_id, parsed.limit, if (parsed.incoming) .incoming else .outgoing, visible, truncated),
        .json => try writeGraphNeighborsJson(stdout, parsed.graph_name, parsed.node_id, parsed.limit, if (parsed.incoming) .incoming else .outgoing, visible, truncated),
    }
    return ExitCode.ok;
}

pub fn graphWalkCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseGraphWalkCommandArgs(args) catch |err| return usageErrorFormat(stderr, "graph-walk", graphCommandErrorFormat(args), graphCommandUsageMessage("graph-walk", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "graph-walk", parsed.format, err);
    defer db.deinit();

    const requested_limit = if (parsed.limit == std.math.maxInt(usize)) parsed.limit else parsed.limit + 1;
    var walk = db.graphWalk(allocator, .{
        .graph_name = parsed.graph_name,
        .start_node_id = parsed.node_id,
        .edge_type = parsed.edge_type,
        .max_depth = parsed.max_depth,
        .limit = requested_limit,
    }) catch |err| return graphInspectErrorFormat(stderr, "graph-walk", parsed.format, err);
    defer walk.deinit(allocator);

    const visible_len = @min(parsed.limit, walk.items.len);
    const visible = walk.items[0..visible_len];
    const truncated = walk.items.len > parsed.limit;

    switch (parsed.format) {
        .text => try writeGraphWalkText(stdout, parsed.path, parsed.graph_name, parsed.node_id, parsed.limit, parsed.max_depth, visible, truncated),
        .json => try writeGraphWalkJson(stdout, parsed.graph_name, parsed.node_id, parsed.limit, parsed.max_depth, visible, truncated),
    }
    return ExitCode.ok;
}

pub fn tablesCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "tables", boundedCommandErrorFormat(args), boundedCommandUsageMessage("tables", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = openDatabase(ctx, path) catch |err| return openErrorFormat(stderr, "tables", parsed.format, err);
    defer db.deinit();

    var list = try loadTableList(allocator, &db, parsed.limit);
    defer list.deinit(allocator);

    switch (parsed.format) {
        .text => try writeTablesText(stdout, parsed.path, parsed.limit, list),
        .json => try writeTablesJson(stdout, parsed.limit, list),
    }
    return ExitCode.ok;
}

pub fn loadDatabaseSummary(allocator: std.mem.Allocator, db: *zova.Database, path: [:0]const u8) !DatabaseSummary {
    return .{
        .format_version = try scalarTextAlloc(allocator, db, "select value from _zova_meta where key = 'format_version'"),
        .database_bytes = fileSize(path),
        .wal_bytes = try fileSizeWithSuffix(allocator, path, "-wal"),
        .journal_bytes = try fileSizeWithSuffix(allocator, path, "-journal"),
        .page_count = try scalarU64(db, "pragma page_count"),
        .page_size = try scalarU64(db, "pragma page_size"),
        .freelist_count = try scalarU64(db, "pragma freelist_count"),
        .object_count = try scalarU64(db, "select count(*) from _zova_objects"),
        .object_logical_bytes = try scalarU64(db, "select coalesce(sum(size_bytes), 0) from _zova_objects"),
        .chunk_count = try scalarU64(db, "select count(*) from _zova_chunks"),
        .manifest_count = try scalarU64(db, "select count(*) from _zova_object_chunks"),
        .loose_chunk_count = try scalarU64(db,
            \\select count(*)
            \\from _zova_chunks c
            \\where not exists (
            \\  select 1 from _zova_object_chunks oc where oc.chunk_hash = c.chunk_hash
            \\)
        ),
        .chunk_bytes = try scalarU64(db, "select coalesce(sum(size_bytes), 0) from _zova_chunks"),
        .vector_collection_count = try scalarU64(db, "select count(*) from _zova_vector_collections"),
        .vector_count = try scalarU64(db, "select count(*) from _zova_vectors"),
        .kv_entry_count = try scalarU64(db, "select count(*) from _zova_kv"),
        .kv_key_bytes = try scalarU64(db, "select coalesce(sum(length(namespace) + length(key)), 0) from _zova_kv"),
        .kv_value_bytes = try scalarU64(db, "select coalesce(sum(length(value)), 0) from _zova_kv"),
        .kv_allocated_bytes = try scalarU64(db,
            \\select coalesce(sum(pgsize), 0)
            \\from dbstat
            \\where name = '_zova_kv'
        ),
        .user_table_count = try scalarU64(db,
            \\select count(*)
            \\from sqlite_master
            \\where type = 'table'
            \\  and substr(name, 1, 6) != '_zova_'
            \\  and substr(name, 1, 7) != 'sqlite_'
        ),
        .private_table_count = try scalarU64(db,
            \\select count(*)
            \\from sqlite_master
            \\where type = 'table'
            \\  and substr(name, 1, 6) = '_zova_'
        ),
    };
}

pub fn emptyDatabaseSummary(allocator: std.mem.Allocator) !DatabaseSummary {
    return .{
        .format_version = try allocator.dupe(u8, ""),
        .database_bytes = 0,
        .wal_bytes = 0,
        .journal_bytes = 0,
        .page_count = 0,
        .page_size = 0,
        .freelist_count = 0,
        .object_count = 0,
        .object_logical_bytes = 0,
        .chunk_count = 0,
        .manifest_count = 0,
        .loose_chunk_count = 0,
        .chunk_bytes = 0,
        .vector_collection_count = 0,
        .vector_count = 0,
        .kv_entry_count = 0,
        .kv_key_bytes = 0,
        .kv_value_bytes = 0,
        .kv_allocated_bytes = 0,
        .user_table_count = 0,
        .private_table_count = 0,
    };
}

fn loadStatsSummary(allocator: std.mem.Allocator, db: *zova.Database, path: [:0]const u8, limit: usize) !StatsSummary {
    const database = try loadDatabaseSummary(allocator, db, path);
    errdefer {
        var cleanup = database;
        cleanup.deinit(allocator);
    }

    const object_sizes = try numericStats(db, "select coalesce(min(size_bytes), 0), coalesce(max(size_bytes), 0), coalesce(avg(size_bytes), 0) from _zova_objects");
    const object_chunks = try numericStats(db, "select coalesce(min(chunk_count), 0), coalesce(max(chunk_count), 0), coalesce(avg(chunk_count), 0) from _zova_objects");
    const chunk_sizes = try numericStats(db, "select coalesce(min(size_bytes), 0), coalesce(max(size_bytes), 0), coalesce(avg(size_bytes), 0) from _zova_chunks");
    const loose_chunk_bytes = try scalarU64(db,
        \\select coalesce(sum(c.size_bytes), 0)
        \\from _zova_chunks c
        \\where not exists (
        \\  select 1 from _zova_object_chunks oc where oc.chunk_hash = c.chunk_hash
        \\)
    );
    const manifest_bytes = try scalarU64(db, "select coalesce(sum(size_bytes), 0) from _zova_object_chunks");
    const deduped_bytes_saved = if (manifest_bytes > database.chunk_bytes) manifest_bytes - database.chunk_bytes else 0;

    const vector_collections = try loadVectorCollectionStats(allocator, db);
    errdefer {
        for (vector_collections) |*item| item.deinit(allocator);
        allocator.free(vector_collections);
    }

    const top_objects = try loadTopObjectStats(allocator, db, limit);
    errdefer {
        for (top_objects) |*item| item.deinit(allocator);
        allocator.free(top_objects);
    }

    const top_chunks = try loadTopChunkStats(allocator, db, limit);
    errdefer {
        for (top_chunks) |*item| item.deinit(allocator);
        allocator.free(top_chunks);
    }

    return .{
        .database = database,
        .object_size_min = object_sizes.min,
        .object_size_max = object_sizes.max,
        .object_size_avg = object_sizes.avg,
        .object_chunk_count_min = object_chunks.min,
        .object_chunk_count_max = object_chunks.max,
        .object_chunk_count_avg = object_chunks.avg,
        .chunk_size_min = chunk_sizes.min,
        .chunk_size_max = chunk_sizes.max,
        .chunk_size_avg = chunk_sizes.avg,
        .loose_chunk_bytes = loose_chunk_bytes,
        .deduped_bytes_saved = deduped_bytes_saved,
        .vector_collections = vector_collections,
        .top_objects = top_objects,
        .top_objects_truncated = database.object_count > limit,
        .top_chunks = top_chunks,
        .top_chunks_truncated = database.chunk_count > limit,
    };
}

fn loadObjectList(allocator: std.mem.Allocator, db: *zova.Database, limit: usize) !ObjectList {
    var stmt = try db.prepare(
        \\select object_id, size_bytes, chunk_count, chunker
        \\from _zova_objects
        \\order by hex(object_id) asc
        \\limit ?
    );
    defer stmt.deinit();
    try stmt.bindInt64(1, @intCast(limit));

    var items: std.ArrayList(TopObjectStats) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while ((try stmt.step()) == .row) {
        try items.append(allocator, .{
            .id_hex = try lowerHexAlloc(allocator, stmt.columnBlob(0)),
            .size_bytes = @intCast(stmt.columnInt64(1)),
            .chunk_count = @intCast(stmt.columnInt64(2)),
            .chunker = try allocator.dupe(u8, stmt.columnText(3)),
        });
    }

    return .{
        .items = try items.toOwnedSlice(allocator),
        .truncated = try scalarU64(db, "select count(*) from _zova_objects") > limit,
    };
}

fn loadObjectDetail(allocator: std.mem.Allocator, db: *zova.Database, id: zova.ObjectId, limit: usize) !ObjectDetail {
    var metadata = try db.prepare("select object_id, size_bytes, chunk_count, chunker from _zova_objects where object_id = ?");
    defer metadata.deinit();
    try metadata.bindBlob(1, &id);

    const step = try metadata.step();
    if (step == .done) return error.ObjectNotFound;

    const id_hex = try lowerHexAlloc(allocator, metadata.columnBlob(0));
    errdefer allocator.free(id_hex);
    const size_bytes: u64 = @intCast(metadata.columnInt64(1));
    const chunk_count: u64 = @intCast(metadata.columnInt64(2));
    const chunker = try allocator.dupe(u8, metadata.columnText(3));
    errdefer allocator.free(chunker);

    var rows: std.ArrayList(ManifestRow) = .empty;
    errdefer {
        for (rows.items) |*item| item.deinit(allocator);
        rows.deinit(allocator);
    }

    var manifest = try db.prepare(
        \\select chunk_index, chunk_hash, offset, size_bytes
        \\from _zova_object_chunks
        \\where object_id = ?
        \\order by chunk_index asc
        \\limit ?
    );
    defer manifest.deinit();
    try manifest.bindBlob(1, &id);
    try manifest.bindInt64(2, @intCast(limit));

    while ((try manifest.step()) == .row) {
        const raw_hash = manifest.columnBlob(1);
        if (raw_hash.len != @sizeOf(zova.ObjectChunkId)) return error.ObjectCorrupt;

        try rows.append(allocator, .{
            .index = @intCast(manifest.columnInt64(0)),
            .chunk_hash_hex = try lowerHexAlloc(allocator, raw_hash),
            .offset = @intCast(manifest.columnInt64(2)),
            .size_bytes = @intCast(manifest.columnInt64(3)),
        });
    }

    return .{
        .id_hex = id_hex,
        .size_bytes = size_bytes,
        .chunk_count = chunk_count,
        .chunker = chunker,
        .manifest = try rows.toOwnedSlice(allocator),
        .manifest_truncated = chunk_count > limit,
    };
}

fn loadChunkList(allocator: std.mem.Allocator, db: *zova.Database, limit: usize) !ChunkList {
    var stmt = try db.prepare(
        \\select c.chunk_hash, c.size_bytes, count(oc.chunk_hash)
        \\from _zova_chunks c
        \\left join _zova_object_chunks oc on oc.chunk_hash = c.chunk_hash
        \\group by c.chunk_hash, c.size_bytes
        \\order by hex(c.chunk_hash) asc
        \\limit ?
    );
    defer stmt.deinit();
    try stmt.bindInt64(1, @intCast(limit));

    var items: std.ArrayList(TopChunkStats) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while ((try stmt.step()) == .row) {
        const reference_count: u64 = @intCast(stmt.columnInt64(2));
        try items.append(allocator, .{
            .id_hex = try lowerHexAlloc(allocator, stmt.columnBlob(0)),
            .size_bytes = @intCast(stmt.columnInt64(1)),
            .reference_count = reference_count,
            .loose = reference_count == 0,
        });
    }

    return .{
        .items = try items.toOwnedSlice(allocator),
        .truncated = try scalarU64(db, "select count(*) from _zova_chunks") > limit,
    };
}

fn loadChunkDetail(allocator: std.mem.Allocator, db: *zova.Database, id: zova.ObjectChunkId, limit: usize) !ChunkDetail {
    var metadata = try db.prepare("select chunk_hash, size_bytes from _zova_chunks where chunk_hash = ?");
    defer metadata.deinit();
    try metadata.bindBlob(1, &id);

    const step = try metadata.step();
    if (step == .done) return error.ObjectChunkNotFound;

    const id_hex = try lowerHexAlloc(allocator, metadata.columnBlob(0));
    errdefer allocator.free(id_hex);
    const size_bytes: u64 = @intCast(metadata.columnInt64(1));
    const reference_count = try chunkReferenceCount(db, id);

    const references = try loadChunkReferences(allocator, db, id, limit);
    errdefer {
        for (references) |*item| item.deinit(allocator);
        allocator.free(references);
    }

    return .{
        .id_hex = id_hex,
        .size_bytes = size_bytes,
        .reference_count = reference_count,
        .loose = reference_count == 0,
        .references = references,
        .references_truncated = reference_count > limit,
    };
}

fn chunkReferenceCount(db: *zova.Database, id: zova.ObjectChunkId) !u64 {
    var stmt = try db.prepare("select count(*) from _zova_object_chunks where chunk_hash = ?");
    defer stmt.deinit();
    try stmt.bindBlob(1, &id);
    return switch (try stmt.step()) {
        .row => @intCast(stmt.columnInt64(0)),
        .done => 0,
    };
}

fn loadChunkReferences(allocator: std.mem.Allocator, db: *zova.Database, id: zova.ObjectChunkId, limit: usize) ![]ChunkReference {
    var stmt = try db.prepare(
        \\select object_id, chunk_index, offset, size_bytes
        \\from _zova_object_chunks
        \\where chunk_hash = ?
        \\order by hex(object_id), chunk_index
        \\limit ?
    );
    defer stmt.deinit();
    try stmt.bindBlob(1, &id);
    try stmt.bindInt64(2, @intCast(limit));

    var items: std.ArrayList(ChunkReference) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while ((try stmt.step()) == .row) {
        try items.append(allocator, .{
            .object_id_hex = try lowerHexAlloc(allocator, stmt.columnBlob(0)),
            .chunk_index = @intCast(stmt.columnInt64(1)),
            .offset = @intCast(stmt.columnInt64(2)),
            .size_bytes = @intCast(stmt.columnInt64(3)),
        });
    }

    return try items.toOwnedSlice(allocator);
}

fn loadVectorCollectionStats(allocator: std.mem.Allocator, db: *zova.Database) ![]VectorCollectionStats {
    var stmt = try db.prepare(
        \\select vc.name, vc.dimensions, vc.metric, count(v.vector_id), coalesce(sum(length(v."values")), 0)
        \\from _zova_vector_collections vc
        \\left join _zova_vectors v on v.collection_key = vc.collection_key
        \\group by vc.name, vc.dimensions, vc.metric
        \\order by vc.name
    );
    defer stmt.deinit();

    var items: std.ArrayList(VectorCollectionStats) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while ((try stmt.step()) == .row) {
        try items.append(allocator, .{
            .name = try allocator.dupe(u8, stmt.columnText(0)),
            .dimensions = @intCast(stmt.columnInt64(1)),
            .metric = try allocator.dupe(u8, stmt.columnText(2)),
            .vector_count = @intCast(stmt.columnInt64(3)),
            .stored_bytes = @intCast(stmt.columnInt64(4)),
        });
    }

    return try items.toOwnedSlice(allocator);
}

fn loadVectorCollectionList(allocator: std.mem.Allocator, db: *zova.Database, limit: usize) !VectorCollectionListSummary {
    var stmt = try db.prepare(
        \\select vc.name, vc.dimensions, vc.metric, count(v.vector_id), coalesce(sum(length(v."values")), 0)
        \\from _zova_vector_collections vc
        \\left join _zova_vectors v on v.collection_key = vc.collection_key
        \\group by vc.name, vc.dimensions, vc.metric
        \\order by vc.name
        \\limit ?
    );
    defer stmt.deinit();
    try stmt.bindInt64(1, @intCast(limit));

    var items: std.ArrayList(VectorCollectionStats) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while ((try stmt.step()) == .row) {
        try items.append(allocator, .{
            .name = try allocator.dupe(u8, stmt.columnText(0)),
            .dimensions = @intCast(stmt.columnInt64(1)),
            .metric = try allocator.dupe(u8, stmt.columnText(2)),
            .vector_count = @intCast(stmt.columnInt64(3)),
            .stored_bytes = @intCast(stmt.columnInt64(4)),
        });
    }

    return .{
        .items = try items.toOwnedSlice(allocator),
        .truncated = try scalarU64(db, "select count(*) from _zova_vector_collections") > limit,
    };
}

fn loadVectorCollectionDetail(allocator: std.mem.Allocator, db: *zova.Database, name: []const u8, limit: usize) !VectorCollectionDetail {
    var stmt = try db.prepare(
        \\select vc.name, vc.dimensions, vc.metric, count(v.vector_id), coalesce(sum(length(v."values")), 0)
        \\from _zova_vector_collections vc
        \\left join _zova_vectors v on v.collection_key = vc.collection_key
        \\where vc.name = ?
        \\group by vc.name, vc.dimensions, vc.metric
    );
    defer stmt.deinit();
    try stmt.bindText(1, name);

    const step = try stmt.step();
    if (step == .done) return error.VectorCollectionNotFound;

    const owned_name = try allocator.dupe(u8, stmt.columnText(0));
    errdefer allocator.free(owned_name);
    const metric = try allocator.dupe(u8, stmt.columnText(2));
    errdefer allocator.free(metric);
    const vector_count: u64 = @intCast(stmt.columnInt64(3));

    const ids = try loadVectorIds(allocator, db, name, limit);
    errdefer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }

    return .{
        .name = owned_name,
        .dimensions = @intCast(stmt.columnInt64(1)),
        .metric = metric,
        .vector_count = vector_count,
        .stored_bytes = @intCast(stmt.columnInt64(4)),
        .vector_ids = ids,
        .vector_ids_truncated = vector_count > limit,
    };
}

fn loadVectorIds(allocator: std.mem.Allocator, db: *zova.Database, collection_name: []const u8, limit: usize) ![][]u8 {
    var stmt = try db.prepare(
        \\select v.vector_id
        \\from _zova_vectors v
        \\join _zova_vector_collections c on c.collection_key = v.collection_key
        \\where c.name = ?
        \\order by v.vector_id asc
        \\limit ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, collection_name);
    try stmt.bindInt64(2, @intCast(limit));

    var ids: std.ArrayList([]u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }

    while ((try stmt.step()) == .row) {
        try ids.append(allocator, try allocator.dupe(u8, stmt.columnText(0)));
    }

    return try ids.toOwnedSlice(allocator);
}

fn loadTableList(allocator: std.mem.Allocator, db: *zova.Database, limit: usize) !TableList {
    const user_count = try scalarU64(db,
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table'
        \\  and substr(name, 1, 6) != '_zova_'
        \\  and substr(name, 1, 7) != 'sqlite_'
    );
    const private_count = try scalarU64(db,
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table'
        \\  and substr(name, 1, 6) = '_zova_'
    );

    const user_tables = try loadTableNames(allocator, db,
        \\select name
        \\from sqlite_master
        \\where type = 'table'
        \\  and substr(name, 1, 6) != '_zova_'
        \\  and substr(name, 1, 7) != 'sqlite_'
        \\order by name asc
        \\limit ?
    , limit);
    errdefer {
        for (user_tables) |name| allocator.free(name);
        allocator.free(user_tables);
    }

    const private_tables = try loadTableNames(allocator, db,
        \\select name
        \\from sqlite_master
        \\where type = 'table'
        \\  and substr(name, 1, 6) = '_zova_'
        \\order by name asc
        \\limit ?
    , limit);
    errdefer {
        for (private_tables) |name| allocator.free(name);
        allocator.free(private_tables);
    }

    return .{
        .user_count = user_count,
        .private_count = private_count,
        .user_tables = user_tables,
        .private_tables = private_tables,
        .user_tables_truncated = user_count > limit,
        .private_tables_truncated = private_count > limit,
    };
}

fn loadTableNames(allocator: std.mem.Allocator, db: *zova.Database, sql: [:0]const u8, limit: usize) ![][]u8 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try stmt.bindInt64(1, @intCast(limit));

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    while ((try stmt.step()) == .row) {
        try names.append(allocator, try allocator.dupe(u8, stmt.columnText(0)));
    }

    return try names.toOwnedSlice(allocator);
}

fn loadTopObjectStats(allocator: std.mem.Allocator, db: *zova.Database, limit: usize) ![]TopObjectStats {
    var stmt = try db.prepare(
        \\select object_id, size_bytes, chunk_count, chunker
        \\from _zova_objects
        \\order by size_bytes desc, hex(object_id) asc
        \\limit ?
    );
    defer stmt.deinit();
    try stmt.bindInt64(1, @intCast(limit));

    var items: std.ArrayList(TopObjectStats) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while ((try stmt.step()) == .row) {
        try items.append(allocator, .{
            .id_hex = try lowerHexAlloc(allocator, stmt.columnBlob(0)),
            .size_bytes = @intCast(stmt.columnInt64(1)),
            .chunk_count = @intCast(stmt.columnInt64(2)),
            .chunker = try allocator.dupe(u8, stmt.columnText(3)),
        });
    }

    return try items.toOwnedSlice(allocator);
}

fn loadTopChunkStats(allocator: std.mem.Allocator, db: *zova.Database, limit: usize) ![]TopChunkStats {
    var stmt = try db.prepare(
        \\select c.chunk_hash, c.size_bytes, count(oc.chunk_hash)
        \\from _zova_chunks c
        \\left join _zova_object_chunks oc on oc.chunk_hash = c.chunk_hash
        \\group by c.chunk_hash, c.size_bytes
        \\order by count(oc.chunk_hash) desc, hex(c.chunk_hash) asc
        \\limit ?
    );
    defer stmt.deinit();
    try stmt.bindInt64(1, @intCast(limit));

    var items: std.ArrayList(TopChunkStats) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while ((try stmt.step()) == .row) {
        const reference_count: u64 = @intCast(stmt.columnInt64(2));
        try items.append(allocator, .{
            .id_hex = try lowerHexAlloc(allocator, stmt.columnBlob(0)),
            .size_bytes = @intCast(stmt.columnInt64(1)),
            .reference_count = reference_count,
            .loose = reference_count == 0,
        });
    }

    return try items.toOwnedSlice(allocator);
}

fn numericStats(db: *zova.Database, sql: [:0]const u8) !NumericStats {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    return switch (try stmt.step()) {
        .row => .{
            .min = @intCast(stmt.columnInt64(0)),
            .max = @intCast(stmt.columnInt64(1)),
            .avg = stmt.columnDouble(2),
        },
        .done => .{ .min = 0, .max = 0, .avg = 0 },
    };
}
