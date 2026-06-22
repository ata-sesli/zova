//! Zova-owned database identity layer.
//!
//! This module is the first layer above the plain SQLite wrapper. A database
//! enters Zova mode by using a `.zova` file path through `zova.Database`.
//! The file is still a SQLite database underneath, but Zova validates private
//! metadata before treating it as a Zova-owned database.
//!
//! Zova is currently pre-1.0, and internal `.zova` format compatibility is
//! not preserved between experimental format versions. The current v0.12
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
//! chunk BLOB rows, `putObjectChunk` stores verified loose chunks for
//! receive-side transfer workflows, `assembleObjectFromChunks` turns verified
//! chunks into complete objects, `getObject` reconstructs and verifies the full
//! object in memory, `objectManifest` and `getObjectChunk` expose verified
//! read-side chunk primitives, `readObjectRange` serves caller-requested byte
//! ranges without full-object allocation, `ObjectWriter` streams caller bytes
//! through the same FastCDC-v1 chunker without retaining the full object, and
//! delete helpers remove only Zova-owned object or unreferenced chunk rows.
//! User SQL references and transfer state remain application-owned.
//!
//! Zova vector APIs follow pgvector's philosophy: vectors are native searchable
//! numeric values, while labels and application metadata stay in user SQL
//! tables. Current vector search is exact flat scan through Zig/C APIs and
//! read-only SQL integration; approximate indexes and payload filters are
//! intentionally deferred.
//! Migrations, transfer-session state, peer protocols, and repair tooling are
//! intentionally absent from this release.

const std = @import("std");
const fastcdc = @import("object_fastcdc.zig");
const object_impl = @import("object.zig");
const sqlite = @import("sqlite.zig");
const vector_impl = @import("vector.zig");
const vector_sql = @import("vector_sql.zig");
const zova_error = @import("zova_error.zig");

const metadata_table = "_zova_meta";
const objects_table = "_zova_objects";
const chunks_table = "_zova_chunks";
const object_chunks_table = "_zova_object_chunks";
const magic_value = "zova";
const format_version = "3";
pub const ObjectId = object_impl.ObjectId;
pub const ObjectChunkId = object_impl.ObjectChunkId;
pub const ObjectChunk = object_impl.ObjectChunk;
pub const ObjectManifest = object_impl.ObjectManifest;
pub const ObjectChunkData = object_impl.ObjectChunkData;
pub const Object = object_impl.Object;
pub const ObjectWriter = object_impl.ObjectWriter;

/// Compute the content identity for a Zova object.
pub fn objectId(bytes: []const u8) ObjectId {
    return object_impl.objectId(bytes);
}

/// Compute the content identity for a single Zova object chunk.
pub fn objectChunkId(bytes: []const u8) ObjectChunkId {
    return object_impl.objectChunkId(bytes);
}

pub const Error = zova_error.Error;

pub const max_vector_dimensions = vector_impl.max_vector_dimensions;
pub const VectorMetric = vector_impl.VectorMetric;
pub const VectorCollectionOptions = vector_impl.VectorCollectionOptions;
pub const VectorCollectionInfo = vector_impl.VectorCollectionInfo;
pub const VectorCollectionList = vector_impl.VectorCollectionList;
pub const VectorInput = vector_impl.VectorInput;
pub const Vector = vector_impl.Vector;
pub const VectorSearchResult = vector_impl.VectorSearchResult;
pub const VectorSearchResults = vector_impl.VectorSearchResults;

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
        try vector_sql.register(&raw);
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
        try vector_sql.register(&raw);
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

    /// Reclaim SQLite free pages with an explicit in-place `VACUUM`.
    ///
    /// Zova never runs `VACUUM` automatically after object or vector deletes.
    /// This method is a thin SQLite wrapper for applications that deliberately
    /// want SQLite to rebuild the database file and potentially shrink it.
    pub fn vacuum(self: *Database) Error!void {
        try self.exec("vacuum");
    }

    /// Current SQLite error message for the underlying connection.
    pub fn errorMessage(self: *Database) []const u8 {
        return self.sqlite_db.errorMessage();
    }

    /// Create an incremental object writer for this database connection.
    pub fn objectWriter(self: *Database, allocator: std.mem.Allocator) Error!ObjectWriter {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.objectWriter(allocator);
    }

    /// Create a native vector collection.
    pub fn createVectorCollection(
        self: *Database,
        name: []const u8,
        options: VectorCollectionOptions,
    ) Error!void {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.createVectorCollection(name, options);
    }

    /// Return whether a valid vector collection exists.
    pub fn hasVectorCollection(self: *Database, name: []const u8) Error!bool {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.hasVectorCollection(name);
    }

    /// Return owned metadata for one existing vector collection.
    pub fn vectorCollectionInfo(
        self: *Database,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) Error!VectorCollectionInfo {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.vectorCollectionInfo(allocator, name);
    }

    /// List all vector collections sorted by ascending name.
    pub fn listVectorCollections(
        self: *Database,
        allocator: std.mem.Allocator,
    ) Error!VectorCollectionList {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.listVectorCollections(allocator);
    }

    /// Store or replace one vector row in a collection.
    pub fn putVector(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
        values: []const f32,
    ) Error!void {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.putVector(collection_name, vector_id, values);
    }

    /// Store or replace multiple vector rows in a collection.
    pub fn putVectors(
        self: *Database,
        collection_name: []const u8,
        inputs: []const VectorInput,
    ) Error!void {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.putVectors(collection_name, inputs);
    }

    /// Load one vector row into owned memory.
    pub fn getVector(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        vector_id: []const u8,
    ) Error!Vector {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.getVector(allocator, collection_name, vector_id);
    }

    /// Return whether a vector id exists in an existing collection.
    pub fn hasVector(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
    ) Error!bool {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.hasVector(collection_name, vector_id);
    }

    /// Delete one vector row from an existing collection.
    pub fn deleteVector(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
    ) Error!void {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.deleteVector(collection_name, vector_id);
    }

    /// Delete a vector collection and all private vector rows in it.
    pub fn deleteVectorCollection(self: *Database, name: []const u8) Error!void {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.deleteVectorCollection(name);
    }

    /// Search one vector collection with an exact flat scan.
    pub fn searchVectors(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: []const f32,
        limit: usize,
    ) Error!VectorSearchResults {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.searchVectors(allocator, collection_name, query, limit);
    }

    /// Search one vector collection with an exact flat scan and distance cap.
    pub fn searchVectorsWithin(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: []const f32,
        max_distance: f64,
        limit: usize,
    ) Error!VectorSearchResults {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.searchVectorsWithin(allocator, collection_name, query, max_distance, limit);
    }

    /// Search one vector collection over a caller-supplied candidate id set.
    pub fn searchVectorsIn(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: []const f32,
        candidate_ids: []const []const u8,
        limit: usize,
    ) Error!VectorSearchResults {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.searchVectorsIn(allocator, collection_name, query, candidate_ids, limit);
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
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.searchVectorsInWithin(allocator, collection_name, query, candidate_ids, max_distance, limit);
    }

    /// Search one vector collection using an existing vector as the query.
    pub fn searchVectorsById(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        source_vector_id: []const u8,
        limit: usize,
    ) Error!VectorSearchResults {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.searchVectorsById(allocator, collection_name, source_vector_id, limit);
    }

    /// Search candidates using an existing vector as the query.
    pub fn searchVectorsByIdIn(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        source_vector_id: []const u8,
        candidate_ids: []const []const u8,
        limit: usize,
    ) Error!VectorSearchResults {
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.searchVectorsByIdIn(allocator, collection_name, source_vector_id, candidate_ids, limit);
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
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.searchVectorsByIdWithin(allocator, collection_name, source_vector_id, max_distance, limit);
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
        var vectors = vector_impl.Database{ .sqlite_db = &self.sqlite_db };
        return vectors.searchVectorsByIdInWithin(allocator, collection_name, source_vector_id, candidate_ids, max_distance, limit);
    }

    /// Store raw bytes as a content-addressed Zova object.
    pub fn putObject(self: *Database, bytes: []const u8) Error!ObjectId {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.putObject(bytes);
    }

    /// Load and verify an object by id.
    pub fn getObject(self: *Database, allocator: std.mem.Allocator, id: ObjectId) Error!Object {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.getObject(allocator, id);
    }

    /// Read a byte range from a logical object into a caller-provided buffer.
    pub fn readObjectRange(self: *Database, id: ObjectId, offset: u64, buffer: []u8) Error!usize {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.readObjectRange(id, offset, buffer);
    }

    /// Return the public manifest for one object.
    pub fn objectManifest(self: *Database, allocator: std.mem.Allocator, id: ObjectId) Error!ObjectManifest {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.objectManifest(allocator, id);
    }

    /// Return whether a stored chunk hash exists.
    pub fn hasObjectChunk(self: *Database, hash: ObjectChunkId) Error!bool {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.hasObjectChunk(hash);
    }

    /// Store one verified loose object chunk.
    pub fn putObjectChunk(self: *Database, expected_hash: ObjectChunkId, bytes: []const u8) Error!void {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.putObjectChunk(expected_hash, bytes);
    }

    /// Assemble a complete object from already-verified chunks.
    pub fn assembleObjectFromChunks(
        self: *Database,
        id: ObjectId,
        size_bytes: u64,
        chunks: []const ObjectChunk,
    ) Error!void {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.assembleObjectFromChunks(id, size_bytes, chunks);
    }

    /// Delete one unreferenced loose chunk if possible.
    pub fn deleteObjectChunk(self: *Database, hash: ObjectChunkId) Error!bool {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.deleteObjectChunk(hash);
    }

    /// Load and verify one chunk by hash.
    pub fn getObjectChunk(
        self: *Database,
        allocator: std.mem.Allocator,
        hash: ObjectChunkId,
    ) Error!ObjectChunkData {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.getObjectChunk(allocator, hash);
    }

    /// Return whether an object id exists without loading object bytes.
    pub fn hasObject(self: *Database, id: ObjectId) Error!bool {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.hasObject(id);
    }

    /// Return the original full object byte length.
    pub fn objectSize(self: *Database, id: ObjectId) Error!u64 {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.objectSize(id);
    }

    /// Return the number of FastCDC chunks in the object manifest.
    pub fn objectChunkCount(self: *Database, id: ObjectId) Error!u64 {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.objectChunkCount(id);
    }

    /// Delete one Zova object and garbage-collect its unreferenced chunks.
    pub fn deleteObject(self: *Database, id: ObjectId) Error!void {
        var objects = object_impl.Database{ .sqlite_db = &self.sqlite_db };
        return objects.deleteObject(id);
    }
};

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
    try db.exec(object_impl.objects_schema_sql ++ ";");
    try db.exec(object_impl.chunks_schema_sql ++ ";");
    try db.exec(object_impl.object_chunks_schema_sql ++ ";");
}

fn initializeVectorSchema(db: *sqlite.Database) sqlite.Error!void {
    try db.exec(vector_impl.collections_schema_sql ++ ";");
    try db.exec(vector_impl.vectors_schema_sql ++ ";");
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
    try validateRequiredTable(db, object_impl.objects_table, &object_columns, object_impl.objects_schema_sql);

    const chunk_columns = [_][]const u8{
        "chunk_hash",
        "size_bytes",
        "data",
    };
    try validateRequiredTable(db, object_impl.chunks_table, &chunk_columns, object_impl.chunks_schema_sql);

    const object_chunk_columns = [_][]const u8{
        "object_id",
        "chunk_index",
        "chunk_hash",
        "offset",
        "size_bytes",
    };
    try validateRequiredTable(db, object_impl.object_chunks_table, &object_chunk_columns, object_impl.object_chunks_schema_sql);
}

fn validateVectorSchema(db: *sqlite.Database) Error!void {
    const vector_collection_columns = [_][]const u8{
        "name",
        "dimensions",
        "metric",
        "element_type",
    };
    try validateRequiredTable(db, "_zova_vector_collections", &vector_collection_columns, vector_impl.collections_schema_sql);

    const vector_columns = [_][]const u8{
        "collection_name",
        "vector_id",
        "dimensions",
        "values",
    };
    try validateRequiredTable(db, "_zova_vectors", &vector_columns, vector_impl.vectors_schema_sql);
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

fn testingPutLooseManifest(allocator: std.mem.Allocator, db: *Database, bytes: []const u8) ![]ObjectChunk {
    var chunks: std.ArrayList(ObjectChunk) = .empty;
    errdefer chunks.deinit(allocator);

    var offset: usize = 0;
    var index: u64 = 0;
    while (offset < bytes.len) {
        const chunk_len = fastcdc.cut(bytes[offset..]);
        const chunk_bytes = bytes[offset .. offset + chunk_len];
        const hash = objectChunkId(chunk_bytes);
        try db.putObjectChunk(hash, chunk_bytes);
        try chunks.append(allocator, .{
            .index = index,
            .hash = hash,
            .offset = @intCast(offset),
            .size_bytes = @intCast(chunk_len),
        });
        offset += chunk_len;
        index += 1;
    }

    return try chunks.toOwnedSlice(allocator);
}

fn testingStreamObject(db: *Database, bytes: []const u8, pieces: []const usize) !ObjectId {
    var writer = try db.objectWriter(std.testing.allocator);
    defer writer.deinit();

    var offset: usize = 0;
    var piece_index: usize = 0;
    while (offset < bytes.len) {
        const requested = if (pieces.len == 0) bytes.len else pieces[piece_index % pieces.len];
        std.debug.assert(requested > 0);
        const len = @min(requested, bytes.len - offset);
        try writer.write(bytes[offset .. offset + len]);
        offset += len;
        piece_index += 1;
    }

    return try writer.finish();
}

const TestingTrackingAllocator = struct {
    backing: std.mem.Allocator,
    largest_request: usize = 0,

    fn allocator(self: *TestingTrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn record(self: *TestingTrackingAllocator, len: usize) void {
        self.largest_request = @max(self.largest_request, len);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TestingTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.record(len);
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *TestingTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.record(new_len);
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TestingTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.record(new_len);
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TestingTrackingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

fn testingExpectObjectBytes(db: *Database, id: ObjectId, expected: []const u8) !void {
    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &object.id);
    try std.testing.expectEqualSlices(u8, expected, object.bytes);
}

fn testingExpectManifestsEqual(left: ObjectManifest, right: ObjectManifest) !void {
    try std.testing.expectEqualSlices(u8, &left.object_id, &right.object_id);
    try std.testing.expectEqual(left.size_bytes, right.size_bytes);
    try std.testing.expectEqual(left.chunk_count, right.chunk_count);
    try std.testing.expectEqualStrings(left.chunker, right.chunker);
    try std.testing.expectEqual(left.chunks.len, right.chunks.len);

    for (left.chunks, right.chunks) |left_chunk, right_chunk| {
        try std.testing.expectEqual(left_chunk.index, right_chunk.index);
        try std.testing.expectEqualSlices(u8, &left_chunk.hash, &right_chunk.hash);
        try std.testing.expectEqual(left_chunk.offset, right_chunk.offset);
        try std.testing.expectEqual(left_chunk.size_bytes, right_chunk.size_bytes);
    }
}

fn expectSearchIds(results: *const VectorSearchResults, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, results.items.len);
    for (expected, 0..) |expected_id, index| {
        try std.testing.expectEqualStrings(expected_id, results.items[index].id);
    }
}

fn expectSqlPrepareOrStepError(db: *Database, sql: [:0]const u8) !void {
    var stmt = db.prepare(sql) catch return;
    defer stmt.deinit();

    _ = stmt.step() catch return;
    try std.testing.expect(false);
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

test "object chunk ids are sha256 of chunk bytes" {
    const abc_expected = ObjectChunkId{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };

    try std.testing.expectEqualSlices(u8, &abc_expected, &objectChunkId("abc"));
    try std.testing.expectEqualSlices(u8, &objectChunkId("same chunk"), &objectChunkId("same chunk"));
    try std.testing.expect(!std.mem.eql(u8, &objectChunkId("left"), &objectChunkId("right")));
}

test "object writer streams empty small binary and large objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-basic.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const empty_id = try testingStreamObject(&db, "", &.{1});
    try std.testing.expectEqualSlices(u8, &objectId(""), &empty_id);
    try testingExpectObjectBytes(&db, empty_id, "");
    try std.testing.expectEqual(@as(u64, 0), try db.objectChunkCount(empty_id));

    const small = "streamed hello object";
    const small_id = try testingStreamObject(&db, small, &.{ 1, 3, 2 });
    try std.testing.expectEqualSlices(u8, &objectId(small), &small_id);
    try testingExpectObjectBytes(&db, small_id, small);

    const binary = [_]u8{ 'z', 'o', 0, 1, 2, 0xff, 'a' };
    const binary_id = try testingStreamObject(&db, &binary, &.{2});
    try std.testing.expectEqualSlices(u8, &objectId(&binary), &binary_id);
    try testingExpectObjectBytes(&db, binary_id, &binary);

    var large: [fastcdc.max_size * 3 + fastcdc.avg_size]u8 = undefined;
    for (&large, 0..) |*byte, index| {
        byte.* = @intCast((index * 29 + index / 5 + 17) % 251);
    }

    const large_id = try testingStreamObject(&db, &large, &.{ 13, 8191, 3, 65537 });
    try std.testing.expectEqualSlices(u8, &objectId(&large), &large_id);
    try std.testing.expect(try db.objectChunkCount(large_id) > 1);
    try testingExpectObjectBytes(&db, large_id, &large);

    var range: [97]u8 = undefined;
    try std.testing.expectEqual(range.len, try db.readObjectRange(large_id, 1234, &range));
    try std.testing.expectEqualSlices(u8, large[1234 .. 1234 + range.len], &range);

    var manifest = try db.objectManifest(std.testing.allocator, large_id);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expect(manifest.chunks.len > 1);

    var first_chunk = try db.getObjectChunk(std.testing.allocator, manifest.chunks[0].hash);
    defer first_chunk.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &manifest.chunks[0].hash, &first_chunk.hash);
}

test "object writer manifest matches put object for same bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var put_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const writer_path = try testingDbPath(&writer_path_buffer, tmp.sub_path[0..], "writer-manifest.zova");
    const put_path = try testingDbPath(&put_path_buffer, tmp.sub_path[0..], "put-manifest.zova");

    var bytes: [fastcdc.max_size * 2 + 777]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 11 + index / 17 + 91) % 253);
    }

    var writer_db = try Database.create(writer_path);
    defer writer_db.deinit();
    const writer_id = try testingStreamObject(&writer_db, &bytes, &.{ 1, 5, 257, 4099 });

    var put_db = try Database.create(put_path);
    defer put_db.deinit();
    const put_id = try put_db.putObject(&bytes);

    try std.testing.expectEqualSlices(u8, &put_id, &writer_id);

    var writer_manifest = try writer_db.objectManifest(std.testing.allocator, writer_id);
    defer writer_manifest.deinit(std.testing.allocator);
    var put_manifest = try put_db.objectManifest(std.testing.allocator, put_id);
    defer put_manifest.deinit(std.testing.allocator);
    try testingExpectManifestsEqual(writer_manifest, put_manifest);
}

test "object writer does not allocate object sized memory for multi megabyte input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-memory.zova");

    const bytes = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 31 + index / 7 + 19) % 251);
    }

    var db = try Database.create(db_path);
    defer db.deinit();

    var tracking = TestingTrackingAllocator{ .backing = std.testing.allocator };
    var writer = try db.objectWriter(tracking.allocator());
    defer writer.deinit();

    var offset: usize = 0;
    while (offset < bytes.len) {
        const len = @min(bytes.len - offset, 37_919);
        try writer.write(bytes[offset .. offset + len]);
        offset += len;
    }

    const id = try writer.finish();
    try std.testing.expectEqualSlices(u8, &objectId(bytes), &id);
    try std.testing.expect(try db.objectChunkCount(id) > 1);
    try std.testing.expect(tracking.largest_request < bytes.len / 4);
    try std.testing.expect(tracking.largest_request <= fastcdc.max_size * 4);

    var preview: [128]u8 = undefined;
    try std.testing.expectEqual(preview.len, try db.readObjectRange(id, 123_456, &preview));
    try std.testing.expectEqualSlices(u8, bytes[123_456 .. 123_456 + preview.len], &preview);
}

test "object writer deduplicates repeated content and existing objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-dedupe.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const repeated = [_]u8{0} ** (fastcdc.max_size * 4);
    const first_id = try testingStreamObject(&db, &repeated, &.{ 1024, 7, 9000 });
    const second_id = try testingStreamObject(&db, &repeated, &.{repeated.len});

    try std.testing.expectEqualSlices(u8, &first_id, &second_id);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_objects"));

    const chunk_rows = try testingCount(&db, "select count(*) from _zova_chunks");
    const manifest_rows = try testingObjectManifestCount(&db, first_id);
    try std.testing.expect(manifest_rows > 1);
    try std.testing.expect(chunk_rows < manifest_rows);
}

test "object writer cancel and deinit cleanup unfinished chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-cancel.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = [_]u8{0x42} ** (fastcdc.max_size + fastcdc.avg_size);
    const id = objectId(&bytes);

    var writer = try db.objectWriter(std.testing.allocator);
    try writer.write(&bytes);
    try writer.cancel();
    defer writer.deinit();

    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
    try std.testing.expectError(error.ObjectWriterClosed, writer.write("again"));
    try std.testing.expectError(error.ObjectWriterClosed, writer.finish());
    try std.testing.expectError(error.ObjectWriterClosed, writer.cancel());

    var finished = try db.objectWriter(std.testing.allocator);
    try finished.write("closed after finish");
    _ = try finished.finish();
    defer finished.deinit();
    try std.testing.expectError(error.ObjectWriterClosed, finished.write("again"));
    try std.testing.expectError(error.ObjectWriterClosed, finished.finish());
    try std.testing.expectError(error.ObjectWriterClosed, finished.cancel());

    const chunk_count_before_auto_cancel = try testingCount(&db, "select count(*) from _zova_chunks");
    {
        var auto_cancel = try db.objectWriter(std.testing.allocator);
        try auto_cancel.write(&bytes);
        auto_cancel.deinit();
    }
    try testingExpectObjectMissing(&db, id);
    try std.testing.expectEqual(chunk_count_before_auto_cancel, try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "object writer cancel preserves pre-existing loose chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-cancel-existing-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const chunk = [_]u8{0x73} ** fastcdc.max_size;
    const hash = objectChunkId(&chunk);
    try db.putObjectChunk(hash, &chunk);

    var writer = try db.objectWriter(std.testing.allocator);
    try writer.write(&chunk);
    try writer.cancel();
    defer writer.deinit();

    try std.testing.expect(try db.hasObjectChunk(hash));
    var stored = try db.getObjectChunk(std.testing.allocator, hash);
    defer stored.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &chunk, stored.bytes);
    try testingExpectObjectMissing(&db, objectId(&chunk));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "object writer rejects active transactions and can retry after finish failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-transaction.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.sqlite_db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.objectWriter(std.testing.allocator));
    try db.sqlite_db.rollback();

    var active_writer = try db.objectWriter(std.testing.allocator);
    defer active_writer.deinit();
    try db.sqlite_db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, active_writer.write("blocked"));
    try std.testing.expectError(error.ObjectTransactionActive, active_writer.finish());
    try std.testing.expectError(error.ObjectTransactionActive, active_writer.cancel());
    try db.sqlite_db.rollback();
    try active_writer.cancel();

    const bytes = "writer rollback retry";
    const id = objectId(bytes);
    var writer = try db.objectWriter(std.testing.allocator);
    defer writer.deinit();
    try writer.write(bytes);

    try db.exec(
        \\create trigger force_writer_manifest_failure
        \\before insert on _zova_object_chunks
        \\begin
        \\  select raise(abort, 'forced writer manifest failure');
        \\end;
    );
    try std.testing.expectError(error.Constraint, writer.finish());
    try std.testing.expect(!try db.hasObject(id));
    try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));

    try db.exec("drop trigger force_writer_manifest_failure");
    try std.testing.expectError(error.ObjectWriterClosed, writer.write("after failed finish"));
    const retried_id = try writer.finish();
    try std.testing.expectEqualSlices(u8, &id, &retried_id);
    try testingExpectObjectBytes(&db, id, bytes);
}

test "object writer works after reopen and on converted databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-reopen.zova");

    const reopened_id = id: {
        var db = try Database.create(db_path);
        defer db.deinit();
        break :id try testingStreamObject(&db, "persisted writer object", &.{ 2, 3 });
    };

    {
        var db = try Database.open(db_path);
        defer db.deinit();
        try testingExpectObjectBytes(&db, reopened_id, "persisted writer object");
        try testingQuickCheckOk(&db);
        try testingIntegrityCheckOk(&db);
    }

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "writer-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "writer-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table notes (id integer primary key, body text not null)");
        try source.exec("insert into notes (body) values ('source row')");
    }

    try convertSqliteToZova(source_path, dest_path);
    var db = try Database.open(dest_path);
    defer db.deinit();

    const converted_id = try testingStreamObject(&db, "converted writer object", &.{1});
    try testingExpectObjectBytes(&db, converted_id, "converted writer object");
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes"));
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
    var edited_range: [64]u8 = undefined;
    try std.testing.expectEqual(edited_range.len, try db.readObjectRange(edited_id, 257, &edited_range));
    try std.testing.expectEqualSlices(u8, edited[257 .. 257 + edited_range.len], &edited_range);
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
    _ = id;
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

    try db.exec(object_impl.object_chunks_schema_sql ++ ";");
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

test "object manifest exposes ordered chunk metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-manifest.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expectError(error.ObjectNotFound, db.objectManifest(std.testing.allocator, objectId("missing")));

    const empty_id = try db.putObject("");
    var empty_manifest = try db.objectManifest(std.testing.allocator, empty_id);
    defer empty_manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &empty_id, &empty_manifest.object_id);
    try std.testing.expectEqual(@as(u64, 0), empty_manifest.size_bytes);
    try std.testing.expectEqual(@as(u64, 0), empty_manifest.chunk_count);
    try std.testing.expectEqualStrings(fastcdc.version, empty_manifest.chunker);
    try std.testing.expectEqual(@as(usize, 0), empty_manifest.chunks.len);

    const small_id = try db.putObject("small object");
    var small_manifest = try db.objectManifest(std.testing.allocator, small_id);
    defer small_manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), small_manifest.chunk_count);
    try std.testing.expectEqual(@as(usize, 1), small_manifest.chunks.len);
    try std.testing.expectEqual(@as(u64, 0), small_manifest.chunks[0].offset);
    try std.testing.expectEqual(@as(u64, "small object".len), small_manifest.chunks[0].size_bytes);

    var bytes: [fastcdc.max_size + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 29 + index / 5 + 7) % 251);
    }

    const id = try db.putObject(&bytes);
    var manifest = try db.objectManifest(std.testing.allocator, id);
    defer manifest.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &id, &manifest.object_id);
    try std.testing.expectEqual(@as(u64, bytes.len), manifest.size_bytes);
    try std.testing.expectEqual(try db.objectChunkCount(id), manifest.chunk_count);
    try std.testing.expectEqual(@as(usize, @intCast(manifest.chunk_count)), manifest.chunks.len);
    try std.testing.expectEqualStrings(fastcdc.version, manifest.chunker);
    try std.testing.expect(manifest.chunks.len > 1);

    var expected_offset: u64 = 0;
    for (manifest.chunks, 0..) |chunk, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index)), chunk.index);
        try std.testing.expectEqual(expected_offset, chunk.offset);
        try std.testing.expect(chunk.size_bytes > 0);
        try std.testing.expect(chunk.size_bytes <= fastcdc.max_size);
        try std.testing.expect(try db.hasObjectChunk(chunk.hash));
        expected_offset += chunk.size_bytes;
    }
    try std.testing.expectEqual(@as(u64, bytes.len), expected_offset);
}

test "object chunks can be read and reassembled through public API" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-chunk-read.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var bytes: [fastcdc.max_size + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 13 + index / 7 + 19) % 253);
    }

    const id = try db.putObject(&bytes);
    var manifest = try db.objectManifest(std.testing.allocator, id);
    defer manifest.deinit(std.testing.allocator);

    var rebuilt = try std.testing.allocator.alloc(u8, bytes.len);
    defer std.testing.allocator.free(rebuilt);

    for (manifest.chunks) |chunk| {
        var chunk_data = try db.getObjectChunk(std.testing.allocator, chunk.hash);
        defer chunk_data.deinit(std.testing.allocator);

        try std.testing.expectEqualSlices(u8, &chunk.hash, &chunk_data.hash);
        try std.testing.expectEqual(@as(usize, @intCast(chunk.size_bytes)), chunk_data.bytes.len);
        const start: usize = @intCast(chunk.offset);
        @memcpy(rebuilt[start .. start + chunk_data.bytes.len], chunk_data.bytes);
    }

    try std.testing.expectEqualSlices(u8, &bytes, rebuilt);

    const missing = [_]u8{0x91} ** 32;
    try std.testing.expect(!try db.hasObjectChunk(missing));
    try std.testing.expectError(error.ObjectChunkNotFound, db.getObjectChunk(std.testing.allocator, missing));
}

test "put object chunk stores verified loose chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "loose-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = "received loose chunk";
    const hash = objectChunkId(bytes);
    try db.putObjectChunk(hash, bytes);

    try std.testing.expect(try db.hasObjectChunk(hash));
    var chunk = try db.getObjectChunk(std.testing.allocator, hash);
    defer chunk.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &hash, &chunk.hash);
    try std.testing.expectEqualSlices(u8, bytes, chunk.bytes);

    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));
    try db.putObjectChunk(hash, bytes);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_object_chunks"));
}

test "put object chunk validates hash and size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "loose-chunk-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expectError(error.ObjectCorrupt, db.putObjectChunk(objectChunkId(""), ""));
    try std.testing.expectError(error.ObjectChunkHashMismatch, db.putObjectChunk(objectChunkId("expected"), "actual"));

    const too_large = try std.testing.allocator.alloc(u8, fastcdc.max_size + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 0xaa);
    try std.testing.expectError(error.ObjectCorrupt, db.putObjectChunk(objectChunkId(too_large), too_large));

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
}

test "loose object chunks persist and work after conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "loose-chunk-reopen.zova");

        const hash = objectChunkId("persisted loose chunk");
        {
            var db = try Database.create(db_path);
            defer db.deinit();
            try db.putObjectChunk(hash, "persisted loose chunk");
        }

        var reopened = try Database.open(db_path);
        defer reopened.deinit();
        var chunk = try reopened.getObjectChunk(std.testing.allocator, hash);
        defer chunk.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "persisted loose chunk", chunk.bytes);
    }

    {
        var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "loose-source.db");
        const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "loose-converted.zova");

        {
            var source = try sqlite.Database.open(source_path);
            defer source.deinit();
            try source.exec("create table source_rows (id integer primary key, body text not null)");
            try source.exec("insert into source_rows (body) values ('source data')");
        }

        try convertSqliteToZova(source_path, dest_path);

        var db = try Database.open(dest_path);
        defer db.deinit();

        const hash = objectChunkId("converted loose chunk");
        try db.putObjectChunk(hash, "converted loose chunk");

        var chunk = try db.getObjectChunk(std.testing.allocator, hash);
        defer chunk.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "converted loose chunk", chunk.bytes);
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from source_rows"));
    }
}

test "put object chunk detects existing corrupt rows and participates in caller transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "loose-chunk-corrupt-existing.zova");

        var db = try Database.create(db_path);
        defer db.deinit();

        const bytes = "loose valid";
        const hash = objectChunkId(bytes);
        try db.putObjectChunk(hash, bytes);

        var corrupt = try db.prepare("update _zova_chunks set data = ? where chunk_hash = ?");
        defer corrupt.deinit();
        try corrupt.bindBlob(1, "loose wrong");
        try corrupt.bindBlob(2, &hash);
        try std.testing.expectEqual(sqlite.Step.done, try corrupt.step());

        try std.testing.expectError(error.ObjectCorrupt, db.putObjectChunk(hash, bytes));
        try std.testing.expectError(error.ObjectCorrupt, db.getObjectChunk(std.testing.allocator, hash));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "loose-chunk-transaction.zova");

        var db = try Database.create(db_path);
        defer db.deinit();

        const hash = objectChunkId("transaction loose chunk");
        try db.sqlite_db.begin();
        try db.putObjectChunk(hash, "transaction loose chunk");
        try db.sqlite_db.commit();

        var chunk = try db.getObjectChunk(std.testing.allocator, hash);
        defer chunk.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "transaction loose chunk", chunk.bytes);
    }
}

test "assemble object from verified chunks supports empty one chunk multi chunk and shuffled input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "assemble-basic.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const empty_id = objectId("");
    try db.assembleObjectFromChunks(empty_id, 0, &.{});
    var empty = try db.getObject(std.testing.allocator, empty_id);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "", empty.bytes);

    const small = "assembled small";
    const small_id = objectId(small);
    const small_manifest = try testingPutLooseManifest(std.testing.allocator, &db, small);
    defer std.testing.allocator.free(small_manifest);
    try db.assembleObjectFromChunks(small_id, small.len, small_manifest);
    var small_object = try db.getObject(std.testing.allocator, small_id);
    defer small_object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, small, small_object.bytes);

    var large = try std.testing.allocator.alloc(u8, fastcdc.max_size + fastcdc.avg_size * 2);
    defer std.testing.allocator.free(large);
    for (large, 0..) |*byte, index| {
        byte.* = @intCast((index * 17 + index / 3 + 41) % 251);
    }

    const large_id = objectId(large);
    const large_manifest = try testingPutLooseManifest(std.testing.allocator, &db, large);
    defer std.testing.allocator.free(large_manifest);
    try std.testing.expect(large_manifest.len > 1);

    const shuffled = try std.testing.allocator.dupe(ObjectChunk, large_manifest);
    defer std.testing.allocator.free(shuffled);
    std.mem.reverse(ObjectChunk, shuffled);

    try db.assembleObjectFromChunks(large_id, large.len, shuffled);
    var range: [257]u8 = undefined;
    try std.testing.expectEqual(range.len, try db.readObjectRange(large_id, 1234, &range));
    try std.testing.expectEqualSlices(u8, large[1234 .. 1234 + range.len], &range);

    var manifest = try db.objectManifest(std.testing.allocator, large_id);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, large.len), manifest.size_bytes);
    try std.testing.expectEqual(@as(usize, large_manifest.len), manifest.chunks.len);
}

test "assemble object consumes existing chunks and rejects existing objects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "assemble-existing.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const shared = "chunk already stored by another object";
    const tail = " plus loose chunk";
    const base_id = try db.putObject(shared);
    var base_manifest = try db.objectManifest(std.testing.allocator, base_id);
    defer base_manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), base_manifest.chunks.len);

    const combined = try std.mem.concat(std.testing.allocator, u8, &.{ shared, tail });
    defer std.testing.allocator.free(combined);
    const combined_id = objectId(combined);
    const tail_hash = objectChunkId(tail);
    try db.putObjectChunk(tail_hash, tail);

    const combined_manifest = [_]ObjectChunk{
        base_manifest.chunks[0],
        .{
            .index = 1,
            .hash = tail_hash,
            .offset = shared.len,
            .size_bytes = tail.len,
        },
    };
    try db.assembleObjectFromChunks(combined_id, combined.len, &combined_manifest);
    var combined_object = try db.getObject(std.testing.allocator, combined_id);
    defer combined_object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, combined, combined_object.bytes);
    try std.testing.expectEqual(@as(i64, 1), try testingSharedChunkCount(&db, base_id, combined_id));

    try std.testing.expectError(error.ObjectAlreadyExists, db.assembleObjectFromChunks(base_id, shared.len, &.{}));

    const corrupt_id = try db.putObject("corrupt existing");
    {
        var corrupt = try db.prepare(
            \\update _zova_chunks
            \\set data = ?
            \\where chunk_hash in (
            \\  select chunk_hash from _zova_object_chunks where object_id = ?
            \\)
        );
        defer corrupt.deinit();
        try corrupt.bindBlob(1, "xxxxxxxxxxxxxxxx");
        try corrupt.bindBlob(2, &corrupt_id);
        try std.testing.expectEqual(sqlite.Step.done, try corrupt.step());
    }
    try std.testing.expectError(error.ObjectCorrupt, db.assembleObjectFromChunks(corrupt_id, 0, &.{}));
}

test "assemble object validates manifest and chunk storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "assemble-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = "manifest validation";
    const id = objectId(bytes);
    const manifest = try testingPutLooseManifest(std.testing.allocator, &db, bytes);
    defer std.testing.allocator.free(manifest);
    try std.testing.expectEqual(@as(usize, 1), manifest.len);

    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(objectId("wrong id"), bytes.len, manifest));
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len + 1, manifest));

    var bad = try std.testing.allocator.dupe(ObjectChunk, manifest);
    defer std.testing.allocator.free(bad);

    bad[0].index = 1;
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, bad));

    bad[0] = manifest[0];
    bad[0].offset = 1;
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, bad));

    bad[0] = manifest[0];
    bad[0].size_bytes -= 1;
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, bad));

    bad[0] = manifest[0];
    bad[0].size_bytes = 0;
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, bad));

    bad[0] = manifest[0];
    bad[0].size_bytes = fastcdc.max_size + 1;
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, bad));

    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(id, bytes.len, &.{}));

    const left = "left";
    const right = "right";
    const left_hash = objectChunkId(left);
    const right_hash = objectChunkId(right);
    try db.putObjectChunk(left_hash, left);
    try db.putObjectChunk(right_hash, right);
    const overlap = [_]ObjectChunk{
        .{
            .index = 0,
            .hash = left_hash,
            .offset = 0,
            .size_bytes = left.len,
        },
        .{
            .index = 1,
            .hash = right_hash,
            .offset = 2,
            .size_bytes = right.len,
        },
    };
    try std.testing.expectError(error.ObjectManifestInvalid, db.assembleObjectFromChunks(objectId("leftright"), left.len + right.len, &overlap));

    const missing = [_]ObjectChunk{.{
        .index = 0,
        .hash = objectChunkId("missing"),
        .offset = 0,
        .size_bytes = "missing".len,
    }};
    try std.testing.expectError(error.ObjectChunkNotFound, db.assembleObjectFromChunks(objectId("missing"), "missing".len, &missing));

    {
        const corrupt_bytes = try std.testing.allocator.dupe(u8, bytes);
        defer std.testing.allocator.free(corrupt_bytes);
        corrupt_bytes[0] +%= 1;

        var corrupt = try db.prepare("update _zova_chunks set data = ? where chunk_hash = ?");
        defer corrupt.deinit();
        try corrupt.bindBlob(1, corrupt_bytes);
        try corrupt.bindBlob(2, &manifest[0].hash);
        try std.testing.expectEqual(sqlite.Step.done, try corrupt.step());
    }
    try std.testing.expectError(error.ObjectCorrupt, db.assembleObjectFromChunks(id, bytes.len, manifest));
}

test "assemble object owns transactions rolls back failures and works after conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "assemble-transaction.zova");

        var db = try Database.create(db_path);
        defer db.deinit();

        const bytes = "transaction assembly";
        const id = objectId(bytes);
        const manifest = try testingPutLooseManifest(std.testing.allocator, &db, bytes);
        defer std.testing.allocator.free(manifest);

        try db.sqlite_db.begin();
        try std.testing.expectError(error.ObjectTransactionActive, db.assembleObjectFromChunks(id, bytes.len, manifest));
        try db.sqlite_db.rollback();

        try db.exec(
            \\create trigger force_manifest_insert_failure
            \\before insert on _zova_object_chunks
            \\begin
            \\  select raise(abort, 'forced manifest failure');
            \\end;
        );
        try std.testing.expectError(error.Constraint, db.assembleObjectFromChunks(id, bytes.len, manifest));
        try std.testing.expect(!try db.hasObject(id));
        try std.testing.expectEqual(@as(i64, 0), try testingObjectManifestCount(&db, id));
        try std.testing.expect(try db.hasObjectChunk(manifest[0].hash));

        try db.exec("drop trigger force_manifest_insert_failure");
        try db.assembleObjectFromChunks(id, bytes.len, manifest);
        var object = try db.getObject(std.testing.allocator, id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, bytes, object.bytes);
    }

    {
        var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "assemble-source.db");
        const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "assemble-converted.zova");

        {
            var source = try sqlite.Database.open(source_path);
            defer source.deinit();
            try source.exec("create table notes (id integer primary key, body text not null)");
            try source.exec("insert into notes (body) values ('source row')");
        }

        try convertSqliteToZova(source_path, dest_path);
        var db = try Database.open(dest_path);
        defer db.deinit();

        const bytes = "converted assembly";
        const id = objectId(bytes);
        const manifest = try testingPutLooseManifest(std.testing.allocator, &db, bytes);
        defer std.testing.allocator.free(manifest);
        try db.assembleObjectFromChunks(id, bytes.len, manifest);

        var object = try db.getObject(std.testing.allocator, id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, bytes, object.bytes);
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes"));
    }
}

test "delete object chunk removes only unreferenced loose chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "delete-object-chunk.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const loose_hash = objectChunkId("loose cleanup");
    try std.testing.expect(!try db.deleteObjectChunk(loose_hash));
    try db.putObjectChunk(loose_hash, "loose cleanup");
    try std.testing.expect(try db.deleteObjectChunk(loose_hash));
    try std.testing.expect(!try db.hasObjectChunk(loose_hash));
    try std.testing.expect(!try db.deleteObjectChunk(loose_hash));

    const id = try db.putObject("referenced chunk");
    var manifest = try db.objectManifest(std.testing.allocator, id);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), manifest.chunks.len);
    try std.testing.expect(!try db.deleteObjectChunk(manifest.chunks[0].hash));
    try std.testing.expect(try db.hasObjectChunk(manifest.chunks[0].hash));

    try db.deleteObject(id);
    try std.testing.expect(!try db.hasObjectChunk(manifest.chunks[0].hash));

    try db.exec("drop table _zova_chunks");
    try std.testing.expectError(error.SqliteError, db.deleteObjectChunk(loose_hash));
    try db.exec(object_impl.chunks_schema_sql ++ ";");
    try db.putObjectChunk(loose_hash, "loose cleanup");
    try std.testing.expect(try db.deleteObjectChunk(loose_hash));
}

test "object range reads copy caller requested bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-range-read.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const empty_id = try db.putObject("");
    var empty_buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try db.readObjectRange(empty_id, 0, &empty_buffer));

    const missing = objectId("missing");
    try std.testing.expectError(error.ObjectNotFound, db.readObjectRange(missing, 0, &empty_buffer));

    const small = "hello range";
    const small_id = try db.putObject(small);
    var small_full: [small.len]u8 = undefined;
    try std.testing.expectEqual(small.len, try db.readObjectRange(small_id, 0, &small_full));
    try std.testing.expectEqualSlices(u8, small, &small_full);

    var one: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try db.readObjectRange(small_id, 0, &one));
    try std.testing.expectEqual(@as(u8, 'h'), one[0]);
    try std.testing.expectEqual(@as(usize, 1), try db.readObjectRange(small_id, small.len - 1, &one));
    try std.testing.expectEqual(@as(u8, 'e'), one[0]);

    var tail: [64]u8 = undefined;
    const tail_len = try db.readObjectRange(small_id, 6, &tail);
    try std.testing.expectEqual(@as(usize, 5), tail_len);
    try std.testing.expectEqualSlices(u8, "range", tail[0..tail_len]);
    try std.testing.expectEqual(@as(usize, 0), try db.readObjectRange(small_id, small.len, &tail));
    try std.testing.expectEqual(@as(usize, 0), try db.readObjectRange(small_id, 0, tail[0..0]));
    try std.testing.expectError(error.ObjectRangeInvalid, db.readObjectRange(small_id, small.len + 1, &tail));

    {
        var delete_manifest = try db.prepare("delete from _zova_object_chunks where object_id = ?");
        defer delete_manifest.deinit();

        try delete_manifest.bindBlob(1, &small_id);
        try std.testing.expectEqual(sqlite.Step.done, try delete_manifest.step());
    }
    try std.testing.expectEqual(@as(usize, 0), try db.readObjectRange(small_id, small.len, &tail));
    try std.testing.expectEqual(@as(usize, 0), try db.readObjectRange(small_id, 0, tail[0..0]));
    try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(small_id, 0, &tail));

    var bytes: [fastcdc.max_size * 3 + fastcdc.avg_size]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 17 + index / 11 + 31) % 251);
    }

    const large_id = try db.putObject(&bytes);
    var manifest = try db.objectManifest(std.testing.allocator, large_id);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expect(manifest.chunks.len > 2);

    const full = try std.testing.allocator.alloc(u8, bytes.len);
    defer std.testing.allocator.free(full);
    try std.testing.expectEqual(bytes.len, try db.readObjectRange(large_id, 0, full));
    try std.testing.expectEqualSlices(u8, &bytes, full);

    var within_one_chunk: [17]u8 = undefined;
    const within_offset: usize = @intCast(manifest.chunks[0].offset + 3);
    try std.testing.expectEqual(within_one_chunk.len, try db.readObjectRange(large_id, within_offset, &within_one_chunk));
    try std.testing.expectEqualSlices(u8, bytes[within_offset .. within_offset + within_one_chunk.len], &within_one_chunk);

    var across_two_chunks: [32]u8 = undefined;
    const two_chunk_offset: usize = @intCast(manifest.chunks[1].offset - 7);
    try std.testing.expectEqual(across_two_chunks.len, try db.readObjectRange(large_id, two_chunk_offset, &across_two_chunks));
    try std.testing.expectEqualSlices(u8, bytes[two_chunk_offset .. two_chunk_offset + across_two_chunks.len], &across_two_chunks);

    var across_many_chunks: [fastcdc.max_size + 4096]u8 = undefined;
    const many_offset: usize = @intCast(manifest.chunks[0].size_bytes - 11);
    try std.testing.expectEqual(across_many_chunks.len, try db.readObjectRange(large_id, many_offset, &across_many_chunks));
    try std.testing.expectEqualSlices(u8, bytes[many_offset .. many_offset + across_many_chunks.len], &across_many_chunks);

    var reopened = try Database.open(db_path);
    defer reopened.deinit();
    var repeated: [19]u8 = undefined;
    try std.testing.expectEqual(repeated.len, try reopened.readObjectRange(large_id, 1234, &repeated));
    try std.testing.expectEqualSlices(u8, bytes[1234 .. 1234 + repeated.len], &repeated);
}

test "object range reads report corrupt private rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-missing-chunk.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("missing chunk");
        var buffer: [16]u8 = undefined;
        try db.exec("delete from _zova_chunks");
        try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(id, 0, &buffer));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-bad-chunk-data.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("abc");
        var buffer: [3]u8 = undefined;
        try db.exec("update _zova_chunks set data = x'616264'");
        try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(id, 0, &buffer));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-missing-manifest.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("missing manifest");
        var buffer: [16]u8 = undefined;
        try db.exec("delete from _zova_object_chunks");
        try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(id, 0, &buffer));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-bad-index.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("bad index");
        var buffer: [9]u8 = undefined;
        try db.exec("update _zova_object_chunks set chunk_index = 1");
        try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(id, 0, &buffer));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-inflated-count.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("inflated count");
        var buffer: [14]u8 = undefined;
        try db.exec("update _zova_objects set size_bytes = 1000000, chunk_count = 1000000");
        try std.testing.expectError(error.ObjectCorrupt, db.readObjectRange(id, 0, &buffer));
    }
}

test "database open accepts corrupt object bytes but read APIs detect corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "open-corrupt-object.zova");
    const id = id: {
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("corrupt after open");
        try db.exec("update _zova_chunks set data = x'636f7272757074206166746572204f50454e'");
        break :id id;
    };

    var reopened = try Database.open(db_path);
    defer reopened.deinit();

    try std.testing.expect(try reopened.hasObject(id));
    var buffer: [18]u8 = undefined;
    try std.testing.expectError(error.ObjectCorrupt, reopened.readObjectRange(id, 0, &buffer));
    try std.testing.expectError(error.ObjectCorrupt, reopened.getObject(std.testing.allocator, id));
}

test "two connections can read object ranges concurrently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "concurrent-range-reads.zova");

    var first = try Database.create(db_path);
    defer first.deinit();

    const bytes = "concurrent object range reads";
    const id = try first.putObject(bytes);

    var second = try Database.open(db_path);
    defer second.deinit();

    var first_read: [10]u8 = undefined;
    var second_read: [12]u8 = undefined;
    try std.testing.expectEqual(first_read.len, try first.readObjectRange(id, 0, &first_read));
    try std.testing.expectEqual(second_read.len, try second.readObjectRange(id, 11, &second_read));
    try std.testing.expectEqualSlices(u8, bytes[0..first_read.len], &first_read);
    try std.testing.expectEqualSlices(u8, bytes[11 .. 11 + second_read.len], &second_read);
}

test "two connections can read writer-created object ranges concurrently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "writer-concurrent-range-reads.zova");

    var first = try Database.create(db_path);
    defer first.deinit();

    var bytes: [fastcdc.max_size * 2 + 4096]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 13 + index / 3 + 41) % 253);
    }
    const id = try testingStreamObject(&first, &bytes, &.{ 5, 1000, 65_537, 11 });

    var second = try Database.open(db_path);
    defer second.deinit();

    var first_read: [257]u8 = undefined;
    var second_read: [1024]u8 = undefined;
    try std.testing.expectEqual(first_read.len, try first.readObjectRange(id, 4093, &first_read));
    try std.testing.expectEqual(second_read.len, try second.readObjectRange(id, fastcdc.max_size - 17, &second_read));
    try std.testing.expectEqualSlices(u8, bytes[4093 .. 4093 + first_read.len], &first_read);
    try std.testing.expectEqualSlices(u8, bytes[fastcdc.max_size - 17 .. fastcdc.max_size - 17 + second_read.len], &second_read);
}

test "range reads report sqlite lock errors under exclusive lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "range-read-exclusive-lock.zova");

    var first = try Database.create(db_path);
    defer first.deinit();
    const id = try first.putObject("locked range read");

    var second = try Database.open(db_path);
    defer second.deinit();

    try first.exec("begin exclusive");
    defer first.exec("rollback") catch {};

    var buffer: [6]u8 = undefined;
    const result = second.readObjectRange(id, 0, &buffer);
    try std.testing.expectError(error.Busy, result);
}

test "duplicate chunks are addressable once by distinct chunk hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "distinct-duplicate-chunks.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    const bytes = [_]u8{0} ** (fastcdc.max_size * 4);
    const id = try db.putObject(&bytes);
    const chunk_rows = try testingCount(&db, "select count(*) from _zova_chunks");
    const manifest_rows = try testingObjectManifestCount(&db, id);
    try std.testing.expect(manifest_rows > chunk_rows);

    var hashes = std.AutoHashMap(ObjectChunkId, void).init(std.testing.allocator);
    defer hashes.deinit();

    var manifest = try db.objectManifest(std.testing.allocator, id);
    defer manifest.deinit(std.testing.allocator);

    for (manifest.chunks) |chunk| {
        try hashes.put(chunk.hash, {});
    }
    try std.testing.expectEqual(@as(usize, @intCast(chunk_rows)), hashes.count());

    var iterator = hashes.iterator();
    while (iterator.next()) |entry| {
        var chunk = try db.getObjectChunk(std.testing.allocator, entry.key_ptr.*);
        defer chunk.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, entry.key_ptr, &chunk.hash);
    }
}

test "manifest and chunk reads report corrupt private rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-missing-chunk.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("missing chunk");
        try db.exec("delete from _zova_chunks");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-bad-offset.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("bad offset");
        try db.exec("update _zova_object_chunks set offset = 1");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-missing-row.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("missing manifest");
        try db.exec("delete from _zova_object_chunks");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-bad-index.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("bad index");
        try db.exec("update _zova_object_chunks set chunk_index = 1");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-bad-size.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("abc");
        try db.exec("update _zova_object_chunks set size_bytes = 1");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "manifest-inflated-count.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("inflated count");
        try db.exec("update _zova_objects set size_bytes = 1000000, chunk_count = 1000000");
        try std.testing.expectError(error.ObjectCorrupt, db.objectManifest(std.testing.allocator, id));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "chunk-bad-data.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("abc");
        var manifest = try db.objectManifest(std.testing.allocator, id);
        defer manifest.deinit(std.testing.allocator);

        try db.exec("update _zova_chunks set data = x'616264'");
        try std.testing.expectError(error.ObjectCorrupt, db.getObjectChunk(std.testing.allocator, manifest.chunks[0].hash));
    }

    {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "chunk-bad-size.zova");
        var db = try Database.create(db_path);
        defer db.deinit();

        const id = try db.putObject("abc");
        var manifest = try db.objectManifest(std.testing.allocator, id);
        defer manifest.deinit(std.testing.allocator);

        try db.exec("pragma ignore_check_constraints = on");
        try db.exec("update _zova_chunks set size_bytes = 2");
        try db.exec("pragma ignore_check_constraints = off");
        try std.testing.expectError(error.ObjectCorrupt, db.getObjectChunk(std.testing.allocator, manifest.chunks[0].hash));
    }
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
        try raw.exec(object_impl.objects_schema_sql ++ ";");
        try raw.exec(object_impl.chunks_schema_sql ++ ";");
        try raw.exec(object_impl.object_chunks_schema_sql ++ ";");
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
        try raw.exec(object_impl.objects_schema_sql ++ ";");
        try raw.exec(object_impl.chunks_schema_sql ++ ";");
        try raw.exec(object_impl.object_chunks_schema_sql ++ ";");
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
        try raw.exec(object_impl.objects_schema_sql ++ ";");
        try raw.exec(object_impl.chunks_schema_sql ++ ";");
        try raw.exec(object_impl.object_chunks_schema_sql ++ ";");
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

test "vector collection info and listing return owned sorted metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-collection-info.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    {
        var empty = try db.listVectorCollections(std.testing.allocator);
        defer empty.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    }

    try db.createVectorCollection("beta", .{ .dimensions = 2, .metric = .dot });
    try db.createVectorCollection("alpha", .{ .dimensions = 3, .metric = .cosine });
    try db.putVector("alpha", "a-1", &.{ 1.0, 0.0, 0.0 });
    try db.putVector("alpha", "a-2", &.{ 0.0, 1.0, 0.0 });
    try db.putVector("beta", "b-1", &.{ 2.0, 3.0 });

    {
        var info = try db.vectorCollectionInfo(std.testing.allocator, "alpha");
        defer info.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("alpha", info.name);
        try std.testing.expectEqual(@as(u32, 3), info.dimensions);
        try std.testing.expectEqual(VectorMetric.cosine, info.metric);
        try std.testing.expectEqual(@as(u64, 2), info.vector_count);
    }

    {
        var list = try db.listVectorCollections(std.testing.allocator);
        defer list.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), list.items.len);
        try std.testing.expectEqualStrings("alpha", list.items[0].name);
        try std.testing.expectEqual(@as(u32, 3), list.items[0].dimensions);
        try std.testing.expectEqual(VectorMetric.cosine, list.items[0].metric);
        try std.testing.expectEqual(@as(u64, 2), list.items[0].vector_count);
        try std.testing.expectEqualStrings("beta", list.items[1].name);
        try std.testing.expectEqual(@as(u32, 2), list.items[1].dimensions);
        try std.testing.expectEqual(VectorMetric.dot, list.items[1].metric);
        try std.testing.expectEqual(@as(u64, 1), list.items[1].vector_count);
    }

    try std.testing.expectError(error.VectorCollectionNotFound, db.vectorCollectionInfo(std.testing.allocator, "missing"));
    try std.testing.expectError(error.VectorInvalid, db.vectorCollectionInfo(std.testing.allocator, ""));
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

test "batch vector upsert validates before writing and last duplicate wins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-batch.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });

    const invalid_batch = [_]VectorInput{
        .{ .id = "good", .values = &.{ 1.0, 1.0 } },
        .{ .id = "bad", .values = &.{1.0} },
    };
    try std.testing.expectError(error.VectorDimensionMismatch, db.putVectors("chunks", &invalid_batch));
    try std.testing.expect(!try db.hasVector("chunks", "good"));

    const batch = [_]VectorInput{
        .{ .id = "a", .values = &.{ 1.0, 2.0 } },
        .{ .id = "b", .values = &.{ 3.0, 4.0 } },
        .{ .id = "a", .values = &.{ 5.0, 6.0 } },
    };
    try db.putVectors("chunks", &batch);

    {
        var vector = try db.getVector(std.testing.allocator, "chunks", "a");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 5.0, 6.0 }, vector.values);
    }
    {
        var vector = try db.getVector(std.testing.allocator, "chunks", "b");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 3.0, 4.0 }, vector.values);
    }

    try db.putVectors("chunks", &.{});
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from _zova_vectors where collection_name = 'chunks'"));

    try std.testing.expectError(error.VectorCollectionNotFound, db.putVectors("missing", &batch));
    const invalid_id = [_]VectorInput{.{ .id = "_zova_bad", .values = &.{ 1.0, 2.0 } }};
    try std.testing.expectError(error.VectorInvalid, db.putVectors("chunks", &invalid_id));

    try db.exec("begin");
    try db.putVectors("chunks", &[_]VectorInput{.{ .id = "tx", .values = &.{ 7.0, 8.0 } }});
    try db.exec("commit");
    try std.testing.expect(try db.hasVector("chunks", "tx"));
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

test "delete vector collection removes private vectors and leaves sql references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-delete-collection.zova");

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
    try db.putVectors("chunks", &[_]VectorInput{
        .{ .id = "keep-ref-1", .values = &.{ 1.0, 1.0 } },
        .{ .id = "keep-ref-2", .values = &.{ 2.0, 2.0 } },
    });

    var insert = try db.prepare("insert into chunks (vector_id, body) values (?, ?)");
    defer insert.deinit();
    try insert.bindText(1, "keep-ref-1");
    try insert.bindText(2, "application row 1");
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    try insert.reset();
    try insert.clearBindings();
    try insert.bindText(1, "keep-ref-2");
    try insert.bindText(2, "application row 2");
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());

    try db.exec("begin");
    try db.deleteVectorCollection("chunks");
    try db.exec("commit");

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors where collection_name = 'chunks'"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vector_collections where name = 'chunks'"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from chunks"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.hasVector("chunks", "keep-ref-1"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.getVector(std.testing.allocator, "chunks", "keep-ref-1"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.searchVectors(std.testing.allocator, "chunks", &.{ 1.0, 1.0 }, 10));
    try std.testing.expectError(error.VectorCollectionNotFound, db.deleteVectorCollection("chunks"));
    try std.testing.expectError(error.VectorInvalid, db.deleteVectorCollection(""));
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

test "vector collection management persists and works after conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "collection-management-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "collection-management-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table docs (id integer primary key, body text not null); insert into docs (body) values ('alpha'), ('beta')");
    }

    try convertSqliteToZova(source_path, dest_path);

    {
        var db = try Database.open(dest_path);
        defer db.deinit();
        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .dot });
        try db.putVectors("docs", &[_]VectorInput{
            .{ .id = "doc-1", .values = &.{ 1.0, 0.0 } },
            .{ .id = "doc-2", .values = &.{ 0.0, 1.0 } },
        });
    }

    {
        var reopened = try Database.open(dest_path);
        defer reopened.deinit();

        var info = try reopened.vectorCollectionInfo(std.testing.allocator, "docs");
        defer info.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("docs", info.name);
        try std.testing.expectEqual(VectorMetric.dot, info.metric);
        try std.testing.expectEqual(@as(u64, 2), info.vector_count);

        try reopened.deleteVectorCollection("docs");
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&reopened, "select count(*) from docs"));
    }
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

test "candidate-filtered vector search ranks only supplied ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-candidates.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("docs", "global-nearest", &.{ 0.0, 0.0 });
    try db.putVector("docs", "near", &.{ 1.0, 0.0 });
    try db.putVector("docs", "tie-b", &.{ 0.0, 2.0 });
    try db.putVector("docs", "tie-a", &.{ 2.0, 0.0 });
    try db.putVector("docs", "far", &.{ 10.0, 0.0 });

    const candidates = [_][]const u8{ "far", "missing", "tie-b", "near", "tie-a", "near" };
    var results = try db.searchVectorsIn(std.testing.allocator, "docs", &.{ 0.0, 0.0 }, &candidates, 3);
    defer results.deinit(std.testing.allocator);

    try expectSearchIds(&results, &.{ "near", "tie-a", "tie-b" });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), results.items[0].distance, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), results.items[1].distance, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), results.items[2].distance, 0.000001);
}

test "candidate-filtered vector search validates inputs and handles empty limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-candidate-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });
    try db.putVector("docs", "valid", &.{ 1.0, 2.0 });

    const valid_candidates = [_][]const u8{"valid"};
    const invalid_candidates = [_][]const u8{ "_zova_bad", "valid" };

    try std.testing.expectError(error.VectorCollectionNotFound, db.searchVectorsIn(std.testing.allocator, "missing", &.{ 1.0, 2.0 }, &valid_candidates, 10));
    try std.testing.expectError(error.VectorDimensionMismatch, db.searchVectorsIn(std.testing.allocator, "docs", &.{1.0}, &valid_candidates, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsIn(std.testing.allocator, "docs", &.{ std.math.nan(f32), 1.0 }, &valid_candidates, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsIn(std.testing.allocator, "docs", &.{ std.math.inf(f32), 1.0 }, &valid_candidates, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsIn(std.testing.allocator, "cosine", &.{ 0.0, 0.0 }, &valid_candidates, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsIn(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &invalid_candidates, 0));

    var empty_limit = try db.searchVectorsIn(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &valid_candidates, 0);
    defer empty_limit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_limit.items.len);

    var empty_candidates = try db.searchVectorsIn(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &.{}, 10);
    defer empty_candidates.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_candidates.items.len);
}

test "candidate-filtered vector search supports cosine dot reopen and conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "candidate-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "candidate-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table docs (id integer primary key, body text not null); insert into docs (body) values ('a'), ('b')");
    }

    try convertSqliteToZova(source_path, dest_path);

    {
        var db = try Database.open(dest_path);
        defer db.deinit();

        try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });
        try db.putVector("cosine", "east", &.{ 1.0, 0.0 });
        try db.putVector("cosine", "north", &.{ 0.0, 1.0 });
        try db.putVector("cosine", "northeast", &.{ 1.0, 1.0 });

        try db.createVectorCollection("dot", .{ .dimensions = 2, .metric = .dot });
        try db.putVector("dot", "large", &.{ 3.0, 0.0 });
        try db.putVector("dot", "small", &.{ 1.0, 0.0 });
        try db.putVector("dot", "negative", &.{ -1.0, 0.0 });
    }

    {
        var reopened = try Database.open(dest_path);
        defer reopened.deinit();

        const cosine_candidates = [_][]const u8{ "north", "northeast" };
        var cosine_results = try reopened.searchVectorsIn(std.testing.allocator, "cosine", &.{ 1.0, 0.0 }, &cosine_candidates, 10);
        defer cosine_results.deinit(std.testing.allocator);
        try expectSearchIds(&cosine_results, &.{ "northeast", "north" });
        try std.testing.expectApproxEqAbs(@as(f64, 1.0 - 0.7071067811865475), cosine_results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosine_results.items[1].distance, 0.000001);

        const dot_candidates = [_][]const u8{ "small", "negative" };
        var dot_results = try reopened.searchVectorsIn(std.testing.allocator, "dot", &.{ 1.0, 0.0 }, &dot_candidates, 10);
        defer dot_results.deinit(std.testing.allocator);
        try expectSearchIds(&dot_results, &.{ "small", "negative" });
        try std.testing.expectApproxEqAbs(@as(f64, -1.0), dot_results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), dot_results.items[1].distance, 0.000001);
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&reopened, "select count(*) from docs"));
    }
}

test "candidate-filtered vector search reports only selected corrupt private vector rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-candidate-corrupt.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("docs", "good", &.{ 1.0, 2.0 });
    try db.putVector("docs", "bad", &.{ 3.0, 4.0 });
    try db.exec("pragma ignore_check_constraints = on");
    try db.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'bad'");
    try db.exec("pragma ignore_check_constraints = off");

    const good_only = [_][]const u8{"good"};
    var results = try db.searchVectorsIn(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &good_only, 10);
    defer results.deinit(std.testing.allocator);
    try expectSearchIds(&results, &.{"good"});

    const selected_bad = [_][]const u8{"bad"};
    try std.testing.expectError(error.VectorCorrupt, db.searchVectorsIn(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &selected_bad, 10));
}

test "search vectors by id excludes source and supports candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-by-id.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("docs", "source", &.{ 0.0, 0.0 });
    try db.putVector("docs", "near", &.{ 1.0, 0.0 });
    try db.putVector("docs", "tie-b", &.{ 0.0, 2.0 });
    try db.putVector("docs", "tie-a", &.{ 2.0, 0.0 });
    try db.putVector("docs", "global-far", &.{ 10.0, 0.0 });

    {
        var results = try db.searchVectorsById(std.testing.allocator, "docs", "source", 3);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "near", "tie-a", "tie-b" });
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), results.items[0].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), results.items[1].distance, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), results.items[2].distance, 0.000001);
    }

    {
        const candidates = [_][]const u8{ "source", "global-far", "missing", "near", "near" };
        var results = try db.searchVectorsByIdIn(std.testing.allocator, "docs", "source", &candidates, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "near", "global-far" });
    }
}

test "vector search thresholds filter inclusively across search modes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-thresholds.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("l2", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("l2", "source", &.{ 0.0, 0.0 });
    try db.putVector("l2", "one", &.{ 1.0, 0.0 });
    try db.putVector("l2", "two", &.{ 2.0, 0.0 });
    try db.putVector("l2", "three", &.{ 3.0, 0.0 });

    {
        var results = try db.searchVectorsWithin(std.testing.allocator, "l2", &.{ 0.0, 0.0 }, 2.0, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "source", "one", "two" });
    }

    {
        const candidates = [_][]const u8{ "one", "two", "three" };
        var results = try db.searchVectorsInWithin(std.testing.allocator, "l2", &.{ 0.0, 0.0 }, &candidates, 1.0, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"one"});
    }

    {
        var results = try db.searchVectorsByIdWithin(std.testing.allocator, "l2", "source", 2.0, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "one", "two" });
    }

    {
        const candidates = [_][]const u8{ "source", "one", "two", "three" };
        var results = try db.searchVectorsByIdInWithin(std.testing.allocator, "l2", "source", &candidates, 1.0, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"one"});
    }

    try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });
    try db.putVector("cosine", "east", &.{ 1.0, 0.0 });
    try db.putVector("cosine", "northeast", &.{ 1.0, 1.0 });
    try db.putVector("cosine", "north", &.{ 0.0, 1.0 });
    {
        var results = try db.searchVectorsWithin(std.testing.allocator, "cosine", &.{ 1.0, 0.0 }, 0.3, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "east", "northeast" });
    }

    try db.createVectorCollection("dot", .{ .dimensions = 2, .metric = .dot });
    try db.putVector("dot", "strong", &.{ 3.0, 0.0 });
    try db.putVector("dot", "weak", &.{ 1.0, 0.0 });
    try db.putVector("dot", "negative", &.{ -1.0, 0.0 });
    {
        var results = try db.searchVectorsWithin(std.testing.allocator, "dot", &.{ 1.0, 0.0 }, -1.0, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{ "strong", "weak" });
    }

    {
        var results = try db.searchVectorsWithin(std.testing.allocator, "l2", &.{ 0.0, 0.0 }, 0.5, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"source"});
    }
}

test "search vectors by id and thresholds validate inputs and corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-search-by-id-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("docs", "source", &.{ 1.0, 2.0 });
    try db.putVector("docs", "good", &.{ 2.0, 3.0 });
    try db.putVector("docs", "bad", &.{ 3.0, 4.0 });

    const valid_candidates = [_][]const u8{"good"};
    const invalid_candidates = [_][]const u8{"_zova_bad"};

    try std.testing.expectError(error.VectorCollectionNotFound, db.searchVectorsById(std.testing.allocator, "missing", "source", 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsById(std.testing.allocator, "docs", "_zova_bad", 10));
    try std.testing.expectError(error.VectorNotFound, db.searchVectorsById(std.testing.allocator, "docs", "missing", 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsInWithin(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, &invalid_candidates, 1.0, 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsWithin(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, std.math.nan(f64), 10));
    try std.testing.expectError(error.VectorInvalid, db.searchVectorsWithin(std.testing.allocator, "docs", &.{ 1.0, 2.0 }, std.math.inf(f64), 10));

    var empty_limit = try db.searchVectorsByIdInWithin(std.testing.allocator, "docs", "source", &valid_candidates, 1.0, 0);
    defer empty_limit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_limit.items.len);

    try db.exec("pragma ignore_check_constraints = on");
    try db.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'bad'");
    try db.exec("pragma ignore_check_constraints = off");

    try std.testing.expectError(error.VectorCorrupt, db.searchVectorsById(std.testing.allocator, "docs", "bad", 10));

    {
        var results = try db.searchVectorsByIdIn(std.testing.allocator, "docs", "source", &valid_candidates, 10);
        defer results.deinit(std.testing.allocator);
        try expectSearchIds(&results, &.{"good"});
    }

    const selected_bad = [_][]const u8{"bad"};
    try std.testing.expectError(error.VectorCorrupt, db.searchVectorsByIdIn(std.testing.allocator, "docs", "source", &selected_bad, 10));
}

test "sql vector scalar functions and virtual table rank metadata rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-sql.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec(
        \\create table chunks (
        \\  id text primary key,
        \\  document_id text not null,
        \\  body text not null,
        \\  vector_id text not null
        \\);
    );
    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("chunks", "chunk-a", &.{ 1.0, 0.0 });
    try db.putVector("chunks", "chunk-b", &.{ 3.0, 0.0 });
    try db.putVector("chunks", "chunk-c", &.{ 10.0, 0.0 });
    try db.exec(
        \\insert into chunks (id, document_id, body, vector_id) values
        \\  ('a', 'doc-1', 'alpha', 'chunk-a'),
        \\  ('b', 'doc-1', 'bravo', 'chunk-b'),
        \\  ('c', 'doc-2', 'charlie', 'chunk-c');
    );

    const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 0.0, 0.0 });
    defer std.testing.allocator.free(query_blob);

    {
        var stmt = try db.prepare(
            \\select c.id, zova_vector_distance('chunks', c.vector_id, ?) as distance
            \\from chunks c
            \\where c.document_id = 'doc-1'
            \\order by distance
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, query_blob);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("a", stmt.columnText(0));
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), stmt.columnDouble(1), 0.000001);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("b", stmt.columnText(0));
        try std.testing.expectApproxEqAbs(@as(f64, 3.0), stmt.columnDouble(1), 0.000001);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    {
        var stmt = try db.prepare(
            \\select c.id, zova_vector_distance_by_id('chunks', c.vector_id, 'chunk-a') as distance
            \\from chunks c
            \\where c.vector_id != 'chunk-a'
            \\order by distance
        );
        defer stmt.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("b", stmt.columnText(0));
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), stmt.columnDouble(1), 0.000001);
    }

    {
        var stmt = try db.prepare(
            \\select c.id, s.rank, s.distance
            \\from zova_vector_search as s
            \\join chunks c on c.vector_id = s.vector_id
            \\where s.collection = 'chunks'
            \\  and s.query_vector = ?
            \\  and s.top_k = 2
            \\order by s.rank
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, query_blob);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("a", stmt.columnText(0));
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt64(1));
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), stmt.columnDouble(2), 0.000001);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("b", stmt.columnText(0));
        try std.testing.expectEqual(@as(i64, 2), stmt.columnInt64(1));
        try std.testing.expectApproxEqAbs(@as(f64, 3.0), stmt.columnDouble(2), 0.000001);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    {
        var stmt = try db.prepare(
            \\select vector_id, distance
            \\from zova_vector_search
            \\where collection = 'chunks'
            \\  and source_vector_id = 'chunk-a'
            \\  and max_distance = 2.0
            \\order by rank
        );
        defer stmt.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("chunk-b", stmt.columnText(0));
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), stmt.columnDouble(1), 0.000001);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }
}

test "sql vector integration validates errors and registers only on zova connections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-sql-validation.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();

        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVector("docs", "source", &.{ 0.0, 0.0 });
        try db.putVector("docs", "near", &.{ 1.0, 0.0 });
        try db.putVector("docs", "far", &.{ 5.0, 0.0 });

        const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 0.0, 0.0 });
        defer std.testing.allocator.free(query_blob);

        {
            var stmt = try db.prepare(
                \\select vector_id
                \\from zova_vector_search
                \\where collection = 'docs'
                \\  and query_vector = ?
                \\  and top_k = 0
            );
            defer stmt.deinit();

            try stmt.bindBlob(1, query_blob);
            try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
        }

        try expectSqlPrepareOrStepError(&db, "select * from zova_vector_search");
        try expectSqlPrepareOrStepError(&db,
            \\select *
            \\from zova_vector_search
            \\where collection = 'docs'
            \\  and query_vector = x'0000000000000000'
            \\  and source_vector_id = 'source'
            \\  and top_k = 1
        );
        try expectSqlPrepareOrStepError(&db,
            \\select zova_vector_distance('docs', 'source', x'00')
        );
        try expectSqlPrepareOrStepError(&db,
            \\insert into zova_vector_search (rank, vector_id, distance)
            \\values (1, 'x', 0.0)
        );

        try db.exec("pragma ignore_check_constraints = on");
        try db.exec("update _zova_vectors set \"values\" = x'0000803f' where vector_id = 'far'");
        try db.exec("pragma ignore_check_constraints = off");
        try expectSqlPrepareOrStepError(&db,
            \\select zova_vector_distance('docs', 'far', x'0000000000000000')
        );
        try expectSqlPrepareOrStepError(&db,
            \\select vector_id
            \\from zova_vector_search
            \\where collection = 'docs'
            \\  and source_vector_id = 'source'
            \\  and top_k = 10
        );
    }

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try std.testing.expectError(error.SqliteError, raw.prepare(
            \\select zova_vector_distance('docs', 'source', x'0000000000000000')
        ));
    }

    {
        var reopened = try Database.open(db_path);
        defer reopened.deinit();

        var stmt = try reopened.prepare(
            \\select zova_vector_distance_by_id('docs', 'near', 'source')
        );
        defer stmt.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), stmt.columnDouble(0), 0.000001);
    }
}

test "sql vector integration works after sqlite conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "vector-sql-source.db");
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "vector-sql-converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();

        try source.exec(
            \\create table chunks (
            \\  id text primary key,
            \\  document_id text not null,
            \\  vector_id text
            \\);
        );
        try source.exec(
            \\insert into chunks (id, document_id, vector_id) values
            \\  ('one', 'doc', null),
            \\  ('two', 'doc', null);
        );
    }

    try convertSqliteToZova(source_path, dest_path);

    var db = try Database.open(dest_path);
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .dot });
    try db.putVector("chunks", "one-vector", &.{ 2.0, 0.0 });
    try db.putVector("chunks", "two-vector", &.{ 1.0, 0.0 });
    try db.exec("update chunks set vector_id = id || '-vector'");

    const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 1.0, 0.0 });
    defer std.testing.allocator.free(query_blob);

    var stmt = try db.prepare(
        \\select c.id, s.distance
        \\from zova_vector_search as s
        \\join chunks as c on c.vector_id = s.vector_id
        \\where s.collection = 'chunks'
        \\  and s.query_vector = ?
        \\  and s.top_k = 2
        \\order by s.rank
    );
    defer stmt.deinit();

    try stmt.bindBlob(1, query_blob);
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("one", stmt.columnText(0));
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), stmt.columnDouble(1), 0.000001);
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings("two", stmt.columnText(0));
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), stmt.columnDouble(1), 0.000001);
}

test "sql vector integration supports all metrics and threshold-only searches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "vector-sql-metrics.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.createVectorCollection("cosine", .{ .dimensions = 2, .metric = .cosine });
    try db.putVector("cosine", "east", &.{ 1.0, 0.0 });
    try db.putVector("cosine", "northeast", &.{ 1.0, 1.0 });
    try db.putVector("cosine", "north", &.{ 0.0, 1.0 });

    try db.createVectorCollection("dot", .{ .dimensions = 2, .metric = .dot });
    try db.putVector("dot", "strong", &.{ 3.0, 0.0 });
    try db.putVector("dot", "weak", &.{ 1.0, 0.0 });
    try db.putVector("dot", "negative", &.{ -1.0, 0.0 });

    try db.createVectorCollection("empty", .{ .dimensions = 2, .metric = .l2 });

    const east_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 1.0, 0.0 });
    defer std.testing.allocator.free(east_blob);

    {
        var stmt = try db.prepare(
            \\select
            \\  zova_vector_distance('cosine', 'east', ?),
            \\  zova_vector_distance_by_id('cosine', 'northeast', 'east'),
            \\  zova_vector_distance('dot', 'strong', ?),
            \\  zova_vector_distance_by_id('dot', 'weak', 'strong')
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, east_blob);
        try stmt.bindBlob(2, east_blob);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), stmt.columnDouble(0), 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 0.292893), stmt.columnDouble(1), 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, -3.0), stmt.columnDouble(2), 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, -3.0), stmt.columnDouble(3), 0.000001);
    }

    {
        var stmt = try db.prepare(
            \\select vector_id
            \\from zova_vector_search
            \\where collection = 'dot'
            \\  and query_vector = ?
            \\  and max_distance = -1.0
            \\order by rank
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, east_blob);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("strong", stmt.columnText(0));
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("weak", stmt.columnText(0));
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    {
        var stmt = try db.prepare(
            \\select vector_id
            \\from zova_vector_search
            \\where collection = 'dot'
            \\  and query_vector = ?
            \\  and top_k = 1
            \\  and max_distance = -1.0
            \\order by rank
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, east_blob);
        try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
        try std.testing.expectEqualStrings("strong", stmt.columnText(0));
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    {
        var stmt = try db.prepare(
            \\select vector_id
            \\from zova_vector_search
            \\where collection = 'empty'
            \\  and query_vector = ?
            \\  and top_k = 10
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, east_blob);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    try expectSqlPrepareOrStepError(&db, "select zova_vector_distance('missing', 'id', x'0000803f00000000')");
    try expectSqlPrepareOrStepError(&db, "select zova_vector_distance('dot', 'missing', x'0000803f00000000')");
    try expectSqlPrepareOrStepError(&db, "select zova_vector_distance_by_id('dot', 'weak', 'missing')");
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
