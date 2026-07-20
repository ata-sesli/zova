//! Native graph relationship storage and bounded traversal.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova_error = @import("zova_error.zig");

pub const Error = zova_error.Error;

pub const graphs_table = "_zova_graphs";
pub const graph_nodes_table = "_zova_graph_nodes";
pub const graph_edge_types_table = "_zova_graph_edge_types";
pub const graph_edges_table = "_zova_graph_edges";
pub const default_graph_name = "default";

pub const StorageSchema = enum {
    main,
    graph_store,

    pub fn prefix(self: StorageSchema) []const u8 {
        return switch (self) {
            .main => "main.",
            .graph_store => "graph_store.",
        };
    }
};

const ResolvedGraphEndpoints = struct {
    graph_key: i64 = 0,
    nodes: std.StringHashMap(i64),
};

const ResolvedBatchEndpoints = struct {
    graphs: std.StringHashMap(ResolvedGraphEndpoints),

    fn init() ResolvedBatchEndpoints {
        return .{ .graphs = std.StringHashMap(ResolvedGraphEndpoints).init(std.heap.c_allocator) };
    }

    fn deinit(self: *ResolvedBatchEndpoints) void {
        var graphs = self.graphs.valueIterator();
        while (graphs.next()) |graph| {
            var node_ids = graph.nodes.keyIterator();
            while (node_ids.next()) |node_id| std.heap.c_allocator.free(node_id.*);
            graph.nodes.deinit();
        }
        self.graphs.deinit();
    }

    fn graphKey(self: *const ResolvedBatchEndpoints, graph_name: []const u8) ?i64 {
        const graph = self.graphs.get(graph_name) orelse return null;
        return graph.graph_key;
    }

    fn nodeKey(self: *const ResolvedBatchEndpoints, graph_name: []const u8, node_id: []const u8) ?i64 {
        const graph = self.graphs.get(graph_name) orelse return null;
        return graph.nodes.get(node_id);
    }
};

const GraphBatchEndpoint = struct {
    graph_name: []const u8,
    node_id: []const u8,
};

const GraphBatchEndpointContext = struct {
    pub fn hash(_: GraphBatchEndpointContext, endpoint: GraphBatchEndpoint) u64 {
        const graph_hash = std.hash.Wyhash.hash(0, endpoint.graph_name);
        return std.hash.Wyhash.hash(graph_hash, endpoint.node_id);
    }

    pub fn eql(_: GraphBatchEndpointContext, left: GraphBatchEndpoint, right: GraphBatchEndpoint) bool {
        return std.mem.eql(u8, left.graph_name, right.graph_name) and
            std.mem.eql(u8, left.node_id, right.node_id);
    }
};

const GraphBatchEndpointSet = std.HashMap(
    GraphBatchEndpoint,
    void,
    GraphBatchEndpointContext,
    std.hash_map.default_max_load_percentage,
);

const GraphBatchEndpointSlotMap = std.HashMap(
    GraphBatchEndpoint,
    usize,
    GraphBatchEndpointContext,
    std.hash_map.default_max_load_percentage,
);

const NormalizedGraphEdge = struct {
    input: GraphEdgeInput,
    from_slot: usize,
    to_slot: usize,
};

const GraphNodeKeyTuple = struct {
    graph_key: i64,
    node_id: []const u8,
};

const GraphNodeKeyTupleContext = struct {
    pub fn hash(_: GraphNodeKeyTupleContext, value: GraphNodeKeyTuple) u64 {
        return std.hash.Wyhash.hash(@bitCast(value.graph_key), value.node_id);
    }

    pub fn eql(_: GraphNodeKeyTupleContext, left: GraphNodeKeyTuple, right: GraphNodeKeyTuple) bool {
        return left.graph_key == right.graph_key and std.mem.eql(u8, left.node_id, right.node_id);
    }
};

const GraphNodeKeySlotMap = std.HashMap(
    GraphNodeKeyTuple,
    usize,
    GraphNodeKeyTupleContext,
    std.hash_map.default_max_load_percentage,
);

const GraphEdgeKeyTuple = struct {
    graph_key: i64,
    from_node_key: i64,
    edge_type_key: i64,
    to_node_key: i64,
};

const GraphEdgeKeyTupleContext = struct {
    pub fn hash(_: GraphEdgeKeyTupleContext, value: GraphEdgeKeyTuple) u64 {
        var digest = std.hash.Wyhash.hash(@bitCast(value.graph_key), std.mem.asBytes(&value.from_node_key));
        digest = std.hash.Wyhash.hash(digest, std.mem.asBytes(&value.edge_type_key));
        return std.hash.Wyhash.hash(digest, std.mem.asBytes(&value.to_node_key));
    }

    pub fn eql(_: GraphEdgeKeyTupleContext, left: GraphEdgeKeyTuple, right: GraphEdgeKeyTuple) bool {
        return left.graph_key == right.graph_key and
            left.from_node_key == right.from_node_key and
            left.edge_type_key == right.edge_type_key and
            left.to_node_key == right.to_node_key;
    }
};

const GraphEdgeKeySlotMap = std.HashMap(
    GraphEdgeKeyTuple,
    usize,
    GraphEdgeKeyTupleContext,
    std.hash_map.default_max_load_percentage,
);

const GraphEdgeTypeTuple = struct {
    graph_key: i64,
    name: []const u8,
};

const GraphEdgeTypeTupleContext = struct {
    pub fn hash(_: GraphEdgeTypeTupleContext, value: GraphEdgeTypeTuple) u64 {
        return std.hash.Wyhash.hash(@bitCast(value.graph_key), value.name);
    }

    pub fn eql(_: GraphEdgeTypeTupleContext, left: GraphEdgeTypeTuple, right: GraphEdgeTypeTuple) bool {
        return left.graph_key == right.graph_key and std.mem.eql(u8, left.name, right.name);
    }
};

const GraphEdgeTypeKeyMap = std.HashMap(
    GraphEdgeTypeTuple,
    i64,
    GraphEdgeTypeTupleContext,
    std.hash_map.default_max_load_percentage,
);

const GraphEdgeTypeKeyMapUnmanaged = std.HashMapUnmanaged(
    GraphEdgeTypeTuple,
    i64,
    GraphEdgeTypeTupleContext,
    std.hash_map.default_max_load_percentage,
);

pub const GraphEdgeTypeCache = struct {
    loaded: bool = false,
    by_key: std.AutoHashMapUnmanaged(i64, []u8) = .empty,
    by_type: GraphEdgeTypeKeyMapUnmanaged = .empty,

    pub fn clear(self: *GraphEdgeTypeCache) void {
        var values = self.by_key.valueIterator();
        while (values.next()) |name| std.heap.c_allocator.free(name.*);
        self.by_key.clearAndFree(std.heap.c_allocator);
        self.by_type.clearAndFree(std.heap.c_allocator);
        self.loaded = false;
    }

    pub fn deinit(self: *GraphEdgeTypeCache) void {
        self.clear();
    }
};

const FreshGraphEdgeTuple = struct {
    from_node_key: i64,
    edge_type_key: i64,
    to_node_key: i64,
};

const FreshGraphEdgeTupleContext = struct {
    pub fn hash(_: FreshGraphEdgeTupleContext, value: FreshGraphEdgeTuple) u64 {
        var digest = std.hash.Wyhash.hash(0, std.mem.asBytes(&value.from_node_key));
        digest = std.hash.Wyhash.hash(digest, std.mem.asBytes(&value.edge_type_key));
        return std.hash.Wyhash.hash(digest, std.mem.asBytes(&value.to_node_key));
    }

    pub fn eql(_: FreshGraphEdgeTupleContext, left: FreshGraphEdgeTuple, right: FreshGraphEdgeTuple) bool {
        return left.from_node_key == right.from_node_key and left.edge_type_key == right.edge_type_key and left.to_node_key == right.to_node_key;
    }
};

const FreshGraphEdgeMap = std.HashMap(FreshGraphEdgeTuple, usize, FreshGraphEdgeTupleContext, std.hash_map.default_max_load_percentage);

const ResolvedGraphEndpoint = struct {
    graph_key: i64,
    node_key: i64,
};

const ResolvedGraphEndpointSlots = struct {
    items: []?ResolvedGraphEndpoint,

    fn deinit(self: *ResolvedGraphEndpointSlots) void {
        std.heap.c_allocator.free(self.items);
    }
};

const max_graph_name_bytes: usize = 128;
const max_node_id_bytes: usize = 512;
const max_edge_type_bytes: usize = 128;
const max_kind_bytes: usize = 128;

pub const graphs_schema_sql =
    \\create table _zova_graphs (
    \\  graph_key integer primary key,
    \\  name text not null unique check (length(name) > 0 and length(name) <= 128),
    \\  created_order integer not null
    \\)
;

pub const graph_nodes_schema_sql =
    \\create table _zova_graph_nodes (
    \\  node_key integer primary key,
    \\  graph_key integer not null,
    \\  node_id text not null check (length(node_id) > 0 and length(node_id) <= 512),
    \\  kind text not null check (length(kind) > 0 and length(kind) <= 128),
    \\  target_type text not null check (target_type in ('none', 'record', 'object', 'object_chunk', 'vector', 'entity', 'fact', 'concept', 'external')),
    \\  target_namespace text,
    \\  target_ref text,
    \\  created_order integer not null,
    \\  unique (graph_key, node_id),
    \\  unique (graph_key, node_key),
    \\  foreign key (graph_key) references _zova_graphs(graph_key) on delete cascade
    \\)
;

pub const graph_edge_types_schema_sql =
    \\create table _zova_graph_edge_types (
    \\  edge_type_key integer primary key,
    \\  graph_key integer not null,
    \\  name text not null check (length(name) > 0 and length(name) <= 128),
    \\  unique (graph_key, name),
    \\  unique (graph_key, edge_type_key),
    \\  foreign key (graph_key) references _zova_graphs(graph_key) on delete cascade
    \\)
;

pub const graph_edges_schema_sql =
    \\create table _zova_graph_edges (
    \\  edge_key integer primary key,
    \\  graph_key integer not null,
    \\  from_node_key integer not null,
    \\  edge_type_key integer not null,
    \\  to_node_key integer not null,
    \\  created_order integer not null,
    \\  payload blob not null default x'',
    \\  foreign key (graph_key) references _zova_graphs(graph_key) on delete cascade,
    \\  foreign key (graph_key, from_node_key) references _zova_graph_nodes(graph_key, node_key) on delete cascade,
    \\  foreign key (graph_key, to_node_key) references _zova_graph_nodes(graph_key, node_key) on delete cascade,
    \\  foreign key (graph_key, edge_type_key) references _zova_graph_edge_types(graph_key, edge_type_key) on delete cascade
    \\)
;

pub const graph_edges_topology_index_sql =
    \\create unique index if not exists _zova_graph_edges_topology_idx
    \\on _zova_graph_edges (from_node_key, edge_type_key, to_node_key)
;

pub const graph_nodes_created_order_index_sql =
    \\create index if not exists _zova_graph_nodes_created_order_idx
    \\on _zova_graph_nodes (graph_key, created_order, node_key)
;

pub const graph_edges_created_order_index_sql =
    \\create index if not exists _zova_graph_edges_created_order_idx
    \\on _zova_graph_edges (graph_key, created_order, edge_key)
;

pub const graph_edges_from_node_index_sql =
    \\create index if not exists _zova_graph_edges_from_node_idx
    \\on _zova_graph_edges (graph_key, from_node_key, created_order, to_node_key)
;

pub const graph_edges_from_node_type_index_sql =
    \\create index if not exists _zova_graph_edges_from_node_type_idx
    \\on _zova_graph_edges (graph_key, from_node_key, edge_type_key, created_order, to_node_key)
;

pub const graph_edges_to_node_index_sql =
    \\create index if not exists _zova_graph_edges_to_node_idx
    \\on _zova_graph_edges (graph_key, to_node_key, created_order, from_node_key)
;

pub const graph_edges_to_node_type_index_sql =
    \\create index if not exists _zova_graph_edges_to_node_type_idx
    \\on _zova_graph_edges (graph_key, to_node_key, edge_type_key, created_order, from_node_key)
;

pub const GraphTargetType = enum {
    none,
    record,
    object,
    object_chunk,
    vector,
    entity,
    fact,
    concept,
    external,
};

pub const GraphInfo = struct {
    name: []u8,
    node_count: u64,
    edge_count: u64,

    pub fn deinit(self: *GraphInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const GraphList = struct {
    items: []GraphInfo,

    pub fn deinit(self: *GraphList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const GraphNodeInput = struct {
    graph_name: []const u8 = default_graph_name,
    node_id: []const u8,
    kind: []const u8,
    target_type: GraphTargetType = .none,
    target_namespace: ?[]const u8 = null,
    target_ref: ?[]const u8 = null,
};

pub const FreshGraphNodeInput = struct {
    node_id: []const u8,
    kind: []const u8,
    target_type: GraphTargetType = .none,
    target_namespace: ?[]const u8 = null,
    target_ref: ?[]const u8 = null,
};

pub const GraphNode = struct {
    graph_name: []u8,
    node_id: []u8,
    kind: []u8,
    target_type: GraphTargetType,
    target_namespace: ?[]u8,
    target_ref: ?[]u8,

    pub fn deinit(self: *GraphNode, allocator: std.mem.Allocator) void {
        allocator.free(self.graph_name);
        allocator.free(self.node_id);
        allocator.free(self.kind);
        if (self.target_namespace) |value| allocator.free(value);
        if (self.target_ref) |value| allocator.free(value);
    }
};

pub const GraphEdgeInput = struct {
    graph_name: []const u8 = default_graph_name,
    from_node_id: []const u8,
    edge_type: []const u8,
    to_node_id: []const u8,
};

pub const FreshGraphEdgeInput = struct {
    from_node_ordinal: usize,
    edge_type: []const u8,
    to_node_ordinal: usize,
    payload: []const u8 = &.{},
};

pub const FreshGraphBuildProfile = struct {
    validation_ms: f64 = 0,
    key_generation_ms: f64 = 0,
    index_drop_ms: f64 = 0,
    graph_and_types_ms: f64 = 0,
    node_load_ms: f64 = 0,
    edge_load_ms: f64 = 0,
    index_build_ms: f64 = 0,
    payload_bytes: u64 = 0,
};

pub const GraphEdgePayloadReplacement = struct {
    edge_key: i64,
    payload: []const u8,
};

pub const GraphEdgePayloadLookup = struct {
    found: bool,
    edge_key: i64,
    payload: ?[]u8 = null,

    pub fn deinit(self: *GraphEdgePayloadLookup, allocator: std.mem.Allocator) void {
        if (self.payload) |value| allocator.free(value);
    }
};

pub const GraphEdgePayloadLookupList = struct {
    items: []GraphEdgePayloadLookup,

    pub fn deinit(self: *GraphEdgePayloadLookupList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const GraphEdge = struct {
    graph_name: []u8,
    from_node_id: []u8,
    edge_type: []u8,
    to_node_id: []u8,

    pub fn deinit(self: *GraphEdge, allocator: std.mem.Allocator) void {
        allocator.free(self.graph_name);
        allocator.free(self.from_node_id);
        allocator.free(self.edge_type);
        allocator.free(self.to_node_id);
    }
};

pub const GraphNeighborDirection = enum {
    outgoing,
    incoming,
};

pub const GraphNeighborsOptions = struct {
    graph_name: []const u8 = default_graph_name,
    node_id: []const u8,
    direction: GraphNeighborDirection = .outgoing,
    edge_type: ?[]const u8 = null,
    limit: usize = 10,
};

/// Count directed graph edges adjacent to one existing node.
pub const GraphDegreeOptions = struct {
    graph_name: []const u8 = default_graph_name,
    node_id: []const u8,
    direction: GraphNeighborDirection = .outgoing,
    edge_type: ?[]const u8 = null,
};

pub const GraphNeighbor = struct {
    node_id: []u8,
    kind: []u8,
    edge_type: []u8,

    pub fn deinit(self: *GraphNeighbor, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.kind);
        allocator.free(self.edge_type);
    }
};

pub const GraphNeighborList = struct {
    items: []GraphNeighbor,

    pub fn deinit(self: *GraphNeighborList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const GraphKeyedNeighbor = struct {
    edge_key: i64,
    neighbor_node_key: i64,
    node_id: []u8,
    kind: []u8,
    edge_type: []u8,

    pub fn deinit(self: *GraphKeyedNeighbor, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.kind);
        allocator.free(self.edge_type);
    }
};

pub const GraphKeyedNeighborList = struct {
    items: []GraphKeyedNeighbor,

    pub fn deinit(self: *GraphKeyedNeighborList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const GraphKeyedNodeLookup = struct {
    found: bool,
    node_key: i64,
    node_id: ?[]u8 = null,
    kind: ?[]u8 = null,
    created_order: i64 = 0,

    pub fn deinit(self: *GraphKeyedNodeLookup, allocator: std.mem.Allocator) void {
        if (self.node_id) |value| allocator.free(value);
        if (self.kind) |value| allocator.free(value);
    }
};

pub const GraphKeyedNodeLookupList = struct {
    items: []GraphKeyedNodeLookup,
    pub fn deinit(self: *GraphKeyedNodeLookupList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const GraphKeyedEdgeLookup = struct {
    found: bool,
    edge_key: i64,
    source_node_key: i64 = 0,
    edge_type: ?[]u8 = null,
    target_node_key: i64 = 0,
    created_order: i64 = 0,

    pub fn deinit(self: *GraphKeyedEdgeLookup, allocator: std.mem.Allocator) void {
        if (self.edge_type) |value| allocator.free(value);
    }
};

pub const GraphKeyedEdgeLookupList = struct {
    items: []GraphKeyedEdgeLookup,
    pub fn deinit(self: *GraphKeyedEdgeLookupList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const GraphScanCursor = struct {
    created_order: i64 = 0,
    key: i64 = 0,
};

pub const GraphScanOptions = struct {
    graph_name: []const u8 = default_graph_name,
    node_after: GraphScanCursor = .{},
    edge_after: GraphScanCursor = .{},
    node_limit: usize = 0,
    edge_limit: usize = 0,
};

pub const GraphScanNode = struct {
    node_key: i64,
    node_id: []u8,
    kind: []u8,
    created_order: i64,

    pub fn deinit(self: *GraphScanNode, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.kind);
    }
};

pub const GraphScanEdge = struct {
    edge_key: i64,
    source_node_key: i64,
    edge_type: []u8,
    target_node_key: i64,
    created_order: i64,

    pub fn deinit(self: *GraphScanEdge, allocator: std.mem.Allocator) void {
        allocator.free(self.edge_type);
    }
};

pub const GraphScanResult = struct {
    nodes: []GraphScanNode,
    edges: []GraphScanEdge,
    has_more_nodes: bool,
    has_more_edges: bool,

    pub fn deinit(self: *GraphScanResult, allocator: std.mem.Allocator) void {
        for (self.nodes) |*node| node.deinit(allocator);
        allocator.free(self.nodes);
        for (self.edges) |*edge| edge.deinit(allocator);
        allocator.free(self.edges);
    }
};

pub const GraphWalkOptions = struct {
    graph_name: []const u8 = default_graph_name,
    start_node_id: []const u8,
    edge_type: ?[]const u8 = null,
    max_depth: u32 = 1,
    limit: usize = 10,
};

/// Options for a bounded graph walk with an explicit edge direction.
pub const GraphWalkDirectionOptions = struct {
    graph_name: []const u8 = default_graph_name,
    start_node_id: []const u8,
    direction: GraphNeighborDirection = .outgoing,
    edge_type: ?[]const u8 = null,
    max_depth: u32 = 1,
    limit: usize = 10,
};

/// Internal diagnostics for one graph walk's reusable adjacency scan.
pub const GraphWalkScanProfile = struct {
    root_lookup_ms: f64 = 0,
    adjacency_prepare_ms: f64 = 0,
    adjacency_execute_ms: f64 = 0,
    bfs_bookkeeping_allocation_ms: f64 = 0,
    adjacency_statement_prepares: u64 = 0,
    adjacency_query_binds: u64 = 0,
    adjacency_rows_stepped: u64 = 0,
    frontier_expansions: u64 = 0,
    result_count: u64 = 0,
};

pub const GraphWalkItem = struct {
    node_id: []u8,
    kind: []u8,
    depth: u32,
    predecessor_node_id: ?[]u8,
    edge_type: ?[]u8,

    pub fn deinit(self: *GraphWalkItem, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.kind);
        if (self.predecessor_node_id) |value| allocator.free(value);
        if (self.edge_type) |value| allocator.free(value);
    }
};

pub const GraphWalk = struct {
    items: []GraphWalkItem,

    pub fn deinit(self: *GraphWalk, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const Database = struct {
    sqlite_db: *sqlite.Database,
    storage_schema: StorageSchema = .main,
    edge_type_cache: ?*GraphEdgeTypeCache = null,

    fn prepareSchema(self: *Database, comptime sql_template: []const u8) Error!sqlite.Statement {
        var sql_buffer: [4096]u8 = undefined;
        const prefix = self.storage_schema.prefix();
        const sql_len = std.mem.replacementSize(u8, sql_template, "{s}", prefix);
        if (sql_len >= sql_buffer.len) return error.SqliteError;
        _ = std.mem.replace(u8, sql_template, "{s}", prefix, sql_buffer[0..sql_len]);
        sql_buffer[sql_len] = 0;
        const db = self.sqlite_db;
        return try db.prepare(sql_buffer[0..sql_len :0]);
    }

    fn execSchema(self: *Database, comptime sql_template: []const u8) Error!void {
        var sql_buffer: [4096]u8 = undefined;
        const prefix = self.storage_schema.prefix();
        const sql_len = std.mem.replacementSize(u8, sql_template, "{s}", prefix);
        if (sql_len >= sql_buffer.len) return error.SqliteError;
        _ = std.mem.replace(u8, sql_template, "{s}", prefix, sql_buffer[0..sql_len]);
        sql_buffer[sql_len] = 0;
        try self.sqlite_db.exec(sql_buffer[0..sql_len :0]);
    }

    fn ensureEdgeTypeCache(self: *Database) Error!void {
        const cache = self.edge_type_cache orelse return;
        if (cache.loaded) return;
        errdefer cache.clear();
        var stmt = try self.prepareSchema("select graph_key,edge_type_key,name from {s}_zova_graph_edge_types order by edge_type_key");
        defer stmt.deinit();
        while ((try stmt.step()) == .row) {
            const graph_key = stmt.columnInt64(0);
            const edge_type_key = stmt.columnInt64(1);
            if (graph_key <= 0 or edge_type_key <= 0 or cache.by_key.contains(edge_type_key)) return error.GraphInvalid;
            const name = try std.heap.c_allocator.dupe(u8, stmt.columnText(2));
            cache.by_key.put(std.heap.c_allocator, edge_type_key, name) catch |err| {
                std.heap.c_allocator.free(name);
                return err;
            };
            cache.by_type.put(std.heap.c_allocator, .{ .graph_key = graph_key, .name = name }, edge_type_key) catch |err| {
                _ = cache.by_key.remove(edge_type_key);
                std.heap.c_allocator.free(name);
                return err;
            };
        }
        cache.loaded = true;
    }

    fn graphKeyForRead(self: *Database, name: []const u8) Error!i64 {
        return self.graphKey(name);
    }

    fn edgeTypeKeyForRead(self: *Database, graph_key: i64, name: []const u8) Error!?i64 {
        if (self.edge_type_cache) |cache| {
            try self.ensureEdgeTypeCache();
            if (cache.by_type.get(.{ .graph_key = graph_key, .name = name })) |key| return key;
            var stmt = try self.prepareSchema("select edge_type_key,name from {s}_zova_graph_edge_types where graph_key=? and name=?");
            defer stmt.deinit();
            try stmt.bindInt64(1, graph_key);
            try stmt.bindText(2, name);
            if ((try stmt.step()) != .row) return null;
            const key = stmt.columnInt64(0);
            const owned_name = try std.heap.c_allocator.dupe(u8, stmt.columnText(1));
            cache.by_key.put(std.heap.c_allocator, key, owned_name) catch |err| {
                std.heap.c_allocator.free(owned_name);
                return err;
            };
            cache.by_type.put(std.heap.c_allocator, .{ .graph_key = graph_key, .name = owned_name }, key) catch |err| {
                _ = cache.by_key.remove(key);
                std.heap.c_allocator.free(owned_name);
                return err;
            };
            return key;
        }
        var stmt = try self.prepareSchema("select edge_type_key from {s}_zova_graph_edge_types where graph_key=? and name=?");
        defer stmt.deinit();
        try stmt.bindInt64(1, graph_key);
        try stmt.bindText(2, name);
        return switch (try stmt.step()) {
            .done => null,
            .row => stmt.columnInt64(0),
        };
    }

    fn dupeEdgeTypeNameForRead(self: *Database, allocator: std.mem.Allocator, edge_type_key: i64) Error![]u8 {
        if (edge_type_key <= 0) return error.GraphInvalid;
        if (self.edge_type_cache) |cache| {
            try self.ensureEdgeTypeCache();
            if (cache.by_key.get(edge_type_key)) |name| return allocator.dupe(u8, name);
            var stmt = try self.prepareSchema("select graph_key,name from {s}_zova_graph_edge_types where edge_type_key=?");
            defer stmt.deinit();
            try stmt.bindInt64(1, edge_type_key);
            if ((try stmt.step()) != .row) return error.GraphInvalid;
            const graph_key = stmt.columnInt64(0);
            const owned_name = try std.heap.c_allocator.dupe(u8, stmt.columnText(1));
            cache.by_key.put(std.heap.c_allocator, edge_type_key, owned_name) catch |err| {
                std.heap.c_allocator.free(owned_name);
                return err;
            };
            cache.by_type.put(std.heap.c_allocator, .{ .graph_key = graph_key, .name = owned_name }, edge_type_key) catch |err| {
                _ = cache.by_key.remove(edge_type_key);
                std.heap.c_allocator.free(owned_name);
                return err;
            };
            return allocator.dupe(u8, owned_name);
        }
        var stmt = try self.prepareSchema("select name from {s}_zova_graph_edge_types where edge_type_key=?");
        defer stmt.deinit();
        try stmt.bindInt64(1, edge_type_key);
        if ((try stmt.step()) != .row) return error.GraphInvalid;
        return allocator.dupe(u8, stmt.columnText(0));
    }

    fn dropGraphSecondaryIndexes(self: *Database) Error!void {
        try self.execSchema(
            \\drop index {s}_zova_graph_nodes_created_order_idx;
            \\drop index {s}_zova_graph_edges_topology_idx;
            \\drop index {s}_zova_graph_edges_created_order_idx;
            \\drop index {s}_zova_graph_edges_from_node_idx;
            \\drop index {s}_zova_graph_edges_from_node_type_idx;
            \\drop index {s}_zova_graph_edges_to_node_idx;
            \\drop index {s}_zova_graph_edges_to_node_type_idx;
        );
    }

    fn createGraphSecondaryIndexes(self: *Database) Error!void {
        try self.execSchema(
            \\create index {s}_zova_graph_nodes_created_order_idx on _zova_graph_nodes(graph_key,created_order,node_key);
            \\create unique index {s}_zova_graph_edges_topology_idx on _zova_graph_edges(from_node_key,edge_type_key,to_node_key);
            \\create index {s}_zova_graph_edges_created_order_idx on _zova_graph_edges(graph_key,created_order,edge_key);
            \\create index {s}_zova_graph_edges_from_node_idx on _zova_graph_edges(graph_key,from_node_key,created_order,to_node_key);
            \\create index {s}_zova_graph_edges_from_node_type_idx on _zova_graph_edges(graph_key,from_node_key,edge_type_key,created_order,to_node_key);
            \\create index {s}_zova_graph_edges_to_node_idx on _zova_graph_edges(graph_key,to_node_key,created_order,from_node_key);
            \\create index {s}_zova_graph_edges_to_node_type_idx on _zova_graph_edges(graph_key,to_node_key,edge_type_key,created_order,from_node_key);
        );
    }

    pub fn createGraph(self: *Database, name: []const u8) Error!void {
        try validateGraphName(name);

        var stmt = try self.prepareSchema(
            \\insert into {s}_zova_graphs (name, created_order)
            \\values (?, coalesce((select max(created_order) + 1 from {s}_zova_graphs), 1))
        );
        defer stmt.deinit();

        try stmt.bindText(1, name);
        _ = stmt.step() catch |err| switch (err) {
            error.Constraint => return error.GraphExists,
            else => return err,
        };
    }

    /// Build the sole graph in an empty native graph store using ordinal endpoints.
    /// The caller owns the surrounding transaction or savepoint.
    pub fn buildFreshGraphKeyed(
        self: *Database,
        graph_name: []const u8,
        nodes: []const FreshGraphNodeInput,
        edges: []const FreshGraphEdgeInput,
        out_node_keys: []i64,
        out_edge_keys: []i64,
    ) Error!void {
        return self.buildFreshGraphKeyedProfiled(graph_name, nodes, edges, out_node_keys, out_edge_keys, null);
    }

    pub fn buildFreshGraphKeyedProfiled(
        self: *Database,
        graph_name: []const u8,
        nodes: []const FreshGraphNodeInput,
        edges: []const FreshGraphEdgeInput,
        out_node_keys: []i64,
        out_edge_keys: []i64,
        profile: ?*FreshGraphBuildProfile,
    ) Error!void {
        if (profile) |value| value.* = .{};
        const validation_start = graphProfileTimestamp();
        if (out_node_keys.len != nodes.len or out_edge_keys.len != edges.len) return error.InvalidArgument;
        try validateGraphName(graph_name);

        var node_slots = std.StringHashMap(usize).init(std.heap.c_allocator);
        defer node_slots.deinit();
        const input_node_slots = try std.heap.c_allocator.alloc(usize, nodes.len);
        defer std.heap.c_allocator.free(input_node_slots);
        var final_node_inputs: std.ArrayList(usize) = .empty;
        defer final_node_inputs.deinit(std.heap.c_allocator);
        for (nodes, 0..) |node, input_index| {
            try validateNodeId(node.node_id);
            try validateNodeKind(node.kind);
            if (node.target_namespace) |value| try validateOptionalText(value);
            if (node.target_ref) |value| try validateOptionalText(value);
            const entry = try node_slots.getOrPut(node.node_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = final_node_inputs.items.len;
                try final_node_inputs.append(std.heap.c_allocator, input_index);
            } else {
                final_node_inputs.items[entry.value_ptr.*] = input_index;
            }
            input_node_slots[input_index] = entry.value_ptr.*;
        }

        var type_slots = std.StringHashMap(usize).init(std.heap.c_allocator);
        defer type_slots.deinit();
        var type_names: std.ArrayList([]const u8) = .empty;
        defer type_names.deinit(std.heap.c_allocator);
        var edge_slots = FreshGraphEdgeMap.init(std.heap.c_allocator);
        defer edge_slots.deinit();
        var distinct_edges: std.ArrayList(FreshGraphEdgeTuple) = .empty;
        defer distinct_edges.deinit(std.heap.c_allocator);
        const input_edge_slots = try std.heap.c_allocator.alloc(usize, edges.len);
        defer std.heap.c_allocator.free(input_edge_slots);
        for (edges, 0..) |edge, input_index| {
            if (edge.from_node_ordinal >= nodes.len or edge.to_node_ordinal >= nodes.len) return error.InvalidArgument;
            try validateEdgeType(edge.edge_type);
            const type_entry = try type_slots.getOrPut(edge.edge_type);
            if (!type_entry.found_existing) {
                type_entry.value_ptr.* = type_names.items.len;
                try type_names.append(std.heap.c_allocator, edge.edge_type);
            }
            const tuple: FreshGraphEdgeTuple = .{
                .from_node_key = @intCast(input_node_slots[edge.from_node_ordinal] + 1),
                .edge_type_key = @intCast(type_entry.value_ptr.* + 1),
                .to_node_key = @intCast(input_node_slots[edge.to_node_ordinal] + 1),
            };
            const entry = try edge_slots.getOrPut(tuple);
            if (!entry.found_existing) {
                entry.value_ptr.* = distinct_edges.items.len;
                try distinct_edges.append(std.heap.c_allocator, tuple);
            }
            input_edge_slots[input_index] = entry.value_ptr.*;
        }

        {
            var empty = try self.prepareSchema(
                \\select
                \\ (select count(*) from {s}_zova_graphs) +
                \\ (select count(*) from {s}_zova_graph_nodes) +
                \\ (select count(*) from {s}_zova_graph_edge_types) +
                \\ (select count(*) from {s}_zova_graph_edges)
            );
            defer empty.deinit();
            if ((try empty.step()) != .row or empty.columnInt64(0) != 0) return error.GraphInvalid;
        }

        if (profile) |value| value.validation_ms = graphProfileElapsedMs(validation_start);
        const drop_start = graphProfileTimestamp();
        try self.dropGraphSecondaryIndexes();
        if (profile) |value| value.index_drop_ms = graphProfileElapsedMs(drop_start);
        const metadata_start = graphProfileTimestamp();
        var graph_insert = try self.prepareSchema("insert into {s}_zova_graphs(graph_key,name,created_order) values(1,?,1)");
        defer graph_insert.deinit();
        try graph_insert.bindText(1, graph_name);
        if ((try graph_insert.step()) != .done or self.sqlite_db.changes() != 1) return error.GraphInvalid;

        var type_insert = try self.prepareSchema("insert into {s}_zova_graph_edge_types(edge_type_key,graph_key,name) values(?,1,?)");
        defer type_insert.deinit();
        for (type_names.items, 0..) |name, type_index| {
            try type_insert.bindInt64(1, @intCast(type_index + 1));
            try type_insert.bindText(2, name);
            if ((try type_insert.step()) != .done or self.sqlite_db.changes() != 1) return error.GraphInvalid;
            try type_insert.reset();
            try type_insert.clearBindings();
        }
        if (profile) |value| value.graph_and_types_ms = graphProfileElapsedMs(metadata_start);

        const node_start = graphProfileTimestamp();
        var node_insert = try self.prepareSchema(
            "insert into {s}_zova_graph_nodes(node_key,graph_key,node_id,kind,target_type,target_namespace,target_ref,created_order) values(?,1,?,?,?,?,?,?)",
        );
        defer node_insert.deinit();
        for (final_node_inputs.items, 0..) |input_index, slot| {
            const node = nodes[input_index];
            const node_key: i64 = @intCast(slot + 1);
            try node_insert.bindInt64(1, node_key);
            try node_insert.bindText(2, node.node_id);
            try node_insert.bindText(3, node.kind);
            try node_insert.bindText(4, targetTypeText(node.target_type));
            if (node.target_namespace) |value| try node_insert.bindText(5, value) else try node_insert.bindNull(5);
            if (node.target_ref) |value| try node_insert.bindText(6, value) else try node_insert.bindNull(6);
            try node_insert.bindInt64(7, node_key);
            if ((try node_insert.step()) != .done or self.sqlite_db.changes() != 1) return error.GraphInvalid;
            try node_insert.reset();
            try node_insert.clearBindings();
        }
        if (profile) |value| value.node_load_ms = graphProfileElapsedMs(node_start);

        const edge_start = graphProfileTimestamp();
        var edge_insert = try self.prepareSchema(
            "insert into {s}_zova_graph_edges(edge_key,graph_key,from_node_key,edge_type_key,to_node_key,created_order) values(?,1,?,?,?,?)",
        );
        defer edge_insert.deinit();
        for (distinct_edges.items, 0..) |edge, slot| {
            const edge_key: i64 = @intCast(slot + 1);
            try edge_insert.bindInt64(1, edge_key);
            try edge_insert.bindInt64(2, edge.from_node_key);
            try edge_insert.bindInt64(3, edge.edge_type_key);
            try edge_insert.bindInt64(4, edge.to_node_key);
            try edge_insert.bindInt64(5, edge_key);
            if ((try edge_insert.step()) != .done or self.sqlite_db.changes() != 1) return error.GraphInvalid;
            try edge_insert.reset();
            try edge_insert.clearBindings();
        }
        if (profile) |value| value.edge_load_ms = graphProfileElapsedMs(edge_start);
        const indexes_start = graphProfileTimestamp();
        try self.createGraphSecondaryIndexes();
        if (profile) |value| value.index_build_ms = graphProfileElapsedMs(indexes_start);

        for (input_node_slots, out_node_keys) |slot, *key| key.* = @intCast(slot + 1);
        for (input_edge_slots, out_edge_keys) |slot, *key| key.* = @intCast(slot + 1);
    }

    /// Build trusted, final-order graph input without topology normalization.
    /// Duplicate node IDs or edges are contract violations and fail atomically.
    pub fn buildFreshGraphPreparedKeyed(
        self: *Database,
        graph_name: []const u8,
        nodes: []const FreshGraphNodeInput,
        edges: []const FreshGraphEdgeInput,
        out_node_keys: []i64,
        out_edge_keys: []i64,
    ) Error!void {
        return self.buildFreshGraphPreparedKeyedProfiled(graph_name, nodes, edges, out_node_keys, out_edge_keys, null);
    }

    pub fn buildFreshGraphPreparedKeyedProfiled(
        self: *Database,
        graph_name: []const u8,
        nodes: []const FreshGraphNodeInput,
        edges: []const FreshGraphEdgeInput,
        out_node_keys: []i64,
        out_edge_keys: []i64,
        profile: ?*FreshGraphBuildProfile,
    ) Error!void {
        if (profile) |value| value.* = .{};
        const validation_start = graphProfileTimestamp();
        if (out_node_keys.len != nodes.len or out_edge_keys.len != edges.len) return error.InvalidArgument;
        try validateGraphName(graph_name);

        for (nodes) |node| {
            try validateNodeId(node.node_id);
            try validateNodeKind(node.kind);
            if (node.target_namespace) |value| try validateOptionalText(value);
            if (node.target_ref) |value| try validateOptionalText(value);
        }

        var type_slots = std.StringHashMap(usize).init(std.heap.c_allocator);
        defer type_slots.deinit();
        var type_names: std.ArrayList([]const u8) = .empty;
        defer type_names.deinit(std.heap.c_allocator);
        const edge_type_slots = try std.heap.c_allocator.alloc(usize, edges.len);
        defer std.heap.c_allocator.free(edge_type_slots);
        for (edges, edge_type_slots) |edge, *type_slot| {
            if (edge.from_node_ordinal >= nodes.len or edge.to_node_ordinal >= nodes.len) return error.InvalidArgument;
            try validateEdgeType(edge.edge_type);
            const entry = try type_slots.getOrPut(edge.edge_type);
            if (!entry.found_existing) {
                entry.value_ptr.* = type_names.items.len;
                try type_names.append(std.heap.c_allocator, edge.edge_type);
            }
            type_slot.* = entry.value_ptr.*;
        }

        {
            var empty = try self.prepareSchema(
                \\select
                \\ (select count(*) from {s}_zova_graphs) +
                \\ (select count(*) from {s}_zova_graph_nodes) +
                \\ (select count(*) from {s}_zova_graph_edge_types) +
                \\ (select count(*) from {s}_zova_graph_edges)
            );
            defer empty.deinit();
            if ((try empty.step()) != .row or empty.columnInt64(0) != 0) return error.GraphInvalid;
        }
        if (profile) |value| value.validation_ms = graphProfileElapsedMs(validation_start);

        const key_start = graphProfileTimestamp();
        for (out_node_keys, 0..) |*key, index| key.* = @intCast(index + 1);
        for (out_edge_keys, 0..) |*key, index| key.* = @intCast(index + 1);
        if (profile) |value| value.key_generation_ms = graphProfileElapsedMs(key_start);

        const drop_start = graphProfileTimestamp();
        try self.dropGraphSecondaryIndexes();
        if (profile) |value| value.index_drop_ms = graphProfileElapsedMs(drop_start);

        const metadata_start = graphProfileTimestamp();
        var graph_insert = try self.prepareSchema("insert into {s}_zova_graphs(graph_key,name,created_order) values(1,?,1)");
        defer graph_insert.deinit();
        try graph_insert.bindText(1, graph_name);
        if ((try graph_insert.step()) != .done or self.sqlite_db.changes() != 1) return error.GraphInvalid;
        var type_insert = try self.prepareSchema("insert into {s}_zova_graph_edge_types(edge_type_key,graph_key,name) values(?,1,?)");
        defer type_insert.deinit();
        for (type_names.items, 0..) |name, type_index| {
            try type_insert.bindInt64(1, @intCast(type_index + 1));
            try type_insert.bindText(2, name);
            if ((try type_insert.step()) != .done or self.sqlite_db.changes() != 1) return error.GraphInvalid;
            try type_insert.reset();
            try type_insert.clearBindings();
        }
        if (profile) |value| value.graph_and_types_ms = graphProfileElapsedMs(metadata_start);

        const node_start = graphProfileTimestamp();
        var node_insert = try self.prepareSchema(
            "insert into {s}_zova_graph_nodes(node_key,graph_key,node_id,kind,target_type,target_namespace,target_ref,created_order) values(?,1,?,?,?,?,?,?)",
        );
        defer node_insert.deinit();
        for (nodes, 0..) |node, index| {
            const node_key: i64 = @intCast(index + 1);
            try node_insert.bindInt64(1, node_key);
            try node_insert.bindText(2, node.node_id);
            try node_insert.bindText(3, node.kind);
            try node_insert.bindText(4, targetTypeText(node.target_type));
            if (node.target_namespace) |value| try node_insert.bindText(5, value) else try node_insert.bindNull(5);
            if (node.target_ref) |value| try node_insert.bindText(6, value) else try node_insert.bindNull(6);
            try node_insert.bindInt64(7, node_key);
            if ((try node_insert.step()) != .done or self.sqlite_db.changes() != 1) return error.GraphInvalid;
            try node_insert.reset();
            try node_insert.clearBindings();
        }
        if (profile) |value| value.node_load_ms = graphProfileElapsedMs(node_start);

        const edge_start = graphProfileTimestamp();
        var edge_insert = try self.prepareSchema(
            "insert into {s}_zova_graph_edges(edge_key,graph_key,from_node_key,edge_type_key,to_node_key,created_order,payload) values(?,1,?,?,?,?,?)",
        );
        defer edge_insert.deinit();
        var payload_bytes: u64 = 0;
        for (edges, edge_type_slots, 0..) |edge, type_slot, index| {
            const edge_key: i64 = @intCast(index + 1);
            try edge_insert.bindInt64(1, edge_key);
            try edge_insert.bindInt64(2, @intCast(edge.from_node_ordinal + 1));
            try edge_insert.bindInt64(3, @intCast(type_slot + 1));
            try edge_insert.bindInt64(4, @intCast(edge.to_node_ordinal + 1));
            try edge_insert.bindInt64(5, edge_key);
            try edge_insert.bindBlobBorrowed(6, edge.payload);
            payload_bytes = std.math.add(u64, payload_bytes, edge.payload.len) catch return error.InvalidArgument;
            if ((try edge_insert.step()) != .done or self.sqlite_db.changes() != 1) return error.GraphInvalid;
            try edge_insert.reset();
            try edge_insert.clearBindings();
        }
        if (profile) |value| {
            value.edge_load_ms = graphProfileElapsedMs(edge_start);
            value.payload_bytes = payload_bytes;
        }

        const indexes_start = graphProfileTimestamp();
        try self.createGraphSecondaryIndexes();
        if (profile) |value| value.index_build_ms = graphProfileElapsedMs(indexes_start);
    }

    pub fn deleteGraph(self: *Database, name: []const u8) Error!void {
        try validateGraphName(name);
        var delete_graph = try self.prepareSchema("delete from {s}_zova_graphs where name = ?");
        defer delete_graph.deinit();
        try delete_graph.bindText(1, name);
        std.debug.assert((try delete_graph.step()) == .done);
        if (self.sqlite_db.changes() == 0) return error.GraphNotFound;
    }

    pub fn hasGraph(self: *Database, name: []const u8) Error!bool {
        try validateGraphName(name);

        var stmt = try self.prepareSchema("select count(*) from {s}_zova_graphs where name = ?");
        defer stmt.deinit();
        try stmt.bindText(1, name);
        std.debug.assert((try stmt.step()) == .row);
        return stmt.columnInt64(0) == 1;
    }

    fn graphKey(self: *Database, name: []const u8) Error!i64 {
        var stmt = try self.prepareSchema("select graph_key from {s}_zova_graphs where name = ?");
        defer stmt.deinit();
        try stmt.bindText(1, name);
        return switch (try stmt.step()) {
            .done => error.GraphNotFound,
            .row => stmt.columnInt64(0),
        };
    }

    fn ensureGraphEdgeType(self: *Database, graph_key: i64, name: []const u8) Error!i64 {
        var insert = try self.prepareSchema(
            \\insert into {s}_zova_graph_edge_types(graph_key,name) values(?1,?2)
            \\on conflict(graph_key,name) do nothing
        );
        defer insert.deinit();
        try insert.bindInt64(1, graph_key);
        try insert.bindText(2, name);
        if ((try insert.step()) != .done) return error.GraphInvalid;

        var select = try self.prepareSchema(
            "select edge_type_key from {s}_zova_graph_edge_types where graph_key=?1 and name=?2",
        );
        defer select.deinit();
        try select.bindInt64(1, graph_key);
        try select.bindText(2, name);
        if ((try select.step()) != .row) return error.GraphInvalid;
        const key = select.columnInt64(0);
        if (key <= 0) return error.GraphInvalid;
        return key;
    }

    fn resolveGraphEdgeTypes(
        self: *Database,
        normalized_edges: []const NormalizedGraphEdge,
        endpoints: *const ResolvedGraphEndpointSlots,
    ) Error!GraphEdgeTypeKeyMap {
        var result = GraphEdgeTypeKeyMap.init(std.heap.c_allocator);
        errdefer result.deinit();
        for (normalized_edges) |edge| {
            const endpoint = endpoints.items[edge.from_slot] orelse return error.GraphNodeNotFound;
            const tuple = GraphEdgeTypeTuple{ .graph_key = endpoint.graph_key, .name = edge.input.edge_type };
            if (!result.contains(tuple)) try result.put(tuple, try self.ensureGraphEdgeType(tuple.graph_key, tuple.name));
        }
        return result;
    }

    pub fn graphInfo(self: *Database, allocator: std.mem.Allocator, name: []const u8) Error!GraphInfo {
        try validateGraphName(name);

        var stmt = try self.prepareSchema(
            \\select g.name,
            \\  (select count(*) from {s}_zova_graph_nodes n where n.graph_key = g.graph_key),
            \\  (select count(*) from {s}_zova_graph_edges e where e.graph_key = g.graph_key)
            \\from {s}_zova_graphs g
            \\where g.name = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, name);

        return switch (try stmt.step()) {
            .done => error.GraphNotFound,
            .row => try graphInfoFromRow(allocator, &stmt),
        };
    }

    pub fn listGraphs(self: *Database, allocator: std.mem.Allocator) Error!GraphList {
        var stmt = try self.prepareSchema(
            \\select g.name,
            \\  (select count(*) from {s}_zova_graph_nodes n where n.graph_key = g.graph_key),
            \\  (select count(*) from {s}_zova_graph_edges e where e.graph_key = g.graph_key)
            \\from {s}_zova_graphs g
            \\order by g.name
        );
        defer stmt.deinit();

        var items: std.ArrayList(GraphInfo) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        while (try stmt.step() == .row) {
            try appendGraphInfoFromRow(&items, allocator, &stmt);
        }

        return .{ .items = try items.toOwnedSlice(allocator) };
    }

    pub fn putGraphNode(self: *Database, input: GraphNodeInput) Error!void {
        try validateGraphName(input.graph_name);
        try validateNodeId(input.node_id);
        try validateNodeKind(input.kind);
        if (input.target_namespace) |value| try validateOptionalText(value);
        if (input.target_ref) |value| try validateOptionalText(value);
        const graph_key = try self.graphKey(input.graph_name);

        var stmt = try self.prepareSchema(
            \\insert into {s}_zova_graph_nodes
            \\  (graph_key, node_id, kind, target_type, target_namespace, target_ref, created_order)
            \\values (?, ?, ?, ?, ?, ?, coalesce((select max(created_order) + 1 from {s}_zova_graph_nodes where graph_key = ?), 1))
            \\on conflict(graph_key, node_id) do update set
            \\  kind = excluded.kind,
            \\  target_type = excluded.target_type,
            \\  target_namespace = excluded.target_namespace,
            \\  target_ref = excluded.target_ref
        );
        defer stmt.deinit();

        try stmt.bindInt64(1, graph_key);
        try stmt.bindText(2, input.node_id);
        try stmt.bindText(3, input.kind);
        try stmt.bindText(4, targetTypeText(input.target_type));
        if (input.target_namespace) |value| {
            try stmt.bindText(5, value);
        } else {
            try stmt.bindNull(5);
        }
        if (input.target_ref) |value| {
            try stmt.bindText(6, value);
        } else {
            try stmt.bindNull(6);
        }
        try stmt.bindInt64(7, graph_key);
        std.debug.assert((try stmt.step()) == .done);
    }

    /// Upsert graph nodes as one all-or-nothing batch.
    ///
    /// Every graph must already exist. Repeated node ids are applied in input
    /// order, so the final occurrence supplies the stored node fields.
    pub fn putGraphNodes(self: *Database, inputs: []const GraphNodeInput) Error!void {
        var graph_keys: std.StringHashMap(i64) = .init(std.heap.c_allocator);
        defer graph_keys.deinit();
        for (inputs) |input| {
            try validateGraphName(input.graph_name);
            try validateNodeId(input.node_id);
            try validateNodeKind(input.kind);
            if (input.target_namespace) |value| try validateOptionalText(value);
            if (input.target_ref) |value| try validateOptionalText(value);
            if (!graph_keys.contains(input.graph_name)) {
                try graph_keys.put(input.graph_name, try self.graphKey(input.graph_name));
            }
        }
        if (inputs.len == 0) return;

        try ensureGraphBatchIndexes(self);

        var stmt = try self.prepareSchema(
            \\insert into {s}_zova_graph_nodes
            \\  (graph_key, node_id, kind, target_type, target_namespace, target_ref, created_order)
            \\values (?, ?, ?, ?, ?, ?, ?)
            \\on conflict(graph_key, node_id) do update set
            \\  kind = excluded.kind,
            \\  target_type = excluded.target_type,
            \\  target_namespace = excluded.target_namespace,
            \\  target_ref = excluded.target_ref
        );
        defer stmt.deinit();

        var next_order_stmt = try self.prepareSchema(
            \\select coalesce(max(created_order), 0) + 1
            \\from {s}_zova_graph_nodes
            \\where graph_key = ?
        );
        defer next_order_stmt.deinit();
        var next_orders: std.AutoHashMap(i64, i64) = .init(std.heap.c_allocator);
        defer next_orders.deinit();

        for (inputs) |input| {
            const graph_key = graph_keys.get(input.graph_name) orelse return error.GraphNotFound;
            const created_order = try nextGraphCreatedOrder(&next_order_stmt, &next_orders, graph_key);
            try bindGraphNodeInput(&stmt, graph_key, input, created_order);
            std.debug.assert((try stmt.step()) == .done);
            try stmt.reset();
            try stmt.clearBindings();
        }
    }

    /// Upsert graph nodes and return one opaque database-local key per input.
    pub fn putGraphNodesKeyed(self: *Database, inputs: []const GraphNodeInput, out_keys: []i64) Error!void {
        if (out_keys.len != inputs.len) return error.InvalidArgument;
        var graph_keys: std.StringHashMap(i64) = .init(std.heap.c_allocator);
        defer graph_keys.deinit();
        var key_slots = GraphNodeKeySlotMap.init(std.heap.c_allocator);
        defer key_slots.deinit();
        const input_slots = try std.heap.c_allocator.alloc(usize, inputs.len);
        defer std.heap.c_allocator.free(input_slots);
        var distinct_key_count: usize = 0;
        for (inputs, input_slots) |input, *input_slot| {
            try validateGraphName(input.graph_name);
            try validateNodeId(input.node_id);
            try validateNodeKind(input.kind);
            if (input.target_namespace) |value| try validateOptionalText(value);
            if (input.target_ref) |value| try validateOptionalText(value);
            if (!graph_keys.contains(input.graph_name)) {
                try graph_keys.put(input.graph_name, try self.graphKey(input.graph_name));
            }
            const graph_key = graph_keys.get(input.graph_name) orelse return error.GraphNotFound;
            const result = try key_slots.getOrPut(.{ .graph_key = graph_key, .node_id = input.node_id });
            if (!result.found_existing) {
                result.value_ptr.* = distinct_key_count;
                distinct_key_count += 1;
            }
            input_slot.* = result.value_ptr.*;
        }
        if (inputs.len == 0) return;

        const resolved_keys = try std.heap.c_allocator.alloc(?i64, distinct_key_count);
        defer std.heap.c_allocator.free(resolved_keys);
        @memset(resolved_keys, null);
        var preload = try self.prepareSchema(
            \\/* zova_graph_node_key_preload */
            \\select node_id,node_key from {s}_zova_graph_nodes where graph_key=?
        );
        defer preload.deinit();
        var graph_key_iterator = graph_keys.valueIterator();
        while (graph_key_iterator.next()) |graph_key| {
            try preload.bindInt64(1, graph_key.*);
            while ((try preload.step()) == .row) {
                const slot = key_slots.get(.{ .graph_key = graph_key.*, .node_id = preload.columnText(0) }) orelse continue;
                const node_key = preload.columnInt64(1);
                if (node_key <= 0) return error.GraphInvalid;
                resolved_keys[slot] = node_key;
            }
            try preload.reset();
            try preload.clearBindings();
        }

        try ensureGraphBatchIndexes(self);
        var stmt = try self.prepareSchema(
            \\insert into {s}_zova_graph_nodes
            \\  (graph_key, node_id, kind, target_type, target_namespace, target_ref, created_order)
            \\values (?, ?, ?, ?, ?, ?, ?)
            \\on conflict(graph_key, node_id) do update set
            \\  kind = excluded.kind,
            \\  target_type = excluded.target_type,
            \\  target_namespace = excluded.target_namespace,
            \\  target_ref = excluded.target_ref
        );
        defer stmt.deinit();
        var next_order_stmt = try self.prepareSchema(
            \\select coalesce(max(created_order), 0) + 1
            \\from {s}_zova_graph_nodes
            \\where graph_key = ?
        );
        defer next_order_stmt.deinit();
        var next_orders: std.AutoHashMap(i64, i64) = .init(std.heap.c_allocator);
        defer next_orders.deinit();

        for (inputs, input_slots, out_keys) |input, slot, *out_key| {
            const graph_key = graph_keys.get(input.graph_name) orelse return error.GraphNotFound;
            const created_order = try nextGraphCreatedOrder(&next_order_stmt, &next_orders, graph_key);
            try bindGraphNodeInput(&stmt, graph_key, input, created_order);
            if ((try stmt.step()) != .done) return error.GraphInvalid;
            if (resolved_keys[slot]) |node_key| {
                out_key.* = node_key;
            } else {
                if (self.sqlite_db.changes() != 1) return error.GraphInvalid;
                const node_key = self.sqlite_db.lastInsertRowId();
                if (node_key <= 0) return error.GraphInvalid;
                resolved_keys[slot] = node_key;
                out_key.* = node_key;
            }
            try stmt.reset();
            try stmt.clearBindings();
        }
    }

    pub fn getGraphNode(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, node_id: []const u8) Error!GraphNode {
        const resolved = try self.getGraphNodeWithKey(allocator, graph_name, node_id);
        return resolved.node;
    }

    fn getGraphNodeWithKey(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, node_id: []const u8) Error!struct { node: GraphNode, graph_key: i64 } {
        try validateGraphName(graph_name);
        try validateNodeId(node_id);

        var stmt = try self.prepareSchema(
            \\select g.name, n.node_id, n.kind, n.target_type, n.target_namespace, n.target_ref, g.graph_key
            \\from {s}_zova_graph_nodes n
            \\join {s}_zova_graphs g on g.graph_key = n.graph_key
            \\where g.name = ? and n.node_id = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, graph_name);
        try stmt.bindText(2, node_id);

        return switch (try stmt.step()) {
            .done => error.GraphNodeNotFound,
            .row => .{ .node = try nodeFromRow(allocator, &stmt), .graph_key = stmt.columnInt64(6) },
        };
    }

    pub fn hasGraphNode(self: *Database, graph_name: []const u8, node_id: []const u8) Error!bool {
        try validateGraphName(graph_name);
        try validateNodeId(node_id);

        var stmt = try self.prepareSchema(
            \\select count(*)
            \\from {s}_zova_graph_nodes n
            \\join {s}_zova_graphs g on g.graph_key = n.graph_key
            \\where g.name = ? and n.node_id = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, graph_name);
        try stmt.bindText(2, node_id);
        std.debug.assert((try stmt.step()) == .row);
        return stmt.columnInt64(0) == 1;
    }

    pub fn deleteGraphNode(self: *Database, graph_name: []const u8, node_id: []const u8) Error!void {
        try validateGraphName(graph_name);
        try validateNodeId(node_id);
        var delete_node = try self.prepareSchema(
            \\delete from {s}_zova_graph_nodes
            \\where graph_key = (select graph_key from {s}_zova_graphs where name = ?)
            \\  and node_id = ?
        );
        defer delete_node.deinit();
        try delete_node.bindText(1, graph_name);
        try delete_node.bindText(2, node_id);
        std.debug.assert((try delete_node.step()) == .done);
        if (self.sqlite_db.changes() == 0) return error.GraphNodeNotFound;
    }

    /// Delete graph nodes and all of their incident edges as one batch.
    ///
    /// Missing node ids are ignored so repeated incremental deletions are
    /// idempotent. A missing graph remains an error.
    pub fn deleteGraphNodes(self: *Database, graph_name: []const u8, node_ids: []const []const u8) Error!void {
        try validateGraphName(graph_name);
        for (node_ids) |node_id| try validateNodeId(node_id);
        if (!try self.hasGraph(graph_name)) return error.GraphNotFound;
        if (node_ids.len == 0) return;

        try ensureGraphBatchIndexes(self);
        try self.sqlite_db.exec(
            \\create temp table if not exists temp._zova_graph_batch_delete_ids (
            \\  node_id text not null primary key
            \\) without rowid;
            \\delete from temp._zova_graph_batch_delete_ids;
        );
        defer self.sqlite_db.exec("delete from temp._zova_graph_batch_delete_ids") catch {};

        var insert_id = try self.prepareSchema("insert or ignore into temp._zova_graph_batch_delete_ids (node_id) values (?)");
        defer insert_id.deinit();
        for (node_ids) |node_id| {
            try insert_id.bindText(1, node_id);
            std.debug.assert((try insert_id.step()) == .done);
            try insert_id.reset();
            try insert_id.clearBindings();
        }

        var delete_nodes = try self.prepareSchema(
            \\delete from {s}_zova_graph_nodes
            \\where graph_key = (select graph_key from {s}_zova_graphs where name = ?)
            \\  and node_id in (select node_id from temp._zova_graph_batch_delete_ids)
        );
        defer delete_nodes.deinit();
        try delete_nodes.bindText(1, graph_name);
        std.debug.assert((try delete_nodes.step()) == .done);
    }

    pub fn putGraphEdge(self: *Database, input: GraphEdgeInput) Error!void {
        return self.putGraphEdges(&.{input});
    }

    /// Insert typed directed graph edges as one all-or-nothing batch.
    ///
    /// Both endpoints must already exist for every input. Exact duplicate edges
    /// are idempotent and retain their original insertion order.
    pub fn putGraphEdges(self: *Database, inputs: []const GraphEdgeInput) Error!void {
        if (inputs.len == 0) return;

        var graph_names = std.StringHashMap(void).init(std.heap.c_allocator);
        defer graph_names.deinit();
        var edge_types = std.StringHashMap(void).init(std.heap.c_allocator);
        defer edge_types.deinit();
        var endpoint_slots = GraphBatchEndpointSlotMap.init(std.heap.c_allocator);
        defer endpoint_slots.deinit();
        var distinct_endpoints: std.ArrayList(GraphBatchEndpoint) = .empty;
        defer distinct_endpoints.deinit(std.heap.c_allocator);
        const normalized_edges = try std.heap.c_allocator.alloc(NormalizedGraphEdge, inputs.len);
        defer std.heap.c_allocator.free(normalized_edges);

        for (inputs, 0..) |input, index| {
            if (!graph_names.contains(input.graph_name)) {
                try validateGraphName(input.graph_name);
                try graph_names.put(input.graph_name, {});
            }
            if (!edge_types.contains(input.edge_type)) {
                try validateEdgeType(input.edge_type);
                try edge_types.put(input.edge_type, {});
            }

            const from_slot = try graphEndpointSlot(
                &endpoint_slots,
                &distinct_endpoints,
                .{ .graph_name = input.graph_name, .node_id = input.from_node_id },
            );
            const to_slot = try graphEndpointSlot(
                &endpoint_slots,
                &distinct_endpoints,
                .{ .graph_name = input.graph_name, .node_id = input.to_node_id },
            );
            normalized_edges[index] = .{
                .input = input,
                .from_slot = from_slot,
                .to_slot = to_slot,
            };
        }

        try ensureGraphBatchIndexes(self);
        var resolved_endpoints = try self.resolvePutGraphBatchEndpoints(distinct_endpoints.items);
        defer resolved_endpoints.deinit();
        defer self.clearPutGraphBatchEndpoints();
        var resolved_edge_types = try self.resolveGraphEdgeTypes(normalized_edges, &resolved_endpoints);
        defer resolved_edge_types.deinit();

        var stmt = try self.prepareSchema(
            \\/* zova_graph_edge_insert */
            \\insert into {s}_zova_graph_edges (graph_key, from_node_key, edge_type_key, to_node_key, created_order)
            \\values (?, ?, ?, ?, ?)
            \\on conflict(from_node_key, edge_type_key, to_node_key) do nothing
        );
        defer stmt.deinit();

        var next_order_stmt = try self.prepareSchema(
            \\select coalesce(max(created_order), 0) + 1
            \\from {s}_zova_graph_edges
            \\where graph_key = ?
        );
        defer next_order_stmt.deinit();
        var next_orders: std.AutoHashMap(i64, i64) = .init(std.heap.c_allocator);
        defer next_orders.deinit();

        for (normalized_edges) |edge| {
            const from_endpoint = resolved_endpoints.items[edge.from_slot] orelse return error.GraphNodeNotFound;
            const to_endpoint = resolved_endpoints.items[edge.to_slot] orelse return error.GraphNodeNotFound;
            if (from_endpoint.graph_key != to_endpoint.graph_key) return error.GraphInvalid;
            const graph_key = from_endpoint.graph_key;
            const edge_type_key = resolved_edge_types.get(.{ .graph_key = graph_key, .name = edge.input.edge_type }) orelse return error.GraphInvalid;
            const created_order = try nextGraphCreatedOrder(&next_order_stmt, &next_orders, graph_key);
            try stmt.bindInt64(1, graph_key);
            try stmt.bindInt64(2, from_endpoint.node_key);
            try stmt.bindInt64(3, edge_type_key);
            try stmt.bindInt64(4, to_endpoint.node_key);
            try stmt.bindInt64(5, created_order);
            std.debug.assert((try stmt.step()) == .done);
            try stmt.reset();
            try stmt.clearBindings();
        }
    }

    /// Insert graph edges and return one opaque database-local key per input.
    pub fn putGraphEdgesKeyed(self: *Database, inputs: []const GraphEdgeInput, out_keys: []i64) Error!void {
        if (out_keys.len != inputs.len) return error.InvalidArgument;
        if (inputs.len == 0) return;

        var graph_names = std.StringHashMap(void).init(std.heap.c_allocator);
        defer graph_names.deinit();
        var edge_types = std.StringHashMap(void).init(std.heap.c_allocator);
        defer edge_types.deinit();
        var endpoint_slots = GraphBatchEndpointSlotMap.init(std.heap.c_allocator);
        defer endpoint_slots.deinit();
        var distinct_endpoints: std.ArrayList(GraphBatchEndpoint) = .empty;
        defer distinct_endpoints.deinit(std.heap.c_allocator);
        const normalized_edges = try std.heap.c_allocator.alloc(NormalizedGraphEdge, inputs.len);
        defer std.heap.c_allocator.free(normalized_edges);

        for (inputs, 0..) |input, index| {
            if (!graph_names.contains(input.graph_name)) {
                try validateGraphName(input.graph_name);
                try graph_names.put(input.graph_name, {});
            }
            if (!edge_types.contains(input.edge_type)) {
                try validateEdgeType(input.edge_type);
                try edge_types.put(input.edge_type, {});
            }
            normalized_edges[index] = .{
                .input = input,
                .from_slot = try graphEndpointSlot(&endpoint_slots, &distinct_endpoints, .{
                    .graph_name = input.graph_name,
                    .node_id = input.from_node_id,
                }),
                .to_slot = try graphEndpointSlot(&endpoint_slots, &distinct_endpoints, .{
                    .graph_name = input.graph_name,
                    .node_id = input.to_node_id,
                }),
            };
        }

        try ensureGraphBatchIndexes(self);
        var resolved_endpoints = try self.resolvePutGraphBatchEndpoints(distinct_endpoints.items);
        defer resolved_endpoints.deinit();
        defer self.clearPutGraphBatchEndpoints();
        var resolved_edge_types = try self.resolveGraphEdgeTypes(normalized_edges, &resolved_endpoints);
        defer resolved_edge_types.deinit();

        var key_slots = GraphEdgeKeySlotMap.init(std.heap.c_allocator);
        defer key_slots.deinit();
        const input_key_slots = try std.heap.c_allocator.alloc(usize, normalized_edges.len);
        defer std.heap.c_allocator.free(input_key_slots);
        var affected_graph_keys = std.AutoHashMap(i64, void).init(std.heap.c_allocator);
        defer affected_graph_keys.deinit();
        var distinct_key_count: usize = 0;
        for (normalized_edges, input_key_slots) |edge, *input_key_slot| {
            const from = resolved_endpoints.items[edge.from_slot] orelse return error.GraphNodeNotFound;
            const to = resolved_endpoints.items[edge.to_slot] orelse return error.GraphNodeNotFound;
            if (from.graph_key != to.graph_key) return error.GraphInvalid;
            const edge_type_key = resolved_edge_types.get(.{ .graph_key = from.graph_key, .name = edge.input.edge_type }) orelse return error.GraphInvalid;
            try affected_graph_keys.put(from.graph_key, {});
            const result = try key_slots.getOrPut(.{
                .graph_key = from.graph_key,
                .from_node_key = from.node_key,
                .edge_type_key = edge_type_key,
                .to_node_key = to.node_key,
            });
            if (!result.found_existing) {
                result.value_ptr.* = distinct_key_count;
                distinct_key_count += 1;
            }
            input_key_slot.* = result.value_ptr.*;
        }
        const resolved_keys = try std.heap.c_allocator.alloc(?i64, distinct_key_count);
        defer std.heap.c_allocator.free(resolved_keys);
        @memset(resolved_keys, null);
        var preload = try self.prepareSchema(
            \\/* zova_graph_edge_key_preload */
            \\select e.from_node_key,e.edge_type_key,e.to_node_key,e.edge_key
            \\from {s}_zova_graph_edges e where e.graph_key=?
        );
        defer preload.deinit();
        var affected_graph_key_iterator = affected_graph_keys.keyIterator();
        while (affected_graph_key_iterator.next()) |graph_key| {
            try preload.bindInt64(1, graph_key.*);
            while ((try preload.step()) == .row) {
                const slot = key_slots.get(.{
                    .graph_key = graph_key.*,
                    .from_node_key = preload.columnInt64(0),
                    .edge_type_key = preload.columnInt64(1),
                    .to_node_key = preload.columnInt64(2),
                }) orelse continue;
                const edge_key = preload.columnInt64(3);
                if (edge_key <= 0) return error.GraphInvalid;
                resolved_keys[slot] = edge_key;
            }
            try preload.reset();
            try preload.clearBindings();
        }

        var insert = try self.prepareSchema(
            \\/* zova_graph_edge_insert */
            \\insert into {s}_zova_graph_edges (graph_key, from_node_key, edge_type_key, to_node_key, created_order)
            \\values (?, ?, ?, ?, ?)
            \\on conflict(from_node_key, edge_type_key, to_node_key) do nothing
        );
        defer insert.deinit();
        var next_order_stmt = try self.prepareSchema(
            \\select coalesce(max(created_order), 0) + 1
            \\from {s}_zova_graph_edges
            \\where graph_key = ?
        );
        defer next_order_stmt.deinit();
        var next_orders: std.AutoHashMap(i64, i64) = .init(std.heap.c_allocator);
        defer next_orders.deinit();

        for (normalized_edges, input_key_slots, out_keys) |edge, key_slot, *out_key| {
            const from = resolved_endpoints.items[edge.from_slot] orelse return error.GraphNodeNotFound;
            const to = resolved_endpoints.items[edge.to_slot] orelse return error.GraphNodeNotFound;
            if (from.graph_key != to.graph_key) return error.GraphInvalid;
            const edge_type_key = resolved_edge_types.get(.{ .graph_key = from.graph_key, .name = edge.input.edge_type }) orelse return error.GraphInvalid;
            const created_order = try nextGraphCreatedOrder(&next_order_stmt, &next_orders, from.graph_key);
            if (resolved_keys[key_slot]) |edge_key| {
                out_key.* = edge_key;
                continue;
            }
            try insert.bindInt64(1, from.graph_key);
            try insert.bindInt64(2, from.node_key);
            try insert.bindInt64(3, edge_type_key);
            try insert.bindInt64(4, to.node_key);
            try insert.bindInt64(5, created_order);
            if ((try insert.step()) != .done) return error.GraphInvalid;
            if (self.sqlite_db.changes() != 1) return error.GraphInvalid;
            const edge_key = self.sqlite_db.lastInsertRowId();
            if (edge_key <= 0) return error.GraphInvalid;
            resolved_keys[key_slot] = edge_key;
            out_key.* = edge_key;
            try insert.reset();
            try insert.clearBindings();
        }
    }

    pub fn hasGraphEdge(self: *Database, graph_name: []const u8, from_node_id: []const u8, edge_type: []const u8, to_node_id: []const u8) Error!bool {
        try validateGraphName(graph_name);
        try validateNodeId(from_node_id);
        try validateEdgeType(edge_type);
        try validateNodeId(to_node_id);

        var stmt = try self.prepareSchema(
            \\select count(*)
            \\from {s}_zova_graph_edges e
            \\join {s}_zova_graph_edge_types et on et.edge_type_key=e.edge_type_key
            \\where (e.graph_key,e.from_node_key,e.to_node_key)=(
            \\  select g.graph_key,src.node_key,dst.node_key
            \\  from {s}_zova_graphs g
            \\  join {s}_zova_graph_nodes src on src.graph_key=g.graph_key and src.node_id=?2
            \\  join {s}_zova_graph_nodes dst on dst.graph_key=g.graph_key and dst.node_id=?4
            \\  where g.name=?1
            \\) and et.name=?3
        );
        defer stmt.deinit();
        try stmt.bindText(1, graph_name);
        try stmt.bindText(2, from_node_id);
        try stmt.bindText(3, edge_type);
        try stmt.bindText(4, to_node_id);
        std.debug.assert((try stmt.step()) == .row);
        return stmt.columnInt64(0) == 1;
    }

    pub fn getGraphEdge(
        self: *Database,
        allocator: std.mem.Allocator,
        graph_name: []const u8,
        from_node_id: []const u8,
        edge_type: []const u8,
        to_node_id: []const u8,
    ) Error!GraphEdge {
        try validateGraphName(graph_name);
        try validateNodeId(from_node_id);
        try validateEdgeType(edge_type);
        try validateNodeId(to_node_id);

        var stmt = try self.prepareSchema(
            \\select g.name, src.node_id, et.name, dst.node_id
            \\from {s}_zova_graph_edges e
            \\join {s}_zova_graphs g on g.graph_key = e.graph_key
            \\join {s}_zova_graph_edge_types et on et.edge_type_key=e.edge_type_key
            \\join {s}_zova_graph_nodes src on src.node_key = e.from_node_key
            \\join {s}_zova_graph_nodes dst on dst.node_key = e.to_node_key
            \\where g.name = ? and src.node_id = ? and et.name = ? and dst.node_id = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, graph_name);
        try stmt.bindText(2, from_node_id);
        try stmt.bindText(3, edge_type);
        try stmt.bindText(4, to_node_id);

        return switch (try stmt.step()) {
            .done => error.GraphEdgeNotFound,
            .row => try graphEdgeFromRow(allocator, &stmt),
        };
    }

    pub fn deleteGraphEdge(self: *Database, input: GraphEdgeInput) Error!void {
        try validateGraphName(input.graph_name);
        try validateNodeId(input.from_node_id);
        try validateEdgeType(input.edge_type);
        try validateNodeId(input.to_node_id);
        if (!try self.hasGraphEdge(input.graph_name, input.from_node_id, input.edge_type, input.to_node_id)) return error.GraphEdgeNotFound;

        var stmt = try self.prepareSchema(
            \\delete from {s}_zova_graph_edges
            \\where graph_key = (select graph_key from {s}_zova_graphs where name = ?)
            \\  and from_node_key = (select node_key from {s}_zova_graph_nodes where graph_key = (select graph_key from {s}_zova_graphs where name = ?) and node_id = ?)
            \\  and edge_type_key = (select edge_type_key from {s}_zova_graph_edge_types where graph_key=(select graph_key from {s}_zova_graphs where name=?) and name=?)
            \\  and to_node_key = (select node_key from {s}_zova_graph_nodes where graph_key = (select graph_key from {s}_zova_graphs where name = ?) and node_id = ?)
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.graph_name);
        try stmt.bindText(2, input.graph_name);
        try stmt.bindText(3, input.from_node_id);
        try stmt.bindText(4, input.graph_name);
        try stmt.bindText(5, input.edge_type);
        try stmt.bindText(6, input.graph_name);
        try stmt.bindText(7, input.to_node_id);
        std.debug.assert((try stmt.step()) == .done);
    }

    /// Delete exact graph edges as one validated idempotent batch.
    pub fn deleteGraphEdges(self: *Database, inputs: []const GraphEdgeInput) Error!void {
        for (inputs) |input| {
            try validateGraphName(input.graph_name);
            try validateNodeId(input.from_node_id);
            try validateEdgeType(input.edge_type);
            try validateNodeId(input.to_node_id);
        }
        if (inputs.len == 0) return;
        var graphs: std.StringHashMap(void) = .init(std.heap.c_allocator);
        defer graphs.deinit();
        for (inputs) |input| if (!graphs.contains(input.graph_name)) {
            _ = try self.graphKey(input.graph_name);
            try graphs.put(input.graph_name, {});
        };
        try self.resolveGraphBatchEndpoints(inputs, null, false);
        defer self.clearGraphBatchEndpoints();
        var endpoints = try self.loadResolvedBatchEndpoints(inputs);
        defer endpoints.deinit();

        var stmt = try self.prepareSchema(
            \\delete from {s}_zova_graph_edges
            \\where graph_key = ?
            \\  and from_node_key = ?
            \\  and edge_type_key = (select edge_type_key from {s}_zova_graph_edge_types where graph_key=? and name=?)
            \\  and to_node_key = ?
        );
        defer stmt.deinit();
        for (inputs) |input| {
            const graph_key = endpoints.graphKey(input.graph_name) orelse continue;
            const from_node_key = endpoints.nodeKey(input.graph_name, input.from_node_id) orelse continue;
            const to_node_key = endpoints.nodeKey(input.graph_name, input.to_node_id) orelse continue;
            try stmt.bindInt64(1, graph_key);
            try stmt.bindInt64(2, from_node_key);
            try stmt.bindInt64(3, graph_key);
            try stmt.bindText(4, input.edge_type);
            try stmt.bindInt64(5, to_node_key);
            std.debug.assert((try stmt.step()) == .done);
            try stmt.reset();
            try stmt.clearBindings();
        }
    }

    fn graphEndpointSlot(
        endpoint_slots: *GraphBatchEndpointSlotMap,
        distinct_endpoints: *std.ArrayList(GraphBatchEndpoint),
        endpoint: GraphBatchEndpoint,
    ) Error!usize {
        if (endpoint_slots.get(endpoint)) |slot| return slot;

        try validateNodeId(endpoint.node_id);
        const slot = distinct_endpoints.items.len;
        try distinct_endpoints.append(std.heap.c_allocator, endpoint);
        errdefer _ = distinct_endpoints.pop();
        try endpoint_slots.put(endpoint, slot);
        return slot;
    }

    fn resolvePutGraphBatchEndpoints(
        self: *Database,
        distinct_endpoints: []const GraphBatchEndpoint,
    ) Error!ResolvedGraphEndpointSlots {
        try self.sqlite_db.exec(
            \\create temp table if not exists temp._zova_graph_put_batch_endpoints (
            \\  slot integer primary key,
            \\  graph_name text not null,
            \\  node_id text not null
            \\);
            \\delete from temp._zova_graph_put_batch_endpoints;
        );
        errdefer self.clearPutGraphBatchEndpoints();

        var insert_endpoint = try self.prepareSchema(
            \\/* zova_graph_endpoint_stage */
            \\insert into temp._zova_graph_put_batch_endpoints (slot, graph_name, node_id) values (?, ?, ?)
        );
        defer insert_endpoint.deinit();
        for (distinct_endpoints, 0..) |endpoint, slot| {
            try insert_endpoint.bindInt64(1, @intCast(slot));
            try insert_endpoint.bindText(2, endpoint.graph_name);
            try insert_endpoint.bindText(3, endpoint.node_id);
            std.debug.assert((try insert_endpoint.step()) == .done);
            try insert_endpoint.reset();
            try insert_endpoint.clearBindings();
        }

        const items = try std.heap.c_allocator.alloc(?ResolvedGraphEndpoint, distinct_endpoints.len);
        errdefer std.heap.c_allocator.free(items);
        @memset(items, null);

        var resolve = try self.prepareSchema(
            \\/* zova_graph_batch_slot_resolve */
            \\select batch.slot, g.graph_key, n.node_key
            \\from temp._zova_graph_put_batch_endpoints batch
            \\join {s}_zova_graphs g on g.name = batch.graph_name
            \\join {s}_zova_graph_nodes n on n.graph_key = g.graph_key and n.node_id = batch.node_id
        );
        defer resolve.deinit();

        var resolved_count: usize = 0;
        while ((try resolve.step()) == .row) {
            const raw_slot = resolve.columnInt64(0);
            if (raw_slot < 0) return error.GraphInvalid;
            const slot: usize = @intCast(raw_slot);
            if (slot >= items.len or items[slot] != null) return error.GraphInvalid;
            items[slot] = .{
                .graph_key = resolve.columnInt64(1),
                .node_key = resolve.columnInt64(2),
            };
            resolved_count += 1;
        }
        if (resolved_count != distinct_endpoints.len) return error.GraphNodeNotFound;

        return .{ .items = items };
    }

    fn clearPutGraphBatchEndpoints(self: *Database) void {
        self.sqlite_db.exec("delete from temp._zova_graph_put_batch_endpoints") catch {};
    }

    fn resolveGraphBatchEndpoints(
        self: *Database,
        inputs: []const GraphEdgeInput,
        distinct_endpoints: ?[]const GraphBatchEndpoint,
        require_all: bool,
    ) Error!void {
        try self.sqlite_db.exec(
            \\create temp table if not exists temp._zova_graph_batch_endpoints (
            \\  graph_name text not null,
            \\  node_id text not null,
            \\  primary key (graph_name, node_id)
            \\) without rowid;
            \\create temp table if not exists temp._zova_graph_batch_resolved (
            \\  graph_name text not null,
            \\  node_id text not null,
            \\  graph_key integer not null,
            \\  node_key integer not null,
            \\  primary key (graph_name, node_id)
            \\) without rowid;
            \\delete from temp._zova_graph_batch_endpoints;
            \\delete from temp._zova_graph_batch_resolved;
        );

        var insert_endpoint = try self.prepareSchema(
            \\/* zova_graph_endpoint_stage */
            \\insert or ignore into temp._zova_graph_batch_endpoints (graph_name, node_id) values (?, ?)
        );
        defer insert_endpoint.deinit();
        if (distinct_endpoints) |endpoints| {
            for (endpoints) |endpoint| {
                try insert_endpoint.bindText(1, endpoint.graph_name);
                try insert_endpoint.bindText(2, endpoint.node_id);
                std.debug.assert((try insert_endpoint.step()) == .done);
                try insert_endpoint.reset();
                try insert_endpoint.clearBindings();
            }
        } else for (inputs) |input| {
            const endpoints = [_][]const u8{ input.from_node_id, input.to_node_id };
            for (endpoints) |node_id| {
                try insert_endpoint.bindText(1, input.graph_name);
                try insert_endpoint.bindText(2, node_id);
                std.debug.assert((try insert_endpoint.step()) == .done);
                try insert_endpoint.reset();
                try insert_endpoint.clearBindings();
            }
        }

        var resolve = try self.prepareSchema(
            \\/* zova_graph_batch_resolve */
            \\insert into temp._zova_graph_batch_resolved (graph_name, node_id, graph_key, node_key)
            \\select batch.graph_name, batch.node_id, g.graph_key, n.node_key
            \\from temp._zova_graph_batch_endpoints batch
            \\join {s}_zova_graphs g on g.name = batch.graph_name
            \\join {s}_zova_graph_nodes n on n.graph_key = g.graph_key and n.node_id = batch.node_id
        );
        defer resolve.deinit();
        std.debug.assert((try resolve.step()) == .done);

        if (require_all) {
            var counts = try self.prepareSchema(
                \\select
                \\  (select count(*) from temp._zova_graph_batch_endpoints),
                \\  (select count(*) from temp._zova_graph_batch_resolved)
            );
            defer counts.deinit();
            std.debug.assert((try counts.step()) == .row);
            if (counts.columnInt64(0) != counts.columnInt64(1)) return error.GraphNodeNotFound;
        }
    }

    fn loadResolvedBatchEndpoints(self: *Database, inputs: []const GraphEdgeInput) Error!ResolvedBatchEndpoints {
        var result = ResolvedBatchEndpoints.init();
        errdefer result.deinit();
        for (inputs) |input| {
            if (!result.graphs.contains(input.graph_name)) {
                try result.graphs.put(input.graph_name, .{ .nodes = std.StringHashMap(i64).init(std.heap.c_allocator) });
            }
        }

        var stmt = try self.sqlite_db.prepare(
            "select graph_name,node_id,graph_key,node_key from temp._zova_graph_batch_resolved",
        );
        defer stmt.deinit();
        while ((try stmt.step()) == .row) {
            const graph = result.graphs.getPtr(stmt.columnText(0)) orelse return error.GraphInvalid;
            graph.graph_key = stmt.columnInt64(2);
            const node_id = try std.heap.c_allocator.dupe(u8, stmt.columnText(1));
            errdefer std.heap.c_allocator.free(node_id);
            try graph.nodes.put(node_id, stmt.columnInt64(3));
        }
        return result;
    }

    fn clearGraphBatchEndpoints(self: *Database) void {
        self.sqlite_db.exec(
            "delete from temp._zova_graph_batch_endpoints; delete from temp._zova_graph_batch_resolved;",
        ) catch {};
    }

    pub fn graphNeighbors(self: *Database, allocator: std.mem.Allocator, options: GraphNeighborsOptions) Error!GraphNeighborList {
        try validateGraphName(options.graph_name);
        try validateNodeId(options.node_id);
        if (options.edge_type) |edge_type| try validateEdgeType(edge_type);
        const graph_key = try self.graphKeyForRead(options.graph_name);
        const edge_type_key = if (options.edge_type) |edge_type| (try self.edgeTypeKeyForRead(graph_key, edge_type)) orelse -1 else null;
        const sqlite_limit = try sqliteLimit(options.limit);
        var stmt = switch (options.direction) {
            .outgoing => if (options.edge_type == null)
                try self.prepareSchema(
                    \\select n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key=e.to_node_key
                    \\where e.graph_key=?1 and e.from_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2)
                    \\order by e.created_order, e.to_node_key
                    \\limit ?3
                )
            else
                try self.prepareSchema(
                    \\select n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key=e.to_node_key
                    \\where e.graph_key=?1 and e.from_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2) and e.edge_type_key=?3
                    \\order by e.created_order, e.to_node_key
                    \\limit ?4
                ),
            .incoming => if (options.edge_type == null)
                try self.prepareSchema(
                    \\select n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key=e.from_node_key
                    \\where e.graph_key=?1 and e.to_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2)
                    \\order by e.created_order, e.from_node_key
                    \\limit ?3
                )
            else
                try self.prepareSchema(
                    \\select n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key=e.from_node_key
                    \\where e.graph_key=?1 and e.to_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2) and e.edge_type_key=?3
                    \\order by e.created_order, e.from_node_key
                    \\limit ?4
                ),
        };
        defer stmt.deinit();

        try stmt.bindInt64(1, graph_key);
        try stmt.bindText(2, options.node_id);
        if (edge_type_key) |key| {
            try stmt.bindInt64(3, key);
            try stmt.bindInt64(4, sqlite_limit);
        } else {
            try stmt.bindInt64(3, sqlite_limit);
        }

        var items: std.ArrayList(GraphNeighbor) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        while (try stmt.step() == .row) {
            const node_id = try allocator.dupe(u8, stmt.columnText(0));
            errdefer allocator.free(node_id);
            const kind = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(kind);
            const edge_type = try self.dupeEdgeTypeNameForRead(allocator, stmt.columnInt64(2));
            errdefer allocator.free(edge_type);
            try items.append(allocator, .{ .node_id = node_id, .kind = kind, .edge_type = edge_type });
        }
        if (items.items.len == 0 and !try self.hasGraphNode(options.graph_name, options.node_id)) {
            return error.GraphNodeNotFound;
        }

        return .{ .items = try items.toOwnedSlice(allocator) };
    }

    pub fn graphNeighborsKeyed(self: *Database, allocator: std.mem.Allocator, options: GraphNeighborsOptions) Error!GraphKeyedNeighborList {
        try validateGraphName(options.graph_name);
        try validateNodeId(options.node_id);
        if (options.edge_type) |edge_type| try validateEdgeType(edge_type);
        const graph_key = try self.graphKeyForRead(options.graph_name);
        const edge_type_key = if (options.edge_type) |edge_type| (try self.edgeTypeKeyForRead(graph_key, edge_type)) orelse -1 else null;
        const sqlite_limit = try sqliteLimit(options.limit);
        var stmt = switch (options.direction) {
            .outgoing => if (options.edge_type == null)
                try self.prepareSchema(
                    \\select e.edge_key,n.node_key,n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e join {s}_zova_graph_nodes n on n.node_key=e.to_node_key
                    \\where e.graph_key=?1 and e.from_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2)
                    \\order by e.created_order,n.node_id collate binary,n.node_key limit ?3
                )
            else
                try self.prepareSchema(
                    \\select e.edge_key,n.node_key,n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e join {s}_zova_graph_nodes n on n.node_key=e.to_node_key
                    \\where e.graph_key=?1 and e.from_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2) and e.edge_type_key=?3
                    \\order by e.created_order,n.node_id collate binary,n.node_key limit ?4
                ),
            .incoming => if (options.edge_type == null)
                try self.prepareSchema(
                    \\select e.edge_key,n.node_key,n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e join {s}_zova_graph_nodes n on n.node_key=e.from_node_key
                    \\where e.graph_key=?1 and e.to_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2)
                    \\order by e.created_order,n.node_id collate binary,n.node_key limit ?3
                )
            else
                try self.prepareSchema(
                    \\select e.edge_key,n.node_key,n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e join {s}_zova_graph_nodes n on n.node_key=e.from_node_key
                    \\where e.graph_key=?1 and e.to_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2) and e.edge_type_key=?3
                    \\order by e.created_order,n.node_id collate binary,n.node_key limit ?4
                ),
        };
        defer stmt.deinit();
        try stmt.bindInt64(1, graph_key);
        try stmt.bindText(2, options.node_id);
        if (edge_type_key) |key| {
            try stmt.bindInt64(3, key);
            try stmt.bindInt64(4, sqlite_limit);
        } else try stmt.bindInt64(3, sqlite_limit);

        var items: std.ArrayList(GraphKeyedNeighbor) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }
        while ((try stmt.step()) == .row) {
            const edge_key = stmt.columnInt64(0);
            const neighbor_node_key = stmt.columnInt64(1);
            if (edge_key <= 0 or neighbor_node_key <= 0) return error.GraphInvalid;
            const node_id = try allocator.dupe(u8, stmt.columnText(2));
            errdefer allocator.free(node_id);
            const kind = try allocator.dupe(u8, stmt.columnText(3));
            errdefer allocator.free(kind);
            const edge_type = try self.dupeEdgeTypeNameForRead(allocator, stmt.columnInt64(4));
            errdefer allocator.free(edge_type);
            try items.append(allocator, .{ .edge_key = edge_key, .neighbor_node_key = neighbor_node_key, .node_id = node_id, .kind = kind, .edge_type = edge_type });
        }
        if (items.items.len == 0 and !try self.hasGraphNode(options.graph_name, options.node_id)) return error.GraphNodeNotFound;
        return .{ .items = try items.toOwnedSlice(allocator) };
    }

    pub fn graphNodesGetManyKeyed(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, keys: []const i64) Error!GraphKeyedNodeLookupList {
        try validateGraphName(graph_name);
        for (keys) |key| if (key <= 0) return error.InvalidArgument;
        const graph_key = try self.graphKeyForRead(graph_name);
        var items = try allocator.alloc(GraphKeyedNodeLookup, keys.len);
        errdefer allocator.free(items);
        for (keys, items) |key, *item| item.* = .{ .found = false, .node_key = key };
        errdefer for (items) |*item| item.deinit(allocator);
        if (keys.len == 0) return .{ .items = items };

        try self.stageOpaqueKeys("_zova_graph_nodes_get_many_keys", keys);
        defer self.clearOpaqueKeys("_zova_graph_nodes_get_many_keys");
        var stmt = try self.prepareSchema(
            \\select batch.ordinal,n.node_key,n.node_id,n.kind,n.created_order
            \\from temp._zova_graph_nodes_get_many_keys batch
            \\left join {s}_zova_graph_nodes n on n.graph_key=?1 and n.node_key=batch.row_key
            \\order by batch.ordinal
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, graph_key);
        var seen: usize = 0;
        while ((try stmt.step()) == .row) : (seen += 1) {
            const ordinal = stmt.columnInt64(0);
            if (ordinal < 0 or @as(usize, @intCast(ordinal)) >= items.len) return error.GraphInvalid;
            const item = &items[@intCast(ordinal)];
            if (stmt.columnType(1) == .null) continue;
            const node_key = stmt.columnInt64(1);
            const created_order = stmt.columnInt64(4);
            if (node_key != item.node_key or created_order <= 0) return error.GraphInvalid;
            item.node_id = try allocator.dupe(u8, stmt.columnText(2));
            item.kind = allocator.dupe(u8, stmt.columnText(3)) catch |err| {
                allocator.free(item.node_id.?);
                item.node_id = null;
                return err;
            };
            item.created_order = created_order;
            item.found = true;
        }
        if (seen != keys.len) return error.GraphInvalid;
        return .{ .items = items };
    }

    pub fn graphEdgesGetManyKeyed(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, keys: []const i64) Error!GraphKeyedEdgeLookupList {
        try validateGraphName(graph_name);
        for (keys) |key| if (key <= 0) return error.InvalidArgument;
        const graph_key = try self.graphKeyForRead(graph_name);
        var items = try allocator.alloc(GraphKeyedEdgeLookup, keys.len);
        errdefer allocator.free(items);
        for (keys, items) |key, *item| item.* = .{ .found = false, .edge_key = key };
        errdefer for (items) |*item| item.deinit(allocator);
        if (keys.len == 0) return .{ .items = items };

        try self.ensureEdgeTypeCache();

        try self.stageOpaqueKeys("_zova_graph_edges_get_many_keys", keys);
        defer self.clearOpaqueKeys("_zova_graph_edges_get_many_keys");
        var stmt = try self.prepareSchema(
            \\select batch.ordinal,e.edge_key,e.from_node_key,e.edge_type_key,e.to_node_key,e.created_order
            \\from temp._zova_graph_edges_get_many_keys batch
            \\left join {s}_zova_graph_edges e on e.graph_key=?1 and e.edge_key=batch.row_key
            \\order by batch.ordinal
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, graph_key);
        var seen: usize = 0;
        while ((try stmt.step()) == .row) : (seen += 1) {
            const ordinal = stmt.columnInt64(0);
            if (ordinal < 0 or @as(usize, @intCast(ordinal)) >= items.len) return error.GraphInvalid;
            const item = &items[@intCast(ordinal)];
            if (stmt.columnType(1) == .null) continue;
            const edge_key = stmt.columnInt64(1);
            const source = stmt.columnInt64(2);
            const target = stmt.columnInt64(4);
            const created_order = stmt.columnInt64(5);
            if (edge_key != item.edge_key or source <= 0 or target <= 0 or created_order <= 0) return error.GraphInvalid;
            item.edge_type = try self.dupeEdgeTypeNameForRead(allocator, stmt.columnInt64(3));
            item.source_node_key = source;
            item.target_node_key = target;
            item.created_order = created_order;
            item.found = true;
        }
        if (seen != keys.len) return error.GraphInvalid;
        return .{ .items = items };
    }

    pub fn graphEdgePayloadsGetMany(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, keys: []const i64) Error!GraphEdgePayloadLookupList {
        try validateGraphName(graph_name);
        for (keys) |key| if (key <= 0) return error.InvalidArgument;
        const graph_key = try self.graphKeyForRead(graph_name);
        var items = try allocator.alloc(GraphEdgePayloadLookup, keys.len);
        errdefer allocator.free(items);
        for (keys, items) |key, *item| item.* = .{ .found = false, .edge_key = key };
        errdefer for (items) |*item| item.deinit(allocator);
        if (keys.len == 0) return .{ .items = items };

        try self.stageOpaqueKeys("_zova_graph_edge_payload_keys", keys);
        defer self.clearOpaqueKeys("_zova_graph_edge_payload_keys");
        var stmt = try self.prepareSchema(
            \\select batch.ordinal,e.edge_key,e.payload
            \\from temp._zova_graph_edge_payload_keys batch
            \\left join {s}_zova_graph_edges e on e.graph_key=?1 and e.edge_key=batch.row_key
            \\order by batch.ordinal
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, graph_key);
        var seen: usize = 0;
        while ((try stmt.step()) == .row) : (seen += 1) {
            const ordinal = stmt.columnInt64(0);
            if (ordinal < 0 or @as(usize, @intCast(ordinal)) >= items.len) return error.GraphInvalid;
            const item = &items[@intCast(ordinal)];
            if (stmt.columnType(1) == .null) continue;
            if (stmt.columnInt64(1) != item.edge_key) return error.GraphInvalid;
            item.payload = try allocator.dupe(u8, stmt.columnBlob(2));
            item.found = true;
        }
        if (seen != keys.len) return error.GraphInvalid;
        return .{ .items = items };
    }

    pub fn replaceGraphEdgePayloads(self: *Database, graph_name: []const u8, replacements: []const GraphEdgePayloadReplacement) Error!void {
        try validateGraphName(graph_name);
        for (replacements) |replacement| if (replacement.edge_key <= 0) return error.InvalidArgument;
        const graph_key = try self.graphKeyForRead(graph_name);
        if (replacements.len == 0) return;

        const keys = try std.heap.c_allocator.alloc(i64, replacements.len);
        defer std.heap.c_allocator.free(keys);
        for (replacements, keys) |replacement, *key| key.* = replacement.edge_key;
        try self.stageOpaqueKeys("_zova_graph_edge_payload_replace_keys", keys);
        defer self.clearOpaqueKeys("_zova_graph_edge_payload_replace_keys");
        var validate = try self.prepareSchema(
            \\select count(*)
            \\from temp._zova_graph_edge_payload_replace_keys batch
            \\join {s}_zova_graph_edges e on e.graph_key=?1 and e.edge_key=batch.row_key
        );
        defer validate.deinit();
        try validate.bindInt64(1, graph_key);
        if ((try validate.step()) != .row or validate.columnInt64(0) != @as(i64, @intCast(replacements.len))) return error.GraphEdgeNotFound;

        var update = try self.prepareSchema("update {s}_zova_graph_edges set payload=?1 where graph_key=?2 and edge_key=?3");
        defer update.deinit();
        for (replacements) |replacement| {
            try update.bindBlobBorrowed(1, replacement.payload);
            try update.bindInt64(2, graph_key);
            try update.bindInt64(3, replacement.edge_key);
            if ((try update.step()) != .done or self.sqlite_db.changes() != 1) return error.GraphEdgeNotFound;
            try update.reset();
            try update.clearBindings();
        }
    }

    fn stageOpaqueKeys(self: *Database, comptime table: []const u8, keys: []const i64) Error!void {
        try self.sqlite_db.exec("create temp table if not exists temp." ++ table ++ " (ordinal integer primary key,row_key integer not null) without rowid; delete from temp." ++ table);
        var stmt = try self.sqlite_db.prepare("insert into temp." ++ table ++ "(ordinal,row_key) values(?,?)");
        defer stmt.deinit();
        for (keys, 0..) |key, ordinal| {
            try stmt.bindInt64(1, @intCast(ordinal));
            try stmt.bindInt64(2, key);
            std.debug.assert((try stmt.step()) == .done);
            try stmt.reset();
            try stmt.clearBindings();
        }
    }

    fn clearOpaqueKeys(self: *Database, comptime table: []const u8) void {
        self.sqlite_db.exec("delete from temp." ++ table) catch {};
    }

    /// Count edges adjacent to one existing graph node.
    pub fn graphDegree(self: *Database, options: GraphDegreeOptions) Error!u64 {
        try validateGraphName(options.graph_name);
        try validateNodeId(options.node_id);
        if (options.edge_type) |edge_type| try validateEdgeType(edge_type);
        const graph_key = try self.graphKeyForRead(options.graph_name);
        const edge_type_key = if (options.edge_type) |edge_type| (try self.edgeTypeKeyForRead(graph_key, edge_type)) orelse -1 else null;
        var stmt = switch (options.direction) {
            .outgoing => if (options.edge_type != null)
                try self.prepareSchema(
                    \\select count(*) from {s}_zova_graph_edges e
                    \\where e.graph_key=?1 and e.from_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2) and e.edge_type_key=?3
                )
            else
                try self.prepareSchema(
                    \\select count(*) from {s}_zova_graph_edges e
                    \\where e.graph_key=?1 and e.from_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2)
                ),
            .incoming => if (options.edge_type != null)
                try self.prepareSchema(
                    \\select count(*) from {s}_zova_graph_edges e
                    \\where e.graph_key=?1 and e.to_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2) and e.edge_type_key=?3
                )
            else
                try self.prepareSchema(
                    \\select count(*) from {s}_zova_graph_edges e
                    \\where e.graph_key=?1 and e.to_node_key=(select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2)
                ),
        };
        defer stmt.deinit();
        try stmt.bindInt64(1, graph_key);
        try stmt.bindText(2, options.node_id);
        if (edge_type_key) |key| try stmt.bindInt64(3, key);
        std.debug.assert((try stmt.step()) == .row);
        const count = stmt.columnInt64(0);
        if (count < 0) return error.GraphInvalid;
        if (count == 0 and !try self.hasGraphNode(options.graph_name, options.node_id)) return error.GraphNodeNotFound;
        return @intCast(count);
    }

    pub fn graphDegreeManyKeyed(
        self: *Database,
        graph_name: []const u8,
        node_keys: []const i64,
        direction: GraphNeighborDirection,
        edge_type: ?[]const u8,
        out_degrees: []u64,
    ) Error!void {
        if (out_degrees.len != node_keys.len) return error.InvalidArgument;
        try validateGraphName(graph_name);
        if (edge_type) |value| try validateEdgeType(value);
        const graph_key = try self.graphKeyForRead(graph_name);
        const edge_type_key = if (edge_type) |value| (try self.edgeTypeKeyForRead(graph_key, value)) orelse -1 else null;
        for (node_keys) |node_key| if (node_key <= 0) return error.InvalidArgument;
        if (node_keys.len == 0) return;

        try self.sqlite_db.exec(
            \\create temp table if not exists temp._zova_graph_degree_many_keys (
            \\ ordinal integer primary key,
            \\ node_key integer not null
            \\) without rowid;
            \\delete from temp._zova_graph_degree_many_keys;
        );
        defer self.sqlite_db.exec("delete from temp._zova_graph_degree_many_keys") catch {};
        var stage = try self.sqlite_db.prepare("insert into temp._zova_graph_degree_many_keys(ordinal,node_key) values(?,?)");
        defer stage.deinit();
        for (node_keys, 0..) |node_key, ordinal| {
            try stage.bindInt64(1, @intCast(ordinal));
            try stage.bindInt64(2, node_key);
            std.debug.assert((try stage.step()) == .done);
            try stage.reset();
            try stage.clearBindings();
        }

        var query = switch (direction) {
            .outgoing => if (edge_type == null)
                try self.prepareSchema(
                    \\select batch.ordinal,count(e.edge_key)
                    \\from temp._zova_graph_degree_many_keys batch
                    \\join {s}_zova_graph_nodes n on n.graph_key=?1 and n.node_key=batch.node_key
                    \\left join {s}_zova_graph_edges e on e.graph_key=n.graph_key and e.from_node_key=n.node_key
                    \\group by batch.ordinal order by batch.ordinal
                )
            else
                try self.prepareSchema(
                    \\select batch.ordinal,count(e.edge_key)
                    \\from temp._zova_graph_degree_many_keys batch
                    \\join {s}_zova_graph_nodes n on n.graph_key=?1 and n.node_key=batch.node_key
                    \\left join {s}_zova_graph_edges e on e.graph_key=n.graph_key and e.from_node_key=n.node_key and e.edge_type_key=?2
                    \\group by batch.ordinal order by batch.ordinal
                ),
            .incoming => if (edge_type == null)
                try self.prepareSchema(
                    \\select batch.ordinal,count(e.edge_key)
                    \\from temp._zova_graph_degree_many_keys batch
                    \\join {s}_zova_graph_nodes n on n.graph_key=?1 and n.node_key=batch.node_key
                    \\left join {s}_zova_graph_edges e on e.graph_key=n.graph_key and e.to_node_key=n.node_key
                    \\group by batch.ordinal order by batch.ordinal
                )
            else
                try self.prepareSchema(
                    \\select batch.ordinal,count(e.edge_key)
                    \\from temp._zova_graph_degree_many_keys batch
                    \\join {s}_zova_graph_nodes n on n.graph_key=?1 and n.node_key=batch.node_key
                    \\left join {s}_zova_graph_edges e on e.graph_key=n.graph_key and e.to_node_key=n.node_key and e.edge_type_key=?2
                    \\group by batch.ordinal order by batch.ordinal
                ),
        };
        defer query.deinit();
        try query.bindInt64(1, graph_key);
        if (edge_type_key) |key| try query.bindInt64(2, key);
        var resolved: usize = 0;
        while ((try query.step()) == .row) {
            const ordinal = query.columnInt64(0);
            const degree = query.columnInt64(1);
            if (ordinal < 0 or degree < 0) return error.GraphInvalid;
            const index: usize = @intCast(ordinal);
            if (index >= out_degrees.len) return error.GraphInvalid;
            out_degrees[index] = @intCast(degree);
            resolved += 1;
        }
        if (resolved != node_keys.len) return error.GraphNodeNotFound;
    }

    pub fn graphScan(self: *Database, allocator: std.mem.Allocator, options: GraphScanOptions) Error!GraphScanResult {
        try validateGraphName(options.graph_name);
        try validateGraphScanCursor(options.node_after);
        try validateGraphScanCursor(options.edge_after);
        const graph_key = try self.graphKey(options.graph_name);
        var nodes: std.ArrayList(GraphScanNode) = .empty;
        errdefer {
            for (nodes.items) |*node| node.deinit(allocator);
            nodes.deinit(allocator);
        }
        var edges: std.ArrayList(GraphScanEdge) = .empty;
        errdefer {
            for (edges.items) |*edge| edge.deinit(allocator);
            edges.deinit(allocator);
        }
        var has_more_nodes = false;
        var has_more_edges = false;

        if (options.node_limit != 0) {
            const query_limit = std.math.add(usize, options.node_limit, 1) catch return error.InvalidArgument;
            var stmt = try self.prepareSchema(
                \\select node_key,node_id,kind,created_order from {s}_zova_graph_nodes
                \\where graph_key=?1 and (created_order>?2 or (created_order=?2 and node_key>?3))
                \\order by created_order,node_key limit ?4
            );
            defer stmt.deinit();
            try stmt.bindInt64(1, graph_key);
            try stmt.bindInt64(2, options.node_after.created_order);
            try stmt.bindInt64(3, options.node_after.key);
            try stmt.bindInt64(4, try sqliteLimit(query_limit));
            while ((try stmt.step()) == .row) {
                if (nodes.items.len == options.node_limit) {
                    has_more_nodes = true;
                    break;
                }
                try appendGraphScanNode(&nodes, allocator, &stmt);
            }
        }
        if (options.edge_limit != 0) {
            const query_limit = std.math.add(usize, options.edge_limit, 1) catch return error.InvalidArgument;
            var stmt = try self.prepareSchema(
                \\select e.edge_key,e.from_node_key,e.edge_type_key,e.to_node_key,e.created_order from {s}_zova_graph_edges e
                \\where e.graph_key=?1 and (e.created_order>?2 or (e.created_order=?2 and e.edge_key>?3))
                \\order by e.created_order,e.edge_key limit ?4
            );
            defer stmt.deinit();
            try stmt.bindInt64(1, graph_key);
            try stmt.bindInt64(2, options.edge_after.created_order);
            try stmt.bindInt64(3, options.edge_after.key);
            try stmt.bindInt64(4, try sqliteLimit(query_limit));
            while ((try stmt.step()) == .row) {
                if (edges.items.len == options.edge_limit) {
                    has_more_edges = true;
                    break;
                }
                const edge_key = stmt.columnInt64(0);
                const source_node_key = stmt.columnInt64(1);
                const target_node_key = stmt.columnInt64(3);
                const created_order = stmt.columnInt64(4);
                if (edge_key <= 0 or source_node_key <= 0 or target_node_key <= 0 or created_order <= 0) return error.GraphInvalid;
                const edge_type = try self.dupeEdgeTypeNameForRead(allocator, stmt.columnInt64(2));
                errdefer allocator.free(edge_type);
                try edges.append(allocator, .{ .edge_key = edge_key, .source_node_key = source_node_key, .edge_type = edge_type, .target_node_key = target_node_key, .created_order = created_order });
            }
        }
        const owned_nodes = try nodes.toOwnedSlice(allocator);
        errdefer {
            for (owned_nodes) |*node| node.deinit(allocator);
            allocator.free(owned_nodes);
        }
        const owned_edges = try edges.toOwnedSlice(allocator);
        return .{
            .nodes = owned_nodes,
            .edges = owned_edges,
            .has_more_nodes = has_more_nodes,
            .has_more_edges = has_more_edges,
        };
    }

    pub fn graphWalk(self: *Database, allocator: std.mem.Allocator, options: GraphWalkOptions) Error!GraphWalk {
        return self.graphWalkInternal(allocator, .{
            .graph_name = options.graph_name,
            .start_node_id = options.start_node_id,
            .direction = .outgoing,
            .edge_type = options.edge_type,
            .max_depth = options.max_depth,
            .limit = options.limit,
        }, null);
    }

    /// Return a bounded incoming or outgoing directed walk from one graph node.
    pub fn graphWalkDirection(self: *Database, allocator: std.mem.Allocator, options: GraphWalkDirectionOptions) Error!GraphWalk {
        return self.graphWalkInternal(allocator, options, null);
    }

    /// Run a walk with internal adjacency-scan counters for benchmark and test use.
    pub fn graphWalkProfiled(self: *Database, allocator: std.mem.Allocator, options: GraphWalkOptions, profile: *GraphWalkScanProfile) Error!GraphWalk {
        profile.* = .{};
        return self.graphWalkInternal(allocator, .{
            .graph_name = options.graph_name,
            .start_node_id = options.start_node_id,
            .direction = .outgoing,
            .edge_type = options.edge_type,
            .max_depth = options.max_depth,
            .limit = options.limit,
        }, profile);
    }

    /// Run an incoming or outgoing walk with internal timing and scan counters.
    pub fn graphWalkDirectionProfiled(
        self: *Database,
        allocator: std.mem.Allocator,
        options: GraphWalkDirectionOptions,
        profile: *GraphWalkScanProfile,
    ) Error!GraphWalk {
        profile.* = .{};
        return self.graphWalkInternal(allocator, options, profile);
    }

    fn graphWalkInternal(
        self: *Database,
        allocator: std.mem.Allocator,
        options: GraphWalkDirectionOptions,
        profile: ?*GraphWalkScanProfile,
    ) Error!GraphWalk {
        try validateGraphName(options.graph_name);
        try validateNodeId(options.start_node_id);
        if (options.edge_type) |edge_type| try validateEdgeType(edge_type);
        const sqlite_limit = try sqliteLimit(options.limit);
        const walk_start = if (profile != null) graphProfileTimestamp() else std.Io.Timestamp.zero;
        const root_lookup_start = if (profile != null) graphProfileTimestamp() else std.Io.Timestamp.zero;

        var visited: std.StringHashMap(void) = .init(allocator);
        defer freeVisitedKeys(allocator, &visited);
        var frontier: std.ArrayList(GraphWalkItem) = .empty;
        defer {
            for (frontier.items) |*item| item.deinit(allocator);
            frontier.deinit(allocator);
        }
        var results: std.ArrayList(GraphWalkItem) = .empty;
        errdefer {
            for (results.items) |*item| item.deinit(allocator);
            results.deinit(allocator);
        }

        const resolved_start = try self.getGraphNodeWithKey(allocator, options.graph_name, options.start_node_id);
        const start = resolved_start.node;
        defer {
            var owned_start = start;
            owned_start.deinit(allocator);
        }
        if (profile) |value| value.root_lookup_ms = graphProfileElapsedMs(root_lookup_start);
        try putVisited(&visited, allocator, options.start_node_id);
        try appendGraphWalkItem(&frontier, allocator, start.node_id, start.kind, 0, null, null);

        const adjacency_prepare_start = if (profile != null) graphProfileTimestamp() else std.Io.Timestamp.zero;
        const edge_type_key = if (options.edge_type) |edge_type| (try self.edgeTypeKeyForRead(resolved_start.graph_key, edge_type)) orelse -1 else null;
        var adjacency_stmt = try self.prepareWalkAdjacency(options.direction, edge_type_key != null);
        defer adjacency_stmt.deinit();
        try bindWalkAdjacencyConstants(&adjacency_stmt, resolved_start.graph_key, edge_type_key, sqlite_limit);
        if (profile) |value| {
            value.adjacency_prepare_ms = graphProfileElapsedMs(adjacency_prepare_start);
            value.adjacency_statement_prepares += 1;
        }

        var frontier_index: usize = 0;
        while (frontier_index < frontier.items.len and results.items.len < options.limit) : (frontier_index += 1) {
            const current = &frontier.items[frontier_index];
            const current_node_id = current.node_id;
            const current_kind = current.kind;
            const current_depth = current.depth;
            const current_predecessor_node_id = current.predecessor_node_id;
            const current_edge_type = current.edge_type;

            try appendGraphWalkItem(&results, allocator, current_node_id, current_kind, current_depth, current_predecessor_node_id, current_edge_type);
            if (current_depth >= options.max_depth) continue;

            if (profile) |value| {
                const operation_start = graphProfileTimestamp();
                try bindWalkAdjacencyNode(&adjacency_stmt, current_node_id);
                value.adjacency_execute_ms += graphProfileElapsedMs(operation_start);
                value.adjacency_query_binds += 1;
                value.frontier_expansions += 1;
            } else {
                try bindWalkAdjacencyNode(&adjacency_stmt, current_node_id);
            }

            while (true) {
                const step_result = if (profile) |value| result: {
                    const operation_start = graphProfileTimestamp();
                    const operation_result = try adjacency_stmt.step();
                    value.adjacency_execute_ms += graphProfileElapsedMs(operation_start);
                    break :result operation_result;
                } else try adjacency_stmt.step();
                if (step_result != .row) break;
                if (profile) |value| value.adjacency_rows_stepped += 1;
                const neighbor_node_id = adjacency_stmt.columnText(0);
                const neighbor_kind = adjacency_stmt.columnText(1);
                const neighbor_edge_type_key = adjacency_stmt.columnInt64(2);
                if (visited.contains(neighbor_node_id)) continue;
                try putVisited(&visited, allocator, neighbor_node_id);
                if (self.edge_type_cache) |cache| {
                    try self.ensureEdgeTypeCache();
                    if (cache.by_key.get(neighbor_edge_type_key)) |neighbor_edge_type| {
                        try appendGraphWalkItem(&frontier, allocator, neighbor_node_id, neighbor_kind, current_depth + 1, current_node_id, neighbor_edge_type);
                    } else {
                        const neighbor_edge_type = try self.dupeEdgeTypeNameForRead(allocator, neighbor_edge_type_key);
                        defer allocator.free(neighbor_edge_type);
                        try appendGraphWalkItem(&frontier, allocator, neighbor_node_id, neighbor_kind, current_depth + 1, current_node_id, neighbor_edge_type);
                    }
                } else {
                    const neighbor_edge_type = try self.dupeEdgeTypeNameForRead(allocator, neighbor_edge_type_key);
                    defer allocator.free(neighbor_edge_type);
                    try appendGraphWalkItem(&frontier, allocator, neighbor_node_id, neighbor_kind, current_depth + 1, current_node_id, neighbor_edge_type);
                }
            }
            if (profile) |value| {
                const operation_start = graphProfileTimestamp();
                try resetWalkAdjacency(&adjacency_stmt);
                value.adjacency_execute_ms += graphProfileElapsedMs(operation_start);
            } else {
                try resetWalkAdjacency(&adjacency_stmt);
            }
        }

        const owned_results = try results.toOwnedSlice(allocator);
        if (profile) |value| {
            value.result_count = @intCast(owned_results.len);
            const accounted_ms = value.root_lookup_ms + value.adjacency_prepare_ms + value.adjacency_execute_ms;
            value.bfs_bookkeeping_allocation_ms = @max(0, graphProfileElapsedMs(walk_start) - accounted_ms);
        }
        return .{ .items = owned_results };
    }

    fn prepareWalkAdjacency(self: *Database, direction: GraphNeighborDirection, filtered: bool) Error!sqlite.Statement {
        return switch (direction) {
            .outgoing => if (!filtered)
                try self.prepareSchema(
                    \\select n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key = e.to_node_key
                    \\where e.graph_key=?1 and e.from_node_key=(
                    \\  select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2
                    \\)
                    \\order by e.created_order, e.to_node_key
                    \\limit ?
                )
            else
                try self.prepareSchema(
                    \\select n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key = e.to_node_key
                    \\where e.graph_key=?1 and e.from_node_key=(
                    \\  select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2
                    \\) and e.edge_type_key=?3
                    \\order by e.created_order, e.to_node_key
                    \\limit ?
                ),
            .incoming => if (!filtered)
                try self.prepareSchema(
                    \\select n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key = e.from_node_key
                    \\where e.graph_key=?1 and e.to_node_key=(
                    \\  select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2
                    \\)
                    \\order by e.created_order, e.from_node_key
                    \\limit ?
                )
            else
                try self.prepareSchema(
                    \\select n.node_id,n.kind,e.edge_type_key
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key = e.from_node_key
                    \\where e.graph_key=?1 and e.to_node_key=(
                    \\  select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2
                    \\) and e.edge_type_key=?3
                    \\order by e.created_order, e.from_node_key
                    \\limit ?
                ),
        };
    }
};

fn graphProfileIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn graphProfileTimestamp() std.Io.Timestamp {
    return std.Io.Clock.awake.now(graphProfileIo());
}

fn graphProfileElapsedMs(start: std.Io.Timestamp) f64 {
    const elapsed_ns = start.durationTo(graphProfileTimestamp()).toNanoseconds();
    if (elapsed_ns <= 0) return 0;
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms);
}

fn bindWalkAdjacencyConstants(
    stmt: *sqlite.Statement,
    graph_key: i64,
    edge_type_key: ?i64,
    sqlite_limit: i64,
) Error!void {
    try stmt.bindInt64(1, graph_key);
    if (edge_type_key) |key| {
        try stmt.bindInt64(3, key);
        try stmt.bindInt64(4, sqlite_limit);
    } else {
        try stmt.bindInt64(3, sqlite_limit);
    }
}

fn bindWalkAdjacencyNode(stmt: *sqlite.Statement, current_node_id: []const u8) Error!void {
    try stmt.bindText(2, current_node_id);
}

fn resetWalkAdjacency(stmt: *sqlite.Statement) Error!void {
    try stmt.reset();
}

test "walk adjacency reset retains invariant bindings" {
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();

    try db.exec(
        \\create table adjacency (
        \\  graph_name text not null,
        \\  node_id text not null,
        \\  edge_type text not null,
        \\  value text not null
        \\);
        \\insert into adjacency values
        \\  ('app', 'first', 'calls', 'first-value'),
        \\  ('app', 'second', 'calls', 'second-value');
    );

    var stmt = try db.prepare(
        \\select value from adjacency
        \\where graph_name = ?1 and node_id = ?2 and edge_type = ?3
        \\limit ?4
    );
    defer stmt.deinit();

    try stmt.bindText(1, "app");
    try stmt.bindText(3, "calls");
    try stmt.bindInt64(4, 1);

    try stmt.bindText(2, "first");
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("first-value", stmt.columnText(0));

    try resetWalkAdjacency(&stmt);
    try stmt.bindText(2, "second");
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("second-value", stmt.columnText(0));
}

fn bindGraphNodeInput(stmt: *sqlite.Statement, graph_key: i64, input: GraphNodeInput, created_order: i64) Error!void {
    try stmt.bindInt64(1, graph_key);
    try stmt.bindText(2, input.node_id);
    try stmt.bindText(3, input.kind);
    try stmt.bindText(4, targetTypeText(input.target_type));
    if (input.target_namespace) |value| {
        try stmt.bindText(5, value);
    } else {
        try stmt.bindNull(5);
    }
    if (input.target_ref) |value| {
        try stmt.bindText(6, value);
    } else {
        try stmt.bindNull(6);
    }
    try stmt.bindInt64(7, created_order);
}

fn nextGraphCreatedOrder(
    stmt: *sqlite.Statement,
    next_orders: *std.AutoHashMap(i64, i64),
    graph_key: i64,
) Error!i64 {
    const entry = try next_orders.getOrPut(graph_key);
    if (!entry.found_existing) {
        try stmt.bindInt64(1, graph_key);
        std.debug.assert((try stmt.step()) == .row);
        const next_order = stmt.columnInt64(0);
        try stmt.reset();
        try stmt.clearBindings();
        if (next_order < 1) return error.GraphInvalid;
        entry.value_ptr.* = next_order;
    }

    const created_order = entry.value_ptr.*;
    entry.value_ptr.* = std.math.add(i64, created_order, 1) catch return error.GraphInvalid;
    return created_order;
}

fn ensureGraphBatchIndexes(self: *Database) Error!void {
    var nodes_created_order = try self.prepareSchema(
        \\create index if not exists {s}_zova_graph_nodes_created_order_idx
        \\on _zova_graph_nodes (graph_key, created_order, node_key)
    );
    defer nodes_created_order.deinit();
    std.debug.assert((try nodes_created_order.step()) == .done);

    var edges_topology = try self.prepareSchema(
        \\create unique index if not exists {s}_zova_graph_edges_topology_idx
        \\on _zova_graph_edges (from_node_key, edge_type_key, to_node_key)
    );
    defer edges_topology.deinit();
    std.debug.assert((try edges_topology.step()) == .done);

    var edges_created_order = try self.prepareSchema(
        \\create index if not exists {s}_zova_graph_edges_created_order_idx
        \\on _zova_graph_edges (graph_key, created_order, edge_key)
    );
    defer edges_created_order.deinit();
    std.debug.assert((try edges_created_order.step()) == .done);

    var edges_from_node = try self.prepareSchema(
        \\create index if not exists {s}_zova_graph_edges_from_node_idx
        \\on _zova_graph_edges (graph_key, from_node_key, created_order, to_node_key)
    );
    defer edges_from_node.deinit();
    std.debug.assert((try edges_from_node.step()) == .done);

    var edges_from_node_type = try self.prepareSchema(
        \\create index if not exists {s}_zova_graph_edges_from_node_type_idx
        \\on _zova_graph_edges (graph_key, from_node_key, edge_type_key, created_order, to_node_key)
    );
    defer edges_from_node_type.deinit();
    std.debug.assert((try edges_from_node_type.step()) == .done);

    var edges_to_node = try self.prepareSchema(
        \\create index if not exists {s}_zova_graph_edges_to_node_idx
        \\on _zova_graph_edges (graph_key, to_node_key, created_order, from_node_key)
    );
    defer edges_to_node.deinit();
    std.debug.assert((try edges_to_node.step()) == .done);

    var edges_to_node_type = try self.prepareSchema(
        \\create index if not exists {s}_zova_graph_edges_to_node_type_idx
        \\on _zova_graph_edges (graph_key, to_node_key, edge_type_key, created_order, from_node_key)
    );
    defer edges_to_node_type.deinit();
    std.debug.assert((try edges_to_node_type.step()) == .done);
}

fn graphInfoFromRow(allocator: std.mem.Allocator, stmt: *sqlite.Statement) Error!GraphInfo {
    const name = try allocator.dupe(u8, stmt.columnText(0));
    errdefer allocator.free(name);

    return .{
        .name = name,
        .node_count = @intCast(stmt.columnInt64(1)),
        .edge_count = @intCast(stmt.columnInt64(2)),
    };
}

fn appendGraphInfoFromRow(items: *std.ArrayList(GraphInfo), allocator: std.mem.Allocator, stmt: *sqlite.Statement) Error!void {
    var item = try graphInfoFromRow(allocator, stmt);
    errdefer item.deinit(allocator);
    try items.append(allocator, item);
}

fn nodeFromRow(allocator: std.mem.Allocator, stmt: *sqlite.Statement) Error!GraphNode {
    const target_type = try targetTypeFromText(stmt.columnText(3));
    const graph_name = try allocator.dupe(u8, stmt.columnText(0));
    errdefer allocator.free(graph_name);
    const node_id = try allocator.dupe(u8, stmt.columnText(1));
    errdefer allocator.free(node_id);
    const kind = try allocator.dupe(u8, stmt.columnText(2));
    errdefer allocator.free(kind);
    const target_namespace = if (stmt.columnType(4) == .null) null else try allocator.dupe(u8, stmt.columnText(4));
    errdefer if (target_namespace) |value| allocator.free(value);
    const target_ref = if (stmt.columnType(5) == .null) null else try allocator.dupe(u8, stmt.columnText(5));
    errdefer if (target_ref) |value| allocator.free(value);

    return .{
        .graph_name = graph_name,
        .node_id = node_id,
        .kind = kind,
        .target_type = target_type,
        .target_namespace = target_namespace,
        .target_ref = target_ref,
    };
}

fn graphEdgeFromRow(allocator: std.mem.Allocator, stmt: *sqlite.Statement) Error!GraphEdge {
    const graph_name = try allocator.dupe(u8, stmt.columnText(0));
    errdefer allocator.free(graph_name);
    const from_node_id = try allocator.dupe(u8, stmt.columnText(1));
    errdefer allocator.free(from_node_id);
    const edge_type = try allocator.dupe(u8, stmt.columnText(2));
    errdefer allocator.free(edge_type);
    const to_node_id = try allocator.dupe(u8, stmt.columnText(3));
    errdefer allocator.free(to_node_id);

    return .{
        .graph_name = graph_name,
        .from_node_id = from_node_id,
        .edge_type = edge_type,
        .to_node_id = to_node_id,
    };
}

fn graphNeighborFromRow(allocator: std.mem.Allocator, stmt: *sqlite.Statement) Error!GraphNeighbor {
    const node_id = try allocator.dupe(u8, stmt.columnText(0));
    errdefer allocator.free(node_id);
    const kind = try allocator.dupe(u8, stmt.columnText(1));
    errdefer allocator.free(kind);
    const edge_type = try allocator.dupe(u8, stmt.columnText(2));
    errdefer allocator.free(edge_type);

    return .{
        .node_id = node_id,
        .kind = kind,
        .edge_type = edge_type,
    };
}

fn appendGraphNeighborFromRow(items: *std.ArrayList(GraphNeighbor), allocator: std.mem.Allocator, stmt: *sqlite.Statement) Error!void {
    var item = try graphNeighborFromRow(allocator, stmt);
    errdefer item.deinit(allocator);
    try items.append(allocator, item);
}

fn appendGraphKeyedNeighborFromRow(
    items: *std.ArrayList(GraphKeyedNeighbor),
    allocator: std.mem.Allocator,
    stmt: *sqlite.Statement,
) Error!void {
    const edge_key = stmt.columnInt64(0);
    const neighbor_node_key = stmt.columnInt64(1);
    if (edge_key <= 0 or neighbor_node_key <= 0) return error.GraphInvalid;
    const node_id = try allocator.dupe(u8, stmt.columnText(2));
    errdefer allocator.free(node_id);
    const kind = try allocator.dupe(u8, stmt.columnText(3));
    errdefer allocator.free(kind);
    const edge_type = try allocator.dupe(u8, stmt.columnText(4));
    errdefer allocator.free(edge_type);
    try items.append(allocator, .{
        .edge_key = edge_key,
        .neighbor_node_key = neighbor_node_key,
        .node_id = node_id,
        .kind = kind,
        .edge_type = edge_type,
    });
}

fn appendGraphScanNode(
    items: *std.ArrayList(GraphScanNode),
    allocator: std.mem.Allocator,
    stmt: *sqlite.Statement,
) Error!void {
    const node_key = stmt.columnInt64(0);
    const created_order = stmt.columnInt64(3);
    if (node_key <= 0 or created_order <= 0) return error.GraphInvalid;
    const node_id = try allocator.dupe(u8, stmt.columnText(1));
    errdefer allocator.free(node_id);
    const kind = try allocator.dupe(u8, stmt.columnText(2));
    errdefer allocator.free(kind);
    try items.append(allocator, .{
        .node_key = node_key,
        .node_id = node_id,
        .kind = kind,
        .created_order = created_order,
    });
}

fn appendGraphScanEdge(
    items: *std.ArrayList(GraphScanEdge),
    allocator: std.mem.Allocator,
    stmt: *sqlite.Statement,
) Error!void {
    const edge_key = stmt.columnInt64(0);
    const source_node_key = stmt.columnInt64(1);
    const target_node_key = stmt.columnInt64(3);
    const created_order = stmt.columnInt64(4);
    if (edge_key <= 0 or source_node_key <= 0 or target_node_key <= 0 or created_order <= 0) return error.GraphInvalid;
    const edge_type = try allocator.dupe(u8, stmt.columnText(2));
    errdefer allocator.free(edge_type);
    try items.append(allocator, .{
        .edge_key = edge_key,
        .source_node_key = source_node_key,
        .edge_type = edge_type,
        .target_node_key = target_node_key,
        .created_order = created_order,
    });
}

fn validateGraphScanCursor(cursor: GraphScanCursor) Error!void {
    if (cursor.created_order == 0 and cursor.key == 0) return;
    if (cursor.created_order <= 0 or cursor.key <= 0) return error.InvalidArgument;
}

fn graphWalkItemOwned(
    allocator: std.mem.Allocator,
    node_id_source: []const u8,
    kind_source: []const u8,
    depth: u32,
    predecessor_source: ?[]const u8,
    edge_type_source: ?[]const u8,
) Error!GraphWalkItem {
    const node_id = try allocator.dupe(u8, node_id_source);
    errdefer allocator.free(node_id);
    const kind = try allocator.dupe(u8, kind_source);
    errdefer allocator.free(kind);
    const predecessor_node_id = if (predecessor_source) |value| try allocator.dupe(u8, value) else null;
    errdefer if (predecessor_node_id) |value| allocator.free(value);
    const edge_type = if (edge_type_source) |value| try allocator.dupe(u8, value) else null;
    errdefer if (edge_type) |value| allocator.free(value);

    return .{
        .node_id = node_id,
        .kind = kind,
        .depth = depth,
        .predecessor_node_id = predecessor_node_id,
        .edge_type = edge_type,
    };
}

fn appendGraphWalkItem(
    items: *std.ArrayList(GraphWalkItem),
    allocator: std.mem.Allocator,
    node_id: []const u8,
    kind: []const u8,
    depth: u32,
    predecessor_node_id: ?[]const u8,
    edge_type: ?[]const u8,
) Error!void {
    var item = try graphWalkItemOwned(allocator, node_id, kind, depth, predecessor_node_id, edge_type);
    errdefer item.deinit(allocator);
    try items.append(allocator, item);
}

fn putVisited(visited: *std.StringHashMap(void), allocator: std.mem.Allocator, node_id: []const u8) Error!void {
    const owned_node_id = try allocator.dupe(u8, node_id);
    errdefer allocator.free(owned_node_id);
    try visited.put(owned_node_id, {});
}

fn freeVisitedKeys(allocator: std.mem.Allocator, visited: *std.StringHashMap(void)) void {
    var key_it = visited.keyIterator();
    while (key_it.next()) |key| allocator.free(key.*);
    visited.deinit();
}

pub fn validateGraphName(name: []const u8) Error!void {
    try validateAsciiName(name, max_graph_name_bytes);
}

pub fn validateNodeId(id: []const u8) Error!void {
    if (id.len == 0 or id.len > max_node_id_bytes) return error.GraphInvalid;
    if (!std.unicode.utf8ValidateSlice(id)) return error.GraphInvalid;
    if (hasReservedZovaPrefix(id)) return error.GraphInvalid;
    for (id) |byte| {
        if (byte == 0) return error.GraphInvalid;
    }
}

pub fn validateEdgeType(edge_type: []const u8) Error!void {
    try validateAsciiName(edge_type, max_edge_type_bytes);
}

fn validateNodeKind(kind: []const u8) Error!void {
    try validateAsciiName(kind, max_kind_bytes);
}

fn validateOptionalText(value: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.GraphInvalid;
    for (value) |byte| {
        if (byte == 0) return error.GraphInvalid;
    }
}

fn sqliteLimit(limit: usize) Error!i64 {
    return std.math.cast(i64, limit) orelse error.GraphInvalid;
}

fn validateAsciiName(name: []const u8, max_len: usize) Error!void {
    if (name.len == 0 or name.len > max_len) return error.GraphInvalid;
    if (hasReservedZovaPrefix(name)) return error.GraphInvalid;
    for (name) |byte| {
        if (!isGraphNameByte(byte)) return error.GraphInvalid;
    }
}

fn isGraphNameByte(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or
        byte == '_' or
        byte == '.' or
        byte == ':' or
        byte == '-';
}

fn hasReservedZovaPrefix(name: []const u8) bool {
    const reserved = "_zova_";
    if (name.len < reserved.len) return false;
    for (reserved, 0..) |expected, index| {
        if (std.ascii.toLower(name[index]) != expected) return false;
    }
    return true;
}

pub fn targetTypeText(target_type: GraphTargetType) []const u8 {
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

pub fn targetTypeFromText(text: []const u8) Error!GraphTargetType {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "record")) return .record;
    if (std.mem.eql(u8, text, "object")) return .object;
    if (std.mem.eql(u8, text, "object_chunk")) return .object_chunk;
    if (std.mem.eql(u8, text, "vector")) return .vector;
    if (std.mem.eql(u8, text, "entity")) return .entity;
    if (std.mem.eql(u8, text, "fact")) return .fact;
    if (std.mem.eql(u8, text, "concept")) return .concept;
    if (std.mem.eql(u8, text, "external")) return .external;
    return error.GraphInvalid;
}
