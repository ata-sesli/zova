//! Inspection and check CLI for Zova.
//!
//! The CLI is intentionally non-mutating. It opens current-format `.zova`
//! databases, reports bounded summaries, and validates existing object/vector
//! storage. It does not repair, migrate, delete, vacuum, or dump binary content.

const std = @import("std");
const zova = @import("zova");
const cli_options = @import("cli_options");
const sqlite = zova.sqlite;

pub const package_version = cli_options.package_version;

const ExitCode = struct {
    const ok: u8 = 0;
    const unexpected: u8 = 1;
    const usage: u8 = 2;
    const open: u8 = 3;
    const check_failed: u8 = 4;
};

const cli_json_version = 1;
const default_list_limit = 10;
const max_list_limit = 100;

const OutputFormat = enum {
    text,
    json,
};

const BoundedCommandArgs = struct {
    format: OutputFormat,
    limit: usize,
    path: []const u8,
    id: ?[]const u8,
};

const BoundedCommandParseError = error{
    DuplicateJson,
    DuplicateLimit,
    MissingLimitValue,
    InvalidLimit,
    UnknownFlag,
    MissingPath,
    MissingId,
    ExtraArgs,
};

const DatabaseSummary = struct {
    format_version: []u8,
    database_bytes: u64,
    wal_bytes: u64,
    journal_bytes: u64,
    page_count: u64,
    page_size: u64,
    freelist_count: u64,
    object_count: u64,
    object_logical_bytes: u64,
    chunk_count: u64,
    manifest_count: u64,
    loose_chunk_count: u64,
    chunk_bytes: u64,
    vector_collection_count: u64,
    vector_count: u64,
    user_table_count: u64,
    private_table_count: u64,

    fn deinit(self: *DatabaseSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.format_version);
    }
};

const DeepStats = struct {
    objects: u64 = 0,
    chunks: u64 = 0,
    vectors: u64 = 0,
    loose_chunks: u64 = 0,
};

const StatsSummary = struct {
    database: DatabaseSummary,
    object_size_min: u64,
    object_size_max: u64,
    object_size_avg: f64,
    object_chunk_count_min: u64,
    object_chunk_count_max: u64,
    object_chunk_count_avg: f64,
    chunk_size_min: u64,
    chunk_size_max: u64,
    chunk_size_avg: f64,
    loose_chunk_bytes: u64,
    deduped_bytes_saved: u64,
    vector_collections: []VectorCollectionStats,
    top_objects: []TopObjectStats,
    top_objects_truncated: bool,
    top_chunks: []TopChunkStats,
    top_chunks_truncated: bool,

    fn deinit(self: *StatsSummary, allocator: std.mem.Allocator) void {
        self.database.deinit(allocator);
        for (self.vector_collections) |*item| item.deinit(allocator);
        allocator.free(self.vector_collections);
        for (self.top_objects) |*item| item.deinit(allocator);
        allocator.free(self.top_objects);
        for (self.top_chunks) |*item| item.deinit(allocator);
        allocator.free(self.top_chunks);
    }
};

const VectorCollectionStats = struct {
    name: []u8,
    dimensions: u64,
    metric: []u8,
    vector_count: u64,
    stored_bytes: u64,

    fn deinit(self: *VectorCollectionStats, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.metric);
    }
};

const TopObjectStats = struct {
    id_hex: []u8,
    size_bytes: u64,
    chunk_count: u64,
    chunker: []u8,

    fn deinit(self: *TopObjectStats, allocator: std.mem.Allocator) void {
        allocator.free(self.id_hex);
        allocator.free(self.chunker);
    }
};

const TopChunkStats = struct {
    id_hex: []u8,
    size_bytes: u64,
    reference_count: u64,
    loose: bool,

    fn deinit(self: *TopChunkStats, allocator: std.mem.Allocator) void {
        allocator.free(self.id_hex);
    }
};

const NumericStats = struct {
    min: u64,
    max: u64,
    avg: f64,
};

const ObjectList = struct {
    items: []TopObjectStats,
    truncated: bool,

    fn deinit(self: *ObjectList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

const ObjectDetail = struct {
    id_hex: []u8,
    size_bytes: u64,
    chunk_count: u64,
    chunker: []u8,
    manifest: []ManifestRow,
    manifest_truncated: bool,

    fn deinit(self: *ObjectDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.id_hex);
        allocator.free(self.chunker);
        for (self.manifest) |*item| item.deinit(allocator);
        allocator.free(self.manifest);
    }
};

const ManifestRow = struct {
    index: u64,
    chunk_hash_hex: []u8,
    offset: u64,
    size_bytes: u64,

    fn deinit(self: *ManifestRow, allocator: std.mem.Allocator) void {
        allocator.free(self.chunk_hash_hex);
    }
};

const ChunkList = struct {
    items: []TopChunkStats,
    truncated: bool,

    fn deinit(self: *ChunkList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

const ChunkDetail = struct {
    id_hex: []u8,
    size_bytes: u64,
    reference_count: u64,
    loose: bool,
    references: []ChunkReference,
    references_truncated: bool,

    fn deinit(self: *ChunkDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.id_hex);
        for (self.references) |*item| item.deinit(allocator);
        allocator.free(self.references);
    }
};

const ChunkReference = struct {
    object_id_hex: []u8,
    chunk_index: u64,
    offset: u64,
    size_bytes: u64,

    fn deinit(self: *ChunkReference, allocator: std.mem.Allocator) void {
        allocator.free(self.object_id_hex);
    }
};

const VectorCollectionListSummary = struct {
    items: []VectorCollectionStats,
    truncated: bool,

    fn deinit(self: *VectorCollectionListSummary, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

const VectorCollectionDetail = struct {
    name: []u8,
    dimensions: u64,
    metric: []u8,
    vector_count: u64,
    stored_bytes: u64,
    vector_ids: [][]u8,
    vector_ids_truncated: bool,

    fn deinit(self: *VectorCollectionDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.metric);
        for (self.vector_ids) |id| allocator.free(id);
        allocator.free(self.vector_ids);
    }
};

const TableList = struct {
    user_count: u64,
    private_count: u64,
    user_tables: [][]u8,
    private_tables: [][]u8,
    user_tables_truncated: bool,
    private_tables_truncated: bool,

    fn deinit(self: *TableList, allocator: std.mem.Allocator) void {
        for (self.user_tables) |name| allocator.free(name);
        allocator.free(self.user_tables);
        for (self.private_tables) |name| allocator.free(name);
        allocator.free(self.private_tables);
    }
};

const DeepIssueCounts = struct {
    sqlite: u64 = 0,
    object: u64 = 0,
    chunk: u64 = 0,
    vector: u64 = 0,
};

const DeepIssueArea = enum {
    sqlite,
    object,
    chunk,
    vector,
};

const DeepIssue = struct {
    area: DeepIssueArea,
    kind: []const u8,
    severity: []const u8 = "error",
    detail: []const u8,
    object_id_hex: ?[]u8 = null,
    chunk_hash_hex: ?[]u8 = null,
    collection_name: ?[]u8 = null,
    vector_id: ?[]u8 = null,

    fn deinit(self: *DeepIssue, allocator: std.mem.Allocator) void {
        if (self.object_id_hex) |value| allocator.free(value);
        if (self.chunk_hash_hex) |value| allocator.free(value);
        if (self.collection_name) |value| allocator.free(value);
        if (self.vector_id) |value| allocator.free(value);
    }
};

const DeepReport = struct {
    stats: DeepStats = .{},
    issue_count: u64 = 0,
    issue_counts: DeepIssueCounts = .{},
    issues: []DeepIssue = &.{},
    issues_truncated: bool = false,

    fn deinit(self: *DeepReport, allocator: std.mem.Allocator) void {
        for (self.issues) |*issue| issue.deinit(allocator);
        allocator.free(self.issues);
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len <= 1) {
        try writeUsage(stderr);
        return ExitCode.usage;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--version")) {
        if (args.len != 2) return usageError(stderr, "unexpected argument after --version");
        try stdout.print("zova {s}\n", .{package_version});
        return ExitCode.ok;
    }
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        if (args.len != 2) return usageError(stderr, "unexpected argument after help");
        try writeUsage(stdout);
        return ExitCode.ok;
    }
    if (std.mem.eql(u8, command, "info")) {
        return infoCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "stats")) {
        return statsCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "objects")) {
        return objectsCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "object")) {
        return objectCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "chunks")) {
        return chunksCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "chunk")) {
        return chunkCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "vectors")) {
        return vectorsCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "vector-collection")) {
        return vectorCollectionCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "tables")) {
        return tablesCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "check")) {
        return checkCommand(allocator, args[2..], stdout, stderr);
    }

    try stderr.print("unknown command: {s}\n\n", .{command});
    try writeUsage(stderr);
    return ExitCode.usage;
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage:
        \\  zova --version
        \\  zova --help
        \\  zova info <file.zova>
        \\  zova info --json <file.zova>
        \\  zova stats [--json] [--limit <n>] <file.zova>
        \\  zova objects [--json] [--limit <n>] <file.zova>
        \\  zova object [--json] [--limit <n>] <file.zova> <object-id>
        \\  zova chunks [--json] [--limit <n>] <file.zova>
        \\  zova chunk [--json] [--limit <n>] <file.zova> <chunk-id>
        \\  zova vectors [--json] [--limit <n>] <file.zova>
        \\  zova vector-collection [--json] [--limit <n>] <file.zova> <name>
        \\  zova tables [--json] [--limit <n>] <file.zova>
        \\  zova check [--deep] <file.zova>
        \\  zova check --json [--deep] <file.zova>
        \\
        \\commands:
        \\  info   print a bounded summary of a current-format Zova database
        \\  stats  print deeper bounded storage statistics
        \\  objects list bounded object metadata
        \\  object  inspect one object manifest without reading object bytes
        \\  chunks  list bounded chunk metadata
        \\  chunk   inspect one chunk reference summary without reading chunk bytes
        \\  vectors list bounded vector collection metadata without vector values
        \\  vector-collection inspect one collection and bounded vector ids
        \\  tables  list bounded user/private table names without schema or rows
        \\  check  validate Zova identity/schema and SQLite quick_check
        \\
        \\exit codes:
        \\  0 healthy/success
        \\  1 unexpected internal error
        \\  2 usage error
        \\  3 open or Zova identity error
        \\  4 integrity or corruption check failure
        \\
    );
}

fn usageError(stderr: *std.Io.Writer, message: []const u8) !u8 {
    try stderr.print("usage error: {s}\n\n", .{message});
    try writeUsage(stderr);
    return ExitCode.usage;
}

fn usageErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, message: []const u8) !u8 {
    switch (format) {
        .text => return usageError(stderr, message),
        .json => try writeJsonError(stderr, command, message),
    }
    return ExitCode.usage;
}

fn infoCommand(
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

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "info", format, err);
    defer db.deinit();

    var summary = try loadDatabaseSummary(allocator, &db, path);
    defer summary.deinit(allocator);

    switch (format) {
        .text => try writeInfoText(stdout, raw_path, summary),
        .json => try writeInfoJson(stdout, summary),
    }
    return ExitCode.ok;
}

fn statsCommand(
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

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "stats", format, err);
    defer db.deinit();

    var summary = try loadStatsSummary(allocator, &db, path, limit);
    defer summary.deinit(allocator);

    switch (format) {
        .text => try writeStatsText(stdout, raw_path, limit, summary),
        .json => try writeStatsJson(stdout, limit, summary),
    }
    return ExitCode.ok;
}

fn objectsCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "objects", boundedCommandErrorFormat(args), boundedCommandUsageMessage("objects", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "objects", parsed.format, err);
    defer db.deinit();

    var list = try loadObjectList(allocator, &db, parsed.limit);
    defer list.deinit(allocator);

    switch (parsed.format) {
        .text => try writeObjectsText(stdout, parsed.path, parsed.limit, list),
        .json => try writeObjectsJson(stdout, parsed.limit, list),
    }
    return ExitCode.ok;
}

fn objectCommand(
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

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "object", parsed.format, err);
    defer db.deinit();

    var detail = loadObjectDetail(allocator, &db, id, parsed.limit) catch |err| return inspectErrorFormat(stderr, "object", parsed.format, err);
    defer detail.deinit(allocator);

    switch (parsed.format) {
        .text => try writeObjectText(stdout, parsed.path, parsed.limit, detail),
        .json => try writeObjectJson(stdout, parsed.limit, detail),
    }
    return ExitCode.ok;
}

fn chunksCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "chunks", boundedCommandErrorFormat(args), boundedCommandUsageMessage("chunks", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "chunks", parsed.format, err);
    defer db.deinit();

    var list = try loadChunkList(allocator, &db, parsed.limit);
    defer list.deinit(allocator);

    switch (parsed.format) {
        .text => try writeChunksText(stdout, parsed.path, parsed.limit, list),
        .json => try writeChunksJson(stdout, parsed.limit, list),
    }
    return ExitCode.ok;
}

fn chunkCommand(
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

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "chunk", parsed.format, err);
    defer db.deinit();

    var detail = loadChunkDetail(allocator, &db, id, parsed.limit) catch |err| return inspectErrorFormat(stderr, "chunk", parsed.format, err);
    defer detail.deinit(allocator);

    switch (parsed.format) {
        .text => try writeChunkText(stdout, parsed.path, parsed.limit, detail),
        .json => try writeChunkJson(stdout, parsed.limit, detail),
    }
    return ExitCode.ok;
}

fn vectorsCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "vectors", boundedCommandErrorFormat(args), boundedCommandUsageMessage("vectors", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "vectors", parsed.format, err);
    defer db.deinit();

    var list = try loadVectorCollectionList(allocator, &db, parsed.limit);
    defer list.deinit(allocator);

    switch (parsed.format) {
        .text => try writeVectorsText(stdout, parsed.path, parsed.limit, list),
        .json => try writeVectorsJson(stdout, parsed.limit, list),
    }
    return ExitCode.ok;
}

fn vectorCollectionCommand(
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

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "vector-collection", parsed.format, err);
    defer db.deinit();

    var detail = loadVectorCollectionDetail(allocator, &db, name, parsed.limit) catch |err| return vectorInspectErrorFormat(stderr, "vector-collection", parsed.format, err);
    defer detail.deinit(allocator);

    switch (parsed.format) {
        .text => try writeVectorCollectionText(stdout, parsed.path, parsed.limit, detail),
        .json => try writeVectorCollectionJson(stdout, parsed.limit, detail),
    }
    return ExitCode.ok;
}

fn tablesCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "tables", boundedCommandErrorFormat(args), boundedCommandUsageMessage("tables", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "tables", parsed.format, err);
    defer db.deinit();

    var list = try loadTableList(allocator, &db, parsed.limit);
    defer list.deinit(allocator);

    switch (parsed.format) {
        .text => try writeTablesText(stdout, parsed.path, parsed.limit, list),
        .json => try writeTablesJson(stdout, parsed.limit, list),
    }
    return ExitCode.ok;
}

fn parseLimit(value: []const u8, max_limit: usize) !usize {
    if (value.len == 0) return error.InvalidLimit;
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidLimit;
    if (parsed > max_limit) return error.InvalidLimit;
    return parsed;
}

fn parseBoundedCommandArgs(args: []const []const u8, expect_id: bool) BoundedCommandParseError!BoundedCommandArgs {
    var format: OutputFormat = .text;
    var limit: usize = default_list_limit;
    var saw_limit = false;
    var positionals: [2][]const u8 = undefined;
    var positional_count: usize = 0;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            if (saw_limit) return error.DuplicateLimit;
            saw_limit = true;
            index += 1;
            if (index >= args.len) return error.MissingLimitValue;
            limit = parseLimit(args[index], max_list_limit) catch return error.InvalidLimit;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (positional_count >= positionals.len) return error.ExtraArgs;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingPath;
    if (expect_id and positional_count == 1) return error.MissingId;
    if (!expect_id and positional_count > 1) return error.ExtraArgs;
    if (expect_id and positional_count > 2) return error.ExtraArgs;

    return .{
        .format = format,
        .limit = limit,
        .path = positionals[0],
        .id = if (expect_id) positionals[1] else null,
    };
}

fn boundedCommandUsageMessage(command: []const u8, err: BoundedCommandParseError) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.DuplicateLimit => "duplicate --limit",
        error.MissingLimitValue => "--limit requires a value",
        error.InvalidLimit => "invalid --limit",
        error.UnknownFlag => "unknown flag",
        error.MissingPath => if (std.mem.eql(u8, command, "object") or std.mem.eql(u8, command, "chunk") or std.mem.eql(u8, command, "vector-collection"))
            "command requires <file.zova> <id>"
        else
            "command requires <file.zova>",
        error.MissingId => if (std.mem.eql(u8, command, "object"))
            "object requires <file.zova> <object-id>"
        else if (std.mem.eql(u8, command, "chunk"))
            "chunk requires <file.zova> <chunk-id>"
        else
            "vector-collection requires <file.zova> <name>",
        error.ExtraArgs => "too many arguments",
    };
}

fn boundedCommandErrorFormat(args: []const []const u8) OutputFormat {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return .json;
    }
    return .text;
}

fn parseHex32(value: []const u8) ![32]u8 {
    if (value.len != 64) return error.InvalidHex;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*byte, index| {
        const high = hexNibble(value[index * 2]) orelse return error.InvalidHex;
        const low = hexNibble(value[index * 2 + 1]) orelse return error.InvalidHex;
        byte.* = (high << 4) | low;
    }
    return out;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn checkCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var deep = false;
    var format: OutputFormat = .text;
    var path_arg: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--deep")) {
            if (deep) return usageErrorFormat(stderr, "check", format, "duplicate --deep");
            deep = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return usageErrorFormat(stderr, "check", format, "duplicate --json");
            format = .json;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErrorFormat(stderr, "check", format, "unknown flag");
        } else if (path_arg == null) {
            path_arg = arg;
        } else {
            return usageErrorFormat(stderr, "check", format, "check accepts only [--json] [--deep] <file.zova>");
        }
    }

    const raw_path = path_arg orelse return usageErrorFormat(stderr, "check", format, "check requires <file.zova>");
    const path = try allocator.dupeZ(u8, raw_path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "check", format, err);
    defer db.deinit();

    quickCheck(&db) catch |err| return checkErrorFormat(stderr, "check", format, "sqlite quick_check failed", err);

    if (deep) {
        var report = deepCheck(allocator, &db) catch |err| return deepCheckErrorFormat(stderr, format, err);
        defer report.deinit(allocator);
        if (report.issue_count != 0) {
            switch (format) {
                .text => try writeDeepCheckFailureText(stderr, report),
                .json => try writeDeepCheckFailureJson(stderr, report),
            }
            return ExitCode.check_failed;
        }

        switch (format) {
            .text => try writeCheckText(stdout, report),
            .json => try writeCheckJson(stdout, report),
        }
        return ExitCode.ok;
    }

    switch (format) {
        .text => try writeCheckText(stdout, null),
        .json => try writeCheckJson(stdout, null),
    }
    return ExitCode.ok;
}

fn openErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    switch (format) {
        .text => try stderr.print("{s} open failed: {s}\n", .{ command, @errorName(err) }),
        .json => try writeJsonError(stderr, command, @errorName(err)),
    }
    return ExitCode.open;
}

fn checkErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, message: []const u8, err: anyerror) !u8 {
    switch (format) {
        .text => try stderr.print("{s}: {s}\n", .{ message, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, message, @errorName(err)),
    }
    return ExitCode.check_failed;
}

fn deepCheckErrorFormat(stderr: *std.Io.Writer, format: OutputFormat, err: anyerror) !u8 {
    const label = switch (err) {
        error.ObjectCorrupt,
        error.ObjectNotFound,
        error.ObjectChunkNotFound,
        => "object corruption",
        error.VectorCorrupt,
        error.VectorCollectionNotFound,
        error.VectorNotFound,
        => "vector corruption",
        else => "deep check failed",
    };
    switch (format) {
        .text => try stderr.print("{s}: {s}\n", .{ label, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, "check", label, @errorName(err)),
    }
    return ExitCode.check_failed;
}

fn inspectErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    const label = switch (err) {
        error.ObjectNotFound,
        error.ObjectChunkNotFound,
        => "not found",
        error.ObjectCorrupt => "object corruption",
        else => "inspection failed",
    };
    switch (format) {
        .text => try stderr.print("{s}: {s}: {s}\n", .{ command, label, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, label, @errorName(err)),
    }
    return ExitCode.check_failed;
}

fn vectorInspectErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    const label = switch (err) {
        error.VectorCollectionNotFound => "not found",
        error.VectorCorrupt => "vector corruption",
        else => "inspection failed",
    };
    switch (format) {
        .text => try stderr.print("{s}: {s}: {s}\n", .{ command, label, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, label, @errorName(err)),
    }
    return ExitCode.check_failed;
}

fn isValidCliVectorName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    return !startsWithZovaPrefix(name);
}

fn startsWithZovaPrefix(name: []const u8) bool {
    const prefix = "_zova_";
    if (name.len < prefix.len) return false;
    for (prefix, 0..) |expected, index| {
        if (std.ascii.toLower(name[index]) != expected) return false;
    }
    return true;
}

fn loadDatabaseSummary(allocator: std.mem.Allocator, db: *zova.Database, path: [:0]const u8) !DatabaseSummary {
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
        \\select vc.name, vc.dimensions, vc.metric, count(v.vector_id), coalesce(sum(v.dimensions * 4), 0)
        \\from _zova_vector_collections vc
        \\left join _zova_vectors v on v.collection_name = vc.name
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
        \\select vc.name, vc.dimensions, vc.metric, count(v.vector_id), coalesce(sum(v.dimensions * 4), 0)
        \\from _zova_vector_collections vc
        \\left join _zova_vectors v on v.collection_name = vc.name
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
        \\select vc.name, vc.dimensions, vc.metric, count(v.vector_id), coalesce(sum(v.dimensions * 4), 0)
        \\from _zova_vector_collections vc
        \\left join _zova_vectors v on v.collection_name = vc.name
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
        \\select vector_id
        \\from _zova_vectors
        \\where collection_name = ?
        \\order by vector_id asc
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

fn lowerHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[@intCast(byte >> 4)];
        out[index * 2 + 1] = digits[@intCast(byte & 0x0f)];
    }
    return out;
}

fn writeInfoText(stdout: *std.Io.Writer, path: []const u8, summary: DatabaseSummary) !void {
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
        summary.user_table_count,
        summary.private_table_count,
    });
}

fn writeInfoJson(stdout: *std.Io.Writer, summary: DatabaseSummary) !void {
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
        summary.user_table_count,
        summary.private_table_count,
    });
}

fn writeStatsText(stdout: *std.Io.Writer, path: []const u8, limit: usize, summary: StatsSummary) !void {
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

fn writeStatsJson(stdout: *std.Io.Writer, limit: usize, summary: StatsSummary) !void {
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

fn writeObjectsText(stdout: *std.Io.Writer, path: []const u8, limit: usize, list: ObjectList) !void {
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

fn writeObjectsJson(stdout: *std.Io.Writer, limit: usize, list: ObjectList) !void {
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

fn writeObjectText(stdout: *std.Io.Writer, path: []const u8, limit: usize, detail: ObjectDetail) !void {
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

fn writeObjectJson(stdout: *std.Io.Writer, limit: usize, detail: ObjectDetail) !void {
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

fn writeChunksText(stdout: *std.Io.Writer, path: []const u8, limit: usize, list: ChunkList) !void {
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

fn writeChunksJson(stdout: *std.Io.Writer, limit: usize, list: ChunkList) !void {
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

fn writeChunkText(stdout: *std.Io.Writer, path: []const u8, limit: usize, detail: ChunkDetail) !void {
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

fn writeChunkJson(stdout: *std.Io.Writer, limit: usize, detail: ChunkDetail) !void {
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

fn writeVectorsText(stdout: *std.Io.Writer, path: []const u8, limit: usize, list: VectorCollectionListSummary) !void {
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

fn writeVectorsJson(stdout: *std.Io.Writer, limit: usize, list: VectorCollectionListSummary) !void {
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

fn writeVectorCollectionText(stdout: *std.Io.Writer, path: []const u8, limit: usize, detail: VectorCollectionDetail) !void {
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

fn writeVectorCollectionJson(stdout: *std.Io.Writer, limit: usize, detail: VectorCollectionDetail) !void {
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

fn writeTablesText(stdout: *std.Io.Writer, path: []const u8, limit: usize, list: TableList) !void {
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

fn writeTablesJson(stdout: *std.Io.Writer, limit: usize, list: TableList) !void {
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

fn writeStringArrayJson(stdout: *std.Io.Writer, items: []const []const u8) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try writeJsonString(stdout, item);
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

fn writeCheckText(stdout: *std.Io.Writer, report: ?DeepReport) !void {
    try stdout.print("quick_check: ok\n", .{});
    if (report) |deep_report| {
        try stdout.print(
            \\deep_check: ok
            \\objects_checked: {d}
            \\chunks_checked: {d}
            \\vectors_checked: {d}
            \\loose_chunks: {d}
            \\issue_count: {d}
            \\sqlite_issues: {d}
            \\object_issues: {d}
            \\chunk_issues: {d}
            \\vector_issues: {d}
            \\
        , .{
            deep_report.stats.objects,
            deep_report.stats.chunks,
            deep_report.stats.vectors,
            deep_report.stats.loose_chunks,
            deep_report.issue_count,
            deep_report.issue_counts.sqlite,
            deep_report.issue_counts.object,
            deep_report.issue_counts.chunk,
            deep_report.issue_counts.vector,
        });
    }
    try stdout.print("status: ok\n", .{});
}

fn writeCheckJson(stdout: *std.Io.Writer, report: ?DeepReport) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"check\",\n");
    try stdout.writeAll("  \"quick_check\": \"ok\"");
    if (report) |deep_report| {
        try stdout.print(
            \\,
            \\  "deep_check": "ok",
            \\  "checked": {{
            \\    "objects": {d},
            \\    "chunks": {d},
            \\    "vectors": {d},
            \\    "loose_chunks": {d}
            \\  }},
            \\  "issue_count": {d},
            \\  "issue_counts":
        , .{
            deep_report.stats.objects,
            deep_report.stats.chunks,
            deep_report.stats.vectors,
            deep_report.stats.loose_chunks,
            deep_report.issue_count,
        });
        try stdout.writeByte(' ');
        try writeDeepIssueCountsJson(stdout, deep_report.issue_counts);
        try stdout.writeAll(",\n  \"issues_truncated\": false,\n  \"issues\": []");
    }
    try stdout.writeAll("\n}\n");
}

fn writeDeepCheckFailureText(stderr: *std.Io.Writer, report: DeepReport) !void {
    try stderr.print(
        \\deep_check: failed
        \\issue_count: {d}
        \\sqlite_issues: {d}
        \\object_issues: {d}
        \\chunk_issues: {d}
        \\vector_issues: {d}
        \\issues_truncated: {}
        \\issues:
        \\
    , .{
        report.issue_count,
        report.issue_counts.sqlite,
        report.issue_counts.object,
        report.issue_counts.chunk,
        report.issue_counts.vector,
        report.issues_truncated,
    });
    if (report.issue_counts.object != 0 or report.issue_counts.chunk != 0) {
        try stderr.writeAll("object corruption: detected\n");
    }
    if (report.issue_counts.vector != 0) {
        try stderr.writeAll("vector corruption: detected\n");
    }
    for (report.issues) |issue| {
        try stderr.print("  area={s} kind={s} severity={s} detail={s}", .{
            deepIssueAreaText(issue.area),
            issue.kind,
            issue.severity,
            issue.detail,
        });
        if (issue.object_id_hex) |value| try stderr.print(" object_id={s}", .{value});
        if (issue.chunk_hash_hex) |value| try stderr.print(" chunk_hash={s}", .{value});
        if (issue.collection_name) |value| try stderr.print(" collection={s}", .{value});
        if (issue.vector_id) |value| try stderr.print(" vector_id={s}", .{value});
        try stderr.writeByte('\n');
    }
}

fn writeDeepCheckFailureJson(stderr: *std.Io.Writer, report: DeepReport) !void {
    try stderr.writeAll("{\n");
    try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stderr.writeAll("  \"status\": \"error\",\n");
    try stderr.writeAll("  \"command\": \"check\",\n");
    try stderr.writeAll("  \"kind\": \"deep_check\",\n");
    try stderr.writeAll("  \"error\": \"corruption detected\",\n");
    try stderr.print("  \"issue_count\": {d},\n", .{report.issue_count});
    try stderr.writeAll("  \"issue_counts\": ");
    try writeDeepIssueCountsJson(stderr, report.issue_counts);
    try stderr.print(",\n  \"issues_truncated\": {},\n", .{report.issues_truncated});
    try stderr.writeAll("  \"issues\": ");
    try writeDeepIssuesJson(stderr, report.issues);
    try stderr.writeAll("\n}\n");
}

fn writeDeepIssueCountsJson(writer: *std.Io.Writer, counts: DeepIssueCounts) !void {
    try writer.print(
        \\{{
        \\    "sqlite": {d},
        \\    "object": {d},
        \\    "chunk": {d},
        \\    "vector": {d}
        \\  }}
    , .{ counts.sqlite, counts.object, counts.chunk, counts.vector });
}

fn writeDeepIssuesJson(writer: *std.Io.Writer, issues: []const DeepIssue) !void {
    try writer.writeAll("[");
    for (issues, 0..) |issue, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll("{\"area\": ");
        try writeJsonString(writer, deepIssueAreaText(issue.area));
        try writer.writeAll(", \"kind\": ");
        try writeJsonString(writer, issue.kind);
        try writer.writeAll(", \"severity\": ");
        try writeJsonString(writer, issue.severity);
        try writer.writeAll(", \"detail\": ");
        try writeJsonString(writer, issue.detail);
        if (issue.object_id_hex) |value| {
            try writer.writeAll(", \"object_id\": ");
            try writeJsonString(writer, value);
        }
        if (issue.chunk_hash_hex) |value| {
            try writer.writeAll(", \"chunk_hash\": ");
            try writeJsonString(writer, value);
        }
        if (issue.collection_name) |value| {
            try writer.writeAll(", \"collection\": ");
            try writeJsonString(writer, value);
        }
        if (issue.vector_id) |value| {
            try writer.writeAll(", \"vector_id\": ");
            try writeJsonString(writer, value);
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn deepIssueAreaText(area: DeepIssueArea) []const u8 {
    return switch (area) {
        .sqlite => "sqlite",
        .object => "object",
        .chunk => "chunk",
        .vector => "vector",
    };
}

fn writeJsonError(stderr: *std.Io.Writer, command: []const u8, err: []const u8) !void {
    try writeJsonErrorWithKind(stderr, command, "error", err);
}

fn writeJsonErrorWithKind(stderr: *std.Io.Writer, command: []const u8, kind: []const u8, err: []const u8) !void {
    try stderr.writeAll("{\n");
    try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stderr.writeAll("  \"status\": \"error\",\n");
    try stderr.writeAll("  \"command\": ");
    try writeJsonString(stderr, command);
    try stderr.writeAll(",\n  \"kind\": ");
    try writeJsonString(stderr, kind);
    try stderr.writeAll(",\n  \"error\": ");
    try writeJsonString(stderr, err);
    try stderr.writeAll("\n}\n");
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn fileSize(path: [:0]const u8) u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return @intCast(stat.size);
}

fn fileSizeWithSuffix(allocator: std.mem.Allocator, path: [:0]const u8, suffix: []const u8) !u64 {
    const joined_raw = try std.mem.concat(allocator, u8, &.{ path, suffix });
    defer allocator.free(joined_raw);
    const joined = try allocator.dupeZ(u8, joined_raw);
    defer allocator.free(joined);
    return fileSize(joined);
}

fn quickCheck(db: *zova.Database) !void {
    var stmt = try db.prepare("pragma quick_check");
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        if (!std.mem.eql(u8, stmt.columnText(0), "ok")) return error.CheckFailed;
    }
}

fn deepCheck(allocator: std.mem.Allocator, db: *zova.Database) !DeepReport {
    var issues: std.ArrayList(DeepIssue) = .empty;
    errdefer {
        for (issues.items) |*issue| issue.deinit(allocator);
        issues.deinit(allocator);
    }

    var report = DeepReport{};
    try validateObjects(allocator, db, &report, &issues);
    try validateLooseChunks(allocator, db, &report, &issues);
    try validateVectors(allocator, db, &report, &issues);
    report.issues = try issues.toOwnedSlice(allocator);
    return report;
}

fn validateObjects(allocator: std.mem.Allocator, db: *zova.Database, report: *DeepReport, issues: *std.ArrayList(DeepIssue)) !void {
    var stmt = try db.prepare("select object_id from _zova_objects order by hex(object_id)");
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const raw_id = stmt.columnBlob(0);
        if (raw_id.len != @sizeOf(zova.ObjectId)) {
            try addDeepIssue(allocator, report, issues, .object, "object_id_shape", "ObjectCorrupt", raw_id, null, null, null);
            continue;
        }
        var id: zova.ObjectId = undefined;
        @memcpy(&id, raw_id);
        report.stats.objects += 1;

        var manifest = db.objectManifest(allocator, id) catch |err| {
            try addDeepIssue(allocator, report, issues, .object, "object_manifest", @errorName(err), id[0..], null, null, null);
            continue;
        };
        defer manifest.deinit(allocator);
        for (manifest.chunks) |chunk| {
            report.stats.chunks += 1;
            var chunk_data = db.getObjectChunk(allocator, chunk.hash) catch |err| {
                try addDeepIssue(allocator, report, issues, .chunk, "chunk_integrity", @errorName(err), id[0..], chunk.hash[0..], null, null);
                continue;
            };
            chunk_data.deinit(allocator);
        }

        var object = db.getObject(allocator, id) catch |err| {
            try addDeepIssue(allocator, report, issues, .object, "object_integrity", @errorName(err), id[0..], null, null, null);
            continue;
        };
        object.deinit(allocator);
    }
}

fn validateLooseChunks(allocator: std.mem.Allocator, db: *zova.Database, report: *DeepReport, issues: *std.ArrayList(DeepIssue)) !void {
    var stmt = try db.prepare(
        \\select c.chunk_hash
        \\from _zova_chunks c
        \\where not exists (
        \\  select 1 from _zova_object_chunks oc where oc.chunk_hash = c.chunk_hash
        \\)
        \\order by hex(c.chunk_hash)
    );
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const raw_hash = stmt.columnBlob(0);
        if (raw_hash.len != @sizeOf(zova.ObjectChunkId)) {
            try addDeepIssue(allocator, report, issues, .chunk, "loose_chunk_id_shape", "ObjectCorrupt", null, raw_hash, null, null);
            continue;
        }
        var hash: zova.ObjectChunkId = undefined;
        @memcpy(&hash, raw_hash);
        report.stats.loose_chunks += 1;

        var chunk = db.getObjectChunk(allocator, hash) catch |err| {
            try addDeepIssue(allocator, report, issues, .chunk, "loose_chunk_integrity", @errorName(err), null, hash[0..], null, null);
            continue;
        };
        chunk.deinit(allocator);
    }
}

fn validateVectors(allocator: std.mem.Allocator, db: *zova.Database, report: *DeepReport, issues: *std.ArrayList(DeepIssue)) !void {
    var stmt = try db.prepare(
        \\select collection_name, vector_id
        \\from _zova_vectors
        \\order by collection_name, vector_id
    );
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const collection_name = stmt.columnText(0);
        const vector_id = stmt.columnText(1);
        report.stats.vectors += 1;
        var vector = db.getVector(allocator, collection_name, vector_id) catch |err| {
            try addDeepIssue(allocator, report, issues, .vector, "vector_integrity", @errorName(err), null, null, collection_name, vector_id);
            continue;
        };
        vector.deinit(allocator);
    }
}

fn addDeepIssue(
    allocator: std.mem.Allocator,
    report: *DeepReport,
    issues: *std.ArrayList(DeepIssue),
    area: DeepIssueArea,
    kind: []const u8,
    detail: []const u8,
    object_id: ?[]const u8,
    chunk_hash: ?[]const u8,
    collection_name: ?[]const u8,
    vector_id: ?[]const u8,
) !void {
    report.issue_count += 1;
    switch (area) {
        .sqlite => report.issue_counts.sqlite += 1,
        .object => report.issue_counts.object += 1,
        .chunk => report.issue_counts.chunk += 1,
        .vector => report.issue_counts.vector += 1,
    }

    if (issues.items.len >= 10) {
        report.issues_truncated = true;
        return;
    }

    var issue = DeepIssue{
        .area = area,
        .kind = kind,
        .detail = detail,
    };
    errdefer issue.deinit(allocator);

    if (object_id) |bytes| issue.object_id_hex = try lowerHexAlloc(allocator, bytes);
    if (chunk_hash) |bytes| issue.chunk_hash_hex = try lowerHexAlloc(allocator, bytes);
    if (collection_name) |value| issue.collection_name = try allocator.dupe(u8, value);
    if (vector_id) |value| issue.vector_id = try allocator.dupe(u8, value);

    try issues.append(allocator, issue);
}

fn scalarU64(db: *zova.Database, sql: [:0]const u8) !u64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    return switch (try stmt.step()) {
        .row => @intCast(stmt.columnInt64(0)),
        .done => 0,
    };
}

fn scalarTextAlloc(allocator: std.mem.Allocator, db: *zova.Database, sql: [:0]const u8) ![]u8 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    return switch (try stmt.step()) {
        .row => try allocator.dupe(u8, stmt.columnText(0)),
        .done => try allocator.dupe(u8, ""),
    };
}
