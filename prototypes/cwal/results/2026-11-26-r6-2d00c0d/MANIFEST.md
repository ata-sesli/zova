# R6 verification runs, 2026-11-26

- Source: commit `2d00c0d` plus the uncommitted R6 changes to `src/` and
  `torture.py`, saved as `source.patch` (SHA-256
  `5a6aba6387ba209ad31bc2352015e16762504e743d40651be2c0a543d520fd83`). To
  reproduce, check out `2d00c0d` and run `git apply source.patch` in
  `prototypes/cwal`. If these changes are committed later, the commit's
  `src/` and `torture.py` match this patch.
- Scratch filesystem: tmpfs. 8 jobs. See `HOST.txt`.
- Driver: `scripts/r6run.sh` (log: `logs/r6run.log`). It runs these steps in
  order:
  1. Builds Debug, ReleaseSafe and ReleaseFast (`binaries/SHA256SUMS`).
  2. Runs `delaypoints` (now with the three R6 cases) 20 times per build.
  3. Runs the reduced torture suite on each build, with the same options as
     the T2/T3 run.
  4. Runs the mutation sweep on ReleaseSafe, as in the T2/T3 run, with
     `no-root-check` and `no-repair-lock` added (both against
     `delaypoints`).
- Masking check, run by hand after the sweep on the same ReleaseSafe binary:
  `CWAL_MUTATE=<m> python3 torture.py --only delaypoints` for
  `no-early-heads,no-root-check`, `heads-process-wide,no-root-check` and
  `no-root-check` alone.
- Model: `./model.py` on the same tree, with the member-ownership model and
  the `no-root-check` mutation added. It ran twice. The first run
  (`logs/model-run1.log`, `model-run1.time`) exited 1 only because
  `no-ckpt-gate` went undetected: the root check refuses its tear. That case
  was then confirmed with `./model.py --model protocol --mutation
  no-ckpt-gate,no-root-check` (`logs/mask-no-ckpt-gate+no-root-check.log`),
  `model.py` was changed to test `no-ckpt-gate` that way, and the second
  run (`logs/model.log`, `model.time`) exited 0. `model.py` is not in
  `source.patch`.
- Reproducer: `scripts/reproducer/r6.py` runs the R6 cases N times each
  against `CWAL_BIN`; `shmloss.py` runs the lost-`-shm` case; `dbg.py` is the
  single-trial debug driver. Binaries in `binaries/reproducer-SHA256SUMS`:
  `r6-ReleaseSafe` is `2d00c0d` plus the `recover-begin` pause point and the
  test (no fix); `r6fix-ReleaseSafe` is the fix, identical to the
  ReleaseSafe binary of the main run.

| Log | Claim it backs |
|---|---|
| `logs/r6run.log` | Build hashes, plus the result and duration of every step |
| `logs/repeat-<build>-<i>.log` | 20 of 20 runs of `delaypoints` pass on each build |
| `logs/suite-Debug.log`, `suite-ReleaseSafe.log`, `suite-ReleaseFast.log` | `RESULT PASS` on each build |
| `logs/mut-none.log` | The swept sections pass with no mutation |
| `logs/mut-<mutation>.log`, `mut-<mutation>-delaypoints.log` | `rc=1` in `r6run.log` means detected |
| `logs/mut-no-root-check-delaypoints.log` | Caught by the "outsider dies" R6 case: the torn commit stays in `main.db` only |
| `logs/mut-no-repair-lock-delaypoints.log` | Caught by the `recover-truncate` R6 case: the outsider's checkpoint succeeds during recovery |
| `logs/mut-no-cross-flag.log` | Not detected by `survivors` in this run (probabilistic, about 1 in 10 trials); `delaypoints` catches it |
| `logs/mut-no-late-alone.log` | Not detected by `ndangle`, as recorded before; `delaypoints` catches it |
| `logs/mut-no-early-heads-delaypoints.log`, `mut-heads-process-wide-delaypoints.log` | Not detected: the R3 cases still refuse, now through the root-page check (`backfill_seen=True`) |
| `logs/mask-no-early-heads+no-root-check.log` | With the root check also removed, both R3 cases fail, as in the T2/T3 run |
| `logs/mask-heads-process-wide+no-root-check.log` | With the root check also removed, the same-process R3 case fails, as in the T2/T3 run |
| `logs/mask-no-root-check.log` | `no-root-check` alone: both R3 cases still pass; only the R6 "outsider dies" case fails |
| `logs/model.log` | Every model and mutation as expected, exit 0: the foreign-checkpoint-with-power-loss run passes (3,809,327 states, 2,159 refusals); `no-root-check` and `no-ckpt-gate` with `no-root-check` are caught at 2,084 states; the ownership model passes (85,876 states) and its four mutations violate O2 |
| `logs/model-run1.log` | Same results, but `no-ckpt-gate` alone explores the whole space with no violation (3,809,327 states, 2,159 refusals); exit 1 |
| `logs/mask-no-ckpt-gate+no-root-check.log` | `no-ckpt-gate` is caught at 2,084 states once the root check is removed |
| `logs/reproducer/r6-first-ReleaseSafe.log` | Before the fix, first test version: 0 / 3 per case; the opener truncates `main.db-wal` after the outsider's checkpoint |
| `logs/reproducer/r6-prefix-ReleaseSafe.log` | Before the fix, final test: 0 / 3 for "outsider dies" and "outsider stays open" |
| `logs/reproducer/r6-fix-ReleaseSafe.log` | With the fix: 5 / 5 for each of the three cases |
| `logs/reproducer/r6-mut-no-root-check.log` | `no-root-check`: "outsider dies" 0 / 3, the others pass |
| `logs/reproducer/r6-mut-no-repair-lock.log` | `no-repair-lock`: "before truncation" 0 / 3, the others pass |
| `logs/reproducer/shmloss-r6-ReleaseSafe.log` | Before the fix: a completed outside checkpoint followed by a lost `-shm` is a silent tear, 0 / 3 |
| `logs/reproducer/shmloss-r6fix-ReleaseSafe.log` | With the fix: refused with every WAL unchanged, 3 / 3 |
