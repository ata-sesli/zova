//! Graph mutation, traversal, keyed reads, and fresh graph loading.

const std = @import("std");
const graph = @import("../graph.zig");

const allocator = @import("values.zig").allocator;
const candidateIdSlices = @import("values.zig").candidateIdSlices;
const databaseHandle = @import("handles.zig").databaseHandle;
const emptyGraphEdge = @import("results.zig").emptyGraphEdge;
const emptyGraphInfo = @import("results.zig").emptyGraphInfo;
const emptyGraphKeyedNeighborResults = @import("results.zig").emptyGraphKeyedNeighborResults;
const emptyGraphList = @import("results.zig").emptyGraphList;
const emptyGraphNeighborResults = @import("results.zig").emptyGraphNeighborResults;
const emptyGraphNode = @import("results.zig").emptyGraphNode;
const emptyGraphScanResults = @import("results.zig").emptyGraphScanResults;
const emptyGraphWalkResults = @import("results.zig").emptyGraphWalkResults;
const failDb = @import("errors.zig").failDb;
const fillGraphEdge = @import("results.zig").fillGraphEdge;
const fillGraphEdgePayloadResults = @import("results.zig").fillGraphEdgePayloadResults;
const fillGraphInfo = @import("results.zig").fillGraphInfo;
const fillGraphKeyedEdgeResults = @import("results.zig").fillGraphKeyedEdgeResults;
const fillGraphKeyedNeighborResults = @import("results.zig").fillGraphKeyedNeighborResults;
const fillGraphKeyedNodeResults = @import("results.zig").fillGraphKeyedNodeResults;
const fillGraphList = @import("results.zig").fillGraphList;
const fillGraphNeighborResults = @import("results.zig").fillGraphNeighborResults;
const fillGraphNode = @import("results.zig").fillGraphNode;
const fillGraphScanResults = @import("results.zig").fillGraphScanResults;
const fillGraphWalkResults = @import("results.zig").fillGraphWalkResults;
const freshGraphEdgeInputSlices = @import("values.zig").freshGraphEdgeInputSlices;
const freshGraphEdgePayloadInputSlices = @import("values.zig").freshGraphEdgePayloadInputSlices;
const freshGraphNodeInputSlices = @import("values.zig").freshGraphNodeInputSlices;
const graphDirectionFromAbi = @import("values.zig").graphDirectionFromAbi;
const graphEdgeInputSlices = @import("values.zig").graphEdgeInputSlices;
const graphEdgePayloadReplacementSlices = @import("values.zig").graphEdgePayloadReplacementSlices;
const graphNodeInputSlices = @import("values.zig").graphNodeInputSlices;
const graphTargetTypeFromAbi = @import("values.zig").graphTargetTypeFromAbi;
const okDb = @import("errors.zig").okDb;
const optionalCStringSpan = @import("values.zig").optionalCStringSpan;
const zova_graph_build_fresh_keyed_request = @import("types.zig").zova_graph_build_fresh_keyed_request;
const zova_graph_build_fresh_prepared_keyed_with_payloads_request = @import("types.zig").zova_graph_build_fresh_prepared_keyed_with_payloads_request;
const zova_graph_create_request = @import("types.zig").zova_graph_create_request;
const zova_graph_degree_many_keyed_request = @import("types.zig").zova_graph_degree_many_keyed_request;
const zova_graph_degree_request = @import("types.zig").zova_graph_degree_request;
const zova_graph_delete_request = @import("types.zig").zova_graph_delete_request;
const zova_graph_edge_delete_many_request = @import("types.zig").zova_graph_edge_delete_many_request;
const zova_graph_edge_delete_request = @import("types.zig").zova_graph_edge_delete_request;
const zova_graph_edge_exists_request = @import("types.zig").zova_graph_edge_exists_request;
const zova_graph_edge_get_request = @import("types.zig").zova_graph_edge_get_request;
const zova_graph_edge_payload_get_many_request = @import("types.zig").zova_graph_edge_payload_get_many_request;
const zova_graph_edge_payload_replace_many_request = @import("types.zig").zova_graph_edge_payload_replace_many_request;
const zova_graph_edge_put_many_keyed_request = @import("types.zig").zova_graph_edge_put_many_keyed_request;
const zova_graph_edge_put_many_request = @import("types.zig").zova_graph_edge_put_many_request;
const zova_graph_edge_put_request = @import("types.zig").zova_graph_edge_put_request;
const zova_graph_edges_get_many_keyed_request = @import("types.zig").zova_graph_edges_get_many_keyed_request;
const zova_graph_exists_request = @import("types.zig").zova_graph_exists_request;
const zova_graph_info_get_request = @import("types.zig").zova_graph_info_get_request;
const zova_graph_list_request = @import("types.zig").zova_graph_list_request;
const zova_graph_neighbors_keyed_request = @import("types.zig").zova_graph_neighbors_keyed_request;
const zova_graph_neighbors_request = @import("types.zig").zova_graph_neighbors_request;
const zova_graph_node_delete_many_request = @import("types.zig").zova_graph_node_delete_many_request;
const zova_graph_node_delete_request = @import("types.zig").zova_graph_node_delete_request;
const zova_graph_node_exists_request = @import("types.zig").zova_graph_node_exists_request;
const zova_graph_node_get_request = @import("types.zig").zova_graph_node_get_request;
const zova_graph_node_put_many_keyed_request = @import("types.zig").zova_graph_node_put_many_keyed_request;
const zova_graph_node_put_many_request = @import("types.zig").zova_graph_node_put_many_request;
const zova_graph_node_put_request = @import("types.zig").zova_graph_node_put_request;
const zova_graph_nodes_get_many_keyed_request = @import("types.zig").zova_graph_nodes_get_many_keyed_request;
const zova_graph_scan_request = @import("types.zig").zova_graph_scan_request;
const zova_graph_walk_direction_profiled_request = @import("types.zig").zova_graph_walk_direction_profiled_request;
const zova_graph_walk_direction_request = @import("types.zig").zova_graph_walk_direction_request;
const zova_graph_walk_request = @import("types.zig").zova_graph_walk_request;
const zova_status = @import("types.zig").zova_status;

pub fn zova_graph_create(request: ?*const zova_graph_create_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    handle.db.createGraph(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_exists(request: ?*const zova_graph_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasGraph(std.mem.span(name)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_graph_info_get(request: ?*const zova_graph_info_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_info orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphInfo();
    var info = handle.db.graphInfo(allocator, std.mem.span(name)) catch |err| return failDb(handle, err);
    defer info.deinit(allocator);
    fillGraphInfo(out, info) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graphs_list(request: ?*const zova_graph_list_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_list orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphList();
    var list = handle.db.listGraphs(allocator) catch |err| return failDb(handle, err);
    defer list.deinit(allocator);
    fillGraphList(out, list.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_delete(request: ?*const zova_graph_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    handle.db.deleteGraph(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_node_put(request: ?*const zova_graph_node_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const kind = req.kind orelse return failDb(handle, error.InvalidArgument);
    const target_type = graphTargetTypeFromAbi(req.target_type) orelse return failDb(handle, error.InvalidArgument);
    handle.db.putGraphNode(.{
        .graph_name = std.mem.span(graph_name),
        .node_id = std.mem.span(node_id),
        .kind = std.mem.span(kind),
        .target_type = target_type,
        .target_namespace = optionalCStringSpan(req.target_namespace),
        .target_ref = optionalCStringSpan(req.target_ref),
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_node_put_many(request: ?*const zova_graph_node_put_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const nodes = graphNodeInputSlices(req.nodes, req.nodes_len) catch |err| return failDb(handle, err);
    defer if (nodes.len != 0) allocator.free(nodes);
    handle.db.putGraphNodes(nodes) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_node_put_many_keyed(request: ?*const zova_graph_node_put_many_keyed_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    if (req.out_node_keys_capacity < req.nodes_len) return .INVALID_ARGUMENT;
    if (req.nodes_len != 0 and (req.nodes == null or req.out_node_keys == null)) return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const nodes = graphNodeInputSlices(req.nodes, req.nodes_len) catch |err| return failDb(handle, err);
    defer if (nodes.len != 0) allocator.free(nodes);
    const keys = allocator.alloc(i64, nodes.len) catch |err| return failDb(handle, err);
    defer allocator.free(keys);
    handle.db.putGraphNodesKeyed(nodes, keys) catch |err| return failDb(handle, err);
    if (keys.len != 0) @memcpy(req.out_node_keys.?[0..keys.len], keys);
    return okDb(handle);
}

fn graphBuildFreshKeyed(request: ?*const zova_graph_build_fresh_keyed_request, comptime prepared: bool) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    if (req.out_node_keys_capacity < req.nodes_len or req.out_edge_keys_capacity < req.edges_len) return .INVALID_ARGUMENT;
    if (req.nodes_len != 0 and (req.nodes == null or req.out_node_keys == null)) return .INVALID_ARGUMENT;
    if (req.edges_len != 0 and (req.edges == null or req.out_edge_keys == null)) return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const graph_name = req.graph_name orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const nodes = freshGraphNodeInputSlices(req.nodes, req.nodes_len) catch |err| return failDb(handle, err);
    defer if (nodes.len != 0) allocator.free(nodes);
    const edges = freshGraphEdgeInputSlices(req.edges, req.edges_len) catch |err| return failDb(handle, err);
    defer if (edges.len != 0) allocator.free(edges);
    const node_keys = allocator.alloc(i64, nodes.len) catch |err| return failDb(handle, err);
    defer allocator.free(node_keys);
    const edge_keys = allocator.alloc(i64, edges.len) catch |err| return failDb(handle, err);
    defer allocator.free(edge_keys);
    if (prepared) {
        handle.db.buildFreshGraphPreparedKeyed(std.mem.span(graph_name), nodes, edges, node_keys, edge_keys) catch |err| return failDb(handle, err);
    } else {
        handle.db.buildFreshGraphKeyed(std.mem.span(graph_name), nodes, edges, node_keys, edge_keys) catch |err| return failDb(handle, err);
    }
    if (node_keys.len != 0) @memcpy(req.out_node_keys.?[0..node_keys.len], node_keys);
    if (edge_keys.len != 0) @memcpy(req.out_edge_keys.?[0..edge_keys.len], edge_keys);
    return okDb(handle);
}

pub fn zova_graph_build_fresh_keyed(request: ?*const zova_graph_build_fresh_keyed_request) callconv(.c) zova_status {
    return graphBuildFreshKeyed(request, false);
}

pub fn zova_graph_build_fresh_prepared_keyed(request: ?*const zova_graph_build_fresh_keyed_request) callconv(.c) zova_status {
    return graphBuildFreshKeyed(request, true);
}

pub fn zova_graph_build_fresh_prepared_keyed_with_payloads(request: ?*const zova_graph_build_fresh_prepared_keyed_with_payloads_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    if (req.out_node_keys_capacity < req.nodes_len or req.out_edge_keys_capacity < req.edges_len) return .INVALID_ARGUMENT;
    if (req.nodes_len != 0 and (req.nodes == null or req.out_node_keys == null)) return .INVALID_ARGUMENT;
    if (req.edges_len != 0 and (req.edges == null or req.out_edge_keys == null)) return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const graph_name = req.graph_name orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const nodes = freshGraphNodeInputSlices(req.nodes, req.nodes_len) catch |err| return failDb(handle, err);
    defer if (nodes.len != 0) allocator.free(nodes);
    const edges = freshGraphEdgePayloadInputSlices(req.edges, req.edges_len) catch |err| return failDb(handle, err);
    defer if (edges.len != 0) allocator.free(edges);
    const node_keys = allocator.alloc(i64, nodes.len) catch |err| return failDb(handle, err);
    defer allocator.free(node_keys);
    const edge_keys = allocator.alloc(i64, edges.len) catch |err| return failDb(handle, err);
    defer allocator.free(edge_keys);
    handle.db.buildFreshGraphPreparedKeyed(std.mem.span(graph_name), nodes, edges, node_keys, edge_keys) catch |err| return failDb(handle, err);
    if (node_keys.len != 0) @memcpy(req.out_node_keys.?[0..node_keys.len], node_keys);
    if (edge_keys.len != 0) @memcpy(req.out_edge_keys.?[0..edge_keys.len], edge_keys);
    return okDb(handle);
}

pub fn zova_graph_node_get(request: ?*const zova_graph_node_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_node orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphNode();
    var node = handle.db.getGraphNode(allocator, std.mem.span(graph_name), std.mem.span(node_id)) catch |err| return failDb(handle, err);
    defer node.deinit(allocator);
    fillGraphNode(out, node) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_node_exists(request: ?*const zova_graph_node_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasGraphNode(std.mem.span(graph_name), std.mem.span(node_id)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_graph_node_delete(request: ?*const zova_graph_node_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    handle.db.deleteGraphNode(std.mem.span(graph_name), std.mem.span(node_id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_node_delete_many(request: ?*const zova_graph_node_delete_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_ids = candidateIdSlices(req.node_ids, req.node_count) catch |err| return failDb(handle, err);
    defer if (node_ids.len != 0) allocator.free(node_ids);
    handle.db.deleteGraphNodes(std.mem.span(graph_name), node_ids) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_put(request: ?*const zova_graph_edge_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const from_node_id = req.from_node_id orelse return failDb(handle, error.InvalidArgument);
    const edge_type = req.edge_type orelse return failDb(handle, error.InvalidArgument);
    const to_node_id = req.to_node_id orelse return failDb(handle, error.InvalidArgument);
    handle.db.putGraphEdge(.{
        .graph_name = std.mem.span(graph_name),
        .from_node_id = std.mem.span(from_node_id),
        .edge_type = std.mem.span(edge_type),
        .to_node_id = std.mem.span(to_node_id),
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_put_many(request: ?*const zova_graph_edge_put_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const edges = graphEdgeInputSlices(req.edges, req.edges_len) catch |err| return failDb(handle, err);
    defer if (edges.len != 0) allocator.free(edges);
    handle.db.putGraphEdges(edges) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_put_many_keyed(request: ?*const zova_graph_edge_put_many_keyed_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    if (req.out_edge_keys_capacity < req.edges_len) return .INVALID_ARGUMENT;
    if (req.edges_len != 0 and (req.edges == null or req.out_edge_keys == null)) return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const edges = graphEdgeInputSlices(req.edges, req.edges_len) catch |err| return failDb(handle, err);
    defer if (edges.len != 0) allocator.free(edges);
    const keys = allocator.alloc(i64, edges.len) catch |err| return failDb(handle, err);
    defer allocator.free(keys);
    handle.db.putGraphEdgesKeyed(edges, keys) catch |err| return failDb(handle, err);
    if (keys.len != 0) @memcpy(req.out_edge_keys.?[0..keys.len], keys);
    return okDb(handle);
}

pub fn zova_graph_edge_delete_many(request: ?*const zova_graph_edge_delete_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const edges = graphEdgeInputSlices(req.edges, req.edges_len) catch |err| return failDb(handle, err);
    defer if (edges.len != 0) allocator.free(edges);
    handle.db.deleteGraphEdges(edges) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_get(request: ?*const zova_graph_edge_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const from_node_id = req.from_node_id orelse return failDb(handle, error.InvalidArgument);
    const edge_type = req.edge_type orelse return failDb(handle, error.InvalidArgument);
    const to_node_id = req.to_node_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_edge orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphEdge();
    var edge = handle.db.getGraphEdge(allocator, std.mem.span(graph_name), std.mem.span(from_node_id), std.mem.span(edge_type), std.mem.span(to_node_id)) catch |err| return failDb(handle, err);
    defer edge.deinit(allocator);
    fillGraphEdge(out, edge) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_exists(request: ?*const zova_graph_edge_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const from_node_id = req.from_node_id orelse return failDb(handle, error.InvalidArgument);
    const edge_type = req.edge_type orelse return failDb(handle, error.InvalidArgument);
    const to_node_id = req.to_node_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasGraphEdge(std.mem.span(graph_name), std.mem.span(from_node_id), std.mem.span(edge_type), std.mem.span(to_node_id)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_graph_edge_delete(request: ?*const zova_graph_edge_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const from_node_id = req.from_node_id orelse return failDb(handle, error.InvalidArgument);
    const edge_type = req.edge_type orelse return failDb(handle, error.InvalidArgument);
    const to_node_id = req.to_node_id orelse return failDb(handle, error.InvalidArgument);
    handle.db.deleteGraphEdge(.{
        .graph_name = std.mem.span(graph_name),
        .from_node_id = std.mem.span(from_node_id),
        .edge_type = std.mem.span(edge_type),
        .to_node_id = std.mem.span(to_node_id),
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_neighbors(request: ?*const zova_graph_neighbors_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const direction = graphDirectionFromAbi(req.direction) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphNeighborResults();
    var results = handle.db.graphNeighbors(allocator, .{
        .graph_name = std.mem.span(graph_name),
        .node_id = std.mem.span(node_id),
        .direction = direction,
        .edge_type = optionalCStringSpan(req.edge_type),
        .limit = req.limit,
    }) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphNeighborResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_neighbors_keyed(request: ?*const zova_graph_neighbors_keyed_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const out = req.out_results orelse return .INVALID_ARGUMENT;
    out.* = emptyGraphKeyedNeighborResults();
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const direction = graphDirectionFromAbi(req.direction) orelse return failDb(handle, error.InvalidArgument);
    var results = handle.db.graphNeighborsKeyed(allocator, .{
        .graph_name = std.mem.span(graph_name),
        .node_id = std.mem.span(node_id),
        .direction = direction,
        .edge_type = optionalCStringSpan(req.edge_type),
        .limit = req.limit,
    }) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphKeyedNeighborResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_nodes_get_many_keyed(request: ?*const zova_graph_nodes_get_many_keyed_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const out = req.out_results orelse return .INVALID_ARGUMENT;
    out.* = .{ .items = null, .len = 0 };
    const graph_name = req.graph_name orelse return .INVALID_ARGUMENT;
    if (req.key_count != 0 and req.node_keys == null) return .INVALID_ARGUMENT;
    const keys: []const i64 = if (req.key_count == 0) &.{} else req.node_keys.?[0..req.key_count];
    for (keys) |key| if (key <= 0) return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    var results = handle.db.graphNodesGetManyKeyed(allocator, std.mem.span(graph_name), keys) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphKeyedNodeResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edges_get_many_keyed(request: ?*const zova_graph_edges_get_many_keyed_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const out = req.out_results orelse return .INVALID_ARGUMENT;
    out.* = .{ .items = null, .len = 0 };
    const graph_name = req.graph_name orelse return .INVALID_ARGUMENT;
    if (req.key_count != 0 and req.edge_keys == null) return .INVALID_ARGUMENT;
    const keys: []const i64 = if (req.key_count == 0) &.{} else req.edge_keys.?[0..req.key_count];
    for (keys) |key| if (key <= 0) return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    var results = handle.db.graphEdgesGetManyKeyed(allocator, std.mem.span(graph_name), keys) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphKeyedEdgeResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_payload_get_many(request: ?*const zova_graph_edge_payload_get_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const out = req.out_results orelse return .INVALID_ARGUMENT;
    out.* = .{ .items = null, .len = 0 };
    const graph_name = req.graph_name orelse return .INVALID_ARGUMENT;
    if (req.key_count != 0 and req.edge_keys == null) return .INVALID_ARGUMENT;
    const keys: []const i64 = if (req.key_count == 0) &.{} else req.edge_keys.?[0..req.key_count];
    for (keys) |key| if (key <= 0) return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    var results = handle.db.graphEdgePayloadsGetMany(allocator, std.mem.span(graph_name), keys) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphEdgePayloadResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_payload_replace_many(request: ?*const zova_graph_edge_payload_replace_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const graph_name = req.graph_name orelse return .INVALID_ARGUMENT;
    if (req.replacement_count != 0 and req.replacements == null) return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const replacements = graphEdgePayloadReplacementSlices(req.replacements, req.replacement_count) catch |err| return failDb(handle, err);
    defer if (replacements.len != 0) allocator.free(replacements);
    handle.mutex.lock();
    defer handle.mutex.unlock();
    handle.db.replaceGraphEdgePayloads(std.mem.span(graph_name), replacements) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_degree(request: ?*const zova_graph_degree_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const direction = graphDirectionFromAbi(req.direction) orelse return failDb(handle, error.InvalidArgument);
    const out_degree = req.out_degree orelse return failDb(handle, error.InvalidArgument);
    out_degree.* = handle.db.graphDegree(.{
        .graph_name = std.mem.span(graph_name),
        .node_id = std.mem.span(node_id),
        .direction = direction,
        .edge_type = optionalCStringSpan(req.edge_type),
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_degree_many_keyed(request: ?*const zova_graph_degree_many_keyed_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    if (req.out_degrees_capacity < req.node_count) return .INVALID_ARGUMENT;
    if (req.node_count != 0 and (req.node_keys == null or req.out_degrees == null)) return .INVALID_ARGUMENT;
    const graph_name = req.graph_name orelse return .INVALID_ARGUMENT;
    const direction = graphDirectionFromAbi(req.direction) orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const node_keys: []const i64 = if (req.node_count == 0) &.{} else req.node_keys.?[0..req.node_count];
    const degrees = allocator.alloc(u64, req.node_count) catch |err| return failDb(handle, err);
    defer allocator.free(degrees);
    handle.db.graphDegreeManyKeyed(
        std.mem.span(graph_name),
        node_keys,
        direction,
        optionalCStringSpan(req.edge_type),
        degrees,
    ) catch |err| return failDb(handle, err);
    if (degrees.len != 0) @memcpy(req.out_degrees.?[0..degrees.len], degrees);
    return okDb(handle);
}

pub fn zova_graph_scan(request: ?*const zova_graph_scan_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const out = req.out_results orelse return .INVALID_ARGUMENT;
    out.* = emptyGraphScanResults();
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    var results = handle.db.graphScan(allocator, .{
        .graph_name = std.mem.span(graph_name),
        .node_after = .{ .created_order = req.node_after.created_order, .key = req.node_after.key },
        .edge_after = .{ .created_order = req.edge_after.created_order, .key = req.edge_after.key },
        .node_limit = req.node_limit,
        .edge_limit = req.edge_limit,
    }) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphScanResults(out, results) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_walk(request: ?*const zova_graph_walk_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const start_node_id = req.start_node_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphWalkResults();
    var results = handle.db.graphWalk(allocator, .{
        .graph_name = std.mem.span(graph_name),
        .start_node_id = std.mem.span(start_node_id),
        .edge_type = optionalCStringSpan(req.edge_type),
        .max_depth = req.max_depth,
        .limit = req.limit,
    }) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphWalkResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_walk_direction(request: ?*const zova_graph_walk_direction_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const start_node_id = req.start_node_id orelse return failDb(handle, error.InvalidArgument);
    const direction = graphDirectionFromAbi(req.direction) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphWalkResults();
    var results = handle.db.graphWalkDirection(allocator, .{
        .graph_name = std.mem.span(graph_name),
        .start_node_id = std.mem.span(start_node_id),
        .direction = direction,
        .edge_type = optionalCStringSpan(req.edge_type),
        .max_depth = req.max_depth,
        .limit = req.limit,
    }) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphWalkResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_walk_direction_profiled(request: ?*const zova_graph_walk_direction_profiled_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const out = req.out_results orelse return .INVALID_ARGUMENT;
    const out_profile = req.out_profile orelse return .INVALID_ARGUMENT;
    out.* = emptyGraphWalkResults();
    out_profile.* = .{};

    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const total_start = cAbiProfileTimestamp();
    const mutex_start = cAbiProfileTimestamp();
    handle.mutex.lock();
    out_profile.mutex_wait_ms = cAbiProfileElapsedMs(mutex_start);
    defer handle.mutex.unlock();

    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const start_node_id = req.start_node_id orelse return failDb(handle, error.InvalidArgument);
    const direction = graphDirectionFromAbi(req.direction) orelse return failDb(handle, error.InvalidArgument);
    var scan_profile: graph.GraphWalkScanProfile = .{};
    const traversal_start = cAbiProfileTimestamp();
    var results = handle.db.graphWalkDirectionProfiled(allocator, .{
        .graph_name = std.mem.span(graph_name),
        .start_node_id = std.mem.span(start_node_id),
        .direction = direction,
        .edge_type = optionalCStringSpan(req.edge_type),
        .max_depth = req.max_depth,
        .limit = req.limit,
    }, &scan_profile) catch |err| return failDb(handle, err);
    var results_active = true;
    defer if (results_active) results.deinit(allocator);
    const traversal_ms = cAbiProfileElapsedMs(traversal_start);

    out_profile.root_lookup_ms = scan_profile.root_lookup_ms;
    out_profile.adjacency_prepare_ms = scan_profile.adjacency_prepare_ms;
    out_profile.adjacency_execute_ms = scan_profile.adjacency_execute_ms;
    const traversal_accounted_ms = scan_profile.root_lookup_ms + scan_profile.adjacency_prepare_ms + scan_profile.adjacency_execute_ms;
    out_profile.bfs_bookkeeping_allocation_ms = @max(0, traversal_ms - traversal_accounted_ms);
    out_profile.frontier_expansions = scan_profile.frontier_expansions;
    out_profile.adjacency_query_binds = scan_profile.adjacency_query_binds;
    out_profile.adjacency_rows_stepped = scan_profile.adjacency_rows_stepped;
    out_profile.result_count = scan_profile.result_count;

    const export_start = cAbiProfileTimestamp();
    fillGraphWalkResults(out, results.items) catch |err| return failDb(handle, err);
    out_profile.c_abi_result_export_ms = cAbiProfileElapsedMs(export_start);
    const cleanup_start = cAbiProfileTimestamp();
    results.deinit(allocator);
    results_active = false;
    out_profile.bfs_bookkeeping_allocation_ms += cAbiProfileElapsedMs(cleanup_start);
    out_profile.total_profiled_ms = cAbiProfileElapsedMs(total_start);
    return okDb(handle);
}

fn cAbiProfileIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn cAbiProfileTimestamp() std.Io.Timestamp {
    return std.Io.Clock.awake.now(cAbiProfileIo());
}

fn cAbiProfileElapsedMs(start: std.Io.Timestamp) f64 {
    const elapsed_ns = start.durationTo(cAbiProfileTimestamp()).toNanoseconds();
    if (elapsed_ns <= 0) return 0;
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms);
}
