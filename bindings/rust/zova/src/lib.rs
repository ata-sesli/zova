//! Safe Rust bindings for Zova's C ABI.
//!
//! This Rust binding currently covers database lifecycle, records through
//! prepared SQL statements, transactions, explicit vacuum, free-page reclaim,
//! backup/compact/restore, objects, chunks, manifests, range reads, assembly, `ObjectWriter`,
//! vector collections, vector CRUD, exact vector search, and SQL-native vector
//! queries through prepared statements, graphs, and graph traversal. Use
//! `SharedDatabase` when one serialized handle should be shared across Rust
//! threads.

mod database;
mod error;
mod extension;
mod graph;
mod kv;
mod notification;
mod object;
mod progress;
mod shared;
mod statement;
mod vector;

pub use database::{
    migrate_database, migrate_database_with_extensions, migrate_database_with_progress,
    probe_format, restore_backup, restore_backup_to_memory, AutoVacuum, BackupOptions,
    CompactOptions, Database, ExtensionOptions, FormatCompatibility, FormatInfo, MigrateOptions,
    OpenOptions, ReclaimOptions, ReclaimedMember, RestoreOptions,
};
pub use error::{Error, Result, Status};
pub use extension::ExtensionInfo;
pub use graph::{
    GraphDegreeOptions, GraphEdge, GraphEdgeInput, GraphInfo, GraphNeighbor,
    GraphNeighborDirection, GraphNeighborsOptions, GraphNode, GraphNodeInput, GraphTargetType,
    GraphWalkItem, GraphWalkOptions, DEFAULT_GRAPH_NAME,
};
pub use kv::KvEntry;
pub use notification::{Notification, Subscription};
pub use object::{
    object_chunk_id, object_id, ObjectChunkId, ObjectId, ObjectManifest, ObjectManifestChunk,
    ObjectPutOptions, ObjectReader, ObjectStorageProfile, ObjectWriter, OwnedObjectReader,
    OwnedObjectWriter,
};
pub use object::{ObjectSeekableReader, OwnedObjectSeekableReader};
pub use progress::{Progress, ProgressMember, ProgressPhase};
pub use shared::SharedObjectSeekableReader;
pub use shared::{
    SharedDatabase, SharedDatabaseGuard, SharedObjectReader, SharedObjectWriter, SharedStatement,
    SharedSubscription,
};
pub use statement::{ColumnType, OwnedStatement, Statement, Step};
pub use vector::{
    Vector, VectorCollectionInfo, VectorCollectionOptions, VectorElementType, VectorInput,
    VectorMetric, VectorSearchResult, VectorValues, VectorValuesOwned,
};
