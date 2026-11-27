# R6 partial-checkpoint check: false-positive run, 2026-11-27

- Purpose: check that the recovery-only torn-page check (`tornPageCheckpointed`)
  refuses no valid crash state. The check closes R6's remaining case, a
  checkpointer that died after copying part of a torn commit, before the
  marker page and before advancing nBackfill.
- Source: the prototype at `a0f73da` (unchanged since `889fcb3`) plus
  `source.patch` (SHA-256 `70c357a25b0be11f9349742c05bd06f4aaf2cbbcc8e40e24acf401cc6ff32769`), which copies the check from
  `src/cwal/cwal.zig` into a scratch copy of `prototypes/cwal`. The
  prototype in the repository was not changed.
- Build: ReleaseSafe (`binaries/SHA256SUMS`). Scratch filesystem: tmpfs, 8
  jobs. See `HOST.txt`.
- Driver: `scripts/run.sh` (log `logs/run.log`): `delaypoints` 5 times,
  then the reduced suite with the options of the R6 run
  (`--jobs 8 --powerloss-seeds 1 --ncap 300 --allcap 400 --survivor-trials 5
  --restart-seeds 1 --io-positions 4 --files 2 3 8`).

| Log | Claim it backs |
|---|---|
| `logs/repeat-<i>.log` | 5 of 5 runs of `delaypoints` (including the three R6 cases) pass |
| `logs/suite-ReleaseSafe.log` | `RESULT PASS` in 1,282 s |
| `logs/suite-ReleaseSafe.log` against `../2026-11-26-r6-2d00c0d/logs/suite-ReleaseSafe.log` | Every crash, power-loss and recovery-crash line is identical to the R6 run (same `recoveries`, torn-state and run counts, 0 failures): the check added no refusal. Only the timing-driven sections differ (`survivors`-style reader counts and the ownership race counts), as between any two runs. |

The deterministic reproducer is the integrated test
`R6: a torn page checkpointed without an earlier WAL copy refuses recovery`
in `src/cwal/cwal_tests.zig`; the prototype's torture suite has no
partial-copy case.
