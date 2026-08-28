//! Native object storage, manifests, chunks, range reads, and streaming writer.

const std = @import("std");
const builtin = @import("builtin");
const fastcdc = @import("object_fastcdc.zig");
const fixed_chunks = @import("object_fixed_chunks.zig");
pub const sqlite = @import("sqlite.zig");
const zova_error = @import("zova_error.zig");

pub const Error = zova_error.Error;
pub const ObjectReaderError = Error || error{ObjectReaderClosed};

const range_blob_test_metrics = struct {
    var active: usize = 0;
    var max_active: usize = 0;
};

fn testRangeBlobOpened() void {
    if (builtin.is_test) {
        range_blob_test_metrics.active += 1;
        range_blob_test_metrics.max_active = @max(
            range_blob_test_metrics.max_active,
            range_blob_test_metrics.active,
        );
    }
}

fn testRangeBlobClosed() void {
    if (builtin.is_test) {
        std.debug.assert(range_blob_test_metrics.active > 0);
        range_blob_test_metrics.active -= 1;
    }
}

/// Test-only observability for the range reader's BLOB lifetime.
pub fn resetRangeBlobTestMetrics() void {
    if (builtin.is_test) {
        range_blob_test_metrics.active = 0;
        range_blob_test_metrics.max_active = 0;
    }
}

/// Test-only maximum number of range BLOB handles held concurrently.
pub fn maxRangeBlobTestHandles() usize {
    return if (builtin.is_test) range_blob_test_metrics.max_active else 0;
}

/// Test-only current number of range BLOB handles held concurrently.
pub fn activeRangeBlobTestHandles() usize {
    return if (builtin.is_test) range_blob_test_metrics.active else 0;
}

/// Object chunking profiles used by the internal storage prototype.
///
/// The public package does not expose the option-bearing facade until the
/// format migration widens the production schema.  The internal object layer
/// can nevertheless exercise both policies against an explicitly prepared
/// fixed 1 MiB storage profile.
pub const ObjectStorageProfile = enum {
    deduplication,
    streaming,
};

pub const ObjectPutOptions = struct {
    profile: ObjectStorageProfile = .deduplication,
};

const ChunkingPolicy = enum {
    fastcdc,
    fixed_1m,

    fn fromProfile(profile: ObjectStorageProfile) ChunkingPolicy {
        return switch (profile) {
            .deduplication => .fastcdc,
            .streaming => .fixed_1m,
        };
    }

    fn version(self: ChunkingPolicy) []const u8 {
        return switch (self) {
            .fastcdc => fastcdc.version,
            .fixed_1m => fixed_chunks.version,
        };
    }

    fn maxSize(self: ChunkingPolicy) usize {
        return switch (self) {
            .fastcdc => fastcdc.max_size,
            .fixed_1m => fixed_chunks.max_size,
        };
    }

    fn cut(self: ChunkingPolicy, input: []const u8) usize {
        return switch (self) {
            .fastcdc => fastcdc.cut(input),
            .fixed_1m => fixed_chunks.cut(input),
        };
    }
};

const PolicyStreamChunk = struct {
    offset: usize,
    bytes: []const u8,
};

const PolicyStreamChunker = union(ChunkingPolicy) {
    fastcdc: fastcdc.StreamChunker,
    fixed_1m: fixed_chunks.StreamChunker,

    fn init(policy: ChunkingPolicy) PolicyStreamChunker {
        return switch (policy) {
            .fastcdc => .{ .fastcdc = .empty },
            .fixed_1m => .{ .fixed_1m = .empty },
        };
    }

    fn write(self: *PolicyStreamChunker, allocator: std.mem.Allocator, bytes: []const u8) !usize {
        return switch (self.*) {
            .fastcdc => |*chunker| chunker.write(allocator, bytes),
            .fixed_1m => |*chunker| chunker.write(allocator, bytes),
        };
    }

    fn next(self: *PolicyStreamChunker) ?PolicyStreamChunk {
        return switch (self.*) {
            .fastcdc => |*chunker| if (chunker.next()) |chunk| .{ .offset = chunk.offset, .bytes = chunk.bytes } else null,
            .fixed_1m => |*chunker| if (chunker.next()) |chunk| .{ .offset = chunk.offset, .bytes = chunk.bytes } else null,
        };
    }

    fn consume(self: *PolicyStreamChunker, allocator: std.mem.Allocator, len: usize) void {
        switch (self.*) {
            .fastcdc => |*chunker| chunker.consume(allocator, len),
            .fixed_1m => |*chunker| chunker.consume(allocator, len),
        }
    }

    fn finish(self: *PolicyStreamChunker) void {
        switch (self.*) {
            .fastcdc => |*chunker| chunker.finish(),
            .fixed_1m => |*chunker| chunker.finish(),
        }
    }

    fn isFinished(self: *const PolicyStreamChunker) bool {
        return switch (self.*) {
            .fastcdc => |chunker| chunker.finished,
            .fixed_1m => |chunker| chunker.finished,
        };
    }

    fn deinit(self: *PolicyStreamChunker, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .fastcdc => |*chunker| chunker.deinit(allocator),
            .fixed_1m => |*chunker| chunker.deinit(allocator),
        }
    }
};

pub const objects_table = "_zova_objects";
pub const chunks_table = "_zova_chunks";
pub const object_chunks_table = "_zova_object_chunks";
pub const format10_objects_schema_sql =
    \\create table _zova_objects (
    \\  object_id blob not null primary key check (length(object_id) = 32),
    \\  size_bytes integer not null check (size_bytes >= 0),
    \\  chunk_count integer not null check (chunk_count >= 0),
    \\  chunker text not null check (chunker = 'fastcdc-v1')
    \\)
;
pub const format10_chunks_schema_sql =
    \\create table _zova_chunks (
    \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
    \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
    \\  data blob not null check (length(data) = size_bytes)
    \\)
;
pub const format10_object_chunks_schema_sql =
    \\create table _zova_object_chunks (
    \\  object_id blob not null check (length(object_id) = 32),
    \\  chunk_index integer not null check (chunk_index >= 0),
    \\  chunk_hash blob not null check (length(chunk_hash) = 32),
    \\  offset integer not null check (offset >= 0),
    \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
    \\  primary key (object_id, chunk_index),
    \\  foreign key (object_id) references _zova_objects(object_id),
    \\  foreign key (chunk_hash) references _zova_chunks(chunk_hash)
    \\)
;
pub const objects_schema_sql =
    \\create table _zova_objects (
    \\  object_id blob not null primary key check (length(object_id) = 32),
    \\  size_bytes integer not null check (size_bytes >= 0),
    \\  chunk_count integer not null check (chunk_count >= 0),
    \\  chunker text not null check (chunker in ('fastcdc-v1', 'fixed-1m-v1'))
    \\)
;
pub const chunks_schema_sql =
    \\create table _zova_chunks (
    \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
    \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 1048576),
    \\  data blob not null check (length(data) = size_bytes)
    \\)
;
pub const object_chunks_schema_sql =
    \\create table _zova_object_chunks (
    \\  object_id blob not null check (length(object_id) = 32),
    \\  chunk_index integer not null check (chunk_index >= 0),
    \\  chunk_hash blob not null check (length(chunk_hash) = 32),
    \\  offset integer not null check (offset >= 0),
    \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 1048576),
    \\  primary key (object_id, chunk_index),
    \\  foreign key (object_id) references _zova_objects(object_id),
    \\  foreign key (chunk_hash) references _zova_chunks(chunk_hash)
    \\)
;

/// SHA-256 digest of full object bytes.
///
/// Zova object identity is content identity: the same bytes produce the same
/// raw 32-byte `ObjectId`.
pub const ObjectId = [32]u8;

/// SHA-256 digest of one stored object chunk.
///
/// Chunk identity is content identity for the chunk bytes. Chunk ids are stable
/// object-transfer identifiers, not application metadata.
pub const ObjectChunkId = [32]u8;

/// Compute the content identity for a Zova object.
pub fn objectId(bytes: []const u8) ObjectId {
    var digest: ObjectId = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

/// Compute the content identity for a single Zova object chunk.
///
/// The returned id is the SHA-256 digest of the chunk byte slice. This helper
/// is useful for receive-side workflows that verify chunks before complete
/// object assembly exists.
pub fn objectChunkId(bytes: []const u8) ObjectChunkId {
    var digest: ObjectChunkId = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

/// One chunk entry in an object manifest.
///
/// Indexes are 0-based. Offsets and sizes are byte counts within the full
/// logical object.
pub const ObjectChunk = struct {
    index: u64,
    hash: ObjectChunkId,
    offset: u64,
    size_bytes: u64,
};

/// Owned object manifest returned by `Database.objectManifest`.
///
/// The manifest describes the logical object layout without exposing private
/// table details. `chunker` identifies the stored physical representation.
pub const ObjectManifest = struct {
    object_id: ObjectId,
    size_bytes: u64,
    chunk_count: u64,
    chunker: []const u8,
    chunks: []ObjectChunk,

    /// Free the owned chunk slice.
    pub fn deinit(self: *ObjectManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.chunks);
    }
};

/// Owned chunk bytes returned by `Database.getObjectChunk`.
///
/// Call `deinit` with the same allocator passed to `getObjectChunk`.
pub const ObjectChunkData = struct {
    hash: ObjectChunkId,
    bytes: []u8,

    /// Free the owned chunk byte buffer.
    pub fn deinit(self: *ObjectChunkData, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

/// Owned object bytes returned by `Database.getObject`.
///
/// v0.4 reads whole objects into memory. Call `deinit` with the same allocator
/// passed to `getObject` when the bytes are no longer needed.
pub const Object = struct {
    id: ObjectId,
    bytes: []u8,

    /// Free the owned byte buffer.
    pub fn deinit(self: *Object, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

/// Sequential reader for one stored object.
///
/// The reader keeps the manifest statement active for its lifetime, pinning a
/// single SQLite read snapshot. Chunk bytes are read through one 64 KiB
/// scratch buffer and verified as they are consumed; no object-sized or
/// fixed-chunk-sized allocation is required.
pub const ObjectReader = struct {
    sqlite_db: *sqlite.Database,
    storage_schema: StorageSchema,
    id: ObjectId,
    size_bytes: u64,
    chunk_count: u64,
    policy: ChunkingPolicy,
    manifest: sqlite.Statement,
    blob: ?sqlite.Blob = null,
    expected_chunk_hash: ObjectChunkId = undefined,
    current_chunk_index: u64 = 0,
    current_chunk_offset: u64 = 0,
    current_chunk_size: u64 = 0,
    current_chunk_read: u64 = 0,
    next_chunk_index: u64 = 0,
    next_chunk_offset: u64 = 0,
    chunk_hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    object_hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    scratch: [64 * 1024]u8 = undefined,
    finished: bool = false,
    closed: bool = false,

    /// Read up to `buffer.len` bytes and advance the logical position.
    /// Returning zero means the complete object has been verified.
    pub fn read(self: *ObjectReader, buffer: []u8) ObjectReaderError!usize {
        if (self.closed) return error.ObjectReaderClosed;
        if (buffer.len == 0 or self.finished) return 0;

        return self.readInner(buffer) catch |err| {
            self.deinit();
            return err;
        };
    }

    /// Close the reader and release its snapshot/blob handles.
    pub fn deinit(self: *ObjectReader) void {
        if (self.closed) return;
        if (self.blob) |*blob| blob.deinit();
        self.blob = null;
        self.manifest.deinit();
        self.closed = true;
    }

    fn readInner(self: *ObjectReader, buffer: []u8) Error!usize {
        var written: usize = 0;
        while (written < buffer.len and !self.finished) {
            var blob = self.blob orelse return error.ObjectCorrupt;
            const remaining = self.current_chunk_size - self.current_chunk_read;
            const requested = @min(@min(remaining, @as(u64, self.scratch.len)), @as(u64, buffer.len - written));
            const requested_usize: usize = @intCast(requested);

            try blob.read(self.scratch[0..requested_usize], self.current_chunk_read);
            self.chunk_hasher.update(self.scratch[0..requested_usize]);
            self.object_hasher.update(self.scratch[0..requested_usize]);
            @memcpy(buffer[written .. written + requested_usize], self.scratch[0..requested_usize]);
            written += requested_usize;
            self.current_chunk_read += requested;

            if (self.current_chunk_read == self.current_chunk_size) {
                var chunk_digest: ObjectChunkId = undefined;
                var chunk_hasher = self.chunk_hasher;
                chunk_hasher.final(&chunk_digest);
                if (!std.mem.eql(u8, &chunk_digest, &self.expected_chunk_hash)) return error.ObjectCorrupt;

                self.blob.?.deinit();
                self.blob = null;
                try self.loadNextChunk();
            }
        }
        return written;
    }

    fn loadNextChunk(self: *ObjectReader) Error!void {
        switch (try self.manifest.step()) {
            .row => {
                const raw_index = self.manifest.columnInt64(0);
                if (raw_index < 0 or @as(u64, @intCast(raw_index)) != self.next_chunk_index) return error.ObjectCorrupt;

                const raw_hash = self.manifest.columnBlob(1);
                if (raw_hash.len != @sizeOf(ObjectChunkId)) return error.ObjectCorrupt;
                @memcpy(&self.expected_chunk_hash, raw_hash);

                const offset = try sqliteI64ToU64(self.manifest.columnInt64(2));
                const size = try sqliteI64ToU64(self.manifest.columnInt64(3));
                if (offset != self.next_chunk_offset or size == 0 or size > self.policy.maxSize()) return error.ObjectCorrupt;
                if (self.policy == .fixed_1m and self.next_chunk_index + 1 < self.chunk_count and size != fixed_chunks.chunk_size) {
                    return error.ObjectCorrupt;
                }
                if (offset > self.size_bytes or size > self.size_bytes - offset) return error.ObjectCorrupt;
                if (self.manifest.columnType(4) == .null) return error.ObjectCorrupt;

                const rowid = self.manifest.columnInt64(4);
                if (rowid <= 0) return error.ObjectCorrupt;
                var next_blob = try sqlite.Blob.open(
                    self.sqlite_db,
                    self.storage_schema.sqliteName(),
                    "_zova_chunks",
                    "data",
                    rowid,
                );
                errdefer next_blob.deinit();
                if (try next_blob.bytes() != size) return error.ObjectCorrupt;

                self.current_chunk_index = self.next_chunk_index;
                self.current_chunk_offset = offset;
                self.current_chunk_size = size;
                self.current_chunk_read = 0;
                self.chunk_hasher = std.crypto.hash.sha2.Sha256.init(.{});
                self.next_chunk_index += 1;
                self.next_chunk_offset += size;
                self.blob = next_blob;
            },
            .done => {
                if (self.next_chunk_index != self.chunk_count or self.next_chunk_offset != self.size_bytes) return error.ObjectCorrupt;
                if (self.policy == .fixed_1m and self.chunk_count != fixed_chunks.countForSize(self.size_bytes)) return error.ObjectCorrupt;

                var digest: ObjectId = undefined;
                var hasher = self.object_hasher;
                hasher.final(&digest);
                if (!std.mem.eql(u8, &digest, &self.id)) return error.ObjectCorrupt;
                self.finished = true;
            },
        }
    }
};

pub const StorageSchema = enum {
    main,
    object_store,

    pub fn prefix(self: StorageSchema) []const u8 {
        return switch (self) {
            .main => "main.",
            .object_store => "object_store.",
        };
    }

    fn sqliteName(self: StorageSchema) [:0]const u8 {
        return switch (self) {
            .main => "main",
            .object_store => "object_store",
        };
    }
};

/// Incremental writer for one content-addressed Zova object.
///
/// `ObjectWriter` accepts arbitrary byte slices, emits FastCDC-v1 chunks as
/// they become available, stores those chunks as verified loose chunks, and
/// assembles the final object on `finish`. It does not keep the full object in
/// memory and it does not hold a SQLite transaction open across `write` calls.
/// The writer must be deinitialized; unfinished writers auto-cancel.
pub const ObjectWriter = struct {
    sqlite_db: *sqlite.Database,
    storage_schema: StorageSchema = .main,
    allow_active_transactions: bool = false,
    allocator: std.mem.Allocator,
    policy: ChunkingPolicy = .fastcdc,
    chunker: PolicyStreamChunker = .{ .fastcdc = .empty },
    hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    size_bytes: u64 = 0,
    chunks: std.ArrayList(ObjectChunk) = .empty,
    seen_chunks: std.ArrayList(ObjectChunkId) = .empty,
    closed: bool = false,

    /// Retained metadata allocation sizes for the internal object benchmark.
    /// This is intentionally not re-exported through the package facade.
    pub const DescriptorMetrics = struct {
        chunks_len: usize,
        chunks_capacity: usize,
        seen_chunks_len: usize,
        seen_chunks_capacity: usize,
        chunker_buffer_capacity: usize,
    };

    fn init(
        sqlite_db: *sqlite.Database,
        storage_schema: StorageSchema,
        allow_active_transactions: bool,
        allocator: std.mem.Allocator,
        policy: ChunkingPolicy,
    ) ObjectWriter {
        return .{
            .sqlite_db = sqlite_db,
            .storage_schema = storage_schema,
            .allow_active_transactions = allow_active_transactions,
            .allocator = allocator,
            .policy = policy,
            .chunker = PolicyStreamChunker.init(policy),
            .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
        };
    }

    fn database(self: *ObjectWriter) Database {
        return .{
            .sqlite_db = self.sqlite_db,
            .storage_schema = self.storage_schema,
            .allow_active_transactions = self.allow_active_transactions,
        };
    }

    /// Report the writer's retained descriptor capacities for diagnostics.
    /// The arrays remain owned by the writer and are not copied.
    pub fn descriptorMetrics(self: *const ObjectWriter) DescriptorMetrics {
        const chunker_buffer_capacity = switch (self.chunker) {
            .fastcdc => |chunker| chunker.buffer.capacity,
            .fixed_1m => |chunker| chunker.buffer.capacity,
        };
        return .{
            .chunks_len = self.chunks.items.len,
            .chunks_capacity = self.chunks.capacity,
            .seen_chunks_len = self.seen_chunks.items.len,
            .seen_chunks_capacity = self.seen_chunks.capacity,
            .chunker_buffer_capacity = chunker_buffer_capacity,
        };
    }

    /// Append bytes to the streamed object.
    ///
    /// Empty writes are no-ops. Non-empty writes may be split into several
    /// FastCDC chunks internally. Single-file writers reject active caller
    /// transactions; bound object-store writers may join them through the
    /// attached object-store schema.
    pub fn write(self: *ObjectWriter, bytes: []const u8) Error!void {
        if (self.closed) return error.ObjectWriterClosed;
        if (self.chunker.isFinished()) return error.ObjectWriterClosed;
        try rejectActiveTransaction(self.sqlite_db, self.allow_active_transactions);
        if (bytes.len == 0) return;

        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.drainReadyChunks();

            const accepted = try self.chunker.write(self.allocator, bytes[offset..]);
            if (accepted == 0) {
                try self.drainReadyChunks();
                continue;
            }

            try self.addSize(accepted);
            self.hasher.update(bytes[offset .. offset + accepted]);
            offset += accepted;
        }

        try self.drainReadyChunks();
    }

    /// Finish the stream and return the object's content id.
    ///
    /// The final object id is SHA-256 of all bytes written. If the same valid
    /// object already exists, `finish` returns that id successfully, matching
    /// `Database.putObject`. After `finish`, all writer operations return
    /// `error.ObjectWriterClosed`; call `deinit` to free writer-owned buffers.
    pub fn finish(self: *ObjectWriter) Error!ObjectId {
        if (self.closed) return error.ObjectWriterClosed;
        try rejectActiveTransaction(self.sqlite_db, self.allow_active_transactions);

        self.chunker.finish();
        try self.drainReadyChunks();
        var db = self.database();

        var final_hasher = self.hasher;
        var id: ObjectId = undefined;
        final_hasher.final(&id);

        db.assembleObjectFromChunksWithPolicy(id, self.size_bytes, self.chunks.items, self.policy) catch |err| switch (err) {
            error.ObjectAlreadyExists => {
                try self.ensureExistingObjectIsValid(id);
            },
            else => return err,
        };

        try self.deleteUnreferencedSeenChunks();
        self.closed = true;
        return id;
    }

    /// Cancel an unfinished writer and remove unreferenced chunks it stored.
    ///
    /// Chunks already referenced by completed objects are preserved. After
    /// cancellation, all writer operations return `error.ObjectWriterClosed`.
    pub fn cancel(self: *ObjectWriter) Error!void {
        if (self.closed) return error.ObjectWriterClosed;
        try rejectActiveTransaction(self.sqlite_db, self.allow_active_transactions);

        try self.deleteUnreferencedSeenChunks();
        self.closed = true;
    }

    /// Free writer-owned buffers.
    ///
    /// If the writer has not been finished or cancelled, `deinit` attempts to
    /// cancel it first and deliberately ignores cleanup errors.
    pub fn deinit(self: *ObjectWriter) void {
        if (!self.closed) {
            self.cancel() catch {};
        }
        self.chunker.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.seen_chunks.deinit(self.allocator);
    }

    fn drainReadyChunks(self: *ObjectWriter) Error!void {
        while (self.chunker.next()) |chunk| {
            try self.storeChunk(chunk);
            self.chunker.consume(self.allocator, chunk.bytes.len);
        }
    }

    fn storeChunk(self: *ObjectWriter, chunk: PolicyStreamChunk) Error!void {
        std.debug.assert(chunk.bytes.len > 0);
        std.debug.assert(chunk.bytes.len <= self.policy.maxSize());

        const hash = objectChunkId(chunk.bytes);
        var db = self.database();
        const already_stored = already_stored: {
            var existing = db.getObjectChunkWithPolicy(self.allocator, hash, self.policy) catch |err| switch (err) {
                error.ObjectChunkNotFound => break :already_stored false,
                else => return err,
            };
            existing.deinit(self.allocator);
            break :already_stored true;
        };

        try db.putObjectChunkWithPolicy(hash, chunk.bytes, self.policy);
        if (!already_stored) try self.rememberSeenChunk(hash);
        try self.chunks.append(self.allocator, .{
            .index = @intCast(self.chunks.items.len),
            .hash = hash,
            .offset = @intCast(chunk.offset),
            .size_bytes = @intCast(chunk.bytes.len),
        });
    }

    fn rememberSeenChunk(self: *ObjectWriter, hash: ObjectChunkId) Error!void {
        for (self.seen_chunks.items) |seen_hash| {
            if (std.mem.eql(u8, &seen_hash, &hash)) return;
        }
        try self.seen_chunks.append(self.allocator, hash);
    }

    fn deleteUnreferencedSeenChunks(self: *ObjectWriter) Error!void {
        var db = self.database();
        for (self.seen_chunks.items) |hash| {
            _ = try db.deleteObjectChunk(hash);
        }
    }

    fn ensureExistingObjectIsValid(self: *ObjectWriter, id: ObjectId) Error!void {
        var db = self.database();
        var manifest = db.objectManifest(self.allocator, id) catch |err| switch (err) {
            error.ObjectNotFound, error.ObjectCorrupt => return error.ObjectCorrupt,
            else => return err,
        };
        defer manifest.deinit(self.allocator);

        const existing_policy = policyFromVersion(manifest.chunker) orelse return error.ObjectCorrupt;

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var total_size: u64 = 0;
        for (manifest.chunks) |chunk| {
            var chunk_data = db.getObjectChunkWithPolicy(self.allocator, chunk.hash, existing_policy) catch |err| switch (err) {
                error.ObjectChunkNotFound, error.ObjectCorrupt => return error.ObjectCorrupt,
                else => return err,
            };

            if (@as(u64, @intCast(chunk_data.bytes.len)) != chunk.size_bytes) {
                chunk_data.deinit(self.allocator);
                return error.ObjectCorrupt;
            }

            hasher.update(chunk_data.bytes);
            total_size += chunk.size_bytes;
            chunk_data.deinit(self.allocator);
        }

        if (total_size != manifest.size_bytes) return error.ObjectCorrupt;

        var digest: ObjectId = undefined;
        hasher.final(&digest);
        if (!std.mem.eql(u8, &digest, &id)) return error.ObjectCorrupt;
    }

    fn addSize(self: *ObjectWriter, len: usize) Error!void {
        const amount: u64 = @intCast(len);
        const max_size: u64 = @intCast(std.math.maxInt(i64));
        if (amount > max_size - self.size_bytes) return error.ObjectTooLarge;
        self.size_bytes += amount;
    }
};

pub const Database = struct {
    sqlite_db: *sqlite.Database,
    storage_schema: StorageSchema = .main,
    allow_active_transactions: bool = false,

    /// Construct an object-layer handle over an explicitly prepared schema.
    ///
    /// This is intentionally not re-exported by the package facade. It lets
    /// focused storage tests construct an object-layer handle directly.
    pub fn initForPrototype(
        sqlite_db: *sqlite.Database,
        storage_schema: StorageSchema,
    ) Database {
        return .{
            .sqlite_db = sqlite_db,
            .storage_schema = storage_schema,
        };
    }

    fn prepareSchema(self: *Database, comptime sql_format: []const u8, args: anytype) Error!sqlite.Statement {
        var sql_buffer: [4096]u8 = undefined;
        const sql = std.fmt.bufPrintZ(&sql_buffer, sql_format, args) catch return error.SqliteError;
        return try self.sqlite_db.prepare(sql);
    }

    /// Create an incremental object writer for this database connection.
    ///
    /// The writer streams bytes through FastCDC-v1, stores verified loose
    /// chunks as they are emitted, and assembles the final content-addressed
    /// object on `ObjectWriter.finish`. By default writer operations reject
    /// active caller-owned transactions; the Zova facade enables ambient
    /// transaction participation only for attached bound object stores.
    pub fn objectWriter(self: *Database, allocator: std.mem.Allocator) Error!ObjectWriter {
        try rejectActiveTransaction(self.sqlite_db, self.allow_active_transactions);
        return ObjectWriter.init(self.sqlite_db, self.storage_schema, self.allow_active_transactions, allocator, .fastcdc);
    }

    /// Open a sequential reader over one object and pin its SQLite snapshot.
    /// The reader keeps one manifest statement active until EOF or `deinit`.
    pub fn objectReader(self: *Database, id: ObjectId) Error!ObjectReader {
        const metadata = try loadObjectMetadata(self.sqlite_db, self.storage_schema, id);
        const size_bytes = try sqliteI64ToU64(metadata.size_bytes);
        const chunk_count = try sqliteI64ToU64(metadata.chunk_count);
        var manifest = try self.prepareSchema(
            \\select oc.chunk_index, oc.chunk_hash, oc.offset, oc.size_bytes, c.rowid
            \\from {s}_zova_object_chunks oc
            \\left join {s}_zova_chunks c on c.chunk_hash = oc.chunk_hash
            \\where oc.object_id = ?
            \\order by oc.chunk_index asc
        , .{ self.storage_schema.prefix(), self.storage_schema.prefix() });
        errdefer manifest.deinit();
        try manifest.bindBlob(1, &id);

        var reader = ObjectReader{
            .sqlite_db = self.sqlite_db,
            .storage_schema = self.storage_schema,
            .id = id,
            .size_bytes = size_bytes,
            .chunk_count = chunk_count,
            .policy = metadata.policy,
            .manifest = manifest,
        };
        errdefer reader.deinit();
        try reader.loadNextChunk();
        return reader;
    }

    /// Create an object writer for an explicitly selected internal profile.
    ///
    /// The package facade exposes this through the public storage profile.
    pub fn objectWriterWithOptions(self: *Database, allocator: std.mem.Allocator, options: ObjectPutOptions) Error!ObjectWriter {
        try rejectActiveTransaction(self.sqlite_db, self.allow_active_transactions);
        return ObjectWriter.init(
            self.sqlite_db,
            self.storage_schema,
            self.allow_active_transactions,
            allocator,
            ChunkingPolicy.fromProfile(options.profile),
        );
    }

    /// Store raw bytes as a content-addressed Zova object.
    ///
    /// The returned id is the SHA-256 digest of the full byte slice. By
    /// default this owns its own transaction and returns
    /// `error.ObjectTransactionActive` inside a user transaction. The Zova
    /// facade enables ambient transaction participation for attached bound
    /// object stores.
    pub fn putObject(self: *Database, bytes: []const u8) Error!ObjectId {
        return self.putObjectWithOptions(bytes, .{ .profile = .deduplication });
    }

    /// Store bytes using an explicitly selected internal chunking profile.
    ///
    /// Existing callers continue to use `putObject` and FastCDC-v1 unless
    /// they explicitly select the streaming profile.
    pub fn putObjectWithOptions(self: *Database, bytes: []const u8, options: ObjectPutOptions) Error!ObjectId {
        const policy = ChunkingPolicy.fromProfile(options.profile);
        const id = objectId(bytes);
        const size_bytes = try usizeToSqliteI64(bytes.len);
        const chunk_count = try usizeToSqliteI64(countObjectChunks(policy, bytes));

        const owns_transaction = try beginOwnedWrite(self.sqlite_db, self.allow_active_transactions);
        var committed = false;
        errdefer if (!committed and owns_transaction) self.sqlite_db.rollback() catch {};

        if (try objectRowExists(self.sqlite_db, self.storage_schema, id)) {
            // Loading metadata validates the stored representation identifier;
            // the existing object remains authoritative and is never repacked
            // to satisfy the newly requested policy.
            _ = try loadObjectMetadata(self.sqlite_db, self.storage_schema, id);
            if (owns_transaction) try self.sqlite_db.commit();
            committed = true;
            return id;
        }

        try insertObjectRow(self.sqlite_db, self.storage_schema, id, size_bytes, chunk_count, policy);

        var inserts = try ObjectInsertStatements.init(self.sqlite_db, self.storage_schema);
        defer inserts.deinit();

        var offset: usize = 0;
        var chunk_index: i64 = 0;
        while (offset < bytes.len) {
            const chunk_len = policy.cut(bytes[offset..]);
            const chunk = bytes[offset .. offset + chunk_len];
            const chunk_hash = objectId(chunk);
            try inserts.insertChunk(chunk_hash, chunk);
            try inserts.insertManifest(
                id,
                chunk_index,
                chunk_hash,
                try usizeToSqliteI64(offset),
                try usizeToSqliteI64(chunk_len),
            );
            offset += chunk_len;
            chunk_index += 1;
        }

        if (owns_transaction) try self.sqlite_db.commit();
        committed = true;
        return id;
    }

    /// Load and verify an object by id.
    ///
    /// The returned object owns an allocated byte buffer. Missing ids return
    /// `error.ObjectNotFound`. Broken private object rows return
    /// `error.ObjectCorrupt` rather than being repaired.
    pub fn getObject(self: *Database, allocator: std.mem.Allocator, id: ObjectId) Error!Object {
        const metadata = try loadObjectMetadata(self.sqlite_db, self.storage_schema, id);
        const size = try sqliteI64ToUsize(metadata.size_bytes);
        const chunk_count = try sqliteI64ToUsize(metadata.chunk_count);
        var bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);

        if (chunk_count == 0) {
            if (size != 0) return error.ObjectCorrupt;
            if (!std.mem.eql(u8, &objectId(bytes), &id)) return error.ObjectCorrupt;
            return .{ .id = id, .bytes = bytes };
        }

        var manifest = try self.prepareSchema(
            \\select oc.chunk_index, oc.chunk_hash, oc.offset, oc.size_bytes, c.data
            \\from {s}_zova_object_chunks oc
            \\left join {s}_zova_chunks c on c.chunk_hash = oc.chunk_hash
            \\where oc.object_id = ?
            \\order by oc.chunk_index asc
        , .{ self.storage_schema.prefix(), self.storage_schema.prefix() });
        defer manifest.deinit();

        try manifest.bindBlob(1, &id);

        var expected_index: i64 = 0;
        var expected_offset: usize = 0;
        while ((try manifest.step()) == .row) {
            if (manifest.columnInt64(0) != expected_index) return error.ObjectCorrupt;

            const chunk_hash = manifest.columnBlob(1);
            if (chunk_hash.len != @sizeOf(ObjectId)) return error.ObjectCorrupt;

            const offset = try sqliteI64ToUsize(manifest.columnInt64(2));
            const chunk_size = try sqliteI64ToUsize(manifest.columnInt64(3));
            if (offset != expected_offset) return error.ObjectCorrupt;
            if (chunk_size == 0 or chunk_size > metadata.policy.maxSize()) return error.ObjectCorrupt;
            if (metadata.policy == .fixed_1m and expected_index + 1 < chunk_count and chunk_size != fixed_chunks.chunk_size) {
                return error.ObjectCorrupt;
            }
            if (offset > bytes.len or chunk_size > bytes.len - offset) return error.ObjectCorrupt;
            if (manifest.columnType(4) == .null) return error.ObjectCorrupt;

            const chunk_data = manifest.columnBlob(4);
            if (chunk_data.len != chunk_size) return error.ObjectCorrupt;
            const actual_chunk_hash = objectId(chunk_data);
            if (!std.mem.eql(u8, &actual_chunk_hash, chunk_hash)) return error.ObjectCorrupt;

            @memcpy(bytes[offset .. offset + chunk_size], chunk_data);
            expected_offset += chunk_size;
            expected_index += 1;
        }

        if (expected_index != @as(i64, @intCast(chunk_count))) return error.ObjectCorrupt;
        if (expected_offset != bytes.len) return error.ObjectCorrupt;
        if (metadata.policy == .fixed_1m and chunk_count != (bytes.len + fixed_chunks.chunk_size - 1) / fixed_chunks.chunk_size) {
            return error.ObjectCorrupt;
        }
        if (!std.mem.eql(u8, &objectId(bytes), &id)) return error.ObjectCorrupt;

        return .{ .id = id, .bytes = bytes };
    }

    /// Read a byte range from a logical object into a caller-provided buffer.
    ///
    /// This is the v0.6 object serving path: it avoids object-sized
    /// allocation, reads only the chunks that overlap the requested range, and
    /// verifies every touched chunk by SHA-256 before copying bytes. `offset`
    /// is a 0-based byte offset in the full object. Offsets past the end
    /// return `error.ObjectRangeInvalid`; offsets at the end return `0`.
    /// Full-object reads additionally verify the final full-object SHA-256.
    pub fn readObjectRange(self: *Database, id: ObjectId, offset: u64, buffer: []u8) Error!usize {
        const metadata = try loadObjectMetadata(self.sqlite_db, self.storage_schema, id);
        const size = try sqliteI64ToU64(metadata.size_bytes);
        const chunk_count = try sqliteI64ToU64(metadata.chunk_count);

        const max_chunk_count = switch (metadata.policy) {
            .fastcdc => size,
            .fixed_1m => fixed_chunks.countForSize(size),
        };
        if ((size != 0 and chunk_count == 0) or chunk_count > max_chunk_count) return error.ObjectCorrupt;

        if (offset > size) return error.ObjectRangeInvalid;

        const available = size - offset;
        const read_len_u64 = @min(available, @as(u64, @intCast(buffer.len)));
        if (read_len_u64 == 0) return 0;

        if (chunk_count == 0) {
            if (size != 0) return error.ObjectCorrupt;
            if (!std.mem.eql(u8, &objectId(""), &id)) return error.ObjectCorrupt;
            return 0;
        }

        const read_end = offset + read_len_u64;
        const full_read = offset == 0 and read_len_u64 == size;
        if (full_read) try validateObjectManifestShape(self.sqlite_db, self.storage_schema, id, size, chunk_count, metadata.policy);

        var chunks = if (metadata.policy == .fixed_1m)
            try self.prepareSchema(
                \\select oc.chunk_index, oc.chunk_hash, oc.offset, oc.size_bytes, c.rowid
                \\from {s}_zova_object_chunks oc
                \\left join {s}_zova_chunks c on c.chunk_hash = oc.chunk_hash
                \\where oc.object_id = ?
                \\  and oc.chunk_index between ? and ?
                \\order by oc.chunk_index asc
            , .{ self.storage_schema.prefix(), self.storage_schema.prefix() })
        else
            try self.prepareSchema(
                \\select oc.chunk_index, oc.chunk_hash, oc.offset, oc.size_bytes, c.rowid
                \\from {s}_zova_object_chunks oc
                \\left join {s}_zova_chunks c on c.chunk_hash = oc.chunk_hash
                \\where oc.object_id = ?
                \\  and oc.offset + oc.size_bytes > ?
                \\  and oc.offset < ?
                \\order by oc.chunk_index asc
            , .{ self.storage_schema.prefix(), self.storage_schema.prefix() });
        defer chunks.deinit();

        try chunks.bindBlob(1, &id);
        if (metadata.policy == .fixed_1m) {
            const first_index = offset / fixed_chunks.chunk_size;
            const last_index = (read_end - 1) / fixed_chunks.chunk_size;
            try chunks.bindInt64(2, try u64ToSqliteI64(first_index));
            try chunks.bindInt64(3, try u64ToSqliteI64(last_index));
        } else {
            try chunks.bindInt64(2, try u64ToSqliteI64(offset));
            try chunks.bindInt64(3, try u64ToSqliteI64(read_end));
        }

        var scratch: [64 * 1024]u8 = undefined;
        var copied: usize = 0;
        while ((try chunks.step()) == .row) {
            const raw_index = chunks.columnInt64(0);
            if (raw_index < 0) return error.ObjectCorrupt;
            const chunk_index: u64 = @intCast(raw_index);

            const raw_hash = chunks.columnBlob(1);
            if (raw_hash.len != @sizeOf(ObjectChunkId)) return error.ObjectCorrupt;
            var expected_hash: ObjectChunkId = undefined;
            @memcpy(&expected_hash, raw_hash);

            const chunk_offset = try sqliteI64ToU64(chunks.columnInt64(2));
            const chunk_size = try sqliteI64ToU64(chunks.columnInt64(3));
            if (chunk_size == 0 or chunk_size > metadata.policy.maxSize()) return error.ObjectCorrupt;
            if (metadata.policy == .fixed_1m) {
                if (chunk_index > std.math.maxInt(u64) / fixed_chunks.chunk_size) return error.ObjectCorrupt;
                if (chunk_offset != chunk_index * fixed_chunks.chunk_size) return error.ObjectCorrupt;
                if (chunk_index + 1 < chunk_count and chunk_size != fixed_chunks.chunk_size) return error.ObjectCorrupt;
            }
            if (chunk_offset > size or chunk_size > size - chunk_offset) return error.ObjectCorrupt;

            if (chunks.columnType(4) == .null) return error.ObjectCorrupt;
            const rowid = chunks.columnInt64(4);
            if (rowid <= 0) return error.ObjectCorrupt;
            const chunk_copied = blk: {
                var blob = try sqlite.Blob.open(
                    self.sqlite_db,
                    self.storage_schema.sqliteName(),
                    "_zova_chunks",
                    "data",
                    rowid,
                );
                testRangeBlobOpened();
                defer {
                    blob.deinit();
                    testRangeBlobClosed();
                }
                if (try blob.bytes() != chunk_size) return error.ObjectCorrupt;

                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                var chunk_read: u64 = 0;
                var chunk_copied: usize = 0;
                while (chunk_read < chunk_size) {
                    const remaining = chunk_size - chunk_read;
                    const read_size: usize = @intCast(@min(remaining, @as(u64, scratch.len)));
                    try blob.read(scratch[0..read_size], chunk_read);
                    hasher.update(scratch[0..read_size]);

                    const part_start = chunk_offset + chunk_read;
                    const part_end = part_start + read_size;
                    const copy_start = @max(offset, part_start);
                    const copy_end = @min(read_end, part_end);
                    if (copy_start < copy_end) {
                        const src_start: usize = @intCast(copy_start - part_start);
                        const dest_start: usize = @intCast(copy_start - offset);
                        const copy_len: usize = @intCast(copy_end - copy_start);
                        @memcpy(buffer[dest_start .. dest_start + copy_len], scratch[src_start .. src_start + copy_len]);
                        chunk_copied += copy_len;
                    }
                    chunk_read += read_size;
                }

                var actual_chunk_hash: ObjectChunkId = undefined;
                hasher.final(&actual_chunk_hash);
                if (!std.mem.eql(u8, &actual_chunk_hash, &expected_hash)) return error.ObjectCorrupt;
                break :blk chunk_copied;
            };
            copied += chunk_copied;
        }

        if (copied != @as(usize, @intCast(read_len_u64))) return error.ObjectCorrupt;
        if (full_read and !std.mem.eql(u8, &objectId(buffer[0..copied]), &id)) {
            return error.ObjectCorrupt;
        }

        return copied;
    }

    /// Return the public manifest for one object.
    ///
    /// The manifest validates object/chunk ordering, offsets, sizes, and chunk
    /// row presence. It does not hash every chunk byte; use `getObjectChunk`
    /// or `getObject` when byte-level verification is required.
    pub fn objectManifest(
        self: *Database,
        allocator: std.mem.Allocator,
        id: ObjectId,
    ) Error!ObjectManifest {
        const metadata = try loadObjectMetadata(self.sqlite_db, self.storage_schema, id);
        const size = try sqliteI64ToU64(metadata.size_bytes);
        const chunk_count = try sqliteI64ToU64(metadata.chunk_count);

        if (chunk_count == 0) {
            if (size != 0) return error.ObjectCorrupt;
            if (!std.mem.eql(u8, &objectId(""), &id)) return error.ObjectCorrupt;
            return .{
                .object_id = id,
                .size_bytes = 0,
                .chunk_count = 0,
                .chunker = metadata.policy.version(),
                .chunks = try allocator.alloc(ObjectChunk, 0),
            };
        }

        if (chunk_count > size) return error.ObjectCorrupt;
        if (try countObjectManifestRows(self.sqlite_db, self.storage_schema, id) != chunk_count) return error.ObjectCorrupt;

        const chunk_len = try sqliteI64ToUsize(metadata.chunk_count);
        var chunks = try allocator.alloc(ObjectChunk, chunk_len);
        errdefer allocator.free(chunks);

        var manifest = try self.prepareSchema(
            \\select oc.chunk_index, oc.chunk_hash, oc.offset, oc.size_bytes, c.size_bytes
            \\from {s}_zova_object_chunks oc
            \\left join {s}_zova_chunks c on c.chunk_hash = oc.chunk_hash
            \\where oc.object_id = ?
            \\order by oc.chunk_index asc
        , .{ self.storage_schema.prefix(), self.storage_schema.prefix() });
        defer manifest.deinit();

        try manifest.bindBlob(1, &id);

        var expected_index: u64 = 0;
        var expected_offset: u64 = 0;
        while ((try manifest.step()) == .row) {
            if (expected_index >= chunks.len) return error.ObjectCorrupt;

            const chunk_index = try sqliteI64ToU64(manifest.columnInt64(0));
            if (chunk_index != expected_index) return error.ObjectCorrupt;

            const raw_hash = manifest.columnBlob(1);
            if (raw_hash.len != @sizeOf(ObjectChunkId)) return error.ObjectCorrupt;
            var chunk_hash: ObjectChunkId = undefined;
            @memcpy(&chunk_hash, raw_hash);

            const offset = try sqliteI64ToU64(manifest.columnInt64(2));
            const chunk_size = try sqliteI64ToU64(manifest.columnInt64(3));
            if (offset != expected_offset) return error.ObjectCorrupt;
            if (chunk_size == 0 or chunk_size > metadata.policy.maxSize()) return error.ObjectCorrupt;
            if (offset > size or chunk_size > size - offset) return error.ObjectCorrupt;
            if (manifest.columnType(4) == .null) return error.ObjectCorrupt;

            const stored_chunk_size = try sqliteI64ToU64(manifest.columnInt64(4));
            if (stored_chunk_size != chunk_size) return error.ObjectCorrupt;

            chunks[@intCast(expected_index)] = .{
                .index = chunk_index,
                .hash = chunk_hash,
                .offset = offset,
                .size_bytes = chunk_size,
            };

            expected_offset += chunk_size;
            expected_index += 1;
        }

        if (expected_index != chunk_count) return error.ObjectCorrupt;
        if (expected_offset != size) return error.ObjectCorrupt;
        if (!validateManifestPolicyShape(size, chunks, metadata.policy)) return error.ObjectCorrupt;

        return .{
            .object_id = id,
            .size_bytes = size,
            .chunk_count = chunk_count,
            .chunker = metadata.policy.version(),
            .chunks = chunks,
        };
    }

    /// Return whether a stored object chunk exists by chunk hash.
    pub fn hasObjectChunk(self: *Database, hash: ObjectChunkId) Error!bool {
        var stmt = try self.prepareSchema(
            "select 1 from {s}_zova_chunks where chunk_hash = ? limit 1",
            .{self.storage_schema.prefix()},
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, &hash);
        return switch (try stmt.step()) {
            .row => true,
            .done => false,
        };
    }

    /// Store one verified loose object chunk.
    ///
    /// `expected_hash` must be `objectChunkId(bytes)`. Empty chunks and chunks
    /// larger than FastCDC's maximum chunk size are rejected as
    /// `error.ObjectCorrupt`; hash mismatches return
    /// `error.ObjectChunkHashMismatch`. Existing valid chunks are accepted
    /// idempotently, and existing malformed chunk rows return
    /// `error.ObjectCorrupt` instead of being overwritten.
    ///
    /// This method stores only `_zova_chunks` rows. It does not create objects,
    /// manifests, transfer sessions, or user metadata, and it may run inside a
    /// caller-owned SQLite transaction.
    pub fn putObjectChunk(self: *Database, expected_hash: ObjectChunkId, bytes: []const u8) Error!void {
        return self.putObjectChunkWithPolicy(expected_hash, bytes, .fastcdc);
    }

    /// Store one verified loose chunk for an explicitly selected internal
    /// profile.
    pub fn putObjectChunkWithOptions(
        self: *Database,
        expected_hash: ObjectChunkId,
        bytes: []const u8,
        options: ObjectPutOptions,
    ) Error!void {
        return self.putObjectChunkWithPolicy(expected_hash, bytes, ChunkingPolicy.fromProfile(options.profile));
    }

    fn putObjectChunkWithPolicy(
        self: *Database,
        expected_hash: ObjectChunkId,
        bytes: []const u8,
        policy: ChunkingPolicy,
    ) Error!void {
        if (bytes.len == 0 or bytes.len > policy.maxSize()) return error.ObjectCorrupt;
        const actual_hash = objectChunkId(bytes);
        if (!std.mem.eql(u8, &actual_hash, &expected_hash)) return error.ObjectChunkHashMismatch;

        var existing = self.getObjectChunkWithPolicy(std.heap.page_allocator, expected_hash, policy) catch |err| switch (err) {
            error.ObjectChunkNotFound => {
                try insertChunkRow(self.sqlite_db, self.storage_schema, expected_hash, bytes);
                return;
            },
            else => return err,
        };
        existing.deinit(std.heap.page_allocator);
    }

    /// Assemble a complete object from existing verified chunks.
    ///
    /// The supplied `chunks` are a public manifest, not bytes. Every referenced
    /// chunk must already exist in `_zova_chunks`, usually through
    /// `putObjectChunk` or another object. Zova validates manifest shape,
    /// verifies every stored chunk hash, streams the chunk bytes through
    /// SHA-256, and requires the final digest to equal `id` before writing the
    /// object row and manifest rows.
    ///
    /// Assembly owns a `begin immediate` transaction by default and returns
    /// `error.ObjectTransactionActive` inside caller-owned transactions unless
    /// the database wrapper explicitly allows ambient transactions. Existing
    /// valid objects return `error.ObjectAlreadyExists`; invalid caller
    /// manifests return `error.ObjectManifestInvalid`.
    pub fn assembleObjectFromChunks(
        self: *Database,
        id: ObjectId,
        size_bytes: u64,
        chunks: []const ObjectChunk,
    ) Error!void {
        return self.assembleObjectFromChunksWithPolicy(id, size_bytes, chunks, .fastcdc);
    }

    /// Assemble an object using an explicitly selected internal profile.
    /// Fixed manifests are accepted only by an explicitly prepared prototype
    /// schema; the ordinary assembly path remains FastCDC-only.
    pub fn assembleObjectFromChunksWithOptions(
        self: *Database,
        id: ObjectId,
        size_bytes: u64,
        chunks: []const ObjectChunk,
        options: ObjectPutOptions,
    ) Error!void {
        return self.assembleObjectFromChunksWithPolicy(
            id,
            size_bytes,
            chunks,
            ChunkingPolicy.fromProfile(options.profile),
        );
    }

    fn assembleObjectFromChunksWithPolicy(
        self: *Database,
        id: ObjectId,
        size_bytes: u64,
        chunks: []const ObjectChunk,
        policy: ChunkingPolicy,
    ) Error!void {
        const owns_transaction = try beginOwnedWrite(self.sqlite_db, self.allow_active_transactions);
        var committed = false;
        errdefer if (!committed and owns_transaction) self.sqlite_db.rollback() catch {};

        if (try objectRowExists(self.sqlite_db, self.storage_schema, id)) {
            var existing = self.getObject(std.heap.page_allocator, id) catch |err| switch (err) {
                error.ObjectNotFound, error.ObjectCorrupt => return error.ObjectCorrupt,
                else => return err,
            };
            existing.deinit(std.heap.page_allocator);
            return error.ObjectAlreadyExists;
        }

        const sorted_chunks = try self.validateAssemblyChunks(std.heap.page_allocator, id, size_bytes, chunks, policy);
        defer std.heap.page_allocator.free(sorted_chunks);

        try insertObjectRow(
            self.sqlite_db,
            self.storage_schema,
            id,
            try u64ToSqliteI64(size_bytes),
            try usizeToSqliteI64(sorted_chunks.len),
            policy,
        );

        var inserts = try ObjectInsertStatements.init(self.sqlite_db, self.storage_schema);
        defer inserts.deinit();

        for (sorted_chunks) |chunk| {
            try inserts.insertManifest(
                id,
                try u64ToSqliteI64(chunk.index),
                chunk.hash,
                try u64ToSqliteI64(chunk.offset),
                try u64ToSqliteI64(chunk.size_bytes),
            );
        }

        if (owns_transaction) try self.sqlite_db.commit();
        committed = true;
    }

    /// Delete one unreferenced stored chunk by hash.
    ///
    /// This is cleanup for loose chunks, not object deletion. It removes a
    /// chunk only when no `_zova_object_chunks` row references it. Missing
    /// chunks and referenced chunks both return `false`.
    pub fn deleteObjectChunk(self: *Database, hash: ObjectChunkId) Error!bool {
        var stmt = try self.prepareSchema(
            \\delete from {s}_zova_chunks
            \\where chunk_hash = ?
            \\  and not exists (
            \\    select 1
            \\    from {s}_zova_object_chunks
            \\    where {s}_zova_object_chunks.chunk_hash = {s}_zova_chunks.chunk_hash
            \\  )
        , .{ self.storage_schema.prefix(), self.storage_schema.prefix(), self.storage_schema.prefix(), self.storage_schema.prefix() });
        defer stmt.deinit();

        try stmt.bindBlob(1, &hash);
        std.debug.assert((try stmt.step()) == .done);
        return self.sqlite_db.changes() > 0;
    }

    fn validateAssemblyChunks(
        self: *Database,
        allocator: std.mem.Allocator,
        id: ObjectId,
        size_bytes: u64,
        chunks: []const ObjectChunk,
        policy: ChunkingPolicy,
    ) Error![]ObjectChunk {
        if (size_bytes > std.math.maxInt(i64)) return error.ObjectTooLarge;

        if (size_bytes == 0) {
            if (chunks.len != 0) return error.ObjectManifestInvalid;
            if (!std.mem.eql(u8, &objectId(""), &id)) return error.ObjectManifestInvalid;
            return try allocator.alloc(ObjectChunk, 0);
        }

        if (chunks.len == 0) return error.ObjectManifestInvalid;

        const sorted_chunks = try allocator.dupe(ObjectChunk, chunks);
        errdefer allocator.free(sorted_chunks);
        std.mem.sort(ObjectChunk, sorted_chunks, {}, objectChunkIndexLessThan);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var expected_index: u64 = 0;
        var expected_offset: u64 = 0;

        for (sorted_chunks) |chunk| {
            if (chunk.index != expected_index) return error.ObjectManifestInvalid;
            if (chunk.offset != expected_offset) return error.ObjectManifestInvalid;
            if (chunk.size_bytes == 0 or chunk.size_bytes > policy.maxSize()) return error.ObjectManifestInvalid;
            if (chunk.offset > size_bytes or chunk.size_bytes > size_bytes - chunk.offset) {
                return error.ObjectManifestInvalid;
            }

            var stored_chunk = try self.getObjectChunkWithPolicy(allocator, chunk.hash, policy);
            defer stored_chunk.deinit(allocator);
            if (stored_chunk.bytes.len != chunk.size_bytes) return error.ObjectManifestInvalid;

            hasher.update(stored_chunk.bytes);
            expected_offset += chunk.size_bytes;
            expected_index += 1;
        }

        if (expected_offset != size_bytes) return error.ObjectManifestInvalid;

        if (!validateManifestPolicyShape(size_bytes, sorted_chunks, policy)) {
            return error.ObjectManifestInvalid;
        }

        var digest: ObjectId = undefined;
        hasher.final(&digest);
        if (!std.mem.eql(u8, &digest, &id)) return error.ObjectManifestInvalid;

        return sorted_chunks;
    }

    /// Load and verify a stored object chunk by chunk hash.
    ///
    /// Missing chunks return `error.ObjectChunkNotFound`. Malformed or
    /// hash-mismatched private chunk rows return `error.ObjectCorrupt`.
    pub fn getObjectChunk(
        self: *Database,
        allocator: std.mem.Allocator,
        hash: ObjectChunkId,
    ) Error!ObjectChunkData {
        return self.getObjectChunkWithPolicy(allocator, hash, .fastcdc);
    }

    fn getObjectChunkWithPolicy(
        self: *Database,
        allocator: std.mem.Allocator,
        hash: ObjectChunkId,
        policy: ChunkingPolicy,
    ) Error!ObjectChunkData {
        var stmt = try self.prepareSchema(
            \\select size_bytes, data
            \\from {s}_zova_chunks
            \\where chunk_hash = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindBlob(1, &hash);
        switch (try stmt.step()) {
            .done => return error.ObjectChunkNotFound,
            .row => {
                const size = try sqliteI64ToUsize(stmt.columnInt64(0));
                if (size == 0 or size > policy.maxSize()) return error.ObjectCorrupt;

                const data = stmt.columnBlob(1);
                if (data.len != size) return error.ObjectCorrupt;
                if (!std.mem.eql(u8, &objectId(data), &hash)) return error.ObjectCorrupt;

                const bytes = try allocator.dupe(u8, data);
                errdefer allocator.free(bytes);
                return .{ .hash = hash, .bytes = bytes };
            },
        }
    }

    /// Return whether an object id exists without loading object bytes.
    pub fn hasObject(self: *Database, id: ObjectId) Error!bool {
        return try objectRowExists(self.sqlite_db, self.storage_schema, id);
    }

    /// Return the original full object byte length.
    pub fn objectSize(self: *Database, id: ObjectId) Error!u64 {
        const metadata = try loadObjectMetadata(self.sqlite_db, self.storage_schema, id);
        return try sqliteI64ToU64(metadata.size_bytes);
    }

    /// Return the number of FastCDC chunks in the object manifest.
    pub fn objectChunkCount(self: *Database, id: ObjectId) Error!u64 {
        const metadata = try loadObjectMetadata(self.sqlite_db, self.storage_schema, id);
        return try sqliteI64ToU64(metadata.chunk_count);
    }

    /// Delete one Zova object and garbage-collect its unreferenced chunks.
    ///
    /// Delete owns a `begin immediate` transaction by default and returns
    /// `error.ObjectTransactionActive` inside caller-owned transactions unless
    /// the database wrapper explicitly allows ambient transactions. Missing or
    /// already-deleted ids return `error.ObjectNotFound`. User SQL rows that
    /// store this object id are not inspected or modified.
    pub fn deleteObject(self: *Database, id: ObjectId) Error!void {
        const owns_transaction = try beginOwnedWrite(self.sqlite_db, self.allow_active_transactions);
        var committed = false;
        errdefer if (!committed and owns_transaction) self.sqlite_db.rollback() catch {};

        if (!try objectRowExists(self.sqlite_db, self.storage_schema, id)) return error.ObjectNotFound;

        const candidate_chunks = try collectDeleteCandidateChunks(std.heap.page_allocator, self.sqlite_db, self.storage_schema, id);
        defer std.heap.page_allocator.free(candidate_chunks);

        try deleteObjectManifestRows(self.sqlite_db, self.storage_schema, id);
        try deleteObjectRow(self.sqlite_db, self.storage_schema, id);
        try deleteUnreferencedCandidateChunks(self.sqlite_db, self.storage_schema, candidate_chunks);

        if (owns_transaction) try self.sqlite_db.commit();
        committed = true;
    }
};

const ObjectMetadata = struct {
    size_bytes: i64,
    chunk_count: i64,
    policy: ChunkingPolicy,
};

fn hasActiveTransaction(db: *sqlite.Database) bool {
    return sqlite.c.sqlite3_get_autocommit(db.handle) == 0 or
        sqlite.c.sqlite3_txn_state(db.handle, null) != sqlite.c.SQLITE_TXN_NONE;
}

fn rejectActiveTransaction(db: *sqlite.Database, allow_active_transactions: bool) Error!void {
    if (!allow_active_transactions and hasActiveTransaction(db)) return error.ObjectTransactionActive;
}

fn beginOwnedWrite(db: *sqlite.Database, allow_active_transactions: bool) Error!bool {
    if (hasActiveTransaction(db)) {
        if (allow_active_transactions) return false;
        return error.ObjectTransactionActive;
    }

    try db.beginImmediate();
    return true;
}

fn prepareSchema(
    db: *sqlite.Database,
    storage_schema: StorageSchema,
    comptime sql_format: []const u8,
    args: anytype,
) Error!sqlite.Statement {
    var sql_buffer: [4096]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&sql_buffer, sql_format, args) catch return error.SqliteError;
    _ = storage_schema;
    return try db.prepare(sql);
}

fn countObjectChunks(policy: ChunkingPolicy, bytes: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const chunk_len = policy.cut(bytes[offset..]);
        std.debug.assert(chunk_len > 0);
        count += 1;
        offset += chunk_len;
    }
    return count;
}

fn validateManifestPolicyShape(size_bytes: u64, chunks: []const ObjectChunk, policy: ChunkingPolicy) bool {
    if (policy == .fastcdc) return true;
    if (size_bytes == 0) return chunks.len == 0;
    if (chunks.len != (size_bytes + fixed_chunks.chunk_size - 1) / fixed_chunks.chunk_size) return false;

    var expected_offset: u64 = 0;
    for (chunks, 0..) |chunk, index| {
        if (chunk.offset != expected_offset or chunk.size_bytes == 0 or chunk.size_bytes > fixed_chunks.chunk_size) return false;
        if (index + 1 < chunks.len and chunk.size_bytes != fixed_chunks.chunk_size) return false;
        if (chunk.offset > size_bytes or chunk.size_bytes > size_bytes - chunk.offset) return false;
        expected_offset += chunk.size_bytes;
    }
    return expected_offset == size_bytes;
}

fn policyFromVersion(chunker: []const u8) ?ChunkingPolicy {
    if (std.mem.eql(u8, chunker, fastcdc.version)) return .fastcdc;
    if (std.mem.eql(u8, chunker, fixed_chunks.version)) return .fixed_1m;
    return null;
}

fn objectChunkIndexLessThan(_: void, left: ObjectChunk, right: ObjectChunk) bool {
    return left.index < right.index;
}

fn objectRowExists(db: *sqlite.Database, storage_schema: StorageSchema, id: ObjectId) Error!bool {
    var stmt = try prepareSchema(
        db,
        storage_schema,
        "select 1 from {s}_zova_objects where object_id = ? limit 1",
        .{storage_schema.prefix()},
    );
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    return switch (try stmt.step()) {
        .row => true,
        .done => false,
    };
}

fn countObjectManifestRows(db: *sqlite.Database, storage_schema: StorageSchema, id: ObjectId) Error!u64 {
    var stmt = try prepareSchema(
        db,
        storage_schema,
        "select count(*) from {s}_zova_object_chunks where object_id = ?",
        .{storage_schema.prefix()},
    );
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    std.debug.assert((try stmt.step()) == .row);
    return try sqliteI64ToU64(stmt.columnInt64(0));
}

fn validateObjectManifestShape(
    db: *sqlite.Database,
    storage_schema: StorageSchema,
    id: ObjectId,
    size: u64,
    chunk_count: u64,
    policy: ChunkingPolicy,
) Error!void {
    if (chunk_count == 0) {
        if (size != 0) return error.ObjectCorrupt;
        return;
    }
    if (chunk_count > size) return error.ObjectCorrupt;
    if (try countObjectManifestRows(db, storage_schema, id) != chunk_count) return error.ObjectCorrupt;

    var manifest = try prepareSchema(db, storage_schema,
        \\select oc.chunk_index, oc.chunk_hash, oc.offset, oc.size_bytes, c.size_bytes
        \\from {s}_zova_object_chunks oc
        \\left join {s}_zova_chunks c on c.chunk_hash = oc.chunk_hash
        \\where oc.object_id = ?
        \\order by oc.chunk_index asc
    , .{ storage_schema.prefix(), storage_schema.prefix() });
    defer manifest.deinit();

    try manifest.bindBlob(1, &id);

    var expected_index: u64 = 0;
    var expected_offset: u64 = 0;
    while ((try manifest.step()) == .row) {
        const chunk_index = try sqliteI64ToU64(manifest.columnInt64(0));
        if (chunk_index != expected_index) return error.ObjectCorrupt;
        if (manifest.columnBlob(1).len != @sizeOf(ObjectChunkId)) return error.ObjectCorrupt;

        const offset = try sqliteI64ToU64(manifest.columnInt64(2));
        const chunk_size = try sqliteI64ToU64(manifest.columnInt64(3));
        if (offset != expected_offset) return error.ObjectCorrupt;
        if (chunk_size == 0 or chunk_size > policy.maxSize()) return error.ObjectCorrupt;
        if (policy == .fixed_1m and expected_index + 1 < chunk_count and chunk_size != fixed_chunks.chunk_size) {
            return error.ObjectCorrupt;
        }
        if (offset > size or chunk_size > size - offset) return error.ObjectCorrupt;
        if (manifest.columnType(4) == .null) return error.ObjectCorrupt;

        const stored_chunk_size = try sqliteI64ToU64(manifest.columnInt64(4));
        if (stored_chunk_size != chunk_size) return error.ObjectCorrupt;

        expected_offset += chunk_size;
        expected_index += 1;
    }

    if (expected_index != chunk_count) return error.ObjectCorrupt;
    if (expected_offset != size) return error.ObjectCorrupt;

    if (policy == .fixed_1m and chunk_count != (size + fixed_chunks.chunk_size - 1) / fixed_chunks.chunk_size) {
        return error.ObjectCorrupt;
    }
}

fn collectDeleteCandidateChunks(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    storage_schema: StorageSchema,
    id: ObjectId,
) Error![]ObjectId {
    var chunks: std.ArrayList(ObjectId) = .empty;
    errdefer chunks.deinit(allocator);

    var stmt = try prepareSchema(db, storage_schema,
        \\select distinct chunk_hash
        \\from {s}_zova_object_chunks
        \\where object_id = ?
    , .{storage_schema.prefix()});
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    while ((try stmt.step()) == .row) {
        const candidate = stmt.columnBlob(0);
        if (candidate.len != @sizeOf(ObjectId)) return error.SqliteError;

        var chunk_hash: ObjectId = undefined;
        @memcpy(&chunk_hash, candidate);
        try chunks.append(allocator, chunk_hash);
    }

    return try chunks.toOwnedSlice(allocator);
}

fn deleteObjectManifestRows(db: *sqlite.Database, storage_schema: StorageSchema, id: ObjectId) Error!void {
    var stmt = try prepareSchema(
        db,
        storage_schema,
        "delete from {s}_zova_object_chunks where object_id = ?",
        .{storage_schema.prefix()},
    );
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    std.debug.assert((try stmt.step()) == .done);
}

fn deleteObjectRow(db: *sqlite.Database, storage_schema: StorageSchema, id: ObjectId) Error!void {
    var stmt = try prepareSchema(
        db,
        storage_schema,
        "delete from {s}_zova_objects where object_id = ?",
        .{storage_schema.prefix()},
    );
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    std.debug.assert((try stmt.step()) == .done);
}

fn deleteUnreferencedCandidateChunks(
    db: *sqlite.Database,
    storage_schema: StorageSchema,
    candidate_chunks: []const ObjectId,
) Error!void {
    var delete_chunk = try prepareSchema(db, storage_schema,
        \\delete from {s}_zova_chunks
        \\where chunk_hash = ?
        \\  and not exists (
        \\    select 1
        \\    from {s}_zova_object_chunks
        \\    where {s}_zova_object_chunks.chunk_hash = {s}_zova_chunks.chunk_hash
        \\  )
    , .{ storage_schema.prefix(), storage_schema.prefix(), storage_schema.prefix(), storage_schema.prefix() });
    defer delete_chunk.deinit();

    for (candidate_chunks) |chunk_hash| {
        try delete_chunk.bindBlob(1, &chunk_hash);
        std.debug.assert((try delete_chunk.step()) == .done);
        try delete_chunk.reset();
        try delete_chunk.clearBindings();
    }
}

fn loadObjectMetadata(db: *sqlite.Database, storage_schema: StorageSchema, id: ObjectId) Error!ObjectMetadata {
    var stmt = try prepareSchema(db, storage_schema,
        \\select size_bytes, chunk_count, chunker
        \\from {s}_zova_objects
        \\where object_id = ?
    , .{storage_schema.prefix()});
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);

    switch (try stmt.step()) {
        .done => return error.ObjectNotFound,
        .row => {
            const size_bytes = stmt.columnInt64(0);
            const chunk_count = stmt.columnInt64(1);
            if (size_bytes < 0 or chunk_count < 0) return error.ObjectCorrupt;
            const policy = policyFromVersion(stmt.columnText(2)) orelse return error.ObjectCorrupt;
            return .{
                .size_bytes = size_bytes,
                .chunk_count = chunk_count,
                .policy = policy,
            };
        },
    }
}

fn insertObjectRow(
    db: *sqlite.Database,
    storage_schema: StorageSchema,
    id: ObjectId,
    size_bytes: i64,
    chunk_count: i64,
    policy: ChunkingPolicy,
) Error!void {
    var stmt = try prepareSchema(db, storage_schema,
        \\insert into {s}_zova_objects (object_id, size_bytes, chunk_count, chunker)
        \\values (?, ?, ?, ?)
        \\on conflict(object_id) do nothing
    , .{storage_schema.prefix()});
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    try stmt.bindInt64(2, size_bytes);
    try stmt.bindInt64(3, chunk_count);
    try stmt.bindText(4, policy.version());
    std.debug.assert((try stmt.step()) == .done);
}

/// Reusable insert statements for one object publication.  Keeping these
/// prepared for the operation avoids preparing the same SQL once per chunk;
/// bindings are copied by SQLite and cleared after each execution.
const ObjectInsertStatements = struct {
    chunk: sqlite.Statement,
    manifest: sqlite.Statement,

    fn init(db: *sqlite.Database, storage_schema: StorageSchema) Error!ObjectInsertStatements {
        var chunk = try prepareSchema(db, storage_schema,
            \\insert into {s}_zova_chunks (chunk_hash, size_bytes, data)
            \\values (?, ?, ?)
            \\on conflict(chunk_hash) do nothing
        , .{storage_schema.prefix()});
        errdefer chunk.deinit();

        const manifest = try prepareSchema(db, storage_schema,
            \\insert into {s}_zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\values (?, ?, ?, ?, ?)
        , .{storage_schema.prefix()});

        return .{ .chunk = chunk, .manifest = manifest };
    }

    fn deinit(self: *ObjectInsertStatements) void {
        self.chunk.deinit();
        self.manifest.deinit();
    }

    fn insertChunk(self: *ObjectInsertStatements, chunk_hash: ObjectId, chunk: []const u8) Error!void {
        try self.chunk.bindBlob(1, &chunk_hash);
        try self.chunk.bindInt64(2, try usizeToSqliteI64(chunk.len));
        try self.chunk.bindBlob(3, chunk);
        std.debug.assert((try self.chunk.step()) == .done);
        try self.chunk.reset();
        try self.chunk.clearBindings();
    }

    fn insertManifest(
        self: *ObjectInsertStatements,
        id: ObjectId,
        chunk_index: i64,
        chunk_hash: ObjectId,
        offset: i64,
        size_bytes: i64,
    ) Error!void {
        try self.manifest.bindBlob(1, &id);
        try self.manifest.bindInt64(2, chunk_index);
        try self.manifest.bindBlob(3, &chunk_hash);
        try self.manifest.bindInt64(4, offset);
        try self.manifest.bindInt64(5, size_bytes);
        std.debug.assert((try self.manifest.step()) == .done);
        try self.manifest.reset();
        try self.manifest.clearBindings();
    }
};

fn insertChunkRow(
    db: *sqlite.Database,
    storage_schema: StorageSchema,
    chunk_hash: ObjectId,
    chunk: []const u8,
) Error!void {
    var stmt = try prepareSchema(db, storage_schema,
        \\insert into {s}_zova_chunks (chunk_hash, size_bytes, data)
        \\values (?, ?, ?)
        \\on conflict(chunk_hash) do nothing
    , .{storage_schema.prefix()});
    defer stmt.deinit();

    try stmt.bindBlob(1, &chunk_hash);
    try stmt.bindInt64(2, try usizeToSqliteI64(chunk.len));
    try stmt.bindBlob(3, chunk);
    std.debug.assert((try stmt.step()) == .done);
}

fn insertManifestRow(
    db: *sqlite.Database,
    storage_schema: StorageSchema,
    id: ObjectId,
    chunk_index: i64,
    chunk_hash: ObjectId,
    offset: i64,
    size_bytes: i64,
) Error!void {
    var stmt = try prepareSchema(db, storage_schema,
        \\insert into {s}_zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
        \\values (?, ?, ?, ?, ?)
    , .{storage_schema.prefix()});
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    try stmt.bindInt64(2, chunk_index);
    try stmt.bindBlob(3, &chunk_hash);
    try stmt.bindInt64(4, offset);
    try stmt.bindInt64(5, size_bytes);
    std.debug.assert((try stmt.step()) == .done);
}

fn usizeToSqliteI64(value: usize) Error!i64 {
    if (value > std.math.maxInt(i64)) return error.ObjectTooLarge;
    return @intCast(value);
}

fn u64ToSqliteI64(value: u64) Error!i64 {
    if (value > std.math.maxInt(i64)) return error.ObjectTooLarge;
    return @intCast(value);
}

fn sqliteI64ToU64(value: i64) Error!u64 {
    if (value < 0) return error.ObjectCorrupt;
    return @intCast(value);
}

fn sqliteI64ToUsize(value: i64) Error!usize {
    const unsigned = try sqliteI64ToU64(value);
    if (unsigned > std.math.maxInt(usize)) return error.ObjectTooLarge;
    return @intCast(unsigned);
}
