import native = require("../index.js");

export const packageVersion = native.packageVersion();
export const abiVersion = native.abiVersion();
/** Numeric C ABI version of the linked Zova library. */
export const abiVersionParts: Readonly<{ major: number; minor: number; patch: number }> =
  Object.freeze(native.abiVersionParts());
export const formatVersion = native.formatVersion();
export const sqliteVersion = native.sqliteVersion();

export {
  convertSqliteToZova,
  Database,
  migrateDatabase,
  probeFormat,
  restoreBackup,
} from "./database.js";
export { AsyncDatabase } from "./async-database.js";
export { ZovaError } from "./errors.js";
export {
  LinkedPlugin,
  trustExtensionBundle,
  untrustExtensionBundle,
  verifyExtensionBundle,
} from "./extension.js";
export { FreshBuild } from "./fresh-build.js";
export type { FreshBuildProfile, FreshBuildResult, FreshValue } from "./fresh-build.js";
export type {
  GraphDegreeOptions,
  GraphDirection,
  GraphEdge,
  GraphEdgeInput,
  GraphEdgePayloadReplacement,
  GraphFreshEdgeInput,
  GraphFreshKeys,
  GraphFreshNodeInput,
  GraphInfo,
  GraphKeyedDegreeOptions,
  GraphKeyedEdge,
  GraphKeyedNeighbor,
  GraphKeyedNode,
  GraphKeys,
  GraphNeighbor,
  GraphNeighborsOptions,
  GraphNode,
  GraphNodeInput,
  GraphScanCursor,
  GraphScanOptions,
  GraphScanPage,
  GraphTargetType,
  GraphWalkDirectionOptions,
  GraphWalkDirectionProfiled,
  GraphWalkItem,
  GraphWalkOptions,
  GraphWalkProfile,
} from "./graph.js";
export {
  ObjectReader,
  ObjectSeekableReader,
  ObjectWriter,
  objectChunkId,
  objectId,
  objectIdFromHex,
  objectIdToHex,
} from "./object.js";
export type {
  Progress,
  ProgressMember,
  ProgressOptions,
  ProgressPhase,
} from "./progress.js";
export type {
  SqlFunction,
  SqlFunctionOptions,
  SqlFunctionResult,
  SqlValue,
} from "./sql-function.js";
export { Statement } from "./statement.js";
export { Subscription } from "./subscription.js";
export type { Notification } from "./subscription.js";
export { Step } from "./types.js";
export type {
  ObjectManifest,
  ObjectManifestChunk,
  ObjectCompression,
  ObjectManifestChunkInput,
  ObjectPutOptions,
  ObjectStorageProfile,
  SeekWhence,
} from "./object.js";
export type {
  ColumnType,
  CreateOptions,
  ExtensionInfo,
  AutoVacuumMode,
  ExtensionOptions,
  FormatCompatibilityName,
  FormatInfo,
  KvEntry,
  KvScanOptions,
  KvScanPage,
  OpenOptions,
  ReclaimedMember,
  ReclaimOptions,
} from "./types.js";
export type {
  Vector,
  VectorCollectionInfo,
  VectorCollectionOptions,
  VectorElementType,
  VectorInput,
  VectorMetric,
  VectorMultiI8Aggregation,
  VectorMultiI8SearchMode,
  VectorMultiI8SearchOptions,
  VectorSearchOptions,
  VectorSearchResult,
  VectorValues,
} from "./vector.js";
