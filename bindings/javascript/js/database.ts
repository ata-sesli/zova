import native = require("../index.js");

import { callNative, normalizeNativeError, ZovaError } from "./errors.js";
import { FreshBuild } from "./fresh-build.js";
import { graphKeys } from "./graph.js";
import type {
  GraphDegreeOptions,
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
  GraphScanOptions,
  GraphScanPage,
  GraphWalkDirectionOptions,
  GraphWalkDirectionProfiled,
  GraphWalkItem,
  GraphWalkOptions,
} from "./graph.js";
import {
  ObjectReader,
  ObjectSeekableReader,
  ObjectWriter,
  type ObjectCompression,
  type ObjectManifest,
  type ObjectManifestChunkInput,
  type ObjectPutOptions,
} from "./object.js";
import { sqlFunctionTrampoline } from "./sql-function.js";
import type { SqlFunction, SqlFunctionOptions } from "./sql-function.js";
import { Statement } from "./statement.js";
import { Subscription } from "./subscription.js";
import { nativeExtensionOptions, reclaimedMember } from "./types.js";
import type {
  CreateOptions, ExtensionInfo, ExtensionOptions, FormatInfo, KvEntry, KvScanOptions, KvScanPage, OpenOptions, ReclaimedMember,
  ReclaimOptions,
} from "./types.js";
import type {
  Vector,
  VectorCollectionInfo,
  VectorCollectionOptions,
  VectorInput,
  VectorMultiI8SearchOptions,
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

  static create(path: string, extensions?: ExtensionOptions): Database {
    return new Database(
      callNative(() => native.NativeDatabase.create(path, nativeExtensionOptions(extensions))),
    );
  }

  /** Create a new database with creation-time settings such as page size. */
  static createWithOptions(path: string, options: CreateOptions = {}): Database {
    return new Database(
      callNative(() => native.NativeDatabase.createWithOptions(path, options.pageSize)),
    );
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
          extensions: nativeExtensionOptions(options.extensions),
        }),
      ),
    );
  }

  /**
   * Open for extension maintenance without running installed extension hooks,
   * so `extensionUpgrade` and `extensionRebuild` can repair a database whose
   * extension check fails.
   */
  static openForExtensionUpgrade(path: string, options: OpenOptions = {}): Database {
    return new Database(
      callNative(() =>
        native.NativeDatabase.openForExtensionUpgrade(path, {
          readOnly: options.readOnly,
          busyTimeoutMs: options.busyTimeoutMs,
          extensions: nativeExtensionOptions(options.extensions),
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

  /** Run an installed extension's upgrade hook to the loaded version. */
  extensionUpgrade(name: string): void {
    callNative(() => this.#native.extensionUpgrade(name));
  }

  /** Run an installed extension's rebuild hook to recreate derived state. */
  extensionRebuild(name: string): void {
    callNative(() => this.#native.extensionRebuild(name));
  }

  /**
   * Register a scalar SQL function on this connection. `arity` -1 accepts any
   * number of arguments. Arguments arrive as `SqlValue`s: integers are
   * `bigint`, floats `number`. A thrown exception or an unsupported result
   * fails the statement with that message.
   *
   * The function runs synchronously while a statement steps. It must not use
   * this database or its statements: that call waits for the statement
   * already running and never returns.
   */
  registerFunction(
    name: string,
    arity: number,
    fn: SqlFunction,
    options: SqlFunctionOptions = {},
  ): void {
    callNative(() =>
      this.#native.registerFunction(
        name,
        arity,
        {
          deterministic: options.deterministic,
          directOnly: options.directOnly,
          innocuous: options.innocuous,
        },
        sqlFunctionTrampoline(fn),
      ),
    );
  }

  /** Start a fresh-build session; see `FreshBuild`. */
  beginFreshBuild(): FreshBuild {
    return new FreshBuild(callNative(() => this.#native.beginFreshBuild()));
  }

  backupTo(destination: string, verify = true): void {
    callNative(() => this.#native.backupTo(destination, verify));
  }

  compactTo(destination: string, verify = true): void {
    callNative(() => this.#native.compactTo(destination, verify));
  }

  /**
   * Release free pages of incremental auto-vacuum member files in place, each
   * step in its own short write transaction. Members are reported in a fixed
   * order: the main database, then each attached object, vector, and graph
   * store. Throws `ZOVA_OBJECT_TRANSACTION_ACTIVE` inside an explicit
   * transaction.
   */
  reclaimSpace(options: ReclaimOptions = {}): ReclaimedMember[] {
    return callNative(() =>
      this.#native.reclaimSpace(options.maxPages, options.stepPages),
    ).map(reclaimedMember);
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

  /** Return one page of a namespace in ascending key byte order. */
  kvScan(namespace: Uint8Array, options: KvScanOptions): KvScanPage {
    return callNative(() => this.#native.kvScan(namespace, { ...options }));
  }

  /** Insert one entry only when its key is absent. Returns whether it was written. */
  kvPutIfAbsent(namespace: Uint8Array, key: Uint8Array, value: Uint8Array): boolean {
    return callNative(() => this.#native.kvPutIfAbsent(namespace, key, value));
  }

  /**
   * Replace one value only when the current value equals `expected` byte for
   * byte. A missing key never matches. Returns whether it was written.
   */
  kvCompareAndPut(
    namespace: Uint8Array,
    key: Uint8Array,
    expected: Uint8Array,
    value: Uint8Array,
  ): boolean {
    return callNative(() => this.#native.kvCompareAndPut(namespace, key, expected, value));
  }

  /**
   * Delete one entry only when its current value equals `expected` byte for
   * byte. A missing key never matches. Returns whether it was deleted.
   */
  kvCompareAndDelete(namespace: Uint8Array, key: Uint8Array, expected: Uint8Array): boolean {
    return callNative(() => this.#native.kvCompareAndDelete(namespace, key, expected));
  }

  listen(channel: string): Subscription {
    return Subscription.create(callNative(() => this.#native.listen(channel)));
  }

  notify(channel: string, payload: string): void {
    callNative(() => this.#native.notify(channel, payload));
  }

  /** Select chunk compression for objects written through this handle. */
  setObjectCompression(compression: ObjectCompression): void {
    callNative(() => this.#native.setObjectCompression(compression));
  }

  putObject(data: Uint8Array): Uint8Array {
    return callNative(() => this.#native.putObject(data));
  }

  putObjectWithOptions(
    data: Uint8Array,
    options: ObjectPutOptions,
  ): Uint8Array {
    return callNative(() => this.#native.putObjectWithOptions(data, options));
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

  putObjectChunkWithOptions(
    hash: Uint8Array,
    data: Uint8Array,
    options: ObjectPutOptions,
  ): void {
    callNative(() => this.#native.putObjectChunkWithOptions(hash, data, options));
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

  assembleObjectFromChunksWithOptions(
    id: Uint8Array,
    sizeBytes: bigint,
    chunks: readonly ObjectManifestChunkInput[],
    options: ObjectPutOptions,
  ): void {
    callNative(() =>
      this.#native.assembleObjectFromChunksWithOptions(
        id,
        sizeBytes,
        [...chunks],
        options,
      ),
    );
  }

  objectWriter(): ObjectWriter {
    return new ObjectWriter(callNative(() => this.#native.objectWriter()));
  }

  objectWriterWithOptions(options: ObjectPutOptions): ObjectWriter {
    return new ObjectWriter(
      callNative(() => this.#native.objectWriterWithOptions(options)),
    );
  }

  objectReader(id: Uint8Array): ObjectReader {
    return new ObjectReader(callNative(() => this.#native.objectReader(id)));
  }

  objectSeekableReader(id: Uint8Array): ObjectSeekableReader {
    return new ObjectSeekableReader(
      callNative(() => this.#native.objectSeekableReader(id)),
    );
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

  /** Insert or replace nodes atomically; returns their keys in input order. */
  putGraphNodesKeyed(inputs: readonly GraphNodeInput[]): BigInt64Array {
    return callNative(() => this.#native.putGraphNodesKeyed([...inputs]));
  }

  /** Insert edges atomically; returns their keys in input order. */
  putGraphEdgesKeyed(inputs: readonly GraphEdgeInput[]): BigInt64Array {
    return callNative(() => this.#native.putGraphEdgesKeyed([...inputs]));
  }

  /** Look nodes up by key; a missing key gives `null`. */
  getGraphNodesKeyed(graphName: string, nodeKeys: GraphKeys): (GraphKeyedNode | null)[] {
    return callNative(() =>
      this.#native.getGraphNodesKeyed(graphName, graphKeys(nodeKeys)).map((node) => node ?? null),
    );
  }

  /** Look edges up by key; a missing key gives `null`. */
  getGraphEdgesKeyed(graphName: string, edgeKeys: GraphKeys): (GraphKeyedEdge | null)[] {
    return callNative(() =>
      this.#native.getGraphEdgesKeyed(graphName, graphKeys(edgeKeys)).map((edge) => edge ?? null),
    );
  }

  graphNeighborsKeyed(options: GraphNeighborsOptions): GraphKeyedNeighbor[] {
    return callNative(() => this.#native.graphNeighborsKeyed(options));
  }

  /** Degree of each node key, in input order. */
  graphDegreesKeyed(options: GraphKeyedDegreeOptions): BigUint64Array {
    return callNative(() =>
      this.#native.graphDegreesKeyed({ ...options, nodeKeys: graphKeys(options.nodeKeys) }),
    );
  }

  /** Payload of each edge key; a missing key gives `null`. */
  getGraphEdgePayloads(graphName: string, edgeKeys: GraphKeys): (Uint8Array | null)[] {
    return callNative(() =>
      this.#native
        .getGraphEdgePayloads(graphName, graphKeys(edgeKeys))
        .map((payload) => payload ?? null),
    );
  }

  /** Replace edge payloads atomically. */
  replaceGraphEdgePayloads(
    graphName: string,
    replacements: readonly GraphEdgePayloadReplacement[],
  ): void {
    callNative(() => this.#native.replaceGraphEdgePayloads(graphName, [...replacements]));
  }

  /** One page of nodes and edges in creation order. */
  graphScan(options: GraphScanOptions): GraphScanPage {
    return callNative(() => this.#native.graphScan(options));
  }

  /** Breadth-first walk along outgoing or incoming edges. */
  graphWalkDirection(options: GraphWalkDirectionOptions): GraphWalkItem[] {
    return callNative(() => this.#native.graphWalkDirection(options));
  }

  graphWalkDirectionProfiled(options: GraphWalkDirectionOptions): GraphWalkDirectionProfiled {
    return callNative(() => this.#native.graphWalkDirectionProfiled(options));
  }

  /**
   * Create and load a new graph in one transaction. Duplicate edges are
   * merged, so their inputs share one key.
   */
  buildFreshGraphKeyed(
    graphName: string,
    nodes: readonly GraphFreshNodeInput[],
    edges: readonly GraphFreshEdgeInput[],
  ): GraphFreshKeys {
    return callNative(() =>
      this.#native.buildFreshGraphKeyed(graphName, [...nodes], [...edges]),
    );
  }

  /** Like `buildFreshGraphKeyed` for input that is already unique and valid. */
  buildFreshGraphPreparedKeyed(
    graphName: string,
    nodes: readonly GraphFreshNodeInput[],
    edges: readonly GraphFreshEdgeInput[],
  ): GraphFreshKeys {
    return callNative(() =>
      this.#native.buildFreshGraphPreparedKeyed(graphName, [...nodes], [...edges]),
    );
  }

  /** `buildFreshGraphPreparedKeyed` with edge payloads; an omitted payload is empty. */
  buildFreshGraphPreparedKeyedWithPayloads(
    graphName: string,
    nodes: readonly GraphFreshNodeInput[],
    edges: readonly GraphFreshEdgeInput[],
  ): GraphFreshKeys {
    return callNative(() =>
      this.#native.buildFreshGraphPreparedKeyedWithPayloads(graphName, [...nodes], [...edges]),
    );
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

  /** Score each stored i8 vector against several query rows at once. */
  searchVectorsMultiI8(
    collectionName: string,
    options: VectorMultiI8SearchOptions,
  ): VectorSearchResult[] {
    return callNative(() =>
      this.#native.searchVectorsMultiI8(collectionName, {
        ...options,
        candidateIds:
          options.candidateIds === undefined ? undefined : [...options.candidateIds],
      }),
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

export function probeFormat(path: string): FormatInfo {
  return callNative(() => {
    const info = native.probeFormat(path);
    return {
      formatVersion: info.formatVersion,
      compatibility: info.compatibility as FormatInfo["compatibility"],
    };
  });
}

/**
 * Migrate a `.zova` file forward to this release's storage format. A database
 * with a non-bundled extension installed needs that extension's trusted
 * bundle in `extensions`, exactly as `Database.open` does.
 */
export function migrateDatabase(
  source: string,
  destination: string,
  verify = true,
  extensions?: ExtensionOptions,
): void {
  callNative(() =>
    native.migrateDatabase(source, destination, verify, nativeExtensionOptions(extensions)),
  );
}

export function convertSqliteToZova(
  source: string,
  destination: string,
): void {
  callNative(() => native.convertSqliteToZova(source, destination));
}
