//! Object, chunk, writer, and reader entrypoint implementations.

const std = @import("std");
const zova = @import("../zova.zig");

const ReaderHandle = @import("handles.zig").ReaderHandle;
const WriterHandle = @import("handles.zig").WriterHandle;
const allocator = @import("values.zig").allocator;
const bytesConst = @import("values.zig").bytesConst;
const bytesMut = @import("values.zig").bytesMut;
const databaseHandle = @import("handles.zig").databaseHandle;
const emptyBuffer = @import("results.zig").emptyBuffer;
const emptyManifest = @import("results.zig").emptyManifest;
const failDb = @import("errors.zig").failDb;
const fromChunkId = @import("values.zig").fromChunkId;
const fromObjectId = @import("values.zig").fromObjectId;
const manifestChunks = @import("values.zig").manifestChunks;
const objectOptionsFromAbi = @import("values.zig").objectOptionsFromAbi;
const okDb = @import("errors.zig").okDb;
const readerHandle = @import("handles.zig").readerHandle;
const toChunkId = @import("values.zig").toChunkId;
const toObjectId = @import("values.zig").toObjectId;
const writerHandle = @import("handles.zig").writerHandle;
const zova_object_assemble_from_chunks_request = @import("types.zig").zova_object_assemble_from_chunks_request;
const zova_object_assemble_from_chunks_with_options_request = @import("types.zig").zova_object_assemble_from_chunks_with_options_request;
const zova_object_chunk_count_request = @import("types.zig").zova_object_chunk_count_request;
const zova_object_chunk_delete_request = @import("types.zig").zova_object_chunk_delete_request;
const zova_object_chunk_get_request = @import("types.zig").zova_object_chunk_get_request;
const zova_object_chunk_id = @import("types.zig").zova_object_chunk_id;
const zova_object_chunk_put_request = @import("types.zig").zova_object_chunk_put_request;
const zova_object_chunk_put_with_options_request = @import("types.zig").zova_object_chunk_put_with_options_request;
const zova_object_delete_request = @import("types.zig").zova_object_delete_request;
const zova_object_exists_request = @import("types.zig").zova_object_exists_request;
const zova_object_get_request = @import("types.zig").zova_object_get_request;
const zova_object_id = @import("types.zig").zova_object_id;
const zova_object_manifest_chunk = @import("types.zig").zova_object_manifest_chunk;
const zova_object_manifest_get_request = @import("types.zig").zova_object_manifest_get_request;
const zova_object_put_request = @import("types.zig").zova_object_put_request;
const zova_object_put_with_options_request = @import("types.zig").zova_object_put_with_options_request;
const zova_object_read_range_request = @import("types.zig").zova_object_read_range_request;
const zova_object_reader_create_request = @import("types.zig").zova_object_reader_create_request;
const zova_object_reader_destroy_request = @import("types.zig").zova_object_reader_destroy_request;
const zova_object_reader_read_request = @import("types.zig").zova_object_reader_read_request;
const zova_object_size_request = @import("types.zig").zova_object_size_request;
const zova_object_writer = @import("types.zig").zova_object_writer;
const zova_object_writer_cancel_request = @import("types.zig").zova_object_writer_cancel_request;
const zova_object_writer_create_request = @import("types.zig").zova_object_writer_create_request;
const zova_object_writer_create_with_options_request = @import("types.zig").zova_object_writer_create_with_options_request;
const zova_object_writer_finish_request = @import("types.zig").zova_object_writer_finish_request;
const zova_object_writer_write_request = @import("types.zig").zova_object_writer_write_request;
const zova_status = @import("types.zig").zova_status;

pub fn zova_object_id_from_bytes(data: ?[*]const u8, len: usize, out_id: ?*zova_object_id) callconv(.c) zova_status {
    const out = out_id orelse return .INVALID_ARGUMENT;
    const bytes = bytesConst(data, len) orelse return .INVALID_ARGUMENT;
    out.* = fromObjectId(zova.objectId(bytes));
    return .OK;
}

pub fn zova_object_chunk_id_from_bytes(
    data: ?[*]const u8,
    len: usize,
    out_id: ?*zova_object_chunk_id,
) callconv(.c) zova_status {
    const out = out_id orelse return .INVALID_ARGUMENT;
    const bytes = bytesConst(data, len) orelse return .INVALID_ARGUMENT;
    out.* = fromChunkId(zova.objectChunkId(bytes));
    return .OK;
}

pub fn zova_object_put(request: ?*const zova_object_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_id orelse return failDb(handle, error.InvalidArgument);
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle, error.InvalidArgument);
    const id = handle.db.putObject(bytes) catch |err| return failDb(handle, err);
    out.* = fromObjectId(id);
    return okDb(handle);
}

pub fn zova_object_put_with_options(
    request: ?*const zova_object_put_with_options_request,
) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_id orelse return failDb(handle, error.InvalidArgument);
    out.* = .{ .bytes = [_]u8{0} ** 32 };
    const options = objectOptionsFromAbi(req.options) orelse return failDb(handle, error.InvalidArgument);
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle, error.InvalidArgument);
    const id = handle.db.putObjectWithOptions(bytes, options) catch |err| return failDb(handle, err);
    out.* = fromObjectId(id);
    return okDb(handle);
}

pub fn zova_object_get(request: ?*const zova_object_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_buffer orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyBuffer();
    var object = handle.db.getObject(allocator, toObjectId(req.id)) catch |err| return failDb(handle, err);
    // Transfer ownership of the allocation from zova.Object to zova_buffer.
    out.* = .{ .data = object.bytes.ptr, .len = object.bytes.len };
    object.bytes = &.{};
    return okDb(handle);
}

pub fn zova_object_read_range(request: ?*const zova_object_read_range_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_copied orelse return failDb(handle, error.InvalidArgument);
    out.* = 0;
    const buffer = bytesMut(req.buffer, req.buffer_len) orelse return failDb(handle, error.InvalidArgument);
    const copied = handle.db.readObjectRange(toObjectId(req.id), req.offset, buffer) catch |err| return failDb(handle, err);
    out.* = copied;
    return okDb(handle);
}

pub fn zova_object_delete(request: ?*const zova_object_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    handle.db.deleteObject(toObjectId(req.id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_exists(request: ?*const zova_object_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasObject(toObjectId(req.id)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_object_size(request: ?*const zova_object_size_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_size orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.objectSize(toObjectId(req.id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_chunk_count(request: ?*const zova_object_chunk_count_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_count orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.objectChunkCount(toObjectId(req.id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_manifest_get(request: ?*const zova_object_manifest_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
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

    const chunker = allocator.dupeZ(u8, manifest.chunker) catch |err| {
        allocator.free(chunks);
        return failDb(handle, err);
    };

    out.* = .{
        .object_id = fromObjectId(manifest.object_id),
        .size_bytes = manifest.size_bytes,
        .chunk_count = manifest.chunk_count,
        .chunker = chunker.ptr,
        .chunks = if (chunks.len == 0) null else chunks.ptr,
        .chunks_len = chunks.len,
    };
    return okDb(handle);
}

pub fn zova_object_chunk_get(request: ?*const zova_object_chunk_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_buffer orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyBuffer();
    var chunk = handle.db.getObjectChunk(allocator, toChunkId(req.hash)) catch |err| return failDb(handle, err);
    // Transfer ownership of the allocation from zova.ObjectChunkData to zova_buffer.
    out.* = .{ .data = chunk.bytes.ptr, .len = chunk.bytes.len };
    chunk.bytes = &.{};
    return okDb(handle);
}

pub fn zova_object_chunk_put(request: ?*const zova_object_chunk_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.putObjectChunk(toChunkId(req.expected_hash), bytes) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_chunk_put_with_options(
    request: ?*const zova_object_chunk_put_with_options_request,
) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const options = objectOptionsFromAbi(req.options) orelse return failDb(handle, error.InvalidArgument);
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.putObjectChunkWithOptions(toChunkId(req.expected_hash), bytes, options) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_chunk_delete(request: ?*const zova_object_chunk_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_deleted orelse return failDb(handle, error.InvalidArgument);
    const deleted = handle.db.deleteObjectChunk(toChunkId(req.hash)) catch |err| return failDb(handle, err);
    out.* = if (deleted) 1 else 0;
    return okDb(handle);
}

pub fn zova_object_assemble_from_chunks(
    request: ?*const zova_object_assemble_from_chunks_request,
) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
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

pub fn zova_object_assemble_from_chunks_with_options(
    request: ?*const zova_object_assemble_from_chunks_with_options_request,
) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const options = objectOptionsFromAbi(req.options) orelse return failDb(handle, error.InvalidArgument);
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
    handle.db.assembleObjectFromChunksWithOptions(toObjectId(req.id), req.size_bytes, chunks, options) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_writer_create(request: ?*const zova_object_writer_create_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_writer orelse return failDb(handle, error.InvalidArgument);
    out.* = null;

    var writer = handle.db.objectWriter(allocator) catch |err| return failDb(handle, err);
    const writer_handle = allocator.create(WriterHandle) catch |err| {
        writer.deinit();
        return failDb(handle, err);
    };
    writer_handle.* = .{ .db = handle, .writer = writer };
    handle.live_writers += 1;
    out.* = @ptrCast(writer_handle);
    return okDb(handle);
}

pub fn zova_object_writer_create_with_options(
    request: ?*const zova_object_writer_create_with_options_request,
) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_writer orelse return failDb(handle, error.InvalidArgument);
    out.* = null;
    const options = objectOptionsFromAbi(req.options) orelse return failDb(handle, error.InvalidArgument);
    var writer = handle.db.objectWriterWithOptions(allocator, options) catch |err| return failDb(handle, err);
    const writer_handle = allocator.create(WriterHandle) catch |err| {
        writer.deinit();
        return failDb(handle, err);
    };
    writer_handle.* = .{ .db = handle, .writer = writer };
    handle.live_writers += 1;
    out.* = @ptrCast(writer_handle);
    return okDb(handle);
}

pub fn zova_object_writer_write(request: ?*const zova_object_writer_write_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = writerHandle(req.writer) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle.db, error.InvalidArgument);
    handle.writer.write(bytes) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_object_writer_finish(request: ?*const zova_object_writer_finish_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = writerHandle(req.writer) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_id orelse return failDb(handle.db, error.InvalidArgument);
    const id = handle.writer.finish() catch |err| return failDb(handle.db, err);
    out.* = fromObjectId(id);
    return okDb(handle.db);
}

pub fn zova_object_writer_cancel(request: ?*const zova_object_writer_cancel_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = writerHandle(req.writer) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.writer.cancel() catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_object_writer_destroy(writer: ?*zova_object_writer) callconv(.c) zova_status {
    const handle = writerHandle(writer) orelse return .INVALID_ARGUMENT;
    const db_handle = handle.db;
    db_handle.mutex.lock();
    defer db_handle.mutex.unlock();
    handle.writer.deinit();
    std.debug.assert(db_handle.live_writers > 0);
    db_handle.live_writers -= 1;
    allocator.destroy(handle);
    return okDb(db_handle);
}

pub fn zova_object_reader_create(
    request: ?*const zova_object_reader_create_request,
) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_reader orelse return failDb(handle, error.InvalidArgument);
    out.* = null;

    const reader = handle.db.objectReader(toObjectId(req.id)) catch |err| return failDb(handle, err);
    const reader_handle = allocator.create(ReaderHandle) catch |err| {
        var cleanup = reader;
        cleanup.deinit();
        return failDb(handle, err);
    };
    reader_handle.* = .{ .db = handle, .reader = reader };
    handle.live_readers += 1;
    out.* = @ptrCast(reader_handle);
    return okDb(handle);
}

pub fn zova_object_reader_read(
    request: ?*const zova_object_reader_read_request,
) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = readerHandle(req.reader) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_read orelse return failDb(handle.db, error.InvalidArgument);
    out.* = 0;
    const buffer = bytesMut(req.buffer, req.buffer_len) orelse return failDb(handle.db, error.InvalidArgument);
    const read = handle.reader.read(buffer) catch |err| return failDb(handle.db, err);
    out.* = read;
    return okDb(handle.db);
}

pub fn zova_object_reader_destroy(
    request: ?*const zova_object_reader_destroy_request,
) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const slot = req.reader orelse return .INVALID_ARGUMENT;
    const raw = slot.* orelse return .OK;
    const handle = readerHandle(raw) orelse return .INVALID_ARGUMENT;
    const db_handle = handle.db;
    db_handle.mutex.lock();
    defer db_handle.mutex.unlock();
    slot.* = null;
    handle.reader.deinit();
    std.debug.assert(db_handle.live_readers > 0);
    db_handle.live_readers -= 1;
    allocator.destroy(handle);
    return okDb(db_handle);
}
