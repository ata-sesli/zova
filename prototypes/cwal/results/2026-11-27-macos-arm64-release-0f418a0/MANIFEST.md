# T1 evidence: native Apple Silicon torture in release builds, 2026-11-27

- Purpose: close two gaps of `../2026-11-27-macos-arm64-0f418a0` (Debug
  only; 236 checkpoint races). The torture sections run as ReleaseSafe and
  ReleaseFast builds, and `ckptrace` runs 20 times per build mode (Debug,
  ReleaseSafe, ReleaseFast) plus once with the validation removed. Evidence
  only: T1 closes on the integrated build in phase 7.
- Source: the prototype at `0f418a0` (unchanged at `165bd60`) plus
  `source.patch` (SHA-256
  `3a0dbf8c10e7bd03c5be25523a3ab93a919f282e21b3ff1af59d3e1c31eee6ff`,
  identical to the Debug run's patch; portability only, apply from the
  repository root). The prototype source in the repository is not committed
  with these edits.
- Builds: `zig build -Doptimize=<mode> --prefix <external disk>` in
  `prototypes/cwal` (`binaries/SHA256SUMS`). The Debug binary has the same
  SHA-256 as the one the Debug run used.
- Host: Apple M1, macOS 15.7.8, see `HOST.txt`. Scratch filesystem and
  binaries: APFS on an external USB solid-state disk (`/Volumes/wipesides`);
  6 jobs.
- Driver: `scripts/run.sh MODE [sections|ckptrace]...`, run as
  `ReleaseSafe sections ckptrace`, `ReleaseFast sections ckptrace` and
  `Debug ckptrace`, one after another. Options: `--jobs 6 --powerloss-seeds 1
  --ncap 300 --allcap 400 --survivor-trials 5 --restart-seeds 1
  --io-positions 4 --files 2 3 8`. `recovery` runs only nested in `crash`,
  so both are covered by one `--only crash recovery` call.

| Log | Claim it backs |
|---|---|
| `logs/run-ReleaseSafe.log`, `logs/run-ReleaseFast.log` | Every section call ends `RESULT PASS` with exit code 0 in both builds |
| `logs/<mode>/readers.log` | cwal `mixed` 0 in both checkpoint modes |
| `logs/<mode>/ckptreset.log` | 5 of 5 cases: counter active after the crash, 0 after the next writer, `check=ok` |
| `logs/<mode>/closeckpt.log` | cwal 40 runs, 0 check failures (plain: 14 ReleaseSafe, 9 ReleaseFast) |
| `logs/<mode>/nreaders.log` | Every cwal line: `mixed` 0, `ckpt_violations` 0, `check=ok` |
| `logs/<mode>/powerloss.log` | cwal 1678 runs, 0 failures; during recovery 20 torn states, 4320 runs, 0 failures |
| `logs/<mode>/crash-recovery.log` | cwal 1678 events, 0 failures, recoveries none 1527 / rollback 151; 40 torn states, 8640 runs, 0 failures |
| `logs/<mode>/delaypoints.log`, `ownership.log` | 7 of 7 and 17 of 17 cases pass; both ownership races `overlaps=0` |
| `logs/Debug/ckptrace-run01..20.log` | 20 of 20 pass: 1205 races, 1200 fallbacks, 0 violations |
| `logs/ReleaseSafe/ckptrace-run01..20.log` | 20 of 20 pass: 1481 races, 1300 fallbacks, 0 violations |
| `logs/ReleaseFast/ckptrace-run01..20.log` | 20 of 20 pass: 1587 races, 1347 fallbacks, 0 violations |
| `logs/<mode>/ckptrace-mutated-no-ckpt-validate.log` | `CWAL_MUTATE=no-ckpt-validate` gives `RESULT FAIL`, exit code 1: Debug 50 violations (50 races, 50 fallbacks), ReleaseSafe 62 (69 races, 62 fallbacks), ReleaseFast 66 (76 races, 66 fallbacks) |

In the mutated runs the violation count equals the fallback count: every
race the validation would have caught is reported.

In `nreaders`, one plain-SQLite line per release build ends
`check=FAIL torn transactions=1`. Plain lines are the control without the
protocol and do not count toward the result.

## What this run does not cover

- One host and one CPU design (Apple M1). No other ARM64 implementation, no
  Linux/aarch64.
- 4,273 unmutated checkpoint races with 0 violations (plus the sections'
  own `ckptrace` runs) is still absence of an observed failure, not proof of
  the ordering argument.
- The prototype, not the integrated `src/cwal` build, which is where T1
  formally closes.
- Reduced options; simulated power loss only; plain `fsync` in the prototype.
