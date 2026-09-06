import createZova from "/zova.mjs";

try {
  const start = performance.now();
  postMessage({ progress: "initializing module" });
  const zova = await createZova();
  postMessage({ progress: "module initialized; entering native smoke" });
  const initialized = performance.now();
  for (let i = 0; i < 10; i++) {
    const status = zova._zova_wasm_smoke();
    if (status !== 0n) throw new Error(`native smoke failed at stage ${status} (expected bigint zero)`);
  }
  postMessage({ ok: true, cycles: 10, initializationMs: initialized - start,
    smokeMs: performance.now() - initialized });
} catch (error) {
  postMessage({ ok: false, error: String(error), stack: error?.stack });
}
