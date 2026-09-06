import { WorkerChannel } from "/runtime/channel.mjs";
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const rejects = async promise => {
  try { await promise; } catch { return; }
  throw new Error("Expected rejection");
};
let channel;
try {
  for (let cycle = 0; cycle < 10; cycle++) {
    channel = new WorkerChannel(new Worker("/runtime/worker.mjs", { type: "module" }));
    await channel.request("initialize");
    const input = new Uint8Array([0, 255, 3]);
    const resultPromise = channel.request("query", {
      sql: "SELECT ? AS x, ? AS x, ?, ?, ?, ?",
      parameters: [null, -(1n << 63n), (1n << 63n) - 1n, 1.25, "a\0β", input],
    });
    input[0] = 99;
    const result = await resultPromise;
    assert(result.columns[0] === "x" && result.columns[1] === "x", "duplicate column names");
    const row = result.rows[0];
    assert(row[0] === null && row[1] === -(1n << 63n) && row[2] === (1n << 63n) - 1n, "integer/null values");
    assert(row[3] === 1.25 && row[4] === "a\0β" && row[5][0] === 0 && row[5][1] === 255, "owned values");
    assert(input.length === 3, "input detached");
    await channel.request("exec", { sql: "CREATE TABLE t(v);" });
    const put = channel.request("exec", { sql: "INSERT INTO t VALUES(7);" });
    const read = channel.request("query", { sql: "SELECT v FROM t" });
    await put;
    assert((await read).rows[0][0] === 7n, "FIFO order");
    for (const args of [
      { sql: "bad sql" }, { sql: "SELECT ?", parameters: [] },
      { sql: "SELECT ?", parameters: [1n << 63n] }, { sql: "SELECT ?", parameters: [true] },
    ]) await rejects(channel.request("query", args));
    const key = { namespace: new Uint8Array([0]), key: new Uint8Array([255]) };
    assert(await channel.request("kv_get", key) === null, "missing key");
    await channel.request("kv_put", { ...key, value: new Uint8Array() });
    assert((await channel.request("kv_get", key)).length === 0, "empty value");
    await channel.request("kv_put", { ...key, value: new Uint8Array([7, 0]) });
    assert((await channel.request("kv_get", key))[0] === 7, "overwrite");
    assert(await channel.request("kv_delete", key) === true, "delete found");
    assert(await channel.request("kv_delete", key) === false, "delete missing");
    // Force linear-memory growth, then verify copies and cleanup still work.
    if (cycle === 0) {
      const large = new Uint8Array(20 * 1024 * 1024); large[large.length - 1] = 9;
      const copy = (await channel.request("query", { sql: "SELECT ?", parameters: [large] })).rows[0][0];
      assert(copy.length === large.length && copy[copy.length - 1] === 9, "memory growth copy");
    }
    await channel.close();
    await channel.close();
    await rejects(channel.request("query", { sql: "SELECT 1" }));
  }
  channel = new WorkerChannel(new Worker("/missing-worker.mjs", { type: "module" }));
  const failed = await Promise.allSettled([
    channel.request("initialize"), channel.request("query", { sql: "SELECT 1" }),
  ]);
  assert(failed.every(x => x.status === "rejected"), "worker startup failure settles pending requests");
  await fetch("/result", { method: "POST", body: JSON.stringify({ ok: true, cycles: 10, runtime: "SQL/KV/FIFO/errors/growth/startup-failure" }) });
} catch (error) {
  await fetch("/result", { method: "POST", body: JSON.stringify({ ok: false, error: String(error), stack: error.stack }) });
} finally { channel?.terminate(); }
