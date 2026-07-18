//! Native graph relationship storage and bounded traversal.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova_error = @import("zova_error.zig");

pub const Error = zova_error.Error;

pub const graphs_table = "_zova_graphs";
pub const graph_nodes_table = "_zova_graph_nodes";
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
    edge_type: []const u8,
    to_node_key: i64,
};

const GraphEdgeKeyTupleContext = struct {
    pub fn hash(_: GraphEdgeKeyTupleContext, value: GraphEdgeKeyTuple) u64 {
        var digest = std.hash.Wyhash.hash(@bitCast(value.graph_key), std.mem.asBytes(&value.from_node_key));
        digest = std.hash.Wyhash.hash(digest, value.edge_type);
        return std.hash.Wyhash.hash(digest, std.mem.asBytes(&value.to_node_key));
    }

    pub fn eql(_: GraphEdgeKeyTupleContext, left: GraphEdgeKeyTuple, right: GraphEdgeKeyTuple) bool {
        return left.graph_key == right.graph_key and
            left.from_node_key == right.from_node_key and
            left.to_node_key == right.to_node_key and
            std.mem.eql(u8, left.edge_type, right.edge_type);
    }
};

const GraphEdgeKeySlotMap = std.HashMap(
    GraphEdgeKeyTuple,
    usize,
    GraphEdgeKeyTupleContext,
    std.hash_map.default_max_load_percentage,
);

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

pub const graph_edges_schema_sql =
    \\create table _zova_graph_edges (
    \\  edge_key integer primary key,
    \\  graph_key integer not null,
    \\  from_node_key integer not null,
    \\  edge_type text not null check (length(edge_type) > 0 and length(edge_type) <= 128),
    \\  to_node_key integer not null,
    \\  created_order integer not null,
    \\  unique (graph_key, from_node_key, edge_type, to_node_key),
    \\  foreign key (graph_key) references _zova_graphs(graph_key) on delete cascade,
    \\  foreign key (graph_key, from_node_key) references _zova_graph_nodes(graph_key, node_key) on delete cascade,
    \\  foreign key (graph_key, to_node_key) references _zova_graph_nodes(graph_key, node_key) on delete cascade
    \\)
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
    \\on _zova_graph_edges (graph_key, from_node_key, edge_type, created_order, to_node_key)
;

pub const graph_edges_to_node_index_sql =
    \\create index if not exists _zova_graph_edges_to_node_idx
    \\on _zova_graph_edges (graph_key, to_node_key, created_order, from_node_key)
;

pub const graph_edges_to_node_type_index_sql =
    \\create index if not exists _zova_graph_edges_to_node_type_idx
    \\on _zova_graph_edges (graph_key, to_node_key, edge_type, created_order, from_node_key)
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

        var stmt = try self.prepareSchema(
            \\/* zova_graph_edge_insert */
            \\insert into {s}_zova_graph_edges (graph_key, from_node_key, edge_type, to_node_key, created_order)
            \\values (?, ?, ?, ?, ?)
            \\on conflict(graph_key, from_node_key, edge_type, to_node_key) do nothing
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
            const created_order = try nextGraphCreatedOrder(&next_order_stmt, &next_orders, graph_key);
            try stmt.bindInt64(1, graph_key);
            try stmt.bindInt64(2, from_endpoint.node_key);
            try stmt.bindText(3, edge.input.edge_type);
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
            try affected_graph_keys.put(from.graph_key, {});
            const result = try key_slots.getOrPut(.{
                .graph_key = from.graph_key,
                .from_node_key = from.node_key,
                .edge_type = edge.input.edge_type,
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
            \\select from_node_key,edge_type,to_node_key,edge_key
            \\from {s}_zova_graph_edges where graph_key=?
        );
        defer preload.deinit();
        var affected_graph_key_iterator = affected_graph_keys.keyIterator();
        while (affected_graph_key_iterator.next()) |graph_key| {
            try preload.bindInt64(1, graph_key.*);
            while ((try preload.step()) == .row) {
                const slot = key_slots.get(.{
                    .graph_key = graph_key.*,
                    .from_node_key = preload.columnInt64(0),
                    .edge_type = preload.columnText(1),
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
            \\insert into {s}_zova_graph_edges (graph_key, from_node_key, edge_type, to_node_key, created_order)
            \\values (?, ?, ?, ?, ?)
            \\on conflict(graph_key, from_node_key, edge_type, to_node_key) do nothing
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
            const created_order = try nextGraphCreatedOrder(&next_order_stmt, &next_orders, from.graph_key);
            if (resolved_keys[key_slot]) |edge_key| {
                out_key.* = edge_key;
                continue;
            }
            try insert.bindInt64(1, from.graph_key);
            try insert.bindInt64(2, from.node_key);
            try insert.bindText(3, edge.input.edge_type);
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
            \\where (e.graph_key,e.from_node_key,e.to_node_key)=(
            \\  select g.graph_key,src.node_key,dst.node_key
            \\  from {s}_zova_graphs g
            \\  join {s}_zova_graph_nodes src on src.graph_key=g.graph_key and src.node_id=?2
            \\  join {s}_zova_graph_nodes dst on dst.graph_key=g.graph_key and dst.node_id=?4
            \\  where g.name=?1
            \\) and e.edge_type=?3
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
            \\select g.name, src.node_id, e.edge_type, dst.node_id
            \\from {s}_zova_graph_edges e
            \\join {s}_zova_graphs g on g.graph_key = e.graph_key
            \\join {s}_zova_graph_nodes src on src.node_key = e.from_node_key
            \\join {s}_zova_graph_nodes dst on dst.node_key = e.to_node_key
            \\where g.name = ? and src.node_id = ? and e.edge_type = ? and dst.node_id = ?
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
            \\  and edge_type = ?
            \\  and to_node_key = (select node_key from {s}_zova_graph_nodes where graph_key = (select graph_key from {s}_zova_graphs where name = ?) and node_id = ?)
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.graph_name);
        try stmt.bindText(2, input.graph_name);
        try stmt.bindText(3, input.from_node_id);
        try stmt.bindText(4, input.edge_type);
        try stmt.bindText(5, input.graph_name);
        try stmt.bindText(6, input.to_node_id);
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
            \\  and edge_type = ?
            \\  and to_node_key = ?
        );
        defer stmt.deinit();
        for (inputs) |input| {
            const graph_key = endpoints.graphKey(input.graph_name) orelse continue;
            const from_node_key = endpoints.nodeKey(input.graph_name, input.from_node_id) orelse continue;
            const to_node_key = endpoints.nodeKey(input.graph_name, input.to_node_id) orelse continue;
            try stmt.bindInt64(1, graph_key);
            try stmt.bindInt64(2, from_node_key);
            try stmt.bindText(3, input.edge_type);
            try stmt.bindInt64(4, to_node_key);
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
        const sqlite_limit = try sqliteLimit(options.limit);
        var stmt = switch (options.direction) {
            .outgoing => if (options.edge_type == null)
                try self.prepareSchema(
                    \\select n.node_id, n.kind, e.edge_type
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key=e.to_node_key
                    \\where (e.graph_key,e.from_node_key)=(
                    \\  select g.graph_key,current.node_key
                    \\  from {s}_zova_graphs g
                    \\  join {s}_zova_graph_nodes current on current.graph_key=g.graph_key
                    \\  where g.name=?1 and current.node_id=?2
                    \\)
                    \\order by e.created_order, e.to_node_key
                    \\limit ?3
                )
            else
                try self.prepareSchema(
                    \\select n.node_id, n.kind, e.edge_type
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key=e.to_node_key
                    \\where (e.graph_key,e.from_node_key)=(
                    \\  select g.graph_key,current.node_key
                    \\  from {s}_zova_graphs g
                    \\  join {s}_zova_graph_nodes current on current.graph_key=g.graph_key
                    \\  where g.name=?1 and current.node_id=?2
                    \\) and e.edge_type=?3
                    \\order by e.created_order, e.to_node_key
                    \\limit ?4
                ),
            .incoming => if (options.edge_type == null)
                try self.prepareSchema(
                    \\select n.node_id, n.kind, e.edge_type
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key=e.from_node_key
                    \\where (e.graph_key,e.to_node_key)=(
                    \\  select g.graph_key,current.node_key
                    \\  from {s}_zova_graphs g
                    \\  join {s}_zova_graph_nodes current on current.graph_key=g.graph_key
                    \\  where g.name=?1 and current.node_id=?2
                    \\)
                    \\order by e.created_order, e.from_node_key
                    \\limit ?3
                )
            else
                try self.prepareSchema(
                    \\select n.node_id, n.kind, e.edge_type
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key=e.from_node_key
                    \\where (e.graph_key,e.to_node_key)=(
                    \\  select g.graph_key,current.node_key
                    \\  from {s}_zova_graphs g
                    \\  join {s}_zova_graph_nodes current on current.graph_key=g.graph_key
                    \\  where g.name=?1 and current.node_id=?2
                    \\) and e.edge_type=?3
                    \\order by e.created_order, e.from_node_key
                    \\limit ?4
                ),
        };
        defer stmt.deinit();

        try stmt.bindText(1, options.graph_name);
        try stmt.bindText(2, options.node_id);
        if (options.edge_type) |edge_type| {
            try stmt.bindText(3, edge_type);
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
            try appendGraphNeighborFromRow(&items, allocator, &stmt);
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
        const sqlite_limit = try sqliteLimit(options.limit);
        var stmt = switch (options.direction) {
            .outgoing => if (options.edge_type == null)
                try self.prepareSchema(
                    \\select e.edge_key,n.node_key,n.node_id,n.kind,e.edge_type
                    \\from {s}_zova_graph_edges e join {s}_zova_graph_nodes n on n.node_key=e.to_node_key
                    \\where (e.graph_key,e.from_node_key)=(
                    \\ select g.graph_key,current.node_key from {s}_zova_graphs g
                    \\ join {s}_zova_graph_nodes current on current.graph_key=g.graph_key
                    \\ where g.name=?1 and current.node_id=?2)
                    \\order by e.created_order,n.node_id collate binary,n.node_key limit ?3
                )
            else
                try self.prepareSchema(
                    \\select e.edge_key,n.node_key,n.node_id,n.kind,e.edge_type
                    \\from {s}_zova_graph_edges e join {s}_zova_graph_nodes n on n.node_key=e.to_node_key
                    \\where (e.graph_key,e.from_node_key)=(
                    \\ select g.graph_key,current.node_key from {s}_zova_graphs g
                    \\ join {s}_zova_graph_nodes current on current.graph_key=g.graph_key
                    \\ where g.name=?1 and current.node_id=?2) and e.edge_type=?3
                    \\order by e.created_order,n.node_id collate binary,n.node_key limit ?4
                ),
            .incoming => if (options.edge_type == null)
                try self.prepareSchema(
                    \\select e.edge_key,n.node_key,n.node_id,n.kind,e.edge_type
                    \\from {s}_zova_graph_edges e join {s}_zova_graph_nodes n on n.node_key=e.from_node_key
                    \\where (e.graph_key,e.to_node_key)=(
                    \\ select g.graph_key,current.node_key from {s}_zova_graphs g
                    \\ join {s}_zova_graph_nodes current on current.graph_key=g.graph_key
                    \\ where g.name=?1 and current.node_id=?2)
                    \\order by e.created_order,n.node_id collate binary,n.node_key limit ?3
                )
            else
                try self.prepareSchema(
                    \\select e.edge_key,n.node_key,n.node_id,n.kind,e.edge_type
                    \\from {s}_zova_graph_edges e join {s}_zova_graph_nodes n on n.node_key=e.from_node_key
                    \\where (e.graph_key,e.to_node_key)=(
                    \\ select g.graph_key,current.node_key from {s}_zova_graphs g
                    \\ join {s}_zova_graph_nodes current on current.graph_key=g.graph_key
                    \\ where g.name=?1 and current.node_id=?2) and e.edge_type=?3
                    \\order by e.created_order,n.node_id collate binary,n.node_key limit ?4
                ),
        };
        defer stmt.deinit();
        try stmt.bindText(1, options.graph_name);
        try stmt.bindText(2, options.node_id);
        if (options.edge_type) |edge_type| {
            try stmt.bindText(3, edge_type);
            try stmt.bindInt64(4, sqlite_limit);
        } else try stmt.bindInt64(3, sqlite_limit);

        var items: std.ArrayList(GraphKeyedNeighbor) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }
        while ((try stmt.step()) == .row) try appendGraphKeyedNeighborFromRow(&items, allocator, &stmt);
        if (items.items.len == 0 and !try self.hasGraphNode(options.graph_name, options.node_id)) return error.GraphNodeNotFound;
        return .{ .items = try items.toOwnedSlice(allocator) };
    }

    pub fn graphNodesGetManyKeyed(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, keys: []const i64) Error!GraphKeyedNodeLookupList {
        try validateGraphName(graph_name);
        for (keys) |key| if (key <= 0) return error.InvalidArgument;
        const graph_key = try self.graphKey(graph_name);
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
        const graph_key = try self.graphKey(graph_name);
        var items = try allocator.alloc(GraphKeyedEdgeLookup, keys.len);
        errdefer allocator.free(items);
        for (keys, items) |key, *item| item.* = .{ .found = false, .edge_key = key };
        errdefer for (items) |*item| item.deinit(allocator);
        if (keys.len == 0) return .{ .items = items };

        try self.stageOpaqueKeys("_zova_graph_edges_get_many_keys", keys);
        defer self.clearOpaqueKeys("_zova_graph_edges_get_many_keys");
        var stmt = try self.prepareSchema(
            \\select batch.ordinal,e.edge_key,e.from_node_key,e.edge_type,e.to_node_key,e.created_order
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
            item.edge_type = try allocator.dupe(u8, stmt.columnText(3));
            item.source_node_key = source;
            item.target_node_key = target;
            item.created_order = created_order;
            item.found = true;
        }
        if (seen != keys.len) return error.GraphInvalid;
        return .{ .items = items };
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
        var stmt = switch (options.direction) {
            .outgoing => if (options.edge_type != null)
                try self.prepareSchema(
                    \\select count(*) from {s}_zova_graph_edges e
                    \\where (e.graph_key,e.from_node_key)=(
                    \\  select g.graph_key,n.node_key from {s}_zova_graphs g
                    \\  join {s}_zova_graph_nodes n on n.graph_key=g.graph_key
                    \\  where g.name=? and n.node_id=?
                    \\) and e.edge_type=?
                )
            else
                try self.prepareSchema(
                    \\select count(*) from {s}_zova_graph_edges e
                    \\where (e.graph_key,e.from_node_key)=(
                    \\  select g.graph_key,n.node_key from {s}_zova_graphs g
                    \\  join {s}_zova_graph_nodes n on n.graph_key=g.graph_key
                    \\  where g.name=? and n.node_id=?
                    \\)
                ),
            .incoming => if (options.edge_type != null)
                try self.prepareSchema(
                    \\select count(*) from {s}_zova_graph_edges e
                    \\where (e.graph_key,e.to_node_key)=(
                    \\  select g.graph_key,n.node_key from {s}_zova_graphs g
                    \\  join {s}_zova_graph_nodes n on n.graph_key=g.graph_key
                    \\  where g.name=? and n.node_id=?
                    \\) and e.edge_type=?
                )
            else
                try self.prepareSchema(
                    \\select count(*) from {s}_zova_graph_edges e
                    \\where (e.graph_key,e.to_node_key)=(
                    \\  select g.graph_key,n.node_key from {s}_zova_graphs g
                    \\  join {s}_zova_graph_nodes n on n.graph_key=g.graph_key
                    \\  where g.name=? and n.node_id=?
                    \\)
                ),
        };
        defer stmt.deinit();
        try stmt.bindText(1, options.graph_name);
        try stmt.bindText(2, options.node_id);
        if (options.edge_type) |edge_type| try stmt.bindText(3, edge_type);
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
        const graph_key = try self.graphKey(graph_name);
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
                    \\left join {s}_zova_graph_edges e on e.graph_key=n.graph_key and e.from_node_key=n.node_key and e.edge_type=?2
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
                    \\left join {s}_zova_graph_edges e on e.graph_key=n.graph_key and e.to_node_key=n.node_key and e.edge_type=?2
                    \\group by batch.ordinal order by batch.ordinal
                ),
        };
        defer query.deinit();
        try query.bindInt64(1, graph_key);
        if (edge_type) |value| try query.bindText(2, value);
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
                \\select edge_key,from_node_key,edge_type,to_node_key,created_order from {s}_zova_graph_edges
                \\where graph_key=?1 and (created_order>?2 or (created_order=?2 and edge_key>?3))
                \\order by created_order,edge_key limit ?4
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
                try appendGraphScanEdge(&edges, allocator, &stmt);
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
        var adjacency_stmt = try self.prepareWalkAdjacency(options.direction, options.edge_type);
        defer adjacency_stmt.deinit();
        try bindWalkAdjacencyConstants(&adjacency_stmt, resolved_start.graph_key, options, sqlite_limit);
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
                const neighbor_edge_type = adjacency_stmt.columnText(2);
                if (visited.contains(neighbor_node_id)) continue;
                try putVisited(&visited, allocator, neighbor_node_id);
                try appendGraphWalkItem(&frontier, allocator, neighbor_node_id, neighbor_kind, current_depth + 1, current_node_id, neighbor_edge_type);
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

    fn prepareWalkAdjacency(self: *Database, direction: GraphNeighborDirection, edge_type: ?[]const u8) Error!sqlite.Statement {
        return switch (direction) {
            .outgoing => if (edge_type == null)
                try self.prepareSchema(
                    \\select n.node_id, n.kind, e.edge_type
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
                    \\select n.node_id, n.kind, e.edge_type
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key = e.to_node_key
                    \\where e.graph_key=?1 and e.from_node_key=(
                    \\  select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2
                    \\) and e.edge_type=?3
                    \\order by e.created_order, e.to_node_key
                    \\limit ?
                ),
            .incoming => if (edge_type == null)
                try self.prepareSchema(
                    \\select n.node_id, n.kind, e.edge_type
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
                    \\select n.node_id, n.kind, e.edge_type
                    \\from {s}_zova_graph_edges e
                    \\join {s}_zova_graph_nodes n on n.node_key = e.from_node_key
                    \\where e.graph_key=?1 and e.to_node_key=(
                    \\  select node_key from {s}_zova_graph_nodes where graph_key=?1 and node_id=?2
                    \\) and e.edge_type=?3
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
    options: GraphWalkDirectionOptions,
    sqlite_limit: i64,
) Error!void {
    try stmt.bindInt64(1, graph_key);
    if (options.edge_type) |edge_type| {
        try stmt.bindText(3, edge_type);
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
        \\on _zova_graph_edges (graph_key, from_node_key, edge_type, created_order, to_node_key)
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
        \\on _zova_graph_edges (graph_key, to_node_key, edge_type, created_order, from_node_key)
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
