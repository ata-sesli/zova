//! Inspection, check, and operational-copy CLI for Zova.
//!
//! Inspection and check commands are non-mutating. Operational commands create
//! new backup/compact/restore files but do not overwrite destinations, repair,
//! migrate, delete, or dump binary content.

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

const GraphNodeCommandArgs = struct {
    format: OutputFormat,
    path: []const u8,
    graph_name: []const u8,
    node_id: []const u8,
};

const GraphNeighborsCommandArgs = struct {
    format: OutputFormat,
    limit: usize,
    path: []const u8,
    graph_name: []const u8,
    node_id: []const u8,
    incoming: bool,
    edge_type: ?[]const u8,
};

const GraphWalkCommandArgs = struct {
    format: OutputFormat,
    limit: usize,
    max_depth: u32,
    path: []const u8,
    graph_name: []const u8,
    node_id: []const u8,
    edge_type: ?[]const u8,
};

const SalvageCommandArgs = struct {
    format: OutputFormat,
    limit: usize,
    dry_run: bool,
    source_path: []const u8,
    destination_path: ?[]const u8,
};

const OperationalCommandArgs = struct {
    format: OutputFormat,
    verify: bool,
    source_path: []const u8,
    destination_path: []const u8,
};

const SplitRole = enum {
    objects,
    vectors,
};

const SplitCommandArgs = struct {
    format: OutputFormat,
    role: SplitRole,
    main_path: []const u8,
    store_path: []const u8,
};

const ObjectStoreAction = enum {
    create,
    bind,
    info,
    unbind,
};

const ObjectStoreCommandArgs = struct {
    format: OutputFormat,
    action: ObjectStoreAction,
    main_path: ?[]const u8,
    store_path: ?[]const u8,
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

const GraphCommandParseError = error{
    DuplicateJson,
    DuplicateLimit,
    DuplicateIncoming,
    DuplicateEdgeType,
    DuplicateMaxDepth,
    MissingLimitValue,
    MissingEdgeTypeValue,
    MissingMaxDepthValue,
    InvalidLimit,
    InvalidMaxDepth,
    UnknownFlag,
    MissingPath,
    MissingGraph,
    MissingNode,
    ExtraArgs,
};

const SalvageCommandParseError = error{
    DuplicateJson,
    DuplicateDryRun,
    DuplicateLimit,
    MissingLimitValue,
    InvalidLimit,
    UnknownFlag,
    MissingSource,
    MissingDestination,
    DestinationNotAllowed,
    ExtraArgs,
};

const ObjectStoreCommandParseError = error{
    MissingAction,
    UnknownAction,
    DuplicateJson,
    UnknownFlag,
    MissingMainPath,
    MissingStorePath,
    ExtraArgs,
};

const SplitCommandParseError = error{
    MissingRole,
    DuplicateRole,
    DuplicateJson,
    UnknownFlag,
    MissingMainPath,
    MissingStorePath,
    SamePath,
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

const DiagnosticStats = struct {
    objects: u64 = 0,
    chunks: u64 = 0,
    vectors: u64 = 0,
    loose_chunks: u64 = 0,
    graphs: u64 = 0,
    graph_nodes: u64 = 0,
    graph_edges: u64 = 0,
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

const DiagnosticIssueCounts = struct {
    sqlite: u64 = 0,
    bound_store: u64 = 0,
    object: u64 = 0,
    chunk: u64 = 0,
    vector: u64 = 0,
    graph: u64 = 0,
};

const DiagnosticSeverityCounts = struct {
    info: u64 = 0,
    warning: u64 = 0,
    errors: u64 = 0,
    fatal: u64 = 0,
};

const DiagnosticIssueArea = enum {
    sqlite,
    bound_store,
    object,
    chunk,
    vector,
    graph,
};

const DiagnosticIssue = struct {
    area: DiagnosticIssueArea,
    kind: []const u8,
    severity: []const u8 = "error",
    detail: []const u8,
    object_id_hex: ?[]u8 = null,
    chunk_hash_hex: ?[]u8 = null,
    collection_name: ?[]u8 = null,
    vector_id: ?[]u8 = null,
    graph_name: ?[]u8 = null,
    node_id: ?[]u8 = null,
    edge_type: ?[]u8 = null,

    fn deinit(self: *DiagnosticIssue, allocator: std.mem.Allocator) void {
        if (self.object_id_hex) |value| allocator.free(value);
        if (self.chunk_hash_hex) |value| allocator.free(value);
        if (self.collection_name) |value| allocator.free(value);
        if (self.vector_id) |value| allocator.free(value);
        if (self.graph_name) |value| allocator.free(value);
        if (self.node_id) |value| allocator.free(value);
        if (self.edge_type) |value| allocator.free(value);
    }
};

const DiagnosticReport = struct {
    stats: DiagnosticStats = .{},
    issue_count: u64 = 0,
    issue_counts: DiagnosticIssueCounts = .{},
    severity_counts: DiagnosticSeverityCounts = .{},
    issues: []DiagnosticIssue = &.{},
    issues_truncated: bool = false,
    issue_limit: usize = 10,

    fn deinit(self: *DiagnosticReport, allocator: std.mem.Allocator) void {
        for (self.issues) |*issue| issue.deinit(allocator);
        allocator.free(self.issues);
    }
};

const SalvageRecoverability = enum {
    recoverable,
    partially_recoverable,
    not_recoverable,
    unknown,
};

const SalvageCounts = struct {
    user_tables: u64 = 0,
    user_schema_objects: u64 = 0,
    user_rows: u64 = 0,
    graphs: u64 = 0,
    graph_nodes: u64 = 0,
    graph_edges: u64 = 0,
    objects: u64 = 0,
    chunks: u64 = 0,
    loose_chunks: u64 = 0,
    vector_collections: u64 = 0,
    vectors: u64 = 0,
};

const SalvagePlan = struct {
    report: DiagnosticReport,
    recoverability: SalvageRecoverability,
    recoverable: SalvageCounts,
    skipped: SalvageCounts,

    fn deinit(self: *SalvagePlan, allocator: std.mem.Allocator) void {
        self.report.deinit(allocator);
    }
};

const SalvageExecutionResult = struct {
    plan: SalvagePlan,
    copied: SalvageCounts,
    destination_verified: bool,

    fn deinit(self: *SalvageExecutionResult, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
    }
};

const UserSqlCopyResult = struct {
    copied_tables: u64 = 0,
    skipped_tables: u64 = 0,
    copied_schema_objects: u64 = 0,
    skipped_schema_objects: u64 = 0,
    copied_rows: u64 = 0,
    skipped_rows: u64 = 0,
};

const UserSqlRowCopyResult = struct {
    copied_rows: u64 = 0,
    skipped_rows: u64 = 0,
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
    if (std.mem.eql(u8, command, "graphs")) {
        return graphsCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "graph")) {
        return graphCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "graph-node")) {
        return graphNodeCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "graph-neighbors")) {
        return graphNeighborsCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "graph-walk")) {
        return graphWalkCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "tables")) {
        return tablesCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "check")) {
        return checkCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "doctor")) {
        return doctorCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "salvage")) {
        return salvageCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "backup")) {
        return backupCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "compact")) {
        return compactCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "restore")) {
        return restoreCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "split")) {
        return splitCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "object-store")) {
        return objectStoreCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "vector-store")) {
        return vectorStoreCommand(allocator, args[2..], stdout, stderr);
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
        \\  zova graphs [--json] [--limit <n>] <file.zova>
        \\  zova graph [--json] <file.zova> <graph>
        \\  zova graph-node [--json] <file.zova> <graph> <node-id>
        \\  zova graph-neighbors [--json] [--incoming] [--edge-type <type>] [--limit <n>] <file.zova> <graph> <node-id>
        \\  zova graph-walk [--json] [--edge-type <type>] [--max-depth <n>] [--limit <n>] <file.zova> <graph> <node-id>
        \\  zova tables [--json] [--limit <n>] <file.zova>
        \\  zova check [--deep] <file.zova>
        \\  zova check --json [--deep] <file.zova>
        \\  zova doctor [--json] [--limit <n>] <file.zova>
        \\  zova salvage --dry-run [--json] [--limit <n>] <source.zova>
        \\  zova salvage [--json] [--limit <n>] <source.zova> <destination.zova>
        \\  zova backup [--json] [--no-verify] <source.zova> <destination.zova>
        \\  zova compact [--json] [--no-verify] <source.zova> <destination.zova>
        \\  zova restore [--json] [--no-verify] <backup.zova> <destination.zova>
        \\  zova split (--objects | --vectors) [--json] <main.zova> <store.zova>
        \\  zova object-store create [--json] <objects.zova>
        \\  zova object-store bind [--json] <main.zova> <objects.zova>
        \\  zova object-store info [--json] <main.zova>
        \\  zova object-store unbind [--json] <main.zova>
        \\  zova vector-store create [--json] <vectors.zova>
        \\  zova vector-store bind [--json] <main.zova> <vectors.zova>
        \\  zova vector-store info [--json] <main.zova>
        \\  zova vector-store unbind [--json] <main.zova>
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
        \\  graphs list bounded graph metadata
        \\  graph inspect one graph summary
        \\  graph-node inspect one graph node without user row/object/vector data
        \\  graph-neighbors list bounded incoming or outgoing neighbors
        \\  graph-walk walk directed graph edges with depth and result bounds
        \\  tables  list bounded user/private table names without schema or rows
        \\  check  validate Zova identity/schema and SQLite quick_check
        \\  doctor explain database health and suggested recovery actions
        \\  salvage plan or copy best-effort recovery without mutating the source
        \\  backup create a verified snapshot copy without overwriting destination
        \\  compact create a verified space-reclaiming copy with VACUUM INTO
        \\  restore restore a backup into a new destination file
        \\  split  move existing single-file object or vector storage into a new bound store
        \\  object-store manage one optional bound object store
        \\  vector-store manage one optional bound vector store
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

fn parseOperationalCommandArgs(
    args: []const []const u8,
    command: []const u8,
    stderr: *std.Io.Writer,
) !OperationalCommandArgs {
    var format: OutputFormat = .text;
    var verify = true;
    var saw_no_verify = false;
    var source_path: ?[]const u8 = null;
    var destination_path: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            if (saw_no_verify) return error.DuplicateNoVerify;
            saw_no_verify = true;
            verify = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (source_path == null) {
            source_path = arg;
        } else if (destination_path == null) {
            destination_path = arg;
        } else {
            return error.ExtraArgs;
        }
    }

    const source = source_path orelse {
        _ = stderr;
        _ = command;
        return error.MissingSource;
    };
    const destination = destination_path orelse return error.MissingDestination;

    return .{
        .format = format,
        .verify = verify,
        .source_path = source,
        .destination_path = destination,
    };
}

fn operationalUsageMessage(command: []const u8, err: anyerror) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.DuplicateNoVerify => "duplicate --no-verify",
        error.UnknownFlag => "unknown flag",
        error.MissingSource => "missing source path",
        error.MissingDestination => "missing destination path",
        error.ExtraArgs => if (std.mem.eql(u8, command, "restore"))
            "restore accepts only [--json] [--no-verify] <backup.zova> <destination.zova>"
        else
            "command accepts only [--json] [--no-verify] <source.zova> <destination.zova>",
        else => "invalid command arguments",
    };
}

fn operationalErrorExitCode(err: anyerror) u8 {
    return switch (err) {
        error.Corrupt,
        error.ObjectCorrupt,
        error.ObjectNotFound,
        error.ObjectChunkNotFound,
        error.VectorCorrupt,
        error.VectorCollectionNotFound,
        error.VectorNotFound,
        => ExitCode.check_failed,
        else => ExitCode.open,
    };
}

fn argsContain(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn operationalErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    const exit_code = operationalErrorExitCode(err);
    const label = if (exit_code == ExitCode.check_failed) "verification failed" else "operation failed";
    switch (format) {
        .text => try stderr.print("{s}: {s}: {s}\n", .{ command, label, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, label, @errorName(err)),
    }
    return exit_code;
}

fn backupCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseOperationalCommandArgs(args, "backup", stderr) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "backup", format, operationalUsageMessage("backup", err));
    };

    const source = try allocator.dupeZ(u8, parsed.source_path);
    defer allocator.free(source);
    const destination = try allocator.dupeZ(u8, parsed.destination_path);
    defer allocator.free(destination);

    var db = zova.Database.open(source) catch |err| return openErrorFormat(stderr, "backup", parsed.format, err);
    defer db.deinit();

    db.backupTo(destination, .{ .verify = parsed.verify }) catch |err| return operationalErrorFormat(stderr, "backup", parsed.format, err);
    try writeOperationalSuccess(stdout, "backup", parsed, parsed.source_path, parsed.destination_path);
    return ExitCode.ok;
}

fn compactCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseOperationalCommandArgs(args, "compact", stderr) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "compact", format, operationalUsageMessage("compact", err));
    };

    const source = try allocator.dupeZ(u8, parsed.source_path);
    defer allocator.free(source);
    const destination = try allocator.dupeZ(u8, parsed.destination_path);
    defer allocator.free(destination);

    var db = zova.Database.open(source) catch |err| return openErrorFormat(stderr, "compact", parsed.format, err);
    defer db.deinit();

    db.compactTo(destination, .{ .verify = parsed.verify }) catch |err| return operationalErrorFormat(stderr, "compact", parsed.format, err);
    try writeOperationalSuccess(stdout, "compact", parsed, parsed.source_path, parsed.destination_path);
    return ExitCode.ok;
}

fn restoreCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseOperationalCommandArgs(args, "restore", stderr) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "restore", format, operationalUsageMessage("restore", err));
    };

    const source = try allocator.dupeZ(u8, parsed.source_path);
    defer allocator.free(source);
    const destination = try allocator.dupeZ(u8, parsed.destination_path);
    defer allocator.free(destination);

    zova.restoreBackup(source, destination, .{ .verify = parsed.verify }) catch |err| return operationalErrorFormat(stderr, "restore", parsed.format, err);
    try writeOperationalSuccess(stdout, "restore", parsed, parsed.source_path, parsed.destination_path);
    return ExitCode.ok;
}

fn splitCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseSplitCommandArgs(args) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "split", format, splitUsageMessage(err));
    };

    const main_z = try allocator.dupeZ(u8, parsed.main_path);
    defer allocator.free(main_z);
    const store_z = try allocator.dupeZ(u8, parsed.store_path);
    defer allocator.free(store_z);

    var db = zova.Database.openForObjectStoreManagement(main_z, .{}) catch |err| return openErrorFormat(stderr, "split", parsed.format, err);
    defer db.deinit();

    switch (parsed.role) {
        .objects => {
            const result = db.splitObjectStore(store_z) catch |err| return splitErrorFormat(stderr, parsed.format, err);
            try writeSplitObjectSuccess(stdout, parsed, result);
        },
        .vectors => {
            const result = db.splitVectorStore(store_z) catch |err| return splitErrorFormat(stderr, parsed.format, err);
            try writeSplitVectorSuccess(stdout, parsed, result);
        },
    }
    return ExitCode.ok;
}

fn parseSplitCommandArgs(args: []const []const u8) SplitCommandParseError!SplitCommandArgs {
    var format: OutputFormat = .text;
    var role: ?SplitRole = null;
    var main_path: ?[]const u8 = null;
    var store_path: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--objects")) {
            if (role != null) return error.DuplicateRole;
            role = .objects;
        } else if (std.mem.eql(u8, arg, "--vectors")) {
            if (role != null) return error.DuplicateRole;
            role = .vectors;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (main_path == null) {
            main_path = arg;
        } else if (store_path == null) {
            store_path = arg;
        } else {
            return error.ExtraArgs;
        }
    }

    const selected_role = role orelse return error.MissingRole;
    const main = main_path orelse return error.MissingMainPath;
    const store = store_path orelse return error.MissingStorePath;
    if (std.mem.eql(u8, main, store)) return error.SamePath;

    return .{
        .format = format,
        .role = selected_role,
        .main_path = main,
        .store_path = store,
    };
}

fn splitUsageMessage(err: SplitCommandParseError) []const u8 {
    return switch (err) {
        error.MissingRole => "split requires exactly one of --objects or --vectors",
        error.DuplicateRole => "split accepts only one role flag",
        error.DuplicateJson => "duplicate --json",
        error.UnknownFlag => "unknown flag",
        error.MissingMainPath => "split requires <main.zova>",
        error.MissingStorePath => "split requires <store.zova>",
        error.SamePath => "split store path must differ from main path",
        error.ExtraArgs => "split accepts only (--objects | --vectors) [--json] <main.zova> <store.zova>",
    };
}

fn splitErrorFormat(stderr: *std.Io.Writer, format: OutputFormat, err: anyerror) !u8 {
    switch (format) {
        .text => try stderr.print("split: failed: {s}\n", .{@errorName(err)}),
        .json => try writeJsonErrorWithKind(stderr, "split", "operation failed", @errorName(err)),
    }
    return ExitCode.open;
}

fn objectStoreCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseObjectStoreCommandArgs(args) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "object-store", format, objectStoreUsageMessage(err));
    };

    const command_name = objectStoreCommandName(parsed.action);
    switch (parsed.action) {
        .create => {
            const store_path = parsed.store_path.?;
            const store_z = try allocator.dupeZ(u8, store_path);
            defer allocator.free(store_z);

            zova.createObjectStore(store_z) catch |err| return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, null, store_path, null, true, true);
            return ExitCode.ok;
        },
        .bind => {
            const main_path = parsed.main_path.?;
            const store_path = parsed.store_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);
            const store_z = try allocator.dupeZ(u8, store_path);
            defer allocator.free(store_z);

            var db = zova.Database.openForObjectStoreManagement(main_z, .{}) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            db.bindObjectStore(store_z) catch |err| {
                if (err == error.BoundStoreExists) return boundStoreMigrationRequiredFormat(stderr, command_name, parsed.format, .objects, main_path, store_path);
                return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            };
            var info = (try db.boundObjectStore(allocator)).?;
            defer info.deinit(allocator);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, info.path, info.store_id, false, true);
            return ExitCode.ok;
        },
        .info => {
            const main_path = parsed.main_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);

            var db = zova.Database.openForObjectStoreManagement(main_z, .{}) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            var maybe_info = try db.boundObjectStore(allocator);
            if (maybe_info) |*info| {
                defer info.deinit(allocator);
                try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, info.path, info.store_id, false, true);
            } else {
                try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, null, null, false, false);
            }
            return ExitCode.ok;
        },
        .unbind => {
            const main_path = parsed.main_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);

            var db = zova.Database.openForObjectStoreManagement(main_z, .{}) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            db.unbindObjectStore() catch |err| return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, null, null, false, false);
            return ExitCode.ok;
        },
    }
}

fn vectorStoreCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseObjectStoreCommandArgs(args) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "vector-store", format, vectorStoreUsageMessage(err));
    };

    const command_name = vectorStoreCommandName(parsed.action);
    switch (parsed.action) {
        .create => {
            const store_path = parsed.store_path.?;
            const store_z = try allocator.dupeZ(u8, store_path);
            defer allocator.free(store_z);

            zova.createVectorStore(store_z) catch |err| return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, null, store_path, null, true, true);
            return ExitCode.ok;
        },
        .bind => {
            const main_path = parsed.main_path.?;
            const store_path = parsed.store_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);
            const store_z = try allocator.dupeZ(u8, store_path);
            defer allocator.free(store_z);

            var db = zova.Database.openForObjectStoreManagement(main_z, .{}) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            db.bindVectorStore(store_z) catch |err| {
                if (err == error.BoundStoreExists) return boundStoreMigrationRequiredFormat(stderr, command_name, parsed.format, .vectors, main_path, store_path);
                return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            };
            var info = (try db.boundVectorStore(allocator)).?;
            defer info.deinit(allocator);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, info.path, info.store_id, false, true);
            return ExitCode.ok;
        },
        .info => {
            const main_path = parsed.main_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);

            var db = zova.Database.openForObjectStoreManagement(main_z, .{}) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            var maybe_info = try db.boundVectorStore(allocator);
            if (maybe_info) |*info| {
                defer info.deinit(allocator);
                try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, info.path, info.store_id, false, true);
            } else {
                try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, null, null, false, false);
            }
            return ExitCode.ok;
        },
        .unbind => {
            const main_path = parsed.main_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);

            var db = zova.Database.openForObjectStoreManagement(main_z, .{}) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            db.unbindVectorStore() catch |err| return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, null, null, false, false);
            return ExitCode.ok;
        },
    }
}

fn parseObjectStoreCommandArgs(args: []const []const u8) ObjectStoreCommandParseError!ObjectStoreCommandArgs {
    if (args.len == 0) return error.MissingAction;

    const action = parseObjectStoreAction(args[0]) orelse return error.UnknownAction;
    var format: OutputFormat = .text;
    var first_path: ?[]const u8 = null;
    var second_path: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (first_path == null) {
            first_path = arg;
        } else if (second_path == null) {
            second_path = arg;
        } else {
            return error.ExtraArgs;
        }
    }

    switch (action) {
        .create => {
            const store_path = first_path orelse return error.MissingStorePath;
            if (second_path != null) return error.ExtraArgs;
            return .{ .format = format, .action = action, .main_path = null, .store_path = store_path };
        },
        .bind => {
            const main_path = first_path orelse return error.MissingMainPath;
            const store_path = second_path orelse return error.MissingStorePath;
            return .{ .format = format, .action = action, .main_path = main_path, .store_path = store_path };
        },
        .info, .unbind => {
            const main_path = first_path orelse return error.MissingMainPath;
            if (second_path != null) return error.ExtraArgs;
            return .{ .format = format, .action = action, .main_path = main_path, .store_path = null };
        },
    }
}

fn parseObjectStoreAction(value: []const u8) ?ObjectStoreAction {
    if (std.mem.eql(u8, value, "create")) return .create;
    if (std.mem.eql(u8, value, "bind")) return .bind;
    if (std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "unbind")) return .unbind;
    return null;
}

fn objectStoreCommandName(action: ObjectStoreAction) []const u8 {
    return switch (action) {
        .create => "object-store-create",
        .bind => "object-store-bind",
        .info => "object-store-info",
        .unbind => "object-store-unbind",
    };
}

fn vectorStoreCommandName(action: ObjectStoreAction) []const u8 {
    return switch (action) {
        .create => "vector-store-create",
        .bind => "vector-store-bind",
        .info => "vector-store-info",
        .unbind => "vector-store-unbind",
    };
}

fn objectStoreUsageMessage(err: ObjectStoreCommandParseError) []const u8 {
    return switch (err) {
        error.MissingAction => "object-store requires create, bind, info, or unbind",
        error.UnknownAction => "unknown object-store action",
        error.DuplicateJson => "duplicate --json",
        error.UnknownFlag => "unknown flag",
        error.MissingMainPath => "object-store action requires <main.zova>",
        error.MissingStorePath => "object-store action requires <objects.zova>",
        error.ExtraArgs => "object-store action received extra arguments",
    };
}

fn vectorStoreUsageMessage(err: ObjectStoreCommandParseError) []const u8 {
    return switch (err) {
        error.MissingAction => "vector-store requires create, bind, info, or unbind",
        error.UnknownAction => "unknown vector-store action",
        error.DuplicateJson => "duplicate --json",
        error.UnknownFlag => "unknown flag",
        error.MissingMainPath => "vector-store action requires <main.zova>",
        error.MissingStorePath => "vector-store action requires <vectors.zova>",
        error.ExtraArgs => "vector-store action received extra arguments",
    };
}

fn objectStoreErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    switch (format) {
        .text => try stderr.print("{s}: failed: {s}\n", .{ command, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, "operation failed", @errorName(err)),
    }
    return ExitCode.open;
}

fn boundStoreMigrationRequiredFormat(
    stderr: *std.Io.Writer,
    command: []const u8,
    format: OutputFormat,
    role: SplitRole,
    main_path: []const u8,
    store_path: []const u8,
) !u8 {
    const role_flag = splitRoleFlag(role);
    switch (format) {
        .text => {
            try stderr.print("{s}: failed: BoundStoreExists\n", .{command});
            try stderr.print("main database already contains {s} storage; run zova split {s} {s} {s}\n", .{
                splitRoleStorageName(role),
                role_flag,
                main_path,
                store_path,
            });
        },
        .json => {
            try stderr.writeAll("{\n");
            try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stderr.writeAll("  \"status\": \"error\",\n");
            try stderr.writeAll("  \"command\": ");
            try writeJsonString(stderr, command);
            try stderr.writeAll(",\n  \"kind\": \"split required\",\n");
            try stderr.writeAll("  \"error\": \"BoundStoreExists\",\n");
            try stderr.writeAll("  \"suggested_command\": ");
            try writeJsonStringFormat(stderr, "zova split {s} {s} {s}", .{ role_flag, main_path, store_path });
            try stderr.writeAll("\n}\n");
        },
    }
    return ExitCode.open;
}

fn writeSplitObjectSuccess(stdout: *std.Io.Writer, parsed: SplitCommandArgs, result: zova.SplitObjectStoreResult) !void {
    switch (parsed.format) {
        .text => {
            try stdout.writeAll("split: ok\n");
            try stdout.writeAll("role: objects\n");
            try stdout.print("main_path: {s}\n", .{parsed.main_path});
            try stdout.print("store_path: {s}\n", .{parsed.store_path});
            try stdout.print("copied_objects: {d}\n", .{result.copied.objects});
            try stdout.print("copied_chunks: {d}\n", .{result.copied.chunks});
            try stdout.print("copied_manifest_rows: {d}\n", .{result.copied.manifest_rows});
            try stdout.print("cleared_objects: {d}\n", .{result.cleared.objects});
            try stdout.print("cleared_chunks: {d}\n", .{result.cleared.chunks});
            try stdout.print("cleared_manifest_rows: {d}\n", .{result.cleared.manifest_rows});
            try stdout.print("verified: {}\n", .{result.verified});
        },
        .json => {
            try writeSplitJsonHeader(stdout, parsed, result.store_id, result.bound_set_id, result.verified);
            try stdout.writeAll(",\n  \"copied\": {\n");
            try stdout.print("    \"objects\": {d},\n", .{result.copied.objects});
            try stdout.print("    \"chunks\": {d},\n", .{result.copied.chunks});
            try stdout.print("    \"manifest_rows\": {d}\n", .{result.copied.manifest_rows});
            try stdout.writeAll("  },\n  \"cleared\": {\n");
            try stdout.print("    \"objects\": {d},\n", .{result.cleared.objects});
            try stdout.print("    \"chunks\": {d},\n", .{result.cleared.chunks});
            try stdout.print("    \"manifest_rows\": {d}\n", .{result.cleared.manifest_rows});
            try stdout.writeAll("  }\n}\n");
        },
    }
}

fn writeSplitVectorSuccess(stdout: *std.Io.Writer, parsed: SplitCommandArgs, result: zova.SplitVectorStoreResult) !void {
    switch (parsed.format) {
        .text => {
            try stdout.writeAll("split: ok\n");
            try stdout.writeAll("role: vectors\n");
            try stdout.print("main_path: {s}\n", .{parsed.main_path});
            try stdout.print("store_path: {s}\n", .{parsed.store_path});
            try stdout.print("copied_vector_collections: {d}\n", .{result.copied.vector_collections});
            try stdout.print("copied_vectors: {d}\n", .{result.copied.vectors});
            try stdout.print("cleared_vector_collections: {d}\n", .{result.cleared.vector_collections});
            try stdout.print("cleared_vectors: {d}\n", .{result.cleared.vectors});
            try stdout.print("verified: {}\n", .{result.verified});
        },
        .json => {
            try writeSplitJsonHeader(stdout, parsed, result.store_id, result.bound_set_id, result.verified);
            try stdout.writeAll(",\n  \"copied\": {\n");
            try stdout.print("    \"vector_collections\": {d},\n", .{result.copied.vector_collections});
            try stdout.print("    \"vectors\": {d}\n", .{result.copied.vectors});
            try stdout.writeAll("  },\n  \"cleared\": {\n");
            try stdout.print("    \"vector_collections\": {d},\n", .{result.cleared.vector_collections});
            try stdout.print("    \"vectors\": {d}\n", .{result.cleared.vectors});
            try stdout.writeAll("  }\n}\n");
        },
    }
}

fn writeSplitJsonHeader(
    stdout: *std.Io.Writer,
    parsed: SplitCommandArgs,
    store_id: [64]u8,
    bound_set_id: [64]u8,
    verified: bool,
) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"split\",\n");
    try stdout.writeAll("  \"role\": ");
    try writeJsonString(stdout, splitRoleJsonName(parsed.role));
    try stdout.writeAll(",\n  \"main_path\": ");
    try writeJsonString(stdout, parsed.main_path);
    try stdout.writeAll(",\n  \"store_path\": ");
    try writeJsonString(stdout, parsed.store_path);
    try stdout.writeAll(",\n  \"created\": true,\n");
    try stdout.writeAll("  \"bound\": true,\n");
    try stdout.print("  \"verified\": {},\n", .{verified});
    try stdout.writeAll("  \"store_id\": ");
    try writeJsonString(stdout, store_id[0..]);
    try stdout.writeAll(",\n  \"bound_set_id\": ");
    try writeJsonString(stdout, bound_set_id[0..]);
}

fn splitRoleJsonName(role: SplitRole) []const u8 {
    return switch (role) {
        .objects => "objects",
        .vectors => "vectors",
    };
}

fn splitRoleFlag(role: SplitRole) []const u8 {
    return switch (role) {
        .objects => "--objects",
        .vectors => "--vectors",
    };
}

fn splitRoleStorageName(role: SplitRole) []const u8 {
    return switch (role) {
        .objects => "object",
        .vectors => "vector",
    };
}

fn writeObjectStoreSuccess(
    stdout: *std.Io.Writer,
    format: OutputFormat,
    command: []const u8,
    main_path: ?[]const u8,
    store_path: ?[]const u8,
    store_id: ?[]const u8,
    created: bool,
    bound: bool,
) !void {
    switch (format) {
        .text => {
            try stdout.print("{s}: ok\n", .{command});
            if (main_path) |value| try stdout.print("main_path: {s}\n", .{value});
            if (store_path) |value| try stdout.print("path: {s}\n", .{value});
            if (store_id) |value| try stdout.print("store_id: {s}\n", .{value});
            if (created) try stdout.writeAll("created: true\n");
            try stdout.print("bound: {}\n", .{bound});
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"command\": ");
            try writeJsonString(stdout, command);
            if (main_path) |value| {
                try stdout.writeAll(",\n  \"main_path\": ");
                try writeJsonString(stdout, value);
            }
            if (store_path) |value| {
                try stdout.writeAll(",\n  \"path\": ");
                try writeJsonString(stdout, value);
            }
            if (store_id) |value| {
                try stdout.writeAll(",\n  \"store_id\": ");
                try writeJsonString(stdout, value);
            }
            try stdout.print(",\n  \"created\": {},\n  \"bound\": {}\n", .{ created, bound });
            try stdout.writeAll("}\n");
        },
    }
}

fn writeOperationalSuccess(
    stdout: *std.Io.Writer,
    command: []const u8,
    parsed: OperationalCommandArgs,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    switch (parsed.format) {
        .text => {
            try stdout.print("{s}: ok\n", .{command});
            try stdout.print("source: {s}\n", .{source_path});
            try stdout.print("destination: {s}\n", .{destination_path});
            try stdout.print("verified: {}\n", .{parsed.verify});
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"command\": ");
            try writeJsonString(stdout, command);
            try stdout.writeAll(",\n  \"source_path\": ");
            try writeJsonString(stdout, source_path);
            try stdout.writeAll(",\n  \"destination_path\": ");
            try writeJsonString(stdout, destination_path);
            try stdout.print(",\n  \"verified\": {}\n", .{parsed.verify});
            try stdout.writeAll("}\n");
        },
    }
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

fn graphsCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "graphs", boundedCommandErrorFormat(args), boundedCommandUsageMessage("graphs", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "graphs", parsed.format, err);
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

fn graphCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, true) catch |err| return usageErrorFormat(stderr, "graph", boundedCommandErrorFormat(args), boundedCommandUsageMessage("graph", err));
    const graph_name = parsed.id orelse return usageErrorFormat(stderr, "graph", parsed.format, "graph requires <file.zova> <graph>");
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "graph", parsed.format, err);
    defer db.deinit();

    var info = db.graphInfo(allocator, graph_name) catch |err| return graphInspectErrorFormat(stderr, "graph", parsed.format, err);
    defer info.deinit(allocator);

    switch (parsed.format) {
        .text => try writeGraphText(stdout, parsed.path, info),
        .json => try writeGraphJson(stdout, info),
    }
    return ExitCode.ok;
}

fn graphNodeCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseGraphNodeCommandArgs(args) catch |err| return usageErrorFormat(stderr, "graph-node", graphCommandErrorFormat(args), graphCommandUsageMessage("graph-node", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "graph-node", parsed.format, err);
    defer db.deinit();

    var node = db.getGraphNode(allocator, parsed.graph_name, parsed.node_id) catch |err| return graphInspectErrorFormat(stderr, "graph-node", parsed.format, err);
    defer node.deinit(allocator);

    switch (parsed.format) {
        .text => try writeGraphNodeText(stdout, parsed.path, node),
        .json => try writeGraphNodeJson(stdout, node),
    }
    return ExitCode.ok;
}

fn graphNeighborsCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseGraphNeighborsCommandArgs(args) catch |err| return usageErrorFormat(stderr, "graph-neighbors", graphCommandErrorFormat(args), graphCommandUsageMessage("graph-neighbors", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "graph-neighbors", parsed.format, err);
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

fn graphWalkCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseGraphWalkCommandArgs(args) catch |err| return usageErrorFormat(stderr, "graph-walk", graphCommandErrorFormat(args), graphCommandUsageMessage("graph-walk", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openErrorFormat(stderr, "graph-walk", parsed.format, err);
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

fn parseGraphNodeCommandArgs(args: []const []const u8) GraphCommandParseError!GraphNodeCommandArgs {
    var format: OutputFormat = .text;
    var positionals: [3][]const u8 = undefined;
    var positional_count: usize = 0;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (positional_count >= positionals.len) return error.ExtraArgs;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingPath;
    if (positional_count == 1) return error.MissingGraph;
    if (positional_count == 2) return error.MissingNode;

    return .{
        .format = format,
        .path = positionals[0],
        .graph_name = positionals[1],
        .node_id = positionals[2],
    };
}

fn parseGraphNeighborsCommandArgs(args: []const []const u8) GraphCommandParseError!GraphNeighborsCommandArgs {
    var format: OutputFormat = .text;
    var limit: usize = default_list_limit;
    var incoming = false;
    var edge_type: ?[]const u8 = null;
    var saw_limit = false;
    var saw_incoming = false;
    var saw_edge_type = false;
    var positionals: [3][]const u8 = undefined;
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
        } else if (std.mem.eql(u8, arg, "--incoming")) {
            if (saw_incoming) return error.DuplicateIncoming;
            saw_incoming = true;
            incoming = true;
        } else if (std.mem.eql(u8, arg, "--edge-type")) {
            if (saw_edge_type) return error.DuplicateEdgeType;
            saw_edge_type = true;
            index += 1;
            if (index >= args.len) return error.MissingEdgeTypeValue;
            edge_type = args[index];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (positional_count >= positionals.len) return error.ExtraArgs;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingPath;
    if (positional_count == 1) return error.MissingGraph;
    if (positional_count == 2) return error.MissingNode;

    return .{
        .format = format,
        .limit = limit,
        .path = positionals[0],
        .graph_name = positionals[1],
        .node_id = positionals[2],
        .incoming = incoming,
        .edge_type = edge_type,
    };
}

fn parseGraphWalkCommandArgs(args: []const []const u8) GraphCommandParseError!GraphWalkCommandArgs {
    var format: OutputFormat = .text;
    var limit: usize = default_list_limit;
    var max_depth: u32 = 1;
    var edge_type: ?[]const u8 = null;
    var saw_limit = false;
    var saw_max_depth = false;
    var saw_edge_type = false;
    var positionals: [3][]const u8 = undefined;
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
        } else if (std.mem.eql(u8, arg, "--max-depth")) {
            if (saw_max_depth) return error.DuplicateMaxDepth;
            saw_max_depth = true;
            index += 1;
            if (index >= args.len) return error.MissingMaxDepthValue;
            const parsed = std.fmt.parseUnsigned(u32, args[index], 10) catch return error.InvalidMaxDepth;
            if (parsed > 64) return error.InvalidMaxDepth;
            max_depth = parsed;
        } else if (std.mem.eql(u8, arg, "--edge-type")) {
            if (saw_edge_type) return error.DuplicateEdgeType;
            saw_edge_type = true;
            index += 1;
            if (index >= args.len) return error.MissingEdgeTypeValue;
            edge_type = args[index];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (positional_count >= positionals.len) return error.ExtraArgs;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingPath;
    if (positional_count == 1) return error.MissingGraph;
    if (positional_count == 2) return error.MissingNode;

    return .{
        .format = format,
        .limit = limit,
        .max_depth = max_depth,
        .path = positionals[0],
        .graph_name = positionals[1],
        .node_id = positionals[2],
        .edge_type = edge_type,
    };
}

fn parseSalvageCommandArgs(args: []const []const u8) SalvageCommandParseError!SalvageCommandArgs {
    var format: OutputFormat = .text;
    var limit: usize = default_list_limit;
    var saw_dry_run = false;
    var saw_limit = false;
    var positionals: [2][]const u8 = undefined;
    var positional_count: usize = 0;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            if (saw_dry_run) return error.DuplicateDryRun;
            saw_dry_run = true;
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

    if (positional_count == 0) return error.MissingSource;
    if (saw_dry_run and positional_count > 1) return error.DestinationNotAllowed;
    if (!saw_dry_run and positional_count == 1) return error.MissingDestination;
    if (!saw_dry_run and positional_count > 2) return error.ExtraArgs;

    return .{
        .format = format,
        .limit = limit,
        .dry_run = saw_dry_run,
        .source_path = positionals[0],
        .destination_path = if (saw_dry_run) null else positionals[1],
    };
}

fn boundedCommandUsageMessage(command: []const u8, err: BoundedCommandParseError) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.DuplicateLimit => "duplicate --limit",
        error.MissingLimitValue => "--limit requires a value",
        error.InvalidLimit => "invalid --limit",
        error.UnknownFlag => "unknown flag",
        error.MissingPath => if (std.mem.eql(u8, command, "object") or std.mem.eql(u8, command, "chunk") or std.mem.eql(u8, command, "vector-collection") or std.mem.eql(u8, command, "graph"))
            "command requires <file.zova> <id>"
        else
            "command requires <file.zova>",
        error.MissingId => if (std.mem.eql(u8, command, "object"))
            "object requires <file.zova> <object-id>"
        else if (std.mem.eql(u8, command, "chunk"))
            "chunk requires <file.zova> <chunk-id>"
        else if (std.mem.eql(u8, command, "graph"))
            "graph requires <file.zova> <graph>"
        else
            "vector-collection requires <file.zova> <name>",
        error.ExtraArgs => "too many arguments",
    };
}

fn graphCommandUsageMessage(command: []const u8, err: GraphCommandParseError) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.DuplicateLimit => "duplicate --limit",
        error.DuplicateIncoming => "duplicate --incoming",
        error.DuplicateEdgeType => "duplicate --edge-type",
        error.DuplicateMaxDepth => "duplicate --max-depth",
        error.MissingLimitValue => "--limit requires a value",
        error.MissingEdgeTypeValue => "--edge-type requires a value",
        error.MissingMaxDepthValue => "--max-depth requires a value",
        error.InvalidLimit => "invalid --limit",
        error.InvalidMaxDepth => "invalid --max-depth",
        error.UnknownFlag => "unknown flag",
        error.MissingPath => "command requires <file.zova> <graph> <node-id>",
        error.MissingGraph => "command requires <graph>",
        error.MissingNode => if (std.mem.eql(u8, command, "graph-node"))
            "graph-node requires <file.zova> <graph> <node-id>"
        else if (std.mem.eql(u8, command, "graph-neighbors"))
            "graph-neighbors requires <file.zova> <graph> <node-id>"
        else
            "graph-walk requires <file.zova> <graph> <node-id>",
        error.ExtraArgs => "too many arguments",
    };
}

fn salvageCommandUsageMessage(err: SalvageCommandParseError) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.DuplicateDryRun => "duplicate --dry-run",
        error.DuplicateLimit => "duplicate --limit",
        error.MissingLimitValue => "--limit requires a value",
        error.InvalidLimit => "invalid --limit",
        error.UnknownFlag => "unknown flag",
        error.MissingSource => "salvage requires <source.zova>",
        error.MissingDestination => "salvage execution requires <destination.zova>",
        error.DestinationNotAllowed => "salvage --dry-run does not accept a destination",
        error.ExtraArgs => "too many arguments",
    };
}

fn boundedCommandErrorFormat(args: []const []const u8) OutputFormat {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return .json;
    }
    return .text;
}

fn graphCommandErrorFormat(args: []const []const u8) OutputFormat {
    return boundedCommandErrorFormat(args);
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

    var db = zova.Database.open(path) catch |err| {
        if (deep) {
            if (try writeBoundStoreOpenFailureCheck(allocator, stderr, format, path, err)) |exit_code| return exit_code;
        }
        return openErrorFormat(stderr, "check", format, err);
    };
    defer db.deinit();

    quickCheck(&db) catch |err| return checkErrorFormat(stderr, "check", format, "sqlite quick_check failed", err);

    if (deep) {
        var report = runDiagnostics(allocator, &db, 10) catch |err| return deepCheckErrorFormat(stderr, format, err);
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

fn doctorCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "doctor", boundedCommandErrorFormat(args), boundedCommandUsageMessage("doctor", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| {
        if (try writeBoundStoreOpenFailureDoctor(allocator, stderr, parsed.format, parsed.path, path, err)) |exit_code| return exit_code;
        return openErrorFormat(stderr, "doctor", parsed.format, err);
    };
    defer db.deinit();

    quickCheck(&db) catch |err| return doctorCheckErrorFormat(stderr, parsed.format, parsed.path, "sqlite quick_check failed", err);

    var summary = loadDatabaseSummary(allocator, &db, path) catch |err| return doctorCheckErrorFormat(stderr, parsed.format, parsed.path, "summary failed", err);
    defer summary.deinit(allocator);

    var report = runDiagnostics(allocator, &db, parsed.limit) catch |err| return doctorCheckErrorFormat(stderr, parsed.format, parsed.path, "diagnostic check failed", err);
    defer report.deinit(allocator);

    if (report.issue_count != 0) {
        switch (parsed.format) {
            .text => try writeDoctorText(stderr, parsed.path, summary, report),
            .json => try writeDoctorJson(stderr, parsed.path, summary, report),
        }
        return ExitCode.check_failed;
    }

    switch (parsed.format) {
        .text => try writeDoctorText(stdout, parsed.path, summary, report),
        .json => try writeDoctorJson(stdout, parsed.path, summary, report),
    }
    return ExitCode.ok;
}

fn writeBoundStoreOpenFailureCheck(
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    format: OutputFormat,
    path: [:0]const u8,
    open_err: anyerror,
) !?u8 {
    var db = zova.Database.openForObjectStoreManagement(path, .{}) catch return null;
    defer db.deinit();

    var has_bound_store = false;
    if (try db.boundObjectStore(allocator)) |info_value| {
        var info = info_value;
        info.deinit(allocator);
        has_bound_store = true;
    }
    if (try db.boundVectorStore(allocator)) |info_value| {
        var info = info_value;
        info.deinit(allocator);
        has_bound_store = true;
    }
    if (!has_bound_store) return null;

    var report = try runDiagnostics(allocator, &db, 10);
    if (report.issue_count == 0) {
        report.deinit(allocator);
        report = try diagnosticErrorReport(allocator, 10, .bound_store, "bound_store_open_failed", @errorName(open_err));
    }
    defer report.deinit(allocator);

    switch (format) {
        .text => {
            try writeDeepCheckFailureText(stderr, report);
            if (reportHasIssue(report, .bound_store, "missing_or_unreadable_store")) {
                try stderr.print(
                    \\suggested_actions:
                    \\  run zova object-store bind {s} <objects.zova> or zova vector-store bind {s} <vectors.zova>
                    \\
                , .{ path, path });
            }
        },
        .json => try writeDeepCheckFailureJson(stderr, report),
    }
    return ExitCode.check_failed;
}

fn writeBoundStoreOpenFailureDoctor(
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    format: OutputFormat,
    source_path: []const u8,
    path: [:0]const u8,
    open_err: anyerror,
) !?u8 {
    var db = zova.Database.openForObjectStoreManagement(path, .{}) catch return null;
    defer db.deinit();

    var has_bound_store = false;
    if (try db.boundObjectStore(allocator)) |info_value| {
        var info = info_value;
        info.deinit(allocator);
        has_bound_store = true;
    }
    if (try db.boundVectorStore(allocator)) |info_value| {
        var info = info_value;
        info.deinit(allocator);
        has_bound_store = true;
    }
    if (!has_bound_store) return null;

    quickCheck(&db) catch |err| return try doctorCheckErrorFormat(stderr, format, source_path, "sqlite quick_check failed", err);

    var summary = loadDatabaseSummary(allocator, &db, path) catch |err| return try doctorCheckErrorFormat(stderr, format, source_path, "summary failed", err);
    defer summary.deinit(allocator);

    var report = try runDiagnostics(allocator, &db, 10);
    if (report.issue_count == 0) {
        report.deinit(allocator);
        report = try diagnosticErrorReport(allocator, 10, .bound_store, "bound_store_open_failed", @errorName(open_err));
    }
    defer report.deinit(allocator);

    switch (format) {
        .text => try writeDoctorText(stderr, source_path, summary, report),
        .json => try writeDoctorJson(stderr, source_path, summary, report),
    }
    return ExitCode.check_failed;
}

fn salvageCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseSalvageCommandArgs(args) catch |err| {
        const format = boundedCommandErrorFormat(args);
        return usageErrorFormat(stderr, "salvage", format, salvageCommandUsageMessage(err));
    };
    if (!parsed.dry_run and !isZovaPath(parsed.destination_path.?)) {
        return usageErrorFormat(stderr, "salvage", parsed.format, "destination path must end in .zova");
    }

    const source = try allocator.dupeZ(u8, parsed.source_path);
    defer allocator.free(source);

    var db = zova.Database.openWithOptions(source, .{ .read_only = true }) catch |err| return openErrorFormat(stderr, "salvage", parsed.format, err);
    defer db.deinit();

    if (quickCheck(&db)) |_| {} else |err| {
        const report = try diagnosticErrorReport(allocator, parsed.limit, .sqlite, "sqlite_quick_check", @errorName(err));
        var summary = try emptyDatabaseSummary(allocator);
        defer summary.deinit(allocator);
        var plan = buildSalvagePlan(summary, report);
        defer plan.deinit(allocator);
        return if (parsed.dry_run)
            writeSalvageFailure(stderr, parsed.format, parsed.source_path, plan)
        else
            writeSalvageExecutionFailure(stderr, parsed.format, parsed.source_path, parsed.destination_path.?, plan);
    }

    var summary = loadDatabaseSummary(allocator, &db, source) catch |err| {
        const report = try diagnosticErrorReport(allocator, parsed.limit, .sqlite, "summary", @errorName(err));
        var empty_summary = try emptyDatabaseSummary(allocator);
        defer empty_summary.deinit(allocator);
        var plan = buildSalvagePlan(empty_summary, report);
        defer plan.deinit(allocator);
        return if (parsed.dry_run)
            writeSalvageFailure(stderr, parsed.format, parsed.source_path, plan)
        else
            writeSalvageExecutionFailure(stderr, parsed.format, parsed.source_path, parsed.destination_path.?, plan);
    };
    defer summary.deinit(allocator);

    const report = runDiagnostics(allocator, &db, parsed.limit) catch |err| {
        const diagnostic_report = try diagnosticErrorReport(allocator, parsed.limit, .sqlite, "diagnostic_check", @errorName(err));
        var plan = buildSalvagePlan(summary, diagnostic_report);
        defer plan.deinit(allocator);
        return if (parsed.dry_run)
            writeSalvageFailure(stderr, parsed.format, parsed.source_path, plan)
        else
            writeSalvageExecutionFailure(stderr, parsed.format, parsed.source_path, parsed.destination_path.?, plan);
    };

    var plan = buildSalvagePlan(summary, report);
    plan.recoverable.user_schema_objects = countUserSchemaObjects(&db) catch 0;
    plan.recoverable.user_rows = countUserRows(allocator, &db) catch 0;

    if (!parsed.dry_run) {
        const destination = try allocator.dupeZ(u8, parsed.destination_path.?);
        defer allocator.free(destination);
        var result = executeSalvage(allocator, &db, destination, plan) catch |err| {
            plan.deinit(allocator);
            return salvageExecutionErrorFormat(stderr, parsed.format, parsed.source_path, parsed.destination_path.?, err);
        };
        defer result.deinit(allocator);

        if (!result.destination_verified) {
            return writeSalvageExecutionFailure(stderr, parsed.format, parsed.source_path, parsed.destination_path.?, result.plan);
        }

        switch (parsed.format) {
            .text => try writeSalvageExecutionText(stdout, parsed.source_path, parsed.destination_path.?, result),
            .json => try writeSalvageExecutionJson(stdout, parsed.source_path, parsed.destination_path.?, result),
        }
        return ExitCode.ok;
    }

    defer plan.deinit(allocator);

    const has_issues = plan.report.issue_count != 0;
    if (has_issues) {
        switch (parsed.format) {
            .text => try writeSalvageDryRunText(stderr, parsed.source_path, plan),
            .json => try writeSalvageDryRunJson(stderr, parsed.source_path, plan),
        }
        return ExitCode.check_failed;
    }

    switch (parsed.format) {
        .text => try writeSalvageDryRunText(stdout, parsed.source_path, plan),
        .json => try writeSalvageDryRunJson(stdout, parsed.source_path, plan),
    }
    return ExitCode.ok;
}

fn isZovaPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zova");
}

fn expectDone(stmt: *sqlite.Statement) !void {
    switch (try stmt.step()) {
        .done => {},
        .row => return error.SqliteError,
    }
}

fn writeSalvageFailure(stderr: *std.Io.Writer, format: OutputFormat, source_path: []const u8, plan: SalvagePlan) !u8 {
    switch (format) {
        .text => try writeSalvageDryRunText(stderr, source_path, plan),
        .json => try writeSalvageDryRunJson(stderr, source_path, plan),
    }
    return ExitCode.check_failed;
}

fn writeSalvageExecutionFailure(
    stderr: *std.Io.Writer,
    format: OutputFormat,
    source_path: []const u8,
    destination_path: []const u8,
    plan: SalvagePlan,
) !u8 {
    const result = SalvageExecutionResult{
        .plan = plan,
        .copied = .{},
        .destination_verified = false,
    };
    switch (format) {
        .text => try writeSalvageExecutionText(stderr, source_path, destination_path, result),
        .json => try writeSalvageExecutionJson(stderr, source_path, destination_path, result),
    }
    return ExitCode.check_failed;
}

fn salvageExecutionErrorFormat(
    stderr: *std.Io.Writer,
    format: OutputFormat,
    source_path: []const u8,
    destination_path: []const u8,
    err: anyerror,
) !u8 {
    switch (format) {
        .text => try stderr.print("salvage failed: {s}\nsource: {s}\ndestination: {s}\n", .{ @errorName(err), source_path, destination_path }),
        .json => {
            try stderr.writeAll("{\n");
            try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stderr.writeAll("  \"status\": \"error\",\n");
            try stderr.writeAll("  \"command\": \"salvage\",\n");
            try stderr.writeAll("  \"source_path\": ");
            try writeJsonString(stderr, source_path);
            try stderr.writeAll(",\n  \"destination_path\": ");
            try writeJsonString(stderr, destination_path);
            try stderr.writeAll(",\n  \"error\": ");
            try writeJsonString(stderr, @errorName(err));
            try stderr.writeAll(",\n  \"destination_verified\": false\n");
            try stderr.writeAll("}\n");
        },
    }
    return ExitCode.check_failed;
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

fn doctorCheckErrorFormat(stderr: *std.Io.Writer, format: OutputFormat, source_path: []const u8, message: []const u8, err: anyerror) !u8 {
    switch (format) {
        .text => {
            try stderr.print("Zova doctor: {s}\n", .{source_path});
            try stderr.print("status: needs_attention\nerror: {s}: {s}\n", .{ message, @errorName(err) });
            try stderr.writeAll("suggested_actions:\n");
            try writeSuggestedActionsText(stderr, source_path, true);
        },
        .json => {
            try stderr.writeAll("{\n");
            try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stderr.writeAll("  \"status\": \"needs_attention\",\n");
            try stderr.writeAll("  \"command\": \"doctor\",\n");
            try stderr.writeAll("  \"source_path\": ");
            try writeJsonString(stderr, source_path);
            try stderr.writeAll(",\n  \"error\": ");
            try writeJsonString(stderr, message);
            try stderr.writeAll(",\n  \"kind\": ");
            try writeJsonString(stderr, @errorName(err));
            try stderr.writeAll(",\n  \"suggested_actions\": ");
            try writeSuggestedActionsJson(stderr, source_path, true);
            try stderr.writeAll("\n}\n");
        },
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

fn graphInspectErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    const label = switch (err) {
        error.GraphNotFound,
        error.GraphNodeNotFound,
        error.GraphEdgeNotFound,
        => "not found",
        error.GraphInvalid => "invalid graph input",
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

fn emptyDatabaseSummary(allocator: std.mem.Allocator) !DatabaseSummary {
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

fn writeGraphsText(stdout: *std.Io.Writer, path: []const u8, limit: usize, items: []const zova.GraphInfo, truncated: bool) !void {
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

fn writeGraphsJson(stdout: *std.Io.Writer, limit: usize, items: []const zova.GraphInfo, truncated: bool) !void {
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

fn writeGraphText(stdout: *std.Io.Writer, path: []const u8, info: zova.GraphInfo) !void {
    try stdout.print(
        \\Zova graph: {s}
        \\graph: {s}
        \\nodes: {d}
        \\edges: {d}
        \\
    , .{ path, info.name, info.node_count, info.edge_count });
}

fn writeGraphJson(stdout: *std.Io.Writer, info: zova.GraphInfo) !void {
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

fn writeGraphNodeText(stdout: *std.Io.Writer, path: []const u8, node: zova.GraphNode) !void {
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

fn writeGraphNodeJson(stdout: *std.Io.Writer, node: zova.GraphNode) !void {
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

fn writeGraphNeighborsText(
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

fn writeGraphNeighborsJson(
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

fn writeGraphWalkText(
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

fn writeGraphWalkJson(
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

fn writeStringArrayJson(stdout: *std.Io.Writer, items: []const []const u8) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try writeJsonString(stdout, item);
    }
    try stdout.writeAll("]");
}

fn writeNullableJsonString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |actual| {
        try writeJsonString(writer, actual);
    } else {
        try writer.writeAll("null");
    }
}

fn graphTargetTypeText(target_type: zova.GraphTargetType) []const u8 {
    return switch (target_type) {
        .none => "none",
        .record => "record",
        .object => "object",
        .object_chunk => "object_chunk",
        .vector => "vector",
        .entity => "entity",
        .fact => "fact",
        .concept => "concept",
        .external => "external",
    };
}

fn graphTargetTypeFromText(text: []const u8) ?zova.GraphTargetType {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "record")) return .record;
    if (std.mem.eql(u8, text, "object")) return .object;
    if (std.mem.eql(u8, text, "object_chunk")) return .object_chunk;
    if (std.mem.eql(u8, text, "vector")) return .vector;
    if (std.mem.eql(u8, text, "entity")) return .entity;
    if (std.mem.eql(u8, text, "fact")) return .fact;
    if (std.mem.eql(u8, text, "concept")) return .concept;
    if (std.mem.eql(u8, text, "external")) return .external;
    return null;
}

fn graphDirectionText(direction: zova.GraphNeighborDirection) []const u8 {
    return switch (direction) {
        .outgoing => "outgoing",
        .incoming => "incoming",
    };
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

fn writeCheckText(stdout: *std.Io.Writer, report: ?DiagnosticReport) !void {
    try stdout.print("quick_check: ok\n", .{});
    if (report) |deep_report| {
        try stdout.print(
            \\deep_check: ok
            \\objects_checked: {d}
            \\chunks_checked: {d}
            \\vectors_checked: {d}
            \\loose_chunks: {d}
            \\graphs_checked: {d}
            \\graph_nodes_checked: {d}
            \\graph_edges_checked: {d}
            \\issue_count: {d}
            \\sqlite_issues: {d}
            \\bound_store_issues: {d}
            \\object_issues: {d}
            \\chunk_issues: {d}
            \\vector_issues: {d}
            \\graph_issues: {d}
            \\error_issues: {d}
            \\
        , .{
            deep_report.stats.objects,
            deep_report.stats.chunks,
            deep_report.stats.vectors,
            deep_report.stats.loose_chunks,
            deep_report.stats.graphs,
            deep_report.stats.graph_nodes,
            deep_report.stats.graph_edges,
            deep_report.issue_count,
            deep_report.issue_counts.sqlite,
            deep_report.issue_counts.bound_store,
            deep_report.issue_counts.object,
            deep_report.issue_counts.chunk,
            deep_report.issue_counts.vector,
            deep_report.issue_counts.graph,
            deep_report.severity_counts.errors,
        });
    }
    try stdout.print("status: ok\n", .{});
}

fn writeCheckJson(stdout: *std.Io.Writer, report: ?DiagnosticReport) !void {
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
            \\    "loose_chunks": {d},
            \\    "graphs": {d},
            \\    "graph_nodes": {d},
            \\    "graph_edges": {d}
            \\  }},
            \\  "issue_count": {d},
            \\  "issue_counts":
        , .{
            deep_report.stats.objects,
            deep_report.stats.chunks,
            deep_report.stats.vectors,
            deep_report.stats.loose_chunks,
            deep_report.stats.graphs,
            deep_report.stats.graph_nodes,
            deep_report.stats.graph_edges,
            deep_report.issue_count,
        });
        try stdout.writeByte(' ');
        try writeDiagnosticIssueCountsJson(stdout, deep_report.issue_counts);
        try stdout.writeAll(",\n  \"severity_counts\": ");
        try writeDiagnosticSeverityCountsJson(stdout, deep_report.severity_counts);
        try stdout.writeAll(",\n  \"issues_truncated\": false,\n  \"issues\": [],\n  \"suggested_actions\": ");
        try writeSuggestedActionsJson(stdout, "", false);
    }
    try stdout.writeAll("\n}\n");
}

fn writeDeepCheckFailureText(stderr: *std.Io.Writer, report: DiagnosticReport) !void {
    try stderr.print(
        \\deep_check: failed
        \\issue_count: {d}
        \\sqlite_issues: {d}
        \\bound_store_issues: {d}
        \\object_issues: {d}
        \\chunk_issues: {d}
        \\vector_issues: {d}
        \\graph_issues: {d}
        \\error_issues: {d}
        \\issues_truncated: {}
        \\issues:
        \\
    , .{
        report.issue_count,
        report.issue_counts.sqlite,
        report.issue_counts.bound_store,
        report.issue_counts.object,
        report.issue_counts.chunk,
        report.issue_counts.vector,
        report.issue_counts.graph,
        report.severity_counts.errors,
        report.issues_truncated,
    });
    if (report.issue_counts.object != 0 or report.issue_counts.chunk != 0) {
        try stderr.writeAll("object corruption: detected\n");
    }
    if (report.issue_counts.vector != 0) {
        try stderr.writeAll("vector corruption: detected\n");
    }
    if (report.issue_counts.graph != 0) {
        try stderr.writeAll("graph corruption: detected\n");
    }
    for (report.issues) |issue| {
        try stderr.print("  area={s} kind={s} severity={s} detail={s}", .{
            diagnosticIssueAreaText(issue.area),
            issue.kind,
            issue.severity,
            issue.detail,
        });
        if (issue.object_id_hex) |value| try stderr.print(" object_id={s}", .{value});
        if (issue.chunk_hash_hex) |value| try stderr.print(" chunk_hash={s}", .{value});
        if (issue.collection_name) |value| try stderr.print(" collection={s}", .{value});
        if (issue.vector_id) |value| try stderr.print(" vector_id={s}", .{value});
        if (issue.graph_name) |value| try stderr.print(" graph={s}", .{value});
        if (issue.node_id) |value| try stderr.print(" node_id={s}", .{value});
        if (issue.edge_type) |value| try stderr.print(" edge_type={s}", .{value});
        try stderr.writeByte('\n');
    }
}

fn writeDeepCheckFailureJson(stderr: *std.Io.Writer, report: DiagnosticReport) !void {
    try stderr.writeAll("{\n");
    try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stderr.writeAll("  \"status\": \"error\",\n");
    try stderr.writeAll("  \"command\": \"check\",\n");
    try stderr.writeAll("  \"kind\": \"deep_check\",\n");
    try stderr.writeAll("  \"error\": \"corruption detected\",\n");
    try stderr.print("  \"issue_count\": {d},\n", .{report.issue_count});
    try stderr.writeAll("  \"issue_counts\": ");
    try writeDiagnosticIssueCountsJson(stderr, report.issue_counts);
    try stderr.writeAll(",\n  \"severity_counts\": ");
    try writeDiagnosticSeverityCountsJson(stderr, report.severity_counts);
    try stderr.print(",\n  \"issues_truncated\": {},\n", .{report.issues_truncated});
    try stderr.writeAll("  \"issues\": ");
    try writeDiagnosticIssuesJson(stderr, report.issues);
    try stderr.writeAll(",\n  \"suggested_actions\": ");
    try writeSuggestedActionsJson(stderr, "", true);
    try stderr.writeAll("\n}\n");
}

fn writeDoctorText(writer: *std.Io.Writer, source_path: []const u8, summary: DatabaseSummary, report: DiagnosticReport) !void {
    const has_issues = report.issue_count != 0;
    try writer.print(
        \\Zova doctor: {s}
        \\status: {s}
        \\quick_check: ok
        \\schema: ok
        \\objects_checked: {d}
        \\chunks_checked: {d}
        \\vectors_checked: {d}
        \\loose_chunks: {d}
        \\graphs_checked: {d}
        \\graph_nodes_checked: {d}
        \\graph_edges_checked: {d}
        \\user_tables: {d}
        \\private_tables: {d}
        \\issue_count: {d}
        \\sqlite_issues: {d}
        \\bound_store_issues: {d}
        \\object_issues: {d}
        \\chunk_issues: {d}
        \\vector_issues: {d}
        \\graph_issues: {d}
        \\error_issues: {d}
        \\issues_truncated: {}
        \\
    , .{
        source_path,
        if (has_issues) "needs_attention" else "ok",
        report.stats.objects,
        report.stats.chunks,
        report.stats.vectors,
        report.stats.loose_chunks,
        report.stats.graphs,
        report.stats.graph_nodes,
        report.stats.graph_edges,
        summary.user_table_count,
        summary.private_table_count,
        report.issue_count,
        report.issue_counts.sqlite,
        report.issue_counts.bound_store,
        report.issue_counts.object,
        report.issue_counts.chunk,
        report.issue_counts.vector,
        report.issue_counts.graph,
        report.severity_counts.errors,
        report.issues_truncated,
    });

    try writer.writeAll("issues:\n");
    if (report.issues.len == 0) {
        if (report.issue_count == 0) {
            try writer.writeAll("  none\n");
        } else {
            try writer.writeAll("  no issue examples shown\n");
        }
    } else {
        for (report.issues) |issue| {
            try writer.print("  area={s} kind={s} severity={s} detail={s}", .{
                diagnosticIssueAreaText(issue.area),
                issue.kind,
                issue.severity,
                issue.detail,
            });
            if (issue.object_id_hex) |value| try writer.print(" object_id={s}", .{value});
            if (issue.chunk_hash_hex) |value| try writer.print(" chunk_hash={s}", .{value});
            if (issue.collection_name) |value| try writer.print(" collection={s}", .{value});
            if (issue.vector_id) |value| try writer.print(" vector_id={s}", .{value});
            if (issue.graph_name) |value| try writer.print(" graph={s}", .{value});
            if (issue.node_id) |value| try writer.print(" node_id={s}", .{value});
            if (issue.edge_type) |value| try writer.print(" edge_type={s}", .{value});
            try writer.writeByte('\n');
        }
    }

    try writer.writeAll("suggested_actions:\n");
    try writeSuggestedActionsText(writer, source_path, has_issues);
    if (reportHasIssue(report, .bound_store, "missing_or_unreadable_store")) {
        try writer.print("  run zova object-store bind {s} <objects.zova>\n", .{source_path});
        try writer.print("  run zova vector-store bind {s} <vectors.zova>\n", .{source_path});
    }
}

fn writeDoctorJson(writer: *std.Io.Writer, source_path: []const u8, summary: DatabaseSummary, report: DiagnosticReport) !void {
    const has_issues = report.issue_count != 0;
    try writer.writeAll("{\n");
    try writer.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try writer.print("  \"status\": \"{s}\",\n", .{if (has_issues) "needs_attention" else "ok"});
    try writer.writeAll("  \"command\": \"doctor\",\n");
    try writer.writeAll("  \"source_path\": ");
    try writeJsonString(writer, source_path);
    try writer.print(
        \\,
        \\  "quick_check": "ok",
        \\  "schema": "ok",
        \\  "checked": {{
        \\    "objects": {d},
        \\    "chunks": {d},
        \\    "vectors": {d},
        \\    "loose_chunks": {d},
        \\    "graphs": {d},
        \\    "graph_nodes": {d},
        \\    "graph_edges": {d}
        \\  }},
        \\  "tables": {{
        \\    "user": {d},
        \\    "private": {d}
        \\  }},
        \\  "issue_count": {d},
        \\  "issue_counts":
    , .{
        report.stats.objects,
        report.stats.chunks,
        report.stats.vectors,
        report.stats.loose_chunks,
        report.stats.graphs,
        report.stats.graph_nodes,
        report.stats.graph_edges,
        summary.user_table_count,
        summary.private_table_count,
        report.issue_count,
    });
    try writer.writeByte(' ');
    try writeDiagnosticIssueCountsJson(writer, report.issue_counts);
    try writer.writeAll(",\n  \"severity_counts\": ");
    try writeDiagnosticSeverityCountsJson(writer, report.severity_counts);
    try writer.print(",\n  \"issues_truncated\": {},\n", .{report.issues_truncated});
    try writer.writeAll("  \"issues\": ");
    try writeDiagnosticIssuesJson(writer, report.issues);
    try writer.writeAll(",\n  \"suggested_actions\": ");
    try writeSuggestedActionsJson(writer, source_path, has_issues);
    try writer.writeAll("\n}\n");
}

fn writeSuggestedActionsText(writer: *std.Io.Writer, source_path: []const u8, has_issues: bool) !void {
    if (!has_issues) {
        try writer.writeAll("  no action needed\n");
        return;
    }
    try writer.writeAll("  restore from a recent backup if available\n");
    try writer.print("  run zova check --deep {s}\n", .{source_path});
    try writer.print("  run zova salvage --dry-run {s}\n", .{source_path});
    try writer.print("  run zova salvage {s} <destination.zova>\n", .{source_path});
}

fn writeSuggestedActionsJson(writer: *std.Io.Writer, source_path: []const u8, has_issues: bool) !void {
    _ = source_path;
    if (!has_issues) {
        try writer.writeAll("[\"no action needed\"]");
        return;
    }
    try writer.writeAll("[");
    try writeJsonString(writer, "restore from a recent backup if available");
    try writer.writeAll(", ");
    try writeJsonString(writer, "run zova check --deep <file.zova>");
    try writer.writeAll(", ");
    try writeJsonString(writer, "run zova salvage --dry-run <file.zova>");
    try writer.writeAll(", ");
    try writeJsonString(writer, "run zova salvage <file.zova> <destination.zova>");
    try writer.writeAll("]");
}

fn writeSalvageDryRunText(writer: *std.Io.Writer, source_path: []const u8, plan: SalvagePlan) !void {
    const has_issues = plan.report.issue_count != 0;
    try writer.print(
        \\Zova salvage dry-run: {s}
        \\status: {s}
        \\dry_run: true
        \\will_write_destination: false
        \\recoverability: {s}
        \\recoverable_user_tables: {d}
        \\recoverable_user_schema_objects: {d}
        \\recoverable_user_rows: {d}
        \\recoverable_objects: {d}
        \\recoverable_chunks: {d}
        \\recoverable_loose_chunks: {d}
        \\recoverable_vector_collections: {d}
        \\recoverable_vectors: {d}
        \\skipped_user_tables: {d}
        \\skipped_user_schema_objects: {d}
        \\skipped_user_rows: {d}
        \\skipped_objects: {d}
        \\skipped_chunks: {d}
        \\skipped_loose_chunks: {d}
        \\skipped_vector_collections: {d}
        \\skipped_vectors: {d}
        \\issue_count: {d}
        \\sqlite_issues: {d}
        \\bound_store_issues: {d}
        \\object_issues: {d}
        \\chunk_issues: {d}
        \\vector_issues: {d}
        \\error_issues: {d}
        \\issues_truncated: {}
        \\
    , .{
        source_path,
        if (has_issues) "needs_attention" else "ok",
        salvageRecoverabilityText(plan.recoverability),
        plan.recoverable.user_tables,
        plan.recoverable.user_schema_objects,
        plan.recoverable.user_rows,
        plan.recoverable.objects,
        plan.recoverable.chunks,
        plan.recoverable.loose_chunks,
        plan.recoverable.vector_collections,
        plan.recoverable.vectors,
        plan.skipped.user_tables,
        plan.skipped.user_schema_objects,
        plan.skipped.user_rows,
        plan.skipped.objects,
        plan.skipped.chunks,
        plan.skipped.loose_chunks,
        plan.skipped.vector_collections,
        plan.skipped.vectors,
        plan.report.issue_count,
        plan.report.issue_counts.sqlite,
        plan.report.issue_counts.bound_store,
        plan.report.issue_counts.object,
        plan.report.issue_counts.chunk,
        plan.report.issue_counts.vector,
        plan.report.severity_counts.errors,
        plan.report.issues_truncated,
    });

    try writer.writeAll("issues:\n");
    if (plan.report.issues.len == 0) {
        if (plan.report.issue_count == 0) {
            try writer.writeAll("  none\n");
        } else {
            try writer.writeAll("  no issue examples shown\n");
        }
    } else {
        for (plan.report.issues) |issue| {
            try writer.print("  area={s} kind={s} severity={s} detail={s}", .{
                diagnosticIssueAreaText(issue.area),
                issue.kind,
                issue.severity,
                issue.detail,
            });
            if (issue.object_id_hex) |value| try writer.print(" object_id={s}", .{value});
            if (issue.chunk_hash_hex) |value| try writer.print(" chunk_hash={s}", .{value});
            if (issue.collection_name) |value| try writer.print(" collection={s}", .{value});
            if (issue.vector_id) |value| try writer.print(" vector_id={s}", .{value});
            try writer.writeByte('\n');
        }
    }

    try writer.writeAll("suggested_actions:\n");
    try writeSalvageSuggestedActionsText(writer, source_path, has_issues);
}

fn writeSalvageDryRunJson(writer: *std.Io.Writer, source_path: []const u8, plan: SalvagePlan) !void {
    const has_issues = plan.report.issue_count != 0;
    try writer.writeAll("{\n");
    try writer.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try writer.print("  \"status\": \"{s}\",\n", .{if (has_issues) "needs_attention" else "ok"});
    try writer.writeAll("  \"command\": \"salvage\",\n");
    try writer.writeAll("  \"dry_run\": true,\n");
    try writer.writeAll("  \"will_write_destination\": false,\n");
    try writer.writeAll("  \"source_path\": ");
    try writeJsonString(writer, source_path);
    try writer.writeAll(",\n  \"recoverability\": ");
    try writeJsonString(writer, salvageRecoverabilityText(plan.recoverability));
    try writer.writeAll(",\n  \"recoverable\": ");
    try writeSalvageCountsJson(writer, plan.recoverable);
    try writer.writeAll(",\n  \"skipped\": ");
    try writeSalvageCountsJson(writer, plan.skipped);
    try writer.print(",\n  \"issue_count\": {d},\n", .{plan.report.issue_count});
    try writer.writeAll("  \"issue_counts\": ");
    try writeDiagnosticIssueCountsJson(writer, plan.report.issue_counts);
    try writer.writeAll(",\n  \"severity_counts\": ");
    try writeDiagnosticSeverityCountsJson(writer, plan.report.severity_counts);
    try writer.print(",\n  \"issues_truncated\": {},\n", .{plan.report.issues_truncated});
    try writer.writeAll("  \"issues\": ");
    try writeDiagnosticIssuesJson(writer, plan.report.issues);
    try writer.writeAll(",\n  \"suggested_actions\": ");
    try writeSalvageSuggestedActionsJson(writer, has_issues);
    try writer.writeAll("\n}\n");
}

fn writeSalvageExecutionText(
    writer: *std.Io.Writer,
    source_path: []const u8,
    destination_path: []const u8,
    result: SalvageExecutionResult,
) !void {
    try writer.print(
        \\Zova salvage: {s}
        \\status: {s}
        \\dry_run: false
        \\will_write_destination: true
        \\destination: {s}
        \\destination_verified: {}
        \\recoverability: {s}
        \\copied_user_tables: {d}
        \\copied_user_schema_objects: {d}
        \\copied_user_rows: {d}
        \\copied_objects: {d}
        \\copied_chunks: {d}
        \\copied_loose_chunks: {d}
        \\copied_vector_collections: {d}
        \\copied_vectors: {d}
        \\skipped_user_tables: {d}
        \\skipped_user_schema_objects: {d}
        \\skipped_user_rows: {d}
        \\skipped_objects: {d}
        \\skipped_chunks: {d}
        \\skipped_loose_chunks: {d}
        \\skipped_vector_collections: {d}
        \\skipped_vectors: {d}
        \\issue_count: {d}
        \\issues_truncated: {}
        \\
    , .{
        source_path,
        if (result.destination_verified) "ok" else "error",
        destination_path,
        result.destination_verified,
        salvageRecoverabilityText(result.plan.recoverability),
        result.copied.user_tables,
        result.copied.user_schema_objects,
        result.copied.user_rows,
        result.copied.objects,
        result.copied.chunks,
        result.copied.loose_chunks,
        result.copied.vector_collections,
        result.copied.vectors,
        result.plan.skipped.user_tables,
        result.plan.skipped.user_schema_objects,
        result.plan.skipped.user_rows,
        result.plan.skipped.objects,
        result.plan.skipped.chunks,
        result.plan.skipped.loose_chunks,
        result.plan.skipped.vector_collections,
        result.plan.skipped.vectors,
        result.plan.report.issue_count,
        result.plan.report.issues_truncated,
    });

    try writer.writeAll("issues:\n");
    if (result.plan.report.issues.len == 0) {
        if (result.plan.report.issue_count == 0) {
            try writer.writeAll("  none\n");
        } else {
            try writer.writeAll("  no issue examples shown\n");
        }
    } else {
        for (result.plan.report.issues) |issue| {
            try writer.print("  area={s} kind={s} severity={s} detail={s}", .{
                diagnosticIssueAreaText(issue.area),
                issue.kind,
                issue.severity,
                issue.detail,
            });
            if (issue.object_id_hex) |value| try writer.print(" object_id={s}", .{value});
            if (issue.chunk_hash_hex) |value| try writer.print(" chunk_hash={s}", .{value});
            if (issue.collection_name) |value| try writer.print(" collection={s}", .{value});
            if (issue.vector_id) |value| try writer.print(" vector_id={s}", .{value});
            try writer.writeByte('\n');
        }
    }

    try writer.writeAll("suggested_actions:\n");
    if (result.destination_verified) {
        try writer.writeAll("  run zova check --deep on the destination before replacing any live file\n");
    } else {
        try writer.writeAll("  restore from a recent backup if available\n");
        try writer.writeAll("  inspect the source with zova doctor before trying salvage again\n");
    }
}

fn writeSalvageExecutionJson(
    writer: *std.Io.Writer,
    source_path: []const u8,
    destination_path: []const u8,
    result: SalvageExecutionResult,
) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try writer.print("  \"status\": \"{s}\",\n", .{if (result.destination_verified) "ok" else "error"});
    try writer.writeAll("  \"command\": \"salvage\",\n");
    try writer.writeAll("  \"dry_run\": false,\n");
    try writer.writeAll("  \"will_write_destination\": true,\n");
    try writer.writeAll("  \"source_path\": ");
    try writeJsonString(writer, source_path);
    try writer.writeAll(",\n  \"destination_path\": ");
    try writeJsonString(writer, destination_path);
    try writer.print(",\n  \"destination_verified\": {},\n", .{result.destination_verified});
    try writer.writeAll("  \"recoverability\": ");
    try writeJsonString(writer, salvageRecoverabilityText(result.plan.recoverability));
    try writer.writeAll(",\n  \"copied\": ");
    try writeSalvageCountsJson(writer, result.copied);
    try writer.writeAll(",\n  \"recoverable\": ");
    try writeSalvageCountsJson(writer, result.plan.recoverable);
    try writer.writeAll(",\n  \"skipped\": ");
    try writeSalvageCountsJson(writer, result.plan.skipped);
    try writer.print(",\n  \"issue_count\": {d},\n", .{result.plan.report.issue_count});
    try writer.writeAll("  \"issue_counts\": ");
    try writeDiagnosticIssueCountsJson(writer, result.plan.report.issue_counts);
    try writer.writeAll(",\n  \"severity_counts\": ");
    try writeDiagnosticSeverityCountsJson(writer, result.plan.report.severity_counts);
    try writer.print(",\n  \"issues_truncated\": {},\n", .{result.plan.report.issues_truncated});
    try writer.writeAll("  \"issues\": ");
    try writeDiagnosticIssuesJson(writer, result.plan.report.issues);
    try writer.writeAll(",\n  \"suggested_actions\": ");
    if (result.destination_verified) {
        try writer.writeAll("[");
        try writeJsonString(writer, "run zova check --deep on the destination before replacing any live file");
        try writer.writeAll("]");
    } else {
        try writer.writeAll("[");
        try writeJsonString(writer, "restore from a recent backup if available");
        try writer.writeAll(", ");
        try writeJsonString(writer, "inspect the source with zova doctor before trying salvage again");
        try writer.writeAll("]");
    }
    try writer.writeAll("\n}\n");
}

fn writeSalvageCountsJson(writer: *std.Io.Writer, counts: SalvageCounts) !void {
    try writer.print(
        \\{{
        \\    "user_tables": {d},
        \\    "user_schema_objects": {d},
        \\    "user_rows": {d},
        \\    "graphs": {d},
        \\    "graph_nodes": {d},
        \\    "graph_edges": {d},
        \\    "objects": {d},
        \\    "chunks": {d},
        \\    "loose_chunks": {d},
        \\    "vector_collections": {d},
        \\    "vectors": {d}
        \\  }}
    , .{
        counts.user_tables,
        counts.user_schema_objects,
        counts.user_rows,
        counts.graphs,
        counts.graph_nodes,
        counts.graph_edges,
        counts.objects,
        counts.chunks,
        counts.loose_chunks,
        counts.vector_collections,
        counts.vectors,
    });
}

fn writeSalvageSuggestedActionsText(writer: *std.Io.Writer, source_path: []const u8, has_issues: bool) !void {
    if (!has_issues) {
        try writer.writeAll("  source appears recoverable\n");
        try writer.writeAll("  no destination was written\n");
        try writer.print("  run: zova salvage {s} <destination.zova>\n", .{source_path});
        return;
    }
    try writer.writeAll("  restore from a recent backup if available\n");
    try writer.print("  review this dry-run report before salvaging {s}\n", .{source_path});
    try writer.print("  run: zova salvage {s} <destination.zova>\n", .{source_path});
}

fn writeSalvageSuggestedActionsJson(writer: *std.Io.Writer, has_issues: bool) !void {
    if (!has_issues) {
        try writer.writeAll("[");
        try writeJsonString(writer, "source appears recoverable");
        try writer.writeAll(", ");
        try writeJsonString(writer, "no destination was written");
        try writer.writeAll(", ");
        try writeJsonString(writer, "run zova salvage <source.zova> <destination.zova> to create a recovery copy");
        try writer.writeAll("]");
        return;
    }
    try writer.writeAll("[");
    try writeJsonString(writer, "restore from a recent backup if available");
    try writer.writeAll(", ");
    try writeJsonString(writer, "review this dry-run report before salvaging");
    try writer.writeAll(", ");
    try writeJsonString(writer, "run zova salvage <source.zova> <destination.zova> to copy recoverable data into a new file");
    try writer.writeAll("]");
}

fn salvageRecoverabilityText(value: SalvageRecoverability) []const u8 {
    return switch (value) {
        .recoverable => "recoverable",
        .partially_recoverable => "partially_recoverable",
        .not_recoverable => "not_recoverable",
        .unknown => "unknown",
    };
}

fn writeDiagnosticIssueCountsJson(writer: *std.Io.Writer, counts: DiagnosticIssueCounts) !void {
    try writer.print(
        \\{{
        \\    "sqlite": {d},
        \\    "bound_store": {d},
        \\    "object": {d},
        \\    "chunk": {d},
        \\    "vector": {d},
        \\    "graph": {d}
        \\  }}
    , .{ counts.sqlite, counts.bound_store, counts.object, counts.chunk, counts.vector, counts.graph });
}

fn writeDiagnosticSeverityCountsJson(writer: *std.Io.Writer, counts: DiagnosticSeverityCounts) !void {
    try writer.print(
        \\{{
        \\    "info": {d},
        \\    "warning": {d},
        \\    "error": {d},
        \\    "fatal": {d}
        \\  }}
    , .{ counts.info, counts.warning, counts.errors, counts.fatal });
}

fn writeDiagnosticIssuesJson(writer: *std.Io.Writer, issues: []const DiagnosticIssue) !void {
    try writer.writeAll("[");
    for (issues, 0..) |issue, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll("{\"area\": ");
        try writeJsonString(writer, diagnosticIssueAreaText(issue.area));
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
        if (issue.graph_name) |value| {
            try writer.writeAll(", \"graph\": ");
            try writeJsonString(writer, value);
        }
        if (issue.node_id) |value| {
            try writer.writeAll(", \"node_id\": ");
            try writeJsonString(writer, value);
        }
        if (issue.edge_type) |value| {
            try writer.writeAll(", \"edge_type\": ");
            try writeJsonString(writer, value);
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn diagnosticIssueAreaText(area: DiagnosticIssueArea) []const u8 {
    return switch (area) {
        .sqlite => "sqlite",
        .bound_store => "bound_store",
        .object => "object",
        .chunk => "chunk",
        .vector => "vector",
        .graph => "graph",
    };
}

fn reportHasIssue(report: DiagnosticReport, area: DiagnosticIssueArea, kind: []const u8) bool {
    for (report.issues) |issue| {
        if (issue.area == area and std.mem.eql(u8, issue.kind, kind)) return true;
    }
    return false;
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

fn writeJsonStringFormat(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) !void {
    var buffer: [std.fs.max_path_bytes * 3]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, format, args) catch return error.NoSpaceLeft;
    try writeJsonString(writer, value);
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

fn runDiagnostics(allocator: std.mem.Allocator, db: *zova.Database, issue_limit: usize) !DiagnosticReport {
    var issues: std.ArrayList(DiagnosticIssue) = .empty;
    errdefer {
        for (issues.items) |*issue| issue.deinit(allocator);
        issues.deinit(allocator);
    }

    var report = DiagnosticReport{ .issue_limit = issue_limit };
    try validateBoundStores(allocator, db, &report, &issues);
    try validateObjects(allocator, db, &report, &issues);
    try validateLooseChunks(allocator, db, &report, &issues);
    try validateVectors(allocator, db, &report, &issues);
    try validateGraphs(allocator, db, &report, &issues);
    report.issues = try issues.toOwnedSlice(allocator);
    return report;
}

fn validateBoundStores(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    if (try db.boundObjectStore(allocator)) |info_value| {
        var info = info_value;
        defer info.deinit(allocator);
        try validateOneBoundStore(
            allocator,
            report,
            issues,
            info.path,
            "object_store",
            info.store_id,
            info.bound_set_id,
            "object_epoch",
            "missing_object_epoch",
            "object_epoch_unreadable",
            "object_epoch_invalid",
            "object_epoch_mismatch",
            info.object_epoch,
        );
    }

    if (try db.boundVectorStore(allocator)) |info_value| {
        var info = info_value;
        defer info.deinit(allocator);
        try validateOneBoundStore(
            allocator,
            report,
            issues,
            info.path,
            "vector_store",
            info.store_id,
            info.bound_set_id,
            "vector_epoch",
            "missing_vector_epoch",
            "vector_epoch_unreadable",
            "vector_epoch_invalid",
            "vector_epoch_mismatch",
            info.vector_epoch,
        );
    }
}

fn validateOneBoundStore(
    allocator: std.mem.Allocator,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    path: []const u8,
    expected_role: []const u8,
    expected_store_id: []const u8,
    expected_bound_set_id: []const u8,
    epoch_key: []const u8,
    missing_epoch_kind: []const u8,
    unreadable_epoch_kind: []const u8,
    invalid_epoch_kind: []const u8,
    mismatch_epoch_kind: []const u8,
    expected_epoch: u64,
) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var store = sqlite.Database.openWithFlags(path_z, .read_only) catch |err| {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "missing_or_unreadable_store", @errorName(err), null, null, null, null);
        return;
    };
    defer store.deinit();

    const magic = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, "magic", "missing_store_magic", "NotZovaDatabase", "store_magic_unreadable")) orelse return;
    defer allocator.free(magic);
    if (!std.mem.eql(u8, magic, "zova")) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "store_magic_mismatch", "NotZovaDatabase", null, null, null, null);
        return;
    }

    const format_version = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, "format_version", "missing_store_format_version", "UnsupportedZovaVersion", "store_format_version_unreadable")) orelse return;
    defer allocator.free(format_version);
    if (!std.mem.eql(u8, format_version, "4")) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "store_format_version_mismatch", "UnsupportedZovaVersion", null, null, null, null);
        return;
    }

    const role = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, "store_role", "missing_store_role", "BoundStoreInvalid", "store_role_unreadable")) orelse return;
    defer allocator.free(role);
    if (!std.mem.eql(u8, role, expected_role)) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "store_role_mismatch", "BoundStoreInvalid", null, null, null, null);
        return;
    }

    const store_id = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, "store_id", "missing_store_id", "BoundStoreInvalid", "store_id_unreadable")) orelse return;
    defer allocator.free(store_id);
    if (!std.mem.eql(u8, store_id, expected_store_id)) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "store_id_mismatch", "BoundStoreInvalid", null, null, null, null);
        return;
    }

    const bound_set_id = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, "bound_set_id", "missing_bound_set_id", "BoundStoreInvalid", "bound_set_id_unreadable")) orelse return;
    defer allocator.free(bound_set_id);
    if (!std.mem.eql(u8, bound_set_id, expected_bound_set_id)) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "bound_set_id_mismatch", "BoundStoreInvalid", null, null, null, null);
        return;
    }

    const epoch_text = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, epoch_key, missing_epoch_kind, "BoundStoreInvalid", unreadable_epoch_kind)) orelse return;
    defer allocator.free(epoch_text);
    const epoch = std.fmt.parseInt(u64, epoch_text, 10) catch {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, invalid_epoch_kind, "BoundStoreInvalid", null, null, null, null);
        return;
    };
    if (epoch != expected_epoch) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, mismatch_epoch_kind, "BoundStoreInvalid", null, null, null, null);
    }
}

fn requiredBoundStoreMetaValueAlloc(
    allocator: std.mem.Allocator,
    store: *sqlite.Database,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    key: []const u8,
    missing_kind: []const u8,
    missing_detail: []const u8,
    unreadable_kind: []const u8,
) !?[]u8 {
    const value = sqliteMetaValueAlloc(allocator, store, key) catch |err| {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, unreadable_kind, @errorName(err), null, null, null, null);
        return null;
    };
    if (value) |actual| return actual;

    try addDiagnosticIssue(allocator, report, issues, .bound_store, missing_kind, missing_detail, null, null, null, null);
    return null;
}

fn diagnosticErrorReport(
    allocator: std.mem.Allocator,
    issue_limit: usize,
    area: DiagnosticIssueArea,
    kind: []const u8,
    detail: []const u8,
) !DiagnosticReport {
    var issues: std.ArrayList(DiagnosticIssue) = .empty;
    errdefer {
        for (issues.items) |*issue| issue.deinit(allocator);
        issues.deinit(allocator);
    }

    var report = DiagnosticReport{ .issue_limit = issue_limit };
    try addDiagnosticIssue(allocator, &report, &issues, area, kind, detail, null, null, null, null);
    report.issues = try issues.toOwnedSlice(allocator);
    return report;
}

fn buildSalvagePlan(summary: DatabaseSummary, report: DiagnosticReport) SalvagePlan {
    var recoverable = SalvageCounts{
        .user_tables = summary.user_table_count,
        .objects = summary.object_count,
        .chunks = summary.chunk_count,
        .loose_chunks = summary.loose_chunk_count,
        .vector_collections = summary.vector_collection_count,
        .vectors = summary.vector_count,
        .graphs = report.stats.graphs,
        .graph_nodes = report.stats.graph_nodes,
        .graph_edges = report.stats.graph_edges,
    };
    const skipped = SalvageCounts{
        .objects = @min(summary.object_count, report.issue_counts.object),
        .chunks = report.issue_counts.chunk,
        .vectors = @min(summary.vector_count, report.issue_counts.vector),
        .graph_edges = @min(report.stats.graph_edges, report.issue_counts.graph),
    };

    recoverable.objects = subtractClamped(recoverable.objects, skipped.objects);
    recoverable.chunks = subtractClamped(recoverable.chunks, skipped.chunks);
    recoverable.vectors = subtractClamped(recoverable.vectors, skipped.vectors);
    recoverable.graph_edges = subtractClamped(recoverable.graph_edges, skipped.graph_edges);

    const recoverability: SalvageRecoverability = if (report.issue_counts.sqlite != 0)
        .unknown
    else if (report.issue_count == 0)
        .recoverable
    else if (hasRecoverableData(recoverable))
        .partially_recoverable
    else
        .not_recoverable;

    return .{
        .report = report,
        .recoverability = recoverability,
        .recoverable = recoverable,
        .skipped = skipped,
    };
}

fn executeSalvage(
    allocator: std.mem.Allocator,
    source: *zova.Database,
    destination_path: [:0]const u8,
    plan: SalvagePlan,
) !SalvageExecutionResult {
    if (plan.report.issue_counts.sqlite != 0) return error.Corrupt;

    var destination = try zova.Database.create(destination_path);
    defer destination.deinit();

    var result_plan = plan;
    var copied = SalvageCounts{};
    const user_sql = try copyUserSql(allocator, source, &destination);
    copied.user_tables = user_sql.copied_tables;
    copied.user_schema_objects = user_sql.copied_schema_objects;
    copied.user_rows = user_sql.copied_rows;
    result_plan.skipped.user_tables += user_sql.skipped_tables;
    result_plan.skipped.user_schema_objects += user_sql.skipped_schema_objects;
    result_plan.skipped.user_rows += user_sql.skipped_rows;
    result_plan.recoverable.user_tables = copied.user_tables;
    result_plan.recoverable.user_schema_objects = copied.user_schema_objects;
    result_plan.recoverable.user_rows = copied.user_rows;
    copied.objects = try copyValidObjects(allocator, source, &destination);
    copied.loose_chunks = try copyValidLooseChunks(allocator, source, &destination);
    try copyValidVectors(allocator, source, &destination, &copied);
    try copyValidGraphs(allocator, source, &destination, &copied);
    copied.chunks = try scalarU64(&destination, "select count(*) from _zova_chunks");

    const destination_verified = try verifySalvageDestination(allocator, &destination);
    return .{
        .plan = result_plan,
        .copied = copied,
        .destination_verified = destination_verified,
    };
}

fn copyUserSql(allocator: std.mem.Allocator, source: *zova.Database, destination: *zova.Database) !UserSqlCopyResult {
    var tables = try source.prepare(
        \\select name, sql
        \\from sqlite_master
        \\where type = 'table'
        \\  and sql is not null
        \\  and lower(substr(name, 1, 6)) != '_zova_'
        \\  and lower(substr(name, 1, 7)) != 'sqlite_'
        \\order by name asc
    );
    defer tables.deinit();

    var result = UserSqlCopyResult{};
    while ((try tables.step()) == .row) {
        const table_name = try allocator.dupe(u8, tables.columnText(0));
        defer allocator.free(table_name);
        const schema_sql = try allocator.dupeZ(u8, tables.columnText(1));
        defer allocator.free(schema_sql);
        const source_row_count = countRowsInUserTable(allocator, source, table_name) catch 0;

        destination.exec(schema_sql) catch {
            result.skipped_tables += 1;
            result.skipped_rows += source_row_count;
            continue;
        };
        const rows = copyUserTableRows(allocator, source, destination, table_name, source_row_count) catch {
            result.skipped_tables += 1;
            result.skipped_rows += source_row_count;
            continue;
        };
        result.copied_rows += rows.copied_rows;
        result.skipped_rows += rows.skipped_rows;
        if (rows.skipped_rows != 0) result.skipped_tables += 1;
        result.copied_tables += 1;
    }

    const schema_objects = try copyUserSchemaObjects(allocator, source, destination);
    result.copied_schema_objects = schema_objects.copied_schema_objects;
    result.skipped_schema_objects = schema_objects.skipped_schema_objects;
    return result;
}

fn copyUserSchemaObjects(allocator: std.mem.Allocator, source: *zova.Database, destination: *zova.Database) !UserSqlCopyResult {
    var objects = try source.prepare(
        \\select sql
        \\from sqlite_master
        \\where type in ('index', 'view', 'trigger')
        \\  and sql is not null
        \\  and lower(substr(name, 1, 6)) != '_zova_'
        \\  and lower(substr(name, 1, 7)) != 'sqlite_'
        \\  and lower(substr(tbl_name, 1, 6)) != '_zova_'
        \\  and lower(substr(tbl_name, 1, 7)) != 'sqlite_'
        \\order by
        \\  case type when 'index' then 0 when 'view' then 1 else 2 end,
        \\  name asc
    );
    defer objects.deinit();

    var result = UserSqlCopyResult{};
    while ((try objects.step()) == .row) {
        const schema_sql = try allocator.dupeZ(u8, objects.columnText(0));
        defer allocator.free(schema_sql);
        destination.exec(schema_sql) catch {
            result.skipped_schema_objects += 1;
            continue;
        };
        result.copied_schema_objects += 1;
    }
    return result;
}

fn countUserSchemaObjects(db: *zova.Database) !u64 {
    return try scalarU64(db,
        \\select count(*)
        \\from sqlite_master
        \\where type in ('index', 'view', 'trigger')
        \\  and sql is not null
        \\  and lower(substr(name, 1, 6)) != '_zova_'
        \\  and lower(substr(name, 1, 7)) != 'sqlite_'
        \\  and lower(substr(tbl_name, 1, 6)) != '_zova_'
        \\  and lower(substr(tbl_name, 1, 7)) != 'sqlite_'
    );
}

fn countUserRows(allocator: std.mem.Allocator, db: *zova.Database) !u64 {
    var tables = try db.prepare(
        \\select name
        \\from sqlite_master
        \\where type = 'table'
        \\  and sql is not null
        \\  and lower(substr(name, 1, 6)) != '_zova_'
        \\  and lower(substr(name, 1, 7)) != 'sqlite_'
        \\order by name asc
    );
    defer tables.deinit();

    var count: u64 = 0;
    while ((try tables.step()) == .row) {
        const table_name = try allocator.dupe(u8, tables.columnText(0));
        defer allocator.free(table_name);
        count += countRowsInUserTable(allocator, db, table_name) catch 0;
    }
    return count;
}

fn countRowsInUserTable(allocator: std.mem.Allocator, db: *zova.Database, table_name: []const u8) !u64 {
    const quoted_name = try quoteSqlIdentifierAlloc(allocator, table_name);
    defer allocator.free(quoted_name);

    const sql = try std.fmt.allocPrintSentinel(allocator, "select count(*) from {s}", .{quoted_name}, 0);
    defer allocator.free(sql);

    return try scalarU64(db, sql);
}

fn copyUserTableRows(
    allocator: std.mem.Allocator,
    source: *zova.Database,
    destination: *zova.Database,
    table_name: []const u8,
    source_row_count: u64,
) !UserSqlRowCopyResult {
    const quoted_name = try quoteSqlIdentifierAlloc(allocator, table_name);
    defer allocator.free(quoted_name);

    const select_sql = try std.fmt.allocPrintSentinel(allocator, "select * from {s}", .{quoted_name}, 0);
    defer allocator.free(select_sql);

    var read_rows = try source.prepare(select_sql);
    defer read_rows.deinit();

    const column_count = read_rows.columnCount();
    const insert_sql = try buildInsertAllSql(allocator, quoted_name, @intCast(column_count));
    defer allocator.free(insert_sql);

    var insert_row = destination.prepare(insert_sql) catch return .{ .skipped_rows = source_row_count };
    defer insert_row.deinit();

    var result = UserSqlRowCopyResult{};
    while ((try read_rows.step()) == .row) {
        var column_index: c_int = 0;
        var row_failed = false;
        while (column_index < column_count) : (column_index += 1) {
            const bind_index: c_int = column_index + 1;
            const bind_result = switch (read_rows.columnType(column_index)) {
                .integer => insert_row.bindInt64(bind_index, read_rows.columnInt64(column_index)),
                .float => insert_row.bindDouble(bind_index, read_rows.columnDouble(column_index)),
                .text => insert_row.bindText(bind_index, read_rows.columnText(column_index)),
                .blob => insert_row.bindBlob(bind_index, read_rows.columnBlob(column_index)),
                .null => insert_row.bindNull(bind_index),
            };
            bind_result catch {
                row_failed = true;
                break;
            };
        }
        if (!row_failed) {
            expectDone(&insert_row) catch {
                row_failed = true;
            };
        }
        if (row_failed) {
            result.skipped_rows += 1;
        } else {
            result.copied_rows += 1;
        }
        insert_row.reset() catch {};
        insert_row.clearBindings() catch {};
    }
    return result;
}

fn copyValidObjects(allocator: std.mem.Allocator, source: *zova.Database, destination: *zova.Database) !u64 {
    var objects = try source.prepare("select object_id from _zova_objects order by hex(object_id)");
    defer objects.deinit();

    var copied: u64 = 0;
    while ((try objects.step()) == .row) {
        const raw_id = objects.columnBlob(0);
        if (raw_id.len != @sizeOf(zova.ObjectId)) continue;

        var id: zova.ObjectId = undefined;
        @memcpy(&id, raw_id);
        var object = source.getObject(allocator, id) catch continue;

        const copied_id = destination.putObject(object.bytes) catch {
            object.deinit(allocator);
            continue;
        };
        object.deinit(allocator);
        if (std.mem.eql(u8, copied_id[0..], id[0..])) copied += 1;
    }
    return copied;
}

fn copyValidLooseChunks(allocator: std.mem.Allocator, source: *zova.Database, destination: *zova.Database) !u64 {
    var chunks = try source.prepare(
        \\select c.chunk_hash
        \\from _zova_chunks c
        \\where not exists (
        \\  select 1 from _zova_object_chunks oc where oc.chunk_hash = c.chunk_hash
        \\)
        \\order by hex(c.chunk_hash)
    );
    defer chunks.deinit();

    var copied: u64 = 0;
    while ((try chunks.step()) == .row) {
        const raw_hash = chunks.columnBlob(0);
        if (raw_hash.len != @sizeOf(zova.ObjectChunkId)) continue;

        var hash: zova.ObjectChunkId = undefined;
        @memcpy(&hash, raw_hash);
        var chunk = source.getObjectChunk(allocator, hash) catch continue;

        destination.putObjectChunk(hash, chunk.bytes) catch {
            chunk.deinit(allocator);
            continue;
        };
        chunk.deinit(allocator);
        copied += 1;
    }
    return copied;
}

fn copyValidVectors(
    allocator: std.mem.Allocator,
    source: *zova.Database,
    destination: *zova.Database,
    copied: *SalvageCounts,
) !void {
    var collections = try source.listVectorCollections(allocator);
    defer collections.deinit(allocator);

    for (collections.items) |collection| {
        destination.createVectorCollection(collection.name, .{
            .dimensions = collection.dimensions,
            .metric = collection.metric,
        }) catch continue;
        copied.vector_collections += 1;

        var vectors = try source.prepare(
            \\select vector_id
            \\from _zova_vectors
            \\where collection_name = ?
            \\order by vector_id asc
        );
        defer vectors.deinit();
        try vectors.bindText(1, collection.name);

        while ((try vectors.step()) == .row) {
            const vector_id = try allocator.dupe(u8, vectors.columnText(0));

            var vector = source.getVector(allocator, collection.name, vector_id) catch {
                allocator.free(vector_id);
                continue;
            };

            destination.putVector(collection.name, vector.id, vector.values) catch {
                vector.deinit(allocator);
                allocator.free(vector_id);
                continue;
            };
            vector.deinit(allocator);
            allocator.free(vector_id);
            copied.vectors += 1;
        }
    }
}

fn copyValidGraphs(
    allocator: std.mem.Allocator,
    source: *zova.Database,
    destination: *zova.Database,
    copied: *SalvageCounts,
) !void {
    _ = allocator;

    var graphs = try source.prepare("select name from _zova_graphs order by created_order, name");
    defer graphs.deinit();
    while ((try graphs.step()) == .row) {
        const graph_name = graphs.columnText(0);
        if (!isValidGraphAsciiName(graph_name, 128)) continue;
        destination.createGraph(graph_name) catch continue;
        copied.graphs += 1;
    }

    var nodes = try source.prepare(
        \\select graph_name, node_id, kind, target_type, target_namespace, target_ref
        \\from _zova_graph_nodes
        \\order by created_order, graph_name, node_id
    );
    defer nodes.deinit();
    while ((try nodes.step()) == .row) {
        const graph_name = nodes.columnText(0);
        const node_id = nodes.columnText(1);
        const kind = nodes.columnText(2);
        const target_type_text = nodes.columnText(3);
        if (!isValidGraphAsciiName(graph_name, 128)) continue;
        if (!isValidGraphNodeId(node_id)) continue;
        if (!isValidGraphAsciiName(kind, 128)) continue;
        const target_type = graphTargetTypeFromText(target_type_text) orelse continue;
        const target_namespace = if (nodes.columnType(4) == .null) null else nodes.columnText(4);
        const target_ref = if (nodes.columnType(5) == .null) null else nodes.columnText(5);
        if (target_namespace) |value| {
            if (!isValidGraphOptionalText(value)) continue;
        }
        if (target_ref) |value| {
            if (!isValidGraphOptionalText(value)) continue;
        }
        if (!graphTargetReferenceAvailable(destination, target_type, target_namespace, target_ref)) continue;
        destination.putGraphNode(.{
            .graph_name = graph_name,
            .node_id = node_id,
            .kind = kind,
            .target_type = target_type,
            .target_namespace = target_namespace,
            .target_ref = target_ref,
        }) catch continue;
        copied.graph_nodes += 1;
    }

    var edges = try source.prepare(
        \\select graph_name, from_node_id, edge_type, to_node_id
        \\from _zova_graph_edges
        \\order by created_order, graph_name, from_node_id, edge_type, to_node_id
    );
    defer edges.deinit();
    while ((try edges.step()) == .row) {
        const graph_name = edges.columnText(0);
        const from_node_id = edges.columnText(1);
        const edge_type = edges.columnText(2);
        const to_node_id = edges.columnText(3);
        if (!isValidGraphAsciiName(graph_name, 128)) continue;
        if (!isValidGraphNodeId(from_node_id)) continue;
        if (!isValidGraphAsciiName(edge_type, 128)) continue;
        if (!isValidGraphNodeId(to_node_id)) continue;
        destination.putGraphEdge(.{
            .graph_name = graph_name,
            .from_node_id = from_node_id,
            .edge_type = edge_type,
            .to_node_id = to_node_id,
        }) catch continue;
        copied.graph_edges += 1;
    }
}

fn graphTargetReferenceAvailable(
    db: *zova.Database,
    target_type: zova.GraphTargetType,
    target_namespace: ?[]const u8,
    target_ref: ?[]const u8,
) bool {
    return switch (target_type) {
        .object => {
            const ref = target_ref orelse return false;
            const id = parseHex32(ref) catch return false;
            return db.hasObject(id) catch false;
        },
        .object_chunk => {
            const ref = target_ref orelse return false;
            const id = parseHex32(ref) catch return false;
            return db.hasObjectChunk(id) catch false;
        },
        .vector => {
            const collection = target_namespace orelse return false;
            const vector_id = target_ref orelse return false;
            return db.hasVector(collection, vector_id) catch false;
        },
        else => true,
    };
}

fn verifySalvageDestination(allocator: std.mem.Allocator, destination: *zova.Database) !bool {
    quickCheck(destination) catch return false;
    var report = runDiagnostics(allocator, destination, 0) catch return false;
    defer report.deinit(allocator);
    return report.issue_count == 0;
}

fn quoteSqlIdentifierAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var quote_count: usize = 0;
    for (name) |byte| {
        if (byte == '"') quote_count += 1;
    }

    const out = try allocator.alloc(u8, name.len + quote_count + 2);
    var index: usize = 0;
    out[index] = '"';
    index += 1;
    for (name) |byte| {
        out[index] = byte;
        index += 1;
        if (byte == '"') {
            out[index] = '"';
            index += 1;
        }
    }
    out[index] = '"';
    return out;
}

fn buildInsertAllSql(allocator: std.mem.Allocator, quoted_name: []const u8, column_count: usize) ![:0]u8 {
    if (column_count == 0) {
        return std.fmt.allocPrintSentinel(allocator, "insert into {s} default values", .{quoted_name}, 0);
    }

    const placeholders_len = column_count + (column_count - 1) * 2;
    const placeholders = try allocator.alloc(u8, placeholders_len);
    defer allocator.free(placeholders);

    var index: usize = 0;
    for (0..column_count) |column_index| {
        if (column_index != 0) {
            placeholders[index] = ',';
            placeholders[index + 1] = ' ';
            index += 2;
        }
        placeholders[index] = '?';
        index += 1;
    }

    return std.fmt.allocPrintSentinel(allocator, "insert into {s} values ({s})", .{ quoted_name, placeholders }, 0);
}

fn subtractClamped(value: u64, amount: u64) u64 {
    return if (amount >= value) 0 else value - amount;
}

fn hasRecoverableData(counts: SalvageCounts) bool {
    return counts.user_tables != 0 or
        counts.user_schema_objects != 0 or
        counts.user_rows != 0 or
        counts.graphs != 0 or
        counts.graph_nodes != 0 or
        counts.graph_edges != 0 or
        counts.objects != 0 or
        counts.chunks != 0 or
        counts.loose_chunks != 0 or
        counts.vector_collections != 0 or
        counts.vectors != 0;
}

fn validateObjects(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    const prefix = diagnosticObjectSchemaPrefix(db);
    const sql = try std.fmt.allocPrintSentinel(allocator, "select object_id from {s}_zova_objects order by hex(object_id)", .{prefix}, 0);
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const raw_id = stmt.columnBlob(0);
        if (raw_id.len != @sizeOf(zova.ObjectId)) {
            try addDiagnosticIssue(allocator, report, issues, .object, "object_id_shape", "ObjectCorrupt", raw_id, null, null, null);
            continue;
        }
        var id: zova.ObjectId = undefined;
        @memcpy(&id, raw_id);
        report.stats.objects += 1;

        var manifest = db.objectManifest(allocator, id) catch |err| {
            try addMissingManifestChunkIssues(allocator, db, report, issues, id);
            try addDiagnosticIssue(allocator, report, issues, .object, "object_manifest", @errorName(err), id[0..], null, null, null);
            continue;
        };
        defer manifest.deinit(allocator);
        for (manifest.chunks) |chunk| {
            report.stats.chunks += 1;
            var chunk_data = db.getObjectChunk(allocator, chunk.hash) catch |err| {
                try addDiagnosticIssue(allocator, report, issues, .chunk, "chunk_integrity", @errorName(err), id[0..], chunk.hash[0..], null, null);
                continue;
            };
            chunk_data.deinit(allocator);
        }

        var object = db.getObject(allocator, id) catch |err| {
            try addDiagnosticIssue(allocator, report, issues, .object, "object_integrity", @errorName(err), id[0..], null, null, null);
            continue;
        };
        object.deinit(allocator);
    }
}

fn addMissingManifestChunkIssues(
    allocator: std.mem.Allocator,
    db: *zova.Database,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    object_id: zova.ObjectId,
) !void {
    const prefix = diagnosticObjectSchemaPrefix(db);
    const sql = try std.fmt.allocPrintSentinel(allocator,
        \\select oc.chunk_hash
        \\from {s}_zova_object_chunks oc
        \\left join {s}_zova_chunks c on c.chunk_hash = oc.chunk_hash
        \\where oc.object_id = ?
        \\  and c.chunk_hash is null
        \\order by oc.chunk_index asc
    , .{ prefix, prefix }, 0);
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try stmt.bindBlob(1, &object_id);

    while ((try stmt.step()) == .row) {
        const raw_hash = stmt.columnBlob(0);
        const kind: []const u8 = if (raw_hash.len == @sizeOf(zova.ObjectChunkId)) "missing_chunk" else "missing_chunk_id_shape";
        const detail: []const u8 = if (raw_hash.len == @sizeOf(zova.ObjectChunkId)) "ObjectChunkNotFound" else "ObjectCorrupt";
        try addDiagnosticIssue(allocator, report, issues, .chunk, kind, detail, object_id[0..], raw_hash, null, null);
    }
}

fn validateLooseChunks(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    const prefix = diagnosticObjectSchemaPrefix(db);
    const sql = try std.fmt.allocPrintSentinel(allocator,
        \\select c.chunk_hash
        \\from {s}_zova_chunks c
        \\where not exists (
        \\  select 1 from {s}_zova_object_chunks oc where oc.chunk_hash = c.chunk_hash
        \\)
        \\order by hex(c.chunk_hash)
    , .{ prefix, prefix }, 0);
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const raw_hash = stmt.columnBlob(0);
        if (raw_hash.len != @sizeOf(zova.ObjectChunkId)) {
            try addDiagnosticIssue(allocator, report, issues, .chunk, "loose_chunk_id_shape", "ObjectCorrupt", null, raw_hash, null, null);
            continue;
        }
        var hash: zova.ObjectChunkId = undefined;
        @memcpy(&hash, raw_hash);
        report.stats.loose_chunks += 1;

        var chunk = db.getObjectChunk(allocator, hash) catch |err| {
            try addDiagnosticIssue(allocator, report, issues, .chunk, "loose_chunk_integrity", @errorName(err), null, hash[0..], null, null);
            continue;
        };
        chunk.deinit(allocator);
    }
}

fn diagnosticObjectSchemaPrefix(db: *zova.Database) []const u8 {
    var stmt = db.prepare("select 1 from object_store.sqlite_master limit 1") catch return "";
    defer stmt.deinit();
    return "object_store.";
}

fn diagnosticVectorSchemaPrefix(db: *zova.Database) []const u8 {
    var stmt = db.prepare("select 1 from vector_store.sqlite_master limit 1") catch return "";
    defer stmt.deinit();
    return "vector_store.";
}

fn validateVectors(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    const prefix = diagnosticVectorSchemaPrefix(db);
    const sql = try std.fmt.allocPrintSentinel(allocator,
        \\select collection_name, vector_id
        \\from {s}_zova_vectors
        \\order by collection_name, vector_id
    , .{prefix}, 0);
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const collection_name = stmt.columnText(0);
        const vector_id = stmt.columnText(1);
        report.stats.vectors += 1;
        var vector = db.getVector(allocator, collection_name, vector_id) catch |err| {
            try addDiagnosticIssue(allocator, report, issues, .vector, "vector_integrity", @errorName(err), null, null, collection_name, vector_id);
            continue;
        };
        const collection = db.vectorCollectionInfo(allocator, collection_name) catch |err| {
            vector.deinit(allocator);
            try addDiagnosticIssue(allocator, report, issues, .vector, "vector_integrity", @errorName(err), null, null, collection_name, vector_id);
            continue;
        };
        var mutable_collection = collection;
        defer mutable_collection.deinit(allocator);
        if (mutable_collection.metric == .cosine) {
            var norm_squared: f32 = 0;
            for (vector.values) |value| norm_squared += value * value;
            if (norm_squared == 0) {
                vector.deinit(allocator);
                try addDiagnosticIssue(allocator, report, issues, .vector, "vector_integrity", @errorName(error.VectorCorrupt), null, null, collection_name, vector_id);
                continue;
            }
        }
        vector.deinit(allocator);
    }
}

fn validateGraphs(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    var graphs = try db.prepare("select name from _zova_graphs order by name");
    defer graphs.deinit();
    while ((try graphs.step()) == .row) {
        const graph_name = graphs.columnText(0);
        report.stats.graphs += 1;
        if (!isValidGraphAsciiName(graph_name, 128)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "graph_name_invalid", @errorName(error.GraphInvalid), graph_name, null, null);
        }
    }

    var nodes = try db.prepare(
        \\select graph_name, node_id, kind, target_type, target_namespace, target_ref
        \\from _zova_graph_nodes
        \\order by graph_name, node_id
    );
    defer nodes.deinit();
    while ((try nodes.step()) == .row) {
        const graph_name = nodes.columnText(0);
        const node_id = nodes.columnText(1);
        const kind = nodes.columnText(2);
        const target_type = nodes.columnText(3);
        report.stats.graph_nodes += 1;

        if (!isValidGraphAsciiName(graph_name, 128)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_graph_name_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (!isValidGraphNodeId(node_id)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_id_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (!isValidGraphAsciiName(kind, 128)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_kind_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (!isValidGraphTargetTypeText(target_type)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_target_type_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (nodes.columnType(4) != .null and !isValidGraphOptionalText(nodes.columnText(4))) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_target_namespace_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (nodes.columnType(5) != .null and !isValidGraphOptionalText(nodes.columnText(5))) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_target_ref_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (graphTargetTypeFromText(target_type)) |target_type_value| {
            try validateGraphTargetReference(
                allocator,
                db,
                report,
                issues,
                graph_name,
                node_id,
                target_type_value,
                if (nodes.columnType(4) == .null) null else nodes.columnText(4),
                if (nodes.columnType(5) == .null) null else nodes.columnText(5),
            );
        }
    }

    var edges = try db.prepare(
        \\select e.graph_name, e.from_node_id, e.edge_type, e.to_node_id,
        \\  from_node.node_id is null,
        \\  to_node.node_id is null
        \\from _zova_graph_edges e
        \\left join _zova_graph_nodes from_node
        \\  on from_node.graph_name = e.graph_name and from_node.node_id = e.from_node_id
        \\left join _zova_graph_nodes to_node
        \\  on to_node.graph_name = e.graph_name and to_node.node_id = e.to_node_id
        \\order by e.graph_name, e.from_node_id, e.edge_type, e.to_node_id
    );
    defer edges.deinit();
    while ((try edges.step()) == .row) {
        const graph_name = edges.columnText(0);
        const from_node_id = edges.columnText(1);
        const edge_type = edges.columnText(2);
        const to_node_id = edges.columnText(3);
        const missing_from = edges.columnInt64(4) != 0;
        const missing_to = edges.columnInt64(5) != 0;
        report.stats.graph_edges += 1;

        if (!isValidGraphAsciiName(graph_name, 128)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "edge_graph_name_invalid", @errorName(error.GraphInvalid), graph_name, from_node_id, edge_type);
        }
        if (!isValidGraphNodeId(from_node_id)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "edge_from_node_invalid", @errorName(error.GraphInvalid), graph_name, from_node_id, edge_type);
        }
        if (!isValidGraphNodeId(to_node_id)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "edge_to_node_invalid", @errorName(error.GraphInvalid), graph_name, to_node_id, edge_type);
        }
        if (!isValidGraphAsciiName(edge_type, 128)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "edge_type_invalid", @errorName(error.GraphInvalid), graph_name, from_node_id, edge_type);
        }
        if (missing_from) {
            try addGraphDiagnosticIssue(allocator, report, issues, "missing_edge_from_node", @errorName(error.GraphNodeNotFound), graph_name, from_node_id, edge_type);
        }
        if (missing_to) {
            try addGraphDiagnosticIssue(allocator, report, issues, "missing_edge_to_node", @errorName(error.GraphNodeNotFound), graph_name, to_node_id, edge_type);
        }
    }
}

fn isValidGraphAsciiName(name: []const u8, max_len: usize) bool {
    if (name.len == 0 or name.len > max_len) return false;
    if (startsWithZovaPrefix(name)) return false;
    for (name) |byte| {
        if (!((byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '_' or
            byte == '.' or
            byte == ':' or
            byte == '-')) return false;
    }
    return true;
}

fn isValidGraphNodeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 512) return false;
    if (!std.unicode.utf8ValidateSlice(id)) return false;
    if (startsWithZovaPrefix(id)) return false;
    for (id) |byte| {
        if (byte == 0) return false;
    }
    return true;
}

fn isValidGraphOptionalText(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| {
        if (byte == 0) return false;
    }
    return true;
}

fn isValidGraphTargetTypeText(text: []const u8) bool {
    return std.mem.eql(u8, text, "none") or
        std.mem.eql(u8, text, "record") or
        std.mem.eql(u8, text, "object") or
        std.mem.eql(u8, text, "object_chunk") or
        std.mem.eql(u8, text, "vector") or
        std.mem.eql(u8, text, "entity") or
        std.mem.eql(u8, text, "fact") or
        std.mem.eql(u8, text, "concept") or
        std.mem.eql(u8, text, "external");
}

fn validateGraphTargetReference(
    allocator: std.mem.Allocator,
    db: *zova.Database,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    graph_name: []const u8,
    node_id: []const u8,
    target_type: zova.GraphTargetType,
    target_namespace: ?[]const u8,
    target_ref: ?[]const u8,
) !void {
    switch (target_type) {
        .object => {
            const ref = target_ref orelse {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_object_target_missing", @errorName(error.ObjectNotFound), graph_name, node_id, null);
                return;
            };
            const id = parseHex32(ref) catch {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_object_target_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
                return;
            };
            if (!(db.hasObject(id) catch false)) {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_object_target_missing", @errorName(error.ObjectNotFound), graph_name, node_id, null);
            }
        },
        .object_chunk => {
            const ref = target_ref orelse {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_chunk_target_missing", @errorName(error.ObjectChunkNotFound), graph_name, node_id, null);
                return;
            };
            const id = parseHex32(ref) catch {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_chunk_target_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
                return;
            };
            if (!(db.hasObjectChunk(id) catch false)) {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_chunk_target_missing", @errorName(error.ObjectChunkNotFound), graph_name, node_id, null);
            }
        },
        .vector => {
            const collection = target_namespace orelse {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_vector_target_missing", @errorName(error.VectorNotFound), graph_name, node_id, null);
                return;
            };
            const vector_id = target_ref orelse {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_vector_target_missing", @errorName(error.VectorNotFound), graph_name, node_id, null);
                return;
            };
            if (!(db.hasVector(collection, vector_id) catch false)) {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_vector_target_missing", @errorName(error.VectorNotFound), graph_name, node_id, null);
            }
        },
        else => {},
    }
}

fn addDiagnosticIssue(
    allocator: std.mem.Allocator,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    area: DiagnosticIssueArea,
    kind: []const u8,
    detail: []const u8,
    object_id: ?[]const u8,
    chunk_hash: ?[]const u8,
    collection_name: ?[]const u8,
    vector_id: ?[]const u8,
) !void {
    report.issue_count += 1;
    report.severity_counts.errors += 1;
    switch (area) {
        .sqlite => report.issue_counts.sqlite += 1,
        .bound_store => report.issue_counts.bound_store += 1,
        .object => report.issue_counts.object += 1,
        .chunk => report.issue_counts.chunk += 1,
        .vector => report.issue_counts.vector += 1,
        .graph => report.issue_counts.graph += 1,
    }

    if (issues.items.len >= report.issue_limit) {
        report.issues_truncated = true;
        return;
    }

    var issue = DiagnosticIssue{
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

fn addGraphDiagnosticIssue(
    allocator: std.mem.Allocator,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    kind: []const u8,
    detail: []const u8,
    graph_name: ?[]const u8,
    node_id: ?[]const u8,
    edge_type: ?[]const u8,
) !void {
    report.issue_count += 1;
    report.severity_counts.errors += 1;
    report.issue_counts.graph += 1;

    if (issues.items.len >= report.issue_limit) {
        report.issues_truncated = true;
        return;
    }

    var issue = DiagnosticIssue{
        .area = .graph,
        .kind = kind,
        .detail = detail,
    };
    errdefer issue.deinit(allocator);

    if (graph_name) |value| issue.graph_name = try allocator.dupe(u8, value);
    if (node_id) |value| issue.node_id = try allocator.dupe(u8, value);
    if (edge_type) |value| issue.edge_type = try allocator.dupe(u8, value);

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

fn sqliteMetaValueAlloc(allocator: std.mem.Allocator, db: *sqlite.Database, key: []const u8) !?[]u8 {
    var stmt = try db.prepare("select value from _zova_meta where key = ?");
    defer stmt.deinit();

    try stmt.bindText(1, key);
    return switch (try stmt.step()) {
        .done => null,
        .row => try allocator.dupe(u8, stmt.columnText(0)),
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
