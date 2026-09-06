// Run with Bun. Uses only the explicitly supplied browser, never downloads one.
import { mkdtemp, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const [output, executable] = process.argv.slice(2);
if (!output || !executable) throw new Error("usage: bun browser-smoke.mjs <wasm-output> <browser-executable>");
const profile = await mkdtemp(join(tmpdir(), "zova-wasm-browser-"));
let browser;
let timer;
let resolveResult;
const result = new Promise(resolve => { resolveResult = resolve; });
const worker = new URL("./worker.mjs", import.meta.url);
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === "/progress" && request.method === "POST") {
      console.log(await request.text());
      return new Response("ok");
    }
    if (path === "/result" && request.method === "POST") {
      resolveResult(await request.json());
      return new Response("ok");
    }
    if (path === "/") return new Response(`<!doctype html><script type="module">
      const worker = new Worker('/worker.mjs', {type:'module'});
      const report = result => fetch('/result', {method:'POST', body:JSON.stringify(result)});
      worker.onmessage = event => {
        if (event.data.progress) { fetch('/progress', {method:'POST', body:JSON.stringify(event.data)}); return; }
        report(event.data); worker.terminate();
      };
      worker.onerror = event => report({ok:false,error:event.message});
      </script>`, { headers: { "Content-Type": "text/html" } });
    if (path === "/worker.mjs") return new Response(Bun.file(worker));
    if (path === "/zova.mjs" || path === "/zova.wasm") {
      return new Response(Bun.file(join(resolve(output), path.slice(1))));
    }
    return new Response("Not found", { status: 404 });
  },
});
try {
  browser = Bun.spawn([executable, "--headless=new", "--no-first-run", "--no-default-browser-check",
    "--disable-extensions", "--disable-background-networking",
    `--user-data-dir=${profile}`, `http://127.0.0.1:${server.port}/`], { stdout: "ignore", stderr: "inherit" });
  timer = setTimeout(() => resolveResult({ ok: false, error: "browser smoke timed out after 30s" }), 30000);
  browser.exited.then(code => resolveResult({ ok: false, error: `browser exited early: ${code}` }));
  const report = await result;
  console.log(JSON.stringify(report));
  if (!report.ok) process.exitCode = 1;
} finally {
  clearTimeout(timer);
  browser?.kill();
  if (browser) await browser.exited;
  server.stop(true);
  await rm(profile, { recursive: true, force: true });
}
