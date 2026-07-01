//! Native graph relationship storage and bounded traversal.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova_error = @import("zova_error.zig");

pub const Error = zova_error.Error;

pub const graphs_table = "_zova_graphs";
pub const graph_nodes_table = "_zova_graph_nodes";
pub const graph_edges_table = "_zova_graph_edges";
pub const default_graph_name = "default";

const max_graph_name_bytes: usize = 128;
const max_node_id_bytes: usize = 512;
const max_edge_type_bytes: usize = 128;
const max_kind_bytes: usize = 128;

pub const graphs_schema_sql =
    \\create table _zova_graphs (
    \\  name text not null primary key check (length(name) > 0 and length(name) <= 128),
    \\  created_order integer not null
    \\)
;

pub const graph_nodes_schema_sql =
    \\create table _zova_graph_nodes (
    \\  graph_name text not null,
    \\  node_id text not null check (length(node_id) > 0 and length(node_id) <= 512),
    \\  kind text not null check (length(kind) > 0 and length(kind) <= 128),
    \\  target_type text not null check (target_type in ('none', 'record', 'object', 'object_chunk', 'vector', 'entity', 'fact', 'concept', 'external')),
    \\  target_namespace text,
    \\  target_ref text,
    \\  created_order integer not null,
    \\  primary key (graph_name, node_id),
    \\  foreign key (graph_name) references _zova_graphs(name)
    \\)
;

pub const graph_edges_schema_sql =
    \\create table _zova_graph_edges (
    \\  graph_name text not null,
    \\  from_node_id text not null,
    \\  edge_type text not null check (length(edge_type) > 0 and length(edge_type) <= 128),
    \\  to_node_id text not null,
    \\  created_order integer not null,
    \\  primary key (graph_name, from_node_id, edge_type, to_node_id),
    \\  foreign key (graph_name, from_node_id) references _zova_graph_nodes(graph_name, node_id),
    \\  foreign key (graph_name, to_node_id) references _zova_graph_nodes(graph_name, node_id)
    \\)
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

pub const GraphWalkOptions = struct {
    graph_name: []const u8 = default_graph_name,
    start_node_id: []const u8,
    edge_type: ?[]const u8 = null,
    max_depth: u32 = 1,
    limit: usize = 10,
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

    pub fn createGraph(self: *Database, name: []const u8) Error!void {
        try validateGraphName(name);

        var stmt = try self.sqlite_db.prepare(
            \\insert into _zova_graphs (name, created_order)
            \\values (?, coalesce((select max(created_order) + 1 from _zova_graphs), 1))
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

        if (!try self.hasGraph(name)) return error.GraphNotFound;
        var delete_edges = try self.sqlite_db.prepare("delete from _zova_graph_edges where graph_name = ?");
        defer delete_edges.deinit();
        try delete_edges.bindText(1, name);
        std.debug.assert((try delete_edges.step()) == .done);

        var delete_nodes = try self.sqlite_db.prepare("delete from _zova_graph_nodes where graph_name = ?");
        defer delete_nodes.deinit();
        try delete_nodes.bindText(1, name);
        std.debug.assert((try delete_nodes.step()) == .done);

        var delete_graph = try self.sqlite_db.prepare("delete from _zova_graphs where name = ?");
        defer delete_graph.deinit();
        try delete_graph.bindText(1, name);
        std.debug.assert((try delete_graph.step()) == .done);
    }

    pub fn hasGraph(self: *Database, name: []const u8) Error!bool {
        try validateGraphName(name);

        var stmt = try self.sqlite_db.prepare("select count(*) from _zova_graphs where name = ?");
        defer stmt.deinit();
        try stmt.bindText(1, name);
        std.debug.assert((try stmt.step()) == .row);
        return stmt.columnInt64(0) == 1;
    }

    pub fn graphInfo(self: *Database, allocator: std.mem.Allocator, name: []const u8) Error!GraphInfo {
        try validateGraphName(name);

        var stmt = try self.sqlite_db.prepare(
            \\select g.name,
            \\  (select count(*) from _zova_graph_nodes n where n.graph_name = g.name),
            \\  (select count(*) from _zova_graph_edges e where e.graph_name = g.name)
            \\from _zova_graphs g
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
        var stmt = try self.sqlite_db.prepare(
            \\select g.name,
            \\  (select count(*) from _zova_graph_nodes n where n.graph_name = g.name),
            \\  (select count(*) from _zova_graph_edges e where e.graph_name = g.name)
            \\from _zova_graphs g
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
        if (!try self.hasGraph(input.graph_name)) return error.GraphNotFound;

        var stmt = try self.sqlite_db.prepare(
            \\insert into _zova_graph_nodes
            \\  (graph_name, node_id, kind, target_type, target_namespace, target_ref, created_order)
            \\values (?, ?, ?, ?, ?, ?, coalesce((select max(created_order) + 1 from _zova_graph_nodes where graph_name = ?), 1))
            \\on conflict(graph_name, node_id) do update set
            \\  kind = excluded.kind,
            \\  target_type = excluded.target_type,
            \\  target_namespace = excluded.target_namespace,
            \\  target_ref = excluded.target_ref
        );
        defer stmt.deinit();

        try stmt.bindText(1, input.graph_name);
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
        try stmt.bindText(7, input.graph_name);
        std.debug.assert((try stmt.step()) == .done);
    }

    pub fn getGraphNode(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, node_id: []const u8) Error!GraphNode {
        try validateGraphName(graph_name);
        try validateNodeId(node_id);

        var stmt = try self.sqlite_db.prepare(
            \\select graph_name, node_id, kind, target_type, target_namespace, target_ref
            \\from _zova_graph_nodes
            \\where graph_name = ? and node_id = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, graph_name);
        try stmt.bindText(2, node_id);

        return switch (try stmt.step()) {
            .done => error.GraphNodeNotFound,
            .row => try nodeFromRow(allocator, &stmt),
        };
    }

    pub fn hasGraphNode(self: *Database, graph_name: []const u8, node_id: []const u8) Error!bool {
        try validateGraphName(graph_name);
        try validateNodeId(node_id);

        var stmt = try self.sqlite_db.prepare("select count(*) from _zova_graph_nodes where graph_name = ? and node_id = ?");
        defer stmt.deinit();
        try stmt.bindText(1, graph_name);
        try stmt.bindText(2, node_id);
        std.debug.assert((try stmt.step()) == .row);
        return stmt.columnInt64(0) == 1;
    }

    pub fn deleteGraphNode(self: *Database, graph_name: []const u8, node_id: []const u8) Error!void {
        try validateGraphName(graph_name);
        try validateNodeId(node_id);
        if (!try self.hasGraphNode(graph_name, node_id)) return error.GraphNodeNotFound;

        var delete_edges = try self.sqlite_db.prepare(
            \\delete from _zova_graph_edges
            \\where graph_name = ? and (from_node_id = ? or to_node_id = ?)
        );
        defer delete_edges.deinit();
        try delete_edges.bindText(1, graph_name);
        try delete_edges.bindText(2, node_id);
        try delete_edges.bindText(3, node_id);
        std.debug.assert((try delete_edges.step()) == .done);

        var delete_node = try self.sqlite_db.prepare("delete from _zova_graph_nodes where graph_name = ? and node_id = ?");
        defer delete_node.deinit();
        try delete_node.bindText(1, graph_name);
        try delete_node.bindText(2, node_id);
        std.debug.assert((try delete_node.step()) == .done);
    }

    pub fn putGraphEdge(self: *Database, input: GraphEdgeInput) Error!void {
        try validateGraphName(input.graph_name);
        try validateNodeId(input.from_node_id);
        try validateNodeId(input.to_node_id);
        try validateEdgeType(input.edge_type);

        if (!try self.hasGraphNode(input.graph_name, input.from_node_id)) return error.GraphNodeNotFound;
        if (!try self.hasGraphNode(input.graph_name, input.to_node_id)) return error.GraphNodeNotFound;

        var stmt = try self.sqlite_db.prepare(
            \\insert into _zova_graph_edges (graph_name, from_node_id, edge_type, to_node_id, created_order)
            \\values (?, ?, ?, ?, coalesce((select max(created_order) + 1 from _zova_graph_edges where graph_name = ?), 1))
            \\on conflict(graph_name, from_node_id, edge_type, to_node_id) do nothing
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.graph_name);
        try stmt.bindText(2, input.from_node_id);
        try stmt.bindText(3, input.edge_type);
        try stmt.bindText(4, input.to_node_id);
        try stmt.bindText(5, input.graph_name);
        std.debug.assert((try stmt.step()) == .done);
    }

    pub fn hasGraphEdge(self: *Database, graph_name: []const u8, from_node_id: []const u8, edge_type: []const u8, to_node_id: []const u8) Error!bool {
        try validateGraphName(graph_name);
        try validateNodeId(from_node_id);
        try validateEdgeType(edge_type);
        try validateNodeId(to_node_id);

        var stmt = try self.sqlite_db.prepare(
            \\select count(*)
            \\from _zova_graph_edges
            \\where graph_name = ? and from_node_id = ? and edge_type = ? and to_node_id = ?
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

        var stmt = try self.sqlite_db.prepare(
            \\select graph_name, from_node_id, edge_type, to_node_id
            \\from _zova_graph_edges
            \\where graph_name = ? and from_node_id = ? and edge_type = ? and to_node_id = ?
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

        var stmt = try self.sqlite_db.prepare(
            \\delete from _zova_graph_edges
            \\where graph_name = ? and from_node_id = ? and edge_type = ? and to_node_id = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.graph_name);
        try stmt.bindText(2, input.from_node_id);
        try stmt.bindText(3, input.edge_type);
        try stmt.bindText(4, input.to_node_id);
        std.debug.assert((try stmt.step()) == .done);
    }

    pub fn graphNeighbors(self: *Database, allocator: std.mem.Allocator, options: GraphNeighborsOptions) Error!GraphNeighborList {
        try validateGraphName(options.graph_name);
        try validateNodeId(options.node_id);
        if (options.edge_type) |edge_type| try validateEdgeType(edge_type);
        const sqlite_limit = try sqliteLimit(options.limit);
        if (!try self.hasGraphNode(options.graph_name, options.node_id)) return error.GraphNodeNotFound;

        var stmt = switch (options.direction) {
            .outgoing => if (options.edge_type == null)
                try self.sqlite_db.prepare(
                    \\select n.node_id, n.kind, e.edge_type
                    \\from _zova_graph_edges e
                    \\join _zova_graph_nodes n on n.graph_name = e.graph_name and n.node_id = e.to_node_id
                    \\where e.graph_name = ? and e.from_node_id = ?
                    \\order by e.created_order, n.node_id
                    \\limit ?
                )
            else
                try self.sqlite_db.prepare(
                    \\select n.node_id, n.kind, e.edge_type
                    \\from _zova_graph_edges e
                    \\join _zova_graph_nodes n on n.graph_name = e.graph_name and n.node_id = e.to_node_id
                    \\where e.graph_name = ? and e.from_node_id = ? and e.edge_type = ?
                    \\order by e.created_order, n.node_id
                    \\limit ?
                ),
            .incoming => if (options.edge_type == null)
                try self.sqlite_db.prepare(
                    \\select n.node_id, n.kind, e.edge_type
                    \\from _zova_graph_edges e
                    \\join _zova_graph_nodes n on n.graph_name = e.graph_name and n.node_id = e.from_node_id
                    \\where e.graph_name = ? and e.to_node_id = ?
                    \\order by e.created_order, n.node_id
                    \\limit ?
                )
            else
                try self.sqlite_db.prepare(
                    \\select n.node_id, n.kind, e.edge_type
                    \\from _zova_graph_edges e
                    \\join _zova_graph_nodes n on n.graph_name = e.graph_name and n.node_id = e.from_node_id
                    \\where e.graph_name = ? and e.to_node_id = ? and e.edge_type = ?
                    \\order by e.created_order, n.node_id
                    \\limit ?
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

        return .{ .items = try items.toOwnedSlice(allocator) };
    }

    pub fn graphWalk(self: *Database, allocator: std.mem.Allocator, options: GraphWalkOptions) Error!GraphWalk {
        try validateGraphName(options.graph_name);
        try validateNodeId(options.start_node_id);
        if (options.edge_type) |edge_type| try validateEdgeType(edge_type);
        _ = try sqliteLimit(options.limit);
        if (!try self.hasGraphNode(options.graph_name, options.start_node_id)) return error.GraphNodeNotFound;

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

        const start = try self.getGraphNode(allocator, options.graph_name, options.start_node_id);
        defer {
            var owned_start = start;
            owned_start.deinit(allocator);
        }
        try putVisited(&visited, allocator, options.start_node_id);
        try appendGraphWalkItem(&frontier, allocator, start.node_id, start.kind, 0, null, null);

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

            var neighbors = try self.graphNeighbors(allocator, .{
                .graph_name = options.graph_name,
                .node_id = current_node_id,
                .direction = .outgoing,
                .edge_type = options.edge_type,
                .limit = options.limit,
            });
            defer neighbors.deinit(allocator);

            for (neighbors.items) |neighbor| {
                if (visited.contains(neighbor.node_id)) continue;
                try putVisited(&visited, allocator, neighbor.node_id);
                try appendGraphWalkItem(&frontier, allocator, neighbor.node_id, neighbor.kind, current_depth + 1, current_node_id, neighbor.edge_type);
            }
        }

        return .{ .items = try results.toOwnedSlice(allocator) };
    }
};

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
