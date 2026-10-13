import { afterEach, expect, test } from "bun:test";
import { Database, ZovaWasmError } from "../src/index.ts";

const originalWorker = globalThis.Worker;
class TestWorker extends EventTarget {
  static last: TestWorker;
  messages: Array<{ id: number; operation: string }> = [];
  constructor(public url: URL, public options: WorkerOptions) { super(); TestWorker.last = this; }
  postMessage(message: { id: number; operation: string }) {
    this.messages.push(structuredClone(message));
    queueMicrotask(() => this.dispatchEvent(new MessageEvent("message", {
      data: { id: message.id, ok: true, value: message.operation === "prepare" ? { handle: 7, parameterCount: 1, columns: ["v"] } : undefined },
    })));
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
