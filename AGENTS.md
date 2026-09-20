# Zova agent guide

## What this project is

Zova is an embedded, local-first data engine built in Zig on bundled SQLite. A
single database can combine ordinary SQL tables with content-addressed objects,
exact vectors, graph topology, binary key-value namespaces, notifications,
bound external stores, migrations, diagnostics, and trusted extensions. The
repository ships a Zig API, stable C ABI and CLI, plus Rust, Python, Go,
JavaScript/TypeScript, and experimental browser-WASM distributions.

The stable public contract is documented in `API_STABILITY.md`. Current package,
ABI, SQLite, and storage-format identities live in `src/version.zig`.

## Repository map: look here first

### Core and storage

- `src/root.zig`: public Zig package surface. It should not become a test-suite
  aggregator.
- `src/zova.zig`: main database facade and cross-subsystem orchestration,
  including transactions, bound stores, migration, fresh-build sessions, copy,
  validation, and repair paths.
- `src/sqlite.zig`: reviewed SQLite connection/statement/value wrapper. New
  ordinary SQLite operations should go through this layer.
- `src/sqlite_array.zig`: bundled SQLite array/carray integration used by
  integer-key batch reads.
- `src/database/`: lifecycle, metadata, paths, backup, validation, bound-store,
  format, migration, and crash-safe migration-publication components.
- `src/version.zig`: package version, numeric ABI version, bundled SQLite
  version, current storage format, and minimum migratable format.

### Data subsystems

- `src/object.zig`: object/chunk/manifest schema and public object operations.
  Chunking implementations are in `object_fastcdc.zig` and
  `object_fixed_chunks.zig`.
- `src/vector.zig`: vector collections, writes, exact search, storage, and
  validation. SQL helpers and virtual-table behavior are in `vector_sql.zig`.
- `src/graph.zig`: graph schema, nodes/edges, keyed batches, payloads, scans,
  traversal, fresh graph loading, and graph-store behavior. SQL-facing graph
  helpers live in `graph_sql.zig`; walk scratch state is in
  `graph_walk_scratch.zig`.
- `src/kv.zig`: namespaced binary key-value operations and atomic batches.
- `src/notify.zig`: transaction-aware same-process notifications.
- `src/statement_cache.zig`: prepared-statement caching and lifecycle rules.

### Extensions, C ABI, and CLI

- `src/extension.zig`: extension metadata and lifecycle foundations.
- `src/extension_plugin.zig`: portable plugin ABI integration.
- `src/extension_dynamic.zig`: trusted native bundle loading.
- `src/trgm.zig`: bundled trigram extension.
- `src/c_api.zig` and `src/c_api_internal.zig`: C ABI export root and shared
  implementation support.
- `src/c_api/`: ABI modules split by database, statement, object, vector,
  graph, KV, notification, extension, fresh-build, handle, and result concerns.
- `include/zova.h` and `include/zova_plugin.h`: public C and plugin headers.
- `src/main.zig`, `src/cli.zig`, and `src/cli/`: CLI entry point, command
  dispatch, parsing, inspect/doctor/salvage/maintenance, and rendering.

### Bindings and browser package

- `bindings/rust/zova/`: safe Rust API; `bindings/rust/zova-sys/`: raw ABI
  selection. The `zova-sys-<platform>` crates contain target-specific generated
  Zova C plus bundled SQLite.
- `bindings/python/`: PyO3 package and Python API. Its `rust/` subtree is a
  synchronized source snapshot, not an independent implementation.
- `bindings/javascript/`: Node-API Rust addon plus TypeScript wrappers in `js/`.
- `bindings/go/`: cgo wrapper over the public C ABI.
- `bindings/wasm/`: experimental browser SQL/KV package, worker/runtime code,
  Emscripten bridge, OPFS integration, and browser durability tests.

### Tests, benchmarks, docs, and release automation

- `src/test_*_root.zig`: focused Zig suite roots. White-box subsystem tests live
  beside production files as `*_tests.zig` or `*_behavior_tests.zig`.
- `tests/`: external CLI, end-to-end, header, C/C++, dynamic-extension, plugin,
  SQLite-capability, and ABI smoke fixtures.
- `bench/`: benchmark programs and retained benchmark notes. Prefer an existing
  harness and fixture over inventing a second one.
- `scripts/`: generated-source checks, compatibility checks, bounded benchmark
  runners, packaging, source verification, and release tooling.
- `docs/`: maintained user documentation. `notes/`: implementation plans,
  investigations, and retained engineering reports.
- `.github/release-notes/`: versioned release notes consumed by publication.
- `build.zig`: authoritative build/test dependency graph and named Zig steps.

## Navigation path for a change

1. Start with the subsystem file above and its adjacent tests.
2. If behavior crosses stores or transactions, inspect the corresponding
   methods in `src/zova.zig` and `src/database/`.
3. For public native behavior, follow the relevant `src/c_api/<area>.zig`
   wrapper and declarations in `include/zova.h`.
4. For language exposure, inspect the safe Rust binding first; Python and
   JavaScript often wrap it, while Go calls the C ABI directly.
5. For version, format, package, or release work, start at `src/version.zig`,
   `docs/storage-compatibility.md`, `scripts/check-versions.sh`, and the release
   workflows. Do not search the whole repository first.

## Scope and design

- Understand the existing implementation before editing it. Prefer the smallest
  coherent change and follow nearby patterns.
- Keep Zova generic. Do not add CBM-specific behavior or modify another
  repository unless the task explicitly includes it.
- Preserve public API behavior, deterministic ordering, transaction semantics,
  bound-store routing, and opaque-key contracts.
- Batch mutations must be operation-atomic, including inside caller-owned
  transactions; use the established transaction/savepoint patterns.
- Private tables and storage details must not leak through public APIs.

## Versions and storage

- Package version, C ABI identity, and on-disk format are separate contracts.
- Never bump the package, ABI, storage format, migration floor, or SQLite
  version without explicit authorization.
- A storage-format change requires schema validation, immutable retained
  fixtures, migration coverage, and updated compatibility documentation.
- Preserve historical release statements when updating current-version prose.
- Put implementation plans and investigation reports in `notes/`; reserve
  `docs/` for maintained user documentation.

## Generated and vendored sources

- Do not hand-edit generated C or bundled binding snapshots.
- Regenerate canonical C with `scripts/update-generated-c.sh` and verify it with
  `scripts/check-generated-c.sh`.
- Synchronize Rust and Python native snapshots through their existing `tools/`
  scripts, then run the matching check scripts.
- Do not edit vendored SQLite unless the task explicitly requires it.

## Verification

- Use the focused Zig suite while developing (`zig build test-graphs`,
  `test-objects`, `test-vectors`, `test-migration`, `test-c-api`, and related
  steps). Keep `zig build test` as the complete Zig gate.
- Use `cargo nextest run`, not ordinary `cargo test`, for Rust test execution.
- Before release work, run `scripts/check-versions.sh` and the complete
  `scripts/check-release.sh` from a clean, synchronized tree.
- Run `git diff --check` before handing off changes.
- Treat `.badbox/` findings as advisory structural evidence, not proof of a bug
  or a replacement for tests and query-plan/performance checks.

## Performance work

- Measure a baseline and candidate under the same build, cache, filesystem, and
  fixture conditions. Include all added preparation work in reported timings.
- Use bounded benchmark scripts, show progress, and state expected resource use
  before launching expensive runs. Do not start multi-hour or very large
  benchmarks without explicit approval.
- Retain an optimization only when parity, correctness, storage, and the stated
  performance gates pass. Do not weaken gates or stack unrelated experiments.

## Git and release safety

- Preserve existing dirty and staged work. Never reset, unstage, rewrite
  history, commit, push, merge, tag, publish, or trigger release workflows
  unless the user explicitly requests that action.
- When release publication is requested, require the exact release commit's CI
  and artifact workflow to succeed before running the publish workflow.
