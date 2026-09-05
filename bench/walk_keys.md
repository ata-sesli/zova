# Integer-key graph traversal (#43)

## Scope and method

Baseline: `702ecf5` (stacked on #46). Candidate replaces string visited keys and
public-ID adjacency lookups with integer keys, and transfers frontier-owned strings
to the returned prefix. No schema, index, format, or public API changes.

Measured on Darwin arm64, Zig 0.16.0, bundled SQLite 3.53.4, ReleaseFast.
Both binaries were built once with the same harness. Memory databases exclude
fixture setup from timing. Binaries, caches, and logs live on the external disk.
One warmup process per variant, then seven interleaved trials per variant,
alternating baseline/candidate and candidate/baseline. Each sample is the mean of
16 warm walks. Total includes result digest checking, result cleanup, and allocation
counter overhead. Profile phases are measured in a separate 16-walk loop.

Fixtures: 256 nodes and 510 reciprocal edges, chain (low degree) or star
(high degree); incoming/outgoing and filtered/unfiltered. The typed star reaches
129 nodes; all other cases reach 256. Public fields, depths and predecessors are
hashed; baseline/candidate digests, result counts, expansions, and rows match in
all trials. This is a bounded native microbenchmark, not a CBM promotion gate.

All times below are microseconds. p95 is nearest-rank across seven trial means
(the maximum), **not individual-query p95**. No outliers are excluded.

## Total time

| Fixture | Baseline median | Candidate median | Improvement | Baseline MAD | Candidate MAD | Baseline p95 | Candidate p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| high-incoming-all | 523.161 | 325.833 | 37.7% | 16.271 | 4.044 | 539.432 | 345.734 |
| high-incoming-typed | 240.049 | 158.081 | 34.1% | 11.698 | 1.211 | 319.036 | 204.073 |
| high-outgoing-all | 480.990 | 330.174 | 31.4% | 6.779 | 3.818 | 553.828 | 393.826 |
| high-outgoing-typed | 235.956 | 156.547 | 33.7% | 5.391 | 0.878 | 407.768 | 161.036 |
| low-incoming-all | 526.857 | 360.070 | 31.7% | 10.320 | 3.023 | 614.909 | 366.609 |
| low-incoming-typed | 485.388 | 308.320 | 36.5% | 14.195 | 4.646 | 548.805 | 349.091 |
| low-outgoing-all | 507.320 | 343.930 | 32.2% | 17.620 | 8.948 | 557.711 | 396.224 |
| low-outgoing-typed | 483.771 | 312.055 | 35.5% | 11.622 | 4.706 | 1431.565 | 351.487 |

## Phase medians and allocations per walk

Allocation counts cover the supplied Zig allocator, not SQLite's internal allocator.
Profile category definitions are unchanged; phase medians are not additive.

| Fixture | Adjacency baseline | Adjacency candidate | Bookkeeping baseline | Bookkeeping candidate | Allocations baseline | Allocations candidate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| high-incoming-all | 296.144 | 217.696 | 134.918 | 108.952 | 2312 | 1034 |
| high-incoming-typed | 141.817 | 95.026 | 70.795 | 53.994 | 1168 | 525 |
| high-outgoing-all | 314.584 | 222.357 | 142.894 | 108.367 | 2312 | 1034 |
| high-outgoing-typed | 134.836 | 94.703 | 67.878 | 54.688 | 1168 | 525 |
| low-incoming-all | 328.998 | 247.939 | 148.986 | 109.986 | 2312 | 1034 |
| low-incoming-typed | 279.392 | 196.928 | 142.409 | 107.783 | 2312 | 1034 |
| low-outgoing-all | 305.096 | 227.871 | 141.281 | 108.175 | 2312 | 1034 |
| low-outgoing-typed | 281.880 | 196.835 | 144.232 | 109.778 | 2312 | 1034 |

## Every measured sample

| Fixture | Variant | Trial | Total | Adjacency | Bookkeeping |
| --- | --- | ---: | ---: | ---: | ---: |
| high-incoming-all | baseline | 1 | 529.161 | 295.803 | 133.306 |
| high-incoming-all | baseline | 2 | 539.432 | 326.441 | 134.918 |
| high-incoming-all | baseline | 3 | 506.891 | 296.144 | 134.358 |
| high-incoming-all | baseline | 4 | 535.878 | 300.900 | 136.568 |
| high-incoming-all | baseline | 5 | 495.760 | 293.951 | 132.992 |
| high-incoming-all | baseline | 6 | 483.883 | 294.416 | 136.313 |
| high-incoming-all | baseline | 7 | 523.161 | 312.333 | 142.063 |
| high-incoming-all | candidate | 1 | 321.789 | 217.696 | 108.952 |
| high-incoming-all | candidate | 2 | 325.797 | 245.150 | 112.254 |
| high-incoming-all | candidate | 3 | 345.734 | 217.244 | 111.785 |
| high-incoming-all | candidate | 4 | 343.125 | 217.580 | 105.906 |
| high-incoming-all | candidate | 5 | 338.125 | 220.167 | 110.539 |
| high-incoming-all | candidate | 6 | 324.234 | 217.777 | 105.738 |
| high-incoming-all | candidate | 7 | 325.833 | 215.822 | 107.652 |
| high-incoming-typed | baseline | 1 | 319.036 | 135.043 | 67.674 |
| high-incoming-typed | baseline | 2 | 240.049 | 141.817 | 69.816 |
| high-incoming-typed | baseline | 3 | 228.352 | 147.634 | 73.210 |
| high-incoming-typed | baseline | 4 | 228.302 | 161.180 | 74.075 |
| high-incoming-typed | baseline | 5 | 243.807 | 140.389 | 70.795 |
| high-incoming-typed | baseline | 6 | 231.221 | 139.652 | 70.200 |
| high-incoming-typed | baseline | 7 | 265.534 | 142.235 | 71.647 |
| high-incoming-typed | candidate | 1 | 154.096 | 95.026 | 53.534 |
| high-incoming-typed | candidate | 2 | 157.841 | 93.844 | 53.515 |
| high-incoming-typed | candidate | 3 | 198.914 | 97.500 | 55.337 |
| high-incoming-typed | candidate | 4 | 158.422 | 93.862 | 53.994 |
| high-incoming-typed | candidate | 5 | 204.073 | 93.492 | 53.401 |
| high-incoming-typed | candidate | 6 | 158.081 | 97.878 | 55.065 |
| high-incoming-typed | candidate | 7 | 156.870 | 95.493 | 55.233 |
| high-outgoing-all | baseline | 1 | 474.935 | 327.974 | 145.938 |
| high-outgoing-all | baseline | 2 | 470.406 | 305.693 | 147.294 |
| high-outgoing-all | baseline | 3 | 485.263 | 320.957 | 138.564 |
| high-outgoing-all | baseline | 4 | 553.828 | 306.769 | 138.195 |
| high-outgoing-all | baseline | 5 | 474.211 | 314.584 | 147.921 |
| high-outgoing-all | baseline | 6 | 480.990 | 293.290 | 134.122 |
| high-outgoing-all | baseline | 7 | 529.107 | 316.976 | 142.894 |
| high-outgoing-all | candidate | 1 | 330.174 | 222.823 | 108.367 |
| high-outgoing-all | candidate | 2 | 326.247 | 222.357 | 123.588 |
| high-outgoing-all | candidate | 3 | 326.685 | 215.249 | 104.330 |
| high-outgoing-all | candidate | 4 | 393.826 | 227.546 | 109.524 |
| high-outgoing-all | candidate | 5 | 347.167 | 226.233 | 117.840 |
| high-outgoing-all | candidate | 6 | 326.357 | 211.887 | 106.764 |
| high-outgoing-all | candidate | 7 | 332.760 | 214.413 | 105.470 |
| high-outgoing-typed | baseline | 1 | 235.956 | 134.734 | 67.878 |
| high-outgoing-typed | baseline | 2 | 230.591 | 135.413 | 67.566 |
| high-outgoing-typed | baseline | 3 | 243.711 | 134.836 | 66.951 |
| high-outgoing-typed | baseline | 4 | 407.768 | 135.551 | 69.973 |
| high-outgoing-typed | baseline | 5 | 232.799 | 133.230 | 67.394 |
| high-outgoing-typed | baseline | 6 | 230.565 | 134.116 | 67.978 |
| high-outgoing-typed | baseline | 7 | 250.362 | 148.493 | 76.020 |
| high-outgoing-typed | candidate | 1 | 155.813 | 92.961 | 52.490 |
| high-outgoing-typed | candidate | 2 | 158.367 | 93.073 | 53.463 |
| high-outgoing-typed | candidate | 3 | 156.391 | 98.410 | 55.846 |
| high-outgoing-typed | candidate | 4 | 157.643 | 94.703 | 55.019 |
| high-outgoing-typed | candidate | 5 | 161.036 | 103.396 | 61.117 |
| high-outgoing-typed | candidate | 6 | 155.669 | 93.608 | 53.658 |
| high-outgoing-typed | candidate | 7 | 156.547 | 95.192 | 54.688 |
| low-incoming-all | baseline | 1 | 614.909 | 350.413 | 154.993 |
| low-incoming-all | baseline | 2 | 526.857 | 342.573 | 152.555 |
| low-incoming-all | baseline | 3 | 517.148 | 318.383 | 143.250 |
| low-incoming-all | baseline | 4 | 539.099 | 322.612 | 138.984 |
| low-incoming-all | baseline | 5 | 516.536 | 328.998 | 148.986 |
| low-incoming-all | baseline | 6 | 523.807 | 325.052 | 144.828 |
| low-incoming-all | baseline | 7 | 565.427 | 344.755 | 151.734 |
| low-incoming-all | candidate | 1 | 366.609 | 240.406 | 106.234 |
| low-incoming-all | candidate | 2 | 355.839 | 254.826 | 114.620 |
| low-incoming-all | candidate | 3 | 358.781 | 261.123 | 116.848 |
| low-incoming-all | candidate | 4 | 362.643 | 247.939 | 109.475 |
| low-incoming-all | candidate | 5 | 360.070 | 249.349 | 117.807 |
| low-incoming-all | candidate | 6 | 363.094 | 244.970 | 109.986 |
| low-incoming-all | candidate | 7 | 350.763 | 247.131 | 108.026 |
| low-incoming-typed | baseline | 1 | 548.805 | 289.885 | 142.409 |
| low-incoming-typed | baseline | 2 | 485.945 | 303.547 | 159.622 |
| low-incoming-typed | baseline | 3 | 485.388 | 273.659 | 139.972 |
| low-incoming-typed | baseline | 4 | 471.193 | 275.631 | 140.788 |
| low-incoming-typed | baseline | 5 | 468.482 | 279.392 | 146.751 |
| low-incoming-typed | baseline | 6 | 465.432 | 266.675 | 136.263 |
| low-incoming-typed | baseline | 7 | 489.591 | 292.676 | 153.215 |
| low-incoming-typed | candidate | 1 | 303.674 | 199.380 | 109.365 |
| low-incoming-typed | candidate | 2 | 308.320 | 283.314 | 166.956 |
| low-incoming-typed | candidate | 3 | 309.065 | 196.340 | 106.973 |
| low-incoming-typed | candidate | 4 | 349.091 | 196.928 | 107.783 |
| low-incoming-typed | candidate | 5 | 302.341 | 199.096 | 108.357 |
| low-incoming-typed | candidate | 6 | 317.677 | 196.760 | 107.144 |
| low-incoming-typed | candidate | 7 | 304.013 | 192.704 | 106.181 |
| low-outgoing-all | baseline | 1 | 495.560 | 600.783 | 162.538 |
| low-outgoing-all | baseline | 2 | 557.711 | 326.441 | 156.791 |
| low-outgoing-all | baseline | 3 | 532.331 | 298.001 | 133.457 |
| low-outgoing-all | baseline | 4 | 507.320 | 301.430 | 138.281 |
| low-outgoing-all | baseline | 5 | 524.940 | 310.936 | 140.210 |
| low-outgoing-all | baseline | 6 | 491.776 | 305.096 | 143.771 |
| low-outgoing-all | baseline | 7 | 489.055 | 296.688 | 141.281 |
| low-outgoing-all | candidate | 1 | 334.982 | 225.539 | 109.047 |
| low-outgoing-all | candidate | 2 | 354.417 | 229.326 | 108.340 |
| low-outgoing-all | candidate | 3 | 396.224 | 227.727 | 107.645 |
| low-outgoing-all | candidate | 4 | 335.159 | 244.629 | 123.316 |
| low-outgoing-all | candidate | 5 | 336.872 | 224.399 | 107.882 |
| low-outgoing-all | candidate | 6 | 343.930 | 227.871 | 108.132 |
| low-outgoing-all | candidate | 7 | 363.505 | 230.432 | 108.175 |
| low-outgoing-typed | baseline | 1 | 1431.565 | 354.603 | 180.556 |
| low-outgoing-typed | baseline | 2 | 481.542 | 292.516 | 150.700 |
| low-outgoing-typed | baseline | 3 | 488.516 | 269.034 | 144.232 |
| low-outgoing-typed | baseline | 4 | 510.161 | 268.998 | 138.405 |
| low-outgoing-typed | baseline | 5 | 483.771 | 281.880 | 140.344 |
| low-outgoing-typed | baseline | 6 | 458.753 | 271.417 | 137.284 |
| low-outgoing-typed | baseline | 7 | 472.148 | 289.619 | 149.392 |
| low-outgoing-typed | candidate | 1 | 305.951 | 194.870 | 106.831 |
| low-outgoing-typed | candidate | 2 | 351.487 | 196.835 | 110.977 |
| low-outgoing-typed | candidate | 3 | 327.573 | 198.209 | 108.244 |
| low-outgoing-typed | candidate | 4 | 311.799 | 204.964 | 114.817 |
| low-outgoing-typed | candidate | 5 | 311.505 | 196.678 | 109.778 |
| low-outgoing-typed | candidate | 6 | 312.055 | 200.345 | 113.587 |
| low-outgoing-typed | candidate | 7 | 316.760 | 194.044 | 107.279 |

## Evidence and reproduction

- RED: the new cursor trace test detected 24 per-expansion public-ID subqueries on the baseline (43 passed, 1 failed).
- ReleaseFast graph suite: 44/44 passed after the production edit.
- Debug: graph 44/44, core 176/176, C API 226/226, plus C/C++ ABI/header smoke passed.
- Final ReleaseSafe graph suite: 45/45 passed, including bound-store traversal inside a caller transaction and after rollback.
- New allocation-failure sweep exercises result allocation and cleanup of queued entries beyond the result limit.
- Existing tests retain direction/filter, shortest predecessor, ordering, missing-root and depth/limit coverage.
- Cross-platform and generated-C checks are left to CI; these local results are not a full release check.

Build each revision once with `zig build build-walk-keys -Doptimize=ReleaseFast`,
using the same harness and external cache paths, with respective prefixes
`$ROOT/issue43-baseline` and `$ROOT/issue43-candidate`. Run
`sh scripts/bench-walk-keys.sh "$ROOT"` for the full bounded trial set.

Local evidence root: `/Volumes/wipesides/codebase-memory-mcp-cache/zova-object-1m`.
Local cache: `$ROOT/local`; global cache: `/Volumes/wipesides/codebase-memory-mcp-cache/zig-global`.
Raw logs: `$ROOT/issue43-trials.hhf7vK` (run 0 is warmup).

Binary SHA-256:

- Baseline: `af2a334c3983661010b72a649f7feff86be8c830952ccc3baa0c6744a6c9c001`
- Candidate: `70da4361a5a467968e9cb4e4ec5f756fd0a03d30aa04f7175449d6369ecf7a25`

Decision: retain the narrow change. All eight total medians and trial-mean p95s
improve, alongside lower adjacency/bookkeeping medians and fewer allocations.
