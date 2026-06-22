//! Native vector storage and exact search implementation.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova_error = @import("zova_error.zig");

pub const Error = zova_error.Error;

const vector_collections_table = "_zova_vector_collections";
const vectors_table = "_zova_vectors";
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

/// Required options for creating a native vector collection.
///
/// The metric is explicit by design; Zova does not guess distance semantics.
/// v0.5 supports only `f32` vectors and at most `max_vector_dimensions`.
pub const VectorCollectionOptions = struct {
    dimensions: u32,
    metric: VectorMetric,
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

const CollectionMetadata = struct {
    dimensions: u32,
    metric: VectorMetric,
};

pub const collections_schema_sql =
    \\create table _zova_vector_collections (
    \\  name text not null primary key check (length(name) > 0 and length(name) <= 255),
    \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
    \\  metric text not null check (metric in ('cosine', 'l2', 'dot')),
    \\  element_type text not null check (element_type = 'f32')
    \\)
;
pub const vectors_schema_sql =
    \\create table _zova_vectors (
    \\  collection_name text not null,
    \\  vector_id text not null check (length(vector_id) > 0),
    \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
    \\  "values" blob not null check (length("values") = dimensions * 4),
    \\  primary key (collection_name, vector_id),
    \\  foreign key (collection_name) references _zova_vector_collections(name)
    \\)
;

pub const Database = struct {
    sqlite_db: *sqlite.Database,

    fn prepare(self: *Database, sql: [:0]const u8) Error!sqlite.Statement {
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

        var stmt = try self.prepare(
            \\select c.name, c.dimensions, c.metric, c.element_type, count(v.vector_id)
            \\from _zova_vector_collections c
            \\left join _zova_vectors v on v.collection_name = c.name
            \\where c.name = ?
            \\group by c.name, c.dimensions, c.metric, c.element_type
        );
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
        var stmt = try self.prepare(
            \\select c.name, c.dimensions, c.metric, c.element_type, count(v.vector_id)
            \\from _zova_vector_collections c
            \\left join _zova_vectors v on v.collection_name = c.name
            \\group by c.name, c.dimensions, c.metric, c.element_type
            \\order by c.name asc
        );
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

    /// Delete a vector collection and all private vector rows in it.
    ///
    /// User SQL rows that store collection names or vector ids are
    /// application-owned and are not scanned or mutated. This method uses
    /// ordinary SQLite deletes and can participate in a caller-owned
    /// transaction.
    pub fn deleteVectorCollection(self: *Database, name: []const u8) Error!void {
        try validateVectorCollectionName(name);
        _ = try loadVectorCollection(self, name);

        var delete_vectors = try self.prepare("delete from _zova_vectors where collection_name = ?");
        defer delete_vectors.deinit();
        try delete_vectors.bindText(1, name);
        std.debug.assert((try delete_vectors.step()) == .done);

        var delete_collection = try self.prepare("delete from _zova_vector_collections where name = ?");
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
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorValues(collection.dimensions, collection.metric, query);

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
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorValues(collection.dimensions, collection.metric, query);
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
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorValues(collection.dimensions, collection.metric, query);

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
        try validateVectorCollectionName(collection_name);
        const collection = try loadVectorCollection(self, collection_name);
        try validateVectorValues(collection.dimensions, collection.metric, query);
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
        defer allocator.free(query);

        return self.searchAllVectors(allocator, collection_name, collection, query, limit, null, source_vector_id);
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
        defer allocator.free(query);

        return self.searchCandidateVectors(allocator, collection_name, collection, query, candidate_ids, limit, null, source_vector_id);
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
        defer allocator.free(query);

        return self.searchAllVectors(allocator, collection_name, collection, query, limit, max_distance, source_vector_id);
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
        defer allocator.free(query);

        return self.searchCandidateVectors(allocator, collection_name, collection, query, candidate_ids, limit, max_distance, source_vector_id);
    }

    fn searchAllVectors(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        collection: CollectionMetadata,
        query: []const f32,
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

        var stmt = try self.prepare(
            \\select vector_id, dimensions, "values"
            \\from _zova_vectors
            \\where collection_name = ?
        );
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);
        while ((try stmt.step()) == .row) {
            const vector_id = stmt.columnText(0);
            if (exclude_id) |excluded| {
                if (std.mem.eql(u8, vector_id, excluded)) continue;
            }

            try validateStoredVectorDimensions(collection.dimensions, stmt.columnInt64(1));

            const distance = try vectorDistanceFromEncoded(
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
        query: []const f32,
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

        var stmt = try self.prepare(
            \\select dimensions, "values"
            \\from _zova_vectors
            \\where collection_name = ? and vector_id = ?
        );
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
    ) Error![]f32 {
        var stmt = try self.prepare(
            \\select dimensions, "values"
            \\from _zova_vectors
            \\where collection_name = ? and vector_id = ?
        );
        defer stmt.deinit();

        try stmt.bindText(1, collection_name);
        try stmt.bindText(2, vector_id);

        return switch (try stmt.step()) {
            .done => error.VectorNotFound,
            .row => {
                try validateStoredVectorDimensions(collection.dimensions, stmt.columnInt64(0));
                const values = try decodeF32Le(allocator, stmt.columnBlob(1), collection.dimensions);
                errdefer allocator.free(values);
                try validateStoredVectorValues(collection.metric, values);
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

        var stmt = try self.prepare(
            \\insert into _zova_vectors (collection_name, vector_id, dimensions, "values")
            \\values (?, ?, ?, ?)
            \\on conflict(collection_name, vector_id) do update set
            \\  dimensions = excluded.dimensions,
            \\  "values" = excluded."values"
        );
        defer stmt.deinit();

        for (vectors) |vector| {
            const encoded = try encodeF32Le(std.heap.page_allocator, vector.values);
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

fn validateVectorInput(collection: CollectionMetadata, input: VectorInput) Error!void {
    try validateVectorId(input.id);
    try validateVectorValues(collection.dimensions, collection.metric, input.values);
}

fn validateVectorSearchThreshold(max_distance: f64) Error!void {
    if (std.math.isNan(max_distance) or std.math.isInf(max_distance)) return error.VectorInvalid;
}

fn validateStoredVectorDimensions(expected_dimensions: u32, stored_dimensions: i64) Error!void {
    if (stored_dimensions < 0) return error.VectorCorrupt;
    if (@as(u64, @intCast(stored_dimensions)) != expected_dimensions) return error.VectorCorrupt;
}

fn validateStoredVectorValues(metric: VectorMetric, values: []const f32) Error!void {
    var norm_squared: f64 = 0;
    for (values) |value| {
        if (std.math.isNan(value) or std.math.isInf(value)) return error.VectorCorrupt;
        const value_f64: f64 = @floatCast(value);
        norm_squared += value_f64 * value_f64;
    }
    if (metric == .cosine and norm_squared == 0) return error.VectorCorrupt;
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

fn loadVectorCollection(db: *Database, name: []const u8) Error!CollectionMetadata {
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

fn vectorCollectionInfoFromRow(allocator: std.mem.Allocator, stmt: *sqlite.Statement) Error!VectorCollectionInfo {
    const dimensions_i64 = stmt.columnInt64(1);
    if (dimensions_i64 <= 0 or dimensions_i64 > max_vector_dimensions) return error.NotZovaDatabase;
    if (!std.mem.eql(u8, stmt.columnText(3), "f32")) return error.NotZovaDatabase;

    const name = try allocator.dupe(u8, stmt.columnText(0));
    errdefer allocator.free(name);

    return .{
        .name = name,
        .dimensions = @intCast(dimensions_i64),
        .metric = try vectorMetricFromText(stmt.columnText(2)),
        .vector_count = try sqliteI64ToU64(stmt.columnInt64(4)),
    };
}

fn vectorByteLen(dimensions: u32) usize {
    return @as(usize, @intCast(dimensions)) * @sizeOf(f32);
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

fn sqliteI64ToU64(value: i64) Error!u64 {
    if (value < 0) return error.VectorCorrupt;
    return @intCast(value);
}

fn isReservedZovaName(name: []const u8) bool {
    const reserved_prefix = "_zova_";
    return name.len >= reserved_prefix.len and
        std.ascii.eqlIgnoreCase(name[0..reserved_prefix.len], reserved_prefix);
}
