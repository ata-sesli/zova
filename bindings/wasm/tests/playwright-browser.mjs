import { chromium } from "playwright";
import { resolve, join } from "node:path";
import { stat } from "node:fs/promises";

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
  const page = await browser.newPage();
  page.on("pageerror", error => resolveReport({ ok: false, error: error.message }));
  deadline = setTimeout(() => resolveReport({ ok: false, error: "Browser test timed out" }), 30000);
  const base = `http://127.0.0.1:${server.port}`;
  await page.goto(base);
  const result = await report;
  if (!result.ok) throw new Error(JSON.stringify(result));
  clearTimeout(deadline);

  // Test actual worker initialization failure from the installed artifact.
  const failedPage = await browser.newPage();
  await failedPage.route("**/dist/worker.mjs", route => route.abort());
  await failedPage.goto(`${base}/failure`);
  await failedPage.waitForFunction(() => Boolean(globalThis.zova));
  const initializationFailed = await failedPage.evaluate(async () => {
    try { await globalThis.zova.Database.createMemory(); return false; }
    catch (error) { return error instanceof globalThis.zova.ZovaWasmError; }
  });
  if (!initializationFailed) throw new Error("Worker initialization failure was not typed");

  const failurePage = await browser.newPage();
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
  const wasmBytes = (await stat(join(installedPackage, "zova.wasm"))).size;
  console.log(JSON.stringify({ ...result, initializationFailure: true, runtimeFailure: true, wasmBytes }));
} finally {
  clearTimeout(deadline);
  await browser?.close();
  server.stop(true);
}
