# USearch HNSW #141 implementation and bounded verification

Date: 2026-10-11. Branch: `work/usearch-hnsw-141`.
Baseline: `11ccd0a2ad27a973d4a0a0d885b9dcaa7780c6c4` (merged #140).
Verification was performed before publication. Package/application ABI 1.1.0
and format 12 remain unchanged.
No CBM, core schema, public header, or generated binding snapshot changes.

## Implementation

Separate C++ reference bundle `examples/usearch-hnsw`, using public plugin
services 3/4/5/6 only. Immutable USearch v2.26.4 pin:
`1e8a19253138510f35ee2c68dc641e5b5c83c7b5`, Apache-2.0.
Archive SHA-256:
`298ced4f07dddd9e9d9f9228283da179c10664817c64b84497ec8a91ae1246aa`.

SQL build, approximate search and persistent incremental refresh. Search
automatically reconciles final source values: additions/replacements are scored,
deleted/stale base entries are excluded. Refresh copies a prospective generation
once per batch, applies removals/replacements/additions and persists it once.
Source incarnation/revision/branch tokens protect rollback, recreation and old
snapshots. Missing/divergent/retired history reconstructs the caller-visible
snapshot. A cache holds one immutable persisted base, never a shared newest delta.

Owned private tables store configuration/coverage and chunked serialized HNSW
plus public-ID mapping. No sidecar file. Existing atomic host operations protect
private writes and result delivery. Explicit recovery rebuild repairs derived
indexes from authoritative vectors. No salvage-copy hook is claimed.

One dependency compatibility edit is applied only to the build copy: the
USearch key map uses its nullable allocator instead of throwing std::allocator.
A deterministic allocation test reproduced an abort in its noexcept reservation
path before this edit. There are no algorithm or serialization layout changes.

Serialized metadata, matrix sizes, identity labels, node levels, entry level and
adjacency references are checked before upstream loading. A recomputed-checksum
forged entry-level test initially failed, then passed after tightening that check.
Checksums detect accidental corruption, not authenticated provenance.

## Verification

- Real C ABI C++ consumer: main and bound vector stores, all nine type/metric
  combinations, ties, empty indexes, duplicate put-many final occurrence,
  idempotent delete-many, automatic reconciliation and persistent refresh.
- Caller writes, savepoints, rollback/reused revisions, provisional generations,
  runtime SQL failure preserving earlier caller work, failed build and refresh.
- Two-connection old WAL snapshot, committed visibility, history retirement,
  collection recreation/configuration changes, reopen and readonly operations.
- Corruption recovery rebuild, verified backup and registry-aware CLI restore.
- Partial host delivery OOM/cancellation, 12 deterministic C++ allocation
  failures, cursor/output cleanup, canceled row delivery and serialized faults.
- AddressSanitizer/UBSan behavior and fault checks passed on macOS ARM64.
- Safe Rust nextest consumer: 1 passed. Go/cgo consumer passed. Installed Python
  wheel and installed npm package under both Node and Bun passed.
- `zig build test-extensions test-vectors test-c-api -j2 --summary all`:
  401 passed, 6 skipped (407 total): extensions 39/42, plugin ABI 56/56,
  vectors 67/67, C API 239/242. 27/27 build steps succeeded.
- Rust formatting, Go formatting and git diff --check passed.

The cross-platform native-plugin CI matrix now runs the USearch runner. Linux
x64/ARM64, macOS Intel and Windows executions remain pending; no remote CI was
triggered. Full unrelated suites and generated-C regeneration were not rerun:
core/API/native source declarations did not change. The locally checked host and
installed generated-C packages from #140 were reused.

The plain C restore request has no external-registry selection and rejects this
required plugin as unavailable, even with NO_VERIFY. This existing boundary is
not bypassed or altered: the runner uses the existing registry-aware CLI restore
with default verification and checks results after reopening the restored file.

## Bounded measurements

AppleClang 17.0.0, C++20, CMake Release (`-O3 -DNDEBUG`), SIMD dependencies and
OpenMP disabled, one ANN thread. Host Zig 0.17.0; existing ReleaseSafe generated-C
archive. Seed 0x5a6f7661, 2048 f32 L2 vectors, 32 dimensions, k=10, expansion=128.
One warmup then three measured build/update samples, 40 query pairs. All artifacts
and caches on `/Volumes/wipesides`; no large repository benchmark was run.

Milliseconds; build includes validation, source scan/conversion, HNSW construction,
serialization/private storage, SQL result processing and outer commit:

| Sample | Load | Conversion | HNSW build | Persistence | Commit | Complete build |
|---|---:|---:|---:|---:|---:|---:|
| 0 | 1.174830 | 0.124331 | 54.287200 | 2.096830 | 2.943583 | 60.850458 |
| 1 | 1.193390 | 0.127985 | 54.215900 | 2.087830 | 3.302542 | 61.155792 |
| 2 | 1.110410 | 0.126118 | 54.013000 | 1.999080 | 3.484834 | 60.935959 |

Complete build median 60.935959 ms; MAD 0.085501 ms. Reported phases do not
include every metadata/registration/parameter/result-processing cost; complete
wall time includes them. Phase sums are not presented as exact reconciliation.

Incremental samples each include 16 authoritative puts, search reconciliation,
persistent refresh, confirming search and outer commit:

| Sample | Refresh load/copy/apply | Persistence | Commit | Complete update |
|---|---:|---:|---:|---:|
| 0 | 2.169500 | 1.954790 | 3.252083 | 11.171417 |
| 1 | 2.229790 | 1.976500 | 3.089958 | 11.082208 |
| 2 | 2.124460 | 2.020290 | 2.680208 | 10.731625 |

Complete update median 11.082208 ms; MAD 0.089209 ms. Refresh reconstructed=0
and changed IDs=16 for every sample. The index timing includes loading, delta
conversion, copy and HNSW updates, not only the algorithm's add/remove calls.

| Query path | p50 ms | p95 ms | Recall@10 |
|---|---:|---:|---:|
| Complete plugin SQL search/result consumption | 0.267313 | 0.303917 | 1.000000 |
| Core exact C API search/result allocation/free | 0.598874 | 0.644208 | Reference |

These are different application surfaces and one small synthetic workload,
not a general speedup/recall guarantee. The log retains all 40 individual pairs.
Peak process RSS 14.188 MiB. Final fixture file 1,212,416 bytes, including source,
other correctness fixtures, retained journal and derived storage.

Plugin DBSTAT attribution includes automatic indexes via sqlite_schema ownership:
The native fixture queries Zova's bundled SQLite, not the runner's Python
SQLite, whose optional DBSTAT support varies by distribution.

| Object | Bytes |
|---|---:|
| Generation chunks table | 598016 |
| Generation metadata table | 4096 |
| Chunks primary-key autoindex | 4096 |
| Metadata primary-key autoindex | 4096 |
| Total derived plugin pages | 610304 |

Bundled dylib: 308840 bytes; SHA-256
`ebca1ef696d5c4d9d5aaab1e9dc6f4bf280ffb1e662ff1145585dfc2c51b0d08`.
DBSTAT is not the entire file footprint: freelist/WAL and other schema objects
are not included in the derived subtotal.

## Evidence and reproduction

Runner: `scripts/check-usearch-hnsw.py`; usage/limits: reference README.
Final complete log (all individual query samples and installed consumers):
`/Volumes/wipesides/codebase-memory-mcp-cache/zova-1.1.0-release/zig17-verification/issue141/report-run.log`.
Host-service suites: same directory, `zig-checks.log`.
Sanitizer build: `sanitize-3`; focused final behavior log `sanitizer-verified.log`.
The later duplicate batch/initially-empty-refresh test also passed under that
same sanitizer build. Earlier failed runs are retained for diagnosis, not mixed
into the final measurement table.
