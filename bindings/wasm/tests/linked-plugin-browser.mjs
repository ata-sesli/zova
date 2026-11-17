// Checks a module built with a statically linked plugin (#221):
//   ZOVA_WASM_PLUGIN_SOURCES=tests/plugin_fixture.c:bindings/wasm/tests/linked-plugin.c \
//     sh bindings/wasm/tools/build-package.sh <out>
//   bun bindings/wasm/tests/linked-plugin-browser.mjs <out>/package
import { chromium } from "playwright";
import { join, resolve } from "node:path";

const [packageDirectory, helium = process.env.HELIUM_EXECUTABLE] = process.argv.slice(2);
if (!packageDirectory) throw new Error("usage: bun linked-plugin-browser.mjs <package-directory>");
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === "/") return new Response('<script type="module">import * as zova from "/package/dist/index.js"; globalThis.zova = zova;</script>', { headers: { "Content-Type": "text/html" } });
    if (path === "/helpers.mjs") return new Response(Bun.file(new URL("./browser-helpers.mjs", import.meta.url)), { headers: { "Content-Type": "text/javascript" } });
    if (path === "/extension-missing.zova") return new Response(Bun.file(new URL("./extension-missing.zova", import.meta.url)));
    if (path === "/seed.mjs") return new Response(`
      import init from '/package/zova.mjs';
      onmessage = async ({data}) => {
        let pool;
        try {
          const sqlite = await (await init()).zovaOpfsBootstrap();
          pool = await sqlite.installOpfsSAHPoolVfs({directory:'.zova-' + data.name,initialCapacity:6});
          pool.importDb('/db.zova', data.bytes);
          pool.pauseVfs();
          postMessage({});
        } catch(error) { pool?.pauseVfs(); postMessage({error:String(error)}); }
      };`, { headers: { "Content-Type": "text/javascript" } });
    if (/^\/package\/(?:dist\/[a-z-]+\.(?:js|mjs)|zova\.(?:mjs|wasm))$/.test(path)) return new Response(Bun.file(join(resolve(packageDirectory), path.slice(9))));
    return new Response("Not found", { status: 404 });
  },
});
const browser = await chromium.launch({ ...(helium ? { executablePath: resolve(helium) } : {}), headless: true });
try {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.port}/`);
  await page.waitForFunction(() => Boolean(globalThis.zova));
  const result = await page.evaluate(async () => {
    const h = await import("/helpers.mjs");
    const { Database } = zova;
    const out = {};
    const memory = await Database.createMemory();
    await memory.installExtension("c_test");
    out.memoryList = (await memory.listExtensions()).map(item => item.name);
    await memory.checkExtension("c_test");
    await memory.dropExtension("c_test");
    await memory.close();
    const name = "plugin-" + crypto.randomUUID();
    let db = await Database.openPersistent(name);
    await db.installExtension("c_test");
    await db.close();
    db = await Database.openPersistent(name);
    out.reopened = (await db.listExtensions()).map(item => item.name);
    await db.checkExtensions();
    const exported = await db.export();
    await db.close();
    // The native fixture database opens here, and imports pass verification.
    const seeded = "native-plugin-" + crypto.randomUUID();
    await h.seed(seeded, await h.fetchBytes("/extension-missing.zova"));
    const native = await Database.openPersistent(seeded);
    out.native = (await native.listExtensions()).map(item => item.name);
    await native.close();
    const imported = await Database.importPersistent("imported-" + crypto.randomUUID(), exported);
    out.imported = (await imported.listExtensions()).map(item => item.name);
    await imported.close();
    return out;
  });
  const ok = result.memoryList.join() === "c_test" && result.reopened.join() === "c_test" && result.native.join() === "c_test" && result.imported.join() === "c_test";
  console.log("Linked plugin: " + JSON.stringify(result));
  if (!ok) throw new Error("Linked plugin checks failed");
} finally {
  await browser.close();
  server.stop(true);
}
