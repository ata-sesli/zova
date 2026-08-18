import native = require("../index.js");

export const packageVersion = native.packageVersion();
export const abiVersion = native.abiVersion();
export const formatVersion = native.formatVersion();
export const sqliteVersion = native.sqliteVersion();

export {
  convertSqliteToZova,
  Database,
  restoreBackup,
} from "./database.js";
export { AsyncDatabase } from "./async-database.js";
export { ZovaError } from "./errors.js";
export type {
  GraphDegreeOptions,
  GraphDirection,
  GraphEdge,
  GraphEdgeInput,
  GraphInfo,
  GraphNeighbor,
  GraphNeighborsOptions,
  GraphNode,
  GraphNodeInput,
  GraphTargetType,
  GraphWalkItem,
  GraphWalkOptions,
} from "./graph.js";
export {
  ObjectWriter,
  objectChunkId,
  objectId,
  objectIdFromHex,
  objectIdToHex,
} from "./object.js";
export { Statement } from "./statement.js";
export { Subscription } from "./subscription.js";
export type { Notification } from "./subscription.js";
export { Step } from "./types.js";
export type {
  ObjectManifest,
  ObjectManifestChunk,
  ObjectManifestChunkInput,
} from "./object.js";
export type { ColumnType, ExtensionInfo, KvEntry, OpenOptions } from "./types.js";
export type {
  Vector,
  VectorCollectionInfo,
  VectorCollectionOptions,
  VectorElementType,
  VectorInput,
  VectorMetric,
  VectorSearchOptions,
  VectorSearchResult,
  VectorValues,
} from "./vector.js";
