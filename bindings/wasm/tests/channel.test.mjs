import { test, expect } from "bun:test";
import { WorkerChannel } from "../src/channel.mjs";

class WorkerBoundary extends EventTarget {
  sent = [];
  terminated = false;
  postMessage(message) { this.sent.push(structuredClone(message)); }
  terminate() { this.terminated = true; }
  reply(data) { this.dispatchEvent(new MessageEvent("message", { data })); }
}
test("worker failure rejects every pending request and closes channel", async () => {
  const worker = new WorkerBoundary();
  const channel = new WorkerChannel(worker);
  const first = channel.request("initialize");
  const second = channel.request("query", { sql: "SELECT 1", parameters: [] });
  const rejected = Promise.allSettled([first, second]);
  worker.dispatchEvent(new Event("error"));
  expect((await rejected).map(x => x.status)).toEqual(["rejected", "rejected"]);
  expect(worker.terminated).toBe(true);
  await expect(channel.request("exec", { sql: "SELECT 1" })).rejects.toThrow();
});
test("close follows queued work, is idempotent and forbids later requests", async () => {
  const worker = new WorkerBoundary();
  const channel = new WorkerChannel(worker);
  const value = channel.request("query", { sql: "SELECT 1" });
  const closed = channel.close();
  expect(channel.close()).toBe(closed);
  await expect(channel.request("query", {})).rejects.toThrow();
  expect(worker.sent.map(x => x.id)).toEqual([1, 2]);
  worker.reply({ id: 1, ok: true, value: 42 });
  worker.reply({ id: 2, ok: true });
  expect(await value).toBe(42);
  await closed;
  expect(worker.terminated).toBe(true);
});
test("initialization failure rejects queued requests", async () => {
  const worker = new WorkerBoundary();
  const channel = new WorkerChannel(worker);
  const initialized = channel.request("initialize");
  const queued = channel.request("exec", { sql: "SELECT 1" });
  const results = Promise.allSettled([initialized, queued]);
  worker.reply({ id: 1, ok: false, fatal: true, error: { message: "module failed" } });
  expect((await results).every(x => x.status === "rejected")).toBe(true);
});
test("explicit termination rejects pending work", async () => {
  const worker = new WorkerBoundary();
  const channel = new WorkerChannel(worker);
  const pending = channel.request("initialize");
  const result = Promise.allSettled([pending]);
  channel.terminate();
  expect((await result)[0].status).toBe("rejected");
  expect(worker.terminated).toBe(true);
});
