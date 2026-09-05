# Floating-point exact search: issue #42

## Status

**Update:** the [same-process wall/CPU experiment](float_tail.md) did not reproduce
the two regressions; both cases improve in every paired trial. The observations
below are retained as historical evidence, not the current acceptance verdict.

See [the buffered follow-up](float_search_followup.md) for the newer focused and
full-matrix investigation. The data below retains the original harness results.

**Draft: median gains demonstrated, tail acceptance unresolved.**
Do not merge solely on these median results. Several 33-dimensional cases have
higher measured p95 after the change. Repeating the same bounded trials did not
establish absence of a material tail regression. No samples were discarded and
no further optimization was added to mask that result.

## Implementation

Prepare one exact f64 query buffer and release it at the end of the search.
Dispatch type/metric before the dimension loop. Preserve ordered scalar f64
accumulation, stored-value validation, zero-norm checks, candidate selection,
thresholds, and final tie ordering. i8 remains allocation-free in query preparation
and keeps its existing SIMD cosine path.

The hand-written widening is intentional: commit 2f8ac97 fixed f32 edge-case
widening and removed compiler-runtime linking workarounds in generated C. It is
unchanged here for f32 and f16. SIMD reduction/reassociation is not adopted:
changing accumulation order can change exact distances and ties. This candidate
evaluates reusable query preparation and type/metric specialization only; a
separate order-preserving SIMD decoding experiment remains deferred.

The new buffer costs one allocation and 8 × dimensions bytes (264 bytes at 33,
3072 bytes at 384, at most 128 KiB at the supported dimension ceiling). It is not
retained across calls. No public API, format, schema, index, CBM or version changes.

## Method

Baseline 981cf57, candidate on work/float-vector-scoring-42. Darwin arm64,
Zig 0.16.0, SQLite 3.53.4, ReleaseFast. Both binaries built once with the same
harness. Two identical trial sets: each one warmup process per variant followed
by seven alternating baseline/candidate or candidate/baseline trials. Per case,
each process performs a warmup search and eight separately timed searches.
Fixtures have 128 vectors, dimensions 33 or 384; full scan or 16 candidate IDs;
f32/f16 × cosine/dot/L2; limit 10. Database setup is excluded.

Each latency includes collection lookup, query preparation, validation, scoring,
top-k and output allocation. Result hashing and caller result destruction are
outside timing. The allocator counter itself is present for both variants.
All result-ID/distance-bit digests match baseline across both sets.
Allocated bytes are cumulative supplied-Zig-allocator bytes, not SQLite or RSS.

## Pooled individual-search results

112 searches per variant/case; p95 is nearest-rank over those samples.
Times are microseconds. Pooling includes both initial and confirmation sets.

| Type/metric/dimensions/path | Baseline median | Candidate median | Gain | Baseline p95 | Candidate p95 | Baseline MAD | Candidate MAD |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| f32/cosine/33/full | 54.167 | 39.625 | 26.8% | 84.500 | 57.541 | 2.105 | 1.104 |
| f32/cosine/33/candidate | 17.188 | 15.541 | 9.6% | 45.083 | 23.917 | 0.604 | 0.541 |
| f32/dot/33/full | 53.333 | 38.188 | 28.4% | 73.167 | 75.459 | 1.999 | 0.354 |
| f32/dot/33/candidate | 17.000 | 14.959 | 12.0% | 18.584 | 48.083 | 0.500 | 0.249 |
| f32/l2/33/full | 52.229 | 40.250 | 22.9% | 69.625 | 122.083 | 0.937 | 2.000 |
| f32/l2/33/candidate | 17.063 | 15.771 | 7.6% | 38.125 | 49.291 | 0.625 | 1.062 |
| f16/cosine/33/full | 45.251 | 34.916 | 22.8% | 60.709 | 177.250 | 0.793 | 1.207 |
| f16/cosine/33/candidate | 15.917 | 14.646 | 8.0% | 17.625 | 24.042 | 0.500 | 0.542 |
| f16/dot/33/full | 45.750 | 34.500 | 24.6% | 54.916 | 39.792 | 1.605 | 1.042 |
| f16/dot/33/candidate | 15.979 | 14.500 | 9.3% | 18.709 | 16.291 | 0.562 | 0.521 |
| f16/l2/33/full | 44.834 | 35.084 | 21.7% | 90.708 | 41.625 | 0.501 | 1.333 |
| f16/l2/33/candidate | 15.542 | 14.771 | 5.0% | 17.750 | 22.500 | 0.209 | 0.646 |
| f32/cosine/384/full | 300.958 | 148.625 | 50.6% | 376.000 | 202.209 | 9.500 | 1.959 |
| f32/cosine/384/candidate | 48.416 | 31.000 | 36.0% | 78.834 | 79.834 | 1.104 | 1.042 |
| f32/dot/384/full | 299.688 | 147.500 | 50.8% | 469.458 | 177.958 | 8.146 | 2.459 |
| f32/dot/384/candidate | 47.605 | 29.917 | 37.2% | 191.709 | 43.750 | 0.647 | 0.542 |
| f32/l2/384/full | 298.063 | 151.938 | 49.0% | 734.042 | 271.250 | 5.938 | 5.271 |
| f32/l2/384/candidate | 47.855 | 31.605 | 34.0% | 137.542 | 38.833 | 0.834 | 1.520 |
| f16/cosine/384/full | 221.125 | 99.480 | 55.0% | 722.083 | 116.000 | 4.542 | 2.417 |
| f16/cosine/384/candidate | 38.230 | 23.084 | 39.6% | 124.292 | 26.833 | 1.020 | 0.459 |
| f16/dot/384/full | 215.688 | 98.250 | 54.4% | 508.166 | 168.917 | 3.291 | 1.813 |
| f16/dot/384/candidate | 36.541 | 22.813 | 37.6% | 123.167 | 29.750 | 0.209 | 0.645 |
| f16/l2/384/full | 217.187 | 100.021 | 53.9% | 898.500 | 120.500 | 2.895 | 2.916 |
| f16/l2/384/candidate | 37.000 | 22.833 | 38.3% | 47.125 | 26.000 | 0.458 | 0.458 |

## Per-process median samples

Seven measured process medians in run order per cell. These are provided to show
trial variability; the p95 above uses individual searches, not these medians.

| Case | Set | Baseline samples (µs) | Candidate samples (µs) |
| --- | ---: | --- | --- |
| f32/cosine/33/full | 1 | 51.730, 51.854, 57.355, 53.563, 51.708, 51.813, 53.167 | 44.938, 38.730, 41.542, 38.896, 40.584, 39.250, 38.730 |
| f32/cosine/33/full | 2 | 54.084, 54.499, 51.813, 60.730, 55.730, 53.604, 56.147 | 40.188, 86.646, 38.729, 39.208, 42.229, 38.916, 38.958 |
| f32/cosine/33/candidate | 1 | 16.542, 16.604, 17.813, 16.792, 16.688, 16.666, 16.938 | 17.771, 14.938, 16.188, 16.042, 15.729, 14.896, 15.063 |
| f32/cosine/33/candidate | 2 | 17.354, 18.355, 16.604, 20.021, 30.770, 17.063, 17.833 | 15.021, 39.959, 14.958, 15.291, 16.063, 15.063, 15.209 |
| f32/dot/33/full | 1 | 51.251, 54.521, 51.355, 51.250, 51.187, 51.270, 53.563 | 44.645, 37.959, 37.875, 38.000, 38.042, 37.938, 41.875 |
| f32/dot/33/full | 2 | 54.708, 62.896, 56.667, 56.604, 53.480, 52.271, 53.438 | 37.979, 83.480, 38.709, 37.938, 41.146, 37.980, 37.896 |
| f32/dot/33/candidate | 1 | 16.499, 17.813, 17.041, 16.313, 16.438, 16.500, 16.396 | 17.396, 15.084, 14.791, 14.792, 14.917, 14.688, 15.479 |
| f32/dot/33/candidate | 2 | 17.541, 18.458, 17.209, 17.770, 16.999, 16.709, 17.042 | 14.834, 48.854, 15.021, 14.875, 15.916, 14.709, 14.792 |
| f32/l2/33/full | 1 | 51.395, 51.666, 51.395, 51.541, 51.438, 51.438, 51.480 | 44.459, 38.166, 38.334, 39.479, 38.291, 49.292, 38.188 |
| f32/l2/33/full | 2 | 54.084, 63.459, 51.834, 55.854, 55.145, 52.958, 53.188 | 40.729, 121.312, 42.250, 41.208, 40.333, 38.188, 41.479 |
| f32/l2/33/candidate | 1 | 16.375, 16.792, 16.271, 18.812, 16.229, 16.438, 16.292 | 16.959, 14.604, 22.916, 15.188, 14.709, 16.063, 14.625 |
| f32/l2/33/candidate | 2 | 16.917, 35.646, 17.084, 17.646, 17.604, 17.792, 17.542 | 15.521, 49.374, 16.438, 16.500, 16.834, 14.666, 16.042 |
| f16/cosine/33/full | 1 | 44.666, 44.750, 46.646, 45.541, 44.480, 44.541, 44.500 | 39.271, 33.916, 35.000, 34.688, 34.521, 33.792, 33.895 |
| f16/cosine/33/full | 2 | 44.688, 50.084, 46.229, 49.688, 59.417, 44.813, 47.063 | 33.875, 5610.875, 35.563, 36.813, 39.354, 34.125, 35.188 |
| f16/cosine/33/candidate | 1 | 15.396, 15.625, 16.063, 15.584, 15.459, 15.750, 15.354 | 16.166, 14.104, 14.604, 14.958, 14.313, 14.042, 14.021 |
| f16/cosine/33/candidate | 2 | 15.563, 16.813, 16.854, 16.750, 17.313, 15.521, 16.333 | 14.104, 30.291, 15.271, 14.166, 15.521, 14.146, 14.646 |
| f16/dot/33/full | 1 | 47.208, 44.250, 45.938, 44.209, 44.980, 44.104, 44.541 | 38.916, 37.105, 34.605, 33.437, 33.666, 33.438, 33.416 |
| f16/dot/33/full | 2 | 44.292, 48.313, 44.396, 47.563, 51.874, 44.437, 46.770 | 33.499, 38.500, 33.479, 36.125, 37.188, 33.646, 34.834 |
| f16/dot/33/candidate | 1 | 16.396, 15.333, 16.083, 15.437, 15.604, 15.604, 16.896 | 16.270, 15.416, 14.437, 14.000, 14.562, 14.041, 13.938 |
| f16/dot/33/candidate | 2 | 15.541, 18.084, 15.667, 16.687, 16.813, 15.459, 16.396 | 14.063, 15.417, 13.979, 15.104, 15.854, 14.125, 14.563 |
| f16/l2/33/full | 1 | 45.833, 44.417, 46.229, 44.438, 44.416, 44.375, 44.520 | 36.416, 34.625, 34.855, 33.875, 35.125, 33.584, 33.667 |
| f16/l2/33/full | 2 | 44.521, 251.875, 44.334, 48.708, 47.729, 44.416, 47.646 | 33.730, 36.855, 37.730, 36.355, 37.229, 33.875, 36.124 |
| f16/l2/33/candidate | 1 | 15.604, 15.333, 15.437, 15.333, 15.500, 15.583, 15.583 | 14.979, 14.250, 14.459, 14.209, 15.063, 14.021, 14.000 |
| f16/l2/33/candidate | 2 | 15.417, 17.063, 15.333, 16.791, 16.583, 15.479, 16.438 | 14.083, 16.979, 21.563, 15.646, 15.250, 14.021, 15.125 |
| f32/cosine/384/full | 1 | 308.855, 292.042, 291.500, 291.333, 293.167, 294.771, 301.479 | 158.021, 146.938, 160.479, 147.479, 147.313, 147.021, 146.625 |
| f32/cosine/384/full | 2 | 291.500, 366.708, 294.458, 314.854, 332.125, 291.688, 302.708 | 147.000, 169.250, 147.272, 203.334, 157.978, 146.979, 157.084 |
| f32/cosine/384/candidate | 1 | 48.562, 47.416, 50.416, 47.500, 47.438, 47.770, 47.771 | 32.208, 30.042, 32.895, 30.042, 30.312, 31.084, 29.895 |
| f32/cosine/384/candidate | 2 | 47.416, 56.459, 47.375, 51.438, 51.980, 51.416, 51.625 | 30.083, 33.646, 30.063, 72.397, 33.250, 30.000, 31.416 |
| f32/dot/384/full | 1 | 291.688, 303.271, 292.583, 292.250, 291.396, 294.292, 294.667 | 159.584, 145.313, 158.375, 145.104, 145.688, 146.104, 145.041 |
| f32/dot/384/full | 2 | 297.292, 436.875, 307.542, 327.063, 319.583, 294.979, 305.542 | 147.500, 145.896, 157.105, 171.166, 146.104, 145.813, 157.208 |
| f32/dot/384/candidate | 1 | 47.041, 47.708, 47.166, 47.249, 47.000, 47.125, 47.020 | 32.063, 29.396, 31.770, 29.563, 30.584, 29.791, 29.313 |
| f32/dot/384/candidate | 2 | 47.625, 56.896, 47.521, 279.479, 51.417, 47.501, 49.563 | 29.520, 29.626, 29.750, 75.791, 29.605, 29.750, 31.916 |
| f32/l2/384/full | 1 | 299.438, 296.395, 313.854, 296.083, 295.167, 292.417, 295.230 | 153.104, 146.833, 173.688, 146.792, 146.916, 147.125, 148.750 |
| f32/l2/384/full | 2 | 292.292, 610.542, 293.833, 334.209, 320.000, 292.458, 314.604 | 146.813, 163.333, 152.333, 210.729, 158.959, 148.041, 159.791 |
| f32/l2/384/candidate | 1 | 47.022, 47.166, 48.480, 47.020, 47.604, 47.999, 46.979 | 31.438, 29.520, 32.334, 29.708, 30.041, 30.666, 29.521 |
| f32/l2/384/candidate | 2 | 47.166, 141.834, 47.771, 51.083, 53.125, 47.813, 50.480 | 32.541, 30.875, 31.876, 36.395, 34.208, 29.626, 32.291 |
| f16/cosine/384/full | 1 | 222.042, 219.354, 216.750, 219.250, 216.625, 220.791, 218.000 | 100.021, 97.459, 97.959, 98.376, 97.105, 96.875, 99.959 |
| f16/cosine/384/full | 2 | 216.833, 561.063, 233.812, 713.270, 220.938, 233.416, 224.834 | 96.959, 107.417, 98.479, 112.313, 97.271, 100.874, 104.791 |
| f16/cosine/384/candidate | 1 | 40.813, 37.854, 37.396, 37.354, 37.625, 38.147, 37.291 | 23.563, 22.625, 23.000, 22.688, 22.999, 22.895, 22.875 |
| f16/cosine/384/candidate | 2 | 37.563, 140.334, 40.000, 40.354, 37.230, 38.688, 38.875 | 22.937, 28.063, 23.458, 24.541, 23.292, 22.959, 24.479 |
| f16/dot/384/full | 1 | 214.125, 213.584, 219.666, 214.729, 212.646, 213.188, 214.584 | 98.709, 101.250, 100.791, 96.563, 96.938, 96.916, 96.770 |
| f16/dot/384/full | 2 | 212.729, 495.062, 288.145, 232.916, 212.688, 216.541, 224.021 | 96.813, 169.021, 97.208, 106.729, 103.020, 96.730, 104.584 |
| f16/dot/384/candidate | 1 | 36.438, 36.480, 36.396, 36.375, 36.500, 38.875, 36.416 | 22.645, 23.938, 24.375, 22.250, 25.416, 22.249, 22.292 |
| f16/dot/384/candidate | 2 | 36.541, 131.541, 43.855, 37.333, 36.520, 36.438, 36.541 | 22.292, 25.229, 22.354, 24.125, 24.583, 22.292, 23.541 |
| f16/l2/384/full | 1 | 214.459, 220.459, 214.250, 214.334, 214.895, 214.438, 214.334 | 98.896, 107.729, 104.688, 98.041, 97.771, 97.188, 97.146 |
| f16/l2/384/full | 2 | 214.875, 1038.458, 234.125, 218.645, 214.375, 218.646, 222.709 | 97.354, 105.125, 104.563, 135.541, 103.062, 97.145, 102.188 |
| f16/l2/384/candidate | 1 | 36.709, 36.938, 36.624, 36.666, 36.938, 36.833, 36.480 | 22.688, 24.645, 23.000, 22.374, 22.645, 22.395, 22.584 |
| f16/l2/384/candidate | 2 | 36.895, 44.688, 39.563, 37.521, 36.688, 37.375, 37.980 | 22.500, 23.500, 22.834, 25.000, 23.895, 22.563, 24.084 |

## Verification

- RED: prepared-query ownership test failed compilation against the original two-argument initializer.
- Initial ReleaseFast vector suite: 51/51 passed.
- Final ReleaseSafe vectors: 52/52; C API: 228/228; C/C++ ABI/header smoke passed.
- Exact distance-bit comparison against the original scalar reference for f32/f16, all metrics, dimensions 1–7, 16/17, 32/33, 384/385, cancellation, subnormal values, signed zero, and largest finite values.
- Allocation-failure cleanup, malformed lengths, nonfinite input and corrupt stored values tested; existing SQL/native, candidate/full, tie and threshold tests remain green.
- Darwin arm64 generated C: compiled with clang -O2, C ABI smoke passed, exported symbols match canonical Zig C ABI. Other supported targets remain CI work.
- Portable widening routines are unchanged.

## Reproduction and retained evidence

Build `zig build build-float-search -Doptimize=ReleaseFast` on each revision,
using the same harness and external caches; prefixes `$ROOT/issue42-baseline`
and `$ROOT/issue42-candidate`. Run
`sh scripts/bench-float-search.sh "$ROOT"` for one complete bounded trial set.

ROOT: `/Volumes/wipesides/codebase-memory-mcp-cache/zova-object-1m`.
Local cache: `$ROOT/local`; global cache:
`/Volumes/wipesides/codebase-memory-mcp-cache/zig-global`.
Raw per-search logs (including allocation counts/bytes and digests):
`$ROOT/issue42-trials.47v0A3` and `$ROOT/issue42-trials.qpiTPc`.
Run 0 is warmup, not included in statistics.
Generated-C artifacts: `$ROOT/issue42-generated-c`.

Binary SHA-256:

- Baseline: `7936a2d454578609c4e3f389f19ced666d084f48e73f1b155f18ac18fc7ba692`
- Candidate: `3fddd786d450031d7a98b869796a40cc0596851c5c7f0c7c3a27c12db95863fc`

No cross-platform performance or CBM promotion claim is made. The small-query
tail regressions require controlled attribution before this candidate is accepted.
