# NetworKit PageRank reference — issue #140

Implementation baseline: `1f50549`, branch `work/networkit-pagerank-140`.
Package/ABI remain **1.1.0**, plugin ABI **1**, storage format **12**.
No CBM files, persistent schema, or public declarations changed.

## Implementation

`examples/networkit-pagerank` builds a separate trusted C++ plugin using the
documented C graph-data and operation services. NetworKit 11.2.2 is pinned to
`6b3878ee00a6eadd50be3b3047fbcae56bcac685`; its TLX dependency is pinned to
`2dd63ab839909f0b43cd02108a1869c4670b2c8e`. CMake verifies archive SHA-256
checksums and compiles only nine upstream implementation files. The installed
bundle includes NetworKit's MIT, TLX's Boost, and Zova's MIT licenses.

SQL entry point:

```sql
SELECT node_key, node_id, score, iterations, converged
FROM zova_networkit_pagerank('links', 0.85, 1e-10, 200, 10000, 100000);
```

The plugin maps opaque keys into dense library indices, retains directed typed
edge multiplicity as weights, redistributes dangling probability, normalizes
scores, and separately checks the final L1 convergence residual. Empty graphs
return no rows. Output follows node creation order. Each cursor materializes
one snapshot; there is no persistent index or cross-call cache.

Limits: 250,000 nodes, 1,000,000 edges, 1,000 iterations, and a 100-million
`(nodes + edges) * max_iterations` work ceiling. Scans use 256-row/1-MiB pages.
Computations are serialized within the module and use one OpenMP worker,
restoring the calling task's thread budget and preserving its SIGINT handler.
Cancellation is checked during host scans/result delivery, not asynchronously
inside NetworKit's bounded iteration. These limits are not an RSS sandbox.

OpenMP is a shared toolchain runtime. A privately copied macOS libomp caused a
duplicate-runtime abort in the fault test; that packaging approach was removed.
Authors must select one compatible application-wide runtime. This reference is
not a self-contained universal binary or a bundled Zova extension.

## Host fix exposed by the reference

Read-only bound-store reopen initially failed because `query_only` also rejects
Zova's TEMP operation-generation markers. Registration now lifts that flag only
for its fixed TEMP statements, under an authorizer that rejects persistent
writes, trigger/view origins and arbitrary functions. Protection is restored
before any plugin callback. A regression verifies read-only reopen, rejection of
main/bound/TEMP writes, and rejection of a TEMP trigger redirecting a marker to
persistent storage on a caller query-only writable connection. No metadata
format or plugin ABI changes were needed.

## Verification

- Extension suites: **95 passed, 3 skipped** (98 total), ReleaseSafe.
- C API suite: **239 passed, 3 skipped** (242 total), ReleaseSafe.
- C/C++ ABI smoke and generated-C symbol parity: passed.
- Actual plugin: cycle/dangling/isolated/empty/self-loop/weighted analytic scores,
  key and public-ID mapping, deterministic ordering, iteration/size limits,
  errors, early finalization, read-only reopen and caller rollback passed.
- Main and bound-store two-connection WAL tests: old snapshots stay unchanged
  after a writer commits, then see new topology after the reader commits.
- Real plugin fault-boundary test: partial host OOM/cancellation/SQL failure,
  invalid endpoint mapping, failed result delivery/retry, EOF, thread restoration
  and signal-handler preservation passed.
- Safe Rust nextest, Go/cgo, installed Python wheel, installed npm under Node
  and Bun: PageRank SQL consumers passed.
- ASan/UBSan real-plugin fault test: passed (leak detection disabled).
- Rust native and Python source-snapshot checks: passed after synchronization.
- Rust formatting and `git diff --check`: passed.

Local execution was **macOS arm64**, Zig **0.17.0**, Apple Clang **17**, CMake
**3.31**, ReleaseSafe host / Release C++ plugin. CI now adds the reference to the
existing five native-platform package jobs; Linux/Windows results are not claimed
from this local run. The complete Zig umbrella and release suite were not run.

## Bounded profile

Actual generated-C C ABI, external-disk fixture: **2,048 nodes / 8,192 edges**,
including dangling nodes and a high-degree source. One warmup, three samples,
one compute worker. All times are milliseconds.

| Sample | Scan/copy | Conversion | NetworKit | Result construction | Complete SQL call |
|---|---:|---:|---:|---:|---:|
| 0 | 3.349542 | 0.923459 | 0.443750 | 0.185458 | 13.224750 |
| 1 | 3.369458 | 0.932833 | 0.446875 | 0.186333 | 13.295791 |
| 2 | 3.340292 | 0.921500 | 0.445084 | 0.186166 | 13.224667 |

Complete-call median: **13.224750 ms**; MAD: **0.000083 ms**.
Peak process RSS: **8.672 MiB**, including the host and preceding correctness
fixtures. Complete time includes preparation, every row/key/ID/score copy, EOF,
and statement finalization. The four internal timings exclude SQL delivery and
some cleanup; their sum is not the complete-call cost. Three samples support
only a small diagnostic, not p95 or large-graph performance guarantees.

Plugin SHA-256:
`747ae6e32c5e6f62d4c7b048e90b963ee4a4d9a96984dd43f9bb9fca59045140`.
Raw logs reside under
`/Volumes/wipesides/codebase-memory-mcp-cache/zova-1.1.0-release/zig17-verification/issue140/`:
`complete-3.log`, `final-checks.log`, and `final-tail.log`.

Reproduce using `scripts/check-networkit-pagerank.py` as documented in the
reference README. This report records verification performed before publication.
