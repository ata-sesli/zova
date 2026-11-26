# T2/T3 verification runs, 2026-11-26

- Source: commit `3498a53` plus the uncommitted T2/T3 changes to `src/`
  and `torture.py`, saved as `source.patch` (SHA-256
  `71f6ab5e19dad284805c7d00784c255dc64b4f09de9ea39e5d19ab453868e18f`). To
  reproduce, check out `3498a53` and run `git apply source.patch` in
  `prototypes/cwal`. If these changes are committed later, the commit's
  `src/` and `torture.py` match this patch.
- Scratch filesystem: tmpfs. 8 jobs. See `HOST.txt`.
- Driver: `scripts/t23.sh` (log: `logs/t23.log`). It runs these steps in
  order:
  1. Builds Debug, ReleaseSafe and ReleaseFast.
  2. Runs the two new sections (`delaypoints`, `ownership`) 30 times per
     build.
  3. Runs the reduced torture suite on each build:
     `--jobs 8 --powerloss-seeds 1 --ncap 300 --allcap 400 --survivor-trials 5 --restart-seeds 1 --io-positions 4 --files 2 3 8`.
     It now includes both new sections.
  4. Runs the mutation sweep on ReleaseSafe. Each mutation runs only the
     sections that should catch it, with
     `--powerloss-seeds 1 --survivor-trials 10 --restart-seeds 2 --files 3 8`.
     The sweep includes the new mutations `no-early-heads`,
     `heads-process-wide` and `no-ownership`, and runs `no-cross-flag` and
     `no-late-alone` against both their old section and `delaypoints`.
- `model.py` was not rerun. T2/T3 do not change the modelled protocol.

| Log | Claim it backs |
|---|---|
| `logs/t23.log` | Build hashes, plus the result and duration of every step |
| `logs/repeat-<build>-<i>.log` | 30 of 30 runs of `delaypoints` and `ownership` pass on each build |
| `logs/suite-Debug.log`, `suite-ReleaseSafe.log`, `suite-ReleaseFast.log` | `RESULT PASS` on each build: 91 `pass` lines (the 70 enforcement cases, 4 delay-point cases, 17 ownership cases) and 0 `FAIL` lines |
| `logs/mut-none.log` | The swept sections pass with no mutation |
| `logs/mut-<mutation>.log` | `rc=1` in `t23.log` means detected |
| `logs/mut-<mutation>-delaypoints.log` | The same mutation against the `delaypoints` section |
| `logs/mut-no-late-alone.log` | Not detected by `ndangle` on ReleaseSafe (0 / 153 and 0 / 480), as recorded before T2. The deterministic test catches it (`mut-no-late-alone-delaypoints.log`). |
| `logs/mut-no-ownership.log` | All 10 refusal cases fail; the races show 369 and 50 overlapping intervals |
| `logs/mut-heads-process-wide-delaypoints.log` | Only the same-process R3 case fails: the opener truncates `main.db-wal` although the torn commit is already in `main.db` |
