// In-place migration of persistent browser databases (#215), checked against
// native CLI migration of the same retained fixtures.

// Prepended to the packed worker. `at` stops the worker at a publication step
// ("publish-0" before replacing, "publish-1" after the commit) or at the nth
// storage write after replacement starts ("write-n"). With `stop` the page
// terminates the worker there; without it the worker stays stopped and keeps
// its lock. `count` reports the replacement's write count.
const faultScript = config => `
  const testConfig = ${JSON.stringify(config)};
  const testPost = self.postMessage.bind(self);
  let testPublishing = false;
  let testWrites = 0;
  const testStop = () => { if (testConfig.stop) testPost({ testStop: true }); for (;;) {} };
  if (testConfig.estimate) navigator.storage.estimate = async () => testConfig.estimate;
  self.postMessage = (message, ...rest) => {
    testPost(message, ...rest);
    const event = message?.progress;
    if (event?.phase !== "publish") return;
    if (event.done === 0) testPublishing = true;
    if (event.done === 1 && testConfig.count) testPost({ testWrites });
    if (testConfig.at === "publish-" + event.done) testStop();
  };
  const testWrite = FileSystemSyncAccessHandle.prototype.write;
  FileSystemSyncAccessHandle.prototype.write = function (...args) {
    const result = testWrite.apply(this, args);
    if (testPublishing && testConfig.at === "write-" + ++testWrites) testStop();
    return result;
  };
`;

export async function testMigration(context, base, formats) {
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const pages = [];
  const open = async (path = "/failure") => {
    const page = await context.newPage();
    pages.push(page);
    await page.goto(base + path);
    await page.waitForFunction(() => Boolean(globalThis.zova ?? globalThis.previous));
    await page.evaluate(async () => { globalThis.h = await import("/helpers.mjs"); });
    return page;
  };
  const faulted = async config => {
    const page = await context.newPage();
    pages.push(page);
    await page.addInitScript(() => {
      const NativeWorker = Worker;
      globalThis.Worker = class extends NativeWorker {
        constructor(...args) {
          super(...args);
          this.addEventListener("message", ({ data }) => {
            if (data?.testStop) { this.terminate(); globalThis.testStopped = true; }
            if (data?.testWrites !== undefined) globalThis.testWrites = data.testWrites;
          });
        }
      };
    });
    await page.route("**/dist/worker.mjs", async route => {
      const response = await route.fetch();
      await route.fulfill({ response, body: faultScript(config) + await response.text() });
    });
    await page.goto(`${base}/failure`);
    await page.waitForFunction(() => Boolean(globalThis.zova));
    return page;
  };
  try {
    const page = await open();
    const seed = (name, format = 12) => page.evaluate(async ({ name, format }) =>
      h.seed(name, await h.fetchBytes(`/fixtures/${typeof format === "number" ? `format-${format}` : format}.zova`)), { name, format });
    const nativeDumps = {};

    // Retained fixtures migrate in place and match native migration.
    for (const format of formats) {
      const result = await page.evaluate(async format => {
        const { Database } = zova;
        const name = `fixture-${format}-${crypto.randomUUID()}`;
        await h.seed(name, await h.fetchBytes(`/fixtures/format-${format}.zova`));
        const openStatus = await h.status(Database.openPersistent(name));
        const before = await Database.probePersistent(name);
        const events = [];
        await Database.migratePersistent(name, { progress: event => events.push(event) });
        const after = await Database.probePersistent(name);
        const db = await Database.openPersistent(name);
        const migrated = [await h.dump(db), await h.summary(db)];
        await db.close();
        const nativeName = `native-${format}-${crypto.randomUUID()}`;
        const native = await Database.importPersistent(nativeName, await h.fetchBytes(`/native/format-${format}.zova`));
        const expected = [await h.dump(native), await h.summary(native)];
        await native.close();
        const repeatEvents = [];
        await Database.migratePersistent(name, { progress: event => repeatEvents.push(event) });
        const firstDifference = migrated[0].split("\n").find((line, index) => line !== expected[0].split("\n")[index]);
        return { openStatus, before, after, events, repeatEvents, sameRows: migrated[0] === expected[0],
          sameApi: migrated[1] === expected[1], firstDifference, summary: migrated[1], nativeDump: expected[0] };
      }, format);
      assert(result.openStatus === "ZOVA_MIGRATION_REQUIRED", `format ${format}: open did not refuse: ${result.openStatus}`);
      assert(result.before.formatVersion === format && result.before.compatibility === "migratable", `format ${format}: probe ${JSON.stringify(result.before)}`);
      assert(result.after.formatVersion === 13 && result.after.compatibility === "current", `format ${format}: after ${JSON.stringify(result.after)}`);
      assert(result.sameRows, `format ${format}: rows differ from native migration at ${result.firstDifference}`);
      assert(result.sameApi, `format ${format}: API reads differ from native migration`);
      assert(JSON.parse(result.summary).objects.length > 0 && JSON.parse(result.summary).vectors.length > 0 && JSON.parse(result.summary).graphs.length > 0, "fixture contents missing");
      assert(result.repeatEvents.length === 0, "migrating a current database reported work");
      const seen = new Map();
      for (const event of result.events) {
        const key = event.phase + "/" + event.member;
        const last = seen.get(key);
        assert(event.done <= event.total && (!last || (event.done >= last.done && event.total === last.total)), `bad progress ${JSON.stringify(event)}`);
        seen.set(key, event);
      }
      for (const key of ["copy/main", "migrate/main", "verify/null", "publish/null"]) {
        assert(seen.has(key) && seen.get(key).done === seen.get(key).total, `missing or unfinished progress ${key}`);
      }
      nativeDumps[format] = result.nativeDump;
    }

    // A database written by the published previous package.
    const previous = await open("/previous");
    const legacyName = "legacy-" + Date.now();
    await previous.evaluate(async name => {
      const db = await previous.Database.openPersistent(name);
      await db.exec("CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes VALUES (1, 'kept')");
      await db.kv.put(new Uint8Array([1]), new Uint8Array([2]), new Uint8Array([3, 4]));
      globalThis.objectId = await db.putObject(new TextEncoder().encode("legacy object"));
      await db.createVectorCollection("docs", { dimensions: 2, metric: "cosine", elementType: "f32" });
      await db.putVectors("docs", [{ id: "a", values: new Float32Array([1, 0]) }, { id: "b", values: new Float32Array([0, 1]) }]);
      await db.createGraph("g");
      await db.putGraphNodes([{ graphName: "g", nodeId: "x", kind: "k", targetType: "none" }, { graphName: "g", nodeId: "y", kind: "k", targetType: "none" }]);
      await db.putGraphEdges([{ graphName: "g", fromNodeId: "x", edgeType: "e", toNodeId: "y" }]);
      await db.close();
    }, legacyName);
    const objectId = await previous.evaluate(() => Array.from(globalThis.objectId));
    await previous.close();
    const legacy = await page.evaluate(async ({ name, objectId }) => {
      const { Database } = zova;
      const before = await Database.probePersistent(name);
      await Database.migratePersistent(name);
      const db = await Database.openPersistent(name);
      try {
        return {
          before,
          note: (await db.query("SELECT body FROM notes WHERE id = 1")).rows[0][0],
          kv: Array.from(await db.kv.get(new Uint8Array([1]), new Uint8Array([2]))),
          object: new TextDecoder().decode(await db.getObject(new Uint8Array(objectId))),
          search: (await db.searchVectors("docs", new Float32Array([1, 0.1]), 1))[0].id,
          walk: (await db.graphWalk({ graphName: "g", startNodeId: "x", maxDepth: 1, limit: 5 })).map(item => item.nodeId).join(),
          integrity: (await db.query("PRAGMA integrity_check")).rows[0][0],
        };
      } finally { await db.close(); }
    }, { name: legacyName, objectId });
    assert(legacy.before.formatVersion === 12 && legacy.before.compatibility === "migratable", `previous package probe ${JSON.stringify(legacy.before)}`);
    assert(legacy.note === "kept" && legacy.kv.join() === "3,4" && legacy.object === "legacy object" && legacy.search === "a" &&
      legacy.walk === "x,y" && legacy.integrity === "ok", `previous package contents ${JSON.stringify(legacy)}`);

    // Stopping the worker at each publication step leaves the original or the
    // migrated database; the next call reopens or resumes.
    const fixtureHash = await page.evaluate(async () => h.sha256(await h.fetchBytes("/fixtures/format-12.zova")));
    const outcome = async name => page.evaluate(async ({ name, fixtureHash }) => {
      const { Database } = zova;
      const info = await h.retryBusy(() => Database.probePersistent(name));
      const original = info.formatVersion === 12 && await h.snapshot(name) === fixtureHash;
      if (info.formatVersion === 12) await Database.migratePersistent(name);
      const db = await Database.openPersistent(name);
      try { return { info, original, rows: await h.dump(db) }; } finally { await db.close(); }
    }, { name, fixtureHash });
    const calibrate = await faulted({ count: true });
    const calibrationName = "calibrate-" + Date.now();
    await seed(calibrationName);
    await calibrate.evaluate(name => zova.Database.migratePersistent(name), calibrationName);
    const writes = await calibrate.evaluate(() => globalThis.testWrites);
    assert(writes > 4, `replacement wrote ${writes} times`);
    const stops = ["publish-0", ...new Set([1, Math.ceil(writes / 4), Math.ceil(writes / 2), Math.ceil(writes * 3 / 4), writes].map(n => "write-" + n)), "publish-1"];
    const stopOutcomes = {};
    for (const at of stops) {
      const name = `stop-${at}-${Date.now()}`;
      await seed(name);
      const stopped = await faulted({ at, stop: true });
      await stopped.evaluate(name => { zova.Database.migratePersistent(name).catch(() => undefined); }, name);
      await stopped.waitForFunction(() => globalThis.testStopped === true);
      await stopped.close();
      const result = await outcome(name);
      const state = result.info.formatVersion === 13 ? "migrated" : result.original ? "original" : "neither";
      assert(state !== "neither", `${at}: stored database is neither the original nor migrated`);
      assert(result.rows === nativeDumps[12], `${at}: resumed migration differs from native`);
      if (at === "publish-0") assert(state === "original", "stop before replacement changed the database");
      if (at === "publish-1") assert(state === "migrated", "stop after commit lost the migration");
      stopOutcomes[at] = state;
    }

    // A second tab gets ZOVA_BUSY while a migration owns the database.
    const busyName = "busy-" + Date.now();
    await seed(busyName);
    const holder = await faulted({ at: "publish-0" });
    await holder.evaluate(name => {
      zova.Database.migratePersistent(name, { progress: event => { if (event.phase === "publish") globalThis.held = true; } }).catch(() => undefined);
    }, busyName);
    await holder.waitForFunction(() => globalThis.held === true);
    const busy = await page.evaluate(async name => [
      await h.status(zova.Database.openPersistent(name)),
      await h.status(zova.Database.migratePersistent(name)),
      await h.status(zova.Database.probePersistent(name)),
    ], busyName);
    assert(busy.every(status => status === "ZOVA_BUSY"), `second tab during migration: ${busy}`);
    await holder.close();
    assert((await outcome(busyName)).rows === nativeDumps[12], "migration after a stopped owner differs from native");

    // Cancellation leaves the source unchanged; a started replacement completes.
    const cancelled = await page.evaluate(async fixtureHash => {
      const { Database } = zova;
      const results = {};
      const run = async (label, options) => {
        const name = `${label}-${crypto.randomUUID()}`;
        await h.seed(name, await h.fetchBytes("/fixtures/format-12.zova"));
        let error;
        try { await Database.migratePersistent(name, options(name)); } catch (caught) { error = caught; }
        const info = await h.retryBusy(() => Database.probePersistent(name));
        results[label] = { status: error?.status, thrown: error instanceof RangeError, format: info.formatVersion,
          unchanged: await h.snapshot(name) === fixtureHash, typed: error === undefined || error instanceof zova.ZovaWasmError || error instanceof RangeError };
      };
      await run("pre-aborted", () => ({ signal: AbortSignal.abort() }));
      await run("abort-copy", () => {
        const controller = new AbortController();
        return { signal: controller.signal, progress: event => { if (event.phase === "copy") controller.abort(); } };
      });
      await run("abort-verify", () => {
        const controller = new AbortController();
        return { signal: controller.signal, progress: event => { if (event.phase === "verify") controller.abort(); } };
      });
      await run("throwing-progress", () => ({ progress: () => { throw new RangeError("stop"); } }));
      await run("abort-publish", () => {
        const controller = new AbortController();
        return { signal: controller.signal, progress: event => { if (event.phase === "publish") controller.abort(); } };
      });
      return results;
    }, fixtureHash);
    for (const label of ["pre-aborted", "abort-copy", "abort-verify"]) {
      const result = cancelled[label];
      assert(result.status === "ZOVA_INTERRUPTED" && result.format === 12 && result.unchanged, `${label}: ${JSON.stringify(result)}`);
    }
    assert(cancelled["throwing-progress"].thrown && cancelled["throwing-progress"].unchanged, `throwing progress: ${JSON.stringify(cancelled["throwing-progress"])}`);
    assert(cancelled["abort-publish"].status === undefined && cancelled["abort-publish"].format === 13, `abort after publication started: ${JSON.stringify(cancelled["abort-publish"])}`);

    // Too little origin storage fails before copying; bound sets are out of scope.
    const spaceName = "space-" + Date.now();
    await seed(spaceName);
    const small = await faulted({ estimate: { quota: 4096, usage: 0 } });
    const space = await small.evaluate(async name => {
      try { await zova.Database.migratePersistent(name); return "migrated"; }
      catch (error) { return error.status + ": " + error.message; }
    }, spaceName);
    await small.close();
    assert(/^ZOVA_CANT_OPEN: Migration needs \d+ free bytes/.test(space), `space check: ${space}`);
    const bound = await page.evaluate(async fixtureHash => {
      const name = "bound-" + crypto.randomUUID();
      await h.seed(name, await h.fetchBytes("/fixtures/bound-main-format-12.zova"));
      const status = await h.status(zova.Database.migratePersistent(name));
      return { status, format: (await zova.Database.probePersistent(name)).formatVersion };
    });
    assert(bound.status === "ZOVA_BOUND_STORE_INVALID" && bound.format === 12, `bound set: ${JSON.stringify(bound)}`);
    assert(await page.evaluate(async ({ name, fixtureHash }) => await h.snapshot(name) === fixtureHash, { name: spaceName, fixtureHash }), "space failure changed the source");

    console.log(`Migration: formats ${formats.join(", ")} match native, previous package migrated, stops ${JSON.stringify(stopOutcomes)}, busy, cancellation and space checks passed`);
  } finally {
    for (const page of pages) await page.close().catch(() => undefined);
  }
}
