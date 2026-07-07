//! Native vector storage and exact search implementation.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova_error = @import("zova_error.zig");

pub const Error = zova_error.Error;

pub const vector_collections_table = "_zova_vector_collections";
pub const vectors_table = "_zova_vectors";
const max_vector_collection_name_bytes: usize = 255;
pub const max_vector_dimensions: u32 = 16_384;

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

/// Raw element type stored by a Zova vector collection.
///
/// `f16` values are IEEE 754 binary16 bit patterns transported as `u16`.
/// `i8` values are raw signed bytes. Zova does not quantize or dequantize
/// either type.
pub const VectorElementType = enum {
    f32,
    f16,
    i8,
};

/// Required options for creating a native vector collection.
///
/// The metric is explicit by design; Zova does not guess distance semantics.
/// `element_type` defaults to `f32` for compatibility with earlier APIs.
pub const VectorCollectionOptions = struct {
    dimensions: u32,
    metric: VectorMetric,
    element_type: VectorElementType = .f32,
};

/// Owned metadata for one native vector collection.
///
/// `name` is heap-owned. `vector_count` counts private Zova vector rows in the
/// collection; application metadata rows that reference vector ids remain in
/// user SQL tables and are not counted here.
pub const VectorCollectionInfo = struct {
    name: []u8,
    dimensions: u32,
    metric: VectorMetric,
    element_type: VectorElementType,
    vector_count: u64,

    /// Free the owned collection name.
    pub fn deinit(self: *VectorCollectionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Owned list of vector collection metadata rows.
///
/// The list returned by `Database.listVectorCollections` is sorted by
/// ascending collection name.
pub const VectorCollectionList = struct {
    items: []VectorCollectionInfo,

    /// Free every owned collection name and the item slice.
    pub fn deinit(self: *VectorCollectionList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

/// Input row for `Database.putVectors`.
///
/// Vector ids are application-provided UTF-8 text ids scoped to a collection.
/// Values are stored exactly as finite little-endian `f32` bytes.
pub const VectorInput = struct {
    id: []const u8,
    values: []const f32,
};

/// Typed input row for `Database.putVectorsTyped`.
pub const TypedVectorInput = struct {
    id: []const u8,
    values: VectorValuesConst,
};

/// Borrowed typed vector values.
pub const VectorValuesConst = union(VectorElementType) {
    f32: []const f32,
    f16: []const u16,
    i8: []const i8,
};

/// Owned typed vector values.
pub const VectorValuesOwned = union(VectorElementType) {
    f32: []f32,
    f16: []u16,
    i8: []i8,

    pub fn asConst(self: VectorValuesOwned) VectorValuesConst {
        return switch (self) {
            .f32 => |values| .{ .f32 = values },
            .f16 => |values| .{ .f16 = values },
            .i8 => |values| .{ .i8 = values },
        };
    }

    pub fn deinit(self: VectorValuesOwned, allocator: std.mem.Allocator) void {
        switch (self) {
            .f32 => |values| allocator.free(values),
            .f16 => |values| allocator.free(values),
            .i8 => |values| allocator.free(values),
        }
    }
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

/// Owned typed vector row returned by `Database.getVectorTyped`.
pub const TypedVector = struct {
    id: []u8,
    values: VectorValuesOwned,

    /// Free the owned id and value buffers.
    pub fn deinit(self: *TypedVector, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.values.deinit(allocator);
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

pub const StorageSchema = enum {
    main,
    vector_store,

    pub fn prefix(self: StorageSchema) []const u8 {
        return switch (self) {
            .main => "main.",
            .vector_store => "vector_store.",
        };
    }
};

const CollectionMetadata = struct {
    dimensions: u32,
    metric: VectorMetric,
    element_type: VectorElementType,
};

pub const collections_schema_sql =
    \\create table _zova_vector_collections (
    \\  name text not null primary key check (length(name) > 0 and length(name) <= 255),
    \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
    \\  metric text not null check (metric in ('cosine', 'l2', 'dot')),
    \\  element_type text not null check (element_type in ('f32', 'f16', 'i8'))
    \\)
;
pub const vectors_schema_sql =
    \\create table _zova_vectors (
    \\  collection_name text not null,
    \\  vector_id text not null check (length(vector_id) > 0),
    \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
    \\  "values" blob not null check (length("values") > 0),
    \\  primary key (collection_name, vector_id),
    \\  foreign key (collection_name) references _zova_vector_collections(name)
    \\)
;

pub const Database = struct {
    sqlite_db: *sqlite.Database,
    storage_schema: StorageSchema = .main,

    fn prepareSchema(self: *Database, comptime sql_format: []const u8, args: anytype) Error!sqlite.Statement {
        var sql_buffer: [4096]u8 = undefined;
        const sql = std.fmt.bufPrintZ(&sql_buffer, sql_format, args) catch return error.SqliteError;
        return try self.sqlite_db.prepare(sql);
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

        var insert = try self.prepareSchema(
            \\insert into {s}_zova_vector_collections (name, dimensions, metric, element_type)
            \\values (?, ?, ?, ?)
        , .{self.storage_schema.prefix()});
        defer insert.deinit();

        try insert.bindText(1, name);
        try insert.bindInt64(2, @intCast(options.dimensions));
        try insert.bindText(3, vectorMetricText(options.metric));
        try insert.bindText(4, vectorElementTypeText(options.element_type));
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

        var stmt = try self.prepareSchema(
            \\select count(*)
            \\from {s}_zova_vector_collections
            \\where name = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindText(1, name);
        const step = try stmt.step();
        std.debug.assert(step == .row);
        return stmt.columnInt64(0) == 1;
    }

    /// Return owned metadata for one existing vector collection.
    ///
    /// Missing valid names return `error.VectorCollectionNotFound`; invalid
    /// names return `error.VectorInvalid`. The returned name is owned memory
    /// and must be freed with `VectorCollectionInfo.deinit`.
    pub fn vectorCollectionInfo(
        self: *Database,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) Error!VectorCollectionInfo {
        try validateVectorCollectionName(name);

        var stmt = try self.prepareSchema(
            \\select c.name, c.dimensions, c.metric, c.element_type, count(v.vector_id)
            \\from {s}_zova_vector_collections c
            \\left join {s}_zova_vectors v on v.collection_name = c.name
            \\where c.name = ?
            \\group by c.name, c.dimensions, c.metric, c.element_type
        , .{ self.storage_schema.prefix(), self.storage_schema.prefix() });
        defer stmt.deinit();

        try stmt.bindText(1, name);
        return switch (try stmt.step()) {
            .done => error.VectorCollectionNotFound,
            .row => try vectorCollectionInfoFromRow(allocator, &stmt),
        };
    }

    /// List all vector collections sorted by ascending name.
    ///
    /// Each returned collection name is owned. Call
    /// `VectorCollectionList.deinit` with the same allocator to release the
    /// list.
    pub fn listVectorCollections(
        self: *Database,
        allocator: std.mem.Allocator,
    ) Error!VectorCollectionList {
        var stmt = try self.prepareSchema(
            \\select c.name, c.dimensions, c.metric, c.element_type, count(v.vector_id)
            \\from {s}_zova_vector_collections c
            \\left join {s}_zova_vectors v on v.collection_name = c.name
            \\group by c.name, c.dimensions, c.metric, c.element_type
            \\order by c.name asc
        , .{ self.storage_schema.prefix(), self.storage_schema.prefix() });
        defer stmt.deinit();

        var items: std.ArrayList(VectorCollectionInfo) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        while ((try stmt.step()) == .row) {
            const info = try vectorCollectionInfoFromRow(allocator, &stmt);
            items.append(allocator, info) catch |err| {
                var cleanup = info;
                cleanup.deinit(allocator);
                return err;
            };
        }

        return .{ .items = try items.toOwnedSlice(allocator) };
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
        return self.putVectorTyped(collection_name, vector_id, .{ .f32 = values });
    }

    /// Store or replace one typed vector row in a collection.
    pub fn putVectorTyped(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
        values: VectorValuesConst,
    ) Error!void {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateTypedVectorInput(collection, .{ .id = vector_id, .values = values });
        try self.writeTypedVectorRows(collection_name, collection, &[_]TypedVectorInput{.{ .id = vector_id, .values = values }});
    }

    /// Store or replace multiple vector rows in a collection.
    ///
    /// Batch writes use the same upsert semantics as `putVector`. Duplicate ids
    /// inside the batch are applied in input order, so the last entry wins.
    /// Zova validates the whole batch before writing any row. This method is a
    /// sequence of normal SQLite statements and can participate in a
    /// caller-owned transaction.
    pub fn putVectors(
        self: *Database,
        collection_name: []const u8,
        vectors: []const VectorInput,
    ) Error!void {
        if (vectors.len == 0) {
            try validateVectorCollectionName(collection_name);
            _ = try loadVectorCollection(self, collection_name);
            return;
        }

        const typed_vectors = try std.heap.page_allocator.alloc(TypedVectorInput, vectors.len);
        defer std.heap.page_allocator.free(typed_vectors);
        for (vectors, typed_vectors) |vector, *typed| {
            typed.* = .{ .id = vector.id, .values = .{ .f32 = vector.values } };
        }
        return self.putVectorsTyped(collection_name, typed_vectors);
    }

    /// Store or replace multiple typed vector rows in a collection.
    pub fn putVectorsTyped(
        self: *Database,
        collection_name: []const u8,
        vectors: []const TypedVectorInput,
    ) Error!void {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        for (vectors) |vector| try validateTypedVectorInput(collection, vector);
        try self.writeTypedVectorRows(collection_name, collection, vectors);
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
        var typed = try self.getVectorTyped(allocator, collection_name, vector_id);
        errdefer typed.deinit(allocator);
        return switch (typed.values) {
            .f32 => |values| .{
                .id = typed.id,
                .values = values,
            },
            else => error.VectorInvalid,
        };
    }

    /// Load one typed vector row into owned memory.
    pub fn getVectorTyped(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        vector_id: []const u8,
    ) Error!TypedVector {
        try validateVectorCollectionName(collection_name);
        try validateVectorId(vector_id);

        const collection = try loadVectorCollection(self, collection_name);

        var stmt = try self.prepareSchema(
            \\select vector_id, dimensions, "values"
            \\from {s}_zova_vectors
            \\where collection_name = ? and vector_id = ?
        , .{self.storage_schema.prefix()});
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

                const values = try decodeValuesLe(allocator, collection.element_type, stmt.columnBlob(2), collection.dimensions);
                errdefer values.deinit(allocator);

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

        var stmt = try self.prepareSchema(
            \\select 1
            \\from {s}_zova_vectors
            \\where collection_name = ? and vector_id = ?
            \\limit 1
        , .{self.storage_schema.prefix()});
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

        var stmt = try self.prepareSchema("delete from {s}_zova_vectors where collection_name = ? and vector_id = ?", .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);
        try stmt.bindText(2, vector_id);
        std.debug.assert((try stmt.step()) == .done);

        if (self.sqlite_db.changes() == 0) return error.VectorNotFound;
    }

    /// Delete a vector collection and all private vector rows in it.
    ///
    /// User SQL rows that store collection names or vector ids are
    /// application-owned and are not scanned or mutated. This method uses
    /// ordinary SQLite deletes and can participate in a caller-owned
    /// transaction.
    pub fn deleteVectorCollection(self: *Database, name: []const u8) Error!void {
        try validateVectorCollectionName(name);
        _ = try loadVectorCollection(self, name);

        var delete_vectors = try self.prepareSchema("delete from {s}_zova_vectors where collection_name = ?", .{self.storage_schema.prefix()});
        defer delete_vectors.deinit();
        try delete_vectors.bindText(1, name);
        std.debug.assert((try delete_vectors.step()) == .done);

        var delete_collection = try self.prepareSchema("delete from {s}_zova_vector_collections where name = ?", .{self.storage_schema.prefix()});
        defer delete_collection.deinit();
        try delete_collection.bindText(1, name);
        std.debug.assert((try delete_collection.step()) == .done);
        if (self.sqlite_db.changes() == 0) return error.VectorCollectionNotFound;
    }

    /// Search one vector collection with an exact flat scan.
    ///
    /// Search is collection-wide. It does not inspect labels, join user
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
        return self.searchVectorsTyped(allocator, collection_name, .{ .f32 = query }, limit);
    }

    /// Search one vector collection with an exact typed flat scan.
    pub fn searchVectorsTyped(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: VectorValuesConst,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorValues(collection, query);

        return self.searchAllVectors(allocator, collection_name, collection, query, limit, null, null);
    }

    /// Search one vector collection with an exact flat scan and distance cap.
    ///
    /// `max_distance` uses Zova's unified lower-is-better distance model and is
    /// inclusive: results whose distance equals the threshold are returned.
    /// Negative thresholds are valid for dot-product collections because dot
    /// search stores distance as negative dot product.
    pub fn searchVectorsWithin(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: []const f32,
        max_distance: f64,
        limit: usize,
    ) Error!VectorSearchResults {
        return self.searchVectorsWithinTyped(allocator, collection_name, .{ .f32 = query }, max_distance, limit);
    }

    /// Search one typed vector collection with an exact flat scan and distance cap.
    pub fn searchVectorsWithinTyped(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: VectorValuesConst,
        max_distance: f64,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorValues(collection, query);
        try validateVectorSearchThreshold(max_distance);

        return self.searchAllVectors(allocator, collection_name, collection, query, limit, max_distance, null);
    }

    /// Search one vector collection over a caller-supplied candidate id set.
    ///
    /// This is the SQL-filter-first vector search path: callers select eligible
    /// vector ids from their own SQL metadata tables, then Zova ranks only
    /// those candidates by the collection metric. Missing candidate ids are
    /// skipped. Duplicate candidate ids are considered once. Results are sorted
    /// by ascending distance and then by ascending vector id.
    pub fn searchVectorsIn(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: []const f32,
        candidate_ids: []const []const u8,
        limit: usize,
    ) Error!VectorSearchResults {
        return self.searchVectorsInTyped(allocator, collection_name, .{ .f32 = query }, candidate_ids, limit);
    }

    /// Search one typed vector collection over a caller-supplied candidate id set.
    pub fn searchVectorsInTyped(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: VectorValuesConst,
        candidate_ids: []const []const u8,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorValues(collection, query);

        return self.searchCandidateVectors(allocator, collection_name, collection, query, candidate_ids, limit, null, null);
    }

    /// Search one vector collection over candidates with an inclusive distance cap.
    pub fn searchVectorsInWithin(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: []const f32,
        candidate_ids: []const []const u8,
        max_distance: f64,
        limit: usize,
    ) Error!VectorSearchResults {
        return self.searchVectorsInWithinTyped(allocator, collection_name, .{ .f32 = query }, candidate_ids, max_distance, limit);
    }

    /// Search one typed vector collection over candidates with an inclusive distance cap.
    pub fn searchVectorsInWithinTyped(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: VectorValuesConst,
        candidate_ids: []const []const u8,
        max_distance: f64,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorValues(collection, query);
        try validateVectorSearchThreshold(max_distance);

        return self.searchCandidateVectors(allocator, collection_name, collection, query, candidate_ids, limit, max_distance, null);
    }

    /// Search one vector collection using an existing vector as the query.
    ///
    /// The source vector is loaded from the same collection, validated as
    /// stored Zova data, and excluded from the result set. Missing source ids
    /// return `error.VectorNotFound`.
    pub fn searchVectorsById(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        source_vector_id: []const u8,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        try validateVectorId(source_vector_id);
        const collection = try loadVectorCollection(self, collection_name);
        const query = try self.loadVectorValuesForSearch(allocator, collection_name, collection, source_vector_id);
        defer query.deinit(allocator);

        return self.searchAllVectors(allocator, collection_name, collection, vectorValuesConst(query), limit, null, source_vector_id);
    }

    /// Search candidates using an existing vector as the query.
    ///
    /// Candidate ids are validated, deduplicated, and missing candidates are
    /// skipped. The source id is excluded even if supplied as a candidate.
    pub fn searchVectorsByIdIn(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        source_vector_id: []const u8,
        candidate_ids: []const []const u8,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        try validateVectorId(source_vector_id);
        const collection = try loadVectorCollection(self, collection_name);
        const query = try self.loadVectorValuesForSearch(allocator, collection_name, collection, source_vector_id);
        defer query.deinit(allocator);

        return self.searchCandidateVectors(allocator, collection_name, collection, vectorValuesConst(query), candidate_ids, limit, null, source_vector_id);
    }

    /// Search by existing vector id with an inclusive distance cap.
    pub fn searchVectorsByIdWithin(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        source_vector_id: []const u8,
        max_distance: f64,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        try validateVectorId(source_vector_id);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorSearchThreshold(max_distance);
        const query = try self.loadVectorValuesForSearch(allocator, collection_name, collection, source_vector_id);
        defer query.deinit(allocator);

        return self.searchAllVectors(allocator, collection_name, collection, vectorValuesConst(query), limit, max_distance, source_vector_id);
    }

    /// Search candidates by existing vector id with an inclusive distance cap.
    pub fn searchVectorsByIdInWithin(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        source_vector_id: []const u8,
        candidate_ids: []const []const u8,
        max_distance: f64,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        try validateVectorId(source_vector_id);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorSearchThreshold(max_distance);
        const query = try self.loadVectorValuesForSearch(allocator, collection_name, collection, source_vector_id);
        defer query.deinit(allocator);

        return self.searchCandidateVectors(allocator, collection_name, collection, vectorValuesConst(query), candidate_ids, limit, max_distance, source_vector_id);
    }

    fn searchAllVectors(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        query: VectorValuesConst,
        limit: usize,
        max_distance: ?f64,
        exclude_id: ?[]const u8,
    ) Error!VectorSearchResults {
        var results: std.ArrayList(VectorSearchResult) = .empty;
        errdefer {
            freeSearchItems(allocator, results.items);
            results.deinit(allocator);
        }

        if (limit == 0) {
            return .{ .items = try results.toOwnedSlice(allocator) };
        }

        var stmt = try self.prepareSchema(
            \\select vector_id, dimensions, "values"
            \\from {s}_zova_vectors
            \\where collection_name = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);
        while ((try stmt.step()) == .row) {
            const vector_id = stmt.columnText(0);
            if (exclude_id) |excluded| {
                if (std.mem.eql(u8, vector_id, excluded)) continue;
            }

            try validateStoredVectorDimensions(collection.dimensions, stmt.columnInt64(1));

            const distance = try vectorDistanceFromEncoded(
                collection.element_type,
                collection.metric,
                query,
                stmt.columnBlob(2),
                collection.dimensions,
            );
            if (!distanceWithinThreshold(distance, max_distance)) continue;
            try maybeInsertSearchResult(allocator, &results, limit, vector_id, distance);
        }

        const items = try results.toOwnedSlice(allocator);
        std.mem.sort(VectorSearchResult, items, {}, searchResultLessThan);
        return .{ .items = items };
    }

    fn searchCandidateVectors(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        query: VectorValuesConst,
        candidate_ids: []const []const u8,
        limit: usize,
        max_distance: ?f64,
        exclude_id: ?[]const u8,
    ) Error!VectorSearchResults {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        for (candidate_ids) |candidate_id| {
            try validateVectorId(candidate_id);
            if (exclude_id) |excluded| {
                if (std.mem.eql(u8, candidate_id, excluded)) continue;
            }
            if (!seen.contains(candidate_id)) {
                try seen.put(candidate_id, {});
            }
        }

        var results: std.ArrayList(VectorSearchResult) = .empty;
        errdefer {
            freeSearchItems(allocator, results.items);
            results.deinit(allocator);
        }

        if (limit == 0 or seen.count() == 0) {
            return .{ .items = try results.toOwnedSlice(allocator) };
        }

        var stmt = try self.prepareSchema(
            \\select dimensions, "values"
            \\from {s}_zova_vectors
            \\where collection_name = ? and vector_id = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);

        var iterator = seen.keyIterator();
        while (iterator.next()) |candidate_id| {
            try stmt.bindText(2, candidate_id.*);

            switch (try stmt.step()) {
                .done => {},
                .row => {
                    try validateStoredVectorDimensions(collection.dimensions, stmt.columnInt64(0));

                    const distance = try vectorDistanceFromEncoded(
                        collection.element_type,
                        collection.metric,
                        query,
                        stmt.columnBlob(1),
                        collection.dimensions,
                    );
                    if (distanceWithinThreshold(distance, max_distance)) {
                        try maybeInsertSearchResult(allocator, &results, limit, candidate_id.*, distance);
                    }
                },
            }

            try stmt.reset();
        }

        const items = try results.toOwnedSlice(allocator);
        std.mem.sort(VectorSearchResult, items, {}, searchResultLessThan);
        return .{ .items = items };
    }

    fn loadVectorValuesForSearch(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        vector_id: []const u8,
    ) Error!VectorValuesOwned {
        var stmt = try self.prepareSchema(
            \\select dimensions, "values"
            \\from {s}_zova_vectors
            \\where collection_name = ? and vector_id = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);
        try stmt.bindText(2, vector_id);

        return switch (try stmt.step()) {
            .done => error.VectorNotFound,
            .row => {
                try validateStoredVectorDimensions(collection.dimensions, stmt.columnInt64(0));
                const values = try decodeValuesLe(allocator, collection.element_type, stmt.columnBlob(1), collection.dimensions);
                errdefer values.deinit(allocator);
                try validateStoredVectorValues(collection, vectorValuesConst(values));
                return values;
            },
        };
    }

    fn writeTypedVectorRows(
        self: *Database,
        collection_name: []const u8,
        collection: CollectionMetadata,
        vectors: []const TypedVectorInput,
    ) Error!void {
        if (vectors.len == 0) return;

        var stmt = try self.prepareSchema(
            \\insert into {s}_zova_vectors (collection_name, vector_id, dimensions, "values")
            \\values (?, ?, ?, ?)
            \\on conflict(collection_name, vector_id) do update set
            \\  dimensions = excluded.dimensions,
            \\  "values" = excluded."values"
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        for (vectors) |vector| {
            const encoded = try encodeValuesLe(std.heap.page_allocator, vector.values);
            defer std.heap.page_allocator.free(encoded);

            try stmt.bindText(1, collection_name);
            try stmt.bindText(2, vector.id);
            try stmt.bindInt64(3, @intCast(collection.dimensions));
            try stmt.bindBlob(4, encoded);
            std.debug.assert((try stmt.step()) == .done);
            try stmt.reset();
            try stmt.clearBindings();
        }
    }
};

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

fn validateVectorValues(collection: CollectionMetadata, values: VectorValuesConst) Error!void {
    if (vectorValuesElementType(values) != collection.element_type) return error.VectorInvalid;
    if (vectorValuesLen(values) != collection.dimensions) return error.VectorDimensionMismatch;
    var norm_squared: f64 = 0;
    for (0..vectorValuesLen(values)) |index| {
        const value_f64 = try inputValueAsF64(values, index);
        norm_squared += value_f64 * value_f64;
    }
    if (collection.metric == .cosine and norm_squared == 0) return error.VectorInvalid;
}

fn validateTypedVectorInput(collection: CollectionMetadata, input: TypedVectorInput) Error!void {
    try validateVectorId(input.id);
    try validateVectorValues(collection, input.values);
}

fn validateVectorSearchThreshold(max_distance: f64) Error!void {
    if (std.math.isNan(max_distance) or std.math.isInf(max_distance)) return error.VectorInvalid;
}

fn validateStoredVectorDimensions(expected_dimensions: u32, stored_dimensions: i64) Error!void {
    if (stored_dimensions < 0) return error.VectorCorrupt;
    if (@as(u64, @intCast(stored_dimensions)) != expected_dimensions) return error.VectorCorrupt;
}

fn validateStoredVectorValues(collection: CollectionMetadata, values: VectorValuesConst) Error!void {
    if (vectorValuesElementType(values) != collection.element_type) return error.VectorCorrupt;
    if (vectorValuesLen(values) != collection.dimensions) return error.VectorCorrupt;
    var norm_squared: f64 = 0;
    for (0..vectorValuesLen(values)) |index| {
        const value_f64 = inputValueAsF64(values, index) catch return error.VectorCorrupt;
        norm_squared += value_f64 * value_f64;
    }
    if (collection.metric == .cosine and norm_squared == 0) return error.VectorCorrupt;
}

fn distanceWithinThreshold(distance: f64, max_distance: ?f64) bool {
    if (max_distance) |threshold| {
        return distance <= threshold;
    }
    return true;
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

fn vectorElementTypeText(element_type: VectorElementType) []const u8 {
    return switch (element_type) {
        .f32 => "f32",
        .f16 => "f16",
        .i8 => "i8",
    };
}

fn vectorElementTypeFromText(text: []const u8) Error!VectorElementType {
    if (std.mem.eql(u8, text, "f32")) return .f32;
    if (std.mem.eql(u8, text, "f16")) return .f16;
    if (std.mem.eql(u8, text, "i8")) return .i8;
    return error.NotZovaDatabase;
}

fn loadVectorCollection(db: *Database, name: []const u8) Error!CollectionMetadata {
    var stmt = try db.prepareSchema(
        \\select dimensions, metric, element_type
        \\from {s}_zova_vector_collections
        \\where name = ?
    , .{db.storage_schema.prefix()});
    defer stmt.deinit();

    try stmt.bindText(1, name);
    return switch (try stmt.step()) {
        .done => error.VectorCollectionNotFound,
        .row => {
            const dimensions_i64 = stmt.columnInt64(0);
            if (dimensions_i64 <= 0 or dimensions_i64 > max_vector_dimensions) return error.NotZovaDatabase;
            return .{
                .dimensions = @intCast(dimensions_i64),
                .metric = try vectorMetricFromText(stmt.columnText(1)),
                .element_type = try vectorElementTypeFromText(stmt.columnText(2)),
            };
        },
    };
}

fn vectorCollectionInfoFromRow(allocator: std.mem.Allocator, stmt: *sqlite.Statement) Error!VectorCollectionInfo {
    const dimensions_i64 = stmt.columnInt64(1);
    if (dimensions_i64 <= 0 or dimensions_i64 > max_vector_dimensions) return error.NotZovaDatabase;

    const name = try allocator.dupe(u8, stmt.columnText(0));
    errdefer allocator.free(name);

    return .{
        .name = name,
        .dimensions = @intCast(dimensions_i64),
        .metric = try vectorMetricFromText(stmt.columnText(2)),
        .element_type = try vectorElementTypeFromText(stmt.columnText(3)),
        .vector_count = try sqliteI64ToU64(stmt.columnInt64(4)),
    };
}

fn vectorByteLen(element_type: VectorElementType, dimensions: u32) usize {
    const element_size: usize = switch (element_type) {
        .f32 => @sizeOf(f32),
        .f16 => @sizeOf(u16),
        .i8 => @sizeOf(i8),
    };
    return @as(usize, @intCast(dimensions)) * element_size;
}

pub fn encodeF32Le(allocator: std.mem.Allocator, values: []const f32) Error![]u8 {
    const bytes = try allocator.alloc(u8, values.len * @sizeOf(f32));
    errdefer allocator.free(bytes);

    for (values, 0..) |value, index| {
        const bits: u32 = @bitCast(value);
        std.mem.writeInt(u32, bytes[index * 4 ..][0..4], bits, .little);
    }

    return bytes;
}

fn encodeValuesLe(allocator: std.mem.Allocator, values: VectorValuesConst) Error![]u8 {
    return switch (values) {
        .f32 => |f32_values| encodeF32Le(allocator, f32_values),
        .f16 => |f16_values| encodeF16Le(allocator, f16_values),
        .i8 => |i8_values| encodeI8(allocator, i8_values),
    };
}

pub fn encodeF16Le(allocator: std.mem.Allocator, values: []const u16) Error![]u8 {
    const bytes = try allocator.alloc(u8, values.len * @sizeOf(u16));
    errdefer allocator.free(bytes);

    for (values, 0..) |value, index| {
        std.mem.writeInt(u16, bytes[index * 2 ..][0..2], value, .little);
    }

    return bytes;
}

pub fn encodeI8(allocator: std.mem.Allocator, values: []const i8) Error![]u8 {
    const bytes = try allocator.alloc(u8, values.len);
    errdefer allocator.free(bytes);

    for (values, 0..) |value, index| {
        bytes[index] = @bitCast(value);
    }

    return bytes;
}

fn decodeValuesLe(
    allocator: std.mem.Allocator,
    element_type: VectorElementType,
    bytes: []const u8,
    dimensions: u32,
) Error!VectorValuesOwned {
    return switch (element_type) {
        .f32 => .{ .f32 = try decodeF32Le(allocator, bytes, dimensions) },
        .f16 => .{ .f16 = try decodeF16Le(allocator, bytes, dimensions) },
        .i8 => .{ .i8 = try decodeI8(allocator, bytes, dimensions) },
    };
}

fn decodeF32Le(allocator: std.mem.Allocator, bytes: []const u8, dimensions: u32) Error![]f32 {
    if (bytes.len != vectorByteLen(.f32, dimensions)) return error.VectorCorrupt;

    const values = try allocator.alloc(f32, dimensions);
    errdefer allocator.free(values);

    for (values, 0..) |*value, index| {
        const bits = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
        value.* = @bitCast(bits);
        if (std.math.isNan(value.*) or std.math.isInf(value.*)) return error.VectorCorrupt;
    }

    return values;
}

fn decodeF16Le(allocator: std.mem.Allocator, bytes: []const u8, dimensions: u32) Error![]u16 {
    if (bytes.len != vectorByteLen(.f16, dimensions)) return error.VectorCorrupt;

    const values = try allocator.alloc(u16, dimensions);
    errdefer allocator.free(values);

    for (values, 0..) |*value, index| {
        value.* = std.mem.readInt(u16, bytes[index * 2 ..][0..2], .little);
        if (!f16BitsFinite(value.*)) return error.VectorCorrupt;
    }

    return values;
}

fn decodeI8(allocator: std.mem.Allocator, bytes: []const u8, dimensions: u32) Error![]i8 {
    if (bytes.len != vectorByteLen(.i8, dimensions)) return error.VectorCorrupt;

    const values = try allocator.alloc(i8, dimensions);
    errdefer allocator.free(values);

    for (values, 0..) |*value, index| {
        value.* = @bitCast(bytes[index]);
    }

    return values;
}

fn decodeF32LeAt(bytes: []const u8, index: usize) f32 {
    const bits = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    return @bitCast(bits);
}

fn vectorDistanceFromEncoded(
    element_type: VectorElementType,
    metric: VectorMetric,
    query: VectorValuesConst,
    encoded_values: []const u8,
    dimensions: u32,
) Error!f64 {
    if (vectorValuesElementType(query) != element_type) return error.VectorInvalid;
    if (vectorValuesLen(query) != dimensions) return error.VectorDimensionMismatch;
    if (encoded_values.len != vectorByteLen(element_type, dimensions)) return error.VectorCorrupt;

    return switch (metric) {
        .cosine => cosineDistanceFromEncoded(element_type, query, encoded_values),
        .l2 => l2DistanceFromEncoded(element_type, query, encoded_values),
        .dot => dotDistanceFromEncoded(element_type, query, encoded_values),
    };
}

fn cosineDistanceFromEncoded(element_type: VectorElementType, query: VectorValuesConst, encoded_values: []const u8) Error!f64 {
    var dot: f64 = 0;
    var query_norm: f64 = 0;
    var stored_norm: f64 = 0;

    for (0..vectorValuesLen(query)) |index| {
        const query_f64 = try inputValueAsF64(query, index);
        const stored_f64 = try encodedValueAsF64(element_type, encoded_values, index);
        dot += query_f64 * stored_f64;
        query_norm += query_f64 * query_f64;
        stored_norm += stored_f64 * stored_f64;
    }

    if (query_norm == 0) return error.VectorInvalid;
    if (stored_norm == 0) return error.VectorCorrupt;
    return 1.0 - (dot / (@sqrt(query_norm) * @sqrt(stored_norm)));
}

fn l2DistanceFromEncoded(element_type: VectorElementType, query: VectorValuesConst, encoded_values: []const u8) Error!f64 {
    var sum: f64 = 0;
    for (0..vectorValuesLen(query)) |index| {
        const diff = try inputValueAsF64(query, index) - try encodedValueAsF64(element_type, encoded_values, index);
        sum += diff * diff;
    }
    return @sqrt(sum);
}

fn dotDistanceFromEncoded(element_type: VectorElementType, query: VectorValuesConst, encoded_values: []const u8) Error!f64 {
    var dot: f64 = 0;
    for (0..vectorValuesLen(query)) |index| {
        dot += try inputValueAsF64(query, index) * try encodedValueAsF64(element_type, encoded_values, index);
    }
    return -dot;
}

fn vectorValuesElementType(values: VectorValuesConst) VectorElementType {
    return switch (values) {
        .f32 => .f32,
        .f16 => .f16,
        .i8 => .i8,
    };
}

fn vectorValuesLen(values: VectorValuesConst) usize {
    return switch (values) {
        .f32 => |typed| typed.len,
        .f16 => |typed| typed.len,
        .i8 => |typed| typed.len,
    };
}

fn vectorValuesConst(values: VectorValuesOwned) VectorValuesConst {
    return switch (values) {
        .f32 => |typed| .{ .f32 = typed },
        .f16 => |typed| .{ .f16 = typed },
        .i8 => |typed| .{ .i8 = typed },
    };
}

fn inputValueAsF64(values: VectorValuesConst, index: usize) Error!f64 {
    return switch (values) {
        .f32 => |typed| {
            const value = typed[index];
            if (std.math.isNan(value) or std.math.isInf(value)) return error.VectorInvalid;
            return f32ToF64(value);
        },
        .f16 => |typed| {
            const value = typed[index];
            if (!f16BitsFinite(value)) return error.VectorInvalid;
            return f16BitsToF64(value);
        },
        .i8 => |typed| @floatFromInt(typed[index]),
    };
}

fn encodedValueAsF64(element_type: VectorElementType, encoded_values: []const u8, index: usize) Error!f64 {
    return switch (element_type) {
        .f32 => {
            const value = decodeF32LeAt(encoded_values, index);
            if (std.math.isNan(value) or std.math.isInf(value)) return error.VectorCorrupt;
            return f32ToF64(value);
        },
        .f16 => {
            const offset = index * @sizeOf(u16);
            const bits = std.mem.readInt(u16, encoded_values[offset..][0..2], .little);
            if (!f16BitsFinite(bits)) return error.VectorCorrupt;
            return f16BitsToF64(bits);
        },
        .i8 => @floatFromInt(@as(i8, @bitCast(encoded_values[index]))),
    };
}

fn f16BitsFinite(bits: u16) bool {
    return ((bits >> 10) & 0x1f) != 0x1f;
}

fn f16BitsToF64(bits: u16) f64 {
    const sign = @as(u64, bits >> 15) << 63;
    const exponent = (bits >> 10) & 0x1f;
    const fraction = bits & 0x03ff;

    if (exponent == 0x1f) {
        const quiet_nan = if (fraction == 0) 0 else @as(u64, 1) << 51;
        return @bitCast(sign | (@as(u64, 0x7ff) << 52) | (@as(u64, fraction) << 42) | quiet_nan);
    }

    if (exponent == 0) {
        if (fraction == 0) return @bitCast(sign);
        const top_bit: u4 = @intCast(15 - @clz(fraction));
        const exponent64 = @as(u64, top_bit) + 999;
        const mantissa_source = @as(u64, fraction) - (@as(u64, 1) << top_bit);
        const shift: u6 = @intCast(52 - @as(u6, top_bit));
        const mantissa = mantissa_source << shift;
        return @bitCast(sign | (exponent64 << 52) | mantissa);
    }

    const exponent64 = @as(u64, exponent) + 1008;
    const mantissa = @as(u64, fraction) << 42;
    return @bitCast(sign | (exponent64 << 52) | mantissa);
}

pub fn f32ToF64(value: f32) f64 {
    const bits: u32 = @bitCast(value);
    const sign = @as(u64, bits >> 31) << 63;
    const exponent = (bits >> 23) & 0xff;
    const fraction = bits & 0x7fffff;

    if (exponent == 0xff) {
        const quiet_nan = if (fraction == 0) 0 else @as(u64, 1) << 51;
        return @bitCast(sign | (@as(u64, 0x7ff) << 52) | (@as(u64, fraction) << 29) | quiet_nan);
    }

    if (exponent == 0) {
        if (fraction == 0) return @bitCast(sign);
        const top_bit: u6 = @intCast(31 - @clz(fraction));
        const exponent64 = @as(u64, top_bit) + 874;
        const mantissa_source = @as(u64, fraction) - (@as(u64, 1) << top_bit);
        const mantissa = mantissa_source << @intCast(52 - top_bit);
        return @bitCast(sign | (exponent64 << 52) | mantissa);
    }

    const exponent64 = @as(u64, exponent) + 896;
    const mantissa = @as(u64, fraction) << 29;
    return @bitCast(sign | (exponent64 << 52) | mantissa);
}

test "f32ToF64 matches Zig float widening" {
    const values = [_]f32{
        0.0,
        -0.0,
        1.0,
        -1.0,
        1.5,
        -12345.75,
        std.math.floatMin(f32),
        std.math.floatMax(f32),
        @as(f32, @bitCast(@as(u32, 1))),
        @as(f32, @bitCast(@as(u32, 0x007fffff))),
    };
    for (values) |value| {
        const expected: f64 = @floatCast(value);
        try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(f32ToF64(value))));
    }
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

fn sqliteI64ToU64(value: i64) Error!u64 {
    if (value < 0) return error.VectorCorrupt;
    return @intCast(value);
}

fn isReservedZovaName(name: []const u8) bool {
    const reserved_prefix = "_zova_";
    return name.len >= reserved_prefix.len and
        std.ascii.eqlIgnoreCase(name[0..reserved_prefix.len], reserved_prefix);
}
