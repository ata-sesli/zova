import { WorkerChannel } from "./channel.mjs";

export type SqlValue = null | number | bigint | string | Uint8Array;
export interface QueryResult {
  columns: string[];
  rows: SqlValue[][];
}

export type VectorMetric = "cosine" | "l2" | "dot";
export type VectorElementType = "f32" | "f16" | "i8";
/** f32 values, raw IEEE half-float bits for f16, or i8 values. */
export type VectorValues = Float32Array | Uint16Array | Int8Array;
export interface VectorCollectionOptions {
  readonly dimensions: number;
  readonly metric: VectorMetric;
  readonly elementType: VectorElementType;
}
export interface VectorCollectionInfo extends VectorCollectionOptions {
  readonly name: string;
  readonly vectorCount: bigint;
}
export interface VectorInput { readonly id: string; readonly values: VectorValues; }
export interface Vector { readonly id: string; readonly values: VectorValues; }
export interface VectorSearchResult { readonly id: string; readonly distance: number; }

export type GraphTargetType =
  "none" | "record" | "object" | "object-chunk" | "vector" | "entity" | "fact" | "concept" | "external";
export type GraphDirection = "outgoing" | "incoming";
export interface GraphInfo { name: string; nodeCount: bigint; edgeCount: bigint; }
export interface GraphNodeInput {
  graphName: string;
  nodeId: string;
  kind: string;
  targetType: GraphTargetType;
  targetNamespace?: string;
  targetRef?: string;
}
export interface GraphNode extends GraphNodeInput {}
export interface GraphEdgeInput { graphName: string; fromNodeId: string; edgeType: string; toNodeId: string; }
export interface GraphEdge extends GraphEdgeInput {}
export interface GraphNeighborsOptions {
  graphName: string;
  nodeId: string;
  direction: GraphDirection;
  edgeType?: string;
  limit: number;
}
export interface GraphNeighbor { nodeId: string; kind: string; edgeType: string; }
export interface GraphDegreeOptions { graphName: string; nodeId: string; direction: GraphDirection; edgeType?: string; }
export interface GraphWalkOptions {
  graphName: string;
  startNodeId: string;
  /** Defaults to "outgoing". */
  direction?: GraphDirection;
  edgeType?: string;
  maxDepth: number;
  limit: number;
}
export interface GraphWalkItem { nodeId: string; kind: string; depth: number; predecessorNodeId?: string; edgeType?: string; }

export class ZovaWasmError extends Error {
  constructor(message: string, readonly status: string, readonly statusCode: number) {
    super(message);
    this.name = "ZovaWasmError";
  }
}

function failure(error: unknown): ZovaWasmError {
  if (error instanceof ZovaWasmError) return error;
  const value = error as { message?: unknown; status?: unknown; statusCode?: unknown } | null;
  return new ZovaWasmError(
    String(value?.message ?? error),
    typeof value?.status === "string" ? value.status : "ZOVA_MISUSE",
    typeof value?.statusCode === "number" ? value.statusCode : 16,
  );
}
function invalid(message: string): never {
  throw new ZovaWasmError(message, "ZOVA_INVALID_ARGUMENT", 1);
}
function validateSql(sql: string): void {
  if (typeof sql !== "string" || sql.includes("\0")) invalid("SQL must be a string without NUL bytes");
}
function validateBytes(...values: Uint8Array[]): void {
  if (!values.every(value => value instanceof Uint8Array)) invalid("KV inputs must be Uint8Array values");
}
function validateParameters(parameters: readonly SqlValue[]): void {
  if (!Array.isArray(parameters)) invalid("Parameters must be an array");
  for (const value of parameters) {
    if (value === null || typeof value === "string" || value instanceof Uint8Array) continue;
    if (typeof value === "number" && Number.isFinite(value)) continue;
    if (typeof value === "bigint" && value >= -(1n << 63n) && value < (1n << 63n)) continue;
    invalid("Unsupported SQL parameter or out-of-range integer");
  }
}

function text<T extends string | undefined>(value: T, label: string): T {
  if (typeof value !== "string" || value.includes("\0")) invalid(label + " must be a string without NUL bytes");
  return value;
}
function optionalText(value: string | undefined, label: string): string | undefined {
  return value === undefined ? undefined : text(value, label);
}
function size(value: number, label: string): number {
  if (!Number.isInteger(value) || value < 0 || value >= 0xffffffff) invalid(label + " must be a non-negative integer");
  return value;
}
function objectId(id: Uint8Array): Uint8Array {
  if (!(id instanceof Uint8Array) || id.length !== 32) invalid("Object IDs are 32-byte Uint8Array values");
  return new Uint8Array(id);
}
function vectorValues(values: VectorValues): VectorValues {
  if (!(values instanceof Float32Array || values instanceof Uint16Array || values instanceof Int8Array)) {
    invalid("Vector values must be a Float32Array, Uint16Array or Int8Array");
  }
  return values.slice();
}
function list<T, U>(items: readonly T[], copy: (item: T) => U): U[] {
  if (!Array.isArray(items)) invalid("Expected an array");
  return items.map(copy);
}
function node(input: GraphNodeInput): GraphNodeInput {
  return {
    graphName: text(input?.graphName, "Graph name"), nodeId: text(input.nodeId, "Node ID"), kind: text(input.kind, "Node kind"),
    targetType: text(input.targetType, "Target type"),
    targetNamespace: optionalText(input.targetNamespace, "Target namespace"), targetRef: optionalText(input.targetRef, "Target reference"),
  };
}
function edge(input: GraphEdgeInput): GraphEdgeInput {
  return {
    graphName: text(input?.graphName, "Graph name"), fromNodeId: text(input.fromNodeId, "Source node ID"),
    edgeType: text(input.edgeType, "Edge type"), toNodeId: text(input.toNodeId, "Destination node ID"),
  };
}
function edgeScope(options: GraphDegreeOptions): GraphDegreeOptions {
  return {
    graphName: text(options?.graphName, "Graph name"), nodeId: text(options.nodeId, "Node ID"),
    direction: text(options.direction, "Direction"), edgeType: optionalText(options.edgeType, "Edge type"),
  };
}

const constructionToken = Symbol("Database");
type Request = <T>(operation: string, prepare: () => object) => Promise<T>;
interface Shared { channel: WorkerChannel; tail: Promise<void>; active: number; }
interface Scope { done: boolean; }

/**
 * Experimental prepared statement owned by its database. Run one query or
 * iteration at a time; closing the database finalizes it.
 */
export class Statement {
  #request: Request;
  #handle: number;
  #finalizing?: Promise<void>;
  readonly parameterCount: number;
  readonly columns: readonly string[];

  /** @internal Use Database.prepare(). */
  constructor(request: Request, info: { handle: number; parameterCount: number; columns: string[] }, token: symbol) {
    if (token !== constructionToken) invalid("Use Database.prepare()");
    this.#request = request;
    this.#handle = info.handle;
    this.parameterCount = info.parameterCount;
    this.columns = Object.freeze(info.columns);
  }

  get finalized(): boolean { return this.#finalizing !== undefined; }

  #send<T>(operation: string, prepare: () => object = () => ({})): Promise<T> {
    if (this.finalized) return Promise.reject(new ZovaWasmError("Statement is finalized", "ZOVA_MISUSE", 16));
    return this.#request(operation, () => ({ handle: this.#handle, ...prepare() }));
  }

  /** Rebinds every parameter, runs to completion and resets the statement. */
  query(parameters: readonly SqlValue[] = []): Promise<QueryResult> {
    return this.#send("statement_query", () => ({ parameters: copyParameters(parameters) }));
  }

  /** Yields rows fetched from the worker `batchSize` at a time. */
  async *iterate(parameters: readonly SqlValue[] = [], batchSize = 256): AsyncGenerator<SqlValue[], void, undefined> {
    await this.#send("statement_bind", () => {
      if (!Number.isInteger(batchSize) || batchSize < 1) invalid("Batch size must be a positive integer");
      return { parameters: copyParameters(parameters) };
    });
    let done = false;
    try {
      while (!done) {
        const page = await this.#send<{ rows: SqlValue[][]; done: boolean }>("statement_fetch", () => ({ maxRows: batchSize }));
        done = page.done;
        yield* page.rows;
      }
    } finally {
      // An abandoned iteration must not keep its read cursor open.
      if (!done && !this.finalized) await this.#send("statement_reset").catch(() => undefined);
    }
  }

  finalize(): Promise<void> {
    this.#finalizing ??= this.#request<void>("statement_finalize", () => ({ handle: this.#handle }));
    return this.#finalizing;
  }
}
function copyParameters(parameters: readonly SqlValue[]): SqlValue[] {
  validateParameters(parameters);
  return parameters.map(value => value instanceof Uint8Array ? new Uint8Array(value) : value);
}

/** Experimental browser database. Each instance owns a dedicated worker. */
export class Database {
  #shared: Shared;
  #scope?: Scope;
  #closing?: Promise<void>;

  private constructor(shared: Shared, token: symbol, scope?: Scope) {
    if (token !== constructionToken) invalid("Use Database.createMemory() or Database.openPersistent()");
    this.#shared = shared;
    this.#scope = scope;
  }

  static async createMemory(): Promise<Database> {
    return Database.#open({});
  }

  static async openPersistent(name: string): Promise<Database> {
    if (typeof name !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(name)) {
      invalid("Database name must be 1–64 ASCII letters, digits, underscores or hyphens, starting with a letter or digit");
    }
    return Database.#open({ name });
  }

  /**
   * Stores exported database bytes under a new persistent name and opens it.
   * An existing name is never replaced, and bytes that fail normal Zova
   * validation are removed again.
   */
  static async importPersistent(name: string, data: Uint8Array): Promise<Database> {
    if (typeof name !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(name)) {
      invalid("Database name must be 1–64 ASCII letters, digits, underscores or hyphens, starting with a letter or digit");
    }
    if (!(data instanceof Uint8Array)) invalid("Imported database must be a Uint8Array");
    return Database.#open({ name, data: new Uint8Array(data) });
  }

  static async #open(args: { name?: string; data?: Uint8Array }): Promise<Database> {
    let channel: WorkerChannel | undefined;
    try {
      channel = new WorkerChannel(new Worker(new URL("./worker.mjs", import.meta.url), { type: "module" }));
      await channel.request("initialize", args);
      return new Database({ channel, tail: Promise.resolve(), active: 0 }, constructionToken);
    } catch (error) {
      channel?.terminate();
      throw failure(error);
    }
  }

  get closed(): boolean { return this.#shared.channel.closed; }

  // `outlive` lets a statement prepared inside a transaction keep working
  // after it, as an ordinary queued request.
  async #request<T>(operation: string, prepare: () => object, outlive = false): Promise<T> {
    try {
      if (this.closed) throw new ZovaWasmError("Database is closed", "ZOVA_MISUSE", 16);
      const inTransaction = this.#scope !== undefined && !this.#scope.done;
      if (this.#scope?.done && !outlive) throw new ZovaWasmError("Transaction has ended", "ZOVA_MISUSE", 16);
      // Validation and input copies happen here, before any await.
      const args = prepare();
      // Outside a transaction the request posts synchronously; while one is
      // running, other callers wait for it so their work cannot interleave.
      if (!inTransaction && this.#shared.active > 0) await this.#shared.tail;
      return await this.#shared.channel.request(operation, args) as T;
    } catch (error) { throw failure(error); }
  }

  /**
   * Runs `callback` inside one immediate transaction: committed when it
   * resolves, rolled back when it throws. Use only the `tx` handle inside the
   * callback; other calls on this database wait until the transaction ends,
   * so awaiting them from the callback never completes.
   */
  async transaction<T>(callback: (tx: Database) => T | Promise<T>): Promise<T> {
    if (typeof callback !== "function") invalid("Transaction callback must be a function");
    if (this.#scope) throw new ZovaWasmError("Transactions cannot be nested", "ZOVA_MISUSE", 16);
    if (this.closed) throw new ZovaWasmError("Database is closed", "ZOVA_MISUSE", 16);
    const shared = this.#shared;
    const send = (operation: string): Promise<void> =>
      shared.channel.request(operation).catch((error: unknown) => { throw failure(error); });
    const previous = shared.tail;
    let release!: () => void;
    shared.tail = new Promise<void>(resolve => { release = resolve; });
    shared.active++;
    const scope: Scope = { done: false };
    try {
      await previous;
      await send("begin");
      let value: T;
      try {
        value = await callback(new Database(shared, constructionToken, scope));
      } catch (error) {
        scope.done = true;
        await send("rollback").catch(() => undefined);
        throw error;
      }
      scope.done = true;
      try {
        await send("commit");
      } catch (error) {
        await send("rollback").catch(() => undefined);
        throw error;
      }
      return value;
    } finally {
      scope.done = true;
      shared.active--;
      release();
    }
  }

  async prepare(sql: string): Promise<Statement> {
    const info = await this.#request<{ handle: number; parameterCount: number; columns: string[] }>(
      "prepare", () => { validateSql(sql); return { sql }; });
    return new Statement((operation, prepare) => this.#request(operation, prepare, true), info, constructionToken);
  }

  /** Bytes of the committed persistent database. Rejects while a transaction is open. */
  export(): Promise<Uint8Array> {
    return this.#request("export", () => ({}));
  }

  exec(sql: string): Promise<void> {
    return this.#request("exec", () => { validateSql(sql); return { sql }; });
  }

  query(sql: string, parameters: readonly SqlValue[] = []): Promise<QueryResult> {
    return this.#request("query", () => {
      validateSql(sql);
      validateParameters(parameters);
      return { sql, parameters: parameters.map(value => value instanceof Uint8Array ? new Uint8Array(value) : value) };
    });
  }

  readonly kv = Object.freeze({
    get: (namespace: Uint8Array, key: Uint8Array): Promise<Uint8Array | null> =>
      this.#request("kv_get", () => {
        validateBytes(namespace, key);
        return { namespace: new Uint8Array(namespace), key: new Uint8Array(key) };
      }),
    put: (namespace: Uint8Array, key: Uint8Array, value: Uint8Array): Promise<void> =>
      this.#request("kv_put", () => {
        validateBytes(namespace, key, value);
        return { namespace: new Uint8Array(namespace), key: new Uint8Array(key), value: new Uint8Array(value) };
      }),
    delete: (namespace: Uint8Array, key: Uint8Array): Promise<boolean> =>
      this.#request("kv_delete", () => {
        validateBytes(namespace, key);
        return { namespace: new Uint8Array(namespace), key: new Uint8Array(key) };
      }),
  });

  putObject(data: Uint8Array): Promise<Uint8Array> {
    return this.#request("object_put", () => { validateBytes(data); return { data: new Uint8Array(data) }; });
  }
  getObject(id: Uint8Array): Promise<Uint8Array> {
    return this.#request("object_get", () => ({ id: objectId(id) }));
  }
  readObjectRange(id: Uint8Array, offset: bigint, length: number): Promise<Uint8Array> {
    return this.#request("object_read_range", () => {
      if (typeof offset !== "bigint" || offset < 0n || offset >= (1n << 64n)) invalid("Offset must be an unsigned 64-bit bigint");
      return { id: objectId(id), offset, size: size(length, "Length") };
    });
  }
  hasObject(id: Uint8Array): Promise<boolean> {
    return this.#request("object_exists", () => ({ id: objectId(id) }));
  }
  objectSize(id: Uint8Array): Promise<bigint> {
    return this.#request("object_size", () => ({ id: objectId(id) }));
  }
  deleteObject(id: Uint8Array): Promise<void> {
    return this.#request("object_delete", () => ({ id: objectId(id) }));
  }

  createVectorCollection(name: string, options: VectorCollectionOptions): Promise<void> {
    return this.#request("vector_collection_create", () => ({
      name: text(name, "Collection name"),
      options: {
        dimensions: size(options?.dimensions, "Dimensions"), metric: text(options.metric, "Metric"),
        elementType: text(options.elementType, "Element type"),
      },
    }));
  }
  hasVectorCollection(name: string): Promise<boolean> {
    return this.#request("vector_collection_exists", () => ({ name: text(name, "Collection name") }));
  }
  vectorCollectionInfo(name: string): Promise<VectorCollectionInfo> {
    return this.#request("vector_collection_info", () => ({ name: text(name, "Collection name") }));
  }
  listVectorCollections(): Promise<VectorCollectionInfo[]> {
    return this.#request("vector_collections_list", () => ({}));
  }
  deleteVectorCollection(name: string): Promise<void> {
    return this.#request("vector_collection_delete", () => ({ name: text(name, "Collection name") }));
  }
  putVector(collectionName: string, vectorId: string, values: VectorValues): Promise<void> {
    return this.putVectors(collectionName, [{ id: vectorId, values }]);
  }
  /** One atomic batch. */
  putVectors(collectionName: string, vectors: readonly VectorInput[]): Promise<void> {
    return this.#request("vector_put_many", () => ({
      collection: text(collectionName, "Collection name"),
      vectors: list(vectors, vector => ({ id: text(vector?.id, "Vector ID"), values: vectorValues(vector.values) })),
    }));
  }
  getVector(collectionName: string, vectorId: string): Promise<Vector> {
    return this.#request("vector_get", () => ({ collection: text(collectionName, "Collection name"), id: text(vectorId, "Vector ID") }));
  }
  hasVector(collectionName: string, vectorId: string): Promise<boolean> {
    return this.#request("vector_exists", () => ({ collection: text(collectionName, "Collection name"), id: text(vectorId, "Vector ID") }));
  }
  deleteVector(collectionName: string, vectorId: string): Promise<void> {
    return this.#request("vector_delete", () => ({ collection: text(collectionName, "Collection name"), id: text(vectorId, "Vector ID") }));
  }
  deleteVectors(collectionName: string, vectorIds: readonly string[]): Promise<void> {
    return this.#request("vector_delete_many", () => ({
      collection: text(collectionName, "Collection name"), ids: list(vectorIds, id => text(id, "Vector ID")),
    }));
  }
  /** Exact nearest-neighbor search, closest first. */
  searchVectors(collectionName: string, query: VectorValues, limit: number): Promise<VectorSearchResult[]> {
    return this.#request("vector_search", () => ({
      collection: text(collectionName, "Collection name"), query: vectorValues(query), limit: size(limit, "Limit"),
    }));
  }
  searchVectorsById(collectionName: string, vectorId: string, limit: number): Promise<VectorSearchResult[]> {
    return this.#request("vector_search_by_id", () => ({
      collection: text(collectionName, "Collection name"), id: text(vectorId, "Vector ID"), limit: size(limit, "Limit"),
    }));
  }

  createGraph(name: string): Promise<void> {
    return this.#request("graph_create", () => ({ name: text(name, "Graph name") }));
  }
  hasGraph(name: string): Promise<boolean> {
    return this.#request("graph_exists", () => ({ name: text(name, "Graph name") }));
  }
  graphInfo(name: string): Promise<GraphInfo> {
    return this.#request("graph_info", () => ({ name: text(name, "Graph name") }));
  }
  listGraphs(): Promise<GraphInfo[]> {
    return this.#request("graphs_list", () => ({}));
  }
  deleteGraph(name: string): Promise<void> {
    return this.#request("graph_delete", () => ({ name: text(name, "Graph name") }));
  }
  putGraphNode(input: GraphNodeInput): Promise<void> {
    return this.putGraphNodes([input]);
  }
  /** One atomic batch. */
  putGraphNodes(inputs: readonly GraphNodeInput[]): Promise<void> {
    return this.#request("graph_node_put_many", () => ({ nodes: list(inputs, node) }));
  }
  getGraphNode(graphName: string, nodeId: string): Promise<GraphNode> {
    return this.#request("graph_node_get", () => ({ graphName: text(graphName, "Graph name"), nodeId: text(nodeId, "Node ID") }));
  }
  hasGraphNode(graphName: string, nodeId: string): Promise<boolean> {
    return this.#request("graph_node_exists", () => ({ graphName: text(graphName, "Graph name"), nodeId: text(nodeId, "Node ID") }));
  }
  /** Also removes every edge that touches the node. */
  deleteGraphNode(graphName: string, nodeId: string): Promise<void> {
    return this.#request("graph_node_delete", () => ({ graphName: text(graphName, "Graph name"), nodeId: text(nodeId, "Node ID") }));
  }
  deleteGraphNodes(graphName: string, nodeIds: readonly string[]): Promise<void> {
    return this.#request("graph_node_delete_many", () => ({
      graphName: text(graphName, "Graph name"), nodeIds: list(nodeIds, id => text(id, "Node ID")),
    }));
  }
  putGraphEdge(input: GraphEdgeInput): Promise<void> {
    return this.putGraphEdges([input]);
  }
  /** One atomic batch. */
  putGraphEdges(inputs: readonly GraphEdgeInput[]): Promise<void> {
    return this.#request("graph_edge_put_many", () => ({ edges: list(inputs, edge) }));
  }
  getGraphEdge(graphName: string, fromNodeId: string, edgeType: string, toNodeId: string): Promise<GraphEdge> {
    return this.#request("graph_edge_get", () => edge({ graphName, fromNodeId, edgeType, toNodeId }));
  }
  hasGraphEdge(graphName: string, fromNodeId: string, edgeType: string, toNodeId: string): Promise<boolean> {
    return this.#request("graph_edge_exists", () => edge({ graphName, fromNodeId, edgeType, toNodeId }));
  }
  deleteGraphEdge(input: GraphEdgeInput): Promise<void> {
    return this.#request("graph_edge_delete", () => edge(input));
  }
  deleteGraphEdges(inputs: readonly GraphEdgeInput[]): Promise<void> {
    return this.#request("graph_edge_delete_many", () => ({ edges: list(inputs, edge) }));
  }
  graphNeighbors(options: GraphNeighborsOptions): Promise<GraphNeighbor[]> {
    return this.#request("graph_neighbors", () => ({ ...edgeScope(options), limit: size(options.limit, "Limit") }));
  }
  graphDegree(options: GraphDegreeOptions): Promise<bigint> {
    return this.#request("graph_degree", () => edgeScope(options));
  }
  /** Bounded breadth-first walk; the start node is returned at depth 0. */
  graphWalk(options: GraphWalkOptions): Promise<GraphWalkItem[]> {
    return this.#request("graph_walk", () => ({
      graphName: text(options?.graphName, "Graph name"), startNodeId: text(options.startNodeId, "Start node ID"),
      direction: text(options.direction ?? "outgoing", "Direction"), edgeType: optionalText(options.edgeType, "Edge type"),
      maxDepth: size(options.maxDepth, "Maximum depth"), limit: size(options.limit, "Limit"),
    }));
  }

  close(): Promise<void> {
    if (this.#scope) return Promise.reject(new ZovaWasmError("Close the database, not its transaction handle", "ZOVA_MISUSE", 16));
    if (this.#closing) return this.#closing;
    const closing: Promise<void> = this.#shared.channel.close().then(
      () => undefined,
      (error: unknown) => { throw failure(error); },
    );
    this.#closing = closing;
    return closing;
  }
}
