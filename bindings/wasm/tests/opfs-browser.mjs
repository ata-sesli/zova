import { chromium } from "playwright";
import { resolve } from "node:path";
const [directory] = process.argv.slice(2);
const helium = process.env.HELIUM_EXECUTABLE;
if (!directory || (!helium && process.env.CI !== "true")) throw new Error("Set HELIUM_EXECUTABLE for local tests and supply the spike output directory");
const worker = `import init from '/zova.mjs';
onmessage = async ({data}) => {
  try {
    const module = await init();
    const sqlite = await module.zovaOpfsBootstrap();
    await sqlite.installOpfsSAHPoolVfs({directory:data.directory,initialCapacity:6});
    const vfs = sqlite.capi.sqlite3_vfs_find('opfs-sahpool');
    if (!vfs) throw new Error('OPFS VFS missing');
    if (sqlite.capi.sqlite3_vfs_register(vfs,1)) throw new Error('Cannot select OPFS');
    if (module._zova_wasm_smoke() !== 0n) throw new Error('Memory lifecycle regression');
    if (data.phase === -1) { postMessage({ok:true}); return; }
    const status = module._zova_opfs_smoke(data.phase);
    if(status !== 0) throw new Error('Zova persistence failed: status ' + status);
    postMessage({ok:true});
  } catch(e) { postMessage({ok:false,error:String(e)}); }
};`;
const server = Bun.serve({hostname:"127.0.0.1",port:0,fetch(request) {
  const path = new URL(request.url).pathname;
  if(path === '/') return new Response('<!doctype html><title>OPFS spike</title>',{headers:{'Content-Type':'text/html'}});
  if(path === '/worker.mjs') return new Response(worker,{headers:{'Content-Type':'text/javascript'}});
  if(path === '/zova.mjs' || path === '/zova.wasm') return new Response(Bun.file(resolve(directory,path.slice(1))));
  return new Response('Not found',{status:404});
}});
let browser;
try {
  browser = await chromium.launch({headless:true,...(helium ? {executablePath:helium} : {})});
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.port}`);
  const ownershipError = await page.evaluate(async () => {
    const directory = '/zova-spike-' + crypto.randomUUID();
    for(const phase of [1,0,2,0]) {
      await new Promise((resolve,reject) => {
        const worker = new Worker('/worker.mjs',{type:'module'});
        const timer=setTimeout(()=>{worker.terminate();reject(new Error('OPFS timeout'));},15000);
        worker.onmessage=({data})=>{clearTimeout(timer);worker.terminate();data.ok?resolve():reject(new Error(data.error));};
        worker.onerror=event=>{clearTimeout(timer);worker.terminate();reject(new Error(event.message));};
        worker.postMessage({phase,directory});
      });
    }
    const owner = new Worker('/worker.mjs',{type:'module'});
    const contender = new Worker('/worker.mjs',{type:'module'});
    const request = worker => new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>reject(new Error('Pool ownership timeout')),15000);
      worker.onmessage=({data})=>{clearTimeout(timer);resolve(data);};
      worker.onerror=event=>{clearTimeout(timer);reject(new Error(event.message));};
      worker.postMessage({phase:-1,directory});
    });
    try {
      const first = await request(owner);
      if (!first.ok) throw new Error(first.error);
      const second = await request(contender);
      if (second.ok) throw new Error('Competing pool unexpectedly acquired');
      if (!second.error.includes('NoModificationAllowedError')) throw new Error('Unexpected contention failure: ' + second.error);
      return second.error;
    } finally { owner.terminate(); contender.terminate(); }
  });
  console.log('OPFS SQL/KV reopen, rollback, worker-termination recovery and integrity passed');
  console.log('Competing pool rejected:', ownershipError);
} finally { await browser?.close(); server.stop(true); }
