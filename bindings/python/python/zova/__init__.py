from enum import IntEnum

from ._native import (
    ClosedHandleError,
    Database,
    ObjectChunkId,
    ObjectId,
    ObjectManifest,
    ObjectManifestChunk,
    ObjectWriter,
    Vector,
    VectorCollectionInfo,
    VectorCollectionOptions,
    VectorInput,
    VectorSearchResult,
    ZovaError,
    convert_sqlite_to_zova,
    encode_f32_le,
    object_chunk_id,
    object_id,
)

__version__ = "0.13.2"


class Step(IntEnum):
    ROW = 1
    DONE = 2


class ColumnType(IntEnum):
    INTEGER = 1
    FLOAT = 2
    TEXT = 3
    BLOB = 4
    NULL = 5


class VectorMetric(IntEnum):
    COSINE = 0
    L2 = 1
    DOT = 2


__all__ = [
    "ClosedHandleError",
    "ColumnType",
    "Database",
    "ObjectChunkId",
    "ObjectId",
    "ObjectManifest",
    "ObjectManifestChunk",
    "ObjectWriter",
    "Step",
    "Vector",
    "VectorCollectionInfo",
    "VectorCollectionOptions",
    "VectorInput",
    "VectorMetric",
    "VectorSearchResult",
    "ZovaError",
    "__version__",
    "convert_sqlite_to_zova",
    "encode_f32_le",
    "object_chunk_id",
    "object_id",
]
