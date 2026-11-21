# Zova for JavaScript and TypeScript

Synchronous and queued asynchronous Node-API bindings for Zova. The package is
built with napi-rs, uses the same native Zova engine as the Rust, Python, Go,
Zig, and C APIs, and ships TypeScript declarations.

The npm package is named `zova-js`. The Zova product, `.zova` file extension,
and native library names remain unchanged.

## Runtime support

- Node.js 22 and 24
- Bun, after the same installed native package passes the blocking Bun suite
- macOS arm64 and x86_64
- Linux arm64 and x86_64 with glibc
- Windows x86_64 with MSVC

Electron, Deno, browsers, musl Linux, Windows arm64, and WASM are not claimed.
Prebuilt installs do not need Zig, Rust, a C compiler, or an install-time
download. Building this package from source requires Bun, Rust, and a C
toolchain; Zig is not required because `zova-sys` builds the generated C
snapshot.

## Local installation

```sh
cd bindings/javascript
bun install --frozen-lockfile
bun run build
bun run test
```

Node and Bun load the same `.node` addon:

```sh
node tests/runtime-smoke.mjs
bun tests/runtime-smoke.mjs
```

Install the published package with:

```sh
bun add zova-js
# or
npm install zova-js
```

## SQL and transactions

```ts
import { Database, Step } from "zova-js";

const db = Database.create("app.zova");
db.exec("create table notes(id integer primary key, body text not null)");

const insert = db.prepare("insert into notes(body) values (?1)");
insert.bindText(1, "hello");
insert.step();
insert.close();

db.transaction((transaction) => {
  transaction.exec("insert into notes(body) values ('committed')");
});

db.close();
```

`transaction(fn)` and `savepoint(name, fn)` are deliberately synchronous. A
callback that returns a Promise is rejected before commit, and a thrown error
rolls back the scope.

## Data mappings

| Zova value | JavaScript value |
|---|---|
| SQL integer, count, identity | `bigint` |
| blob or object bytes | `Uint8Array` |
| f32 vector | `Float32Array` |
| f16 raw elements | `Uint16Array` |
| i8 vector | `Int8Array` |
| nullable SQL data | `null` |
| absent option | `undefined` |

## Storage APIs

The synchronous `Database` facade exposes:

- SQLite execution, prepared statements, bindings, stepping, and columns
- transactions, savepoints, backup, compact, restore, vacuum, and conversion
- `reclaimSpace({ maxPages, stepPages })`, which releases free pages in place
  from files in incremental auto-vacuum mode (the format-13 default) and
  returns one `ReclaimedMember` per member file
- storage-format probing and explicit copy-forward migration (`probeFormat`,
  `migrateDatabase`, and their async `AsyncDatabase` counterparts), with the
  same optional `ExtensionOptions` as `Database.open` for databases with a
  non-bundled extension installed
- objects, manifests, chunks, range reads, assembly, `ObjectWriter`, and
  `ObjectSeekableReader` for seekable, chunk-verified reads such as HTTP range
  serving (`read`/`seek` and `readAsync`/`seekAsync`)
- opt-in per-handle LZ4 chunk compression with
  `setObjectCompression("lz4" | "none")` on `Database` and `AsyncDatabase`;
  object IDs and manifests are unchanged and reads decode compressed chunks
- f32/f16/i8 vector collection lifecycle, batch writes/deletes, and exact search
- public graph CRUD, atomic batches, neighbors, degree, and walks
- bundled extension install/list/info/check/drop

From 1.2.0, builds support trusted native bundles through both handle types:

```typescript
const extensions = { bundlePaths: ["./search.zovaext"] };
const db = Database.create("app.zova", extensions);
db.installExtension("search");
db.close();
const reopened = Database.open("app.zova", { readOnly: true, extensions });
```

`AsyncDatabase.create/open` accept the same options. Set `trustStorePath` in the
extension options for a non-default store. First trust the bundle using
`zova extension trust ./search.zovaext`; opening never grants trust or loads
paths from database metadata. Native code/dependencies must match the host;
close releases callback state before unloading libraries. Published 1.1.0 npm
packages do not include this support.

Extension authoring remains unwrapped. See the
[extension capability matrix](../../docs/extensions.md#availability-and-binding-matrix).

## Low-level surfaces

The synchronous `Database` wraps every function in the C ABI. Beyond the APIs
above:

- Opaque-key graph APIs: `putGraphNodesKeyed`, `putGraphEdgesKeyed`,
  `getGraphNodesKeyed`, `getGraphEdgesKeyed` (a missing key gives `null`),
  `graphNeighborsKeyed`, `graphDegreesKeyed`, `getGraphEdgePayloads`,
  `replaceGraphEdgePayloads`, `graphScan` cursor pages, `graphWalkDirection`
  (and `graphWalkDirectionProfiled`), and the `buildFreshGraph*Keyed`
  builders. Keys are `bigint` values, returned as `BigInt64Array`; they are
  opaque and do not survive a graph rebuild.
- `beginFreshBuild()` returns a `FreshBuild` that loads tables, FTS tables,
  one graph and vector collections into empty targets, then publishes them
  together with `finish()`. `abort()`, `close()`, and any failure (including
  invalid row values) roll the session back. While it is active, other calls
  on the same `Database` fail and `close()` throws.
- `searchVectorsMultiI8` scores i8 vectors against several query rows.
- `registerFunction(name, arity, fn, options)` registers a scalar SQL
  function. Arguments arrive as `null`, `bigint`, `number`, `string`, or
  `Uint8Array`. A returned `number` is a SQL float, a `bigint` an integer, a
  `boolean` 0 or 1. A thrown exception or an unsupported result fails the
  statement. The function runs on the JavaScript thread while its statement
  steps, so it must not use the same `Database` or its statements: that call
  never returns.
- `LinkedPlugin.fromAddress(address)` wraps a `zova_plugin_descriptor_v1`
  linked into the process, for example from an FFI library. The descriptor
  must stay valid for the rest of the process; a wrong address crashes it.
  Pass linked plugins as `plugins` in `ExtensionOptions`, which
  `Database.create/open`, `AsyncDatabase.create/open`, `migrateDatabase`, and
  `AsyncDatabase.migrateDatabase` accept.
- `Database.openForExtensionUpgrade` opens without running installed extension
  hooks, so `extensionUpgrade` and `extensionRebuild` can repair a database
  whose extension check fails.
- `Database.createWithOptions(path, { pageSize })`, `abiVersionParts`, and the
  `verifyExtensionBundle`, `trustExtensionBundle` and `untrustExtensionBundle`
  functions.

## Queued async work

`AsyncDatabase` is separate from `Database`. It serializes operations FIFO,
runs native work on Node's worker pool, rejects new calls as soon as close
begins, waits for already queued work, and closes exactly once.

```ts
import { AsyncDatabase } from "zova-js";

const db = AsyncDatabase.create("app.zova");
await db.exec("create table notes(body text)");
const id = await db.putObject(new TextEncoder().encode("large bytes"));
const bytes = await db.getObject(id);
await db.close();
```

Queued work also includes backup/compact/restore, `reclaimSpace`, vector
batches and searches, and graph batches and walks. Inputs are copied before
worker execution.
`AsyncDatabase.objectSeekableReader(id)` opens a seekable reader whose
`readAsync` runs on the worker pool; its async reads and seeks run in call
order.

Async transaction callbacks and prepared statement handles are intentionally
not exposed.

## Ownership

Every native child has explicit cleanup. Call `Statement.close()`,
`ObjectWriter.close()`/`cancel()`, `ObjectSeekableReader.close()`, and
`Database.close()` yourself. Node-API
finalizers are fallback cleanup.

Input typed arrays are borrowed only during synchronous calls or copied before
queued worker execution. Returned strings and typed arrays are JavaScript-owned.
Native result containers are freed before control returns to JavaScript.

## Errors

Native failures are normalized to `ZovaError`:

```ts
try {
  db.exec("select * from missing");
} catch (error) {
  if (error instanceof ZovaError) {
    console.error(error.code, error.status, error.message);
  }
}
```

The binding preserves Zova's status name, numeric status, and native message.

## Deferred capabilities

- extension authoring
- async transaction callbacks
- direct Bun FFI
- zero-copy native output
- browser builds of this native addon (the experimental `zova-wasm` is separate)
