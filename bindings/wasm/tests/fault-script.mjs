// Prepended to the packed worker. `at` stops the worker at a publication step
// ("publish-0" before replacing, "publish-1" after the commit) or at the nth
// storage write after replacement starts ("write-n"). With `stop` the page
// terminates the worker there; without it the worker stays stopped and keeps
// its lock. `count` reports the replacement's write count. `always` counts
// every storage write from the start.
export const faultScript = config => `
  const testConfig = ${JSON.stringify(config)};
  const testPost = self.postMessage.bind(self);
  let testPublishing = Boolean(testConfig.always);
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

// A page whose packed worker runs `faultScript(config)` first and whose
// workers are terminated when they post `testStop`.
export async function faultedPage(context, base, config) {
  const page = await context.newPage();
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
  await page.evaluate(async () => { globalThis.h = await import("/helpers.mjs"); });
  return page;
}
