// Listing, deleting and streamed export/import of persistent databases (#220).
import { faultedPage } from "./fault-script.mjs";

// Prepended to the packed worker: keeps the module's memory for measurement.
const captureMemory = `
  for (const name of ["instantiate", "instantiateStreaming"]) {
    const original = WebAssembly[name];
    WebAssembly[name] = async (...args) => {
      const result = await original.apply(WebAssembly, args);
      const exports = (result.instance ?? result).exports;
      globalThis.testMemory = Object.values(exports).find(value => value instanceof WebAssembly.Memory);
      return result;
    };
  }
`;

export async function testTransfer(context, base, mebibytes) {
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const pages = [];
  const plain = async () => {
    const page = await context.newPage();
    pages.push(page);
    await page.goto(`${base}/failure`);
    await page.waitForFunction(() => Boolean(globalThis.zova));
    await page.evaluate(async () => { globalThis.h = await import("/helpers.mjs"); });
    return page;
  };
  try {
    // Listing, deletion and ownership.
    const page = await plain();
    const other = await plain();
    const id = String(Date.now());
    await other.evaluate(async id => { globalThis.owned = await zova.Database.openPersistent("owned-" + id); }, id);
    const managed = await page.evaluate(async id => {
      const { Database } = zova;
      const closed = await Database.openPersistent("closed-" + id);
      await closed.exec("CREATE TABLE t(v); INSERT INTO t VALUES (1)");
      await closed.close();
      await h.status(Database.probePersistent("never-" + id)); // leaves an empty pool directory
      const list = await Database.listPersistent();
      const find = name => list.find(item => item.name === name);
      return {
        closed: find("closed-" + id), owned: find("owned-" + id), never: find("never-" + id),
        deleteOwned: await h.status(Database.deletePersistent("owned-" + id)),
        deleteClosed: await Database.deletePersistent("closed-" + id),
        deleteAgain: await Database.deletePersistent("closed-" + id),
        listedAfter: (await Database.listPersistent()).some(item => item.name === "closed-" + id),
        reopenedEmpty: await (async () => {
          const db = await Database.openPersistent("closed-" + id);
          try { return (await db.query("SELECT count(*) FROM sqlite_schema WHERE name = 't'")).rows[0][0] === 0n; } finally { await db.close(); }
        })(),
      };
    }, id);
    assert(managed.closed && managed.closed.inUse === false && managed.closed.bytes > 0, `closed database listing ${JSON.stringify(managed.closed)}`);
    assert(managed.owned && managed.owned.inUse === true && managed.owned.bytes === undefined, `open database listing ${JSON.stringify(managed.owned)}`);
    assert(managed.never === undefined, "an empty name was listed");
    assert(managed.deleteOwned === "ZOVA_BUSY" && managed.deleteClosed === true && managed.deleteAgain === false && !managed.listedAfter && managed.reopenedEmpty, `deletion ${JSON.stringify(managed)}`);
    const ownedIntact = await other.evaluate(async () => {
      await owned.exec("CREATE TABLE IF NOT EXISTS kept(v)");
      return (await owned.query("SELECT count(*) FROM sqlite_schema WHERE name = 'kept'")).rows[0][0] === 1n;
    });
    assert(ownedIntact, "refused deletion changed the owned database");
    await other.evaluate(() => owned.close());

    // A stopped streamed import is never listed and its name reopens empty.
    const stopped = await faultedPage(context, base, { at: "write-3", stop: true, always: true });
    pages.push(stopped);
    await stopped.evaluate(async id => {
      const source = await zova.Database.createMemory();
      await source.exec("CREATE TABLE t(v); WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<200) INSERT INTO t SELECT randomblob(3000) FROM n");
      const bytes = await source.export();
      await source.close();
      const stream = new ReadableStream({ start(controller) { for (let at = 0; at < bytes.length; at += 65536) controller.enqueue(bytes.slice(at, at + 65536)); controller.close(); } });
      zova.Database.importPersistent("crashed-" + id, stream).catch(() => undefined);
    }, id);
    await stopped.waitForFunction(() => globalThis.testStopped === true);
    await stopped.close();
    const crashed = await page.evaluate(async id => {
      const listed = await h.retryBusy(() => zova.Database.listPersistent());
      const db = await h.retryBusy(() => zova.Database.openPersistent("crashed-" + id));
      try {
        return { listed: listed.some(item => item.name === "crashed-" + id), empty: (await db.query("SELECT count(*) FROM sqlite_schema WHERE name = 't'")).rows[0][0] === 0n };
      } finally { await db.close(); }
    }, id);
    assert(!crashed.listed && crashed.empty, `stopped import ${JSON.stringify(crashed)}`);

    // Streamed export into a streamed import, measuring both workers' memory.
    const measured = await context.newPage();
    pages.push(measured);
    await measured.route("**/dist/worker.mjs", async route => {
      const response = await route.fetch();
      await route.fulfill({ response, body: captureMemory + await response.text() });
    });
    await measured.goto(`${base}/failure`);
    await measured.waitForFunction(() => Boolean(globalThis.zova));
    const workers = [];
    measured.on("worker", worker => workers.push(worker));
    const source = await measured.evaluate(async ({ id, mebibytes }) => {
      globalThis.h = await import("/helpers.mjs");
      globalThis.source = await zova.Database.openPersistent("large-" + id);
      await source.exec("CREATE TABLE blobs(id INTEGER PRIMARY KEY, data BLOB)");
      for (let done = 0; done < mebibytes; done += 64) {
        await source.exec(`WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<${Math.min(64, mebibytes - done)}) INSERT INTO blobs(data) SELECT randomblob(1048576) FROM n`);
      }
      await source.putObject(h.patternBytes(200000, 9));
      return { bytes: (await source.query("SELECT page_count * page_size FROM pragma_page_count, pragma_page_size")).rows[0][0].toString() };
    }, { id, mebibytes });
    const memory = async () => Promise.all(workers.map(worker => worker.evaluate(() => globalThis.testMemory?.buffer.byteLength ?? 0).catch(() => 0)));
    const before = await memory();
    const transfer = await measured.evaluate(async id => {
      const started = performance.now();
      const copy = globalThis.copy = await zova.Database.importPersistent("copy-" + id, await source.exportStream());
      const seconds = (performance.now() - started) / 1000;
      // Compare the two files chunk by chunk without holding either whole.
      const readers = [await source.exportStream(1 << 20), await copy.exportStream(1 << 20)].map(stream => stream.getReader());
      let compared = 0;
      for (;;) {
        const [a, b] = await Promise.all(readers.map(reader => reader.read()));
        if (a.done || b.done) { if (a.done !== b.done) throw new Error("Copies differ in length"); break; }
        if (a.value.length !== b.value.length || !a.value.every((byte, index) => byte === b.value[index])) throw new Error(`Copies differ at ${compared}`);
        compared += a.value.length;
      }
      const rows = (await copy.query("SELECT count(*) FROM blobs")).rows[0][0].toString();
      return { seconds, compared, rows };
    }, id);
    const after = await memory();
    await measured.evaluate(async () => { await copy.close(); await source.close(); });
    const peak = Math.max(...after);
    const measurement = { mebibytes, storedBytes: Number(source.bytes), comparedBytes: transfer.compared, transferSeconds: +transfer.seconds.toFixed(1),
      workerMemoryBefore: before, workerMemoryAfter: after, peakWorkerMemory: peak };
    console.log("Transfer: " + JSON.stringify(measurement));
    assert(transfer.compared === Number(source.bytes) && transfer.rows === String(mebibytes), `transfer ${JSON.stringify(transfer)}`);
    // Every worker stays near its initial heap whatever the database size.
    assert(peak < 64 * (1 << 20), `worker memory reached ${peak} bytes for a ${source.bytes}-byte database`);
    return measurement;
  } finally {
    for (const page of pages) await page.close().catch(() => undefined);
  }
}
