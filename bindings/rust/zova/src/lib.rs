//! Safe Rust bindings for Zova's C ABI.
//!
//! This Rust binding currently covers database lifecycle, records through
//! prepared SQL statements, transactions, explicit vacuum, backup/compact/
//! restore, objects, chunks, manifests, range reads, assembly, `ObjectWriter`,
//! vector collections, vector CRUD, exact vector search, and SQL-native vector
//! queries through prepared statements, graphs, and graph traversal. Use
//! `SharedDatabase` when one serialized handle should be shared across Rust
//! threads.

mod database;
mod error;
mod graph;
mod notification;
mod object;
mod shared;
mod statement;
mod vector;

pub use database::{
    restore_backup, BackupOptions, CompactOptions, Database, OpenOptions, RestoreOptions,
};
pub use error::{Error, Result, Status};
pub use graph::{
    GraphEdge, GraphEdgeInput, GraphInfo, GraphNeighbor, GraphNeighborDirection,
    GraphNeighborsOptions, GraphNode, GraphNodeInput, GraphTargetType, GraphWalkItem,
    GraphWalkOptions, DEFAULT_GRAPH_NAME,
};
pub use notification::{Notification, Subscription};
pub use object::{
    object_chunk_id, object_id, ObjectChunkId, ObjectId, ObjectManifest, ObjectManifestChunk,
    ObjectWriter, OwnedObjectWriter,
};
pub use shared::{
    SharedDatabase, SharedDatabaseGuard, SharedObjectWriter, SharedStatement, SharedSubscription,
};
pub use statement::{ColumnType, OwnedStatement, Statement, Step};
pub use vector::{
    Vector, VectorCollectionInfo, VectorCollectionOptions, VectorInput, VectorMetric,
    VectorSearchResult,
};
