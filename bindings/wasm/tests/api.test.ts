import { afterEach, expect, test } from "bun:test";
import { Database, ZovaError, ZovaWasmError } from "../src/index.ts";

const originalWorker = globalThis.Worker;
class TestWorker extends EventTarget {
  static last: TestWorker;
  messages: Array<{ id: number; operation: string }> = [];
  transfers: Transferable[][] = [];
  constructor(public url: URL, public options: WorkerOptions) { super(); TestWorker.last = this; }
  postMessage(message: { id: number; operation: string }, transfer: Transferable[] = []) {
    // Transfer as a real worker would, detaching the sender's buffers.
    this.messages.push(structuredClone(message, { transfer }));
    this.transfers.push(transfer);
    const progress = message.operation === "migrate_stage" ? { phase: "copy", member: "main", done: 1, total: 1 } : undefined;
    const value = message.operation === "prepare" ? { handle: 7, parameterCount: 1, columns: ["v"] }
      : message.operation === "migrate_stage" ? { staged: true } : undefined;
    queueMicrotask(() => {
      if (progress) this.dispatchEvent(new MessageEvent("message", { data: { id: message.id, progress } }));
      this.dispatchEvent(new MessageEvent("message", { data: { id: message.id, ok: true, value } }));
    });
  }
  terminate() {}
}
afterEach(() => { globalThis.Worker = originalWorker; });
function installWorker() { globalThis.Worker = TestWorker as unknown as typeof Worker; }

test("persistent opening validates names before worker creation", async () => {
  installWorker();
  for (const name of ["", "../db", "a/b", "a.b", "a\\b", "\0", "a".repeat(65), null, 1]) {
    await expect(Database.openPersistent(name as string)).rejects.toBeInstanceOf(ZovaError);
  }
  const db = await Database.openPersistent("notes-1");
  expect(TestWorker.last.messages[0]).toMatchObject({operation:"initialize", args:{name:"notes-1"}});
  await db.close();
});

test("validates values before posting and returns typed errors", async () => {
  installWorker();
  const db = await Database.createMemory();
  const count = TestWorker.last.messages.length;
  for (const value of [true, undefined, {}, NaN, Infinity, 1n << 63n]) {
    await expect(db.query("SELECT ?", [value] as never)).rejects.toBeInstanceOf(ZovaError);
  }
  await expect(db.exec("SELECT\0 1")).rejects.toBeInstanceOf(ZovaError);
  await expect(db.kv.get("bad" as never, new Uint8Array())).rejects.toBeInstanceOf(ZovaError);
  expect(TestWorker.last.messages.length).toBe(count);
  await db.close();
});
test("close is immediately visible, idempotent, and rejects subsequent work", async () => {
  installWorker();
  const db = await Database.createMemory();
  expect(db.closed).toBe(false);
  const closing = db.close();
  expect(db.closed).toBe(true);
  expect(db.close()).toBe(closing);
  await expect(db.query("SELECT 1")).rejects.toBeInstanceOf(ZovaError);
  await closing;
  expect(TestWorker.last.messages.filter(x => x.operation === "close").length).toBe(1);
});
test("worker failure marks database closed and returns typed errors", async () => {
  installWorker();
  const db = await Database.createMemory();
  TestWorker.last.dispatchEvent(new Event("error"));
  expect(db.closed).toBe(true);
  await expect(db.exec("SELECT 1")).rejects.toBeInstanceOf(ZovaError);
});
test("copies shared-memory inputs before posting", async () => {
  installWorker();
  const db = await Database.createMemory();
  const input = new Uint8Array(new SharedArrayBuffer(1));
  input[0] = 42;
  const pending = db.query("SELECT ?", [input]);
  input[0] = 9;
  const sent = TestWorker.last.messages.at(-1) as unknown as { args: { parameters: Uint8Array[] } };
  expect(sent.args.parameters[0][0]).toBe(42);
  await pending;
  await db.close();
});
test("transactions bracket their work and hold back outside requests", async () => {
  installWorker();
  const db = await Database.createMemory();
  const start = TestWorker.last.messages.length;
  const running = db.transaction(async tx => {
    await tx.exec("SELECT 1");
    await expect(tx.transaction(async () => 1)).rejects.toBeInstanceOf(ZovaError);
    await expect(tx.close()).rejects.toBeInstanceOf(ZovaError);
    return 5;
  });
  const outside = db.exec("SELECT 2");
  expect(await running).toBe(5);
  await outside;
  await expect(db.transaction(async tx => { await tx.exec("SELECT 3"); throw new RangeError("stop"); })).rejects.toBeInstanceOf(RangeError);
  expect(TestWorker.last.messages.slice(start).map(x => x.operation))
    .toEqual(["begin", "exec", "commit", "exec", "begin", "exec", "rollback"]);
  await expect(db.transaction("no" as never)).rejects.toBeInstanceOf(ZovaError);
  await db.close();
});
test("statements address their handle and finalize once", async () => {
  installWorker();
  const db = await Database.createMemory();
  const statement = await db.prepare("SELECT ?");
  expect(statement.parameterCount).toBe(1);
  expect(statement.columns).toEqual(["v"]);
  await statement.query([1n]);
  expect(TestWorker.last.messages.at(-1)).toMatchObject({ operation: "statement_query", args: { handle: 7, parameters: [1n] } });
  const count = TestWorker.last.messages.length;
  await expect(statement.query([true] as never)).rejects.toBeInstanceOf(ZovaError);
  expect(TestWorker.last.messages.length).toBe(count);
  const finalizing = statement.finalize();
  expect(statement.finalized).toBe(true);
  expect(statement.finalize()).toBe(finalizing);
  await finalizing;
  await expect(statement.query([1n])).rejects.toBeInstanceOf(ZovaError);
  expect(TestWorker.last.messages.filter(x => x.operation === "statement_finalize").length).toBe(1);
  await db.close();
});
test("object, vector, graph and import arguments are validated before posting", async () => {
  installWorker();
  await expect(Database.importPersistent("../db", new Uint8Array(1))).rejects.toBeInstanceOf(ZovaError);
  await expect(Database.importPersistent("ok", "bytes" as never)).rejects.toBeInstanceOf(ZovaError);
  const db = await Database.createMemory();
  const count = TestWorker.last.messages.length;
  const rejected = [
    db.getObject(new Uint8Array(31)),
    db.readObjectRange(new Uint8Array(32), 1 as never, 1),
    db.createVectorCollection("c", { dimensions: 1.5, metric: "l2", elementType: "f32" }),
    db.putVector("c", "a", [1, 2] as never),
    db.putVector("c\0", "a", new Float32Array(2)),
    db.searchVectors("c", new Float32Array(2), -1),
    db.putGraphEdges("no" as never),
    db.graphWalk({ graphName: "g", startNodeId: "a", maxDepth: 1.5, limit: 1 }),
  ];
  for (const [index, promise] of rejected.entries()) {
    const error = await promise.then(() => null, (reason: unknown) => reason);
    expect([index, error instanceof ZovaError]).toEqual([index, true]);
  }
  expect(TestWorker.last.messages.length).toBe(count);
  await db.close();
});
test("probe and migrate validate before creating a worker", async () => {
  installWorker();
  const before = TestWorker.last;
  for (const name of ["", "../db", "a.b", null]) {
    await expect(Database.probePersistent(name as string)).rejects.toBeInstanceOf(ZovaError);
    await expect(Database.migratePersistent(name as string)).rejects.toBeInstanceOf(ZovaError);
  }
  await expect(Database.migratePersistent("notes", { progress: "no" as never })).rejects.toBeInstanceOf(ZovaError);
  await expect(Database.migratePersistent("notes", { signal: AbortSignal.abort() })).rejects.toMatchObject({ code: "ZOVA_INTERRUPTED" });
  expect(TestWorker.last).toBe(before);
});
test("migration stages, then publishes, in a maintenance worker", async () => {
  installWorker();
  const events: unknown[] = [];
  await Database.migratePersistent("notes", { progress: event => events.push(event) });
  expect(TestWorker.last.messages.map(x => x.operation)).toEqual(["initialize", "migrate_stage", "migrate_publish", "close"]);
  expect(TestWorker.last.messages[0]).toMatchObject({ args: { name: "notes", maintenance: true } });
  expect(events).toEqual([{ phase: "copy", member: "main", done: 1, total: 1 }]);
});
test("explicit transactions, savepoints, KV batches and notifications post their operations", async () => {
  installWorker();
  const db = await Database.createMemory();
  const start = TestWorker.last.messages.length;
  await db.begin();
  await db.savepoint("s", async sp => { await sp.kv.putMany(new Uint8Array([1]), [{ key: new Uint8Array([2]), value: new Uint8Array() }]); });
  await db.commit();
  await db.transaction(async tx => { await expect(tx.begin()).rejects.toMatchObject({ code: "ZOVA_MISUSE" }); });
  await expect(db.kv.putMany(new Uint8Array([1]), [{ key: "k" as never, value: new Uint8Array() }])).rejects.toBeInstanceOf(ZovaError);
  await expect(db.notify("c", 1 as never)).rejects.toBeInstanceOf(ZovaError);
  await expect(db.savepoint("s\0")).rejects.toBeInstanceOf(ZovaError);
  expect(TestWorker.last.messages.slice(start).map(x => x.operation))
    .toEqual(["begin_deferred", "savepoint", "kv_put_many", "release_savepoint", "commit", "begin", "commit"]);
  await db.close();
});
test("object ID hex helpers and object arguments validate locally", async () => {
  const { objectIdToHex, objectIdFromHex } = await import("../src/index.ts");
  const id = Uint8Array.from({ length: 32 }, (_, index) => index * 7);
  expect(objectIdFromHex(objectIdToHex(id))).toEqual(id);
  expect(() => objectIdFromHex("zz")).toThrow(ZovaError);
  expect(() => objectIdToHex(new Uint8Array(31))).toThrow(ZovaError);
  installWorker();
  const db = await Database.createMemory();
  const count = TestWorker.last.messages.length;
  for (const promise of [
    db.putObjectWithOptions(new Uint8Array(1), { profile: "zip" as never }),
    db.objectWriterWithOptions({ profile: "zip" as never }),
    db.assembleObjectFromChunks(new Uint8Array(32), 1n, [{ index: 0, hash: new Uint8Array(32), offset: 0n, sizeBytes: 1n } as never]),
    db.objectReader(new Uint8Array(32), 0),
    db.getObjectChunk(new Uint8Array(3)),
  ]) await expect(promise).rejects.toBeInstanceOf(ZovaError);
  expect(TestWorker.last.messages.length).toBe(count);
  await db.close();
});
test("filtered vector search selects its operation and validates options", async () => {
  installWorker();
  const db = await Database.createMemory();
  const start = TestWorker.last.messages.length;
  await db.searchVectors("c", new Float32Array(2), 3);
  await db.searchVectors("c", new Float32Array(2), { limit: 3, candidateIds: ["a"], maxDistance: 0.5 });
  await db.searchVectorsById("c", "a", { limit: 3 });
  expect(TestWorker.last.messages.slice(start).map(x => x.operation)).toEqual(["vector_search", "vector_search_filtered", "vector_search_by_id_filtered"]);
  expect(TestWorker.last.messages.at(-2)).toMatchObject({ args: { limit: 3, candidateIds: ["a"], maxDistance: 0.5 } });
  for (const options of [{ limit: -1 }, { limit: 1, candidateIds: "a" }, { limit: 1, candidateIds: [1] }, { limit: 1, maxDistance: "1" }, null]) {
    await expect(db.searchVectors("c", new Float32Array(2), options as never)).rejects.toBeInstanceOf(ZovaError);
  }
  await db.close();
});
test("backup and compact stage, then publish, and stop at phase boundaries", async () => {
  installWorker();
  const db = await Database.createMemory();
  const start = TestWorker.last.messages.length;
  await expect(db.backupTo("../x")).rejects.toBeInstanceOf(ZovaError);
  await expect(db.backupTo("x", { signal: AbortSignal.abort() })).rejects.toMatchObject({ code: "ZOVA_INTERRUPTED" });
  await expect(db.reclaimSpace({ maxPages: -1 })).rejects.toBeInstanceOf(ZovaError);
  expect(TestWorker.last.messages.length).toBe(start);
  await db.compactTo("copy", { verify: false });
  expect(TestWorker.last.messages.slice(start).map(x => x.operation)).toEqual(["copy_begin", "copy_stage", "copy_publish"]);
  expect(TestWorker.last.messages.at(-2)).toMatchObject({ args: { compact: true, verify: false } });
  let thrown: unknown;
  await db.backupTo("copy2", { progress: () => { throw new RangeError("stop"); } }).catch(error => { thrown = error; });
  expect(thrown).toBeUndefined(); // the test worker reports no progress, so nothing cancels
  await db.close();
});
test("import, list and delete validate before posting and stream imports chunk by chunk", async () => {
  installWorker();
  await expect(Database.deletePersistent("../x")).rejects.toBeInstanceOf(ZovaError);
  await expect(Database.importPersistent("ok", 5 as never)).rejects.toBeInstanceOf(ZovaError);
  const stream = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new Uint8Array([1, 2])); controller.enqueue(new Uint8Array([3])); controller.close(); } });
  const db = await Database.importPersistent("streamed", stream);
  expect(TestWorker.last.messages.map(x => x.operation)).toEqual(["initialize", "import_write", "import_write", "import_finish"]);
  expect(TestWorker.last.messages[0]).toMatchObject({ args: { name: "streamed", importing: true } });
  await db.close();
  const memory = await Database.createMemory();
  await memory.transaction(async tx => { await expect(tx.exportStream()).rejects.toMatchObject({ code: "ZOVA_MISUSE" }); });
  await expect(memory.exportStream(0)).rejects.toBeInstanceOf(ZovaError);
  await memory.close();
});
test("extension calls validate names before posting", async () => {
  installWorker();
  const db = await Database.createMemory();
  const start = TestWorker.last.messages.length;
  await expect(db.installExtension("a\0b")).rejects.toBeInstanceOf(ZovaError);
  await expect(db.extensionInfo(5 as never)).rejects.toBeInstanceOf(ZovaError);
  expect(TestWorker.last.messages.length).toBe(start);
  await db.installExtension("trgm");
  await db.checkExtensions();
  expect(TestWorker.last.messages.slice(start).map(x => x.operation)).toEqual(["extension_install", "extensions_check_all"]);
  await db.close();
});
test("open options and conversion validate locally and reach initialize", async () => {
  installWorker();
  await expect(Database.createMemory({ pageSize: -1 })).rejects.toBeInstanceOf(ZovaError);
  await expect(Database.openPersistent("opts", { busyTimeoutMs: 1.5 })).rejects.toBeInstanceOf(ZovaError);
  await expect(Database.convertSqliteToPersistent("conv", "bytes" as never)).rejects.toBeInstanceOf(ZovaError);
  let db = await Database.createMemory({ pageSize: 8192 });
  expect(TestWorker.last.messages[0]).toMatchObject({ operation: "initialize", args: { pageSize: 8192 } });
  await db.close();
  db = await Database.openPersistent("opts", { readOnly: true, busyTimeoutMs: 50 });
  expect(TestWorker.last.messages[0]).toMatchObject({ args: { name: "opts", readOnly: true, busyTimeoutMs: 50 } });
  await db.close();
  db = await Database.openPersistentForExtensionUpgrade("opts");
  expect(TestWorker.last.messages[0]).toMatchObject({ args: { name: "opts", upgrade: true } });
  await db.close();
  const data = Uint8Array.of(1, 2, 3);
  db = await Database.convertSqliteToPersistent("conv", data);
  expect(TestWorker.last.messages.map(x => x.operation)).toEqual(["initialize", "import_write", "import_finish"]);
  expect(TestWorker.last.messages[0]).toMatchObject({ args: { name: "conv", importing: true, convert: true } });
  await db.close();
});
test("parity calls validate before posting", async () => {
  installWorker();
  const db = await Database.createMemory();
  const count = TestWorker.last.messages.length;
  const bytes = new Uint8Array(1);
  for (const call of [
    () => db.kv.scan(bytes, { limit: -1 }),
    () => db.kv.scan(bytes, { prefix: "a" as never, limit: 1 }),
    () => db.kv.compareAndPut(bytes, bytes, "x" as never, bytes),
    () => db.searchVectorsMultiI8("c", { queryValues: new Float32Array(2) as never, queryCount: 1, dimensions: 2, limit: 1 }),
    () => db.getGraphNodesKeyed("g", [1n << 63n]),
    () => db.getGraphEdgePayloads("g", [1 as never]),
    () => db.graphWalkDirection({ graphName: "g", startNodeId: "a", maxDepth: 1, limit: 1 } as never),
    () => db.graphScan({ graphName: "g", nodeLimit: 1, edgeLimit: 1, nodeAfter: { createdOrder: 1, key: 1n } as never }),
    () => db.buildFreshGraphKeyed("g", [], [{ fromNodeOrdinal: 0, edgeType: "e", toNodeOrdinal: 0, payload: bytes }]),
    () => db.registerFunction("f", 0, "module" as never),
    () => db.registerFunction("f", 0, { module: "http://[", export: "f" }),
  ]) await expect(call()).rejects.toBeInstanceOf(ZovaError);
  expect(TestWorker.last.messages.length).toBe(count);
  await db.registerFunction("f", 1, { module: "https://example.test/fn.mjs", export: "f" }, { deterministic: true });
  expect(TestWorker.last.messages.at(-1)).toMatchObject({ operation: "register_function",
    args: { name: "f", arity: 1, module: "https://example.test/fn.mjs", export: "f", options: { deterministic: true, directOnly: false } } });
  await db.graphWalkDirectionProfiled({ graphName: "g", startNodeId: "a", direction: "incoming", maxDepth: 1, limit: 1 });
  expect(TestWorker.last.messages.at(-1)).toMatchObject({ operation: "graph_walk_profiled", args: { direction: "incoming" } });
  await db.close();
});
test("fresh builds roll back on invalid input and close once finished", async () => {
  installWorker();
  const db = await Database.createMemory();
  let build = await db.beginFreshBuild();
  await build.tableRows("t", ["a"], [[1n]]);
  await expect(build.tableRows("t", "a" as never, [])).rejects.toBeInstanceOf(ZovaError);
  expect(build.closed).toBe(true);
  await expect(build.finish()).rejects.toBeInstanceOf(ZovaError);
  build = await db.beginFreshBuild();
  await build.finish();
  expect(build.closed).toBe(true);
  await build.close();
  expect(TestWorker.last.messages.slice(1).map(x => x.operation)).toEqual([
    "fresh_build_begin", "fresh_build_rows", "fresh_build_abort", "fresh_build_begin", "fresh_build_finish",
  ]);
  await db.close();
});
test("batch calls transfer their own copies of large inputs", async () => {
  installWorker();
  const db = await Database.createMemory();
  const worker = TestWorker.last;
  const keys = BigInt64Array.of(1n, 2n);
  const payload = Uint8Array.of(1, 2);
  const queryValues = Int8Array.of(1, 2);
  const values = Float32Array.of(1);
  const node = { nodeId: "a", kind: "k", targetType: "none" as const };
  const sent = async (call: () => Promise<unknown>) => {
    const before = worker.messages.length;
    await call();
    return worker.messages.slice(before).map((message, index) => [message, worker.transfers[before + index].length] as const);
  };
  const [[nodes, nodeBuffers]] = await sent(() => db.getGraphNodesKeyed("g", keys));
  expect(nodes).toMatchObject({ operation: "graph_nodes_get_keyed", args: { keys: BigInt64Array.of(1n, 2n) } });
  expect(nodeBuffers).toBe(1);
  expect((await sent(() => db.getGraphEdgesKeyed("g", [1n])))[0][1]).toBe(1);
  expect((await sent(() => db.getGraphEdgePayloads("g", keys)))[0][1]).toBe(1);
  expect((await sent(() => db.graphDegreesKeyed({ graphName: "g", nodeKeys: keys, direction: "outgoing" })))[0][1]).toBe(1);
  expect((await sent(() => db.replaceGraphEdgePayloads("g", [{ edgeKey: 1n, payload }, { edgeKey: 2n, payload }])))[0][1]).toBe(2);
  expect((await sent(() => db.buildFreshGraphPreparedKeyedWithPayloads("g", [node, node],
    [{ fromNodeOrdinal: 0, edgeType: "e", toNodeOrdinal: 1, payload }])))[0][1]).toBe(1);
  expect((await sent(() => db.searchVectorsMultiI8("c", { queryValues, queryCount: 1, dimensions: 2, limit: 1 })))[0][1]).toBe(1);
  const build = await db.beginFreshBuild();
  expect((await sent(() => build.tableRows("t", ["b"], [[payload], [null]])))[0][1]).toBe(1);
  expect((await sent(() => build.graph("g", [node], [{ fromNodeOrdinal: 0, edgeType: "e", toNodeOrdinal: 0, payload }])))[0][1]).toBe(1);
  expect((await sent(() => build.vectors("v", [{ id: "a", values }, { id: "b", values }])))[0][1]).toBe(2);
  // The caller's arrays stay usable; only the package's copies moved.
  expect([keys.length, payload.length, queryValues.length, values.length]).toEqual([2, 2, 2, 1]);
  // Calls that send no batch transfer nothing.
  expect((await sent(() => db.graphScan({ graphName: "g", nodeLimit: 1, edgeLimit: 1 })))[0][1]).toBe(0);
  await db.close();
});
test("errors carry native zova-js fields, with deprecated aliases", async () => {
  installWorker();
  const db = await Database.createMemory();
  const error = await db.exec("SELECT\0 1").catch(error => error);
  expect(error).toBeInstanceOf(ZovaError);
  expect(error).toBeInstanceOf(ZovaWasmError);
  expect(ZovaWasmError).toBe(ZovaError);
  expect([error.name, error.code, error.status, error.statusCode]).toEqual(["ZovaError", "ZOVA_INVALID_ARGUMENT", 1, 1]);
  const own = new ZovaError("ZOVA_BUSY", 10, "busy");
  expect([own.code, own.status, own.message]).toEqual(["ZOVA_BUSY", 10, "busy"]);
  await db.close();
});
