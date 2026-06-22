//! Safe Rust bindings for Zova's C ABI.
//!
//! This Rust binding currently covers database lifecycle, records through
//! prepared SQL statements, transactions, explicit vacuum, objects, chunks,
//! manifests, range reads, assembly, `ObjectWriter`, vector collections, vector
//! CRUD, exact vector search, and SQL-native vector queries through prepared
//! statements.

mod database;
mod error;
mod object;
mod statement;
mod vector;

pub use database::Database;
pub use error::{Error, Result, Status};
pub use object::{
    object_chunk_id, object_id, ObjectChunkId, ObjectId, ObjectManifest, ObjectManifestChunk,
    ObjectWriter, OwnedObjectWriter,
};
pub use statement::{ColumnType, OwnedStatement, Statement, Step};
pub use vector::{
    Vector, VectorCollectionInfo, VectorCollectionOptions, VectorInput, VectorMetric,
    VectorSearchResult,
};
