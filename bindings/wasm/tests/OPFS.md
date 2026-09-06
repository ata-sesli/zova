# OPFS integration spike (#64)

This is a private go/no-go fixture, not the public persistent database API.
The normal `zova-wasm` package remains memory-only. Only the test build sets
`enable_wasm_opfs`; native builds retain their existing filesystem paths.

## Exact source and runtime

- SQLite 3.53.4, source ID
  `bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc`.
- Upstream archive: https://github.com/sqlite/sqlite/archive/refs/tags/version-3.53.4.tar.gz
- Archive SHA-256: `16bc1b2027ba2653e3d262e740376be23f67cad77865db814493267494326c3c`.
- Emscripten 6.0.9, Zig 0.16.0, Playwright from the package lockfile.

The upstream `sqlite3-wasm.c` includes **Zova's vendored sqlite3.c**. It replaces
the standalone amalgamation compilation in this fixture: there is exactly one
SQLite engine in the module. Zova's target-generated C links to that engine.
Upstream bootstrap, whwasmutil, jaccwabyt, C API glue, VFS helper and SAH pool
JavaScript are preprocessed with upstream c-pp. No independent sqlite3.wasm is
loaded. The upstream bare-bones export list plus its retained WASM helper
exports supplies the struct/function-table glue. Table growth supports JS VFS
callbacks; memory growth remains enabled.

These broader SQLite exports and test entrypoints are private to the spike,
not additions to include/zova.h or the public browser package. The fixture
uses the upstream SQLite WASM configuration (including DQS=0 and omitted UTF16,
shared-cache and dynamic-loading code), with a 4096-byte default page size.
Native SQLite configuration is unchanged. Public packaging work must account
for these differences rather than silently treating the two builds as equal.

## Reproduce

Use an external disk for source, outputs, caches and browser profiles locally.
Install the existing WASM development dependencies first. Download/extract the
archive above, verifying its SHA-256 before extraction. Then, from the repo:

```sh
# Set these to directories on the external disk:
export SQLITE_SOURCE=/absolute/sqlite-version-3.53.4
export SPIKE_OUT=/absolute/zova-opfs-spike
export CORE_CACHE=/absolute/existing-wasm-core-output
export EM_CACHE=/absolute/existing-emscripten-cache
export TMPDIR=/absolute/existing-browser-tmp

bun bindings/wasm/tools/build-opfs-spike.mjs "$SQLITE_SOURCE" "$SPIKE_OUT" "$CORE_CACHE"
HELIUM_EXECUTABLE=/Applications/Helium.app/Contents/MacOS/Helium \
  bun bindings/wasm/tests/opfs-browser.mjs "$SPIKE_OUT"
```

The source ID is checked against the vendored header. The SDK version is
checked. The script builds fresh Zova C, using CORE_CACHE only for Zig caches.
It does not copy a prior generated-C artifact. Linux CI may use Playwright
Chromium with CI=true; local runs require explicit installed Helium.

## Proven and bounded

The browser fixture runs these phases in separate workers using the same OPFS
directory: create and write SQL/KV, reopen and compare, begin an uncommitted
spilling write and terminate, then reopen and check original values/integrity.
The spilling transaction adds only 128 4-KiB blobs with a one-page cache.
It also checks ordinary rollback, DELETE journal mode, FULL synchronization,
in-memory format-11 lifecycle, and rejection of a competing pool owner.

SAH pool holds exclusive access handles for its **whole pool**, not just the
currently open database. A database close does not release the pool; worker
termination does. The observed competing-worker error is
`NoModificationAllowedError` from `createSyncAccessHandle`. Per-database pool
isolation, deterministic public errors and lifecycle ownership belong to #66.

Upstream xSync calls SyncAccessHandle.flush and propagates failure as
SQLITE_IOERR. This spike selects rollback-journal DELETE/FULL, not WAL. The
termination test covers an uncommitted spill with recovery, not browser/OS
power loss or every crash boundary. Quota and injected flush failures remain
in #67. No unload-time save is used.

The origin must provide OPFS sync handles in a dedicated worker (localhost or
an appropriate secure context). No SharedArrayBuffer, pthreads or COOP/COEP
headers are used. Browser quotas, eviction and private-mode differences remain
part of the later public contract.

Zova creation/opening normally does filesystem preflight through Zig I/O,
which is deliberately failing in the browser build. The spike instead checks
the registered default opfs-sahpool VFS and refuses a MEMFS fallback, then uses
the existing Zova creation/schema-validation path. This is not yet a complete
atomic create-or-open API: failure cleanup, input names and unsupported-file
behavior need the public lifecycle implementation in #65.

## Local evidence (2026-09-07)

- Before the path integration: real OPFS registration succeeded, but Zova
  create returned ZOVA_CANT_OPEN (13).
- After integration: SQL/KV reopen, rollback, worker-termination recovery,
  integrity, memory lifecycle and competing-pool rejection passed in Helium.
- Native core: 178/178; native KV: 29/29.
- Native C API: 228/228; C ABI and header smoke checks passed.
- Spike WASM: 1,596,117 bytes; SHA-256
  `7f27578a8f207a0c3affb8626d2504a31fa9cbf76383399f74600c366d3ff732`.

This is feasibility evidence, not a persistence release guarantee or benchmark.
