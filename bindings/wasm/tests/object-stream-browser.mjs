// Streams a large object through a persistent database and records the
// worker's WebAssembly memory, which must stay bounded by the chunk size (#217).

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

export async function testObjectStreaming(context, base, mebibytes) {
  const page = await context.newPage();
  try {
    await page.route("**/dist/worker.mjs", async route => {
      const response = await route.fetch();
      await route.fulfill({ response, body: captureMemory + await response.text() });
    });
    await page.goto(`${base}/failure`);
    await page.waitForFunction(() => Boolean(globalThis.zova));
    const ready = page.waitForEvent("worker");
    await page.evaluate(async () => {
      globalThis.h = await import("/helpers.mjs");
      globalThis.db = await zova.Database.openPersistent("large-" + crypto.randomUUID());
    });
    const worker = await ready;
    const memory = () => worker.evaluate(() => globalThis.testMemory.buffer.byteLength);
    const before = await memory();
    const write = await page.evaluate(async mebibytes => {
      const started = performance.now();
      let block = 0;
      const source = new ReadableStream({
        pull(controller) {
          if (block === mebibytes) { controller.close(); return; }
          controller.enqueue(h.patternBytes(1 << 20, block++ + 1));
        },
      });
      const writer = await db.objectWriter();
      await source.pipeTo(writer);
      globalThis.largeId = await writer.id;
      return { ms: performance.now() - started, size: String(await db.objectSize(globalThis.largeId)) };
    }, mebibytes);
    const afterWrite = await memory();
    const read = await page.evaluate(async () => {
      const started = performance.now();
      let offset = 0;
      let cachedBlock = -1;
      let expected;
      for await (const piece of await db.objectReader(globalThis.largeId, 1 << 20)) {
        for (let index = 0; index < piece.length; index++, offset++) {
          const block = offset >>> 20;
          if (block !== cachedBlock) { expected = h.patternBytes(1 << 20, block + 1); cachedBlock = block; }
          if (piece[index] !== expected[offset & 0xfffff]) throw new Error(`Byte ${offset} differs`);
        }
      }
      await db.close();
      return { ms: performance.now() - started, bytes: offset };
    });
    const afterRead = await memory().catch(() => afterWrite);
    const total = mebibytes * (1 << 20);
    if (write.size !== String(total) || read.bytes !== total) throw new Error(`Large object size ${write.size}/${read.bytes}, expected ${total}`);
    const peak = Math.max(afterWrite, afterRead);
    // Memory never shrinks, so its final size is the peak. The initial heap
    // and SQLite's page cache are fixed; growth must not follow object size.
    const limit = before + 32 * (1 << 20);
    const measurement = { mebibytes, chunkBytes: 1 << 20, wasmMemoryBefore: before, wasmMemoryAfterWrite: afterWrite, wasmMemoryPeak: peak, limit,
      writeSeconds: +(write.ms / 1000).toFixed(1), readSeconds: +(read.ms / 1000).toFixed(1) };
    console.log("Object streaming: " + JSON.stringify(measurement));
    if (peak > limit) throw new Error(`Worker memory grew to ${peak} bytes while streaming ${total} bytes`);
    return measurement;
  } finally {
    await page.close();
  }
}
