# T1 early evidence: native Apple Silicon torture run, 2026-11-27

- Purpose: early native weak-memory evidence for tracked item T1 (the
  checkpoint counter's seqlock relies on store-then-load ordering across two
  `xShmBarrier` calls, which x86-64 gives for free and ARM64 does not), plus
  the macOS checks of §9 (flock, mmap, fsync on APFS).
- Source: the prototype at `0f418a0` plus `source.patch` (SHA-256
  `3a0dbf8c10e7bd03c5be25523a3ab93a919f282e21b3ff1af59d3e1c31eee6ff`, apply
  from the repository root). The patch is portability only: errno through
  `std.c._errno()` in `cwal.zig` (as `0f418a0` did for `src/cwal`), and two
  compile fixes in `workload.zig` (no `clock_nanosleep` on macOS; `struct
  rusage` has a plain `ru_maxrss` there). No protocol logic changed. The
  prototype source in the repository is not committed with these edits.
- Build: Debug, `zig build` in `prototypes/cwal` (`binaries/SHA256SUMS`).
- Host: Apple M1, macOS 15.7.8, see `HOST.txt`. Scratch filesystem: APFS on
  an external USB solid-state disk (`/Volumes/wipesides`), not the internal
  disk; 6 jobs.
- Drivers: `scripts/run.sh` (ten sections, one `torture.py --only` call
  each, log `logs/run.log`), `scripts/ckptrace-repeat.sh` (log
  `logs/ckptrace-repeat.log`), `scripts/apfs-checks.sh` (log
  `logs/apfs-checks.log`). Options: `--jobs 6 --powerloss-seeds 1 --ncap 300
  --allcap 400 --survivor-trials 5 --restart-seeds 1 --io-positions 4
  --files 2 3 8`.
- Linux reference for the counts: `../2026-11-27-r6-partial-a0f73da/logs/suite-ReleaseSafe.log`
  (x86-64, ReleaseSafe, tmpfs, 8 jobs).

| Log | Claim it backs |
|---|---|
| `logs/run.log` | All ten sections end `RESULT PASS` with exit code 0 |
| `logs/readers.log` | cwal `mixed` 0 in both checkpoint modes (1522 and 815 reads); plain SQLite `mixed` 26 and 67 |
| `logs/ckptrace.log`, `logs/ckptrace-run2.log` to `-run4.log` | 4 of 4 unmutated runs: `ckpt_violations` 0 with 55, 65, 59, 57 checkpoint races |
| `logs/ckptrace-mutated-no-ckpt-validate.log` | With `CWAL_MUTATE=no-ckpt-validate`: 53 violations in 53 races, `RESULT FAIL`, exit code 1 |
| `logs/ckptreset.log` | 5 of 5 cases: counter active after the crash, 0 after the next writer, `check=ok` |
| `logs/closeckpt.log` | cwal 40 runs, 0 check failures; plain 40 runs, 15 failures |
| `logs/nreaders.log` | Every cwal line for 2, 3 and 8 files: `mixed` 0, `ckpt_violations` 0, `check=ok` |
| `logs/crash.log` | cwal 1678 events, 0 failures, recoveries none 1527 / rollback 151; plain 1340 events, 135 failures (identical to the Linux run) |
| `logs/powerloss.log` | cwal 1678 runs, 0 failures; power loss during recovery: 20 torn states, 4320 runs, 0 failures (identical to the Linux run) |
| `logs/crash-recovery.log` | `--only crash recovery`: 40 torn states, 8640 runs, 0 failures (identical to the Linux run) |
| `logs/delaypoints.log` | 7 of 7 cases pass |
| `logs/ownership.log` | 17 of 17 cases pass; both races `overlaps=0` |
| `logs/apfs-checks.log` | flock, mmap and fsync observations on this APFS disk; sync calls issued by the bundled SQLite 3.53.4; `sqlite3MemoryBarrier` in the tested binary is `dmb ish` |

`recovery` runs only nested in `crash`, so it has its own
`--only crash recovery` invocation.

`logs/stopped-internal-disk-run/` holds the logs of a first run whose scratch
directory was on the internal APFS disk. It was stopped during `nreaders` to
move the scratch directory to the external disk; its six finished sections
passed. It backs no claim above.

## What this run does not cover

- One host (Apple M1), one Debug build, the reduced options above. No
  ReleaseSafe or ReleaseFast build, where the compiler reorders more.
- The sections are probabilistic for memory ordering: zero violations in 236
  checkpoint races shows no failure was observed, not that none is possible.
  The mutation shows the detector works on this host.
- No other ARM64 implementation (Linux/aarch64 server cores, Graviton,
  Ampere), no Rosetta.
- `powerloss` simulates lost and torn unsynced writes in the harness. It does
  not test what this disk keeps after a real power cut, and the prototype and
  SQLite's defaults use plain `fsync`, not `F_FULLFSYNC`.
- The internal APFS disk was not the scratch filesystem.
- The workload driver (`workload.zig`) only compiles on macOS; it still reads
  `/proc` and was not run.
