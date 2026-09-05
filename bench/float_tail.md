# Same-process wall/CPU attribution: issue #42

## Decision

The two suspected regressions did not reproduce under per-sample, same-process
alternation. Candidate median and p95 improve in both wall time and thread CPU
time, in every one of seven trials. Retain the existing candidate for review;
do not introduce a stack buffer or workload fallback on this evidence.

This is not proof that every platform/workload improves. It resolves the two
specific local performance objections; previous separate-process data remains
available in the earlier reports rather than being discarded.

## Method

Darwin arm64, Zig 0.16.0, ReleaseFast; baseline 981cf57 versus production candidate
39c74b0 (unchanged through 80eed4b). Each native static library was built once and
linked into its own dylib, loaded RTLD_LOCAL/RTLD_FIRST. The driver verifies that
the function pointers are distinct and checks result ID/distance-bit hashes for
every baseline/candidate pair. The baseline vector source SHA-256 matches the
981cf57 Git object. Same 128-row fixtures as the prior harness: f16 dot 33-dimensional
full search, f32 L2 384-dimensional search over 16 candidate IDs, limit 10.

Seven trials, each 32 warmup pairs and 512 measured pairs per case/phase. Both
implementations run on the same calling thread, alternating order every sample
and trial. No concurrent builds. Output is buffered until each trial completes.
3584 individual searches per variant/case/phase, with no exclusions.

Wall time uses CLOCK_MONOTONIC; CPU uses CLOCK_THREAD_CPUTIME_ID. CPU measurement
surrounds wall timestamps and therefore includes their small overhead. Wall
readings on this host are microsecond-quantized; sub-microsecond wall/CPU gaps
must not be interpreted as scheduling evidence. The C ABI input/output overhead
is included for both implementations, unlike the earlier direct-Zig harness.

## Results (µs)

| Case | Phase | Variant | Wall median | Wall p95 | CPU median | CPU p95 |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| f16-dot-33-full | search | baseline | 46.000 | 74.000 | 45.958 | 73.958 |
| f16-dot-33-full | search | candidate | 34.000 | 56.000 | 34.791 | 56.125 |
| f16-dot-33-full | prepare-control | baseline | 2.000 | 3.000 | 2.375 | 2.583 |
| f16-dot-33-full | prepare-control | candidate | 2.000 | 3.000 | 2.417 | 2.583 |
| f32-l2-384-candidate | search | baseline | 49.000 | 50.000 | 49.583 | 49.875 |
| f32-l2-384-candidate | search | candidate | 30.000 | 31.000 | 31.000 | 31.250 |
| f32-l2-384-candidate | prepare-control | baseline | 3.000 | 4.000 | 3.334 | 3.500 |
| f32-l2-384-candidate | prepare-control | candidate | 3.000 | 4.000 | 3.375 | 3.500 |

## Per-trial search p95 (µs)

| Case | Variant | Wall p95, trials 1–7 | CPU p95, trials 1–7 |
| --- | --- | --- | --- |
| f16-dot-33-full | baseline | 111.000, 51.000, 46.000, 46.000, 46.000, 46.000, 46.000 | 110.792, 50.459, 46.125, 46.125, 46.167, 46.125, 46.167 |
| f16-dot-33-full | candidate | 83.000, 37.000, 35.000, 35.000, 35.000, 35.000, 35.000 | 83.625, 36.792, 34.917, 34.917, 34.917, 34.917, 34.958 |
| f32-l2-384-candidate | baseline | 50.000, 50.000, 50.000, 50.000, 50.000, 50.000, 50.000 | 49.917, 49.875, 50.333, 49.917, 49.958, 49.792, 49.792 |
| f32-l2-384-candidate | candidate | 31.000, 31.000, 31.000, 31.000, 31.000, 31.000, 31.000 | 31.292, 31.291, 31.292, 31.250, 31.375, 31.250, 31.209 |

## Attribution

- f16 dot wall p95: 74 → 56 µs (24.3% lower); CPU p95: 73.958 → 56.125.
  The first trial slows both implementations substantially, and its CPU time
  rises with wall time. It is not explained by ordinary off-CPU preemption alone.
  Frequency/core/cache/warmup effects remain possibilities, not proven causes.
  Candidate is still faster in every trial, including that slow trial.
- f32 L2 wall p95: 50 → 31 µs (38% lower); CPU p95: 49.875 → 31.250.
  A few extreme samples have extra wall time beyond CPU time, but these do not
  produce a candidate p95 regression in the paired comparison.
- Allocation is not implicated as the tail bottleneck. Preparation-control CPU
  medians differ by only 0.042 µs and 0.041 µs respectively in this ABI harness.

The zero-limit preparation control includes collection lookup, input processing,
validation, preparation and cleanup. It does NOT isolate query initialization.
Subtracting its median CPU time from search median gives an approximate residual:

| Case | Baseline residual | Candidate residual |
| --- | ---: | ---: |
| f16 dot | 43.583 µs | 32.374 µs |
| f32 L2 candidates | 46.249 µs | 27.625 µs |

This residual includes row access, scoring, selection and result conversion;
it is not a directly measured scoring stage, and differences of medians are
estimates. No public/private profiling API was added to production for this test.

## Verification and reproduction

Driver compiles with clang -std=c11 -O2 -Wall -Wextra -Werror. All paired result
hashes matched. The linker warned about a 15.0 default deployment target versus
15.7.8 library objects; execution was on the compatible build host and succeeded.
The script is explicitly Darwin-only; it does not claim portable dlopen behavior.

Production code and its existing correctness tests are unchanged. The previous
52 vector / 228 C API ReleaseSafe tests and C/C++ checks remain applicable.
At inspection all 56 reported PR #51 push/PR CI checks for 80eed4b succeeded,
including native Zig and generated C on Linux x86_64/ARM64 and macOS. A new
benchmark/report commit will trigger fresh CI; this is not a future-CI claim.

```sh
sh scripts/bench-float-tail.sh "$ROOT" "$EXPORTED_BASELINE_SOURCE"
```

ROOT: `/Volumes/wipesides/codebase-memory-mcp-cache/zova-object-1m`.
Baseline export: `$ROOT/issue42-baseline-source.m8HIeK`.
Artifacts and every individual sample:
`$ROOT/issue42-same-process.ygMHfT/samples.csv`.

Dylib SHA-256:

- Baseline: `39babd537271906add55450b2b989e065f2900922590d40a0f32bb8c9528508f`
- Candidate: `75aed0779ae088b177f7e6aa58554e3560ed22c96199002016ecd4f46e80c0ac`
