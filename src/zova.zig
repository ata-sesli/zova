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

/// Options for opening an existing `.zova` database.
pub const OpenOptions = struct {
    /// Open the SQLite handle read-only. Read APIs and SQL queries work, while
    /// SQLite-backed writes return `error.ReadOnly`.
    read_only: bool = false,
    /// Initial SQLite busy timeout in milliseconds. A value of 0 leaves
    /// SQLite's default busy handling unchanged.
    busy_timeout_ms: u32 = 0,
};

/// Options for `Database.backupTo`.
pub const BackupOptions = struct {
    /// Open and validate the destination after copying.
    verify: bool = true,
};

/// Options for `Database.compactTo`.
pub const CompactOptions = struct {
    /// Open and validate the destination after compacting.
    verify: bool = true,
};

/// Options for `restoreBackup`.
pub const RestoreOptions = struct {
    /// Open and validate the restored destination after copying.
    verify: bool = true,
};

/// Convert an existing SQLite database file into a new `.zova` database.
///
/// The source is opened as plain SQLite and is never mutated. The destination
/// must use the `.zova` extension and must not already exist. Source schema
/// objects with `_zova_` names are rejected because that namespace is reserved
/// for Zova-owned metadata inside `.zova` files.
pub fn convertSqliteToZova(source_path: [:0]const u8, dest_path: [:0]const u8) Error!void {
    try reserveDestinationZovaFile(dest_path);
    errdefer deleteDestinationFile(dest_path);

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

/// Restore a backup `.zova` file into a new destination `.zova` file.
///
/// This uses SQLite's online backup API and never overwrites an existing
/// destination. The source must already be a valid current-format Zova file.
pub fn restoreBackup(source_path: [:0]const u8, dest_path: [:0]const u8, options: RestoreOptions) Error!void {
    if (!isZovaPath(source_path)) return error.NotZovaPath;

    var source = try Database.openWithOptions(source_path, .{ .read_only = true });
    defer source.deinit();

    try source.backupTo(dest_path, .{ .verify = options.verify });
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
        return openWithOptions(path, .{});
    }

    /// Open an existing initialized `.zova` database with explicit options.
    ///
    /// Read-only opens still validate Zova metadata and register connection-
    /// local SQL vector helpers, but they never write private schema or run
    /// migrations. Mutating SQL/object/vector APIs fail through SQLite's normal
    /// read-only error path.
    pub fn openWithOptions(path: [:0]const u8, options: OpenOptions) Error!Database {
        if (!isZovaPath(path)) return error.NotZovaPath;
        try ensurePathExists(path);

        const flags: sqlite.OpenFlags = if (options.read_only) .read_only else .read_write;
        var raw = try sqlite.Database.openWithFlags(path, flags);
        errdefer raw.deinit();

        if (options.busy_timeout_ms != 0) try raw.setBusyTimeout(options.busy_timeout_ms);
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

    /// Create a named SQLite savepoint on this Zova connection.
    ///
    /// Names use Zova's strict savepoint identifier rule: ASCII, 1-64 bytes,
    /// first byte `[A-Za-z_]`, remaining bytes `[A-Za-z0-9_]`, and no
    /// case-insensitive `_zova_` prefix.
    pub fn savepoint(self: *Database, name: []const u8) Error!void {
        try self.sqlite_db.savepoint(name);
    }

    /// Roll back changes made after a named SQLite savepoint.
    ///
    /// SQLite keeps the savepoint active after `ROLLBACK TO`; call
    /// `releaseSavepoint` when the checkpoint should be removed.
    pub fn rollbackToSavepoint(self: *Database, name: []const u8) Error!void {
        try self.sqlite_db.rollbackToSavepoint(name);
    }

    /// Release a named SQLite savepoint.
    pub fn releaseSavepoint(self: *Database, name: []const u8) Error!void {
        try self.sqlite_db.releaseSavepoint(name);
    }

    /// Run a callback inside a named SQLite savepoint.
    ///
    /// The savepoint is released when the callback succeeds. If the callback
    /// returns an error, Zova rolls back to the savepoint, releases it, and then
    /// returns the callback error unless cleanup itself fails.
    pub fn withSavepoint(
        self: *Database,
        name: []const u8,
        context: anytype,
        comptime callback: fn (@TypeOf(context)) Error!void,
    ) Error!void {
        try self.savepoint(name);
        callback(context) catch |callback_err| {
            self.rollbackToSavepoint(name) catch |cleanup_err| return cleanup_err;
            self.releaseSavepoint(name) catch |cleanup_err| return cleanup_err;
            return callback_err;
        };
        try self.releaseSavepoint(name);
    }

    /// Reclaim SQLite free pages with an explicit in-place `VACUUM`.
    ///
    /// Zova never runs `VACUUM` automatically after object or vector deletes.
    /// This method is a thin SQLite wrapper for applications that deliberately
    /// want SQLite to rebuild the database file and potentially shrink it.
    pub fn vacuum(self: *Database) Error!void {
        try self.exec("vacuum");
    }

    /// Copy this database to a new `.zova` destination with SQLite's online
    /// backup API.
    ///
    /// The destination must not already exist. When verification is enabled,
    /// Zova opens the copy, runs SQLite `quick_check`, and validates object,
    /// chunk, and vector rows through the public read paths.
    pub fn backupTo(self: *Database, destination_path: [:0]const u8, options: BackupOptions) Error!void {
        try reserveDestinationZovaFile(destination_path);
        errdefer deleteDestinationFile(destination_path);

        {
            var dest = try sqlite.Database.open(destination_path);
            defer dest.deinit();
            try backupMainDatabase(&self.sqlite_db, &dest);
        }

        if (options.verify) try verifyOperationalCopy(destination_path);
    }

    /// Write a compact copy to a new `.zova` destination using SQLite
    /// `VACUUM INTO`.
    ///
    /// This is the explicit space-reclaiming copy path. The source database is
    /// not replaced, and the destination must not already exist.
    pub fn compactTo(self: *Database, destination_path: [:0]const u8, options: CompactOptions) Error!void {
        try ensureDestinationZovaPathAvailable(destination_path);
        errdefer deleteDestinationFile(destination_path);

        var vacuum_stmt = try self.prepare("vacuum into ?");
        defer vacuum_stmt.deinit();

        try vacuum_stmt.bindText(1, destination_path);
        try expectDone(&vacuum_stmt);

        if (options.verify) try verifyOperationalCopy(destination_path);
    }

    /// Set SQLite's busy timeout in milliseconds for this connection.
    ///
    /// Passing 0 clears the busy handler.
    pub fn setBusyTimeout(self: *Database, milliseconds: u32) Error!void {
        try self.sqlite_db.setBusyTimeout(milliseconds);
    }

    /// Rowid from the most recent successful INSERT on this connection.
    pub fn lastInsertRowid(self: *Database) i64 {
        return self.sqlite_db.lastInsertRowId();
    }

    /// Number of rows modified by the most recent INSERT, UPDATE, or DELETE.
    pub fn changes(self: *Database) i64 {
        return self.sqlite_db.changes();
    }

    /// Total number of rows modified by INSERT, UPDATE, or DELETE on this connection.
    pub fn totalChanges(self: *Database) i64 {
        return self.sqlite_db.totalChanges();
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

fn ensureDestinationZovaPathAvailable(path: [:0]const u8) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;

    const io = defaultIo();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try ensureParentPathExists(io, path);
                return;
            },
            else => return error.CantOpen,
        };
        return error.DestinationExists;
    }

    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try ensureParentPathExists(io, path);
            return;
        },
        else => return error.CantOpen,
    };

    return error.DestinationExists;
}

fn ensureParentPathExists(io: std.Io, path: []const u8) Error!void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;

    if (std.fs.path.isAbsolute(parent)) {
        std.Io.Dir.accessAbsolute(io, parent, .{}) catch return error.CantOpen;
    } else {
        std.Io.Dir.cwd().access(io, parent, .{}) catch return error.CantOpen;
    }
}

fn reserveDestinationZovaFile(path: [:0]const u8) Error!void {
    try ensureDestinationZovaPathAvailable(path);

    const io = defaultIo();
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DestinationExists,
        else => return error.CantOpen,
    };
    file.close(io);
}

fn deleteDestinationFile(path: [:0]const u8) void {
    std.Io.Dir.cwd().deleteFile(defaultIo(), path) catch {};
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

fn expectDone(stmt: *sqlite.Statement) Error!void {
    switch (try stmt.step()) {
        .done => {},
        .row => return error.SqliteError,
    }
}

fn verifyOperationalCopy(path: [:0]const u8) Error!void {
    var db = try Database.openWithOptions(path, .{ .read_only = true });
    defer db.deinit();

    try verifyQuickCheck(&db);
    try verifyStoredObjects(&db);
    try verifyStoredChunks(&db);
    try verifyStoredVectors(&db);
}

fn verifyQuickCheck(db: *Database) Error!void {
    var stmt = try db.prepare("pragma quick_check");
    defer stmt.deinit();

    switch (try stmt.step()) {
        .done => return error.Corrupt,
        .row => {
            if (!std.mem.eql(u8, stmt.columnText(0), "ok")) return error.Corrupt;
        },
    }

    switch (try stmt.step()) {
        .done => {},
        .row => return error.Corrupt,
    }
}

fn verifyStoredObjects(db: *Database) Error!void {
    const allocator = std.heap.page_allocator;

    var objects = try db.prepare("select object_id from _zova_objects order by object_id");
    defer objects.deinit();

    while ((try objects.step()) == .row) {
        const blob = objects.columnBlob(0);
        if (blob.len != @sizeOf(ObjectId)) return error.ObjectCorrupt;

        var id: ObjectId = undefined;
        @memcpy(id[0..], blob);

        var object = try db.getObject(allocator, id);
        defer object.deinit(allocator);
    }
}

fn verifyStoredChunks(db: *Database) Error!void {
    const allocator = std.heap.page_allocator;

    var chunks = try db.prepare("select chunk_hash from _zova_chunks order by chunk_hash");
    defer chunks.deinit();

    while ((try chunks.step()) == .row) {
        const blob = chunks.columnBlob(0);
        if (blob.len != @sizeOf(ObjectChunkId)) return error.ObjectCorrupt;

        var hash: ObjectChunkId = undefined;
        @memcpy(hash[0..], blob);

        var chunk = try db.getObjectChunk(allocator, hash);
        defer chunk.deinit(allocator);
    }
}

fn verifyStoredVectors(db: *Database) Error!void {
    const allocator = std.heap.page_allocator;

    var vectors = try db.prepare(
        \\select collection_name, vector_id
        \\from _zova_vectors
        \\order by collection_name, vector_id
    );
    defer vectors.deinit();

    while ((try vectors.step()) == .row) {
        const collection_name = try allocator.dupe(u8, vectors.columnText(0));
        defer allocator.free(collection_name);

        const vector_id = try allocator.dupe(u8, vectors.columnText(1));
        defer allocator.free(vector_id);

        var vector = try db.getVector(allocator, collection_name, vector_id);
        defer vector.deinit(allocator);
    }
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

const test_support = @import("zova_test_support.zig");
const testingDbPath = test_support.testingDbPath;
const testingWriteMetadata = test_support.testingWriteMetadata;
const testingExpectTableCount = test_support.testingExpectTableCount;
const testingCount = test_support.testingCount;
const testingQuickCheckOk = test_support.testingQuickCheckOk;
const testingIntegrityCheckOk = test_support.testingIntegrityCheckOk;

const OperationalFixtureIds = struct {
    primary_object: ObjectId,
    streamed_object: ObjectId,
    loose_chunk: ObjectChunkId,
};

fn fillOperationalLargeFixture(bytes: []u8) void {
    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 31 + index / 7) % 251);
    }
}

fn populateOperationalFixture(
    db: *Database,
    primary_bytes: []const u8,
    streamed_bytes: []const u8,
    loose_bytes: []const u8,
) !OperationalFixtureIds {
    try db.exec(
        \\create table docs (
        \\  id integer primary key,
        \\  title text not null,
        \\  object_id blob,
        \\  vector_id text
        \\);
        \\create table doc_log (
        \\  doc_id integer not null,
        \\  title text not null
        \\);
        \\create index docs_title_idx on docs (title);
        \\create view doc_titles as select title from docs;
        \\create trigger docs_after_insert
        \\after insert on docs
        \\begin
        \\  insert into doc_log (doc_id, title) values (new.id, new.title);
        \\end;
    );

    const primary_object = try db.putObject(primary_bytes);
    const streamed_object = try test_support.testingStreamObject(db, streamed_bytes, &.{ 1, 17, 4096, 70_000 });

    var insert_doc = try db.prepare(
        \\insert into docs (title, object_id, vector_id)
        \\values (?, ?, ?)
    );
    defer insert_doc.deinit();

    try insert_doc.bindText(1, "primary");
    try insert_doc.bindBlob(2, &primary_object);
    try insert_doc.bindText(3, "doc-a");
    try std.testing.expectEqual(sqlite.Step.done, try insert_doc.step());

    try insert_doc.reset();
    try insert_doc.clearBindings();
    try insert_doc.bindText(1, "streamed");
    try insert_doc.bindBlob(2, &streamed_object);
    try insert_doc.bindText(3, "doc-b");
    try std.testing.expectEqual(sqlite.Step.done, try insert_doc.step());

    try db.createVectorCollection("docs", .{ .dimensions = 3, .metric = .l2 });
    try db.putVectors("docs", &.{
        .{ .id = "doc-a", .values = &.{ 1.0, 0.0, 0.0 } },
        .{ .id = "doc-b", .values = &.{ 0.0, 2.0, 0.0 } },
    });

    const loose_chunk = objectChunkId(loose_bytes);
    try db.putObjectChunk(loose_chunk, loose_bytes);

    return .{
        .primary_object = primary_object,
        .streamed_object = streamed_object,
        .loose_chunk = loose_chunk,
    };
}

fn expectOperationalFixture(
    path: [:0]const u8,
    ids: OperationalFixtureIds,
    primary_bytes: []const u8,
    streamed_bytes: []const u8,
    loose_bytes: []const u8,
) !void {
    var db = try Database.open(path);
    defer db.deinit();

    try testingQuickCheckOk(&db);
    try testingIntegrityCheckOk(&db);

    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from docs"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from doc_log"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(&db,
        \\select count(*)
        \\from sqlite_master
        \\where name in ('docs_title_idx', 'doc_titles', 'docs_after_insert')
    ));

    var view_rows = try db.prepare("select title from doc_titles order by title");
    defer view_rows.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try view_rows.step());
    try std.testing.expectEqualStrings("primary", view_rows.columnText(0));
    try std.testing.expectEqual(sqlite.Step.row, try view_rows.step());
    try std.testing.expectEqualStrings("streamed", view_rows.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try view_rows.step());

    var primary = try db.getObject(std.testing.allocator, ids.primary_object);
    defer primary.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, primary_bytes, primary.bytes);

    var streamed = try db.getObject(std.testing.allocator, ids.streamed_object);
    defer streamed.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, streamed_bytes, streamed.bytes);

    var range: [37]u8 = undefined;
    const range_len = try db.readObjectRange(ids.streamed_object, 11, &range);
    try std.testing.expectEqual(@as(usize, range.len), range_len);
    try std.testing.expectEqualSlices(u8, streamed_bytes[11 .. 11 + range.len], &range);

    var manifest = try db.objectManifest(std.testing.allocator, ids.streamed_object);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expect(manifest.chunks.len > 1);

    var loose = try db.getObjectChunk(std.testing.allocator, ids.loose_chunk);
    defer loose.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, loose_bytes, loose.bytes);

    var vector = try db.getVector(std.testing.allocator, "docs", "doc-a");
    defer vector.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("doc-a", vector.id);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0 }, vector.values);

    var results = try db.searchVectors(std.testing.allocator, "docs", &.{ 1.0, 0.0, 0.0 }, 2);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("doc-a", results.items[0].id);

    const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 1.0, 0.0, 0.0 });
    defer std.testing.allocator.free(query_blob);

    var distance = try db.prepare("select zova_vector_distance('docs', 'doc-a', ?)");
    defer distance.deinit();
    try distance.bindBlob(1, query_blob);
    try std.testing.expectEqual(sqlite.Step.row, try distance.step());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), distance.columnDouble(0), 0.000001);
    try std.testing.expectEqual(sqlite.Step.done, try distance.step());
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

test "backup compact and restore preserve zova records objects chunks and vectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "operations-source.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "operations-backup.zova");

    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "operations-compact.zova");

    var restored_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restored_path = try testingDbPath(&restored_buffer, tmp.sub_path[0..], "operations-restored.zova");

    var quoted_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const quoted_path = try testingDbPath(&quoted_buffer, tmp.sub_path[0..], "operations copy 'quoted'.zova");

    const primary_bytes = "primary object bytes\x00with nul";
    const loose_bytes = "verified loose operational chunk";

    const streamed_bytes = try std.testing.allocator.alloc(u8, 140_000);
    defer std.testing.allocator.free(streamed_bytes);
    fillOperationalLargeFixture(streamed_bytes);

    var ids: OperationalFixtureIds = undefined;
    {
        var db = try Database.create(source_path);
        defer db.deinit();

        ids = try populateOperationalFixture(&db, primary_bytes, streamed_bytes, loose_bytes);
        try db.backupTo(backup_path, .{});
        try db.compactTo(compact_path, .{});
        try db.backupTo(quoted_path, .{});
    }

    try restoreBackup(backup_path, restored_path, .{});

    try expectOperationalFixture(backup_path, ids, primary_bytes, streamed_bytes, loose_bytes);
    try expectOperationalFixture(compact_path, ids, primary_bytes, streamed_bytes, loose_bytes);
    try expectOperationalFixture(restored_path, ids, primary_bytes, streamed_bytes, loose_bytes);
    try expectOperationalFixture(quoted_path, ids, primary_bytes, streamed_bytes, loose_bytes);
}

test "savepoints roll back zova records objects and vectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "savepoints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec("create table notes (body text not null)");
    const readable_object = try db.putObject("readable inside savepoint");
    var pending_writer = try db.objectWriter(std.testing.allocator);
    defer pending_writer.deinit();
    try pending_writer.write("writer finish blocked inside savepoint");

    try db.exec("begin immediate");
    try db.exec("insert into notes (body) values ('outer')");

    try db.savepoint("sp_vectors");
    try db.exec("insert into notes (body) values ('rolled back')");
    var readable = try db.getObject(std.testing.allocator, readable_object);
    defer readable.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "readable inside savepoint", readable.bytes);
    var range_buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try db.readObjectRange(readable_object, 0, &range_buffer));
    try std.testing.expectEqualSlices(u8, "readable", &range_buffer);
    try std.testing.expectError(error.ObjectTransactionActive, db.putObject("savepoint object"));
    try std.testing.expectError(error.ObjectTransactionActive, db.deleteObject(readable_object));
    try std.testing.expectError(error.ObjectTransactionActive, pending_writer.finish());
    try db.createVectorCollection("save_vectors", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("save_vectors", "v1", &.{ 1.0, 2.0 });
    try db.rollbackToSavepoint("sp_vectors");
    try db.releaseSavepoint("sp_vectors");

    try std.testing.expect(!try db.hasVectorCollection("save_vectors"));

    try db.savepoint("sp_release");
    try db.exec("insert into notes (body) values ('kept')");
    try db.createVectorCollection("kept_vectors", .{ .dimensions = 2, .metric = .l2 });
    try db.releaseSavepoint("sp_release");
    try db.exec("commit");

    try pending_writer.cancel();
    const kept_object = try db.putObject("kept savepoint object");
    try std.testing.expect(try db.hasObject(kept_object));
    try std.testing.expect(try db.hasVectorCollection("kept_vectors"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from notes"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from notes where body = 'rolled back'"));
    try testingQuickCheckOk(&db);
}

test "scoped savepoint helper releases rolls back nests and reports cleanup failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "scoped-savepoints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec("create table notes (body text not null)");
    try db.exec("begin immediate");

    const Ctx = struct {
        db: *Database,
        invoked: *bool,

        fn insertKept(self: *@This()) Error!void {
            self.invoked.* = true;
            try self.db.exec("insert into notes (body) values ('kept scoped')");
        }

        fn insertThenFail(self: *@This()) Error!void {
            self.invoked.* = true;
            try self.db.exec("insert into notes (body) values ('rolled back scoped')");
            return error.InvalidArgument;
        }

        fn insertInner(self: *@This()) Error!void {
            try self.db.exec("insert into notes (body) values ('inner rolled back')");
        }

        fn nestedThenFail(self: *@This()) Error!void {
            self.invoked.* = true;
            try self.db.exec("insert into notes (body) values ('outer rolled back')");
            try self.db.withSavepoint("sp_inner", self, @This().insertInner);
            return error.InvalidArgument;
        }

        fn releaseManually(self: *@This()) Error!void {
            self.invoked.* = true;
            try self.db.exec("insert into notes (body) values ('manual release kept')");
            try self.db.releaseSavepoint("sp_manual");
        }
    };

    var invoked = false;
    var ctx = Ctx{ .db = &db, .invoked = &invoked };

    try db.withSavepoint("sp_keep", &ctx, Ctx.insertKept);
    try std.testing.expect(invoked);

    invoked = false;
    try std.testing.expectError(error.InvalidArgument, db.withSavepoint("sp_fail", &ctx, Ctx.insertThenFail));
    try std.testing.expect(invoked);

    invoked = false;
    try std.testing.expectError(error.InvalidArgument, db.withSavepoint("sp_outer", &ctx, Ctx.nestedThenFail));
    try std.testing.expect(invoked);

    invoked = false;
    try std.testing.expectError(error.InvalidArgument, db.withSavepoint("bad name", &ctx, Ctx.insertKept));
    try std.testing.expect(!invoked);

    invoked = false;
    try std.testing.expectError(error.SqliteError, db.withSavepoint("sp_manual", &ctx, Ctx.releaseManually));
    try std.testing.expect(invoked);

    try db.exec("commit");
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from notes"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes where body = 'kept scoped'"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes where body = 'manual release kept'"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from notes where body like '%rolled back%'"));
}

test "operational copy APIs reject invalid and existing destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "operations-reject-source.zova");

    var invalid_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_dest_path = try testingDbPath(&invalid_dest_buffer, tmp.sub_path[0..], "operations-reject.db");

    var existing_backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_backup_path = try testingDbPath(&existing_backup_buffer, tmp.sub_path[0..], "operations-existing-backup.zova");

    var existing_compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_compact_path = try testingDbPath(&existing_compact_buffer, tmp.sub_path[0..], "operations-existing-compact.zova");

    var existing_restore_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_restore_path = try testingDbPath(&existing_restore_buffer, tmp.sub_path[0..], "operations-existing-restore.zova");

    var missing_parent_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_parent_path = try std.fmt.bufPrintZ(&missing_parent_buffer, ".zig-cache/tmp/{s}/missing-parent/operations.zova", .{tmp.sub_path[0..]});

    {
        var db = try Database.create(source_path);
        defer db.deinit();
        _ = try db.putObject("copy me");

        try std.testing.expectError(error.NotZovaPath, db.backupTo(invalid_dest_path, .{}));
        try std.testing.expectError(error.NotZovaPath, db.compactTo(invalid_dest_path, .{}));
    }

    {
        var dest = try Database.create(existing_backup_path);
        defer dest.deinit();
    }
    {
        var dest = try Database.create(existing_compact_path);
        defer dest.deinit();
    }
    {
        var dest = try Database.create(existing_restore_path);
        defer dest.deinit();
    }

    var db = try Database.open(source_path);
    defer db.deinit();

    try std.testing.expectError(error.DestinationExists, db.backupTo(existing_backup_path, .{}));
    try std.testing.expectError(error.DestinationExists, db.compactTo(existing_compact_path, .{}));
    try std.testing.expectError(error.DestinationExists, restoreBackup(source_path, existing_restore_path, .{}));
    try std.testing.expectError(error.CantOpen, db.backupTo(missing_parent_path, .{}));
    try std.testing.expectError(error.NotZovaPath, restoreBackup(invalid_dest_path, existing_restore_path, .{}));
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
