# Zova for JavaScript and TypeScript

Synchronous and queued asynchronous Node-API bindings for Zova. The package is
built with napi-rs, uses the same native Zova engine as the Rust, Python, Go,
Zig, and C APIs, and ships TypeScript declarations.

The package is not published yet. Its external npm name remains unapproved;
local development currently uses the placeholder package name `zova`.

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
bun test
```

Node and Bun load the same `.node` addon:

```sh
node tests/runtime-smoke.mjs
bun tests/runtime-smoke.mjs
```

After publication, installation will use the final approved npm name:

```sh
bun add zova
# or
npm install zova
```

## SQL and transactions

```ts
import { Database, Step } from "zova";

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
- objects, manifests, chunks, range reads, assembly, and `ObjectWriter`
- f32/f16/i8 vector collection lifecycle, batch writes/deletes, and exact search
- public graph CRUD, atomic batches, neighbors, degree, and walks
- bundled extension install/list/info/check/drop

The advanced opaque-key, graph-scan, edge-payload, and fresh-build APIs remain
available through Zova's C ABI and raw `zova-sys`; they are intentionally
deferred from the JavaScript package.

## Queued async work

`AsyncDatabase` is separate from `Database`. It serializes operations FIFO,
runs native work on Node's worker pool, rejects new calls as soon as close
begins, waits for already queued work, and closes exactly once.

```ts
import { AsyncDatabase } from "zova";

const db = AsyncDatabase.create("app.zova");
await db.exec("create table notes(body text)");
const id = await db.putObject(new TextEncoder().encode("large bytes"));
const bytes = await db.getObject(id);
await db.close();
```

Queued work also includes backup/compact/restore, vector batches and searches,
and graph batches and walks. Inputs are copied before worker execution.

Async transaction callbacks and prepared statement handles are intentionally
not exposed.

## Ownership

Every native child has explicit cleanup. Call `Statement.close()`,
`ObjectWriter.close()`/`cancel()`, and `Database.close()` yourself. Node-API
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

- JavaScript-authored SQLite callbacks
- extension authoring or dynamic `.zovaext` loading
- async transaction callbacks
- direct Bun FFI
- zero-copy native output
- browser/WASM builds
