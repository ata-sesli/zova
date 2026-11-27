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
export interface VectorInput {
    readonly id: string;
    readonly values: VectorValues;
}
export interface Vector {
    readonly id: string;
    readonly values: VectorValues;
}
export interface VectorSearchResult {
    readonly id: string;
    readonly distance: number;
}
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
export type GraphTargetType = "none" | "record" | "object" | "object-chunk" | "vector" | "entity" | "fact" | "concept" | "external";
export type GraphDirection = "outgoing" | "incoming";
export interface GraphInfo {
    name: string;
    nodeCount: bigint;
    edgeCount: bigint;
}
export interface GraphNodeInput {
    graphName: string;
    nodeId: string;
    kind: string;
    targetType: GraphTargetType;
    targetNamespace?: string;
    targetRef?: string;
}
export interface GraphNode extends GraphNodeInput {
}
export interface GraphEdgeInput {
    graphName: string;
    fromNodeId: string;
    edgeType: string;
    toNodeId: string;
}
export interface GraphEdge extends GraphEdgeInput {
}
export interface GraphNeighborsOptions {
    graphName: string;
    nodeId: string;
    direction: GraphDirection;
    edgeType?: string;
    limit: number;
}
export interface GraphNeighbor {
    nodeId: string;
    kind: string;
    edgeType: string;
}
export interface GraphDegreeOptions {
    graphName: string;
    nodeId: string;
    direction: GraphDirection;
    edgeType?: string;
}
export interface GraphWalkOptions {
    graphName: string;
    startNodeId: string;
    /** Defaults to "outgoing". */
    direction?: GraphDirection;
    edgeType?: string;
    maxDepth: number;
    limit: number;
}
export interface GraphWalkItem {
    nodeId: string;
    kind: string;
    depth: number;
    predecessorNodeId?: string;
    edgeType?: string;
}
/** Graph node and edge keys: a `BigInt64Array` or an array of `bigint`. */
export type GraphKeys = BigInt64Array | readonly bigint[];
export interface GraphKeyedNode {
    nodeKey: bigint;
    nodeId: string;
    kind: string;
    createdOrder: bigint;
}
export interface GraphKeyedEdge {
    edgeKey: bigint;
    sourceNodeKey: bigint;
    edgeType: string;
    targetNodeKey: bigint;
    createdOrder: bigint;
}
export interface GraphKeyedNeighbor {
    edgeKey: bigint;
    neighborNodeKey: bigint;
    nodeId: string;
    kind: string;
    edgeType: string;
}
export interface GraphKeyedDegreeOptions {
    graphName: string;
    nodeKeys: GraphKeys;
    direction: GraphDirection;
    edgeType?: string;
}
export interface GraphEdgePayloadReplacement {
    edgeKey: bigint;
    payload: Uint8Array;
}
/** Scan position: continue after the last returned row's order and key. */
export interface GraphScanCursor {
    createdOrder: bigint;
    key: bigint;
}
export interface GraphScanOptions {
    graphName: string;
    /** Omit to start at the first node. */
    nodeAfter?: GraphScanCursor;
    /** Omit to start at the first edge. */
    edgeAfter?: GraphScanCursor;
    nodeLimit: number;
    edgeLimit: number;
}
export interface GraphScanPage {
    nodes: GraphKeyedNode[];
    edges: GraphKeyedEdge[];
    hasMoreNodes: boolean;
    hasMoreEdges: boolean;
}
export interface GraphWalkDirectionOptions extends GraphWalkOptions {
    direction: GraphDirection;
}
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
export interface GraphWalkDirectionProfiled {
    items: GraphWalkItem[];
    profile: GraphWalkProfile;
}
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
export declare class ZovaError extends Error {
    readonly code: string;
    readonly status: number;
    constructor(code: string, status: number, message: string);
    /** @deprecated Use `status`. */
    get statusCode(): number;
}
/** @deprecated Use `ZovaError`; this is the same class. */
export declare const ZovaWasmError: typeof ZovaError;
/** @deprecated Use `ZovaError`. */
export type ZovaWasmError = ZovaError;
type Request = <T>(operation: string, prepare: () => object, transfer?: (args: object) => Transferable[]) => Promise<T>;
/**
 * A prepared statement owned by its database. Run one query or
 * iteration at a time; closing the database finalizes it.
 */
export declare class Statement {
    #private;
    readonly parameterCount: number;
    readonly columns: readonly string[];
    /** @internal Use Database.prepare(). */
    constructor(request: Request, info: {
        handle: number;
        parameterCount: number;
        columns: string[];
    }, token: symbol);
    get finalized(): boolean;
    /** Rebinds every parameter, runs to completion and resets the statement. */
    query(parameters?: readonly SqlValue[]): Promise<QueryResult>;
    /** Yields rows fetched from the worker `batchSize` at a time. */
    iterate(parameters?: readonly SqlValue[], batchSize?: number): AsyncGenerator<SqlValue[], void, undefined>;
    finalize(): Promise<void>;
    /** Runs to the next row. Column accessors then read that row without a worker round trip. */
    step(): Promise<Step>;
    /** Resets the cursor and keeps the bindings. */
    reset(): Promise<void>;
    clearBindings(): Promise<void>;
    /** 1-based index of a named parameter such as `:name`, or null. */
    parameterIndex(name: string): Promise<number | null>;
    bindNull(index: number): Promise<void>;
    bindInteger(index: number, value: bigint): Promise<void>;
    bindFloat(index: number, value: number): Promise<void>;
    bindText(index: number, value: string): Promise<void>;
    bindBlob(index: number, value: Uint8Array): Promise<void>;
    columnCount(): number;
    columnName(index: number): string;
    columnType(index: number): ColumnType;
    /** Integer and float columns convert as SQLite does; null reads as 0n. */
    columnInteger(index: number): bigint;
    columnFloat(index: number): number;
    columnText(index: number): string | null;
    columnBlob(index: number): Uint8Array | null;
}
export type ObjectStorageProfile = "deduplication" | "streaming";
export interface ObjectPutOptions {
    readonly profile: ObjectStorageProfile;
}
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
export declare class ObjectWriter extends WritableStream<Uint8Array> {
    /** The stored object's ID once the stream closes; rejects if it is aborted or fails. */
    readonly id: Promise<Uint8Array>;
    /** @internal Use Database.objectWriter(). */
    constructor(request: Request, handle: number, token: symbol);
}
/**
 * Seekable, verified reader for one stored object. Each chunk is checked
 * against its manifest SHA-256 before its bytes are returned. Calls run in
 * order; reads at or past the end return an empty array.
 */
export declare class ObjectSeekableReader {
    #private;
    /** Object size in bytes. */
    readonly size: bigint;
    /** @internal Use Database.objectSeekableReader(). */
    constructor(request: Request, handle: number, objectSize: bigint, token: symbol);
    get closed(): boolean;
    /** Offset of the next `read()`. */
    get position(): bigint;
    /** Reads up to `size` bytes at the current position and advances it. */
    read(size: number): Promise<Uint8Array>;
    /** Moves the read offset and returns the new absolute offset. */
    seek(offset: bigint | number, whence?: SeekWhence): Promise<bigint>;
    /** Reads up to `length` bytes at `offset` in one worker call, then continues from there. */
    readAt(offset: bigint, length: number): Promise<Uint8Array>;
    close(): Promise<void>;
}
export declare function objectIdToHex(id: Uint8Array): string;
export declare function objectIdFromHex(value: string): Uint8Array;
/** The ID a whole object with these bytes is stored under. */
export declare function objectId(data: Uint8Array): Promise<Uint8Array>;
/** The hash a chunk with these bytes is stored under. */
export declare function objectChunkId(data: Uint8Array): Promise<Uint8Array>;
/** The zova-wasm package version. */
export declare const packageVersion = "1.5.0";
/** The storage format this package creates. */
export declare const formatVersion = "15";
/** The bundled SQLite version. */
export declare const sqliteVersion = "3.53.4";
/** The C ABI version string of the bundled native code, as native `abiVersion`. */
export declare function abiVersion(): Promise<string>;
/** The C ABI version as numbers, as native `abiVersionParts`. */
export declare function abiVersionParts(): Promise<AbiVersionParts>;
export type Step = "row" | "done";
/** `step()` results by name, as native `zova-js`'s `Step` enum. */
export declare const Step: Readonly<{
    readonly Row: "row";
    readonly Done: "done";
}>;
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
export declare class Subscription {
    #private;
    /** @internal Use Database.listen(). */
    constructor(request: Request, handle: number, token: symbol);
    get closed(): boolean;
    /** The next queued notification, or null when none is waiting. */
    tryReceive(): Promise<Notification | null>;
    close(): Promise<void>;
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
export declare class FreshBuild {
    #private;
    constructor(request: Request, token: symbol);
    get closed(): boolean;
    /** Append rows to an empty ordinary table; each row has one value per column. */
    tableRows(tableName: string, columns: readonly string[], rows: readonly (readonly FreshValue[])[]): Promise<void>;
    /** Append rows to an empty FTS5 table; each row has one value per column. */
    ftsRows(tableName: string, columns: readonly string[], rows: readonly (readonly FreshValue[])[]): Promise<void>;
    /** Load one new graph. Edges name nodes by position and may carry payloads. */
    graph(graphName: string, nodes: readonly GraphFreshNodeInput[], edges: readonly GraphFreshEdgeInput[]): Promise<void>;
    /** Load vectors into an empty collection. */
    vectors(collectionName: string, vectors: readonly VectorInput[]): Promise<void>;
    /** Commit the session and close it. */
    finish(): Promise<FreshBuildResult>;
    /** Roll the session back and close it. */
    abort(): Promise<void>;
    /** Roll back an unfinished session. Closing a closed session does nothing. */
    close(): Promise<void>;
}
export declare class Database {
    #private;
    private constructor();
    /** `pageSize` 0 or omitted keeps SQLite's default. */
    static createMemory(options?: CreateOptions): Promise<Database>;
    /**
     * Opens a persistent database, creating it when the name is new.
     * `readOnly` requires an existing database; `pageSize` applies only when
     * the name is created.
     */
    static openPersistent(name: string, options?: OpenPersistentOptions): Promise<Database>;
    /**
     * Opens an existing persistent database for extension maintenance without
     * running installed extension hooks, so `extensionUpgrade` and
     * `extensionRebuild` can repair a database whose extension check fails.
     */
    static openPersistentForExtensionUpgrade(name: string, options?: OpenPersistentOptions): Promise<Database>;
    /**
     * Converts an ordinary SQLite database file, given as bytes or a stream, into
     * a new persistent Zova database and opens it, as native
     * `convertSqliteToZova`. An existing name is never replaced, and the SQLite
     * bytes are only staged while the conversion runs.
     */
    static convertSqliteToPersistent(name: string, data: Uint8Array | ReadableStream<Uint8Array>): Promise<Database>;
    /**
     * Reads the storage format of a persistent database without opening or
     * changing it. Takes the database's lock, so an open owner causes `ZOVA_BUSY`.
     */
    static probePersistent(name: string): Promise<FormatInfo>;
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
    static migratePersistent(name: string, options?: MigrateOptions): Promise<void>;
    /**
     * Copies the stored database `sourceName` to the new persistent name
     * `targetName` with the same guarantees as `backupTo`. The source must exist
     * and be a current-format database; it is opened, read and closed.
     */
    static restoreBackup(sourceName: string, targetName: string, options?: CopyOptions): Promise<void>;
    /**
     * Restores the stored database `sourceName` into a new memory database. The
     * source is owned only while it is read.
     */
    static restoreBackupToMemory(sourceName: string, options?: {
        readonly verify?: boolean;
    }): Promise<Database>;
    /**
     * Stores exported database bytes, or a stream of them, under a new
     * persistent name and opens it. An existing name is never replaced. The
     * stored file must pass normal Zova opening and the core's copy
     * verification, or it is removed again. A stream is written as it arrives,
     * so neither side holds the whole database; until it completes the name is
     * marked incomplete, and a stopped import is never listed or opened.
     */
    static importPersistent(name: string, data: Uint8Array | ReadableStream<Uint8Array>): Promise<Database>;
    /** Stored persistent databases of this origin, by name. */
    static listPersistent(): Promise<PersistentDatabaseInfo[]>;
    /**
     * Deletes a stored persistent database. Takes its lock first, so a database
     * open in another tab or worker rejects with `ZOVA_BUSY` and nothing is
     * removed. Resolves whether the name held storage.
     */
    static deletePersistent(name: string): Promise<boolean>;
    get closed(): boolean;
    /**
     * Runs `callback` inside one immediate transaction: committed when it
     * resolves, rolled back when it throws. Use only the `tx` handle inside the
     * callback; other calls on this database wait until the transaction ends,
     * so awaiting them from the callback never completes.
     */
    transaction<T>(callback: (tx: Database) => T | Promise<T>): Promise<T>;
    begin(): Promise<void>;
    beginImmediate(): Promise<void>;
    commit(): Promise<void>;
    rollback(): Promise<void>;
    /**
     * Opens a savepoint. With a callback, releases it when the callback
     * resolves, or rolls back to it and releases it when the callback throws.
     */
    savepoint(name: string): Promise<void>;
    savepoint<T>(name: string, callback: (database: Database) => T | Promise<T>): Promise<T>;
    releaseSavepoint(name: string): Promise<void>;
    rollbackToSavepoint(name: string): Promise<void>;
    changes(): Promise<bigint>;
    totalChanges(): Promise<bigint>;
    lastInsertRowid(): Promise<bigint>;
    /**
     * Sets SQLite's busy timeout. A browser database has one exclusive owner
     * and one connection, so there is normally nothing to wait for.
     */
    setBusyTimeout(milliseconds: number): Promise<void>;
    /** Queues a notification for this database's subscriptions on `channel`. */
    notify(channel: string, payload: string): Promise<void>;
    listen(channel: string): Promise<Subscription>;
    prepare(sql: string): Promise<Statement>;
    /**
     * Extension lifecycle for the extensions this module knows: the bundled
     * `trgm`, and plugins linked into a custom build. There is no run-time
     * loading; `.zovaext` bundles, bundle paths and trust stores do not apply.
     */
    installExtension(name: string): Promise<void>;
    dropExtension(name: string): Promise<void>;
    listExtensions(): Promise<ExtensionInfo[]>;
    extensionInfo(name: string): Promise<ExtensionInfo>;
    checkExtension(name: string): Promise<void>;
    checkExtensions(): Promise<void>;
    /** Releases free pages of incremental auto-vacuum files in bounded steps, as native. */
    reclaimSpace(options?: ReclaimOptions): Promise<ReclaimedMember[]>;
    /** Rebuilds the database file with SQLite `VACUUM`. */
    vacuum(): Promise<void>;
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
    backupTo(targetName: string, options?: CopyOptions): Promise<void>;
    /** As `backupTo`, through SQLite `VACUUM INTO`, which drops free pages. */
    compactTo(targetName: string, options?: CopyOptions): Promise<void>;
    /**
     * Streams the committed database in reads of up to `chunkSize` bytes (1 MiB
     * by default): the stored file, or a serialized copy of a memory database.
     * Other calls on this database wait until the stream ends or is cancelled.
     * Rejects while a transaction is open. Import the bytes with
     * `importPersistent()`, which verifies them.
     */
    exportStream(chunkSize?: number): Promise<ReadableStream<Uint8Array>>;
    /** The committed database as one `Uint8Array`, also for memory databases. Rejects while a transaction is open. */
    export(): Promise<Uint8Array>;
    exec(sql: string): Promise<void>;
    query(sql: string, parameters?: readonly SqlValue[]): Promise<QueryResult>;
    readonly kv: Readonly<{
        get: (namespace: Uint8Array, key: Uint8Array) => Promise<Uint8Array | null>;
        put: (namespace: Uint8Array, key: Uint8Array, value: Uint8Array) => Promise<void>;
        delete: (namespace: Uint8Array, key: Uint8Array) => Promise<boolean>;
        getMany: (namespace: Uint8Array, keys: readonly Uint8Array[]) => Promise<(Uint8Array | null)[]>;
        putMany: (namespace: Uint8Array, entries: readonly KvEntry[]) => Promise<void>;
        deleteMany: (namespace: Uint8Array, keys: readonly Uint8Array[]) => Promise<void>;
        count: (namespace: Uint8Array) => Promise<bigint>;
        clearNamespace: (namespace: Uint8Array) => Promise<void>;
        /** One page of a namespace in ascending key byte order. */
        scan: (namespace: Uint8Array, options: KvScanOptions) => Promise<KvScanPage>;
        /** Inserts one entry only when its key is absent. Resolves whether it was written. */
        putIfAbsent: (namespace: Uint8Array, key: Uint8Array, value: Uint8Array) => Promise<boolean>;
        /**
         * Replaces one value only when the current value equals `expected` byte
         * for byte. A missing key never matches. Resolves whether it was written.
         */
        compareAndPut: (namespace: Uint8Array, key: Uint8Array, expected: Uint8Array, value: Uint8Array) => Promise<boolean>;
        /**
         * Deletes one entry only when its current value equals `expected` byte for
         * byte. A missing key never matches. Resolves whether it was deleted.
         */
        compareAndDelete: (namespace: Uint8Array, key: Uint8Array, expected: Uint8Array) => Promise<boolean>;
    }>;
    /** Selects chunk compression for objects written through this database. */
    setObjectCompression(compression: ObjectCompression): Promise<void>;
    putObject(data: Uint8Array): Promise<Uint8Array>;
    getObject(id: Uint8Array): Promise<Uint8Array>;
    readObjectRange(id: Uint8Array, offset: bigint, length: number): Promise<Uint8Array>;
    hasObject(id: Uint8Array): Promise<boolean>;
    objectSize(id: Uint8Array): Promise<bigint>;
    deleteObject(id: Uint8Array): Promise<void>;
    /** @internal Used by checkedId() and objectChunkId(). */
    objectIdOf(operation: string, data: Uint8Array): Promise<Uint8Array>;
    putObjectWithOptions(data: Uint8Array, options: ObjectPutOptions): Promise<Uint8Array>;
    objectChunkCount(id: Uint8Array): Promise<bigint>;
    objectManifest(id: Uint8Array): Promise<ObjectManifest>;
    getObjectChunk(hash: Uint8Array): Promise<Uint8Array>;
    hasObjectChunk(hash: Uint8Array): Promise<boolean>;
    /** Stores one loose chunk after checking that `hash` is the SHA-256 of `data`. */
    putObjectChunk(hash: Uint8Array, data: Uint8Array): Promise<void>;
    putObjectChunkWithOptions(hash: Uint8Array, data: Uint8Array, options: ObjectPutOptions): Promise<void>;
    /** Resolves false when the chunk did not exist. */
    deleteObjectChunk(hash: Uint8Array): Promise<boolean>;
    /** Records an object from stored chunks; the manifest and `id` are verified. */
    assembleObjectFromChunks(id: Uint8Array, sizeBytes: bigint, chunks: readonly ObjectManifestChunkInput[]): Promise<void>;
    assembleObjectFromChunksWithOptions(id: Uint8Array, sizeBytes: bigint, chunks: readonly ObjectManifestChunkInput[], options: ObjectPutOptions): Promise<void>;
    /**
     * Streams bytes into a new object. Each written chunk is copied once and
     * moved to the worker, so memory stays bounded by the chunk size, not the
     * object size. Close the stream to store the object and resolve `writer.id`;
     * aborting it, or any failed write, cancels the object and stores nothing.
     */
    objectWriter(): Promise<ObjectWriter>;
    objectWriterWithOptions(options: ObjectPutOptions): Promise<ObjectWriter>;
    /**
     * Streams a stored object's verified bytes in reads of up to `chunkSize`
     * bytes (1 MiB by default), each moved from the worker without copying.
     * Cancel the stream to release the reader early.
     */
    objectReader(id: Uint8Array, chunkSize?: number): Promise<ReadableStream<Uint8Array>>;
    /** Verified random access to one object, for example to serve HTTP ranges. */
    objectSeekableReader(id: Uint8Array): Promise<ObjectSeekableReader>;
    createVectorCollection(name: string, options: VectorCollectionOptions): Promise<void>;
    hasVectorCollection(name: string): Promise<boolean>;
    vectorCollectionInfo(name: string): Promise<VectorCollectionInfo>;
    listVectorCollections(): Promise<VectorCollectionInfo[]>;
    deleteVectorCollection(name: string): Promise<void>;
    putVector(collectionName: string, vectorId: string, values: VectorValues): Promise<void>;
    /** One atomic batch. */
    putVectors(collectionName: string, vectors: readonly VectorInput[]): Promise<void>;
    getVector(collectionName: string, vectorId: string): Promise<Vector>;
    hasVector(collectionName: string, vectorId: string): Promise<boolean>;
    deleteVector(collectionName: string, vectorId: string): Promise<void>;
    deleteVectors(collectionName: string, vectorIds: readonly string[]): Promise<void>;
    /**
     * Exact nearest-neighbor search, closest first. Pass `VectorSearchOptions`
     * to filter as native `zova-js` does; a bare `limit` remains accepted.
     */
    searchVectors(collectionName: string, query: VectorValues, options: VectorSearchOptions | number): Promise<VectorSearchResult[]>;
    /** Search by a stored vector, which is excluded from its own results. */
    searchVectorsById(collectionName: string, vectorId: string, options: VectorSearchOptions | number): Promise<VectorSearchResult[]>;
    /** Scores each stored i8 vector against several query rows at once. */
    searchVectorsMultiI8(collectionName: string, options: VectorMultiI8SearchOptions): Promise<VectorSearchResult[]>;
    createGraph(name: string): Promise<void>;
    hasGraph(name: string): Promise<boolean>;
    graphInfo(name: string): Promise<GraphInfo>;
    listGraphs(): Promise<GraphInfo[]>;
    deleteGraph(name: string): Promise<void>;
    putGraphNode(input: GraphNodeInput): Promise<void>;
    /** One atomic batch. */
    putGraphNodes(inputs: readonly GraphNodeInput[]): Promise<void>;
    getGraphNode(graphName: string, nodeId: string): Promise<GraphNode>;
    hasGraphNode(graphName: string, nodeId: string): Promise<boolean>;
    /** Also removes every edge that touches the node. */
    deleteGraphNode(graphName: string, nodeId: string): Promise<void>;
    deleteGraphNodes(graphName: string, nodeIds: readonly string[]): Promise<void>;
    putGraphEdge(input: GraphEdgeInput): Promise<void>;
    /** One atomic batch. */
    putGraphEdges(inputs: readonly GraphEdgeInput[]): Promise<void>;
    getGraphEdge(graphName: string, fromNodeId: string, edgeType: string, toNodeId: string): Promise<GraphEdge>;
    hasGraphEdge(graphName: string, fromNodeId: string, edgeType: string, toNodeId: string): Promise<boolean>;
    deleteGraphEdge(input: GraphEdgeInput): Promise<void>;
    deleteGraphEdges(inputs: readonly GraphEdgeInput[]): Promise<void>;
    graphNeighbors(options: GraphNeighborsOptions): Promise<GraphNeighbor[]>;
    graphDegree(options: GraphDegreeOptions): Promise<bigint>;
    /** Bounded breadth-first walk; the start node is returned at depth 0. */
    graphWalk(options: GraphWalkOptions): Promise<GraphWalkItem[]>;
    /** Breadth-first walk along outgoing or incoming edges. */
    graphWalkDirection(options: GraphWalkDirectionOptions): Promise<GraphWalkItem[]>;
    graphWalkDirectionProfiled(options: GraphWalkDirectionOptions): Promise<GraphWalkDirectionProfiled>;
    /** One atomic batch; resolves each node's key in input order. */
    putGraphNodesKeyed(inputs: readonly GraphNodeInput[]): Promise<BigInt64Array>;
    /** One atomic batch; resolves each edge's key in input order. */
    putGraphEdgesKeyed(inputs: readonly GraphEdgeInput[]): Promise<BigInt64Array>;
    /** Nodes by key, in input order; `null` for a missing key. */
    getGraphNodesKeyed(graphName: string, nodeKeys: GraphKeys): Promise<(GraphKeyedNode | null)[]>;
    /** Edges by key, in input order; `null` for a missing key. */
    getGraphEdgesKeyed(graphName: string, edgeKeys: GraphKeys): Promise<(GraphKeyedEdge | null)[]>;
    graphNeighborsKeyed(options: GraphNeighborsOptions): Promise<GraphKeyedNeighbor[]>;
    /** Degree of each node key, in input order. */
    graphDegreesKeyed(options: GraphKeyedDegreeOptions): Promise<BigUint64Array>;
    /** Edge payloads by key, in input order; `null` for a missing edge. */
    getGraphEdgePayloads(graphName: string, edgeKeys: GraphKeys): Promise<(Uint8Array | null)[]>;
    /** One atomic batch. */
    replaceGraphEdgePayloads(graphName: string, replacements: readonly GraphEdgePayloadReplacement[]): Promise<void>;
    /** One page of nodes and edges in creation order. */
    graphScan(options: GraphScanOptions): Promise<GraphScanPage>;
    /**
     * Creates and loads a new graph in one transaction. Duplicate edges are
     * merged, so their inputs share one key.
     */
    buildFreshGraphKeyed(graphName: string, nodes: readonly GraphFreshNodeInput[], edges: readonly GraphFreshEdgeInput[]): Promise<GraphFreshKeys>;
    /** Like `buildFreshGraphKeyed` for input that is already unique and valid. */
    buildFreshGraphPreparedKeyed(graphName: string, nodes: readonly GraphFreshNodeInput[], edges: readonly GraphFreshEdgeInput[]): Promise<GraphFreshKeys>;
    /** `buildFreshGraphPreparedKeyed` with edge payloads; an omitted payload is empty. */
    buildFreshGraphPreparedKeyedWithPayloads(graphName: string, nodes: readonly GraphFreshNodeInput[], edges: readonly GraphFreshEdgeInput[]): Promise<GraphFreshKeys>;
    /** Starts a fresh-build session; see `FreshBuild`. */
    beginFreshBuild(): Promise<FreshBuild>;
    /**
     * Registers a scalar SQL function on this database. `arity` is the number
     * of arguments, or -1 for any number. The database worker imports
     * `fn.module` (resolved against the page URL) and calls its export
     * `fn.export` synchronously for each row. Arguments arrive as `SqlValue`s:
     * integers are `bigint`, floats `number`. A thrown exception or an
     * unsupported result fails the statement with that message. The function
     * runs in the worker, so it cannot use page state, this database, or await.
     */
    registerFunction(name: string, arity: number, fn: SqlFunctionModule, options?: SqlFunctionOptions): Promise<void>;
    /** Runs the named extension's upgrade hook. */
    extensionUpgrade(name: string): Promise<void>;
    /** Runs the named extension's rebuild hook. */
    extensionRebuild(name: string): Promise<void>;
    /** @internal Used by `abiVersion()`. */
    abiInfo(): Promise<{
        major: number;
        minor: number;
        patch: number;
        version: string;
    }>;
    close(): Promise<void>;
}
export {};
