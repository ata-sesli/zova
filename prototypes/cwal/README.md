# CWAL prototype: atomic commits and consistent snapshots across WAL files

Standalone Zig prototype for issue #260. It is not part of Zova's build and
does not modify SQLite. It answers one question: can a set of SQLite files in
WAL mode (a main database plus attached stores) get

- cross-file crash atomicity: after any crash or power loss, a transaction is
  in every file or in none;
- consistent snapshots: a reader sees every file at the same commit;

while keeping WAL's concurrency (readers do not wait for fsyncs)?

**Answer: yes, at a cost.** A cross-file commit needs one extra fsync
(three instead of two). The commit-markers variant removes it: a cross-file
commit then costs the same as plain WAL on a real disk (2 fsyncs, 9.7 ms),
at the price of an explicit-transaction requirement for cross-file writes
and lower read throughput under a saturating writer (see
[Commit markers](#commit-markers-results)). Readers almost never wait for the writer (16 ms in
total for 4 readers over 3 s): on a real disk they reach about 76% of plain
WAL read throughput under a saturating writer.
Numbers are under [Results](#results).

Two protocol variants can be switched off to compare against the first
design (`CWAL_LAZY_COMMIT=0`, `CWAL_SNAPSHOT_READS=0`; both default to 1 and
must be the same for every process of a set):

- **Lazy commit**: `COMMITTED` is written without an fsync. If it is lost,
  recovery checks the WAL files and keeps a transaction that is complete on
  every member.
- **Snapshot reads**: a seqlock replaces the reader gate. A reader that
  starts while the writer is publishing opens every member at the state
  before that commit with `sqlite3_snapshot_open`.

## How it works

A VFS shim (`src/cwal.zig`) wraps SQLite's `unix` VFS. SQLite itself is
unchanged; the shim only observes and gates VFS calls, reads the documented
wal-index header, and repairs WAL files when nobody has the set open.

Files next to `main.db`:

| File | Purpose |
| --- | --- |
| `main.db-cwal` | Coordination journal: two 128-byte checksummed records (4 KiB apart), newest valid sequence wins. 4,224 bytes, never grows. |
| `main.db-cwal-snap` | Seqlock page (4 KiB, `mmap` shared): a sequence number, odd during the publication window, and each member's wal-index header from before the window. With commit markers also a cross-file flag for the current window and a broken flag. Not durable; reset when a handle opens the set alone. |
| `main.db-cwal-gate` | `flock`. With `CWAL_SNAPSHOT_READS=0`: readers hold it shared while pinning every member; the writer holds it exclusively during the publication window. Otherwise only used briefly at open. |
| `main.db-cwal-alive` | `flock`: every handle holds it shared; recovery needs it exclusively. |
| `main.db-cwal-writer` | `flock`: single writer. |
| `main.db-cwal-live` | `flock`: held by a writer that opened with a clean journal. |

### Commit (writer)

1. **Commit hook** (before SQLite's phase one). Members whose WAL write lock
   is held are the participants. For two or more, read each one's rollback
   point from its wal-index header — `mxFrame` (last committed frame), page
   size and WAL salts — and write `PREPARED{parts}` + fsync.
   The rollback point is the *logical* end of the WAL, not its file size:
   SQLite reuses a WAL from frame 0 after a checkpoint without shrinking it.
2. **First commit-time WAL fsync** (with `synchronous=FULL`, SQLite syncs a
   member's WAL after its commit frame and *before* publishing it in the
   wal-index). Open the publication window: copy every member's wal-index
   header (no member has published yet, so these are the last committed
   state) into the seqlock page, then make the sequence odd. With
   `CWAL_SNAPSHOT_READS=0`, take the gate exclusively instead. Publication
   of all members happens inside this window.
3. **First `SQLITE_FCNTL_COMMIT_PHASETWO`**. SQLite runs phase one for every
   member before phase two of any, so all members are published and durable.
   Close the window (sequence even, or release the gate), then write
   `COMMITTED`. With lazy commit there is no fsync here; the record is synced
   before the writer's next checkpoint (a checkpoint can reset a WAL, after
   which recovery could no longer see that the transaction completed) and
   when a writer opens the set.
4. **Rollback hook**: `IDLE`, or `BROKEN` if a commit frame was already
   written (a published member cannot be taken back while others read it),
   with fsync, before the window closes.

Single-file commits write no record; they only open the window during
publication, so that a reader cannot see a later solo commit on one file but
miss an earlier one on another.

### Reads

`beginRead` starts one read transaction on every member:

1. Load the sequence `s1`, then check the journal. `PREPARED` is acceptable
   while `-live` is held (the writer is alive); `PREPARED` without a live
   writer, or `BROKEN`, returns `error.Broken`. The journal is read after
   `s1` because a writer that rolls back marks the set `BROKEN` before it
   closes the window. A reader skips this check when `s1` is even and equal
   to the sequence at which it last found the journal `IDLE` or
   `COMMITTED`: a clean journal becomes unreadable only through a window,
   which moves the sequence. The one exception is a writer that dies after
   writing `PREPARED` but before opening the window; it published nothing,
   so every member still shows the last committed state.
2. `s1` even (no publication in progress): `BEGIN`, touch every member
   (taking its WAL read lock), load the sequence again. If it is still `s1`,
   no publication happened while the members were pinned, so they show one
   point between commits. Otherwise roll back and retry.
3. `s1` odd: copy the saved headers, recheck the sequence, `BEGIN`, and
   `sqlite3_snapshot_open` each member at its saved header — the state
   before the commit that is being published. If SQLite cannot open the
   snapshot (rare; it could not keep a read mark there), roll back and wait
   for the window to end.

Each handle reads every member once at open, because
`sqlite3_snapshot_open` needs the member's WAL to be open already.

With `CWAL_SNAPSHOT_READS=0`, `beginRead` instead takes the gate shared,
checks the journal, touches every member and releases the gate.

A writer that dies inside a single-file commit's window leaves the sequence
odd with a clean journal, so no recovery runs. The next writer makes it even
at open; without that every later window would flip its parity.

### Checkpoint gate

Copying frames of an unfinished cross-file commit into a database file would
make it impossible to roll back. Two paths are gated, and the second one is
easy to miss:

- `xShmLock(WAL_CKPT_LOCK, exclusive)` — explicit and automatic checkpoints.
- `xLock(SQLITE_LOCK_EXCLUSIVE)` on a member database file —
  `sqlite3WalClose` takes this lock, switches the WAL to exclusive mode and
  then checkpoints **without** calling `xShmLock` for the checkpoint lock.
  Gating only `WAL_CKPT_LOCK` does not stop close-time checkpoints.

Both return `SQLITE_BUSY` unless the caller is the writer, outside a commit,
and the journal is `IDLE` or `COMMITTED`. Readers therefore never checkpoint,
and a reader closing while the set is torn leaves the WAL in place.

### Recovery

Runs on open when the handle gets `-alive` exclusively (nobody else has the
set open) and the journal is `PREPARED` or `BROKEN`.

**Roll forward** (lazy commit, `PREPARED` only): if every recorded member's
WAL holds a commit frame after its rollback point that SQLite's own WAL
recovery would accept — valid header, header salts in every frame, unbroken
checksum chain from frame 1 — the transaction completed and only its
`COMMITTED` record was lost. Keep every WAL as it is. (If the salts differ
from the recorded ones, the transaction reset the WAL and its frames start
at frame 1.)

**Roll back** otherwise. For each recorded part: if the WAL header salts
still match, truncate the WAL to `32 + frames × (24 + page_size)`; if they
differ, the torn transaction reset the WAL (SQLite resets only after every
frame was checkpointed), so truncate to 0. Then fsync.

Finally delete every member's `-shm`, reset the seqlock, and write `IDLE`.
Each step is idempotent and `IDLE` is written last, so a crash anywhere in
recovery just reruns it. Rolling back only removes frames, so a rerun after
a partial rollback still decides to roll back.

While other handles still have the set open, recovery cannot run; they get
`error.Broken` on their next `beginRead`, close, and the last one to reopen
recovers.

### Commit markers (`CWAL_COMMIT_MARKERS=1`)

A variant that drops the `PREPARED` record, and with it the journal and its
fsync: a cross-file commit costs the same two fsyncs as plain WAL. It needs
snapshot reads.

**Commit.** Each member has a one-row table
`cwal_marker(k, txn, mask)`, created by the writer at open. `Conn.commit`
counts the members whose WAL write lock is held; for two or more it numbers
the transaction (`txn` = previous + 1), updates the marker row in each of
those members to `(txn, mask of members)`, and then runs `COMMIT`. The
markers are ordinary rows, so they commit atomically with each member's
data. The commit hook refuses a cross-file commit without markers, so a
cross-file statement cannot autocommit: `Conn.autocommit` wraps it in an
explicit transaction. The publication window works as before, and the
seqlock page records whether the window belongs to a cross-file commit.

**Recovery** (on exclusive open). Read each member's marker as SQLite sees
the file (database plus valid WAL frames), through a connection that does not
checkpoint on close. Take the newest marker. If a member in its mask has an
older marker, that transaction is torn: for each member that has it, truncate
the WAL to the start of its last commit (the end of the commit before it, or
the WAL header if there is none) and fsync. Then delete every `-shm`.
This works because only the newest cross-file transaction can be torn: the
writer starts the next commit only after every member of this one is
durable, so the torn transaction is the last commit in each member that has
it, and it cannot have been checkpointed (the writer checkpoints only
between commits). Truncating only removes frames, so recovery is
idempotent.

**Readers and open.** There is no journal to check:

- `error.Broken` if the broken flag is set (a writer rolled back after a
  member published), or if the sequence is odd, the window is cross-file
  and no writer is alive (some members may have published).
- A writer that opens while other handles are open refuses (`Broken`) an odd
  sequence with the cross-file flag; that set needs recovery. An odd
  sequence from a single-file window is closed as before.
- A writer that dies after writing frames but before opening the window
  leaves the members unpublished; readers and a new writer see the last
  committed state, and SQLite overwrites the unpublished frames on the next
  write. If the set is closed first, recovery finds the frames, sees the
  marker missing elsewhere and removes them.

## Running

```bash
cd prototypes/cwal
zig build                      # Debug, for torture
python3 torture.py --work /tmp/cwal-torture
zig build -Doptimize=ReleaseFast
./bench.sh /tmp/cwal-bench     # filesystem chosen by the directory
```

`zig-out/bin/cwal` commands: `seed`, `writer`, `reader`, `check`, `recover`,
`state`, `bench`, `benchrw`. Fault injection is controlled by environment:
`CWAL_CRASH_AT=n` (SIGKILL at event n), `CWAL_CRASH_TAG=t` (count only events
tagged t), `CWAL_POWERLOSS=1` + `CWAL_SEED`, `CWAL_TRACE=1`, and
`CWAL_MUTATE=…` (test-only defects, to show the tests catch them; see the
mutation table). Protocol variants: `CWAL_LAZY_COMMIT`,
`CWAL_SNAPSHOT_READS`, `CWAL_COMMIT_MARKERS`; `CWAL_WINDOW_DELAY_US` widens the publication window
for tests. `bench.sh` takes `CWAL_BIN` to run a separate ReleaseFast build.

## Tests

Every test also runs a **plain-WAL baseline**: the same VFS and workload with
the protocol off. Its failures show the oracle detects torn commits and mixed
snapshots.

Writer workload (20 rounds, deterministic event sequence): explicit
`BEGIN…COMMIT` cross-file inserts; *implicit* (autocommit) cross-file inserts
through a TEMP trigger; single-file commits on each file; a cross-file
transaction larger than the page cache (SQLite spills uncommitted frames into
both WALs before the commit); and `PASSIVE`, `RESTART` and `TRUNCATE`
checkpoints, so later commits reuse the WAL from frame 0 with new salts and
old frames still in the file. With commit markers the implicit cross-file
insert runs through `Conn.autocommit`, that is, inside an explicit
transaction.

The checker opens the set (running recovery), then requires
`integrity_check = ok` on each file, identical pair-id sets forming a prefix
`1..k`, matching bulk row counts, every acknowledged commit present, and a
clean journal.

| Test | What it does |
| --- | --- |
| Process crash | SIGKILL the writer at every fault event (each write, fsync, truncate, lock, shm lock, protocol step), recover, check. |
| Crash during recovery | For 40 torn states, kill recovery at every one of its events, once and twice in a row, then check. |
| Power loss | As above, but writes not yet fsynced are kept in memory; at the crash each is dropped, persisted, or torn at 512-byte granularity (3 seeds). Also during recovery. |
| Concurrent snapshots | One writer process and two reader processes with two threads each. Readers pause between pinning members, attempt `PASSIVE` checkpoints, and close/reopen read-write connections (close-time checkpoints). Besides the pair and bulk counts, a reader also requires the single-file commits to be in order (`solo_s` equals `solo` or is one behind). The writer's window is widened by 300 µs, and the test runs twice: with all checkpoint modes (`RESTART`/`TRUNCATE` wait for readers, so the writer commits little while readers run) and with `PASSIVE` only. |
| Surviving readers | Kill the writer at a random fsync or at the phase-two notification (inside the window) while reader processes keep running; restart a writer while they run; check afterwards. Half the trials use `PASSIVE` checkpoints only. |
| Close-time checkpoint | One reader connection stays open while the writer is killed at each of its first 40 fsyncs; the reader then closes as the last connection, which makes SQLite try to checkpoint. |
| Mutations | Rerun with each protocol piece disabled. |

## Results

Linux 7.2, x86_64, 8 CPUs, SQLite 3.53.4 (vendored, built with
`SQLITE_ENABLE_SNAPSHOT`), Zig 0.17.0. Measured on 2026-11-25.

### Correctness

Both variants on (the default):

| Test | Plain WAL (baseline) | CWAL |
| --- | --- | --- |
| Process crash at every writer event | 118 / 1,220 torn | **0 / 1,379** |
| Crash during recovery, once and twice (40 torn states) | — | **0 / 3,868** |
| Power loss at every writer event, 3 seeds | 354 / 3,660 torn | **0 / 4,137** |
| Power loss during recovery (20 torn states, 3 seeds) | — | **0 / 5,730** |
| Concurrent snapshots, 2 processes × 2 threads, both checkpoint workloads | 78 mixed reads | **0 mixed** / 2,172; 164 snapshot reads; 83/83 reader checkpoints denied |
| Writer killed, readers survive (20 trials) | 119,433 mixed reads, 7 torn sets | **0 mixed** / 306,165; 1,669 snapshot reads; 83 `Broken` reopens; 0 torn |
| Last reader closes after writer killed at each of 40 fsyncs | 10 / 40 torn | **0 / 40** |

Recovery outcomes. Process crash: 324 of 1,379 crash points left the
journal `PREPARED`; recovery rolled 77 forward and 247 back. Power loss:
2,192 of 4,137 left it `PREPARED`; 1,434 rolled forward (mostly a lost
unsynced `COMMITTED`), 758 back.

Single-variant runs also pass: lazy commit only (crash, recovery, power
loss, survivors) and snapshot reads only (readers, survivors, close
checkpoint), each 0 failures and 0 mixed reads.

Mutations. Each test-only defect is caught by at least one test:

| Mutation | Caught by |
| --- | --- |
| `no-gate` (no publication window) | 79 mixed snapshots |
| `no-seq-check` (accept a read without rechecking the sequence) | 47 mixed snapshots |
| `no-snapshot-open` (inside a window, pin current state instead of the saved headers) | 107 mixed snapshots |
| `no-solo-window` (no window for single-file commits) | 21 out-of-order solo commits |
| `always-rollforward` (keep every `PREPARED` transaction) | 125 / 1,379 torn sets in the crash matrix |
| `always-rollback` (never roll forward) | 581 / 1,379 lost acknowledged commits under power loss |
| `no-salt-check` (ignore WAL resets in recovery) | 22 / 1,379 torn sets in the crash matrix |
| `no-lock-gate` (close-time checkpoints allowed) | 8 / 40 torn sets in the close test |
| `no-ckpt-gate` (`WAL_CKPT_LOCK` not gated) | 2 / 40 torn sets in the close test; 16,492 mixed reads and 1 torn set in the survivor test |

Rerun after readers started skipping the journal check (see Overhead):
the crash, recovery and power-loss results are identical; concurrent
snapshots 0 mixed of 2,355 (166 snapshot reads); survivors 0 mixed of
313,430; close test 0 / 40. Every mutation is still caught (`no-gate` 71,
`no-seq-check` 35, `no-snapshot-open` 95, `no-solo-window` 14 mixed reads;
the others unchanged).

No test produces `BROKEN` (a writer that rolls back after a member
published). The reader's journal check for it, and the rule for skipping
that check, are argued but not exercised.

### Overhead

Medians of 3 interleaved repetitions, ReleaseFast. `base` is the first
design (synced `COMMITTED`, reader gate); `lazy` and `snap` enable one
variant each; `both` is the default.

Commit latency, 500 commits each, one 100-byte row per commit. `pair` writes
both files (implicit transaction via TEMP trigger); `solo` writes one file.

| Commit | Filesystem | Plain FULL | Plain NORMAL | CWAL base | CWAL lazy | CWAL snap | CWAL both |
| --- | --- | --- | --- | --- | --- | --- | --- |
| pair, mean | btrfs / SSD | 10.15 ms | 0.12 ms | 18.74 ms | 14.63 ms | 19.15 ms | **14.39 ms** |
| pair, fsyncs | | 2 | 0 | 4 | 3 | 4 | **3** |
| solo, mean | btrfs / SSD | 4.95 ms | 0.09 ms | 4.92 ms | 5.06 ms | 4.80 ms | 5.00 ms |
| solo, fsyncs | | 1 | 0 | 1 | 1 | 1 | 1 |
| pair, mean | tmpfs | 43.7 µs | 40.6 µs | 52.8 µs | 52.1 µs | 50.6 µs | 49.3 µs |
| solo, mean | tmpfs | 22.7 µs | 21.3 µs | 26.0 µs | 26.1 µs | 23.2 µs | 23.4 µs |

- Lazy commit removes one fsync per cross-file commit (4 → 3): −22% latency
  on btrfs (−23% with both variants). A cross-file commit now costs 1.4× plain `FULL` instead of 1.8×.
- Single-file commits cost nothing measurable. With snapshot reads the shim
  adds about 1–6 µs per commit (tmpfs); the gate's `flock` calls are gone.
- Journal storage: 4,224 bytes, plus the 4 KiB seqlock page, per set.

Concurrent reads: one writer committing cross-file transactions back to back
(`synchronous=FULL`) and 4 reader threads, each running `beginRead`, two
point queries and a rollback, for 3 s.

| Filesystem | Mode | Reads/s | Commits/s | Reader wait | Snapshot reads |
| --- | --- | --- | --- | --- | --- |
| btrfs / SSD | plain | 206,957 | 129 | — | — |
| btrfs / SSD | CWAL base | 32,235 | 58 | 3.5 s | — |
| btrfs / SSD | CWAL lazy | 32,610 | 70 | 4.3 s | — |
| btrfs / SSD | CWAL snap | 128,625 | 73 | 0 | 67,870 |
| btrfs / SSD | CWAL both, journal checked on every read | 124,762 | 92 | 16 ms | 83,750 |
| btrfs / SSD | CWAL both (current) ¹ | **148,880** | **100** | 16 ms | 87,658 |
| tmpfs | plain | 51,396 | 14,181 | — | — |
| tmpfs | CWAL base | 71,812 | 5,858 | 1.0 s (writer 1.4 s) | — |
| tmpfs | CWAL snap | 41,698 | 11,046 | 0 | 30,036 |
| tmpfs | CWAL both, journal checked on every read | 39,990 | 11,217 | 0 | 28,371 |
| tmpfs | CWAL both (current) ¹ | **45,174** | **10,906** | 0 | 36,697 |

¹ Separate run (3 interleaved repetitions against plain). Plain WAL in that
run: 194,922 reads/s and 140 commits/s on btrfs, 53,803 reads/s and 13,658
commits/s on tmpfs.

- On a real disk, snapshot reads raise reader throughput about 4× (32k →
  125k reads/s) and readers no longer wait. About 22% of reads started
  inside a window and used snapshots.
- Skipping the journal check while the sequence has not moved (and reading
  both journal slots with one `pread`) raised reads from 60% to 76% of plain
  WAL on btrfs (125k → 149k reads/s), and from 78% to 84% on tmpfs. On
  btrfs about 70% of reads skip the journal. Before the change, a reader
  spent about 17 µs starting a read against 8 µs for plain WAL; 6 µs of it
  was the journal check.
- The remaining gap is the snapshot path: a read that starts inside a
  window spends about 17 µs in `sqlite3_snapshot_open`, against about 9 µs
  to pin members normally (both measured with temporary timers), and about
  20% of reads on btrfs start inside a window.
- The writer also gains: 58 → 92 commits/s on btrfs (plain: 129), from the
  removed fsync and from no longer waiting for readers on the gate.
- On tmpfs the gate favoured readers (72k reads/s, but the writer was held
  to 5.9k commits/s). With snapshot reads the writer runs at 11.2k
  commits/s (79% of plain) and readers at 40k reads/s (78% of plain).
  Commits are so frequent there that a reader's pin is often overlapped by
  a new window and retried (about 65k retries per 3 s run).
- Across runs on btrfs the `base` reader throughput varied widely (32k here,
  52.8k in the run of 2026-11-24); the `both` runs stayed within
  115k–135k.

### Commit markers results

`CWAL_COMMIT_MARKERS=1` (with snapshot reads). Correctness, same suites as
above:

| Test | CWAL with commit markers |
| --- | --- |
| Process crash at every writer event | **0 / 1,458**; 135 recoveries rolled back a torn transaction |
| Crash during recovery, once and twice (40 torn states) | **0 / 6,240** |
| Power loss at every writer event, 3 seeds | **0 / 4,374**; 405 rolled back |
| Power loss during recovery (20 torn states, 3 seeds) | **0 / 9,360** |
| Concurrent snapshots, both checkpoint workloads | **0 mixed** / 1,505; 227 snapshot reads |
| Writer killed, readers survive (20 trials) | **0 mixed** / 311,520; 67 `Broken` reopens; 0 torn |
| Last reader closes after writer killed at each of 40 fsyncs | **0 / 40** |

The writer opens with more events (it creates the marker tables), hence
1,458 crash points instead of 1,379. The default variant was rerun in the
same session with the results listed under Correctness.

| Mutation (commit markers) | Caught by |
| --- | --- |
| `no-markers` (cross-file commits write no markers) | 119 / 1,408 torn sets in the crash matrix |
| `no-marker-rollback` (recovery detects a torn transaction but keeps it) | 135 / 1,458 torn sets under power loss |
| `no-cross-flag` (a new writer closes a dead writer's cross-file window without recovery) | 17,938 mixed reads and 1 torn set in the survivor test |
| `no-gate`, `no-seq-check`, `no-snapshot-open`, `no-solo-window` | 77, 39, 102 and 10 mixed reads |
| `no-lock-gate`, `no-ckpt-gate` | 8 / 40 and 4 / 40 torn sets in the close test |

Overhead, one run of all variants (3 interleaved repetitions, medians,
ReleaseFast). Commit latency is the median (p50); one `both` repetition had
outliers that put its mean at 18.5 ms.

| Measure | Plain FULL | CWAL both | CWAL markers |
| --- | --- | --- | --- |
| btrfs: cross-file commit, fsyncs | 2 | 3 | **2** |
| btrfs: cross-file commit, p50 | 9.73 ms | 14.78 ms | **9.64 ms** |
| btrfs: single-file commit, p50 | 5.06 ms | 5.00 ms | 4.59 ms |
| btrfs: reads/s, 4 readers + writer | 204,291 | 149,538 | 132,326 |
| btrfs: commits/s in that test | 136 | 93 | **133** |
| btrfs: reads that used snapshots | — | 22% | 34% |
| tmpfs: cross-file commit, p50 | 42.5 µs | 47.9 µs | 65.6 µs |
| tmpfs: reads/s | 52,700 | 44,570 | 66,932 |
| tmpfs: commits/s | 13,959 | 10,812 | 8,102 |

- On a real disk the markers remove the third fsync: a cross-file commit
  costs the same as plain WAL, and the writer under reader load runs at
  plain speed (133 vs 136 commits/s, up from 93).
- Readers lose some throughput (150k → 132k reads/s) because the faster
  writer spends more of its time inside publication windows: 34% of reads
  started in one and took the slower `sqlite3_snapshot_open` path. The
  window still spans the second member's WAL write and fsync.
- On tmpfs, where commits are CPU-bound, each cross-file commit costs about
  23 µs more than with the journal: the marker `UPDATE`s (parsed each time)
  and one extra WAL frame per member. The writer is slower (8.1k vs 10.8k
  commits/s) and readers correspondingly faster.
- No journal file; each member gains a one-row table (one 4 KiB page).

### Possible further reductions (not implemented)

- **Cheaper snapshot reads**: find out where `sqlite3_snapshot_open`
  spends its 17 µs (likely read-mark and checkpoint-lock calls) and whether
  a reader can avoid them.
- **Cheaper markers**: prepare the marker `UPDATE`s once per handle; on
  tmpfs most of the markers' 23 µs per commit is statement overhead.
- **Fewer retries under very frequent commits**: when a pin is overlapped by
  a window, go straight to the snapshot path for that window instead of
  restarting.

## Limits

- Only handles that go through this protocol are coordinated. Any other
  SQLite connection to a member (CLI, backup tool) can checkpoint or read
  mixed states.
- Readers must start transactions with `beginRead`; a plain `BEGIN` gets no
  cross-file snapshot.
- Requires `synchronous=FULL` (or `EXTRA`) on every member; the publication
  window begins at the commit-time WAL fsync, which `NORMAL` does not issue.
  `NORMAL` would also not be power-safe across files.
- After a writer crash in the middle of a cross-file commit, the set is
  unreadable until every handle has closed and one reopens (recovery needs
  exclusive access). Readers get `error.Broken` rather than a mixed view.
- The power-loss model does not simulate directory-entry loss (no directory
  fsync) and runs single-process only. Process-crash tests are multi-process.
- One writer per set, enforced with `flock`. Lock files assume a local
  filesystem.
- The wal-index header layout is a documented file format
  (walformat.html), but reading it from a VFS is not a supported SQLite API.
- Snapshot reads build a `sqlite3_snapshot` from a saved wal-index header.
  The two have the same contents in SQLite 3.53.4, but `sqlite3_snapshot` is
  documented as opaque, so this relies on an implementation detail. They
  also need `SQLITE_ENABLE_SNAPSHOT`, which Zova's build does not set.
- Roll-forward recovery reads every frame of each recorded WAL once (only
  after a crash in a cross-file commit).
- Commit markers: cross-file writes must commit through `Conn.commit` or
  `Conn.autocommit`; a cross-file autocommit statement issued directly is
  refused by the commit hook. Each member holds a `cwal_marker` table, which
  a production version would hide from the public API. Recovery opens each
  member with a separate SQLite connection to read its marker. A writer that
  reopens while readers are open (no recovery) takes its transaction number
  from the published markers, so it may reuse the number of an unpublished,
  abandoned transaction; that is harmless with two members (every
  cross-file commit writes both) but needs care with more.
- Tested on Linux x86_64 with SQLite 3.53.4 (the vendored copy), tmpfs and
  btrfs.
