import { Database, ZovaWasmError } from "/package/dist/index.js";
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const rejects = async promise => {
  try { await promise; } catch (error) {
    assert(error instanceof ZovaWasmError, "Expected ZovaWasmError");
    assert(typeof error.status === "string" && typeof error.statusCode === "number", "Error status fields");
    return;
  }
  throw new Error("Expected rejection");
};
let db;
try {
  const started = performance.now();
  db = await Database.createMemory();
  const initialized = performance.now();
  const first = await db.query("SELECT 42 AS value");
  const queried = performance.now();
  assert(first.rows[0][0] === 42n, "integer result");
  assert(!db.closed, "open state");
  const input = new Uint8Array([0, 255]);
  const result = db.query("SELECT ? AS x, ? AS x, ?, ?, ?, ?", [null, -(1n << 63n), (1n << 63n) - 1n, 1.5, "a\0β", input]);
  input[0] = 9;
  const { columns, rows: [row] } = await result;
  assert(columns[0] === "x" && columns[1] === "x", "duplicate names");
  assert(row[0] === null && row[1] === -(1n << 63n) && row[2] === (1n << 63n) - 1n, "int64 extremes/null");
  assert(row[3] === 1.5 && row[4] === "a\0β" && row[5][0] === 0 && row[5][1] === 255, "value copies");
  assert(input.length === 2, "input remains attached");
  await db.exec("CREATE TABLE tasks(id INTEGER, title TEXT)");
  const insert = db.query("INSERT INTO tasks VALUES (?, ?)", [1n, "Try browser Zova"]);
  const read = db.query("SELECT id, title FROM tasks");
  await insert;
  assert((await read).rows[0][1] === "Try browser Zova", "concurrent FIFO");
  for (const args of [["bad sql"], ["SELECT ?", [true]], ["SELECT ?", [NaN]], ["SELECT ?", [1n << 63n]], ["SELECT ?", []]]) {
    await rejects(db.query(...args));
  }
  const ns = new Uint8Array([0]); const key = new Uint8Array([255]);
  assert(await db.kv.get(ns, key) === null, "missing KV");
  await db.kv.put(ns, key, new Uint8Array());
  assert((await db.kv.get(ns, key)).length === 0, "empty KV");
  const data = new Uint8Array([42]);
  const put = db.kv.put(ns, key, data); data[0] = 7;
  await put;
  assert((await db.kv.get(ns, key))[0] === 42, "copied KV");
  assert(await db.kv.delete(ns, key) === true, "delete existing");
  assert(await db.kv.delete(ns, key) === false, "delete absent");
  const close = db.close();
  assert(db.closed && db.close() === close, "idempotent immediate close");
  await rejects(db.exec("SELECT 1"));
  await close;
  db = await Database.createMemory();
  await rejects(db.query("SELECT * FROM tasks"));
  await db.close();
  for (let cycle = 0; cycle < 8; cycle++) {
    db = await Database.createMemory();
    assert((await db.query("SELECT 1")).rows[0][0] === 1n, "repeated lifecycle");
    await db.close();
  }
  const persistentName = "test-" + crypto.randomUUID();
  db = await Database.openPersistent(persistentName);
  await db.exec("CREATE TABLE saved(value); INSERT INTO saved VALUES(42)");
  await db.kv.put(new Uint8Array([1]), new Uint8Array([2]), new Uint8Array([3]));
  await db.close();
  db = await Database.openPersistent(persistentName);
  assert((await db.query("SELECT value FROM saved")).rows[0][0] === 42n, "persistent SQL reopen");
  assert((await db.kv.get(new Uint8Array([1]), new Uint8Array([2])))[0] === 3, "persistent KV reopen");
  await rejects(db.query("INVALID SQL"));
  await db.close();
  await fetch("/result", { method: "POST", body: JSON.stringify({ ok: true, packedPackage: true,
    initializationMs: initialized - started, firstQueryMs: queried - initialized }) });
} catch (error) {
  await fetch("/result", { method: "POST", body: JSON.stringify({ ok: false, error: String(error), stack: error.stack }) });
} finally { await db?.close(); }
