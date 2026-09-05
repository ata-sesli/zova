# Issue #45: fixed KV statement reuse

## Decision and scope

Retain a two-slot connection-owned cache for single get/put calls. Median get-hit time improves 71.6% and memory-owned put time improves 61.1% in this tiny-value benchmark. Disk-owned put median changes +2.1%, inside trial variability; no disk speedup is claimed. No schema, format, version, public function, batch path, notification, or durability change.

The cache follows the existing Zova database-owner pattern. It stores SQLite handles, not pointers into a movable facade. Only two idle statements are retained. A lease removes its handle from the slot before entering SQLite; a nested call prepares its own statement, and surplus statements are finalized on return. This prevents reusing an in-flight statement but does not add general callback-reentrancy or concurrent-Zig-handle support. Existing C ABI per-handle locking and caller serialization remain authoritative.

Every return resets and clears bindings; cleanup failure finalizes the statement instead of caching it. Put releases its statement before commit/savepoint release. Database teardown finalizes both slots before closing SQLite. Schema invalidation uses SQLite's existing [prepare_v2 automatic recompile](https://www.sqlite.org/c3ref/prepare.html); [reset alone retains bindings](https://www.sqlite.org/c3ref/reset.html), hence explicit clearing. No borrowed inputs or shared result memory were introduced.

## Method

- Baseline: `44dcaeb` (issue #44), same added benchmark harness, no cache.
- Candidate: the two-slot cache in this PR. Both binaries built once, ReleaseFast, native macOS, Zig 0.16.0, SQLite 3.53.4. Version 1.0.0-rc.1, format 11.
- 2,000 calls per in-memory measurement, one namespace/key and an 11-byte value; hits and misses measured separately. Get results are validated and freed with the C allocator.
- 16 disk-backed, autocommit puts per sample, alternating two different values to force real updates. Fresh database per process; schema setup excluded. SQLite durability defaults unchanged.
- One warmup per binary followed by seven measured trials. Reversed order each trial: baseline/candidate, candidate/baseline. No samples discarded.
- Preparation, prepared execution, and empty-transaction controls are measured separately. These are controls, not additive instrumentation of the full API call. Prepared put execution includes SQLite's implicit in-memory commit; savepoint API measurements include their savepoint overhead.
- Every reported latency sample is a per-call mean within a trial. Median, nearest-rank p95, and MAD summarize those seven trial means, **not individual-call latency percentiles**. Seven-sample p95 is the maximum; scheduler noise remains visible.
- External root: `/Volumes/wipesides/codebase-memory-mcp-cache/zova-object-1m`; local cache `ROOT/local`, global cache `/Volumes/wipesides/codebase-memory-mcp-cache/zig-global`.
- Raw comparison output: `ROOT/issue45-trials.2dKg7W`. Initial pre-change probe: `ROOT/issue45-trials.X60wJG` (not included in comparison).

## Results

All timings are microseconds; retained statement memory is bytes.

| Measurement | Baseline median | Candidate median | Baseline p95 | Candidate p95 | Baseline MAD | Candidate MAD |
|---|---:|---:|---:|---:|---:|---:|
| get_hit_us | 1.604354 | 0.455584 | 1.658625 | 1.185125 | 0.028708 | 0.007918 |
| get_miss_us | 1.455896 | 0.336709 | 2.675666 | 0.905917 | 0.007334 | 0.004813 |
| put_memory_owned_us | 2.792250 | 1.085271 | 4.439917 | 2.065000 | 0.054395 | 0.022209 |
| put_memory_savepoint_us | 2.874771 | 1.241854 | 3.066146 | 2.068625 | 0.115396 | 0.065562 |
| retained_statement_bytes | 0.000000 | 7488.000000 | 0.000000 | 7488.000000 | 0.000000 | 0.000000 |
| prepare_get_us | 1.099667 | 1.116854 | 1.182146 | 1.595292 | 0.012375 | 0.025396 |
| execute_get_us | 0.389042 | 0.390750 | 0.399146 | 0.434563 | 0.006917 | 0.014021 |
| prepare_put_us | 1.583563 | 1.703375 | 2.134771 | 3.076104 | 0.011292 | 0.101167 |
| execute_put_autocommit_us | 0.650729 | 0.653792 | 0.671938 | 1.641229 | 0.004146 | 0.004500 |
| empty_transaction_us | 0.396125 | 0.400021 | 1.067729 | 2.221396 | 0.003541 | 0.007146 |
| put_disk_owned_us | 531.557313 | 542.682313 | 595.671875 | 595.638000 | 20.421875 | 33.281313 |

## All measured samples (1–7, warmup excluded)

| Measurement | Variant | Samples |
|---|---|---|
| get_hit_us | baseline | 1.575375, 1.604354, 1.658625, 1.612792, 1.575646, 1.588167, 1.639938 |
| get_hit_us | candidate | 1.185125, 0.464125, 0.452750, 0.455584, 1.168209, 0.448896, 0.447666 |
| get_miss_us | baseline | 1.454146, 1.455479, 1.463230, 1.447230, 2.675666, 1.455896, 1.524834 |
| get_miss_us | candidate | 0.459625, 0.336709, 0.336521, 0.331896, 0.905917, 0.369479, 0.333355 |
| put_memory_owned_us | baseline | 4.439917, 2.778188, 2.781041, 2.939813, 2.792250, 2.737855, 2.858604 |
| put_memory_owned_us | candidate | 1.435313, 1.074000, 1.062792, 1.107480, 2.065000, 1.079979, 1.085271 |
| put_memory_savepoint_us | baseline | 2.998813, 2.874771, 2.759375, 2.847813, 2.807479, 2.996292, 3.066146 |
| put_memory_savepoint_us | candidate | 1.308729, 1.756854, 1.176730, 1.241854, 2.068625, 1.176292, 1.177229 |
| retained_statement_bytes | baseline | 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000 |
| retained_statement_bytes | candidate | 7488.000000, 7488.000000, 7488.000000, 7488.000000, 7488.000000, 7488.000000, 7488.000000 |
| prepare_get_us | baseline | 1.149459, 1.092500, 1.182146, 1.087292, 1.115417, 1.092083, 1.099667 |
| prepare_get_us | candidate | 1.223875, 1.175646, 1.095959, 1.091458, 1.595292, 1.116854, 1.097792 |
| execute_get_us | baseline | 0.391396, 0.389146, 0.382125, 0.374041, 0.389042, 0.376542, 0.399146 |
| execute_get_us | candidate | 0.434563, 0.390750, 0.376729, 0.380250, 0.406625, 0.391021, 0.370209 |
| prepare_put_us | baseline | 1.583563, 1.582417, 1.572271, 1.574021, 1.745313, 1.637500, 2.134771 |
| prepare_put_us | candidate | 1.703375, 1.602208, 2.182021, 1.588125, 3.076104, 1.655521, 1.720604 |
| execute_put_autocommit_us | baseline | 0.636605, 0.646667, 0.654875, 0.643396, 0.652042, 0.671938, 0.650729 |
| execute_put_autocommit_us | candidate | 0.669646, 0.649292, 0.650458, 0.653792, 1.641229, 0.651958, 0.684084 |
| empty_transaction_us | baseline | 0.391229, 0.392584, 0.394229, 1.067729, 0.402250, 0.396125, 0.398188 |
| empty_transaction_us | candidate | 0.415854, 0.392875, 0.394750, 0.400021, 2.221396, 0.398813, 0.416896 |
| put_disk_owned_us | baseline | 531.557313, 537.395813, 595.671875, 526.908875, 509.252625, 551.979188, 452.195313 |
| put_disk_owned_us | candidate | 534.572875, 542.682313, 507.145813, 595.638000, 589.809875, 509.401000, 569.734375 |

## Memory and limitations

`SQLITE_DBSTATUS_STMT_USED` after warming both APIs reports 7,488 retained bytes versus zero in baseline. This is a measured plan-memory tradeoff, not a platform-independent byte bound; the cache has exactly two slots and finalizes them on close. Result allocation and blob-binding copies remain unchanged. Exact allocator call counts are not instrumented. Preparation avoidance is demonstrated by retained-statement coverage and the independent prepare-versus-execute controls, not inferred from a claimed allocator count.

These results justify caching tiny in-memory calls, not application-wide speedups or improvements for every key/value distribution. Full cross-platform and generated-C coverage remains a CI responsibility.

## Reproduction

Build each source variant with `zig build build-kv-calls -Doptimize=ReleaseFast`, the same external `--cache-dir` / `--global-cache-dir`, and `--prefix ROOT/issue45-baseline` or `ROOT/issue45-candidate`. Run `sh scripts/bench-kv-calls.sh ROOT` for the complete bounded alternating batch. An optional `baseline` second argument runs a single pre-change diagnostic. Every invocation makes a new database directory.

## Verification

The retained-statement test was observed red before implementation (expected two retained statements, found zero). The final Debug suite covers misses, namespaces, binary/empty inputs, allocation failure, bind failure, trigger failure, transaction/savepoint rollback, drop/recreate schema, preserved SQLite diagnostic text, owned result lifetime, nested reads, VACUUM, close, backup/restore, notifications and batch atomicity.

Verification passed: 29/29 KV tests in Debug and ReleaseSafe, 172/172 core tests, 222/222 C API tests, C/C++ ABI smoke checks, Zig formatting, shell syntax and diff whitespace checks. The diagnostic-text assertion was added after the ReleaseSafe run and passed in the final Debug run; production code was unchanged. Full cross-platform and generated-C checks are left to CI.
