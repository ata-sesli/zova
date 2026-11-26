# Post-fix regression and mutation runs, 2026-11-26

- Source: commit `77c5b5a` (tag `cwal-prototype-baseline`). This is the
  prototype after the R1–R3 fixes.
- Scratch filesystem: tmpfs. The suites ran with 8 jobs. See `HOST.txt`.
- Driver: `scripts/postfix.sh`, which runs these steps in order:
  1. Builds Debug, ReleaseSafe and ReleaseFast.
  2. Runs the reduced torture suite on each build:
     `--jobs 8 --powerloss-seeds 1 --ncap 300 --allcap 400 --survivor-trials 5 --restart-seeds 1 --io-positions 4 --files 2 3 8`.
  3. Runs the mutation sweep (`scripts/postmut.sh`; each mutation runs only
     the sections that should catch it, with
     `--powerloss-seeds 1 --survivor-trials 10 --restart-seeds 2 --files 3 8`).
  4. Runs `no-late-alone` on the Debug build.
  5. Runs `model.py`.

| Log | Claim it backs |
|---|---|
| `logs/postfix.log` | Build hashes, the result and duration of each step |
| `logs/post-Debug.log`, `post-ReleaseSafe.log`, `post-ReleaseFast.log` | `RESULT PASS` in each build; 70 `pass` enforcement lines; crashed-set outcomes |
| `logs/post-mut-<mutation>.log` | One mutation each. `rc=1` in `postfix.log` means detected. |
| `logs/post-mut-late-alone-debug.log` | `no-late-alone` on Debug |
| `logs/post-model.log` | Model-check states and verdicts |
| `logs/xf-base-ReleaseSafe.log` | `no-cross-flag`, 40 survivor trials, post-fix binary: detected, 4 of 40 trials fail |
| `logs/xf-out-ReleaseSafe.log` | The same run on the pre-fix binary (SHA-256 `d3dec15ca1c769c52f965eb54cf3c5549267b4e2d7045a2c26a225cb61d4da5b`, built before the R1–R3 fixes): detected, 3 of 40 |

The two `xf-*` runs used this command:

```bash
CWAL_BIN=<binary> CWAL_MUTATE=no-cross-flag python3 torture.py --only survivors \
  --jobs 8 --powerloss-seeds 1 --survivor-trials 40 --restart-seeds 2 --files 3 8
```

The sweep ran with the `no-cross-flag` mutation at 10 trials, and the
mutation was not detected (`post-mut-no-cross-flag.log`). It is caught only
when a writer kill lands inside a cross-file window, roughly one trial in
ten.
