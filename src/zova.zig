//! Zova-owned database identity layer.
//!
//! This module is the first layer above the plain SQLite wrapper. A database
//! enters Zova mode by using a `.zova` file path through `zova.Database`.
//! The file is still a SQLite database underneath, but Zova validates private
//! metadata before treating it as a Zova-owned database.
//!
//! Zova 1.x preserves the explicit migration path documented in
//! `docs/storage-compatibility.md`. The current storage format is version `12`:
//! `_zova_meta.format_version = '12'` plus
//! the required private object, vector, graph, key-value, and extension
//! registry schemas.
//! `Database.open` is intentionally non-mutating: it validates the file and
//! rejects migration-required, future, unsupported legacy, incomplete, or
//! invalid private schemas instead of repairing or migrating them.
//!
//! Existing SQLite files can be converted into new `.zova` files with
//! `convertSqliteToZova`. Conversion copies the source with SQLite's backup
//! API, initializes Zova metadata in the destination, and never mutates the
//! source file.
//!
//! Zova object APIs use deterministic SHA-256 object identity and private
//! FastCDC chunking by default. `putObject` stores whole caller bytes as content-addressed
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

const extension_impl = @import("extension.zig");

const graph_impl = @import("graph.zig");

const graph_sql = @import("graph_sql.zig");

const kv_impl = @import("kv.zig");

const notify_impl = @import("notify.zig");

const object_impl = @import("object.zig");

const sqlite = @import("sqlite.zig");

const statement_cache = @import("statement_cache.zig");

const graph_walk_scratch = @import("graph_walk_scratch.zig");

const vector_impl = @import("vector.zig");

const vector_sql = @import("vector_sql.zig");

const version = @import("version.zig");

const zova_error = @import("zova_error.zig");

const metadata_table = @import("database/types.zig").metadata_table;

const objects_table = @import("database/types.zig").objects_table;

const chunks_table = @import("database/types.zig").chunks_table;

const object_chunks_table = @import("database/types.zig").object_chunks_table;

const kv_table = @import("database/types.zig").kv_table;

const bound_stores_table = @import("database/types.zig").bound_stores_table;

const magic_value = @import("database/types.zig").magic_value;

const format_version = @import("database/types.zig").format_version;

pub const minimum_migratable_format = @import("database/types.zig").minimum_migratable_format;

/// Compatibility class assigned to a Zova storage format version.
///
/// `migratable` marks formats this release can migrate explicitly into the
/// current format; `unsupported_legacy` marks formats older than the earliest
/// migratable format, and `unsupported_future` marks formats newer than this
/// release.
pub const FormatCompatibility = @import("database/types.zig").FormatCompatibility;

const parseFormatVersion = @import("database/format.zig").parseFormatVersion;

const classifyFormatVersion = @import("database/format.zig").classifyFormatVersion;

/// Non-mutating classification result for one Zova database file.
///
/// `format_version` is the strictly parsed `_zova_meta.format_version` value
/// and `compatibility` is how this release treats that format.
pub const DatabaseFormatInfo = @import("database/types.zig").DatabaseFormatInfo;

/// Probe one database's storage format without mutation.
///
/// The probe opens the file with a raw read-only SQLite connection, reads only
/// the historical identity metadata required for classification, and never
/// attaches bound stores, repairs schemas, or writes. Recognized but
/// incompatible databases probe successfully; malformed or non-Zova inputs are
/// rejected exactly as `Database.open` rejects them.
pub const probeDatabaseFormat = @import("database/migration.zig").probeDatabaseFormat;

/// Read and classify `_zova_meta.format_version` using the same strict parsing
/// as `probeDatabaseFormat`, so open and probe cannot disagree.
const readFormatClassification = @import("database/format.zig").readFormatClassification;

/// One registered storage-format migration.
///
/// Steps are keyed by exact `(from, to)` versions and must be adjacent:
/// `to == from + 1`. There is deliberately no catch-all upgrader and no way to
/// skip versions; migrating across several formats applies one registered step
/// at a time.
const MigrationStep = @import("database/types.zig").MigrationStep;

pub const migration_steps = @import("database/migration.zig").migration_steps;

pub const findMigrationStep = @import("database/migration.zig").findMigrationStep;

const migrateFormat9To10 = @import("database/migration.zig").migrateFormat9To10;

const migrateFormat10To11 = @import("database/migration.zig").migrateFormat10To11;

/// Role-aware validation of one Zova file at an exact expected storage
/// format, structurally equivalent to the existing open-time and attach-time
/// validators while intentionally omitting only requirements introduced by
/// later formats (currently the format-10 private key-value schema that
/// migration itself adds).
///
/// Used by migration preflight so a forged or malformed file — wrong or
/// missing magic, missing metadata, malformed required tables, a store role
/// without its identity or schema, or a main with a malformed bound-store
/// table — can never be transformed. Object and KV validation is selected by
/// the exact source format so every adjacent step validates the schema that
/// actually existed at that version.
const validateMigrationSourceSchema = @import("database/migration.zig").validateMigrationSourceSchema;

/// Apply the single registered adjacent migration step for this database's
/// storage format and return the new version.
///
/// The exact expected source identity, version, role, and schema are validated
/// after `BEGIN IMMEDIATE` so validation and mutation share one stable
/// transaction. Schema work happens first, `_zova_meta.format_version` is
/// updated as the final statement, and every failure path rolls back
/// completely so the version never advances on SQL, allocation, constraint,
/// or validation failure.
pub const runMigrationStep = @import("database/migration.zig").runMigrationStep;

const runMigrationsToCurrent = @import("database/migration.zig").runMigrationsToCurrent;

const validateForeignKeys = @import("database/migration.zig").validateForeignKeys;

const bound_object_store_role = @import("database/types.zig").bound_object_store_role;

const bound_vector_store_role = @import("database/types.zig").bound_vector_store_role;

const bound_graph_store_role = @import("database/types.zig").bound_graph_store_role;

const batch_mutation_savepoint = @import("database/types.zig").batch_mutation_savepoint;

const BatchMutationScope = @import("database/types.zig").BatchMutationScope;

const bound_object_store_name = @import("database/types.zig").bound_object_store_name;

const bound_vector_store_name = @import("database/types.zig").bound_vector_store_name;

const bound_graph_store_name = @import("database/types.zig").bound_graph_store_name;

const bound_object_store_schema_name = @import("database/types.zig").bound_object_store_schema_name;

const bound_vector_store_schema_name = @import("database/types.zig").bound_vector_store_schema_name;

const bound_graph_store_schema_name = @import("database/types.zig").bound_graph_store_schema_name;

const bundled_extensions = @import("database/types.zig").bundled_extensions;

const bound_stores_schema_sql = @import("database/types.zig").bound_stores_schema_sql;

pub const ObjectId = @import("database/types.zig").ObjectId;

pub const ObjectChunkId = @import("database/types.zig").ObjectChunkId;

pub const ObjectChunk = @import("database/types.zig").ObjectChunk;

pub const ObjectManifest = @import("database/types.zig").ObjectManifest;

pub const ObjectChunkData = @import("database/types.zig").ObjectChunkData;

pub const Object = @import("database/types.zig").Object;

/// Physical object chunking profile. Existing methods use `.deduplication`;
/// `.streaming` stores fixed 1 MiB chunks for large sequential workloads.
pub const ObjectStorageProfile = @import("database/types.zig").ObjectStorageProfile;

pub const ObjectPutOptions = @import("database/types.zig").ObjectPutOptions;

pub const ObjectReaderError = @import("database/types.zig").ObjectReaderError;

pub const KvPutEntry = @import("database/types.zig").KvPutEntry;

pub const ObjectReader = struct {
    inner: object_impl.ObjectReader,

    pub fn read(self: *ObjectReader, buffer: []u8) object_impl.ObjectReaderError!usize {
        return self.inner.read(buffer);
    }

    pub fn deinit(self: *ObjectReader) void {
        self.inner.deinit();
    }
};

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

pub const Error = @import("database/types.zig").Error;

/// Options applied only while creating a fresh Zova database.
pub const CreateOptions = @import("database/types.zig").CreateOptions;

pub const max_vector_dimensions = @import("database/types.zig").max_vector_dimensions;

pub const VectorMetric = @import("database/types.zig").VectorMetric;

pub const VectorElementType = @import("database/types.zig").VectorElementType;

pub const VectorCollectionOptions = @import("database/types.zig").VectorCollectionOptions;

pub const VectorCollectionInfo = @import("database/types.zig").VectorCollectionInfo;

pub const VectorCollectionList = @import("database/types.zig").VectorCollectionList;

pub const VectorInput = @import("database/types.zig").VectorInput;

pub const VectorValuesConst = @import("database/types.zig").VectorValuesConst;

pub const VectorValuesOwned = @import("database/types.zig").VectorValuesOwned;

pub const Vector = @import("database/types.zig").Vector;

pub const VectorSearchResult = @import("database/types.zig").VectorSearchResult;

pub const VectorSearchResults = @import("database/types.zig").VectorSearchResults;

pub const MultiI8CosineSearchMode = @import("database/types.zig").MultiI8CosineSearchMode;

pub const MultiI8CosineSearchOptions = @import("database/types.zig").MultiI8CosineSearchOptions;

pub const Notification = @import("database/types.zig").Notification;

pub const NotificationSubscription = @import("database/types.zig").NotificationSubscription;

pub const GraphTargetType = @import("database/types.zig").GraphTargetType;

pub const GraphInfo = @import("database/types.zig").GraphInfo;

pub const GraphList = @import("database/types.zig").GraphList;

pub const GraphNodeInput = @import("database/types.zig").GraphNodeInput;

pub const FreshGraphNodeInput = @import("database/types.zig").FreshGraphNodeInput;

pub const GraphNode = @import("database/types.zig").GraphNode;

pub const GraphEdgeInput = @import("database/types.zig").GraphEdgeInput;

pub const FreshGraphEdgeInput = @import("database/types.zig").FreshGraphEdgeInput;

pub const FreshGraphBuildProfile = @import("database/types.zig").FreshGraphBuildProfile;

pub const GraphEdgePayloadReplacement = @import("database/types.zig").GraphEdgePayloadReplacement;

pub const GraphEdgePayloadLookup = @import("database/types.zig").GraphEdgePayloadLookup;

pub const GraphEdgePayloadLookupList = @import("database/types.zig").GraphEdgePayloadLookupList;

pub const GraphEdge = @import("database/types.zig").GraphEdge;

pub const GraphNeighborDirection = @import("database/types.zig").GraphNeighborDirection;

pub const GraphNeighborsOptions = @import("database/types.zig").GraphNeighborsOptions;

pub const GraphDegreeOptions = @import("database/types.zig").GraphDegreeOptions;

pub const GraphNeighbor = @import("database/types.zig").GraphNeighbor;

pub const GraphNeighborList = @import("database/types.zig").GraphNeighborList;

pub const GraphKeyedNeighbor = @import("database/types.zig").GraphKeyedNeighbor;

pub const GraphKeyedNeighborList = @import("database/types.zig").GraphKeyedNeighborList;

pub const GraphKeyedNodeLookup = @import("database/types.zig").GraphKeyedNodeLookup;

pub const GraphKeyedNodeLookupList = @import("database/types.zig").GraphKeyedNodeLookupList;

pub const GraphKeyedEdgeLookup = @import("database/types.zig").GraphKeyedEdgeLookup;

pub const GraphKeyedEdgeLookupList = @import("database/types.zig").GraphKeyedEdgeLookupList;

pub const GraphScanCursor = @import("database/types.zig").GraphScanCursor;

pub const GraphScanOptions = @import("database/types.zig").GraphScanOptions;

pub const GraphScanNode = @import("database/types.zig").GraphScanNode;

pub const GraphScanEdge = @import("database/types.zig").GraphScanEdge;

pub const GraphScanResult = @import("database/types.zig").GraphScanResult;

pub const GraphWalkOptions = @import("database/types.zig").GraphWalkOptions;

pub const GraphWalkDirectionOptions = @import("database/types.zig").GraphWalkDirectionOptions;

pub const GraphWalkScanProfile = @import("database/types.zig").GraphWalkScanProfile;

pub const GraphWalkItem = @import("database/types.zig").GraphWalkItem;

pub const GraphWalk = @import("database/types.zig").GraphWalk;

pub const Extension = @import("database/types.zig").Extension;

pub const ExtensionRegistry = @import("database/types.zig").ExtensionRegistry;

pub const ExtensionManifest = @import("database/types.zig").ExtensionManifest;

pub const ExtensionInfo = @import("database/types.zig").ExtensionInfo;

pub const ExtensionList = @import("database/types.zig").ExtensionList;

pub const ExtensionSalvageMode = @import("database/types.zig").ExtensionSalvageMode;

pub const ExtensionSalvageContext = @import("database/types.zig").ExtensionSalvageContext;

pub const ExtensionSalvageResult = @import("database/types.zig").ExtensionSalvageResult;

pub const DynamicExtensionSet = @import("database/types.zig").DynamicExtensionSet;

pub const DynamicExtensionTrustRecord = @import("database/types.zig").DynamicExtensionTrustRecord;

pub const DynamicExtensionTrustedList = @import("database/types.zig").DynamicExtensionTrustedList;

pub const DynamicExtensionTrustStoreOptions = @import("database/types.zig").DynamicExtensionTrustStoreOptions;

pub const DynamicExtensionBundleInfo = @import("database/types.zig").DynamicExtensionBundleInfo;

pub const DynamicExtensionOwnedRegistry = @import("database/types.zig").DynamicExtensionOwnedRegistry;

pub const extension_dynamic = @import("database/types.zig").extension_dynamic;

/// Information about the optional object store bound to a main `.zova` file.
///
/// Single-file Zova remains the default. This struct is returned only when a
/// main database has explicitly been bound to one external object store.
pub const BoundObjectStoreInfo = @import("database/types.zig").BoundObjectStoreInfo;

const BoundObjectStore = @import("database/types.zig").BoundObjectStore;

pub const SplitObjectStoreCounts = @import("database/types.zig").SplitObjectStoreCounts;

pub const SplitObjectStoreResult = @import("database/types.zig").SplitObjectStoreResult;

/// Information about the optional vector store bound to a main `.zova` file.
///
/// Single-file Zova remains the default. This struct is returned only when a
/// main database has explicitly been bound to one external vector store.
pub const BoundVectorStoreInfo = @import("database/types.zig").BoundVectorStoreInfo;

const BoundVectorStore = @import("database/types.zig").BoundVectorStore;

pub const SplitVectorStoreCounts = @import("database/types.zig").SplitVectorStoreCounts;

pub const SplitVectorStoreResult = @import("database/types.zig").SplitVectorStoreResult;

/// Information about the optional graph store bound to a main `.zova` file.
pub const BoundGraphStoreInfo = @import("database/types.zig").BoundGraphStoreInfo;

const BoundGraphStore = @import("database/types.zig").BoundGraphStore;

pub const SplitGraphStoreCounts = @import("database/types.zig").SplitGraphStoreCounts;

pub const SplitGraphStoreResult = @import("database/types.zig").SplitGraphStoreResult;

/// Options for opening an existing `.zova` database.
pub const OpenOptions = @import("database/types.zig").OpenOptions;

const ExtensionOpenMode = @import("database/types.zig").ExtensionOpenMode;

/// Options for `Database.backupTo`.
pub const BackupOptions = @import("database/types.zig").BackupOptions;

/// Options for `Database.compactTo`.
pub const CompactOptions = @import("database/types.zig").CompactOptions;

/// Options for `restoreBackup`.
pub const RestoreOptions = @import("database/types.zig").RestoreOptions;

/// Options for `migrateDatabase`.
pub const MigrateOptions = @import("database/types.zig").MigrateOptions;

/// Create a standalone object-store `.zova` file.
///
/// This is opt-in storage for a main database that later calls
/// `Database.bindObjectStore`. Normal `.zova` files remain single-file by
/// default, and object-store files are rejected by `Database.open` as main
/// databases.
pub const createObjectStore = @import("database/lifecycle.zig").createObjectStore;

/// Create a standalone vector-store `.zova` file.
///
/// This is opt-in storage for a main database that later calls
/// `Database.bindVectorStore`. Normal `.zova` files remain single-file by
/// default, and vector-store files are rejected by `Database.open` as main
/// databases.
pub const createVectorStore = @import("database/lifecycle.zig").createVectorStore;

/// Create a standalone graph-store `.zova` file.
pub const createGraphStore = @import("database/lifecycle.zig").createGraphStore;

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
    try restoreBackupWithExtensions(source_path, dest_path, options, bundledExtensionRegistry());
}

/// Open any Zova database file for read-only logical inspection.
///
/// Unlike `Database.open`, this does not enforce the current storage format,
/// role, or schema: the runtime SQL helpers are registered so vector, graph,
/// and notification APIs work against migratable format-9 sources during
/// migration verification. The handle is always read-only.
pub fn openForLogicalInspection(path: [:0]const u8) Error!Database {
    if (!isZovaPath(path)) return error.NotZovaPath;
    try ensureSourcePathExists(path);

    var raw = try sqlite.Database.openWithFlags(path, .read_only);
    errdefer raw.deinit();
    try enableForeignKeys(&raw);
    try vector_sql.register(&raw);
    try graph_sql.register(&raw);
    // Installed-extension SQL is registered so bundled behavior (for example
    // trigram functions) can be exercised against migratable sources.
    try extension_impl.registerSqlForInstalled(&raw, bundledExtensionRegistry());
    const notifications = try initNotifications(&raw);
    errdefer deinitNotifications(notifications);
    return .{ .sqlite_db = raw, .notifications = notifications };
}

/// Restore a backup `.zova` file with process-registered extension code.
pub fn restoreBackupWithExtensions(source_path: [:0]const u8, dest_path: [:0]const u8, options: RestoreOptions, registry: ExtensionRegistry) Error!void {
    if (!isZovaPath(source_path)) return error.NotZovaPath;

    var source = try Database.openWithOptionsAndExtensions(source_path, .{ .read_only = true }, registry);
    defer source.deinit();

    try source.backupTo(dest_path, .{ .verify = options.verify });
}

/// Restore a backup `.zova` file into a new volatile in-memory database.
///
/// This reuses the same SQLite online backup guarantees as file-backed
/// restore. The returned database owns the source's schema and data entirely
/// in memory and never creates database, WAL, or journal files.
pub fn restoreBackupToMemory(source_path: [:0]const u8, options: RestoreOptions) Error!Database {
    return restoreBackupToMemoryWithExtensions(source_path, options, bundledExtensionRegistry());
}

/// Restore a backup `.zova` file into a new in-memory database with
/// process-registered extension code.
pub fn restoreBackupToMemoryWithExtensions(source_path: [:0]const u8, options: RestoreOptions, registry: ExtensionRegistry) Error!Database {
    if (!isZovaPath(source_path)) return error.NotZovaPath;

    var source = try Database.openWithOptionsAndExtensions(source_path, .{ .read_only = true }, registry);
    defer source.deinit();

    var memory = try source.restoreIntoMemory(registry);
    if (options.verify) {
        errdefer memory.deinit();
        try verifyCurrentDatabase(&memory);
    }
    return memory;
}

/// Explicitly migrate one `.zova` database and every bound store from its
/// released storage format to the current format.
///
/// Migration is offline and copy-forward: the source main and store files are
/// never modified, all work happens in same-directory staging files, migrated
/// stores are published before the destination main database, and the
/// destination main is published last as the commit marker. Any ordinary
/// failure removes every file the attempt created. The caller must keep the
/// source set offline; the source main is locked for the duration of the copy.
pub fn migrateDatabase(source_path: [:0]const u8, destination_path: [:0]const u8, options: MigrateOptions) Error!void {
    return migrateDatabaseWithExtensions(source_path, destination_path, options, bundledExtensionRegistry());
}

/// `migrateDatabase` with process-registered extension code. The registry
/// participates in staged-set verification exactly as it does for open.
pub fn migrateDatabaseWithExtensions(
    source_path: [:0]const u8,
    destination_path: [:0]const u8,
    options: MigrateOptions,
    registry: ExtensionRegistry,
) Error!void {
    return migrateDatabaseInternal(std.heap.c_allocator, source_path, destination_path, options, registry, null);
}

/// Test-only fault points covering every phase boundary required by the
/// migration safety model. Production callers always pass `null`. Module-pub
/// for the test suite but deliberately absent from the package exports.
pub const MigrateFaultPoint = enum {
    after_destination_reservation,
    after_main_copy,
    after_main_migration,
    after_store_copy,
    after_store_migration,
    after_validation,
    after_store_publication,
    before_main_publication,
    after_main_publication,
};

pub const MigrateFaultHook = *const fn (point: MigrateFaultPoint) Error!void;

pub fn migrateDatabaseInternal(
    allocator: std.mem.Allocator,
    source_path: [:0]const u8,
    destination_path: [:0]const u8,
    options: MigrateOptions,
    registry: ExtensionRegistry,
    fault_hook: ?MigrateFaultHook,
) Error!void {
    if (!isZovaPath(source_path)) return error.NotZovaPath;
    if (!isZovaPath(destination_path)) return error.NotZovaPath;
    try ensureSourcePathExists(source_path);

    // Fast classification before touching destinations so unsupported sources
    // are rejected without creating anything.
    var source_format_version: u32 = undefined;
    {
        var probe = try sqlite.Database.openWithFlags(source_path, .read_only);
        defer probe.deinit();
        const early = try readFormatClassification(&probe);
        source_format_version = early.format_version;
        switch (early.compatibility) {
            .migratable => {},
            .current => return error.NoMigrationPath,
            .unsupported_legacy => return error.UnsupportedLegacyFormat,
            .unsupported_future => return error.UnsupportedFutureFormat,
        }
    }

    // Everything allocated from here on is owned by the single guarded
    // cleanup below and flows through the caller-supplied allocator so
    // allocation-fault injection can exercise every path.
    var bindings: [3]MigrateBindingPlan = undefined;
    var binding_count: usize = 0;
    var committed = false;
    var main_final: ?[:0]u8 = null;
    var main_staging: ?[:0]u8 = null;
    var publication: ?@import("database/migration_publication.zig").Publication = null;
    defer if (publication) |*p| p.deinit();
    errdefer if (!committed) {
        if (main_staging) |staging| {
            allocator.free(staging);
            main_staging = null;
        }
        for (bindings[0..binding_count]) |*binding| {
            binding.deinit(allocator);
        }
        if (main_final) |final| allocator.free(final);
    };

    // Lock the source main database before collecting the binding plan so no
    // writer can unbind or rebind a store between planning and copying:
    // concurrent writers receive Busy/Locked instead of a torn snapshot. The
    // lock lives on its own connection so the backup reads below never
    // contend with it.
    //
    // Destination reservation happens under the same lock; existing
    // destinations are still rejected before anything is copied.
    {
        var lock = try sqlite.Database.open(source_path);
        defer lock.deinit();
        try lock.beginImmediate();
        defer lock.rollback() catch {};

        // Plan from the locked stable state.
        try collectMigrationBindings(allocator, source_path, &bindings, &binding_count);

        main_final = try allocator.dupeSentinel(u8, destination_path, 0);
        try ensureDestinationZovaPathAvailable(main_final.?);
        publication = try @import("database/migration_publication.zig").Publication.init(allocator, destination_path);
        try publication.?.reserve(0, main_final.?);
        for (bindings[0..binding_count], 1..) |*binding, index| {
            const sibling = try migrationSiblingPath(allocator, destination_path, binding.suffix);
            allocator.free(binding.final_path);
            binding.final_path = sibling;
            try publication.?.reserve(index, binding.final_path);
        }
        if (fault_hook) |hook| try hook(.after_destination_reservation);

        // Preflight the whole set under the lock: exact source schema plus
        // every recorded store's identity, role, epoch, schema, and
        // cross-checked IDs.
        var snapshot = try sqlite.Database.openWithFlags(source_path, .read_only);
        defer snapshot.deinit();
        var source_format_buffer: [16]u8 = undefined;
        const source_format_text = std.fmt.bufPrint(
            &source_format_buffer,
            "{d}",
            .{source_format_version},
        ) catch unreachable;
        try validateMigrationSourceSchema(&snapshot, source_format_text);
        for (bindings[0..binding_count]) |*binding| {
            try validateMigrationStoreBinding(binding, source_format_text);
        }

        // Stage, copy-forward, and transform every member in the exclusively
        // owned recovery directory. Copy and migration are separate phases
        // with their own fault boundaries.
        main_staging = try publication.?.stage(0);
        {
            var main_copy_source = try sqlite.Database.openWithFlags(source_path, .read_only);
            defer main_copy_source.deinit();
            try copyForwardMember(&main_copy_source, main_staging.?);
            if (fault_hook) |hook| try hook(.after_main_copy);
        }
        {
            var staged = try sqlite.Database.open(main_staging.?);
            defer staged.deinit();
            try runMigrationsToCurrent(&staged);
            if (fault_hook) |hook| try hook(.after_main_migration);
        }
        for (bindings[0..binding_count], 1..) |*binding, index| {
            const staged_path = try publication.?.stage(index);
            allocator.free(binding.staging_path);
            binding.staging_path = staged_path;
            binding.staged = true;
            var store_source = try sqlite.Database.openWithFlags(binding.store_path, .read_only);
            defer store_source.deinit();
            try copyForwardMember(&store_source, binding.staging_path);
            if (fault_hook) |hook| try hook(.after_store_copy);
            var staged = try sqlite.Database.open(binding.staging_path);
            defer staged.deinit();
            try runMigrationsToCurrent(&staged);
            if (fault_hook) |hook| try hook(.after_store_migration);
        }
    }

    // Verify the staged set with bindings pointing at staging paths, then
    // rewrite only the destination binding paths for publication.
    try rebindMigrationSet(main_staging.?, bindings[0..binding_count], .staging);
    if (options.verify) {
        try verifyOperationalCopy(main_staging.?, registry);
        if (fault_hook) |hook| try hook(.after_validation);
    }
    try rebindMigrationSet(main_staging.?, bindings[0..binding_count], .final);

    // The source lock was released when staging completed. Publish stores
    // first and the main database last as the commit marker.
    for (0..binding_count) |index| {
        try publication.?.publish(index + 1);
        if (fault_hook) |hook| try hook(.after_store_publication);
    }

    if (fault_hook) |hook| try hook(.before_main_publication);
    try publication.?.publish(0);
    publication.?.committed = true;

    committed = true;
    allocator.free(main_final.?);
    if (main_staging) |staging| allocator.free(staging);
    for (bindings[0..binding_count]) |*binding| binding.deinit(allocator);
    binding_count = 0;
    if (fault_hook) |hook| try hook(.after_main_publication);
}

/// One planned bound-store member of a migration set.
///
/// `role` and `suffix` are static strings; the other five fields are owned.
pub const MigrateBindingPlan = @import("database/migration.zig").MigrateBindingPlan;

/// Collect the main database's bound-store rows, if any. Single-file mains
/// produce zero bindings.
pub const collectMigrationBindings = @import("database/migration.zig").collectMigrationBindings;

/// Validate one recorded bound store before any copying: the file must exist,
/// carry a genuine migratable format-9 schema under its role, and its stored
/// identity must match the main database's binding row exactly.
const validateMigrationStoreBinding = @import("database/migration.zig").validateMigrationStoreBinding;

/// Copy one source member forward into a fresh staging file. Migration of the
/// staged copy is a separate step so each phase has its own fault boundary.
const copyForwardMember = @import("database/migration.zig").copyForwardMember;

const MigrateRebindTarget = @import("database/migration.zig").MigrateRebindTarget;

/// Rewrite only the destination binding paths in a staged main database.
const rebindMigrationSet = @import("database/migration.zig").rebindMigrationSet;

/// Derive a destination sibling name `<stem>.<suffix>.zova` from a
/// destination whose name ends in `.zova`.
const migrationSiblingPath = @import("database/migration.zig").migrationSiblingPath;

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

pub fn bundledExtensionRegistry() ExtensionRegistry {
    return ExtensionRegistry.init(&bundled_extensions);
}

pub fn salvageInstalledExtensions(
    allocator: std.mem.Allocator,
    source: *sqlite.Database,
    destination: ?*sqlite.Database,
    registry: ExtensionRegistry,
    mode: ExtensionSalvageMode,
) Error!ExtensionSalvageResult {
    return extension_impl.salvageInstalled(allocator, source, destination, registry, mode);
}

const validateCreateOptions = @import("database/lifecycle.zig").validateCreateOptions;

const applyCreateOptions = @import("database/lifecycle.zig").applyCreateOptions;

/// Owns one initialized `.zova` database.
///
/// A Zova database is physically SQLite, but it must use the `.zova` extension
/// and contain valid `_zova_meta` metadata before `open` accepts it.
/// Use documented methods; accessible fields and this struct's layout are
/// implementation details, not stable application APIs. Do not mutate caches,
/// attachment state, notifications, or registry storage directly.
/// The accessible SQLite connection is an advanced escape hatch: do not close
/// or replace it, modify private storage, or bypass Zova bookkeeping. See
/// API_STABILITY.md for the raw-access and maintenance-mode boundaries.
pub const Database = struct {
    sqlite_db: sqlite.Database,
    notifications: *notify_impl.Hub,
    bound_object_store: ?BoundObjectStore = null,
    bound_vector_store: ?BoundVectorStore = null,
    bound_graph_store: ?BoundGraphStore = null,
    main_graph_edge_types: graph_impl.GraphEdgeTypeCache = .{},
    bound_graph_edge_types: graph_impl.GraphEdgeTypeCache = .{},
    kv_statements: kv_impl.StatementCache = .{},
    idle_statements: statement_cache.Cache = .{},
    graph_walk_scratch: graph_walk_scratch.GraphWalkScratch = graph_walk_scratch.GraphWalkScratch.init(),
    extension_registry: ExtensionRegistry = ExtensionRegistry.empty(),

    /// Create a new initialized `.zova` database.
    ///
    /// This never overwrites an existing file. The file is initialized with the
    /// private `_zova_meta` table, format version `12`, and the required
    /// object, vector, graph, key-value, and extension registry schemas.
    pub fn create(path: [:0]const u8) Error!Database {
        return createWithOptionsAndExtensions(path, .{}, bundledExtensionRegistry());
    }

    /// Create a new initialized `.zova` database with fresh-file options.
    pub fn createWithOptions(path: [:0]const u8, options: CreateOptions) Error!Database {
        return createWithOptionsAndExtensions(path, options, bundledExtensionRegistry());
    }

    /// Create a new initialized `.zova` database with process-registered
    /// extension code available for later extension lifecycle calls.
    pub fn createWithExtensions(path: [:0]const u8, registry: ExtensionRegistry) Error!Database {
        return createWithOptionsAndExtensions(path, .{}, registry);
    }

    /// Create a new initialized `.zova` database with fresh-file options and
    /// process-registered extension code.
    ///
    /// A path of `":memory:"` creates a fully initialized volatile in-memory
    /// database instead of a file-backed one. No database, WAL, or journal
    /// file is created, and the database is reclaimed when its lifetime ends.
    /// Prefer the idiomatic `createMemory` family for that mode.
    pub fn createWithOptionsAndExtensions(path: [:0]const u8, options: CreateOptions, registry: ExtensionRegistry) Error!Database {
        try registry.validate();
        try validateCreateOptions(options);
        const memory = isMemoryPath(path);
        if (!memory) {
            if (!isZovaPath(path)) return error.NotZovaPath;

            if (@import("database/paths.zig").wasm_opfs) {
                try @import("database/paths.zig").reserveDestinationZovaFile(path);
            } else {
                const io = defaultIo();
                var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
                    error.PathAlreadyExists => return error.DestinationExists,
                    else => return error.CantOpen,
                };
                file.close(io);

                errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
            }
        }

        var raw = try sqlite.Database.open(path);
        errdefer raw.deinit();

        try applyCreateOptions(&raw, options);
        try enableForeignKeys(&raw);
        try initializeZovaSchema(&raw);
        try vector_sql.register(&raw);
        try graph_sql.register(&raw);
        try extension_impl.registerSqlForInstalled(&raw, registry);
        const notifications = try initNotifications(&raw);
        errdefer deinitNotifications(notifications);
        return .{ .sqlite_db = raw, .notifications = notifications, .extension_registry = registry };
    }

    /// Create a new initialized volatile in-memory database.
    ///
    /// The database lives entirely in memory and is initialized with the same
    /// private `_zova_meta` metadata, format version, and object, vector, graph,
    /// and extension registry schemas as a file-backed `.zova` database. It
    /// never creates database, WAL, or journal files, is isolated from every
    /// other in-memory database, and is reclaimed when its lifetime ends. All
    /// SQL, object, vector, graph, extension, transaction, and diagnostic APIs
    /// behave exactly as they do for a file-backed database.
    pub fn createMemory() Error!Database {
        return createMemoryWithExtensions(bundledExtensionRegistry());
    }

    /// Create a new initialized in-memory database with process-registered
    /// extension code available for later extension lifecycle calls.
    pub fn createMemoryWithExtensions(registry: ExtensionRegistry) Error!Database {
        return createMemoryWithOptionsAndExtensions(.{}, registry);
    }

    /// Create a new initialized in-memory database with fresh-file options and
    /// process-registered extension code.
    pub fn createMemoryWithOptionsAndExtensions(options: CreateOptions, registry: ExtensionRegistry) Error!Database {
        return createWithOptionsAndExtensions(":memory:", options, registry);
    }

    /// Open an existing initialized `.zova` database.
    ///
    /// The `.zova` extension is the public opt-in boundary. Metadata is the
    /// actual validity check, so a renamed SQLite file is rejected. Open never
    /// repairs, migrates, or lazily initializes missing private schema.
    pub fn open(path: [:0]const u8) Error!Database {
        return openWithOptions(path, .{});
    }

    /// Open an existing initialized `.zova` database with process-registered
    /// extension code.
    pub fn openWithExtensions(path: [:0]const u8, registry: ExtensionRegistry) Error!Database {
        return openWithOptionsAndExtensions(path, .{}, registry);
    }

    /// Open an existing initialized `.zova` database with explicit options.
    ///
    /// Read-only opens still validate Zova metadata and register connection-
    /// local SQL vector and graph helpers, but they never write private schema
    /// or run migrations. Mutating SQL/object/vector/graph APIs fail through
    /// SQLite's normal read-only error path.
    pub fn openWithOptions(path: [:0]const u8, options: OpenOptions) Error!Database {
        return openWithOptionsAndExtensions(path, options, bundledExtensionRegistry());
    }

    /// Open an existing initialized `.zova` database with explicit options and
    /// process-registered extension code.
    pub fn openWithOptionsAndExtensions(path: [:0]const u8, options: OpenOptions, registry: ExtensionRegistry) Error!Database {
        return openInternal(path, options, true, registry, .enforce);
    }

    /// Open a database for diagnostic extension metadata inspection.
    ///
    /// This validates core Zova schema and extension registry shape, but does
    /// not require installed extension code, run extension checks, or register
    /// extension SQL hooks. It is intended for `doctor`, `check --deep`, and
    /// `zova extension list/info` fallback paths.
    /// Maintenance-only mode; do not assume normal extension initialization.
    pub fn openForExtensionInspection(path: [:0]const u8, options: OpenOptions) Error!Database {
        return openForExtensionInspectionWithExtensions(path, options, ExtensionRegistry.empty());
    }

    /// Explicit maintenance connection: validate the file format/core schema,
    /// but do not run incompatible extension hooks. Upgrade, close, then reopen
    /// normally before application use. Never performs an implicit upgrade.
    pub fn openForExtensionUpgradeWithExtensions(path: [:0]const u8, options: OpenOptions, registry: ExtensionRegistry) Error!Database {
        if (options.read_only) return error.ExtensionInvalid;
        return openInternal(path, options, true, registry, .inspect);
    }

    /// Open a database for diagnostic extension metadata inspection with
    /// process-registered extension code available to explicit checks.
    /// Forces read-only inspection; normal extension hooks are not run.
    pub fn openForExtensionInspectionWithExtensions(path: [:0]const u8, options: OpenOptions, registry: ExtensionRegistry) Error!Database {
        return openInternal(path, .{
            .read_only = true,
            .busy_timeout_ms = options.busy_timeout_ms,
        }, true, registry, .inspect);
    }

    /// Open only the main `.zova` file for bound-store binding management.
    ///
    /// This is for repairing or replacing binding metadata when the configured
    /// store path is no longer available. Object/vector/graph APIs on the returned
    /// handle use the main file only; normal application code should use `open`
    /// or `openWithOptions`.
    /// After repair, close and reopen normally to restore bound-store routing.
    pub fn openForObjectStoreManagement(path: [:0]const u8, options: OpenOptions) Error!Database {
        return openForObjectStoreManagementWithExtensions(path, options, bundledExtensionRegistry());
    }

    /// Open only the main `.zova` file for bound-store binding management with
    /// process-registered extension code.
    pub fn openForObjectStoreManagementWithExtensions(path: [:0]const u8, options: OpenOptions, registry: ExtensionRegistry) Error!Database {
        return openInternal(path, options, false, registry, .enforce);
    }

    fn openInternal(path: [:0]const u8, options: OpenOptions, load_bound_stores: bool, registry: ExtensionRegistry, extension_mode: ExtensionOpenMode) Error!Database {
        try registry.validate();
        if (!isZovaPath(path)) return error.NotZovaPath;
        try ensurePathExists(path);

        const flags: sqlite.OpenFlags = if (options.read_only) .read_only else .read_write;
        var raw = try sqlite.Database.openWithFlags(path, flags);
        errdefer raw.deinit();

        try enableForeignKeys(&raw);
        if (options.busy_timeout_ms != 0) try raw.setBusyTimeout(options.busy_timeout_ms);
        try validateZovaSchema(&raw);
        try @import("vector_maintenance.zig").register(&raw);
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
        const bound_graph_store = if (load_bound_stores)
            try openConfiguredBoundGraphStore(&raw, options)
        else
            null;
        errdefer if (bound_graph_store != null) raw.detachDatabase(bound_graph_store_schema_name) catch {};
        try vector_sql.register(&raw);
        try graph_sql.register(&raw);
        switch (extension_mode) {
            .enforce => {
                try extension_impl.registerSqlForInstalled(&raw, registry);
                try extension_impl.checkAll(&raw, registry);
            },
            .inspect => try extension_impl.validateInstalledRegistry(std.heap.c_allocator, &raw),
        }
        const notifications = try initNotifications(&raw);
        errdefer deinitNotifications(notifications);
        return .{
            .sqlite_db = raw,
            .notifications = notifications,
            .bound_object_store = bound_object_store,
            .bound_vector_store = bound_vector_store,
            .bound_graph_store = bound_graph_store,
            .extension_registry = registry,
        };
    }

    /// Close the underlying SQLite connection.
    pub fn deinit(self: *Database) void {
        self.main_graph_edge_types.deinit();
        self.bound_graph_edge_types.deinit();
        self.kv_statements.deinit();
        self.idle_statements.deinit();
        self.graph_walk_scratch.deinit();
        self.sqlite_db.deinit();
        deinitNotifications(self.notifications);
    }

    /// Install one process-registered extension into this database.
    ///
    /// The database records extension metadata and extension-owned storage, but
    /// never records executable paths or auto-loads code from the file.
    pub fn installExtension(self: *Database, name: []const u8) Error!void {
        try extension_impl.install(&self.sqlite_db, self.extension_registry, name, validateExtensionLifecycleCore);
    }

    /// Execute one declared forward extension-data path, atomically.
    pub fn upgradeExtension(self: *Database, name: []const u8) Error!void {
        try extension_impl.upgrade(std.heap.c_allocator, &self.sqlite_db, self.extension_registry, name, validateExtensionLifecycleCore);
    }

    /// Explicit plugin repair at the installed data version; no implicit upgrade.
    pub fn rebuildExtension(self: *Database, name: []const u8) Error!void {
        try extension_impl.rebuild(std.heap.c_allocator, &self.sqlite_db, self.extension_registry, name, validateExtensionLifecycleCore);
    }

    /// Return installed extension metadata sorted by extension name.
    pub fn listExtensions(self: *Database, allocator: std.mem.Allocator) Error!ExtensionList {
        return extension_impl.listInstalled(allocator, &self.sqlite_db);
    }

    /// Return the first extension-private SQLite object with no installed
    /// owner, if one exists.
    /// Maintenance diagnostic, not an application-data enumeration API.
    pub fn unknownExtensionStorage(self: *Database, allocator: std.mem.Allocator) Error!?[]u8 {
        return extension_impl.findUnknownPrivateStorage(allocator, &self.sqlite_db);
    }

    /// Return metadata for one installed extension.
    pub fn extensionInfo(self: *Database, allocator: std.mem.Allocator, name: []const u8) Error!ExtensionInfo {
        return extension_impl.loadInfo(allocator, &self.sqlite_db, name);
    }

    /// Run the registered extension's health check hook.
    pub fn checkExtension(self: *Database, name: []const u8) Error!void {
        try extension_impl.check(&self.sqlite_db, self.extension_registry, name);
    }

    /// Register SQL needed by one installed extension before diagnostic checks.
    /// Does not convert an inspection handle into a normally opened connection.
    pub fn registerExtensionSqlForDiagnostics(self: *Database, name: []const u8) Error!void {
        try extension_impl.registerSqlForInstalledExtension(&self.sqlite_db, self.extension_registry, name);
    }

    /// Drop one process-registered extension and its namespaced storage.
    pub fn dropExtension(self: *Database, name: []const u8) Error!void {
        try extension_impl.drop(&self.sqlite_db, self.extension_registry, name, validateExtensionLifecycleCore);
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
        self.invalidateActiveGraphEdgeTypes();
        const owns_transaction = try self.beginBoundGraphMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        try graphs.createGraph(name);
        if (self.bound_graph_store != null) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBoundGraphMutation(owns_transaction);
        committed = true;
    }

    /// Delete a graph and all of its Zova-owned graph nodes and edges.
    pub fn deleteGraph(self: *Database, name: []const u8) Error!void {
        self.invalidateActiveGraphEdgeTypes();
        const owns_transaction = try self.beginBoundGraphMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        try graphs.deleteGraph(name);
        if (self.bound_graph_store != null) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBoundGraphMutation(owns_transaction);
        committed = true;
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
        const owns_transaction = try self.beginBoundGraphMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        try graphs.putGraphNode(input);
        if (self.bound_graph_store != null) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBoundGraphMutation(owns_transaction);
        committed = true;
    }

    /// Upsert graph nodes atomically, using a savepoint in a caller transaction.
    pub fn putGraphNodes(self: *Database, inputs: []const GraphNodeInput) Error!void {
        const scope = try self.beginBatchMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBatchMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.putGraphNodes(inputs);
        if (self.bound_graph_store != null and inputs.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
        committed = true;
    }

    /// Upsert graph nodes atomically and return aligned opaque row keys.
    pub fn putGraphNodesKeyed(self: *Database, inputs: []const GraphNodeInput, out_keys: []i64) Error!void {
        if (out_keys.len != inputs.len) return error.InvalidArgument;
        const scope = try self.beginBatchMutation();
        var finished = false;
        errdefer if (!finished) self.rollbackBatchMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.putGraphNodesKeyed(inputs, out_keys);
        if (self.bound_graph_store != null and inputs.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
        finished = true;
    }

    /// Build one graph atomically in an otherwise empty native graph store.
    pub fn buildFreshGraphKeyed(
        self: *Database,
        graph_name: []const u8,
        nodes: []const FreshGraphNodeInput,
        edges: []const FreshGraphEdgeInput,
        out_node_keys: []i64,
        out_edge_keys: []i64,
    ) Error!void {
        return self.buildFreshGraphKeyedProfiled(graph_name, nodes, edges, out_node_keys, out_edge_keys, null);
    }

    pub fn buildFreshGraphKeyedProfiled(
        self: *Database,
        graph_name: []const u8,
        nodes: []const FreshGraphNodeInput,
        edges: []const FreshGraphEdgeInput,
        out_node_keys: []i64,
        out_edge_keys: []i64,
        profile: ?*FreshGraphBuildProfile,
    ) Error!void {
        self.invalidateActiveGraphEdgeTypes();
        if (out_node_keys.len != nodes.len or out_edge_keys.len != edges.len) return error.InvalidArgument;
        const temporary_node_keys = try std.heap.c_allocator.alloc(i64, nodes.len);
        defer std.heap.c_allocator.free(temporary_node_keys);
        const temporary_edge_keys = try std.heap.c_allocator.alloc(i64, edges.len);
        defer std.heap.c_allocator.free(temporary_edge_keys);
        const scope = try self.beginBatchMutation();
        var finished = false;
        errdefer if (!finished) self.rollbackBatchMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.buildFreshGraphKeyedProfiled(graph_name, nodes, edges, temporary_node_keys, temporary_edge_keys, profile);
        if (self.bound_graph_store != null) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
        finished = true;
        @memcpy(out_node_keys, temporary_node_keys);
        @memcpy(out_edge_keys, temporary_edge_keys);
    }

    /// Build trusted, final-order graph input atomically without normalization.
    pub fn buildFreshGraphPreparedKeyed(
        self: *Database,
        graph_name: []const u8,
        nodes: []const FreshGraphNodeInput,
        edges: []const FreshGraphEdgeInput,
        out_node_keys: []i64,
        out_edge_keys: []i64,
    ) Error!void {
        return self.buildFreshGraphPreparedKeyedProfiled(graph_name, nodes, edges, out_node_keys, out_edge_keys, null);
    }

    pub fn buildFreshGraphPreparedKeyedProfiled(
        self: *Database,
        graph_name: []const u8,
        nodes: []const FreshGraphNodeInput,
        edges: []const FreshGraphEdgeInput,
        out_node_keys: []i64,
        out_edge_keys: []i64,
        profile: ?*FreshGraphBuildProfile,
    ) Error!void {
        self.invalidateActiveGraphEdgeTypes();
        if (out_node_keys.len != nodes.len or out_edge_keys.len != edges.len) return error.InvalidArgument;
        const temporary_node_keys = try std.heap.c_allocator.alloc(i64, nodes.len);
        defer std.heap.c_allocator.free(temporary_node_keys);
        const temporary_edge_keys = try std.heap.c_allocator.alloc(i64, edges.len);
        defer std.heap.c_allocator.free(temporary_edge_keys);
        const scope = try self.beginBatchMutation();
        var finished = false;
        errdefer if (!finished) self.rollbackBatchMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.buildFreshGraphPreparedKeyedProfiled(graph_name, nodes, edges, temporary_node_keys, temporary_edge_keys, profile);
        if (self.bound_graph_store != null) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
        finished = true;
        @memcpy(out_node_keys, temporary_node_keys);
        @memcpy(out_edge_keys, temporary_edge_keys);
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
        const owns_transaction = try self.beginBoundGraphMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        try graphs.deleteGraphNode(graph_name, node_id);
        if (self.bound_graph_store != null) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBoundGraphMutation(owns_transaction);
        committed = true;
    }

    /// Delete graph nodes and incident edges atomically, including in caller transactions.
    pub fn deleteGraphNodes(self: *Database, graph_name: []const u8, node_ids: []const []const u8) Error!void {
        const scope = try self.beginBatchMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBatchMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.deleteGraphNodes(graph_name, node_ids);
        if (self.bound_graph_store != null and node_ids.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
        committed = true;
    }

    /// Create an explicit directed graph edge.
    pub fn putGraphEdge(self: *Database, input: GraphEdgeInput) Error!void {
        self.invalidateActiveGraphEdgeTypes();
        const owns_transaction = try self.beginBoundGraphMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        try graphs.putGraphEdge(input);
        if (self.bound_graph_store != null) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBoundGraphMutation(owns_transaction);
        committed = true;
    }

    /// Insert graph edges atomically, using a savepoint in a caller transaction.
    pub fn putGraphEdges(self: *Database, inputs: []const GraphEdgeInput) Error!void {
        self.invalidateActiveGraphEdgeTypes();
        const scope = try self.beginBatchMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBatchMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.putGraphEdges(inputs);
        if (self.bound_graph_store != null and inputs.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
        committed = true;
    }

    /// Insert graph edges atomically and return aligned opaque row keys.
    pub fn putGraphEdgesKeyed(self: *Database, inputs: []const GraphEdgeInput, out_keys: []i64) Error!void {
        self.invalidateActiveGraphEdgeTypes();
        if (out_keys.len != inputs.len) return error.InvalidArgument;
        const scope = try self.beginBatchMutation();
        var finished = false;
        errdefer if (!finished) self.rollbackBatchMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.putGraphEdgesKeyed(inputs, out_keys);
        if (self.bound_graph_store != null and inputs.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
        finished = true;
    }

    pub fn graphEdgePayloadsGetMany(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, keys: []const i64) Error!GraphEdgePayloadLookupList {
        var graphs = self.graphDatabase();
        return try graphs.graphEdgePayloadsGetMany(allocator, graph_name, keys);
    }

    pub fn replaceGraphEdgePayloads(self: *Database, graph_name: []const u8, replacements: []const GraphEdgePayloadReplacement) Error!void {
        const scope = try self.beginBatchMutation();
        var finished = false;
        errdefer if (!finished) self.rollbackBatchMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.replaceGraphEdgePayloads(graph_name, replacements);
        if (self.bound_graph_store != null and replacements.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
        finished = true;
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
        const owns_transaction = try self.beginBoundGraphMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        try graphs.deleteGraphEdge(input);
        if (self.bound_graph_store != null) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBoundGraphMutation(owns_transaction);
        committed = true;
    }

    /// Delete graph edges atomically, using a savepoint in a caller transaction.
    /// Missing endpoints and edges are ignored for replay safety.
    pub fn deleteGraphEdges(self: *Database, inputs: []const GraphEdgeInput) Error!void {
        const scope = try self.beginBatchMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBatchMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.deleteGraphEdges(inputs);
        if (self.bound_graph_store != null and inputs.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
        committed = true;
    }

    /// Return bounded incoming or outgoing graph neighbors.
    pub fn graphNeighbors(self: *Database, allocator: std.mem.Allocator, options: GraphNeighborsOptions) Error!GraphNeighborList {
        var graphs = self.graphDatabase();
        return try graphs.graphNeighbors(allocator, options);
    }

    /// Return bounded incoming or outgoing neighbors with opaque row keys.
    pub fn graphNeighborsKeyed(self: *Database, allocator: std.mem.Allocator, options: GraphNeighborsOptions) Error!GraphKeyedNeighborList {
        var graphs = self.graphDatabase();
        return try graphs.graphNeighborsKeyed(allocator, options);
    }

    pub fn graphNodesGetManyKeyed(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, keys: []const i64) Error!GraphKeyedNodeLookupList {
        const owns_transaction = !hasActiveTransaction(&self.sqlite_db);
        if (owns_transaction) try self.sqlite_db.begin();
        errdefer if (owns_transaction) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        var result = try graphs.graphNodesGetManyKeyed(allocator, graph_name, keys);
        errdefer result.deinit(allocator);
        if (owns_transaction) try self.sqlite_db.commit();
        return result;
    }

    pub fn graphEdgesGetManyKeyed(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, keys: []const i64) Error!GraphKeyedEdgeLookupList {
        const owns_transaction = !hasActiveTransaction(&self.sqlite_db);
        if (owns_transaction) try self.sqlite_db.begin();
        errdefer if (owns_transaction) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        var result = try graphs.graphEdgesGetManyKeyed(allocator, graph_name, keys);
        errdefer result.deinit(allocator);
        if (owns_transaction) try self.sqlite_db.commit();
        return result;
    }

    /// Count incoming or outgoing graph edges, optionally restricted by type.
    pub fn graphDegree(self: *Database, options: GraphDegreeOptions) Error!u64 {
        var graphs = self.graphDatabase();
        return try graphs.graphDegree(options);
    }

    /// Count degrees for opaque node keys while preserving caller order.
    pub fn graphDegreeManyKeyed(
        self: *Database,
        graph_name: []const u8,
        node_keys: []const i64,
        direction: GraphNeighborDirection,
        edge_type: ?[]const u8,
        out_degrees: []u64,
    ) Error!void {
        var graphs = self.graphDatabase();
        return try graphs.graphDegreeManyKeyed(graph_name, node_keys, direction, edge_type, out_degrees);
    }

    /// Return independently bounded opaque-key node and edge topology pages.
    pub fn graphScan(self: *Database, allocator: std.mem.Allocator, options: GraphScanOptions) Error!GraphScanResult {
        var graphs = self.graphDatabase();
        return try graphs.graphScan(allocator, options);
    }

    /// Return a bounded directed walk from one graph node.
    pub fn graphWalk(self: *Database, allocator: std.mem.Allocator, options: GraphWalkOptions) Error!GraphWalk {
        var graphs = self.graphDatabase();
        return try graphs.graphWalk(allocator, options);
    }

    /// Return a bounded incoming or outgoing directed walk from one graph node.
    pub fn graphWalkDirection(self: *Database, allocator: std.mem.Allocator, options: GraphWalkDirectionOptions) Error!GraphWalk {
        var graphs = self.graphDatabase();
        return try graphs.graphWalkDirection(allocator, options);
    }

    /// Run an incoming or outgoing graph walk with diagnostic stage metrics.
    pub fn graphWalkDirectionProfiled(
        self: *Database,
        allocator: std.mem.Allocator,
        options: GraphWalkDirectionOptions,
        profile: *GraphWalkScanProfile,
    ) Error!GraphWalk {
        var graphs = self.graphDatabase();
        return try graphs.graphWalkDirectionProfiled(allocator, options, profile);
    }

    /// Copy this database to a new `.zova` destination with SQLite's online
    /// backup API.
    ///
    /// The destination must not already exist. When verification is enabled,
    /// Zova opens the copy, runs SQLite `quick_check`, and validates object,
    /// chunk, vector, and graph rows through the public read paths.
    pub fn backupTo(self: *Database, destination_path: [:0]const u8, options: BackupOptions) Error!void {
        try reserveDestinationZovaFile(destination_path);
        errdefer deleteDestinationFile(destination_path);

        {
            var dest = try sqlite.Database.open(destination_path);
            defer dest.deinit();
            try backupMainDatabase(&self.sqlite_db, &dest);
        }

        try self.inlineBoundStoresIntoDestination(destination_path);
        if (options.verify) try verifyOperationalCopy(destination_path, self.extension_registry);
    }

    /// Copy this database's main schema and data into a new in-memory database
    /// using SQLite's online backup API.
    ///
    /// The returned database is isolated, volatile, and initialized with the
    /// same connection-local SQL vector/graph helpers and notification wiring
    /// as an opened database.
    fn restoreIntoMemory(self: *Database, registry: ExtensionRegistry) Error!Database {
        var raw = try sqlite.Database.open(":memory:");
        errdefer raw.deinit();
        try backupMainDatabase(&self.sqlite_db, &raw);
        try @import("vector_maintenance.zig").register(&raw);
        try self.inlineBoundStoresIntoDatabase(&raw);
        try enableForeignKeys(&raw);
        try vector_sql.register(&raw);
        try graph_sql.register(&raw);
        try extension_impl.registerSqlForInstalled(&raw, registry);
        const notifications = try initNotifications(&raw);
        errdefer deinitNotifications(notifications);
        return .{ .sqlite_db = raw, .notifications = notifications, .extension_registry = registry };
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
        try vacuum_stmt.expectDone();

        try self.inlineBoundStoresIntoDestination(destination_path);
        if (options.verify) try verifyOperationalCopy(destination_path, self.extension_registry);
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

    pub fn bindGraphStore(self: *Database, path: [:0]const u8) Error!void {
        self.bound_graph_edge_types.clear();
        try self.rejectBoundStoreManagementInsideMainTransaction();
        try ensureMainDatabaseRole(&self.sqlite_db);
        try ensureBoundStoreTable(&self.sqlite_db);
        if (sqlite.c.sqlite3_db_readonly(self.sqlite_db.handle, "main") == 1) return error.ReadOnly;

        const stored_path = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
        defer std.heap.c_allocator.free(stored_path);
        const had_binding = try hasBoundGraphStoreRow(&self.sqlite_db);
        if (!had_binding and try mainGraphStorageHasRows(&self.sqlite_db)) return error.BoundStoreExists;

        const had_attached_store = self.bound_graph_store != null;
        var detached_old = false;
        if (had_binding and had_attached_store) {
            try self.sqlite_db.detachDatabase(bound_graph_store_schema_name);
            self.bound_graph_store = null;
            detached_old = true;
        }
        errdefer if (detached_old) self.restoreConfiguredBoundGraphStore() catch {};

        // Attaching or replacing a bound store changes the schemas cached
        // read SQL refers to, so dispose the cache first.
        self.idle_statements.deinit();
        try attachGraphStore(&self.sqlite_db, stored_path, false);
        errdefer self.sqlite_db.detachDatabase(bound_graph_store_schema_name) catch {};
        const store_id = try validateAttachedGraphStoreAlloc(std.heap.c_allocator, &self.sqlite_db, bound_graph_store_schema_name);
        defer std.heap.c_allocator.free(store_id);

        var bound_set_id: [64]u8 = undefined;
        randomHex64(&bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_graph_store_schema_name, "bound_set_id", &bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_graph_store_schema_name, "graph_epoch", "0");
        if (had_binding)
            try updateBoundGraphStoreRow(&self.sqlite_db, stored_path, store_id, &bound_set_id)
        else
            try insertBoundGraphStoreRow(&self.sqlite_db, stored_path, store_id, &bound_set_id);
        self.bound_graph_store = .{};
    }

    /// Move existing single-file graph storage into a new bound graph store.
    pub fn splitGraphStore(self: *Database, store_path: [:0]const u8) Error!SplitGraphStoreResult {
        self.main_graph_edge_types.clear();
        self.bound_graph_edge_types.clear();
        try self.rejectBoundStoreManagementInsideMainTransaction();
        try ensureMainDatabaseRole(&self.sqlite_db);
        try ensureBoundStoreTable(&self.sqlite_db);
        if (sqlite.c.sqlite3_db_readonly(self.sqlite_db.handle, "main") == 1) return error.ReadOnly;
        if (try hasBoundGraphStoreRow(&self.sqlite_db)) return error.BoundStoreExists;

        const copied_counts = try graphStorageCounts(&self.sqlite_db, .main);

        try createGraphStore(store_path);
        errdefer deleteDestinationFile(store_path);

        // Attaching or replacing a bound store changes the schemas cached
        // read SQL refers to, so dispose the cache first.
        self.idle_statements.deinit();
        try attachGraphStore(&self.sqlite_db, store_path, false);
        errdefer self.sqlite_db.detachDatabase(bound_graph_store_schema_name) catch {};

        try self.sqlite_db.beginImmediate();
        var committed = false;
        errdefer if (!committed) self.sqlite_db.rollback() catch {};

        const store_id_alloc = try validateAttachedGraphStoreAlloc(std.heap.c_allocator, &self.sqlite_db, bound_graph_store_schema_name);
        defer std.heap.c_allocator.free(store_id_alloc);
        const store_id = try copyStoreId(store_id_alloc);

        var bound_set_id: [64]u8 = undefined;
        randomHex64(&bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_graph_store_schema_name, "bound_set_id", &bound_set_id);
        try setAttachedMetadataValue(&self.sqlite_db, bound_graph_store_schema_name, "graph_epoch", "0");
        try insertBoundGraphStoreRow(&self.sqlite_db, store_path, store_id_alloc, &bound_set_id);

        self.bound_graph_store = .{};
        errdefer self.bound_graph_store = null;

        try copyGraphStorage(&self.sqlite_db, .main, &self.sqlite_db, .graph_store);
        try clearMainGraphStorage(&self.sqlite_db);
        const remaining_main_counts = try graphStorageCounts(&self.sqlite_db, .main);
        if (remaining_main_counts.graphs != 0 or remaining_main_counts.nodes != 0 or remaining_main_counts.edges != 0) {
            return error.GraphInvalid;
        }

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

    pub fn boundGraphStore(self: *Database, allocator: std.mem.Allocator) Error!?BoundGraphStoreInfo {
        return try loadBoundGraphStoreInfo(allocator, &self.sqlite_db);
    }

    pub fn unbindGraphStore(self: *Database) Error!void {
        self.bound_graph_edge_types.clear();
        try self.rejectBoundStoreManagementInsideMainTransaction();
        if (!try hasBoundGraphStoreRow(&self.sqlite_db)) return error.BoundStoreNotFound;
        const had_attached_store = self.bound_graph_store != null;
        try self.detachBoundGraphStore();
        var deleted = false;
        errdefer if (had_attached_store and !deleted) self.restoreConfiguredBoundGraphStore() catch {};
        try deleteBoundGraphStoreRows(&self.sqlite_db);
        deleted = true;
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

        const stored_path = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
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

        // Attaching or replacing a bound store changes the schemas cached
        // read SQL refers to, so dispose the cache first.
        self.idle_statements.deinit();
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

        // Attaching or replacing a bound store changes the schemas cached
        // read SQL refers to, so dispose the cache first.
        self.idle_statements.deinit();
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
        try stmt.expectDone();
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

        const stored_path = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
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

        // Attaching or replacing a bound store changes the schemas cached
        // read SQL refers to, so dispose the cache first.
        self.idle_statements.deinit();
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

        // Attaching or replacing a bound store changes the schemas cached
        // read SQL refers to, so dispose the cache first.
        self.idle_statements.deinit();
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
        try stmt.expectDone();
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

    /// Create an object writer using an explicitly selected storage profile.
    /// The streaming profile is accepted by this facade once the selected
    /// object store supports the fixed-1MiB representation.
    pub fn objectWriterWithOptions(self: *Database, allocator: std.mem.Allocator, options: ObjectPutOptions) Error!ObjectWriter {
        var objects = self.objectDatabase();
        return .{
            .inner = try objects.objectWriterWithOptions(allocator, options),
            .sqlite_db = &self.sqlite_db,
            .bound = self.bound_object_store != null,
        };
    }

    /// Open a sequential reader over one stored object and pin its snapshot.
    pub fn objectReader(self: *Database, id: ObjectId) Error!ObjectReader {
        var objects = self.objectDatabase();
        return .{ .inner = try objects.objectReader(id) };
    }

    /// Create a native vector collection.
    pub fn createVectorCollection(
        self: *Database,
        name: []const u8,
        options: VectorCollectionOptions,
    ) Error!void {
        const scope = try self.beginBoundVectorMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundVectorMutation(scope) catch {};

        var vectors = self.vectorDatabase();
        try vectors.createVectorCollection(name, options);
        if (self.bound_vector_store != null) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBoundVectorMutation(scope);
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
        values: VectorValuesConst,
    ) Error!void {
        const scope = try self.beginBoundVectorMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundVectorMutation(scope) catch {};

        var vectors = self.vectorDatabase();
        try vectors.putVector(collection_name, vector_id, values);
        if (self.bound_vector_store != null) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBoundVectorMutation(scope);
        committed = true;
    }

    /// Store or replace vector rows atomically, including in caller transactions.
    pub fn putVectors(
        self: *Database,
        collection_name: []const u8,
        inputs: []const VectorInput,
    ) Error!void {
        try @import("extension_operations.zig").requireSourceIdle(&self.sqlite_db);
        const scope = try self.beginBatchMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBatchMutation(scope) catch {};

        var vectors = self.vectorDatabase();
        try vectors.putVectors(collection_name, inputs);
        if (self.bound_vector_store != null and inputs.len != 0) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
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
        const scope = try self.beginBoundVectorMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundVectorMutation(scope) catch {};

        var vectors = self.vectorDatabase();
        try vectors.deleteVector(collection_name, vector_id);
        if (self.bound_vector_store != null) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBoundVectorMutation(scope);
        committed = true;
    }

    /// Delete vector rows atomically, including in caller transactions.
    /// Missing and duplicate ids are ignored.
    pub fn deleteVectors(
        self: *Database,
        collection_name: []const u8,
        vector_ids: []const []const u8,
    ) Error!void {
        try @import("extension_operations.zig").requireSourceIdle(&self.sqlite_db);
        const scope = try self.beginBatchMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBatchMutation(scope) catch {};

        var vectors = self.vectorDatabase();
        try vectors.deleteVectors(collection_name, vector_ids);
        if (self.bound_vector_store != null and vector_ids.len != 0) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBatchMutation(scope);
        committed = true;
    }

    /// Delete a vector collection and all private vector rows in it.
    pub fn deleteVectorCollection(self: *Database, name: []const u8) Error!void {
        const scope = try self.beginBoundVectorMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundVectorMutation(scope) catch {};

        var vectors = self.vectorDatabase();
        try vectors.deleteVectorCollection(name);
        if (self.bound_vector_store != null) try incrementBoundVectorEpoch(&self.sqlite_db);
        try self.finishBoundVectorMutation(scope);
        committed = true;
    }

    /// Search one vector collection with an exact flat scan.
    pub fn searchVectors(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: VectorValuesConst,
        limit: usize,
    ) Error!VectorSearchResults {
        var vectors = self.vectorDatabase();
        return vectors.searchVectors(allocator, collection_name, query, limit);
    }

    /// Search a raw-i8 cosine collection against multiple queries.
    pub fn searchMultiI8Cosine(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        options: MultiI8CosineSearchOptions,
        limit: usize,
    ) Error!VectorSearchResults {
        var vectors = self.vectorDatabase();
        return vectors.searchMultiI8Cosine(allocator, collection_name, options, limit);
    }

    /// Search one vector collection with an exact flat scan and distance cap.
    pub fn searchVectorsWithin(
        self: *Database,
        allocator: std.mem.Allocator,
        collection_name: []const u8,
        query: VectorValuesConst,
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
        query: VectorValuesConst,
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
        query: VectorValuesConst,
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
    ///
    /// The put is operation-atomic and joins an active caller transaction
    /// through an internal savepoint without committing it, so a SQL row
    /// referencing the returned id can be written in the same caller
    /// transaction.
    pub fn putObject(self: *Database, bytes: []const u8) Error!ObjectId {
        if (self.bound_object_store == null) {
            var objects = self.objectDatabase();
            return objects.putObject(bytes);
        }

        const id = objectId(bytes);
        const existed = try self.hasObject(id);
        const scope = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundObjectMutation(scope) catch {};

        var objects = self.objectDatabase();
        const result = try objects.putObject(bytes);
        if (!existed) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(scope);
        committed = true;
        return result;
    }

    /// Store raw bytes using an explicitly selected storage profile.
    pub fn putObjectWithOptions(self: *Database, bytes: []const u8, options: ObjectPutOptions) Error!ObjectId {
        if (self.bound_object_store == null) {
            var objects = self.objectDatabase();
            return objects.putObjectWithOptions(bytes, options);
        }

        const id = objectId(bytes);
        const existed = try self.hasObject(id);
        const scope = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundObjectMutation(scope) catch {};

        var objects = self.objectDatabase();
        const result = try objects.putObjectWithOptions(bytes, options);
        if (!existed) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(scope);
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
        const scope = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundObjectMutation(scope) catch {};

        var objects = self.objectDatabase();
        try objects.putObjectChunk(expected_hash, bytes);
        if (self.bound_object_store != null and !existed) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(scope);
        committed = true;
    }

    /// Store one verified loose chunk using an explicitly selected profile.
    pub fn putObjectChunkWithOptions(
        self: *Database,
        expected_hash: ObjectChunkId,
        bytes: []const u8,
        options: ObjectPutOptions,
    ) Error!void {
        const existed = if (self.bound_object_store != null) try self.hasObjectChunk(expected_hash) else false;
        const scope = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundObjectMutation(scope) catch {};

        var objects = self.objectDatabase();
        try objects.putObjectChunkWithOptions(expected_hash, bytes, options);
        if (self.bound_object_store != null and !existed) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(scope);
        committed = true;
    }

    /// Assemble a complete object from already-verified chunks.
    pub fn assembleObjectFromChunks(
        self: *Database,
        id: ObjectId,
        size_bytes: u64,
        chunks: []const ObjectChunk,
    ) Error!void {
        const scope = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundObjectMutation(scope) catch {};

        var objects = self.objectDatabase();
        try objects.assembleObjectFromChunks(id, size_bytes, chunks);
        if (self.bound_object_store != null) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(scope);
        committed = true;
    }

    /// Assemble an object using an explicitly selected storage profile.
    pub fn assembleObjectFromChunksWithOptions(
        self: *Database,
        id: ObjectId,
        size_bytes: u64,
        chunks: []const ObjectChunk,
        options: ObjectPutOptions,
    ) Error!void {
        const scope = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundObjectMutation(scope) catch {};

        var objects = self.objectDatabase();
        try objects.assembleObjectFromChunksWithOptions(id, size_bytes, chunks, options);
        if (self.bound_object_store != null) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(scope);
        committed = true;
    }

    /// Delete one unreferenced loose chunk if possible.
    pub fn deleteObjectChunk(self: *Database, hash: ObjectChunkId) Error!bool {
        const scope = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundObjectMutation(scope) catch {};

        var objects = self.objectDatabase();
        const deleted = try objects.deleteObjectChunk(hash);
        if (self.bound_object_store != null and deleted) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(scope);
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
        const scope = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (!committed) self.rollbackBoundObjectMutation(scope) catch {};

        var objects = self.objectDatabase();
        try objects.deleteObject(id);
        if (self.bound_object_store != null) try incrementBoundObjectEpoch(&self.sqlite_db);
        try self.finishBoundObjectMutation(scope);
        committed = true;
    }

    /// Load one transactional key-value entry.
    ///
    /// Missing keys return `found = false`, not an error. Byte comparison is
    /// exact; no text normalization or implicit encoding is applied. The
    /// returned value is caller-owned when `found` is true.
    pub fn kvGet(self: *Database, allocator: std.mem.Allocator, namespace: []const u8, key: []const u8) Error!kv_impl.GetResult {
        var kv = self.kvDatabase();
        return kv.get(allocator, namespace, key);
    }

    /// Load many transactional key-value entries.
    ///
    /// Results align with the input key order and preserve duplicate keys
    /// exactly. Missing keys return `found = false`.
    pub fn kvGetMany(self: *Database, allocator: std.mem.Allocator, namespace: []const u8, keys: []const []const u8) Error![]kv_impl.GetResult {
        var kv = self.kvDatabase();
        return kv.getMany(allocator, namespace, keys);
    }

    /// Insert or replace one transactional key-value entry.
    pub fn kvPut(self: *Database, namespace: []const u8, key: []const u8, value: []const u8) Error!void {
        var kv = self.kvDatabase();
        return kv.put(namespace, key, value);
    }

    /// Insert or replace many transactional key-value entries atomically.
    ///
    /// The whole batch validates before any mutation and either commits
    /// together or rolls back together. Empty batches succeed.
    pub fn kvPutMany(self: *Database, namespace: []const u8, entries: []const kv_impl.PutEntry) Error!void {
        var kv = self.kvDatabase();
        return kv.putMany(namespace, entries);
    }

    /// Delete one transactional key-value entry.
    ///
    /// Missing keys are ignored for replay safety.
    pub fn kvDelete(self: *Database, namespace: []const u8, key: []const u8) Error!void {
        var kv = self.kvDatabase();
        return kv.delete(namespace, key);
    }

    /// Delete many transactional key-value entries atomically.
    ///
    /// Missing keys are ignored. Empty batches succeed.
    pub fn kvDeleteMany(self: *Database, namespace: []const u8, keys: []const []const u8) Error!void {
        var kv = self.kvDatabase();
        return kv.deleteMany(namespace, keys);
    }

    /// Return the number of entries in one transactional key-value namespace.
    pub fn kvCount(self: *Database, namespace: []const u8) Error!u64 {
        var kv = self.kvDatabase();
        return kv.count(namespace);
    }

    /// Delete every entry in one transactional key-value namespace.
    pub fn kvClearNamespace(self: *Database, namespace: []const u8) Error!void {
        var kv = self.kvDatabase();
        return kv.clearNamespace(namespace);
    }

    fn kvDatabase(self: *Database) kv_impl.Database {
        return .{ .sqlite_db = &self.sqlite_db, .statement_cache = &self.kv_statements };
    }

    fn beginBoundObjectMutation(self: *Database) Error!?BatchMutationScope {
        if (self.bound_object_store == null) return null;
        return try self.beginBatchMutation();
    }

    fn finishBoundObjectMutation(self: *Database, scope: ?BatchMutationScope) Error!void {
        if (scope) |s| try self.finishBatchMutation(s);
    }

    fn rollbackBoundObjectMutation(self: *Database, scope: ?BatchMutationScope) Error!void {
        if (scope) |s| try self.rollbackBatchMutation(s);
    }

    fn objectDatabase(self: *Database) object_impl.Database {
        const bound = self.bound_object_store != null;
        return .{
            .sqlite_db = &self.sqlite_db,
            .storage_schema = if (bound) .object_store else .main,
            // Synchronous object mutations always join an active caller
            // transaction through an internal savepoint. The streaming writer
            // keeps its main-store rejection and is allowed inside caller
            // transactions only for an attached bound object store.
            .allow_active_transactions = bound,
            .statement_cache = &self.idle_statements,
        };
    }

    fn beginBoundVectorMutation(self: *Database) Error!?BatchMutationScope {
        try @import("extension_operations.zig").requireSourceIdle(&self.sqlite_db);
        if (self.bound_vector_store == null) return null;
        return try self.beginBatchMutation();
    }

    fn finishBoundVectorMutation(self: *Database, scope: ?BatchMutationScope) Error!void {
        if (scope) |s| try self.finishBatchMutation(s);
    }

    fn rollbackBoundVectorMutation(self: *Database, scope: ?BatchMutationScope) Error!void {
        if (scope) |s| try self.rollbackBatchMutation(s);
    }

    fn beginBoundGraphMutation(self: *Database) Error!bool {
        try @import("extension_operations.zig").requireSourceIdle(&self.sqlite_db);
        if (self.bound_graph_store == null or hasActiveTransaction(&self.sqlite_db)) return false;
        try self.sqlite_db.beginImmediate();
        return true;
    }

    fn beginBatchMutation(self: *Database) Error!BatchMutationScope {
        if (hasActiveTransaction(&self.sqlite_db)) {
            try self.sqlite_db.savepoint(batch_mutation_savepoint);
            return .savepoint;
        }
        try self.sqlite_db.beginImmediate();
        return .transaction;
    }

    fn finishBatchMutation(self: *Database, scope: BatchMutationScope) Error!void {
        switch (scope) {
            .transaction => try self.sqlite_db.commit(),
            .savepoint => try self.sqlite_db.releaseSavepoint(batch_mutation_savepoint),
        }
    }

    fn rollbackBatchMutation(self: *Database, scope: BatchMutationScope) Error!void {
        switch (scope) {
            .transaction => try self.sqlite_db.rollback(),
            .savepoint => {
                try self.sqlite_db.rollbackToSavepoint(batch_mutation_savepoint);
                try self.sqlite_db.releaseSavepoint(batch_mutation_savepoint);
            },
        }
    }

    fn finishBoundGraphMutation(self: *Database, owns_transaction: bool) Error!void {
        if (owns_transaction) try self.sqlite_db.commit();
    }

    fn vectorDatabase(self: *Database) vector_impl.Database {
        return .{
            .sqlite_db = &self.sqlite_db,
            .storage_schema = if (self.bound_vector_store != null) .vector_store else .main,
            .statement_cache = &self.idle_statements,
        };
    }

    fn graphDatabase(self: *Database) graph_impl.Database {
        return .{
            .sqlite_db = &self.sqlite_db,
            .storage_schema = if (self.bound_graph_store != null) .graph_store else .main,
            .edge_type_cache = if (self.bound_graph_store != null) &self.bound_graph_edge_types else &self.main_graph_edge_types,
            .statement_cache = &self.idle_statements,
            .walk_scratch = &self.graph_walk_scratch,
        };
    }

    fn invalidateActiveGraphEdgeTypes(self: *Database) void {
        if (self.bound_graph_store != null) self.bound_graph_edge_types.clear() else self.main_graph_edge_types.clear();
    }

    fn rejectBoundStoreManagementInsideMainTransaction(self: *Database) Error!void {
        if (hasActiveTransaction(&self.sqlite_db)) {
            return error.ObjectTransactionActive;
        }
    }

    fn inlineBoundStoresIntoDestination(self: *Database, destination_path: [:0]const u8) Error!void {
        if (self.bound_object_store == null and self.bound_vector_store == null and self.bound_graph_store == null) return;

        var destination = try sqlite.Database.open(destination_path);
        defer destination.deinit();
        try self.inlineBoundStoresIntoDatabase(&destination);
    }

    /// Copy the contents of every attached bound store into the destination's
    /// main storage and remove the copied binding metadata.
    ///
    /// This is the in-memory counterpart of `inlineBoundStoresIntoDestination`:
    /// it makes the destination self-contained regardless of the source's
    /// bound object, vector, or graph store configuration.
    fn inlineBoundStoresIntoDatabase(self: *Database, destination: *sqlite.Database) Error!void {
        if (self.bound_object_store == null and self.bound_vector_store == null and self.bound_graph_store == null) return;
        try @import("vector_maintenance.zig").register(destination);

        if (self.bound_object_store != null) {
            try clearMainObjectStorage(destination);
            try copyObjectStorage(&self.sqlite_db, .object_store, destination, .main);
            try deleteBoundObjectStoreRows(destination);
        }

        if (self.bound_vector_store != null) {
            try clearMainVectorStorage(destination);
            try copyVectorStorage(&self.sqlite_db, .vector_store, destination, .main);
            try deleteBoundVectorStoreRows(destination);
        }

        if (self.bound_graph_store != null) {
            try clearMainGraphStorage(destination);
            try copyGraphStorage(&self.sqlite_db, .graph_store, destination, .main);
            try deleteBoundGraphStoreRows(destination);
        }
    }

    fn detachBoundObjectStore(self: *Database) Error!void {
        if (self.bound_object_store == null) return;
        // Cached SQL may refer to the attached schema being removed.
        self.idle_statements.deinit();
        try self.sqlite_db.detachDatabase(bound_object_store_schema_name);
        self.bound_object_store = null;
    }

    fn restoreConfiguredBoundObjectStore(self: *Database) Error!void {
        if (self.bound_object_store != null) return;
        self.idle_statements.deinit();
        self.bound_object_store = try openConfiguredBoundObjectStore(&self.sqlite_db, .{});
    }

    fn detachBoundVectorStore(self: *Database) Error!void {
        if (self.bound_vector_store == null) return;
        self.idle_statements.deinit();
        try self.sqlite_db.detachDatabase(bound_vector_store_schema_name);
        self.bound_vector_store = null;
    }

    fn restoreConfiguredBoundVectorStore(self: *Database) Error!void {
        if (self.bound_vector_store != null) return;
        self.idle_statements.deinit();
        self.bound_vector_store = try openConfiguredBoundVectorStore(&self.sqlite_db, .{});
    }

    fn detachBoundGraphStore(self: *Database) Error!void {
        if (self.bound_graph_store == null) return;
        self.idle_statements.deinit();
        try self.sqlite_db.detachDatabase(bound_graph_store_schema_name);
        self.bound_graph_store = null;
    }

    fn restoreConfiguredBoundGraphStore(self: *Database) Error!void {
        if (self.bound_graph_store != null) return;
        self.idle_statements.deinit();
        self.bound_graph_store = try openConfiguredBoundGraphStore(&self.sqlite_db, .{});
    }
};

const isZovaPath = @import("database/paths.zig").isZovaPath;

const isMemoryPath = @import("database/paths.zig").isMemoryPath;

const defaultIo = @import("database/paths.zig").defaultIo;

const ensureDestinationZovaPathAvailable = @import("database/paths.zig").ensureDestinationZovaPathAvailable;

const ensureParentPathExists = @import("database/paths.zig").ensureParentPathExists;

const reserveDestinationZovaFile = @import("database/paths.zig").reserveDestinationZovaFile;

const deleteDestinationFile = @import("database/paths.zig").deleteDestinationFile;

const ensurePathExists = @import("database/paths.zig").ensurePathExists;

const missingPathError = @import("database/paths.zig").missingPathError;

const ensureSourcePathExists = @import("database/paths.zig").ensureSourcePathExists;

const initializeZovaSchema = @import("database/lifecycle.zig").initializeZovaSchema;

const enableForeignKeys = @import("database/lifecycle.zig").enableForeignKeys;

const initializeMetadata = @import("database/lifecycle.zig").initializeMetadata;

const initializeExtensionSchema = @import("database/lifecycle.zig").initializeExtensionSchema;

const initializeObjectSchema = @import("database/lifecycle.zig").initializeObjectSchema;

const initializeVectorSchema = @import("database/lifecycle.zig").initializeVectorSchema;

const initializeGraphSchema = @import("database/lifecycle.zig").initializeGraphSchema;

const initializeKvSchema = @import("database/lifecycle.zig").initializeKvSchema;

const markAsObjectStore = @import("database/lifecycle.zig").markAsObjectStore;

const markAsVectorStore = @import("database/lifecycle.zig").markAsVectorStore;

const markAsGraphStore = @import("database/lifecycle.zig").markAsGraphStore;

const ensureBoundStoreTable = @import("database/lifecycle.zig").ensureBoundStoreTable;

const validateOptionalBoundStoreSchema = @import("database/validation.zig").validateOptionalBoundStoreSchema;

const validateBoundStoreTable = @import("database/validation.zig").validateBoundStoreTable;

const ensureMainDatabaseRole = @import("database/validation.zig").ensureMainDatabaseRole;

const openConfiguredBoundObjectStore = @import("database/bound_stores.zig").openConfiguredBoundObjectStore;

const openConfiguredBoundVectorStore = @import("database/bound_stores.zig").openConfiguredBoundVectorStore;

const openConfiguredBoundGraphStore = @import("database/bound_stores.zig").openConfiguredBoundGraphStore;

const attachObjectStore = @import("database/bound_stores.zig").attachObjectStore;

const attachVectorStore = @import("database/bound_stores.zig").attachVectorStore;

const attachGraphStore = @import("database/bound_stores.zig").attachGraphStore;

const prepareSchemaSql = @import("database/metadata.zig").prepareSchemaSql;

const copyObjectStorage = @import("database/backup.zig").copyObjectStorage;

const copyVectorStorage = @import("database/backup.zig").copyVectorStorage;

const copyGraphStorage = @import("database/backup.zig").copyGraphStorage;

const optionalTextMatchesColumn = @import("database/backup.zig").optionalTextMatchesColumn;

const clearMainObjectStorage = @import("database/backup.zig").clearMainObjectStorage;

const clearMainVectorStorage = @import("database/backup.zig").clearMainVectorStorage;

const clearMainGraphStorage = @import("database/backup.zig").clearMainGraphStorage;

const mainObjectStorageHasRows = @import("database/backup.zig").mainObjectStorageHasRows;

const mainVectorStorageHasRows = @import("database/backup.zig").mainVectorStorageHasRows;

const mainGraphStorageHasRows = @import("database/backup.zig").mainGraphStorageHasRows;

const objectStorageCounts = @import("database/backup.zig").objectStorageCounts;

const vectorStorageCounts = @import("database/backup.zig").vectorStorageCounts;

const graphStorageCounts = @import("database/backup.zig").graphStorageCounts;

const countStorageRows = @import("database/backup.zig").countStorageRows;

const prepareObjectSchemaSql = @import("database/backup.zig").prepareObjectSchemaSql;

const deleteBoundObjectStoreRows = @import("database/bound_stores.zig").deleteBoundObjectStoreRows;

const deleteBoundVectorStoreRows = @import("database/bound_stores.zig").deleteBoundVectorStoreRows;

const deleteBoundGraphStoreRows = @import("database/bound_stores.zig").deleteBoundGraphStoreRows;

const validateObjectStoreDatabaseExpected = @import("database/validation.zig").validateObjectStoreDatabaseExpected;

const validateObjectStoreDatabase = @import("database/validation.zig").validateObjectStoreDatabase;

const validateAttachedObjectStoreAlloc = @import("database/validation.zig").validateAttachedObjectStoreAlloc;

const validateVectorStoreDatabaseExpected = @import("database/validation.zig").validateVectorStoreDatabaseExpected;

const validateVectorStoreDatabase = @import("database/validation.zig").validateVectorStoreDatabase;

const validateAttachedVectorStoreAlloc = @import("database/validation.zig").validateAttachedVectorStoreAlloc;

const validateGraphStoreDatabaseExpected = @import("database/validation.zig").validateGraphStoreDatabaseExpected;

const validateGraphStoreDatabase = @import("database/validation.zig").validateGraphStoreDatabase;

const validateAttachedGraphStoreAlloc = @import("database/validation.zig").validateAttachedGraphStoreAlloc;

const validateAttachedObjectSchema = @import("database/validation.zig").validateAttachedObjectSchema;

const validateAttachedVectorSchema = @import("database/validation.zig").validateAttachedVectorSchema;

const validateAttachedGraphSchema = @import("database/validation.zig").validateAttachedGraphSchema;

const validateAttachedExtensionSchema = @import("database/validation.zig").validateAttachedExtensionSchema;

const validateAttachedRequiredTable = @import("database/validation.zig").validateAttachedRequiredTable;

const attachedTableExists = @import("database/metadata.zig").attachedTableExists;

const attachedTableColumnExists = @import("database/metadata.zig").attachedTableColumnExists;

const attachedObjectStoreIdAlloc = @import("database/metadata.zig").attachedObjectStoreIdAlloc;

const expectAttachedMetadataValue = @import("database/metadata.zig").expectAttachedMetadataValue;

const attachedMetadataValueAlloc = @import("database/metadata.zig").attachedMetadataValueAlloc;

const attachedMetadataU64 = @import("database/metadata.zig").attachedMetadataU64;

const setMetadataValue = @import("database/metadata.zig").setMetadataValue;

const setAttachedMetadataValue = @import("database/metadata.zig").setAttachedMetadataValue;

const hasBoundObjectStoreRow = @import("database/bound_stores.zig").hasBoundObjectStoreRow;

const hasBoundVectorStoreRow = @import("database/bound_stores.zig").hasBoundVectorStoreRow;

const hasBoundGraphStoreRow = @import("database/bound_stores.zig").hasBoundGraphStoreRow;

const loadBoundObjectStoreInfo = @import("database/bound_stores.zig").loadBoundObjectStoreInfo;

const loadBoundVectorStoreInfo = @import("database/bound_stores.zig").loadBoundVectorStoreInfo;

const loadBoundGraphStoreInfo = @import("database/bound_stores.zig").loadBoundGraphStoreInfo;

const insertBoundObjectStoreRow = @import("database/bound_stores.zig").insertBoundObjectStoreRow;

const updateBoundObjectStoreRow = @import("database/bound_stores.zig").updateBoundObjectStoreRow;

const insertBoundVectorStoreRow = @import("database/bound_stores.zig").insertBoundVectorStoreRow;

const updateBoundVectorStoreRow = @import("database/bound_stores.zig").updateBoundVectorStoreRow;

const insertBoundGraphStoreRow = @import("database/bound_stores.zig").insertBoundGraphStoreRow;

const updateBoundGraphStoreRow = @import("database/bound_stores.zig").updateBoundGraphStoreRow;

const incrementBoundObjectEpoch = @import("database/bound_stores.zig").incrementBoundObjectEpoch;

const incrementBoundVectorEpoch = @import("database/bound_stores.zig").incrementBoundVectorEpoch;

const incrementBoundGraphEpoch = @import("database/bound_stores.zig").incrementBoundGraphEpoch;

const objectStoreIdAlloc = @import("database/metadata.zig").objectStoreIdAlloc;

const metadataValueAlloc = @import("database/metadata.zig").metadataValueAlloc;

const isValidStoreId = @import("database/metadata.zig").isValidStoreId;

const randomHex64 = @import("database/metadata.zig").randomHex64;

const lowerHexInto = @import("database/metadata.zig").lowerHexInto;

const sqliteI64ToU64 = @import("database/metadata.zig").sqliteI64ToU64;

const copyStoreId = @import("database/bound_stores.zig").copyStoreId;

const hasActiveTransaction = @import("database/bound_stores.zig").hasActiveTransaction;

const rejectReservedZovaNames = @import("database/bound_stores.zig").rejectReservedZovaNames;

const isReservedZovaName = @import("database/bound_stores.zig").isReservedZovaName;

const backupMainDatabase = @import("database/backup.zig").backupMainDatabase;

pub fn verifyOperationalCopy(path: [:0]const u8, registry: ExtensionRegistry) Error!void {
    var db = try Database.openWithOptionsAndExtensions(path, .{ .read_only = true }, registry);
    defer db.deinit();

    try verifyCurrentDatabase(&db);
}

fn verifyCurrentDatabase(db: *Database) Error!void {
    try verifyQuickCheck(db);
    try verifyStoredObjects(db);
    try verifyStoredChunks(db);
    try verifyStoredVectors(db);
    try verifyStoredKv(db);
}

fn verifyQuickCheck(db: *Database) Error!void {
    try verifyQuickCheckMain(&db.sqlite_db);
    if (db.bound_object_store != null) try verifyQuickCheckAttached(&db.sqlite_db, bound_object_store_schema_name);
    if (db.bound_vector_store != null) try verifyQuickCheckAttached(&db.sqlite_db, bound_vector_store_schema_name);
    if (db.bound_graph_store != null) try verifyQuickCheckAttached(&db.sqlite_db, bound_graph_store_schema_name);
}

const verifyQuickCheckMain = @import("database/backup.zig").verifyQuickCheckMain;

const verifyQuickCheckAttached = @import("database/backup.zig").verifyQuickCheckAttached;

const expectQuickCheckOk = @import("database/backup.zig").expectQuickCheckOk;

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
        \\select c.name, v.vector_id
        \\from {s}_zova_vectors v
        \\join {s}_zova_vector_collections c on c.collection_key = v.collection_key
        \\order by c.name, v.vector_id
    , .{ prefix, prefix });
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

fn verifyStoredKv(db: *Database) Error!void {
    var stmt = try prepareSchemaSql(&db.sqlite_db,
        \\select namespace, key, value from _zova_kv order by namespace, key
    , .{});
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const namespace = stmt.columnBlob(0);
        const key = stmt.columnBlob(1);
        const value = stmt.columnBlob(2);
        _ = namespace;
        _ = key;
        _ = value;
    }
}

const mapSqliteResultCode = @import("database/metadata.zig").mapSqliteResultCode;

const validateZovaSchema = @import("database/validation.zig").validateZovaSchema;

const validateExtensionLifecycleCore = @import("database/validation.zig").validateExtensionLifecycleCore;

const validateExtensionSchema = @import("database/validation.zig").validateExtensionSchema;

const validateObjectSchema = @import("database/validation.zig").validateObjectSchema;

const validateObjectSchemaExpected = @import("database/validation.zig").validateObjectSchemaExpected;

const validateObjectSchemaSql = @import("database/validation.zig").validateObjectSchemaSql;

const validateVectorSchema = @import("database/validation.zig").validateVectorSchema;

const validateGraphSchema = @import("database/validation.zig").validateGraphSchema;

const validateKvSchema = @import("database/validation.zig").validateKvSchema;

const validateRequiredTable = @import("database/validation.zig").validateRequiredTable;

const tableExists = @import("database/metadata.zig").tableExists;

const tableColumnExists = @import("database/metadata.zig").tableColumnExists;

const schemaSqlEqual = @import("database/metadata.zig").schemaSqlEqual;

const skipAsciiWhitespace = @import("database/metadata.zig").skipAsciiWhitespace;

const MetadataKey = @import("database/metadata.zig").MetadataKey;

const expectMetadataValue = @import("database/metadata.zig").expectMetadataValue;

comptime {
    if (@import("builtin").is_test) {
        _ = @import("zova_tests.zig");
        _ = @import("database_lifecycle_tests.zig");
        _ = @import("database_transactions_tests.zig");
        _ = @import("database_bound_stores_tests.zig");
        _ = @import("database_notifications_tests.zig");
    }
}
