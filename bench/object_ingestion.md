# Issue #44: bounded object-ingestion experiment

## Decision

Retain only moving chunk counting after the existing-object check. FastCDC duplicate median fell from 1.022870 to 0.497104 ms (51.4%). Do not claim a fresh-put speedup. No new allocation, public API, format, chunk policy, or durability change.

Keep the fresh counting pass: buffering chunk descriptors adds allocations proportional to the number of chunks; inserting placeholder metadata adds an update and exposes incomplete metadata to SQL triggers. Neither tradeoff is justified here. The existing insertion pass already shares each chunk hash between chunk and manifest insertion.

Reject borrowed payload bindings in this experiment. Relative to counting-only, fixed-profile fresh median increased from 4.530959 to 4.832250 ms (6.6%). FastCDC fresh median improved, but not consistently across profiles. Production retains copying bindings and their existing lifetimes.

## Method

- Baseline source: `88197842e5a7b2d2477fc4e2c073c1f518817ba1` plus the same benchmark harness.
- `count`: baseline plus moving the chunk count below the existing-object return.
- `borrowed`: count plus `bindBlobBorrowed(3, chunk)` in `ObjectInsertStatements.insertChunk`, with error-path binding clearing; discarded.
- macOS native, Zig 0.16.0, SQLite 3.53.4, ReleaseFast; package 1.0.0-rc.1, format 11.
- External database/binary directory: `/Volumes/wipesides/codebase-memory-mcp-cache/zova-object-1m`.
- Local cache: that directory's `local`; global cache: `/Volumes/wipesides/codebase-memory-mcp-cache/zig-global`.
- One deterministic 1 MiB input (seed `0x5a6f7661`), fresh database per sample, unchanged SQLite durability defaults. Each duplicate sample is the mean of 32 synchronous repeat puts.
- One warmup per variant/profile, then seven measured samples. Order reverses each trial: baseline/count/borrowed, borrowed/count/baseline.
- No broad storage/read benchmark. Results are small-fixture evidence, not large-object throughput claims. Seven-sample nearest-rank p95 is the maximum, not a precise tail estimate.
- Raw warmup and measured output: external `issue44-trials.D3E4FK/`.

## Summary (milliseconds)

| Profile | Variant | Operation | Median | p95 | MAD |
|---|---|---|---:|---:|---:|
| deduplication | baseline | fresh | 6.329375 | 7.662458 | 0.187333 |
| deduplication | baseline | duplicate | 1.022870 | 1.033823 | 0.005513 |
| deduplication | count | fresh | 6.627542 | 7.403667 | 0.514167 |
| deduplication | count | duplicate | 0.497104 | 0.508737 | 0.008168 |
| deduplication | borrowed | fresh | 6.300709 | 7.420500 | 0.209584 |
| deduplication | borrowed | duplicate | 0.495755 | 0.511210 | 0.006155 |
| streaming | baseline | fresh | 4.848416 | 7.340541 | 0.127167 |
| streaming | baseline | duplicate | 0.496172 | 0.635141 | 0.006326 |
| streaming | count | fresh | 4.530959 | 5.166917 | 0.346332 |
| streaming | count | duplicate | 0.503064 | 0.525641 | 0.012171 |
| streaming | borrowed | fresh | 4.832250 | 5.159500 | 0.258541 |
| streaming | borrowed | duplicate | 0.496305 | 0.528615 | 0.003129 |

## Measured samples (milliseconds, warmup excluded)

| Profile | Variant | Operation | Samples 1–7 |
|---|---|---|---|
| deduplication | baseline | fresh | 7.024459, 7.662458, 6.329375, 6.142042, 6.007375, 6.421333, 6.145584 |
| deduplication | baseline | duplicate | 1.033823, 1.028383, 1.022870, 1.028124, 1.012599, 1.008803, 1.022563 |
| deduplication | count | fresh | 7.403667, 7.166417, 6.113375, 6.627542, 5.931167, 6.803458, 6.182667 |
| deduplication | count | duplicate | 0.505272, 0.508737, 0.493465, 0.506905, 0.497104, 0.488279, 0.489681 |
| deduplication | borrowed | fresh | 6.753750, 6.884917, 6.300709, 7.420500, 6.172708, 6.196208, 6.091125 |
| deduplication | borrowed | duplicate | 0.511210, 0.490539, 0.495755, 0.501910, 0.504500, 0.488228, 0.492914 |
| streaming | baseline | fresh | 7.340541, 5.477208, 4.848416, 4.537792, 4.975583, 4.774625, 4.725917 |
| streaming | baseline | duplicate | 0.635141, 0.507203, 0.489688, 0.496172, 0.489846, 0.496647, 0.491815 |
| streaming | count | fresh | 4.512208, 4.530959, 4.476167, 5.166917, 4.877291, 4.985958, 4.154500 |
| streaming | count | duplicate | 0.504861, 0.503064, 0.513210, 0.525641, 0.490893, 0.488401, 0.483900 |
| streaming | borrowed | fresh | 4.832250, 5.159500, 4.484791, 4.894708, 4.847500, 4.544000, 4.573709 |
| streaming | borrowed | duplicate | 0.528615, 0.499434, 0.496305, 0.489234, 0.493951, 0.488984, 0.497876 |

## Phase and allocation interpretation

The harness separately hashes the payload before the put; most isolated hash samples were approximately 0.47–0.51 ms, with occasional scheduler outliers (up to 1.11 ms). Hashing remains necessary for duplicate identification. The approximately 0.526 ms duplicate median difference isolates the counting-path change at the operation level; it is not a separately instrumented count-function timer. Fresh puts still make two boundary passes. Duplicate puts now make none.

The retained change adds no allocation and removes none: counting is allocation-free. Allocator call counts were not instrumented. The discarded borrowed variant would remove one SQLite binding allocation/copy per inserted chunk (1 MiB total payload copies for this fixture), not SQLite's own storage copies. No allocation reduction is claimed for the retained implementation.

## Reproduction

Build each isolated source variant once with `zig build build-object-ingestion -Doptimize=ReleaseFast`, passing the same external `--cache-dir` and `--global-cache-dir`, and `--prefix ROOT/issue44-VARIANT`. Then run `sh scripts/bench-object-ingestion.sh ROOT`. The script creates a new results directory, never reuses existing databases, and runs the whole bounded batch with one invocation. The discarded variant is specified above; it is not a production feature or runtime option.

## Correctness

Regression coverage adds a trigger failure after the first manifest row, verifies rollback of object/chunk rows, retries successfully, verifies idempotence, and mutates caller input before reading the stored object. Both profiles are covered. Existing object tests cover empty/boundary inputs, manifests, hashes, malformed metadata, readers/writers and allocation failures. Final checks: 91/91 object tests, 222/222 C API tests, C/C++ ABI smoke checks, Zig formatting and shell syntax checks passed. Full cross-platform and generated-C checks are left to CI.
