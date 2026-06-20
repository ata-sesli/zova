//! Zova-owned database identity layer.
//!
//! This module is the first layer above the plain SQLite wrapper. A database
//! enters Zova mode by using a `.zova` file path through `zova.Database`.
//! The file is still a SQLite database underneath, but Zova validates private
//! metadata before treating it as a Zova-owned database.
//!
//! Zova is currently pre-1.0, and internal `.zova` format compatibility is
//! not preserved between experimental format versions. The current v0.5
//! development format is version `3`: `_zova_meta.format_version = '3'` plus
//! the required private object schema and vector collection schema.
//! `Database.open` is intentionally non-mutating: it validates the file and
//! rejects old, future, incomplete, or invalid private schemas instead of
//! repairing or migrating them.
//!
//! Existing SQLite files can be converted into new `.zova` files with
//! `convertSqliteToZova`. Conversion copies the source with SQLite's backup
//! API, initializes Zova metadata in the destination, and never mutates the
//! source file.
//!
//! Zova object APIs use deterministic SHA-256 object identity and private
//! FastCDC chunking. `putObject` stores whole caller bytes as content-addressed
//! chunk BLOB rows, `getObject` reconstructs and verifies the full object in
//! memory, and `deleteObject` removes only Zova-owned object rows plus
//! unreferenced object chunks. User SQL references remain application-owned.
//!
//! Zova vector APIs follow pgvector's philosophy: vectors are native searchable
//! numeric values, while labels and application metadata stay in user SQL
//! tables. v0.5 uses exact collection-wide flat search; approximate indexes,
//! payload filters, and SQL virtual table integration are intentionally
//! deferred.
//! Migrations, streaming object I/O, and repair tooling are intentionally
//! absent from this release.

const std = @import("std");
const fastcdc = @import("fastcdc.zig");
const sqlite = @import("sqlite.zig");

const metadata_table = "_zova_meta";
const objects_table = "_zova_objects";
const chunks_table = "_zova_chunks";
const object_chunks_table = "_zova_object_chunks";
const vector_collections_table = "_zova_vector_collections";
const vectors_table = "_zova_vectors";
const magic_value = "zova";
const format_version = "3";
pub const max_vector_dimensions: u32 = 16_384;
const max_vector_collection_name_bytes: usize = 255;
const objects_schema_sql =
    \\create table _zova_objects (
    \\  object_id blob not null primary key check (length(object_id) = 32),
    \\  size_bytes integer not null check (size_bytes >= 0),
    \\  chunk_count integer not null check (chunk_count >= 0),
    \\  chunker text not null check (chunker = 'fastcdc-v1')
    \\)
;
const chunks_schema_sql =
    \\create table _zova_chunks (
    \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
    \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
    \\  data blob not null check (length(data) = size_bytes)
    \\)
;
const object_chunks_schema_sql =
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
const vector_collections_schema_sql =
    \\create table _zova_vector_collections (
    \\  name text not null primary key check (length(name) > 0 and length(name) <= 255),
    \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
    \\  metric text not null check (metric in ('cosine', 'l2', 'dot')),
    \\  element_type text not null check (element_type = 'f32')
    \\)
;
const vectors_schema_sql =
    \\create table _zova_vectors (
    \\  collection_name text not null,
    \\  vector_id text not null check (length(vector_id) > 0),
    \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
    \\  "values" blob not null check (length("values") = dimensions * 4),
    \\  primary key (collection_name, vector_id),
    \\  foreign key (collection_name) references _zova_vector_collections(name)
    \\)
;

/// SHA-256 digest of full object bytes.
///
/// Zova object identity is content identity: the same bytes produce the same
/// raw 32-byte `ObjectId`.
pub const ObjectId = [32]u8;

/// Error set for the Zova-owned database layer.
///
/// Boundary errors describe Zova file identity problems. SQLite operation
/// failures keep using the wrapped SQLite errors.
pub const Error = sqlite.Error || error{
    NotZovaPath,
    NotZovaDatabase,
    UnsupportedZovaVersion,
    DestinationExists,
    ZovaNameConflict,
    ObjectNotFound,
    ObjectCorrupt,
    ObjectTooLarge,
    ObjectTransactionActive,
    VectorCollectionExists,
    VectorCollectionNotFound,
    VectorNotFound,
    VectorDimensionMismatch,
    VectorCorrupt,
    VectorInvalid,
    OutOfMemory,
};

/// Distance metric used by a Zova vector collection.
///
/// v0.5 exact search uses one lower-is-better `distance` field for all metrics:
/// cosine uses `1 - cosine_similarity`, l2 uses Euclidean distance, and dot
/// uses negative dot product.
pub const VectorMetric = enum {
    cosine,
    l2,
    dot,
};

/// Required options for creating a native vector collection.
///
/// The metric is explicit by design; Zova does not guess distance semantics.
/// v0.5 supports only `f32` vectors and at most `max_vector_dimensions`.
pub const VectorCollectionOptions = struct {
    dimensions: u32,
    metric: VectorMetric,
};

/// Owned vector row returned by `Database.getVector`.
///
/// Vector ids are application-provided UTF-8 text ids scoped to a collection.
/// Values are decoded from Zova's deterministic little-endian `f32` BLOB
/// format. Call `deinit` with the same allocator passed to `getVector`.
pub const Vector = struct {
    id: []u8,
    values: []f32,

    /// Free the owned id and value buffers.
    pub fn deinit(self: *Vector, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.values);
    }
};

/// One exact vector search result.
///
/// Results contain the application-provided vector id plus a lower-is-better
/// distance. Zova search does not return application metadata or SQL rows.
pub const VectorSearchResult = struct {
    id: []u8,
    distance: f64,
};

/// Owned exact vector search result set.
///
/// Each result id is heap-owned. Call `deinit` with the same allocator passed
/// to `Database.searchVectors`.
pub const VectorSearchResults = struct {
    items: []VectorSearchResult,

    /// Free all owned result ids and the result slice.
    pub fn deinit(self: *VectorSearchResults, allocator: std.mem.Allocator) void {
        freeSearchItems(allocator, self.items);
        allocator.free(self.items);
    }
};

/// Compute the content identity for a Zova object.
pub fn objectId(bytes: []const u8) ObjectId {
    var digest: ObjectId = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

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

/// Convert an existing SQLite database file into a new `.zova` database.
///
/// The source is opened as plain SQLite and is never mutated. The destination
/// must use the `.zova` extension and must not already exist. Source schema
/// objects with `_zova_` names are rejected because that namespace is reserved
/// for Zova-owned metadata inside `.zova` files.
pub fn convertSqliteToZova(source_path: [:0]const u8, dest_path: [:0]const u8) Error!void {
    if (!isZovaPath(dest_path)) return error.NotZovaPath;

    const io = defaultIo();
    var dest_file = std.Io.Dir.cwd().createFile(io, dest_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DestinationExists,
        else => return error.CantOpen,
    };
    dest_file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, dest_path) catch {};

    try ensureSourcePathExists(source_path);

    var source = try sqlite.Database.open(source_path);
    defer source.deinit();

    try rejectReservedZovaNames(&source);

    {
        var dest = try sqlite.Database.open(dest_path);
        defer dest.deinit();

        try backupMainDatabase(&source, &dest);
        try initializeZovaSchema(&dest);
    }

    var validated = try Database.open(dest_path);
    validated.deinit();
}

/// Owns one initialized `.zova` database.
///
/// A Zova database is physically SQLite, but it must use the `.zova` extension
/// and contain valid `_zova_meta` metadata before `open` accepts it. The
/// wrapped SQLite connection is kept public for now as a low-level escape hatch
/// consistent with the v0 SQLite wrapper.
pub const Database = struct {
    sqlite_db: sqlite.Database,

    /// Create a new initialized `.zova` database.
    ///
    /// This never overwrites an existing file. The file is initialized with the
    /// private `_zova_meta` table, format version `3`, the required object
    /// schema, and the required vector collection schema.
    pub fn create(path: [:0]const u8) Error!Database {
        if (!isZovaPath(path)) return error.NotZovaPath;

        const io = defaultIo();
        var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.DestinationExists,
            else => return error.CantOpen,
        };
        file.close(io);

        errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};

        var raw = try sqlite.Database.open(path);
        errdefer raw.deinit();

        try initializeZovaSchema(&raw);
        return .{ .sqlite_db = raw };
    }

    /// Open an existing initialized `.zova` database.
    ///
    /// The `.zova` extension is the public opt-in boundary. Metadata is the
    /// actual validity check, so a renamed SQLite file is rejected. Open never
    /// repairs, migrates, or lazily initializes missing private schema.
    pub fn open(path: [:0]const u8) Error!Database {
        if (!isZovaPath(path)) return error.NotZovaPath;
        try ensurePathExists(path);

        var raw = try sqlite.Database.open(path);
        errdefer raw.deinit();

        try validateZovaSchema(&raw);
        return .{ .sqlite_db = raw };
    }

    /// Close the underlying SQLite connection.
    pub fn deinit(self: *Database) void {
        self.sqlite_db.deinit();
    }

    /// Execute SQL against the underlying SQLite database.
    pub fn exec(self: *Database, sql: [:0]const u8) Error!void {
        try self.sqlite_db.exec(sql);
    }

    /// Prepare SQL against the underlying SQLite database.
    pub fn prepare(self: *Database, sql: [:0]const u8) Error!sqlite.Statement {
        return try self.sqlite_db.prepare(sql);
    }

    /// Current SQLite error message for the underlying connection.
    pub fn errorMessage(self: *Database) []const u8 {
        return self.sqlite_db.errorMessage();
    }

    /// Create a native vector collection.
    ///
    /// Collection names are application-facing stable text names. They must be
    /// non-empty UTF-8, at most 255 bytes, and outside the reserved `_zova_`
    /// namespace. `dimensions` must be in `1...max_vector_dimensions`.
    /// Collection creation is a single SQLite insert and can participate in a
    /// caller-owned SQL transaction.
    pub fn createVectorCollection(
        self: *Database,
        name: []const u8,
        options: VectorCollectionOptions,
    ) Error!void {
        try validateVectorCollectionName(name);
        try validateVectorDimensions(options.dimensions);

        var insert = try self.prepare(
            \\insert into _zova_vector_collections (name, dimensions, metric, element_type)
            \\values (?, ?, ?, 'f32')
        );
        defer insert.deinit();

        try insert.bindText(1, name);
        try insert.bindInt64(2, @intCast(options.dimensions));
        try insert.bindText(3, vectorMetricText(options.metric));
        _ = insert.step() catch |err| switch (err) {
            error.Constraint => return error.VectorCollectionExists,
            else => return err,
        };
    }

    /// Return whether a valid vector collection exists.
    ///
    /// Invalid collection names return `error.VectorInvalid`; valid but missing
    /// names return `false`.
    pub fn hasVectorCollection(self: *Database, name: []const u8) Error!bool {
        try validateVectorCollectionName(name);

        var stmt = try self.prepare(
            \\select count(*)
            \\from _zova_vector_collections
            \\where name = ?
        );
        defer stmt.deinit();

        try stmt.bindText(1, name);
        const step = try stmt.step();
        std.debug.assert(step == .row);
        return stmt.columnInt64(0) == 1;
    }

    /// Store or replace one vector row in a collection.
    ///
    /// `collection_name` must name an existing collection. `vector_id` is a
    /// non-empty UTF-8 text id scoped to that collection. Values must match the
    /// collection dimensions and must be finite `f32` numbers. Storage uses one
    /// SQLite BLOB containing explicit little-endian `f32` bytes.
    pub fn putVector(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
        values: []const f32,
    ) Error!void {
        try validateVectorCollectionName(collection_name);
        try validateVectorId(vector_id);

        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorValues(collection.dimensions, collection.metric, values);

        const encoded = try encodeF32Le(std.heap.page_allocator, values);
        defer std.heap.page_allocator.free(encoded);

        var stmt = try self.prepare(
            \\insert into _zova_vectors (collection_name, vector_id, dimensions, "values")
            \\values (?, ?, ?, ?)
            \\on conflict(collection_name, vector_id) do update set
            \\  dimensions = excluded.dimensions,
            \\  "values" = excluded."values"
        );
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);
        try stmt.bindText(2, vector_id);
        try stmt.bindInt64(3, @intCast(collection.dimensions));
        try stmt.bindBlob(4, encoded);
        std.debug.assert((try stmt.step()) == .done);
    }

    /// Load one vector row into owned memory.
    ///
    /// Missing collections return `error.VectorCollectionNotFound`; missing
    /// vector ids return `error.VectorNotFound`. Invalid private vector bytes
    /// return `error.VectorCorrupt`.
    pub fn getVector(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        vector_id: []const u8,
    ) Error!Vector {
        try validateVectorCollectionName(collection_name);
        try validateVectorId(vector_id);

        const collection = try loadVectorCollection(self, collection_name);

        var stmt = try self.prepare(
            \\select vector_id, dimensions, "values"
            \\from _zova_vectors
            \\where collection_name = ? and vector_id = ?
        );
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);
        try stmt.bindText(2, vector_id);

        switch (try stmt.step()) {
            .done => return error.VectorNotFound,
            .row => {
                const stored_id = stmt.columnText(0);
                const stored_dimensions = stmt.columnInt64(1);
                if (stored_dimensions < 0) return error.VectorCorrupt;
                if (@as(u64, @intCast(stored_dimensions)) != collection.dimensions) return error.VectorCorrupt;

                const id = try allocator.dupe(u8, stored_id);
                errdefer allocator.free(id);

                const values = try decodeF32Le(allocator, stmt.columnBlob(2), collection.dimensions);
                errdefer allocator.free(values);

                return .{ .id = id, .values = values };
            },
        }
    }

    /// Return whether a vector id exists in an existing collection.
    ///
    /// Missing collections return `error.VectorCollectionNotFound`; valid but
    /// missing vector ids return `false`.
    pub fn hasVector(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
    ) Error!bool {
        try validateVectorCollectionName(collection_name);
        try validateVectorId(vector_id);
        _ = try loadVectorCollection(self, collection_name);

        var stmt = try self.prepare(
            \\select 1
            \\from _zova_vectors
            \\where collection_name = ? and vector_id = ?
            \\limit 1
        );
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);
        try stmt.bindText(2, vector_id);
        return switch (try stmt.step()) {
            .row => true,
            .done => false,
        };
    }

    /// Delete one vector row from an existing collection.
    ///
    /// This removes only Zova's private vector row. User SQL rows that store
    /// the same vector id are application-owned and are not scanned or mutated.
    pub fn deleteVector(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
    ) Error!void {
        try validateVectorCollectionName(collection_name);
        try validateVectorId(vector_id);
        _ = try loadVectorCollection(self, collection_name);

        var stmt = try self.prepare("delete from _zova_vectors where collection_name = ? and vector_id = ?");
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);
        try stmt.bindText(2, vector_id);
        std.debug.assert((try stmt.step()) == .done);

        if (self.sqlite_db.changes() == 0) return error.VectorNotFound;
    }

    /// Search one vector collection with an exact flat scan.
    ///
    /// Search is collection-wide in v0.5. It does not inspect labels, join user
    /// tables, or use approximate indexes. Returned results are sorted by
    /// ascending distance and then by ascending vector id for deterministic
    /// ties. `limit = 0` returns an empty owned result set after validating the
    /// collection and query.
    pub fn searchVectors(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: []const f32,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorValues(collection.dimensions, collection.metric, query);

        var results: std.ArrayList(VectorSearchResult) = .empty;
        errdefer {
            freeSearchItems(allocator, results.items);
            results.deinit(allocator);
        }

        if (limit == 0) {
            return .{ .items = try results.toOwnedSlice(allocator) };
        }

        var stmt = try self.prepare(
            \\select vector_id, dimensions, "values"
            \\from _zova_vectors
            \\where collection_name = ?
        );
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);
        while ((try stmt.step()) == .row) {
            const stored_dimensions = stmt.columnInt64(1);
            if (stored_dimensions < 0) return error.VectorCorrupt;
            if (@as(u64, @intCast(stored_dimensions)) != collection.dimensions) return error.VectorCorrupt;

            const distance = try vectorDistanceFromEncoded(
                collection.metric,
                query,
                stmt.columnBlob(2),
                collection.dimensions,
            );
            try maybeInsertSearchResult(allocator, &results, limit, stmt.columnText(0), distance);
        }

        const items = try results.toOwnedSlice(allocator);
        std.mem.sort(VectorSearchResult, items, {}, searchResultLessThan);
        return .{ .items = items };
    }

    /// Store raw bytes as a content-addressed Zova object.
    ///
    /// The returned id is the SHA-256 digest of the full byte slice. v0.4 owns
    /// its own transaction for object writes and returns
    /// `error.ObjectTransactionActive` if the connection is already inside a
    /// user transaction.
    pub fn putObject(self: *Database, bytes: []const u8) Error!ObjectId {
        if (hasActiveTransaction(&self.sqlite_db)) return error.ObjectTransactionActive;

        const id = objectId(bytes);
        const size_bytes = try usizeToSqliteI64(bytes.len);
        const chunk_count = try usizeToSqliteI64(countObjectChunks(bytes));

        try self.sqlite_db.beginImmediate();
        var committed = false;
        errdefer if (!committed) self.sqlite_db.rollback() catch {};

        if (try objectRowExists(&self.sqlite_db, id)) {
            try self.sqlite_db.commit();
            committed = true;
            return id;
        }

        try insertObjectRow(&self.sqlite_db, id, size_bytes, chunk_count);

        var offset: usize = 0;
        while (offset < bytes.len) {
            const chunk_len = fastcdc.cut(bytes[offset..]);
            const chunk = bytes[offset .. offset + chunk_len];
            const chunk_hash = objectId(chunk);
            try insertChunkRow(&self.sqlite_db, chunk_hash, chunk);
            offset += chunk_len;
        }

        offset = 0;
        var chunk_index: i64 = 0;
        while (offset < bytes.len) {
            const chunk_len = fastcdc.cut(bytes[offset..]);
            const chunk = bytes[offset .. offset + chunk_len];
            const chunk_hash = objectId(chunk);
            try insertManifestRow(
                &self.sqlite_db,
                id,
                chunk_index,
                chunk_hash,
                try usizeToSqliteI64(offset),
                try usizeToSqliteI64(chunk_len),
            );
            offset += chunk_len;
            chunk_index += 1;
        }

        try self.sqlite_db.commit();
        committed = true;
        return id;
    }

    /// Load and verify an object by id.
    ///
    /// The returned object owns an allocated byte buffer. Missing ids return
    /// `error.ObjectNotFound`. Broken private object rows return
    /// `error.ObjectCorrupt` rather than being repaired.
    pub fn getObject(self: *Database, allocator: std.mem.Allocator, id: ObjectId) Error!Object {
        const metadata = try loadObjectMetadata(&self.sqlite_db, id);
        const size = try sqliteI64ToUsize(metadata.size_bytes);
        const chunk_count = try sqliteI64ToUsize(metadata.chunk_count);
        var bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);

        if (chunk_count == 0) {
            if (size != 0) return error.ObjectCorrupt;
            if (!std.mem.eql(u8, &objectId(bytes), &id)) return error.ObjectCorrupt;
            return .{ .id = id, .bytes = bytes };
        }

        var manifest = try self.sqlite_db.prepare(
            \\select oc.chunk_index, oc.chunk_hash, oc.offset, oc.size_bytes, c.data
            \\from _zova_object_chunks oc
            \\left join _zova_chunks c on c.chunk_hash = oc.chunk_hash
            \\where oc.object_id = ?
            \\order by oc.chunk_index asc
        );
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
            if (chunk_size == 0 or chunk_size > fastcdc.max_size) return error.ObjectCorrupt;
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
        if (!std.mem.eql(u8, &objectId(bytes), &id)) return error.ObjectCorrupt;

        return .{ .id = id, .bytes = bytes };
    }

    /// Return whether an object id exists without loading object bytes.
    pub fn hasObject(self: *Database, id: ObjectId) Error!bool {
        return try objectRowExists(&self.sqlite_db, id);
    }

    /// Return the original full object byte length.
    pub fn objectSize(self: *Database, id: ObjectId) Error!u64 {
        const metadata = try loadObjectMetadata(&self.sqlite_db, id);
        return try sqliteI64ToU64(metadata.size_bytes);
    }

    /// Return the number of FastCDC chunks in the object manifest.
    pub fn objectChunkCount(self: *Database, id: ObjectId) Error!u64 {
        const metadata = try loadObjectMetadata(&self.sqlite_db, id);
        return try sqliteI64ToU64(metadata.chunk_count);
    }

    /// Delete one Zova object and garbage-collect its unreferenced chunks.
    ///
    /// Delete owns a `begin immediate` transaction and returns
    /// `error.ObjectTransactionActive` if the connection is already inside a
    /// user transaction. Missing or already-deleted ids return
    /// `error.ObjectNotFound`. User SQL rows that store this object id are not
    /// inspected or modified.
    pub fn deleteObject(self: *Database, id: ObjectId) Error!void {
        if (hasActiveTransaction(&self.sqlite_db)) return error.ObjectTransactionActive;

        try self.sqlite_db.beginImmediate();
        var committed = false;
        errdefer if (!committed) self.sqlite_db.rollback() catch {};

        if (!try objectRowExists(&self.sqlite_db, id)) return error.ObjectNotFound;

        const candidate_chunks = try collectDeleteCandidateChunks(std.heap.page_allocator, &self.sqlite_db, id);
        defer std.heap.page_allocator.free(candidate_chunks);

        try deleteObjectManifestRows(&self.sqlite_db, id);
        try deleteObjectRow(&self.sqlite_db, id);
        try deleteUnreferencedCandidateChunks(&self.sqlite_db, candidate_chunks);

        try self.sqlite_db.commit();
        committed = true;
    }
};

const ObjectMetadata = struct {
    size_bytes: i64,
    chunk_count: i64,
};

const VectorCollectionMetadata = struct {
    dimensions: u32,
    metric: VectorMetric,
};

fn hasActiveTransaction(db: *sqlite.Database) bool {
    return sqlite.c.sqlite3_get_autocommit(db.handle) == 0 or
        sqlite.c.sqlite3_txn_state(db.handle, null) != sqlite.c.SQLITE_TXN_NONE;
}

fn countObjectChunks(bytes: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const chunk_len = fastcdc.cut(bytes[offset..]);
        std.debug.assert(chunk_len > 0);
        count += 1;
        offset += chunk_len;
    }
    return count;
}

fn objectRowExists(db: *sqlite.Database, id: ObjectId) Error!bool {
    var stmt = try db.prepare("select 1 from _zova_objects where object_id = ? limit 1");
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    return switch (try stmt.step()) {
        .row => true,
        .done => false,
    };
}

fn collectDeleteCandidateChunks(allocator: std.mem.Allocator, db: *sqlite.Database, id: ObjectId) Error![]ObjectId {
    var chunks: std.ArrayList(ObjectId) = .empty;
    errdefer chunks.deinit(allocator);

    var stmt = try db.prepare(
        \\select distinct chunk_hash
        \\from _zova_object_chunks
        \\where object_id = ?
    );
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

fn deleteObjectManifestRows(db: *sqlite.Database, id: ObjectId) Error!void {
    var stmt = try db.prepare("delete from _zova_object_chunks where object_id = ?");
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    std.debug.assert((try stmt.step()) == .done);
}

fn deleteObjectRow(db: *sqlite.Database, id: ObjectId) Error!void {
    var stmt = try db.prepare("delete from _zova_objects where object_id = ?");
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    std.debug.assert((try stmt.step()) == .done);
}

fn deleteUnreferencedCandidateChunks(db: *sqlite.Database, candidate_chunks: []const ObjectId) Error!void {
    var delete_chunk = try db.prepare(
        \\delete from _zova_chunks
        \\where chunk_hash = ?
        \\  and not exists (
        \\    select 1
        \\    from _zova_object_chunks
        \\    where _zova_object_chunks.chunk_hash = _zova_chunks.chunk_hash
        \\  )
    );
    defer delete_chunk.deinit();

    for (candidate_chunks) |chunk_hash| {
        try delete_chunk.bindBlob(1, &chunk_hash);
        std.debug.assert((try delete_chunk.step()) == .done);
        try delete_chunk.reset();
        try delete_chunk.clearBindings();
    }
}

fn loadObjectMetadata(db: *sqlite.Database, id: ObjectId) Error!ObjectMetadata {
    var stmt = try db.prepare(
        \\select size_bytes, chunk_count, chunker
        \\from _zova_objects
        \\where object_id = ?
    );
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);

    switch (try stmt.step()) {
        .done => return error.ObjectNotFound,
        .row => {
            const size_bytes = stmt.columnInt64(0);
            const chunk_count = stmt.columnInt64(1);
            if (size_bytes < 0 or chunk_count < 0) return error.ObjectCorrupt;
            if (!std.mem.eql(u8, stmt.columnText(2), fastcdc.version)) return error.ObjectCorrupt;
            return .{
                .size_bytes = size_bytes,
                .chunk_count = chunk_count,
            };
        },
    }
}

fn insertObjectRow(db: *sqlite.Database, id: ObjectId, size_bytes: i64, chunk_count: i64) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
        \\values (?, ?, ?, ?)
        \\on conflict(object_id) do nothing
    );
    defer stmt.deinit();

    try stmt.bindBlob(1, &id);
    try stmt.bindInt64(2, size_bytes);
    try stmt.bindInt64(3, chunk_count);
    try stmt.bindText(4, fastcdc.version);
    std.debug.assert((try stmt.step()) == .done);
}

fn insertChunkRow(db: *sqlite.Database, chunk_hash: ObjectId, chunk: []const u8) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_chunks (chunk_hash, size_bytes, data)
        \\values (?, ?, ?)
        \\on conflict(chunk_hash) do nothing
    );
    defer stmt.deinit();

    try stmt.bindBlob(1, &chunk_hash);
    try stmt.bindInt64(2, try usizeToSqliteI64(chunk.len));
    try stmt.bindBlob(3, chunk);
    std.debug.assert((try stmt.step()) == .done);
}

fn insertManifestRow(
    db: *sqlite.Database,
    id: ObjectId,
    chunk_index: i64,
    chunk_hash: ObjectId,
    offset: i64,
    size_bytes: i64,
) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
        \\values (?, ?, ?, ?, ?)
    );
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

fn sqliteI64ToU64(value: i64) Error!u64 {
    if (value < 0) return error.ObjectCorrupt;
    return @intCast(value);
}

fn sqliteI64ToUsize(value: i64) Error!usize {
    const unsigned = try sqliteI64ToU64(value);
    if (unsigned > std.math.maxInt(usize)) return error.ObjectTooLarge;
    return @intCast(unsigned);
}

fn isZovaPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zova");
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn ensurePathExists(path: []const u8) Error!void {
    const io = defaultIo();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return missingPathError(io, path),
            else => return error.CantOpen,
        };
        return;
    }

    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return missingPathError(io, path),
        else => return error.CantOpen,
    };
}

fn missingPathError(io: std.Io, path: []const u8) Error {
    const parent = std.fs.path.dirname(path) orelse return error.NotZovaDatabase;
    if (parent.len == 0) return error.NotZovaDatabase;

    if (std.fs.path.isAbsolute(parent)) {
        std.Io.Dir.accessAbsolute(io, parent, .{}) catch return error.CantOpen;
    } else {
        std.Io.Dir.cwd().access(io, parent, .{}) catch return error.CantOpen;
    }

    return error.NotZovaDatabase;
}

fn ensureSourcePathExists(path: []const u8) Error!void {
    const io = defaultIo();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return error.CantOpen;
        return;
    }

    std.Io.Dir.cwd().access(io, path, .{}) catch return error.CantOpen;
}

fn initializeZovaSchema(db: *sqlite.Database) sqlite.Error!void {
    try initializeMetadata(db);
    try initializeObjectSchema(db);
    try initializeVectorSchema(db);
}

fn initializeMetadata(db: *sqlite.Database) sqlite.Error!void {
    try db.exec(
        \\create table _zova_meta (
        \\  key text primary key,
        \\  value text not null
        \\);
        \\insert into _zova_meta (key, value) values ('magic', 'zova');
        \\insert into _zova_meta (key, value) values ('format_version', '3');
    );
}

fn initializeObjectSchema(db: *sqlite.Database) sqlite.Error!void {
    try db.exec(objects_schema_sql ++ ";");
    try db.exec(chunks_schema_sql ++ ";");
    try db.exec(object_chunks_schema_sql ++ ";");
}

fn initializeVectorSchema(db: *sqlite.Database) sqlite.Error!void {
    try db.exec(vector_collections_schema_sql ++ ";");
    try db.exec(vectors_schema_sql ++ ";");
}

fn rejectReservedZovaNames(db: *sqlite.Database) Error!void {
    var objects = try db.prepare("select name from sqlite_master where name is not null");
    defer objects.deinit();

    while ((try objects.step()) == .row) {
        const name = objects.columnText(0);
        if (isReservedZovaName(name)) return error.ZovaNameConflict;
    }
}

fn isReservedZovaName(name: []const u8) bool {
    const reserved_prefix = "_zova_";
    return name.len >= reserved_prefix.len and
        std.ascii.eqlIgnoreCase(name[0..reserved_prefix.len], reserved_prefix);
}

fn validateVectorCollectionName(name: []const u8) Error!void {
    if (name.len == 0) return error.VectorInvalid;
    if (name.len > max_vector_collection_name_bytes) return error.VectorInvalid;
    if (!std.unicode.utf8ValidateSlice(name)) return error.VectorInvalid;
    if (isReservedZovaName(name)) return error.VectorInvalid;
}

fn validateVectorId(id: []const u8) Error!void {
    if (id.len == 0) return error.VectorInvalid;
    if (id.len > max_vector_collection_name_bytes) return error.VectorInvalid;
    if (!std.unicode.utf8ValidateSlice(id)) return error.VectorInvalid;
    if (isReservedZovaName(id)) return error.VectorInvalid;
}

fn validateVectorDimensions(dimensions: u32) Error!void {
    if (dimensions == 0 or dimensions > max_vector_dimensions) return error.VectorInvalid;
}

fn validateVectorValues(expected_dimensions: u32, metric: VectorMetric, values: []const f32) Error!void {
    if (values.len != expected_dimensions) return error.VectorDimensionMismatch;
    var norm_squared: f64 = 0;
    for (values) |value| {
        if (std.math.isNan(value) or std.math.isInf(value)) return error.VectorInvalid;
        const value_f64: f64 = @floatCast(value);
        norm_squared += value_f64 * value_f64;
    }
    if (metric == .cosine and norm_squared == 0) return error.VectorInvalid;
}

fn vectorMetricText(metric: VectorMetric) []const u8 {
    return switch (metric) {
        .cosine => "cosine",
        .l2 => "l2",
        .dot => "dot",
    };
}

fn vectorMetricFromText(text: []const u8) Error!VectorMetric {
    if (std.mem.eql(u8, text, "cosine")) return .cosine;
    if (std.mem.eql(u8, text, "l2")) return .l2;
    if (std.mem.eql(u8, text, "dot")) return .dot;
    return error.NotZovaDatabase;
}

fn loadVectorCollection(db: *Database, name: []const u8) Error!VectorCollectionMetadata {
    var stmt = try db.prepare(
        \\select dimensions, metric, element_type
        \\from _zova_vector_collections
        \\where name = ?
    );
    defer stmt.deinit();

    try stmt.bindText(1, name);
    return switch (try stmt.step()) {
        .done => error.VectorCollectionNotFound,
        .row => {
            const dimensions_i64 = stmt.columnInt64(0);
            if (dimensions_i64 <= 0 or dimensions_i64 > max_vector_dimensions) return error.NotZovaDatabase;
            if (!std.mem.eql(u8, stmt.columnText(2), "f32")) return error.NotZovaDatabase;
            return .{
                .dimensions = @intCast(dimensions_i64),
                .metric = try vectorMetricFromText(stmt.columnText(1)),
            };
        },
    };
}

fn vectorByteLen(dimensions: u32) usize {
    return @as(usize, @intCast(dimensions)) * @sizeOf(f32);
}

fn encodeF32Le(allocator: std.mem.Allocator, values: []const f32) Error![]u8 {
    const bytes = try allocator.alloc(u8, values.len * @sizeOf(f32));
    errdefer allocator.free(bytes);

    for (values, 0..) |value, index| {
        const bits: u32 = @bitCast(value);
        std.mem.writeInt(u32, bytes[index * 4 ..][0..4], bits, .little);
    }

    return bytes;
}

fn decodeF32Le(allocator: std.mem.Allocator, bytes: []const u8, dimensions: u32) Error![]f32 {
    if (bytes.len != vectorByteLen(dimensions)) return error.VectorCorrupt;

    const values = try allocator.alloc(f32, dimensions);
    errdefer allocator.free(values);

    for (values, 0..) |*value, index| {
        const bits = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
        value.* = @bitCast(bits);
        if (std.math.isNan(value.*) or std.math.isInf(value.*)) return error.VectorCorrupt;
    }

    return values;
}

fn decodeF32LeAt(bytes: []const u8, index: usize) f32 {
    const bits = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    return @bitCast(bits);
}

fn vectorDistanceFromEncoded(
    metric: VectorMetric,
    query: []const f32,
    encoded_values: []const u8,
    dimensions: u32,
) Error!f64 {
    if (encoded_values.len != vectorByteLen(dimensions)) return error.VectorCorrupt;

    return switch (metric) {
        .cosine => cosineDistanceFromEncoded(query, encoded_values),
        .l2 => l2DistanceFromEncoded(query, encoded_values),
        .dot => dotDistanceFromEncoded(query, encoded_values),
    };
}

fn cosineDistanceFromEncoded(query: []const f32, encoded_values: []const u8) Error!f64 {
    var dot: f64 = 0;
    var query_norm: f64 = 0;
    var stored_norm: f64 = 0;

    for (query, 0..) |query_value, index| {
        const stored_value = decodeF32LeAt(encoded_values, index);
        if (std.math.isNan(stored_value) or std.math.isInf(stored_value)) return error.VectorCorrupt;

        const query_f64: f64 = @floatCast(query_value);
        const stored_f64: f64 = @floatCast(stored_value);
        dot += query_f64 * stored_f64;
        query_norm += query_f64 * query_f64;
        stored_norm += stored_f64 * stored_f64;
    }

    if (query_norm == 0 or stored_norm == 0) return error.VectorCorrupt;
    return 1.0 - (dot / (@sqrt(query_norm) * @sqrt(stored_norm)));
}

fn l2DistanceFromEncoded(query: []const f32, encoded_values: []const u8) Error!f64 {
    var sum: f64 = 0;
    for (query, 0..) |query_value, index| {
        const stored_value = decodeF32LeAt(encoded_values, index);
        if (std.math.isNan(stored_value) or std.math.isInf(stored_value)) return error.VectorCorrupt;

        const diff = @as(f64, @floatCast(query_value)) - @as(f64, @floatCast(stored_value));
        sum += diff * diff;
    }
    return @sqrt(sum);
}

fn dotDistanceFromEncoded(query: []const f32, encoded_values: []const u8) Error!f64 {
    var dot: f64 = 0;
    for (query, 0..) |query_value, index| {
        const stored_value = decodeF32LeAt(encoded_values, index);
        if (std.math.isNan(stored_value) or std.math.isInf(stored_value)) return error.VectorCorrupt;

        dot += @as(f64, @floatCast(query_value)) * @as(f64, @floatCast(stored_value));
    }
    return -dot;
}

fn maybeInsertSearchResult(
    allocator: std.mem.Allocator,
    results: *std.ArrayList(VectorSearchResult),
    limit: usize,
    id: []const u8,
    distance: f64,
) Error!void {
    if (results.items.len < limit) {
        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);

        try results.append(allocator, .{
            .id = id_copy,
            .distance = distance,
        });
        return;
    }

    const worst_index = worstSearchResultIndex(results.items);
    if (!searchCandidateLessThan(id, distance, results.items[worst_index])) return;

    const id_copy = try allocator.dupe(u8, id);
    allocator.free(results.items[worst_index].id);
    results.items[worst_index] = .{
        .id = id_copy,
        .distance = distance,
    };
}

fn worstSearchResultIndex(items: []const VectorSearchResult) usize {
    std.debug.assert(items.len > 0);

    var worst_index: usize = 0;
    for (items[1..], 1..) |item, index| {
        if (searchResultLessThan({}, items[worst_index], item)) {
            worst_index = index;
        }
    }
    return worst_index;
}

fn searchCandidateLessThan(candidate_id: []const u8, candidate_distance: f64, existing: VectorSearchResult) bool {
    if (candidate_distance < existing.distance) return true;
    if (candidate_distance > existing.distance) return false;
    return std.mem.order(u8, candidate_id, existing.id) == .lt;
}

fn searchResultLessThan(_: void, lhs: VectorSearchResult, rhs: VectorSearchResult) bool {
    if (lhs.distance < rhs.distance) return true;
    if (lhs.distance > rhs.distance) return false;
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn freeSearchItems(allocator: std.mem.Allocator, items: []VectorSearchResult) void {
    for (items) |item| {
        allocator.free(item.id);
    }
}

fn backupMainDatabase(source: *sqlite.Database, dest: *sqlite.Database) Error!void {
    const backup = sqlite.c.sqlite3_backup_init(dest.handle, "main", source.handle, "main") orelse {
        return mapSqliteResultCode(sqlite.c.sqlite3_errcode(dest.handle));
    };

    const step_rc = sqlite.c.sqlite3_backup_step(backup, -1);
    const finish_rc = sqlite.c.sqlite3_backup_finish(backup);

    if (step_rc != sqlite.c.SQLITE_DONE) return mapSqliteResultCode(step_rc);
    if (finish_rc != sqlite.c.SQLITE_OK) return mapSqliteResultCode(finish_rc);
}

fn mapSqliteResultCode(rc: c_int) Error {
    const primary = rc & 0xff;
    return switch (primary) {
        sqlite.c.SQLITE_BUSY => error.Busy,
        sqlite.c.SQLITE_LOCKED => error.Locked,
        sqlite.c.SQLITE_CONSTRAINT => error.Constraint,
        sqlite.c.SQLITE_CANTOPEN => error.CantOpen,
        sqlite.c.SQLITE_MISUSE => error.Misuse,
        sqlite.c.SQLITE_NOMEM => error.NoMemory,
        sqlite.c.SQLITE_INTERRUPT => error.Interrupt,
        sqlite.c.SQLITE_READONLY => error.ReadOnly,
        sqlite.c.SQLITE_CORRUPT => error.Corrupt,
        else => error.SqliteError,
    };
}

fn validateZovaSchema(db: *sqlite.Database) Error!void {
    try expectMetadataValue(db, "magic", magic_value, .magic);
    try expectMetadataValue(db, "format_version", format_version, .format_version);
    try validateObjectSchema(db);
    try validateVectorSchema(db);
}

fn validateObjectSchema(db: *sqlite.Database) Error!void {
    const object_columns = [_][]const u8{
        "object_id",
        "size_bytes",
        "chunk_count",
        "chunker",
    };
    try validateRequiredTable(db, objects_table, &object_columns, objects_schema_sql);

    const chunk_columns = [_][]const u8{
        "chunk_hash",
        "size_bytes",
        "data",
    };
    try validateRequiredTable(db, chunks_table, &chunk_columns, chunks_schema_sql);

    const object_chunk_columns = [_][]const u8{
        "object_id",
        "chunk_index",
        "chunk_hash",
        "offset",
        "size_bytes",
    };
    try validateRequiredTable(db, object_chunks_table, &object_chunk_columns, object_chunks_schema_sql);
}

fn validateVectorSchema(db: *sqlite.Database) Error!void {
    const vector_collection_columns = [_][]const u8{
        "name",
        "dimensions",
        "metric",
        "element_type",
    };
    try validateRequiredTable(db, vector_collections_table, &vector_collection_columns, vector_collections_schema_sql);

    const vector_columns = [_][]const u8{
        "collection_name",
        "vector_id",
        "dimensions",
        "values",
    };
    try validateRequiredTable(db, vectors_table, &vector_columns, vectors_schema_sql);
}

fn validateRequiredTable(
    db: *sqlite.Database,
    table_name: []const u8,
    required_columns: []const []const u8,
    expected_sql: []const u8,
) Error!void {
    if (!try tableExists(db, table_name)) return error.NotZovaDatabase;

    for (required_columns) |column_name| {
        if (!try tableColumnExists(db, table_name, column_name)) return error.NotZovaDatabase;
    }

    var table_sql = try db.prepare(
        \\select sql
        \\from sqlite_master
        \\where type = 'table' and name = ?
    );
    defer table_sql.deinit();

    try table_sql.bindText(1, table_name);

    switch (try table_sql.step()) {
        .done => return error.NotZovaDatabase,
        .row => {
            const sql_text = table_sql.columnText(0);
            if (!schemaSqlEqual(sql_text, expected_sql)) return error.NotZovaDatabase;
        },
    }
}

fn tableExists(db: *sqlite.Database, table_name: []const u8) Error!bool {
    var stmt = try db.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table' and name = ?
    );
    defer stmt.deinit();

    try stmt.bindText(1, table_name);
    const step = try stmt.step();
    std.debug.assert(step == .row);
    return stmt.columnInt64(0) == 1;
}

fn tableColumnExists(db: *sqlite.Database, table_name: []const u8, column_name: []const u8) Error!bool {
    var stmt = try db.prepare(
        \\select count(*)
        \\from pragma_table_info(?)
        \\where name = ?
    );
    defer stmt.deinit();

    try stmt.bindText(1, table_name);
    try stmt.bindText(2, column_name);
    const step = try stmt.step();
    std.debug.assert(step == .row);
    return stmt.columnInt64(0) == 1;
}

fn schemaSqlEqual(actual: []const u8, expected: []const u8) bool {
    var actual_index: usize = 0;
    var expected_index: usize = 0;

    while (true) {
        actual_index = skipAsciiWhitespace(actual, actual_index);
        expected_index = skipAsciiWhitespace(expected, expected_index);

        if (actual_index == actual.len or expected_index == expected.len) {
            return actual_index == actual.len and expected_index == expected.len;
        }

        if (std.ascii.toLower(actual[actual_index]) != std.ascii.toLower(expected[expected_index])) {
            return false;
        }

        actual_index += 1;
        expected_index += 1;
    }
}

fn skipAsciiWhitespace(bytes: []const u8, start_index: usize) usize {
    var index = start_index;
    while (index < bytes.len and std.ascii.isWhitespace(bytes[index])) : (index += 1) {}
    return index;
}

const MetadataKey = enum {
    magic,
    format_version,
};

fn expectMetadataValue(
    db: *sqlite.Database,
    key: [:0]const u8,
    expected: []const u8,
    metadata_key: MetadataKey,
) Error!void {
    var stmt = db.prepare("select value from _zova_meta where key = ?") catch |err| switch (err) {
        error.SqliteError => return error.NotZovaDatabase,
        else => return err,
    };
    defer stmt.deinit();

    try stmt.bindText(1, key);

    return switch (try stmt.step()) {
        .done => error.NotZovaDatabase,
        .row => {
            const actual = stmt.columnText(0);
            if (std.mem.eql(u8, actual, expected)) return;
            return switch (metadata_key) {
                .magic => error.NotZovaDatabase,
                .format_version => error.UnsupportedZovaVersion,
            };
        },
    };
}

fn testingDbPath(buffer: []u8, sub_path: []const u8, filename: []const u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buffer, ".zig-cache/tmp/{s}/{s}", .{ sub_path, filename });
}

fn testingWriteMetadata(db: *sqlite.Database, magic: []const u8, version_value: []const u8) !void {
    try db.exec(
        \\create table _zova_meta (
        \\  key text primary key,
        \\  value text not null
        \\);
    );

    var insert = try db.prepare("insert into _zova_meta (key, value) values (?, ?)");
    defer insert.deinit();

    try insert.bindText(1, "magic");
    try insert.bindText(2, magic);
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());

    try insert.reset();
    try insert.clearBindings();

    try insert.bindText(1, "format_version");
    try insert.bindText(2, version_value);
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());
}

fn testingExpectTableCount(db: *sqlite.Database, table_name: []const u8, expected: i64) !void {
    var count = try db.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table' and name = ?
    );
    defer count.deinit();

    try count.bindText(1, table_name);
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    try std.testing.expectEqual(expected, count.columnInt64(0));
}

fn testingCount(db: anytype, sql: [:0]const u8) !i64 {
    var count = try db.prepare(sql);
    defer count.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    return count.columnInt64(0);
}

fn testingObjectManifestCount(db: *Database, id: ObjectId) !i64 {
    var count = try db.prepare("select count(*) from _zova_object_chunks where object_id = ?");
    defer count.deinit();

    try count.bindBlob(1, &id);
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    return count.columnInt64(0);
}

fn testingSharedChunkCount(db: *Database, left_id: ObjectId, right_id: ObjectId) !i64 {
    var count = try db.prepare(
        \\select count(*)
        \\from _zova_object_chunks left_chunks
        \\join _zova_object_chunks right_chunks
        \\  on right_chunks.chunk_hash = left_chunks.chunk_hash
        \\where left_chunks.object_id = ?
        \\  and right_chunks.object_id = ?
    );
    defer count.deinit();

    try count.bindBlob(1, &left_id);
    try count.bindBlob(2, &right_id);
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    return count.columnInt64(0);
}

fn testingExpectObjectMissing(db: *Database, id: ObjectId) !void {
    try std.testing.expect(!try db.hasObject(id));
    try std.testing.expectError(error.ObjectNotFound, db.objectSize(id));
    try std.testing.expectError(error.ObjectNotFound, db.objectChunkCount(id));
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, id));
}

fn testingQuickCheckOk(db: *Database) !void {
    var stmt = try db.prepare("pragma quick_check");
    defer stmt.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("ok", stmt.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

fn testingIntegrityCheckOk(db: anytype) !void {
    var stmt = try db.prepare("pragma integrity_check");
    defer stmt.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("ok", stmt.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

fn expectSearchIds(results: *const VectorSearchResults, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, results.items.len);
    for (expected, 0..) |expected_id, index| {
        try std.testing.expectEqualStrings(expected_id, results.items[index].id);
    }
}

test "create initializes and open validates zova database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "identity.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();

        try db.exec("create table user_data (id integer primary key, body text not null)");
        try db.exec("insert into user_data (body) values ('hello')");
    }

    {
        var db = try Database.open(db_path);
        defer db.deinit();

        var select = try db.prepare("select body from user_data");
        defer select.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try select.step());
        try std.testing.expectEqualStrings("hello", select.columnText(0));
    }
}

test "object ids are sha256 of full object bytes" {
    const empty_expected = ObjectId{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    const hello_expected = ObjectId{
        0x2c, 0xf2, 0x4d, 0xba, 0x5f, 0xb0, 0xa3, 0x0e,
        0x26, 0xe8, 0x3b, 0x2a, 0xc5, 0xb9, 0xe2, 0x9e,
        0x1b, 0x16, 0x1e, 0x5c, 0x1f, 0xa7, 0x42, 0x5e,
        0x73, 0x04, 0x33, 0x62, 0x93, 0x8b, 0x98, 0x24,
    };

    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ObjectId));
    try std.testing.expectEqualSlices(u8, &empty_expected, &objectId(""));
    try std.testing.expectEqualSlices(u8, &hello_expected, &objectId("hello"));
    try std.testing.expectEqualSlices(u8, &objectId("same bytes"), &objectId("same bytes"));
    try std.testing.expect(!std.mem.eql(u8, &objectId("first"), &objectId("second")));
    try std.testing.expectEqualStrings("fastcdc-v1", fastcdc.version);
}

test "put and get empty object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "put-get-empty.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("");
    try std.testing.expectEqualSlices(u8, &objectId(""), &id);
    try std.testing.expect(try db.hasObject(id));
    try std.testing.expectEqual(@as(u64, 0), try db.objectSize(id));
    try std.testing.expectEqual(@as(u64, 0), try db.objectChunkCount(id));

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &object.id);
    try std.testing.expectEqualSlices(u8, "", object.bytes);
}

test "put and get small binary object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "put-get-small.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = [_]u8{ 'z', 'o', 'v', 'a', 0, 1, 2, 255 };
    const id = try db.putObject(&bytes);
    try std.testing.expectEqualSlices(u8, &objectId(&bytes), &id);
    try std.testing.expect(try db.hasObject(id));
    try std.testing.expectEqual(@as(u64, bytes.len), try db.objectSize(id));
    try std.testing.expectEqual(@as(u64, 1), try db.objectChunkCount(id));

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &object.id);
    try std.testing.expectEqualSlices(u8, &bytes, object.bytes);
}

test "put and get large multi chunk object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "put-get-large.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var bytes: [fastcdc.max_size + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 17 + index / 3 + 11) % 251);
    }

    const id = try db.putObject(&bytes);
    try std.testing.expect(try db.objectChunkCount(id) > 1);

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &object.id);
    try std.testing.expectEqualSlices(u8, &bytes, object.bytes);
}

test "put same object twice deduplicates object chunks and manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "put-dedupe.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = "same object bytes";
    const first_id = try db.putObject(bytes);
    const second_id = try db.putObject(bytes);

    try std.testing.expectEqualSlices(u8, &first_id, &second_id);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));
    try std.testing.expectEqual(@as(i64, 1), try testingObjectManifestCount(&db, first_id));
}

test "put repeated content deduplicates identical chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "chunk-dedupe.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = [_]u8{0} ** (fastcdc.max_size * 4);
    const id = try db.putObject(&bytes);

    const chunk_rows = try testingCount(&db, "select count(*) from _zova_chunks");
    const manifest_rows = try testingObjectManifestCount(&db, id);
    try std.testing.expect(manifest_rows > 1);
    try std.testing.expect(chunk_rows < manifest_rows);
}

test "put similar objects shares at least one chunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "shared-chunks.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const base = [_]u8{0} ** (fastcdc.max_size * 4);
    var edited: [base.len + 257]u8 = undefined;
    for (edited[0..257], 0..) |*byte, index| {
        byte.* = @intCast((index * 23 + 5) % 241);
    }
    @memcpy(edited[257..], &base);

    const base_id = try db.putObject(&base);
    const edited_id = try db.putObject(&edited);

    try std.testing.expect(!std.mem.eql(u8, &base_id, &edited_id));
    try std.testing.expect(try testingSharedChunkCount(&db, base_id, edited_id) > 0);
}

test "object lookup helpers report present and missing objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-lookups.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const present = try db.putObject("present");
    const missing = objectId("missing");

    try std.testing.expect(try db.hasObject(present));
    try std.testing.expect(!try db.hasObject(missing));
    try std.testing.expectEqual(@as(u64, 7), try db.objectSize(present));
    try std.testing.expectEqual(@as(u64, 1), try db.objectChunkCount(present));
    try std.testing.expectError(error.ObjectNotFound, db.objectSize(missing));
    try std.testing.expectError(error.ObjectNotFound, db.objectChunkCount(missing));
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, missing));
}

test "delete object reports missing for absent and already deleted ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-missing.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expectError(error.ObjectNotFound, db.deleteObject(objectId("missing")));

    const id = try db.putObject("delete once");
    try db.deleteObject(id);
    try std.testing.expectError(error.ObjectNotFound, db.deleteObject(id));
}

test "delete empty object removes only object row and lookup APIs report missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-empty.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("");
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_object_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_object_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "delete one chunk object removes object manifest and unreferenced chunk rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-one-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("one chunk");
    try std.testing.expectEqual(@as(u64, 1), try db.objectChunkCount(id));
    try std.testing.expectEqual(@as(i64, 1), try testingObjectManifestCount(&db, id));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "delete multi chunk object removes manifests and unreferenced chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-multi-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var bytes: [fastcdc.max_size + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 19 + index / 5 + 3) % 253);
    }

    const id = try db.putObject(&bytes);
    const chunk_count = try db.objectChunkCount(id);
    try std.testing.expect(chunk_count > 1);

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "delete preserves chunks shared by another object and later removes them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-shared-chunks.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const base = [_]u8{0} ** (fastcdc.max_size * 4);
    var edited: [base.len + 257]u8 = undefined;
    for (edited[0..257], 0..) |*byte, index| {
        byte.* = @intCast((index * 29 + 7) % 251);
    }
    @memcpy(edited[257..], &base);

    const base_id = try db.putObject(&base);
    const edited_id = try db.putObject(&edited);
    const shared_count = try testingSharedChunkCount(&db, base_id, edited_id);
    try std.testing.expect(shared_count > 0);

    try db.deleteObject(base_id);
    try testingExpectObjectMissing(&db, base_id);
    try std.testing.expect(try db.hasObject(edited_id));

    var edited_object = try db.getObject(std.testing.allocator, edited_id);
    defer edited_object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &edited, edited_object.bytes);
    const remaining_chunk_rows = try testingCount(&db, "select count(*) from _zova_chunks");
    try std.testing.expect(remaining_chunk_rows > 0);
    try std.testing.expect(remaining_chunk_rows <= @as(i64, @intCast(try db.objectChunkCount(edited_id))));

    try db.deleteObject(edited_id);
    try testingExpectObjectMissing(&db, edited_id);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "delete repeated content object handles duplicate candidate chunk hashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-duplicate-candidates.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = [_]u8{0} ** (fastcdc.max_size * 4);
    const id = try db.putObject(&bytes);
    try std.testing.expect((try testingObjectManifestCount(&db, id)) > try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "delete corrupt object with missing chunk data still cleans object and manifest rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-corrupt-missing-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("missing chunk during delete");
    try db.exec("delete from _zova_chunks");
    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
}

test "putting same bytes after delete recreates same object id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-reput.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const first_id = try db.putObject("recreate me");
    try db.deleteObject(first_id);

    const second_id = try db.putObject("recreate me");
    try std.testing.expectEqualSlices(u8, &first_id, &second_id);

    var object = try db.getObject(std.testing.allocator, second_id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "recreate me", object.bytes);
}

test "delete object preserves user sql references and blob tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-user-sql.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec(
        \\create table attachments (object_id blob not null, filename text not null);
        \\create table user_blobs (data blob not null);
    );

    const id = try db.putObject("user referenced");
    {
        var insert = try db.prepare("insert into attachments (object_id, filename) values (?, ?)");
        defer insert.deinit();

        try insert.bindBlob(1, &id);
        try insert.bindText(2, "kept.bin");
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    const blob = [_]u8{ 9, 8, 7, 0, 6 };
    {
        var insert = try db.prepare("insert into user_blobs (data) values (?)");
        defer insert.deinit();

        try insert.bindBlob(1, &blob);
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    try db.deleteObject(id);

    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from attachments"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from user_blobs where length(data) = 5"));
    try testingExpectObjectMissing(&db, id);
    try testingQuickCheckOk(&db);
    try testingIntegrityCheckOk(&db);
}

test "delete object does not touch caller temp tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-temp-collision.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("temp table collision");
    try db.exec(
        \\create temp table zova_delete_candidate_chunks (
        \\  chunk_hash text primary key,
        \\  note text not null
        \\);
        \\insert into temp.zova_delete_candidate_chunks (chunk_hash, note)
        \\values ('caller-owned', 'preserved');
    );

    try db.deleteObject(id);

    var select = try db.prepare("select note from temp.zova_delete_candidate_chunks where chunk_hash = 'caller-owned'");
    defer select.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try select.step());
    try std.testing.expectEqualStrings("preserved", select.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try select.step());
}

test "delete object preserves multiple user sql references to the same id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-multiple-user-refs.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec(
        \\create table attachments (
        \\  id integer primary key,
        \\  object_id blob not null,
        \\  filename text not null
        \\)
    );

    const id = try db.putObject("referenced twice");
    for ([_][]const u8{ "first.bin", "second.bin" }) |filename| {
        var insert = try db.prepare("insert into attachments (object_id, filename) values (?, ?)");
        defer insert.deinit();

        try insert.bindBlob(1, &id);
        try insert.bindText(2, filename);
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    try db.deleteObject(id);

    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from attachments"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from attachments where length(object_id) = 32"));
    try testingExpectObjectMissing(&db, id);
}

test "delete object with missing manifest rows cleans remaining object state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-missing-manifest.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var bytes: [fastcdc.max_size + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 13 + index / 7 + 17) % 251);
    }

    const id = try db.putObject(&bytes);
    try std.testing.expect((try testingObjectManifestCount(&db, id)) > 1);
    try db.exec("delete from _zova_object_chunks where chunk_index = 0");
    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));

    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
}

test "sqlite wrapper can inspect object tables after deletion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "sqlite-inspect-after-delete.zova");
    const id = id: {
        var db = try Database.create(db_path);
        defer db.deinit();

        const stored_id = try db.putObject("raw sqlite inspect");
        try db.deleteObject(stored_id);
        break :id stored_id;
    };

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_objects", 1);
    try testingExpectTableCount(&raw, "_zova_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 1);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&raw, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&raw, "select count(*) from _zova_object_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&raw, "select count(*) from _zova_chunks"));
    try std.testing.expect(!try objectRowExists(&raw, id));
    try testingIntegrityCheckOk(&raw);
}

test "delete object works on converted zova database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "delete-convert.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "delete-convert.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table notes (id integer primary key, body text not null)");
        try source.exec("insert into notes (body) values ('kept')");
    }

    try convertSqliteToZova(source_path, dest_path);

    var db = try Database.open(dest_path);
    defer db.deinit();

    const id = try db.putObject("converted delete");
    try db.deleteObject(id);

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes"));
}

test "delete object rejects active user transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-active-transaction.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const deferred_id = try db.putObject("deferred delete");
    try db.sqlite_db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.deleteObject(deferred_id));
    try db.sqlite_db.rollback();
    try std.testing.expect(try db.hasObject(deferred_id));

    const immediate_id = try db.putObject("immediate delete");
    try db.sqlite_db.beginImmediate();
    try std.testing.expectError(error.ObjectTransactionActive, db.deleteObject(immediate_id));
    try db.sqlite_db.rollback();
    try std.testing.expect(try db.hasObject(immediate_id));
}

test "failed delete rolls back visible changes and keeps connection usable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-rollback.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("rollback delete");
    try db.exec(
        \\create trigger force_chunk_delete_failure
        \\before delete on _zova_chunks
        \\begin
        \\  select raise(abort, 'forced chunk delete failure');
        \\end;
    );

    try std.testing.expectError(error.Constraint, db.deleteObject(id));

    try std.testing.expect(try db.hasObject(id));
    try std.testing.expectEqual(@as(i64, 1), try testingObjectManifestCount(&db, id));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.exec("drop trigger force_chunk_delete_failure");

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "rollback delete", object.bytes);

    const later_id = try db.putObject("later put after failed delete");
    try std.testing.expect(try db.hasObject(later_id));

    try db.deleteObject(id);
    try testingExpectObjectMissing(&db, id);
}

test "delete object follows sqlite write lock behavior across connections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-two-connections.zova");

    var first = try Database.create(db_path);
    defer first.deinit();
    const id = try first.putObject("locked delete");

    var second = try Database.open(db_path);
    defer second.deinit();

    try first.sqlite_db.beginImmediate();
    try std.testing.expectError(error.Busy, second.deleteObject(id));
    try first.sqlite_db.rollback();

    try second.deleteObject(id);
    try testingExpectObjectMissing(&second, id);
}

test "object ids can be stored in user sql tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-relational.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec("create table attachments (id integer primary key, object_id blob not null, filename text not null)");

    const id = try db.putObject("attachment bytes");
    {
        var insert = try db.prepare("insert into attachments (object_id, filename) values (?, ?)");
        defer insert.deinit();

        try insert.bindBlob(1, &id);
        try insert.bindText(2, "note.bin");
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    var loaded_id: ObjectId = undefined;
    {
        var select = try db.prepare("select object_id from attachments where filename = ?");
        defer select.deinit();

        try select.bindText(1, "note.bin");
        try std.testing.expectEqual(sqlite.Step.row, try select.step());
        const stored_id = select.columnBlob(0);
        try std.testing.expectEqual(@as(usize, 32), stored_id.len);
        @memcpy(loaded_id[0..], stored_id);
    }

    var object = try db.getObject(std.testing.allocator, loaded_id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "attachment bytes", object.bytes);
}

test "plain sql blob tables still work in zova databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "plain-blob.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec("create table user_blobs (id integer primary key, data blob not null)");

    const blob = [_]u8{ 0, 1, 2, 3, 4 };
    {
        var insert = try db.prepare("insert into user_blobs (data) values (?)");
        defer insert.deinit();

        try insert.bindBlob(1, &blob);
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    var select = try db.prepare("select data from user_blobs");
    defer select.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try select.step());
    try std.testing.expectEqualSlices(u8, &blob, select.columnBlob(0));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
}

test "object api works on converted sqlite database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "object-convert.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "object-convert.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table notes (id integer primary key, body text not null)");
        try source.exec("insert into notes (body) values ('kept')");
    }

    try convertSqliteToZova(source_path, dest_path);

    var db = try Database.open(dest_path);
    defer db.deinit();

    const id = try db.putObject("converted object");
    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "converted object", object.bytes);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes"));
}

test "put object rejects active user transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "active-transaction.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.sqlite_db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.putObject("deferred"));
    try db.sqlite_db.rollback();

    try db.sqlite_db.beginImmediate();
    try std.testing.expectError(error.ObjectTransactionActive, db.putObject("immediate"));
    try db.sqlite_db.rollback();
}

test "failed put object rolls back visible private rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "put-rollback.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec("drop table _zova_object_chunks");
    try std.testing.expectError(error.SqliteError, db.putObject("rollback me"));

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.exec(object_chunks_schema_sql ++ ";");
    const id = try db.putObject("later success");
    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "later success", object.bytes);
}

test "stored chunk hash is sha256 of chunk bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "chunk-hash.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    _ = try db.putObject("chunk");

    var select = try db.prepare("select chunk_hash from _zova_chunks");
    defer select.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try select.step());
    try std.testing.expectEqualSlices(u8, &objectId("chunk"), select.columnBlob(0));
}

test "get object reports corruption for missing chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt-missing-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("missing chunk");
    try db.exec("delete from _zova_chunks");

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
}

test "get object reports corruption for chunk hash mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt-chunk-data.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("abc");
    {
        var update = try db.prepare("update _zova_chunks set data = ?");
        defer update.deinit();

        try update.bindBlob(1, "abd");
        try std.testing.expectEqual(sqlite.Step.done, try update.step());
    }

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
}

test "get object reports corruption for manifest size and offset mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var size_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size_path = try testingDbPath(&size_path_buffer, tmp.sub_path[0..], "corrupt-manifest-size.zova");

    {
        var db = try Database.create(size_path);
        defer db.deinit();

        const id = try db.putObject("abcdef");
        try db.exec("update _zova_object_chunks set size_bytes = 2");
        try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
    }

    var offset_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const offset_path = try testingDbPath(&offset_path_buffer, tmp.sub_path[0..], "corrupt-manifest-offset.zova");

    {
        var db = try Database.create(offset_path);
        defer db.deinit();

        const id = try db.putObject("abcdef");
        try db.exec("update _zova_object_chunks set offset = 1");
        try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
    }
}

test "get object reports corruption for object size mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt-object-size.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("object size");
    try db.exec("update _zova_objects set size_bytes = size_bytes + 1");

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
}

test "get object reports corruption for full object hash mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt-object-hash.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const real_id = try db.putObject("real bytes");
    const wrong_id = objectId("wrong bytes");

    {
        var update_object = try db.prepare("update _zova_objects set object_id = ? where object_id = ?");
        defer update_object.deinit();

        try update_object.bindBlob(1, &wrong_id);
        try update_object.bindBlob(2, &real_id);
        try std.testing.expectEqual(sqlite.Step.done, try update_object.step());
    }

    {
        var update_manifest = try db.prepare("update _zova_object_chunks set object_id = ? where object_id = ?");
        defer update_manifest.deinit();

        try update_manifest.bindBlob(1, &wrong_id);
        try update_manifest.bindBlob(2, &real_id);
        try std.testing.expectEqual(sqlite.Step.done, try update_manifest.step());
    }

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, wrong_id));
}

test "object manifest rejects duplicate indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "duplicate-manifest-index.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    _ = try db.putObject("duplicate index");

    try std.testing.expectError(
        error.Constraint,
        db.exec(
            \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\select object_id, chunk_index, chunk_hash, offset, size_bytes
            \\from _zova_object_chunks
            \\limit 1
        ),
    );
}

test "get object reports corruption for invalid manifest index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "invalid-manifest-index.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("invalid index");
    try db.exec("update _zova_object_chunks set chunk_index = 1 where chunk_index = 0");

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
}

test "get object reports corruption for chunk count mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "corrupt-chunk-count.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const id = try db.putObject("chunk count");
    try db.exec("update _zova_objects set chunk_count = chunk_count + 1");

    try std.testing.expectError(error.ObjectCorrupt, db.getObject(std.testing.allocator, id));
}

test "open validates identity only and object corruption is read-time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "open-read-time-corruption.zova");
    const id = id: {
        var db = try Database.create(db_path);
        defer db.deinit();

        const stored_id = try db.putObject("abc");
        {
            var update = try db.prepare("update _zova_chunks set data = ?");
            defer update.deinit();

            try update.bindBlob(1, "abd");
            try std.testing.expectEqual(sqlite.Step.done, try update.step());
        }

        break :id stored_id;
    };

    var reopened = try Database.open(db_path);
    defer reopened.deinit();

    try std.testing.expectError(error.ObjectCorrupt, reopened.getObject(std.testing.allocator, id));
}

test "created zova database stores metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "metadata.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    var meta = try raw.prepare("select key, value from _zova_meta order by key");
    defer meta.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings("format_version", meta.columnText(0));
    try std.testing.expectEqualStrings("3", meta.columnText(1));

    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings("magic", meta.columnText(0));
    try std.testing.expectEqualStrings("zova", meta.columnText(1));

    try std.testing.expectEqual(sqlite.Step.done, try meta.step());
}

test "created zova database contains required vector tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-tables.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_vector_collections", 1);
    try testingExpectTableCount(&raw, "_zova_vectors", 1);
}

test "zova database rejects non zova paths" {
    try std.testing.expectError(error.NotZovaPath, Database.open("plain.db"));
    try std.testing.expectError(error.NotZovaPath, Database.create("plain.db"));
}

test "create refuses existing zova file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "existing.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expectError(error.DestinationExists, Database.create(db_path));
}

test "create maps missing parent directory to CantOpen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(
        &path_buffer,
        ".zig-cache/tmp/{s}/missing-parent/missing.zova",
        .{tmp.sub_path[0..]},
    );

    try std.testing.expectError(error.CantOpen, Database.create(db_path));
}

test "open maps inaccessible parent directory to CantOpen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(
        &path_buffer,
        ".zig-cache/tmp/{s}/missing-parent/missing.zova",
        .{tmp.sub_path[0..]},
    );

    try std.testing.expectError(error.CantOpen, Database.open(db_path));
}

test "open rejects uninitialized zova file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "plain.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try raw.exec("create table user_data (id integer primary key)");
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "open rejects wrong magic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "wrong-magic.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try raw.exec(
            \\create table _zova_meta (key text primary key, value text not null);
            \\insert into _zova_meta (key, value) values ('magic', 'not-zova');
            \\insert into _zova_meta (key, value) values ('format_version', '3');
        );
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "open rejects old format version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "old-format.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "1");
    }

    try std.testing.expectError(error.UnsupportedZovaVersion, Database.open(db_path));
}

test "open rejects future format version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "future.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try raw.exec(
            \\create table _zova_meta (key text primary key, value text not null);
            \\insert into _zova_meta (key, value) values ('magic', 'zova');
            \\insert into _zova_meta (key, value) values ('format_version', '4');
        );
    }

    try std.testing.expectError(error.UnsupportedZovaVersion, Database.open(db_path));
}

test "open rejects v0.4 format version two database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "v04-format.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "2");
        try raw.exec(objects_schema_sql ++ ";");
        try raw.exec(chunks_schema_sql ++ ";");
        try raw.exec(object_chunks_schema_sql ++ ";");
    }

    try std.testing.expectError(error.UnsupportedZovaVersion, Database.open(db_path));
}

test "created zova database contains required object tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-tables.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_objects", 1);
    try testingExpectTableCount(&raw, "_zova_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 1);
}

test "open rejects format two database missing required object table without mutating it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-object-table.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "3");
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_objects", 0);
    try testingExpectTableCount(&raw, "_zova_chunks", 0);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 0);
}

test "open rejects version three database missing required vector table without mutating it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-vector-table.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "3");
        try raw.exec(objects_schema_sql ++ ";");
        try raw.exec(chunks_schema_sql ++ ";");
        try raw.exec(object_chunks_schema_sql ++ ";");
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_vector_collections", 0);
    try testingExpectTableCount(&raw, "_zova_vectors", 0);
}

test "open rejects required object table missing required column" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-object-column.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "3");
        try raw.exec(
            \\create table _zova_objects (
            \\  object_id blob not null primary key check (length(object_id) = 32),
            \\  chunk_count integer not null check (chunk_count >= 0),
            \\  chunker text not null check (chunker = 'fastcdc-v1')
            \\);
            \\create table _zova_chunks (
            \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  data blob not null check (length(data) = size_bytes)
            \\);
            \\create table _zova_object_chunks (
            \\  object_id blob not null check (length(object_id) = 32),
            \\  chunk_index integer not null check (chunk_index >= 0),
            \\  chunk_hash blob not null check (length(chunk_hash) = 32),
            \\  offset integer not null check (offset >= 0),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  primary key (object_id, chunk_index),
            \\  foreign key (object_id) references _zova_objects(object_id),
            \\  foreign key (chunk_hash) references _zova_chunks(chunk_hash)
            \\);
        );
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "open rejects required object table missing required constraint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-object-constraint.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "3");
        try raw.exec(
            \\create table _zova_objects (
            \\  object_id blob not null primary key check (length(object_id) = 32),
            \\  size_bytes integer not null,
            \\  chunk_count integer not null check (chunk_count >= 0),
            \\  chunker text not null check (chunker = 'fastcdc-v1')
            \\);
            \\create table _zova_chunks (
            \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  data blob not null check (length(data) = size_bytes)
            \\);
            \\create table _zova_object_chunks (
            \\  object_id blob not null check (length(object_id) = 32),
            \\  chunk_index integer not null check (chunk_index >= 0),
            \\  chunk_hash blob not null check (length(chunk_hash) = 32),
            \\  offset integer not null check (offset >= 0),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  primary key (object_id, chunk_index),
            \\  foreign key (object_id) references _zova_objects(object_id),
            \\  foreign key (chunk_hash) references _zova_chunks(chunk_hash)
            \\);
        );
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "open rejects fake constraint text in required object table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "fake-object-constraint.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "3");
        try raw.exec(
            \\create table _zova_objects (
            \\  object_id blob not null primary key check (length(object_id) = 32),
            \\  size_bytes integer not null check ('check (size_bytes >= 0)' is not null),
            \\  chunk_count integer not null check (chunk_count >= 0),
            \\  chunker text not null check (chunker = 'fastcdc-v1')
            \\);
            \\create table _zova_chunks (
            \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  data blob not null check (length(data) = size_bytes)
            \\);
            \\create table _zova_object_chunks (
            \\  object_id blob not null check (length(object_id) = 32),
            \\  chunk_index integer not null check (chunk_index >= 0),
            \\  chunk_hash blob not null check (length(chunk_hash) = 32),
            \\  offset integer not null check (offset >= 0),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  primary key (object_id, chunk_index),
            \\  foreign key (object_id) references _zova_objects(object_id),
            \\  foreign key (chunk_hash) references _zova_chunks(chunk_hash)
            \\);
        );
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "open rejects required vector table missing required column" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-vector-column.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "3");
        try raw.exec(objects_schema_sql ++ ";");
        try raw.exec(chunks_schema_sql ++ ";");
        try raw.exec(object_chunks_schema_sql ++ ";");
        try raw.exec(
            \\create table _zova_vector_collections (
            \\  name text not null primary key check (length(name) > 0 and length(name) <= 255),
            \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
            \\  element_type text not null check (element_type = 'f32')
            \\);
            \\create table _zova_vectors (
            \\  collection_name text not null,
            \\  vector_id text not null check (length(vector_id) > 0),
            \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
            \\  "values" blob not null check (length("values") = dimensions * 4),
            \\  primary key (collection_name, vector_id),
            \\  foreign key (collection_name) references _zova_vector_collections(name)
            \\);
        );
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "sqlite wrapper can inspect zova object tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "sqlite-inspect.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    var tables = try raw.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table'
        \\  and name in ('_zova_objects', '_zova_chunks', '_zova_object_chunks')
    );
    defer tables.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try tables.step());
    try std.testing.expectEqual(@as(i64, 3), tables.columnInt64(0));
}

test "sqlite wrapper can inspect zova vector tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "sqlite-inspect-vectors.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    var tables = try raw.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table'
        \\  and name in ('_zova_vector_collections', '_zova_vectors')
    );
    defer tables.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try tables.step());
    try std.testing.expectEqual(@as(i64, 2), tables.columnInt64(0));
}

test "create and lookup vector collections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-collections.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expect(!try db.hasVectorCollection("chunks"));
    try db.createVectorCollection("chunks", .{ .dimensions = 3, .metric = .cosine });
    try std.testing.expect(try db.hasVectorCollection("chunks"));

    var row = try db.prepare(
        \\select dimensions, metric, element_type
        \\from _zova_vector_collections
        \\where name = 'chunks'
    );
    defer row.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try row.step());
    try std.testing.expectEqual(@as(i64, 3), row.columnInt64(0));
    try std.testing.expectEqualStrings("cosine", row.columnText(1));
    try std.testing.expectEqualStrings("f32", row.columnText(2));
    try std.testing.expectEqual(sqlite.Step.done, try row.step());
}

test "vector collection duplicate and validation behavior" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = max_vector_dimensions, .metric = .l2 });
    try std.testing.expectError(error.VectorCollectionExists, db.createVectorCollection("chunks", .{ .dimensions = max_vector_dimensions, .metric = .dot }));

    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection("", .{ .dimensions = 3, .metric = .cosine }));
    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection("_zova_vectors", .{ .dimensions = 3, .metric = .cosine }));
    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection("bad\xff", .{ .dimensions = 3, .metric = .cosine }));
    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection("zero", .{ .dimensions = 0, .metric = .cosine }));
    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection("too-many", .{ .dimensions = max_vector_dimensions + 1, .metric = .cosine }));

    var long_name: [256]u8 = undefined;
    @memset(&long_name, 'a');
    try std.testing.expectError(error.VectorInvalid, db.createVectorCollection(&long_name, .{ .dimensions = 3, .metric = .cosine }));
    try std.testing.expectError(error.VectorInvalid, db.hasVectorCollection(""));
}

test "put and get vector rows use little endian f32 blobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-put-get.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 3, .metric = .cosine });
    try std.testing.expect(!try db.hasVector("chunks", "chunk-1"));
    try db.putVector("chunks", "chunk-1", &.{ 1.0, -2.5, 0.25 });
    try std.testing.expect(try db.hasVector("chunks", "chunk-1"));

    var vector = try db.getVector(std.testing.allocator, "chunks", "chunk-1");
    defer vector.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("chunk-1", vector.id);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, -2.5, 0.25 }, vector.values);

    var raw = try db.prepare("select dimensions, \"values\" from _zova_vectors where collection_name = 'chunks' and vector_id = 'chunk-1'");
    defer raw.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try raw.step());
    try std.testing.expectEqual(@as(i64, 3), raw.columnInt64(0));
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x00, 0x80, 0x3f,
        0x00, 0x00, 0x20, 0xc0,
        0x00, 0x00, 0x80, 0x3e,
    }, raw.columnBlob(1));
    try std.testing.expectEqual(sqlite.Step.done, try raw.step());
}

test "vector upsert delete and sql references remain application owned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-upsert-delete.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec(
        \\create table chunks (
        \\  id integer primary key,
        \\  vector_id text not null,
        \\  body text not null
        \\)
    );
    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.createVectorCollection("images", .{ .dimensions = 2, .metric = .dot });

    try db.putVector("chunks", "same-id", &.{ 1.0, 2.0 });
    try db.putVector("images", "same-id", &.{ 9.0, 8.0 });
    try db.putVector("chunks", "same-id", &.{ 3.0, 4.0 });
    try db.putVector("chunks", "delete-me", &.{ 5.0, 6.0 });

    var insert = try db.prepare("insert into chunks (vector_id, body) values (?, ?)");
    defer insert.deinit();
    try insert.bindText(1, "delete-me");
    try insert.bindText(2, "application row");
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());

    {
        var chunks_vector = try db.getVector(std.testing.allocator, "chunks", "same-id");
        defer chunks_vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 3.0, 4.0 }, chunks_vector.values);
    }
    {
        var images_vector = try db.getVector(std.testing.allocator, "images", "same-id");
        defer images_vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 9.0, 8.0 }, images_vector.values);
    }

    try db.deleteVector("chunks", "delete-me");
    try std.testing.expect(!try db.hasVector("chunks", "delete-me"));
    try std.testing.expectError(error.VectorNotFound, db.getVector(std.testing.allocator, "chunks", "delete-me"));
    try std.testing.expectError(error.VectorNotFound, db.deleteVector("chunks", "delete-me"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from chunks where vector_id = 'delete-me'"));
}

test "vector CRUD validates collections ids dimensions and finite values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-validation-crud.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 3, .metric = .cosine });

    try std.testing.expectError(error.VectorCollectionNotFound, db.putVector("missing", "id", &.{ 1.0, 2.0, 3.0 }));
    try std.testing.expectError(error.VectorCollectionNotFound, db.getVector(std.testing.allocator, "missing", "id"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.hasVector("missing", "id"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.deleteVector("missing", "id"));

    try std.testing.expectError(error.VectorInvalid, db.putVector("_zova_bad", "id", &.{ 1.0, 2.0, 3.0 }));
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", "", &.{ 1.0, 2.0, 3.0 }));
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", "_zova_id", &.{ 1.0, 2.0, 3.0 }));
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", "bad\xff", &.{ 1.0, 2.0, 3.0 }));
    try std.testing.expectError(error.VectorDimensionMismatch, db.putVector("chunks", "short", &.{ 1.0, 2.0 }));
    try std.testing.expectError(error.VectorDimensionMismatch, db.putVector("chunks", "empty", &.{}));
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", "nan", &.{ 1.0, std.math.nan(f32), 3.0 }));
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", "inf", &.{ 1.0, std.math.inf(f32), 3.0 }));

    var long_id: [256]u8 = undefined;
    @memset(&long_id, 'a');
    try std.testing.expectError(error.VectorInvalid, db.putVector("chunks", &long_id, &.{ 1.0, 2.0, 3.0 }));
}

test "get vector detects corrupt private rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-corrupt.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("chunks", "bad-len", &.{ 1.0, 2.0 });
    try db.putVector("chunks", "bad-dim", &.{ 3.0, 4.0 });
    try db.putVector("chunks", "bad-finite", &.{ 5.0, 6.0 });

    try db.exec("pragma ignore_check_constraints = on");
    try db.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'bad-len'");
    try db.exec("update _zova_vectors set dimensions = 3 where vector_id = 'bad-dim'");

    var inf_bytes = [_]u8{
        0x00, 0x00, 0x80, 0x3f,
        0x00, 0x00, 0x80, 0x7f,
    };
    var update = try db.prepare("update _zova_vectors set \"values\" = ? where vector_id = 'bad-finite'");
    defer update.deinit();
    try update.bindBlob(1, &inf_bytes);
    try std.testing.expectEqual(sqlite.Step.done, try update.step());
    try db.exec("pragma ignore_check_constraints = off");

    try std.testing.expectError(error.VectorCorrupt, db.getVector(std.testing.allocator, "chunks", "bad-len"));
    try std.testing.expectError(error.VectorCorrupt, db.getVector(std.testing.allocator, "chunks", "bad-dim"));
    try std.testing.expectError(error.VectorCorrupt, db.getVector(std.testing.allocator, "chunks", "bad-finite"));
}

test "vector CRUD persists works after conversion and participates in transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "vector-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "vector-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table docs (id integer primary key, body text not null); insert into docs (body) values ('hello')");
    }

    try convertSqliteToZova(source_path, dest_path);

    {
        var db = try Database.open(dest_path);
        defer db.deinit();

        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .cosine });
        try db.exec("begin");
        try db.putVector("docs", "doc-1", &.{ 0.5, 0.25 });
        try db.exec("commit");

        var vector = try db.getVector(std.testing.allocator, "docs", "doc-1");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.25 }, vector.values);
    }

    {
        var reopened = try Database.open(dest_path);
        defer reopened.deinit();

        try std.testing.expect(try reopened.hasVector("docs", "doc-1"));
        var vector = try reopened.getVector(std.testing.allocator, "docs", "doc-1");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("doc-1", vector.id);
        try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.25 }, vector.values);
    }
}

test "second connection vector write follows sqlite busy behavior" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-lock.zova");

    var first = try Database.create(db_path);
    defer first.deinit();
    try first.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .dot });

    var second = try Database.open(db_path);
    defer second.deinit();

    try first.exec("begin immediate");
    try first.putVector("chunks", "first", &.{ 1.0, 2.0 });
    try std.testing.expectError(error.Busy, second.putVector("chunks", "second", &.{ 3.0, 4.0 }));
    try std.testing.expectError(error.Busy, second.deleteVector("chunks", "first"));
    try first.exec("rollback");

    try second.putVector("chunks", "second", &.{ 3.0, 4.0 });
    try std.testing.expect(try second.hasVector("chunks", "second"));
}

test "search vectors validates inputs and handles empty limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });

    try std.testing.expectError(error.VectorCollectionNotFound, db.searchVectors(std.testing.allocator, "missing", &.{ 1.0, 2.0 }, 10));
    try std.testing.expectError(error.VectorDimensionMismatch, db.searchVectors(std.testing.allocator, "chunks", &.{1.0}, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectors(std.testing.allocator, "chunks", &.{ std.math.nan(f32), 1.0 }, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectors(std.testing.allocator, "chunks", &.{ std.math.inf(f32), 1.0 }, 10));
    try std.testing.expectError(error.VectorInvalid, db.putVector("cosine", "zero", &.{ 0.0, 0.0 }));
    try std.testing.expectError(error.VectorInvalid, db.searchVectors(std.testing.allocator, "cosine", &.{ 0.0, 0.0 }, 10));

    var empty_limit = try db.searchVectors(std.testing.allocator, "chunks", &.{ 1.0, 2.0 }, 0);
    defer empty_limit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_limit.items.len);

    var empty_collection = try db.searchVectors(std.testing.allocator, "chunks", &.{ 1.0, 2.0 }, 10);
    defer empty_collection.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_collection.items.len);
}

test "search vectors returns deterministic cosine l2 and dot results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-metrics.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });
    try db.createVectorCollection("l2", .{ .dimensions = 2, .metric = .l2 });
    try db.createVectorCollection("dot", .{ .dimensions = 2, .metric = .dot });

    try db.putVector("cosine", "east", &.{ 1.0, 0.0 });
    try db.putVector("cosine", "north", &.{ 0.0, 1.0 });
    try db.putVector("cosine", "northeast", &.{ 1.0, 1.0 });

    try db.putVector("l2", "near", &.{ 1.0, 1.0 });
    try db.putVector("l2", "far", &.{ 4.0, 5.0 });
    try db.putVector("l2", "tie-a", &.{ 1.0, 3.0 });
    try db.putVector("l2", "tie-b", &.{ 3.0, 1.0 });
    try db.putVector("l2", "other", &.{ 0.0, 0.0 });

    try db.putVector("dot", "large", &.{ 3.0, 0.0 });
    try db.putVector("dot", "small", &.{ 1.0, 0.0 });
    try db.putVector("dot", "negative", &.{ -1.0, 0.0 });

    {
        var results = try db.searchVectors(std.testing.allocator, "cosine", &.{ 1.0, 0.0 }, 3);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "east", "northeast", "north" });
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0 - 0.7071067811865475), results.items[1].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), results.items[2].distance, 0.000001);
    }

    {
        var results = try db.searchVectors(std.testing.allocator, "l2", &.{ 2.0, 2.0 }, 3);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "near", "tie-a", "tie-b" });
        try std.testing.expectApproxEqAbs(@as(f64, @sqrt(2.0)), results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, @sqrt(2.0)), results.items[1].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, @sqrt(2.0)), results.items[2].distance, 0.000001);
    }

    {
        var results = try db.searchVectors(std.testing.allocator, "dot", &.{ 1.0, 0.0 }, 5);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "large", "small", "negative" });
        try std.testing.expectApproxEqAbs(@as(f64, -3.0), results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, -1.0), results.items[1].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), results.items[2].distance, 0.000001);
    }
}

test "search vectors reflects updates deletes reopen and conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "search-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "search-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table docs (id integer primary key, body text not null); insert into docs (body) values ('a'), ('b')");
    }

    try convertSqliteToZova(source_path, dest_path);

    {
        var db = try Database.open(dest_path);
        defer db.deinit();
        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVector("docs", "a", &.{ 10.0, 10.0 });
        try db.putVector("docs", "b", &.{ 2.0, 2.0 });
        try db.putVector("docs", "a", &.{ 1.0, 1.0 });
        try db.deleteVector("docs", "b");

        var results = try db.searchVectors(std.testing.allocator, "docs", &.{ 0.0, 0.0 }, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"a"});
    }

    {
        var reopened = try Database.open(dest_path);
        defer reopened.deinit();
        var results = try reopened.searchVectors(std.testing.allocator, "docs", &.{ 0.0, 0.0 }, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"a"});
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&reopened, "select count(*) from docs"));
    }
}

test "search vectors reports corrupt private vector rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-corrupt.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("chunks", "bad", &.{ 1.0, 2.0 });
    try db.exec("pragma ignore_check_constraints = on");
    try db.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'bad'");
    try db.exec("pragma ignore_check_constraints = off");
    try std.testing.expectError(error.VectorCorrupt, db.searchVectors(std.testing.allocator, "chunks", &.{ 1.0, 2.0 }, 10));
}

test "object table constraints reject invalid object ids and chunkers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-constraints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    {
        var short_id = [_]u8{0xaa} ** 31;
        var invalid_id = try db.prepare(
            \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
            \\values (?, 0, 0, 'fastcdc-v1')
        );
        defer invalid_id.deinit();

        try invalid_id.bindBlob(1, &short_id);
        try std.testing.expectError(error.Constraint, invalid_id.step());
    }

    {
        var object_id = [_]u8{0xbb} ** 32;
        var invalid_chunker = try db.prepare(
            \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
            \\values (?, 0, 0, ?)
        );
        defer invalid_chunker.deinit();

        try invalid_chunker.bindBlob(1, &object_id);
        try invalid_chunker.bindText(2, "other-chunker");
        try std.testing.expectError(error.Constraint, invalid_chunker.step());
    }
}

test "object table rejects null object ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "null-object-id.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var null_id = try db.prepare(
        \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
        \\values (?, 0, 0, 'fastcdc-v1')
    );
    defer null_id.deinit();

    try null_id.bindNull(1);
    try std.testing.expectError(error.Constraint, null_id.step());
}

test "chunk table constraints reject invalid chunk rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "chunk-constraints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    {
        var short_hash = [_]u8{0xcc} ** 31;
        var invalid_hash = try db.prepare(
            \\insert into _zova_chunks (chunk_hash, size_bytes, data)
            \\values (?, 0, ?)
        );
        defer invalid_hash.deinit();

        try invalid_hash.bindBlob(1, &short_hash);
        try invalid_hash.bindBlob(2, "");
        try std.testing.expectError(error.Constraint, invalid_hash.step());
    }

    {
        var chunk_hash = [_]u8{0xdd} ** 32;
        var invalid_size = try db.prepare(
            \\insert into _zova_chunks (chunk_hash, size_bytes, data)
            \\values (?, 5, ?)
        );
        defer invalid_size.deinit();

        try invalid_size.bindBlob(1, &chunk_hash);
        try invalid_size.bindBlob(2, "abc");
        try std.testing.expectError(error.Constraint, invalid_size.step());
    }

    {
        var chunk_hash = [_]u8{0xee} ** 32;
        var too_large_data = [_]u8{0x11} ** (fastcdc.max_size + 1);
        var too_large = try db.prepare(
            \\insert into _zova_chunks (chunk_hash, size_bytes, data)
            \\values (?, 65537, ?)
        );
        defer too_large.deinit();

        try too_large.bindBlob(1, &chunk_hash);
        try too_large.bindBlob(2, &too_large_data);
        try std.testing.expectError(error.Constraint, too_large.step());
    }
}

test "chunk table rejects null chunk hashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "null-chunk-hash.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var null_hash = try db.prepare(
        \\insert into _zova_chunks (chunk_hash, size_bytes, data)
        \\values (?, 1, ?)
    );
    defer null_hash.deinit();

    try null_hash.bindNull(1);
    try null_hash.bindBlob(2, "a");
    try std.testing.expectError(error.Constraint, null_hash.step());
}

test "chunk table rejects zero-length chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "zero-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var chunk_hash = [_]u8{0x12} ** 32;
    var zero_chunk = try db.prepare(
        \\insert into _zova_chunks (chunk_hash, size_bytes, data)
        \\values (?, 0, ?)
    );
    defer zero_chunk.deinit();

    try zero_chunk.bindBlob(1, &chunk_hash);
    try zero_chunk.bindBlob(2, "");
    try std.testing.expectError(error.Constraint, zero_chunk.step());
}

test "object manifest rejects zero-length entries and short ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-constraints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var object_id = [_]u8{0x21} ** 32;
    var chunk_hash = [_]u8{0x22} ** 32;
    var short_object_id = [_]u8{0x23} ** 31;
    var short_chunk_hash = [_]u8{0x24} ** 31;

    {
        var zero_manifest = try db.prepare(
            \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\values (?, 0, ?, 0, 0)
        );
        defer zero_manifest.deinit();

        try zero_manifest.bindBlob(1, &object_id);
        try zero_manifest.bindBlob(2, &chunk_hash);
        try std.testing.expectError(error.Constraint, zero_manifest.step());
    }

    {
        var invalid_object_id = try db.prepare(
            \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\values (?, 1, ?, 0, 1)
        );
        defer invalid_object_id.deinit();

        try invalid_object_id.bindBlob(1, &short_object_id);
        try invalid_object_id.bindBlob(2, &chunk_hash);
        try std.testing.expectError(error.Constraint, invalid_object_id.step());
    }

    {
        var invalid_chunk_hash = try db.prepare(
            \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\values (?, 2, ?, 0, 1)
        );
        defer invalid_chunk_hash.deinit();

        try invalid_chunk_hash.bindBlob(1, &object_id);
        try invalid_chunk_hash.bindBlob(2, &short_chunk_hash);
        try std.testing.expectError(error.Constraint, invalid_chunk_hash.step());
    }
}

test "object schema accepts empty object row without chunks or manifest rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "empty-object-schema.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var empty_object_id = objectId("");

    {
        var object = try db.prepare(
            \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
            \\values (?, 0, 0, 'fastcdc-v1')
        );
        defer object.deinit();

        try object.bindBlob(1, &empty_object_id);
        try std.testing.expectEqual(sqlite.Step.done, try object.step());
    }

    var chunks = try db.prepare("select count(*) from _zova_chunks");
    defer chunks.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try chunks.step());
    try std.testing.expectEqual(@as(i64, 0), chunks.columnInt64(0));

    var manifest = try db.prepare("select count(*) from _zova_object_chunks");
    defer manifest.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try manifest.step());
    try std.testing.expectEqual(@as(i64, 0), manifest.columnInt64(0));
}

test "object schema accepts minimal valid object chunk and manifest rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "valid-object-schema.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var object_id = [_]u8{0x01} ** 32;
    var chunk_hash = [_]u8{0x02} ** 32;

    {
        var chunk = try db.prepare(
            \\insert into _zova_chunks (chunk_hash, size_bytes, data)
            \\values (?, 3, ?)
        );
        defer chunk.deinit();

        try chunk.bindBlob(1, &chunk_hash);
        try chunk.bindBlob(2, "abc");
        try std.testing.expectEqual(sqlite.Step.done, try chunk.step());
    }

    {
        var object = try db.prepare(
            \\insert into _zova_objects (object_id, size_bytes, chunk_count, chunker)
            \\values (?, 3, 1, 'fastcdc-v1')
        );
        defer object.deinit();

        try object.bindBlob(1, &object_id);
        try std.testing.expectEqual(sqlite.Step.done, try object.step());
    }

    {
        var manifest = try db.prepare(
            \\insert into _zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
            \\values (?, 0, ?, 0, 3)
        );
        defer manifest.deinit();

        try manifest.bindBlob(1, &object_id);
        try manifest.bindBlob(2, &chunk_hash);
        try std.testing.expectEqual(sqlite.Step.done, try manifest.step());
    }

    var count = try db.prepare("select count(*) from _zova_object_chunks");
    defer count.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 1), count.columnInt64(0));
}

test "plain sqlite open on zova path does not initialize metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "sqlite-wrapper.zova");

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try raw.exec("create table user_data (id integer primary key)");

    var count = try raw.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table' and name = '_zova_meta'
    );
    defer count.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 0), count.columnInt64(0));
}

test "convert sqlite to zova preserves table rows and source file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "source.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();

        try source.exec(
            \\create table messages (
            \\  id integer primary key,
            \\  body text not null
            \\);
            \\insert into messages (body) values ('alpha');
            \\insert into messages (body) values ('beta');
        );
    }

    try convertSqliteToZova(source_path, dest_path);

    {
        var dest = try Database.open(dest_path);
        defer dest.deinit();

        var rows = try dest.prepare("select body from messages order by id");
        defer rows.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try rows.step());
        try std.testing.expectEqualStrings("alpha", rows.columnText(0));
        try std.testing.expectEqual(sqlite.Step.row, try rows.step());
        try std.testing.expectEqualStrings("beta", rows.columnText(0));
        try std.testing.expectEqual(sqlite.Step.done, try rows.step());
    }

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();

        var count = try source.prepare("select count(*) from messages");
        defer count.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try count.step());
        try std.testing.expectEqual(@as(i64, 2), count.columnInt64(0));

        var metadata = try source.prepare(
            \\select count(*)
            \\from sqlite_master
            \\where type = 'table' and name = '_zova_meta'
        );
        defer metadata.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try metadata.step());
        try std.testing.expectEqual(@as(i64, 0), metadata.columnInt64(0));
    }
}

test "converted zova remains readable through sqlite wrapper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "sqlite-readable.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "sqlite-readable.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table items (name text not null); insert into items (name) values ('kept')");
    }

    try convertSqliteToZova(source_path, dest_path);

    var raw = try sqlite.Database.open(dest_path);
    defer raw.deinit();

    var item = try raw.prepare("select name from items");
    defer item.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try item.step());
    try std.testing.expectEqualStrings("kept", item.columnText(0));

    var meta = try raw.prepare("select value from _zova_meta where key = 'format_version'");
    defer meta.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings("3", meta.columnText(0));

    try testingExpectTableCount(&raw, "_zova_objects", 1);
    try testingExpectTableCount(&raw, "_zova_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_vector_collections", 1);
    try testingExpectTableCount(&raw, "_zova_vectors", 1);
}

test "convert sqlite to zova preserves index view and trigger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "schema.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "schema.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();

        try source.exec(
            \\create table notes (
            \\  id integer primary key,
            \\  body text not null
            \\);
            \\create table note_log (
            \\  note_id integer not null,
            \\  body text not null
            \\);
            \\create index notes_body_idx on notes (body);
            \\create view note_bodies as select body from notes;
            \\create trigger notes_after_insert
            \\after insert on notes
            \\begin
            \\  insert into note_log (note_id, body) values (new.id, new.body);
            \\end;
            \\insert into notes (body) values ('first');
        );
    }

    try convertSqliteToZova(source_path, dest_path);

    var dest = try Database.open(dest_path);
    defer dest.deinit();

    var objects = try dest.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where name in ('notes_body_idx', 'note_bodies', 'notes_after_insert')
    );
    defer objects.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try objects.step());
    try std.testing.expectEqual(@as(i64, 3), objects.columnInt64(0));

    try dest.exec("insert into notes (body) values ('second')");

    var log = try dest.prepare("select body from note_log order by note_id");
    defer log.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try log.step());
    try std.testing.expectEqualStrings("first", log.columnText(0));
    try std.testing.expectEqual(sqlite.Step.row, try log.step());
    try std.testing.expectEqualStrings("second", log.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try log.step());
}

test "convert sqlite to zova rejects invalid destination path and existing destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "rejects.db");

    var invalid_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_dest_path = try testingDbPath(&invalid_dest_buffer, tmp.sub_path[0..], "rejects.db");

    var existing_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_dest_path = try testingDbPath(&existing_dest_buffer, tmp.sub_path[0..], "existing-dest.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table data (id integer primary key)");
    }

    try std.testing.expectError(error.NotZovaPath, convertSqliteToZova(source_path, invalid_dest_path));

    {
        var dest = try Database.create(existing_dest_path);
        defer dest.deinit();
    }

    try std.testing.expectError(error.DestinationExists, convertSqliteToZova(source_path, existing_dest_path));
}

test "convert sqlite to zova rejects non sqlite source file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "not-sqlite.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "not-sqlite.zova");

    try std.Io.Dir.cwd().writeFile(defaultIo(), .{
        .sub_path = source_path,
        .data = "this is not a sqlite database",
    });

    try std.testing.expectError(error.SqliteError, convertSqliteToZova(source_path, dest_path));
    try std.testing.expectError(error.NotZovaDatabase, Database.open(dest_path));
}

test "convert sqlite to zova rejects reserved zova source names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "reserved.db");

    var meta_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const meta_dest_path = try testingDbPath(&meta_dest_buffer, tmp.sub_path[0..], "reserved-meta.zova");

    var prefix_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const prefix_dest_path = try testingDbPath(&prefix_dest_buffer, tmp.sub_path[0..], "reserved-prefix.zova");

    var case_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const case_dest_path = try testingDbPath(&case_dest_buffer, tmp.sub_path[0..], "reserved-case.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table _zova_meta (key text primary key, value text not null)");
    }

    try std.testing.expectError(error.ZovaNameConflict, convertSqliteToZova(source_path, meta_dest_path));

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("drop table _zova_meta; create table _zova_user_data (id integer primary key)");
    }

    try std.testing.expectError(error.ZovaNameConflict, convertSqliteToZova(source_path, prefix_dest_path));

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("drop table _zova_user_data; create table _ZOVA_case (id integer primary key)");
    }

    try std.testing.expectError(error.ZovaNameConflict, convertSqliteToZova(source_path, case_dest_path));
}

test "failed conversion cleans up destination file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "cleanup.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "cleanup.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table _zova_user_data (id integer primary key)");
    }

    try std.testing.expectError(error.ZovaNameConflict, convertSqliteToZova(source_path, dest_path));
    try std.testing.expectError(error.NotZovaDatabase, Database.open(dest_path));
}
