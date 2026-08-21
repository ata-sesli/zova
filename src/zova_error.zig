//! Shared public error set for the Zova-owned database layer.

const sqlite = @import("sqlite.zig");

/// Error set for `.zova` identity, object, and vector behavior.
///
/// SQLite operation failures keep using the wrapped SQLite errors.
pub const Error = sqlite.Error || error{
    NotZovaPath,
    NotZovaDatabase,
    UnsupportedZovaVersion,
    /// The database reports a storage format this release no longer opens but
    /// can still migrate explicitly. Reserved for format probing and
    /// classification; emitted by the open path once precise open errors land.
    MigrationRequired,
    /// The database reports a storage format newer than this release.
    UnsupportedFutureFormat,
    /// The database reports a pre-migration storage format with no direct
    /// migration path into this release.
    UnsupportedLegacyFormat,
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
    BoundStoreExists,
    BoundStoreNotFound,
    BoundStoreInvalid,
    VectorCollectionExists,
    VectorCollectionNotFound,
    VectorNotFound,
    VectorDimensionMismatch,
    VectorCorrupt,
    VectorInvalid,
    GraphExists,
    GraphNotFound,
    GraphNodeNotFound,
    GraphEdgeNotFound,
    GraphInvalid,
    ExtensionNotFound,
    ExtensionExists,
    ExtensionInvalid,
    ExtensionIncompatible,
    ExtensionUnavailable,
    ExtensionUntrusted,
    ExtensionLoadFailed,
    KvTooLarge,
    KvCorrupt,
    OutOfMemory,
};
