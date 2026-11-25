# CWAL prototype: atomic commits and consistent snapshots across WAL files

Standalone Zig prototype for issue #260. It is not part of Zova's build and
does not modify SQLite. It answers one question: can a set of SQLite files in
WAL mode (a main database plus attached stores) get

- cross-file crash atomicity: after any crash or power loss, a transaction is
  in every file or in none;
- consistent snapshots: a reader sees every file at the same commit;

while keeping WAL's concurrency (readers do not wait for fsyncs)?

**Answer: yes.** A cross-file commit costs the same two fsyncs as plain WAL
(10.1 ms vs 9.6 ms median on btrfs), and readers under a saturating writer
run at 107% of plain WAL read throughput on btrfs (the writer at 99%). The
costs are an explicit-transaction requirement for cross-file writes, and on
tmpfs, where commits are CPU-bound, about 24 µs more per cross-file commit.
Numbers are under [Results](#results).

The prototype first used a coordination journal (a `PREPARED` record and an
extra fsync per cross-file commit). It now uses commit markers only; the
journal design and its measurements are in the history of this directory
(README at commit 9810bc9). [Earlier designs](#earlier-designs) summarises
them.

## How it works

A VFS shim (`src/cwal.zig`) wraps SQLite's `unix` VFS. SQLite itself is
unchanged; the shim only observes and gates VFS calls, reads the documented
wal-index header, and repairs WAL files when nobody has the set open.

Files next to `main.db`:

| File | Purpose |
| --- | --- |
| `main.db-cwal-snap` | Seqlock page (4 KiB, `mmap` shared): a sequence number, odd during the publication window; each member's wal-index header from before the window; a cross-file flag for the current window; a broken flag; the checkpoint counter. Not durable; reset when a handle opens the set alone. |
| `main.db-cwal-alive` | `flock`: every handle holds it shared; recovery needs it exclusively. |
| `main.db-cwal-writer` | `flock`: single writer. |
| `main.db-cwal-live` | `flock`: held by a writer that opened a readable set. |

Each member also holds a one-row table `cwal_marker(k, txn, mask)`, created
by the writer at open.

### Commit (writer)

1. **Markers.** `Conn.commit` counts the members whose WAL write lock is
   held. For two or more it numbers the transaction (`txn` = previous + 1),
   updates the marker row in each of those members to `(txn, mask of
   members)`, and runs `COMMIT`. The markers are ordinary rows, so they
   commit atomically with each member's data. The commit hook refuses a
   cross-file commit without markers, so a cross-file statement cannot
   autocommit: `Conn.autocommit` wraps it in an explicit transaction.
2. **First commit-time WAL fsync** (with `synchronous=FULL`, SQLite syncs a
   member's WAL after its commit frame and *before* publishing it in the
   wal-index). Open the publication window: copy every member's wal-index
   header (no member has published yet, so these are the last committed
   state) into the seqlock page, record whether the commit is cross-file,
   then make the sequence odd. Publication of all members happens inside
   this window.
3. **First `SQLITE_FCNTL_COMMIT_PHASETWO`**. SQLite runs phase one for every
   member before phase two of any, so all members are published and durable.
   Make the sequence even.
4. **Rollback hook**: if a cross-file commit already wrote a commit frame (a
   published member cannot be taken back while others read it), set the
   broken flag before the window closes.

Single-file commits write no markers; they only open the window during
publication, so that a reader cannot see a later solo commit on one file but
miss an earlier one on another. A cross-file commit costs the same two fsyncs
as plain WAL.

### Reads

`beginRead` starts one read transaction on every member:

1. Load the sequence `s1`. Return `error.Broken` if the broken flag is set,
   or if `s1` is odd, the window is cross-file and no writer is alive
   (`-live` not held: some members may have published). The flags are read
   after `s1` because a writer that rolls back sets the broken flag before
   it closes the window.
2. `s1` even (no publication in progress): `BEGIN`, touch every member
   (taking its WAL read lock), load the sequence again. If it is still `s1`,
   no publication happened while the members were pinned, so they show one
   point between commits. Otherwise roll back and retry.
3. `s1` odd: copy the saved headers, recheck the sequence, `BEGIN`, and
   `sqlite3_snapshot_open` each member at its saved header — the state
   before the commit that is being published. If SQLite cannot open the
   snapshot (rare; it could not keep a read mark there), roll back and wait
   for the window to end. The VFS grants SQLite's shared checkpoint lock
   for these opens without a real lock and validates the checkpoint counter
   instead (see [Checkpoint counter](#checkpoint-counter)); if a checkpoint
   started meanwhile, the read is retried.

Each handle reads every member once at open, because
`sqlite3_snapshot_open` needs the member's WAL to be open already.

### Checkpoint gate

Copying frames of an unfinished cross-file commit into a database file would
make it impossible to roll back. Two paths are gated, and the second one is
easy to miss:

- `xShmLock(WAL_CKPT_LOCK, exclusive)` — explicit and automatic checkpoints.
- `xLock(SQLITE_LOCK_EXCLUSIVE)` on a member database file —
  `sqlite3WalClose` takes this lock, switches the WAL to exclusive mode and
  then checkpoints **without** calling `xShmLock` for the checkpoint lock.
  Gating only `WAL_CKPT_LOCK` does not stop close-time checkpoints.

Both return `SQLITE_BUSY` unless the caller is the writer, outside a commit
and its window, and the broken flag is clear. Readers therefore never
checkpoint, and a reader closing while the set is torn leaves the WAL in
place.

### Checkpoint counter

SQLite takes `WAL_CKPT_LOCK` shared around every snapshot open
(`walBeginReadTransaction`): one `fcntl` to take and one to release per
member. It does so only so that no checkpointer can choose to copy frames
past the snapshot and record that choice (`nBackfillAttempted`) on both
sides of the open's check. Every exclusive lock on that byte —
checkpoints, snapshot recovery and wal-index recovery — goes through this
VFS, so the VFS enforces the same rule without the lock:

- When an exclusive lock on the checkpoint byte is granted, and before
  SQLite can use it, the VFS adds to a counter in the seqlock page (started
  checkpointers, high 32 bits; active ones, low 32 bits). It retires the
  active count when SQLite releases the lock, before forwarding the release.
  A live process is therefore counted exactly while it holds the lock.
- A snapshot open's shared lock is granted without a real lock if no
  checkpointer is active, and the started count is remembered. At the
  release, an unchanged count means any checkpointer either finished
  before the open (its `nBackfillAttempted` is visible to the check) or
  started after the reader held its read mark (and stops below it). A
  changed count retries the whole read. If a checkpointer is active at the
  start, the VFS takes the real lock.
- A process killed while holding the lock leaves the active count raised,
  and every snapshot open would then take the real lock. A writer clears it
  at open: it takes every member's checkpoint lock itself (non-blocking,
  retried for up to 1 s), and while it holds them every counted
  checkpointer must be dead, so it zeroes the active count. If a live
  process keeps a lock past the deadline, the count stays, which only costs
  readers the real lock.

### Recovery

Runs on open when the handle gets `-alive` exclusively (nobody else has the
set open). Read each member's marker as SQLite sees the file (database plus
valid WAL frames), through a connection that does not checkpoint on close.
Take the newest marker. If a member in its mask has an older marker, that
transaction is torn: for each member that has it, truncate the WAL to the
start of its last commit (the end of the commit before it, or the WAL header
if there is none) and fsync. Then delete every `-shm` and reset the seqlock
page.

This works because only the newest cross-file transaction can be torn: the
writer starts the next commit only after every member of this one is
durable, so the torn transaction is the last commit in each member that has
it, and it cannot have been checkpointed (the writer checkpoints only
between commits). Truncating only removes frames, so recovery is idempotent
and a crash during it just reruns it.

While other handles still have the set open, recovery cannot run:

- Readers get `error.Broken` (see [Reads](#reads)), close, and the last one
  to reopen recovers.
- A writer that opens refuses (`Broken`) an odd sequence with the cross-file
  flag. An odd sequence from a single-file window (a writer died inside it)
  is closed instead; without that, every later window would flip its
  parity.
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
`state` (prints the seqlock page), `bench`, `benchrw`. Fault injection is
controlled by environment: `CWAL_CRASH_AT=n` (SIGKILL at event n),
`CWAL_CRASH_TAG=t` (count only events tagged t), `CWAL_POWERLOSS=1` +
`CWAL_SEED`, `CWAL_TRACE=1`, and `CWAL_MUTATE=…` (test-only defects, to show
the tests catch them; see the mutation table). `CWAL_WINDOW_DELAY_US`,
`CWAL_CKPT_OPEN_DELAY_US` and `CWAL_CKPT_SCAN_DELAY_US` widen races for
tests. `bench.sh` takes `CWAL_BIN` to run a separate ReleaseFast build.

## Tests

Every test except the checkpoint ones also runs a **plain-WAL baseline**: the
same VFS and workload with the protocol off. Its failures show the oracle
detects torn commits and mixed snapshots.

Writer workload (20 rounds, deterministic event sequence): explicit
`BEGIN…COMMIT` cross-file inserts; cross-file inserts through a TEMP trigger,
run through `Conn.autocommit`; single-file commits on each file; a
cross-file transaction larger than the page cache (SQLite spills uncommitted
frames into both WALs before the commit); and `PASSIVE`, `RESTART` and
`TRUNCATE` checkpoints, so later commits reuse the WAL from frame 0 with new
salts and old frames still in the file.

The checker opens the set (running recovery), then requires
`integrity_check = ok` on each file, identical pair-id sets forming a prefix
`1..k`, matching bulk row counts, and every acknowledged commit present.

| Test | What it does |
| --- | --- |
| Process crash | SIGKILL the writer at every fault event (each write, fsync, truncate, lock, shm lock, protocol step), recover, check. |
| Crash during recovery | For up to 40 torn states, kill recovery at every one of its events, once and twice in a row, then check. |
| Power loss | As above, but writes not yet fsynced are kept in memory; at the crash each is dropped, persisted, or torn at 512-byte granularity (3 seeds). Also during recovery. |
| Concurrent snapshots | One writer process and two reader processes with two threads each. Readers pause between pinning members, attempt `PASSIVE` checkpoints, and close/reopen read-write connections (close-time checkpoints). Besides the pair and bulk counts, a reader also requires the single-file commits to be in order (`solo_s` equals `solo` or is one behind). The writer's window is widened by 300 µs, and the test runs twice: with all checkpoint modes (`RESTART`/`TRUNCATE` wait for readers, so the writer commits little while readers run) and with `PASSIVE` only. |
| Surviving readers | Kill the writer at a random fsync or at the phase-two notification (inside the window) while reader processes keep running; restart a writer while they run; check afterwards. Half the trials use `PASSIVE` checkpoints only. |
| Checkpoint race | The writer pauses 3 ms inside each `PASSIVE` checkpoint, after choosing how far to copy and before recording it; one reader thread pauses 1 ms inside each skipped checkpoint lock and stays in each read 5 ms. Every read checks that no checkpoint recorded an intent to copy past its snapshot (`nBackfillAttempted` ≤ the snapshot's `mxFrame`). |
| Checkpoint counter reset | Kill the writer right after it is granted its 1st…5th checkpoint lock, so the counter stays raised. Start a reader, then a new writer (window widened, `PASSIVE` checkpoints); after it closes the active count must be 0, and the set must check. |
| Close-time checkpoint | One reader connection stays open while the writer is killed at each of its first 40 fsyncs; the reader then closes as the last connection, which makes SQLite try to checkpoint. |
| Mutations | Rerun with each protocol piece disabled. |

## Results

Linux 7.2, x86_64, 8 CPUs, SQLite 3.53.4 (vendored, built with
`SQLITE_ENABLE_SNAPSHOT`), Zig 0.17.0. Measured on 2026-11-25.

### Correctness

| Test | Plain WAL (baseline) | CWAL |
| --- | --- | --- |
| Process crash at every writer event | 118 / 1,220 torn | **0 / 1,465**; 135 recoveries rolled back a torn transaction |
| Crash during recovery, once and twice (40 torn states) | — | **0 / 6,400** |
| Power loss at every writer event, 3 seeds | 354 / 3,660 torn | **0 / 4,395**; 405 rolled back |
| Power loss during recovery (20 torn states, 3 seeds) | — | **0 / 9,600** |
| Concurrent snapshots, 2 processes × 2 threads, both checkpoint workloads | 77 mixed reads | **0 mixed** / 2,341; 156 snapshot reads; 89/89 reader checkpoints denied |
| Writer killed, readers survive (20 trials) | 94,032 mixed reads, 5 torn sets | **0 mixed** / 315,421; 2,288 snapshot reads; 81 `Broken` reopens; 0 torn |
| Checkpoint race (widened) | — | 24 checkpoints started during a snapshot open; each read retried; **0** violated its snapshot |
| Checkpoint counter reset (5 crash points) | — | active count 1 after each crash, **0** after the next writer; 0–1 real-lock fallbacks per run |
| Last reader closes after writer killed at each of 40 fsyncs | 14 / 40 torn | **0 / 40** |

Mutations. Each test-only defect is caught:

| Mutation | Caught by |
| --- | --- |
| `no-markers` (cross-file commits write no markers) | 119 / 1,415 torn sets in the crash matrix |
| `no-marker-rollback` (recovery detects a torn transaction but keeps it) | 135 / 1,465 torn sets under power loss |
| `no-cross-flag` (a new writer closes a dead writer's cross-file window without recovery) | 52,505 mixed reads and 3 torn sets in the survivor test |
| `no-gate` (no publication window) | 84 mixed reads |
| `no-seq-check` (accept a read without rechecking the sequence) | 28 mixed reads |
| `no-snapshot-open` (inside a window, pin current state instead of the saved headers) | 101 mixed reads |
| `no-solo-window` (no window for single-file commits) | 9 out-of-order solo commits |
| `no-lock-gate` (close-time checkpoints allowed) | 11 / 40 torn sets in the close test |
| `no-ckpt-gate` (`WAL_CKPT_LOCK` not gated) | 5 / 40 torn sets in the close test |
| `no-ckpt-validate` (accept a skipped checkpoint lock without checking the counter) | 27 violations in 27 races |
| `no-ckpt-reset` (a writer does not clear a dead checkpointer) | active count stays 1; every snapshot open takes the real lock (2 fallbacks per snapshot read) |

`no-ckpt-skip` (always take the real checkpoint lock) is a control: 0
violations.

### Overhead

Medians of 3 repetitions, ReleaseFast, same VFS and build for both modes.

Commit latency, 500 commits each, one 100-byte row per commit. `pair` writes
both files (through a TEMP trigger; CWAL wraps it in an explicit transaction
with markers); `solo` writes one file.

| Commit | Filesystem | Plain FULL | Plain NORMAL | CWAL |
| --- | --- | --- | --- | --- |
| pair, p50 | btrfs / SSD | 9.56 ms | 0.07 ms | 10.10 ms |
| pair, mean | btrfs / SSD | 9.83 ms | 0.12 ms | 9.94 ms |
| pair, fsyncs | | 2 | 0 | 2 |
| solo, p50 | btrfs / SSD | 4.77 ms | 0.06 ms | 4.63 ms |
| solo, fsyncs | | 1 | 0 | 1 |
| pair, p50 | tmpfs | 42.1 µs | 39.7 µs | 66.3 µs |
| solo, p50 | tmpfs | 22.2 µs | 21.0 µs | 22.1 µs |

Concurrent reads: one writer committing cross-file transactions back to back
(`synchronous=FULL`) and 4 reader threads, each running `beginRead`, two
point queries and a rollback, for 3 s.

| Filesystem | Mode | Reads/s | Commits/s | Reads that used snapshots |
| --- | --- | --- | --- | --- |
| btrfs / SSD | plain | 201,218 | 136 | — |
| btrfs / SSD | CWAL | **215,841** | **134** | 53% |
| tmpfs | plain | 53,713 | 13,867 | — |
| tmpfs | CWAL | **75,153** | 9,428 | 39% |

- On a real disk a cross-file commit costs what plain WAL costs (same two
  fsyncs, within 0.5 ms), single-file commits cost nothing measurable, and
  the writer under reader load runs at plain speed.
- Readers never waited for a window to end in these runs.
- Readers are faster than plain WAL because a read that starts inside a
  window opens snapshots (about 3 µs for two members) instead of touching
  each member through SQL (about 8–9 µs); see
  [Snapshot read cost](#snapshot-read-cost). Plain WAL pays the same SQL
  touch in this benchmark.
- On tmpfs each cross-file commit costs about 24 µs more than plain WAL: the
  marker `UPDATE`s (parsed each time) and one extra WAL frame per member.
  The writer is slower (68% of plain) and readers correspondingly faster.
  Commits are so frequent there that a pin is often overlapped by a new
  window and retried (about 40k retries per run).
- Storage: the 4 KiB seqlock page per set, and a one-row table (one page)
  per member.

### Snapshot read cost

Per-phase timers in the VFS (temporary, ReleaseFast, btrfs, 4 reader
threads; measured before the journal was removed, on the same read path)
showed where `sqlite3_snapshot_open` spent its time, for two members:

| Step | Real checkpoint lock | Counter instead |
| --- | --- | --- |
| Shared checkpoint lock, take (2 calls) | 9.0 µs | 0.27 µs |
| Shared checkpoint lock, release (2 calls) | 4.8 µs | 0.22 µs |
| Other VFS calls (read mark, barriers) | ~1 µs | 1.0–1.2 µs |
| SQLite and shim CPU | 2.0 µs | 1.5–1.7 µs |
| **Whole open** | **16.9 µs** | **2.7–3.2 µs** (2.2 µs with 1 reader) |

The `fcntl` lock calls slow down as readers contend (7.3 µs per pair with 1
reader, 14.4 µs with 4). A normal read start (`BEGIN`, touch each member
through `sqlite3_exec`) costs 8.1–9.5 µs, and two queries after either start
cost the same within 0.5 µs. The read path's lower bound is therefore plain
WAL's own read start: the normal path adds two atomic loads of the sequence,
and the window path adds a 96-byte header copy, two counter loads, and a
retry if a checkpoint starts during the open.

Alternatives measured or considered and dropped:

- Holding the real checkpoint lock across reads (one `fcntl` pair per
  window): same read throughput, but it starved checkpoints (a writer
  `PASSIVE` checkpoint after every commit returned `SQLITE_BUSY` 20,787
  times against 2,767 successes on tmpfs).
- Opening snapshots only for members that already published: with the lock
  skipped an open costs about 1.1–1.5 µs per member, less than touching the
  member normally, so it saves little.
- Reusing a snapshot across reads while the window has not moved: under 1%
  of window reads could use it.

### Earlier designs

Before commit markers, a cross-file commit wrote a `PREPARED` record (with
each member's rollback point) to a two-slot journal and fsynced it, then
`COMMITTED` after publication; a variant wrote `COMMITTED` without an fsync
and rolled forward at recovery when every member's WAL held the commit. The
first design also made readers wait on a gate `flock` instead of using the
seqlock and snapshots. Measured on btrfs with the same harness in earlier
runs on the same machine (README at commit 9810bc9), so the rows are not
one same-run comparison:

| Design | Cross-file commit | Reads/s, 4 readers + writer | Commits/s |
| --- | --- | --- | --- |
| Journal, synced `COMMITTED`, reader gate | 4 fsyncs, 18.7 ms | 32,235 | 58 |
| Journal, lazy `COMMITTED`, snapshot reads | 3 fsyncs, 14.4 ms | 184,920 | 90 |
| Commit markers, snapshot reads (now) | 2 fsyncs, 10.1 ms | 215,841 | 134 |

The journal designs passed the same crash, power-loss and reader tests. They
were dropped because markers remove the extra fsync, the journal file and the
journal check on reads.

### Possible further reductions (not implemented)

- **Cheaper markers**: prepare the marker `UPDATE`s once per handle; on
  tmpfs most of the 24 µs per cross-file commit is statement overhead.
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
- Cross-file writes must commit through `Conn.commit` or `Conn.autocommit`; a
  cross-file autocommit statement issued directly is refused by the commit
  hook. Each member holds a `cwal_marker` table, which a production version
  would hide from the public API.
- After a writer crash in the middle of a cross-file commit, the set is
  unreadable until every handle has closed and one reopens (recovery needs
  exclusive access). Readers get `error.Broken` rather than a mixed view.
- Recovery opens each member with a separate SQLite connection to read its
  marker. A writer that reopens while readers are open (no recovery) takes
  its transaction number from the published markers, so it may reuse the
  number of an unpublished, abandoned transaction; that is harmless with two
  members (every cross-file commit writes both) but needs care with more.
- The power-loss model does not simulate directory-entry loss (no directory
  fsync) and runs single-process only. Process-crash tests are multi-process.
- One writer per set, enforced with `flock`. Lock files assume a local
  filesystem.
- The checkpoint counter counts only exclusive locks taken through this VFS
  (the same assumption as the checkpoint gate). A raised count left by a
  dead process is cleared only when a writer opens; until then readers take
  the real lock on snapshot opens. The race test reads `nBackfillAttempted`
  from the wal-index at a fixed offset.
- The wal-index header layout is a documented file format
  (walformat.html), but reading it from a VFS is not a supported SQLite API.
- Snapshot reads build a `sqlite3_snapshot` from a saved wal-index header.
  The two have the same contents in SQLite 3.53.4, but `sqlite3_snapshot` is
  documented as opaque, so this relies on an implementation detail. They
  also need `SQLITE_ENABLE_SNAPSHOT`, which Zova's build does not set.
- No test produces a rollback after a member published (the broken flag).
  The reader and checkpoint checks for it are argued but not exercised.
- Tested on Linux x86_64 with SQLite 3.53.4 (the vendored copy), tmpfs and
  btrfs.
