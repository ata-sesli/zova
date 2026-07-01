//! Zova-owned database identity layer.
//!
//! This module is the first layer above the plain SQLite wrapper. A database
//! enters Zova mode by using a `.zova` file path through `zova.Database`.
//! The file is still a SQLite database underneath, but Zova validates private
//! metadata before treating it as a Zova-owned database.
//!
//! Zova is currently pre-1.0, and internal `.zova` format compatibility is
//! not preserved between experimental format versions. The current v0.20
//! development format is version `4`: `_zova_meta.format_version = '4'` plus
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
const graph_impl = @import("graph.zig");
const graph_sql = @import("graph_sql.zig");
const notify_impl = @import("notify.zig");
const object_impl = @import("object.zig");
const sqlite = @import("sqlite.zig");
const vector_impl = @import("vector.zig");
const vector_sql = @import("vector_sql.zig");
const zova_error = @import("zova_error.zig");

const metadata_table = "_zova_meta";
const objects_table = "_zova_objects";
const chunks_table = "_zova_chunks";
const object_chunks_table = "_zova_object_chunks";
const bound_stores_table = "_zova_bound_stores";
const magic_value = "zova";
const format_version = "4";
const bound_object_store_role = "object_store";
const bound_vector_store_role = "vector_store";
const bound_object_store_name = "default";
const bound_vector_store_name = "default";
const bound_object_store_schema_name = "object_store";
const bound_vector_store_schema_name = "vector_store";
const bound_stores_schema_sql =
    \\create table _zova_bound_stores (
    \\  role text not null check (role in ('object_store', 'vector_store')),
    \\  name text not null check (name = 'default'),
    \\  path text not null,
    \\  store_id text not null check (length(store_id) = 64),
    \\  bound_set_id text not null check (length(bound_set_id) = 64),
    \\  object_epoch integer check (object_epoch is null or object_epoch >= 0),
    \\  vector_epoch integer check (vector_epoch is null or vector_epoch >= 0),
    \\  created_at_unix integer not null,
    \\  primary key (role, name)
    \\)
;
pub const ObjectId = object_impl.ObjectId;
pub const ObjectChunkId = object_impl.ObjectChunkId;
pub const ObjectChunk = object_impl.ObjectChunk;
pub const ObjectManifest = object_impl.ObjectManifest;
pub const ObjectChunkData = object_impl.ObjectChunkData;
pub const Object = object_impl.Object;

pub const ObjectWriter = struct {
    inner: object_impl.ObjectWriter,
    sqlite_db: *sqlite.Database,
    bound: bool,

    pub fn write(self: *ObjectWriter, bytes: []const u8) Error!void {
        return self.inner.write(bytes);
    }

    pub fn finish(self: *ObjectWriter) Error!ObjectId {
        if (!self.bound) return self.inner.finish();

        const owns_transaction = !hasActiveTransaction(self.sqlite_db);
        var committed = false;
        if (owns_transaction) try self.sqlite_db.beginImmediate();
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        const id = try self.inner.finish();
        try incrementBoundObjectEpoch(self.sqlite_db);

        if (owns_transaction) try self.sqlite_db.commit();
        committed = true;
        return id;
    }

    pub fn cancel(self: *ObjectWriter) Error!void {
        return self.inner.cancel();
    }

    pub fn deinit(self: *ObjectWriter) void {
        self.inner.deinit();
    }
};

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
pub const Notification = notify_impl.Notification;
pub const NotificationSubscription = notify_impl.NotificationSubscription;
pub const GraphTargetType = graph_impl.GraphTargetType;
pub const GraphInfo = graph_impl.GraphInfo;
pub const GraphList = graph_impl.GraphList;
pub const GraphNodeInput = graph_impl.GraphNodeInput;
pub const GraphNode = graph_impl.GraphNode;
pub const GraphEdgeInput = graph_impl.GraphEdgeInput;
pub const GraphEdge = graph_impl.GraphEdge;
pub const GraphNeighborDirection = graph_impl.GraphNeighborDirection;
pub const GraphNeighborsOptions = graph_impl.GraphNeighborsOptions;
pub const GraphNeighbor = graph_impl.GraphNeighbor;
pub const GraphNeighborList = graph_impl.GraphNeighborList;
pub const GraphWalkOptions = graph_impl.GraphWalkOptions;
pub const GraphWalkItem = graph_impl.GraphWalkItem;
pub const GraphWalk = graph_impl.GraphWalk;

/// Information about the optional object store bound to a main `.zova` file.
///
/// Single-file Zova remains the default. This struct is returned only when a
/// main database has explicitly been bound to one external object store.
pub const BoundObjectStoreInfo = struct {
    path: []u8,
    store_id: []u8,
    bound_set_id: []u8,
    object_epoch: u64,

    /// Free owned strings returned by `Database.boundObjectStore`.
    pub fn deinit(self: *BoundObjectStoreInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.store_id);
        allocator.free(self.bound_set_id);
    }
};

const BoundObjectStore = struct {};

pub const SplitObjectStoreCounts = struct {
    objects: u64 = 0,
    chunks: u64 = 0,
    manifest_rows: u64 = 0,
};

pub const SplitObjectStoreResult = struct {
    role: []const u8 = bound_object_store_role,
    store_path: []const u8,
    store_id: [64]u8,
    bound_set_id: [64]u8,
    copied: SplitObjectStoreCounts,
    cleared: SplitObjectStoreCounts,
    verified: bool,
};

/// Information about the optional vector store bound to a main `.zova` file.
///
/// Single-file Zova remains the default. This struct is returned only when a
/// main database has explicitly been bound to one external vector store.
pub const BoundVectorStoreInfo = struct {
    path: []u8,
    store_id: []u8,
    bound_set_id: []u8,
    vector_epoch: u64,

    /// Free owned strings returned by `Database.boundVectorStore`.
    pub fn deinit(self: *BoundVectorStoreInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.store_id);
        allocator.free(self.bound_set_id);
    }
};

const BoundVectorStore = struct {};

pub const SplitVectorStoreCounts = struct {
    vector_collections: u64 = 0,
    vectors: u64 = 0,
};

pub const SplitVectorStoreResult = struct {
    role: []const u8 = bound_vector_store_role,
    store_path: []const u8,
    store_id: [64]u8,
    bound_set_id: [64]u8,
    copied: SplitVectorStoreCounts,
    cleared: SplitVectorStoreCounts,
    verified: bool,
};

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

/// Create a standalone object-store `.zova` file.
///
/// This is opt-in storage for a main database that later calls
/// `Database.bindObjectStore`. Normal `.zova` files remain single-file by
/// default, and object-store files are rejected by `Database.open` as main
/// databases.
pub fn createObjectStore(path: [:0]const u8) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;

    const io = defaultIo();
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DestinationExists,
        else => return error.CantOpen,
    };
    file.close(io);

    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var raw = try sqlite.Database.open(path);
    defer raw.deinit();

    try initializeZovaSchema(&raw);
    try markAsObjectStore(&raw);
}

/// Create a standalone vector-store `.zova` file.
///
/// This is opt-in storage for a main database that later calls
/// `Database.bindVectorStore`. Normal `.zova` files remain single-file by
/// default, and vector-store files are rejected by `Database.open` as main
/// databases.
pub fn createVectorStore(path: [:0]const u8) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;

    const io = defaultIo();
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DestinationExists,
        else => return error.CantOpen,
    };
    file.close(io);

    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var raw = try sqlite.Database.open(path);
    defer raw.deinit();

    try initializeZovaSchema(&raw);
    try markAsVectorStore(&raw);
}

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

fn initNotifications(db: *sqlite.Database) Error!*notify_impl.Hub {
    const allocator = std.heap.c_allocator;
    const hub = allocator.create(notify_impl.Hub) catch return error.OutOfMemory;
    hub.* = notify_impl.Hub.init(allocator);
    errdefer allocator.destroy(hub);
    try notify_impl.registerSql(db, hub);
    return hub;
}

fn deinitNotifications(hub: *notify_impl.Hub) void {
    const allocator = std.heap.c_allocator;
    hub.deinit();
    allocator.destroy(hub);
}

/// Owns one initialized `.zova` database.
///
/// A Zova database is physically SQLite, but it must use the `.zova` extension
/// and contain valid `_zova_meta` metadata before `open` accepts it. The
/// wrapped SQLite connection is kept public for now as a low-level escape hatch
/// consistent with the v0 SQLite wrapper.
pub const Database = struct {
    sqlite_db: sqlite.Database,
    notifications: *notify_impl.Hub,
    bound_object_store: ?BoundObjectStore = null,
    bound_vector_store: ?BoundVectorStore = null,

    /// Create a new initialized `.zova` database.
    ///
    /// This never overwrites an existing file. The file is initialized with the
    /// private `_zova_meta` table, format version `4`, and the required
    /// object, vector, and graph schemas.
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
        try graph_sql.register(&raw);
        const notifications = try initNotifications(&raw);
        errdefer deinitNotifications(notifications);
        return .{ .sqlite_db = raw, .notifications = notifications };
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
    /// local SQL vector and graph helpers, but they never write private schema
    /// or run migrations. Mutating SQL/object/vector/graph APIs fail through
    /// SQLite's normal read-only error path.
    pub fn openWithOptions(path: [:0]const u8, options: OpenOptions) Error!Database {
        return openInternal(path, options, true);
    }

    /// Open only the main `.zova` file for bound-store binding management.
    ///
    /// This is for repairing or replacing binding metadata when the configured
    /// store path is no longer available. Object/vector APIs on the returned
    /// handle use the main file only; normal application code should use `open`
    /// or `openWithOptions`.
    pub fn openForObjectStoreManagement(path: [:0]const u8, options: OpenOptions) Error!Database {
        return openInternal(path, options, false);
    }

    fn openInternal(path: [:0]const u8, options: OpenOptions, load_bound_stores: bool) Error!Database {
        if (!isZovaPath(path)) return error.NotZovaPath;
        try ensurePathExists(path);

        const flags: sqlite.OpenFlags = if (options.read_only) .read_only else .read_write;
        var raw = try sqlite.Database.openWithFlags(path, flags);
        errdefer raw.deinit();

        if (options.busy_timeout_ms != 0) try raw.setBusyTimeout(options.busy_timeout_ms);
        try validateZovaSchema(&raw);
        const bound_object_store = if (load_bound_stores)
            try openConfiguredBoundObjectStore(&raw, options)
        else
            null;
        errdefer if (bound_object_store != null) raw.detachDatabase(bound_object_store_schema_name) catch {};
        const bound_vector_store = if (load_bound_stores)
            try openConfiguredBoundVectorStore(&raw, options)
        else
            null;
        errdefer if (bound_vector_store != null) raw.detachDatabase(bound_vector_store_schema_name) catch {};
        try vector_sql.register(&raw);
        try graph_sql.register(&raw);
        const notifications = try initNotifications(&raw);
        errdefer deinitNotifications(notifications);
        return .{
            .sqlite_db = raw,
            .notifications = notifications,
            .bound_object_store = bound_object_store,
            .bound_vector_store = bound_vector_store,
        };
    }

    /// Close the underlying SQLite connection.
    pub fn deinit(self: *Database) void {
        self.sqlite_db.deinit();
        deinitNotifications(self.notifications);
    }

    /// Execute SQL against the underlying SQLite database.
    pub fn exec(self: *Database, sql: [:0]const u8) Error!void {
        try self.sqlite_db.exec(sql);
    }

    /// Prepare SQL against the underlying SQLite database.
    pub fn prepare(self: *Database, sql: [:0]const u8) Error!sqlite.Statement {
        return try self.sqlite_db.prepare(sql);
    }

    /// Start a deferred SQLite transaction and notification delivery scope.
    pub fn begin(self: *Database) Error!void {
        try self.sqlite_db.begin();
        self.notifications.begin() catch |err| {
            self.sqlite_db.rollback() catch {};
            return err;
        };
    }

    /// Start an immediate SQLite transaction and notification delivery scope.
    pub fn beginImmediate(self: *Database) Error!void {
        try self.sqlite_db.beginImmediate();
        self.notifications.begin() catch |err| {
            self.sqlite_db.rollback() catch {};
            return err;
        };
    }

    /// Commit the active transaction, then deliver pending notifications.
    pub fn commit(self: *Database) Error!void {
        try self.sqlite_db.commit();
        self.notifications.commit();
    }

    /// Roll back the active transaction and discard pending notifications.
    pub fn rollback(self: *Database) Error!void {
        try self.sqlite_db.rollback();
        self.notifications.rollback();
    }

    /// Create a named SQLite savepoint on this Zova connection.
    ///
    /// Names use Zova's strict savepoint identifier rule: ASCII, 1-64 bytes,
    /// first byte `[A-Za-z_]`, remaining bytes `[A-Za-z0-9_]`, and no
    /// case-insensitive `_zova_` prefix.
    pub fn savepoint(self: *Database, name: []const u8) Error!void {
        try self.sqlite_db.savepoint(name);
        self.notifications.savepoint(name) catch |err| {
            self.sqlite_db.releaseSavepoint(name) catch {};
            return err;
        };
    }

    /// Roll back changes made after a named SQLite savepoint.
    ///
    /// SQLite keeps the savepoint active after `ROLLBACK TO`; call
    /// `releaseSavepoint` when the checkpoint should be removed.
    pub fn rollbackToSavepoint(self: *Database, name: []const u8) Error!void {
        try self.sqlite_db.rollbackToSavepoint(name);
        self.notifications.rollbackToSavepoint(name);
    }

    /// Release a named SQLite savepoint.
    pub fn releaseSavepoint(self: *Database, name: []const u8) Error!void {
        try self.notifications.prepareReleaseSavepoint(name);
        try self.sqlite_db.releaseSavepoint(name);
        self.notifications.releaseSavepoint(name);
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

    /// Subscribe to explicit same-handle app notifications on `channel`.
    pub fn listen(self: *Database, channel: []const u8) Error!NotificationSubscription {
        return try self.notifications.listen(channel);
    }

    /// Queue an explicit same-handle app notification.
    ///
    /// Outside a Zova transaction helper this is immediately receiveable.
    /// Inside `begin`/`beginImmediate` and savepoints, delivery follows commit,
    /// rollback, and savepoint release semantics.
    pub fn notify(self: *Database, channel: []const u8, payload: []const u8) Error!void {
        try self.notifications.notify(channel, payload);
    }

    /// Create a named graph for application-provided relationship nodes.
    pub fn createGraph(self: *Database, name: []const u8) Error!void {
        var graphs = self.graphDatabase();
        try graphs.createGraph(name);
    }

    /// Delete a graph and all of its Zova-owned graph nodes and edges.
    pub fn deleteGraph(self: *Database, name: []const u8) Error!void {
        var graphs = self.graphDatabase();
        try graphs.deleteGraph(name);
    }

    /// Return whether a graph exists.
    pub fn hasGraph(self: *Database, name: []const u8) Error!bool {
        var graphs = self.graphDatabase();
        return try graphs.hasGraph(name);
    }

    /// Return owned metadata for one graph.
    pub fn graphInfo(self: *Database, allocator: std.mem.Allocator, name: []const u8) Error!GraphInfo {
        var graphs = self.graphDatabase();
        return try graphs.graphInfo(allocator, name);
    }

    /// List graphs sorted by ascending name.
    pub fn listGraphs(self: *Database, allocator: std.mem.Allocator) Error!GraphList {
        var graphs = self.graphDatabase();
        return try graphs.listGraphs(allocator);
    }

    /// Create or update a graph node.
    pub fn putGraphNode(self: *Database, input: GraphNodeInput) Error!void {
        var graphs = self.graphDatabase();
        try graphs.putGraphNode(input);
    }

    /// Return an owned graph node.
    pub fn getGraphNode(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, node_id: []const u8) Error!GraphNode {
        var graphs = self.graphDatabase();
        return try graphs.getGraphNode(allocator, graph_name, node_id);
    }

    /// Return whether a graph node exists.
    pub fn hasGraphNode(self: *Database, graph_name: []const u8, node_id: []const u8) Error!bool {
        var graphs = self.graphDatabase();
        return try graphs.hasGraphNode(graph_name, node_id);
    }

    /// Delete a graph node and its incident graph edges only.
    pub fn deleteGraphNode(self: *Database, graph_name: []const u8, node_id: []const u8) Error!void {
        var graphs = self.graphDatabase();
        try graphs.deleteGraphNode(graph_name, node_id);
    }

    /// Create an explicit directed graph edge.
    pub fn putGraphEdge(self: *Database, input: GraphEdgeInput) Error!void {
        var graphs = self.graphDatabase();
        try graphs.putGraphEdge(input);
    }

    /// Return whether an explicit graph edge exists.
    pub fn hasGraphEdge(self: *Database, graph_name: []const u8, from_node_id: []const u8, edge_type: []const u8, to_node_id: []const u8) Error!bool {
        var graphs = self.graphDatabase();
        return try graphs.hasGraphEdge(graph_name, from_node_id, edge_type, to_node_id);
    }

    /// Return an owned explicit graph edge.
    pub fn getGraphEdge(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, from_node_id: []const u8, edge_type: []const u8, to_node_id: []const u8) Error!GraphEdge {
        var graphs = self.graphDatabase();
        return try graphs.getGraphEdge(allocator, graph_name, from_node_id, edge_type, to_node_id);
    }

    /// Delete an explicit graph edge.
    pub fn deleteGraphEdge(self: *Database, input: GraphEdgeInput) Error!void {
        var graphs = self.graphDatabase();
        try graphs.deleteGraphEdge(input);
    }

    /// Return bounded incoming or outgoing graph neighbors.
    pub fn graphNeighbors(self: *Database, allocator: std.mem.Allocator, options: GraphNeighborsOptions) Error!GraphNeighborList {
        var graphs = self.graphDatabase();
        return try graphs.graphNeighbors(allocator, options);
    }

    /// Return a bounded directed walk from one graph node.
    pub fn graphWalk(self: *Database, allocator: std.mem.Allocator, options: GraphWalkOptions) Error!GraphWalk {
        var graphs = self.graphDatabase();
        return try graphs.graphWalk(allocator, options);
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

        try self.inlineBoundStoresIntoDestination(destination_path);
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

        try self.inlineBoundStoresIntoDestination(destination_path);
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

    /// Set this main database's optional external object-store binding.
    ///
    /// Single-file object storage remains the default until this method is
    /// called. If a binding already exists, this safely replaces it after the
    /// new store has been attached and validated.
    pub fn bindObjectStore(self: *Database, path: [:0]const u8) Error!void {
        try self.rejectBoundStoreManagementInsideMainTransaction();
        try ensureMainDatabaseRole(&self.sqlite_db);
        try ensureBoundStoreTable(&self.sqlite_db);
        if (sqlite.c.sqlite3_db_readonly(self.sqlite_db.handle, "main") == 1) return error.ReadOnly;

        const stored_path = try std.heap.c_allocator.dupeZ(u8, path);
        defer std.heap.c_allocator.free(stored_path);

        const had_binding = try hasBoundObjectStoreRow(&self.sqlite_db);
        if (!had_binding and try mainObjectStorageHasRows(&self.sqlite_db)) return error.BoundStoreExists;

        const had_attached_store = self.bound_object_store != null;
        var detached_old = false;
        if (had_binding and had_attached_store) {
            try self.sqlite_db.detachDatabase(bound_object_store_schema_name);
            self.bound_object_store = null;
            detached_old = true;
        }

        errdefer if (detached_old) {
            self.restoreConfiguredBoundObjectStore() catch {};
        };

        try attachObjectStore(&self.sqlite_db, stored_path, false);
        errdefer self.sqlite_db.detachDatabase(bound_object_store_schema_name) catch {};

        const store_id = try validateAttachedObjectStoreAlloc(std.heap.c_allocator, &self.sqlite_db, bound_object_store_schema_name);
        defer std.heap.c_allocator.free(store_id);

        var bound_set_id: [64]u8 = undefined;
        randomHex64(&bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_object_store_schema_name, "bound_set_id", &bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_object_store_schema_name, "object_epoch", "0");

        if (had_binding) {
            try updateBoundObjectStoreRow(&self.sqlite_db, stored_path, store_id, &bound_set_id);
        } else {
            try insertBoundObjectStoreRow(&self.sqlite_db, stored_path, store_id, &bound_set_id);
        }

        self.bound_object_store = .{};
    }

    /// Move existing single-file object storage into a new bound object store.
    ///
    /// User SQL tables remain in the main database. The destination must not
    /// already exist, and the main database must not already have an object
    /// store binding.
    pub fn splitObjectStore(self: *Database, store_path: [:0]const u8) Error!SplitObjectStoreResult {
        try self.rejectBoundStoreManagementInsideMainTransaction();
        try ensureMainDatabaseRole(&self.sqlite_db);
        try ensureBoundStoreTable(&self.sqlite_db);
        if (sqlite.c.sqlite3_db_readonly(self.sqlite_db.handle, "main") == 1) return error.ReadOnly;
        if (try hasBoundObjectStoreRow(&self.sqlite_db)) return error.BoundStoreExists;

        const copied_counts = try objectStorageCounts(&self.sqlite_db, .main);

        try createObjectStore(store_path);
        errdefer deleteDestinationFile(store_path);

        try attachObjectStore(&self.sqlite_db, store_path, false);
        errdefer self.sqlite_db.detachDatabase(bound_object_store_schema_name) catch {};

        try self.sqlite_db.beginImmediate();
        var committed = false;
        errdefer if (!committed) self.sqlite_db.rollback() catch {};

        const store_id_alloc = try validateAttachedObjectStoreAlloc(std.heap.c_allocator, &self.sqlite_db, bound_object_store_schema_name);
        defer std.heap.c_allocator.free(store_id_alloc);
        const store_id = try copyStoreId(store_id_alloc);

        var bound_set_id: [64]u8 = undefined;
        randomHex64(&bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_object_store_schema_name, "bound_set_id", &bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_object_store_schema_name, "object_epoch", "0");
        try insertBoundObjectStoreRow(&self.sqlite_db, store_path, store_id_alloc, &bound_set_id);

        self.bound_object_store = .{};
        errdefer self.bound_object_store = null;

        try copyObjectStorage(&self.sqlite_db, .main, &self.sqlite_db, .object_store);
        try clearMainObjectStorage(&self.sqlite_db);

        try verifyCurrentDatabase(self);
        try self.sqlite_db.commit();
        committed = true;

        return .{
            .store_path = store_path,
            .store_id = store_id,
            .bound_set_id = bound_set_id,
            .copied = copied_counts,
            .cleared = copied_counts,
            .verified = true,
        };
    }

    /// Return information about the optional bound object store, if present.
    pub fn boundObjectStore(self: *Database, allocator: std.mem.Allocator) Error!?BoundObjectStoreInfo {
        return try loadBoundObjectStoreInfo(allocator, &self.sqlite_db);
    }

    /// Remove the optional object-store binding from this main database.
    ///
    /// This never deletes or mutates the object store file itself.
    pub fn unbindObjectStore(self: *Database) Error!void {
        try self.rejectBoundStoreManagementInsideMainTransaction();
        if (!try hasBoundObjectStoreRow(&self.sqlite_db)) return error.BoundStoreNotFound;

        const had_attached_store = self.bound_object_store != null;
        try self.detachBoundObjectStore();
        var deleted = false;
        errdefer if (had_attached_store and !deleted) {
            self.restoreConfiguredBoundObjectStore() catch {};
        };

        var stmt = try self.sqlite_db.prepare(
            \\delete from _zova_bound_stores
            \\where role = 'object_store' and name = 'default'
        );
        defer stmt.deinit();
        std.debug.assert((try stmt.step()) == .done);
        deleted = true;
    }

    /// Set this main database's optional external vector-store binding.
    ///
    /// Single-file vector storage remains the default until this method is
    /// called. If a binding already exists, this safely replaces it after the
    /// new store has been attached and validated.
    pub fn bindVectorStore(self: *Database, path: [:0]const u8) Error!void {
        try self.rejectBoundStoreManagementInsideMainTransaction();
        try ensureMainDatabaseRole(&self.sqlite_db);
        try ensureBoundStoreTable(&self.sqlite_db);
        if (sqlite.c.sqlite3_db_readonly(self.sqlite_db.handle, "main") == 1) return error.ReadOnly;

        const stored_path = try std.heap.c_allocator.dupeZ(u8, path);
        defer std.heap.c_allocator.free(stored_path);

        const had_binding = try hasBoundVectorStoreRow(&self.sqlite_db);
        if (!had_binding and try mainVectorStorageHasRows(&self.sqlite_db)) return error.BoundStoreExists;

        const had_attached_store = self.bound_vector_store != null;
        var detached_old = false;
        if (had_binding and had_attached_store) {
            try self.sqlite_db.detachDatabase(bound_vector_store_schema_name);
            self.bound_vector_store = null;
            detached_old = true;
        }

        errdefer if (detached_old) {
            self.restoreConfiguredBoundVectorStore() catch {};
        };

        try attachVectorStore(&self.sqlite_db, stored_path, false);
        errdefer self.sqlite_db.detachDatabase(bound_vector_store_schema_name) catch {};

        const store_id = try validateAttachedVectorStoreAlloc(std.heap.c_allocator, &self.sqlite_db, bound_vector_store_schema_name);
        defer std.heap.c_allocator.free(store_id);

        var bound_set_id: [64]u8 = undefined;
        randomHex64(&bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_vector_store_schema_name, "bound_set_id", &bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_vector_store_schema_name, "vector_epoch", "0");

        if (had_binding) {
            try updateBoundVectorStoreRow(&self.sqlite_db, stored_path, store_id, &bound_set_id);
        } else {
            try insertBoundVectorStoreRow(&self.sqlite_db, stored_path, store_id, &bound_set_id);
        }

        self.bound_vector_store = .{};
    }

    /// Move existing single-file vector storage into a new bound vector store.
    ///
    /// User SQL tables remain in the main database. The destination must not
    /// already exist, and the main database must not already have a vector
    /// store binding.
    pub fn splitVectorStore(self: *Database, store_path: [:0]const u8) Error!SplitVectorStoreResult {
        try self.rejectBoundStoreManagementInsideMainTransaction();
        try ensureMainDatabaseRole(&self.sqlite_db);
        try ensureBoundStoreTable(&self.sqlite_db);
        if (sqlite.c.sqlite3_db_readonly(self.sqlite_db.handle, "main") == 1) return error.ReadOnly;
        if (try hasBoundVectorStoreRow(&self.sqlite_db)) return error.BoundStoreExists;

        const copied_counts = try vectorStorageCounts(&self.sqlite_db, .main);

        try createVectorStore(store_path);
        errdefer deleteDestinationFile(store_path);

        try attachVectorStore(&self.sqlite_db, store_path, false);
        errdefer self.sqlite_db.detachDatabase(bound_vector_store_schema_name) catch {};

        try self.sqlite_db.beginImmediate();
        var committed = false;
        errdefer if (!committed) self.sqlite_db.rollback() catch {};

        const store_id_alloc = try validateAttachedVectorStoreAlloc(std.heap.c_allocator, &self.sqlite_db, bound_vector_store_schema_name);
        defer std.heap.c_allocator.free(store_id_alloc);
        const store_id = try copyStoreId(store_id_alloc);

        var bound_set_id: [64]u8 = undefined;
        randomHex64(&bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_vector_store_schema_name, "bound_set_id", &bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_vector_store_schema_name, "vector_epoch", "0");
        try insertBoundVectorStoreRow(&self.sqlite_db, store_path, store_id_alloc, &bound_set_id);

        self.bound_vector_store = .{};
        errdefer self.bound_vector_store = null;

        try copyVectorStorage(&self.sqlite_db, .main, &self.sqlite_db, .vector_store);
        try clearMainVectorStorage(&self.sqlite_db);

        try verifyCurrentDatabase(self);
        try self.sqlite_db.commit();
        committed = true;

        return .{
            .store_path = store_path,
            .store_id = store_id,
            .bound_set_id = bound_set_id,
            .copied = copied_counts,
            .cleared = copied_counts,
            .verified = true,
        };
    }

    /// Return information about the optional bound vector store, if present.
    pub fn boundVectorStore(self: *Database, allocator: std.mem.Allocator) Error!?BoundVectorStoreInfo {
        return try loadBoundVectorStoreInfo(allocator, &self.sqlite_db);
    }

    /// Remove the optional vector-store binding from this main database.
    ///
    /// This never deletes or mutates the vector store file itself.
    pub fn unbindVectorStore(self: *Database) Error!void {
        try self.rejectBoundStoreManagementInsideMainTransaction();
        if (!try hasBoundVectorStoreRow(&self.sqlite_db)) return error.BoundStoreNotFound;

        const had_attached_store = self.bound_vector_store != null;
        try self.detachBoundVectorStore();
        var deleted = false;
        errdefer if (had_attached_store and !deleted) {
            self.restoreConfiguredBoundVectorStore() catch {};
        };

        var stmt = try self.sqlite_db.prepare(
            \\delete from _zova_bound_stores
            \\where role = 'vector_store' and name = 'default'
        );
        defer stmt.deinit();
        std.debug.assert((try stmt.step()) == .done);
        deleted = true;
    }

    /// Create an incremental object writer for this database connection.
    pub fn objectWriter(self: *Database, allocator: std.mem.Allocator) Error!ObjectWriter {
        var objects = self.objectDatabase();
        return .{
            .inner = try objects.objectWriter(allocator),
            .sqlite_db = &self.sqlite_db,
            .bound = self.bound_object_store != null,
        };
    }

    /// Create a native vector collection.
    pub fn createVectorCollection(
        self: *Database,
        name: []const u8,
        options: VectorCollectionOptions,
    ) Error!void {
        const owns_transaction = try self.beginBoundVectorMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var vectors = self.vectorDatabase();
        try vectors.createVectorCollection(name, options);
        if (self.bound_vector_store != null) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBoundVectorMutation(owns_transaction);
        committed = true;
    }

    /// Return whether a valid vector collection exists.
    pub fn hasVectorCollection(self: *Database, name: []const u8) Error!bool {
        var vectors = self.vectorDatabase();
        return vectors.hasVectorCollection(name);
    }

    /// Return owned metadata for one existing vector collection.
    pub fn vectorCollectionInfo(
        self: *Database,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) Error!VectorCollectionInfo {
        var vectors = self.vectorDatabase();
        return vectors.vectorCollectionInfo(allocator, name);
    }

    /// List all vector collections sorted by ascending name.
    pub fn listVectorCollections(
        self: *Database,
        allocator: std.mem.Allocator,
    ) Error!VectorCollectionList {
        var vectors = self.vectorDatabase();
        return vectors.listVectorCollections(allocator);
    }

    /// Store or replace one vector row in a collection.
    pub fn putVector(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
        values: []const f32,
    ) Error!void {
        const owns_transaction = try self.beginBoundVectorMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var vectors = self.vectorDatabase();
        try vectors.putVector(collection_name, vector_id, values);
        if (self.bound_vector_store != null) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBoundVectorMutation(owns_transaction);
        committed = true;
    }

    /// Store or replace multiple vector rows in a collection.
    pub fn putVectors(
        self: *Database,
        collection_name: []const u8,
        inputs: []const VectorInput,
    ) Error!void {
        const owns_transaction = try self.beginBoundVectorMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var vectors = self.vectorDatabase();
        try vectors.putVectors(collection_name, inputs);
        if (self.bound_vector_store != null and inputs.len != 0) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBoundVectorMutation(owns_transaction);
        committed = true;
    }

    /// Load one vector row into owned memory.
    pub fn getVector(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        vector_id: []const u8,
    ) Error!Vector {
        var vectors = self.vectorDatabase();
        return vectors.getVector(allocator, collection_name, vector_id);
    }

    /// Return whether a vector id exists in an existing collection.
    pub fn hasVector(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
    ) Error!bool {
        var vectors = self.vectorDatabase();
        return vectors.hasVector(collection_name, vector_id);
    }

    /// Delete one vector row from an existing collection.
    pub fn deleteVector(
        self: *Database,
        collection_name: []const u8,
        vector_id: []const u8,
    ) Error!void {
        const owns_transaction = try self.beginBoundVectorMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var vectors = self.vectorDatabase();
        try vectors.deleteVector(collection_name, vector_id);
        if (self.bound_vector_store != null) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBoundVectorMutation(owns_transaction);
        committed = true;
    }

    /// Delete a vector collection and all private vector rows in it.
    pub fn deleteVectorCollection(self: *Database, name: []const u8) Error!void {
        const owns_transaction = try self.beginBoundVectorMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var vectors = self.vectorDatabase();
        try vectors.deleteVectorCollection(name);
        if (self.bound_vector_store != null) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBoundVectorMutation(owns_transaction);
        committed = true;
    }

    /// Search one vector collection with an exact flat scan.
    pub fn searchVectors(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: []const f32,
        limit: usize,
    ) Error!VectorSearchResults {
        var vectors = self.vectorDatabase();
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
        var vectors = self.vectorDatabase();
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
        var vectors = self.vectorDatabase();
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
        var vectors = self.vectorDatabase();
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
        var vectors = self.vectorDatabase();
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
        var vectors = self.vectorDatabase();
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
        var vectors = self.vectorDatabase();
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
        var vectors = self.vectorDatabase();
        return vectors.searchVectorsByIdInWithin(allocator, collection_name, source_vector_id, candidate_ids, max_distance, limit);
    }

    /// Store raw bytes as a content-addressed Zova object.
    pub fn putObject(self: *Database, bytes: []const u8) Error!ObjectId {
        if (self.bound_object_store == null) {
            var objects = self.objectDatabase();
            return objects.putObject(bytes);
        }

        const id = objectId(bytes);
        const existed = try self.hasObject(id);
        const owns_transaction = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var objects = self.objectDatabase();
        const result = try objects.putObject(bytes);
        if (!existed) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(owns_transaction);
        committed = true;
        return result;
    }

    /// Load and verify an object by id.
    pub fn getObject(self: *Database, allocator: std.mem.Allocator, id: ObjectId) Error!Object {
        var objects = self.objectDatabase();
        return objects.getObject(allocator, id);
    }

    /// Read a byte range from a logical object into a caller-provided buffer.
    pub fn readObjectRange(self: *Database, id: ObjectId, offset: u64, buffer: []u8) Error!usize {
        var objects = self.objectDatabase();
        return objects.readObjectRange(id, offset, buffer);
    }

    /// Return the public manifest for one object.
    pub fn objectManifest(self: *Database, allocator: std.mem.Allocator, id: ObjectId) Error!ObjectManifest {
        var objects = self.objectDatabase();
        return objects.objectManifest(allocator, id);
    }

    /// Return whether a stored chunk hash exists.
    pub fn hasObjectChunk(self: *Database, hash: ObjectChunkId) Error!bool {
        var objects = self.objectDatabase();
        return objects.hasObjectChunk(hash);
    }

    /// Store one verified loose object chunk.
    pub fn putObjectChunk(self: *Database, expected_hash: ObjectChunkId, bytes: []const u8) Error!void {
        const existed = if (self.bound_object_store != null) try self.hasObjectChunk(expected_hash) else false;
        const owns_transaction = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var objects = self.objectDatabase();
        try objects.putObjectChunk(expected_hash, bytes);
        if (self.bound_object_store != null and !existed) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(owns_transaction);
        committed = true;
    }

    /// Assemble a complete object from already-verified chunks.
    pub fn assembleObjectFromChunks(
        self: *Database,
        id: ObjectId,
        size_bytes: u64,
        chunks: []const ObjectChunk,
    ) Error!void {
        const owns_transaction = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var objects = self.objectDatabase();
        try objects.assembleObjectFromChunks(id, size_bytes, chunks);
        if (self.bound_object_store != null) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(owns_transaction);
        committed = true;
    }

    /// Delete one unreferenced loose chunk if possible.
    pub fn deleteObjectChunk(self: *Database, hash: ObjectChunkId) Error!bool {
        const owns_transaction = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var objects = self.objectDatabase();
        const deleted = try objects.deleteObjectChunk(hash);
        if (self.bound_object_store != null and deleted) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(owns_transaction);
        committed = true;
        return deleted;
    }

    /// Load and verify one chunk by hash.
    pub fn getObjectChunk(
        self: *Database,
        allocator: std.mem.Allocator,
        hash: ObjectChunkId,
    ) Error!ObjectChunkData {
        var objects = self.objectDatabase();
        return objects.getObjectChunk(allocator, hash);
    }

    /// Return whether an object id exists without loading object bytes.
    pub fn hasObject(self: *Database, id: ObjectId) Error!bool {
        var objects = self.objectDatabase();
        return objects.hasObject(id);
    }

    /// Return the original full object byte length.
    pub fn objectSize(self: *Database, id: ObjectId) Error!u64 {
        var objects = self.objectDatabase();
        return objects.objectSize(id);
    }

    /// Return the number of FastCDC chunks in the object manifest.
    pub fn objectChunkCount(self: *Database, id: ObjectId) Error!u64 {
        var objects = self.objectDatabase();
        return objects.objectChunkCount(id);
    }

    /// Delete one Zova object and garbage-collect its unreferenced chunks.
    pub fn deleteObject(self: *Database, id: ObjectId) Error!void {
        const owns_transaction = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var objects = self.objectDatabase();
        try objects.deleteObject(id);
        if (self.bound_object_store != null) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(owns_transaction);
        committed = true;
    }

    fn beginBoundObjectMutation(self: *Database) Error!bool {
        if (self.bound_object_store == null or hasActiveTransaction(&self.sqlite_db)) return false;
        try self.sqlite_db.beginImmediate();
        return true;
    }

    fn finishBoundObjectMutation(self: *Database, owns_transaction: bool) Error!void {
        if (owns_transaction) try self.sqlite_db.commit();
    }

    fn objectDatabase(self: *Database) object_impl.Database {
        const bound = self.bound_object_store != null;
        return .{
            .sqlite_db = &self.sqlite_db,
            .storage_schema = if (bound) .object_store else .main,
            .allow_active_transactions = bound,
        };
    }

    fn beginBoundVectorMutation(self: *Database) Error!bool {
        if (self.bound_vector_store == null or hasActiveTransaction(&self.sqlite_db)) return false;
        try self.sqlite_db.beginImmediate();
        return true;
    }

    fn finishBoundVectorMutation(self: *Database, owns_transaction: bool) Error!void {
        if (owns_transaction) try self.sqlite_db.commit();
    }

    fn vectorDatabase(self: *Database) vector_impl.Database {
        return .{
            .sqlite_db = &self.sqlite_db,
            .storage_schema = if (self.bound_vector_store != null) .vector_store else .main,
        };
    }

    fn graphDatabase(self: *Database) graph_impl.Database {
        return .{ .sqlite_db = &self.sqlite_db };
    }

    fn rejectBoundStoreManagementInsideMainTransaction(self: *Database) Error!void {
        if (hasActiveTransaction(&self.sqlite_db)) {
            return error.ObjectTransactionActive;
        }
    }

    fn inlineBoundStoresIntoDestination(self: *Database, destination_path: [:0]const u8) Error!void {
        if (self.bound_object_store == null and self.bound_vector_store == null) return;

        var destination = try sqlite.Database.open(destination_path);
        defer destination.deinit();

        if (self.bound_object_store != null) {
            try clearMainObjectStorage(&destination);
            try copyObjectStorage(&self.sqlite_db, .object_store, &destination, .main);
            try deleteBoundObjectStoreRows(&destination);
        }

        if (self.bound_vector_store != null) {
            try clearMainVectorStorage(&destination);
            try copyVectorStorage(&self.sqlite_db, .vector_store, &destination, .main);
            try deleteBoundVectorStoreRows(&destination);
        }
    }

    fn detachBoundObjectStore(self: *Database) Error!void {
        if (self.bound_object_store == null) return;
        try self.sqlite_db.detachDatabase(bound_object_store_schema_name);
        self.bound_object_store = null;
    }

    fn restoreConfiguredBoundObjectStore(self: *Database) Error!void {
        if (self.bound_object_store != null) return;
        self.bound_object_store = try openConfiguredBoundObjectStore(&self.sqlite_db, .{});
    }

    fn detachBoundVectorStore(self: *Database) Error!void {
        if (self.bound_vector_store == null) return;
        try self.sqlite_db.detachDatabase(bound_vector_store_schema_name);
        self.bound_vector_store = null;
    }

    fn restoreConfiguredBoundVectorStore(self: *Database) Error!void {
        if (self.bound_vector_store != null) return;
        self.bound_vector_store = try openConfiguredBoundVectorStore(&self.sqlite_db, .{});
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
    try initializeGraphSchema(db);
}

fn initializeMetadata(db: *sqlite.Database) sqlite.Error!void {
    var random_bytes: [32]u8 = undefined;
    sqlite.c.sqlite3_randomness(random_bytes.len, &random_bytes);

    var database_id: [64]u8 = undefined;
    lowerHexInto(&database_id, &random_bytes);

    try db.exec(
        \\create table _zova_meta (
        \\  key text primary key,
        \\  value text not null
        \\);
        \\insert into _zova_meta (key, value) values ('magic', 'zova');
        \\insert into _zova_meta (key, value) values ('format_version', '4');
    );

    var insert_id = try db.prepare("insert into _zova_meta (key, value) values ('database_id', ?)");
    defer insert_id.deinit();
    try insert_id.bindText(1, &database_id);
    std.debug.assert((try insert_id.step()) == .done);
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

fn initializeGraphSchema(db: *sqlite.Database) sqlite.Error!void {
    try db.exec(graph_impl.graphs_schema_sql ++ ";");
    try db.exec(graph_impl.graph_nodes_schema_sql ++ ";");
    try db.exec(graph_impl.graph_edges_schema_sql ++ ";");
}

fn markAsObjectStore(db: *sqlite.Database) Error!void {
    var store_id: [64]u8 = undefined;
    randomHex64(&store_id);

    var insert_role = try db.prepare("insert into _zova_meta (key, value) values ('store_role', ?)");
    defer insert_role.deinit();
    try insert_role.bindText(1, bound_object_store_role);
    std.debug.assert((try insert_role.step()) == .done);

    var insert_id = try db.prepare("insert into _zova_meta (key, value) values ('store_id', ?)");
    defer insert_id.deinit();
    try insert_id.bindText(1, &store_id);
    std.debug.assert((try insert_id.step()) == .done);

    var insert_epoch = try db.prepare("insert into _zova_meta (key, value) values ('object_epoch', '0')");
    defer insert_epoch.deinit();
    std.debug.assert((try insert_epoch.step()) == .done);
}

fn markAsVectorStore(db: *sqlite.Database) Error!void {
    var store_id: [64]u8 = undefined;
    randomHex64(&store_id);

    var insert_role = try db.prepare("insert into _zova_meta (key, value) values ('store_role', ?)");
    defer insert_role.deinit();
    try insert_role.bindText(1, bound_vector_store_role);
    std.debug.assert((try insert_role.step()) == .done);

    var insert_id = try db.prepare("insert into _zova_meta (key, value) values ('store_id', ?)");
    defer insert_id.deinit();
    try insert_id.bindText(1, &store_id);
    std.debug.assert((try insert_id.step()) == .done);

    var insert_epoch = try db.prepare("insert into _zova_meta (key, value) values ('vector_epoch', '0')");
    defer insert_epoch.deinit();
    std.debug.assert((try insert_epoch.step()) == .done);
}

fn ensureBoundStoreTable(db: *sqlite.Database) Error!void {
    if (try tableExists(db, bound_stores_table)) {
        try validateBoundStoreTable(db);
        return;
    }
    try db.exec(bound_stores_schema_sql ++ ";");
}

fn validateOptionalBoundStoreSchema(db: *sqlite.Database) Error!void {
    if (try tableExists(db, bound_stores_table)) try validateBoundStoreTable(db);
}

fn validateBoundStoreTable(db: *sqlite.Database) Error!void {
    const columns = [_][]const u8{
        "role",
        "name",
        "path",
        "store_id",
        "bound_set_id",
        "object_epoch",
        "vector_epoch",
        "created_at_unix",
    };
    try validateRequiredTable(db, bound_stores_table, &columns, bound_stores_schema_sql);
}

fn ensureMainDatabaseRole(db: *sqlite.Database) Error!void {
    if (try metadataValueAlloc(std.heap.c_allocator, db, "store_role")) |role| {
        defer std.heap.c_allocator.free(role);
        if (std.mem.eql(u8, role, bound_object_store_role)) return error.BoundStoreInvalid;
        if (std.mem.eql(u8, role, bound_vector_store_role)) return error.BoundStoreInvalid;
        return error.NotZovaDatabase;
    }
}

fn openConfiguredBoundObjectStore(db: *sqlite.Database, options: OpenOptions) Error!?BoundObjectStore {
    if (!try tableExists(db, bound_stores_table)) return null;

    var info = (try loadBoundObjectStoreInfo(std.heap.c_allocator, db)) orelse return null;
    defer info.deinit(std.heap.c_allocator);

    const path_z = try std.heap.c_allocator.dupeZ(u8, info.path);
    defer std.heap.c_allocator.free(path_z);

    try attachObjectStore(db, path_z, options.read_only);
    errdefer db.detachDatabase(bound_object_store_schema_name) catch {};

    const actual_store_id = try validateAttachedObjectStoreAlloc(std.heap.c_allocator, db, bound_object_store_schema_name);
    defer std.heap.c_allocator.free(actual_store_id);
    if (!std.mem.eql(u8, actual_store_id, info.store_id)) return error.BoundStoreInvalid;

    const actual_bound_set_id = (try attachedMetadataValueAlloc(std.heap.c_allocator, db, bound_object_store_schema_name, "bound_set_id")) orelse return error.BoundStoreInvalid;
    defer std.heap.c_allocator.free(actual_bound_set_id);
    if (!std.mem.eql(u8, actual_bound_set_id, info.bound_set_id)) return error.BoundStoreInvalid;

    const actual_epoch = try attachedMetadataU64(db, bound_object_store_schema_name, "object_epoch");
    if (actual_epoch != info.object_epoch) return error.BoundStoreInvalid;

    return .{};
}

fn openConfiguredBoundVectorStore(db: *sqlite.Database, options: OpenOptions) Error!?BoundVectorStore {
    if (!try tableExists(db, bound_stores_table)) return null;

    var info = (try loadBoundVectorStoreInfo(std.heap.c_allocator, db)) orelse return null;
    defer info.deinit(std.heap.c_allocator);

    const path_z = try std.heap.c_allocator.dupeZ(u8, info.path);
    defer std.heap.c_allocator.free(path_z);

    try attachVectorStore(db, path_z, options.read_only);
    errdefer db.detachDatabase(bound_vector_store_schema_name) catch {};

    const actual_store_id = try validateAttachedVectorStoreAlloc(std.heap.c_allocator, db, bound_vector_store_schema_name);
    defer std.heap.c_allocator.free(actual_store_id);
    if (!std.mem.eql(u8, actual_store_id, info.store_id)) return error.BoundStoreInvalid;

    const actual_bound_set_id = (try attachedMetadataValueAlloc(std.heap.c_allocator, db, bound_vector_store_schema_name, "bound_set_id")) orelse return error.BoundStoreInvalid;
    defer std.heap.c_allocator.free(actual_bound_set_id);
    if (!std.mem.eql(u8, actual_bound_set_id, info.bound_set_id)) return error.BoundStoreInvalid;

    const actual_epoch = try attachedMetadataU64(db, bound_vector_store_schema_name, "vector_epoch");
    if (actual_epoch != info.vector_epoch) return error.BoundStoreInvalid;

    return .{};
}

fn attachObjectStore(db: *sqlite.Database, path: []const u8, read_only: bool) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;
    try ensurePathExists(path);
    try db.attachDatabase(path, bound_object_store_schema_name);
    errdefer db.detachDatabase(bound_object_store_schema_name) catch {};
    if (read_only) try db.setQueryOnly(true);
}

fn attachVectorStore(db: *sqlite.Database, path: []const u8, read_only: bool) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;
    try ensurePathExists(path);
    try db.attachDatabase(path, bound_vector_store_schema_name);
    errdefer db.detachDatabase(bound_vector_store_schema_name) catch {};
    if (read_only) try db.setQueryOnly(true);
}

fn prepareSchemaSql(db: *sqlite.Database, comptime sql_format: []const u8, args: anytype) Error!sqlite.Statement {
    var sql_buffer: [4096]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&sql_buffer, sql_format, args) catch return error.SqliteError;
    return try db.prepare(sql);
}

fn copyObjectStorage(
    source: *sqlite.Database,
    source_schema: object_impl.StorageSchema,
    destination: *sqlite.Database,
    destination_schema: object_impl.StorageSchema,
) Error!void {
    var source_objects = object_impl.Database{
        .sqlite_db = source,
        .storage_schema = source_schema,
        .allow_active_transactions = false,
    };

    var chunks = try prepareObjectSchemaSql(source, source_schema,
        \\select chunk_hash, size_bytes, data
        \\from {s}_zova_chunks
        \\order by hex(chunk_hash)
    , .{source_schema.prefix()});
    defer chunks.deinit();

    var insert_chunk = try prepareObjectSchemaSql(destination, destination_schema,
        \\insert into {s}_zova_chunks (chunk_hash, size_bytes, data)
        \\values (?, ?, ?)
    , .{destination_schema.prefix()});
    defer insert_chunk.deinit();

    while ((try chunks.step()) == .row) {
        const raw_hash = chunks.columnBlob(0);
        if (raw_hash.len != @sizeOf(ObjectChunkId)) return error.ObjectCorrupt;

        var hash: ObjectChunkId = undefined;
        @memcpy(hash[0..], raw_hash);

        var chunk = try source_objects.getObjectChunk(std.heap.c_allocator, hash);
        chunk.deinit(std.heap.c_allocator);

        try insert_chunk.bindBlob(1, raw_hash);
        try insert_chunk.bindInt64(2, chunks.columnInt64(1));
        try insert_chunk.bindBlob(3, chunks.columnBlob(2));
        std.debug.assert((try insert_chunk.step()) == .done);
        try insert_chunk.reset();
        try insert_chunk.clearBindings();
    }

    var objects = try prepareObjectSchemaSql(
        source,
        source_schema,
        "select object_id, size_bytes, chunk_count, chunker from {s}_zova_objects order by hex(object_id)",
        .{source_schema.prefix()},
    );
    defer objects.deinit();

    var insert_object = try prepareObjectSchemaSql(destination, destination_schema,
        \\insert into {s}_zova_objects (object_id, size_bytes, chunk_count, chunker)
        \\values (?, ?, ?, ?)
    , .{destination_schema.prefix()});
    defer insert_object.deinit();

    while ((try objects.step()) == .row) {
        const raw_id = objects.columnBlob(0);
        if (raw_id.len != @sizeOf(ObjectId)) return error.ObjectCorrupt;

        var id: ObjectId = undefined;
        @memcpy(id[0..], raw_id);

        var object = try source_objects.getObject(std.heap.c_allocator, id);
        object.deinit(std.heap.c_allocator);

        var manifest = try source_objects.objectManifest(std.heap.c_allocator, id);
        manifest.deinit(std.heap.c_allocator);

        try insert_object.bindBlob(1, raw_id);
        try insert_object.bindInt64(2, objects.columnInt64(1));
        try insert_object.bindInt64(3, objects.columnInt64(2));
        try insert_object.bindText(4, objects.columnText(3));
        std.debug.assert((try insert_object.step()) == .done);
        try insert_object.reset();
        try insert_object.clearBindings();
    }

    var manifest_rows = try prepareObjectSchemaSql(source, source_schema,
        \\select object_id, chunk_index, chunk_hash, offset, size_bytes
        \\from {s}_zova_object_chunks
        \\order by hex(object_id), chunk_index
    , .{source_schema.prefix()});
    defer manifest_rows.deinit();

    var insert_manifest = try prepareObjectSchemaSql(destination, destination_schema,
        \\insert into {s}_zova_object_chunks (object_id, chunk_index, chunk_hash, offset, size_bytes)
        \\values (?, ?, ?, ?, ?)
    , .{destination_schema.prefix()});
    defer insert_manifest.deinit();

    while ((try manifest_rows.step()) == .row) {
        try insert_manifest.bindBlob(1, manifest_rows.columnBlob(0));
        try insert_manifest.bindInt64(2, manifest_rows.columnInt64(1));
        try insert_manifest.bindBlob(3, manifest_rows.columnBlob(2));
        try insert_manifest.bindInt64(4, manifest_rows.columnInt64(3));
        try insert_manifest.bindInt64(5, manifest_rows.columnInt64(4));
        std.debug.assert((try insert_manifest.step()) == .done);
        try insert_manifest.reset();
        try insert_manifest.clearBindings();
    }
}

fn copyVectorStorage(
    source: *sqlite.Database,
    source_schema: vector_impl.StorageSchema,
    destination: *sqlite.Database,
    destination_schema: vector_impl.StorageSchema,
) Error!void {
    var source_vectors = vector_impl.Database{
        .sqlite_db = source,
        .storage_schema = source_schema,
    };
    var destination_vectors = vector_impl.Database{
        .sqlite_db = destination,
        .storage_schema = destination_schema,
    };

    var collections = try source_vectors.listVectorCollections(std.heap.c_allocator);
    defer collections.deinit(std.heap.c_allocator);

    for (collections.items) |collection| {
        const destination_has_collection = try destination_vectors.hasVectorCollection(collection.name);
        if (destination_has_collection) {
            var destination_info = try destination_vectors.vectorCollectionInfo(std.heap.c_allocator, collection.name);
            defer destination_info.deinit(std.heap.c_allocator);
            if (destination_info.dimensions != collection.dimensions or destination_info.metric != collection.metric) {
                return error.VectorCollectionExists;
            }
        } else {
            try destination_vectors.createVectorCollection(collection.name, .{
                .dimensions = collection.dimensions,
                .metric = collection.metric,
            });
        }

        var rows = try prepareSchemaSql(source,
            \\select vector_id
            \\from {s}_zova_vectors
            \\where collection_name = ?
            \\order by vector_id
        , .{source_schema.prefix()});
        defer rows.deinit();

        try rows.bindText(1, collection.name);
        while ((try rows.step()) == .row) {
            const vector_id = try std.heap.c_allocator.dupe(u8, rows.columnText(0));
            defer std.heap.c_allocator.free(vector_id);

            var vector = try source_vectors.getVector(std.heap.c_allocator, collection.name, vector_id);
            defer vector.deinit(std.heap.c_allocator);

            try destination_vectors.putVector(collection.name, vector.id, vector.values);
        }
    }
}

fn clearMainObjectStorage(db: *sqlite.Database) Error!void {
    try db.exec(
        \\delete from _zova_object_chunks;
        \\delete from _zova_objects;
        \\delete from _zova_chunks;
    );
}

fn clearMainVectorStorage(db: *sqlite.Database) Error!void {
    try db.exec(
        \\delete from _zova_vectors;
        \\delete from _zova_vector_collections;
    );
}

fn mainObjectStorageHasRows(db: *sqlite.Database) Error!bool {
    const counts = try objectStorageCounts(db, .main);
    return counts.objects != 0 or counts.chunks != 0 or counts.manifest_rows != 0;
}

fn mainVectorStorageHasRows(db: *sqlite.Database) Error!bool {
    const counts = try vectorStorageCounts(db, .main);
    return counts.vector_collections != 0 or counts.vectors != 0;
}

fn objectStorageCounts(db: *sqlite.Database, storage_schema: object_impl.StorageSchema) Error!SplitObjectStoreCounts {
    return .{
        .objects = try countStorageRows(db, "select count(*) from {s}_zova_objects", .{storage_schema.prefix()}),
        .chunks = try countStorageRows(db, "select count(*) from {s}_zova_chunks", .{storage_schema.prefix()}),
        .manifest_rows = try countStorageRows(db, "select count(*) from {s}_zova_object_chunks", .{storage_schema.prefix()}),
    };
}

fn vectorStorageCounts(db: *sqlite.Database, storage_schema: vector_impl.StorageSchema) Error!SplitVectorStoreCounts {
    return .{
        .vector_collections = try countStorageRows(db, "select count(*) from {s}_zova_vector_collections", .{storage_schema.prefix()}),
        .vectors = try countStorageRows(db, "select count(*) from {s}_zova_vectors", .{storage_schema.prefix()}),
    };
}

fn countStorageRows(db: *sqlite.Database, comptime sql_format: []const u8, args: anytype) Error!u64 {
    var stmt = try prepareSchemaSql(db, sql_format, args);
    defer stmt.deinit();
    std.debug.assert((try stmt.step()) == .row);
    return try sqliteI64ToU64(stmt.columnInt64(0));
}

fn prepareObjectSchemaSql(
    db: *sqlite.Database,
    storage_schema: object_impl.StorageSchema,
    comptime sql_format: []const u8,
    args: anytype,
) Error!sqlite.Statement {
    _ = storage_schema;
    return try prepareSchemaSql(db, sql_format, args);
}

fn deleteBoundObjectStoreRows(db: *sqlite.Database) Error!void {
    if (!try tableExists(db, bound_stores_table)) return;

    var stmt = try db.prepare(
        \\delete from _zova_bound_stores
        \\where role = 'object_store' and name = 'default'
    );
    defer stmt.deinit();
    std.debug.assert((try stmt.step()) == .done);
}

fn deleteBoundVectorStoreRows(db: *sqlite.Database) Error!void {
    if (!try tableExists(db, bound_stores_table)) return;

    var stmt = try db.prepare(
        \\delete from _zova_bound_stores
        \\where role = 'vector_store' and name = 'default'
    );
    defer stmt.deinit();
    std.debug.assert((try stmt.step()) == .done);
}

fn validateObjectStoreDatabase(db: *sqlite.Database) Error!void {
    try expectMetadataValue(db, "magic", magic_value, .magic);
    try expectMetadataValue(db, "format_version", format_version, .format_version);
    try expectMetadataValue(db, "store_role", bound_object_store_role, .magic);
    const store_id = try objectStoreIdAlloc(std.heap.c_allocator, db);
    defer std.heap.c_allocator.free(store_id);
    try validateObjectSchema(db);
}

fn validateAttachedObjectStoreAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    comptime schema_name: []const u8,
) Error![]u8 {
    try expectAttachedMetadataValue(db, schema_name, "magic", magic_value, .magic);
    try expectAttachedMetadataValue(db, schema_name, "format_version", format_version, .format_version);
    try expectAttachedMetadataValue(db, schema_name, "store_role", bound_object_store_role, .magic);
    const store_id = try attachedObjectStoreIdAlloc(allocator, db, schema_name);
    errdefer allocator.free(store_id);
    try validateAttachedObjectSchema(db, schema_name);
    return store_id;
}

fn validateVectorStoreDatabase(db: *sqlite.Database) Error!void {
    try expectMetadataValue(db, "magic", magic_value, .magic);
    try expectMetadataValue(db, "format_version", format_version, .format_version);
    try expectMetadataValue(db, "store_role", bound_vector_store_role, .magic);
    const store_id = try objectStoreIdAlloc(std.heap.c_allocator, db);
    defer std.heap.c_allocator.free(store_id);
    try validateVectorSchema(db);
}

fn validateAttachedVectorStoreAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    comptime schema_name: []const u8,
) Error![]u8 {
    try expectAttachedMetadataValue(db, schema_name, "magic", magic_value, .magic);
    try expectAttachedMetadataValue(db, schema_name, "format_version", format_version, .format_version);
    try expectAttachedMetadataValue(db, schema_name, "store_role", bound_vector_store_role, .magic);
    const store_id = try attachedObjectStoreIdAlloc(allocator, db, schema_name);
    errdefer allocator.free(store_id);
    try validateAttachedVectorSchema(db, schema_name);
    return store_id;
}

fn validateAttachedObjectSchema(db: *sqlite.Database, comptime schema_name: []const u8) Error!void {
    const object_columns = [_][]const u8{
        "object_id",
        "size_bytes",
        "chunk_count",
        "chunker",
    };
    try validateAttachedRequiredTable(db, schema_name, object_impl.objects_table, &object_columns, object_impl.objects_schema_sql);

    const chunk_columns = [_][]const u8{
        "chunk_hash",
        "size_bytes",
        "data",
    };
    try validateAttachedRequiredTable(db, schema_name, object_impl.chunks_table, &chunk_columns, object_impl.chunks_schema_sql);

    const object_chunk_columns = [_][]const u8{
        "object_id",
        "chunk_index",
        "chunk_hash",
        "offset",
        "size_bytes",
    };
    try validateAttachedRequiredTable(db, schema_name, object_impl.object_chunks_table, &object_chunk_columns, object_impl.object_chunks_schema_sql);
}

fn validateAttachedVectorSchema(db: *sqlite.Database, comptime schema_name: []const u8) Error!void {
    const vector_collection_columns = [_][]const u8{
        "name",
        "dimensions",
        "metric",
        "element_type",
    };
    try validateAttachedRequiredTable(db, schema_name, vector_impl.vector_collections_table, &vector_collection_columns, vector_impl.collections_schema_sql);

    const vector_columns = [_][]const u8{
        "collection_name",
        "vector_id",
        "dimensions",
        "values",
    };
    try validateAttachedRequiredTable(db, schema_name, vector_impl.vectors_table, &vector_columns, vector_impl.vectors_schema_sql);
}

fn validateAttachedRequiredTable(
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    table_name: []const u8,
    required_columns: []const []const u8,
    expected_sql: []const u8,
) Error!void {
    if (!try attachedTableExists(db, schema_name, table_name)) return error.NotZovaDatabase;

    for (required_columns) |column_name| {
        if (!try attachedTableColumnExists(db, schema_name, table_name, column_name)) return error.NotZovaDatabase;
    }

    var table_sql = try prepareSchemaSql(db,
        \\select sql
        \\from {s}.sqlite_master
        \\where type = 'table' and name = ?
    , .{schema_name});
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

fn attachedTableExists(db: *sqlite.Database, comptime schema_name: []const u8, table_name: []const u8) Error!bool {
    var stmt = try prepareSchemaSql(db,
        \\select count(*)
        \\from {s}.sqlite_master
        \\where type = 'table' and name = ?
    , .{schema_name});
    defer stmt.deinit();

    try stmt.bindText(1, table_name);
    const step = try stmt.step();
    std.debug.assert(step == .row);
    return stmt.columnInt64(0) == 1;
}

fn attachedTableColumnExists(
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    table_name: []const u8,
    column_name: []const u8,
) Error!bool {
    var stmt = try prepareSchemaSql(db,
        \\select count(*)
        \\from {s}.pragma_table_info(?)
        \\where name = ?
    , .{schema_name});
    defer stmt.deinit();

    try stmt.bindText(1, table_name);
    try stmt.bindText(2, column_name);
    const step = try stmt.step();
    std.debug.assert(step == .row);
    return stmt.columnInt64(0) == 1;
}

fn attachedObjectStoreIdAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    comptime schema_name: []const u8,
) Error![]u8 {
    const store_id = (try attachedMetadataValueAlloc(allocator, db, schema_name, "store_id")) orelse return error.BoundStoreInvalid;
    errdefer allocator.free(store_id);
    if (!isValidStoreId(store_id)) return error.BoundStoreInvalid;
    return store_id;
}

fn expectAttachedMetadataValue(
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    key: [:0]const u8,
    expected: []const u8,
    metadata_key: MetadataKey,
) Error!void {
    const actual_value = attachedMetadataValueAlloc(std.heap.c_allocator, db, schema_name, key) catch |err| switch (err) {
        error.SqliteError => return error.NotZovaDatabase,
        else => return err,
    };
    const actual = actual_value orelse return error.NotZovaDatabase;
    defer std.heap.c_allocator.free(actual);

    if (std.mem.eql(u8, actual, expected)) return;
    return switch (metadata_key) {
        .magic => error.NotZovaDatabase,
        .format_version => error.UnsupportedZovaVersion,
    };
}

fn attachedMetadataValueAlloc(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    key: []const u8,
) Error!?[]u8 {
    var stmt = try prepareSchemaSql(db, "select value from {s}._zova_meta where key = ?", .{schema_name});
    defer stmt.deinit();

    try stmt.bindText(1, key);
    return switch (try stmt.step()) {
        .done => null,
        .row => try allocator.dupe(u8, stmt.columnText(0)),
    };
}

fn attachedMetadataU64(
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    key: []const u8,
) Error!u64 {
    var stmt = try prepareSchemaSql(db, "select value from {s}._zova_meta where key = ?", .{schema_name});
    defer stmt.deinit();

    try stmt.bindText(1, key);
    return switch (try stmt.step()) {
        .done => error.BoundStoreInvalid,
        .row => std.fmt.parseInt(u64, stmt.columnText(0), 10) catch error.BoundStoreInvalid,
    };
}

fn setMetadataValue(db: *sqlite.Database, key: []const u8, value: []const u8) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_meta (key, value) values (?, ?)
        \\on conflict(key) do update set value = excluded.value
    );
    defer stmt.deinit();

    try stmt.bindText(1, key);
    try stmt.bindText(2, value);
    std.debug.assert((try stmt.step()) == .done);
}

fn setAttachedMetadataValue(
    db: *sqlite.Database,
    comptime schema_name: []const u8,
    key: []const u8,
    value: []const u8,
) Error!void {
    var stmt = try prepareSchemaSql(db,
        \\insert into {s}._zova_meta (key, value) values (?, ?)
        \\on conflict(key) do update set value = excluded.value
    , .{schema_name});
    defer stmt.deinit();

    try stmt.bindText(1, key);
    try stmt.bindText(2, value);
    std.debug.assert((try stmt.step()) == .done);
}

fn hasBoundObjectStoreRow(db: *sqlite.Database) Error!bool {
    if (!try tableExists(db, bound_stores_table)) return false;

    var stmt = try db.prepare(
        \\select 1
        \\from _zova_bound_stores
        \\where role = 'object_store' and name = 'default'
        \\limit 1
    );
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .row => true,
        .done => false,
    };
}

fn hasBoundVectorStoreRow(db: *sqlite.Database) Error!bool {
    if (!try tableExists(db, bound_stores_table)) return false;

    var stmt = try db.prepare(
        \\select 1
        \\from _zova_bound_stores
        \\where role = 'vector_store' and name = 'default'
        \\limit 1
    );
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .row => true,
        .done => false,
    };
}

fn loadBoundObjectStoreInfo(allocator: std.mem.Allocator, db: *sqlite.Database) Error!?BoundObjectStoreInfo {
    if (!try tableExists(db, bound_stores_table)) return null;

    var stmt = try db.prepare(
        \\select path, store_id, bound_set_id, object_epoch
        \\from _zova_bound_stores
        \\where role = 'object_store' and name = 'default'
    );
    defer stmt.deinit();

    switch (try stmt.step()) {
        .done => return null,
        .row => {
            const path = try allocator.dupe(u8, stmt.columnText(0));
            errdefer allocator.free(path);

            const store_id = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(store_id);
            if (!isValidStoreId(store_id)) return error.BoundStoreInvalid;

            const bound_set_id = try allocator.dupe(u8, stmt.columnText(2));
            errdefer allocator.free(bound_set_id);
            if (!isValidStoreId(bound_set_id)) return error.BoundStoreInvalid;

            const object_epoch = try sqliteI64ToU64(stmt.columnInt64(3));

            switch (try stmt.step()) {
                .done => {},
                .row => return error.BoundStoreInvalid,
            }

            return .{ .path = path, .store_id = store_id, .bound_set_id = bound_set_id, .object_epoch = object_epoch };
        },
    }
}

fn loadBoundVectorStoreInfo(allocator: std.mem.Allocator, db: *sqlite.Database) Error!?BoundVectorStoreInfo {
    if (!try tableExists(db, bound_stores_table)) return null;

    var stmt = try db.prepare(
        \\select path, store_id, bound_set_id, vector_epoch
        \\from _zova_bound_stores
        \\where role = 'vector_store' and name = 'default'
    );
    defer stmt.deinit();

    switch (try stmt.step()) {
        .done => return null,
        .row => {
            const path = try allocator.dupe(u8, stmt.columnText(0));
            errdefer allocator.free(path);

            const store_id = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(store_id);
            if (!isValidStoreId(store_id)) return error.BoundStoreInvalid;

            const bound_set_id = try allocator.dupe(u8, stmt.columnText(2));
            errdefer allocator.free(bound_set_id);
            if (!isValidStoreId(bound_set_id)) return error.BoundStoreInvalid;

            const vector_epoch = try sqliteI64ToU64(stmt.columnInt64(3));

            switch (try stmt.step()) {
                .done => {},
                .row => return error.BoundStoreInvalid,
            }

            return .{ .path = path, .store_id = store_id, .bound_set_id = bound_set_id, .vector_epoch = vector_epoch };
        },
    }
}

fn insertBoundObjectStoreRow(db: *sqlite.Database, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_bound_stores (role, name, path, store_id, bound_set_id, object_epoch, vector_epoch, created_at_unix)
        \\values ('object_store', 'default', ?, ?, ?, 0, null, unixepoch())
    );
    defer stmt.deinit();

    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    std.debug.assert((try stmt.step()) == .done);
}

fn updateBoundObjectStoreRow(db: *sqlite.Database, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(
        \\update _zova_bound_stores
        \\set path = ?, store_id = ?, bound_set_id = ?, object_epoch = 0, vector_epoch = null
        \\where role = 'object_store' and name = 'default'
    );
    defer stmt.deinit();

    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    std.debug.assert((try stmt.step()) == .done);
}

fn insertBoundVectorStoreRow(db: *sqlite.Database, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_bound_stores (role, name, path, store_id, bound_set_id, object_epoch, vector_epoch, created_at_unix)
        \\values ('vector_store', 'default', ?, ?, ?, null, 0, unixepoch())
    );
    defer stmt.deinit();

    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    std.debug.assert((try stmt.step()) == .done);
}

fn updateBoundVectorStoreRow(db: *sqlite.Database, path: []const u8, store_id: []const u8, bound_set_id: []const u8) Error!void {
    var stmt = try db.prepare(
        \\update _zova_bound_stores
        \\set path = ?, store_id = ?, bound_set_id = ?, object_epoch = null, vector_epoch = 0
        \\where role = 'vector_store' and name = 'default'
    );
    defer stmt.deinit();

    try stmt.bindText(1, path);
    try stmt.bindText(2, store_id);
    try stmt.bindText(3, bound_set_id);
    std.debug.assert((try stmt.step()) == .done);
}

fn incrementBoundObjectEpoch(db: *sqlite.Database) Error!void {
    var update_main = try db.prepare(
        \\update _zova_bound_stores
        \\set object_epoch = object_epoch + 1
        \\where role = 'object_store' and name = 'default'
    );
    defer update_main.deinit();
    std.debug.assert((try update_main.step()) == .done);

    var read_epoch = try db.prepare(
        \\select object_epoch
        \\from _zova_bound_stores
        \\where role = 'object_store' and name = 'default'
    );
    defer read_epoch.deinit();
    const epoch = switch (try read_epoch.step()) {
        .done => return error.BoundStoreInvalid,
        .row => read_epoch.columnInt64(0),
    };
    if (epoch < 0) return error.BoundStoreInvalid;

    var epoch_buffer: [32]u8 = undefined;
    const epoch_text = std.fmt.bufPrint(&epoch_buffer, "{d}", .{epoch}) catch return error.BoundStoreInvalid;
    try setAttachedMetadataValue(db, bound_object_store_schema_name, "object_epoch", epoch_text);
}

fn incrementBoundVectorEpoch(db: *sqlite.Database) Error!void {
    var update_main = try db.prepare(
        \\update _zova_bound_stores
        \\set vector_epoch = vector_epoch + 1
        \\where role = 'vector_store' and name = 'default'
    );
    defer update_main.deinit();
    std.debug.assert((try update_main.step()) == .done);

    var read_epoch = try db.prepare(
        \\select vector_epoch
        \\from _zova_bound_stores
        \\where role = 'vector_store' and name = 'default'
    );
    defer read_epoch.deinit();
    const epoch = switch (try read_epoch.step()) {
        .done => return error.BoundStoreInvalid,
        .row => read_epoch.columnInt64(0),
    };
    if (epoch < 0) return error.BoundStoreInvalid;

    var epoch_buffer: [32]u8 = undefined;
    const epoch_text = std.fmt.bufPrint(&epoch_buffer, "{d}", .{epoch}) catch return error.BoundStoreInvalid;
    try setAttachedMetadataValue(db, bound_vector_store_schema_name, "vector_epoch", epoch_text);
}

fn objectStoreIdAlloc(allocator: std.mem.Allocator, db: *sqlite.Database) Error![]u8 {
    const store_id = (try metadataValueAlloc(allocator, db, "store_id")) orelse return error.BoundStoreInvalid;
    errdefer allocator.free(store_id);
    if (!isValidStoreId(store_id)) return error.BoundStoreInvalid;
    return store_id;
}

fn metadataValueAlloc(allocator: std.mem.Allocator, db: *sqlite.Database, key: []const u8) Error!?[]u8 {
    var stmt = try db.prepare("select value from _zova_meta where key = ?");
    defer stmt.deinit();

    try stmt.bindText(1, key);
    return switch (try stmt.step()) {
        .done => null,
        .row => try allocator.dupe(u8, stmt.columnText(0)),
    };
}

fn isValidStoreId(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        _ = std.fmt.charToDigit(byte, 16) catch return false;
    }
    return true;
}

fn randomHex64(dest: *[64]u8) void {
    var random_bytes: [32]u8 = undefined;
    sqlite.c.sqlite3_randomness(random_bytes.len, &random_bytes);
    lowerHexInto(dest, &random_bytes);
}

fn lowerHexInto(dest: *[64]u8, bytes: *const [32]u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes.*, 0..) |byte, index| {
        dest[index * 2] = alphabet[byte >> 4];
        dest[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn sqliteI64ToU64(value: i64) Error!u64 {
    if (value < 0) return error.BoundStoreInvalid;
    return @intCast(value);
}

fn copyStoreId(value: []const u8) Error![64]u8 {
    if (!isValidStoreId(value)) return error.BoundStoreInvalid;
    var result: [64]u8 = undefined;
    @memcpy(result[0..], value);
    return result;
}

fn hasActiveTransaction(db: *sqlite.Database) bool {
    return sqlite.c.sqlite3_get_autocommit(db.handle) == 0 or
        sqlite.c.sqlite3_txn_state(db.handle, null) != sqlite.c.SQLITE_TXN_NONE;
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

    try verifyCurrentDatabase(&db);
}

fn verifyCurrentDatabase(db: *Database) Error!void {
    try verifyQuickCheck(db);
    try verifyStoredObjects(db);
    try verifyStoredChunks(db);
    try verifyStoredVectors(db);
}

fn verifyQuickCheck(db: *Database) Error!void {
    try verifyQuickCheckMain(&db.sqlite_db);
    if (db.bound_object_store != null) try verifyQuickCheckAttached(&db.sqlite_db, bound_object_store_schema_name);
    if (db.bound_vector_store != null) try verifyQuickCheckAttached(&db.sqlite_db, bound_vector_store_schema_name);
}

fn verifyQuickCheckMain(db: *sqlite.Database) Error!void {
    var stmt = try db.prepare("pragma quick_check");
    defer stmt.deinit();
    try expectQuickCheckOk(&stmt);
}

fn verifyQuickCheckAttached(db: *sqlite.Database, comptime schema_name: []const u8) Error!void {
    var stmt = try prepareSchemaSql(db, "pragma {s}.quick_check", .{schema_name});
    defer stmt.deinit();
    try expectQuickCheckOk(&stmt);
}

fn expectQuickCheckOk(stmt: *sqlite.Statement) Error!void {
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

    const prefix = if (db.bound_object_store != null) "object_store." else "";
    var objects = try prepareSchemaSql(&db.sqlite_db, "select object_id from {s}_zova_objects order by object_id", .{prefix});
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

    const prefix = if (db.bound_object_store != null) "object_store." else "";
    var chunks = try prepareSchemaSql(&db.sqlite_db, "select chunk_hash from {s}_zova_chunks order by chunk_hash", .{prefix});
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

    const prefix = if (db.bound_vector_store != null) "vector_store." else "";
    var vectors = try prepareSchemaSql(&db.sqlite_db,
        \\select collection_name, vector_id
        \\from {s}_zova_vectors
        \\order by collection_name, vector_id
    , .{prefix});
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
    try ensureMainDatabaseRole(db);
    try validateObjectSchema(db);
    try validateVectorSchema(db);
    try validateGraphSchema(db);
    try validateOptionalBoundStoreSchema(db);
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

fn validateGraphSchema(db: *sqlite.Database) Error!void {
    const graph_columns = [_][]const u8{
        "name",
        "created_order",
    };
    try validateRequiredTable(db, graph_impl.graphs_table, &graph_columns, graph_impl.graphs_schema_sql);

    const node_columns = [_][]const u8{
        "graph_name",
        "node_id",
        "kind",
        "target_type",
        "target_namespace",
        "target_ref",
        "created_order",
    };
    try validateRequiredTable(db, graph_impl.graph_nodes_table, &node_columns, graph_impl.graph_nodes_schema_sql);

    const edge_columns = [_][]const u8{
        "graph_name",
        "from_node_id",
        "edge_type",
        "to_node_id",
        "created_order",
    };
    try validateRequiredTable(db, graph_impl.graph_edges_table, &edge_columns, graph_impl.graph_edges_schema_sql);
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

fn testingExpectScalarText(db: *sqlite.Database, sql: [:0]const u8, expected: []const u8) !void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings(expected, stmt.columnText(0));
}

fn expectBoundObjectEpoch(db: *Database, expected: u64) !void {
    const main_epoch = try testingCount(&db.sqlite_db,
        \\select object_epoch
        \\from _zova_bound_stores
        \\where role = 'object_store' and name = 'default'
    );
    try std.testing.expectEqual(@as(i64, @intCast(expected)), main_epoch);

    const attached_epoch = try testingCount(&db.sqlite_db,
        \\select cast(value as integer)
        \\from object_store._zova_meta
        \\where key = 'object_epoch'
    );
    try std.testing.expectEqual(@as(i64, @intCast(expected)), attached_epoch);
}

fn expectBoundVectorEpoch(db: *Database, expected: u64) !void {
    const main_epoch = try testingCount(&db.sqlite_db,
        \\select vector_epoch
        \\from _zova_bound_stores
        \\where role = 'vector_store' and name = 'default'
    );
    try std.testing.expectEqual(@as(i64, @intCast(expected)), main_epoch);

    const attached_epoch = try testingCount(&db.sqlite_db,
        \\select cast(value as integer)
        \\from vector_store._zova_meta
        \\where key = 'vector_epoch'
    );
    try std.testing.expectEqual(@as(i64, @intCast(expected)), attached_epoch);
}

fn insertObjectReference(db: *Database, object_id: ObjectId) !void {
    var stmt = try db.prepare("insert into attachments(object_id) values (?)");
    defer stmt.deinit();

    try stmt.bindBlob(1, &object_id);
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

fn testingLowerHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[@intCast(byte >> 4)];
        out[index * 2 + 1] = digits[@intCast(byte & 0x0f)];
    }
    return out;
}

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

    try db.createGraph("ops");
    try db.putGraphNode(.{ .graph_name = "ops", .node_id = "doc:primary", .kind = "document", .target_type = .record, .target_namespace = "docs", .target_ref = "1" });
    try db.putGraphNode(.{ .graph_name = "ops", .node_id = "doc:streamed", .kind = "document", .target_type = .record, .target_namespace = "docs", .target_ref = "2" });
    try db.putGraphNode(.{ .graph_name = "ops", .node_id = "vector:doc-a", .kind = "embedding", .target_type = .vector, .target_namespace = "docs", .target_ref = "doc-a" });
    try db.putGraphEdge(.{ .graph_name = "ops", .from_node_id = "doc:primary", .edge_type = "related_to", .to_node_id = "doc:streamed" });
    try db.putGraphEdge(.{ .graph_name = "ops", .from_node_id = "doc:primary", .edge_type = "embedded_as", .to_node_id = "vector:doc-a" });

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

    try std.testing.expect(try db.hasGraph("ops"));
    try std.testing.expect(try db.hasGraphNode("ops", "doc:primary"));
    try std.testing.expect(try db.hasGraphEdge("ops", "doc:primary", "embedded_as", "vector:doc-a"));
    var neighbors = try db.graphNeighbors(std.testing.allocator, .{
        .graph_name = "ops",
        .node_id = "doc:primary",
        .limit = 10,
    });
    defer neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), neighbors.items.len);
    try std.testing.expectEqualStrings("doc:streamed", neighbors.items[0].node_id);
    try std.testing.expectEqualStrings("vector:doc-a", neighbors.items[1].node_id);

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
    try std.testing.expectEqualStrings("database_id", meta.columnText(0));
    try std.testing.expect(isValidStoreId(meta.columnText(1)));

    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings("format_version", meta.columnText(0));
    try std.testing.expectEqualStrings("4", meta.columnText(1));

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
            \\insert into _zova_meta (key, value) values ('format_version', '4');
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
            \\insert into _zova_meta (key, value) values ('format_version', '5');
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

test "single file remains the default object store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "single-file-default.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try db.boundObjectStore(std.testing.allocator));

    const id = try db.putObject("stored in the main database");
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_objects"));

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "stored in the main database", object.bytes);
}

test "optional bound object store routes object APIs after reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "objects-store.zova");

    try createObjectStore(store_path);

    const id = stored: {
        var db = try Database.create(main_path);
        defer db.deinit();

        try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try db.boundObjectStore(std.testing.allocator));
        try db.bindObjectStore(store_path);

        var info = (try db.boundObjectStore(std.testing.allocator)).?;
        defer info.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.endsWith(u8, info.path, "objects-store.zova"));

        const object_id = try db.putObject("stored outside the main database");
        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from object_store._zova_objects"));
        break :stored object_id;
    };

    {
        var store_raw = try sqlite.Database.open(store_path);
        defer store_raw.deinit();
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&store_raw, "select count(*) from _zova_objects"));
    }

    {
        var reopened = try Database.open(main_path);
        defer reopened.deinit();

        var object = try reopened.getObject(std.testing.allocator, id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "stored outside the main database", object.bytes);

        try reopened.unbindObjectStore();
        try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try reopened.boundObjectStore(std.testing.allocator));
        try std.testing.expectError(error.ObjectNotFound, reopened.getObject(std.testing.allocator, id));

        try reopened.bindObjectStore(store_path);
        var rebound = try reopened.getObject(std.testing.allocator, id);
        defer rebound.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "stored outside the main database", rebound.bytes);
    }

    {
        var read_only = try Database.openWithOptions(main_path, .{ .read_only = true });
        defer read_only.deinit();

        var object = try read_only.getObject(std.testing.allocator, id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "stored outside the main database", object.bytes);
        try std.testing.expectError(error.ReadOnly, read_only.putObject("read-only object write"));
    }
}

test "bound object store initializes and advances consistency markers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-markers-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-markers-store.zova");

    try createObjectStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(store_path);

    var info = (try db.boundObjectStore(std.testing.allocator)).?;
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(isValidStoreId(info.bound_set_id));
    try std.testing.expectEqual(@as(u64, 0), info.object_epoch);
    try testingExpectScalarText(&db.sqlite_db, "select value from object_store._zova_meta where key = 'bound_set_id'", info.bound_set_id);
    try testingExpectScalarText(&db.sqlite_db, "select value from object_store._zova_meta where key = 'object_epoch'", "0");

    _ = try db.putObject("epoch object");
    try expectBoundObjectEpoch(&db, 1);

    var read_object = try db.getObject(std.testing.allocator, objectId("epoch object"));
    read_object.deinit(std.testing.allocator);
    try expectBoundObjectEpoch(&db, 1);

    try db.exec("create table notes (body text)");
    try db.exec("insert into notes (body) values ('raw user sql')");
    try expectBoundObjectEpoch(&db, 1);

    const loose = objectChunkId("epoch chunk");
    try db.putObjectChunk(loose, "epoch chunk");
    try expectBoundObjectEpoch(&db, 2);
    try std.testing.expect(try db.deleteObjectChunk(loose));
    try expectBoundObjectEpoch(&db, 3);
}

test "bound object store marker changes roll back with transactions and savepoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-marker-rollback-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-marker-rollback-store.zova");

    try createObjectStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(store_path);

    try db.beginImmediate();
    _ = try db.putObject("rolled back marker object");
    try expectBoundObjectEpoch(&db, 1);
    try db.rollback();
    try expectBoundObjectEpoch(&db, 0);

    try db.beginImmediate();
    try db.savepoint("sp");
    _ = try db.putObject("savepoint rolled back marker object");
    try expectBoundObjectEpoch(&db, 1);
    try db.rollbackToSavepoint("sp");
    try db.releaseSavepoint("sp");
    try expectBoundObjectEpoch(&db, 0);
    try db.commit();
    try expectBoundObjectEpoch(&db, 0);
}

test "operational copies inline bound object store data into single-file destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-copy-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-copy-objects.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "bound-copy-backup.zova");

    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "bound-copy-compact.zova");

    var restore_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restore_path = try testingDbPath(&restore_buffer, tmp.sub_path[0..], "bound-copy-restore.zova");

    try createObjectStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(store_path);

    const object_id = try db.putObject("bound object copied into one destination file");
    const loose_chunk = objectChunkId("loose chunk copied too");
    try db.putObjectChunk(loose_chunk, "loose chunk copied too");
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from object_store._zova_objects"));

    try db.backupTo(backup_path, .{});
    try db.compactTo(compact_path, .{});
    try restoreBackup(main_path, restore_path, .{});

    const copy_paths = [_][:0]const u8{ backup_path, compact_path, restore_path };
    for (copy_paths) |copy_path| {
        var copy = try Database.open(copy_path);
        defer copy.deinit();

        try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try copy.boundObjectStore(std.testing.allocator));
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&copy, "select count(*) from _zova_objects"));

        var object = try copy.getObject(std.testing.allocator, object_id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "bound object copied into one destination file", object.bytes);

        var chunk = try copy.getObjectChunk(std.testing.allocator, loose_chunk);
        defer chunk.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "loose chunk copied too", chunk.bytes);
    }
}

test "split object store moves existing object storage into a bound store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "split-object-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "split-object-store.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "split-object-backup.zova");

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.exec("create table documents (object_id blob not null, title text not null)");

    const object_id = try db.putObject("object moved into split store");
    const object_id_hex = try testingLowerHexAlloc(std.testing.allocator, &object_id);
    defer std.testing.allocator.free(object_id_hex);

    var insert = try db.prepare("insert into documents (object_id, title) values (?, 'kept in main')");
    defer insert.deinit();
    try insert.bindBlob(1, &object_id);
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());

    const loose_chunk = objectChunkId("loose split chunk");
    try db.putObjectChunk(loose_chunk, "loose split chunk");

    const left_chunk = "assembled-left";
    const right_chunk = "assembled-right";
    const assembled_bytes = left_chunk ++ right_chunk;
    const left_hash = objectChunkId(left_chunk);
    const right_hash = objectChunkId(right_chunk);
    const assembled_id = objectId(assembled_bytes);
    try db.putObjectChunk(left_hash, left_chunk);
    try db.putObjectChunk(right_hash, right_chunk);
    try db.assembleObjectFromChunks(assembled_id, assembled_bytes.len, &.{
        .{ .index = 0, .hash = left_hash, .offset = 0, .size_bytes = left_chunk.len },
        .{ .index = 1, .hash = right_hash, .offset = left_chunk.len, .size_bytes = right_chunk.len },
    });

    try db.createGraph("split_objects");
    try db.putGraphNode(.{ .graph_name = "split_objects", .node_id = "doc:object", .kind = "document", .target_type = .record, .target_namespace = "documents", .target_ref = "kept in main" });
    try db.putGraphNode(.{ .graph_name = "split_objects", .node_id = "object:primary", .kind = "object", .target_type = .object, .target_ref = object_id_hex });
    try db.putGraphEdge(.{ .graph_name = "split_objects", .from_node_id = "doc:object", .edge_type = "has_object", .to_node_id = "object:primary" });

    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&db, "select count(*) from _zova_chunks"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(&db, "select count(*) from _zova_object_chunks"));

    const result = try db.splitObjectStore(store_path);
    try std.testing.expectEqualStrings(bound_object_store_role, result.role);
    try std.testing.expect(result.verified);
    try std.testing.expectEqual(@as(u64, 2), result.copied.objects);
    try std.testing.expectEqual(@as(u64, 4), result.copied.chunks);
    try std.testing.expectEqual(@as(u64, 3), result.copied.manifest_rows);
    try std.testing.expectEqual(result.copied, result.cleared);
    try std.testing.expect(isValidStoreId(&result.store_id));
    try std.testing.expect(isValidStoreId(&result.bound_set_id));

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_object_chunks"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from object_store._zova_objects"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&db, "select count(*) from object_store._zova_chunks"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(&db, "select count(*) from object_store._zova_object_chunks"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from documents"));

    var object = try db.getObject(std.testing.allocator, object_id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "object moved into split store", object.bytes);

    var assembled = try db.getObject(std.testing.allocator, assembled_id);
    defer assembled.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, assembled_bytes, assembled.bytes);
    var assembled_manifest = try db.objectManifest(std.testing.allocator, assembled_id);
    defer assembled_manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), assembled_manifest.chunks.len);

    var chunk = try db.getObjectChunk(std.testing.allocator, loose_chunk);
    defer chunk.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "loose split chunk", chunk.bytes);

    try std.testing.expect(try db.hasGraphNode("split_objects", "object:primary"));
    try std.testing.expect(try db.hasGraphEdge("split_objects", "doc:object", "has_object", "object:primary"));
    var graph_neighbors = try db.graphNeighbors(std.testing.allocator, .{
        .graph_name = "split_objects",
        .node_id = "doc:object",
        .limit = 10,
    });
    defer graph_neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), graph_neighbors.items.len);
    try std.testing.expectEqualStrings("object:primary", graph_neighbors.items[0].node_id);

    try db.backupTo(backup_path, .{});
    var backup = try Database.open(backup_path);
    defer backup.deinit();
    try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try backup.boundObjectStore(std.testing.allocator));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&backup, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&backup, "select count(*) from _zova_chunks"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(&backup, "select count(*) from _zova_object_chunks"));
    try std.testing.expect(try backup.hasGraphEdge("split_objects", "doc:object", "has_object", "object:primary"));
}

test "optional bound vector store routes vector APIs and sql native search after reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-vector-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "vectors-store.zova");

    try createVectorStore(store_path);

    {
        var db = try Database.create(main_path);
        defer db.deinit();

        try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try db.boundVectorStore(std.testing.allocator));
        try db.bindVectorStore(store_path);

        var info = (try db.boundVectorStore(std.testing.allocator)).?;
        defer info.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.endsWith(u8, info.path, "vectors-store.zova"));

        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVectors("docs", &.{
            .{ .id = "doc-a", .values = &.{ 1.0, 0.0 } },
            .{ .id = "doc-b", .values = &.{ 0.0, 2.0 } },
        });

        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors"));
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from vector_store._zova_vectors"));

        const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 1.0, 0.0 });
        defer std.testing.allocator.free(query_blob);

        var distance = try db.prepare("select zova_vector_distance('docs', 'doc-a', ?)");
        defer distance.deinit();
        try distance.bindBlob(1, query_blob);
        try std.testing.expectEqual(sqlite.Step.row, try distance.step());
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), distance.columnDouble(0), 0.000001);
    }

    {
        var store_raw = try sqlite.Database.open(store_path);
        defer store_raw.deinit();
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&store_raw, "select count(*) from _zova_vectors"));
    }

    {
        var reopened = try Database.open(main_path);
        defer reopened.deinit();

        var results = try reopened.searchVectors(std.testing.allocator, "docs", &.{ 1.0, 0.0 }, 2);
        defer results.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), results.items.len);
        try std.testing.expectEqualStrings("doc-a", results.items[0].id);

        try reopened.unbindVectorStore();
        try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try reopened.boundVectorStore(std.testing.allocator));
        try std.testing.expectError(error.VectorCollectionNotFound, reopened.getVector(std.testing.allocator, "docs", "doc-a"));

        try reopened.bindVectorStore(store_path);
        var rebound = try reopened.getVector(std.testing.allocator, "docs", "doc-a");
        defer rebound.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0 }, rebound.values);
    }

    {
        var read_only = try Database.openWithOptions(main_path, .{ .read_only = true });
        defer read_only.deinit();

        var vector = try read_only.getVector(std.testing.allocator, "docs", "doc-b");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 0.0, 2.0 }, vector.values);
        try std.testing.expectError(error.ReadOnly, read_only.putVector("docs", "read-only", &.{ 1.0, 1.0 }));
    }
}

test "bound vector store markers roll back with transactions and savepoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-vector-markers-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-vector-markers-store.zova");

    try createVectorStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindVectorStore(store_path);

    var info = (try db.boundVectorStore(std.testing.allocator)).?;
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(isValidStoreId(info.bound_set_id));
    try std.testing.expectEqual(@as(u64, 0), info.vector_epoch);
    try testingExpectScalarText(&db.sqlite_db, "select value from vector_store._zova_meta where key = 'bound_set_id'", info.bound_set_id);
    try testingExpectScalarText(&db.sqlite_db, "select value from vector_store._zova_meta where key = 'vector_epoch'", "0");

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try expectBoundVectorEpoch(&db, 1);
    try db.putVector("docs", "v1", &.{ 1.0, 2.0 });
    try expectBoundVectorEpoch(&db, 2);

    var read_vector = try db.getVector(std.testing.allocator, "docs", "v1");
    read_vector.deinit(std.testing.allocator);
    try expectBoundVectorEpoch(&db, 2);

    try db.exec("create table notes (body text)");
    try db.exec("insert into notes (body) values ('raw user sql')");
    try expectBoundVectorEpoch(&db, 2);

    try db.beginImmediate();
    try db.putVector("docs", "rolled-back", &.{ 3.0, 4.0 });
    try expectBoundVectorEpoch(&db, 3);
    try db.rollback();
    try expectBoundVectorEpoch(&db, 2);
    try std.testing.expectError(error.VectorNotFound, db.getVector(std.testing.allocator, "docs", "rolled-back"));

    try db.beginImmediate();
    try db.savepoint("sp");
    try db.putVector("docs", "savepoint-rolled-back", &.{ 5.0, 6.0 });
    try expectBoundVectorEpoch(&db, 3);
    try db.rollbackToSavepoint("sp");
    try db.releaseSavepoint("sp");
    try expectBoundVectorEpoch(&db, 2);
    try db.commit();
    try expectBoundVectorEpoch(&db, 2);
}

test "operational copies inline bound vector store data into single-file destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-vector-copy-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-vector-copy-vectors.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "bound-vector-copy-backup.zova");

    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "bound-vector-copy-compact.zova");

    var restore_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restore_path = try testingDbPath(&restore_buffer, tmp.sub_path[0..], "bound-vector-copy-restore.zova");

    try createVectorStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindVectorStore(store_path);

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVectors("docs", &.{
        .{ .id = "doc-a", .values = &.{ 1.0, 0.0 } },
        .{ .id = "doc-b", .values = &.{ 0.0, 2.0 } },
    });
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from vector_store._zova_vectors"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.getVector(std.testing.allocator, "stale", "main-only"));

    try db.backupTo(backup_path, .{});
    try db.compactTo(compact_path, .{});
    try restoreBackup(main_path, restore_path, .{});

    const copy_paths = [_][:0]const u8{ backup_path, compact_path, restore_path };
    for (copy_paths) |copy_path| {
        var copy = try Database.open(copy_path);
        defer copy.deinit();

        try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try copy.boundVectorStore(std.testing.allocator));
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&copy, "select count(*) from _zova_vectors"));

        var results = try copy.searchVectors(std.testing.allocator, "docs", &.{ 1.0, 0.0 }, 2);
        defer results.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), results.items.len);
        try std.testing.expectEqualStrings("doc-a", results.items[0].id);
    }
}

test "split vector store moves existing vector storage into a bound store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "split-vector-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "split-vector-store.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "split-vector-backup.zova");

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.exec("create table documents (vector_id text not null, title text not null)");
    try db.exec("insert into documents (vector_id, title) values ('doc-a', 'kept in main')");
    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVectors("docs", &.{
        .{ .id = "doc-a", .values = &.{ 1.0, 0.0 } },
        .{ .id = "doc-b", .values = &.{ 0.0, 2.0 } },
    });
    try db.createGraph("split_vectors");
    try db.putGraphNode(.{ .graph_name = "split_vectors", .node_id = "doc:a", .kind = "document", .target_type = .record, .target_namespace = "documents", .target_ref = "doc-a" });
    try db.putGraphNode(.{ .graph_name = "split_vectors", .node_id = "vector:doc-a", .kind = "embedding", .target_type = .vector, .target_namespace = "docs", .target_ref = "doc-a" });
    try db.putGraphEdge(.{ .graph_name = "split_vectors", .from_node_id = "doc:a", .edge_type = "embedded_as", .to_node_id = "vector:doc-a" });
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from _zova_vectors"));

    const result = try db.splitVectorStore(store_path);
    try std.testing.expectEqualStrings(bound_vector_store_role, result.role);
    try std.testing.expect(result.verified);
    try std.testing.expectEqual(@as(u64, 1), result.copied.vector_collections);
    try std.testing.expectEqual(@as(u64, 2), result.copied.vectors);
    try std.testing.expectEqual(result.copied, result.cleared);
    try std.testing.expect(isValidStoreId(&result.store_id));
    try std.testing.expect(isValidStoreId(&result.bound_set_id));

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from vector_store._zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from vector_store._zova_vectors"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from documents"));

    var results = try db.searchVectors(std.testing.allocator, "docs", &.{ 1.0, 0.0 }, 2);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("doc-a", results.items[0].id);
    try std.testing.expect(try db.hasGraphNode("split_vectors", "vector:doc-a"));
    try std.testing.expect(try db.hasGraphEdge("split_vectors", "doc:a", "embedded_as", "vector:doc-a"));

    const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 1.0, 0.0 });
    defer std.testing.allocator.free(query_blob);
    var distance = try db.prepare("select zova_vector_distance('docs', 'doc-a', ?)");
    defer distance.deinit();
    try distance.bindBlob(1, query_blob);
    try std.testing.expectEqual(sqlite.Step.row, try distance.step());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), distance.columnDouble(0), 0.000001);

    try db.backupTo(backup_path, .{});
    var backup = try Database.open(backup_path);
    defer backup.deinit();
    try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try backup.boundVectorStore(std.testing.allocator));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&backup, "select count(*) from _zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&backup, "select count(*) from _zova_vectors"));
    try std.testing.expect(try backup.hasGraphEdge("split_vectors", "doc:a", "embedded_as", "vector:doc-a"));
}

test "open rejects bound object store id mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-id-main.zova");

    var store_one_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_one_path = try testingDbPath(&store_one_buffer, tmp.sub_path[0..], "bound-id-one.zova");

    var store_two_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_two_path = try testingDbPath(&store_two_buffer, tmp.sub_path[0..], "bound-id-two.zova");

    try createObjectStore(store_one_path);
    try createObjectStore(store_two_path);

    {
        var db = try Database.create(main_path);
        defer db.deinit();
        try db.bindObjectStore(store_one_path);

        var stmt = try db.sqlite_db.prepare(
            \\update _zova_bound_stores
            \\set path = ?
            \\where role = 'object_store' and name = 'default'
        );
        defer stmt.deinit();
        try stmt.bindText(1, store_two_path);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    try std.testing.expectError(error.BoundStoreInvalid, Database.open(main_path));
}

test "failed replacement bind preserves the current attached object store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-bind-failure-main.zova");

    var old_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const old_store_path = try testingDbPath(&old_store_buffer, tmp.sub_path[0..], "bound-bind-failure-old.zova");

    var missing_store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing_store_path = try testingDbPath(&missing_store_buffer, tmp.sub_path[0..], "bound-bind-failure-missing.zova");

    try createObjectStore(old_store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(old_store_path);

    const id = try db.putObject("old store remains attached");
    try std.testing.expectError(error.NotZovaDatabase, db.bindObjectStore(missing_store_path));

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "old store remains attached", object.bytes);

    var info = (try db.boundObjectStore(std.testing.allocator)).?;
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, info.path, "bound-bind-failure-old.zova"));
}

test "bound object store participates in main transactions and savepoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-attach-transaction-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-attach-transaction-objects.zova");

    try createObjectStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(store_path);
    try db.exec(
        \\create table attachments (
        \\  id integer primary key,
        \\  object_id blob not null
        \\)
    );

    try db.beginImmediate();
    const rolled_back = try db.putObject("rolled back object");
    try insertObjectReference(&db, rolled_back);
    try db.rollback();
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, rolled_back));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from attachments"));

    try db.beginImmediate();
    const committed = try db.putObject("committed object");
    try insertObjectReference(&db, committed);
    try db.commit();

    var committed_object = try db.getObject(std.testing.allocator, committed);
    defer committed_object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "committed object", committed_object.bytes);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from attachments"));

    try db.beginImmediate();
    try db.deleteObject(committed);
    try db.rollback();
    try std.testing.expect(try db.hasObject(committed));

    try db.beginImmediate();
    var writer = try db.objectWriter(std.testing.allocator);
    defer writer.deinit();
    try writer.write("writer rolled back with transaction");
    const writer_rolled_back = try writer.finish();
    try db.rollback();
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, writer_rolled_back));

    try db.beginImmediate();
    try db.savepoint("sp_rollback");
    const savepoint_rolled_back = try db.putObject("savepoint rolled back object");
    try db.rollbackToSavepoint("sp_rollback");
    try db.releaseSavepoint("sp_rollback");
    try db.commit();
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, savepoint_rolled_back));

    try db.beginImmediate();
    try db.savepoint("outer_sp");
    try db.savepoint("inner_sp");
    const inner_released = try db.putObject("inner released object");
    try db.releaseSavepoint("inner_sp");
    try db.rollbackToSavepoint("outer_sp");
    try db.releaseSavepoint("outer_sp");
    try db.commit();
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, inner_released));
}

test "object store binding changes are rejected inside active transactions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-transaction-main.zova");

    var store_one_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_one_path = try testingDbPath(&store_one_buffer, tmp.sub_path[0..], "bound-transaction-one.zova");

    var store_two_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_two_path = try testingDbPath(&store_two_buffer, tmp.sub_path[0..], "bound-transaction-two.zova");

    try createObjectStore(store_one_path);
    try createObjectStore(store_two_path);

    var db = try Database.create(main_path);
    defer db.deinit();

    try db.begin();
    try std.testing.expectError(error.ObjectTransactionActive, db.bindObjectStore(store_one_path));
    try db.rollback();

    try db.bindObjectStore(store_one_path);

    try db.savepoint("sp");
    try std.testing.expectError(error.ObjectTransactionActive, db.unbindObjectStore());
    try std.testing.expectError(error.ObjectTransactionActive, db.bindObjectStore(store_two_path));
    try db.releaseSavepoint("sp");
}

test "object store files are not accepted as main databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "role-object-store.zova");

    try createObjectStore(store_path);
    try std.testing.expectError(error.BoundStoreInvalid, Database.open(store_path));
}

test "open rejects current format database missing required object table without mutating it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-object-table.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "4");
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_objects", 0);
    try testingExpectTableCount(&raw, "_zova_chunks", 0);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 0);
}

test "open rejects current format database missing required vector table without mutating it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-vector-table.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "4");
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

        try testingWriteMetadata(&raw, "zova", "4");
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

        try testingWriteMetadata(&raw, "zova", "4");
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

        try testingWriteMetadata(&raw, "zova", "4");
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

        try testingWriteMetadata(&raw, "zova", "4");
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
    try std.testing.expectEqualStrings("4", meta.columnText(0));

    try testingExpectTableCount(&raw, "_zova_objects", 1);
    try testingExpectTableCount(&raw, "_zova_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_vector_collections", 1);
    try testingExpectTableCount(&raw, "_zova_vectors", 1);
    try testingExpectTableCount(&raw, "_zova_graphs", 1);
    try testingExpectTableCount(&raw, "_zova_graph_nodes", 1);
    try testingExpectTableCount(&raw, "_zova_graph_edges", 1);
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

test "notifications deliver after commit and rollback suppresses pending events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "notifications.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var sub = try db.listen("messages");
    defer sub.deinit();

    try db.notify("messages", "outside");
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("messages", note.channel);
        try std.testing.expectEqualStrings("outside", note.payload);
        try std.testing.expectEqual(@as(u64, 1), note.sequence);
        try std.testing.expectEqual(@as(u64, 0), note.dropped_before);
    }
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));

    try db.beginImmediate();
    try db.notify("messages", "committed");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("committed", note.payload);
    }

    try db.beginImmediate();
    try db.exec("select zova_notify('messages', 'sql-committed')");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("sql-committed", note.payload);
    }

    try db.exec("begin immediate");
    try std.testing.expectError(error.SqliteError, db.exec("select zova_notify('messages', 'raw-sql-transaction')"));
    try db.exec("rollback");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));

    try db.beginImmediate();
    try db.notify("messages", "rolled-back");
    try db.rollback();
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
}

test "notification savepoint release and rollback follow sqlite savepoint semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "notification-savepoints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var sub = try db.listen("objects:changed");
    defer sub.deinit();

    try db.beginImmediate();
    try db.notify("objects:changed", "outer");
    try db.savepoint("inner");
    try db.notify("objects:changed", "discarded");
    try db.rollbackToSavepoint("inner");
    try db.notify("objects:changed", "after-rollback-to");
    try db.releaseSavepoint("inner");
    try db.commit();

    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("outer", note.payload);
    }
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("after-rollback-to", note.payload);
    }
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));

    try db.beginImmediate();
    try db.savepoint("inner");
    try db.notify("objects:changed", "released");
    try db.releaseSavepoint("inner");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();

    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("released", note.payload);
    }
}

test "notification queues drop oldest entries and report dropped count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "notification-overflow.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var sub = try db.listen("overflow");
    defer sub.deinit();

    var index: usize = 0;
    while (index < notify_impl.queue_capacity + 1) : (index += 1) {
        var payload_buffer: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buffer, "event-{d}", .{index});
        try db.notify("overflow", payload);
    }

    var first = (try sub.tryReceive(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event-1", first.payload);
    try std.testing.expectEqual(@as(u64, 1), first.dropped_before);
}

test "notifications support multiple listeners read-only handles and per-handle hubs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "notification-listeners.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();

        var first = try db.listen("events");
        defer first.deinit();
        var second = try db.listen("events");
        defer second.deinit();
        var other = try db.listen("other");
        defer other.deinit();
        var closed = try db.listen("events");
        closed.deinit();

        try db.notify("events", "one");

        var first_note = (try first.tryReceive(std.testing.allocator)).?;
        defer first_note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("one", first_note.payload);

        var second_note = (try second.tryReceive(std.testing.allocator)).?;
        defer second_note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("one", second_note.payload);

        try std.testing.expectEqual(@as(?Notification, null), try other.tryReceive(std.testing.allocator));
    }

    {
        var writer = try Database.open(db_path);
        defer writer.deinit();
        var reader = try Database.open(db_path);
        defer reader.deinit();

        var writer_sub = try writer.listen("local");
        defer writer_sub.deinit();
        var reader_sub = try reader.listen("local");
        defer reader_sub.deinit();

        try writer.notify("local", "writer-only");
        var note = (try writer_sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("writer-only", note.payload);
        try std.testing.expectEqual(@as(?Notification, null), try reader_sub.tryReceive(std.testing.allocator));
    }

    {
        var readonly = try Database.openWithOptions(db_path, .{ .read_only = true });
        defer readonly.deinit();
        var sub = try readonly.listen("readonly");
        defer sub.deinit();
        try readonly.notify("readonly", "local");
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("local", note.payload);
    }
}

test "notification validation rejects invalid channels payloads and SQL notify inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "notification-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var sub = try db.listen("messages");
    defer sub.deinit();

    const invalid_channel_bytes = [_]u8{ 0xc3, 0xa9 };
    const invalid_channels = [_][]const u8{
        "",
        "bad channel",
        "_zova_private",
        invalid_channel_bytes[0..],
    };
    for (invalid_channels) |channel| {
        try std.testing.expectError(error.InvalidArgument, db.listen(channel));
        try std.testing.expectError(error.InvalidArgument, db.notify(channel, "payload"));
    }

    var long_channel: [notify_impl.max_channel_len + 1]u8 = undefined;
    @memset(long_channel[0..], 'a');
    try std.testing.expectError(error.InvalidArgument, db.listen(long_channel[0..]));
    try std.testing.expectError(error.InvalidArgument, db.notify(long_channel[0..], "payload"));

    const invalid_payload = [_]u8{0xff};
    try std.testing.expectError(error.InvalidArgument, db.notify("messages", invalid_payload[0..]));

    try std.testing.expectError(error.SqliteError, db.exec("select zova_notify('_zova_private', 'payload')"));
    try std.testing.expectError(error.SqliteError, db.exec("select zova_notify('messages', cast(x'ff' as text))"));
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
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
