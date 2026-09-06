# zova-wasm

Experimental Zova SQL and binary KV for browsers, in memory or named OPFS storage. The real Zova
core and bundled SQLite run inside a dedicated worker as one WebAssembly module.

This is an unpublished preview for the rc.3 work. Its current development
version follows the repository (`1.0.0-rc.2`, format 11). Browser API stability
and full native compatibility are not promised. Memory databases lose their
data when closed or when their worker/page terminates.

## Try a local package

Build and pack using the instructions below, then install the resulting tarball
with `bun add /absolute/path/zova-wasm-1.0.0-rc.2.tgz` in your browser application.
The package exports browser ESM and TypeScript declarations, with no native
addon dependency. Serve over HTTP(S), allowing module workers and WebAssembly.
Worker and WASM URLs resolve relative to the package; keep its files together
when deploying. Bundler compatibility is not yet a tested guarantee.

```ts
import { Database, ZovaWasmError } from 'zova-wasm';

const db = await Database.createMemory();
try {
  await db.exec('CREATE TABLE tasks(id INTEGER, title TEXT)');
  await db.query('INSERT INTO tasks VALUES (?, ?)', [1n, 'Try browser Zova']);
  const result = await db.query('SELECT id, title FROM tasks WHERE id = ?', [1n]);
  console.log(result.columns); // ['id', 'title']
  console.log(result.rows);    // [[1n, 'Try browser Zova']]

  const encode = (text: string) => new TextEncoder().encode(text);
  await db.kv.put(encode('cache'), encode('greeting'), encode('hello'));
  const value = await db.kv.get(encode('cache'), encode('greeting'));
  console.log(value === null ? 'missing' : new TextDecoder().decode(value));
  console.log(await db.kv.delete(encode('cache'), encode('greeting'))); // true
} catch (error) {
  if (error instanceof ZovaWasmError) console.error(error.status, error.message);
  else throw error;
} finally {
  await db.close();
}
```

## Named persistent databases

<!-- persistent-example -->
```js
import { Database } from 'zova-wasm';

const encode = text => new TextEncoder().encode(text);
const db = await Database.openPersistent('my-app'); // create or reopen
try {
  await db.exec('CREATE TABLE IF NOT EXISTS tasks(id INTEGER PRIMARY KEY, title TEXT)');
  await db.query('INSERT OR REPLACE INTO tasks VALUES (?, ?)', [1n, 'Keep this task']);
  await db.kv.put(encode('settings'), encode('theme'), encode('sage'));
} finally {
  await db.close();
}

const reopened = await Database.openPersistent('my-app');
try {
  const result = await reopened.query('SELECT title FROM tasks WHERE id = ?', [1n]);
  const theme = await reopened.kv.get(encode('settings'), encode('theme'));
  console.log(result.rows[0][0]); // Keep this task
  console.log(new TextDecoder().decode(theme)); // sage
} finally {
  await reopened.close();
}
```
<!-- /persistent-example -->

Names are case-sensitive: 1–64 ASCII letters, digits, underscores or hyphens,
starting with a letter or digit. They are logical names, not filesystem paths.
SQL and KV methods are unchanged. Existing files are validated before writable
opening; incompatible or invalid databases reject without automatic migration.
Missing OPFS support rejects rather than silently opening a memory database.

Persistent opening requires a secure context (HTTPS or localhost), dedicated
workers, Web Locks, and OPFS synchronous access handles. Each name has one exclusive
pool. An atomic, non-waiting Web Lock is acquired before storage initialization;
a competing tab or worker rejects with `ZOVA_BUSY` (status code 10). No active
owner is evicted. Different names can be open concurrently. Close releases storage
handles before ownership; failed initialization and worker/tab termination also
release ownership. Retry opening after the owner has closed or terminated.
Storage belongs to the origin and browser profile. Clearing site data or browser
eviction can remove it. There is no export/backup API yet. Broader crash, quota,
and multi-tab recovery guarantees remain experimental.

### Errors and recovery

Catch `ZovaWasmError` around opening and writes, inspecting `status` and
`statusCode`. `ZOVA_BUSY` means another owner is active: wait for it to close,
then retry with a bounded delay. Worker termination releases locks asynchronously;
do not spin or try to steal them. `ZOVA_CANT_OPEN` can indicate missing storage or
locking support. Invalid names produce `ZOVA_INVALID_ARGUMENT`.

Format/schema errors are not a request to recreate or delete the database.
There is no automatic migration here. Storage write/flush failures reject rather
than fall back to memory; quota failures may surface through SQLite's storage
error mapping, not as a JavaScript `QuotaExceededError`. Do not assume a failed
write succeeded or blindly replay a larger application operation. For an explicit
SQL transaction, attempt rollback, close, and handle recovery at the application
boundary. SQL and KV writes in the example are separate commits, not one combined
transaction.

### Browser storage is not a backup

The same name belongs to the same origin (scheme, host and port) and browser
profile. It is neither a user-selected file nor synchronization with a server or
another device. Changing the origin/profile gives different storage. Clearing
site data can delete the database.

Browsers normally use best-effort storage and can evict it under storage pressure.
Your application may call `navigator.storage.persist()` from its window context
and inspect its boolean result; the browser may grant or deny it, with permission
UI varying by browser. Zova does not request this permission automatically.
`openPersistent()` names the disk-backed mode, not a grant of that permission.
A grant protects against automatic eviction but is not unlimited capacity, a
backup, or protection from user deletion. `navigator.storage.estimate()` provides
an estimate, not reserved space. See [browser quotas and eviction](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria)
and [persistent-storage permission](https://developer.mozilla.org/en-US/docs/Web/API/StorageManager/persist).

The local packed-artifact gate is verified with Helium; Linux CI targets
Playwright Chromium. Firefox, Safari, mobile browsers and private-browsing modes
have not been qualified. Do not infer support from API presence alone. Private
browsing can restrict storage and normally clears it when the private session
ends; no private-mode persistence guarantee is made.

Tests cover reload, rollback, worker termination, and injected quota/write/flush
errors. Real quota exhaustion, browser-process crashes, OS crashes and power loss
remain unverified. There is no unload-time save requirement for completed commits,
but these tests are not a general crash-durability or performance guarantee.

### 1.0.0-rc.3 WASM release notes (planned)

- Adds experimental named OPFS SQL/KV storage alongside `createMemory()`.
- Adds exclusive per-name ownership with explicit busy errors and cleanup.
- Adds packed-artifact persistence, rollback and injected-storage-fault coverage.
- Defers export/import, shared multi-tab connections and automatic migration.
- Does not promise native feature parity, stable browser APIs or performance.

These notes describe the rc.3 changes; the current development package remains
rc.2 until the separate release bump.

## Values and lifecycle

SQL accepts null, finite numbers, signed 64-bit bigint, strings, and Uint8Array.
Numbers bind as floating-point values; use bigint for integer parameters.
Integer result columns return bigint. Positional rows preserve column order
even when names repeat. Text and blobs are copied out of native memory.

KV namespaces, keys, and values are Uint8Array values. Missing get returns null;
an empty stored value returns an empty Uint8Array. Delete reports whether the
key existed. Caller buffers remain attached and are copied when requests send.

Each database owns one worker. Concurrent calls execute in request order.
Close follows earlier work, is idempotent, and marks `closed` immediately.
Operations after close reject. Worker failures reject outstanding work and
mark the database closed. Errors include `status` and `statusCode`.

## Current boundaries

There is no import/export, public prepared-statement handle,
transaction callback helper, graph/vector/object helper, native extension,
bound-store API, migration, or shared access between workers. The native
`zova-js` package is independent. There is no Node/CommonJS fallback.

Memory databases use volatile storage; named databases use the bundled SQLite's
OPFS SAH-pool adapter, not a second engine. The build is single-threaded and
does not require SharedArrayBuffer. Safety traps become worker failures.

## Build and test

Use Zig 0.16.0, Bun, and the pinned Emscripten version in
`emscripten-version.txt` (6.0.9). Install development dependencies with
`bun install` in `bindings/wasm`. From the repository root:

```sh
sh bindings/wasm/tools/build-package.sh /absolute/external/build-output
cd /absolute/external/build-output/package
npm pack --ignore-scripts
```

Build products and caches default to the chosen output directory. Existing
EM_CACHE can be reused. The build downloads checksum-pinned SQLite adapter
sources matching the bundled SQLite, or uses ZOVA_SQLITE_WASM_SOURCE when set.
Its failed-initialization cleanup is patched to release handles without deleting
the pool's stored files; the build rejects an unexpected upstream cleanup shape.
Validate the tarball from the repository root:

```sh
bun bindings/wasm/tools/check-package.mjs /absolute/path/zova-wasm-1.0.0-rc.2.tgz
bun test bindings/wasm/tests/api.test.ts bindings/wasm/tests/channel.test.mjs
```

Test the actual packed and installed artifact with Playwright driving Helium:

```sh
HELIUM_EXECUTABLE=/Applications/Helium.app/Contents/MacOS/Helium \
  sh bindings/wasm/tools/check-browser-package.sh /absolute/external/build-output
```

Local runs require an explicit Helium executable and use a temporary profile
under the build output directory. They do not download Playwright's browser.
Linux CI installs Playwright's bundled Chromium, builds once,
and tests the installed npm tarball before uploading it. Playwright is pinned
in the development lockfile. Native bindings remain independently tested.

Release publication requires a successful Release Artifacts run at the exact
release commit, including the WASM browser job. Experimental WASM prereleases
use npm's `next` tag with trusted publishing. Before the first registry release,
the npm package must exist and its trusted publisher must name this repository,
`publish-release.yml`, and the `release` environment. This change does not publish
the package or bump the repository version.

## License

MIT; see LICENSE.
