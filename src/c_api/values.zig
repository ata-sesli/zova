//! Borrowed C input decoding and ABI value conversion.

const std = @import("std");
const zova = @import("../zova.zig");
const sqlite = @import("../sqlite.zig");
const kv_impl = @import("../kv.zig");

const zova_column_type = @import("types.zig").zova_column_type;
const zova_graph_edge_input = @import("types.zig").zova_graph_edge_input;
const zova_graph_edge_payload_replacement = @import("types.zig").zova_graph_edge_payload_replacement;
const zova_graph_fresh_edge_input = @import("types.zig").zova_graph_fresh_edge_input;
const zova_graph_fresh_edge_payload_input = @import("types.zig").zova_graph_fresh_edge_payload_input;
const zova_graph_fresh_node_input = @import("types.zig").zova_graph_fresh_node_input;
const zova_graph_neighbor_direction = @import("types.zig").zova_graph_neighbor_direction;
const zova_graph_node_input = @import("types.zig").zova_graph_node_input;
const zova_graph_target_type = @import("types.zig").zova_graph_target_type;
const zova_kv_bytes = @import("types.zig").zova_kv_bytes;
const zova_kv_put_entry = @import("types.zig").zova_kv_put_entry;
const zova_object_chunk_id = @import("types.zig").zova_object_chunk_id;
const zova_object_id = @import("types.zig").zova_object_id;
const zova_object_manifest_chunk = @import("types.zig").zova_object_manifest_chunk;
const zova_object_put_options = @import("types.zig").zova_object_put_options;
const zova_object_storage_profile = @import("types.zig").zova_object_storage_profile;
const zova_vector_element_type = @import("types.zig").zova_vector_element_type;
const zova_vector_input = @import("types.zig").zova_vector_input;
const zova_vector_metric = @import("types.zig").zova_vector_metric;
const zova_vector_multi_i8_aggregation = @import("types.zig").zova_vector_multi_i8_aggregation;
const zova_vector_multi_i8_search_mode = @import("types.zig").zova_vector_multi_i8_search_mode;
const zova_vector_values = @import("types.zig").zova_vector_values;

pub const allocator = std.heap.c_allocator;

pub fn bytesConst(data: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

pub fn bytesMut(data: ?[*]u8, len: usize) ?[]u8 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

pub fn manifestChunks(chunks: ?[*]const zova_object_manifest_chunk, len: usize) ?[]const zova_object_manifest_chunk {
    if (len == 0) return &.{};
    const ptr = chunks orelse return null;
    return ptr[0..len];
}

fn floatsConst(data: ?[*]const f32, len: usize) ?[]const f32 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

fn u16Const(data: ?[*]const u16, len: usize) ?[]const u16 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

fn i8Const(data: ?[*]const i8, len: usize) ?[]const i8 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

pub fn candidateIdSlices(
    candidate_ids: ?[*]const ?[*:0]const u8,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const []const u8) {
    if (len == 0) return &.{};
    const ptr = candidate_ids orelse return error.InvalidArgument;
    const candidates = try allocator.alloc([]const u8, len);
    errdefer allocator.free(candidates);
    for (ptr[0..len], candidates) |candidate, *out| {
        const id = candidate orelse return error.InvalidArgument;
        out.* = std.mem.span(id);
    }
    return candidates;
}

pub fn kvKeySlices(keys: ?[*]const zova_kv_bytes, len: usize) (error{ OutOfMemory, InvalidArgument }![]const []const u8) {
    if (len == 0) return &.{};
    const ptr = keys orelse return error.InvalidArgument;
    const result = try allocator.alloc([]const u8, len);
    errdefer allocator.free(result);
    for (ptr[0..len], result) |key, *out| {
        const bytes = bytesConst(key.data, key.len) orelse return error.InvalidArgument;
        out.* = bytes;
    }
    return result;
}

pub fn kvPutEntrySlices(entries: ?[*]const zova_kv_put_entry, len: usize) (error{ OutOfMemory, InvalidArgument }![]const kv_impl.PutEntry) {
    if (len == 0) return &.{};
    const ptr = entries orelse return error.InvalidArgument;
    const result = try allocator.alloc(kv_impl.PutEntry, len);
    errdefer allocator.free(result);
    for (ptr[0..len], result) |entry, *out| {
        const key = bytesConst(entry.key.data, entry.key.len) orelse return error.InvalidArgument;
        const value = bytesConst(entry.value.data, entry.value.len) orelse return error.InvalidArgument;
        out.* = .{ .key = key, .value = value };
    }
    return result;
}

pub fn graphNodeInputSlices(
    inputs: ?[*]const zova_graph_node_input,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const zova.GraphNodeInput) {
    if (len == 0) return &.{};
    const ptr = inputs orelse return error.InvalidArgument;
    const result = try allocator.alloc(zova.GraphNodeInput, len);
    errdefer allocator.free(result);
    for (ptr[0..len], result) |input, *out| {
        const graph_name = input.graph_name orelse return error.InvalidArgument;
        const node_id = input.node_id orelse return error.InvalidArgument;
        const kind = input.kind orelse return error.InvalidArgument;
        const target_type = graphTargetTypeFromAbi(input.target_type) orelse return error.InvalidArgument;
        out.* = .{
            .graph_name = std.mem.span(graph_name),
            .node_id = std.mem.span(node_id),
            .kind = std.mem.span(kind),
            .target_type = target_type,
            .target_namespace = optionalCStringSpan(input.target_namespace),
            .target_ref = optionalCStringSpan(input.target_ref),
        };
    }
    return result;
}

pub fn freshGraphNodeInputSlices(
    inputs: ?[*]const zova_graph_fresh_node_input,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const zova.FreshGraphNodeInput) {
    if (len == 0) return &.{};
    const ptr = inputs orelse return error.InvalidArgument;
    const result = try allocator.alloc(zova.FreshGraphNodeInput, len);
    errdefer allocator.free(result);
    for (ptr[0..len], result) |input, *out| {
        const node_id = input.node_id orelse return error.InvalidArgument;
        const kind = input.kind orelse return error.InvalidArgument;
        const target_type = graphTargetTypeFromAbi(input.target_type) orelse return error.InvalidArgument;
        out.* = .{
            .node_id = std.mem.span(node_id),
            .kind = std.mem.span(kind),
            .target_type = target_type,
            .target_namespace = optionalCStringSpan(input.target_namespace),
            .target_ref = optionalCStringSpan(input.target_ref),
        };
    }
    return result;
}

pub fn freshGraphEdgeInputSlices(
    inputs: ?[*]const zova_graph_fresh_edge_input,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const zova.FreshGraphEdgeInput) {
    if (len == 0) return &.{};
    const ptr = inputs orelse return error.InvalidArgument;
    const result = try allocator.alloc(zova.FreshGraphEdgeInput, len);
    errdefer allocator.free(result);
    for (ptr[0..len], result) |input, *out| {
        const edge_type = input.edge_type orelse return error.InvalidArgument;
        out.* = .{
            .from_node_ordinal = input.from_node_ordinal,
            .edge_type = std.mem.span(edge_type),
            .to_node_ordinal = input.to_node_ordinal,
        };
    }
    return result;
}

pub fn freshGraphEdgePayloadInputSlices(
    inputs: ?[*]const zova_graph_fresh_edge_payload_input,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const zova.FreshGraphEdgeInput) {
    if (len == 0) return &.{};
    const ptr = inputs orelse return error.InvalidArgument;
    const result = try allocator.alloc(zova.FreshGraphEdgeInput, len);
    errdefer allocator.free(result);
    for (ptr[0..len], result) |input, *out| {
        const edge_type = input.edge_type orelse return error.InvalidArgument;
        if (input.payload_len != 0 and input.payload == null) return error.InvalidArgument;
        out.* = .{
            .from_node_ordinal = input.from_node_ordinal,
            .edge_type = std.mem.span(edge_type),
            .to_node_ordinal = input.to_node_ordinal,
            .payload = if (input.payload_len == 0) &.{} else input.payload.?[0..input.payload_len],
        };
    }
    return result;
}

pub fn graphEdgePayloadReplacementSlices(
    inputs: ?[*]const zova_graph_edge_payload_replacement,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const zova.GraphEdgePayloadReplacement) {
    if (len == 0) return &.{};
    const ptr = inputs orelse return error.InvalidArgument;
    const result = try allocator.alloc(zova.GraphEdgePayloadReplacement, len);
    errdefer allocator.free(result);
    for (ptr[0..len], result) |input, *out| {
        if (input.edge_key <= 0 or (input.payload_len != 0 and input.payload == null)) return error.InvalidArgument;
        out.* = .{
            .edge_key = input.edge_key,
            .payload = if (input.payload_len == 0) &.{} else input.payload.?[0..input.payload_len],
        };
    }
    return result;
}

pub fn graphEdgeInputSlices(
    inputs: ?[*]const zova_graph_edge_input,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const zova.GraphEdgeInput) {
    if (len == 0) return &.{};
    const ptr = inputs orelse return error.InvalidArgument;
    const result = try allocator.alloc(zova.GraphEdgeInput, len);
    errdefer allocator.free(result);
    for (ptr[0..len], result) |input, *out| {
        const graph_name = input.graph_name orelse return error.InvalidArgument;
        const from_node_id = input.from_node_id orelse return error.InvalidArgument;
        const edge_type = input.edge_type orelse return error.InvalidArgument;
        const to_node_id = input.to_node_id orelse return error.InvalidArgument;
        out.* = .{
            .graph_name = std.mem.span(graph_name),
            .from_node_id = std.mem.span(from_node_id),
            .edge_type = std.mem.span(edge_type),
            .to_node_id = std.mem.span(to_node_id),
        };
    }
    return result;
}

pub fn multiI8QuerySlices(
    query_values: ?[*]const i8,
    query_values_len: usize,
    query_count: usize,
    dimensions: usize,
) (error{ OutOfMemory, InvalidArgument }![]const []const i8) {
    if (query_count == 0 or dimensions == 0) return error.InvalidArgument;
    const expected_len = std.math.mul(usize, query_count, dimensions) catch return error.InvalidArgument;
    if (query_values_len != expected_len) return error.InvalidArgument;
    const values = (query_values orelse return error.InvalidArgument)[0..query_values_len];
    const queries = try allocator.alloc([]const i8, query_count);
    errdefer allocator.free(queries);
    for (queries, 0..) |*query, index| {
        const start = index * dimensions;
        query.* = values[start .. start + dimensions];
    }
    return queries;
}

pub fn vectorInputSlices(
    vector_inputs: ?[*]const zova_vector_input,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const zova.VectorInput) {
    if (len == 0) return &.{};
    const ptr = vector_inputs orelse return error.InvalidArgument;
    const inputs = try allocator.alloc(zova.VectorInput, len);
    errdefer allocator.free(inputs);

    for (ptr[0..len], inputs) |input, *out| {
        const id = input.id orelse return error.InvalidArgument;
        const values = vectorValuesConst(input.values) orelse return error.InvalidArgument;
        out.* = .{ .id = std.mem.span(id), .values = values };
    }

    return inputs;
}

pub fn vectorMetricFromAbi(metric: c_int) ?zova.VectorMetric {
    return switch (metric) {
        @intFromEnum(zova_vector_metric.COSINE) => .cosine,
        @intFromEnum(zova_vector_metric.L2) => .l2,
        @intFromEnum(zova_vector_metric.DOT) => .dot,
        else => null,
    };
}

pub fn multiI8SearchModeFromAbi(mode: c_int) ?zova.MultiI8CosineSearchMode {
    return switch (mode) {
        @intFromEnum(zova_vector_multi_i8_search_mode.GLOBAL_MIN_COSINE) => .global_min_cosine,
        @intFromEnum(zova_vector_multi_i8_search_mode.CBM_PREFILTER_MIN_COSINE) => .cbm_prefilter_min_cosine,
        else => null,
    };
}

pub fn multiI8AggregationFromAbi(aggregation: c_int) ?void {
    return switch (aggregation) {
        @intFromEnum(zova_vector_multi_i8_aggregation.MIN_COSINE) => {},
        else => null,
    };
}

pub fn vectorMetricToAbi(metric: zova.VectorMetric) c_int {
    return switch (metric) {
        .cosine => @intFromEnum(zova_vector_metric.COSINE),
        .l2 => @intFromEnum(zova_vector_metric.L2),
        .dot => @intFromEnum(zova_vector_metric.DOT),
    };
}

pub fn vectorElementTypeFromAbi(element_type: c_int) ?zova.VectorElementType {
    return switch (element_type) {
        @intFromEnum(zova_vector_element_type.F32) => .f32,
        @intFromEnum(zova_vector_element_type.F16) => .f16,
        @intFromEnum(zova_vector_element_type.I8) => .i8,
        else => null,
    };
}

pub fn vectorElementTypeToAbi(element_type: zova.VectorElementType) c_int {
    return switch (element_type) {
        .f32 => @intFromEnum(zova_vector_element_type.F32),
        .f16 => @intFromEnum(zova_vector_element_type.F16),
        .i8 => @intFromEnum(zova_vector_element_type.I8),
    };
}

pub fn vectorValuesConst(values: zova_vector_values) ?zova.VectorValuesConst {
    const element_type = vectorElementTypeFromAbi(values.element_type) orelse return null;
    return switch (element_type) {
        .f32 => .{ .f32 = floatsConst(values.f32_values, values.values_len) orelse return null },
        .f16 => .{ .f16 = u16Const(values.f16_values, values.values_len) orelse return null },
        .i8 => .{ .i8 = i8Const(values.i8_values, values.values_len) orelse return null },
    };
}

pub fn f32AbiValues(values: []const f32) zova_vector_values {
    return .{
        .element_type = @intFromEnum(zova_vector_element_type.F32),
        .f32_values = if (values.len == 0) null else values.ptr,
        .f16_values = null,
        .i8_values = null,
        .values_len = values.len,
    };
}

pub fn i8AbiValues(values: []const i8) zova_vector_values {
    return .{
        .element_type = @intFromEnum(zova_vector_element_type.I8),
        .f32_values = null,
        .f16_values = null,
        .i8_values = if (values.len == 0) null else values.ptr,
        .values_len = values.len,
    };
}

pub fn graphTargetTypeFromAbi(target_type: c_int) ?zova.GraphTargetType {
    return switch (target_type) {
        @intFromEnum(zova_graph_target_type.NONE) => .none,
        @intFromEnum(zova_graph_target_type.RECORD) => .record,
        @intFromEnum(zova_graph_target_type.OBJECT) => .object,
        @intFromEnum(zova_graph_target_type.OBJECT_CHUNK) => .object_chunk,
        @intFromEnum(zova_graph_target_type.VECTOR) => .vector,
        @intFromEnum(zova_graph_target_type.ENTITY) => .entity,
        @intFromEnum(zova_graph_target_type.FACT) => .fact,
        @intFromEnum(zova_graph_target_type.CONCEPT) => .concept,
        @intFromEnum(zova_graph_target_type.EXTERNAL) => .external,
        else => null,
    };
}

pub fn graphTargetTypeToAbi(target_type: zova.GraphTargetType) c_int {
    return switch (target_type) {
        .none => @intFromEnum(zova_graph_target_type.NONE),
        .record => @intFromEnum(zova_graph_target_type.RECORD),
        .object => @intFromEnum(zova_graph_target_type.OBJECT),
        .object_chunk => @intFromEnum(zova_graph_target_type.OBJECT_CHUNK),
        .vector => @intFromEnum(zova_graph_target_type.VECTOR),
        .entity => @intFromEnum(zova_graph_target_type.ENTITY),
        .fact => @intFromEnum(zova_graph_target_type.FACT),
        .concept => @intFromEnum(zova_graph_target_type.CONCEPT),
        .external => @intFromEnum(zova_graph_target_type.EXTERNAL),
    };
}

pub fn graphDirectionFromAbi(direction: c_int) ?zova.GraphNeighborDirection {
    return switch (direction) {
        @intFromEnum(zova_graph_neighbor_direction.OUTGOING) => .outgoing,
        @intFromEnum(zova_graph_neighbor_direction.INCOMING) => .incoming,
        else => null,
    };
}

pub fn optionalCStringSpan(value: ?[*:0]const u8) ?[]const u8 {
    const ptr = value orelse return null;
    return std.mem.span(ptr);
}

pub fn toObjectId(id: zova_object_id) zova.ObjectId {
    return id.bytes;
}

pub fn objectOptionsFromAbi(options: zova_object_put_options) ?zova.ObjectPutOptions {
    return switch (options.profile) {
        @intFromEnum(zova_object_storage_profile.DEDUPLICATION) => .{ .profile = .deduplication },
        @intFromEnum(zova_object_storage_profile.STREAMING) => .{ .profile = .streaming },
        else => null,
    };
}

pub fn fromObjectId(id: zova.ObjectId) zova_object_id {
    return .{ .bytes = id };
}

pub fn toChunkId(id: zova_object_chunk_id) zova.ObjectChunkId {
    return id.bytes;
}

pub fn fromChunkId(id: zova.ObjectChunkId) zova_object_chunk_id {
    return .{ .bytes = id };
}

pub fn columnTypeToAbi(column_type: sqlite.ColumnType) zova_column_type {
    return switch (column_type) {
        .integer => .INTEGER,
        .float => .FLOAT,
        .text => .TEXT,
        .blob => .BLOB,
        .null => .NULL,
    };
}
