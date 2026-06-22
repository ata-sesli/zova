//! Shared public error set for the Zova-owned database layer.

const sqlite = @import("sqlite.zig");

/// Error set for `.zova` identity, object, and vector behavior.
///
/// SQLite operation failures keep using the wrapped SQLite errors.
pub const Error = sqlite.Error || error{
    NotZovaPath,
    NotZovaDatabase,
    UnsupportedZovaVersion,
    DestinationExists,
    ZovaNameConflict,
    ObjectNotFound,
    ObjectAlreadyExists,
    ObjectChunkNotFound,
    ObjectChunkHashMismatch,
    ObjectCorrupt,
    ObjectManifestInvalid,
    ObjectRangeInvalid,
    ObjectTooLarge,
    ObjectTransactionActive,
    ObjectWriterClosed,
    VectorCollectionExists,
    VectorCollectionNotFound,
    VectorNotFound,
    VectorDimensionMismatch,
    VectorCorrupt,
    VectorInvalid,
    OutOfMemory,
};
