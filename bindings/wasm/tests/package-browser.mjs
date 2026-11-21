import * as zova from "/package/dist/index.js";
const { Database, ZovaError } = zova;
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const rejects = async promise => {
  try { await promise; } catch (error) {
    assert(error instanceof ZovaError && error.name === "ZovaError", "Expected ZovaError");
    assert(typeof error.code === "string" && typeof error.status === "number" && error.statusCode === error.status, "Error status fields");
    assert(zova.ZovaWasmError === ZovaError, "ZovaWasmError is a deprecated alias");
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
      assert(error instanceof ZovaError && error.code === expected, `Expected ${expected}, got ${error.code ?? error}`);
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
  // Memory databases export too, and import as persistent databases.
  const memoryBytes = await db.export();
  const fromMemory = await Database.importPersistent("from-memory-" + crypto.randomUUID(), memoryBytes);
  assert(await fromMemory.hasVectorCollection("docs") && (await fromMemory.query("SELECT count(*) FROM t")).rows[0][0] === 7n, "memory export imports");
  await fromMemory.close();
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

  // Native SQL, transaction, KV and notification parity (#216).
  db = await Database.createMemory();
  await db.exec("CREATE TABLE p(id INTEGER PRIMARY KEY, v)");
  const totalBefore = await db.totalChanges();
  await db.begin();
  await db.query("INSERT INTO p(v) VALUES (?)", ["rolled"]);
  await db.rollback();
  await db.beginImmediate();
  await db.query("INSERT INTO p(v) VALUES (?), (?)", ["a", "b"]);
  assert(await db.changes() === 2n && await db.lastInsertRowid() === 2n, "changes and rowid");
  await db.commit();
  assert((await db.query("SELECT count(*) FROM p")).rows[0][0] === 2n && await db.totalChanges() - totalBefore === 3n, "explicit transactions");
  await db.setBusyTimeout(100);
  await status(db.transaction(tx => tx.commit()), "ZOVA_MISUSE");
  await status(db.commit(), "ZOVA_SQLITE_ERROR");
  // Savepoints nest and roll back inside transaction().
  await db.transaction(async tx => {
    await tx.query("INSERT INTO p(v) VALUES ('outer')");
    await tx.savepoint("s1", async sp => {
      await sp.query("INSERT INTO p(v) VALUES ('kept')");
      let undone;
      try { await sp.savepoint("s2", async inner => { await inner.query("INSERT INTO p(v) VALUES ('dropped')"); throw new RangeError("undo"); }); }
      catch (error) { undone = error; }
      assert(undone instanceof RangeError, "savepoint callback error is rethrown");
    });
    await tx.savepoint("s3");
    await tx.query("INSERT INTO p(v) VALUES ('undone')");
    await tx.rollbackToSavepoint("s3");
    await tx.releaseSavepoint("s3");
  });
  const values = (await db.query("SELECT v FROM p ORDER BY id")).rows.map(row => row[0]).join();
  assert(values === "a,b,outer,kept", `nested savepoints: ${values}`);
  // Statements step one row at a time.
  const stepper = await db.prepare("SELECT ?1 AS i, :f AS f, :t AS t, ?4 AS b, NULL AS n");
  assert(await stepper.parameterIndex(":f") === 2 && await stepper.parameterIndex(":missing") === null, "parameter index");
  await stepper.bindInteger(1, 7n); await stepper.bindFloat(2, 1.5); await stepper.bindText(3, "x"); await stepper.bindBlob(4, new Uint8Array([9]));
  assert(await stepper.step() === "row", "step row");
  assert(stepper.columnCount() === 5 && stepper.columnName(2) === "t" && stepper.columnType(0) === "integer" && stepper.columnType(4) === "null", "column metadata");
  assert(stepper.columnInteger(0) === 7n && stepper.columnFloat(1) === 1.5 && stepper.columnText(2) === "x" && stepper.columnBlob(3)[0] === 9 && stepper.columnText(4) === null, "column values");
  assert(stepper.columnFloat(0) === 7 && stepper.columnInteger(1) === 1n && stepper.columnInteger(4) === 0n, "numeric conversions");
  let mismatch;
  try { stepper.columnInteger(2); } catch (error) { mismatch = error; }
  assert(mismatch instanceof ZovaError && mismatch.code === "ZOVA_MISUSE", "text read as integer is refused");
  assert(await stepper.step() === "done", "step done");
  await stepper.reset();
  assert(await stepper.step() === "row" && stepper.columnInteger(0) === 7n, "reset keeps bindings");
  await stepper.reset(); await stepper.clearBindings();
  assert(await stepper.step() === "row" && stepper.columnType(0) === "null", "cleared bindings");
  await status(stepper.bindInteger(0, 1n), "ZOVA_INVALID_ARGUMENT");
  await stepper.finalize();
  // KV batches are atomic inside and outside transaction().
  const batchNs = new Uint8Array([5]);
  const k = n => new Uint8Array([n]);
  await db.kv.putMany(batchNs, [{ key: k(1), value: k(11) }, { key: k(2), value: k(12) }, { key: k(3), value: new Uint8Array() }]);
  const many = await db.kv.getMany(batchNs, [k(1), k(9), k(3)]);
  assert(many[0][0] === 11 && many[1] === null && many[2].length === 0 && await db.kv.count(batchNs) === 3n, "KV batches");
  await db.exec("CREATE TRIGGER kv_fault BEFORE INSERT ON _zova_kv WHEN NEW.key = X'FF' BEGIN SELECT RAISE(ABORT, 'injected'); END");
  await status(db.kv.putMany(batchNs, [{ key: k(4), value: k(14) }, { key: k(255), value: k(1) }]), "ZOVA_CONSTRAINT");
  assert(await db.kv.get(batchNs, k(4)) === null, "failed batch writes nothing");
  await db.transaction(async tx => {
    await tx.kv.put(batchNs, k(5), k(15));
    await status(tx.kv.putMany(batchNs, [{ key: k(6), value: k(16) }, { key: k(255), value: k(1) }]), "ZOVA_CONSTRAINT");
    await tx.kv.deleteMany(batchNs, [k(1), k(77)]);
  });
  assert((await db.kv.get(batchNs, k(5)))[0] === 15 && await db.kv.get(batchNs, k(6)) === null && await db.kv.get(batchNs, k(1)) === null, "batch inside transaction rolls back only itself");
  await db.exec("DROP TRIGGER kv_fault");
  await db.kv.clearNamespace(batchNs);
  assert(await db.kv.count(batchNs) === 0n, "clear namespace");
  // Notifications arrive after commit, never after rollback.
  const subscription = await db.listen("jobs");
  await db.notify("jobs", "now");
  const received = await subscription.tryReceive();
  assert(received.channel === "jobs" && received.payload === "now" && typeof received.sequence === "bigint" && received.droppedBefore === 0n, "immediate notification");
  assert(await subscription.tryReceive() === null, "queue drained");
  // Inside transaction(), use subscriptions created through `tx`.
  const inner = await db.transaction(async tx => {
    const listener = await tx.listen("jobs");
    await tx.notify("jobs", "committed");
    assert(await listener.tryReceive() === null, "not delivered before commit");
    return listener;
  });
  assert((await subscription.tryReceive()).payload === "committed" && (await inner.tryReceive()).payload === "committed", "delivered after commit");
  await inner.close();
  await db.transaction(async tx => { await tx.notify("jobs", "rolled"); throw new RangeError("undo"); }).catch(() => undefined);
  await db.transaction(async tx => {
    await tx.savepoint("n");
    await tx.notify("jobs", "savepoint-rolled");
    await tx.rollbackToSavepoint("n");
    await tx.releaseSavepoint("n");
  });
  await db.begin(); await db.notify("jobs", "explicit-rolled"); await db.rollback();
  assert(await subscription.tryReceive() === null, "rolled back notifications are dropped");
  await subscription.close();
  assert(subscription.closed, "subscription closed");
  await status(subscription.tryReceive(), "ZOVA_MISUSE");
  await db.close();

  // Streaming object, chunk and manifest APIs match native zova-js (#217).
  {
    const zova = await import("/package/dist/index.js");
    const h = await import("/helpers.mjs");
    const fixture = await (await fetch("/object-fixture.json")).json();
    const hex = zova.objectIdToHex;
    const manifestJson = m => ({ objectId: hex(m.objectId), sizeBytes: String(m.sizeBytes), chunkCount: String(m.chunkCount), chunker: m.chunker,
      chunks: m.chunks.map(c => [String(c.index), hex(c.hash), String(c.offset), String(c.sizeBytes)]) });
    for (const expected of fixture.results) {
      // Like the native generator: content addressing keeps the first manifest.
      await db?.close();
      db = await Database.createMemory();
      const testCase = h.objectFixtureCases.find(item => item.name === expected.case);
      const data = h.patternBytes(testCase.length, testCase.seed);
      const options = expected.profile === null ? undefined : { profile: expected.profile };
      const label = `${expected.case}/${expected.profile}`;
      assert(hex(await zova.objectId(data)) === expected.objectId && hex(await zova.objectChunkId(data)) === expected.chunkId, `${label}: identity helpers`);
      const put = options ? await db.putObjectWithOptions(data, options) : await db.putObject(data);
      assert(JSON.stringify(manifestJson(await db.objectManifest(put))) === JSON.stringify(expected.put), `${label}: put manifest differs from native`);
      const writer = options ? await db.objectWriterWithOptions(options) : await db.objectWriter();
      const source = new ReadableStream({ start(controller) {
        for (let offset = 0; offset < data.length; offset += h.objectWriterPiece) controller.enqueue(data.subarray(offset, offset + h.objectWriterPiece));
        controller.close();
      } });
      await source.pipeTo(writer);
      const written = await writer.id;
      assert(JSON.stringify(manifestJson(await db.objectManifest(written))) === JSON.stringify(expected.writer), `${label}: writer manifest differs from native`);
      assert(await db.objectChunkCount(written) === BigInt(expected.writer.chunkCount), `${label}: chunk count`);
      const read = [];
      for await (const piece of await db.objectReader(written, 100000)) read.push(piece);
      const joined = new Uint8Array(read.reduce((total, piece) => total + piece.length, 0));
      read.reduce((offset, piece) => { joined.set(piece, offset); return offset + piece.length; }, 0);
      assert(same(joined, data) && read.every(piece => piece.length <= 100000), `${label}: reader stream bytes`);
    }
    // Chunks stored one by one assemble into the native object.
    const multi = fixture.results.find(item => item.case === "multi" && item.profile === "deduplication").put;
    const multiCase = h.objectFixtureCases.find(item => item.name === "multi");
    const multiData = h.patternBytes(multiCase.length, multiCase.seed);
    await db.close();
    db = await Database.createMemory();
    const chunkInputs = multi.chunks.map(([index, hash, offset, size]) => ({ index: BigInt(index), hash: zova.objectIdFromHex(hash), offset: BigInt(offset), sizeBytes: BigInt(size) }));
    for (const chunk of chunkInputs) {
      await db.putObjectChunk(chunk.hash, multiData.subarray(Number(chunk.offset), Number(chunk.offset + chunk.sizeBytes)));
    }
    await status(db.putObjectChunk(chunkInputs[0].hash, new Uint8Array([1])), "ZOVA_OBJECT_CHUNK_HASH_MISMATCH");
    assert(await db.hasObjectChunk(chunkInputs[1].hash) && same(await db.getObjectChunk(chunkInputs[1].hash), multiData.subarray(Number(chunkInputs[1].offset), Number(chunkInputs[1].offset + chunkInputs[1].sizeBytes))), "loose chunk read");
    const assembledId = zova.objectIdFromHex(multi.objectId);
    await db.assembleObjectFromChunks(assembledId, BigInt(multi.sizeBytes), chunkInputs);
    assert(same(await db.getObject(assembledId), multiData) && JSON.stringify(manifestJson(await db.objectManifest(assembledId))) === JSON.stringify(multi), "assembled object matches native");
    const looseData = new TextEncoder().encode("loose chunk");
    const looseHash = await zova.objectChunkId(looseData);
    await db.putObjectChunkWithOptions(looseHash, looseData, { profile: "streaming" });
    assert(await db.deleteObjectChunk(looseHash) === true && await db.deleteObjectChunk(looseHash) === false && !await db.hasObjectChunk(looseHash), "loose chunk delete");
    // The seekable reader returns what readObjectRange returns.
    const seekable = await db.objectSeekableReader(assembledId);
    assert(seekable.size === BigInt(multiData.length), "seekable size");
    let seed = 99;
    const random = limit => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % limit; };
    for (let trial = 0; trial < 200; trial++) {
      const offset = BigInt(random(multiData.length + 10));
      const length = random(300000);
      assert(same(await seekable.readAt(offset, length), await db.readObjectRange(assembledId, offset, length)), `seekable read at ${offset}+${length}`);
    }
    assert(await seekable.seek(-10, "end") === BigInt(multiData.length - 10) && same(await seekable.read(100), multiData.subarray(-10)), "seek from end");
    assert((await seekable.read(5)).length === 0 && seekable.position === BigInt(multiData.length), "read at end");
    await seekable.close();
    await status(seekable.readAt(0n, 1), "ZOVA_OBJECT_READER_CLOSED");
    // A cancelled writer leaves no object and no chunks.
    const counts = async () => (await db.query("SELECT (SELECT count(*) FROM _zova_objects), (SELECT count(*) FROM _zova_chunks)")).rows[0].join();
    const before = await counts();
    const cancelled = await db.objectWriter();
    const handle = cancelled.getWriter();
    await handle.write(h.patternBytes(500000, 7));
    await handle.write(h.patternBytes(500000, 8));
    await handle.abort(new RangeError("stop"));
    let cancelError;
    try { await cancelled.id; } catch (error) { cancelError = error; }
    assert(cancelError instanceof RangeError && await counts() === before, "cancelled writer stores nothing");
    const failed = await db.objectWriter();
    const failedHandle = failed.getWriter();
    await failedHandle.write(new Uint8Array(10));
    let wrongChunk;
    try { await failedHandle.write("text"); } catch (error) { wrongChunk = error; }
    assert(wrongChunk instanceof ZovaError && await counts() === before, "failed writer stores nothing");
    await status(db.objectReader(new Uint8Array(32)), "ZOVA_OBJECT_NOT_FOUND");
    await db.close();
  }

  // Filtered vector search matches native zova-js (#218).
  {
    const fixture = JSON.parse(await (await fetch("/vector-fixture.json")).text(), (_, value) => value === "NaN" ? Number.NaN : value);
    const typed = (type, items) => type === "f32" ? new Float32Array(items) : type === "f16" ? new Uint16Array(items) : new Int8Array(items);
    let compared = 0;
    for (const collection of fixture.collections) {
      db = await Database.createMemory();
      const { name, metric, elementType, dimensions } = collection;
      await db.createVectorCollection(name, { dimensions, metric, elementType });
      await db.putVectors(name, collection.vectors.map(vector => ({ id: vector.id, values: typed(elementType, vector.values) })));
      for (const testCase of collection.cases) {
        let actual;
        try {
          const results = testCase.by === "query"
            ? await db.searchVectors(name, typed(elementType, collection.query), testCase.options)
            : await db.searchVectorsById(name, testCase.by, testCase.options);
          actual = { results: results.map(item => [item.id, item.distance]) };
        } catch (error) { actual = { error: error.code }; }
        const label = `${name} ${testCase.by} ${JSON.stringify(testCase.options)}`;
        assert(actual.error === testCase.expected.error, `${label}: status ${actual.error} vs native ${testCase.expected.error}`);
        if (actual.error === undefined) {
          const expected = testCase.expected.results;
          assert(actual.results.map(item => item[0]).join() === expected.map(item => item[0]).join(), `${label}: ids ${actual.results.map(item => item[0])} vs native ${expected.map(item => item[0])}`);
          assert(actual.results.every((item, index) => Math.abs(item[1] - expected[index][1]) <= 1e-9 * Math.max(1, Math.abs(expected[index][1]))), `${label}: distances differ`);
        }
        compared++;
      }
      await db.close();
    }
    assert(compared === 9 * 23, `compared ${compared} native searches`);
    db = await Database.createMemory();
    await status(db.searchVectors("c", new Float32Array(1), { limit: 1, candidateIds: "v1" }), "ZOVA_INVALID_ARGUMENT");
    await status(db.searchVectors("c", new Float32Array(1), { limit: 1, maxDistance: "1" }), "ZOVA_INVALID_ARGUMENT");
    await db.close();
  }

  // Keyed graph, edge payload, scan, directional walk, fresh-build and
  // multi-vector calls replay native zova-js results step by step (#222).
  {
    const { encode, decode } = await import("/fixture-codec.mjs");
    const fixture = await (await fetch("/graph-fixture.json")).json();
    // Distances may differ in the last bits between native and WebAssembly.
    const same = (actual, expected) => {
      if (typeof actual === "number" && typeof expected === "number") {
        return actual === expected || Math.abs(actual - expected) <= 1e-9 * Math.max(1, Math.abs(expected));
      }
      if (Array.isArray(actual) && Array.isArray(expected)) return actual.length === expected.length && actual.every((item, index) => same(item, expected[index]));
      if (actual && expected && typeof actual === "object" && typeof expected === "object") {
        const keys = Object.keys(expected);
        return Object.keys(actual).length === keys.length && keys.every(key => key in actual && same(actual[key], expected[key]));
      }
      return actual === expected;
    };
    const targets = { db: await Database.createMemory() };
    for (const sql of fixture.setup) await targets.db.exec(sql);
    for (const [index, step] of fixture.steps.entries()) {
      const args = decode(step.args);
      let actual;
      try {
        const result = step.call === "$memory" ? await Database.createMemory()
          : step.call === "$rows" ? (await targets[step.target].query(args[0])).rows
          : await targets[step.target][step.call](...args);
        if (step.store) targets[step.store] = result;
        actual = step.store ? { stored: true } : { result: encode(result ?? null) };
      } catch (error) {
        if (!(error instanceof ZovaError)) throw error;
        actual = { error: error.code };
      }
      assert(same(actual, step.expected), `step ${index} ${step.target}.${step.call}: ${JSON.stringify(actual).slice(0, 400)} vs native ${JSON.stringify(step.expected).slice(0, 400)}`);
    }
    for (const target of Object.values(targets)) if (target instanceof Database) await target.close();
    assert(fixture.steps.length > 100, `replayed ${fixture.steps.length} native steps`);
  }

  // Bundled extensions match native results; a missing plugin fails as native (#221).
  {
    const h = await import("/helpers.mjs");
    const fixture = await (await fetch("/extension-fixture.json")).json();
    db = await Database.createMemory();
    await db.installExtension("trgm");
    for (const [sql, rows] of fixture.trgmSql) {
      const actual = (await db.query(sql)).rows.map(row => row[0]);
      assert(JSON.stringify(actual) === JSON.stringify(rows), `trgm: ${sql} returned ${JSON.stringify(actual)}, native ${JSON.stringify(rows)}`);
    }
    const strip = ({ installedAtUnix, ...rest }) => { assert(typeof installedAtUnix === "bigint" && installedAtUnix > 0n, "installedAtUnix"); return rest; };
    const listed = (await db.listExtensions()).map(strip);
    assert(JSON.stringify(listed) === JSON.stringify(fixture.installed), `extension list ${JSON.stringify(listed)}`);
    assert(JSON.stringify(strip(await db.extensionInfo("trgm"))) === JSON.stringify(fixture.installed[0]), "extension info");
    const statusOf = async promise => { try { await promise; return "ZOVA_OK"; } catch (error) { return error.code; } };
    assert(await statusOf(db.checkExtension("trgm")) === fixture.check && await statusOf(db.checkExtensions()) === fixture.checkAll, "extension checks");
    assert(await statusOf(db.installExtension("trgm")) === fixture.installAgain && await statusOf(db.installExtension("nonexistent")) === fixture.installUnknown, "install errors");
    await db.dropExtension("trgm");
    assert(await statusOf(db.checkExtension("trgm")) === fixture.checkAfterDrop && await statusOf(db.dropExtension("trgm")) === fixture.dropAgain, "drop");
    assert((await db.listExtensions()).length === 0, "dropped extension listed");
    await db.close();
    // Installed in a stored database, trgm is registered again on open.
    const trgmName = "trgm-" + crypto.randomUUID();
    db = await Database.openPersistent(trgmName);
    await db.installExtension("trgm");
    await db.close();
    db = await Database.openPersistent(trgmName);
    assert((await db.query("SELECT zova_trgm_similarity('abc', 'abd')")).rows[0][0] > 0 && (await db.listExtensions())[0].name === "trgm", "trgm after reopen");
    await db.close();
    // A database whose extension code this module lacks.
    const missingName = "missing-ext-" + crypto.randomUUID();
    await h.seed(missingName, await h.fetchBytes("/extension-missing.zova"));
    let missing;
    try { await Database.openPersistent(missingName); } catch (error) { missing = error; }
    assert(missing instanceof ZovaError && missing.code === fixture.missingPlugin.status && missing.message === fixture.missingPlugin.message,
      `missing plugin: ${missing?.code} ${missing?.message}, native ${fixture.missingPlugin.status} ${fixture.missingPlugin.message}`);
  }

  // Every C ABI call that applies in a browser, matching native zova-js (#228).
  {
    const bytes = value => new TextEncoder().encode(value);
    const text = value => new TextDecoder().decode(value);
    const statusOf = async promise => { try { await promise; return "ZOVA_OK"; } catch (error) { return error.code; } };

    // ABI version.
    const abi = await zova.abiVersion();
    const parts = await zova.abiVersionParts();
    assert(abi === `${parts.major}.${parts.minor}.${parts.patch}` && Object.isFrozen(parts), `ABI version ${abi}`);
    // The version constants describe the bundled module.
    assert(zova.packageVersion === abi, `package version ${zova.packageVersion} vs ABI ${abi}`);
    db = await Database.createMemory();
    const [[sqlite]] = (await db.query("SELECT sqlite_version()")).rows;
    assert(zova.sqliteVersion === sqlite, `SQLite version ${zova.sqliteVersion} vs ${sqlite}`);
    await db.close();
    const formatName = "format-" + crypto.randomUUID();
    await (await Database.openPersistent(formatName)).close();
    const created = await Database.probePersistent(formatName);
    assert(zova.formatVersion === String(created.formatVersion), `format version ${zova.formatVersion} vs created ${created.formatVersion}`);
    await Database.deletePersistent(formatName);

    // Creation and open options.
    db = await Database.createMemory({ pageSize: 8192 });
    assert((await db.query("PRAGMA page_size")).rows[0][0] === 8192n, "memory pageSize");
    await db.close();
    await status(Database.createMemory({ pageSize: 1000 }), "ZOVA_INVALID_ARGUMENT");
    const optionsName = "options-" + crypto.randomUUID();
    await status(Database.openPersistent(optionsName, { readOnly: true }), "ZOVA_NOT_ZOVA_DATABASE");
    db = await Database.openPersistent(optionsName, { pageSize: 16384, busyTimeoutMs: 1234 });
    assert((await db.query("PRAGMA page_size")).rows[0][0] === 16384n, "persistent pageSize");
    assert((await db.query("PRAGMA busy_timeout")).rows[0][0] === 1234n, "busyTimeoutMs");
    await db.exec("CREATE TABLE kept(v); INSERT INTO kept VALUES(5)");
    await db.close();
    db = await Database.openPersistent(optionsName, { readOnly: true });
    assert((await db.query("SELECT v FROM kept")).rows[0][0] === 5n, "read-only read");
    await rejects(db.exec("INSERT INTO kept VALUES(6)"));
    await db.close();

    // Conversion from an ordinary SQLite database.
    const plain = new Uint8Array(await (await fetch("/plain.sqlite")).arrayBuffer());
    const convertedName = "converted-" + crypto.randomUUID();
    db = await Database.convertSqliteToPersistent(convertedName, plain);
    assert((await db.query("SELECT body FROM notes WHERE id = 1")).rows[0][0] === "from sqlite", "converted rows");
    await db.createGraph("after-convert");
    await db.close();
    db = await Database.openPersistent(convertedName);
    assert(await db.hasGraph("after-convert"), "converted database reopens as Zova");
    await db.close();
    await rejects(Database.convertSqliteToPersistent(convertedName, plain));
    const streamed = "converted-stream-" + crypto.randomUUID();
    db = await Database.convertSqliteToPersistent(streamed, new Blob([plain]).stream());
    assert((await db.query("SELECT count(*) FROM notes")).rows[0][0] === 1n, "streamed conversion");
    await db.close();
    await rejects(Database.convertSqliteToPersistent("not-sqlite-" + crypto.randomUUID(), bytes("not a database")));
    assert(!(await Database.listPersistent()).some(item => item.name.startsWith("not-sqlite-")), "failed conversion leaves no database");

    db = await Database.createMemory();
    // KV scan and compare-and-set.
    const ns = bytes("ns");
    for (const key of ["a1", "a2", "a3", "b1"]) await db.kv.put(ns, bytes(key), bytes("v" + key));
    const all = await db.kv.scan(ns, { limit: 100 });
    assert(all.entries.map(entry => text(entry.key)).join() === "a1,a2,a3,b1" && !all.hasMore && text(all.entries[0].value) === "va1", "KV scan");
    const first = await db.kv.scan(ns, { prefix: bytes("a"), limit: 2, keysOnly: true });
    assert(first.entries.map(entry => text(entry.key)).join() === "a1,a2" && first.hasMore && first.entries[0].value.length === 0, "KV scan page");
    const next = await db.kv.scan(ns, { prefix: bytes("a"), after: first.entries[1].key, limit: 2 });
    assert(next.entries.map(entry => text(entry.key)).join() === "a3" && !next.hasMore, "KV scan continuation");
    const bounded = await db.kv.scan(ns, { start: bytes("a2"), end: bytes("b"), limit: 10 });
    assert(bounded.entries.map(entry => text(entry.key)).join() === "a2,a3", "KV scan bounds");
    await status(db.kv.scan(ns, { limit: 0 }), "ZOVA_INVALID_ARGUMENT");
    assert(await db.kv.putIfAbsent(ns, bytes("k"), bytes("v1")) && !await db.kv.putIfAbsent(ns, bytes("k"), bytes("other")), "putIfAbsent");
    assert(!await db.kv.compareAndPut(ns, bytes("k"), bytes("stale"), bytes("v2")) && await db.kv.compareAndPut(ns, bytes("k"), bytes("v1"), bytes("v2")), "compareAndPut");
    assert(!await db.kv.compareAndDelete(ns, bytes("k"), bytes("v1")) && await db.kv.compareAndDelete(ns, bytes("k"), bytes("v2")), "compareAndDelete");
    assert(!await db.kv.compareAndPut(ns, bytes("missing"), new Uint8Array(), bytes("x")), "missing key never matches");

    // Object compression.
    await db.setObjectCompression("lz4");
    const repetitive = new Uint8Array(1 << 16).fill(7);
    const compressedId = await db.putObject(repetitive);
    assert((await db.getObject(compressedId)).every(value => value === 7), "lz4 object round trip");
    await db.setObjectCompression("none");
    await status(db.setObjectCompression("zstd"), "ZOVA_INVALID_ARGUMENT");

    // Multi-vector i8 search.
    await db.createVectorCollection("codes", { dimensions: 2, metric: "cosine", elementType: "i8" });
    await db.putVectors("codes", [
      { id: "east", values: Int8Array.of(100, 0) }, { id: "north", values: Int8Array.of(0, 100) }, { id: "diag", values: Int8Array.of(70, 70) },
    ]);
    const queryValues = Int8Array.of(100, 0, 0, 100);
    const multi = await db.searchVectorsMultiI8("codes", { queryValues, queryCount: 2, dimensions: 2, limit: 3 });
    assert(multi[0].id === "diag" && multi.map(item => item.id).sort().join() === "diag,east,north", "multi-vector search");
    const within = await db.searchVectorsMultiI8("codes", { queryValues, queryCount: 2, dimensions: 2, limit: 3, candidateIds: ["east", "north"] });
    assert(within.map(item => item.id).sort().join() === "east,north", "multi-vector candidates");
    const prefiltered = await db.searchVectorsMultiI8("codes", { queryValues, queryCount: 2, dimensions: 2, limit: 1,
      mode: "cbm-prefilter-min-cosine", aggregation: "min-cosine", prefilterQueryIndex: 0, prefilterLimit: 2 });
    assert(prefiltered.length === 1, "multi-vector prefilter");
    await status(db.searchVectorsMultiI8("codes", { queryValues, queryCount: 2, dimensions: 2, limit: 1, mode: "nearest" }), "ZOVA_INVALID_ARGUMENT");

    // Keyed graph calls.
    const G = "code";
    const gnode = (nodeId, kind = "file") => ({ graphName: G, nodeId, kind, targetType: "none" });
    await db.createGraph(G);
    const nodeKeys = await db.putGraphNodesKeyed([gnode("a"), gnode("b", "dir")]);
    assert(nodeKeys instanceof BigInt64Array && nodeKeys.length === 2, "keyed node put");
    const edgeKeys = await db.putGraphEdgesKeyed([{ graphName: G, fromNodeId: "a", edgeType: "imports", toNodeId: "b" }]);
    assert(edgeKeys instanceof BigInt64Array && edgeKeys.length === 1, "keyed edge put");
    const keyedNodes = await db.getGraphNodesKeyed(G, [nodeKeys[1], 999_999n, nodeKeys[0]]);
    assert(keyedNodes[0].nodeId === "b" && keyedNodes[0].kind === "dir" && keyedNodes[0].nodeKey === nodeKeys[1]
      && keyedNodes[1] === null && keyedNodes[2].nodeId === "a" && typeof keyedNodes[2].createdOrder === "bigint", "keyed node get");
    const [foundEdge, missingEdge] = await db.getGraphEdgesKeyed(G, BigInt64Array.of(edgeKeys[0], 999_999n));
    assert(missingEdge === null && foundEdge.sourceNodeKey === nodeKeys[0] && foundEdge.targetNodeKey === nodeKeys[1] && foundEdge.edgeType === "imports", "keyed edge get");
    const keyedNeighbors = await db.graphNeighborsKeyed({ graphName: G, nodeId: "a", direction: "outgoing", limit: 10 });
    assert(JSON.stringify(keyedNeighbors, (_, value) => typeof value === "bigint" ? String(value) : value)
      === JSON.stringify([{ edgeKey: String(edgeKeys[0]), neighborNodeKey: String(nodeKeys[1]), nodeId: "b", kind: "dir", edgeType: "imports" }]), "keyed neighbors");
    const degrees = await db.graphDegreesKeyed({ graphName: G, nodeKeys, direction: "outgoing" });
    assert(degrees instanceof BigUint64Array && [...degrees].join() === "1,0", "keyed degrees");
    assert([...await db.graphDegreesKeyed({ graphName: G, nodeKeys, direction: "incoming", edgeType: "imports" })].join() === "0,1", "keyed incoming degrees");
    const payloads = await db.getGraphEdgePayloads(G, [edgeKeys[0], 999_999n]);
    assert(payloads[0] instanceof Uint8Array && payloads[0].length === 0 && payloads[1] === null, "empty payloads");
    await db.replaceGraphEdgePayloads(G, [{ edgeKey: edgeKeys[0], payload: Uint8Array.of(0, 7) }]);
    assert((await db.getGraphEdgePayloads(G, edgeKeys))[0].join() === "0,7", "replaced payloads");
    await rejects(db.getGraphNodesKeyed(G, [1n << 70n]));
    const page1 = await db.graphScan({ graphName: G, nodeLimit: 1, edgeLimit: 5 });
    assert(page1.nodes.map(item => item.nodeId).join() === "a" && page1.hasMoreNodes && page1.edges.length === 1 && !page1.hasMoreEdges, "graph scan");
    const page2 = await db.graphScan({ graphName: G, nodeLimit: 5, edgeLimit: 5,
      nodeAfter: { createdOrder: page1.nodes[0].createdOrder, key: page1.nodes[0].nodeKey },
      edgeAfter: { createdOrder: page1.edges[0].createdOrder, key: page1.edges[0].edgeKey } });
    assert(page2.nodes.map(item => item.nodeId).join() === "b" && !page2.hasMoreNodes && page2.edges.length === 0, "graph scan continuation");
    await db.putGraphNodes([gnode("c")]);
    await db.putGraphEdges([{ graphName: G, fromNodeId: "b", edgeType: "imports", toNodeId: "c" }]);
    const walked = await db.graphWalkDirection({ graphName: G, startNodeId: "c", direction: "incoming", maxDepth: 2, limit: 10 });
    assert(walked.map(item => item.nodeId + item.depth).join() === "c0,b1,a2", "directional walk");
    const profiled = await db.graphWalkDirectionProfiled({ graphName: G, startNodeId: "a", direction: "outgoing", edgeType: "imports", maxDepth: 1, limit: 10 });
    assert(profiled.items.map(item => item.nodeId).join() === "a,b" && profiled.profile.resultCount === 2 && profiled.profile.totalProfiledMs >= 0, "profiled walk");
    await status(db.graphWalkDirection({ graphName: G, startNodeId: "a", direction: "sideways", maxDepth: 1, limit: 1 }), "ZOVA_INVALID_ARGUMENT");
    await db.close();

    // Fresh graph builders.
    const freshNodes = [{ nodeId: "a", kind: "file", targetType: "none" }, { nodeId: "b", kind: "file", targetType: "none" }];
    const imports = { fromNodeOrdinal: 0, edgeType: "imports", toNodeOrdinal: 1 };
    db = await Database.createMemory();
    const merged = await db.buildFreshGraphKeyed(G, freshNodes, [imports, imports]);
    assert(merged.nodeKeys.length === 2 && merged.edgeKeys.length === 2 && merged.edgeKeys[0] === merged.edgeKeys[1]
      && (await db.graphInfo(G)).edgeCount === 1n, "normalizing fresh graph");
    await db.close();
    db = await Database.createMemory();
    await status(db.buildFreshGraphPreparedKeyed(G, freshNodes, [{ ...imports, payload: Uint8Array.of(1) }]), "ZOVA_INVALID_ARGUMENT");
    const prepared = await db.buildFreshGraphPreparedKeyed(G, freshNodes, [imports]);
    assert((await db.getGraphEdgesKeyed(G, prepared.edgeKeys))[0].targetNodeKey === prepared.nodeKeys[1], "prepared fresh graph");
    await db.close();
    db = await Database.createMemory();
    const withPayloads = await db.buildFreshGraphPreparedKeyedWithPayloads(G, freshNodes, [{ ...imports, payload: bytes("w=1") }]);
    assert(text((await db.getGraphEdgePayloads(G, withPayloads.edgeKeys))[0]) === "w=1", "fresh graph payloads");
    await db.close();

    // Fresh-build sessions.
    const prepareFresh = async () => {
      const fresh = await Database.createMemory();
      await fresh.exec("create table files(id integer primary key, path text not null, size real, body blob); create virtual table bodies using fts5(body)");
      await fresh.createVectorCollection("embeddings", { dimensions: 2, metric: "l2", elementType: "f32" });
      return fresh;
    };
    const fileCount = async () => (await db.query("select count(*) from files")).rows[0][0];
    db = await prepareFresh();
    let build = await db.beginFreshBuild();
    assert(build instanceof zova.FreshBuild && !build.closed, "fresh build begins");
    await status(db.beginFreshBuild(), "ZOVA_MISUSE");
    await build.tableRows("files", ["id", "path", "size", "body"], [[1n, "a.rs", 1.5, Uint8Array.of(0, 97)], [2n, "b.rs", null, Uint8Array.of(98)]]);
    await build.ftsRows("bodies", ["body"], [["fn main"]]);
    await build.graph(G, freshNodes, [{ ...imports, payload: Uint8Array.of(119) }]);
    await build.vectors("embeddings", [{ id: "a.rs", values: Float32Array.of(1, 0) }]);
    await rejects(db.exec("select 1"));
    const built = await build.finish();
    assert(build.closed && built.nodeKeys.length === 2 && built.edgeKeys.length === 1, "fresh build keys");
    const { tableRows, ftsRows, vectorRows, payloadBytes } = built.profile;
    assert(tableRows === 2 && ftsRows === 1 && vectorRows === 1 && payloadBytes === 1, `fresh build profile ${JSON.stringify(built.profile)}`);
    assert(await fileCount() === 2n && (await db.query("select count(*) from bodies where bodies match 'main'")).rows[0][0] === 1n
      && (await db.getGraphEdgePayloads(G, built.edgeKeys))[0][0] === 119 && await db.hasVector("embeddings", "a.rs"), "fresh build committed");
    await status(build.abort(), "ZOVA_MISUSE");
    await db.close();
    db = await prepareFresh();
    build = await db.beginFreshBuild();
    await build.tableRows("files", ["id", "path"], [[1n, "a.rs"]]);
    await status(build.tableRows("files", ["id", "path"], [[2n]]), "ZOVA_INVALID_ARGUMENT");
    assert(build.closed && await fileCount() === 0n, "invalid rows roll back");
    build = await db.beginFreshBuild();
    await rejects(build.tableRows("files", ["id", "path"], [[1n, {}]]));
    assert(build.closed, "unsupported value closes the session");
    build = await db.beginFreshBuild();
    await build.tableRows("files", ["id", "path"], [[1n, "a.rs"]]);
    await build.abort();
    assert(await fileCount() === 0n, "abort rolls back");
    build = await db.beginFreshBuild();
    await build.tableRows("files", ["id", "path"], [[1n, "a.rs"]]);
    await build.close();
    await build.close();
    assert(await fileCount() === 0n, "close rolls back");
    await status(build.finish(), "ZOVA_MISUSE");
    build = await db.beginFreshBuild();
    await rejects(build.tableRows("missing_table", ["id"], [[1n]]));
    await rejects(build.finish());
    build = await db.beginFreshBuild();
    await build.tableRows("files", ["id", "path"], [[1n, "a.rs"]]);
    await db.close();
    // Closing the database ends an open session.
    db = await prepareFresh();
    await db.close();

    // SQL functions run from a module the worker imports.
    db = await Database.createMemory();
    const fn = name => ({ module: "/sql-function-fixture.mjs", export: name });
    const one = async sql => (await db.query(sql)).rows[0][0];
    await db.registerFunction("echo", -1, fn("echo"), { deterministic: true });
    await db.registerFunction("types", -1, fn("types"));
    await db.registerFunction("plus", 2, fn("plus"), { innocuous: true });
    await db.registerFunction("flag", 0, fn("flag"), { directOnly: true });
    await db.registerFunction("half", 1, fn("half"));
    await db.registerFunction("empty_value", 0, { module: new URL("/sql-function-fixture.mjs", location.href), export: "emptyValue" });
    assert(await one("select types(42, 1.5, 'text', x'0001', null)") === "bigint:42,number:1.5,string:text,blob:0 1,null", "SQL function arguments");
    assert(await one("select echo('héllo')") === "héllo" && (await one("select echo(x'ff')"))[0] === 255 && await one("select echo(null)") === null, "SQL function echo");
    assert(await one("select plus(2, 3)") === 5n && await one("select flag()") === 1n && await one("select half(3)") === 1.5, "SQL function results");
    assert(await one("select typeof(half(4))") === "real" && await one("select empty_value()") === null, "SQL function result types");
    await db.exec("create table t(x integer); insert into t values (1), (2), (3)");
    assert(await one("select sum(plus(x, 10)) from t") === 36n, "SQL function per row");
    for (const [name, message] of [["boom", "RangeError: no luck"], ["weird", "unsupported SQL function result type Object"], ["huge", "outside the signed 64-bit range"]]) {
      await db.registerFunction(name, 0, fn(name));
      let failed;
      try { await db.query(`select ${name}()`); } catch (error) { failed = error; }
      assert(failed instanceof ZovaError && failed.message.includes(message), `${name}: ${failed?.message}`);
    }
    assert(await one("select 1") === 1n, "connection usable after SQL function errors");
    await status(db.registerFunction("bad", 0, fn("notAFunction")), "ZOVA_INVALID_ARGUMENT");
    await status(db.registerFunction("bad", 0, { module: "/missing-module.mjs", export: "x" }), "ZOVA_INVALID_ARGUMENT");
    for (const [name, arity] of [["", 0], ["ok", 200], ["bad name", 0]]) await status(db.registerFunction(name, arity, fn("echo")), "ZOVA_INVALID_ARGUMENT");
    await rejects(db.query("select bad()"));
    await db.close();

    // Extension maintenance opens skip extension hooks.
    const maintenanceName = "upgrade-" + crypto.randomUUID();
    const h = await import("/helpers.mjs");
    await h.seed(maintenanceName, await h.fetchBytes("/extension-missing.zova"));
    await status(Database.openPersistentForExtensionUpgrade("missing-" + crypto.randomUUID()), "ZOVA_NOT_ZOVA_DATABASE");
    db = await Database.openPersistentForExtensionUpgrade(maintenanceName);
    assert(await statusOf(db.extensionUpgrade("c_test")) === "ZOVA_EXTENSION_UNAVAILABLE", "bare extension upgrade");
    assert(await statusOf(db.extensionRebuild("c_test")) === "ZOVA_EXTENSION_UNAVAILABLE", "bare extension rebuild");
    await db.close();
  }

  await fetch("/result", { method: "POST", body: JSON.stringify({ ok: true, packedPackage: true,
    initializationMs: initialized - started, firstQueryMs: queried - initialized }) });
} catch (error) {
  await fetch("/result", { method: "POST", body: JSON.stringify({ ok: false, error: String(error), stack: error.stack }) });
} finally { await db?.close(); }
