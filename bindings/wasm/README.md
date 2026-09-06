# zova-wasm

Experimental, memory-only Zova SQL and binary KV for browsers. The real Zova
core and bundled SQLite run inside a dedicated worker as one WebAssembly module.

This is an unpublished preview for the rc.3 work. Its current development
version follows the repository (`1.0.0-rc.2`, format 11). Browser API stability
and full native compatibility are not promised. Closing the database,
terminating its worker, or leaving the page loses its data.

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

There is no persistence, OPFS, import/export, public prepared-statement handle,
transaction callback helper, graph/vector/object helper, native extension,
bound-store API, migration, or shared access between workers. The native
`zova-js` package is independent. There is no Node/CommonJS fallback.

Emscripten's volatile MEMFS supplies SQLite's syscall environment; it is not
host filesystem access or durable storage. The build is single-threaded and
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
EM_CACHE, ZIG_LOCAL_CACHE_DIR, and ZIG_GLOBAL_CACHE_DIR settings can be reused.
Validate the tarball from the repository root:

```sh
bun bindings/wasm/tools/check-package.mjs /absolute/path/zova-wasm-1.0.0-rc.2.tgz
bun test bindings/wasm/tests/api.test.ts bindings/wasm/tests/channel.test.mjs
```

The browser runner accepts an explicitly supplied executable and uses a
temporary profile; it downloads no browser. Set TMPDIR to external storage.
Browser CI and registry publication remain issue #39.

## License

MIT; see LICENSE.
