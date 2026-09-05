//! Database option, identity, and result types shared by the facade and internal modules.

const std = @import("std");
const extension_dynamic_impl = @import("../extension_dynamic.zig");
const extension_impl = @import("../extension.zig");
const graph_impl = @import("../graph.zig");
const kv_impl = @import("../kv.zig");
const notify_impl = @import("../notify.zig");
const object_impl = @import("../object.zig");
const sqlite = @import("../sqlite.zig");
const trgm_impl = @import("../trgm.zig");
const vector_impl = @import("../vector.zig");
const version = @import("../version.zig");
const zova_error = @import("../zova_error.zig");

const metadata_table = "_zova_meta";

const objects_table = "_zova_objects";

const chunks_table = "_zova_chunks";

const object_chunks_table = "_zova_object_chunks";

const kv_table = kv_impl.kv_table;

pub const bound_stores_table = "_zova_bound_stores";

pub const magic_value = "zova";

pub const format_version = version.format_version;

pub const minimum_migratable_format = "9";

/// Compatibility class assigned to a Zova storage format version.
///
/// `migratable` marks formats this release can migrate explicitly into the
/// current format; `unsupported_legacy` marks formats older than the earliest
/// migratable format, and `unsupported_future` marks formats newer than this
/// release.
pub const FormatCompatibility = enum {
    current,
    migratable,
    unsupported_legacy,
    unsupported_future,
};

/// Non-mutating classification result for one Zova database file.
///
/// `format_version` is the strictly parsed `_zova_meta.format_version` value
/// and `compatibility` is how this release treats that format.
pub const DatabaseFormatInfo = struct {
    format_version: u32,
    compatibility: FormatCompatibility,
};

/// One registered storage-format migration.
///
/// Steps are keyed by exact `(from, to)` versions and must be adjacent:
/// `to == from + 1`. There is deliberately no catch-all upgrader and no way to
/// skip versions; migrating across several formats applies one registered step
/// at a time.
pub const MigrationStep = struct {
    from_version: u32,
    to_version: u32,
    apply: *const fn (db: *sqlite.Database) Error!void,
};

pub const bound_object_store_role = "object_store";

pub const bound_vector_store_role = "vector_store";

pub const bound_graph_store_role = "graph_store";

pub const graph_keyed_batch_savepoint = "zova_graph_keyed_batch";

pub const GraphKeyedMutationScope = enum { transaction, savepoint };

const bound_object_store_name = "default";

const bound_vector_store_name = "default";

const bound_graph_store_name = "default";

pub const bound_object_store_schema_name = "object_store";

pub const bound_vector_store_schema_name = "vector_store";

pub const bound_graph_store_schema_name = "graph_store";

pub const bundled_extensions = [_]extension_impl.Extension{
    trgm_impl.extension(),
};

pub const bound_stores_schema_sql =
    \\create table _zova_bound_stores (
    \\  role text not null check (role in ('object_store', 'vector_store', 'graph_store')),
    \\  name text not null check (name = 'default'),
    \\  path text not null,
    \\  store_id text not null check (length(store_id) = 64),
    \\  bound_set_id text not null check (length(bound_set_id) = 64),
    \\  object_epoch integer check (object_epoch is null or object_epoch >= 0),
    \\  vector_epoch integer check (vector_epoch is null or vector_epoch >= 0),
    \\  graph_epoch integer check (graph_epoch is null or graph_epoch >= 0),
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

/// Physical object chunking profile. Existing methods use `.deduplication`;
/// `.streaming` stores fixed 1 MiB chunks for large sequential workloads.
pub const ObjectStorageProfile = object_impl.ObjectStorageProfile;

pub const ObjectPutOptions = object_impl.ObjectPutOptions;

pub const ObjectReaderError = object_impl.ObjectReaderError;

pub const KvPutEntry = kv_impl.PutEntry;

pub const Error = zova_error.Error;

/// Options applied only while creating a fresh Zova database.
pub const CreateOptions = struct {
    /// SQLite page size selected before Zova creates its private schema.
    /// Zero preserves SQLite's default page size.
    page_size: u32 = 0,
};

pub const max_vector_dimensions = vector_impl.max_vector_dimensions;

pub const VectorMetric = vector_impl.VectorMetric;

pub const VectorElementType = vector_impl.VectorElementType;

pub const VectorCollectionOptions = vector_impl.VectorCollectionOptions;

pub const VectorCollectionInfo = vector_impl.VectorCollectionInfo;

pub const VectorCollectionList = vector_impl.VectorCollectionList;

pub const VectorInput = vector_impl.VectorInput;

pub const VectorValuesConst = vector_impl.VectorValuesConst;

pub const VectorValuesOwned = vector_impl.VectorValuesOwned;

pub const Vector = vector_impl.Vector;

pub const VectorSearchResult = vector_impl.VectorSearchResult;

pub const VectorSearchResults = vector_impl.VectorSearchResults;

pub const MultiI8CosineSearchMode = vector_impl.MultiI8CosineSearchMode;

pub const MultiI8CosineSearchOptions = vector_impl.MultiI8CosineSearchOptions;

pub const Notification = notify_impl.Notification;

pub const NotificationSubscription = notify_impl.NotificationSubscription;

pub const GraphTargetType = graph_impl.GraphTargetType;

pub const GraphInfo = graph_impl.GraphInfo;

pub const GraphList = graph_impl.GraphList;

pub const GraphNodeInput = graph_impl.GraphNodeInput;

pub const FreshGraphNodeInput = graph_impl.FreshGraphNodeInput;

pub const GraphNode = graph_impl.GraphNode;

pub const GraphEdgeInput = graph_impl.GraphEdgeInput;

pub const FreshGraphEdgeInput = graph_impl.FreshGraphEdgeInput;

pub const FreshGraphBuildProfile = graph_impl.FreshGraphBuildProfile;

pub const GraphEdgePayloadReplacement = graph_impl.GraphEdgePayloadReplacement;

pub const GraphEdgePayloadLookup = graph_impl.GraphEdgePayloadLookup;

pub const GraphEdgePayloadLookupList = graph_impl.GraphEdgePayloadLookupList;

pub const GraphEdge = graph_impl.GraphEdge;

pub const GraphNeighborDirection = graph_impl.GraphNeighborDirection;

pub const GraphNeighborsOptions = graph_impl.GraphNeighborsOptions;

pub const GraphDegreeOptions = graph_impl.GraphDegreeOptions;

pub const GraphNeighbor = graph_impl.GraphNeighbor;

pub const GraphNeighborList = graph_impl.GraphNeighborList;

pub const GraphKeyedNeighbor = graph_impl.GraphKeyedNeighbor;

pub const GraphKeyedNeighborList = graph_impl.GraphKeyedNeighborList;

pub const GraphKeyedNodeLookup = graph_impl.GraphKeyedNodeLookup;

pub const GraphKeyedNodeLookupList = graph_impl.GraphKeyedNodeLookupList;

pub const GraphKeyedEdgeLookup = graph_impl.GraphKeyedEdgeLookup;

pub const GraphKeyedEdgeLookupList = graph_impl.GraphKeyedEdgeLookupList;

pub const GraphScanCursor = graph_impl.GraphScanCursor;

pub const GraphScanOptions = graph_impl.GraphScanOptions;

pub const GraphScanNode = graph_impl.GraphScanNode;

pub const GraphScanEdge = graph_impl.GraphScanEdge;

pub const GraphScanResult = graph_impl.GraphScanResult;

pub const GraphWalkOptions = graph_impl.GraphWalkOptions;

pub const GraphWalkDirectionOptions = graph_impl.GraphWalkDirectionOptions;

pub const GraphWalkScanProfile = graph_impl.GraphWalkScanProfile;

pub const GraphWalkItem = graph_impl.GraphWalkItem;

pub const GraphWalk = graph_impl.GraphWalk;

pub const Extension = extension_impl.Extension;

pub const ExtensionRegistry = extension_impl.Registry;

pub const ExtensionManifest = extension_impl.Manifest;

pub const ExtensionInfo = extension_impl.InstalledInfo;

pub const ExtensionList = extension_impl.InstalledList;

pub const ExtensionSalvageMode = extension_impl.SalvageMode;

pub const ExtensionSalvageContext = extension_impl.SalvageContext;

pub const ExtensionSalvageResult = extension_impl.SalvageResult;

pub const DynamicExtensionSet = extension_dynamic_impl.DynamicExtensionSet;

pub const DynamicExtensionTrustRecord = extension_dynamic_impl.TrustRecord;

pub const DynamicExtensionTrustedList = extension_dynamic_impl.TrustedList;

pub const DynamicExtensionTrustStoreOptions = extension_dynamic_impl.TrustStoreOptions;

pub const DynamicExtensionBundleInfo = extension_dynamic_impl.BundleInfo;

pub const DynamicExtensionOwnedRegistry = extension_dynamic_impl.OwnedRegistry;

pub const extension_dynamic = extension_dynamic_impl;

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

pub const BoundObjectStore = struct {};

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

pub const BoundVectorStore = struct {};

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

/// Information about the optional graph store bound to a main `.zova` file.
pub const BoundGraphStoreInfo = struct {
    path: []u8,
    store_id: []u8,
    bound_set_id: []u8,
    graph_epoch: u64,

    pub fn deinit(self: *BoundGraphStoreInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.store_id);
        allocator.free(self.bound_set_id);
    }
};

pub const BoundGraphStore = struct {};

pub const SplitGraphStoreCounts = struct {
    graphs: u64 = 0,
    nodes: u64 = 0,
    edges: u64 = 0,
};

pub const SplitGraphStoreResult = struct {
    role: []const u8 = bound_graph_store_role,
    store_path: []const u8,
    store_id: [64]u8,
    bound_set_id: [64]u8,
    copied: SplitGraphStoreCounts,
    cleared: SplitGraphStoreCounts,
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

pub const ExtensionOpenMode = enum {
    enforce,
    inspect,
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

/// Options for `migrateDatabase`.
pub const MigrateOptions = struct {
    /// Open and validate the migrated destination set after copying.
    verify: bool = true,
};
