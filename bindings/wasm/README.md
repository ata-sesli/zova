# zova-wasm

Zova for browsers, in memory or named OPFS storage: SQL, binary KV,
transactions, prepared statements, objects, exact vectors and graphs. The real Zova
core and bundled SQLite run inside a dedicated worker as one WebAssembly module.

This package follows the repository release (`1.5.0`, format 14) and the native
`zova-js` API, except where a browser makes that impossible (see
[Native API parity](#native-api-parity)). From 1.5.0 its API is a stable 1.x
surface; [API_STABILITY.md](../../API_STABILITY.md#browser-package-zova-wasm)
lists the commitments and the named exceptions. Memory databases lose their
data when closed or when their worker/page terminates.

## Try a local package

Build and pack using the instructions below, then install the resulting tarball
with `bun add /absolute/path/zova-wasm-1.5.0.tgz` in your browser application.
The package exports browser ESM and TypeScript declarations, with no native
addon dependency. Serve over HTTP(S), allowing module workers and WebAssembly.
Worker and WASM URLs resolve relative to the package; keep its files together
when deploying. Bundler compatibility is not yet a tested guarantee.

```ts
import { Database, ZovaError } from 'zova-wasm';

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
  if (error instanceof ZovaError) console.error(error.code, error.status, error.message);
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
SQL and KV methods are unchanged. Existing files are validated during normal
Zova opening; clean incompatible or invalid databases reject without mutation
or automatic migration. Opening may first recover an abandoned SQLite rollback
journal to restore committed state after worker termination. This is transaction
recovery, not a storage-format migration.
Missing OPFS support rejects rather than silently opening a memory database.

`openPersistent(name, options)` takes the native open and create options:
`readOnly` opens an existing database without writing to it, `busyTimeoutMs`
sets SQLite's busy timeout, and `pageSize` applies when the name is created.
`createMemory({ pageSize })` takes the page size as well. A module with
statically linked plugins rejects `pageSize`, because the native plugin open
has no creation options. `openPersistentForExtensionUpgrade(name)` opens an
existing database without running installed extension hooks, as native
`openForExtensionUpgrade`. `convertSqliteToPersistent(name, data)` converts an
ordinary SQLite database, given as a `Uint8Array` or a stream, into a new
persistent Zova database and opens it, as native `convertSqliteToZova`; the
SQLite bytes are staged in the name's storage only while it runs, and an
existing name is never replaced.

Persistent opening requires a secure context (HTTPS or localhost), dedicated
workers, Web Locks, and OPFS synchronous access handles. Each name has one exclusive
pool. An atomic, non-waiting Web Lock is acquired before storage initialization;
a competing tab or worker rejects with `ZOVA_BUSY` (status code 10). No active
owner is evicted. Different names can be open concurrently. Close releases storage
handles before ownership; failed initialization and worker/tab termination also
release ownership. Retry opening after the owner has closed or terminated.
Storage belongs to the origin and browser profile. Clearing site data or browser
eviction can remove it. `export()`, `exportStream()` and `importPersistent()` copy
databases in and out of that storage; nothing is exported automatically. Crash,
quota and multi-tab recovery are promised only as far as the tests below cover.

### Errors and recovery

Catch `ZovaError` around opening and writes, inspecting `code` (the status
name, such as `ZOVA_BUSY`) and `status` (its number), as with native `zova-js`.
Before 1.5.0 the class was `ZovaWasmError`, with the name in `status` and the
number in `statusCode`; `ZovaWasmError` and `statusCode` remain as deprecated
aliases, but `status` is now the number. `ZOVA_BUSY` means another owner is active: wait for it to close,
then retry with a bounded delay. Worker termination releases locks asynchronously;
do not spin or try to steal them. `ZOVA_CANT_OPEN` can indicate missing storage or
locking support. Invalid names produce `ZOVA_INVALID_ARGUMENT`.

Format/schema errors are not a request to recreate or delete the database.
Opening never migrates; `ZOVA_MIGRATION_REQUIRED` means an older stored format
that `Database.migratePersistent()` can upgrade (see below). Storage write/flush failures reject rather
than fall back to memory; quota failures may surface through SQLite's storage
error mapping, not as a JavaScript `QuotaExceededError`. Do not assume a failed
write succeeded or blindly replay a larger application operation. For an explicit
SQL transaction, attempt rollback, close, and handle recovery at the application
boundary. SQL and KV writes in the example are separate commits; use
`transaction()` to commit them together.

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

Supported browser engines are Chromium-based desktop browsers, version 149 or
later, and desktop Firefox, version 155 or later. The local packed-artifact gate
runs in Helium (Chromium 149) and Playwright Firefox (155); Linux CI runs
Playwright Chromium (153) and Playwright Firefox (155). The same suites pass in
both engines, with no Firefox-specific code or behavior. Safari, WebKit, mobile
browsers and private-browsing modes have not been qualified. Do not infer
support from API presence alone. Private
browsing can restrict storage and normally clears it when the private session
ends; no private-mode persistence guarantee is made.

Tests cover reload, rollback, worker termination, and injected quota/write/flush
errors. Real quota exhaustion, browser-process crashes, OS crashes and power loss
remain unverified. There is no unload-time save requirement for completed commits,
but these tests are not a general crash-durability or performance guarantee.

### Named storage history (introduced in rc.3)

rc.3 introduced named storage as experimental, with these limits; later
releases added export/import and in-place migration, and 1.5.0 makes the API
stable.


- Adds experimental named OPFS SQL/KV storage alongside `createMemory()`.
- Adds exclusive per-name ownership with explicit busy errors and cleanup.
- Adds packed-artifact persistence, rollback and injected-storage-fault coverage.
- Defers export/import, shared multi-tab connections and automatic migration.
- Does not promise native feature parity, stable browser APIs or performance.

## Values and lifecycle

SQL accepts null, finite numbers, signed 64-bit bigint, strings, and Uint8Array.
Numbers bind as floating-point values; use bigint for integer parameters.
Integer result columns return bigint. Positional rows preserve column order
even when names repeat. Text and blobs are copied out of native memory.

KV namespaces, keys, and values are Uint8Array values. Missing get returns null;
an empty stored value returns an empty Uint8Array. Delete reports whether the
key existed. `kv.getMany`, `kv.putMany` (entries `{ key, value }`),
`kv.deleteMany`, `kv.count` (bigint) and `kv.clearNamespace` match native
`kvGetMany` and friends; batches are atomic inside and outside transactions.
`kv.scan(namespace, options)` returns one page `{ entries, hasMore }` in
ascending key order with native `KvScanOptions` (`prefix`, `start`, `end`,
`after`, `limit`, `keysOnly`). `kv.putIfAbsent`, `kv.compareAndPut` and
`kv.compareAndDelete` resolve whether they wrote; a missing key never matches
an expected value. Caller buffers remain attached and are copied when requests send.

Each database owns one worker. Concurrent calls execute in request order.
Close follows earlier work, is idempotent, and marks `closed` immediately.
Operations after close reject. Worker failures reject outstanding work and
mark the database closed. Errors include `code` and `status`.

## Transactions

```ts
const moved = await db.transaction(async tx => {
  await tx.query('UPDATE accounts SET balance = balance - ? WHERE id = ?', [10n, 1n]);
  await tx.kv.put(namespace, key, value);
  return 'moved';
});
```

`transaction()` begins an immediate transaction, runs the callback with a
handle scoped to it, and commits when the callback resolves or rolls back when
it throws, rethrowing the callback's error. SQL, KV, object, vector and graph
writes made through `tx` commit or roll back together. Calls made on `db`
while a transaction runs wait until it ends, so awaiting `db` (rather than `tx`)
inside the callback never completes. Transactions cannot be nested, `tx` rejects
once its transaction has ended, and `tx.close()` rejects.

Explicit control is also available: `begin()`, `beginImmediate()`, `commit()`
and `rollback()` act on the database's one connection, and calls run in order,
so the caller that begins a transaction owns it until it ends. They reject on a
`tx` handle; use savepoints there. `savepoint(name)`, `releaseSavepoint(name)`
and `rollbackToSavepoint(name)` nest inside either form, and
`savepoint(name, async sp => ...)` releases on success or rolls back and
releases on error. `changes()`, `totalChanges()` and `lastInsertRowid()` return
bigint. `setBusyTimeout(ms)` is accepted for parity; with one exclusive owner and
one connection there is normally nothing to wait for.

## Notifications

```ts
const jobs = await db.listen('jobs');
await db.notify('jobs', 'rebuild');
const next = await jobs.tryReceive(); // { channel, payload, sequence, droppedBefore } or null
await jobs.close();
```

Notifications follow native same-process semantics within this database's
worker: a notification sent inside a transaction or savepoint is received only
after commit, and never after rollback. `tryReceive()` polls; there is no
push delivery. A subscription created on `db` waits like other `db` calls while
a `transaction()` callback runs; create one through `tx` to read inside it.
Notifications do not cross workers or tabs.

## Prepared statements

```ts
const insert = await db.prepare('INSERT INTO tasks VALUES (?, ?)');
await insert.query([2n, 'Reuse the plan']);
await insert.finalize();

const select = await db.prepare('SELECT id, title FROM tasks WHERE id >= ?');
for await (const row of select.iterate([1n], 100)) console.log(row);
await select.finalize();
```

`prepare()` compiles one statement and reports `parameterCount` and `columns`.
`query()` rebinds, runs to completion and returns every row. `iterate()` fetches
rows in batches (256 by default) and resets the statement when the loop ends
or is abandoned. A statement has one cursor: do not start a second `query()` or
`iterate()` on the same statement before the first finishes. Rows not yet
fetched reflect later writes on the same database as SQLite defines. Statements
prepared inside a transaction remain usable after it. `finalize()` is idempotent;
closing the database finalizes its statements.

Statements can also be stepped as in native `Statement`: `bindNull`,
`bindInteger` (bigint), `bindFloat`, `bindText`, `bindBlob`, `parameterIndex`,
`clearBindings`, `step()` (resolving `"row"` or `"done"`) and `reset()`, which
keeps bindings. `step()` brings the whole row across in one message, and
`columnCount`, `columnName`, `columnType`, `columnInteger`, `columnFloat`,
`columnText` and `columnBlob` then read it synchronously. Integer and float
columns convert into each other and null reads as `0n`, `0` or `null`; reading
text as a number or a number as text rejects with `ZOVA_MISUSE`, because the
row is already converted and SQLite's own conversion is not reproduced. Each
step is one worker message, so prefer `iterate()` for many rows.

## Objects, vectors and graphs

```ts
const id = await db.putObject(bytes);            // 32-byte SHA-256 identity
const tail = await db.readObjectRange(id, 1024n, 4096);

await db.createVectorCollection('docs', { dimensions: 3, metric: 'cosine', elementType: 'f32' });
await db.putVectors('docs', [{ id: 'a', values: new Float32Array([1, 0, 0]) }]);
const hits = await db.searchVectors('docs', new Float32Array([1, 0, 0]), { limit: 5 });
const near = await db.searchVectorsById('docs', 'a', { limit: 5, candidateIds: ['b', 'c'], maxDistance: 0.5 });

await db.createGraph('links');
await db.putGraphNodes([
  { graphName: 'links', nodeId: 'a', kind: 'page', targetType: 'none' },
  { graphName: 'links', nodeId: 'b', kind: 'page', targetType: 'none' },
]);
await db.putGraphEdge({ graphName: 'links', fromNodeId: 'a', edgeType: 'cites', toNodeId: 'b' });
const reached = await db.graphWalk({ graphName: 'links', startNodeId: 'a', maxDepth: 2, limit: 100 });
```

Method names and result shapes follow the native `zova-js` package. Objects:
`putObject`, `getObject`, `readObjectRange`, `hasObject`, `objectSize`,
`deleteObject`. Vectors: collection create/has/info/list/delete, `putVector(s)`,
`getVector`, `hasVector`, `deleteVector(s)`, `searchVectors` and
`searchVectorsById`. Metrics are `cosine`, `l2` and `dot`; element types are
`f32` (`Float32Array`), `f16` (raw half-float bits in a `Uint16Array`) and `i8`
(`Int8Array`). Search is exact. `searchVectors` and `searchVectorsById` take
native `VectorSearchOptions` (`limit`, optional `candidateIds` and
`maxDistance`) and choose the same core variant as native; a bare `limit`
number is still accepted. Graphs: create/has/info/list/delete, node and
edge put/get/has/delete with batch forms, `graphNeighbors`, `graphDegree` and
`graphWalk`. Counts and sizes are bigint. `getObject` and result lists cross
the worker in one message; stream large objects instead.

`setObjectCompression('lz4' | 'none')` selects how new object chunks are stored
by this database; reads decode either. `searchVectorsMultiI8(collection,
options)` scores i8 vectors against several query rows with native
`VectorMultiI8SearchOptions`.

The keyed graph calls match native `zova-js`: `putGraphNodesKeyed` and
`putGraphEdgesKeyed` resolve `BigInt64Array` keys; `getGraphNodesKeyed`,
`getGraphEdgesKeyed` and `getGraphEdgePayloads` take keys and resolve `null`
for a missing one; `graphNeighborsKeyed`, `graphDegreesKeyed`
(`BigUint64Array`), `replaceGraphEdgePayloads`, `graphScan` (pages continued
by `{ createdOrder, key }` cursors), `graphWalkDirection` and
`graphWalkDirectionProfiled`. `buildFreshGraphKeyed`,
`buildFreshGraphPreparedKeyed` and `buildFreshGraphPreparedKeyedWithPayloads`
create and load a new graph in one transaction.

```ts
const build = await db.beginFreshBuild();
await build.tableRows('files', ['id', 'path'], [[1n, 'a.rs'], [2n, 'b.rs']]);
await build.graph('code', nodes, edges);
await build.vectors('embeddings', vectors);
const { nodeKeys, edgeKeys, profile } = await build.finish();
```

`beginFreshBuild()` starts a native fresh-build session (`tableRows`,
`ftsRows`, `graph`, `vectors`, `finish`, `abort`, `close`). While it is open
other calls on the database reject. `abort`, `close`, any failure including
invalid input, and closing the database roll the whole session back.

Each of these batch calls, and `searchVectorsMultiI8`, sends one message to
the worker. Keys, payloads, row blobs and vector values are copied into
package-owned buffers that are transferred rather than cloned, so caller arrays
stay usable; key, degree and payload results are transferred back.
`tests/graph-fixture.json`, recorded from native `zova-js` by
`tools/generate-graph-fixture.mjs`, holds the results the browser tests compare
against.

## SQL functions

```ts
// /sql/functions.mjs, loaded by the database worker
export const slug = text => text.toLowerCase().replaceAll(' ', '-');
```

```ts
await db.registerFunction('slug', 1, { module: '/sql/functions.mjs', export: 'slug' }, { deterministic: true });
const rows = await db.query("SELECT slug('Hello World')"); // [['hello-world']]
```

`registerFunction(name, arity, { module, export }, options)` registers a scalar
SQL function, as native `registerFunction` does. A browser function cannot be a
closure from the page: SQLite calls it synchronously inside the database
worker, so the worker imports `module` (a URL resolved against the page) and
calls its export `export` for each row. Arguments arrive as `SqlValue`s with
integers as bigint. Return null or undefined, a bigint (integer), a number
(float), a boolean (1 or 0), a string or a `Uint8Array`; a thrown exception or
another result fails the statement with that message. The function cannot use
page state, this database, or await. `arity` -1 accepts any number of
arguments; `options` are `deterministic`, `directOnly` and `innocuous`.
Closing the database releases its functions.

### Streaming objects, chunks and manifests

```ts
const writer = await db.objectWriter();          // or objectWriterWithOptions({ profile: 'streaming' })
await file.stream().pipeTo(writer);              // any ReadableStream<Uint8Array>
const id = await writer.id;

for await (const piece of await db.objectReader(id)) send(piece);   // 1 MiB reads by default

const reader = await db.objectSeekableReader(id); // verified random access
const range = await reader.readAt(1024n, 65536);  // or seek() and read()
await reader.close();
```

`objectWriter()` returns a `WritableStream`: each written chunk is copied once
and moved to the worker, so neither side holds the whole object. Closing the
stream stores the object and resolves `writer.id`; aborting it, or a failed
write, cancels the object and stores nothing. The core writer commits chunks in
batches of 4 MiB in the browser build (64 MiB natively), and keeps one manifest
entry per chunk until it finishes. `objectReader(id, chunkSize)` returns a
`ReadableStream` of verified bytes; cancel it to release the reader early.
`objectSeekableReader(id)` checks each chunk against its manifest hash before
returning bytes, which suits range serving from a Service Worker; reads at or
past the end return an empty array. Readers hold no transaction between calls.

`putObjectWithOptions`, `objectChunkCount`, `objectManifest`, `getObjectChunk`,
`hasObjectChunk`, `putObjectChunk(WithOptions)`, `deleteObjectChunk` and
`assembleObjectFromChunks(WithOptions)` take the same arguments as native
`zova-js`; profiles are `deduplication` (FastCDC) and `streaming` (fixed 1 MiB
chunks). `objectIdToHex` and `objectIdFromHex` are plain functions.
`objectId(data)` and `objectChunkId(data)` use the core's SHA-256 and resolve
the same IDs as native; the first call starts a shared memory-database worker
that stays for the page's lifetime.

## Export, import and managing stored databases

```ts
const bytes = await db.export();                        // persistent or memory database
const copy = await Database.importPersistent('restored', bytes);

const response = await fetch('/backups/latest.zova');   // or a File, or exportStream()
const imported = await Database.importPersistent('downloaded', response.body);
await (await db.exportStream()).pipeTo(uploadStream);   // bounded memory

console.log(await Database.listPersistent());           // [{ name, bytes, inUse }]
await Database.deletePersistent('restored');
```

`export()` returns the committed database as one `Uint8Array`: the stored file
of a persistent database, or a serialized copy of a memory database.
`exportStream(chunkSize)` returns the same bytes as a `ReadableStream` read 1 MiB
at a time; other calls on the database wait until the stream ends or is
cancelled. Both reject while a transaction is open.

`importPersistent(name, data)` accepts those bytes as a `Uint8Array` or a
`ReadableStream<Uint8Array>`, which is written as it arrives, so neither side
holds the whole database. It creates a new name and never replaces a stored
database (`ZOVA_DESTINATION_EXISTS`). The file must pass normal Zova opening and
the core's copy verification, as native backup and restore run it; otherwise it
is removed and the import rejects with the opening or verification error. Until
an import completes, a root-level `.zova-<name>.pending` marker flags the name
as incomplete: an import stopped by a closed tab or worker is not listed, and
the next open of the name removes it. Split databases with bound stores do not
exist in browser storage and cannot be imported.

`listPersistent()` lists stored names with their storage use in bytes. A
database open in another tab or worker is listed with `inUse: true` and no size.
`deletePersistent(name)` takes the name's lock first, so a database open
elsewhere rejects with `ZOVA_BUSY` and nothing is removed; it resolves whether
the name held storage. `probePersistent(name)` reports a stored format without
opening it (see migration below).

## Backup, compact, reclaim and restore

```ts
await db.reclaimSpace();                          // release free pages in place
await db.backupTo('my-app-backup', { progress: event => console.log(event) });
await db.compactTo('my-app-compact', { signal: AbortSignal.timeout(60_000) });
await Database.restoreBackup('my-app-backup', 'my-app-restored');
const scratch = await Database.restoreBackupToMemory('my-app-backup');
```

`reclaimSpace({ maxPages, stepPages })` releases free pages of incremental
auto-vacuum files (every database this package creates) in bounded write
transactions and returns native `ReclaimedMember` records; the stored file
shrinks accordingly. It rejects with `ZOVA_OBJECT_TRANSACTION_ACTIVE` inside a
transaction. `vacuum()` rebuilds the file with SQLite `VACUUM`.

`backupTo(name)` and `compactTo(name)` copy an open persistent database to a
new persistent name in the same origin. The target gets the same ownership
check as opening it (`ZOVA_BUSY`) and must not exist
(`ZOVA_DESTINATION_EXISTS`). The copy is staged in the source's storage and
verified with the core's copy verification (`verify: false` skips it), then
published to the target in one journaled write. A worker or tab stopped at any
point leaves no target: a root-level `.zova-<name>.pending` marker identifies
an incomplete creation, and the next owner of that name removes it. Progress
events use the native phases `copy`, `verify` and `publish`. Aborting `signal`,
or throwing from `progress`, takes effect when the running phase ends (the
database's own worker cannot be stopped mid-call) and rejects with
`ZOVA_INTERRUPTED`, or the thrown error, without creating the target; once
`publish` has started the copy completes. Memory databases reject with
`ZOVA_INVALID_ARGUMENT`; export them instead.

`Database.restoreBackup(source, target)` copies a stored current-format
database to a new name the same way. `Database.restoreBackupToMemory(source)`
returns a memory database and releases the source once it is read. Both reject
with `ZOVA_NOT_ZOVA_DATABASE` when the source name holds no database.

## Migrating stored databases

A newer package can use a newer storage format. Opening a database stored by
an older package then rejects with `ZOVA_MIGRATION_REQUIRED` and changes
nothing. Migrate it explicitly, then open it:

```ts
const info = await Database.probePersistent('my-app'); // { formatVersion, compatibility }
if (info.compatibility === 'migratable') {
  await Database.migratePersistent('my-app', {
    progress: ({ phase, member, done, total }) => console.log(phase, member, done, total),
    signal: AbortSignal.timeout(60_000),
  });
}
const db = await Database.openPersistent('my-app');
```

`probePersistent()` reads the format without opening or changing the
database. `compatibility` is `current`, `migratable`, `unsupported_legacy` or
`unsupported_future`, as native `probeFormat`. Both calls take the database's
lock: they reject with `ZOVA_BUSY` while another tab or worker has it open, and
other tabs get `ZOVA_BUSY` while a migration runs.

`migratePersistent()` runs native Zova migration on a staged copy in the same
origin storage: it copies, migrates and verifies the copy, then replaces the
stored database with it in one journaled SQLite write. A worker or tab that
stops at any point leaves either the original or the migrated database; the
next open, probe or migration rolls back an interrupted replacement and
removes the staged copy, and migrating again resumes. A database that is
already current resolves without changes. Migration needs free origin storage
for about twice the database size; it checks `navigator.storage.estimate()`
first and rejects with `ZOVA_CANT_OPEN` naming the shortfall.

Progress events use the native phases (`copy`, `migrate`, `verify`,
`publish`). Aborting `signal`, or throwing from `progress`, before the
replacement starts stops the worker and rejects with `ZOVA_INTERRUPTED` (or the
thrown error), leaving the stored database unchanged; once the `publish` phase
has started, the migration completes. `verify: false` skips verification of the
staged copy. Databases with bound stores cannot exist in browser storage and
reject with `ZOVA_BOUND_STORE_INVALID`. Downgrades are not supported.

## Extensions

```ts
await db.installExtension('trgm');
const hits = await db.query(
  `SELECT document_id, score FROM zova_trgm_search
   WHERE index_name = ? AND query = ? AND threshold = 0.2 AND "limit" = 10 ORDER BY rank`,
  ['messages', 'attachement failed']);
console.log(await db.listExtensions());  // native ExtensionInfo records
await db.checkExtensions();
await db.dropExtension('trgm');
```

`installExtension`, `dropExtension`, `listExtensions`, `extensionInfo`,
`checkExtension` and `checkExtensions` manage the extensions the module was
built with: the bundled `trgm`, and nothing else in the published package.
Installed extensions register their SQL on every open, as natively. A stored
database with an extension the module lacks rejects on open with
`ZOVA_EXTENSION_UNAVAILABLE`, as native Zova does without that extension's code.

There is no run-time loading in browsers: `.zovaext` bundles and the native
`ExtensionOptions.bundlePaths` and `trustStorePath` options do not apply.
Applications that build their own module can link plugins statically through
the native linked-plugin descriptors. Pass C sources, separated by `:`, in
`ZOVA_WASM_PLUGIN_SOURCES` to `tools/build-package.sh`; one of them defines

```c
const struct zova_plugin_descriptor_v1 *const *zova_wasm_linked_plugins(size_t *count);
```

returning the plugin descriptors (see `tests/linked-plugin.c`). The module then
opens, creates, migrates and verifies imports with those plugins, as native
`zova_database_open_with_plugins` does. `tests/linked-plugin-browser.mjs`
checks such a build; the package gate does not build one.

`extensionUpgrade(name)` and `extensionRebuild(name)` run an extension's data
upgrade or rebuild hook, as natively; open the database with
`openPersistentForExtensionUpgrade` when its extension check fails.

## Native API parity

Every public name of native `zova-js` and its browser form. Every browser
method returns a promise. `bun tools/check-api.mjs` fails CI when a `zova-js`
name is missing from the first column.

| Native `zova-js` | `zova-wasm` |
| --- | --- |
| `packageVersion`, `formatVersion`, `sqliteVersion` | same constants |
| `abiVersion`, `abiVersionParts` | async functions |
| `ZovaError` (`code`, `status`) | same; `ZovaWasmError` and `statusCode` are deprecated aliases |
| `Database.create(path)`, `Database.open(path, { readOnly, busyTimeoutMs })`, `createWithOptions` | `openPersistent(name, options)` opens a name or creates it |
| `createMemory` | same, with `{ pageSize }` |
| `Database.openForExtensionUpgrade` | `openPersistentForExtensionUpgrade` |
| `AsyncDatabase` | not needed: every `Database` method is already asynchronous |
| `closed`, `close` | same on `Database`, `Subscription`, `ObjectSeekableReader` and `FreshBuild`; `Statement` has `finalized` and `finalize()`; object writers and readers are streams |
| `exec`, `query`, `prepare` | same |
| `begin`, `beginImmediate`, `commit`, `rollback` | same; reject on a `transaction()` handle |
| `transaction(callback)` | same, immediate, async callback |
| `transactionImmediate(callback)` | `transaction(callback)` is already immediate |
| `savepoint`, `releaseSavepoint`, `rollbackToSavepoint` | same, async callback form |
| `changes`, `totalChanges`, `lastInsertRowid`, `setBusyTimeout` | same |
| `Statement.parameterCount()` | `parameterCount` property, set by `prepare()` |
| `Statement.parameterIndex`, `bindNull`, `bindInteger`, `bindFloat`, `bindText`, `bindBlob` | same |
| `step` (`Step`), `reset`, `clearBindings` | same; `Step` is a constant object with the same values |
| `columnCount`, `columnName`, `columnType`, `columnInteger`, `columnFloat`, `columnText`, `columnBlob` | same, synchronous over the stepped row; see above |
| `Statement.close()` | `finalize()` |
| `kvGet`, `kvPut`, `kvDelete` | `kv.get`, `kv.put`, `kv.delete` |
| `kvGetMany`, `kvPutMany`, `kvDeleteMany`, `kvCount`, `kvClearNamespace` | `kv.getMany`, `kv.putMany`, `kv.deleteMany`, `kv.count`, `kv.clearNamespace` |
| `kvScan`, `kvPutIfAbsent`, `kvCompareAndPut`, `kvCompareAndDelete` | `kv.scan`, `kv.putIfAbsent`, `kv.compareAndPut`, `kv.compareAndDelete` |
| `notify`, `listen`, `Subscription.tryReceive` | same; within one worker only |
| `Subscription.tryReceiveAsync` | `tryReceive()` is already asynchronous |
| `Subscription.create` (wraps a native handle) | not applicable; `listen` creates subscriptions |
| `setObjectCompression` | same |
| `putObject`, `putObjectWithOptions`, `getObject`, `readObjectRange`, `hasObject`, `objectSize`, `objectChunkCount`, `deleteObject` | same |
| `objectManifest`, `getObjectChunk`, `hasObjectChunk`, `putObjectChunk`, `putObjectChunkWithOptions`, `deleteObjectChunk` | same |
| `assembleObjectFromChunks`, `assembleObjectFromChunksWithOptions` | same |
| `objectId`, `objectChunkId` | same, asynchronous |
| `objectIdToHex`, `objectIdFromHex` | same |
| `objectWriter`, `objectWriterWithOptions` (`ObjectWriter`: `write`, `finish`, `cancel`) | same names; a `WritableStream` with `id` (close, abort) |
| `objectReader` (`ObjectReader.read(size)`) | a `ReadableStream` of reads up to `chunkSize` |
| `objectSeekableReader` (`ObjectSeekableReader`: `read`, `seek`, `position`, `size`) | same, asynchronous, plus `readAt(offset, length)` |
| `ObjectSeekableReader.readAsync`, `seekAsync` | `read` and `seek` are already asynchronous |
| `createVectorCollection`, `hasVectorCollection`, `vectorCollectionInfo`, `listVectorCollections`, `deleteVectorCollection` | same |
| `putVector`, `putVectors`, `getVector`, `hasVector`, `deleteVector`, `deleteVectors` | same |
| `searchVectors`, `searchVectorsById` with `VectorSearchOptions` | same; a bare `limit` is also accepted |
| `searchVectorsMultiI8` | same |
| `createGraph`, `hasGraph`, `graphInfo`, `listGraphs`, `deleteGraph` | same |
| `putGraphNode`, `putGraphNodes`, `getGraphNode`, `hasGraphNode`, `deleteGraphNode`, `deleteGraphNodes` | same |
| `putGraphEdge`, `putGraphEdges`, `getGraphEdge`, `hasGraphEdge`, `deleteGraphEdge`, `deleteGraphEdges` | same |
| `graphNeighbors`, `graphDegree`, `graphWalk` | same |
| `putGraphNodesKeyed`, `putGraphEdgesKeyed`, `getGraphNodesKeyed`, `getGraphEdgesKeyed`, `graphNeighborsKeyed`, `graphDegreesKeyed` | same |
| `getGraphEdgePayloads`, `replaceGraphEdgePayloads`, `graphScan`, `graphWalkDirection`, `graphWalkDirectionProfiled` | same |
| `buildFreshGraphKeyed`, `buildFreshGraphPreparedKeyed`, `buildFreshGraphPreparedKeyedWithPayloads` | same |
| `beginFreshBuild` (`FreshBuild`: `tableRows`, `ftsRows`, `graph`, `vectors`, `finish`, `abort`) | same; closing the database aborts an open session |
| `registerFunction(name, arity, fn, options)` | `fn` is `{ module, export }`, run in the worker |
| `reclaimSpace`, `vacuum` | same |
| `backupTo(path)`, `compactTo(path)` (async with progress) | `backupTo(name)`, `compactTo(name)` to a persistent name, with progress |
| `restoreBackup(path, path)`, `restoreBackupToMemory(path)` | same with persistent names |
| `probeFormat(path)` | `probePersistent(name)` |
| `convertSqliteToZova(path, path)` | `convertSqliteToPersistent(name, data)` |
| `migrateDatabase(path, path)` | `migratePersistent(name)`, in place |
| `installExtension`, `dropExtension`, `listExtensions`, `extensionInfo`, `checkExtension`, `checkExtensions` | same, for bundled and statically linked extensions |
| `extensionUpgrade`, `extensionRebuild` | same |
| `LinkedPlugin` (`fromAddress`, `address`) and `ExtensionOptions` (`bundlePaths`, `trustStorePath`) | not applicable: browsers cannot load code at run time; link plugins into the module at build time |
| `verifyExtensionBundle`, `trustExtensionBundle`, `untrustExtensionBundle` | not applicable: there are no `.zovaext` bundles or trust store in a browser |

## Current boundaries

Each of these follows from running in a browser:

- No run-time extension loading (`.zovaext` bundles and their trust store):
  browsers cannot load native code at run time. Link plugins into a custom
  module at build time instead.
- SQL functions are worker modules, not page closures, because SQLite calls
  them synchronously inside the worker.
- One connection per name at a time; no sharing between workers or tabs.
- A named database is one file. Bound stores, which only the Zig API and CLI
  create, cannot come with it, so migrating a database that has them fails
  with `ZOVA_BOUND_STORE_INVALID`.
- There is no Node/CommonJS build; Node and Bun use native `zova-js`.

See the
[extension capability matrix](../../docs/extensions.md#availability-and-binding-matrix).

Memory databases use volatile storage; named databases use the bundled SQLite's
OPFS SAH-pool adapter, not a second engine. The build is single-threaded and
does not require SharedArrayBuffer. Safety traps become worker failures.

## Build and test

Use Zig 0.17.0, Bun, and the pinned Emscripten version in
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
bun bindings/wasm/tools/check-package.mjs /absolute/path/zova-wasm-1.5.0.tgz
bun test bindings/wasm/tests/api.test.ts bindings/wasm/tests/channel.test.mjs
```

`bun run test` in `bindings/wasm` also runs `tools/check-api.mjs`. It fails
when the emitted `dist/index.d.ts` differs from the reviewed
`api/index.d.ts`, or when a public `zova-js` name has no row in the
[Native API parity](#native-api-parity) table. After reviewing an intended API
change, accept it with `bun tools/check-api.mjs --update`.

Test the actual packed and installed artifact with Playwright driving Helium:

```sh
HELIUM_EXECUTABLE=/Applications/Helium.app/Contents/MacOS/Helium \
  sh bindings/wasm/tools/check-browser-package.sh /absolute/external/build-output
```

Local Chromium runs require an explicit Helium executable and use a temporary
profile under the build output directory. They do not download Playwright's
browser. To run the same suites in Firefox, install Playwright's Firefox once
with `bunx playwright install firefox` in `bindings/wasm`, then set
`ZOVA_WASM_BROWSER=firefox`:

```sh
ZOVA_WASM_BROWSER=firefox \
  sh bindings/wasm/tools/check-browser-package.sh /absolute/external/build-output
```

Linux CI installs Playwright's bundled Chromium and Firefox, builds once,
and tests the installed npm tarball in Chromium before uploading it, then in
Firefox. The Firefox step does not block the job yet. Playwright is pinned
in the development lockfile. Native bindings remain independently tested.

Release publication requires a successful Release Artifacts run at the exact
release commit, including the WASM browser job. WASM publication uses trusted
publishing with npm's `next` tag for prereleases (such as `1.0.0-rc.3`) and
`latest` for stable versions (such as `1.5.0`). The dist-tag does not change
the API's stability contract. Publication remains independent
of `zova-js`.

Both paths publish the exact versioned WASM tarball from the verified artifact
run. A retry skips an already-published version only when its registry SHA-512
integrity matches that tarball; a mismatch or registry lookup error stops
publication. Successful retries leave existing dist-tags unchanged, so rerunning
an older release cannot move a tag backwards. No artifacts are overwritten.
Before the first registry release,
the npm package must exist and its trusted publisher must name this repository,
`publish-release.yml`, and the `release` environment. This change does not publish
the package or bump the repository version.

## License

MIT; see LICENSE.
