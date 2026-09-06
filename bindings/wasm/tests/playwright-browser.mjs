import { chromium } from "playwright";
import { resolve, join } from "node:path";
import { stat } from "node:fs/promises";
import { testOwnership } from "./ownership-browser.mjs";
import { testDurability } from "./durability-browser.mjs";

const [installedPackage, helium = process.env.HELIUM_EXECUTABLE] = process.argv.slice(2);
if (!installedPackage) throw new Error("usage: bun playwright-browser.mjs <installed-zova-wasm-directory> [helium-executable]");
if (!helium && process.env.CI !== "true") throw new Error("Local tests require HELIUM_EXECUTABLE pointing to installed Helium");
if (helium && !(await stat(helium)).isFile()) throw new Error("HELIUM_EXECUTABLE must name an installed Helium executable");
let resolveReport;
const report = new Promise(resolve => { resolveReport = resolve; });
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === "/result" && request.method === "POST") {
      resolveReport(await request.json()); return new Response("ok");
    }
    if (path === "/") return new Response('<script type="module" src="/test.mjs"></script>', { headers: { "Content-Type": "text/html" } });
    if (path === "/failure") return new Response('<script type="module">import * as zova from "/package/dist/index.js"; globalThis.zova = zova;</script>', { headers: { "Content-Type": "text/html" } });
    if (path === "/test.mjs") return new Response(Bun.file(new URL("./package-browser.mjs", import.meta.url)));
    if (path === "/snapshot.mjs") return new Response(`
      import init from '/package/zova.mjs';
      onmessage = async ({data}) => {
        let pool;
        try {
          const module = await init();
          const sqlite = await module.zovaOpfsBootstrap();
          pool = await sqlite.installOpfsSAHPoolVfs({directory:'.zova-' + data,initialCapacity:6});
          const bytes = pool.exportFile('/db.zova');
          const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
          pool.pauseVfs();
          postMessage({hash});
        } catch(error) { pool?.pauseVfs(); postMessage({error:String(error)}); }
      };`, {headers:{"Content-Type":"text/javascript"}});
    if (/^\/package\/(?:dist\/[a-z-]+\.(?:js|mjs)|zova\.(?:mjs|wasm))$/.test(path)) {
      return new Response(Bun.file(join(resolve(installedPackage), path.slice(9))));
    }
    return new Response("Not found", { status: 404 });
  },
});
let browser;
let deadline;
try {
  // Local runs use Helium; CI uses Playwright's bundled Chromium.
  browser = await chromium.launch({ ...(helium ? { executablePath: resolve(helium) } : {}), headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();
  page.on("pageerror", error => resolveReport({ ok: false, error: error.message }));
  deadline = setTimeout(() => resolveReport({ ok: false, error: "Browser test timed out" }), 30000);
  const base = `http://127.0.0.1:${server.port}`;
  await page.goto(base);
  const result = await report;
  if (!result.ok) throw new Error(JSON.stringify(result));
  clearTimeout(deadline);

  // Test actual worker initialization failure from the installed artifact.
  const failedPage = await context.newPage();
  await failedPage.route("**/dist/worker.mjs", route => route.abort());
  await failedPage.goto(`${base}/failure`);
  await failedPage.waitForFunction(() => Boolean(globalThis.zova));
  const initializationFailed = await failedPage.evaluate(async () => {
    try { await globalThis.zova.Database.createMemory(); return false; }
    catch (error) { return error instanceof globalThis.zova.ZovaWasmError; }
  });
  if (!initializationFailed) throw new Error("Worker initialization failure was not typed");

  const failurePage = await context.newPage();
  await failurePage.goto(`${base}/failure`);
  await failurePage.waitForFunction(() => Boolean(globalThis.zova));
  const workerReady = failurePage.waitForEvent("worker");
  await failurePage.evaluate(async () => { globalThis.db = await globalThis.zova.Database.createMemory(); });
  const worker = await workerReady;
  await worker.evaluate(() => { setTimeout(() => { throw new Error("intentional worker fault"); }, 0); });
  await failurePage.waitForFunction(() => globalThis.db.closed);
  const runtimeFailed = await failurePage.evaluate(async () => {
    try { await globalThis.db.query("SELECT 1"); return false; }
    catch (error) { return error instanceof globalThis.zova.ZovaWasmError; }
  });
  if (!runtimeFailed) throw new Error("Worker runtime failure was not typed");
  const persistencePage = await context.newPage();
  await persistencePage.goto(`${base}/failure`);
  await persistencePage.waitForFunction(() => Boolean(globalThis.zova));
  await persistencePage.evaluate(async () => {
    const snapshot = name => new Promise((resolve, reject) => {
      const worker = new Worker('/snapshot.mjs', {type:'module'});
      worker.onmessage = ({data}) => { worker.terminate(); data.error ? reject(new Error(data.error)) : resolve(JSON.stringify(data.hash)); };
      worker.onerror = event => { worker.terminate(); reject(new Error(event.message)); };
      worker.postMessage(name);
    });
    for (const sql of ["UPDATE _zova_meta SET value='10' WHERE key='format_version'", "UPDATE _zova_meta SET value='999' WHERE key='format_version'", "DROP TABLE _zova_meta"]) {
      const name = 'reject-' + crypto.randomUUID();
      const db = await globalThis.zova.Database.openPersistent(name);
      await db.exec(sql);
      await db.close();
      const before = await snapshot(name);
      for (let attempt = 0; attempt < 2; attempt++) {
        let rejected = false;
        try { const unexpected = await globalThis.zova.Database.openPersistent(name); await unexpected.close(); }
        catch(error) { rejected = error instanceof globalThis.zova.ZovaWasmError; }
        if (!rejected) throw new Error('Invalid format/schema accepted');
        if (before !== await snapshot(name)) throw new Error('Failed open changed stored database');
      }
    }
  });
  const unavailablePage = await context.newPage();
  await unavailablePage.route('**/dist/worker.mjs', async route => {
    const response = await route.fetch();
    await route.fulfill({response, body:'Object.defineProperty(navigator, "storage", {value:undefined});\n' + await response.text()});
  });
  await unavailablePage.goto(`${base}/failure`);
  await unavailablePage.waitForFunction(() => Boolean(globalThis.zova));
  const unavailable = await unavailablePage.evaluate(async () => {
    try { await globalThis.zova.Database.openPersistent('unavailable'); return false; }
    catch(error) { return error instanceof globalThis.zova.ZovaWasmError && error.status === 'ZOVA_CANT_OPEN'; }
  });
  if (!unavailable) throw new Error('Missing OPFS did not reject without fallback');
  const preservedName = 'preserve-' + Date.now();
  await persistencePage.evaluate(async name => {
    const db = await globalThis.zova.Database.openPersistent(name);
    await db.exec('CREATE TABLE kept(value); INSERT INTO kept VALUES(17)');
    await db.close();
  }, preservedName);
  const acquisitionPage = await context.newPage();
  await acquisitionPage.route('**/dist/worker.mjs', async route => {
    const response = await route.fetch();
    await route.fulfill({response, body:'FileSystemFileHandle.prototype.createSyncAccessHandle = async () => { throw new Error("injected acquisition failure"); };\n' + await response.text()});
  });
  await acquisitionPage.goto(`${base}/failure`);
  await acquisitionPage.waitForFunction(() => Boolean(globalThis.zova));
  const acquisitionFailed = await acquisitionPage.evaluate(async name => {
    try { await globalThis.zova.Database.openPersistent(name); return false; }
    catch { return true; }
  }, preservedName);
  if (!acquisitionFailed) throw new Error('Injected acquisition unexpectedly succeeded');
  await persistencePage.evaluate(async name => {
    const db = await globalThis.zova.Database.openPersistent(name);
    try {
      if ((await db.query('SELECT value FROM kept')).rows[0][0] !== 17n) throw new Error('Pool initialization failure lost data');
    } finally { await db.close(); }
  }, preservedName);
  const wasmBytes = (await stat(join(installedPackage, "zova.wasm"))).size;
  await testDurability(context, base);
  await testOwnership(browser, base);
  console.log(JSON.stringify({ ...result, initializationFailure: true, runtimeFailure: true,
    persistentReopen: true, rejectedOpenPreservesBytes: true, missingOpfs: true,
    poolInitializationFailurePreservesData: true, exclusiveOwnership: true,
    durabilityAndInjectedStorageFaults: true, wasmBytes }));
} finally {
  clearTimeout(deadline);
  await browser?.close();
  server.stop(true);
}
