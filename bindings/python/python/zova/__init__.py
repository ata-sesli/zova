from enum import IntEnum

from ._native import (
    ClosedHandleError,
    Database,
    GraphEdge,
    GraphEdgeInput,
    GraphInfo,
    GraphNeighbor,
    GraphNeighborsOptions,
    GraphNode,
    GraphNodeInput,
    GraphWalkItem,
    GraphWalkOptions,
    Notification,
    ObjectChunkId,
    ObjectId,
    ObjectManifest,
    ObjectManifestChunk,
    ObjectWriter,
    SavepointContext,
    Subscription,
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
    restore_backup,
)

__version__ = "0.20.0"


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


class GraphTargetType(IntEnum):
    NONE = 0
    RECORD = 1
    OBJECT = 2
    OBJECT_CHUNK = 3
    VECTOR = 4
    ENTITY = 5
    FACT = 6
    CONCEPT = 7
    EXTERNAL = 8


class GraphNeighborDirection(IntEnum):
    OUTGOING = 0
    INCOMING = 1


DEFAULT_GRAPH_NAME = "default"


__all__ = [
    "ClosedHandleError",
    "ColumnType",
    "Database",
    "DEFAULT_GRAPH_NAME",
    "GraphEdge",
    "GraphEdgeInput",
    "GraphInfo",
    "GraphNeighbor",
    "GraphNeighborDirection",
    "GraphNeighborsOptions",
    "GraphNode",
    "GraphNodeInput",
    "GraphTargetType",
    "GraphWalkItem",
    "GraphWalkOptions",
    "Notification",
    "ObjectChunkId",
    "ObjectId",
    "ObjectManifest",
    "ObjectManifestChunk",
    "ObjectWriter",
    "SavepointContext",
    "Subscription",
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
    "restore_backup",
]
