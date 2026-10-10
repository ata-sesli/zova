# #136: source-local incremental vector maintenance

Implementation baseline: `bcc1c9881198fa49921d4cf5d6a158f60d1cc1cd`.
Branch: `work/plugin-vector-maintenance-136`.
Package and application ABI remain 1.1.0. The explicitly approved storage
transition is 11→12; existing formats 9/10 retain their adjacent migrations.

## Implemented boundary

Negotiated plugin service 6 supplies caller-visible source views and bounded
change pages. It does not implement USearch/HNSW itself (#141). A test plugin
automatically reconciles an immutable base plus call-local delta through SQL;
ordinary inserts, replacements, deletes and transaction rollback are covered.

Two private source-local tables and five triggers commit vector changes and
history in the same SQLite file, including a bound vector store. History stores
public IDs and branch tokens, never duplicate vector payloads. Each collection
keeps 4096 events, retired in 256-event blocks, with at most 4351 visible rows.
Values delivered by reconciliation are the authoritative final values in the
caller's snapshot. Missing history and incompatible source coverage are explicit
errors, not empty deltas.

Collection incarnation detects deletion/recreation. A private nonce function
prevents application overrides of SQL randomblob() from breaking rollback-branch
identity. Savepoint/outer rollback undo both values and journal state. Bound
single-vector operations now also roll back late epoch failures within a caller
transaction, preserving its earlier work.

Immutable bases and per-snapshot deltas keep older WAL readers correct; tests
include history retirement by a newer connection. Logical retention does not
bound physical WAL growth while a long-lived reader pins old pages. No cross-file
WAL crash-atomicity claim is made for plugin generation storage in main and
vector source storage in a bound file.

Whole-collection backup, restore-to-memory and split preserve source identity and
coverage; merges create destination views. The explicit migration adds tracking
without rewriting existing native keys, public data or extension storage.
Retained format-11 fixtures were produced with the unmodified baseline CLI
before activating format 12; hashes are recorded in tests/fixtures/fixtures.sha256.

## Bounded measurement

External disk, Zig 0.17.0, SQLite 3.53.4, ReleaseFast, unchanged durability.
2048 vectors × 32 i8 dimensions; each sample includes 512 puts, 128 deletes and
transaction commit, followed by paged reconciliation, projection and parity.
One warmup and seven measured samples per main/bound case. These are absolute
host-maintenance costs, not a speedup claim or ANN latency/recall evidence.

| Source | Write+commit median / MAD (ms) | Reconciliation median / MAD (ms) |
| --- | --- | --- |
| Main | 5.399 / 0.138 | 0.382 / 0.002 |
| Bound | 6.637 / 0.286 | 0.410 / 0.027 |

Measured samples (milliseconds, excluding warmup):

| Run | Main write+commit | Main reconciliation | Bound write+commit | Bound reconciliation |
| --- | --- | --- | --- | --- |
| 1 | 4.897 | 0.383 | 7.737 | 0.478 |
| 2 | 5.224 | 0.381 | 6.637 | 0.464 |
| 3 | 5.506 | 0.382 | 7.046 | 0.472 |
| 4 | 5.399 | 0.385 | 6.708 | 0.410 |
| 5 | 5.555 | 0.381 | 6.485 | 0.389 |
| 6 | 5.391 | 0.383 | 6.174 | 0.386 |
| 7 | 5.537 | 0.379 | 6.351 | 0.383 |

Warmups: main write/reconcile 4.819/0.393 ms; bound 7.389/0.469 ms.

Both: 640 delivered events per sample; zero parity failures; journal DBSTAT
155648 bytes (including automatic indexes), payload 113336 bytes, unused
29573 bytes. The fixed test projection is 4104 bytes, not a real ANN index or
whole-process peak-memory measurement. Seven samples do not establish reliable
tail-latency guarantees.

Every sample and the reproduction script are retained:

- scripts/bench-vector-maintenance.sh
- /Volumes/wipesides/codebase-memory-mcp-cache/zova-1.1.0-release/vector-maintenance-136.H7CjR3/results.log

The final samples were collected after verification builds ended. Earlier
6i3qE1 evidence is retained; fpvo3y overlapped verification compilation and is
excluded from the final timing table. Main/bound measurements are separate
absolute workloads, not alternating variants or a controlled speedup comparison.

## Verification evidence

The final verification runner and its log are on the external disk:

- /tmp/zova-136-verify.sh
- /Volumes/wipesides/codebase-memory-mcp-cache/zova-1.1.0-release/zig17-verification/issue136/verification.log
- /Volumes/wipesides/codebase-memory-mcp-cache/zova-1.1.0-release/zig17-verification/issue136/snapshot-checks.log
- /Volumes/wipesides/codebase-memory-mcp-cache/zova-1.1.0-release/zig17-verification/issue136/wasm-compile.log

Final results:

- Complete Debug `zig build test c-abi-test check-storage-compat`: all 74 build
  steps succeeded, including C/C++ fixtures. Unchanged suites reused successful
  cache entries; the build summary's 287 passed/3 skipped counts only rerun tests,
  not the complete project's test inventory.
- ReleaseSafe: vectors 67/67, plugin ABI 48/48, migration 46/46, lifecycle 33
  passed/3 skipped. The process-termination migration publication/recovery driver
  also passed, separately from the mid-step SQL failure/rollback test.
- Immutable storage compatibility matrix: 140 checks, zero failures.
- Raw/safe Rust nextest: 91 passed, one ignored test skipped.
- Generated C compiled, passed C ABI smoke, and matched all 189 native exported
  application symbols. SHA256: generated zova_c.c
  `7cac4dd567439002e5fe2231f1ad626f5efd10bed3a3700bb04bfa904b8619ca`;
  ReleaseSafe libzova_c.a
  `58a4a97fb35983dca437f595b8622492ff93c09eb44e1127575707b35d442d59`.
- Go suite passed. Python 3.14 migration checks 8/8; JavaScript load/migration
  checks 7/7 and TypeScript build passed. Python/JavaScript full suites were not
  rerun in this task. Go emitted a local macOS deployment-target linker warning.
- Rust/Python snapshot synchronization and parity checks passed.
- Experimental WASM C ABI root compiled; no browser runtime/durability rerun.
- Formatters, package/ABI version check and git diff --check passed.

Native platform execution here is macOS arm64; other platforms remain CI work.
No CBM files, vendored SQLite sources or release workflows were changed.
