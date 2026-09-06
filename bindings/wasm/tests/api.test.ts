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
      data: { id: message.id, ok: true },
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
