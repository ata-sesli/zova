# Vector norm reuse: corrected local measurements

Baseline: `85ad872dd11a4d8369e420d81412a714b3d90682` (operation-atomic vector batches). Candidate: that baseline plus the norm reuse in this PR. Zig 0.16.0; SQLite 3.53.4; ReleaseFast; macOS arm64; external APFS disk. Seed 0x5a6f7661, 384 dimensions, cosine, 2048 rows. No durability/PRAGMA overrides.

The old benchmark instantiated internal vector.Database, bypassing the public batch transaction. Its replay average also included the first fresh insertion. Those timings did not fairly measure public putVectors. The corrected harness uses the public facade, populates replay inputs before timing, and verifies all payloads outside timing.

One warmup and seven measured samples per variant, alternating order each round. Each invocation creates a fresh database. Fresh and replay are separate timings (the local comparison harness recorded both per invocation). All validation/allocation/encoding/SQLite/commit work inside the public call is timed. No samples discarded. This is local evidence, not cross-platform or full-indexing proof.

## Final vector-only result

| Type | Fresh baseline → candidate ms | Improvement | Replay baseline → candidate ms | Improvement |
|---|---:|---:|---:|---:|
| f32 | 16.013166 → 14.770917 | 7.8% | 6.116916 → 4.912292 | 19.7% |
| f16 | 9.568792 → 8.329333 | 13.0% | 4.423875 → 3.247833 | 26.6% |
| i8 | 6.289334 → 5.631000 | 10.5% | 2.952833 → 2.570833 | 12.9% |

| Type | Fresh MAD baseline / candidate ms | Replay MAD baseline / candidate ms |
|---|---:|---:|
| f32 | .089791 / .313500 | .053624 / .031041 |
| f16 | .186583 / .280167 | .033417 / .029708 |
| i8 | .238126 / .037916 | .098208 / .031333 |

An earlier confirmation at 256 rows showed fresh medians changing by −9.1% (f32), −6.5% (f16), +0.9% (i8), and replay by −15.1%, −17.5%, −7.3%, respectively. No material small-batch median regression. The final 2048-row comparison excludes the rejected, independent object-borrowing experiment.

Final database sizes were identical between variants: f32 4382720 bytes; f16 1859584; i8 1019904. Extra temporary memory: 8 bytes/input, 16 KiB at 2048 rows. No schema, format, API or encoding change.

## Every final sample

Round 0 is warmup; medians/MAD use rounds 1–7. All timings milliseconds.

| Round | Variant | Type | Fresh | Replay |
|---:|---|---|---:|---:|
| 0 | baseline | f32 | 15.464791 | 6.037125 |
| 0 | retained | f32 | 22.669542 | 6.819416 |
| 0 | baseline | f16 | 9.478708 | 4.462667 |
| 0 | retained | f16 | 8.264833 | 4.073875 |
| 0 | baseline | i8 | 6.249500 | 3.185917 |
| 0 | retained | i8 | 6.343084 | 3.051334 |
| 1 | retained | f32 | 15.445333 | 5.203792 |
| 1 | baseline | f32 | 16.450417 | 5.828209 |
| 1 | retained | f16 | 8.740000 | 3.246333 |
| 1 | baseline | f16 | 9.755375 | 4.390458 |
| 1 | retained | i8 | 5.631000 | 2.740750 |
| 1 | baseline | i8 | 5.984666 | 2.851667 |
| 2 | baseline | f32 | 16.013166 | 6.345291 |
| 2 | retained | f32 | 14.447834 | 5.015084 |
| 2 | baseline | f16 | 9.291916 | 4.373750 |
| 2 | retained | f16 | 8.010459 | 3.314167 |
| 2 | baseline | i8 | 6.289334 | 2.880916 |
| 2 | retained | i8 | 5.593084 | 2.707917 |
| 3 | retained | f32 | 14.457417 | 4.912292 |
| 3 | baseline | f32 | 16.961500 | 6.063292 |
| 3 | retained | f16 | 8.329333 | 3.238583 |
| 3 | baseline | f16 | 9.467208 | 4.420417 |
| 3 | retained | i8 | 5.906208 | 2.570833 |
| 3 | baseline | i8 | 6.051208 | 3.103750 |
| 4 | baseline | f32 | 15.923375 | 6.116916 |
| 4 | retained | f32 | 15.087875 | 4.876208 |
| 4 | baseline | f16 | 9.691125 | 4.423875 |
| 4 | retained | f16 | 8.609500 | 3.347208 |
| 4 | baseline | i8 | 6.522500 | 3.051041 |
| 4 | retained | i8 | 5.498833 | 2.590667 |
| 5 | retained | f32 | 14.770917 | 4.910583 |
| 5 | baseline | f32 | 16.054125 | 6.169166 |
| 5 | retained | f16 | 8.421166 | 3.247833 |
| 5 | baseline | f16 | 9.568792 | 4.449125 |
| 5 | retained | i8 | 5.490875 | 2.539500 |
| 5 | baseline | i8 | 6.721500 | 2.952833 |
| 6 | baseline | f32 | 15.955375 | 6.028958 |
| 6 | retained | f32 | 14.763625 | 4.943333 |
| 6 | baseline | f16 | 9.295625 | 4.470958 |
| 6 | retained | f16 | 8.170500 | 3.218125 |
| 6 | baseline | i8 | 6.166542 | 2.925333 |
| 6 | retained | i8 | 5.640584 | 2.548792 |
| 7 | retained | f32 | 14.798625 | 4.889042 |
| 7 | baseline | f32 | 15.434000 | 6.164375 |
| 7 | retained | f16 | 8.027584 | 3.398584 |
| 7 | baseline | f16 | 9.843000 | 4.792667 |
| 7 | retained | i8 | 5.655167 | 2.502792 |
| 7 | baseline | i8 | 6.563667 | 3.137750 |

## Reproduction

Build baseline and candidate with the same corrected harness and `zig build build-vector-norms-94 -Doptimize=ReleaseFast`, using distinct external output prefixes. Place binaries under `EXTERNAL_ROOT/base/bin` and `EXTERNAL_ROOT/cand/bin`, then run `scripts/bench-vector-norms-94.sh EXTERNAL_ROOT`. Round zero is warmup. Start with one 256-row pilot on unfamiliar hardware before running the matrix.

Local evidence binaries SHA-256:

- Baseline: `9a8f78d2802f7e022d41892d462ac3193c742c2c91501434643937e8b8c19f19`
- Vector-only candidate: `5f5fe2d60d42cbdcef7c192e9deed63d8906fcf3316c9324bd695407adb59fc2`

