//! Vector collection, mutation, and search entrypoint implementations.

const std = @import("std");

const allocator = @import("values.zig").allocator;
const candidateIdSlices = @import("values.zig").candidateIdSlices;
const databaseHandle = @import("handles.zig").databaseHandle;
const emptyVector = @import("results.zig").emptyVector;
const emptyVectorCollectionInfo = @import("results.zig").emptyVectorCollectionInfo;
const emptyVectorCollectionList = @import("results.zig").emptyVectorCollectionList;
const emptyVectorSearchResults = @import("results.zig").emptyVectorSearchResults;
const failDb = @import("errors.zig").failDb;
const fillSearchResults = @import("results.zig").fillSearchResults;
const fillVector = @import("results.zig").fillVector;
const fillVectorCollectionInfo = @import("results.zig").fillVectorCollectionInfo;
const fillVectorCollectionList = @import("results.zig").fillVectorCollectionList;
const multiI8AggregationFromAbi = @import("values.zig").multiI8AggregationFromAbi;
const multiI8QuerySlices = @import("values.zig").multiI8QuerySlices;
const multiI8SearchModeFromAbi = @import("values.zig").multiI8SearchModeFromAbi;
const okDb = @import("errors.zig").okDb;
const vectorElementTypeFromAbi = @import("values.zig").vectorElementTypeFromAbi;
const vectorInputSlices = @import("values.zig").vectorInputSlices;
const vectorMetricFromAbi = @import("values.zig").vectorMetricFromAbi;
const vectorValuesConst = @import("values.zig").vectorValuesConst;
const zova_status = @import("types.zig").zova_status;
const zova_vector_collection_create_request = @import("types.zig").zova_vector_collection_create_request;
const zova_vector_collection_delete_request = @import("types.zig").zova_vector_collection_delete_request;
const zova_vector_collection_exists_request = @import("types.zig").zova_vector_collection_exists_request;
const zova_vector_collection_info_get_request = @import("types.zig").zova_vector_collection_info_get_request;
const zova_vector_collections_list_request = @import("types.zig").zova_vector_collections_list_request;
const zova_vector_delete_many_request = @import("types.zig").zova_vector_delete_many_request;
const zova_vector_delete_request = @import("types.zig").zova_vector_delete_request;
const zova_vector_exists_request = @import("types.zig").zova_vector_exists_request;
const zova_vector_get_request = @import("types.zig").zova_vector_get_request;
const zova_vector_put_many_request = @import("types.zig").zova_vector_put_many_request;
const zova_vector_put_request = @import("types.zig").zova_vector_put_request;
const zova_vector_search_by_id_in_request = @import("types.zig").zova_vector_search_by_id_in_request;
const zova_vector_search_by_id_in_within_request = @import("types.zig").zova_vector_search_by_id_in_within_request;
const zova_vector_search_by_id_request = @import("types.zig").zova_vector_search_by_id_request;
const zova_vector_search_by_id_within_request = @import("types.zig").zova_vector_search_by_id_within_request;
const zova_vector_search_in_request = @import("types.zig").zova_vector_search_in_request;
const zova_vector_search_in_within_request = @import("types.zig").zova_vector_search_in_within_request;
const zova_vector_search_multi_i8_request = @import("types.zig").zova_vector_search_multi_i8_request;
const zova_vector_search_request = @import("types.zig").zova_vector_search_request;
const zova_vector_search_within_request = @import("types.zig").zova_vector_search_within_request;

pub fn zova_vector_collection_create(request: ?*const zova_vector_collection_create_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const metric = vectorMetricFromAbi(req.options.metric) orelse return failDb(handle, error.InvalidArgument);
    const element_type = vectorElementTypeFromAbi(req.options.element_type) orelse return failDb(handle, error.InvalidArgument);

    handle.db.createVectorCollection(std.mem.span(name), .{
        .dimensions = req.options.dimensions,
        .metric = metric,
        .element_type = element_type,
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_collection_exists(request: ?*const zova_vector_collection_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasVectorCollection(std.mem.span(name)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_vector_put(request: ?*const zova_vector_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);
    const values = vectorValuesConst(req.values) orelse return failDb(handle, error.InvalidArgument);

    handle.db.putVector(std.mem.span(collection_name), std.mem.span(vector_id), values) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_get(request: ?*const zova_vector_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_vector orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVector();

    var vector = handle.db.getVector(allocator, std.mem.span(collection_name), std.mem.span(vector_id)) catch |err| return failDb(handle, err);
    errdefer vector.deinit(allocator);
    fillVector(out, &vector) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_exists(request: ?*const zova_vector_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasVector(std.mem.span(collection_name), std.mem.span(vector_id)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_vector_delete(request: ?*const zova_vector_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);

    handle.db.deleteVector(std.mem.span(collection_name), std.mem.span(vector_id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search(request: ?*const zova_vector_search_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const query = vectorValuesConst(req.query) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    var results = handle.db.searchVectors(allocator, std.mem.span(collection_name), query, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_in(request: ?*const zova_vector_search_in_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const query = vectorValuesConst(req.query) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchVectorsIn(allocator, std.mem.span(collection_name), query, candidates, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_multi_i8(request: ?*const zova_vector_search_multi_i8_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();
    const mode = multiI8SearchModeFromAbi(req.mode) orelse return failDb(handle, error.InvalidArgument);
    if (multiI8AggregationFromAbi(req.aggregation) == null) return failDb(handle, error.InvalidArgument);

    const queries = multiI8QuerySlices(req.query_values, req.query_values_len, req.query_count, req.dimensions) catch |err| return failDb(handle, err);
    defer allocator.free(queries);
    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchMultiI8Cosine(allocator, std.mem.span(collection_name), .{
        .queries = queries,
        .candidate_ids = if (req.candidate_count == 0) null else candidates,
        .mode = mode,
        .prefilter_query_index = req.prefilter_query_index,
        .prefilter_limit = req.prefilter_limit,
    }, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_collection_info_get(request: ?*const zova_vector_collection_info_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_info orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorCollectionInfo();

    var info = handle.db.vectorCollectionInfo(allocator, std.mem.span(name)) catch |err| return failDb(handle, err);
    defer info.deinit(allocator);

    fillVectorCollectionInfo(out, info) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_collections_list(request: ?*const zova_vector_collections_list_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_list orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorCollectionList();

    var list = handle.db.listVectorCollections(allocator) catch |err| return failDb(handle, err);
    defer list.deinit(allocator);

    fillVectorCollectionList(out, list.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_put_many(request: ?*const zova_vector_put_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);

    const vectors = vectorInputSlices(req.vectors, req.vectors_len) catch |err| return failDb(handle, err);
    defer if (vectors.len != 0) allocator.free(vectors);

    handle.db.putVectors(std.mem.span(collection_name), vectors) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_delete_many(request: ?*const zova_vector_delete_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_ids = candidateIdSlices(req.vector_ids, req.vector_count) catch |err| return failDb(handle, err);
    defer if (vector_ids.len != 0) allocator.free(vector_ids);
    handle.db.deleteVectors(std.mem.span(collection_name), vector_ids) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_collection_delete(request: ?*const zova_vector_collection_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);

    handle.db.deleteVectorCollection(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_within(request: ?*const zova_vector_search_within_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const query = vectorValuesConst(req.query) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    var results = handle.db.searchVectorsWithin(allocator, std.mem.span(collection_name), query, req.max_distance, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_in_within(request: ?*const zova_vector_search_in_within_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const query = vectorValuesConst(req.query) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchVectorsInWithin(allocator, std.mem.span(collection_name), query, candidates, req.max_distance, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_by_id(request: ?*const zova_vector_search_by_id_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const source_vector_id = req.source_vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    var results = handle.db.searchVectorsById(allocator, std.mem.span(collection_name), std.mem.span(source_vector_id), req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_by_id_in(request: ?*const zova_vector_search_by_id_in_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const source_vector_id = req.source_vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchVectorsByIdIn(allocator, std.mem.span(collection_name), std.mem.span(source_vector_id), candidates, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_by_id_within(request: ?*const zova_vector_search_by_id_within_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const source_vector_id = req.source_vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    var results = handle.db.searchVectorsByIdWithin(allocator, std.mem.span(collection_name), std.mem.span(source_vector_id), req.max_distance, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_by_id_in_within(request: ?*const zova_vector_search_by_id_in_within_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const source_vector_id = req.source_vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchVectorsByIdInWithin(
        allocator,
        std.mem.span(collection_name),
        std.mem.span(source_vector_id),
        candidates,
        req.max_distance,
        req.limit,
    ) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}
