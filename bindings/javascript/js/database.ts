import native = require("../index.js");

import { callNative, normalizeNativeError, ZovaError } from "./errors.js";
import type {
  GraphDegreeOptions,
  GraphEdge,
  GraphEdgeInput,
  GraphInfo,
  GraphNeighbor,
  GraphNeighborsOptions,
  GraphNode,
  GraphNodeInput,
  GraphWalkItem,
  GraphWalkOptions,
} from "./graph.js";
import {
  ObjectWriter,
  type ObjectManifest,
  type ObjectManifestChunkInput,
} from "./object.js";
import { Statement } from "./statement.js";
import { Subscription } from "./subscription.js";
import type { ExtensionInfo, KvEntry, OpenOptions } from "./types.js";
import type {
  Vector,
  VectorCollectionInfo,
  VectorCollectionOptions,
  VectorInput,
  VectorSearchOptions,
  VectorSearchResult,
  VectorValues,
} from "./vector.js";

function isPromiseLike(value: unknown): value is PromiseLike<unknown> {
  return (
    (typeof value === "object" || typeof value === "function") &&
    value !== null &&
    "then" in value &&
    typeof value.then === "function"
  );
}

export class Database {
  readonly #native: native.NativeDatabase;

  private constructor(database: native.NativeDatabase) {
    this.#native = database;
  }

  static create(path: string): Database {
    return new Database(callNative(() => native.NativeDatabase.create(path)));
  }

  static createMemory(): Database {
    return new Database(callNative(() => native.NativeDatabase.createMemory()));
  }

  static restoreBackupToMemory(source: string, verify = true): Database {
    return new Database(
      callNative(() => native.restoreBackupToMemory(source, verify)),
    );
  }

  static open(path: string, options: OpenOptions = {}): Database {
    return new Database(
      callNative(() =>
        native.NativeDatabase.open(path, {
          readOnly: options.readOnly,
          busyTimeoutMs: options.busyTimeoutMs,
        }),
      ),
    );
  }

  get closed(): boolean {
    return this.#native.closed;
  }

  close(): void {
    callNative(() => this.#native.close());
  }

  exec(sql: string): void {
    callNative(() => this.#native.exec(sql));
  }

  prepare(sql: string): Statement {
    return new Statement(callNative(() => this.#native.prepare(sql)));
  }

  begin(): void {
    callNative(() => this.#native.begin());
  }

  beginImmediate(): void {
    callNative(() => this.#native.beginImmediate());
  }

  commit(): void {
    callNative(() => this.#native.commit());
  }

  rollback(): void {
    callNative(() => this.#native.rollback());
  }

  savepoint(name: string): void;
  savepoint<T>(name: string, callback: (database: Database) => T): T;
  savepoint<T>(
    name: string,
    callback?: (database: Database) => T,
  ): T | void {
    callNative(() => this.#native.savepoint(name));
    if (callback === undefined) {
      return;
    }
    try {
      const value = callback(this);
      if (isPromiseLike(value)) {
        throw new ZovaError(
          "ZOVA_INVALID_ARGUMENT",
          1,
          "savepoint callback must be synchronous",
        );
      }
      this.releaseSavepoint(name);
      return value;
    } catch (error) {
      try {
        this.rollbackToSavepoint(name);
        this.releaseSavepoint(name);
      } catch {
        // Preserve the error that caused the savepoint to fail.
      }
      throw normalizeNativeError(error);
    }
  }

  rollbackToSavepoint(name: string): void {
    callNative(() => this.#native.rollbackToSavepoint(name));
  }

  releaseSavepoint(name: string): void {
    callNative(() => this.#native.releaseSavepoint(name));
  }

  transaction<T>(callback: (database: Database) => T): T {
    this.begin();
    try {
      const value = callback(this);
      if (isPromiseLike(value)) {
        throw new ZovaError(
          "ZOVA_INVALID_ARGUMENT",
          1,
          "transaction callback must be synchronous",
        );
      }
      this.commit();
      return value;
    } catch (error) {
      try {
        this.rollback();
      } catch {
        // Preserve the error that caused the transaction to fail.
      }
      throw normalizeNativeError(error);
    }
  }

  transactionImmediate<T>(callback: (database: Database) => T): T {
    this.beginImmediate();
    try {
      const value = callback(this);
      if (isPromiseLike(value)) {
        throw new ZovaError(
          "ZOVA_INVALID_ARGUMENT",
          1,
          "transaction callback must be synchronous",
        );
      }
      this.commit();
      return value;
    } catch (error) {
      try {
        this.rollback();
      } catch {
        // Preserve the error that caused the transaction to fail.
      }
      throw normalizeNativeError(error);
    }
  }

  setBusyTimeout(milliseconds: number): void {
    callNative(() => this.#native.setBusyTimeout(milliseconds));
  }

  vacuum(): void {
    callNative(() => this.#native.vacuum());
  }

  installExtension(name: string): void {
    callNative(() => this.#native.installExtension(name));
  }

  listExtensions(): ExtensionInfo[] {
    return callNative(() => this.#native.listExtensions());
  }

  extensionInfo(name: string): ExtensionInfo {
    return callNative(() => this.#native.extensionInfo(name));
  }

  checkExtension(name: string): void {
    callNative(() => this.#native.checkExtension(name));
  }

  checkExtensions(): void {
    callNative(() => this.#native.checkExtensions());
  }

  dropExtension(name: string): void {
    callNative(() => this.#native.dropExtension(name));
  }

  backupTo(destination: string, verify = true): void {
    callNative(() => this.#native.backupTo(destination, verify));
  }

  compactTo(destination: string, verify = true): void {
    callNative(() => this.#native.compactTo(destination, verify));
  }

  lastInsertRowid(): bigint {
    return callNative(() => this.#native.lastInsertRowid());
  }

  changes(): bigint {
    return callNative(() => this.#native.changes());
  }

  totalChanges(): bigint {
    return callNative(() => this.#native.totalChanges());
  }

  kvGet(namespace: Uint8Array, key: Uint8Array): Uint8Array | null {
    return callNative(() => this.#native.kvGet(namespace, key));
  }

  kvGetMany(
    namespace: Uint8Array,
    keys: readonly Uint8Array[],
  ): (Uint8Array | null)[] {
    return callNative(() =>
      this.#native.kvGetMany(namespace, [...keys]).map((value) => value ?? null),
    );
  }

  kvPut(namespace: Uint8Array, key: Uint8Array, value: Uint8Array): void {
    callNative(() => this.#native.kvPut(namespace, key, value));
  }

  kvPutMany(
    namespace: Uint8Array,
    entries: readonly KvEntry[],
  ): void {
    callNative(() =>
      this.#native.kvPutMany(
        namespace,
        entries.map((entry) => ({
          key: entry.key,
          value: entry.value,
        })),
      ),
    );
  }

  kvDelete(namespace: Uint8Array, key: Uint8Array): void {
    callNative(() => this.#native.kvDelete(namespace, key));
  }

  kvDeleteMany(namespace: Uint8Array, keys: readonly Uint8Array[]): void {
    callNative(() => this.#native.kvDeleteMany(namespace, [...keys]));
  }

  kvCount(namespace: Uint8Array): bigint {
    return callNative(() => this.#native.kvCount(namespace));
  }

  kvClearNamespace(namespace: Uint8Array): void {
    callNative(() => this.#native.kvClearNamespace(namespace));
  }

  listen(channel: string): Subscription {
    return Subscription.create(callNative(() => this.#native.listen(channel)));
  }

  notify(channel: string, payload: string): void {
    callNative(() => this.#native.notify(channel, payload));
  }

  putObject(data: Uint8Array): Uint8Array {
    return callNative(() => this.#native.putObject(data));
  }

  getObject(id: Uint8Array): Uint8Array {
    return callNative(() => this.#native.getObject(id));
  }

  readObjectRange(id: Uint8Array, offset: bigint, size: number): Uint8Array {
    return callNative(() => this.#native.readObjectRange(id, offset, size));
  }

  hasObject(id: Uint8Array): boolean {
    return callNative(() => this.#native.hasObject(id));
  }

  objectSize(id: Uint8Array): bigint {
    return callNative(() => this.#native.objectSize(id));
  }

  objectChunkCount(id: Uint8Array): bigint {
    return callNative(() => this.#native.objectChunkCount(id));
  }

  deleteObject(id: Uint8Array): void {
    callNative(() => this.#native.deleteObject(id));
  }

  objectManifest(id: Uint8Array): ObjectManifest {
    return callNative(() => this.#native.objectManifest(id));
  }

  getObjectChunk(hash: Uint8Array): Uint8Array {
    return callNative(() => this.#native.getObjectChunk(hash));
  }

  hasObjectChunk(hash: Uint8Array): boolean {
    return callNative(() => this.#native.hasObjectChunk(hash));
  }

  putObjectChunk(hash: Uint8Array, data: Uint8Array): void {
    callNative(() => this.#native.putObjectChunk(hash, data));
  }

  deleteObjectChunk(hash: Uint8Array): boolean {
    return callNative(() => this.#native.deleteObjectChunk(hash));
  }

  assembleObjectFromChunks(
    id: Uint8Array,
    sizeBytes: bigint,
    chunks: readonly ObjectManifestChunkInput[],
  ): void {
    callNative(() =>
      this.#native.assembleObjectFromChunks(id, sizeBytes, [...chunks]),
    );
  }

  objectWriter(): ObjectWriter {
    return new ObjectWriter(callNative(() => this.#native.objectWriter()));
  }

  createVectorCollection(
    name: string,
    options: VectorCollectionOptions,
  ): void {
    callNative(() => this.#native.createVectorCollection(name, options));
  }

  hasVectorCollection(name: string): boolean {
    return callNative(() => this.#native.hasVectorCollection(name));
  }

  vectorCollectionInfo(name: string): VectorCollectionInfo {
    const info = callNative(() => this.#native.vectorCollectionInfo(name));
    return {
      ...info,
      metric: info.metric as VectorCollectionInfo["metric"],
      elementType:
        info.elementType as VectorCollectionInfo["elementType"],
    };
  }

  listVectorCollections(): VectorCollectionInfo[] {
    return callNative(() => this.#native.listVectorCollections()).map(
      (info) => ({
        ...info,
        metric: info.metric as VectorCollectionInfo["metric"],
        elementType:
          info.elementType as VectorCollectionInfo["elementType"],
      }),
    );
  }

  deleteVectorCollection(name: string): void {
    callNative(() => this.#native.deleteVectorCollection(name));
  }

  putVector(
    collectionName: string,
    vectorId: string,
    values: VectorValues,
  ): void {
    callNative(() => this.#native.putVector(collectionName, vectorId, values));
  }

  putVectors(
    collectionName: string,
    vectors: readonly VectorInput[],
  ): void {
    callNative(() => this.#native.putVectors(collectionName, [...vectors]));
  }

  getVector(collectionName: string, vectorId: string): Vector {
    return callNative(() => this.#native.getVector(collectionName, vectorId));
  }

  hasVector(collectionName: string, vectorId: string): boolean {
    return callNative(() => this.#native.hasVector(collectionName, vectorId));
  }

  deleteVector(collectionName: string, vectorId: string): void {
    callNative(() => this.#native.deleteVector(collectionName, vectorId));
  }

  deleteVectors(
    collectionName: string,
    vectorIds: readonly string[],
  ): void {
    callNative(() => this.#native.deleteVectors(collectionName, [...vectorIds]));
  }

  createGraph(name: string): void {
    callNative(() => this.#native.createGraph(name));
  }

  hasGraph(name: string): boolean {
    return callNative(() => this.#native.hasGraph(name));
  }

  graphInfo(name: string): GraphInfo {
    return callNative(() => this.#native.graphInfo(name));
  }

  listGraphs(): GraphInfo[] {
    return callNative(() => this.#native.listGraphs());
  }

  deleteGraph(name: string): void {
    callNative(() => this.#native.deleteGraph(name));
  }

  putGraphNode(input: GraphNodeInput): void {
    callNative(() => this.#native.putGraphNode(input));
  }

  putGraphNodes(inputs: readonly GraphNodeInput[]): void {
    callNative(() => this.#native.putGraphNodes([...inputs]));
  }

  getGraphNode(graphName: string, nodeId: string): GraphNode {
    const node = callNative(() =>
      this.#native.getGraphNode(graphName, nodeId),
    );
    return {
      ...node,
      targetType: node.targetType as GraphNode["targetType"],
    };
  }

  hasGraphNode(graphName: string, nodeId: string): boolean {
    return callNative(() => this.#native.hasGraphNode(graphName, nodeId));
  }

  deleteGraphNode(graphName: string, nodeId: string): void {
    callNative(() => this.#native.deleteGraphNode(graphName, nodeId));
  }

  deleteGraphNodes(graphName: string, nodeIds: readonly string[]): void {
    callNative(() =>
      this.#native.deleteGraphNodes(graphName, [...nodeIds]),
    );
  }

  putGraphEdge(input: GraphEdgeInput): void {
    callNative(() => this.#native.putGraphEdge(input));
  }

  putGraphEdges(inputs: readonly GraphEdgeInput[]): void {
    callNative(() => this.#native.putGraphEdges([...inputs]));
  }

  getGraphEdge(
    graphName: string,
    fromNodeId: string,
    edgeType: string,
    toNodeId: string,
  ): GraphEdge {
    return callNative(() =>
      this.#native.getGraphEdge(
        graphName,
        fromNodeId,
        edgeType,
        toNodeId,
      ),
    );
  }

  hasGraphEdge(
    graphName: string,
    fromNodeId: string,
    edgeType: string,
    toNodeId: string,
  ): boolean {
    return callNative(() =>
      this.#native.hasGraphEdge(
        graphName,
        fromNodeId,
        edgeType,
        toNodeId,
      ),
    );
  }

  deleteGraphEdge(input: GraphEdgeInput): void {
    callNative(() => this.#native.deleteGraphEdge(input));
  }

  deleteGraphEdges(inputs: readonly GraphEdgeInput[]): void {
    callNative(() => this.#native.deleteGraphEdges([...inputs]));
  }

  graphNeighbors(options: GraphNeighborsOptions): GraphNeighbor[] {
    return callNative(() => this.#native.graphNeighbors(options));
  }

  graphDegree(options: GraphDegreeOptions): bigint {
    return callNative(() => this.#native.graphDegree(options));
  }

  graphWalk(options: GraphWalkOptions): GraphWalkItem[] {
    return callNative(() => this.#native.graphWalk(options));
  }

  searchVectors(
    collectionName: string,
    query: VectorValues,
    options: VectorSearchOptions,
  ): VectorSearchResult[] {
    return callNative(() =>
      this.#native.searchVectors(
        collectionName,
        query,
        options.candidateIds === undefined
          ? undefined
          : [...options.candidateIds],
        options.maxDistance,
        options.limit,
      ),
    );
  }

  searchVectorsById(
    collectionName: string,
    sourceVectorId: string,
    options: VectorSearchOptions,
  ): VectorSearchResult[] {
    return callNative(() =>
      this.#native.searchVectorsById(
        collectionName,
        sourceVectorId,
        options.candidateIds === undefined
          ? undefined
          : [...options.candidateIds],
        options.maxDistance,
        options.limit,
      ),
    );
  }
}

export function restoreBackup(
  source: string,
  destination: string,
  verify = true,
): void {
  callNative(() => native.restoreBackup(source, destination, verify));
}

export function convertSqliteToZova(
  source: string,
  destination: string,
): void {
  callNative(() => native.convertSqliteToZova(source, destination));
}
