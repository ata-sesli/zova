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
/**
 * As native `zova-js`: `candidateIds` restricts the search to those vector IDs
 * (unknown IDs are ignored; an empty list matches nothing), and `maxDistance`
 * drops results farther than it.
 */
export interface VectorSearchOptions {
  readonly limit: number;
  readonly candidateIds?: readonly string[];
  readonly maxDistance?: number;
}

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
/** Graph node and edge keys: a `BigInt64Array` or an array of `bigint`. */
export type GraphKeys = BigInt64Array | readonly bigint[];
export interface GraphKeyedNode { nodeKey: bigint; nodeId: string; kind: string; createdOrder: bigint; }
export interface GraphKeyedEdge { edgeKey: bigint; sourceNodeKey: bigint; edgeType: string; targetNodeKey: bigint; createdOrder: bigint; }
export interface GraphKeyedNeighbor { edgeKey: bigint; neighborNodeKey: bigint; nodeId: string; kind: string; edgeType: string; }
export interface GraphKeyedDegreeOptions { graphName: string; nodeKeys: GraphKeys; direction: GraphDirection; edgeType?: string; }
export interface GraphEdgePayloadReplacement { edgeKey: bigint; payload: Uint8Array; }
/** Scan position: continue after the last returned row's order and key. */
export interface GraphScanCursor { createdOrder: bigint; key: bigint; }
export interface GraphScanOptions {
  graphName: string;
  /** Omit to start at the first node. */
  nodeAfter?: GraphScanCursor;
  /** Omit to start at the first edge. */
  edgeAfter?: GraphScanCursor;
  nodeLimit: number;
  edgeLimit: number;
}
export interface GraphScanPage { nodes: GraphKeyedNode[]; edges: GraphKeyedEdge[]; hasMoreNodes: boolean; hasMoreEdges: boolean; }
export interface GraphWalkDirectionOptions extends GraphWalkOptions { direction: GraphDirection; }
/** Where a directional walk spent its time; timings are milliseconds. */
export interface GraphWalkProfile {
  mutexWaitMs: number;
  rootLookupMs: number;
  adjacencyPrepareMs: number;
  adjacencyExecuteMs: number;
  bfsBookkeepingAllocationMs: number;
  cAbiResultExportMs: number;
  totalProfiledMs: number;
  frontierExpansions: number;
  adjacencyQueryBinds: number;
  adjacencyRowsStepped: number;
  resultCount: number;
}
export interface GraphWalkDirectionProfiled { items: GraphWalkItem[]; profile: GraphWalkProfile; }
export interface GraphFreshNodeInput {
  nodeId: string;
  kind: string;
  targetType: GraphTargetType;
  targetNamespace?: string;
  targetRef?: string;
}
/** An edge between two nodes of the same fresh build, by node position. */
export interface GraphFreshEdgeInput {
  fromNodeOrdinal: number;
  edgeType: string;
  toNodeOrdinal: number;
  /** Only `buildFreshGraphPreparedKeyedWithPayloads` and `FreshBuild.graph` accept payloads. */
  payload?: Uint8Array;
}
export interface GraphFreshKeys {
  /** Node keys in input order. */
  nodeKeys: BigInt64Array;
  /** Edge keys in input order; deduplicated edges repeat a key. */
  edgeKeys: BigInt64Array;
}

/**
 * Multi-vector i8 search, as native `zova-js`. `global-min-cosine` scores
 * every vector by its least similar query row; `cbm-prefilter-min-cosine`
 * first keeps the `prefilterLimit` vectors closest to row
 * `prefilterQueryIndex`, then scores those the same way.
 */
export type VectorMultiI8SearchMode = "global-min-cosine" | "cbm-prefilter-min-cosine";
export type VectorMultiI8Aggregation = "min-cosine";
export interface VectorMultiI8SearchOptions {
  /** `queryCount` rows of `dimensions` values each, row after row. */
  readonly queryValues: Int8Array;
  readonly queryCount: number;
  readonly dimensions: number;
  /** Restrict the search to these vector IDs. */
  readonly candidateIds?: readonly string[];
  readonly mode?: VectorMultiI8SearchMode;
  readonly aggregation?: VectorMultiI8Aggregation;
  readonly prefilterQueryIndex?: number;
  readonly prefilterLimit?: number;
  readonly limit: number;
}

/** How new object chunks are stored; reads decode every stored encoding. */
export type ObjectCompression = "none" | "lz4";

/** One fresh-build cell: `null`, an integer `bigint`, a float `number`, text, or a blob. */
export type FreshValue = null | bigint | number | string | Uint8Array;
/** Where a fresh build spent its time; timings are milliseconds. */
export interface FreshBuildProfile {
  readonly validationMs: number;
  readonly tableLoadMs: number;
  readonly ftsLoadMs: number;
  readonly graphLoadMs: number;
  readonly graphValidationMs: number;
  readonly graphKeyGenerationMs: number;
  readonly graphNodeLoadMs: number;
  readonly graphEdgeLoadMs: number;
  readonly vectorLoadMs: number;
  readonly indexBuildMs: number;
  readonly commitMs: number;
  readonly tableRows: number;
  readonly ftsRows: number;
  readonly vectorRows: number;
  readonly payloadBytes: number;
}
export interface FreshBuildResult {
  /** Keys of the session's graph nodes, in input order. */
  readonly nodeKeys: BigInt64Array;
  /** Keys of the session's graph edges, in input order. */
  readonly edgeKeys: BigInt64Array;
  readonly profile: FreshBuildProfile;
}

/**
 * A browser SQL function: the URL of an ES module and the name of the
 * function it exports. The database worker imports the module and calls the
 * function synchronously for each row, so it cannot use page state or await.
 */
export interface SqlFunctionModule {
  readonly module: string | URL;
  readonly export: string;
}
export interface SqlFunctionOptions {
  /** Same arguments always give the same result, so SQLite may reuse it. */
  readonly deterministic?: boolean;
  /** Callable only from top-level SQL, not from views, triggers, or schema. */
  readonly directOnly?: boolean;
  /** Has no side effects and leaks no information. */
  readonly innocuous?: boolean;
}

/** Fresh-database options. `pageSize` 0 or omitted keeps SQLite's default. */
export interface CreateOptions {
  readonly pageSize?: number;
}
/**
 * `pageSize` applies only when the name is created. `readOnly` opens an
 * existing database without writing to it; `busyTimeoutMs` is SQLite's busy
 * timeout, as native `Database.open` options.
 */
export interface OpenPersistentOptions extends CreateOptions {
  readonly readOnly?: boolean;
  readonly busyTimeoutMs?: number;
}
export interface AbiVersionParts {
  readonly major: number;
  readonly minor: number;
  readonly patch: number;
}

/** The stage of a migration; fixes the unit of `done` and `total`. */
export type ProgressPhase = "copy" | "migrate" | "verify" | "publish";
/** The member file a copy or migrate event refers to. */
export type ProgressMember = "main" | "object_store" | "vector_store" | "graph_store";
/**
 * One progress event, as in native Zova. `copy` counts SQLite pages, `migrate`
 * format steps, `verify` stored items, and `publish` files. Events for one
 * phase and member keep `total` fixed, never decrease `done`, and end with
 * `done === total`. `member` is `null` for `verify` and `publish`.
 */
export interface Progress {
  readonly phase: ProgressPhase;
  readonly member: ProgressMember | null;
  readonly done: number;
  readonly total: number;
}
/**
 * `progress` receives events from the worker, all before the operation
 * settles. Aborting `signal`, or an exception thrown by `progress`, cancels the
 * operation; a cancelled operation rejects with `ZOVA_INTERRUPTED`, or with the
 * thrown exception.
 */
export interface ProgressOptions {
  readonly progress?: (progress: Progress) => void;
  readonly signal?: AbortSignal;
}
/** An installed extension, as native `zova-js` reports it. */
export interface ExtensionInfo {
  readonly name: string;
  readonly version: string;
  readonly storagePrefix: string;
  readonly zovaAbiMin: string;
  readonly capabilities: string;
  readonly required: boolean;
  readonly installedAtUnix: bigint;
  readonly manifestJson: string;
}
/** One stored persistent database. `bytes` is its storage use, unknown while another worker has it open. */
export interface PersistentDatabaseInfo {
  readonly name: string;
  readonly bytes?: number;
  readonly inUse: boolean;
}
/** Options for `backupTo`, `compactTo` and `restoreBackup`. */
export interface CopyOptions extends ProgressOptions {
  /** Verify the copy with the core's copy verification. Defaults to true. */
  readonly verify?: boolean;
}
/**
 * `maxPages` bounds the pages released by one call (default 0: every free
 * page); `stepPages` is the pages released per write transaction (default 1024).
 */
export interface ReclaimOptions {
  readonly maxPages?: number;
  readonly stepPages?: number;
}
export type AutoVacuumMode = "none" | "full" | "incremental";
/** What `reclaimSpace` did for one member file, as in native `zova-js`. */
export interface ReclaimedMember {
  readonly member: ProgressMember;
  readonly autoVacuum: AutoVacuumMode;
  readonly pageSize: number;
  readonly pagesReleased: number;
  readonly freePagesLeft: number;
}
export interface MigrateOptions extends ProgressOptions {
  /** Verify the migrated copy before publishing it. Defaults to true. */
  readonly verify?: boolean;
}
export type FormatCompatibilityName = "current" | "migratable" | "unsupported_legacy" | "unsupported_future";
export interface FormatInfo {
  readonly formatVersion: number;
  readonly compatibility: FormatCompatibilityName;
}

/**
 * A Zova failure, as native `zova-js`'s `ZovaError`: `code` is the status
 * name (`"ZOVA_BUSY"`) and `status` its number (`10`).
 */
export class ZovaError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, status: number, message: string) {
    super(message);
    this.name = "ZovaError";
    this.code = code;
    this.status = status;
  }

  /** @deprecated Use `status`. */
  get statusCode(): number { return this.status; }
}
/** @deprecated Use `ZovaError`; this is the same class. */
export const ZovaWasmError = ZovaError;
/** @deprecated Use `ZovaError`. */
export type ZovaWasmError = ZovaError;

// Worker replies carry the status name as `status` and its number as `statusCode`.
function failure(error: unknown): ZovaError {
  if (error instanceof ZovaError) return error;
  const value = error as { message?: unknown; status?: unknown; statusCode?: unknown } | null;
  return new ZovaError(
    typeof value?.status === "string" ? value.status : "ZOVA_MISUSE",
    typeof value?.statusCode === "number" ? value.statusCode : 16,
    String(value?.message ?? error),
  );
}
function invalid(message: string): never {
  throw new ZovaError("ZOVA_INVALID_ARGUMENT", 1, message);
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

function persistentName(name: string): void {
  if (typeof name !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(name)) {
    invalid("Database name must be 1–64 ASCII letters, digits, underscores or hyphens, starting with a letter or digit");
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
function checkedId(id: Uint8Array): Uint8Array {
  if (!(id instanceof Uint8Array) || id.length !== 32) invalid("Object IDs are 32-byte Uint8Array values");
  return new Uint8Array(id);
}
function objectProfile(options: ObjectPutOptions): ObjectStorageProfile {
  const profile = options?.profile;
  if (profile !== "deduplication" && profile !== "streaming") invalid("Object storage profile must be deduplication or streaming");
  return profile;
}
function manifestChunk(chunk: ObjectManifestChunkInput): ObjectManifestChunkInput {
  for (const field of ["index", "offset", "sizeBytes"] as const) {
    if (typeof chunk?.[field] !== "bigint") invalid("Manifest chunk index, offset and sizeBytes are bigint");
  }
  return { index: chunk.index, hash: checkedId(chunk.hash), offset: chunk.offset, sizeBytes: chunk.sizeBytes };
}
function searchOptions(options: VectorSearchOptions): VectorSearchOptions {
  if (typeof options !== "object" || options === null) invalid("Search options must be an object or a limit");
  const { candidateIds, maxDistance } = options;
  if (maxDistance !== undefined && typeof maxDistance !== "number") invalid("maxDistance must be a number");
  return {
    limit: size(options.limit, "Limit"),
    candidateIds: candidateIds === undefined ? undefined : list(candidateIds, id => text(id, "Candidate ID")),
    maxDistance,
  };
}
function kvBytes(value: Uint8Array): Uint8Array {
  validateBytes(value);
  return new Uint8Array(value);
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
// A package-owned copy, so batch calls can transfer it to the worker.
function graphKeys(keys: GraphKeys): BigInt64Array {
  if (keys instanceof BigInt64Array) return keys.slice();
  if (!Array.isArray(keys)) invalid("Graph keys must be a BigInt64Array or an array of bigint");
  return BigInt64Array.from(keys, (key: unknown) => {
    if (typeof key !== "bigint" || key < -(1n << 63n) || key >= (1n << 63n)) invalid("Graph keys must be signed 64-bit bigint values");
    return key;
  });
}
// Buffers of the typed arrays in prepared arguments. Batch calls pass this as
// `transfer`: their prepared arguments hold only package-owned copies, so the
// buffers move to the worker instead of being cloned.
function owned(args: unknown, found = new Set<ArrayBuffer>()): ArrayBuffer[] {
  if (ArrayBuffer.isView(args)) { if (args.buffer instanceof ArrayBuffer) found.add(args.buffer); }
  else if (Array.isArray(args)) for (const item of args) owned(item, found);
  else if (args !== null && typeof args === "object") for (const item of Object.values(args)) owned(item, found);
  return [...found];
}
function freshNode(input: GraphFreshNodeInput): GraphFreshNodeInput {
  return {
    nodeId: text(input?.nodeId, "Node ID"), kind: text(input.kind, "Node kind"), targetType: text(input.targetType, "Target type"),
    targetNamespace: optionalText(input.targetNamespace, "Target namespace"), targetRef: optionalText(input.targetRef, "Target reference"),
  };
}
function freshEdges(edges: readonly GraphFreshEdgeInput[], payloads: boolean): GraphFreshEdgeInput[] {
  return list(edges, input => {
    if (input?.payload !== undefined && !payloads) {
      invalid("Only buildFreshGraphPreparedKeyedWithPayloads and FreshBuild.graph accept payloads");
    }
    return {
      fromNodeOrdinal: size(input?.fromNodeOrdinal, "Node ordinal"), edgeType: text(input.edgeType, "Edge type"),
      toNodeOrdinal: size(input.toNodeOrdinal, "Node ordinal"), payload: input.payload === undefined ? undefined : kvBytes(input.payload),
    };
  });
}
function freshValue(value: FreshValue): FreshValue {
  return value instanceof Uint8Array ? new Uint8Array(value) : value;
}
function walkOptions(options: GraphWalkOptions): GraphWalkOptions {
  return {
    graphName: text(options?.graphName, "Graph name"), startNodeId: text(options.startNodeId, "Start node ID"),
    direction: text(options.direction ?? "outgoing", "Direction"), edgeType: optionalText(options.edgeType, "Edge type"),
    maxDepth: size(options.maxDepth, "Maximum depth"), limit: size(options.limit, "Limit"),
  };
}
function createOptions(options: OpenPersistentOptions | undefined): OpenPersistentOptions {
  if (options === undefined) return {};
  if (typeof options !== "object" || options === null) invalid("Options must be an object");
  return {
    pageSize: options.pageSize === undefined ? undefined : size(options.pageSize, "pageSize"),
    readOnly: options.readOnly === undefined ? undefined : Boolean(options.readOnly),
    busyTimeoutMs: options.busyTimeoutMs === undefined ? undefined : size(options.busyTimeoutMs, "busyTimeoutMs"),
  };
}
function edgeScope(options: GraphDegreeOptions): GraphDegreeOptions {
  return {
    graphName: text(options?.graphName, "Graph name"), nodeId: text(options.nodeId, "Node ID"),
    direction: text(options.direction, "Direction"), edgeType: optionalText(options.edgeType, "Edge type"),
  };
}

const constructionToken = Symbol("Database");
type Request = <T>(operation: string, prepare: () => object, transfer?: (args: object) => Transferable[]) => Promise<T>;
interface Shared { channel: WorkerChannel; tail: Promise<void>; active: number; }
interface Scope { done: boolean; }

/**
 * A prepared statement owned by its database. Run one query or
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
    if (this.finalized) return Promise.reject(new ZovaError("ZOVA_MISUSE", 16, "Statement is finalized"));
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

  // Step-by-step use, as native `Statement`. Each call is one worker message;
  // prefer `iterate()`, which fetches rows in batches.
  #row?: SqlValue[];

  /** Runs to the next row. Column accessors then read that row without a worker round trip. */
  async step(): Promise<Step> {
    const result = await this.#send<{ done: boolean; row?: SqlValue[] }>("statement_step");
    this.#row = result.row;
    return result.done ? "done" : "row";
  }
  /** Resets the cursor and keeps the bindings. */
  reset(): Promise<void> {
    this.#row = undefined;
    return this.#send("statement_reset_only");
  }
  clearBindings(): Promise<void> {
    return this.#send("statement_clear_bindings");
  }
  /** 1-based index of a named parameter such as `:name`, or null. */
  parameterIndex(name: string): Promise<number | null> {
    return this.#send("statement_parameter_index", () => ({ name: text(name, "Parameter name") }));
  }
  bindNull(index: number): Promise<void> { return this.#bind(index, null); }
  bindInteger(index: number, value: bigint): Promise<void> {
    if (typeof value !== "bigint") return Promise.reject(new ZovaError("ZOVA_INVALID_ARGUMENT", 1, "Integer values are bigint"));
    return this.#bind(index, value);
  }
  bindFloat(index: number, value: number): Promise<void> {
    if (typeof value !== "number") return Promise.reject(new ZovaError("ZOVA_INVALID_ARGUMENT", 1, "Float values are numbers"));
    return this.#bind(index, value);
  }
  bindText(index: number, value: string): Promise<void> {
    if (typeof value !== "string") return Promise.reject(new ZovaError("ZOVA_INVALID_ARGUMENT", 1, "Text values are strings"));
    return this.#bind(index, value);
  }
  bindBlob(index: number, value: Uint8Array): Promise<void> {
    if (!(value instanceof Uint8Array)) return Promise.reject(new ZovaError("ZOVA_INVALID_ARGUMENT", 1, "Blob values are Uint8Array"));
    return this.#bind(index, value);
  }
  #bind(index: number, value: SqlValue): Promise<void> {
    return this.#send("statement_bind_one", () => {
      if (!Number.isInteger(index) || index < 1) invalid("Parameter index must be a positive integer");
      return { index, value: copyParameters([value])[0] };
    });
  }

  columnCount(): number { return this.columns.length; }
  columnName(index: number): string {
    if (!Number.isInteger(index) || index < 0 || index >= this.columns.length) invalid("Column index out of range");
    return this.columns[index];
  }
  columnType(index: number): ColumnType {
    const value = this.#value(index);
    return value === null ? "null" : typeof value === "bigint" ? "integer" : typeof value === "number" ? "float"
      : typeof value === "string" ? "text" : "blob";
  }
  /** Integer and float columns convert as SQLite does; null reads as 0n. */
  columnInteger(index: number): bigint {
    const value = this.#value(index);
    if (value === null) return 0n;
    if (typeof value === "bigint") return value;
    if (typeof value === "number") return BigInt(Math.trunc(value));
    return this.#mismatch(index, "columnInteger");
  }
  columnFloat(index: number): number {
    const value = this.#value(index);
    if (value === null) return 0;
    if (typeof value === "number") return value;
    if (typeof value === "bigint") return Number(value);
    return this.#mismatch(index, "columnFloat");
  }
  columnText(index: number): string | null {
    const value = this.#value(index);
    if (value === null || typeof value === "string") return value;
    return this.#mismatch(index, "columnText");
  }
  columnBlob(index: number): Uint8Array | null {
    const value = this.#value(index);
    if (value === null || value instanceof Uint8Array) return value;
    return this.#mismatch(index, "columnBlob");
  }
  #value(index: number): SqlValue {
    if (!this.#row) throw new ZovaError("ZOVA_MISUSE", 16, "No current row: step() must return \"row\" first");
    if (!Number.isInteger(index) || index < 0 || index >= this.#row.length) invalid("Column index out of range");
    return this.#row[index];
  }
  // The row was converted once in the worker; text/number conversions would
  // not match SQLite's formatting, so they are refused instead of guessed.
  #mismatch(index: number, accessor: string): never {
    throw new ZovaError("ZOVA_MISUSE", 16, `${accessor}: column ${index} holds ${this.columnType(index)}`);
  }
}

export type ObjectStorageProfile = "deduplication" | "streaming";
export interface ObjectPutOptions { readonly profile: ObjectStorageProfile; }
export interface ObjectManifestChunk {
  readonly index: bigint;
  readonly hash: Uint8Array;
  readonly offset: bigint;
  readonly sizeBytes: bigint;
}
export type ObjectManifestChunkInput = ObjectManifestChunk;
export interface ObjectManifest {
  readonly objectId: Uint8Array;
  readonly sizeBytes: bigint;
  readonly chunkCount: bigint;
  readonly chunker: string;
  readonly chunks: readonly ObjectManifestChunk[];
}
/** Origin for `ObjectSeekableReader.seek`, as in native `zova-js`. */
export type SeekWhence = "start" | "current" | "end";

/** A `WritableStream` that stores the written bytes as one object; see `Database.objectWriter()`. */
export class ObjectWriter extends WritableStream<Uint8Array> {
  /** The stored object's ID once the stream closes; rejects if it is aborted or fails. */
  readonly id: Promise<Uint8Array>;

  /** @internal Use Database.objectWriter(). */
  constructor(request: Request, handle: number, token: symbol) {
    if (token !== constructionToken) invalid("Use Database.objectWriter()");
    let settle!: { resolve: (id: Uint8Array) => void; reject: (error: unknown) => void };
    const id = new Promise<Uint8Array>((resolve, reject) => { settle = { resolve, reject }; });
    id.catch(() => undefined);
    let done = false;
    const cancel = async (reason: unknown) => {
      if (done) return;
      done = true;
      settle.reject(reason);
      await request("object_writer_cancel", () => ({ handle })).catch(() => undefined);
    };
    super({
      async write(chunk) {
        if (!(chunk instanceof Uint8Array)) {
          const error = new ZovaError("ZOVA_INVALID_ARGUMENT", 1, "Object writers accept Uint8Array chunks");
          await cancel(error);
          throw error;
        }
        try {
          await request("object_writer_write", () => ({ handle, data: chunk.slice() }), args => [(args as { data: Uint8Array }).data.buffer]);
        } catch (error) {
          const typed = failure(error);
          await cancel(typed);
          throw typed;
        }
      },
      async close() {
        done = true;
        try { settle.resolve(await request<Uint8Array>("object_writer_finish", () => ({ handle }))); }
        catch (error) { const typed = failure(error); settle.reject(typed); throw typed; }
      },
      abort: reason => cancel(reason ?? new ZovaError("ZOVA_INTERRUPTED", 18, "Object writer was aborted")),
    });
    this.id = id;
  }
}

/**
 * Seekable, verified reader for one stored object. Each chunk is checked
 * against its manifest SHA-256 before its bytes are returned. Calls run in
 * order; reads at or past the end return an empty array.
 */
export class ObjectSeekableReader {
  #request: Request;
  #handle: number;
  #position = 0n;
  #closing?: Promise<void>;
  /** Object size in bytes. */
  readonly size: bigint;

  /** @internal Use Database.objectSeekableReader(). */
  constructor(request: Request, handle: number, objectSize: bigint, token: symbol) {
    if (token !== constructionToken) invalid("Use Database.objectSeekableReader()");
    this.#request = request;
    this.#handle = handle;
    this.size = objectSize;
  }
  get closed(): boolean { return this.#closing !== undefined; }
  /** Offset of the next `read()`. */
  get position(): bigint { return this.#position; }
  /** Reads up to `size` bytes at the current position and advances it. */
  async read(size: number): Promise<Uint8Array> {
    const bytes = await this.readAt(this.#position, size);
    return bytes;
  }
  /** Moves the read offset and returns the new absolute offset. */
  async seek(offset: bigint | number, whence: SeekWhence = "start"): Promise<bigint> {
    if (typeof offset === "number" && !Number.isSafeInteger(offset)) invalid("Offset must be a safe integer or bigint");
    if (typeof offset !== "number" && typeof offset !== "bigint") invalid("Offset must be a safe integer or bigint");
    const base = whence === "start" ? 0n : whence === "current" ? this.#position : whence === "end" ? this.size : invalid("Unknown seek origin");
    const target = base + BigInt(offset);
    if (target < 0n) invalid("Offset must not be negative");
    this.#position = target;
    return target;
  }
  /** Reads up to `length` bytes at `offset` in one worker call, then continues from there. */
  async readAt(offset: bigint, length: number): Promise<Uint8Array> {
    if (this.closed) throw new ZovaError("ZOVA_OBJECT_READER_CLOSED", 63, "Reader is closed");
    if (typeof offset !== "bigint" || offset < 0n || offset >= (1n << 64n)) invalid("Offset must be an unsigned 64-bit bigint");
    const bytes = await this.#request<Uint8Array>("object_seekable_read_at", () => ({ handle: this.#handle, offset, size: size(length, "Length") }));
    this.#position = offset + BigInt(bytes.length);
    return bytes;
  }
  close(): Promise<void> {
    this.#closing ??= this.#request<void>("object_stream_close", () => ({ handle: this.#handle }));
    return this.#closing;
  }
}

export function objectIdToHex(id: Uint8Array): string {
  return Array.from(checkedId(id), byte => byte.toString(16).padStart(2, "0")).join("");
}
export function objectIdFromHex(value: string): Uint8Array {
  if (typeof value !== "string" || !/^[0-9a-fA-F]{64}$/.test(value)) invalid("Object ID hex must be 64 hexadecimal characters");
  return Uint8Array.from({ length: 32 }, (_, index) => Number.parseInt(value.slice(index * 2, index * 2 + 2), 16));
}
let helper: Promise<Database> | undefined;
// The ID functions need the core's SHA-256; the first call starts one shared
// memory database worker that stays for the page's lifetime.
function hashWith(operation: string, data: Uint8Array): Promise<Uint8Array> {
  try { validateBytes(data); } catch (error) { return Promise.reject(error); }
  const copy = new Uint8Array(data);
  helper ??= Database.createMemory();
  return helper.then(db => db.objectIdOf(operation, copy));
}
/** The ID a whole object with these bytes is stored under. */
export function objectId(data: Uint8Array): Promise<Uint8Array> { return hashWith("object_id", data); }
/** The hash a chunk with these bytes is stored under. */
export function objectChunkId(data: Uint8Array): Promise<Uint8Array> { return hashWith("object_chunk_id", data); }

// As native `zova-js`, from src/version.zig; scripts/check-versions.sh keeps
// these in step with it.
/** The zova-wasm package version. */
export const packageVersion = "1.4.0";
/** The storage format this package creates. */
export const formatVersion = "14";
/** The bundled SQLite version. */
export const sqliteVersion = "3.53.4";

let abi: Promise<{ major: number; minor: number; patch: number; version: string }> | undefined;
function abiInfo() {
  helper ??= Database.createMemory();
  abi ??= helper.then(db => db.abiInfo());
  abi.catch(() => { abi = undefined; });
  return abi;
}
/** The C ABI version string of the bundled native code, as native `abiVersion`. */
export async function abiVersion(): Promise<string> { return (await abiInfo()).version; }
/** The C ABI version as numbers, as native `abiVersionParts`. */
export async function abiVersionParts(): Promise<AbiVersionParts> {
  const { major, minor, patch } = await abiInfo();
  return Object.freeze({ major, minor, patch });
}

export type Step = "row" | "done";
/** `step()` results by name, as native `zova-js`'s `Step` enum. */
export const Step = Object.freeze({ Row: "row", Done: "done" } as const);
export type ColumnType = "integer" | "float" | "text" | "blob" | "null";

export interface Notification {
  readonly channel: string;
  readonly payload: string;
  readonly sequence: bigint;
  readonly droppedBefore: bigint;
}
export interface KvEntry {
  readonly key: Uint8Array;
  readonly value: Uint8Array;
}
/** As native `zova-js` `kvScan`. */
export interface KvScanOptions {
  /** Only keys that begin with these bytes. */
  readonly prefix?: Uint8Array;
  /** Inclusive lower bound. */
  readonly start?: Uint8Array;
  /** Exclusive upper bound. */
  readonly end?: Uint8Array;
  /** Continue strictly after this key. */
  readonly after?: Uint8Array;
  /** Most entries returned; must be a positive integer. */
  readonly limit: number;
  /** Return keys only; every value is then empty. */
  readonly keysOnly?: boolean;
}
export interface KvScanPage {
  readonly entries: KvEntry[];
  /** True when at least one further entry matches the same options. */
  readonly hasMore: boolean;
}

/**
 * Notifications from one channel of the same database. Delivery follows
 * native same-process semantics: a notification sent inside a transaction or
 * savepoint is received only after commit and never after rollback.
 * Notifications do not cross workers or tabs.
 */
export class Subscription {
  #request: Request;
  #handle: number;
  #closing?: Promise<void>;

  /** @internal Use Database.listen(). */
  constructor(request: Request, handle: number, token: symbol) {
    if (token !== constructionToken) invalid("Use Database.listen()");
    this.#request = request;
    this.#handle = handle;
  }
  get closed(): boolean { return this.#closing !== undefined; }
  /** The next queued notification, or null when none is waiting. */
  tryReceive(): Promise<Notification | null> {
    if (this.closed) return Promise.reject(new ZovaError("ZOVA_MISUSE", 16, "Subscription is closed"));
    return this.#request("subscription_receive", () => ({ handle: this.#handle }));
  }
  close(): Promise<void> {
    this.#closing ??= this.#request<void>("subscription_close", () => ({ handle: this.#handle }));
    return this.#closing;
  }
}
function copyParameters(parameters: readonly SqlValue[]): SqlValue[] {
  validateParameters(parameters);
  return parameters.map(value => value instanceof Uint8Array ? new Uint8Array(value) : value);
}

/** A browser database. Each instance owns a dedicated worker. */
/**
 * A fresh-build session: bulk-load empty tables, FTS tables, one graph, and
 * vector collections, then commit them together, as native `FreshBuild`.
 *
 * While the session is open other calls on its database fail. `finish`
 * commits. `abort`, `close`, any failure including invalid input, and closing
 * the database roll the whole session back.
 */
export class FreshBuild {
  readonly #request: Request;
  #closed = false;

  constructor(request: Request, token: symbol) {
    if (token !== constructionToken) invalid("Use Database.beginFreshBuild()");
    this.#request = request;
  }

  get closed(): boolean { return this.#closed; }

  /** Append rows to an empty ordinary table; each row has one value per column. */
  tableRows(tableName: string, columns: readonly string[], rows: readonly (readonly FreshValue[])[]): Promise<void> {
    return this.#rows(false, tableName, columns, rows);
  }
  /** Append rows to an empty FTS5 table; each row has one value per column. */
  ftsRows(tableName: string, columns: readonly string[], rows: readonly (readonly FreshValue[])[]): Promise<void> {
    return this.#rows(true, tableName, columns, rows);
  }
  #rows(fts: boolean, tableName: string, columns: readonly string[], rows: readonly (readonly FreshValue[])[]): Promise<void> {
    return this.#step("fresh_build_rows", () => ({
      fts, tableName: text(tableName, "Table name"), columns: list(columns, column => text(column, "Column name")),
      rows: list(rows, row => list(row, freshValue)),
    }));
  }
  /** Load one new graph. Edges name nodes by position and may carry payloads. */
  graph(graphName: string, nodes: readonly GraphFreshNodeInput[], edges: readonly GraphFreshEdgeInput[]): Promise<void> {
    return this.#step("fresh_build_graph", () => ({
      graphName: text(graphName, "Graph name"), nodes: list(nodes, freshNode), edges: freshEdges(edges, true),
    }));
  }
  /** Load vectors into an empty collection. */
  vectors(collectionName: string, vectors: readonly VectorInput[]): Promise<void> {
    return this.#step("fresh_build_vectors", () => ({
      collection: text(collectionName, "Collection name"),
      vectors: list(vectors, vector => ({ id: text(vector?.id, "Vector ID"), values: vectorValues(vector.values) })),
    }));
  }
  /** Commit the session and close it. */
  finish(): Promise<FreshBuildResult> { return this.#step("fresh_build_finish", () => ({}), true); }
  /** Roll the session back and close it. */
  abort(): Promise<void> { return this.#step("fresh_build_abort", () => ({}), true); }
  /** Roll back an unfinished session. Closing a closed session does nothing. */
  async close(): Promise<void> { if (!this.#closed) await this.abort(); }

  async #step<T>(operation: string, prepare: () => object, last = false): Promise<T> {
    if (this.#closed) throw new ZovaError("ZOVA_MISUSE", 16, "Fresh build is closed");
    let args: object;
    try { args = prepare(); } catch (error) {
      // Invalid input rolls the session back, as natively.
      await this.abort().catch(() => undefined);
      throw error;
    }
    try { return await this.#request<T>(operation, () => args, owned); }
    catch (error) { this.#closed = true; throw error; }
    finally { if (last) this.#closed = true; }
  }
}

export class Database {
  #shared: Shared;
  #scope?: Scope;
  #closing?: Promise<void>;

  private constructor(shared: Shared, token: symbol, scope?: Scope) {
    if (token !== constructionToken) invalid("Use Database.createMemory() or Database.openPersistent()");
    this.#shared = shared;
    this.#scope = scope;
  }

  /** `pageSize` 0 or omitted keeps SQLite's default. */
  static async createMemory(options: CreateOptions = {}): Promise<Database> {
    return Database.#open({ pageSize: createOptions(options).pageSize });
  }

  /**
   * Opens a persistent database, creating it when the name is new.
   * `readOnly` requires an existing database; `pageSize` applies only when
   * the name is created.
   */
  static async openPersistent(name: string, options: OpenPersistentOptions = {}): Promise<Database> {
    persistentName(name);
    return Database.#open({ name, ...createOptions(options) });
  }

  /**
   * Opens an existing persistent database for extension maintenance without
   * running installed extension hooks, so `extensionUpgrade` and
   * `extensionRebuild` can repair a database whose extension check fails.
   */
  static async openPersistentForExtensionUpgrade(name: string, options: OpenPersistentOptions = {}): Promise<Database> {
    persistentName(name);
    const { readOnly, busyTimeoutMs } = createOptions(options);
    return Database.#open({ name, upgrade: true, readOnly, busyTimeoutMs });
  }

  /**
   * Converts an ordinary SQLite database file, given as bytes or a stream, into
   * a new persistent Zova database and opens it, as native
   * `convertSqliteToZova`. An existing name is never replaced, and the SQLite
   * bytes are only staged while the conversion runs.
   */
  static async convertSqliteToPersistent(name: string, data: Uint8Array | ReadableStream<Uint8Array>): Promise<Database> {
    persistentName(name);
    if (typeof ReadableStream !== "undefined" && data instanceof ReadableStream) return Database.#importStream(name, data, true);
    if (!(data instanceof Uint8Array)) invalid("SQLite database must be a Uint8Array or a ReadableStream");
    const copy = new Uint8Array(data);
    return Database.#importStream(name, new ReadableStream({ start(controller) { controller.enqueue(copy); controller.close(); } }), true);
  }

  /**
   * Reads the storage format of a persistent database without opening or
   * changing it. Takes the database's lock, so an open owner causes `ZOVA_BUSY`.
   */
  static async probePersistent(name: string): Promise<FormatInfo> {
    persistentName(name);
    try {
      return await Database.#maintain(name, 0, channel => channel.request("probe"));
    } catch (error) { throw failure(error); }
  }

  /**
   * Migrates a persistent database written in an older storage format to the
   * current one, in place. `openPersistent()` never migrates by itself.
   *
   * The migration holds the database's lock, so other tabs get `ZOVA_BUSY`. It
   * copies, migrates and verifies a staged copy in the same storage, then
   * replaces the database in one journaled write: a stopped worker leaves the
   * original or the migrated database, and the next open or migration finishes
   * recovery. Needs free origin storage for two copies of the database. A
   * database that is already current resolves without changes.
   *
   * Cancelling before the replacement starts rejects with `ZOVA_INTERRUPTED`
   * and leaves the database unchanged. Once it has started, it completes.
   */
  static async migratePersistent(name: string, options: MigrateOptions = {}): Promise<void> {
    persistentName(name);
    const { progress: callback, signal } = options ?? {};
    if (callback !== undefined && typeof callback !== "function") invalid("progress must be a function");
    const interrupted = () => new ZovaError("ZOVA_INTERRUPTED", 18, "Migration was cancelled");
    if (signal?.aborted) throw interrupted();
    let thrown: { error: unknown } | undefined;
    // Set synchronously before the replacement is requested; later cancels are ignored.
    let publishing = false;
    let cancelled = false;
    let stop!: () => void;
    const stopped = new Promise<"stopped">(resolve => { stop = () => resolve("stopped"); });
    const cancel = () => { if (!publishing) { cancelled = true; stop(); } };
    signal?.addEventListener("abort", cancel, { once: true });
    const report = (event: Progress) => {
      if (thrown || !callback) return;
      try { callback(event); } catch (error) { thrown = { error }; cancel(); }
    };
    let channel: WorkerChannel | undefined;
    try {
      channel = Database.#spawn();
      const migrating = channel;
      const run = (async () => {
        await migrating.request("initialize", { name, maintenance: true });
        const staged = await migrating.request("migrate_stage", { verify: options?.verify !== false }, report) as { staged: boolean };
        if (!staged.staged || cancelled) return;
        publishing = true;
        await migrating.request("migrate_publish", {}, report);
      })();
      if (await Promise.race([run.then(() => "done" as const), stopped]) === "stopped" || cancelled) {
        run.catch(() => undefined);
        channel.terminate();
        // Stopped before the replacement was requested. Under the lock, remove
        // the staged copy and confirm the database is unchanged.
        const settled = await Database.#maintain<{ migrated: boolean }>(name, 5000, c => c.request("migrate_settle"));
        if (!settled.migrated) throw thrown ? thrown.error : interrupted();
      }
      if (thrown) throw thrown.error;
    } catch (error) {
      if (thrown && error === thrown.error) throw error;
      throw failure(error);
    } finally {
      signal?.removeEventListener("abort", cancel);
      if (channel && !channel.closed) await channel.close().catch(() => undefined);
    }
  }

  /**
   * Copies the stored database `sourceName` to the new persistent name
   * `targetName` with the same guarantees as `backupTo`. The source must exist
   * and be a current-format database; it is opened, read and closed.
   */
  static async restoreBackup(sourceName: string, targetName: string, options: CopyOptions = {}): Promise<void> {
    persistentName(sourceName);
    persistentName(targetName);
    const source = await Database.#open({ name: sourceName, existing: true });
    try { await source.backupTo(targetName, options); } finally { await source.close().catch(() => undefined); }
  }

  /**
   * Restores the stored database `sourceName` into a new memory database. The
   * source is owned only while it is read.
   */
  static async restoreBackupToMemory(sourceName: string, options: { readonly verify?: boolean } = {}): Promise<Database> {
    persistentName(sourceName);
    return Database.#open({ restoreFrom: sourceName, verify: options?.verify !== false });
  }

  static #spawn(): WorkerChannel {
    return new WorkerChannel(new Worker(new URL("./worker.mjs", import.meta.url), { type: "module" }));
  }

  // Runs `use` in a worker that owns `name` without opening the database.
  static async #maintain<T>(name: string, waitMs: number, use: (channel: WorkerChannel) => Promise<T>): Promise<T> {
    const channel = Database.#spawn();
    try {
      await channel.request("initialize", { name, maintenance: true, waitMs });
      return await use(channel);
    } finally {
      await channel.close().catch(() => undefined);
    }
  }

  /**
   * Stores exported database bytes, or a stream of them, under a new
   * persistent name and opens it. An existing name is never replaced. The
   * stored file must pass normal Zova opening and the core's copy
   * verification, or it is removed again. A stream is written as it arrives,
   * so neither side holds the whole database; until it completes the name is
   * marked incomplete, and a stopped import is never listed or opened.
   */
  static async importPersistent(name: string, data: Uint8Array | ReadableStream<Uint8Array>): Promise<Database> {
    persistentName(name);
    if (typeof ReadableStream !== "undefined" && data instanceof ReadableStream) return Database.#importStream(name, data);
    if (!(data instanceof Uint8Array)) invalid("Imported database must be a Uint8Array or a ReadableStream");
    return Database.#open({ name, data: new Uint8Array(data) });
  }
  static async #importStream(name: string, stream: ReadableStream<Uint8Array>, convert = false): Promise<Database> {
    const reader = stream.getReader();
    const channel = Database.#spawn();
    try {
      await channel.request("initialize", { name, importing: true, convert });
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (!(value instanceof Uint8Array)) invalid("Imported chunks must be Uint8Array values");
        const chunk = value.slice();
        await channel.request("import_write", { data: chunk }, undefined, [chunk.buffer]);
      }
      await channel.request("import_finish");
      return new Database({ channel, tail: Promise.resolve(), active: 0 }, constructionToken);
    } catch (error) {
      reader.cancel(error).catch(() => undefined);
      await channel.request("import_abort").catch(() => undefined);
      channel.terminate();
      throw failure(error);
    }
  }

  /** Stored persistent databases of this origin, by name. */
  static async listPersistent(): Promise<PersistentDatabaseInfo[]> {
    const channel = Database.#spawn();
    try { return await channel.request("list_persistent"); }
    catch (error) { throw failure(error); }
    finally { channel.terminate(); }
  }
  /**
   * Deletes a stored persistent database. Takes its lock first, so a database
   * open in another tab or worker rejects with `ZOVA_BUSY` and nothing is
   * removed. Resolves whether the name held storage.
   */
  static async deletePersistent(name: string): Promise<boolean> {
    persistentName(name);
    const channel = Database.#spawn();
    try { return await channel.request("delete_persistent", { name }); }
    catch (error) { throw failure(error); }
    finally { channel.terminate(); }
  }

  static async #open(args: {
    name?: string; data?: Uint8Array; existing?: boolean; restoreFrom?: string; verify?: boolean;
    pageSize?: number; readOnly?: boolean; busyTimeoutMs?: number; upgrade?: boolean;
  }): Promise<Database> {
    let channel: WorkerChannel | undefined;
    try {
      channel = Database.#spawn();
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
  // `transfer` names buffers inside the prepared arguments that this package
  // owns and may move to the worker instead of copying.
  async #request<T>(operation: string, prepare: () => object, outlive = false, transfer?: (args: object) => Transferable[],
    progress?: (event: Progress) => void): Promise<T> {
    try {
      if (this.closed) throw new ZovaError("ZOVA_MISUSE", 16, "Database is closed");
      const inTransaction = this.#scope !== undefined && !this.#scope.done;
      if (this.#scope?.done && !outlive) throw new ZovaError("ZOVA_MISUSE", 16, "Transaction has ended");
      // Validation and input copies happen here, before any await.
      const args = prepare();
      // Outside a transaction the request posts synchronously; while one is
      // running, other callers wait for it so their work cannot interleave.
      if (!inTransaction && this.#shared.active > 0) await this.#shared.tail;
      return await this.#shared.channel.request(operation, args, progress, transfer?.(args) ?? []) as T;
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
    if (this.#scope) throw new ZovaError("ZOVA_MISUSE", 16, "Transactions cannot be nested");
    if (this.closed) throw new ZovaError("ZOVA_MISUSE", 16, "Database is closed");
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

  // Explicit transaction control on the database's one connection. Calls on
  // this database run in order, so the caller that begins a transaction owns
  // it until commit or rollback. Inside `transaction()`, use savepoints.
  begin(): Promise<void> { return this.#control("begin_deferred"); }
  beginImmediate(): Promise<void> { return this.#control("begin"); }
  commit(): Promise<void> { return this.#control("commit"); }
  rollback(): Promise<void> { return this.#control("rollback"); }
  #control(operation: string): Promise<void> {
    if (this.#scope) return Promise.reject(new ZovaError("ZOVA_MISUSE", 16, "Use savepoints inside transaction()"));
    return this.#request(operation, () => ({}));
  }

  /**
   * Opens a savepoint. With a callback, releases it when the callback
   * resolves, or rolls back to it and releases it when the callback throws.
   */
  savepoint(name: string): Promise<void>;
  savepoint<T>(name: string, callback: (database: Database) => T | Promise<T>): Promise<T>;
  async savepoint<T>(name: string, callback?: (database: Database) => T | Promise<T>): Promise<T | void> {
    if (callback !== undefined && typeof callback !== "function") invalid("Savepoint callback must be a function");
    await this.#request("savepoint", () => ({ name: text(name, "Savepoint name") }));
    if (callback === undefined) return;
    let value: T;
    try {
      value = await callback(this);
    } catch (error) {
      await this.rollbackToSavepoint(name).catch(() => undefined);
      await this.releaseSavepoint(name).catch(() => undefined);
      throw error;
    }
    await this.releaseSavepoint(name);
    return value;
  }
  releaseSavepoint(name: string): Promise<void> {
    return this.#request("release_savepoint", () => ({ name: text(name, "Savepoint name") }));
  }
  rollbackToSavepoint(name: string): Promise<void> {
    return this.#request("rollback_to_savepoint", () => ({ name: text(name, "Savepoint name") }));
  }

  changes(): Promise<bigint> { return this.#request("changes", () => ({})); }
  totalChanges(): Promise<bigint> { return this.#request("total_changes", () => ({})); }
  lastInsertRowid(): Promise<bigint> { return this.#request("last_insert_rowid", () => ({})); }
  /**
   * Sets SQLite's busy timeout. A browser database has one exclusive owner
   * and one connection, so there is normally nothing to wait for.
   */
  setBusyTimeout(milliseconds: number): Promise<void> {
    return this.#request("set_busy_timeout", () => ({ milliseconds: size(milliseconds, "Busy timeout") }));
  }

  /** Queues a notification for this database's subscriptions on `channel`. */
  notify(channel: string, payload: string): Promise<void> {
    return this.#request("notify", () => {
      if (typeof payload !== "string") invalid("Notification payload must be a string");
      return { channel: text(channel, "Channel"), payload };
    });
  }
  async listen(channel: string): Promise<Subscription> {
    const handle = await this.#request<number>("listen", () => ({ channel: text(channel, "Channel") }));
    return new Subscription((operation, prepare) => this.#request(operation, prepare, true), handle, constructionToken);
  }

  async prepare(sql: string): Promise<Statement> {
    const info = await this.#request<{ handle: number; parameterCount: number; columns: string[] }>(
      "prepare", () => { validateSql(sql); return { sql }; });
    return new Statement((operation, prepare) => this.#request(operation, prepare, true), info, constructionToken);
  }

  /**
   * Extension lifecycle for the extensions this module knows: the bundled
   * `trgm`, and plugins linked into a custom build. There is no run-time
   * loading; `.zovaext` bundles, bundle paths and trust stores do not apply.
   */
  installExtension(name: string): Promise<void> {
    return this.#request("extension_install", () => ({ name: text(name, "Extension name") }));
  }
  dropExtension(name: string): Promise<void> {
    return this.#request("extension_drop", () => ({ name: text(name, "Extension name") }));
  }
  listExtensions(): Promise<ExtensionInfo[]> { return this.#request("extensions_list", () => ({})); }
  extensionInfo(name: string): Promise<ExtensionInfo> {
    return this.#request("extension_info", () => ({ name: text(name, "Extension name") }));
  }
  checkExtension(name: string): Promise<void> {
    return this.#request("extension_check", () => ({ name: text(name, "Extension name") }));
  }
  checkExtensions(): Promise<void> { return this.#request("extensions_check_all", () => ({})); }

  /** Releases free pages of incremental auto-vacuum files in bounded steps, as native. */
  reclaimSpace(options: ReclaimOptions = {}): Promise<ReclaimedMember[]> {
    return this.#request("reclaim", () => ({
      maxPages: options?.maxPages === undefined ? 0 : size(options.maxPages, "maxPages"),
      stepPages: options?.stepPages === undefined ? 0 : size(options.stepPages, "stepPages"),
    }));
  }
  /** Rebuilds the database file with SQLite `VACUUM`. */
  vacuum(): Promise<void> { return this.#request("vacuum", () => ({})); }

  /**
   * Copies this persistent database to the new persistent name `targetName`
   * with SQLite's online backup, verified by the core like native `backupTo`.
   * The target gets the same ownership check as opening it (`ZOVA_BUSY`) and
   * must not exist (`ZOVA_DESTINATION_EXISTS`). The copy is staged and
   * verified in this database's storage, then published to the target in
   * one journaled write; a stopped worker leaves no target, and the next open
   * of the name removes any incomplete one. Cancelling with `signal` or a
   * throwing `progress` takes effect at the next phase boundary, before
   * publication, and rejects with `ZOVA_INTERRUPTED` without a target. Once
   * the `publish` phase starts, the copy completes.
   */
  backupTo(targetName: string, options: CopyOptions = {}): Promise<void> { return this.#copyTo(false, targetName, options); }
  /** As `backupTo`, through SQLite `VACUUM INTO`, which drops free pages. */
  compactTo(targetName: string, options: CopyOptions = {}): Promise<void> { return this.#copyTo(true, targetName, options); }
  async #copyTo(compact: boolean, target: string, options: CopyOptions): Promise<void> {
    persistentName(target);
    const { progress: callback, signal } = options ?? {};
    if (callback !== undefined && typeof callback !== "function") invalid("progress must be a function");
    const interrupted = () => new ZovaError("ZOVA_INTERRUPTED", 18, "Copy was cancelled");
    if (signal?.aborted) throw interrupted();
    // Set by `report` between awaits; read through a call so it is not narrowed.
    const stop: { thrown?: { error: unknown } } = {};
    const thrown = () => stop.thrown;
    const report = (event: Progress) => {
      if (stop.thrown || !callback) return;
      try { callback(event); } catch (error) { stop.thrown = { error }; }
    };
    const send = (operation: string, args: object = {}) => this.#request(operation, () => args, false, undefined, report);
    try {
      await send("copy_begin", { target });
      try {
        await send("copy_stage", { compact, verify: options?.verify !== false });
        if (thrown()) throw thrown()!.error;
        if (signal?.aborted) throw interrupted();
        await send("copy_publish");
      } catch (error) {
        await this.#request("copy_discard", () => ({})).catch(() => undefined);
        throw error;
      }
      if (thrown()) throw thrown()!.error;
    } catch (error) {
      if (thrown() && error === thrown()!.error) throw error;
      throw failure(error);
    }
  }

  /**
   * Streams the committed database in reads of up to `chunkSize` bytes (1 MiB
   * by default): the stored file, or a serialized copy of a memory database.
   * Other calls on this database wait until the stream ends or is cancelled.
   * Rejects while a transaction is open. Import the bytes with
   * `importPersistent()`, which verifies them.
   */
  async exportStream(chunkSize = 1 << 20): Promise<ReadableStream<Uint8Array>> {
    if (this.#scope) throw new ZovaError("ZOVA_MISUSE", 16, "Export the database, not its transaction handle");
    if (this.closed) throw new ZovaError("ZOVA_MISUSE", 16, "Database is closed");
    size(chunkSize, "Chunk size");
    if (chunkSize === 0) invalid("Chunk size must be positive");
    // Hold the database like a transaction: other callers wait for the stream.
    const shared = this.#shared;
    const previous = shared.tail;
    let release!: () => void;
    shared.tail = new Promise<void>(resolve => { release = resolve; });
    shared.active++;
    const scope: Scope = { done: false };
    const held = new Database(shared, constructionToken, scope);
    let finished = false;
    const finish = async (end: boolean) => {
      if (finished) return;
      finished = true;
      try { if (end) await held.#request("export_end", () => ({})).catch(() => undefined); }
      finally { scope.done = true; shared.active--; release(); }
    };
    let total: bigint;
    try {
      await previous;
      total = await held.#request<bigint>("export_begin", () => ({}));
    } catch (error) {
      await finish(false);
      throw failure(error);
    }
    let offset = 0n;
    return new ReadableStream<Uint8Array>({
      async pull(controller) {
        try {
          if (offset >= total) { await finish(true); controller.close(); return; }
          const bytes = await held.#request<Uint8Array>("export_read", () => ({ offset, size: chunkSize }));
          if (bytes.length === 0) throw new ZovaError("ZOVA_CORRUPT", 15, "Database file ended early");
          offset += BigInt(bytes.length);
          controller.enqueue(bytes);
        } catch (error) {
          await finish(true);
          controller.error(failure(error));
        }
      },
      cancel: () => finish(true),
    }, { highWaterMark: 1 });
  }

  /** The committed database as one `Uint8Array`, also for memory databases. Rejects while a transaction is open. */
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
    // Batches are atomic: all entries apply or none do, also inside a transaction.
    getMany: (namespace: Uint8Array, keys: readonly Uint8Array[]): Promise<(Uint8Array | null)[]> =>
      this.#request("kv_get_many", () => ({ namespace: kvBytes(namespace), keys: list(keys, kvBytes) })),
    putMany: (namespace: Uint8Array, entries: readonly KvEntry[]): Promise<void> =>
      this.#request("kv_put_many", () => ({
        namespace: kvBytes(namespace), entries: list(entries, entry => ({ key: kvBytes(entry?.key), value: kvBytes(entry.value) })),
      })),
    deleteMany: (namespace: Uint8Array, keys: readonly Uint8Array[]): Promise<void> =>
      this.#request("kv_delete_many", () => ({ namespace: kvBytes(namespace), keys: list(keys, kvBytes) })),
    count: (namespace: Uint8Array): Promise<bigint> =>
      this.#request("kv_count", () => ({ namespace: kvBytes(namespace) })),
    clearNamespace: (namespace: Uint8Array): Promise<void> =>
      this.#request("kv_clear_namespace", () => ({ namespace: kvBytes(namespace) })),
    /** One page of a namespace in ascending key byte order. */
    scan: (namespace: Uint8Array, options: KvScanOptions): Promise<KvScanPage> =>
      this.#request("kv_scan", () => {
        const bound = (value: Uint8Array | undefined) => value === undefined ? undefined : kvBytes(value);
        return {
          namespace: kvBytes(namespace), prefix: bound(options?.prefix), start: bound(options.start), end: bound(options.end),
          after: bound(options.after), limit: size(options.limit, "Limit"), keysOnly: Boolean(options.keysOnly),
        };
      }),
    /** Inserts one entry only when its key is absent. Resolves whether it was written. */
    putIfAbsent: (namespace: Uint8Array, key: Uint8Array, value: Uint8Array): Promise<boolean> =>
      this.#request("kv_put_if_absent", () => ({ namespace: kvBytes(namespace), key: kvBytes(key), value: kvBytes(value) })),
    /**
     * Replaces one value only when the current value equals `expected` byte
     * for byte. A missing key never matches. Resolves whether it was written.
     */
    compareAndPut: (namespace: Uint8Array, key: Uint8Array, expected: Uint8Array, value: Uint8Array): Promise<boolean> =>
      this.#request("kv_compare_and_put", () => ({
        namespace: kvBytes(namespace), key: kvBytes(key), expected: kvBytes(expected), value: kvBytes(value),
      })),
    /**
     * Deletes one entry only when its current value equals `expected` byte for
     * byte. A missing key never matches. Resolves whether it was deleted.
     */
    compareAndDelete: (namespace: Uint8Array, key: Uint8Array, expected: Uint8Array): Promise<boolean> =>
      this.#request("kv_compare_and_delete", () => ({ namespace: kvBytes(namespace), key: kvBytes(key), expected: kvBytes(expected) })),
  });

  /** Selects chunk compression for objects written through this database. */
  setObjectCompression(compression: ObjectCompression): Promise<void> {
    return this.#request("object_set_compression", () => ({ compression: text(compression, "Compression") }));
  }
  putObject(data: Uint8Array): Promise<Uint8Array> {
    return this.#request("object_put", () => { validateBytes(data); return { data: new Uint8Array(data) }; });
  }
  getObject(id: Uint8Array): Promise<Uint8Array> {
    return this.#request("object_get", () => ({ id: checkedId(id) }));
  }
  readObjectRange(id: Uint8Array, offset: bigint, length: number): Promise<Uint8Array> {
    return this.#request("object_read_range", () => {
      if (typeof offset !== "bigint" || offset < 0n || offset >= (1n << 64n)) invalid("Offset must be an unsigned 64-bit bigint");
      return { id: checkedId(id), offset, size: size(length, "Length") };
    });
  }
  hasObject(id: Uint8Array): Promise<boolean> {
    return this.#request("object_exists", () => ({ id: checkedId(id) }));
  }
  objectSize(id: Uint8Array): Promise<bigint> {
    return this.#request("object_size", () => ({ id: checkedId(id) }));
  }
  deleteObject(id: Uint8Array): Promise<void> {
    return this.#request("object_delete", () => ({ id: checkedId(id) }));
  }
  /** @internal Used by checkedId() and objectChunkId(). */
  objectIdOf(operation: string, data: Uint8Array): Promise<Uint8Array> {
    if (operation !== "object_id" && operation !== "object_chunk_id") invalid("Unknown identity");
    return this.#request(operation, () => ({ data }), false, args => [(args as { data: Uint8Array }).data.buffer]);
  }
  putObjectWithOptions(data: Uint8Array, options: ObjectPutOptions): Promise<Uint8Array> {
    return this.#request("object_put_with_options", () => { validateBytes(data); return { data: new Uint8Array(data), profile: objectProfile(options) }; });
  }
  objectChunkCount(id: Uint8Array): Promise<bigint> {
    return this.#request("object_chunk_count", () => ({ id: checkedId(id) }));
  }
  objectManifest(id: Uint8Array): Promise<ObjectManifest> {
    return this.#request("object_manifest", () => ({ id: checkedId(id) }));
  }
  getObjectChunk(hash: Uint8Array): Promise<Uint8Array> {
    return this.#request("object_chunk_get", () => ({ hash: checkedId(hash) }));
  }
  hasObjectChunk(hash: Uint8Array): Promise<boolean> {
    return this.#request("object_chunk_exists", () => ({ hash: checkedId(hash) }));
  }
  /** Stores one loose chunk after checking that `hash` is the SHA-256 of `data`. */
  putObjectChunk(hash: Uint8Array, data: Uint8Array): Promise<void> {
    return this.#request("object_chunk_put", () => { validateBytes(data); return { hash: checkedId(hash), data: new Uint8Array(data) }; });
  }
  putObjectChunkWithOptions(hash: Uint8Array, data: Uint8Array, options: ObjectPutOptions): Promise<void> {
    return this.#request("object_chunk_put", () => {
      validateBytes(data);
      return { hash: checkedId(hash), data: new Uint8Array(data), profile: objectProfile(options) };
    });
  }
  /** Resolves false when the chunk did not exist. */
  deleteObjectChunk(hash: Uint8Array): Promise<boolean> {
    return this.#request("object_chunk_delete", () => ({ hash: checkedId(hash) }));
  }
  /** Records an object from stored chunks; the manifest and `id` are verified. */
  assembleObjectFromChunks(id: Uint8Array, sizeBytes: bigint, chunks: readonly ObjectManifestChunkInput[]): Promise<void> {
    return this.#request("object_assemble", () => ({ id: checkedId(id), sizeBytes, chunks: list(chunks, manifestChunk) }));
  }
  assembleObjectFromChunksWithOptions(id: Uint8Array, sizeBytes: bigint, chunks: readonly ObjectManifestChunkInput[],
    options: ObjectPutOptions): Promise<void> {
    return this.#request("object_assemble", () => ({
      id: checkedId(id), sizeBytes, chunks: list(chunks, manifestChunk), profile: objectProfile(options),
    }));
  }

  /**
   * Streams bytes into a new object. Each written chunk is copied once and
   * moved to the worker, so memory stays bounded by the chunk size, not the
   * object size. Close the stream to store the object and resolve `writer.id`;
   * aborting it, or any failed write, cancels the object and stores nothing.
   */
  objectWriter(): Promise<ObjectWriter> { return this.#writer(undefined); }
  objectWriterWithOptions(options: ObjectPutOptions): Promise<ObjectWriter> {
    try { return this.#writer(objectProfile(options)); } catch (error) { return Promise.reject(failure(error)); }
  }
  async #writer(profile: ObjectStorageProfile | undefined): Promise<ObjectWriter> {
    const handle = await this.#request<number>("object_writer_create", () => ({ profile }));
    return new ObjectWriter((operation, prepare, transfer) => this.#request(operation, prepare, true, transfer), handle, constructionToken);
  }

  /**
   * Streams a stored object's verified bytes in reads of up to `chunkSize`
   * bytes (1 MiB by default), each moved from the worker without copying.
   * Cancel the stream to release the reader early.
   */
  async objectReader(id: Uint8Array, chunkSize = 1 << 20): Promise<ReadableStream<Uint8Array>> {
    size(chunkSize, "Chunk size");
    if (chunkSize === 0) invalid("Chunk size must be positive");
    const request: Request = (operation, prepare) => this.#request(operation, prepare, true);
    const handle = await this.#request<number>("object_reader_create", () => ({ id: checkedId(id) }));
    let open = true;
    const close = () => { if (!open) return Promise.resolve(); open = false; return request<void>("object_stream_close", () => ({ handle })); };
    return new ReadableStream<Uint8Array>({
      async pull(controller) {
        try {
          const bytes = await request<Uint8Array>("object_reader_read", () => ({ handle, size: chunkSize }));
          if (bytes.length > 0) { controller.enqueue(bytes); return; }
          await close();
          controller.close();
        } catch (error) {
          await close().catch(() => undefined);
          controller.error(failure(error));
        }
      },
      cancel: () => close(),
    }, { highWaterMark: 1 });
  }

  /** Verified random access to one object, for example to serve HTTP ranges. */
  async objectSeekableReader(id: Uint8Array): Promise<ObjectSeekableReader> {
    const opened = await this.#request<{ handle: number; size: bigint }>("object_seekable_create", () => ({ id: checkedId(id) }));
    return new ObjectSeekableReader((operation, prepare) => this.#request(operation, prepare, true), opened.handle, opened.size, constructionToken);
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
  /**
   * Exact nearest-neighbor search, closest first. Pass `VectorSearchOptions`
   * to filter as native `zova-js` does; a bare `limit` remains accepted.
   */
  searchVectors(collectionName: string, query: VectorValues, options: VectorSearchOptions | number): Promise<VectorSearchResult[]> {
    if (typeof options === "number") {
      return this.#request("vector_search", () => ({
        collection: text(collectionName, "Collection name"), query: vectorValues(query), limit: size(options, "Limit"),
      }));
    }
    return this.#request("vector_search_filtered", () => ({
      collection: text(collectionName, "Collection name"), query: vectorValues(query), ...searchOptions(options),
    }));
  }
  /** Search by a stored vector, which is excluded from its own results. */
  searchVectorsById(collectionName: string, vectorId: string, options: VectorSearchOptions | number): Promise<VectorSearchResult[]> {
    if (typeof options === "number") {
      return this.#request("vector_search_by_id", () => ({
        collection: text(collectionName, "Collection name"), id: text(vectorId, "Vector ID"), limit: size(options, "Limit"),
      }));
    }
    return this.#request("vector_search_by_id_filtered", () => ({
      collection: text(collectionName, "Collection name"), id: text(vectorId, "Vector ID"), ...searchOptions(options),
    }));
  }

  /** Scores each stored i8 vector against several query rows at once. */
  searchVectorsMultiI8(collectionName: string, options: VectorMultiI8SearchOptions): Promise<VectorSearchResult[]> {
    return this.#request("vector_search_multi_i8", () => {
      if (!(options?.queryValues instanceof Int8Array)) invalid("queryValues must be an Int8Array");
      const optional = (value: number | undefined, label: string) => value === undefined ? undefined : size(value, label);
      return {
        collection: text(collectionName, "Collection name"), queryValues: options.queryValues.slice(),
        queryCount: size(options.queryCount, "queryCount"), dimensions: size(options.dimensions, "dimensions"),
        candidateIds: options.candidateIds === undefined ? undefined : list(options.candidateIds, id => text(id, "Vector ID")),
        mode: optionalText(options.mode, "Mode"), aggregation: optionalText(options.aggregation, "Aggregation"),
        prefilterQueryIndex: optional(options.prefilterQueryIndex, "prefilterQueryIndex"),
        prefilterLimit: optional(options.prefilterLimit, "prefilterLimit"), limit: size(options.limit, "Limit"),
      };
    }, false, owned);
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
    return this.#request("graph_walk", () => walkOptions(options));
  }
  /** Breadth-first walk along outgoing or incoming edges. */
  graphWalkDirection(options: GraphWalkDirectionOptions): Promise<GraphWalkItem[]> {
    return this.#request("graph_walk", () => walkOptions({ ...options, direction: text(options?.direction, "Direction") }));
  }
  graphWalkDirectionProfiled(options: GraphWalkDirectionOptions): Promise<GraphWalkDirectionProfiled> {
    return this.#request("graph_walk_profiled", () => walkOptions({ ...options, direction: text(options?.direction, "Direction") }));
  }

  /** One atomic batch; resolves each node's key in input order. */
  putGraphNodesKeyed(inputs: readonly GraphNodeInput[]): Promise<BigInt64Array> {
    return this.#request("graph_node_put_many_keyed", () => ({ nodes: list(inputs, node) }));
  }
  /** One atomic batch; resolves each edge's key in input order. */
  putGraphEdgesKeyed(inputs: readonly GraphEdgeInput[]): Promise<BigInt64Array> {
    return this.#request("graph_edge_put_many_keyed", () => ({ edges: list(inputs, edge) }));
  }
  /** Nodes by key, in input order; `null` for a missing key. */
  getGraphNodesKeyed(graphName: string, nodeKeys: GraphKeys): Promise<(GraphKeyedNode | null)[]> {
    return this.#request("graph_nodes_get_keyed", () => ({ graphName: text(graphName, "Graph name"), keys: graphKeys(nodeKeys) }), false, owned);
  }
  /** Edges by key, in input order; `null` for a missing key. */
  getGraphEdgesKeyed(graphName: string, edgeKeys: GraphKeys): Promise<(GraphKeyedEdge | null)[]> {
    return this.#request("graph_edges_get_keyed", () => ({ graphName: text(graphName, "Graph name"), keys: graphKeys(edgeKeys) }), false, owned);
  }
  graphNeighborsKeyed(options: GraphNeighborsOptions): Promise<GraphKeyedNeighbor[]> {
    return this.#request("graph_neighbors_keyed", () => ({ ...edgeScope(options), limit: size(options.limit, "Limit") }));
  }
  /** Degree of each node key, in input order. */
  graphDegreesKeyed(options: GraphKeyedDegreeOptions): Promise<BigUint64Array> {
    return this.#request("graph_degrees_keyed", () => ({
      graphName: text(options?.graphName, "Graph name"), nodeKeys: graphKeys(options.nodeKeys),
      direction: text(options.direction, "Direction"), edgeType: optionalText(options.edgeType, "Edge type"),
    }), false, owned);
  }
  /** Edge payloads by key, in input order; `null` for a missing edge. */
  getGraphEdgePayloads(graphName: string, edgeKeys: GraphKeys): Promise<(Uint8Array | null)[]> {
    return this.#request("graph_edge_payloads_get", () => ({ graphName: text(graphName, "Graph name"), keys: graphKeys(edgeKeys) }), false, owned);
  }
  /** One atomic batch. */
  replaceGraphEdgePayloads(graphName: string, replacements: readonly GraphEdgePayloadReplacement[]): Promise<void> {
    return this.#request("graph_edge_payloads_replace", () => ({
      graphName: text(graphName, "Graph name"),
      replacements: list(replacements, item => ({ edgeKey: graphKeys([item?.edgeKey])[0], payload: kvBytes(item.payload) })),
    }), false, owned);
  }
  /** One page of nodes and edges in creation order. */
  graphScan(options: GraphScanOptions): Promise<GraphScanPage> {
    return this.#request("graph_scan", () => {
      const cursor = (value: GraphScanCursor | undefined) => value === undefined ? undefined
        : { createdOrder: graphKeys([value?.createdOrder])[0], key: graphKeys([value.key])[0] };
      return {
        graphName: text(options?.graphName, "Graph name"), nodeAfter: cursor(options.nodeAfter), edgeAfter: cursor(options.edgeAfter),
        nodeLimit: size(options.nodeLimit, "nodeLimit"), edgeLimit: size(options.edgeLimit, "edgeLimit"),
      };
    });
  }
  /**
   * Creates and loads a new graph in one transaction. Duplicate edges are
   * merged, so their inputs share one key.
   */
  buildFreshGraphKeyed(graphName: string, nodes: readonly GraphFreshNodeInput[], edges: readonly GraphFreshEdgeInput[]): Promise<GraphFreshKeys> {
    return this.#freshGraph("normalized", graphName, nodes, edges);
  }
  /** Like `buildFreshGraphKeyed` for input that is already unique and valid. */
  buildFreshGraphPreparedKeyed(graphName: string, nodes: readonly GraphFreshNodeInput[], edges: readonly GraphFreshEdgeInput[]): Promise<GraphFreshKeys> {
    return this.#freshGraph("prepared", graphName, nodes, edges);
  }
  /** `buildFreshGraphPreparedKeyed` with edge payloads; an omitted payload is empty. */
  buildFreshGraphPreparedKeyedWithPayloads(graphName: string, nodes: readonly GraphFreshNodeInput[],
    edges: readonly GraphFreshEdgeInput[]): Promise<GraphFreshKeys> {
    return this.#freshGraph("payloads", graphName, nodes, edges);
  }
  #freshGraph(variant: string, graphName: string, nodes: readonly GraphFreshNodeInput[], edges: readonly GraphFreshEdgeInput[]): Promise<GraphFreshKeys> {
    return this.#request("graph_build_fresh", () => ({
      variant, graphName: text(graphName, "Graph name"), nodes: list(nodes, freshNode), edges: freshEdges(edges, variant === "payloads"),
    }), false, owned);
  }

  /** Starts a fresh-build session; see `FreshBuild`. */
  async beginFreshBuild(): Promise<FreshBuild> {
    await this.#request("fresh_build_begin", () => ({}));
    return new FreshBuild((operation, prepare, transfer) => this.#request(operation, prepare, false, transfer), constructionToken);
  }

  /**
   * Registers a scalar SQL function on this database. `arity` is the number
   * of arguments, or -1 for any number. The database worker imports
   * `fn.module` (resolved against the page URL) and calls its export
   * `fn.export` synchronously for each row. Arguments arrive as `SqlValue`s:
   * integers are `bigint`, floats `number`. A thrown exception or an
   * unsupported result fails the statement with that message. The function
   * runs in the worker, so it cannot use page state, this database, or await.
   */
  registerFunction(name: string, arity: number, fn: SqlFunctionModule, options: SqlFunctionOptions = {}): Promise<void> {
    return this.#request("register_function", () => {
      if (typeof fn !== "object" || fn === null) invalid("A SQL function is a module URL and an export name");
      const base = (globalThis as { location?: { href?: string } }).location?.href;
      let module: string;
      try { module = new URL(fn.module, base).href; }
      catch { invalid("SQL function module must be a URL"); }
      return {
        name: text(name, "Function name"), arity, module, export: text(fn.export, "Export name"),
        options: {
          deterministic: Boolean(options?.deterministic), directOnly: Boolean(options?.directOnly), innocuous: Boolean(options?.innocuous),
        },
      };
    });
  }

  /** Runs the named extension's upgrade hook. */
  extensionUpgrade(name: string): Promise<void> {
    return this.#request("extension_upgrade", () => ({ name: text(name, "Extension name") }));
  }
  /** Runs the named extension's rebuild hook. */
  extensionRebuild(name: string): Promise<void> {
    return this.#request("extension_rebuild", () => ({ name: text(name, "Extension name") }));
  }

  /** @internal Used by `abiVersion()`. */
  abiInfo(): Promise<{ major: number; minor: number; patch: number; version: string }> {
    return this.#request("abi_version", () => ({}));
  }

  close(): Promise<void> {
    if (this.#scope) return Promise.reject(new ZovaError("ZOVA_MISUSE", 16, "Close the database, not its transaction handle"));
    if (this.#closing) return this.#closing;
    const closing: Promise<void> = this.#shared.channel.close().then(
      () => undefined,
      (error: unknown) => { throw failure(error); },
    );
    this.#closing = closing;
    return closing;
  }
}
