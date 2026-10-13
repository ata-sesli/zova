# USearch HNSW reference plugin

Approximate vector search over Zova-owned collections, using only the documented
C plugin ABI. The plugin owns a derived persistent HNSW index, not the vectors.
Core exact search is unchanged. This is a reference extension for Zova 1.2.0
(storage format 12); it requires a 1.2.0 or newer host.

## Build and load

Prebuilt bundles are published independently of Zova releases; see
[prebuilt reference extensions](../../docs/extensions.md#prebuilt-reference-extensions).
To build from source instead:

Requires CMake 3.20+, a C++20 compiler and a native Zova build with portable plugin
services. USearch is fetched at an immutable commit with an archive SHA-256;
there is no dependency on an installed USearch, OpenMP or SIMD runtime.

```sh
cmake -S examples/usearch-hnsw -B /tmp/zova-usearch -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/zova-usearch --parallel 2
cmake --install /tmp/zova-usearch --prefix /tmp/zova-usearch-installed
```

Trust the resulting `usearch.zovaext` bundle through the existing extension trust
API, select it explicitly when opening the database, and install `usearch`.
The [extension guide](../../docs/extensions.md) describes the CLI and binding
loading options. A native plugin is trusted process code, not a sandbox.
No browser-WASM bundle is supplied.

## SQL operations

For an existing two-dimensional f32 collection named `points`:

```sql
SELECT zova_usearch_build('points', 16, 64);
SELECT vector_id, distance FROM zova_usearch_search(
    'points', x'0000803f00000000', 10, 128);
SELECT zova_usearch_refresh('points');
```

`build(collection, connectivity, expansion_add)` scans one visible source
snapshot and atomically replaces its derived index/configuration. Its single
TEXT result is JSON with vector count and load, conversion, HNSW construction,
and serialization/private-storage timings in milliseconds. Configuration
changes require this explicit rebuild.

`search(collection, query, limit, expansion_search)` is a readonly table operation.
The query BLOB uses the collection's exact little-endian f32/f16 or signed-i8
encoding. No implicit SQL numeric conversion occurs. Result columns are
`vector_id`, `distance`, `revision`, `delta_count`, `rebuilt`, `reconcile_ms`, and
`search_ms`. Results are approximate; distances of returned candidates are
recomputed in f64 using Zova's semantics: Euclidean L2, negative dot product, or
`1 - cosine_similarity`. Results sort by distance, then BINARY public vector ID.
This tie-breaker orders the selected candidates; it does not promise exhaustive
selection of every tied vector. Higher expansion generally improves recall at
greater search cost. Original stored values are never quantized or replaced.

`refresh(collection)` incrementally applies the current final values of changed
IDs to a prospective copy of the persisted HNSW generation, then persists once
for the batch. Deletions remove labels; replacements reuse identity labels; new
IDs receive internal labels. Its JSON result reports changed IDs, reconstruction,
index-maintenance and persistence times. It does not copy/serialize an index per
source row. If history is unavailable or the collection incarnation/configuration
changed, it reconstructs from the caller's visible source. Long-lived identity
tombstones compact through that same bounded reconstruction path.

## Automatic maintenance and transaction correctness

Every search uses generic source-local change tracking to exclude removed/stale
base entries and score all visible additions/replacements in a call-local delta.
Applications need not refresh after each write for correct visibility. Delta
scoring is exact; unchanged-base candidate selection remains approximate.
Repeated history IDs are deduplicated to their final authoritative values.

The immutable connection cache holds at most one persisted base. Its identity
includes persisted bytes, configuration and source incarnation/revision/branch
token. A search always validates coverage in its own snapshot. Provisional
changes never update a shared newest index; rollback and older WAL readers do
not inherit another transaction's vectors. Missing/divergent/retired history
causes reconstruction in the same snapshot, never silent omission of changes.

Build/refresh join the host's operation savepoint. Failed source reads, allocation,
private writes or result delivery publish no successful generation. A successful
call inside an outer transaction is provisional until that transaction commits.
Readonly connections can search and reconstruct in memory, but cannot build or
refresh persistent state. Bound vector stores route through the host services.
Source/journal writes share their own file; plugin storage is in the main file.
This does **not** promise cross-file WAL crash atomicity: every reuse validates
source coverage, and a mismatched generation reconstructs or fails explicitly.

## Persistence, recovery and limits

The private stored-data version is 1.0.0, separate from plugin code version.
The representation includes source coverage/configuration, public-ID-to-label
mapping, and pinned USearch serialization in 256 KiB database BLOBs. It is part
of normal database backup/restore; no sidecar index file is written. Reopen
validates derived bytes and graph links before upstream allocation/deserialization.
The checksum detects accidental corruption, not hostile modification.

Explicit extension rebuild repairs derived indexes from the source while
preserving their configured connectivity/expansion. Malformed configuration or
missing source data fails without partial repair. No plugin salvage-copy hook is
claimed; recover the authoritative collection and rebuild its derived index.

Current bounds: 100,000 identity slots, 4,096 dimensions, 32 MiB converted vector
matrix and 64 MiB serialized generation per collection, at most 256 persisted
collections, one ANN thread. Connectivity is 2..64; expansion_add must be at
least connectivity and at most 1,024. Search limit is 1..4,096; expansion_search
is at least limit and at most 100,000. NaN/Inf and zero-norm cosine inputs fail.
Delta conversion is separately bounded to 32 MiB of changed vector values;
deletions hold no values and do not count. These bound plugin-owned
representations, not whole-process RSS; copying, serialization and SQLite caches
also consume memory. Large retained deltas increase search cost; refresh/build
is the explicit way to amortize them. No latency/recall guarantee for arbitrary
datasets is inferred from the small reference benchmark.

## Tests and bounded profiling

`python scripts/check-usearch-hnsw.py OUTPUT --packages PACKAGE_CHECK_OUTPUT`
builds and checks real packaged plugins through C++, safe Rust, Go/cgo, an
installed Python wheel, and installed npm packages under Node and Bun.
Native package CI runs this on all supported native targets. The test covers
main/bound sources, mutations, rollback, snapshots, reopen, readonly search,
history retirement, type/metric parity, malformed input and fault cleanup.
`--sanitize` checks the adapter/dependency with Clang ASan/UBSan.

`--bench` adds only 2,048 vectors x 32 dimensions: one warmup, three measured
build/update samples, 40 searches, recall@10 against Zova exact search, DBSTAT
(including autoindexes), final file size and peak RSS where available.
Use an external output directory and existing caches locally. Commit cost is
reported separately and included in complete publication time.

## Dependency and license

USearch v2.26.4, commit `1e8a19253138510f35ee2c68dc641e5b5c83c7b5`, Apache-2.0.
Archive SHA-256: `298ced4f07dddd9e9d9f9228283da179c10664817c64b84497ec8a91ae1246aa`.
The bundle includes USearch's license and Zova's MIT license. The build applies
one checked compatibility edit: its key-map allocator is switched from throwing
`std::allocator` to USearch's nullable allocator. This prevents a demonstrated
OOM abort inside its `noexcept` reservation path. No algorithm or serialization
layout is changed. Upstream updates require rerunning the allocator, serialized
preflight, snapshot, fault and recall tests; changing stored representation needs
an explicit plugin data-version upgrade.
