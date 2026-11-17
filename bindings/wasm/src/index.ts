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
export interface MigrateOptions extends ProgressOptions {
  /** Verify the migrated copy before publishing it. Defaults to true. */
  readonly verify?: boolean;
}
export type FormatCompatibilityName = "current" | "migratable" | "unsupported_legacy" | "unsupported_future";
export interface FormatInfo {
  readonly formatVersion: number;
  readonly compatibility: FormatCompatibilityName;
}

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
function objectId(id: Uint8Array): Uint8Array {
  if (!(id instanceof Uint8Array) || id.length !== 32) invalid("Object IDs are 32-byte Uint8Array values");
  return new Uint8Array(id);
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
    if (typeof value !== "bigint") return Promise.reject(new ZovaWasmError("Integer values are bigint", "ZOVA_INVALID_ARGUMENT", 1));
    return this.#bind(index, value);
  }
  bindFloat(index: number, value: number): Promise<void> {
    if (typeof value !== "number") return Promise.reject(new ZovaWasmError("Float values are numbers", "ZOVA_INVALID_ARGUMENT", 1));
    return this.#bind(index, value);
  }
  bindText(index: number, value: string): Promise<void> {
    if (typeof value !== "string") return Promise.reject(new ZovaWasmError("Text values are strings", "ZOVA_INVALID_ARGUMENT", 1));
    return this.#bind(index, value);
  }
  bindBlob(index: number, value: Uint8Array): Promise<void> {
    if (!(value instanceof Uint8Array)) return Promise.reject(new ZovaWasmError("Blob values are Uint8Array", "ZOVA_INVALID_ARGUMENT", 1));
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
    if (!this.#row) throw new ZovaWasmError("No current row: step() must return \"row\" first", "ZOVA_MISUSE", 16);
    if (!Number.isInteger(index) || index < 0 || index >= this.#row.length) invalid("Column index out of range");
    return this.#row[index];
  }
  // The row was converted once in the worker; text/number conversions would
  // not match SQLite's formatting, so they are refused instead of guessed.
  #mismatch(index: number, accessor: string): never {
    throw new ZovaWasmError(`${accessor}: column ${index} holds ${this.columnType(index)}`, "ZOVA_MISUSE", 16);
  }
}

export type Step = "row" | "done";
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
    if (this.closed) return Promise.reject(new ZovaWasmError("Subscription is closed", "ZOVA_MISUSE", 16));
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
    persistentName(name);
    return Database.#open({ name });
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
    const interrupted = () => new ZovaWasmError("Migration was cancelled", "ZOVA_INTERRUPTED", 18);
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
   * Stores exported database bytes under a new persistent name and opens it.
   * An existing name is never replaced, and bytes that fail normal Zova
   * validation are removed again.
   */
  static async importPersistent(name: string, data: Uint8Array): Promise<Database> {
    persistentName(name);
    if (!(data instanceof Uint8Array)) invalid("Imported database must be a Uint8Array");
    return Database.#open({ name, data: new Uint8Array(data) });
  }

  static async #open(args: { name?: string; data?: Uint8Array }): Promise<Database> {
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

  // Explicit transaction control on the database's one connection. Calls on
  // this database run in order, so the caller that begins a transaction owns
  // it until commit or rollback. Inside `transaction()`, use savepoints.
  begin(): Promise<void> { return this.#control("begin_deferred"); }
  beginImmediate(): Promise<void> { return this.#control("begin"); }
  commit(): Promise<void> { return this.#control("commit"); }
  rollback(): Promise<void> { return this.#control("rollback"); }
  #control(operation: string): Promise<void> {
    if (this.#scope) return Promise.reject(new ZovaWasmError("Use savepoints inside transaction()", "ZOVA_MISUSE", 16));
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
