// Reclaim, vacuum, backup, compact and restore of persistent databases (#219).
import { faultedPage } from "./fault-script.mjs";

export async function testMaintenance(context, base) {
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
    const page = await plain();
    const result = await page.evaluate(async () => {
      const { Database } = zova;
      const out = {};
      const missing = async name => (await h.status(Database.probePersistent(name))) !== "ok";
      const fill = async db => {
        await db.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, body BLOB)");
        await db.exec("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1500) INSERT INTO t SELECT x, randomblob(4000) FROM n");
        await db.kv.put(new Uint8Array([1]), new Uint8Array([2]), new Uint8Array([3]));
        await db.putObject(h.patternBytes(300000, 5));
        await db.createVectorCollection("v", { dimensions: 2, metric: "l2", elementType: "f32" });
        await db.putVectors("v", [{ id: "a", values: new Float32Array([1, 2]) }]);
        await db.createGraph("g");
        await db.putGraphNodes([{ graphName: "g", nodeId: "n", kind: "k", targetType: "none" }]);
      };
      // Reclaim lowers the stored file size after most data is deleted.
      const id = crypto.randomUUID();
      const db = await Database.openPersistent("source-" + id);
      await fill(db);
      const full = (await db.export()).length;
      await db.exec("DELETE FROM t WHERE id > 100");
      const reclaimed = await db.reclaimSpace();
      const after = (await db.export()).length;
      out.reclaim = { full, after, reclaimed };
      await db.vacuum();
      // Backup and compact publish verified, independent copies.
      const events = { backup: [], compact: [] };
      await db.backupTo("backup-" + id, { progress: event => events.backup.push(event) });
      await db.compactTo("compact-" + id, { progress: event => events.compact.push(event) });
      out.events = events;
      const sourceRows = await h.dump(db);
      for (const kind of ["backup", "compact"]) {
        const copy = await Database.openPersistent(`${kind}-${id}`);
        out[kind] = { same: await h.dump(copy) === sourceRows, integrity: (await copy.query("PRAGMA integrity_check")).rows[0][0],
          size: (await copy.export()).length, summary: await h.summary(copy) === await h.summary(db) };
        await copy.exec("INSERT INTO t VALUES (99999, NULL)");
        await copy.close();
      }
      out.independent = (await db.query("SELECT count(*) FROM t WHERE id = 99999")).rows[0][0] === 0n;
      out.exists = [await h.status(db.backupTo("backup-" + id)), await h.status(db.backupTo("source-" + id))];
      const owner = await Database.openPersistent("owned-" + id);
      out.busy = await h.status(db.backupTo("owned-" + id));
      await owner.close();
      // Cancelling at each phase leaves no target; publication completes.
      out.cancel = {};
      for (const phase of ["copy", "verify", "publish"]) {
        const controller = new AbortController();
        const name = `cancel-${phase}-${id}`;
        out.cancel[phase] = { status: await h.status(db.backupTo(name, { signal: controller.signal, progress: event => { if (event.phase === phase) controller.abort(); } })), missing: await missing(name) };
      }
      out.cancel.pre = { status: await h.status(db.backupTo("pre-" + id, { signal: AbortSignal.abort() })), missing: await missing("pre-" + id) };
      let thrown;
      try { await db.compactTo("thrown-" + id, { progress: () => { throw new RangeError("stop"); } }); } catch (error) { thrown = error; }
      out.cancel.thrown = { rangeError: thrown instanceof RangeError, missing: await missing("thrown-" + id) };
      out.afterCancel = await h.status(db.backupTo("later-" + id));
      await db.close();
      // Restore to a new name and into memory.
      await Database.restoreBackup("backup-" + id, "restored-" + id);
      const restored = await Database.openPersistent("restored-" + id);
      out.restored = (await restored.query("SELECT count(*) FROM t WHERE id = 99999")).rows[0][0] === 1n;
      await restored.close();
      out.restoreMissing = await h.status(Database.restoreBackup("absent-" + id, "nothing-" + id));
      const memory = await Database.restoreBackupToMemory("backup-" + id);
      const reopened = await Database.openPersistent("backup-" + id);
      out.memory = { rows: (await memory.query("SELECT count(*) FROM t")).rows[0][0], sourceReleased: true, exportStatus: await h.status(memory.export()),
        copyStatus: await h.status(memory.backupTo("frommemory-" + id)) };
      await reopened.close();
      await memory.close();
      out.memoryMissing = await h.status(Database.restoreBackupToMemory("absent-" + id));
      out.id = id;
      return out;
    });
    const { reclaim, events } = result;
    assert(reclaim.reclaimed[0].member === "main" && reclaim.reclaimed[0].autoVacuum === "incremental" && reclaim.reclaimed[0].pagesReleased > 0, `reclaim result ${JSON.stringify(reclaim.reclaimed)}`);
    assert(reclaim.after < reclaim.full / 2, `reclaim did not shrink the stored file: ${reclaim.full} -> ${reclaim.after}`);
    for (const kind of ["backup", "compact"]) {
      assert(result[kind].same && result[kind].summary && result[kind].integrity === "ok", `${kind} copy differs from its source`);
      const seen = new Map();
      for (const event of events[kind]) {
        const key = event.phase + "/" + event.member;
        const last = seen.get(key);
        assert(event.done <= event.total && (!last || (event.done >= last.done && event.total === last.total)), `${kind}: bad progress ${JSON.stringify(event)}`);
        seen.set(key, event);
      }
      for (const key of ["copy/main", "verify/null", "publish/null"]) assert(seen.get(key)?.done === seen.get(key)?.total, `${kind}: missing ${key}`);
    }
    assert(result.independent, "copy shares storage with its source");
    assert(result.exists.every(status => status === "ZOVA_DESTINATION_EXISTS"), `existing target: ${result.exists}`);
    assert(result.busy === "ZOVA_BUSY", `owned target: ${result.busy}`);
    for (const phase of ["copy", "verify", "pre"]) assert(result.cancel[phase].status === "ZOVA_INTERRUPTED" && result.cancel[phase].missing, `cancel at ${phase}: ${JSON.stringify(result.cancel[phase])}`);
    assert(result.cancel.publish.status === "ok" && !result.cancel.publish.missing, `cancel during publish: ${JSON.stringify(result.cancel.publish)}`);
    assert(result.cancel.thrown.rangeError && result.cancel.thrown.missing, "throwing progress");
    assert(result.afterCancel === "ok", "copy after cancellations");
    assert(result.restored && result.restoreMissing === "ZOVA_NOT_ZOVA_DATABASE", `restore ${result.restored} ${result.restoreMissing}`);
    assert(result.memory.rows === 101n && result.memory.exportStatus === "ok" && result.memory.copyStatus === "ZOVA_INVALID_ARGUMENT" && result.memoryMissing === "ZOVA_NOT_ZOVA_DATABASE", `restore to memory ${JSON.stringify(result.memory, (_, value) => typeof value === "bigint" ? String(value) : value)} ${result.memoryMissing}`);

    // A worker stopped while publishing leaves no partial target.
    const stops = {};
    for (const at of ["publish-0", "write-1", "write-40", "write-200"]) {
      const name = `stopped-${at}-${Date.now()}`;
      const stopped = await faultedPage(context, base, { at, stop: true });
      pages.push(stopped);
      await stopped.evaluate(async name => {
        const db = await zova.Database.openPersistent("stopsource-" + name);
        await db.exec("CREATE TABLE IF NOT EXISTS t(v); WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<300) INSERT INTO t SELECT randomblob(2000) FROM n");
        db.backupTo(name).catch(() => undefined);
      }, name);
      await stopped.waitForFunction(() => globalThis.testStopped === true);
      await stopped.close();
      stops[at] = await page.evaluate(async name => {
        const source = await h.retryBusy(() => zova.Database.openPersistent("stopsource-" + name));
        const sourceRows = (await source.query("SELECT count(*) FROM t")).rows[0][0];
        await source.close();
        const target = await zova.Database.openPersistent(name);
        const tables = (await target.query("SELECT count(*) FROM sqlite_schema WHERE name = 't'")).rows[0][0];
        await target.close();
        return { sourceRows: String(sourceRows), targetHasData: tables !== 0n };
      }, name);
      assert(stops[at].sourceRows === "300" && !stops[at].targetHasData, `${at}: ${JSON.stringify(stops[at])}`);
    }
    console.log(`Maintenance: reclaim ${reclaim.full} -> ${reclaim.after} bytes, backup/compact verified and independent, cancellation at copy/verify, stops ${Object.keys(stops).join(",")} left no target, restore passed`);
  } finally {
    for (const page of pages) await page.close().catch(() => undefined);
  }
}
