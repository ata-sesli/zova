//! Safe Rust bindings for Zova's C ABI.
//!
//! This Rust binding currently covers database lifecycle, records through
//! prepared SQL statements, transactions, explicit vacuum, free-page reclaim,
//! set-wide journal mode and WAL checkpoints, the experimental cross-file
//! commit protocol,
//! backup/compact/restore, objects, chunks, manifests, range reads, assembly, `ObjectWriter`,
//! vector collections, vector CRUD, exact vector search, and SQL-native vector
//! queries through prepared statements, graphs, graph traversal, opaque-key
//! graph topology, fresh-build sessions, application SQL functions, and
//! statically linked plugins. Use `SharedDatabase` when one serialized handle
//! should be shared across Rust threads.

mod database;
mod error;
mod extension;
mod fresh_build;
mod graph;
mod graph_keyed;
mod journal;
mod kv;
mod notification;
mod object;
mod progress;
mod shared;
mod sql_function;
mod statement;
mod vector;

pub use database::{
    abi_version, abi_version_string, migrate_database, migrate_database_with_extensions,
    migrate_database_with_plugins, migrate_database_with_plugins_and_progress,
    migrate_database_with_progress, probe_format, restore_backup, restore_backup_to_memory,
    trust_extension_bundle, untrust_extension_bundle, verify_extension_bundle, AbiVersion,
    AutoVacuum, BackupOptions, CompactOptions, CreateOptions, Database, ExtensionOptions,
    FormatCompatibility, FormatInfo, LinkedPlugin, MigrateOptions, OpenOptions, ReclaimOptions,
    ReclaimedMember, RestoreOptions,
};
pub use error::{Error, Result, Status};
pub use extension::ExtensionInfo;
pub use fresh_build::{
    FreshBuild, FreshBuildProfile, FreshBuildResult, FreshValue, OwnedFreshBuild,
};
pub use graph::{
    GraphDegreeOptions, GraphEdge, GraphEdgeInput, GraphInfo, GraphNeighbor,
    GraphNeighborDirection, GraphNeighborsOptions, GraphNode, GraphNodeInput, GraphTargetType,
    GraphWalkItem, GraphWalkOptions, DEFAULT_GRAPH_NAME,
};
pub use graph_keyed::{
    GraphEdgePayloadReplacement, GraphFreshEdgeInput, GraphFreshEdgePayloadInput, GraphFreshKeys,
    GraphFreshNodeInput, GraphKeyedDegreeOptions, GraphKeyedEdge, GraphKeyedNeighbor,
    GraphKeyedNode, GraphScanCursor, GraphScanOptions, GraphScanPage, GraphWalkDirectionOptions,
    GraphWalkProfile,
};
pub use journal::{
    CheckpointMode, CheckpointedMember, CommitProtocol, JournalMode, JournalModeMember,
};
pub use kv::{KvEntry, KvScanEntry, KvScanOptions, KvScanPage};
pub use notification::{Notification, Subscription};
pub use object::{
    object_chunk_id, object_id, ObjectChunkId, ObjectCompression, ObjectId, ObjectManifest,
    ObjectManifestChunk, ObjectPutOptions, ObjectReader, ObjectStorageProfile, ObjectWriter,
    OwnedObjectReader, OwnedObjectWriter,
};
pub use object::{ObjectSeekableReader, OwnedObjectSeekableReader};
pub use progress::{Progress, ProgressMember, ProgressPhase};
pub use shared::SharedObjectSeekableReader;
pub use shared::{
    SharedDatabase, SharedDatabaseGuard, SharedFreshBuild, SharedObjectReader, SharedObjectWriter,
    SharedStatement, SharedSubscription,
};
pub use sql_function::{SqlFunctionFlags, SqlFunctionResult, SqlValue};
pub use statement::{ColumnType, OwnedStatement, Statement, Step};
pub use vector::{
    Vector, VectorCollectionInfo, VectorCollectionOptions, VectorElementType, VectorInput,
    VectorMetric, VectorMultiI8Aggregation, VectorMultiI8SearchMode, VectorMultiI8SearchOptions,
    VectorSearchResult, VectorValues, VectorValuesOwned,
};
