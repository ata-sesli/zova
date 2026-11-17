import { afterEach, expect, test } from "bun:test";
import { Database, ZovaWasmError } from "../src/index.ts";

const originalWorker = globalThis.Worker;
class TestWorker extends EventTarget {
  static last: TestWorker;
  messages: Array<{ id: number; operation: string }> = [];
  constructor(public url: URL, public options: WorkerOptions) { super(); TestWorker.last = this; }
  postMessage(message: { id: number; operation: string }) {
    this.messages.push(structuredClone(message));
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
    await expect(Database.openPersistent(name as string)).rejects.toBeInstanceOf(ZovaWasmError);
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
    await expect(db.query("SELECT ?", [value] as never)).rejects.toBeInstanceOf(ZovaWasmError);
  }
  await expect(db.exec("SELECT\0 1")).rejects.toBeInstanceOf(ZovaWasmError);
  await expect(db.kv.get("bad" as never, new Uint8Array())).rejects.toBeInstanceOf(ZovaWasmError);
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
  await expect(db.query("SELECT 1")).rejects.toBeInstanceOf(ZovaWasmError);
  await closing;
  expect(TestWorker.last.messages.filter(x => x.operation === "close").length).toBe(1);
});
test("worker failure marks database closed and returns typed errors", async () => {
  installWorker();
  const db = await Database.createMemory();
  TestWorker.last.dispatchEvent(new Event("error"));
  expect(db.closed).toBe(true);
  await expect(db.exec("SELECT 1")).rejects.toBeInstanceOf(ZovaWasmError);
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
    await expect(tx.transaction(async () => 1)).rejects.toBeInstanceOf(ZovaWasmError);
    await expect(tx.close()).rejects.toBeInstanceOf(ZovaWasmError);
    return 5;
  });
  const outside = db.exec("SELECT 2");
  expect(await running).toBe(5);
  await outside;
  await expect(db.transaction(async tx => { await tx.exec("SELECT 3"); throw new RangeError("stop"); })).rejects.toBeInstanceOf(RangeError);
  expect(TestWorker.last.messages.slice(start).map(x => x.operation))
    .toEqual(["begin", "exec", "commit", "exec", "begin", "exec", "rollback"]);
  await expect(db.transaction("no" as never)).rejects.toBeInstanceOf(ZovaWasmError);
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
  await expect(statement.query([true] as never)).rejects.toBeInstanceOf(ZovaWasmError);
  expect(TestWorker.last.messages.length).toBe(count);
  const finalizing = statement.finalize();
  expect(statement.finalized).toBe(true);
  expect(statement.finalize()).toBe(finalizing);
  await finalizing;
  await expect(statement.query([1n])).rejects.toBeInstanceOf(ZovaWasmError);
  expect(TestWorker.last.messages.filter(x => x.operation === "statement_finalize").length).toBe(1);
  await db.close();
});
test("object, vector, graph and import arguments are validated before posting", async () => {
  installWorker();
  await expect(Database.importPersistent("../db", new Uint8Array(1))).rejects.toBeInstanceOf(ZovaWasmError);
  await expect(Database.importPersistent("ok", "bytes" as never)).rejects.toBeInstanceOf(ZovaWasmError);
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
    expect([index, error instanceof ZovaWasmError]).toEqual([index, true]);
  }
  expect(TestWorker.last.messages.length).toBe(count);
  await db.close();
});
test("probe and migrate validate before creating a worker", async () => {
  installWorker();
  const before = TestWorker.last;
  for (const name of ["", "../db", "a.b", null]) {
    await expect(Database.probePersistent(name as string)).rejects.toBeInstanceOf(ZovaWasmError);
    await expect(Database.migratePersistent(name as string)).rejects.toBeInstanceOf(ZovaWasmError);
  }
  await expect(Database.migratePersistent("notes", { progress: "no" as never })).rejects.toBeInstanceOf(ZovaWasmError);
  await expect(Database.migratePersistent("notes", { signal: AbortSignal.abort() })).rejects.toMatchObject({ status: "ZOVA_INTERRUPTED" });
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
  await db.transaction(async tx => { await expect(tx.begin()).rejects.toMatchObject({ status: "ZOVA_MISUSE" }); });
  await expect(db.kv.putMany(new Uint8Array([1]), [{ key: "k" as never, value: new Uint8Array() }])).rejects.toBeInstanceOf(ZovaWasmError);
  await expect(db.notify("c", 1 as never)).rejects.toBeInstanceOf(ZovaWasmError);
  await expect(db.savepoint("s\0")).rejects.toBeInstanceOf(ZovaWasmError);
  expect(TestWorker.last.messages.slice(start).map(x => x.operation))
    .toEqual(["begin_deferred", "savepoint", "kv_put_many", "release_savepoint", "commit", "begin", "commit"]);
  await db.close();
});
test("object ID hex helpers and object arguments validate locally", async () => {
  const { objectIdToHex, objectIdFromHex } = await import("../src/index.ts");
  const id = Uint8Array.from({ length: 32 }, (_, index) => index * 7);
  expect(objectIdFromHex(objectIdToHex(id))).toEqual(id);
  expect(() => objectIdFromHex("zz")).toThrow(ZovaWasmError);
  expect(() => objectIdToHex(new Uint8Array(31))).toThrow(ZovaWasmError);
  installWorker();
  const db = await Database.createMemory();
  const count = TestWorker.last.messages.length;
  for (const promise of [
    db.putObjectWithOptions(new Uint8Array(1), { profile: "zip" as never }),
    db.objectWriterWithOptions({ profile: "zip" as never }),
    db.assembleObjectFromChunks(new Uint8Array(32), 1n, [{ index: 0, hash: new Uint8Array(32), offset: 0n, sizeBytes: 1n } as never]),
    db.objectReader(new Uint8Array(32), 0),
    db.getObjectChunk(new Uint8Array(3)),
  ]) await expect(promise).rejects.toBeInstanceOf(ZovaWasmError);
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
    await expect(db.searchVectors("c", new Float32Array(2), options as never)).rejects.toBeInstanceOf(ZovaWasmError);
  }
  await db.close();
});
test("backup and compact stage, then publish, and stop at phase boundaries", async () => {
  installWorker();
  const db = await Database.createMemory();
  const start = TestWorker.last.messages.length;
  await expect(db.backupTo("../x")).rejects.toBeInstanceOf(ZovaWasmError);
  await expect(db.backupTo("x", { signal: AbortSignal.abort() })).rejects.toMatchObject({ status: "ZOVA_INTERRUPTED" });
  await expect(db.reclaimSpace({ maxPages: -1 })).rejects.toBeInstanceOf(ZovaWasmError);
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
  await expect(Database.deletePersistent("../x")).rejects.toBeInstanceOf(ZovaWasmError);
  await expect(Database.importPersistent("ok", 5 as never)).rejects.toBeInstanceOf(ZovaWasmError);
  const stream = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new Uint8Array([1, 2])); controller.enqueue(new Uint8Array([3])); controller.close(); } });
  const db = await Database.importPersistent("streamed", stream);
  expect(TestWorker.last.messages.map(x => x.operation)).toEqual(["initialize", "import_write", "import_write", "import_finish"]);
  expect(TestWorker.last.messages[0]).toMatchObject({ args: { name: "streamed", importing: true } });
  await db.close();
  const memory = await Database.createMemory();
  await memory.transaction(async tx => { await expect(tx.exportStream()).rejects.toMatchObject({ status: "ZOVA_MISUSE" }); });
  await expect(memory.exportStream(0)).rejects.toBeInstanceOf(ZovaWasmError);
  await memory.close();
});
test("extension calls validate names before posting", async () => {
  installWorker();
  const db = await Database.createMemory();
  const start = TestWorker.last.messages.length;
  await expect(db.installExtension("a\0b")).rejects.toBeInstanceOf(ZovaWasmError);
  await expect(db.extensionInfo(5 as never)).rejects.toBeInstanceOf(ZovaWasmError);
  expect(TestWorker.last.messages.length).toBe(start);
  await db.installExtension("trgm");
  await db.checkExtensions();
  expect(TestWorker.last.messages.slice(start).map(x => x.operation)).toEqual(["extension_install", "extensions_check_all"]);
  await db.close();
});
