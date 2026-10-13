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
  const same = (a, b) => a.length === b.length && a.every((value, index) => value === b[index]);
  const status = async (promise, expected) => {
    try { await promise; } catch (error) {
      assert(error instanceof ZovaWasmError && error.status === expected, `Expected ${expected}, got ${error.status ?? error}`);
      return;
    }
    throw new Error("Expected " + expected);
  };

  // Transactions: SQL and KV commit or roll back together, outside calls wait.
  db = await Database.createMemory();
  await db.exec("CREATE TABLE t(v INTEGER)");
  const one = new Uint8Array([1]); const two = new Uint8Array([2]);
  assert(await db.transaction(async tx => {
    await tx.query("INSERT INTO t VALUES (?)", [1n]);
    await tx.kv.put(one, one, one);
    return "done";
  }) === "done", "transaction result");
  const order = [];
  const running = db.transaction(async tx => {
    await tx.exec("INSERT INTO t VALUES (2)");
    await new Promise(resolve => setTimeout(resolve, 20));
    order.push("transaction");
  });
  const outside = db.query("SELECT count(*) FROM t").then(result => { order.push("outside"); return result; });
  const queued = db.transaction(async tx => { order.push("second"); await tx.exec("INSERT INTO t VALUES (3)"); });
  await running; await queued;
  assert((await outside).rows[0][0] === 2n && order.join() === "transaction,outside,second", "transaction isolation and order");
  let thrown;
  try {
    await db.transaction(async tx => {
      await tx.exec("INSERT INTO t VALUES (99)");
      await tx.kv.put(one, two, two);
      throw new RangeError("stop");
    });
  } catch (error) { thrown = error; }
  assert(thrown instanceof RangeError, "callback error is preserved");
  assert((await db.query("SELECT count(*) FROM t")).rows[0][0] === 3n && await db.kv.get(one, two) === null, "rollback covers SQL and KV");
  assert((await db.kv.get(one, one))[0] === 1, "committed KV");
  await status(db.transaction(tx => tx.transaction(() => 1)), "ZOVA_MISUSE");
  await status(db.transaction(async tx => { await tx.exec("INSERT INTO t VALUES (98)"); await tx.exec("INVALID"); }), "ZOVA_SQLITE_ERROR");
  assert((await db.query("SELECT count(*) FROM t")).rows[0][0] === 3n, "failed transactions leave no rows");
  let ended;
  await db.transaction(async tx => { ended = tx; });
  await status(ended.exec("SELECT 1"), "ZOVA_MISUSE");
  await status(ended.close(), "ZOVA_MISUSE");

  // Prepared statements: reuse, batched iteration, recovery after errors.
  const insertRow = await db.prepare("INSERT INTO t VALUES (?)");
  assert(insertRow.parameterCount === 1 && insertRow.columns.length === 0, "statement metadata");
  for (const value of [10n, 11n, 12n]) await insertRow.query([value]);
  await rejects(insertRow.query([]));
  await rejects(insertRow.query([true]));
  await insertRow.query([13n]);
  const select = await db.prepare("SELECT v FROM t WHERE v >= ? ORDER BY v");
  assert(select.columns[0] === "v" && (await select.query([10n])).rows.length === 4, "statement query");
  const seen = [];
  for await (const row of select.iterate([10n], 3)) seen.push(row[0]);
  assert(same(seen, [10n, 11n, 12n, 13n]), "batched iteration");
  for await (const row of select.iterate([10n], 1)) { assert(row[0] === 10n, "first row"); break; }
  assert((await select.query([13n])).rows.length === 1, "abandoned iteration resets");
  await rejects((async () => { for await (const row of select.iterate([10n], 0)) void row; })());
  const kept = await db.transaction(tx => tx.prepare("SELECT count(*) FROM t"));
  assert((await kept.query()).rows[0][0] === 7n, "statement outlives its transaction");
  const firstFinalize = insertRow.finalize();
  assert(insertRow.finalized && insertRow.finalize() === firstFinalize, "idempotent finalize");
  await firstFinalize;
  await status(insertRow.query([1n]), "ZOVA_MISUSE");
  assert((await select.query([13n])).rows.length === 1, "other statements survive a finalize");

  // Objects are addressed by the SHA-256 of their bytes.
  const payload = new Uint8Array(70000);
  for (let index = 0; index < payload.length; index++) payload[index] = (index * 31 + (index >> 8)) & 255;
  const id = await db.putObject(payload);
  assert(same(id, new Uint8Array(await crypto.subtle.digest("SHA-256", payload))), "object identity");
  assert(same(await db.getObject(id), payload), "object bytes");
  assert(same(await db.readObjectRange(id, 69990n, 100), payload.subarray(69990)), "object range");
  assert(await db.hasObject(id) && await db.objectSize(id) === 70000n, "object metadata");
  const emptyId = await db.putObject(new Uint8Array());
  assert((await db.getObject(emptyId)).length === 0, "empty object");
  await db.deleteObject(id);
  assert(!await db.hasObject(id), "object deleted");
  await status(db.getObject(id), "ZOVA_OBJECT_NOT_FOUND");
  await status(db.getObject(new Uint8Array(3)), "ZOVA_INVALID_ARGUMENT");

  // Vectors: every element type round-trips, exact search is ordered.
  await db.createVectorCollection("docs", { dimensions: 3, metric: "l2", elementType: "f32" });
  await status(db.createVectorCollection("docs", { dimensions: 3, metric: "l2", elementType: "f32" }), "ZOVA_VECTOR_COLLECTION_EXISTS");
  await status(db.createVectorCollection("bad", { dimensions: 3, metric: "manhattan", elementType: "f32" }), "ZOVA_INVALID_ARGUMENT");
  await db.putVector("docs", "a", new Float32Array([1, 0, 0]));
  await db.putVectors("docs", [{ id: "b", values: new Float32Array([0.5, 0.5, 0]) }, { id: "c", values: new Float32Array([0, 0, 1]) }]);
  const info = await db.vectorCollectionInfo("docs");
  assert(info.name === "docs" && info.dimensions === 3 && info.metric === "l2" && info.elementType === "f32" && info.vectorCount === 3n, "collection info");
  assert((await db.listVectorCollections()).length === 1 && await db.hasVectorCollection("docs"), "collection list");
  const stored = await db.getVector("docs", "b");
  assert(stored.id === "b" && stored.values instanceof Float32Array && same(stored.values, [0.5, 0.5, 0]), "vector values");
  const nearest = await db.searchVectors("docs", new Float32Array([1, 0, 0]), 2);
  assert(nearest.length === 2 && nearest[0].id === "a" && nearest[0].distance === 0 && nearest[1].id === "b", "exact search order");
  const byId = await db.searchVectorsById("docs", "c", 3);
  assert(byId.length === 2 && byId.every(item => item.id !== "c"), "search by stored vector excludes its source");
  await status(db.putVector("docs", "d", new Float32Array([1, 2])), "ZOVA_VECTOR_DIMENSION_MISMATCH");
  await status(db.getVector("docs", "missing"), "ZOVA_VECTOR_NOT_FOUND");
  await status(db.transaction(async tx => { await tx.putVector("docs", "rolled", new Float32Array([9, 9, 9])); await tx.exec("INVALID"); }), "ZOVA_SQLITE_ERROR");
  assert(!await db.hasVector("docs", "rolled"), "vector write rolled back");
  await db.deleteVector("docs", "a");
  await db.deleteVectors("docs", ["b", "missing"]);
  assert(!await db.hasVector("docs", "a") && !await db.hasVector("docs", "b") && await db.hasVector("docs", "c"), "vector deletes");
  await db.createVectorCollection("bytes", { dimensions: 2, metric: "cosine", elementType: "i8" });
  await db.putVector("bytes", "x", new Int8Array([-128, 127]));
  assert(same((await db.getVector("bytes", "x")).values, [-128, 127]) && (await db.getVector("bytes", "x")).values instanceof Int8Array, "i8 vector");
  await db.createVectorCollection("halves", { dimensions: 2, metric: "dot", elementType: "f16" });
  await db.putVector("halves", "x", new Uint16Array([0x3c00, 0xc000]));
  assert(same((await db.getVector("halves", "x")).values, [0x3c00, 0xc000]), "f16 vector bits");
  await db.deleteVectorCollection("halves");
  assert(!await db.hasVectorCollection("halves") && (await db.listVectorCollections()).length === 2, "collection deleted");

  // Graphs: nodes, edges, neighbors, degree and bounded walks.
  await db.createGraph("g");
  await status(db.createGraph("g"), "ZOVA_GRAPH_EXISTS");
  await db.putGraphNode({ graphName: "g", nodeId: "a", kind: "page", targetType: "external", targetNamespace: "url", targetRef: "https://example.test/a" });
  await db.putGraphNodes([
    { graphName: "g", nodeId: "b", kind: "page", targetType: "none" },
    { graphName: "g", nodeId: "c", kind: "note", targetType: "none" },
  ]);
  await db.putGraphEdge({ graphName: "g", fromNodeId: "a", edgeType: "links", toNodeId: "b" });
  await db.putGraphEdges([
    { graphName: "g", fromNodeId: "b", edgeType: "links", toNodeId: "c" },
    { graphName: "g", fromNodeId: "a", edgeType: "cites", toNodeId: "c" },
  ]);
  const nodeA = await db.getGraphNode("g", "a");
  assert(nodeA.kind === "page" && nodeA.targetType === "external" && nodeA.targetNamespace === "url" && nodeA.targetRef === "https://example.test/a", "node fields");
  assert(!("targetRef" in await db.getGraphNode("g", "b")), "absent optional node fields");
  const graph = await db.graphInfo("g");
  assert(graph.nodeCount === 3n && graph.edgeCount === 3n && (await db.listGraphs())[0].name === "g" && await db.hasGraph("g"), "graph info");
  const links = await db.graphNeighbors({ graphName: "g", nodeId: "a", direction: "outgoing", edgeType: "links", limit: 10 });
  assert(links.length === 1 && links[0].nodeId === "b" && links[0].kind === "page" && links[0].edgeType === "links", "filtered neighbors");
  assert((await db.graphNeighbors({ graphName: "g", nodeId: "c", direction: "incoming", limit: 10 })).length === 2, "incoming neighbors");
  assert(await db.graphDegree({ graphName: "g", nodeId: "a", direction: "outgoing" }) === 2n, "degree");
  const walk = await db.graphWalk({ graphName: "g", startNodeId: "a", edgeType: "links", maxDepth: 2, limit: 10 });
  assert(walk.map(item => `${item.nodeId}:${item.depth}`).join() === "a:0,b:1,c:2", "walk order");
  assert(!("predecessorNodeId" in walk[0]) && walk[2].predecessorNodeId === "b" && walk[2].edgeType === "links", "walk provenance");
  const back = await db.graphWalk({ graphName: "g", startNodeId: "c", direction: "incoming", edgeType: "links", maxDepth: 1, limit: 10 });
  assert(back.map(item => item.nodeId).join() === "c,b", "incoming walk");
  assert((await db.getGraphEdge("g", "a", "links", "b")).toNodeId === "b" && await db.hasGraphEdge("g", "a", "cites", "c"), "edge lookup");
  await status(db.getGraphEdge("g", "c", "links", "a"), "ZOVA_GRAPH_EDGE_NOT_FOUND");
  await status(db.getGraphNode("g", "missing"), "ZOVA_GRAPH_NODE_NOT_FOUND");
  await status(db.putGraphNode({ graphName: "g", nodeId: "d", kind: "page", targetType: "planet" }), "ZOVA_INVALID_ARGUMENT");
  await db.deleteGraphEdge({ graphName: "g", fromNodeId: "a", edgeType: "cites", toNodeId: "c" });
  await db.deleteGraphEdges([{ graphName: "g", fromNodeId: "a", edgeType: "links", toNodeId: "b" }]);
  assert((await db.graphInfo("g")).edgeCount === 1n, "edge deletes");
  await db.deleteGraphNode("g", "c");
  assert(!await db.hasGraphNode("g", "c") && (await db.graphInfo("g")).edgeCount === 0n, "node delete removes its edges");
  await db.deleteGraphNodes("g", ["a", "missing"]);
  assert((await db.graphInfo("g")).nodeCount === 1n, "node batch delete");
  await db.deleteGraph("g");
  assert(!await db.hasGraph("g"), "graph deleted");
  await status(db.export(), "ZOVA_INVALID_ARGUMENT");
  await db.close();
  await status(select.query([1n]), "ZOVA_MISUSE");

  // Export and import of persistent databases.
  const sourceName = "export-" + crypto.randomUUID();
  db = await Database.openPersistent(sourceName);
  await db.exec("CREATE TABLE saved(value); INSERT INTO saved VALUES(7)");
  await db.kv.put(one, one, two);
  await db.createVectorCollection("docs", { dimensions: 2, metric: "l2", elementType: "f32" });
  await db.putVector("docs", "a", new Float32Array([3, 4]));
  await db.exec("BEGIN; INSERT INTO saved VALUES(8)");
  await rejects(db.export());
  await db.exec("ROLLBACK");
  const exported = await db.export();
  assert(exported.length > 0 && exported.length % 4096 === 0, "exported whole pages");
  await db.exec("INSERT INTO saved VALUES(9)");
  await db.close();
  const copyName = "import-" + crypto.randomUUID();
  db = await Database.importPersistent(copyName, exported);
  assert((await db.query("SELECT value FROM saved")).rows.length === 1, "import holds the exported state only");
  assert((await db.kv.get(one, one))[0] === 2 && same((await db.getVector("docs", "a")).values, [3, 4]), "imported KV and vectors");
  await db.exec("INSERT INTO saved VALUES(10)");
  await db.close();
  await status(Database.importPersistent(copyName, exported), "ZOVA_DESTINATION_EXISTS");
  db = await Database.openPersistent(copyName);
  assert((await db.query("SELECT value FROM saved")).rows.length === 2, "refused import leaves the existing database");
  await db.exec("UPDATE _zova_meta SET value='999' WHERE key='format_version'");
  const incompatible = await db.export();
  await db.close();
  for (const [bytes, expected] of [[new Uint8Array(4096), "ZOVA_NOT_ZOVA_DATABASE"], [incompatible, "ZOVA_UNSUPPORTED_FUTURE_FORMAT"]]) {
    const rejectedName = "rejected-" + crypto.randomUUID();
    await status(Database.importPersistent(rejectedName, bytes), expected);
    db = await Database.openPersistent(rejectedName);
    assert((await db.query("SELECT count(*) FROM sqlite_schema WHERE name = 'saved'")).rows[0][0] === 0n, "rejected import stores nothing");
    await db.close();
  }
  await fetch("/result", { method: "POST", body: JSON.stringify({ ok: true, packedPackage: true,
    initializationMs: initialized - started, firstQueryMs: queried - initialized }) });
} catch (error) {
  await fetch("/result", { method: "POST", body: JSON.stringify({ ok: false, error: String(error), stack: error.stack }) });
} finally { await db?.close(); }
