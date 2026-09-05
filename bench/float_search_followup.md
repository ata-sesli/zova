# Buffered follow-up: issue #42

## Decision

**Update:** the [same-process wall/CPU experiment](float_tail.md) did not reproduce
the two regressions; both cases improve in every paired trial. The observations
below are retained as historical evidence, not the current acceptance verdict.

Keep PR #51 draft. Production scoring is unchanged from 39c74b0. The focused
short-query run improves every real-search median and p95, but the separate full
matrix still has two worse pooled real-search p95s. Allocation is not established
as their cause; no stack-buffer optimization or fallback dispatch was added.

## Measurement correction and scope

The earlier harness printed every sample between timed searches. This follow-up
buffers 256 records per case and prints only after sampling, with 16 warmups per
case. Timing still measures an individual complete search, not a batch average.
Both baseline 981cf57 and candidate 39c74b0 use this identical new harness; both
binaries were built once. One warmup process followed by seven alternating trials.
1792 individual samples per variant/case. No samples or trials are excluded.
All result/distance-bit digests match across variants.

The zero-limit control (`prepare`) includes collection lookup, query validation,
query preparation, and its cleanup but no scoring. It is NOT an isolated timer
inside the allocator or query initializer. It is also a real zero-limit API path:
its overhead increase is reported, not counted as a search win.

Focused 33-dimensional control medians increase by 0.083–0.125 µs, while normal
search medians fall by 1.3–14.3 µs. This does not justify attributing 50–100 µs tail
spikes to the one extra allocation. Scheduler interference is a hypothesis, not a
proven explanation. No process interference was deliberately introduced, and no
builds ran concurrently with the trials.

## Focused 33-dimensional results (µs)

| Case | Baseline median | Candidate median | Baseline p95 | Candidate p95 |
| --- | ---: | ---: | ---: | ---: |
| f32/cosine/33/full | 52.333 | 38.333 | 57.958 | 40.292 |
| f32/cosine/33/candidate | 16.125 | 14.416 | 16.917 | 15.208 |
| f32/cosine/33/prepare | 1.834 | 1.958 | 1.917 | 2.000 |
| f32/dot/33/full | 52.042 | 37.750 | 54.708 | 39.166 |
| f32/dot/33/candidate | 16.125 | 14.375 | 16.875 | 16.208 |
| f32/dot/33/prepare | 1.792 | 1.917 | 1.875 | 2.208 |
| f32/l2/33/full | 52.208 | 38.459 | 54.333 | 42.292 |
| f32/l2/33/candidate | 16.083 | 14.334 | 16.458 | 15.000 |
| f32/l2/33/prepare | 1.792 | 1.917 | 1.875 | 2.042 |
| f16/cosine/33/full | 45.208 | 33.625 | 46.792 | 35.417 |
| f16/cosine/33/candidate | 15.250 | 13.750 | 15.917 | 14.041 |
| f16/cosine/33/prepare | 1.833 | 1.917 | 1.917 | 2.041 |
| f16/dot/33/full | 44.708 | 33.625 | 46.417 | 35.042 |
| f16/dot/33/candidate | 15.083 | 13.792 | 15.458 | 14.250 |
| f16/dot/33/prepare | 1.792 | 1.916 | 1.875 | 1.959 |
| f16/l2/33/full | 44.542 | 33.625 | 46.625 | 35.167 |
| f16/l2/33/candidate | 15.125 | 13.750 | 15.417 | 14.208 |
| f16/l2/33/prepare | 1.792 | 1.875 | 1.875 | 1.958 |

## Full matrix confirmation (µs)

| Case | Baseline median | Candidate median | Baseline p95 | Candidate p95 |
| --- | ---: | ---: | ---: | ---: |
| f32/cosine/33/full | 52.667 | 40.083 | 68.791 | 40.625 |
| f32/cosine/33/candidate | 16.666 | 14.500 | 17.667 | 15.208 |
| f32/cosine/33/prepare | 1.875 | 2.000 | 2.000 | 6.208 |
| f32/dot/33/full | 53.916 | 39.500 | 169.167 | 112.209 |
| f32/dot/33/candidate | 16.250 | 14.959 | 17.000 | 15.458 |
| f32/dot/33/prepare | 1.833 | 2.000 | 5.667 | 2.042 |
| f32/l2/33/full | 52.708 | 39.834 | 96.083 | 81.584 |
| f32/l2/33/candidate | 16.708 | 14.958 | 49.709 | 15.334 |
| f32/l2/33/prepare | 1.833 | 1.958 | 1.917 | 2.042 |
| f16/cosine/33/full | 46.000 | 34.770 | 134.709 | 35.541 |
| f16/cosine/33/candidate | 15.417 | 14.208 | 44.250 | 40.250 |
| f16/cosine/33/prepare | 1.875 | 1.958 | 1.959 | 2.042 |
| f16/dot/33/full | 46.333 | 34.875 | 55.416 | 97.541 |
| f16/dot/33/candidate | 15.125 | 14.292 | 44.416 | 15.042 |
| f16/dot/33/prepare | 1.875 | 1.917 | 1.917 | 2.041 |
| f16/l2/33/full | 45.291 | 35.000 | 132.042 | 39.042 |
| f16/l2/33/candidate | 15.750 | 14.000 | 19.667 | 14.500 |
| f16/l2/33/prepare | 1.833 | 1.958 | 5.583 | 6.125 |
| f32/cosine/384/full | 311.708 | 156.542 | 1156.584 | 477.000 |
| f32/cosine/384/candidate | 50.000 | 31.083 | 175.583 | 35.125 |
| f32/cosine/384/prepare | 2.542 | 3.250 | 7.750 | 3.375 |
| f32/dot/384/full | 312.083 | 151.604 | 943.625 | 311.250 |
| f32/dot/384/candidate | 49.417 | 29.709 | 82.375 | 30.959 |
| f32/dot/384/prepare | 2.083 | 2.916 | 2.167 | 3.083 |
| f32/l2/384/full | 312.500 | 153.666 | 652.875 | 471.917 |
| f32/l2/384/candidate | 49.208 | 29.875 | 55.750 | 92.917 |
| f32/l2/384/prepare | 2.042 | 2.875 | 6.250 | 9.625 |
| f16/cosine/384/full | 231.375 | 99.792 | 321.083 | 289.583 |
| f16/cosine/384/candidate | 39.000 | 22.667 | 114.500 | 66.208 |
| f16/cosine/384/prepare | 2.375 | 3.000 | 7.458 | 3.084 |
| f16/dot/384/full | 227.000 | 100.063 | 593.750 | 274.125 |
| f16/dot/384/candidate | 38.292 | 22.333 | 112.958 | 65.000 |
| f16/dot/384/prepare | 2.125 | 2.584 | 2.209 | 2.750 |
| f16/l2/384/full | 229.000 | 99.917 | 333.541 | 183.834 |
| f16/l2/384/candidate | 38.333 | 22.333 | 40.541 | 23.292 |
| f16/l2/384/prepare | 2.083 | 2.583 | 6.250 | 2.667 |

## Remaining search tail regressions

- f16/dot/33/full: p95 55.416 → 97.541 µs, despite median 46.333 → 34.875.
- f32/l2/384/candidate: p95 55.750 → 92.917 µs, despite median 49.208 → 29.875.

These fail a conservative 5% no-regression check. They must not be hidden by the
other search wins or by changing from pooled individual p95 to a different
summary. Per-trial p95s below show variability but do not waive acceptance.

| Case | Variant | Trial p95s, runs 1–7 (µs) |
| --- | --- | --- |
| f16/dot/33/full | baseline | 47.083, 53.000, 145.375, 46.584, 49.500, 56.875, 56.708 |
| f16/dot/33/full | candidate | 37.875, 96.917, 113.625, 35.167, 35.750, 39.958, 46.292 |
| f32/l2/384/candidate | baseline | 61.458, 52.750, 176.500, 50.875, 59.500, 49.334, 51.208 |
| f32/l2/384/candidate | candidate | 31.083, 102.875, 95.459, 29.959, 30.792, 90.166, 39.209 |

## Verification and evidence

- Re-ran ReleaseSafe: 52/52 vector tests, 228/228 C API tests, C/C++ ABI/header smoke passed.
- Production code, exact widening, ownership and allocation logic were not modified in this follow-up.
- Existing local generated-C smoke/symbol verification still applies to identical production sources.
- PR CI generated-C jobs passed on Ubuntu x86_64, Ubuntu ARM64 and macOS for 39c74b0; other CI jobs were still running when checked. No all-CI-passed claim.

External root: `/Volumes/wipesides/codebase-memory-mcp-cache/zova-object-1m`.
Focused logs: `issue42-focused-trials.VIBQ5a`.
Full matrix logs: `issue42-trials.7avVaI`.
Every individual sample, allocation count/bytes and digest remains in those logs.
Binaries: `issue42-focused-{baseline,candidate}/bin/zova_float_search_benchmark`.
Caches unchanged: root/local and sibling zig-global.

SHA-256:

- Baseline: `216c0593c8cbf9cb2aa8f090408701a91abb58e81507efa3f9440bfb5f6c2cd5`
- Candidate: `02b70cc3a2a21d80d88d4f804252ff77b506d34f6182e74978f1ab7410d7a92c`

Reproduce after building both revisions with the same current harness:

```sh
sh scripts/bench-float-search.sh "$ROOT" compare issue42-focused short
sh scripts/bench-float-search.sh "$ROOT" compare issue42-focused
```

The baseline source was exported to an external temporary directory; local Git
refs and unrelated Python changes were not altered.
