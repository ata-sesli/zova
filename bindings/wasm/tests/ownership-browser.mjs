// All pages intentionally share one browser context (origin storage and locks).
export async function testOwnership(browser, base) {
  const context = await browser.newContext();
  const page = async () => {
    const p = await context.newPage();
    await p.goto(`${base}/failure`);
    await p.waitForFunction(() => Boolean(globalThis.zova));
    return p;
  };
  const open = (p, name) => p.evaluate(async name => {
    try {
      globalThis.owned = await globalThis.zova.Database.openPersistent(name);
      return 'open';
    } catch (error) { return error.status; }
  }, name);
  try {
    const a = await page();
    const b = await page();
    const results = await Promise.all([open(a, 'race'), open(b, 'race')]);
    if (results.filter(x => x === 'open').length !== 1 || !results.includes('ZOVA_BUSY')) {
      throw new Error(`Expected one owner and one ZOVA_BUSY: ${results}`);
    }
    const owner = results[0] === 'open' ? a : b;
    const other = owner === a ? b : a;
    if (await open(other, 'race') !== 'ZOVA_BUSY') throw new Error('Second tab did not reject');
    if (await open(other, 'independent') !== 'open') throw new Error('Unrelated database blocked');
    await other.evaluate(() => globalThis.owned.close());
    await owner.evaluate(() => globalThis.owned.close());
    if (await open(other, 'race') !== 'open') throw new Error('Close did not release ownership');
    await other.close();
    if (await open(owner, 'race') !== 'open') throw new Error('Tab termination did not release ownership');
    await owner.evaluate(() => globalThis.owned.close());
    const workerReady = owner.waitForEvent('worker');
    if (await open(owner, 'death') !== 'open') throw new Error('Cannot open termination fixture');
    const worker = await workerReady;
    await worker.evaluate(() => { setTimeout(() => { throw new Error('intentional owner failure'); }, 0); });
    await owner.waitForFunction(() => globalThis.owned.closed);
    if (await open(owner, 'death') !== 'open') throw new Error('Worker termination did not release ownership');
    await owner.evaluate(async () => {
      await globalThis.owned.exec("UPDATE _zova_meta SET value='999' WHERE key='format_version'");
      await globalThis.owned.close();
    });
    for (let attempt = 0; attempt < 2; attempt++) {
      const status = await open(owner, 'death');
      if (status !== 'ZOVA_UNSUPPORTED_FUTURE_FORMAT') throw new Error(`Failed open returned ${status}`);
    }
    const unavailable = await page();
    await unavailable.route('**/dist/worker.mjs', async route => {
      const response = await route.fetch();
      await route.fulfill({response, body:'Object.defineProperty(navigator, "locks", {value:undefined});\n' + await response.text()});
    });
    if (await open(unavailable, 'no-locks') !== 'ZOVA_CANT_OPEN') throw new Error('Missing Web Locks accepted');
    await unavailable.evaluate(async () => {
      const memory = await globalThis.zova.Database.createMemory();
      await memory.close();
    });
  } finally { await context.close(); }
}
