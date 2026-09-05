//! Owned C result construction, initialization, and destruction.

const std = @import("std");
const zova = @import("../zova.zig");

const allocator = @import("values.zig").allocator;
const graphTargetTypeToAbi = @import("values.zig").graphTargetTypeToAbi;
const vectorElementTypeToAbi = @import("values.zig").vectorElementTypeToAbi;
const vectorMetricToAbi = @import("values.zig").vectorMetricToAbi;
const zova_buffer = @import("types.zig").zova_buffer;
const zova_extension_info = @import("types.zig").zova_extension_info;
const zova_extension_list = @import("types.zig").zova_extension_list;
const zova_graph_edge = @import("types.zig").zova_graph_edge;
const zova_graph_edge_payload_result = @import("types.zig").zova_graph_edge_payload_result;
const zova_graph_edge_payload_results = @import("types.zig").zova_graph_edge_payload_results;
const zova_graph_info = @import("types.zig").zova_graph_info;
const zova_graph_keyed_edge_result = @import("types.zig").zova_graph_keyed_edge_result;
const zova_graph_keyed_edge_results = @import("types.zig").zova_graph_keyed_edge_results;
const zova_graph_keyed_neighbor_result = @import("types.zig").zova_graph_keyed_neighbor_result;
const zova_graph_keyed_neighbor_results = @import("types.zig").zova_graph_keyed_neighbor_results;
const zova_graph_keyed_node_result = @import("types.zig").zova_graph_keyed_node_result;
const zova_graph_keyed_node_results = @import("types.zig").zova_graph_keyed_node_results;
const zova_graph_list = @import("types.zig").zova_graph_list;
const zova_graph_neighbor_result = @import("types.zig").zova_graph_neighbor_result;
const zova_graph_neighbor_results = @import("types.zig").zova_graph_neighbor_results;
const zova_graph_node = @import("types.zig").zova_graph_node;
const zova_graph_scan_edge = @import("types.zig").zova_graph_scan_edge;
const zova_graph_scan_node = @import("types.zig").zova_graph_scan_node;
const zova_graph_scan_results = @import("types.zig").zova_graph_scan_results;
const zova_graph_target_type = @import("types.zig").zova_graph_target_type;
const zova_graph_walk_result = @import("types.zig").zova_graph_walk_result;
const zova_graph_walk_results = @import("types.zig").zova_graph_walk_results;
const zova_kv_get_many_results = @import("types.zig").zova_kv_get_many_results;
const zova_kv_get_result = @import("types.zig").zova_kv_get_result;
const zova_message = @import("types.zig").zova_message;
const zova_notification = @import("types.zig").zova_notification;
const zova_object_manifest = @import("types.zig").zova_object_manifest;
const zova_text = @import("types.zig").zova_text;
const zova_vector = @import("types.zig").zova_vector;
const zova_vector_collection_info = @import("types.zig").zova_vector_collection_info;
const zova_vector_collection_list = @import("types.zig").zova_vector_collection_list;
const zova_vector_element_type = @import("types.zig").zova_vector_element_type;
const zova_vector_search_result = @import("types.zig").zova_vector_search_result;
const zova_vector_search_results = @import("types.zig").zova_vector_search_results;

pub fn zova_buffer_free(buffer: ?*zova_buffer) callconv(.c) void {
    const out = buffer orelse return;
    if (out.data) |data| {
        allocator.free(data[0..out.len]);
    }
    out.* = .{ .data = null, .len = 0 };
}

pub fn zova_kv_get_result_free(result: ?*zova_kv_get_result) callconv(.c) void {
    const out = result orelse return;
    if (out.value.data) |data| {
        allocator.free(data[0..out.value.len]);
    }
    out.* = .{ .found = 0, .value = .{ .data = null, .len = 0 } };
}

pub fn zova_kv_get_many_results_free(results: ?*zova_kv_get_many_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| {
            if (item.value.data) |data| {
                allocator.free(data[0..item.value.len]);
            }
        }
        allocator.free(items[0..out.len]);
    }
    out.* = .{ .items = null, .len = 0 };
}

pub fn zova_message_free(message: ?*zova_message) callconv(.c) void {
    const out = message orelse return;
    if (out.data) |data| {
        allocator.free(data[0 .. out.len + 1]);
    }
    out.* = .{ .data = null, .len = 0 };
}

pub fn zova_text_free(text: ?*zova_text) callconv(.c) void {
    const out = text orelse return;
    if (out.data) |data| {
        allocator.free(data[0 .. out.len + 1]);
    }
    out.* = emptyText();
}

pub fn zova_notification_free(notification: ?*zova_notification) callconv(.c) void {
    const out = notification orelse return;
    if (out.channel) |channel| {
        allocator.free(channel[0 .. out.channel_len + 1]);
    }
    if (out.payload) |payload| {
        allocator.free(payload[0 .. out.payload_len + 1]);
    }
    out.* = emptyNotification();
}

pub fn zova_object_manifest_free(manifest: ?*zova_object_manifest) callconv(.c) void {
    const out = manifest orelse return;
    if (out.chunker) |chunker| {
        allocator.free(@constCast(chunker[0 .. std.mem.len(chunker) + 1]));
    }
    if (out.chunks) |chunks| {
        allocator.free(chunks[0..out.chunks_len]);
    }
    out.* = emptyManifest();
}

pub fn zova_vector_free(vector: ?*zova_vector) callconv(.c) void {
    const out = vector orelse return;
    if (out.id) |id| {
        allocator.free(id[0 .. out.id_len + 1]);
    }
    if (out.f32_values) |values| {
        allocator.free(values[0..out.values_len]);
    }
    if (out.f16_values) |values| {
        allocator.free(values[0..out.values_len]);
    }
    if (out.i8_values) |values| {
        allocator.free(values[0..out.values_len]);
    }
    out.* = emptyVector();
}

pub fn zova_vector_search_results_free(results: ?*zova_vector_search_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |item| {
            if (item.id) |id| {
                allocator.free(id[0 .. item.id_len + 1]);
            }
        }
        allocator.free(items[0..out.len]);
    }
    out.* = emptyVectorSearchResults();
}

pub fn zova_vector_collection_info_free(info: ?*zova_vector_collection_info) callconv(.c) void {
    const out = info orelse return;
    freeVectorCollectionInfo(out);
    out.* = emptyVectorCollectionInfo();
}

pub fn zova_vector_collection_list_free(list: ?*zova_vector_collection_list) callconv(.c) void {
    const out = list orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeVectorCollectionInfo(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyVectorCollectionList();
}

pub fn zova_graph_info_free(info: ?*zova_graph_info) callconv(.c) void {
    const out = info orelse return;
    freeGraphInfo(out);
    out.* = emptyGraphInfo();
}

pub fn zova_graph_list_free(list: ?*zova_graph_list) callconv(.c) void {
    const out = list orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeGraphInfo(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyGraphList();
}

pub fn zova_extension_info_free(info: ?*zova_extension_info) callconv(.c) void {
    const out = info orelse return;
    freeExtensionInfo(out);
    out.* = emptyExtensionInfo();
}

pub fn zova_extension_list_free(list: ?*zova_extension_list) callconv(.c) void {
    const out = list orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeExtensionInfo(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyExtensionList();
}

pub fn zova_graph_node_free(node: ?*zova_graph_node) callconv(.c) void {
    const out = node orelse return;
    freeGraphNode(out);
    out.* = emptyGraphNode();
}

pub fn zova_graph_edge_free(edge: ?*zova_graph_edge) callconv(.c) void {
    const out = edge orelse return;
    freeGraphEdge(out);
    out.* = emptyGraphEdge();
}

pub fn zova_graph_neighbor_results_free(results: ?*zova_graph_neighbor_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeGraphNeighborResult(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyGraphNeighborResults();
}

pub fn zova_graph_keyed_neighbor_results_free(results: ?*zova_graph_keyed_neighbor_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeGraphKeyedNeighborResult(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyGraphKeyedNeighborResults();
}

pub fn zova_graph_keyed_node_results_free(results: ?*zova_graph_keyed_node_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| {
            if (item.node_id) |value| allocator.free(value[0 .. item.node_id_len + 1]);
            if (item.kind) |value| allocator.free(value[0 .. item.kind_len + 1]);
        }
        allocator.free(items[0..out.len]);
    }
    out.* = .{ .items = null, .len = 0 };
}

pub fn zova_graph_keyed_edge_results_free(results: ?*zova_graph_keyed_edge_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| if (item.edge_type) |value| allocator.free(value[0 .. item.edge_type_len + 1]);
        allocator.free(items[0..out.len]);
    }
    out.* = .{ .items = null, .len = 0 };
}

pub fn zova_graph_edge_payload_results_free(results: ?*zova_graph_edge_payload_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| if (item.payload) |value| allocator.free(value[0..item.payload_len]);
        allocator.free(items[0..out.len]);
    }
    out.* = .{ .items = null, .len = 0 };
}

pub fn zova_graph_scan_results_free(results: ?*zova_graph_scan_results) callconv(.c) void {
    const out = results orelse return;
    if (out.nodes) |nodes| {
        for (nodes[0..out.nodes_len]) |*node| freeGraphScanNode(node);
        allocator.free(nodes[0..out.nodes_len]);
    }
    if (out.edges) |edges| {
        for (edges[0..out.edges_len]) |*edge| freeGraphScanEdge(edge);
        allocator.free(edges[0..out.edges_len]);
    }
    out.* = emptyGraphScanResults();
}

pub fn zova_graph_walk_results_free(results: ?*zova_graph_walk_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeGraphWalkResult(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyGraphWalkResults();
}

pub fn emptyBuffer() zova_buffer {
    return .{ .data = null, .len = 0 };
}

fn emptyText() zova_text {
    return .{ .data = null, .len = 0 };
}

pub fn emptyNotification() zova_notification {
    return .{
        .channel = null,
        .channel_len = 0,
        .payload = null,
        .payload_len = 0,
        .sequence = 0,
        .dropped_before = 0,
    };
}

pub fn emptyManifest() zova_object_manifest {
    return .{
        .object_id = .{ .bytes = [_]u8{0} ** 32 },
        .size_bytes = 0,
        .chunk_count = 0,
        .chunker = null,
        .chunks = null,
        .chunks_len = 0,
    };
}

pub fn emptyVector() zova_vector {
    return .{
        .id = null,
        .id_len = 0,
        .element_type = @intFromEnum(zova_vector_element_type.F32),
        .f32_values = null,
        .f16_values = null,
        .i8_values = null,
        .values_len = 0,
    };
}

pub fn emptyVectorSearchResults() zova_vector_search_results {
    return .{ .items = null, .len = 0 };
}

pub fn emptyVectorCollectionInfo() zova_vector_collection_info {
    return .{
        .name = null,
        .name_len = 0,
        .dimensions = 0,
        .metric = 0,
        .element_type = @intFromEnum(zova_vector_element_type.F32),
        .vector_count = 0,
    };
}

pub fn emptyVectorCollectionList() zova_vector_collection_list {
    return .{ .items = null, .len = 0 };
}

pub fn emptyGraphInfo() zova_graph_info {
    return .{ .name = null, .name_len = 0, .node_count = 0, .edge_count = 0 };
}

pub fn emptyGraphList() zova_graph_list {
    return .{ .items = null, .len = 0 };
}

pub fn emptyExtensionInfo() zova_extension_info {
    return .{
        .name = null,
        .name_len = 0,
        .version = null,
        .version_len = 0,
        .storage_prefix = null,
        .storage_prefix_len = 0,
        .zova_abi_min = null,
        .zova_abi_min_len = 0,
        .capabilities = null,
        .capabilities_len = 0,
        .required = 0,
        .installed_at_unix = 0,
        .manifest_json = null,
        .manifest_json_len = 0,
    };
}

pub fn emptyExtensionList() zova_extension_list {
    return .{ .items = null, .len = 0 };
}

pub fn emptyGraphNode() zova_graph_node {
    return .{
        .graph_name = null,
        .graph_name_len = 0,
        .node_id = null,
        .node_id_len = 0,
        .kind = null,
        .kind_len = 0,
        .target_type = @intFromEnum(zova_graph_target_type.NONE),
        .target_namespace = null,
        .target_namespace_len = 0,
        .has_target_namespace = 0,
        .target_ref = null,
        .target_ref_len = 0,
        .has_target_ref = 0,
    };
}

pub fn emptyGraphEdge() zova_graph_edge {
    return .{
        .graph_name = null,
        .graph_name_len = 0,
        .from_node_id = null,
        .from_node_id_len = 0,
        .edge_type = null,
        .edge_type_len = 0,
        .to_node_id = null,
        .to_node_id_len = 0,
    };
}

pub fn emptyGraphNeighborResults() zova_graph_neighbor_results {
    return .{ .items = null, .len = 0 };
}

pub fn emptyGraphKeyedNeighborResults() zova_graph_keyed_neighbor_results {
    return .{ .items = null, .len = 0 };
}

pub fn emptyGraphScanResults() zova_graph_scan_results {
    return .{
        .nodes = null,
        .nodes_len = 0,
        .edges = null,
        .edges_len = 0,
        .has_more_nodes = 0,
        .has_more_edges = 0,
    };
}

pub fn emptyGraphWalkResults() zova_graph_walk_results {
    return .{ .items = null, .len = 0 };
}

fn freeVectorCollectionInfo(info: *zova_vector_collection_info) void {
    if (info.name) |name| allocator.free(name[0 .. info.name_len + 1]);
}

fn freeGraphInfo(info: *zova_graph_info) void {
    if (info.name) |name| allocator.free(name[0 .. info.name_len + 1]);
}

fn freeExtensionInfo(info: *zova_extension_info) void {
    if (info.name) |value| allocator.free(value[0 .. info.name_len + 1]);
    if (info.version) |value| allocator.free(value[0 .. info.version_len + 1]);
    if (info.storage_prefix) |value| allocator.free(value[0 .. info.storage_prefix_len + 1]);
    if (info.zova_abi_min) |value| allocator.free(value[0 .. info.zova_abi_min_len + 1]);
    if (info.capabilities) |value| allocator.free(value[0 .. info.capabilities_len + 1]);
    if (info.manifest_json) |value| allocator.free(value[0 .. info.manifest_json_len + 1]);
}

fn freeGraphNode(node: *zova_graph_node) void {
    if (node.graph_name) |value| allocator.free(value[0 .. node.graph_name_len + 1]);
    if (node.node_id) |value| allocator.free(value[0 .. node.node_id_len + 1]);
    if (node.kind) |value| allocator.free(value[0 .. node.kind_len + 1]);
    if (node.target_namespace) |value| allocator.free(value[0 .. node.target_namespace_len + 1]);
    if (node.target_ref) |value| allocator.free(value[0 .. node.target_ref_len + 1]);
}

fn freeGraphEdge(edge: *zova_graph_edge) void {
    if (edge.graph_name) |value| allocator.free(value[0 .. edge.graph_name_len + 1]);
    if (edge.from_node_id) |value| allocator.free(value[0 .. edge.from_node_id_len + 1]);
    if (edge.edge_type) |value| allocator.free(value[0 .. edge.edge_type_len + 1]);
    if (edge.to_node_id) |value| allocator.free(value[0 .. edge.to_node_id_len + 1]);
}

fn freeGraphNeighborResult(result: *zova_graph_neighbor_result) void {
    if (result.node_id) |value| allocator.free(value[0 .. result.node_id_len + 1]);
    if (result.kind) |value| allocator.free(value[0 .. result.kind_len + 1]);
    if (result.edge_type) |value| allocator.free(value[0 .. result.edge_type_len + 1]);
}

fn freeGraphKeyedNeighborResult(result: *zova_graph_keyed_neighbor_result) void {
    if (result.node_id) |value| allocator.free(value[0 .. result.node_id_len + 1]);
    if (result.kind) |value| allocator.free(value[0 .. result.kind_len + 1]);
    if (result.edge_type) |value| allocator.free(value[0 .. result.edge_type_len + 1]);
}

fn freeGraphScanNode(node: *zova_graph_scan_node) void {
    if (node.node_id) |value| allocator.free(value[0 .. node.node_id_len + 1]);
    if (node.kind) |value| allocator.free(value[0 .. node.kind_len + 1]);
}

fn freeGraphScanEdge(edge: *zova_graph_scan_edge) void {
    if (edge.edge_type) |value| allocator.free(value[0 .. edge.edge_type_len + 1]);
}

fn freeGraphWalkResult(result: *zova_graph_walk_result) void {
    if (result.node_id) |value| allocator.free(value[0 .. result.node_id_len + 1]);
    if (result.kind) |value| allocator.free(value[0 .. result.kind_len + 1]);
    if (result.predecessor_node_id) |value| allocator.free(value[0 .. result.predecessor_node_id_len + 1]);
    if (result.edge_type) |value| allocator.free(value[0 .. result.edge_type_len + 1]);
}

pub fn fillSearchResults(out: *zova_vector_search_results, items: []const zova.VectorSearchResult) error{OutOfMemory}!void {
    out.* = emptyVectorSearchResults();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_vector_search_result, items.len);
    errdefer {
        for (abi_items[0..items.len]) |item| {
            if (item.id) |id| allocator.free(id[0 .. item.id_len + 1]);
        }
        allocator.free(abi_items);
    }

    for (abi_items) |*item| item.* = .{ .id = null, .id_len = 0, .distance = 0 };
    for (items, abi_items) |item, *abi_item| {
        const id = try allocator.dupeZ(u8, item.id);
        abi_item.* = .{
            .id = id.ptr,
            .id_len = id.len,
            .distance = item.distance,
        };
    }

    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

pub fn fillVector(out: *zova_vector, vector: *zova.Vector) error{OutOfMemory}!void {
    out.* = emptyVector();
    const id = try allocator.dupeZ(u8, vector.id);
    errdefer allocator.free(id);

    out.id = id.ptr;
    out.id_len = id.len;
    allocator.free(vector.id);
    vector.id = &.{};

    switch (vector.values) {
        .f32 => |values| {
            out.element_type = vectorElementTypeToAbi(.f32);
            out.f32_values = if (values.len == 0) null else values.ptr;
            out.values_len = values.len;
        },
        .f16 => |values| {
            out.element_type = vectorElementTypeToAbi(.f16);
            out.f16_values = if (values.len == 0) null else values.ptr;
            out.values_len = values.len;
        },
        .i8 => |values| {
            out.element_type = vectorElementTypeToAbi(.i8);
            out.i8_values = if (values.len == 0) null else values.ptr;
            out.values_len = values.len;
        },
    }
}

pub fn fillGraphInfo(out: *zova_graph_info, info: zova.GraphInfo) error{OutOfMemory}!void {
    out.* = emptyGraphInfo();
    const name = try allocator.dupeZ(u8, info.name);
    out.* = .{
        .name = name.ptr,
        .name_len = name.len,
        .node_count = info.node_count,
        .edge_count = info.edge_count,
    };
}

pub fn fillGraphList(out: *zova_graph_list, items: []const zova.GraphInfo) error{OutOfMemory}!void {
    out.* = emptyGraphList();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_graph_info, items.len);
    errdefer {
        for (abi_items[0..items.len]) |*item| freeGraphInfo(item);
        allocator.free(abi_items);
    }

    for (abi_items) |*item| item.* = emptyGraphInfo();
    for (items, abi_items) |item, *abi_item| try fillGraphInfo(abi_item, item);
    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

pub fn fillExtensionInfo(out: *zova_extension_info, info: zova.ExtensionInfo) error{OutOfMemory}!void {
    out.* = emptyExtensionInfo();
    const name = try allocator.dupeZ(u8, info.name);
    errdefer allocator.free(name);
    const version = try allocator.dupeZ(u8, info.version);
    errdefer allocator.free(version);
    const storage_prefix = try allocator.dupeZ(u8, info.storage_prefix);
    errdefer allocator.free(storage_prefix);
    const zova_abi_min = try allocator.dupeZ(u8, info.zova_abi_min);
    errdefer allocator.free(zova_abi_min);
    const capabilities = try allocator.dupeZ(u8, info.capabilities);
    errdefer allocator.free(capabilities);
    const manifest_json = try allocator.dupeZ(u8, info.manifest_json);
    errdefer allocator.free(manifest_json);

    out.* = .{
        .name = name.ptr,
        .name_len = name.len,
        .version = version.ptr,
        .version_len = version.len,
        .storage_prefix = storage_prefix.ptr,
        .storage_prefix_len = storage_prefix.len,
        .zova_abi_min = zova_abi_min.ptr,
        .zova_abi_min_len = zova_abi_min.len,
        .capabilities = capabilities.ptr,
        .capabilities_len = capabilities.len,
        .required = if (info.required) 1 else 0,
        .installed_at_unix = info.installed_at_unix,
        .manifest_json = manifest_json.ptr,
        .manifest_json_len = manifest_json.len,
    };
}

pub fn fillExtensionList(out: *zova_extension_list, items: []const zova.ExtensionInfo) error{OutOfMemory}!void {
    out.* = emptyExtensionList();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_extension_info, items.len);
    errdefer {
        for (abi_items[0..items.len]) |*item| freeExtensionInfo(item);
        allocator.free(abi_items);
    }

    for (abi_items) |*item| item.* = emptyExtensionInfo();
    for (items, abi_items) |item, *abi_item| try fillExtensionInfo(abi_item, item);
    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

pub fn fillGraphNode(out: *zova_graph_node, node: zova.GraphNode) error{OutOfMemory}!void {
    out.* = emptyGraphNode();
    const graph_name = try allocator.dupeZ(u8, node.graph_name);
    errdefer allocator.free(graph_name);
    const node_id = try allocator.dupeZ(u8, node.node_id);
    errdefer allocator.free(node_id);
    const kind = try allocator.dupeZ(u8, node.kind);
    errdefer allocator.free(kind);
    const target_namespace = if (node.target_namespace) |value| try allocator.dupeZ(u8, value) else null;
    errdefer if (target_namespace) |value| allocator.free(value);
    const target_ref = if (node.target_ref) |value| try allocator.dupeZ(u8, value) else null;
    errdefer if (target_ref) |value| allocator.free(value);

    out.* = .{
        .graph_name = graph_name.ptr,
        .graph_name_len = graph_name.len,
        .node_id = node_id.ptr,
        .node_id_len = node_id.len,
        .kind = kind.ptr,
        .kind_len = kind.len,
        .target_type = graphTargetTypeToAbi(node.target_type),
        .target_namespace = if (target_namespace) |value| value.ptr else null,
        .target_namespace_len = if (target_namespace) |value| value.len else 0,
        .has_target_namespace = if (target_namespace != null) 1 else 0,
        .target_ref = if (target_ref) |value| value.ptr else null,
        .target_ref_len = if (target_ref) |value| value.len else 0,
        .has_target_ref = if (target_ref != null) 1 else 0,
    };
}

pub fn fillGraphEdge(out: *zova_graph_edge, edge: zova.GraphEdge) error{OutOfMemory}!void {
    out.* = emptyGraphEdge();
    const graph_name = try allocator.dupeZ(u8, edge.graph_name);
    errdefer allocator.free(graph_name);
    const from_node_id = try allocator.dupeZ(u8, edge.from_node_id);
    errdefer allocator.free(from_node_id);
    const edge_type = try allocator.dupeZ(u8, edge.edge_type);
    errdefer allocator.free(edge_type);
    const to_node_id = try allocator.dupeZ(u8, edge.to_node_id);
    errdefer allocator.free(to_node_id);

    out.* = .{
        .graph_name = graph_name.ptr,
        .graph_name_len = graph_name.len,
        .from_node_id = from_node_id.ptr,
        .from_node_id_len = from_node_id.len,
        .edge_type = edge_type.ptr,
        .edge_type_len = edge_type.len,
        .to_node_id = to_node_id.ptr,
        .to_node_id_len = to_node_id.len,
    };
}

pub fn fillGraphNeighborResults(out: *zova_graph_neighbor_results, items: []const zova.GraphNeighbor) error{OutOfMemory}!void {
    out.* = emptyGraphNeighborResults();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_graph_neighbor_result, items.len);
    errdefer {
        for (abi_items[0..items.len]) |*item| freeGraphNeighborResult(item);
        allocator.free(abi_items);
    }

    for (abi_items) |*item| item.* = .{ .node_id = null, .node_id_len = 0, .kind = null, .kind_len = 0, .edge_type = null, .edge_type_len = 0 };
    for (items, abi_items) |item, *abi_item| {
        const node_id = try allocator.dupeZ(u8, item.node_id);
        errdefer allocator.free(node_id);
        const kind = try allocator.dupeZ(u8, item.kind);
        errdefer allocator.free(kind);
        const edge_type = try allocator.dupeZ(u8, item.edge_type);
        abi_item.* = .{
            .node_id = node_id.ptr,
            .node_id_len = node_id.len,
            .kind = kind.ptr,
            .kind_len = kind.len,
            .edge_type = edge_type.ptr,
            .edge_type_len = edge_type.len,
        };
    }

    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

pub fn fillGraphKeyedNeighborResults(
    out: *zova_graph_keyed_neighbor_results,
    items: []const zova.GraphKeyedNeighbor,
) error{OutOfMemory}!void {
    out.* = emptyGraphKeyedNeighborResults();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_graph_keyed_neighbor_result, items.len);
    errdefer {
        for (abi_items) |*item| freeGraphKeyedNeighborResult(item);
        allocator.free(abi_items);
    }
    for (abi_items) |*item| item.* = .{
        .edge_key = 0,
        .neighbor_node_key = 0,
        .node_id = null,
        .node_id_len = 0,
        .kind = null,
        .kind_len = 0,
        .edge_type = null,
        .edge_type_len = 0,
    };
    for (items, abi_items) |item, *abi_item| {
        const node_id = try allocator.dupeZ(u8, item.node_id);
        errdefer allocator.free(node_id);
        const kind = try allocator.dupeZ(u8, item.kind);
        errdefer allocator.free(kind);
        const edge_type = try allocator.dupeZ(u8, item.edge_type);
        abi_item.* = .{
            .edge_key = item.edge_key,
            .neighbor_node_key = item.neighbor_node_key,
            .node_id = node_id.ptr,
            .node_id_len = node_id.len,
            .kind = kind.ptr,
            .kind_len = kind.len,
            .edge_type = edge_type.ptr,
            .edge_type_len = edge_type.len,
        };
    }
    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

pub fn fillGraphKeyedNodeResults(out: *zova_graph_keyed_node_results, items: []const zova.GraphKeyedNodeLookup) error{OutOfMemory}!void {
    out.* = .{ .items = null, .len = 0 };
    if (items.len == 0) return;
    const abi_items = try allocator.alloc(zova_graph_keyed_node_result, items.len);
    errdefer {
        var tmp = zova_graph_keyed_node_results{ .items = abi_items.ptr, .len = abi_items.len };
        zova_graph_keyed_node_results_free(&tmp);
    }
    for (abi_items) |*item| item.* = .{ .found = 0, .node_key = 0, .node_id = null, .node_id_len = 0, .kind = null, .kind_len = 0, .created_order = 0 };
    for (items, abi_items) |item, *abi_item| {
        abi_item.node_key = item.node_key;
        if (!item.found) continue;
        const node_id = try allocator.dupeZ(u8, item.node_id.?);
        errdefer allocator.free(node_id);
        const kind = try allocator.dupeZ(u8, item.kind.?);
        abi_item.* = .{ .found = 1, .node_key = item.node_key, .node_id = node_id.ptr, .node_id_len = node_id.len, .kind = kind.ptr, .kind_len = kind.len, .created_order = item.created_order };
    }
    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

pub fn fillGraphKeyedEdgeResults(out: *zova_graph_keyed_edge_results, items: []const zova.GraphKeyedEdgeLookup) error{OutOfMemory}!void {
    out.* = .{ .items = null, .len = 0 };
    if (items.len == 0) return;
    const abi_items = try allocator.alloc(zova_graph_keyed_edge_result, items.len);
    errdefer {
        var tmp = zova_graph_keyed_edge_results{ .items = abi_items.ptr, .len = abi_items.len };
        zova_graph_keyed_edge_results_free(&tmp);
    }
    for (abi_items) |*item| item.* = .{ .found = 0, .edge_key = 0, .source_node_key = 0, .edge_type = null, .edge_type_len = 0, .target_node_key = 0, .created_order = 0 };
    for (items, abi_items) |item, *abi_item| {
        abi_item.edge_key = item.edge_key;
        if (!item.found) continue;
        const edge_type = try allocator.dupeZ(u8, item.edge_type.?);
        abi_item.* = .{ .found = 1, .edge_key = item.edge_key, .source_node_key = item.source_node_key, .edge_type = edge_type.ptr, .edge_type_len = edge_type.len, .target_node_key = item.target_node_key, .created_order = item.created_order };
    }
    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

pub fn fillGraphEdgePayloadResults(out: *zova_graph_edge_payload_results, items: []const zova.GraphEdgePayloadLookup) error{OutOfMemory}!void {
    out.* = .{ .items = null, .len = 0 };
    if (items.len == 0) return;
    const abi_items = try allocator.alloc(zova_graph_edge_payload_result, items.len);
    errdefer {
        var tmp = zova_graph_edge_payload_results{ .items = abi_items.ptr, .len = abi_items.len };
        zova_graph_edge_payload_results_free(&tmp);
    }
    for (abi_items) |*item| item.* = .{ .found = 0, .edge_key = 0, .payload = null, .payload_len = 0 };
    for (items, abi_items) |item, *abi_item| {
        abi_item.edge_key = item.edge_key;
        if (!item.found) continue;
        const payload = item.payload.?;
        const copied = if (payload.len == 0) null else (try allocator.dupe(u8, payload)).ptr;
        abi_item.* = .{ .found = 1, .edge_key = item.edge_key, .payload = copied, .payload_len = payload.len };
    }
    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

pub fn fillGraphScanResults(out: *zova_graph_scan_results, result: zova.GraphScanResult) error{OutOfMemory}!void {
    out.* = emptyGraphScanResults();
    const nodes = try allocator.alloc(zova_graph_scan_node, result.nodes.len);
    errdefer {
        for (nodes) |*node| freeGraphScanNode(node);
        allocator.free(nodes);
    }
    for (nodes) |*node| node.* = .{
        .node_key = 0,
        .node_id = null,
        .node_id_len = 0,
        .kind = null,
        .kind_len = 0,
        .created_order = 0,
    };
    for (result.nodes, nodes) |source, *node| {
        const node_id = try allocator.dupeZ(u8, source.node_id);
        errdefer allocator.free(node_id);
        const kind = try allocator.dupeZ(u8, source.kind);
        node.* = .{
            .node_key = source.node_key,
            .node_id = node_id.ptr,
            .node_id_len = node_id.len,
            .kind = kind.ptr,
            .kind_len = kind.len,
            .created_order = source.created_order,
        };
    }

    const edges = try allocator.alloc(zova_graph_scan_edge, result.edges.len);
    errdefer {
        for (edges) |*edge| freeGraphScanEdge(edge);
        allocator.free(edges);
    }
    for (edges) |*edge| edge.* = .{
        .edge_key = 0,
        .source_node_key = 0,
        .edge_type = null,
        .edge_type_len = 0,
        .target_node_key = 0,
        .created_order = 0,
    };
    for (result.edges, edges) |source, *edge| {
        const edge_type = try allocator.dupeZ(u8, source.edge_type);
        edge.* = .{
            .edge_key = source.edge_key,
            .source_node_key = source.source_node_key,
            .edge_type = edge_type.ptr,
            .edge_type_len = edge_type.len,
            .target_node_key = source.target_node_key,
            .created_order = source.created_order,
        };
    }

    out.* = .{
        .nodes = if (nodes.len == 0) null else nodes.ptr,
        .nodes_len = nodes.len,
        .edges = if (edges.len == 0) null else edges.ptr,
        .edges_len = edges.len,
        .has_more_nodes = if (result.has_more_nodes) 1 else 0,
        .has_more_edges = if (result.has_more_edges) 1 else 0,
    };
}

pub fn fillGraphWalkResults(out: *zova_graph_walk_results, items: []const zova.GraphWalkItem) error{OutOfMemory}!void {
    out.* = emptyGraphWalkResults();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_graph_walk_result, items.len);
    errdefer {
        for (abi_items[0..items.len]) |*item| freeGraphWalkResult(item);
        allocator.free(abi_items);
    }

    for (abi_items) |*item| {
        item.* = .{
            .node_id = null,
            .node_id_len = 0,
            .kind = null,
            .kind_len = 0,
            .depth = 0,
            .predecessor_node_id = null,
            .predecessor_node_id_len = 0,
            .has_predecessor_node_id = 0,
            .edge_type = null,
            .edge_type_len = 0,
            .has_edge_type = 0,
        };
    }

    for (items, abi_items) |item, *abi_item| {
        const node_id = try allocator.dupeZ(u8, item.node_id);
        errdefer allocator.free(node_id);
        const kind = try allocator.dupeZ(u8, item.kind);
        errdefer allocator.free(kind);
        const predecessor = if (item.predecessor_node_id) |value| try allocator.dupeZ(u8, value) else null;
        errdefer if (predecessor) |value| allocator.free(value);
        const edge_type = if (item.edge_type) |value| try allocator.dupeZ(u8, value) else null;

        abi_item.* = .{
            .node_id = node_id.ptr,
            .node_id_len = node_id.len,
            .kind = kind.ptr,
            .kind_len = kind.len,
            .depth = item.depth,
            .predecessor_node_id = if (predecessor) |value| value.ptr else null,
            .predecessor_node_id_len = if (predecessor) |value| value.len else 0,
            .has_predecessor_node_id = if (predecessor != null) 1 else 0,
            .edge_type = if (edge_type) |value| value.ptr else null,
            .edge_type_len = if (edge_type) |value| value.len else 0,
            .has_edge_type = if (edge_type != null) 1 else 0,
        };
    }

    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

pub fn fillVectorCollectionInfo(out: *zova_vector_collection_info, info: zova.VectorCollectionInfo) error{OutOfMemory}!void {
    out.* = emptyVectorCollectionInfo();
    const name = try allocator.dupeZ(u8, info.name);
    out.* = .{
        .name = name.ptr,
        .name_len = name.len,
        .dimensions = info.dimensions,
        .metric = vectorMetricToAbi(info.metric),
        .element_type = vectorElementTypeToAbi(info.element_type),
        .vector_count = info.vector_count,
    };
}

pub fn fillVectorCollectionList(out: *zova_vector_collection_list, items: []const zova.VectorCollectionInfo) error{OutOfMemory}!void {
    out.* = emptyVectorCollectionList();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_vector_collection_info, items.len);
    errdefer {
        for (abi_items[0..items.len]) |*item| freeVectorCollectionInfo(item);
        allocator.free(abi_items);
    }

    for (abi_items) |*item| item.* = emptyVectorCollectionInfo();
    for (items, abi_items) |item, *abi_item| {
        try fillVectorCollectionInfo(abi_item, item);
    }

    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

pub fn fillNotification(out: *zova_notification, notification: zova.Notification) error{OutOfMemory}!void {
    const channel = try allocator.alloc(u8, notification.channel.len + 1);
    errdefer allocator.free(channel);
    @memcpy(channel[0..notification.channel.len], notification.channel);
    channel[notification.channel.len] = 0;

    const payload = try allocator.alloc(u8, notification.payload.len + 1);
    errdefer allocator.free(payload);
    @memcpy(payload[0..notification.payload.len], notification.payload);
    payload[notification.payload.len] = 0;

    out.* = .{
        .channel = channel.ptr,
        .channel_len = notification.channel.len,
        .payload = payload.ptr,
        .payload_len = notification.payload.len,
        .sequence = notification.sequence,
        .dropped_before = notification.dropped_before,
    };
}
