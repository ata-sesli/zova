# Format-12 change-tracking overhead on ordinary vector writes — issue #159

Baseline: `bcc1c9881198fa49921d4cf5d6a158f60d1cc1cd` (storage format 11, the
parent of the vector-maintenance change). Candidate: `main` at
`c368c3690e24d643c12ea0e1c1f5a1d758bff124` (storage format 12). Both were built
with the benchmark source from this change copied into the baseline tree; no
other baseline file was modified.

This is a measurement only. No acceptance gate was stated before measuring, so
this report does not accept or reject the overhead, and it changes no storage,
trigger, or API behavior.

## Result

Format-12 change tracking makes every measured vector write slower. No
extension is loaded in any sample.

- Batch insert (`putVectors`, new rows): 1.65x to 3.34x.
- Batch update (`putVectors`, existing rows): 2.04x to 5.91x.
- Batch delete (`deleteVectors`): 1.69x to 2.29x.
- Single-row puts (`putVector` inside one caller transaction): 4.80x to 9.46x.

At 2,048 rows in the main store the added time is about 10 ms per batch
(roughly 5 µs per row) for insert and update, about 5.5 to 6 ms for delete, and
about 140 to 150 ms (roughly 70 µs per row) for single-row puts. The added
time is nearly independent of element type, so the relative cost is highest
for the narrowest vectors.

Database size grows with the tracking tables and one change record per write
up to the retained history. Main store: 32,768 bytes at 256 rows and 98,304
bytes at 2,048 rows after inserts, and 40,960 / 176,128 bytes after an insert
followed by a full update. Bound store: 53,248 / 118,784 bytes after inserts
and 61,440 / 196,608 bytes after insert plus update.

An additional five-sample check at 2,048 f32 rows built the vector-maintenance
commit itself (`2ad543e`) and matched `main` within 3% in all four modes
(fresh 20.1 vs 20.5 ms, replay 15.1 vs 15.0, single 166.6 vs 166.6, delete
9.09 vs 9.06; baseline 10.2, 4.4, 25.6, 3.6). The overhead is therefore
attributable to that commit, not to later 1.2.0 work.

## Method

- Harness: `bench/vector_norms_94.zig`, the existing public-facade put-many
  benchmark, extended with `single`, `delete` and optional `bound` arguments.
  Runner: `scripts/bench-vector-change-tracking-159.sh`.
- Fixture: deterministic 384-dimension vectors (seed 0x5a6f7661), cosine,
  256 and 2,048 rows, f32/f16/i8, main and bound vector stores.
- Modes: `fresh` times one `putVectors` into an empty collection; `replay`
  populates first and times one upsert batch; `single` times `beginImmediate`,
  one `putVector` per row and `commit`; `delete` populates first and times one
  `deleteVectors` batch.
- One warmup and seven measured samples per variant and case, alternating
  variant order each round. Every invocation creates a fresh database. 768
  invocations in total; no samples discarded. Payload read-back (or absence
  after delete) is verified outside the timed region.
- Everything inside the public call is timed, including validation, encoding,
  SQLite work, triggers and commit. No durability or PRAGMA overrides.
- Bytes are the main database plus the bound store file after the process
  exits.

Environment: Apple M1, macOS 15.7.8, internal APFS disk, Zig 0.17.0, SQLite
3.53.4, ReleaseFast. The usual external benchmark volume was not mounted, so
absolute times are not comparable with earlier retained reports; baseline and
candidate shared the same disk, build mode and cache state.

## Limits

- One machine, one filesystem, small bounded fixtures. This is local evidence,
  not a cross-platform result, and it says nothing about collections larger
  than 2,048 rows or history past the 4,096-change retention point (the
  2,048-row replay case reaches 4,096 changes but does not cross a retirement
  block after it).
- `single` runs inside one caller transaction to expose per-call cost.
  Autocommit single-row puts, where each call pays its own commit, were not
  measured; their relative overhead is expected to be smaller but is unknown.
- The cause of the larger per-call cost in `single` was not investigated.
- Reduction options were not evaluated. Any such work needs its own gate,
  parity and correctness checks, and must not change the storage format or
  validation without explicit authorization.

## Reproduce

```sh
git worktree add --detach BASE_TREE bcc1c9881198fa49921d4cf5d6a158f60d1cc1cd
cp bench/vector_norms_94.zig BASE_TREE/bench/
(cd BASE_TREE && zig build build-vector-norms-94 -Doptimize=ReleaseFast --prefix ROOT/base)
zig build build-vector-norms-94 -Doptimize=ReleaseFast --prefix ROOT/cand
sh scripts/bench-vector-change-tracking-159.sh ROOT
```

## Medians

Median and median absolute deviation over samples 1–7, milliseconds.

| Store | Rows | Mode | Type | Baseline median / MAD ms | Candidate median / MAD ms | Change | Ratio | Bytes baseline → candidate |
|---|---:|---|---|---:|---:|---:|---:|---:|
| main | 256 | fresh | f16 | 0.986 / 0.009 | 2.361 / 0.040 | +139% | 2.39x | 352256 → 385024 |
| main | 256 | fresh | f32 | 1.501 / 0.014 | 2.884 / 0.058 | +92% | 1.92x | 663552 → 696320 |
| main | 256 | fresh | i8 | 0.954 / 0.198 | 2.033 / 0.015 | +113% | 2.13x | 245760 → 278528 |
| main | 256 | replay | f16 | 0.428 / 0.006 | 2.002 / 0.023 | +368% | 4.68x | 352256 → 393216 |
| main | 256 | replay | f32 | 0.458 / 0.001 | 1.980 / 0.016 | +333% | 4.33x | 663552 → 704512 |
| main | 256 | replay | i8 | 0.330 / 0.001 | 1.954 / 0.046 | +491% | 5.91x | 245760 → 286720 |
| main | 256 | single | f16 | 2.766 / 0.117 | 20.848 / 0.326 | +654% | 7.54x | 352256 → 385024 |
| main | 256 | single | f32 | 3.361 / 0.126 | 21.005 / 0.097 | +525% | 6.25x | 663552 → 696320 |
| main | 256 | single | i8 | 2.399 / 0.065 | 19.997 / 0.047 | +733% | 8.33x | 245760 → 278528 |
| main | 256 | delete | f16 | 0.792 / 0.034 | 1.817 / 0.068 | +129% | 2.29x | 352256 → 385024 |
| main | 256 | delete | f32 | 0.610 / 0.014 | 1.373 / 0.029 | +125% | 2.25x | 663552 → 696320 |
| main | 256 | delete | i8 | 0.919 / 0.023 | 1.550 / 0.075 | +69% | 1.69x | 245760 → 278528 |
| main | 2048 | fresh | f16 | 6.741 / 0.312 | 17.250 / 0.668 | +156% | 2.56x | 1859584 → 1957888 |
| main | 2048 | fresh | f32 | 12.488 / 0.397 | 23.482 / 0.594 | +88% | 1.88x | 4382720 → 4481024 |
| main | 2048 | fresh | i8 | 4.283 / 0.099 | 14.319 / 0.305 | +234% | 3.34x | 1019904 → 1118208 |
| main | 2048 | replay | f16 | 3.250 / 0.012 | 14.131 / 0.189 | +335% | 4.35x | 1859584 → 2035712 |
| main | 2048 | replay | f32 | 4.615 / 0.122 | 15.009 / 0.209 | +225% | 3.25x | 4382720 → 4558848 |
| main | 2048 | replay | i8 | 2.531 / 0.006 | 12.309 / 0.080 | +386% | 4.86x | 1019904 → 1196032 |
| main | 2048 | single | f16 | 20.567 / 0.355 | 171.673 / 3.172 | +735% | 8.35x | 1859584 → 1957888 |
| main | 2048 | single | f32 | 28.592 / 1.249 | 172.349 / 2.609 | +503% | 6.03x | 4382720 → 4481024 |
| main | 2048 | single | i8 | 16.550 / 0.030 | 156.487 / 0.354 | +846% | 9.46x | 1019904 → 1118208 |
| main | 2048 | delete | f16 | 4.839 / 0.223 | 11.070 / 0.432 | +129% | 2.29x | 1859584 → 1957888 |
| main | 2048 | delete | f32 | 4.402 / 0.269 | 9.833 / 0.161 | +123% | 2.23x | 4382720 → 4481024 |
| main | 2048 | delete | i8 | 4.339 / 0.020 | 9.909 / 0.053 | +128% | 2.28x | 1019904 → 1118208 |
| bound | 256 | fresh | f16 | 1.441 / 0.069 | 2.678 / 0.035 | +86% | 1.86x | 499712 → 552960 |
| bound | 256 | fresh | f32 | 1.925 / 0.049 | 3.186 / 0.032 | +65% | 1.65x | 811008 → 864256 |
| bound | 256 | fresh | i8 | 1.183 / 0.034 | 2.456 / 0.034 | +108% | 2.08x | 393216 → 446464 |
| bound | 256 | replay | f16 | 1.069 / 0.041 | 2.428 / 0.039 | +127% | 2.27x | 499712 → 561152 |
| bound | 256 | replay | f32 | 1.205 / 0.042 | 2.458 / 0.019 | +104% | 2.04x | 811008 → 872448 |
| bound | 256 | replay | i8 | 0.966 / 0.015 | 2.356 / 0.071 | +144% | 2.44x | 393216 → 454656 |
| bound | 256 | single | f16 | 4.779 / 0.064 | 25.845 / 0.322 | +441% | 5.41x | 499712 → 552960 |
| bound | 256 | single | f32 | 5.141 / 0.057 | 24.693 / 0.036 | +380% | 4.80x | 811008 → 864256 |
| bound | 256 | single | i8 | 4.533 / 0.221 | 25.086 / 0.347 | +453% | 5.53x | 393216 → 446464 |
| bound | 256 | delete | f16 | 1.311 / 0.070 | 2.244 / 0.073 | +71% | 1.71x | 499712 → 552960 |
| bound | 256 | delete | f32 | 1.016 / 0.011 | 1.733 / 0.015 | +71% | 1.71x | 811008 → 864256 |
| bound | 256 | delete | i8 | 1.195 / 0.028 | 2.083 / 0.061 | +74% | 1.74x | 393216 → 446464 |
| bound | 2048 | fresh | f16 | 7.203 / 0.147 | 17.951 / 0.215 | +149% | 2.49x | 2007040 → 2125824 |
| bound | 2048 | fresh | f32 | 11.331 / 0.604 | 22.015 / 0.329 | +94% | 1.94x | 4530176 → 4648960 |
| bound | 2048 | fresh | i8 | 4.631 / 0.039 | 14.449 / 0.122 | +212% | 3.12x | 1167360 → 1286144 |
| bound | 2048 | replay | f16 | 4.046 / 0.084 | 14.440 / 0.191 | +257% | 3.57x | 2007040 → 2203648 |
| bound | 2048 | replay | f32 | 5.355 / 0.118 | 16.240 / 0.122 | +203% | 3.03x | 4530176 → 4726784 |
| bound | 2048 | replay | i8 | 3.168 / 0.017 | 12.643 / 0.070 | +299% | 3.99x | 1167360 → 1363968 |
| bound | 2048 | single | f16 | 32.127 / 0.407 | 195.395 / 2.415 | +508% | 6.08x | 2007040 → 2125824 |
| bound | 2048 | single | f32 | 38.872 / 0.248 | 197.366 / 0.794 | +408% | 5.08x | 4530176 → 4648960 |
| bound | 2048 | single | i8 | 29.574 / 0.780 | 189.815 / 5.708 | +542% | 6.42x | 1167360 → 1286144 |
| bound | 2048 | delete | f16 | 5.291 / 0.135 | 11.227 / 0.148 | +112% | 2.12x | 2007040 → 2125824 |
| bound | 2048 | delete | f32 | 4.206 / 0.115 | 9.617 / 0.228 | +129% | 2.29x | 4530176 → 4648960 |
| bound | 2048 | delete | i8 | 4.908 / 0.100 | 11.114 / 0.277 | +126% | 2.26x | 1167360 → 1286144 |

## Every sample

Round 0 is warmup. All timings milliseconds.

| Store | Rows | Mode | Type | Variant | Warmup | Samples 1–7 |
|---|---:|---|---|---|---:|---|
| main | 256 | fresh | f16 | baseline | 0.998 | 0.986 0.986 1.013 1.100 1.099 0.977 0.978 |
| main | 256 | fresh | f16 | candidate | 2.425 | 2.384 2.461 2.286 2.455 2.341 2.361 2.321 |
| main | 256 | fresh | f32 | baseline | 1.831 | 1.539 1.517 1.553 1.497 1.501 1.487 1.489 |
| main | 256 | fresh | f32 | candidate | 3.158 | 3.036 2.943 2.844 2.835 2.884 2.815 3.820 |
| main | 256 | fresh | i8 | baseline | 0.760 | 0.756 0.717 0.967 1.043 1.179 0.720 0.954 |
| main | 256 | fresh | i8 | candidate | 2.095 | 2.276 2.033 2.095 2.019 2.031 2.049 2.013 |
| main | 256 | replay | f16 | baseline | 0.420 | 0.421 0.418 0.428 0.430 0.437 0.428 0.422 |
| main | 256 | replay | f16 | candidate | 2.015 | 1.979 1.984 1.997 2.070 2.027 2.221 2.002 |
| main | 256 | replay | f32 | baseline | 0.461 | 0.461 0.458 0.456 0.456 0.458 0.469 0.457 |
| main | 256 | replay | f32 | candidate | 2.003 | 2.003 2.034 1.976 1.996 1.966 1.958 1.980 |
| main | 256 | replay | i8 | baseline | 0.330 | 0.330 0.334 0.329 0.331 0.334 0.328 0.329 |
| main | 256 | replay | i8 | candidate | 2.106 | 1.923 1.913 2.124 2.065 1.954 1.860 2.000 |
| main | 256 | single | f16 | baseline | 2.687 | 3.305 2.649 3.048 2.617 2.781 2.766 2.729 |
| main | 256 | single | f16 | candidate | 21.362 | 20.848 20.673 20.522 21.251 20.886 21.735 20.315 |
| main | 256 | single | f32 | baseline | 3.281 | 3.243 3.492 3.204 3.595 3.361 3.236 3.367 |
| main | 256 | single | f32 | candidate | 21.279 | 20.878 21.102 21.005 21.096 20.924 22.621 20.906 |
| main | 256 | single | i8 | baseline | 2.295 | 2.399 2.373 2.475 2.307 2.543 2.366 2.464 |
| main | 256 | single | i8 | candidate | 20.336 | 19.997 19.940 19.879 20.005 20.022 20.045 19.910 |
| main | 256 | delete | f16 | baseline | 0.776 | 0.826 0.776 0.871 0.792 0.764 0.746 0.861 |
| main | 256 | delete | f16 | candidate | 1.634 | 1.748 1.748 1.821 1.596 1.817 1.830 1.941 |
| main | 256 | delete | f32 | baseline | 0.738 | 0.581 0.577 0.610 0.603 0.652 0.624 0.611 |
| main | 256 | delete | f32 | candidate | 1.309 | 1.346 1.297 1.480 1.402 1.760 1.370 1.373 |
| main | 256 | delete | i8 | baseline | 0.722 | 0.942 0.735 0.919 0.723 0.935 0.727 0.920 |
| main | 256 | delete | i8 | candidate | 1.676 | 1.550 1.690 1.474 1.797 1.489 1.607 1.469 |
| main | 2048 | fresh | f16 | baseline | 7.124 | 6.577 7.447 6.429 6.689 7.327 7.672 6.741 |
| main | 2048 | fresh | f16 | candidate | 17.496 | 19.140 16.582 18.140 17.118 17.250 16.102 17.426 |
| main | 2048 | fresh | f32 | baseline | 18.456 | 12.241 11.091 13.393 13.864 12.488 12.091 12.570 |
| main | 2048 | fresh | f32 | candidate | 42.013 | 23.482 22.575 21.715 23.781 22.888 25.106 23.529 |
| main | 2048 | fresh | i8 | baseline | 4.150 | 4.696 4.654 4.217 4.283 4.184 4.528 4.187 |
| main | 2048 | fresh | i8 | candidate | 14.989 | 14.013 14.889 14.613 14.519 14.319 13.734 13.895 |
| main | 2048 | replay | f16 | baseline | 3.388 | 3.190 3.245 3.245 3.278 6.083 3.250 3.261 |
| main | 2048 | replay | f16 | candidate | 14.863 | 14.833 14.320 14.746 14.131 14.015 14.065 13.662 |
| main | 2048 | replay | f32 | baseline | 4.469 | 4.493 4.615 5.135 4.426 4.554 4.615 5.272 |
| main | 2048 | replay | f32 | candidate | 14.943 | 14.800 14.608 15.009 15.024 14.942 15.662 16.066 |
| main | 2048 | replay | i8 | baseline | 2.513 | 2.525 2.518 2.533 2.531 2.535 2.512 2.618 |
| main | 2048 | replay | i8 | candidate | 12.163 | 12.309 12.230 12.266 12.356 12.077 13.490 12.452 |
| main | 2048 | single | f16 | baseline | 19.909 | 34.194 37.495 20.213 20.567 20.503 22.273 20.279 |
| main | 2048 | single | f16 | candidate | 164.213 | 174.530 168.501 164.294 186.873 173.317 171.673 167.951 |
| main | 2048 | single | f32 | baseline | 31.509 | 28.592 28.171 27.422 27.134 31.076 29.841 52.531 |
| main | 2048 | single | f32 | candidate | 169.430 | 178.391 172.349 171.755 169.740 171.768 187.764 216.484 |
| main | 2048 | single | i8 | baseline | 17.228 | 16.547 16.581 16.550 16.558 16.493 16.436 16.954 |
| main | 2048 | single | i8 | candidate | 158.103 | 160.094 157.791 156.217 156.133 156.487 155.726 156.513 |
| main | 2048 | delete | f16 | baseline | 5.128 | 4.881 4.616 5.181 4.580 5.280 4.839 4.787 |
| main | 2048 | delete | f16 | candidate | 11.453 | 11.070 11.533 11.108 12.422 10.637 10.570 10.801 |
| main | 2048 | delete | f32 | baseline | 4.627 | 4.671 4.402 3.904 4.508 4.038 4.296 4.967 |
| main | 2048 | delete | f32 | candidate | 10.051 | 10.523 42.033 9.713 10.145 9.833 9.768 9.672 |
| main | 2048 | delete | i8 | baseline | 4.322 | 4.339 4.319 4.323 4.376 4.312 4.353 4.428 |
| main | 2048 | delete | i8 | candidate | 10.187 | 9.970 9.856 9.878 9.988 9.909 9.947 9.836 |
| bound | 256 | fresh | f16 | baseline | 1.557 | 1.529 1.397 1.423 1.651 1.372 1.632 1.441 |
| bound | 256 | fresh | f16 | candidate | 2.676 | 2.851 2.657 2.619 2.643 2.797 2.678 2.678 |
| bound | 256 | fresh | f32 | baseline | 2.015 | 2.038 1.876 1.925 1.906 2.087 2.768 1.903 |
| bound | 256 | fresh | f32 | candidate | 3.182 | 3.183 3.186 3.108 3.177 3.218 3.229 3.311 |
| bound | 256 | fresh | i8 | baseline | 1.605 | 1.240 1.153 1.120 1.195 1.183 1.287 1.149 |
| bound | 256 | fresh | i8 | candidate | 3.169 | 2.497 2.453 2.422 2.456 2.491 2.490 2.447 |
| bound | 256 | replay | f16 | baseline | 1.060 | 1.066 1.144 1.028 1.047 1.276 1.260 1.069 |
| bound | 256 | replay | f16 | candidate | 2.585 | 2.389 2.476 2.357 2.434 2.389 2.428 2.537 |
| bound | 256 | replay | f32 | baseline | 1.117 | 1.205 1.218 1.113 1.227 1.143 1.163 1.279 |
| bound | 256 | replay | f32 | candidate | 2.427 | 2.458 2.478 2.406 2.460 2.440 2.452 2.511 |
| bound | 256 | replay | i8 | baseline | 0.914 | 0.951 1.078 0.951 0.966 0.955 0.988 1.101 |
| bound | 256 | replay | i8 | candidate | 2.603 | 2.336 3.104 2.285 2.593 2.315 3.683 2.356 |
| bound | 256 | single | f16 | baseline | 9.560 | 4.579 4.503 4.779 4.844 6.739 4.748 4.789 |
| bound | 256 | single | f16 | candidate | 25.449 | 25.803 25.407 25.450 26.167 26.067 27.899 25.845 |
| bound | 256 | single | f32 | baseline | 5.151 | 5.085 5.111 5.360 5.141 5.128 5.214 5.269 |
| bound | 256 | single | f32 | candidate | 24.788 | 24.364 24.652 24.679 25.114 24.693 24.719 24.729 |
| bound | 256 | single | i8 | baseline | 4.226 | 4.960 4.277 4.624 4.398 4.533 9.457 4.312 |
| bound | 256 | single | i8 | candidate | 24.753 | 25.595 25.086 24.740 25.783 24.993 25.077 25.998 |
| bound | 256 | delete | f16 | baseline | 1.318 | 1.318 1.308 1.241 5.727 1.195 1.534 1.311 |
| bound | 256 | delete | f16 | candidate | 2.031 | 2.675 2.232 2.266 2.078 2.244 2.171 2.432 |
| bound | 256 | delete | f32 | baseline | 0.995 | 1.015 1.005 1.036 1.046 0.974 1.019 1.016 |
| bound | 256 | delete | f32 | candidate | 1.756 | 1.733 1.705 1.741 2.040 1.812 1.718 1.719 |
| bound | 256 | delete | i8 | baseline | 1.160 | 1.169 1.186 1.160 1.195 1.223 1.722 1.224 |
| bound | 256 | delete | i8 | candidate | 2.030 | 2.076 2.295 2.083 2.722 2.045 2.144 2.022 |
| bound | 2048 | fresh | f16 | baseline | 6.812 | 7.158 7.203 7.260 7.730 6.826 6.594 7.350 |
| bound | 2048 | fresh | f16 | candidate | 17.326 | 17.736 17.469 17.832 17.951 20.046 22.215 18.080 |
| bound | 2048 | fresh | f32 | baseline | 11.439 | 15.362 11.935 11.135 11.331 10.722 11.153 13.238 |
| bound | 2048 | fresh | f32 | candidate | 22.866 | 23.214 22.705 21.739 21.685 21.769 22.015 25.024 |
| bound | 2048 | fresh | i8 | baseline | 4.774 | 4.773 4.631 4.592 4.593 4.570 4.650 5.021 |
| bound | 2048 | fresh | i8 | candidate | 14.169 | 15.060 14.459 14.012 14.825 14.327 14.439 14.449 |
| bound | 2048 | replay | f16 | baseline | 3.984 | 3.967 4.318 4.784 4.099 4.046 3.951 3.962 |
| bound | 2048 | replay | f16 | candidate | 14.531 | 14.249 13.824 15.032 14.605 14.440 14.513 14.054 |
| bound | 2048 | replay | f32 | baseline | 5.517 | 5.318 5.742 5.237 5.347 5.726 5.883 5.355 |
| bound | 2048 | replay | f32 | candidate | 16.700 | 16.585 16.336 16.211 16.240 16.077 16.362 15.840 |
| bound | 2048 | replay | i8 | baseline | 3.192 | 3.151 3.168 3.376 3.295 3.145 3.159 3.171 |
| bound | 2048 | replay | i8 | candidate | 12.853 | 12.643 12.473 13.870 12.960 12.713 12.608 12.603 |
| bound | 2048 | single | f16 | baseline | 33.600 | 32.654 32.224 32.127 32.949 31.721 31.134 31.853 |
| bound | 2048 | single | f16 | candidate | 202.006 | 195.660 201.087 195.395 183.923 184.559 197.702 192.980 |
| bound | 2048 | single | f32 | baseline | 44.040 | 38.624 38.902 38.872 38.151 42.410 39.806 38.661 |
| bound | 2048 | single | f32 | candidate | 197.758 | 196.950 197.366 198.160 199.528 200.586 197.126 194.494 |
| bound | 2048 | single | i8 | baseline | 28.932 | 28.807 28.681 28.794 29.574 29.931 31.888 32.010 |
| bound | 2048 | single | i8 | candidate | 186.531 | 182.935 185.397 183.437 201.078 189.815 195.523 194.458 |
| bound | 2048 | delete | f16 | baseline | 5.291 | 5.156 5.451 5.233 5.291 5.260 5.993 5.678 |
| bound | 2048 | delete | f16 | candidate | 11.876 | 11.016 11.375 11.227 11.132 11.626 11.612 11.158 |
| bound | 2048 | delete | f32 | baseline | 4.320 | 4.284 4.076 4.206 4.091 4.133 5.221 4.959 |
| bound | 2048 | delete | f32 | candidate | 9.509 | 9.389 11.870 9.400 9.522 9.617 15.809 9.990 |
| bound | 2048 | delete | i8 | baseline | 5.278 | 4.908 4.779 5.335 4.992 5.040 4.808 4.882 |
| bound | 2048 | delete | i8 | candidate | 11.736 | 11.025 10.695 11.637 11.114 10.844 11.392 11.567 |
