# Extension authoring and release acceptance

This guide describes development for **1.2.0**, not an already-published release.
The source package and application ABI remain 1.1.0; storage format is 12.
Published 1.1.0 artifacts do not acquire these capabilities retroactively.
The detailed contracts and CLI commands are in [Extensions](extensions.md),
and exact C layouts, statuses and limits are in `include/zova_plugin.h`.

## Ownership and scope

Zova owns authoritative graph nodes/edges, vectors, validation, transactions
and bound-store routing. A plugin may own derived indexes/results, private
`_zova_ext_<name>_...` storage and working memory. It must access source data
through host services, never private core tables or a raw SQLite handle.
Installing an approximate algorithm does not change core exact search.

Native code is trusted process code. Hashes detect changed bundle contents;
neither hashes nor capability declarations sandbox CPU, memory or filesystem
access. No automatic network fetching, signing or permission enforcement is
promised. Verification can execute library initializers. Trust and select code
explicitly at create/open, and provide it on every later open of installed data.

## Start with the common C ABI

Export `zova_plugin_entry_v1(uint32_t)` with the platform C calling convention.
Return a descriptor only for a supported ABI, set `struct_size`, and declare
every required service in `flags`. Check the extended host size before reading
`get_service`; negotiate the service ID, version and minimum structure size.
An unsupported required service fails before lifecycle hooks run. Code version,
plugin ABI, application ABI and private stored-data version are separate.

Start with the buildable C/Zig query/echo examples, then use the C++ references:

- [C query/echo plugin](../examples/plugin_query.c): public header only.
- [Zig query/echo plugin](../examples/plugin_query.zig): standalone
  `src/extension_plugin_api.zig` helpers over identical C layouts.
- [NetworKit PageRank](../examples/networkit-pagerank/README.md): C++ graph
  scans, bounded computation, typed SQL table rows and no persistent index.
- [USearch HNSW](../examples/usearch-hnsw/README.md): C++ persistent derived
  index, source history, automatic reconciliation, refresh/rebuild and recovery.

From the repository, compile both small examples and the package fixtures:

```sh
zig build plugin-package-fixtures -Doptimize=ReleaseSafe -j2 --prefix /external/plugin-examples
python3 scripts/check-plugin-packages.py /external/new-plugin-check --prepare-only
```

The first command installs C/C++ libraries and both C/Zig author libraries.
The second uses a new output directory, creates manifests/trust stores, and
loads the examples in an actual generated-C C-ABI host. It executes echo/query,
checks close-with-live-statement behavior and read-only reopen. The examples
intentionally share the fixture name `c_test`; load only one at a time. They
create an empty private table; the consumer inserts `id=1` before calling check.
They are teaching examples, not production recovery/index implementations.

An external C/C++ author needs the public plugin header and their compiler,
not engine/SQLite headers. A Zig author can vendor the standalone helper at a
compatible version. Other native languages are equally valid if they preserve
C layouts, calling conventions and unwind rules. Follow the two reference
READMEs for external CMake builds and pinned dependency/license packaging.

## Host services and SQL operations

| Service v1 | Purpose | Author responsibility |
| --- | --- | --- |
| Query | Parameterized read-only SQL with typed row callbacks | No side-effecting functions; discard partial delivery on error |
| Diagnostics | Copy current SQLite error into a bounded caller buffer | Copy promptly; it is not a retained error object |
| Data | Graph scans, keyed reads, adjacency, vector metadata/reads/scans | Treat keys as opaque; copy borrowed bytes if retained |
| Storage | Parameterized reads/writes to declared plugin-owned main tables | Qualify `main.<private_table>`; no core/other-owner access |
| Operations | Register typed scalar or streaming table operations | State exact/approximate semantics, metrics, ordering and limits |
| Vector maintenance | Snapshot-visible incarnation/revision/token and bounded history | Validate coverage; reconstruct or fail on missing/divergent history |

Expose algorithms through ordinary SQL statements. Local operation `rank` in
extension `example` becomes `zova_example_rank`. Scalar callbacks deliver one
typed value; table callbacks use `open`/`next`/`close`. Mutating scalars declare
`MUTATING`, use a standalone SELECT and write only private storage. Table
operations are read-only. Applications use SQL `ORDER BY` for result ordering;
`ORDERED` describes plugin emission, not a substitute for SQL ordering.

Host/context/service pointers are borrowed only during the current callback,
on its thread. Row values/bytes are borrowed only until that row callback
returns. Registration copies metadata; operation state transfers to the host
only on success, and receives exactly one destroy call. On registration failure
the plugin retains cleanup responsibility. Cursor close runs on completion,
LIMIT, reset, finalization and error. Keep code loaded until statements and the
connection close. Never reenter public Zova APIs or host services from a row
callback. Catch C++ exceptions and Rust panics; translate recoverable Zig errors
to statuses. A native crash/panic/abort cannot be rolled back by the ABI.

## Transactions, maintenance and recovery

Host operations pin the caller's visible source snapshots, including bound
stores and earlier caller writes. Lifecycle/private mutations use transactions
or savepoints; failure preserves earlier outer-transaction work. Successful
results inside a caller transaction remain provisional until commit. Plugins
must not issue BEGIN/COMMIT/SAVEPOINT or mutate authoritative data through SQL.
Read-only opens can query/reconstruct in memory, not persist new derived data.
Filesystem or network side effects are not undone by SQL rollback.

For vectors, source mutations and the bounded journal commit in the same source
file. History is retired in bounded batches (at most 4351 records per collection).
Use incarnation, revision and branch token to detect recreation, rollback and
divergence. `HISTORY_UNAVAILABLE` requires reconstruction from the current visible
source or an explicit error, never an empty delta. Never share a mutable newest
cache with an older WAL reader. USearch demonstrates immutable persisted bases
plus call-local deltas, then one transactional refresh per batch. Graph scans
provide snapshot consistency, not a generic graph change journal.

Private index data lives in the main file while a bound source may have its own
WAL. This does **not** promise cross-file crash atomicity. Validate source
coverage before reusing persisted generations after reopen/recovery. Backups
and restores retain database-owned extension data, not executable code or trust.
Provide the selected code for verification. Code-only updates can declare
compatible data; representation changes need explicit atomic data upgrades.
Implement check/rebuild/salvage as appropriate. USearch repairs derived data
from authoritative vectors but does not claim salvage-copy support.

## Budgets and diagnostics

Query/storage: at most 256 parameters, 128 columns, 4096 rows and 1 MiB
SQL/input/delivery budgets. Data calls: at most 4096 inputs/outputs and a 1 MiB
delivery budget. Operations: at most 32 arguments, 64 columns and 1 MiB input
or individual row. Diagnostics: at most 1024 bytes, length-delimited. See the
header for how descriptor bytes contribute to each budget.
Limits and callback cancellation may follow earlier delivered rows: discard
partial output on failure. These bounds do not cap arbitrary native CPU, SQL
workspace or total process RSS. Authors must declare algorithm memory/work
limits and expose useful errors/timings. The references document concrete bounds
and cancellation points; inclusion does not imply general performance guarantees.

## Support and compatibility

The **1.2.0 target** supports the documented common C ABI v1: descriptor/service
negotiation, typed SQL operations, ownership/lifecycle, private data compatibility
and snapshot-aware maintenance. Additive service negotiation does not allow
changing an existing layout or callback contract. Use a new version for an
incompatible interface. Raw Rust declarations and idiomatic Zig helpers share
the same boundary. A plugin's own SQL/configuration/data compatibility remains
that author's responsibility, not Zova's core API promise.

| Surface | Development capability | 1.2.0 boundary |
| --- | --- | --- |
| C/C++/Rust/Zig author using C ABI v1 | All six negotiated services | Documented common ABI; no raw engine access |
| Native CLI and C ABI | Explicit trusted bundles and lifecycle/upgrades | Supported native loader contract |
| Generated-C C ABI / raw `zova-sys` | Same native loader/services | Compiler/target-matched artifacts |
| Safe Rust, Python, Go, Node/Bun `zova-js` | Explicit bundle selection; SQL invocation | No high-level plugin callback-authoring wrapper |
| Legacy Zig descriptors/bundle producer | Existing native path retained | Experimental external authoring; not a second stable ABI |
| NetworKit/USearch references | Separately built, explicitly trusted | Reference SQL/configuration/storage remain experimental |
| Browser `zova-wasm` | No native plugin loader/author API | Experimental browser SQL/KV boundary unchanged |

| Native target | Native and generated-C loader | Packaged consumer CI |
| --- | --- | --- |
| Linux x86_64 / arm64 | Yes | Rust, Go, Python wheel, Node/Bun tarball |
| macOS x86_64 / arm64 | Yes | Rust, Go, Python wheel, Node/Bun tarball |
| Windows x86_64 | Yes | Rust, Go, Python wheel, Node/Bun tarball |

A bundle binary must match OS, CPU, deployment target and runtime ABI.
Package required sibling libraries and their licenses; bundle-relative loading
and content hashes include dependencies. NetworKit also needs one compatible
application OpenMP runtime, not separately duplicated runtimes per plugin.
Unsupported services/versions are errors, not silent fallback. Loader-disabled
builds cannot use bundles. No universal binary or browser native loading is promised.
Bundled `trgm` remains unchanged: its fuzzy overlap/similarity ranking is not
SQLite FTS5's substring trigram tokenizer.

## Release gates

```sh
python3 scripts/check-extension-release.py /external/new-extension-release-check
sh scripts/check-release.sh
```

The extension gate reuses existing package/reference runners with two build
jobs and no opt-in benchmarks. It verifies real C/C++ bundles and dependencies,
C/Zig author libraries, generated-C loading, safe Rust, Go/cgo, an installed
Python wheel and npm tarball under Node/Bun, plus both reference algorithms.
Tests include graph/vector source parity, maintenance, rollback, WAL snapshots,
reopen, read-only/bound stores and fault cleanup in the respective reference
suites. Cross-platform CI runs the same gate; immutable extracted Rust crates
also execute the real plugin-loading fixture. Zig extension/C-ABI and generated-C
parity gates remain required, not replaced by package smoke.

Normal release smoke invokes this gate and builds a local ReleaseSafe archive.
Actual release-artifact jobs additionally load C/C++/Zig bundles through the
packaged native archive on Linux/macOS with system C/C++ linkers and Go/cgo
(#130; Linux explicitly uses GCC). Windows uses its compiler-matched generated-C
package gate; a system-linker native Windows archive gate is not claimed here.
Artifact checks build/test only: they do not publish, tag, bump versions or grant
trust to user bundles. Every release still requires the exact release commit's
CI/artifact checks before publication; a source declaration is not artifact proof.
The actual release Python ABI3 wheel also executes the plugin fixture under both
3.13 and 3.14 before upload. The assembled release npm tarballs execute installed
Node/Bun consumers on Linux; the cross-platform package gate covers each native
target separately. No cross-platform coverage is inferred from the Linux result.
