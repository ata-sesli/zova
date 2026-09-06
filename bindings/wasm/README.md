# Zova browser core spike

Experimental #38 go/no-go proof for the rc.3 WASM preview. This is not yet an
npm package or a supported browser API. Package version remains 1.0.0-rc.2 and
storage format remains 11 while feature work proceeds.

The build emits the real `src/c_api.zig` core for `wasm32-emscripten` using Zig
0.16.0 ReleaseSafe, then links it with bundled SQLite 3.53.4 and a private C
smoke fixture. Emscripten is pinned by `emscripten-version.txt` (6.0.9; the
validated Homebrew build identifies itself as 6.0.9-git).

## Run with Helium

Install the pinned Emscripten version and Bun, then choose an output directory
on the external disk:

```sh
sh bindings/wasm/tools/build-wasm.sh /Volumes/wipesides/codebase-memory-mcp-cache/zova-wasm-38
TMPDIR=/Volumes/wipesides/codebase-memory-mcp-cache/zova-object-1m \
  bun bindings/wasm/tests/browser-smoke.mjs \
  /Volumes/wipesides/codebase-memory-mcp-cache/zova-wasm-38 \
  /Applications/Helium.app/Contents/MacOS/Helium
```

The test launches only the supplied browser, using a separate temporary profile
and a loopback server. It downloads no browser and never uses your browsing
profile. It runs a real dedicated module worker, checks an i64 result crosses
the WASM boundary as `bigint`, and performs ten create/insert/query/close cycles.
Each query checks both the inserted value and the real format-11 metadata.
Close must succeed after statement finalization. The test has a 30-second
deadline and terminates its browser and server afterward.

The report includes observed initialization and ten-cycle smoke duration, not
performance promises. The build prints uncompressed JS and WASM byte counts.

Validated locally with Helium 152.0.7977.64 and Emscripten 6.0.9-git:

| Observation | Result |
| --- | --- |
| Dedicated-worker lifecycle | 10/10 cycles passed |
| Module initialization | 21.5 ms |
| Ten lifecycle cycles | 57.4 ms |
| Uncompressed WASM | 1,447,880 bytes |
| Uncompressed JavaScript | 66,478 bytes |

These are single-run smoke observations, not benchmarks. Native verification
also passed: 772 Zig tests, C/C++ smoke, generated-C symbol parity, 11 raw
`zova-sys` tests, and 56 JavaScript tests.

## Boundaries

- Only the private smoke bridge is exposed to JavaScript. The native C ABI
  retains all existing exports; browser builds select a lifecycle/query subset.
- WASM requires single-threaded compilation and disabled dynamic extensions.
  Native handle mutexes and SQLite thread-safety are unchanged.
- Emscripten's volatile MEMFS supplies SQLite's Unix syscall behavior. It does
  not provide disk persistence, OPFS, or a host filesystem. Do not disable it
  with `FILESYSTEM=0`: no-op syscall stubs can hang SQLite's `robust_open` loop.
- Browser safety violations trap instead of invoking Zig's native panic I/O.
  Zig-side host filesystem operations are unavailable. Graph SQL registration
  stays intact; any profiling timestamps use Emscripten's monotonic clock.
- No pthreads, shared memory, browser persistence, dynamic loading, or alternate
  SQLite engine is added.

The asynchronous bridge/runtime (#41), public SQL/KV package (#40), and packed
artifact browser CI/publication (#39) remain separate work. Those workflows
should consume the pinned SDK version file rather than select `latest`.
