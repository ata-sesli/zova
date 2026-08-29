from dataclasses import dataclass
from enum import IntEnum

from ._native import (
    ClosedHandleError,
    Database,
    ExtensionInfo,
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
    ObjectPutOptions,
    ObjectReader,
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
    migrate_database,
    object_chunk_id,
    object_id,
    probe_format as _probe_format,
    restore_backup,
    restore_backup_to_memory,
)

__version__ = "1.0.0rc1"


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


class VectorElementType(IntEnum):
    F32 = 0
    F16 = 1
    I8 = 2


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


class ObjectStorageProfile(IntEnum):
    DEDUPLICATION = 0
    STREAMING = 1


DEFAULT_GRAPH_NAME = "default"


class FormatCompatibility(IntEnum):
    """Compatibility class assigned to a Zova storage format version."""

    CURRENT = 0
    MIGRATABLE = 1
    UNSUPPORTED_LEGACY = 2
    UNSUPPORTED_FUTURE = 3

    @property
    def name_value(self) -> str:
        """Stable machine-readable name shared by every Zova binding."""
        return _FORMAT_COMPATIBILITY_NAMES[self]


_FORMAT_COMPATIBILITY_NAMES = {
    FormatCompatibility.CURRENT: "current",
    FormatCompatibility.MIGRATABLE: "migratable",
    FormatCompatibility.UNSUPPORTED_LEGACY: "unsupported_legacy",
    FormatCompatibility.UNSUPPORTED_FUTURE: "unsupported_future",
}


@dataclass(frozen=True)
class FormatInfo:
    """Storage-format facts about a `.zova` file, reported without opening or
    mutating the file.

    `compatibility` is a `FormatCompatibility` member whose `name_value` is the
    stable machine-readable name shared by every Zova binding.
    """

    format_version: int
    compatibility: FormatCompatibility


def probe_format(path: str) -> FormatInfo:
    """Probe a `.zova` file's storage format without opening or mutating it.

    The probe never requires an open database handle and never writes to the
    probed file.
    """
    info = _probe_format(path)
    return FormatInfo(
        format_version=info.format_version,
        compatibility=FormatCompatibility(info.compatibility),
    )


__all__ = [
    "ClosedHandleError",
    "ColumnType",
    "Database",
    "DEFAULT_GRAPH_NAME",
    "ExtensionInfo",
    "FormatCompatibility",
    "FormatInfo",
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
    "ObjectPutOptions",
    "ObjectReader",
    "ObjectStorageProfile",
    "ObjectWriter",
    "SavepointContext",
    "Subscription",
    "Step",
    "Vector",
    "VectorCollectionInfo",
    "VectorCollectionOptions",
    "VectorElementType",
    "VectorInput",
    "VectorMetric",
    "VectorSearchResult",
    "ZovaError",
    "__version__",
    "convert_sqlite_to_zova",
    "encode_f32_le",
    "migrate_database",
    "object_chunk_id",
    "object_id",
    "probe_format",
    "restore_backup",
    "restore_backup_to_memory",
]
