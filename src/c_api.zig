//! C ABI bridge for Zova.
//!
//! This module deliberately exposes only C-compatible handles, request structs,
//! fixed-width ids, status values, and owned buffers. It does not expose Zig
//! slices, Zig allocators, Zig error unions, or private `_zova_*` schema.
//!
//! Header contract versus implementation contract:
//! - `include/zova.h` documents what C/Rust/foreign callers may rely on.
//! - this file documents the bridge decisions maintainers must preserve.
//!
//! The C ABI is pre-1.0. It is still designed as if consumers will generate
//! bindings from it: stable numeric statuses, opaque handles, explicit free
//! functions, no global mutable error state, and `zova_`-prefixed symbols.
//!
//! Exported functions should never let Zig implementation details escape. Convert
//! every Zig error into `zova_status`, return owned data through C containers,
//! and keep borrowed pointers scoped to the documented lifetime.
//!
//! Vectors follow the same ABI pattern as objects: collection names and vector
//! ids are borrowed C strings, vector values are borrowed `float` arrays, and
//! returned vectors/search results are library-owned containers with explicit
//! free functions. Vector metadata remains application-owned in normal SQL
//! tables; this bridge only exposes native vector storage and exact search.

const std = @import("std");
const zova = @import("zova.zig");

const allocator = std.heap.c_allocator;

// These opaque declarations match `include/zova.h`. The real state lives in
// DatabaseHandle and WriterHandle below so C callers cannot depend on layout.
pub const zova_database = opaque {};
pub const zova_object_writer = opaque {};

const DatabaseHandle = struct {
    db: zova.Database,
    // Connection-scoped diagnostic text. This mirrors SQLite's model closely:
    // callers can ask the database handle for the most recent useful message,
    // and the pointer is borrowed until another call on the handle replaces it.
    last_error: ?[:0]u8 = null,
};

const WriterHandle = struct {
    // Writers are tied to one database handle. The C ABI intentionally does not
    // support using either handle concurrently from multiple threads.
    db: *DatabaseHandle,
    writer: zova.ObjectWriter,
};

// Keep these numeric values synchronized with `include/zova.h`. Existing values
// should be treated as ABI surface once a release containing them is published.
pub const zova_status = enum(c_int) {
    OK = 0,
    INVALID_ARGUMENT = 1,
    OUT_OF_MEMORY = 2,
    BUSY = 10,
    LOCKED = 11,
    CONSTRAINT = 12,
    CANT_OPEN = 13,
    READ_ONLY = 14,
    CORRUPT = 15,
    MISUSE = 16,
    SQLITE_ERROR = 17,
    NOT_ZOVA_PATH = 30,
    NOT_ZOVA_DATABASE = 31,
    UNSUPPORTED_ZOVA_VERSION = 32,
    DESTINATION_EXISTS = 33,
    ZOVA_NAME_CONFLICT = 34,
    OBJECT_NOT_FOUND = 50,
    OBJECT_ALREADY_EXISTS = 51,
    OBJECT_CHUNK_NOT_FOUND = 52,
    OBJECT_CHUNK_HASH_MISMATCH = 53,
    OBJECT_CORRUPT = 54,
    OBJECT_MANIFEST_INVALID = 55,
    OBJECT_RANGE_INVALID = 56,
    OBJECT_TOO_LARGE = 57,
    OBJECT_TRANSACTION_ACTIVE = 58,
    OBJECT_WRITER_CLOSED = 59,
    VECTOR_COLLECTION_EXISTS = 70,
    VECTOR_COLLECTION_NOT_FOUND = 71,
    VECTOR_NOT_FOUND = 72,
    VECTOR_DIMENSION_MISMATCH = 73,
    VECTOR_CORRUPT = 74,
    VECTOR_INVALID = 75,
};

pub const zova_object_id = extern struct {
    bytes: [32]u8,
};

pub const zova_object_chunk_id = extern struct {
    bytes: [32]u8,
};

pub const zova_buffer = extern struct {
    data: ?[*]u8,
    len: usize,
};

pub const zova_message = extern struct {
    data: ?[*]u8,
    len: usize,
};

pub const zova_object_manifest_chunk = extern struct {
    index: u64,
    hash: zova_object_chunk_id,
    offset: u64,
    size_bytes: u64,
};

pub const zova_object_manifest = extern struct {
    object_id: zova_object_id,
    size_bytes: u64,
    chunk_count: u64,
    chunker: ?[*:0]const u8,
    chunks: ?[*]zova_object_manifest_chunk,
    chunks_len: usize,
};

pub const zova_vector_metric = enum(c_int) {
    COSINE = 0,
    L2 = 1,
    DOT = 2,
};

pub const zova_vector_collection_options = extern struct {
    dimensions: u32,
    // Keep this as a raw C integer instead of a Zig enum field so invalid C
    // enum values can be reported as ZOVA_INVALID_ARGUMENT rather than tripping
    // Zig enum safety checks.
    metric: c_int,
};

pub const zova_vector = extern struct {
    id: ?[*]u8,
    id_len: usize,
    values: ?[*]f32,
    values_len: usize,
};

pub const zova_vector_search_result = extern struct {
    id: ?[*]u8,
    id_len: usize,
    distance: f64,
};

pub const zova_vector_search_results = extern struct {
    items: ?[*]zova_vector_search_result,
    len: usize,
};

pub const zova_database_open_request = extern struct {
    path: ?[*:0]const u8,
    out_db: ?*?*zova_database,
    out_error_message: ?*zova_message,
};

pub const zova_convert_sqlite_to_zova_request = extern struct {
    source_path: ?[*:0]const u8,
    dest_path: ?[*:0]const u8,
    out_error_message: ?*zova_message,
};

pub const zova_database_exec_request = extern struct {
    db: ?*zova_database,
    sql: ?[*:0]const u8,
};

pub const zova_object_put_request = extern struct {
    db: ?*zova_database,
    data: ?[*]const u8,
    len: usize,
    out_id: ?*zova_object_id,
};

pub const zova_object_get_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_buffer: ?*zova_buffer,
};

pub const zova_object_read_range_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    offset: u64,
    buffer: ?[*]u8,
    buffer_len: usize,
    out_copied: ?*usize,
};

pub const zova_object_exists_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_exists: ?*u8,
};

pub const zova_object_size_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_size: ?*u64,
};

pub const zova_object_chunk_count_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_count: ?*u64,
};

pub const zova_object_delete_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
};

pub const zova_object_manifest_get_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_manifest: ?*zova_object_manifest,
};

pub const zova_object_chunk_get_request = extern struct {
    db: ?*zova_database,
    hash: zova_object_chunk_id,
    out_buffer: ?*zova_buffer,
};

pub const zova_object_chunk_put_request = extern struct {
    db: ?*zova_database,
    expected_hash: zova_object_chunk_id,
    data: ?[*]const u8,
    len: usize,
};

pub const zova_object_chunk_delete_request = extern struct {
    db: ?*zova_database,
    hash: zova_object_chunk_id,
    out_deleted: ?*u8,
};

pub const zova_object_assemble_from_chunks_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    size_bytes: u64,
    chunks: ?[*]const zova_object_manifest_chunk,
    chunk_count: usize,
};

pub const zova_object_writer_create_request = extern struct {
    db: ?*zova_database,
    out_writer: ?*?*zova_object_writer,
};

pub const zova_object_writer_write_request = extern struct {
    writer: ?*zova_object_writer,
    data: ?[*]const u8,
    len: usize,
};

pub const zova_object_writer_finish_request = extern struct {
    writer: ?*zova_object_writer,
    out_id: ?*zova_object_id,
};

pub const zova_object_writer_cancel_request = extern struct {
    writer: ?*zova_object_writer,
};

pub const zova_vector_collection_create_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
    options: zova_vector_collection_options,
};

pub const zova_vector_collection_exists_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
    out_exists: ?*u8,
};

pub const zova_vector_put_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    vector_id: ?[*:0]const u8,
    values: ?[*]const f32,
    values_len: usize,
};

pub const zova_vector_get_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    vector_id: ?[*:0]const u8,
    out_vector: ?*zova_vector,
};

pub const zova_vector_exists_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    vector_id: ?[*:0]const u8,
    out_exists: ?*u8,
};

pub const zova_vector_delete_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    vector_id: ?[*:0]const u8,
};

pub const zova_vector_search_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    query: ?[*]const f32,
    query_len: usize,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

pub const zova_vector_search_in_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    query: ?[*]const f32,
    query_len: usize,
    candidate_ids: ?[*]const ?[*:0]const u8,
    candidate_count: usize,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

// Version helpers describe the C ABI boundary, not the .zova file format.
export fn zova_abi_version_major() callconv(.c) u32 {
    return 0;
}

export fn zova_abi_version_minor() callconv(.c) u32 {
    return 9;
}

export fn zova_abi_version_patch() callconv(.c) u32 {
    return 0;
}

export fn zova_abi_version_string() callconv(.c) [*:0]const u8 {
    return "0.9.0";
}

// Accept a raw integer instead of a Zig enum so accidental or future C enum
// values cannot trigger a Zig enum safety check.
export fn zova_status_name(status: c_int) callconv(.c) [*:0]const u8 {
    return statusName(status);
}

// Free functions are null-safe and reset containers. That makes repeated frees
// harmless for callers that follow the container API instead of freeing fields.
export fn zova_buffer_free(buffer: ?*zova_buffer) callconv(.c) void {
    const out = buffer orelse return;
    if (out.data) |data| {
        allocator.free(data[0..out.len]);
    }
    out.* = .{ .data = null, .len = 0 };
}

export fn zova_message_free(message: ?*zova_message) callconv(.c) void {
    const out = message orelse return;
    if (out.data) |data| {
        allocator.free(data[0 .. out.len + 1]);
    }
    out.* = .{ .data = null, .len = 0 };
}

export fn zova_object_manifest_free(manifest: ?*zova_object_manifest) callconv(.c) void {
    const out = manifest orelse return;
    if (out.chunks) |chunks| {
        allocator.free(chunks[0..out.chunks_len]);
    }
    out.* = emptyManifest();
}

export fn zova_vector_free(vector: ?*zova_vector) callconv(.c) void {
    const out = vector orelse return;
    if (out.id) |id| {
        allocator.free(id[0 .. out.id_len + 1]);
    }
    if (out.values) |values| {
        allocator.free(values[0..out.values_len]);
    }
    out.* = emptyVector();
}

export fn zova_vector_search_results_free(results: ?*zova_vector_search_results) callconv(.c) void {
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

export fn zova_database_create(request: ?*const zova_database_open_request) callconv(.c) zova_status {
    return openDatabase(request, .create);
}

export fn zova_database_open(request: ?*const zova_database_open_request) callconv(.c) zova_status {
    return openDatabase(request, .open);
}

export fn zova_database_close(db: ?*zova_database) callconv(.c) zova_status {
    const handle = databaseHandle(db) orelse return .INVALID_ARGUMENT;
    clearLastError(handle);
    handle.db.deinit();
    allocator.destroy(handle);
    return .OK;
}

export fn zova_database_exec(request: ?*const zova_database_exec_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const sql = req.sql orelse return failDb(handle, error.InvalidArgument);
    handle.db.exec(std.mem.span(sql)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

export fn zova_database_last_error_message(db: ?*zova_database) callconv(.c) [*:0]const u8 {
    const handle = databaseHandle(db) orelse return "invalid database handle";
    if (handle.last_error) |message| return message.ptr;
    return "";
}

// No-handle operations cannot use connection-scoped diagnostics, so request
// structs optionally carry an owned zova_message for callers that want details.
export fn zova_convert_sqlite_to_zova(request: ?*const zova_convert_sqlite_to_zova_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const source_path = req.source_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    const dest_path = req.dest_path orelse return failMessage(req.out_error_message, error.InvalidArgument);

    zova.convertSqliteToZova(std.mem.span(source_path), std.mem.span(dest_path)) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    return .OK;
}

// The public helper name is not `zova_object_id`: in C, typedef names and
// function names share one namespace, so that would collide with the id type.
export fn zova_object_id_from_bytes(data: ?[*]const u8, len: usize, out_id: ?*zova_object_id) callconv(.c) zova_status {
    const out = out_id orelse return .INVALID_ARGUMENT;
    const bytes = bytesConst(data, len) orelse return .INVALID_ARGUMENT;
    out.* = fromObjectId(zova.objectId(bytes));
    return .OK;
}

export fn zova_object_chunk_id_from_bytes(
    data: ?[*]const u8,
    len: usize,
    out_id: ?*zova_object_chunk_id,
) callconv(.c) zova_status {
    const out = out_id orelse return .INVALID_ARGUMENT;
    const bytes = bytesConst(data, len) orelse return .INVALID_ARGUMENT;
    out.* = fromChunkId(zova.objectChunkId(bytes));
    return .OK;
}

export fn zova_object_put(request: ?*const zova_object_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const out = req.out_id orelse return failDb(handle, error.InvalidArgument);
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle, error.InvalidArgument);
    const id = handle.db.putObject(bytes) catch |err| return failDb(handle, err);
    out.* = fromObjectId(id);
    return okDb(handle);
}

export fn zova_object_get(request: ?*const zova_object_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const out = req.out_buffer orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyBuffer();
    var object = handle.db.getObject(allocator, toObjectId(req.id)) catch |err| return failDb(handle, err);
    // Transfer ownership of the allocation from zova.Object to zova_buffer.
    out.* = .{ .data = object.bytes.ptr, .len = object.bytes.len };
    object.bytes = &.{};
    return okDb(handle);
}

export fn zova_object_read_range(request: ?*const zova_object_read_range_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const out = req.out_copied orelse return failDb(handle, error.InvalidArgument);
    out.* = 0;
    const buffer = bytesMut(req.buffer, req.buffer_len) orelse return failDb(handle, error.InvalidArgument);
    const copied = handle.db.readObjectRange(toObjectId(req.id), req.offset, buffer) catch |err| return failDb(handle, err);
    out.* = copied;
    return okDb(handle);
}

export fn zova_object_delete(request: ?*const zova_object_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.db.deleteObject(toObjectId(req.id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

export fn zova_object_exists(request: ?*const zova_object_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasObject(toObjectId(req.id)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

export fn zova_object_size(request: ?*const zova_object_size_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const out = req.out_size orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.objectSize(toObjectId(req.id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

export fn zova_object_chunk_count(request: ?*const zova_object_chunk_count_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const out = req.out_count orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.objectChunkCount(toObjectId(req.id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

export fn zova_object_manifest_get(request: ?*const zova_object_manifest_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const out = req.out_manifest orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyManifest();

    var manifest = handle.db.objectManifest(allocator, toObjectId(req.id)) catch |err| return failDb(handle, err);
    defer manifest.deinit(allocator);

    const chunks = allocator.alloc(zova_object_manifest_chunk, manifest.chunks.len) catch |err| return failDb(handle, err);
    errdefer allocator.free(chunks);
    for (manifest.chunks, chunks) |chunk, *out_chunk| {
        out_chunk.* = .{
            .index = chunk.index,
            .hash = fromChunkId(chunk.hash),
            .offset = chunk.offset,
            .size_bytes = chunk.size_bytes,
        };
    }

    out.* = .{
        .object_id = fromObjectId(manifest.object_id),
        .size_bytes = manifest.size_bytes,
        .chunk_count = manifest.chunk_count,
        .chunker = "fastcdc-v1",
        .chunks = if (chunks.len == 0) null else chunks.ptr,
        .chunks_len = chunks.len,
    };
    return okDb(handle);
}

export fn zova_object_chunk_get(request: ?*const zova_object_chunk_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const out = req.out_buffer orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyBuffer();
    var chunk = handle.db.getObjectChunk(allocator, toChunkId(req.hash)) catch |err| return failDb(handle, err);
    // Transfer ownership of the allocation from zova.ObjectChunkData to zova_buffer.
    out.* = .{ .data = chunk.bytes.ptr, .len = chunk.bytes.len };
    chunk.bytes = &.{};
    return okDb(handle);
}

export fn zova_object_chunk_put(request: ?*const zova_object_chunk_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.putObjectChunk(toChunkId(req.expected_hash), bytes) catch |err| return failDb(handle, err);
    return okDb(handle);
}

export fn zova_object_chunk_delete(request: ?*const zova_object_chunk_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const out = req.out_deleted orelse return failDb(handle, error.InvalidArgument);
    const deleted = handle.db.deleteObjectChunk(toChunkId(req.hash)) catch |err| return failDb(handle, err);
    out.* = if (deleted) 1 else 0;
    return okDb(handle);
}

export fn zova_object_assemble_from_chunks(
    request: ?*const zova_object_assemble_from_chunks_request,
) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const input_chunks = manifestChunks(req.chunks, req.chunk_count) orelse return failDb(handle, error.InvalidArgument);
    const chunks = allocator.alloc(zova.ObjectChunk, input_chunks.len) catch |err| return failDb(handle, err);
    defer allocator.free(chunks);
    for (input_chunks, chunks) |chunk, *out_chunk| {
        out_chunk.* = .{
            .index = chunk.index,
            .hash = toChunkId(chunk.hash),
            .offset = chunk.offset,
            .size_bytes = chunk.size_bytes,
        };
    }
    handle.db.assembleObjectFromChunks(toObjectId(req.id), req.size_bytes, chunks) catch |err| return failDb(handle, err);
    return okDb(handle);
}

export fn zova_object_writer_create(request: ?*const zova_object_writer_create_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const out = req.out_writer orelse return failDb(handle, error.InvalidArgument);
    out.* = null;

    var writer = handle.db.objectWriter(allocator) catch |err| return failDb(handle, err);
    const writer_handle = allocator.create(WriterHandle) catch |err| {
        writer.deinit();
        return failDb(handle, err);
    };
    writer_handle.* = .{ .db = handle, .writer = writer };
    out.* = @ptrCast(writer_handle);
    return okDb(handle);
}

export fn zova_object_writer_write(request: ?*const zova_object_writer_write_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = writerHandle(req.writer) orelse return .INVALID_ARGUMENT;
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle.db, error.InvalidArgument);
    handle.writer.write(bytes) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

export fn zova_object_writer_finish(request: ?*const zova_object_writer_finish_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = writerHandle(req.writer) orelse return .INVALID_ARGUMENT;
    const out = req.out_id orelse return failDb(handle.db, error.InvalidArgument);
    const id = handle.writer.finish() catch |err| return failDb(handle.db, err);
    out.* = fromObjectId(id);
    return okDb(handle.db);
}

export fn zova_object_writer_cancel(request: ?*const zova_object_writer_cancel_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = writerHandle(req.writer) orelse return .INVALID_ARGUMENT;
    handle.writer.cancel() catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

export fn zova_object_writer_destroy(writer: ?*zova_object_writer) callconv(.c) zova_status {
    const handle = writerHandle(writer) orelse return .INVALID_ARGUMENT;
    handle.writer.deinit();
    allocator.destroy(handle);
    return .OK;
}

export fn zova_vector_collection_create(request: ?*const zova_vector_collection_create_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const metric = vectorMetricFromAbi(req.options.metric) orelse return failDb(handle, error.InvalidArgument);

    handle.db.createVectorCollection(std.mem.span(name), .{
        .dimensions = req.options.dimensions,
        .metric = metric,
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

export fn zova_vector_collection_exists(request: ?*const zova_vector_collection_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasVectorCollection(std.mem.span(name)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

export fn zova_vector_put(request: ?*const zova_vector_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);
    const values = floatsConst(req.values, req.values_len) orelse return failDb(handle, error.InvalidArgument);

    handle.db.putVector(std.mem.span(collection_name), std.mem.span(vector_id), values) catch |err| return failDb(handle, err);
    return okDb(handle);
}

export fn zova_vector_get(request: ?*const zova_vector_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_vector orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVector();

    var vector = handle.db.getVector(allocator, std.mem.span(collection_name), std.mem.span(vector_id)) catch |err| return failDb(handle, err);
    errdefer vector.deinit(allocator);

    const id = allocator.dupeZ(u8, vector.id) catch |err| return failDb(handle, err);
    errdefer allocator.free(id);

    allocator.free(vector.id);
    vector.id = &.{};
    out.* = .{
        .id = id.ptr,
        .id_len = id.len,
        .values = if (vector.values.len == 0) null else vector.values.ptr,
        .values_len = vector.values.len,
    };
    vector.values = &.{};
    return okDb(handle);
}

export fn zova_vector_exists(request: ?*const zova_vector_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasVector(std.mem.span(collection_name), std.mem.span(vector_id)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

export fn zova_vector_delete(request: ?*const zova_vector_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);

    handle.db.deleteVector(std.mem.span(collection_name), std.mem.span(vector_id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

export fn zova_vector_search(request: ?*const zova_vector_search_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const query = floatsConst(req.query, req.query_len) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    var results = handle.db.searchVectors(allocator, std.mem.span(collection_name), query, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

export fn zova_vector_search_in(request: ?*const zova_vector_search_in_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const query = floatsConst(req.query, req.query_len) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchVectorsIn(allocator, std.mem.span(collection_name), query, candidates, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

const OpenMode = enum { create, open };

fn openDatabase(request: ?*const zova_database_open_request, mode: OpenMode) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const out = req.out_db orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = null;
    const path = req.path orelse return failMessage(req.out_error_message, error.InvalidArgument);

    var db = switch (mode) {
        .create => zova.Database.create(std.mem.span(path)),
        .open => zova.Database.open(std.mem.span(path)),
    } catch |err| return failMessage(req.out_error_message, err);

    const handle = allocator.create(DatabaseHandle) catch |err| {
        db.deinit();
        return failMessage(req.out_error_message, err);
    };
    handle.* = .{ .db = db };
    out.* = @ptrCast(handle);
    return .OK;
}

// Opaque handles are just erased DatabaseHandle/WriterHandle pointers. Casts
// stay local to this module so the ABI can keep exposing incomplete C structs.
fn databaseHandle(db: ?*zova_database) ?*DatabaseHandle {
    const ptr = db orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn writerHandle(writer: ?*zova_object_writer) ?*WriterHandle {
    const ptr = writer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// A null pointer is valid only for empty byte slices. That keeps empty objects
// and zero-length range buffers ergonomic while still catching bad lengths.
fn bytesConst(data: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

fn bytesMut(data: ?[*]u8, len: usize) ?[]u8 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

fn manifestChunks(chunks: ?[*]const zova_object_manifest_chunk, len: usize) ?[]const zova_object_manifest_chunk {
    if (len == 0) return &.{};
    const ptr = chunks orelse return null;
    return ptr[0..len];
}

fn floatsConst(data: ?[*]const f32, len: usize) ?[]const f32 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

fn candidateIdSlices(
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

fn vectorMetricFromAbi(metric: c_int) ?zova.VectorMetric {
    return switch (metric) {
        @intFromEnum(zova_vector_metric.COSINE) => .cosine,
        @intFromEnum(zova_vector_metric.L2) => .l2,
        @intFromEnum(zova_vector_metric.DOT) => .dot,
        else => null,
    };
}

fn toObjectId(id: zova_object_id) zova.ObjectId {
    return id.bytes;
}

fn fromObjectId(id: zova.ObjectId) zova_object_id {
    return .{ .bytes = id };
}

fn toChunkId(id: zova_object_chunk_id) zova.ObjectChunkId {
    return id.bytes;
}

fn fromChunkId(id: zova.ObjectChunkId) zova_object_chunk_id {
    return .{ .bytes = id };
}

fn emptyBuffer() zova_buffer {
    return .{ .data = null, .len = 0 };
}

fn emptyManifest() zova_object_manifest {
    return .{
        .object_id = .{ .bytes = [_]u8{0} ** 32 },
        .size_bytes = 0,
        .chunk_count = 0,
        .chunker = null,
        .chunks = null,
        .chunks_len = 0,
    };
}

fn emptyVector() zova_vector {
    return .{ .id = null, .id_len = 0, .values = null, .values_len = 0 };
}

fn emptyVectorSearchResults() zova_vector_search_results {
    return .{ .items = null, .len = 0 };
}

fn fillSearchResults(out: *zova_vector_search_results, items: []const zova.VectorSearchResult) error{OutOfMemory}!void {
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

fn failDb(handle: *DatabaseHandle, err: anyerror) zova_status {
    const status = statusFromError(err);
    setLastError(handle, err);
    return status;
}

fn okDb(handle: *DatabaseHandle) zova_status {
    clearLastError(handle);
    return .OK;
}

fn failMessage(message: ?*zova_message, err: anyerror) zova_status {
    setMessage(message, @errorName(err));
    return statusFromError(err);
}

// Prefer SQLite's detailed connection error when it has one; fall back to the
// Zig error name for Zova-native failures or argument validation.
fn setLastError(handle: *DatabaseHandle, err: anyerror) void {
    const sqlite_message = handle.db.errorMessage();
    if (!std.mem.eql(u8, sqlite_message, "not an error") and sqlite_message.len > 0) {
        setLastErrorString(handle, sqlite_message);
    } else {
        setLastErrorString(handle, @errorName(err));
    }
}

fn setLastErrorString(handle: *DatabaseHandle, message: []const u8) void {
    clearLastError(handle);
    handle.last_error = allocator.dupeZ(u8, message) catch null;
}

fn clearLastError(handle: *DatabaseHandle) void {
    if (handle.last_error) |message| {
        allocator.free(message);
    }
    handle.last_error = null;
}

fn setMessage(message: ?*zova_message, text: []const u8) void {
    const out = message orelse return;
    clearMessage(out);
    const copy = allocator.dupeZ(u8, text) catch return;
    out.* = .{ .data = copy.ptr, .len = text.len };
}

fn clearMessage(message: ?*zova_message) void {
    const out = message orelse return;
    zova_message_free(out);
}

// This is the only error translation table for the ABI. New public Zova errors
// should be considered here deliberately instead of leaking as SQLITE_ERROR.
fn statusFromError(err: anyerror) zova_status {
    return switch (err) {
        error.OutOfMemory => .OUT_OF_MEMORY,
        error.Busy => .BUSY,
        error.Locked => .LOCKED,
        error.Constraint => .CONSTRAINT,
        error.CantOpen => .CANT_OPEN,
        error.ReadOnly => .READ_ONLY,
        error.Corrupt => .CORRUPT,
        error.Misuse => .MISUSE,
        error.NotZovaPath => .NOT_ZOVA_PATH,
        error.NotZovaDatabase => .NOT_ZOVA_DATABASE,
        error.UnsupportedZovaVersion => .UNSUPPORTED_ZOVA_VERSION,
        error.DestinationExists => .DESTINATION_EXISTS,
        error.ZovaNameConflict => .ZOVA_NAME_CONFLICT,
        error.ObjectNotFound => .OBJECT_NOT_FOUND,
        error.ObjectAlreadyExists => .OBJECT_ALREADY_EXISTS,
        error.ObjectChunkNotFound => .OBJECT_CHUNK_NOT_FOUND,
        error.ObjectChunkHashMismatch => .OBJECT_CHUNK_HASH_MISMATCH,
        error.ObjectCorrupt => .OBJECT_CORRUPT,
        error.ObjectManifestInvalid => .OBJECT_MANIFEST_INVALID,
        error.ObjectRangeInvalid => .OBJECT_RANGE_INVALID,
        error.ObjectTooLarge => .OBJECT_TOO_LARGE,
        error.ObjectTransactionActive => .OBJECT_TRANSACTION_ACTIVE,
        error.ObjectWriterClosed => .OBJECT_WRITER_CLOSED,
        error.VectorCollectionExists => .VECTOR_COLLECTION_EXISTS,
        error.VectorCollectionNotFound => .VECTOR_COLLECTION_NOT_FOUND,
        error.VectorNotFound => .VECTOR_NOT_FOUND,
        error.VectorDimensionMismatch => .VECTOR_DIMENSION_MISMATCH,
        error.VectorCorrupt => .VECTOR_CORRUPT,
        error.VectorInvalid => .VECTOR_INVALID,
        error.InvalidArgument => .INVALID_ARGUMENT,
        else => .SQLITE_ERROR,
    };
}

fn statusName(status: c_int) [*:0]const u8 {
    return switch (status) {
        @intFromEnum(zova_status.OK) => "ZOVA_OK",
        @intFromEnum(zova_status.INVALID_ARGUMENT) => "ZOVA_INVALID_ARGUMENT",
        @intFromEnum(zova_status.OUT_OF_MEMORY) => "ZOVA_OUT_OF_MEMORY",
        @intFromEnum(zova_status.BUSY) => "ZOVA_BUSY",
        @intFromEnum(zova_status.LOCKED) => "ZOVA_LOCKED",
        @intFromEnum(zova_status.CONSTRAINT) => "ZOVA_CONSTRAINT",
        @intFromEnum(zova_status.CANT_OPEN) => "ZOVA_CANT_OPEN",
        @intFromEnum(zova_status.READ_ONLY) => "ZOVA_READ_ONLY",
        @intFromEnum(zova_status.CORRUPT) => "ZOVA_CORRUPT",
        @intFromEnum(zova_status.MISUSE) => "ZOVA_MISUSE",
        @intFromEnum(zova_status.SQLITE_ERROR) => "ZOVA_SQLITE_ERROR",
        @intFromEnum(zova_status.NOT_ZOVA_PATH) => "ZOVA_NOT_ZOVA_PATH",
        @intFromEnum(zova_status.NOT_ZOVA_DATABASE) => "ZOVA_NOT_ZOVA_DATABASE",
        @intFromEnum(zova_status.UNSUPPORTED_ZOVA_VERSION) => "ZOVA_UNSUPPORTED_ZOVA_VERSION",
        @intFromEnum(zova_status.DESTINATION_EXISTS) => "ZOVA_DESTINATION_EXISTS",
        @intFromEnum(zova_status.ZOVA_NAME_CONFLICT) => "ZOVA_ZOVA_NAME_CONFLICT",
        @intFromEnum(zova_status.OBJECT_NOT_FOUND) => "ZOVA_OBJECT_NOT_FOUND",
        @intFromEnum(zova_status.OBJECT_ALREADY_EXISTS) => "ZOVA_OBJECT_ALREADY_EXISTS",
        @intFromEnum(zova_status.OBJECT_CHUNK_NOT_FOUND) => "ZOVA_OBJECT_CHUNK_NOT_FOUND",
        @intFromEnum(zova_status.OBJECT_CHUNK_HASH_MISMATCH) => "ZOVA_OBJECT_CHUNK_HASH_MISMATCH",
        @intFromEnum(zova_status.OBJECT_CORRUPT) => "ZOVA_OBJECT_CORRUPT",
        @intFromEnum(zova_status.OBJECT_MANIFEST_INVALID) => "ZOVA_OBJECT_MANIFEST_INVALID",
        @intFromEnum(zova_status.OBJECT_RANGE_INVALID) => "ZOVA_OBJECT_RANGE_INVALID",
        @intFromEnum(zova_status.OBJECT_TOO_LARGE) => "ZOVA_OBJECT_TOO_LARGE",
        @intFromEnum(zova_status.OBJECT_TRANSACTION_ACTIVE) => "ZOVA_OBJECT_TRANSACTION_ACTIVE",
        @intFromEnum(zova_status.OBJECT_WRITER_CLOSED) => "ZOVA_OBJECT_WRITER_CLOSED",
        @intFromEnum(zova_status.VECTOR_COLLECTION_EXISTS) => "ZOVA_VECTOR_COLLECTION_EXISTS",
        @intFromEnum(zova_status.VECTOR_COLLECTION_NOT_FOUND) => "ZOVA_VECTOR_COLLECTION_NOT_FOUND",
        @intFromEnum(zova_status.VECTOR_NOT_FOUND) => "ZOVA_VECTOR_NOT_FOUND",
        @intFromEnum(zova_status.VECTOR_DIMENSION_MISMATCH) => "ZOVA_VECTOR_DIMENSION_MISMATCH",
        @intFromEnum(zova_status.VECTOR_CORRUPT) => "ZOVA_VECTOR_CORRUPT",
        @intFromEnum(zova_status.VECTOR_INVALID) => "ZOVA_VECTOR_INVALID",
        else => "ZOVA_UNKNOWN_STATUS",
    };
}

test "c abi status names and versions are stable" {
    try std.testing.expectEqual(@as(u32, 0), zova_abi_version_major());
    try std.testing.expectEqual(@as(u32, 9), zova_abi_version_minor());
    try std.testing.expectEqual(@as(u32, 0), zova_abi_version_patch());
    try std.testing.expectEqualStrings("0.9.0", std.mem.span(zova_abi_version_string()));
    try std.testing.expectEqualStrings("ZOVA_OK", std.mem.span(zova_status_name(@intFromEnum(zova_status.OK))));
    try std.testing.expectEqualStrings("ZOVA_OBJECT_NOT_FOUND", std.mem.span(zova_status_name(@intFromEnum(zova_status.OBJECT_NOT_FOUND))));
    try std.testing.expectEqualStrings("ZOVA_VECTOR_INVALID", std.mem.span(zova_status_name(@intFromEnum(zova_status.VECTOR_INVALID))));
    try std.testing.expectEqualStrings("ZOVA_UNKNOWN_STATUS", std.mem.span(zova_status_name(-1)));
}

test "c abi validates null pointers" {
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_create(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_object_id_from_bytes(null, 1, null));
    var id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_object_id_from_bytes(null, 1, &id));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_collection_create(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_put(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_buffer_free_and_status_for_test());
}

test "c abi validates vector request shapes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-vector-validation.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));
    defer _ = zova_database_close(db);

    const invalid_metric_request = zova_vector_collection_create_request{
        .db = db,
        .name = "bad",
        .options = .{ .dimensions = 2, .metric = 99 },
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_collection_create(&invalid_metric_request));

    const create_collection_request = zova_vector_collection_create_request{
        .db = db,
        .name = "chunks",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2) },
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&create_collection_request));

    const bad_values_request = zova_vector_put_request{
        .db = db,
        .collection_name = "chunks",
        .vector_id = "id",
        .values = null,
        .values_len = 2,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_put(&bad_values_request));

    var search_results = zova_vector_search_results{ .items = null, .len = 0 };
    const bad_search_request = zova_vector_search_request{
        .db = db,
        .collection_name = "chunks",
        .query = null,
        .query_len = 2,
        .limit = 10,
        .out_results = &search_results,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search(&bad_search_request));

    const bad_candidates_request = zova_vector_search_in_request{
        .db = db,
        .collection_name = "chunks",
        .query = null,
        .query_len = 0,
        .candidate_ids = null,
        .candidate_count = 1,
        .limit = 10,
        .out_results = &search_results,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_in(&bad_candidates_request));

    const null_candidate_entries = [_]?[*:0]const u8{null};
    const bad_candidate_entry_request = zova_vector_search_in_request{
        .db = db,
        .collection_name = "chunks",
        .query = null,
        .query_len = 0,
        .candidate_ids = &null_candidate_entries,
        .candidate_count = null_candidate_entries.len,
        .limit = 10,
        .out_results = &search_results,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_in(&bad_candidate_entry_request));

    zova_vector_search_results_free(&search_results);
}

fn zova_buffer_free_and_status_for_test() zova_status {
    zova_buffer_free(null);
    return .INVALID_ARGUMENT;
}

test "c abi no-handle create error can return owned message" {
    var message = zova_message{ .data = null, .len = 0 };
    var db: ?*zova_database = null;
    const request = zova_database_open_request{
        .path = "not-zova.db",
        .out_db = &db,
        .out_error_message = &message,
    };
    try std.testing.expectEqual(zova_status.NOT_ZOVA_PATH, zova_database_create(&request));
    try std.testing.expect(db == null);
    try std.testing.expect(message.data != null);
    try std.testing.expect(message.len > 0);
    zova_message_free(&message);
}
