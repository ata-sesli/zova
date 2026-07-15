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
/// Values must use the collection's raw element type.
pub const VectorInput = struct {
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
pub const Vector = struct {
    id: []u8,
    values: VectorValuesOwned,

    /// Free the owned id and value buffers.
    pub fn deinit(self: *Vector, allocator: std.mem.Allocator) void {
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

/// Aggregation mode for raw-i8 multi-query cosine search.
pub const MultiI8CosineSearchMode = enum {
    /// Score every eligible vector by the least similar query.
    global_min_cosine,
    /// Retain a deterministic query-prefilter first, then aggregate only it.
    cbm_prefilter_min_cosine,
};

/// Input for raw-i8 multi-query cosine search.
///
/// All query slices must have the collection's exact dimension and must be
/// non-zero. Results use Zova's lower-is-better distance convention:
/// `max_i(1 - cosine(query[i], candidate))`.
pub const MultiI8CosineSearchOptions = struct {
    queries: []const []const i8,
    candidate_ids: ?[]const []const u8 = null,
    mode: MultiI8CosineSearchMode = .global_min_cosine,
    prefilter_query_index: usize = 0,
    prefilter_limit: usize = 0,
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
    collection_key: i64,
    dimensions: u32,
    metric: VectorMetric,
    element_type: VectorElementType,
};

const candidate_scan_threshold = 128;
const search_heap_threshold = 32;

const PreparedVectorQuery = struct {
    element_type: VectorElementType,
    metric: VectorMetric,
    dimensions: u32,
    values: VectorValuesConst,
    cosine_query_norm: f64 = 0,
    cosine_query_length: f64 = 0,

    fn init(collection: CollectionMetadata, values: VectorValuesConst) Error!PreparedVectorQuery {
        if (vectorValuesElementType(values) != collection.element_type) return error.VectorInvalid;
        if (vectorValuesLen(values) != collection.dimensions) return error.VectorDimensionMismatch;

        var cosine_query_norm: f64 = 0;
        switch (collection.metric) {
            .cosine => {
                cosine_query_norm = switch (values) {
                    .i8 => |typed| blk: {
                        var norm: u64 = 0;
                        for (typed) |value| {
                            const wide: i32 = value;
                            norm += @intCast(wide * wide);
                        }
                        if (norm == 0) return error.VectorInvalid;
                        break :blk u64ToF64Exact(norm);
                    },
                    else => blk: {
                        var norm: f64 = 0;
                        for (0..vectorValuesLen(values)) |index| {
                            const value_f64 = try inputValueAsF64(values, index);
                            norm += value_f64 * value_f64;
                        }
                        if (norm == 0) return error.VectorInvalid;
                        break :blk norm;
                    },
                };
            },
            .l2, .dot => {
                for (0..vectorValuesLen(values)) |index| {
                    _ = try inputValueAsF64(values, index);
                }
            },
        }

        const cosine_query_length = if (collection.metric == .cosine)
            @sqrt(cosine_query_norm)
        else
            0;

        return .{
            .element_type = collection.element_type,
            .metric = collection.metric,
            .dimensions = collection.dimensions,
            .values = values,
            .cosine_query_norm = cosine_query_norm,
            .cosine_query_length = cosine_query_length,
        };
    }

    fn distanceFromEncoded(self: PreparedVectorQuery, encoded_values: []const u8) Error!f64 {
        return self.distanceFromEncodedWithStoredNorm(encoded_values, null);
    }

    fn distanceFromEncodedWithStoredNorm(self: PreparedVectorQuery, encoded_values: []const u8, stored_norm_squared: ?f64) Error!f64 {
        if (encoded_values.len != vectorByteLen(self.element_type, self.dimensions)) return error.VectorCorrupt;

        return switch (self.metric) {
            .cosine => switch (self.values) {
                .i8 => |query| if (stored_norm_squared) |norm|
                    i8CosineDistanceFromEncodedWithStoredNorm(query, self.cosine_query_norm, encoded_values, norm)
                else
                    i8CosineDistanceFromEncoded(query, self.cosine_query_norm, encoded_values),
                else => cosineDistanceFromEncodedPrepared(self.element_type, self.values, encoded_values, self.cosine_query_norm),
            },
            .l2 => l2DistanceFromEncoded(self.element_type, self.values, encoded_values),
            .dot => dotDistanceFromEncoded(self.element_type, self.values, encoded_values),
        };
    }

    fn usesStoredNorms(self: PreparedVectorQuery) bool {
        return self.metric == .cosine and self.element_type == .i8;
    }

    fn i8CosineQuery(self: PreparedVectorQuery) ?[]const i8 {
        if (self.metric != .cosine) return null;
        return switch (self.values) {
            .i8 => |query| query,
            else => null,
        };
    }
};

pub const collections_schema_sql =
    \\create table _zova_vector_collections (
    \\  collection_key integer primary key,
    \\  name text not null unique check (length(name) > 0 and length(name) <= 255),
    \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
    \\  metric text not null check (metric in ('cosine', 'l2', 'dot')),
    \\  element_type text not null check (element_type in ('f32', 'f16', 'i8'))
    \\)
;
pub const vectors_schema_sql =
    \\create table _zova_vectors (
    \\  vector_key integer primary key,
    \\  collection_key integer not null,
    \\  vector_id text not null check (length(vector_id) > 0),
    \\  "values" blob not null check (length("values") > 0),
    \\  norm_squared real check (norm_squared is null or norm_squared >= 0),
    \\  unique (collection_key, vector_id),
    \\  foreign key (collection_key) references _zova_vector_collections(collection_key) on delete cascade
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
            \\left join {s}_zova_vectors v on v.collection_key = c.collection_key
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
            \\left join {s}_zova_vectors v on v.collection_key = c.collection_key
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
    /// collection dimensions, element type, and finite-value rules.
    pub fn putVector(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
        values: VectorValuesConst,
    ) Error!void {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorInput(collection, .{ .id = vector_id, .values = values });
        try self.writeVectorRows(collection_name, collection, &[_]VectorInput{.{ .id = vector_id, .values = values }});
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
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        for (vectors) |vector| try validateVectorInput(collection, vector);
        try self.writeVectorRows(collection_name, collection, vectors);
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

        var stmt = try self.prepareSchema(
            \\select vector_id, "values"
            \\from {s}_zova_vectors
            \\where collection_key = ? and vector_id = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindInt64(1, collection.collection_key);
        try stmt.bindText(2, vector_id);

        switch (try stmt.step()) {
            .done => return error.VectorNotFound,
            .row => {
                const stored_id = stmt.columnText(0);
                const id = try allocator.dupe(u8, stored_id);
                errdefer allocator.free(id);

                const values = try decodeValuesLe(allocator, collection.element_type, stmt.columnBlob(1), collection.dimensions);
                errdefer values.deinit(allocator);
                try validateStoredVectorValues(collection, values.asConst());

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
        const collection = try loadVectorCollection(self, collection_name);

        var stmt = try self.prepareSchema(
            \\select 1
            \\from {s}_zova_vectors
            \\where collection_key = ? and vector_id = ?
            \\limit 1
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindInt64(1, collection.collection_key);
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
        const collection = try loadVectorCollection(self, collection_name);

        var stmt = try self.prepareSchema("delete from {s}_zova_vectors where collection_key = ? and vector_id = ?", .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindInt64(1, collection.collection_key);
        try stmt.bindText(2, vector_id);
        std.debug.assert((try stmt.step()) == .done);

        if (self.sqlite_db.changes() == 0) return error.VectorNotFound;
    }

    /// Delete multiple vector rows from an existing collection.
    ///
    /// The complete request is validated before any private row is changed.
    /// Duplicate and missing ids are ignored, which makes replay safe. The
    /// caller is responsible for wrapping this method in a transaction when
    /// atomicity with other Zova operations is required.
    pub fn deleteVectors(
        self: *Database,
        collection_name: []const u8,
        vector_ids: []const []const u8,
    ) Error!void {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        for (vector_ids) |vector_id| try validateVectorId(vector_id);

        try self.sqlite_db.exec(
            \\create temp table if not exists _zova_vector_delete_ids (
            \\  vector_id text primary key
            \\) without rowid
        );
        try self.sqlite_db.exec("delete from temp._zova_vector_delete_ids");

        var insert_id = try self.sqlite_db.prepare(
            "insert or ignore into temp._zova_vector_delete_ids (vector_id) values (?)",
        );
        defer insert_id.deinit();
        for (vector_ids) |vector_id| {
            try insert_id.bindText(1, vector_id);
            std.debug.assert((try insert_id.step()) == .done);
            try insert_id.reset();
        }

        var delete = try self.prepareSchema(
            \\delete from {s}_zova_vectors
            \\where collection_key = ?
            \\  and vector_id in (select vector_id from temp._zova_vector_delete_ids)
        , .{self.storage_schema.prefix()});
        defer delete.deinit();
        try delete.bindInt64(1, collection.collection_key);
        std.debug.assert((try delete.step()) == .done);
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
        query: VectorValuesConst,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        const prepared_query = try PreparedVectorQuery.init(collection, query);

        return self.searchAllVectors(allocator, collection_name, collection, prepared_query, limit, null, null);
    }

    /// Search one raw-i8 cosine collection against multiple queries.
    ///
    /// The returned distance is the greatest individual cosine distance, which
    /// is equal to `1 - min_cosine_similarity`. Results sort by ascending
    /// distance and then ascending vector id.
    pub fn searchMultiI8Cosine(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        options: MultiI8CosineSearchOptions,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        if (collection.element_type != .i8 or collection.metric != .cosine) return error.VectorInvalid;

        var queries: std.ArrayList(PreparedI8CosineQuery) = .empty;
        defer queries.deinit(allocator);
        if (options.queries.len == 0) return error.VectorInvalid;
        try queries.ensureTotalCapacity(allocator, options.queries.len);
        for (options.queries) |query| {
            const prepared = try PreparedVectorQuery.init(collection, .{ .i8 = query });
            queries.appendAssumeCapacity(.{ .values = query, .length = prepared.cosine_query_length });
        }

        return switch (options.mode) {
            .global_min_cosine => if (options.candidate_ids) |candidate_ids|
                self.searchMultiI8CosineCandidates(allocator, collection_name, collection, queries.items, candidate_ids, limit)
            else
                self.searchMultiI8CosineAll(allocator, collection_name, collection, queries.items, limit),
            .cbm_prefilter_min_cosine => self.searchMultiI8CosinePrefilter(
                allocator,
                collection_name,
                collection,
                queries.items,
                options.candidate_ids,
                options.prefilter_query_index,
                options.prefilter_limit,
                limit,
            ),
        };
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
        query: VectorValuesConst,
        max_distance: f64,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        const prepared_query = try PreparedVectorQuery.init(collection, query);
        try validateVectorSearchThreshold(max_distance);

        return self.searchAllVectors(allocator, collection_name, collection, prepared_query, limit, max_distance, null);
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
        query: VectorValuesConst,
        candidate_ids: []const []const u8,
        limit: usize,
    ) Error!VectorSearchResults {
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        const prepared_query = try PreparedVectorQuery.init(collection, query);

        return self.searchCandidateVectors(allocator, collection_name, collection, prepared_query, candidate_ids, limit, null, null);
    }

    /// Search one vector collection over candidates with an inclusive distance cap.
    pub fn searchVectorsInWithin(
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
        const prepared_query = try PreparedVectorQuery.init(collection, query);
        try validateVectorSearchThreshold(max_distance);

        return self.searchCandidateVectors(allocator, collection_name, collection, prepared_query, candidate_ids, limit, max_distance, null);
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
        const prepared_query = try PreparedVectorQuery.init(collection, vectorValuesConst(query));

        return self.searchAllVectors(allocator, collection_name, collection, prepared_query, limit, null, source_vector_id);
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
        const prepared_query = try PreparedVectorQuery.init(collection, vectorValuesConst(query));

        return self.searchCandidateVectors(allocator, collection_name, collection, prepared_query, candidate_ids, limit, null, source_vector_id);
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
        const prepared_query = try PreparedVectorQuery.init(collection, vectorValuesConst(query));

        return self.searchAllVectors(allocator, collection_name, collection, prepared_query, limit, max_distance, source_vector_id);
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
        const prepared_query = try PreparedVectorQuery.init(collection, vectorValuesConst(query));

        return self.searchCandidateVectors(allocator, collection_name, collection, prepared_query, candidate_ids, limit, max_distance, source_vector_id);
    }

    fn searchAllVectors(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        query: PreparedVectorQuery,
        limit: usize,
        max_distance: ?f64,
        exclude_id: ?[]const u8,
    ) Error!VectorSearchResults {
        if (query.i8CosineQuery()) |i8_query| {
            return self.searchAllI8CosineVectors(
                allocator,
                collection_name,
                collection,
                i8_query,
                query.cosine_query_norm,
                query.cosine_query_length,
                limit,
                max_distance,
                exclude_id,
            );
        }

        var results: std.ArrayList(VectorSearchResult) = .empty;
        errdefer {
            freeSearchItems(allocator, results.items);
            results.deinit(allocator);
        }

        if (limit == 0) {
            return .{ .items = try results.toOwnedSlice(allocator) };
        }

        var stmt = try self.prepareSchema(
            \\select vector_id, "values", norm_squared
            \\from {s}_zova_vectors
            \\where collection_key = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindInt64(1, collection.collection_key);
        while ((try stmt.step()) == .row) {
            const vector_id = stmt.columnText(0);
            if (exclude_id) |excluded| {
                if (std.mem.eql(u8, vector_id, excluded)) continue;
            }

            const stored_norm = optionalColumnDouble(&stmt, 2);
            const distance = try query.distanceFromEncodedWithStoredNorm(stmt.columnBlob(1), stored_norm);
            if (!distanceWithinThreshold(distance, max_distance)) continue;
            try maybeInsertSearchResult(allocator, &results, limit, vector_id, distance);
        }

        const items = try results.toOwnedSlice(allocator);
        std.mem.sort(VectorSearchResult, items, {}, searchResultLessThan);
        return .{ .items = items };
    }

    fn searchAllI8CosineVectors(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        query: []const i8,
        query_norm: f64,
        query_length: f64,
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

        _ = collection_name;
        var stmt = try self.prepareSchema(
            \\select vector_id, "values", norm_squared
            \\from {s}_zova_vectors
            \\where collection_key = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindInt64(1, collection.collection_key);
        while ((try stmt.step()) == .row) {
            const vector_id = stmt.columnText(0);
            if (exclude_id) |excluded| {
                if (std.mem.eql(u8, vector_id, excluded)) continue;
            }

            const encoded_values = stmt.columnBlob(1);
            if (encoded_values.len != query.len) return error.VectorCorrupt;
            const distance = if (optionalColumnDouble(&stmt, 2)) |stored_norm|
                try i8CosineDistanceFromEncodedWithQueryLengthSimd(query, query_length, encoded_values, stored_norm)
            else
                try i8CosineDistanceFromEncoded(query, query_norm, encoded_values);
            if (!distanceWithinThreshold(distance, max_distance)) continue;
            try maybeInsertSearchResult(allocator, &results, limit, vector_id, distance);
        }

        const items = try results.toOwnedSlice(allocator);
        std.mem.sort(VectorSearchResult, items, {}, searchResultLessThan);
        return .{ .items = items };
    }

    fn searchMultiI8CosineAll(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        queries: []const PreparedI8CosineQuery,
        limit: usize,
    ) Error!VectorSearchResults {
        var results: std.ArrayList(VectorSearchResult) = .empty;
        errdefer {
            freeSearchItems(allocator, results.items);
            results.deinit(allocator);
        }
        if (limit == 0) return .{ .items = try results.toOwnedSlice(allocator) };

        var stmt = try self.prepareSchema(
            \\select vector_id, "values", norm_squared
            \\from {s}_zova_vectors
            \\where collection_key = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        _ = collection_name;
        try stmt.bindInt64(1, collection.collection_key);
        while ((try stmt.step()) == .row) {
            const encoded_values = stmt.columnBlob(1);
            if (encoded_values.len != collection.dimensions) return error.VectorCorrupt;
            const stored_norm = optionalColumnDouble(&stmt, 2);
            const distance = try multiI8CosineDistance(queries, encoded_values, stored_norm);
            try maybeInsertSearchResult(allocator, &results, limit, stmt.columnText(0), distance);
        }

        const items = try results.toOwnedSlice(allocator);
        std.mem.sort(VectorSearchResult, items, {}, searchResultLessThan);
        return .{ .items = items };
    }

    fn searchMultiI8CosineCandidates(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        queries: []const PreparedI8CosineQuery,
        candidate_ids: []const []const u8,
        limit: usize,
    ) Error!VectorSearchResults {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (candidate_ids) |candidate_id| {
            try validateVectorId(candidate_id);
            if (!seen.contains(candidate_id)) try seen.put(candidate_id, {});
        }

        var results: std.ArrayList(VectorSearchResult) = .empty;
        errdefer {
            freeSearchItems(allocator, results.items);
            results.deinit(allocator);
        }
        if (limit == 0 or seen.count() == 0) return .{ .items = try results.toOwnedSlice(allocator) };

        const collection_vector_count = if (seen.count() >= candidate_scan_threshold)
            try self.countVectorsInCollection(collection.collection_key)
        else
            0;
        if (shouldScanCandidateVectors(seen.count(), collection_vector_count)) {
            try self.searchMultiI8CosineCandidatesByScan(allocator, collection_name, collection, queries, &seen, &results, limit);
        } else {
            var stmt = try self.prepareSchema(
                \\select "values", norm_squared
                \\from {s}_zova_vectors
                \\where collection_key = ? and vector_id = ?
            , .{self.storage_schema.prefix()});
            defer stmt.deinit();

            try stmt.bindInt64(1, collection.collection_key);
            var iterator = seen.keyIterator();
            while (iterator.next()) |candidate_id| {
                try stmt.bindText(2, candidate_id.*);
                switch (try stmt.step()) {
                    .done => {},
                    .row => {
                        const encoded_values = stmt.columnBlob(0);
                        if (encoded_values.len != collection.dimensions) return error.VectorCorrupt;
                        const stored_norm = optionalColumnDouble(&stmt, 1);
                        const distance = try multiI8CosineDistance(queries, encoded_values, stored_norm);
                        try maybeInsertSearchResult(allocator, &results, limit, candidate_id.*, distance);
                    },
                }
                try stmt.reset();
            }
        }

        const items = try results.toOwnedSlice(allocator);
        std.mem.sort(VectorSearchResult, items, {}, searchResultLessThan);
        return .{ .items = items };
    }

    fn searchMultiI8CosinePrefilter(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        queries: []const PreparedI8CosineQuery,
        candidate_ids: ?[]const []const u8,
        prefilter_query_index: usize,
        prefilter_limit: usize,
        limit: usize,
    ) Error!VectorSearchResults {
        if (prefilter_query_index >= queries.len) return error.VectorInvalid;
        if (candidate_ids) |ids| {
            for (ids) |id| try validateVectorId(id);
        }
        if (limit == 0 or prefilter_limit == 0) return .{ .items = try allocator.alloc(VectorSearchResult, 0) };

        const prefilter_queries = queries[prefilter_query_index .. prefilter_query_index + 1];
        var prefilter = if (candidate_ids) |ids|
            try self.searchMultiI8CosineCandidates(allocator, collection_name, collection, prefilter_queries, ids, prefilter_limit)
        else
            try self.searchMultiI8CosineAll(allocator, collection_name, collection, prefilter_queries, prefilter_limit);
        defer prefilter.deinit(allocator);

        const prefilter_ids = try allocator.alloc([]const u8, prefilter.items.len);
        defer allocator.free(prefilter_ids);
        for (prefilter.items, prefilter_ids) |item, *id| id.* = item.id;
        return self.searchMultiI8CosineCandidates(allocator, collection_name, collection, queries, prefilter_ids, limit);
    }

    fn searchMultiI8CosineCandidatesByScan(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        queries: []const PreparedI8CosineQuery,
        seen: *const std.StringHashMap(void),
        results: *std.ArrayList(VectorSearchResult),
        limit: usize,
    ) Error!void {
        var stmt = try self.prepareSchema(
            \\select vector_id, "values", norm_squared
            \\from {s}_zova_vectors
            \\where collection_key = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        _ = collection_name;
        try stmt.bindInt64(1, collection.collection_key);
        while ((try stmt.step()) == .row) {
            const vector_id = stmt.columnText(0);
            if (!seen.contains(vector_id)) continue;
            const encoded_values = stmt.columnBlob(1);
            if (encoded_values.len != collection.dimensions) return error.VectorCorrupt;
            const stored_norm = optionalColumnDouble(&stmt, 2);
            const distance = try multiI8CosineDistance(queries, encoded_values, stored_norm);
            try maybeInsertSearchResult(allocator, results, limit, vector_id, distance);
        }
    }

    fn searchCandidateVectors(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        query: PreparedVectorQuery,
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

        const collection_vector_count = if (seen.count() >= candidate_scan_threshold)
            try self.countVectorsInCollection(collection.collection_key)
        else
            0;

        if (shouldScanCandidateVectors(seen.count(), collection_vector_count)) {
            try self.searchCandidateVectorsByScan(allocator, collection_name, collection, query, &seen, &results, limit, max_distance);
            const items = try results.toOwnedSlice(allocator);
            std.mem.sort(VectorSearchResult, items, {}, searchResultLessThan);
            return .{ .items = items };
        }

        var stmt = try self.prepareSchema(
            \\select "values", norm_squared
            \\from {s}_zova_vectors
            \\where collection_key = ? and vector_id = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindInt64(1, collection.collection_key);

        var iterator = seen.keyIterator();
        while (iterator.next()) |candidate_id| {
            try stmt.bindText(2, candidate_id.*);

            switch (try stmt.step()) {
                .done => {},
                .row => {
                    const stored_norm = optionalColumnDouble(&stmt, 1);
                    const distance = try query.distanceFromEncodedWithStoredNorm(stmt.columnBlob(0), stored_norm);
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

    fn searchCandidateVectorsByScan(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        query: PreparedVectorQuery,
        seen: *const std.StringHashMap(void),
        results: *std.ArrayList(VectorSearchResult),
        limit: usize,
        max_distance: ?f64,
    ) Error!void {
        var stmt = try self.prepareSchema(
            \\select vector_id, "values", norm_squared
            \\from {s}_zova_vectors
            \\where collection_key = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        _ = collection_name;
        try stmt.bindInt64(1, collection.collection_key);
        while ((try stmt.step()) == .row) {
            const vector_id = stmt.columnText(0);
            if (!seen.contains(vector_id)) continue;

            const stored_norm = optionalColumnDouble(&stmt, 2);
            const distance = try query.distanceFromEncodedWithStoredNorm(stmt.columnBlob(1), stored_norm);
            if (!distanceWithinThreshold(distance, max_distance)) continue;
            try maybeInsertSearchResult(allocator, results, limit, vector_id, distance);
        }
    }

    fn countVectorsInCollection(self: *Database, collection_key: i64) Error!usize {
        var stmt = try self.prepareSchema(
            \\select count(*)
            \\from {s}_zova_vectors
            \\where collection_key = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        try stmt.bindInt64(1, collection_key);
        std.debug.assert((try stmt.step()) == .row);
        return @intCast(try sqliteI64ToU64(stmt.columnInt64(0)));
    }

    fn loadVectorValuesForSearch(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        vector_id: []const u8,
    ) Error!VectorValuesOwned {
        var stmt = try self.prepareSchema(
            \\select "values"
            \\from {s}_zova_vectors
            \\where collection_key = ? and vector_id = ?
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();

        _ = collection_name;
        try stmt.bindInt64(1, collection.collection_key);
        try stmt.bindText(2, vector_id);

        return switch (try stmt.step()) {
            .done => error.VectorNotFound,
            .row => {
                const values = try decodeValuesLe(allocator, collection.element_type, stmt.columnBlob(0), collection.dimensions);
                errdefer values.deinit(allocator);
                try validateStoredVectorValues(collection, vectorValuesConst(values));
                return values;
            },
        };
    }

    fn writeVectorRows(
        self: *Database,
        collection_name: []const u8,
        collection: CollectionMetadata,
        vectors: []const VectorInput,
    ) Error!void {
        if (vectors.len == 0) return;
        _ = collection_name;

        var stmt = try self.prepareSchema(
            \\insert into {s}_zova_vectors (collection_key, vector_id, "values", norm_squared)
            \\values (?, ?, ?, ?)
            \\on conflict(collection_key, vector_id) do update set
            \\  "values" = excluded."values",
            \\  norm_squared = excluded.norm_squared
        , .{self.storage_schema.prefix()});
        defer stmt.deinit();
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(std.heap.c_allocator);

        for (vectors) |vector| {
            const encoded = switch (vector.values) {
                .i8 => |values| std.mem.sliceAsBytes(values),
                else => try encodeValuesLeInto(&scratch, vector.values),
            };
            const norm_squared = try vectorNormSquared(vector.values);

            try stmt.bindInt64(1, collection.collection_key);
            try stmt.bindText(2, vector.id);
            try stmt.bindBlobBorrowed(3, encoded);
            try stmt.bindDouble(4, norm_squared);
            std.debug.assert((try stmt.step()) == .done);
            try stmt.reset();
            try stmt.clearBindings();
        }
    }
};

const PreparedI8CosineQuery = struct {
    values: []const i8,
    length: f64,
};

fn multiI8CosineDistance(
    queries: []const PreparedI8CosineQuery,
    encoded_values: []const u8,
    stored_norm: ?f64,
) Error!f64 {
    std.debug.assert(queries.len > 0);
    var aggregate_distance: f64 = -std.math.inf(f64);
    for (queries) |query| {
        const distance = if (stored_norm) |norm|
            try i8CosineDistanceFromEncodedWithQueryLengthSimd(query.values, query.length, encoded_values, norm)
        else blk: {
            var query_norm_squared: u64 = 0;
            for (query.values) |value| {
                const wide: i32 = value;
                query_norm_squared += @intCast(wide * wide);
            }
            break :blk try i8CosineDistanceFromEncoded(query.values, u64ToF64Exact(query_norm_squared), encoded_values);
        };
        aggregate_distance = @max(aggregate_distance, distance);
    }
    return aggregate_distance;
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

fn validateVectorInput(collection: CollectionMetadata, input: VectorInput) Error!void {
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

fn vectorNormSquared(values: VectorValuesConst) Error!f64 {
    return switch (values) {
        .i8 => |typed| blk: {
            var norm: u64 = 0;
            for (typed) |value| {
                const wide: i32 = value;
                norm += @intCast(wide * wide);
            }
            break :blk u64ToF64Exact(norm);
        },
        else => blk: {
            var norm: f64 = 0;
            for (0..vectorValuesLen(values)) |index| {
                const value = try inputValueAsF64(values, index);
                norm += value * value;
            }
            break :blk norm;
        },
    };
}

fn distanceWithinThreshold(distance: f64, max_distance: ?f64) bool {
    if (max_distance) |threshold| {
        return distance <= threshold;
    }
    return true;
}

fn optionalColumnDouble(stmt: *sqlite.Statement, index: c_int) ?f64 {
    if (stmt.columnType(index) == .null) return null;
    return stmt.columnDouble(index);
}

fn shouldScanCandidateVectors(deduped_candidate_count: usize, collection_vector_count: usize) bool {
    if (deduped_candidate_count < candidate_scan_threshold) return false;
    if (collection_vector_count == 0) return false;
    return deduped_candidate_count >= (collection_vector_count + 3) / 4;
}

test "candidate search strategy scans large candidate sets" {
    try std.testing.expect(!shouldScanCandidateVectors(0, 100));
    try std.testing.expect(!shouldScanCandidateVectors(1, 100));
    try std.testing.expect(!shouldScanCandidateVectors(127, 128));
    try std.testing.expect(!shouldScanCandidateVectors(128, 1_000));
    try std.testing.expect(shouldScanCandidateVectors(128, 512));
    try std.testing.expect(shouldScanCandidateVectors(11_167, 11_167));
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
        \\select collection_key, dimensions, metric, element_type
        \\from {s}_zova_vector_collections
        \\where name = ?
    , .{db.storage_schema.prefix()});
    defer stmt.deinit();

    try stmt.bindText(1, name);
    return switch (try stmt.step()) {
        .done => error.VectorCollectionNotFound,
        .row => {
            const dimensions_i64 = stmt.columnInt64(1);
            if (dimensions_i64 <= 0 or dimensions_i64 > max_vector_dimensions) return error.NotZovaDatabase;
            return .{
                .collection_key = stmt.columnInt64(0),
                .dimensions = @intCast(dimensions_i64),
                .metric = try vectorMetricFromText(stmt.columnText(2)),
                .element_type = try vectorElementTypeFromText(stmt.columnText(3)),
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

fn encodeValuesLeInto(scratch: *std.ArrayList(u8), values: VectorValuesConst) Error![]const u8 {
    const byte_len = switch (values) {
        .f32 => |typed| typed.len * @sizeOf(f32),
        .f16 => |typed| typed.len * @sizeOf(u16),
        .i8 => |typed| typed.len,
    };
    try scratch.resize(std.heap.c_allocator, byte_len);
    switch (values) {
        .f32 => |typed| for (typed, 0..) |value, index| {
            std.mem.writeInt(u32, scratch.items[index * 4 ..][0..4], @bitCast(value), .little);
        },
        .f16 => |typed| for (typed, 0..) |value, index| {
            std.mem.writeInt(u16, scratch.items[index * 2 ..][0..2], value, .little);
        },
        .i8 => |typed| {
            for (typed, 0..) |value, index| scratch.items[index] = @bitCast(value);
        },
    }
    return scratch.items;
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

fn cosineDistanceFromEncodedPrepared(element_type: VectorElementType, query: VectorValuesConst, encoded_values: []const u8, query_norm: f64) Error!f64 {
    var dot: f64 = 0;
    var stored_norm: f64 = 0;

    for (0..vectorValuesLen(query)) |index| {
        const query_f64 = try inputValueAsF64(query, index);
        const stored_f64 = try encodedValueAsF64(element_type, encoded_values, index);
        dot += query_f64 * stored_f64;
        stored_norm += stored_f64 * stored_f64;
    }

    if (stored_norm == 0) return error.VectorCorrupt;
    return 1.0 - (dot / (@sqrt(query_norm) * @sqrt(stored_norm)));
}

fn i8CosineDistanceFromEncoded(query: []const i8, query_norm: f64, encoded_values: []const u8) Error!f64 {
    var dot: i64 = 0;
    var stored_norm: u64 = 0;

    for (query, encoded_values) |query_value, encoded_value| {
        const query_wide: i32 = query_value;
        const stored_value: i8 = @bitCast(encoded_value);
        const stored_wide: i32 = stored_value;
        dot += query_wide * stored_wide;
        stored_norm += @intCast(stored_wide * stored_wide);
    }

    if (stored_norm == 0) return error.VectorCorrupt;
    const dot_f64 = i64ToF64Exact(dot);
    const stored_norm_f64 = u64ToF64Exact(stored_norm);
    return 1.0 - (dot_f64 / (@sqrt(query_norm) * @sqrt(stored_norm_f64)));
}

fn i8CosineDistanceFromEncodedWithStoredNorm(query: []const i8, query_norm: f64, encoded_values: []const u8, stored_norm: f64) Error!f64 {
    return i8CosineDistanceFromEncodedWithQueryLength(query, @sqrt(query_norm), encoded_values, stored_norm);
}

fn i8CosineDistanceFromEncodedWithQueryLength(query: []const i8, query_length: f64, encoded_values: []const u8, stored_norm: f64) Error!f64 {
    if (stored_norm <= 0 or std.math.isNan(stored_norm) or std.math.isInf(stored_norm)) return error.VectorCorrupt;

    var dot: i64 = 0;
    for (query, encoded_values) |query_value, encoded_value| {
        const query_wide: i32 = query_value;
        const stored_value: i8 = @bitCast(encoded_value);
        const stored_wide: i32 = stored_value;
        dot += query_wide * stored_wide;
    }

    const dot_f64 = i64ToF64Exact(dot);
    return 1.0 - (dot_f64 / (query_length * @sqrt(stored_norm)));
}

fn i8CosineDistanceFromEncodedWithQueryLengthSimd(query: []const i8, query_length: f64, encoded_values: []const u8, stored_norm: f64) Error!f64 {
    if (stored_norm <= 0 or std.math.isNan(stored_norm) or std.math.isInf(stored_norm)) return error.VectorCorrupt;

    const lanes = 16;
    const I8x16 = @Vector(lanes, i8);
    const I32x16 = @Vector(lanes, i32);
    const I64x16 = @Vector(lanes, i64);

    var dot: i64 = 0;
    var index: usize = 0;
    while (index + lanes <= query.len) : (index += lanes) {
        const query_array = @as(*align(1) const [lanes]i8, @ptrCast(query.ptr + index)).*;
        const encoded_array = @as(*align(1) const [lanes]u8, @ptrCast(encoded_values.ptr + index)).*;
        const query_vector: I8x16 = @bitCast(query_array);
        const encoded_vector: I8x16 = @bitCast(encoded_array);
        const query_wide: I32x16 = @intCast(query_vector);
        const encoded_wide: I32x16 = @intCast(encoded_vector);
        const products = query_wide * encoded_wide;
        dot += @reduce(.Add, @as(I64x16, @intCast(products)));
    }

    for (query[index..], encoded_values[index..]) |query_value, encoded_value| {
        const query_wide: i32 = query_value;
        const stored_value: i8 = @bitCast(encoded_value);
        const stored_wide: i32 = stored_value;
        dot += query_wide * stored_wide;
    }

    const dot_f64 = i64ToF64Exact(dot);
    return 1.0 - (dot_f64 / (query_length * @sqrt(stored_norm)));
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
        .i8 => |typed| i8ToF64(typed[index]),
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
        .i8 => i8ToF64(@as(i8, @bitCast(encoded_values[index]))),
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

pub fn i8ToF64(value: i8) f64 {
    const sign = if (value < 0) @as(u64, 1) << 63 else 0;
    const wide: i16 = value;
    const magnitude_wide = if (wide < 0) -wide else wide;
    const magnitude: u8 = @intCast(magnitude_wide);
    if (magnitude == 0) return @bitCast(sign);

    const top_bit: u4 = @intCast(7 - @clz(magnitude));
    const exponent64 = @as(u64, top_bit) + 1023;
    const mantissa_source = @as(u64, magnitude) - (@as(u64, 1) << top_bit);
    const shift: u6 = @intCast(52 - @as(u6, top_bit));
    const mantissa = mantissa_source << shift;
    return @bitCast(sign | (exponent64 << 52) | mantissa);
}

fn i64ToF64Exact(value: i64) f64 {
    if (value == 0) return 0.0;
    const sign = if (value < 0) @as(u64, 1) << 63 else 0;
    const magnitude: u64 = if (value < 0)
        @as(u64, @intCast(-(value + 1))) + 1
    else
        @intCast(value);
    return unsignedMagnitudeToF64(sign, magnitude);
}

fn u64ToF64Exact(value: u64) f64 {
    if (value == 0) return 0.0;
    return unsignedMagnitudeToF64(0, value);
}

fn unsignedMagnitudeToF64(sign: u64, magnitude: u64) f64 {
    std.debug.assert(magnitude > 0);
    const top_bit: u6 = @intCast(63 - @clz(magnitude));
    std.debug.assert(top_bit <= 52);
    const exponent64 = @as(u64, top_bit) + 1023;
    const mantissa_source = magnitude - (@as(u64, 1) << top_bit);
    const shift: u6 = @intCast(52 - top_bit);
    const mantissa = mantissa_source << shift;
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

test "i8ToF64 matches Zig float widening" {
    const values = [_]i8{
        -128,
        -127,
        -2,
        -1,
        0,
        1,
        2,
        3,
        7,
        8,
        15,
        16,
        42,
        64,
        100,
        127,
    };
    for (values) |value| {
        const expected: f64 = @floatFromInt(value);
        try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(i8ToF64(value))));
    }
}

test "integer exact widening helpers match Zig float widening" {
    const signed_values = [_]i64{
        -268_435_456,
        -16_384,
        -1,
        1,
        16_384,
        268_435_456,
    };
    for (signed_values) |value| {
        const expected: f64 = @floatFromInt(value);
        try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(i64ToF64Exact(value))));
    }

    const unsigned_values = [_]u64{
        1,
        16_384,
        268_435_456,
    };
    for (unsigned_values) |value| {
        const expected: f64 = @floatFromInt(value);
        try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(u64ToF64Exact(value))));
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
        if (limit > search_heap_threshold) siftSearchHeapUp(results.items, results.items.len - 1);
        return;
    }

    if (limit > search_heap_threshold) {
        if (!searchCandidateLessThan(id, distance, results.items[0])) return;
        const id_copy = try allocator.dupe(u8, id);
        allocator.free(results.items[0].id);
        results.items[0] = .{ .id = id_copy, .distance = distance };
        siftSearchHeapDown(results.items, 0);
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

fn siftSearchHeapUp(items: []VectorSearchResult, start_index: usize) void {
    var index = start_index;
    while (index != 0) {
        const parent = (index - 1) / 2;
        if (!searchResultLessThan({}, items[parent], items[index])) break;
        std.mem.swap(VectorSearchResult, &items[parent], &items[index]);
        index = parent;
    }
}

fn siftSearchHeapDown(items: []VectorSearchResult, start_index: usize) void {
    var index = start_index;
    while (true) {
        const left = index * 2 + 1;
        if (left >= items.len) return;
        const right = left + 1;
        var worse_child = left;
        if (right < items.len and searchResultLessThan({}, items[left], items[right])) worse_child = right;
        if (!searchResultLessThan({}, items[index], items[worse_child])) return;
        std.mem.swap(VectorSearchResult, &items[index], &items[worse_child]);
        index = worse_child;
    }
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

test "i8 cosine accepts a precomputed query length" {
    const query = [_]i8{ 127, -64, 32, -16 };
    const stored = [_]u8{ 96, @bitCast(@as(i8, -48)), 24, @bitCast(@as(i8, -12)) };
    const query_norm_squared: f64 = 21585;
    const stored_norm_squared: f64 = 12240;

    const expected = try i8CosineDistanceFromEncodedWithStoredNorm(
        &query,
        query_norm_squared,
        &stored,
        stored_norm_squared,
    );
    const actual = try i8CosineDistanceFromEncodedWithQueryLength(
        &query,
        @sqrt(query_norm_squared),
        &stored,
        stored_norm_squared,
    );

    try std.testing.expectEqual(expected, actual);
}

test "i8 cosine SIMD scorer preserves exact distance" {
    const query = [_]i8{ 127, -64, 32, -16, 8, -4, 2, -1, 96, -48, 24, -12, 6, -3, 1, -1, 5 };
    const stored = [_]u8{ 96, @bitCast(@as(i8, -48)), 24, @bitCast(@as(i8, -12)), 6, @bitCast(@as(i8, -3)), 1, @bitCast(@as(i8, -1)), 127, @bitCast(@as(i8, -64)), 32, @bitCast(@as(i8, -16)), 8, @bitCast(@as(i8, -4)), 2, @bitCast(@as(i8, -1)), 1 };
    const query_length = @sqrt(@as(f64, 30622));
    const stored_norm_squared: f64 = 28118;

    const expected = try i8CosineDistanceFromEncodedWithQueryLength(&query, query_length, &stored, stored_norm_squared);
    const actual = try i8CosineDistanceFromEncodedWithQueryLengthSimd(&query, query_length, &stored, stored_norm_squared);

    try std.testing.expectEqual(expected, actual);
}

test "multi i8 cosine SIMD aggregation preserves scalar distance" {
    const first = [_]i8{ 127, -64, 32, -16, 8, -4, 2, -1, 5 };
    const second = [_]i8{ -32, 64, -96, 48, -24, 12, -6, 3, -1 };
    const stored = [_]u8{ 96, @bitCast(@as(i8, -48)), 24, @bitCast(@as(i8, -12)), 6, @bitCast(@as(i8, -3)), 1, @bitCast(@as(i8, -1)), 1 };
    const stored_norm_squared: f64 = 12288;
    const first_length = @sqrt(@as(f64, 21615));
    const second_length = @sqrt(@as(f64, 17406));
    const queries = [_]PreparedI8CosineQuery{
        .{ .values = &first, .length = first_length },
        .{ .values = &second, .length = second_length },
    };

    const expected = @max(
        try i8CosineDistanceFromEncodedWithQueryLength(&first, first_length, &stored, stored_norm_squared),
        try i8CosineDistanceFromEncodedWithQueryLength(&second, second_length, &stored, stored_norm_squared),
    );
    const actual = try multiI8CosineDistance(&queries, &stored, stored_norm_squared);
    try std.testing.expectEqual(expected, actual);
}
