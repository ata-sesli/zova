// Real packed-artifact checks. Injected OPFS faults are not power-loss tests.
export async function testDurability(context, base) {
  const page = await context.newPage();
  await page.addInitScript(() => {
    const NativeWorker = Worker;
    globalThis.Worker = class extends NativeWorker {
      constructor(...args) {
        super(...args);
        this.addEventListener('message', ({data}) => {
          if (data?.testWriteReached) { globalThis.crashObserved = true; this.terminate(); }
        });
      }
    };
  });
  const load = async () => {
    await page.goto(`${base}/failure`);
    await page.waitForFunction(() => Boolean(globalThis.zova));
  };
  const open = (afterTermination = false) => page.evaluate(async afterTermination => {
    const deadline = performance.now() + 5000;
    for (;;) {
      try { globalThis.db = await globalThis.zova.Database.openPersistent('durability'); return; }
      catch (error) {
        // Browser worker destruction releases locks asynchronously. Only retry
        // BUSY, only after termination, and never turn another error into success.
        if (!afterTermination || error.status !== 'ZOVA_BUSY' || performance.now() >= deadline) throw error;
        await new Promise(resolve => setTimeout(resolve, 20));
      }
    }
  }, afterTermination);
  const verify = () => page.evaluate(async () => {
    if ((await db.query('PRAGMA integrity_check')).rows[0][0] !== 'ok') throw new Error('Integrity failed');
    if ((await db.query('SELECT count(*) FROM records')).rows[0][0] !== 1n) throw new Error('Partial transaction persisted');
    if ((await db.kv.get(new Uint8Array([1]), new Uint8Array([2])))[0] !== 3) throw new Error('Committed KV lost');
  });
  try {
    await load();
    await open();
    await page.evaluate(async () => {
      const journal = (await db.query('PRAGMA journal_mode')).rows[0][0];
      const sync = (await db.query('PRAGMA synchronous')).rows[0][0];
      if (journal !== 'delete' || sync !== 2n) throw new Error(`Unexpected durability settings: ${journal}/${sync}`);
      await db.exec('CREATE TABLE records(id INTEGER PRIMARY KEY, value BLOB); INSERT INTO records VALUES(1, X\'01\')');
      await db.kv.put(new Uint8Array([1]), new Uint8Array([2]), new Uint8Array([3]));
      await db.exec('BEGIN; INSERT INTO records VALUES(2, X\'02\'); ROLLBACK');
    });
    await verify();
    // Reload without close/save: completed commits must already be durable.
    await page.reload();
    await page.waitForFunction(() => Boolean(globalThis.zova));
    await open(true);
    await verify();
    await page.evaluate(async () => {
      await db.exec('PRAGMA cache_size=8; BEGIN; WITH RECURSIVE n(x) AS (VALUES(2) UNION ALL SELECT x+1 FROM n WHERE x<1000) INSERT INTO records SELECT x, zeroblob(1024) FROM n; CREATE INDEX pending_index ON records(value)');
    });
    // Destroy the owning page/worker with an active, spilled transaction.
    await page.reload();
    await page.waitForFunction(() => Boolean(globalThis.zova));
    await open(true);
    await verify();
    await page.evaluate(async () => {
      if ((await db.query("SELECT count(*) FROM sqlite_schema WHERE name='pending_index'")).rows[0][0] !== 0n) throw new Error('Uncommitted index persisted');
      await db.close();
    });
    const crashReady = page.waitForEvent('worker');
    await open();
    const crashWorker = await crashReady;
    await crashWorker.evaluate(() => {
      const write = FileSystemSyncAccessHandle.prototype.write;
      let writes = 0;
      FileSystemSyncAccessHandle.prototype.write = function (...args) {
        const result = write.apply(this, args);
        if (++writes === 3) postMessage({testWriteReached:true});
        return result;
      };
    });
    await page.evaluate(() => {
      // Deliberately do not await: the worker is terminated after a real write.
      db.exec('PRAGMA cache_size=8; BEGIN; WITH RECURSIVE n(x) AS (VALUES(2) UNION ALL SELECT x+1 FROM n WHERE x<1000) INSERT INTO records SELECT x, zeroblob(1024) FROM n').catch(() => {});
    });
    await page.waitForFunction(() => globalThis.crashObserved === true);
    await page.reload();
    await page.waitForFunction(() => Boolean(globalThis.zova));
    await open(true);
    await verify();
    await page.evaluate(() => db.close());
    for (const [method, errorName] of [['write', 'QuotaExceededError'], ['write', 'UnknownError'], ['flush', 'UnknownError']]) {
      const ready = page.waitForEvent('worker');
      await open();
      const worker = await ready;
      await worker.evaluate(({method, errorName}) => {
        const prototype = FileSystemSyncAccessHandle.prototype;
        const original = prototype[method];
        globalThis.restoreFault = () => { prototype[method] = original; };
        prototype[method] = function () { throw new DOMException('injected storage failure', errorName); };
      }, {method, errorName});
      const rejected = await page.evaluate(async () => {
        try { await db.exec("INSERT INTO records VALUES(2, zeroblob(8192))"); return false; }
        catch (error) { return error instanceof globalThis.zova.ZovaWasmError; }
      });
      await worker.evaluate(() => globalThis.restoreFault());
      if (!rejected) throw new Error(`${method}/${errorName} silently succeeded`);
      await page.evaluate(async () => { try { await db.exec('ROLLBACK'); } catch {} await db.close(); });
      await open();
      await verify();
      await page.evaluate(() => db.close());
    }
    console.log('Durability: reload, rollback, active-transaction and write-triggered worker termination, injected quota/write/flush faults passed');
  } finally { await page.close(); }
}
