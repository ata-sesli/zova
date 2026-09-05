//! Internal CLI argument and result types with their owned-memory cleanup.

const std = @import("std");
const zova = @import("zova");
const sqlite = zova.sqlite;

pub const OutputFormat = enum {
    text,
    json,
};

pub const CommandContext = struct {
    registry: zova.ExtensionRegistry,
};

pub const ParsedGlobalArgs = struct {
    args: []const []const u8,
    extension_paths: []const []const u8,

    pub fn deinit(self: *ParsedGlobalArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.args);
        allocator.free(self.extension_paths);
    }
};

pub const BoundedCommandArgs = struct {
    format: OutputFormat,
    limit: usize,
    path: []const u8,
    id: ?[]const u8,
};

pub const GraphNodeCommandArgs = struct {
    format: OutputFormat,
    path: []const u8,
    graph_name: []const u8,
    node_id: []const u8,
};

pub const GraphNeighborsCommandArgs = struct {
    format: OutputFormat,
    limit: usize,
    path: []const u8,
    graph_name: []const u8,
    node_id: []const u8,
    incoming: bool,
    edge_type: ?[]const u8,
};

pub const GraphWalkCommandArgs = struct {
    format: OutputFormat,
    limit: usize,
    max_depth: u32,
    path: []const u8,
    graph_name: []const u8,
    node_id: []const u8,
    edge_type: ?[]const u8,
};

pub const SalvageCommandArgs = struct {
    format: OutputFormat,
    limit: usize,
    dry_run: bool,
    source_path: []const u8,
    destination_path: ?[]const u8,
};

pub const OperationalCommandArgs = struct {
    format: OutputFormat,
    verify: bool,
    source_path: []const u8,
    destination_path: []const u8,
};

pub const SplitRole = enum {
    objects,
    vectors,
    graphs,
};

pub const SplitCommandArgs = struct {
    format: OutputFormat,
    role: SplitRole,
    main_path: []const u8,
    store_path: []const u8,
};

pub const ObjectStoreAction = enum {
    create,
    bind,
    info,
    unbind,
};

pub const ExtensionAction = enum {
    list,
    info,
    check,
    drop,
    install,
    trust,
    untrust,
    trusted,
    scaffold,
    build,
    pack,
    verify,
};

pub const ObjectStoreCommandArgs = struct {
    format: OutputFormat,
    action: ObjectStoreAction,
    main_path: ?[]const u8,
    store_path: ?[]const u8,
};

pub const ExtensionCommandArgs = struct {
    format: OutputFormat,
    action: ExtensionAction,
    path: ?[]const u8,
    name: ?[]const u8,
    version: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    smoke: bool = false,
};

pub const BoundedCommandParseError = error{
    DuplicateJson,
    DuplicateLimit,
    MissingLimitValue,
    InvalidLimit,
    UnknownFlag,
    MissingPath,
    MissingId,
    ExtraArgs,
};

pub const GraphCommandParseError = error{
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

pub const SalvageCommandParseError = error{
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

pub const ObjectStoreCommandParseError = error{
    MissingAction,
    UnknownAction,
    DuplicateJson,
    UnknownFlag,
    MissingMainPath,
    MissingStorePath,
    ExtraArgs,
};

pub const ExtensionCommandParseError = error{
    MissingAction,
    UnknownAction,
    DuplicateJson,
    DuplicateName,
    DuplicateVersion,
    DuplicateOut,
    DuplicateSmoke,
    UnknownFlag,
    MissingFlagValue,
    MissingPath,
    MissingName,
    MissingVersion,
    MissingOut,
    InvalidName,
    ExtraArgs,
};

pub const SplitCommandParseError = error{
    MissingRole,
    DuplicateRole,
    DuplicateJson,
    UnknownFlag,
    MissingMainPath,
    MissingStorePath,
    SamePath,
    ExtraArgs,
};

pub const DatabaseSummary = struct {
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
    kv_entry_count: u64,
    kv_key_bytes: u64,
    kv_value_bytes: u64,
    kv_allocated_bytes: u64,
    user_table_count: u64,
    private_table_count: u64,

    pub fn deinit(self: *DatabaseSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.format_version);
    }
};

const DiagnosticStats = struct {
    extensions: u64 = 0,
    objects: u64 = 0,
    chunks: u64 = 0,
    object_logical_bytes: u64 = 0,
    object_physical_chunk_bytes: u64 = 0,
    object_referenced_chunk_bytes: u64 = 0,
    fastcdc_manifest_rows: u64 = 0,
    fixed_1m_manifest_rows: u64 = 0,
    fastcdc_chunk_rows: u64 = 0,
    fixed_1m_chunk_rows: u64 = 0,
    object_deduplicated_bytes: u64 = 0,
    vectors: u64 = 0,
    loose_chunks: u64 = 0,
    graphs: u64 = 0,
    graph_nodes: u64 = 0,
    graph_edges: u64 = 0,
};

pub const StatsSummary = struct {
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

    pub fn deinit(self: *StatsSummary, allocator: std.mem.Allocator) void {
        self.database.deinit(allocator);
        for (self.vector_collections) |*item| item.deinit(allocator);
        allocator.free(self.vector_collections);
        for (self.top_objects) |*item| item.deinit(allocator);
        allocator.free(self.top_objects);
        for (self.top_chunks) |*item| item.deinit(allocator);
        allocator.free(self.top_chunks);
    }
};

pub const VectorCollectionStats = struct {
    name: []u8,
    dimensions: u64,
    metric: []u8,
    vector_count: u64,
    stored_bytes: u64,

    pub fn deinit(self: *VectorCollectionStats, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.metric);
    }
};

pub const TopObjectStats = struct {
    id_hex: []u8,
    size_bytes: u64,
    chunk_count: u64,
    chunker: []u8,

    pub fn deinit(self: *TopObjectStats, allocator: std.mem.Allocator) void {
        allocator.free(self.id_hex);
        allocator.free(self.chunker);
    }
};

pub const TopChunkStats = struct {
    id_hex: []u8,
    size_bytes: u64,
    reference_count: u64,
    loose: bool,

    pub fn deinit(self: *TopChunkStats, allocator: std.mem.Allocator) void {
        allocator.free(self.id_hex);
    }
};

pub const NumericStats = struct {
    min: u64,
    max: u64,
    avg: f64,
};

pub const ObjectList = struct {
    items: []TopObjectStats,
    truncated: bool,

    pub fn deinit(self: *ObjectList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const ObjectDetail = struct {
    id_hex: []u8,
    size_bytes: u64,
    chunk_count: u64,
    chunker: []u8,
    manifest: []ManifestRow,
    manifest_truncated: bool,

    pub fn deinit(self: *ObjectDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.id_hex);
        allocator.free(self.chunker);
        for (self.manifest) |*item| item.deinit(allocator);
        allocator.free(self.manifest);
    }
};

pub const ManifestRow = struct {
    index: u64,
    chunk_hash_hex: []u8,
    offset: u64,
    size_bytes: u64,

    pub fn deinit(self: *ManifestRow, allocator: std.mem.Allocator) void {
        allocator.free(self.chunk_hash_hex);
    }
};

pub const ChunkList = struct {
    items: []TopChunkStats,
    truncated: bool,

    pub fn deinit(self: *ChunkList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const ChunkDetail = struct {
    id_hex: []u8,
    size_bytes: u64,
    reference_count: u64,
    loose: bool,
    references: []ChunkReference,
    references_truncated: bool,

    pub fn deinit(self: *ChunkDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.id_hex);
        for (self.references) |*item| item.deinit(allocator);
        allocator.free(self.references);
    }
};

pub const ChunkReference = struct {
    object_id_hex: []u8,
    chunk_index: u64,
    offset: u64,
    size_bytes: u64,

    pub fn deinit(self: *ChunkReference, allocator: std.mem.Allocator) void {
        allocator.free(self.object_id_hex);
    }
};

pub const VectorCollectionListSummary = struct {
    items: []VectorCollectionStats,
    truncated: bool,

    pub fn deinit(self: *VectorCollectionListSummary, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const VectorCollectionDetail = struct {
    name: []u8,
    dimensions: u64,
    metric: []u8,
    vector_count: u64,
    stored_bytes: u64,
    vector_ids: [][]u8,
    vector_ids_truncated: bool,

    pub fn deinit(self: *VectorCollectionDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.metric);
        for (self.vector_ids) |id| allocator.free(id);
        allocator.free(self.vector_ids);
    }
};

pub const TableList = struct {
    user_count: u64,
    private_count: u64,
    user_tables: [][]u8,
    private_tables: [][]u8,
    user_tables_truncated: bool,
    private_tables_truncated: bool,

    pub fn deinit(self: *TableList, allocator: std.mem.Allocator) void {
        for (self.user_tables) |name| allocator.free(name);
        allocator.free(self.user_tables);
        for (self.private_tables) |name| allocator.free(name);
        allocator.free(self.private_tables);
    }
};

pub const DiagnosticIssueCounts = struct {
    sqlite: u64 = 0,
    bound_store: u64 = 0,
    extension: u64 = 0,
    object: u64 = 0,
    chunk: u64 = 0,
    vector: u64 = 0,
    graph: u64 = 0,
};

pub const DiagnosticSeverityCounts = struct {
    info: u64 = 0,
    warning: u64 = 0,
    errors: u64 = 0,
    fatal: u64 = 0,
};

pub const DiagnosticIssueArea = enum {
    sqlite,
    bound_store,
    extension,
    object,
    chunk,
    vector,
    graph,
};

pub const DiagnosticIssue = struct {
    area: DiagnosticIssueArea,
    kind: []u8,
    severity: []const u8 = "error",
    detail: []u8,
    object_id_hex: ?[]u8 = null,
    chunk_hash_hex: ?[]u8 = null,
    collection_name: ?[]u8 = null,
    vector_id: ?[]u8 = null,
    graph_name: ?[]u8 = null,
    node_id: ?[]u8 = null,
    edge_type: ?[]u8 = null,

    pub fn deinit(self: *DiagnosticIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.detail);
        if (self.object_id_hex) |value| allocator.free(value);
        if (self.chunk_hash_hex) |value| allocator.free(value);
        if (self.collection_name) |value| allocator.free(value);
        if (self.vector_id) |value| allocator.free(value);
        if (self.graph_name) |value| allocator.free(value);
        if (self.node_id) |value| allocator.free(value);
        if (self.edge_type) |value| allocator.free(value);
    }
};

pub const DiagnosticReport = struct {
    stats: DiagnosticStats = .{},
    issue_count: u64 = 0,
    issue_counts: DiagnosticIssueCounts = .{},
    severity_counts: DiagnosticSeverityCounts = .{},
    issues: []DiagnosticIssue = &.{},
    issues_truncated: bool = false,
    issue_limit: usize = 10,
    missing_object_store: bool = false,
    missing_vector_store: bool = false,
    missing_graph_store: bool = false,

    pub fn deinit(self: *DiagnosticReport, allocator: std.mem.Allocator) void {
        for (self.issues) |*issue| issue.deinit(allocator);
        allocator.free(self.issues);
    }
};

pub const SalvageRecoverability = enum {
    recoverable,
    partially_recoverable,
    not_recoverable,
    unknown,
};

pub const SalvageCounts = struct {
    user_tables: u64 = 0,
    user_schema_objects: u64 = 0,
    user_rows: u64 = 0,
    extensions: u64 = 0,
    extension_private_objects: u64 = 0,
    graphs: u64 = 0,
    graph_nodes: u64 = 0,
    graph_edges: u64 = 0,
    objects: u64 = 0,
    chunks: u64 = 0,
    loose_chunks: u64 = 0,
    vector_collections: u64 = 0,
    vectors: u64 = 0,
};

pub const SalvagePlan = struct {
    report: DiagnosticReport,
    recoverability: SalvageRecoverability,
    recoverable: SalvageCounts,
    skipped: SalvageCounts,

    pub fn deinit(self: *SalvagePlan, allocator: std.mem.Allocator) void {
        self.report.deinit(allocator);
    }
};

pub const SalvageExecutionResult = struct {
    plan: SalvagePlan,
    copied: SalvageCounts,
    destination_verified: bool,

    pub fn deinit(self: *SalvageExecutionResult, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
    }
};

pub const UserSqlCopyResult = struct {
    copied_tables: u64 = 0,
    skipped_tables: u64 = 0,
    copied_schema_objects: u64 = 0,
    skipped_schema_objects: u64 = 0,
    copied_rows: u64 = 0,
    skipped_rows: u64 = 0,
};

pub const UserSqlRowCopyResult = struct {
    copied_rows: u64 = 0,
    skipped_rows: u64 = 0,
};
