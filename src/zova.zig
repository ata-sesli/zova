//! Zova-owned database identity layer.
//!
//! This module is the first layer above the plain SQLite wrapper. A database
//! enters Zova mode by using a `.zova` file path through `zova.Database`.
//! The file is still a SQLite database underneath, but Zova validates private
//! metadata before treating it as a Zova-owned database.
//!
//! Zova 1.x preserves the explicit migration path documented in
//! `docs/storage-compatibility.md`. The current storage format is version `11`:
//! `_zova_meta.format_version = '11'` plus
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

const extension_dynamic_impl = @import("extension_dynamic.zig");

const extension_impl = @import("extension.zig");

const fastcdc = @import("object_fastcdc.zig");

const graph_impl = @import("graph.zig");

const graph_sql = @import("graph_sql.zig");

const kv_impl = @import("kv.zig");

const notify_impl = @import("notify.zig");

const object_impl = @import("object.zig");

const sqlite = @import("sqlite.zig");

const trgm_impl = @import("trgm.zig");

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

const graph_keyed_batch_savepoint = @import("database/types.zig").graph_keyed_batch_savepoint;

const GraphKeyedMutationScope = @import("database/types.zig").GraphKeyedMutationScope;

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
    after_main_copy,
    after_main_migration,
    after_store_copy,
    after_store_migration,
    after_validation,
    after_store_publication,
    before_main_publication,
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
    var main_reserved = false;
    errdefer if (!committed) {
        if (main_staging) |staging| {
            deleteDestinationFile(staging);
            allocator.free(staging);
            main_staging = null;
        }
        if (main_reserved) deleteDestinationFile(main_final.?);
        for (bindings[0..binding_count]) |*binding| {
            if (binding.staged) deleteDestinationFile(binding.staging_path);
            if (binding.reserved) deleteDestinationFile(binding.final_path);
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

        main_final = try allocator.dupeZ(u8, destination_path);
        try reserveDestinationZovaFile(main_final.?);
        main_reserved = true;
        for (bindings[0..binding_count]) |*binding| {
            const sibling = try migrationSiblingPath(allocator, destination_path, binding.suffix);
            allocator.free(binding.final_path);
            binding.final_path = sibling;
            try reserveDestinationZovaFile(binding.final_path);
            binding.reserved = true;
        }

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

        // Stage, copy-forward, and transform every member. Staging files are
        // exclusively created before use so a name collision can never open
        // or delete a caller's file. Copy and migration are separate phases
        // with their own fault boundaries.
        main_staging = try reserveMigrationStagingPath(allocator, main_final.?);
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
        for (bindings[0..binding_count]) |*binding| {
            const staged_path = try reserveMigrationStagingPath(allocator, binding.final_path);
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
    const cwd = std.Io.Dir.cwd();
    for (bindings[0..binding_count]) |*binding| {
        cwd.rename(binding.staging_path, cwd, binding.final_path, defaultIo()) catch return error.CantOpen;
        if (fault_hook) |hook| try hook(.after_store_publication);
    }

    if (fault_hook) |hook| try hook(.before_main_publication);
    cwd.rename(main_staging.?, cwd, main_final.?, defaultIo()) catch return error.CantOpen;

    committed = true;
    allocator.free(main_final.?);
    if (main_staging) |staging| allocator.free(staging);
    for (bindings[0..binding_count]) |*binding| binding.deinit(allocator);
    binding_count = 0;
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

/// Derive a unique hidden same-directory staging path for one final path.
///
/// Staging names keep the `.zova` extension so the staged set can be verified
/// through the full open path before publication.
/// Derive and exclusively create one staging file, retrying with fresh random
/// names on collision so a pre-existing caller file can never be opened or
/// deleted by this attempt.
const reserveMigrationStagingPath = @import("database/migration.zig").reserveMigrationStagingPath;

const migrationStagingPath = @import("database/migration.zig").migrationStagingPath;

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
/// and contain valid `_zova_meta` metadata before `open` accepts it. The
/// wrapped SQLite connection is kept public for now as a low-level escape hatch
/// consistent with the v0 SQLite wrapper.
pub const Database = struct {
    sqlite_db: sqlite.Database,
    notifications: *notify_impl.Hub,
    bound_object_store: ?BoundObjectStore = null,
    bound_vector_store: ?BoundVectorStore = null,
    bound_graph_store: ?BoundGraphStore = null,
    main_graph_edge_types: graph_impl.GraphEdgeTypeCache = .{},
    bound_graph_edge_types: graph_impl.GraphEdgeTypeCache = .{},
    kv_statements: kv_impl.StatementCache = .{},
    extension_registry: ExtensionRegistry = ExtensionRegistry.empty(),

    /// Create a new initialized `.zova` database.
    ///
    /// This never overwrites an existing file. The file is initialized with the
    /// private `_zova_meta` table, format version `11`, and the required
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

            const io = defaultIo();
            var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => return error.DestinationExists,
                else => return error.CantOpen,
            };
            file.close(io);

            errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
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
    pub fn openForExtensionInspection(path: [:0]const u8, options: OpenOptions) Error!Database {
        return openForExtensionInspectionWithExtensions(path, options, ExtensionRegistry.empty());
    }

    /// Open a database for diagnostic extension metadata inspection with
    /// process-registered extension code available to explicit checks.
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

    /// Return installed extension metadata sorted by extension name.
    pub fn listExtensions(self: *Database, allocator: std.mem.Allocator) Error!ExtensionList {
        return extension_impl.listInstalled(allocator, &self.sqlite_db);
    }

    /// Return the first extension-private SQLite object with no installed
    /// owner, if one exists.
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

    /// Upsert graph nodes in one transaction unless the caller owns one.
    pub fn putGraphNodes(self: *Database, inputs: []const GraphNodeInput) Error!void {
        const owns_transaction = try self.beginGraphBatchMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        try graphs.putGraphNodes(inputs);
        if (self.bound_graph_store != null and inputs.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBoundGraphMutation(owns_transaction);
        committed = true;
    }

    /// Upsert graph nodes atomically and return aligned opaque row keys.
    pub fn putGraphNodesKeyed(self: *Database, inputs: []const GraphNodeInput, out_keys: []i64) Error!void {
        if (out_keys.len != inputs.len) return error.InvalidArgument;
        const scope = try self.beginGraphKeyedMutation();
        var finished = false;
        errdefer if (!finished) self.rollbackGraphKeyedMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.putGraphNodesKeyed(inputs, out_keys);
        if (self.bound_graph_store != null and inputs.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishGraphKeyedMutation(scope);
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
        const scope = try self.beginGraphKeyedMutation();
        var finished = false;
        errdefer if (!finished) self.rollbackGraphKeyedMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.buildFreshGraphKeyedProfiled(graph_name, nodes, edges, temporary_node_keys, temporary_edge_keys, profile);
        if (self.bound_graph_store != null) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishGraphKeyedMutation(scope);
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
        const scope = try self.beginGraphKeyedMutation();
        var finished = false;
        errdefer if (!finished) self.rollbackGraphKeyedMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.buildFreshGraphPreparedKeyedProfiled(graph_name, nodes, edges, temporary_node_keys, temporary_edge_keys, profile);
        if (self.bound_graph_store != null) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishGraphKeyedMutation(scope);
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

    /// Delete graph nodes and all incident edges in one transaction unless the caller owns one.
    pub fn deleteGraphNodes(self: *Database, graph_name: []const u8, node_ids: []const []const u8) Error!void {
        const owns_transaction = try self.beginGraphBatchMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        try graphs.deleteGraphNodes(graph_name, node_ids);
        if (self.bound_graph_store != null and node_ids.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBoundGraphMutation(owns_transaction);
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

    /// Insert graph edges in one transaction unless the caller owns one.
    pub fn putGraphEdges(self: *Database, inputs: []const GraphEdgeInput) Error!void {
        self.invalidateActiveGraphEdgeTypes();
        const owns_transaction = try self.beginGraphBatchMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        try graphs.putGraphEdges(inputs);
        if (self.bound_graph_store != null and inputs.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBoundGraphMutation(owns_transaction);
        committed = true;
    }

    /// Insert graph edges atomically and return aligned opaque row keys.
    pub fn putGraphEdgesKeyed(self: *Database, inputs: []const GraphEdgeInput, out_keys: []i64) Error!void {
        self.invalidateActiveGraphEdgeTypes();
        if (out_keys.len != inputs.len) return error.InvalidArgument;
        const scope = try self.beginGraphKeyedMutation();
        var finished = false;
        errdefer if (!finished) self.rollbackGraphKeyedMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.putGraphEdgesKeyed(inputs, out_keys);
        if (self.bound_graph_store != null and inputs.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishGraphKeyedMutation(scope);
        finished = true;
    }

    pub fn graphEdgePayloadsGetMany(self: *Database, allocator: std.mem.Allocator, graph_name: []const u8, keys: []const i64) Error!GraphEdgePayloadLookupList {
        var graphs = self.graphDatabase();
        return try graphs.graphEdgePayloadsGetMany(allocator, graph_name, keys);
    }

    pub fn replaceGraphEdgePayloads(self: *Database, graph_name: []const u8, replacements: []const GraphEdgePayloadReplacement) Error!void {
        const scope = try self.beginGraphKeyedMutation();
        var finished = false;
        errdefer if (!finished) self.rollbackGraphKeyedMutation(scope) catch {};
        var graphs = self.graphDatabase();
        try graphs.replaceGraphEdgePayloads(graph_name, replacements);
        if (self.bound_graph_store != null and replacements.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishGraphKeyedMutation(scope);
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

    /// Delete graph edges in one transaction unless the caller owns one.
    /// Missing endpoints and edges are ignored for replay safety.
    pub fn deleteGraphEdges(self: *Database, inputs: []const GraphEdgeInput) Error!void {
        const owns_transaction = try self.beginGraphBatchMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};
        var graphs = self.graphDatabase();
        try graphs.deleteGraphEdges(inputs);
        if (self.bound_graph_store != null and inputs.len != 0) try incrementBoundGraphEpoch(&self.sqlite_db);
        try self.finishBoundGraphMutation(owns_transaction);
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
        try expectDone(&vacuum_stmt);

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

        const stored_path = try std.heap.c_allocator.dupeZ(u8, path);
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
        values: VectorValuesConst,
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

    /// Delete multiple vector rows atomically unless the caller owns the
    /// active transaction. Missing and duplicate ids are ignored.
    pub fn deleteVectors(
        self: *Database,
        collection_name: []const u8,
        vector_ids: []const []const u8,
    ) Error!void {
        const owns_transaction = try self.beginBoundVectorMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var vectors = self.vectorDatabase();
        try vectors.deleteVectors(collection_name, vector_ids);
        if (self.bound_vector_store != null and vector_ids.len != 0) try incrementBoundVectorEpoch(&self.sqlite_db);
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

    /// Store raw bytes using an explicitly selected storage profile.
    pub fn putObjectWithOptions(self: *Database, bytes: []const u8, options: ObjectPutOptions) Error!ObjectId {
        if (self.bound_object_store == null) {
            var objects = self.objectDatabase();
            return objects.putObjectWithOptions(bytes, options);
        }

        const id = objectId(bytes);
        const existed = try self.hasObject(id);
        const owns_transaction = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var objects = self.objectDatabase();
        const result = try objects.putObjectWithOptions(bytes, options);
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

    /// Store one verified loose chunk using an explicitly selected profile.
    pub fn putObjectChunkWithOptions(
        self: *Database,
        expected_hash: ObjectChunkId,
        bytes: []const u8,
        options: ObjectPutOptions,
    ) Error!void {
        const existed = if (self.bound_object_store != null) try self.hasObjectChunk(expected_hash) else false;
        const owns_transaction = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var objects = self.objectDatabase();
        try objects.putObjectChunkWithOptions(expected_hash, bytes, options);
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

    /// Assemble an object using an explicitly selected storage profile.
    pub fn assembleObjectFromChunksWithOptions(
        self: *Database,
        id: ObjectId,
        size_bytes: u64,
        chunks: []const ObjectChunk,
        options: ObjectPutOptions,
    ) Error!void {
        const owns_transaction = try self.beginBoundObjectMutation();
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var objects = self.objectDatabase();
        try objects.assembleObjectFromChunksWithOptions(id, size_bytes, chunks, options);
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

    fn beginBoundGraphMutation(self: *Database) Error!bool {
        if (self.bound_graph_store == null or hasActiveTransaction(&self.sqlite_db)) return false;
        try self.sqlite_db.beginImmediate();
        return true;
    }

    fn beginGraphBatchMutation(self: *Database) Error!bool {
        if (hasActiveTransaction(&self.sqlite_db)) return false;
        try self.sqlite_db.beginImmediate();
        return true;
    }

    fn beginGraphKeyedMutation(self: *Database) Error!GraphKeyedMutationScope {
        if (hasActiveTransaction(&self.sqlite_db)) {
            try self.sqlite_db.savepoint(graph_keyed_batch_savepoint);
            return .savepoint;
        }
        try self.sqlite_db.beginImmediate();
        return .transaction;
    }

    fn finishGraphKeyedMutation(self: *Database, scope: GraphKeyedMutationScope) Error!void {
        switch (scope) {
            .transaction => try self.sqlite_db.commit(),
            .savepoint => try self.sqlite_db.releaseSavepoint(graph_keyed_batch_savepoint),
        }
    }

    fn rollbackGraphKeyedMutation(self: *Database, scope: GraphKeyedMutationScope) Error!void {
        switch (scope) {
            .transaction => try self.sqlite_db.rollback(),
            .savepoint => {
                try self.sqlite_db.rollbackToSavepoint(graph_keyed_batch_savepoint);
                try self.sqlite_db.releaseSavepoint(graph_keyed_batch_savepoint);
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
        };
    }

    fn graphDatabase(self: *Database) graph_impl.Database {
        return .{
            .sqlite_db = &self.sqlite_db,
            .storage_schema = if (self.bound_graph_store != null) .graph_store else .main,
            .edge_type_cache = if (self.bound_graph_store != null) &self.bound_graph_edge_types else &self.main_graph_edge_types,
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

    fn detachBoundGraphStore(self: *Database) Error!void {
        if (self.bound_graph_store == null) return;
        try self.sqlite_db.detachDatabase(bound_graph_store_schema_name);
        self.bound_graph_store = null;
    }

    fn restoreConfiguredBoundGraphStore(self: *Database) Error!void {
        if (self.bound_graph_store != null) return;
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

const expectDone = @import("database/metadata.zig").expectDone;

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
        .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0, 0.0 } } },
        .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0, 0.0 } } },
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

    try expectOperationalFixtureHandle(&db, ids, primary_bytes, streamed_bytes, loose_bytes);
}

fn expectOperationalFixtureHandle(
    db: *Database,
    ids: OperationalFixtureIds,
    primary_bytes: []const u8,
    streamed_bytes: []const u8,
    loose_bytes: []const u8,
) !void {
    try testingQuickCheckOk(db);
    try testingIntegrityCheckOk(db);

    try std.testing.expectEqual(@as(i64, 2), try testingCount(db, "select count(*) from docs"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(db, "select count(*) from doc_log"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(db,
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
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0 }, vector.values.f32);

    var results = try db.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0, 0.0 } }, 2);
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

test "createMemory initializes complete schema without creating files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try Database.createMemory();
    defer db.deinit();

    var meta = try db.prepare("select value from _zova_meta where key = 'format_version'");
    defer meta.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings(format_version, meta.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try meta.step());

    var tables = try db.prepare(
        \\select count(*) from sqlite_master
        \\where type = 'table' and name in (
        \\  '_zova_extensions',
        \\  '_zova_objects',
        \\  '_zova_chunks',
        \\  '_zova_object_chunks',
        \\  '_zova_vector_collections',
        \\  '_zova_vectors',
        \\  '_zova_graphs',
        \\  '_zova_graph_nodes',
        \\  '_zova_graph_edge_types',
        \\  '_zova_graph_edges'
        \\)
    );
    defer tables.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try tables.step());
    try std.testing.expectEqual(@as(i64, 10), tables.columnInt64(0));
    try std.testing.expectEqual(sqlite.Step.done, try tables.step());

    const io = defaultIo();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const memory_base = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/memory.zova", .{tmp.sub_path[0..]});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, memory_base, .{}));
    var wal_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_buffer, ".zig-cache/tmp/{s}/memory.zova-wal", .{tmp.sub_path[0..]});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, wal_path, .{}));
    var journal_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const journal_path = try std.fmt.bufPrint(&journal_buffer, ".zig-cache/tmp/{s}/memory.zova-journal", .{tmp.sub_path[0..]});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, journal_path, .{}));
}

test "createMemory matches file backed records objects chunks and vectors" {
    var db = try Database.createMemory();
    defer db.deinit();

    const primary_bytes = "memory primary object bytes\x00with nul";
    const loose_bytes = "verified in-memory loose operational chunk";
    const streamed_bytes = try std.testing.allocator.alloc(u8, 140_000);
    defer std.testing.allocator.free(streamed_bytes);
    fillOperationalLargeFixture(streamed_bytes);

    const ids = try populateOperationalFixture(&db, primary_bytes, streamed_bytes, loose_bytes);
    try expectOperationalFixtureHandle(&db, ids, primary_bytes, streamed_bytes, loose_bytes);
}

test "in-memory database backups to a persistent zova file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "memory-backup.zova");

    const primary_bytes = "memory backup object bytes";
    const loose_bytes = "memory backup loose chunk";
    const streamed_bytes = try std.testing.allocator.alloc(u8, 140_000);
    defer std.testing.allocator.free(streamed_bytes);
    fillOperationalLargeFixture(streamed_bytes);

    const ids = blk: {
        var memory = try Database.createMemory();
        defer memory.deinit();
        const populated = try populateOperationalFixture(&memory, primary_bytes, streamed_bytes, loose_bytes);
        try memory.backupTo(backup_path, .{});
        break :blk populated;
    };

    try expectOperationalFixture(backup_path, ids, primary_bytes, streamed_bytes, loose_bytes);
}

test "restoreBackupToMemory restores schema and data into volatile memory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "memory-restore-source.zova");

    const primary_bytes = "file backed restore source object";
    const loose_bytes = "file backed restore source chunk";
    const streamed_bytes = try std.testing.allocator.alloc(u8, 140_000);
    defer std.testing.allocator.free(streamed_bytes);
    fillOperationalLargeFixture(streamed_bytes);

    const ids = blk: {
        var file = try Database.create(source_path);
        defer file.deinit();
        break :blk try populateOperationalFixture(&file, primary_bytes, streamed_bytes, loose_bytes);
    };

    var restored = try restoreBackupToMemory(source_path, .{});
    defer restored.deinit();

    try expectOperationalFixtureHandle(&restored, ids, primary_bytes, streamed_bytes, loose_bytes);
}

test "restoreBackupToMemory inlines bound object vector and graph stores with source parity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "memory-bound-restore-main.zova");
    var objects_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const objects_path = try testingDbPath(&objects_buffer, tmp.sub_path[0..], "memory-bound-restore-objects.zova");
    var vectors_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vectors_path = try testingDbPath(&vectors_buffer, tmp.sub_path[0..], "memory-bound-restore-vectors.zova");
    var graphs_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const graphs_path = try testingDbPath(&graphs_buffer, tmp.sub_path[0..], "memory-bound-restore-graphs.zova");

    try createObjectStore(objects_path);
    try createVectorStore(vectors_path);
    try createGraphStore(graphs_path);

    const object_bytes = "bound object inline restored into memory";
    const loose_bytes = "bound loose chunk inline restored into memory";

    const object_id = blk: {
        var db = try Database.create(main_path);
        defer db.deinit();
        try db.bindObjectStore(objects_path);
        try db.bindVectorStore(vectors_path);
        try db.bindGraphStore(graphs_path);

        const id = try db.putObject(object_bytes);
        const loose_chunk = objectChunkId("bound loose chunk inline restored into memory");
        try db.putObjectChunk(loose_chunk, loose_bytes);

        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVectors("docs", &.{
            .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0 } } },
            .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0 } } },
        });

        try db.createGraph("alpha");
        try db.putGraphNode(.{ .graph_name = "alpha", .node_id = "root", .kind = "document" });
        try db.putGraphNode(.{ .graph_name = "alpha", .node_id = "leaf", .kind = "note" });
        try db.putGraphEdge(.{ .graph_name = "alpha", .from_node_id = "root", .edge_type = "links", .to_node_id = "leaf" });

        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from object_store._zova_objects"));
        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors"));
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from vector_store._zova_vectors"));
        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_graph_nodes"));
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from graph_store._zova_graph_nodes"));
        break :blk id;
    };

    var restored = try restoreBackupToMemory(main_path, .{});
    defer restored.deinit();

    try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try restored.boundObjectStore(std.testing.allocator));
    try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try restored.boundVectorStore(std.testing.allocator));
    try std.testing.expectEqual(@as(?BoundGraphStoreInfo, null), try restored.boundGraphStore(std.testing.allocator));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&restored, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&restored, "select count(*) from _zova_vectors"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&restored, "select count(*) from _zova_graph_nodes"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&restored, "select count(*) from _zova_graph_edges"));

    var object = try restored.getObject(std.testing.allocator, object_id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, object_bytes, object.bytes);

    var chunk = try restored.getObjectChunk(std.testing.allocator, objectChunkId("bound loose chunk inline restored into memory"));
    defer chunk.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, loose_bytes, chunk.bytes);

    var results = try restored.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0 } }, 2);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("doc-a", results.items[0].id);

    var neighbors = try restored.graphNeighbors(std.testing.allocator, .{ .graph_name = "alpha", .node_id = "root", .limit = 10 });
    defer neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), neighbors.items.len);
    try std.testing.expectEqualStrings("leaf", neighbors.items[0].node_id);
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
    try std.testing.expectEqualStrings(format_version, meta.columnText(1));

    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings("magic", meta.columnText(0));
    try std.testing.expectEqualStrings("zova", meta.columnText(1));

    try std.testing.expectEqual(sqlite.Step.done, try meta.step());
}

test "current format reserves graph store metadata" {
    try std.testing.expectEqualStrings("11", format_version);
    try std.testing.expect(std.mem.indexOf(u8, bound_stores_schema_sql, "'graph_store'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bound_stores_schema_sql, "graph_epoch integer") != null);

    const result: SplitGraphStoreResult = .{
        .store_path = "graph.zova",
        .store_id = [_]u8{'0'} ** 64,
        .bound_set_id = [_]u8{'1'} ** 64,
        .copied = .{},
        .cleared = .{},
        .verified = true,
    };
    try std.testing.expectEqualStrings(bound_graph_store_role, result.role);
}

test "create graph store writes metadata and rejects main database open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-store.zova");

    try createGraphStore(store_path);

    {
        var raw = try sqlite.Database.open(store_path);
        defer raw.deinit();

        try testingExpectScalarText(&raw, "select value from _zova_meta where key = 'magic'", "zova");
        try testingExpectScalarText(&raw, "select value from _zova_meta where key = 'format_version'", "11");
        try testingExpectScalarText(&raw, "select value from _zova_meta where key = 'store_role'", "graph_store");
        try testingExpectScalarText(&raw, "select value from _zova_meta where key = 'graph_epoch'", "0");

        var store_id = try raw.prepare("select value from _zova_meta where key = 'store_id'");
        defer store_id.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try store_id.step());
        try std.testing.expect(isValidStoreId(store_id.columnText(0)));
        try std.testing.expectEqual(sqlite.Step.done, try store_id.step());
    }

    try std.testing.expectError(error.BoundStoreInvalid, Database.open(store_path));
}

test "bound graph epochs participate in transactions and skip empty batches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-epoch-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-epoch-store.zova");
    try createGraphStore(store_path);
    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindGraphStore(store_path);
    try db.createGraph("deps");
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));
    try db.putGraphNodes(&.{});
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));

    try db.begin();
    try db.putGraphNode(.{ .graph_name = "deps", .node_id = "rolled-back", .kind = "file" });
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select cast(value as integer) from graph_store._zova_meta where key = 'graph_epoch'"));
    try db.rollback();
    try std.testing.expect(!(try db.hasGraphNode("deps", "rolled-back")));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select cast(value as integer) from graph_store._zova_meta where key = 'graph_epoch'"));

    try db.savepoint("graph_epoch_rollback");
    try db.putGraphNode(.{ .graph_name = "deps", .node_id = "savepoint-rolled-back", .kind = "file" });
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select cast(value as integer) from graph_store._zova_meta where key = 'graph_epoch'"));
    try db.rollbackToSavepoint("graph_epoch_rollback");
    try db.releaseSavepoint("graph_epoch_rollback");
    try std.testing.expect(!(try db.hasGraphNode("deps", "savepoint-rolled-back")));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select cast(value as integer) from graph_store._zova_meta where key = 'graph_epoch'"));
}

test "unbound graph node batch rolls back earlier writes when a later write fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-unbound-batch-rollback.zova");
    var db = try Database.create(db_path);
    defer db.deinit();
    try db.createGraph("deps");
    try db.exec(
        \\create trigger reject_second_graph_node before insert on _zova_graph_nodes
        \\when new.node_id = 'second' begin select raise(abort, 'reject second'); end;
    );
    try std.testing.expectError(error.Constraint, db.putGraphNodes(&.{
        .{ .graph_name = "deps", .node_id = "first", .kind = "file" },
        .{ .graph_name = "deps", .node_id = "second", .kind = "file" },
    }));
    try std.testing.expect(!(try db.hasGraphNode("deps", "first")));
}

test "read only graph store management rejects bind replacement and unbind without state changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var empty_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const empty_path = try testingDbPath(&empty_buffer, tmp.sub_path[0..], "graph-read-only-empty.zova");
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-read-only-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-read-only-store.zova");
    var replacement_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const replacement_path = try testingDbPath(&replacement_buffer, tmp.sub_path[0..], "graph-read-only-replacement.zova");
    try createGraphStore(store_path);
    try createGraphStore(replacement_path);
    {
        var empty = try Database.create(empty_path);
        empty.deinit();
    }
    {
        var db = try Database.create(main_path);
        defer db.deinit();
        try db.bindGraphStore(store_path);
        try db.createGraph("visible");
    }
    {
        var empty = try Database.openWithOptions(empty_path, .{ .read_only = true });
        defer empty.deinit();
        try std.testing.expectError(error.ReadOnly, empty.bindGraphStore(store_path));
        try std.testing.expectEqual(@as(?BoundGraphStoreInfo, null), try empty.boundGraphStore(std.testing.allocator));
    }
    {
        var read_only = try Database.openWithOptions(main_path, .{ .read_only = true });
        defer read_only.deinit();
        var before = (try read_only.boundGraphStore(std.testing.allocator)).?;
        defer before.deinit(std.testing.allocator);
        try std.testing.expectError(error.ReadOnly, read_only.bindGraphStore(replacement_path));
        try std.testing.expectError(error.ReadOnly, read_only.unbindGraphStore());
        var after = (try read_only.boundGraphStore(std.testing.allocator)).?;
        defer after.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(before.path, after.path);
        try std.testing.expectEqualStrings(before.bound_set_id, after.bound_set_id);
        try std.testing.expect(try read_only.hasGraph("visible"));
    }
}

test "open validates configured graph store identity role and format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-open-validation-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-open-validation-store.zova");
    try createGraphStore(store_path);
    var expected_store_id: [64]u8 = undefined;
    var expected_bound_set_id: [64]u8 = undefined;
    {
        var db = try Database.create(main_path);
        defer db.deinit();
        try db.bindGraphStore(store_path);
        var info = (try db.boundGraphStore(std.testing.allocator)).?;
        defer info.deinit(std.testing.allocator);
        @memcpy(expected_store_id[0..], info.store_id);
        @memcpy(expected_bound_set_id[0..], info.bound_set_id);
    }
    {
        var raw = try sqlite.Database.open(main_path);
        defer raw.deinit();
        try raw.exec("update _zova_bound_stores set store_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' where role = 'graph_store'");
    }
    try std.testing.expectError(error.BoundStoreInvalid, Database.open(main_path));
    {
        var raw = try sqlite.Database.open(main_path);
        defer raw.deinit();
        var stmt = try raw.prepare("update _zova_bound_stores set store_id = ?, bound_set_id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' where role = 'graph_store'");
        defer stmt.deinit();
        try stmt.bindText(1, &expected_store_id);
        try expectDone(&stmt);
    }
    try std.testing.expectError(error.BoundStoreInvalid, Database.open(main_path));
    {
        var raw = try sqlite.Database.open(main_path);
        defer raw.deinit();
        var stmt = try raw.prepare("update _zova_bound_stores set bound_set_id = ? where role = 'graph_store'");
        defer stmt.deinit();
        try stmt.bindText(1, &expected_bound_set_id);
        try expectDone(&stmt);
    }
    {
        var raw = try sqlite.Database.open(store_path);
        defer raw.deinit();
        try raw.exec("update _zova_meta set value = 'vector_store' where key = 'store_role'");
    }
    try std.testing.expectError(error.NotZovaDatabase, Database.open(main_path));
    {
        var raw = try sqlite.Database.open(store_path);
        defer raw.deinit();
        try raw.exec("update _zova_meta set value = 'graph_store' where key = 'store_role'; update _zova_meta set value = '6' where key = 'format_version'");
    }
    try std.testing.expectError(error.UnsupportedZovaVersion, Database.open(main_path));
}

test "configured graph store attaches routes graph APIs and reopens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-store.zova");

    try createGraphStore(store_path);
    {
        var db = try Database.create(main_path);
        defer db.deinit();

        try ensureBoundStoreTable(&db.sqlite_db);
        try attachGraphStore(&db.sqlite_db, store_path, false);
        defer db.sqlite_db.detachDatabase(bound_graph_store_schema_name) catch {};

        const store_id = try validateAttachedGraphStoreAlloc(std.testing.allocator, &db.sqlite_db, bound_graph_store_schema_name);
        defer std.testing.allocator.free(store_id);
        var bound_set_id: [64]u8 = undefined;
        randomHex64(&bound_set_id);
        try setAttachedMetadataValue(&db.sqlite_db, bound_graph_store_schema_name, "bound_set_id", &bound_set_id);

        var insert = try db.sqlite_db.prepare(
            \\insert into _zova_bound_stores
            \\  (role, name, path, store_id, bound_set_id, object_epoch, vector_epoch, graph_epoch, created_at_unix)
            \\values ('graph_store', 'default', ?, ?, ?, null, null, 0, unixepoch())
        );
        defer insert.deinit();
        try insert.bindText(1, store_path);
        try insert.bindText(2, store_id);
        try insert.bindText(3, &bound_set_id);
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    {
        var db = try Database.open(main_path);
        defer db.deinit();
        try db.createGraph("deps");
        try db.putGraphNode(.{ .graph_name = "deps", .node_id = "a", .kind = "file" });
        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from main._zova_graphs"));
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from graph_store._zova_graphs"));
    }

    {
        var reopened = try Database.open(main_path);
        defer reopened.deinit();
        try std.testing.expect(try reopened.hasGraph("deps"));
        try std.testing.expect(try reopened.hasGraphNode("deps", "a"));
    }

    {
        var raw = try sqlite.Database.open(main_path);
        defer raw.deinit();
        try raw.exec("update _zova_bound_stores set graph_epoch = 1 where role = 'graph_store' and name = 'default'");
    }
    try std.testing.expectError(error.BoundStoreInvalid, Database.open(main_path));
}

test "created zova database stores required extension registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extensions-registry.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();

        var extensions = try db.listExtensions(std.testing.allocator);
        defer extensions.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), extensions.items.len);
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try std.testing.expect(try tableExists(&raw, "_zova_extensions"));
}

test "app registered extension installs checks registers sql and drops" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "registered-extension.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});

    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();

        try db.installExtension("test");

        var info = try db.extensionInfo(std.testing.allocator, "test");
        defer info.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("test", info.name);
        try std.testing.expectEqualStrings("0.1.0", info.version);
        try std.testing.expectEqualStrings("_zova_ext_test_", info.storage_prefix);

        try db.checkExtension("test");

        var scalar = try db.prepare("select zova_test_extension_value()");
        defer scalar.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
        try std.testing.expectEqual(@as(i64, 7), scalar.columnInt64(0));

        try std.testing.expect(try tableExists(&db.sqlite_db, "_zova_ext_test_meta"));
    }

    {
        var db = try Database.openWithExtensions(db_path, registry);
        defer db.deinit();
        try db.checkExtension("test");
        try db.dropExtension("test");
        try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_test_meta"));
        try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "test"));
    }
}

test "multiple app registered extensions register sql on one connection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "registered-extension-sql-multiple.zova");

    const registry = ExtensionRegistry.init(&.{ testExtension(), secondSqlExtension() });

    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();

        try db.installExtension("test");
        try db.installExtension("test_two");

        var scalar = try db.prepare("select zova_test_extension_value(), zova_test_extension_two_value()");
        defer scalar.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
        try std.testing.expectEqual(@as(i64, 7), scalar.columnInt64(0));
        try std.testing.expectEqual(@as(i64, 42), scalar.columnInt64(1));
    }

    {
        var db = try Database.openWithExtensions(db_path, registry);
        defer db.deinit();

        try db.checkExtension("test");
        try db.checkExtension("test_two");

        var scalar = try db.prepare("select zova_test_extension_value(), zova_test_extension_two_value()");
        defer scalar.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
        try std.testing.expectEqual(@as(i64, 7), scalar.columnInt64(0));
        try std.testing.expectEqual(@as(i64, 42), scalar.columnInt64(1));
    }
}

test "read only open registers extension sql and checks installed extension" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "registered-extension-read-only.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});
    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();
        try db.installExtension("test");
    }

    var db = try Database.openWithOptionsAndExtensions(db_path, .{ .read_only = true }, registry);
    defer db.deinit();

    try db.checkExtension("test");

    var scalar = try db.prepare("select zova_test_extension_value()");
    defer scalar.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
    try std.testing.expectEqual(@as(i64, 7), scalar.columnInt64(0));

    try std.testing.expectError(error.ReadOnly, db.exec("create table read_only_extension_write_blocked (id integer)"));
}

test "open with missing registered extension code fails clearly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-extension.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});
    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();
        try db.installExtension("test");
    }

    try std.testing.expectError(error.ExtensionUnavailable, Database.open(db_path));
}

test "extension inspection opens missing-code databases for metadata only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extension-inspection.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});
    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();
        try db.installExtension("test");
    }

    try std.testing.expectError(error.ExtensionUnavailable, Database.open(db_path));

    var inspected = try Database.openForExtensionInspection(db_path, .{});
    defer inspected.deinit();
    var extensions = try inspected.listExtensions(std.testing.allocator);
    defer extensions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), extensions.items.len);
    try std.testing.expectEqualStrings("test", extensions.items[0].name);
    try std.testing.expectError(error.ExtensionUnavailable, inspected.checkExtension("test"));
    try std.testing.expectError(error.ReadOnly, inspected.exec("create table inspection_write_blocked (id integer)"));
}

test "extension inspection diagnostics can run SQL-backed check hooks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extension-inspection-sql.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});
    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();
        try db.installExtension("test");
    }

    var inspected = try Database.openForExtensionInspectionWithExtensions(db_path, .{}, registry);
    defer inspected.deinit();
    try inspected.registerExtensionSqlForDiagnostics("test");
    try inspected.checkExtension("test");
}

test "extension registry is used for backup compact and restore verification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var restore_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "extension-copy-source.zova");
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "extension-copy-backup.zova");
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "extension-copy-compact.zova");
    const restore_path = try testingDbPath(&restore_buffer, tmp.sub_path[0..], "extension-copy-restore.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});

    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();
        try db.installExtension("test");

        try db.backupTo(backup_path, .{});
        try db.compactTo(compact_path, .{});
    }

    try restoreBackupWithExtensions(backup_path, restore_path, .{}, registry);

    for ([_][:0]const u8{ backup_path, compact_path, restore_path }) |copy_path| {
        var copy = try Database.openWithExtensions(copy_path, registry);
        defer copy.deinit();
        try copy.checkExtension("test");

        var scalar = try copy.prepare("select zova_test_extension_value()");
        defer scalar.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
        try std.testing.expectEqual(@as(i64, 7), scalar.columnInt64(0));
    }
}

test "extension manifests validate names prefixes and duplicate registry prefixes" {
    try extension_impl.validateManifest(.{
        .name = "compatible_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_compatible_abi_",
        .zova_abi_min = "1.0.0",
    });
    try extension_impl.validateManifest(.{
        .name = "current_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_current_abi_",
        .zova_abi_min = "1.0.0",
    });
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "malformed_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_malformed_abi_",
        .zova_abi_min = "0.23",
    }));
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "prefixed_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_prefixed_abi_",
        .zova_abi_min = "v0.23.0",
    }));
    var newer_abi_buffer: [32]u8 = undefined;
    const newer_abi = try std.fmt.bufPrint(&newer_abi_buffer, "{d}.{d}.0", .{
        version.abi_version_major,
        version.abi_version_minor + 1,
    });
    try std.testing.expectError(error.ExtensionIncompatible, extension_impl.validateManifest(.{
        .name = "newer_minor_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_newer_minor_abi_",
        .zova_abi_min = newer_abi,
    }));
    try std.testing.expectError(error.ExtensionIncompatible, extension_impl.validateManifest(.{
        .name = "different_major_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_different_major_abi_",
        .zova_abi_min = "2.0.0",
    }));

    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext__",
        .zova_abi_min = "1.0.0",
    }));
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "_zova_hidden",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext__zova_hidden_",
        .zova_abi_min = "1.0.0",
    }));
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "bad name",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_bad name_",
        .zova_abi_min = "1.0.0",
    }));
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "test",
        .version = "0.1.0",
        .storage_prefix = "_zova_objects",
        .zova_abi_min = "1.0.0",
    }));
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "optional",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_optional_",
        .zova_abi_min = "1.0.0",
        .required = false,
    }));

    const duplicate_one = testExtension();
    const duplicate_name = Extension{
        .manifest = .{
            .name = "test",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_test_two_",
            .zova_abi_min = "1.0.0",
        },
        .install = testExtensionInstall,
        .check = testExtensionCheck,
        .drop = testExtensionDrop,
    };
    try std.testing.expectError(error.ExtensionInvalid, ExtensionRegistry.init(&.{ duplicate_one, duplicate_name }).validate());

    const duplicate_two = Extension{
        .manifest = .{
            .name = "other",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_test_",
            .zova_abi_min = "1.0.0",
        },
        .install = testExtensionInstall,
        .check = testExtensionCheck,
        .drop = testExtensionDrop,
    };
    try std.testing.expectError(error.ExtensionInvalid, ExtensionRegistry.init(&.{ duplicate_one, duplicate_two }).validate());
}

test "extension registry rejects bundled trgm collisions before create or open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const trgm_collision = Extension{
        .manifest = .{
            .name = "trgm",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_trgm_",
            .zova_abi_min = "1.0.0",
        },
        .install = testExtensionInstall,
        .check = testExtensionCheck,
        .drop = testExtensionDrop,
    };
    const registry = ExtensionRegistry.init(&.{ bundled_extensions[0], trgm_collision });
    try std.testing.expectError(error.ExtensionInvalid, registry.validate());

    var create_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const create_path = try testingDbPath(&create_buffer, tmp.sub_path[0..], "extension-trgm-collision-create.zova");
    try std.testing.expectError(error.ExtensionInvalid, Database.createWithExtensions(create_path, registry));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(defaultIo(), create_path, .{}));

    var open_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const open_path = try testingDbPath(&open_buffer, tmp.sub_path[0..], "extension-trgm-collision-open.zova");
    {
        var db = try Database.create(open_path);
        defer db.deinit();
    }
    try std.testing.expectError(error.ExtensionInvalid, Database.openWithExtensions(open_path, registry));
}

test "extension duplicate install and failed hooks roll back cleanly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extension-rollback.zova");

    const registry = ExtensionRegistry.init(&.{ testExtension(), failingExtension(), registerFailingExtension() });
    var db = try Database.createWithExtensions(db_path, registry);
    defer db.deinit();

    try db.installExtension("test");
    try std.testing.expectError(error.ExtensionExists, db.installExtension("test"));

    try std.testing.expectError(error.ExtensionInvalid, db.installExtension("failing"));
    try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "failing"));
    try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_failing_meta"));

    try std.testing.expectError(error.ExtensionInvalid, db.installExtension("register_fail"));
    try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "register_fail"));
    try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_register_fail_meta"));
}

test "register_sql failure during open fails without mutating installed metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extension-register-open-fail.zova");

    const registry = ExtensionRegistry.init(&.{reopenRegisterFailExtension()});
    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();

        try db.installExtension("reopen_fail");
        var scalar = try db.prepare("select zova_reopen_fail_value()");
        defer scalar.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
        try std.testing.expectEqual(@as(i64, 13), scalar.columnInt64(0));
    }

    try std.testing.expectError(error.ExtensionInvalid, Database.openWithExtensions(db_path, registry));

    var inspected = try Database.openForExtensionInspectionWithExtensions(db_path, .{}, registry);
    defer inspected.deinit();

    var extensions = try inspected.listExtensions(std.testing.allocator);
    defer extensions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), extensions.items.len);
    try std.testing.expectEqualStrings("reopen_fail", extensions.items[0].name);

    var mode = try inspected.prepare("select value from _zova_ext_reopen_fail_meta where key = 'mode'");
    defer mode.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try mode.step());
    try std.testing.expectEqualStrings("fail", mode.columnText(0));
}

test "extension lifecycle audits namespace and drop cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var escape_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const escape_path = try testingDbPath(&escape_buffer, tmp.sub_path[0..], "extension-escape.zova");

    {
        const registry = ExtensionRegistry.init(&.{escapingExtension()});
        var db = try Database.createWithExtensions(escape_path, registry);
        defer db.deinit();

        try std.testing.expectError(error.ExtensionInvalid, db.installExtension("escape"));
        try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "escape"));
        try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_escape_meta"));
        try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_other_meta"));
    }

    var leaky_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const leaky_path = try testingDbPath(&leaky_buffer, tmp.sub_path[0..], "extension-leaky.zova");

    {
        const registry = ExtensionRegistry.init(&.{leakyDropExtension()});
        var db = try Database.createWithExtensions(leaky_path, registry);
        defer db.deinit();

        try db.installExtension("leaky");
        try std.testing.expect(try tableExists(&db.sqlite_db, "_zova_ext_leaky_meta"));
        try std.testing.expectError(error.ExtensionInvalid, db.dropExtension("leaky"));

        var info = try db.extensionInfo(std.testing.allocator, "leaky");
        defer info.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("leaky", info.name);
        try std.testing.expect(try tableExists(&db.sqlite_db, "_zova_ext_leaky_meta"));
    }

    var cross_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cross_path = try testingDbPath(&cross_buffer, tmp.sub_path[0..], "extension-cross-namespace.zova");

    {
        const registry = ExtensionRegistry.init(&.{ testExtension(), crossNamespaceExtension() });
        var db = try Database.createWithExtensions(cross_path, registry);
        defer db.deinit();

        try db.installExtension("test");
        try std.testing.expectError(error.ExtensionInvalid, db.installExtension("cross"));
        try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "cross"));
        try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_test_cross_meta"));
    }
}

test "extension salvage hook copies namespaced storage and installs destination metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "extension-salvage-source.zova");
    const destination_path = try testingDbPath(&destination_buffer, tmp.sub_path[0..], "extension-salvage-destination.zova");

    const registry = ExtensionRegistry.init(&.{salvageExtension()});
    var source = try Database.createWithExtensions(source_path, registry);
    defer source.deinit();
    try source.installExtension("salvage");

    var destination = try Database.createWithExtensions(destination_path, registry);
    defer destination.deinit();

    const result = try extension_impl.salvageInstalled(std.testing.allocator, &source.sqlite_db, &destination.sqlite_db, registry, .copy);
    try std.testing.expectEqual(@as(u64, 1), result.copied_extensions);
    try std.testing.expectEqual(@as(u64, 1), result.copied_private_objects);
    try std.testing.expectEqual(@as(u64, 0), result.skipped_extensions);
    try std.testing.expectEqual(@as(u64, 0), result.skipped_private_objects);
    try std.testing.expect(result.installed_in_destination);

    try std.testing.expect(try tableExists(&destination.sqlite_db, "_zova_ext_salvage_meta"));
    var info = try destination.extensionInfo(std.testing.allocator, "salvage");
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("salvage", info.name);
    try destination.checkExtension("salvage");
}

test "extension salvage hook rolls back storage outside its namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "extension-salvage-bad-source.zova");
    const destination_path = try testingDbPath(&destination_buffer, tmp.sub_path[0..], "extension-salvage-bad-destination.zova");

    const registry = ExtensionRegistry.init(&.{badSalvageExtension()});
    var source = try Database.createWithExtensions(source_path, registry);
    defer source.deinit();
    try source.installExtension("bad_salvage");

    var destination = try Database.createWithExtensions(destination_path, registry);
    defer destination.deinit();

    try std.testing.expectError(error.ExtensionInvalid, extension_impl.salvageInstalled(std.testing.allocator, &source.sqlite_db, &destination.sqlite_db, registry, .copy));
    try std.testing.expect(!try tableExists(&destination.sqlite_db, "_zova_ext_other_salvage_meta"));
    try std.testing.expectError(error.ExtensionNotFound, destination.extensionInfo(std.testing.allocator, "bad_salvage"));
}

fn testExtension() Extension {
    return .{
        .manifest = .{
            .name = "test",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_test_",
            .zova_abi_min = "1.0.0",
            .capabilities = "sql",
        },
        .install = testExtensionInstall,
        .check = testExtensionCheck,
        .drop = testExtensionDrop,
        .register_sql = testExtensionRegisterSql,
    };
}

fn salvageExtension() Extension {
    return .{
        .manifest = .{
            .name = "salvage",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_salvage_",
            .zova_abi_min = "1.0.0",
        },
        .install = salvageExtensionInstall,
        .check = salvageExtensionCheck,
        .drop = salvageExtensionDrop,
        .salvage = salvageExtensionSalvage,
    };
}

fn badSalvageExtension() Extension {
    return .{
        .manifest = .{
            .name = "bad_salvage",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_bad_salvage_",
            .zova_abi_min = "1.0.0",
        },
        .install = badSalvageExtensionInstall,
        .check = badSalvageExtensionCheck,
        .drop = badSalvageExtensionDrop,
        .salvage = badSalvageExtensionSalvage,
    };
}

fn failingExtension() Extension {
    return .{
        .manifest = .{
            .name = "failing",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_failing_",
            .zova_abi_min = "1.0.0",
        },
        .install = failingExtensionInstall,
        .check = testExtensionCheck,
        .drop = testExtensionDrop,
    };
}

fn registerFailingExtension() Extension {
    return .{
        .manifest = .{
            .name = "register_fail",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_register_fail_",
            .zova_abi_min = "1.0.0",
        },
        .install = registerFailingExtensionInstall,
        .check = registerFailingExtensionCheck,
        .drop = registerFailingExtensionDrop,
        .register_sql = registerFailingExtensionRegisterSql,
    };
}

fn reopenRegisterFailExtension() Extension {
    return .{
        .manifest = .{
            .name = "reopen_fail",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_reopen_fail_",
            .zova_abi_min = "1.0.0",
        },
        .install = reopenRegisterFailExtensionInstall,
        .check = reopenRegisterFailExtensionCheck,
        .drop = reopenRegisterFailExtensionDrop,
        .register_sql = reopenRegisterFailExtensionRegisterSql,
    };
}

fn secondSqlExtension() Extension {
    return .{
        .manifest = .{
            .name = "test_two",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_test_two_",
            .zova_abi_min = "1.0.0",
            .capabilities = "sql",
        },
        .install = secondSqlExtensionInstall,
        .check = secondSqlExtensionCheck,
        .drop = secondSqlExtensionDrop,
        .register_sql = secondSqlExtensionRegisterSql,
    };
}

fn escapingExtension() Extension {
    return .{
        .manifest = .{
            .name = "escape",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_escape_",
            .zova_abi_min = "1.0.0",
        },
        .install = escapingExtensionInstall,
        .check = escapingExtensionCheck,
        .drop = escapingExtensionDrop,
    };
}

fn leakyDropExtension() Extension {
    return .{
        .manifest = .{
            .name = "leaky",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_leaky_",
            .zova_abi_min = "1.0.0",
        },
        .install = leakyDropExtensionInstall,
        .check = leakyDropExtensionCheck,
        .drop = leakyDropExtensionDrop,
    };
}

fn crossNamespaceExtension() Extension {
    return .{
        .manifest = .{
            .name = "cross",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_cross_",
            .zova_abi_min = "1.0.0",
        },
        .install = crossNamespaceExtensionInstall,
        .check = crossNamespaceExtensionCheck,
        .drop = crossNamespaceExtensionDrop,
    };
}

fn testExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec(
        \\create table _zova_ext_test_meta (
        \\  key text primary key,
        \\  value text not null
        \\)
    );
    var stmt = try db.prepare("insert into _zova_ext_test_meta (key, value) values ('installed', ?)");
    defer stmt.deinit();
    try stmt.bindText(1, manifest.version);
    std.debug.assert((try stmt.step()) == .done);
}

fn testExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    var stmt = try db.prepare("select value from _zova_ext_test_meta where key = 'installed'");
    defer stmt.deinit();
    switch (try stmt.step()) {
        .row => {
            if (!std.mem.eql(u8, stmt.columnText(0), manifest.version)) return error.ExtensionInvalid;
        },
        .done => return error.ExtensionInvalid,
    }

    var scalar = try db.prepare("select zova_test_extension_value()");
    defer scalar.deinit();
    if ((try scalar.step()) != .row) return error.ExtensionInvalid;
    if (scalar.columnInt64(0) != 7) return error.ExtensionInvalid;
}

fn testExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table _zova_ext_test_meta");
}

fn testExtensionRegisterSql(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    const rc = sqlite.c.sqlite3_create_function_v2(
        db.handle,
        "zova_test_extension_value",
        0,
        sqlite.c.SQLITE_UTF8,
        null,
        testExtensionValueFunc,
        null,
        null,
        null,
    );
    if (rc != sqlite.c.SQLITE_OK) return error.SqliteError;
}

fn salvageExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_salvage_meta (key text primary key, value text not null)");
    var stmt = try db.prepare("insert into _zova_ext_salvage_meta (key, value) values ('installed', ?)");
    defer stmt.deinit();
    try stmt.bindText(1, manifest.version);
    std.debug.assert((try stmt.step()) == .done);
}

fn salvageExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    var stmt = try db.prepare("select value from _zova_ext_salvage_meta where key = 'installed'");
    defer stmt.deinit();
    switch (try stmt.step()) {
        .row => if (!std.mem.eql(u8, stmt.columnText(0), manifest.version)) return error.ExtensionInvalid,
        .done => return error.ExtensionInvalid,
    }
}

fn salvageExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table if exists _zova_ext_salvage_meta");
}

fn salvageExtensionSalvage(context: extension_impl.SalvageContext, manifest: ExtensionManifest) extension_impl.Error!extension_impl.SalvageResult {
    try extension_impl.validateManifest(manifest);
    _ = context.source;
    if (context.mode == .plan) {
        return .{ .copied_extensions = 1, .copied_private_objects = 1 };
    }
    const destination = context.destination orelse return error.ExtensionInvalid;
    try destination.exec("create table _zova_ext_salvage_meta (key text primary key, value text not null)");
    var stmt = try destination.prepare("insert into _zova_ext_salvage_meta (key, value) values ('installed', ?)");
    defer stmt.deinit();
    try stmt.bindText(1, manifest.version);
    std.debug.assert((try stmt.step()) == .done);
    return .{ .copied_extensions = 1, .copied_private_objects = 1, .installed_in_destination = true };
}

fn badSalvageExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_bad_salvage_meta (key text primary key, value text not null)");
}

fn badSalvageExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn badSalvageExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table if exists _zova_ext_bad_salvage_meta");
}

fn badSalvageExtensionSalvage(context: extension_impl.SalvageContext, manifest: ExtensionManifest) extension_impl.Error!extension_impl.SalvageResult {
    try extension_impl.validateManifest(manifest);
    const destination = context.destination orelse return error.ExtensionInvalid;
    try destination.exec("create table _zova_ext_other_salvage_meta (key text primary key, value text not null)");
    return .{ .copied_extensions = 1, .copied_private_objects = 1, .installed_in_destination = true };
}

fn failingExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_failing_meta (key text primary key, value text not null)");
    return error.ExtensionInvalid;
}

fn registerFailingExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_register_fail_meta (key text primary key, value text not null)");
}

fn registerFailingExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn registerFailingExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table _zova_ext_register_fail_meta");
}

fn registerFailingExtensionRegisterSql(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
    return error.ExtensionInvalid;
}

fn reopenRegisterFailExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_reopen_fail_meta (key text primary key, value text not null)");
    try db.exec("insert into _zova_ext_reopen_fail_meta (key, value) values ('mode', 'install')");
}

fn reopenRegisterFailExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    var stmt = try db.prepare("select value from _zova_ext_reopen_fail_meta where key = 'mode'");
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.ExtensionInvalid;
}

fn reopenRegisterFailExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table _zova_ext_reopen_fail_meta");
}

fn reopenRegisterFailExtensionRegisterSql(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    var mode = try db.prepare("select value from _zova_ext_reopen_fail_meta where key = 'mode'");
    defer mode.deinit();
    if ((try mode.step()) != .row) return error.ExtensionInvalid;
    if (std.mem.eql(u8, mode.columnText(0), "fail")) return error.ExtensionInvalid;

    const rc = sqlite.c.sqlite3_create_function_v2(
        db.handle,
        "zova_reopen_fail_value",
        0,
        sqlite.c.SQLITE_UTF8,
        null,
        reopenFailValueFunc,
        null,
        null,
        null,
    );
    if (rc != sqlite.c.SQLITE_OK) return error.SqliteError;
    try db.exec("update _zova_ext_reopen_fail_meta set value = 'fail' where key = 'mode'");
}

fn secondSqlExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_test_two_meta (key text primary key, value text not null)");
    var stmt = try db.prepare("insert into _zova_ext_test_two_meta (key, value) values ('installed', ?)");
    defer stmt.deinit();
    try stmt.bindText(1, manifest.version);
    std.debug.assert((try stmt.step()) == .done);
}

fn secondSqlExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    var stmt = try db.prepare("select value from _zova_ext_test_two_meta where key = 'installed'");
    defer stmt.deinit();
    switch (try stmt.step()) {
        .row => if (!std.mem.eql(u8, stmt.columnText(0), manifest.version)) return error.ExtensionInvalid,
        .done => return error.ExtensionInvalid,
    }

    var scalar = try db.prepare("select zova_test_extension_two_value()");
    defer scalar.deinit();
    if ((try scalar.step()) != .row) return error.ExtensionInvalid;
    if (scalar.columnInt64(0) != 42) return error.ExtensionInvalid;
}

fn secondSqlExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table _zova_ext_test_two_meta");
}

fn secondSqlExtensionRegisterSql(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    const rc = sqlite.c.sqlite3_create_function_v2(
        db.handle,
        "zova_test_extension_two_value",
        0,
        sqlite.c.SQLITE_UTF8,
        null,
        secondSqlExtensionValueFunc,
        null,
        null,
        null,
    );
    if (rc != sqlite.c.SQLITE_OK) return error.SqliteError;
}

fn escapingExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_escape_meta (key text primary key, value text not null)");
    try db.exec("create table _zova_ext_other_meta (key text primary key, value text not null)");
}

fn escapingExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn escapingExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table if exists _zova_ext_escape_meta");
    try db.exec("drop table if exists _zova_ext_other_meta");
}

fn leakyDropExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_leaky_meta (key text primary key, value text not null)");
}

fn leakyDropExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn leakyDropExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn crossNamespaceExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_test_cross_meta (key text primary key, value text not null)");
}

fn crossNamespaceExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn crossNamespaceExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table if exists _zova_ext_test_cross_meta");
}

fn testExtensionValueFunc(ctx: ?*sqlite.c.sqlite3_context, argc: c_int, argv: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    _ = argv;
    if (argc != 0) return;
    sqlite.c.sqlite3_result_int64(ctx, 7);
}

fn reopenFailValueFunc(ctx: ?*sqlite.c.sqlite3_context, argc: c_int, argv: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    _ = argv;
    if (argc != 0) return;
    sqlite.c.sqlite3_result_int64(ctx, 13);
}

fn secondSqlExtensionValueFunc(ctx: ?*sqlite.c.sqlite3_context, argc: c_int, argv: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    _ = argv;
    if (argc != 0) return;
    sqlite.c.sqlite3_result_int64(ctx, 42);
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

        try testingWriteMetadata(&raw, "zova", "7");
    }

    try std.testing.expectError(error.UnsupportedLegacyFormat, Database.open(db_path));
}

fn testingFileSha256(path: []const u8) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn testingCopySqliteFile(source_path: [:0]const u8, destination_path: [:0]const u8) !void {
    var source = try sqlite.Database.openWithFlags(source_path, .read_only);
    defer source.deinit();
    var destination = try sqlite.Database.open(destination_path);
    defer destination.deinit();
    try backupMainDatabase(&source, &destination);
}

test "older main graph and vector fixtures are rejected without mutation" {
    const fixtures = .{
        .{ .path = "tests/fixtures/empty-format-7.zova", .role = StorageRole.main, .open_error = error.UnsupportedLegacyFormat },
        .{ .path = "tests/fixtures/empty-graph-store-format-7.zova", .role = StorageRole.graph },
        .{ .path = "tests/fixtures/empty-vector-store-format-7.zova", .role = StorageRole.vector },
        .{ .path = "tests/fixtures/format-8.zova", .role = StorageRole.main, .open_error = error.UnsupportedLegacyFormat },
        .{ .path = "tests/fixtures/empty-graph-store-format-8.zova", .role = StorageRole.graph },
        .{ .path = "tests/fixtures/empty-vector-store-format-8.zova", .role = StorageRole.vector },
        .{ .path = "tests/fixtures/format-9.zova", .role = StorageRole.main, .open_error = error.MigrationRequired },
        .{ .path = "tests/fixtures/empty-graph-store-format-9.zova", .role = StorageRole.graph },
        .{ .path = "tests/fixtures/empty-vector-store-format-9.zova", .role = StorageRole.vector },
        .{ .path = "tests/fixtures/format-10.zova", .role = StorageRole.main, .open_error = error.MigrationRequired },
        .{ .path = "tests/fixtures/bound-main-format-10.objects.zova", .role = StorageRole.object },
        .{ .path = "tests/fixtures/empty-graph-store-format-10.zova", .role = StorageRole.graph },
        .{ .path = "tests/fixtures/empty-vector-store-format-10.zova", .role = StorageRole.vector },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (fixtures, 0..) |fixture, index| {
        var copy_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const copy_path = try std.fmt.bufPrintZ(&copy_buffer, ".zig-cache/tmp/{s}/old-format-copy-{d}.zova", .{ tmp.sub_path[0..], index });
        try testingCopySqliteFile(fixture.path, copy_path);
        const before = try testingFileSha256(copy_path);

        switch (fixture.role) {
            .main => try std.testing.expectError(fixture.open_error, Database.open(copy_path)),
            .graph => {
                var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const main_path = try std.fmt.bufPrintZ(&main_buffer, ".zig-cache/tmp/{s}/format-11-main-graph-{d}.zova", .{ tmp.sub_path[0..], index });
                var db = try Database.create(main_path);
                defer db.deinit();
                try std.testing.expectError(error.UnsupportedZovaVersion, db.bindGraphStore(copy_path));
            },
            .object => {
                var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const main_path = try std.fmt.bufPrintZ(&main_buffer, ".zig-cache/tmp/{s}/format-11-main-object-{d}.zova", .{ tmp.sub_path[0..], index });
                var db = try Database.create(main_path);
                defer db.deinit();
                try std.testing.expectError(error.UnsupportedZovaVersion, db.bindObjectStore(copy_path));
            },
            .vector => {
                var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const main_path = try std.fmt.bufPrintZ(&main_buffer, ".zig-cache/tmp/{s}/format-11-main-vector-{d}.zova", .{ tmp.sub_path[0..], index });
                var db = try Database.create(main_path);
                defer db.deinit();
                try std.testing.expectError(error.UnsupportedZovaVersion, db.bindVectorStore(copy_path));
            },
        }

        const after = try testingFileSha256(copy_path);
        try std.testing.expectEqualSlices(u8, &before, &after);
    }
}

const StorageRole = enum { main, object, graph, vector };

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
            \\insert into _zova_meta (key, value) values ('format_version', '12');
        );
    }

    try std.testing.expectError(error.UnsupportedFutureFormat, Database.open(db_path));
}

test "format version classification distinguishes current migratable legacy future and malformed" {
    try std.testing.expectEqual(FormatCompatibility.current, classifyFormatVersion(format_version).?);
    try std.testing.expectEqual(FormatCompatibility.current, classifyFormatVersion("11").?);
    try std.testing.expectEqual(FormatCompatibility.migratable, classifyFormatVersion("10").?);
    try std.testing.expectEqual(FormatCompatibility.migratable, classifyFormatVersion("9").?);
    try std.testing.expectEqual(FormatCompatibility.unsupported_legacy, classifyFormatVersion("8").?);
    try std.testing.expectEqual(FormatCompatibility.unsupported_legacy, classifyFormatVersion("7").?);
    try std.testing.expectEqual(FormatCompatibility.unsupported_legacy, classifyFormatVersion("2").?);
    try std.testing.expectEqual(FormatCompatibility.unsupported_future, classifyFormatVersion("12").?);
    try std.testing.expectEqual(FormatCompatibility.unsupported_future, classifyFormatVersion("999").?);

    const malformed = [_][]const u8{
        "",
        "ten",
        "Ten",
        "9x",
        "x9",
        "+9",
        "-1",
        " 10",
        "10 ",
        "4294967296",
        "0x9",
    };
    for (malformed) |value| {
        try std.testing.expectEqual(@as(?FormatCompatibility, null), classifyFormatVersion(value));
    }
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

    try std.testing.expectError(error.UnsupportedLegacyFormat, Database.open(db_path));
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

test "split graph store and operational copies preserve graph storage and traversal order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "split-graph-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "split-graph-store.zova");
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "split-graph-backup.zova");
    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "split-graph-compact.zova");
    var restore_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restore_path = try testingDbPath(&restore_buffer, tmp.sub_path[0..], "split-graph-restore.zova");

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.createGraph("alpha");
    try db.createGraph("beta");
    try db.putGraphNode(.{ .graph_name = "alpha", .node_id = "root", .kind = "document", .target_type = .record, .target_namespace = "docs", .target_ref = "1" });
    try db.putGraphNode(.{ .graph_name = "alpha", .node_id = "object", .kind = "blob", .target_type = .object, .target_ref = "abc" });
    try db.putGraphNode(.{ .graph_name = "alpha", .node_id = "external", .kind = "link", .target_type = .external, .target_namespace = "web", .target_ref = "https://example.test" });
    try db.putGraphNode(.{ .graph_name = "beta", .node_id = "plain", .kind = "note" });
    try db.putGraphEdge(.{ .graph_name = "alpha", .from_node_id = "root", .edge_type = "second", .to_node_id = "external" });
    try db.putGraphEdge(.{ .graph_name = "alpha", .from_node_id = "root", .edge_type = "first", .to_node_id = "object" });
    try db.putGraphEdge(.{ .graph_name = "alpha", .from_node_id = "object", .edge_type = "links", .to_node_id = "external" });

    var before = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "alpha", .node_id = "root", .limit = 10 });
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("external", before.items[0].node_id);
    try std.testing.expectEqualStrings("object", before.items[1].node_id);

    const result = try db.splitGraphStore(store_path);
    try std.testing.expectEqual(@as(u64, 2), result.copied.graphs);
    try std.testing.expectEqual(@as(u64, 4), result.copied.nodes);
    try std.testing.expectEqual(@as(u64, 3), result.copied.edges);
    try std.testing.expectEqual(result.copied, result.cleared);
    try std.testing.expect(result.verified);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_graphs"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_graph_nodes"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_graph_edges"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&db, "select count(*) from graph_store._zova_graph_nodes"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(&db, "select count(*) from graph_store._zova_graph_edges"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(
        &db,
        "select count(*) from graph_store._zova_graph_nodes n join graph_store._zova_graphs g on g.graph_key=n.graph_key where g.name='alpha' and n.node_id='root' and n.created_order=1",
    ));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(
        &db,
        "select count(*) from graph_store._zova_graph_edges e join graph_store._zova_graphs g on g.graph_key=e.graph_key join graph_store._zova_graph_edge_types et on et.graph_key=e.graph_key and et.edge_type_key=e.edge_type_key where g.name='alpha' and et.name='second' and e.created_order=1",
    ));

    var after = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "alpha", .node_id = "root", .limit = 10 });
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(before.items[0].node_id, after.items[0].node_id);
    try std.testing.expectEqualStrings(before.items[1].node_id, after.items[1].node_id);
    var object = try db.getGraphNode(std.testing.allocator, "alpha", "object");
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqual(GraphTargetType.object, object.target_type);
    try std.testing.expectEqualStrings("abc", object.target_ref.?);

    try db.backupTo(backup_path, .{});
    try db.compactTo(compact_path, .{});
    try restoreBackup(main_path, restore_path, .{});
    const copy_paths = [_][:0]const u8{ backup_path, compact_path, restore_path };
    for (copy_paths) |copy_path| {
        var copy = try Database.open(copy_path);
        defer copy.deinit();
        try std.testing.expectEqual(@as(?BoundGraphStoreInfo, null), try copy.boundGraphStore(std.testing.allocator));
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&copy, "select count(*) from _zova_graphs"));
        var neighbors = try copy.graphNeighbors(std.testing.allocator, .{ .graph_name = "alpha", .node_id = "root", .limit = 10 });
        defer neighbors.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("external", neighbors.items[0].node_id);
        try std.testing.expectEqualStrings("object", neighbors.items[1].node_id);
    }
}

test "failed graph split removes destination and keeps main graph storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "split-graph-failure-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "split-graph-failure-store.zova");

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.createGraph("broken");
    try db.putGraphNode(.{ .graph_name = "broken", .node_id = "node", .kind = "note" });
    try db.exec("pragma ignore_check_constraints = on");
    try db.exec("update _zova_graph_nodes set target_type = 'invalid' where node_id = 'node'");
    try db.exec("pragma ignore_check_constraints = off");

    try std.testing.expectError(error.Constraint, db.splitGraphStore(store_path));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(defaultIo(), store_path, .{}));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_graphs"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_graph_nodes"));
    try std.testing.expectEqual(@as(?BoundGraphStoreInfo, null), try db.boundGraphStore(std.testing.allocator));
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
            .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0 } } },
            .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0 } } },
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

        var results = try reopened.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0 } }, 2);
        defer results.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), results.items.len);
        try std.testing.expectEqualStrings("doc-a", results.items[0].id);

        try reopened.unbindVectorStore();
        try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try reopened.boundVectorStore(std.testing.allocator));
        try std.testing.expectError(error.VectorCollectionNotFound, reopened.getVector(std.testing.allocator, "docs", "doc-a"));

        try reopened.bindVectorStore(store_path);
        var rebound = try reopened.getVector(std.testing.allocator, "docs", "doc-a");
        defer rebound.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0 }, rebound.values.f32);
    }

    {
        var read_only = try Database.openWithOptions(main_path, .{ .read_only = true });
        defer read_only.deinit();

        var vector = try read_only.getVector(std.testing.allocator, "docs", "doc-b");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 0.0, 2.0 }, vector.values.f32);
        try std.testing.expectError(error.ReadOnly, read_only.putVector("docs", "read-only", .{ .f32 = &.{ 1.0, 1.0 } }));
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
    try db.putVector("docs", "v1", .{ .f32 = &.{ 1.0, 2.0 } });
    try expectBoundVectorEpoch(&db, 2);

    var read_vector = try db.getVector(std.testing.allocator, "docs", "v1");
    read_vector.deinit(std.testing.allocator);
    try expectBoundVectorEpoch(&db, 2);

    try db.exec("create table notes (body text)");
    try db.exec("insert into notes (body) values ('raw user sql')");
    try expectBoundVectorEpoch(&db, 2);

    try db.beginImmediate();
    try db.putVector("docs", "rolled-back", .{ .f32 = &.{ 3.0, 4.0 } });
    try expectBoundVectorEpoch(&db, 3);
    try db.rollback();
    try expectBoundVectorEpoch(&db, 2);
    try std.testing.expectError(error.VectorNotFound, db.getVector(std.testing.allocator, "docs", "rolled-back"));

    try db.beginImmediate();
    try db.savepoint("sp");
    try db.putVector("docs", "savepoint-rolled-back", .{ .f32 = &.{ 5.0, 6.0 } });
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
        .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0 } } },
        .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0 } } },
    });
    try db.createVectorCollection("bytes", .{ .dimensions = 2, .metric = .l2, .element_type = .i8 });
    try db.putVectors("bytes", &.{
        .{ .id = "byte-a", .values = .{ .i8 = &.{ @as(i8, 1), @as(i8, -1) } } },
        .{ .id = "byte-b", .values = .{ .i8 = &.{ @as(i8, 5), @as(i8, -1) } } },
    });
    try db.createVectorCollection("halves", .{ .dimensions = 2, .metric = .l2, .element_type = .f16 });
    try db.putVector("halves", "half-one", .{ .f16 = &.{ 0x3c00, 0x0000 } });
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors"));
    try std.testing.expectEqual(@as(i64, 5), try testingCount(&db, "select count(*) from vector_store._zova_vectors"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.getVector(std.testing.allocator, "stale", "main-only"));

    try db.backupTo(backup_path, .{});
    try db.compactTo(compact_path, .{});
    try restoreBackup(main_path, restore_path, .{});

    const copy_paths = [_][:0]const u8{ backup_path, compact_path, restore_path };
    for (copy_paths) |copy_path| {
        var copy = try Database.open(copy_path);
        defer copy.deinit();

        try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try copy.boundVectorStore(std.testing.allocator));
        try std.testing.expectEqual(@as(i64, 5), try testingCount(&copy, "select count(*) from _zova_vectors"));

        var results = try copy.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0 } }, 2);
        defer results.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), results.items.len);
        try std.testing.expectEqualStrings("doc-a", results.items[0].id);

        var bytes_info = try copy.vectorCollectionInfo(std.testing.allocator, "bytes");
        defer bytes_info.deinit(std.testing.allocator);
        try std.testing.expectEqual(vector_impl.VectorElementType.i8, bytes_info.element_type);

        var byte_vector = try copy.getVector(std.testing.allocator, "bytes", "byte-a");
        defer byte_vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(i8, &.{ @as(i8, 1), @as(i8, -1) }, byte_vector.values.i8);

        var half_vector = try copy.getVector(std.testing.allocator, "halves", "half-one");
        defer half_vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u16, &.{ 0x3c00, 0x0000 }, half_vector.values.f16);

        var byte_results = try copy.searchVectors(std.testing.allocator, "bytes", .{ .i8 = &.{ @as(i8, 0), @as(i8, 0) } }, 2);
        defer byte_results.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), byte_results.items.len);
        try std.testing.expectEqualStrings("byte-a", byte_results.items[0].id);
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
        .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0 } } },
        .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0 } } },
    });
    try db.createVectorCollection("bytes", .{ .dimensions = 2, .metric = .l2, .element_type = .i8 });
    try db.putVectors("bytes", &.{
        .{ .id = "byte-a", .values = .{ .i8 = &.{ @as(i8, 1), @as(i8, 0) } } },
        .{ .id = "byte-b", .values = .{ .i8 = &.{ @as(i8, 5), @as(i8, 0) } } },
    });
    try db.createGraph("split_vectors");
    try db.putGraphNode(.{ .graph_name = "split_vectors", .node_id = "doc:a", .kind = "document", .target_type = .record, .target_namespace = "documents", .target_ref = "doc-a" });
    try db.putGraphNode(.{ .graph_name = "split_vectors", .node_id = "vector:doc-a", .kind = "embedding", .target_type = .vector, .target_namespace = "docs", .target_ref = "doc-a" });
    try db.putGraphEdge(.{ .graph_name = "split_vectors", .from_node_id = "doc:a", .edge_type = "embedded_as", .to_node_id = "vector:doc-a" });
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from _zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&db, "select count(*) from _zova_vectors"));

    const result = try db.splitVectorStore(store_path);
    try std.testing.expectEqualStrings(bound_vector_store_role, result.role);
    try std.testing.expect(result.verified);
    try std.testing.expectEqual(@as(u64, 2), result.copied.vector_collections);
    try std.testing.expectEqual(@as(u64, 4), result.copied.vectors);
    try std.testing.expectEqual(result.copied, result.cleared);
    try std.testing.expect(isValidStoreId(&result.store_id));
    try std.testing.expect(isValidStoreId(&result.bound_set_id));

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from vector_store._zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&db, "select count(*) from vector_store._zova_vectors"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from documents"));

    var results = try db.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0 } }, 2);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("doc-a", results.items[0].id);
    try std.testing.expect(try db.hasGraphNode("split_vectors", "vector:doc-a"));
    try std.testing.expect(try db.hasGraphEdge("split_vectors", "doc:a", "embedded_as", "vector:doc-a"));

    var byte_vector = try db.getVector(std.testing.allocator, "bytes", "byte-a");
    defer byte_vector.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(i8, &.{ @as(i8, 1), @as(i8, 0) }, byte_vector.values.i8);

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
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&backup, "select count(*) from _zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&backup, "select count(*) from _zova_vectors"));
    try std.testing.expect(try backup.hasGraphEdge("split_vectors", "doc:a", "embedded_as", "vector:doc-a"));

    var backup_bytes = try backup.vectorCollectionInfo(std.testing.allocator, "bytes");
    defer backup_bytes.deinit(std.testing.allocator);
    try std.testing.expectEqual(vector_impl.VectorElementType.i8, backup_bytes.element_type);
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

test "open rejects current format database missing required object table without mutating it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-object-table.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
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

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
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

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
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

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
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

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
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

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
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
    try std.testing.expectEqualStrings(format_version, meta.columnText(0));

    try testingExpectTableCount(&raw, "_zova_objects", 1);
    try testingExpectTableCount(&raw, "_zova_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_vector_collections", 1);
    try testingExpectTableCount(&raw, "_zova_vectors", 1);
    try testingExpectTableCount(&raw, "_zova_graphs", 1);
    try testingExpectTableCount(&raw, "_zova_graph_nodes", 1);
    try testingExpectTableCount(&raw, "_zova_graph_edges", 1);
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

test "in-memory notifications follow transaction savepoint and overflow semantics" {
    var db = try Database.createMemory();
    defer db.deinit();

    var sub = try db.listen("cache:search-results");
    defer sub.deinit();

    try db.notify("cache:search-results", "outside");
    var outside_note = (try sub.tryReceive(std.testing.allocator)).?;
    defer outside_note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cache:search-results", outside_note.channel);
    try std.testing.expectEqualStrings("outside", outside_note.payload);

    try db.beginImmediate();
    try db.notify("cache:search-results", "committed");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("committed", note.payload);
    }

    try db.beginImmediate();
    try db.savepoint("inner");
    try db.notify("cache:search-results", "discarded");
    try db.rollbackToSavepoint("inner");
    try db.notify("cache:search-results", "kept");
    try db.releaseSavepoint("inner");
    try db.rollback();
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));

    var index: usize = 0;
    while (index < notify_impl.queue_capacity + 1) : (index += 1) {
        var payload_buffer: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buffer, "event-{d}", .{index});
        try db.notify("cache:search-results", payload);
    }
    var overflowed = (try sub.tryReceive(std.testing.allocator)).?;
    defer overflowed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event-1", overflowed.payload);
    try std.testing.expectEqual(@as(u64, 1), overflowed.dropped_before);
}

test "notifications defer across one transaction spanning SQL vector graph and kv" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .cosine });
    try db.createGraph("app");

    var sub = try db.listen("app:changed");
    defer sub.deinit();

    try db.beginImmediate();
    try db.exec("insert into _zova_meta (key, value) values ('app:version', '2')");
    try db.putVectors("chunks", &.{.{ .id = "vec-1", .values = .{ .f32 = &.{ 1.0, 2.0 } } }});
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "node-a", .kind = "entity" });
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "node-b", .kind = "entity" });
    try db.putGraphEdge(.{ .graph_name = "app", .from_node_id = "node-a", .edge_type = "links", .to_node_id = "node-b" });
    try db.kvPut("app", "key", "value");
    try db.notify("app:changed", "all-subsystems");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();

    var note = (try sub.tryReceive(std.testing.allocator)).?;
    defer note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("app:changed", note.channel);
    try std.testing.expectEqualStrings("all-subsystems", note.payload);
    try std.testing.expectEqual(@as(u64, 1), note.sequence);

    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_meta where key = 'app:version'"));
    try std.testing.expect(try db.hasGraphNode("app", "node-a"));
    try std.testing.expect(try db.hasGraphEdge("app", "node-a", "links", "node-b"));
    var kv_value = try db.kvGet(std.testing.allocator, "app", "key");
    defer kv_value.deinit(std.testing.allocator);
    try std.testing.expect(kv_value.found);
    try std.testing.expectEqualSlices(u8, "value", kv_value.value);
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

test "conversion rejects extension private source names and cleans destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "extension-private-source.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "extension-private-source.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec(
            \\create table _zova_ext_external_documents (
            \\  id integer primary key,
            \\  body text not null
            \\)
        );
    }

    try std.testing.expectError(error.ZovaNameConflict, convertSqliteToZova(source_path, dest_path));
    try std.testing.expectError(error.NotZovaDatabase, Database.open(dest_path));
}

comptime {
    if (@import("builtin").is_test) {
        _ = @import("database_lifecycle_tests.zig");
        _ = @import("database_transactions_tests.zig");
        _ = @import("database_bound_stores_tests.zig");
        _ = @import("database_notifications_tests.zig");
    }
}
