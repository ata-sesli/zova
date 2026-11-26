# CWAL prototype: atomic commits and consistent snapshots across WAL files

Standalone Zig prototype for issue #260. It is not part of Zova's build and
does not modify SQLite. It answers one question: can a set of SQLite files in
WAL mode (a main database plus up to 31 attached stores) get

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
| `main.db-cwal-gate` | `flock`: held exclusively while a handle opens (until SQLite has mapped every wal-index) or closes. See [Unpublished frames](#unpublished-frames). |

Each member also holds a one-row table `cwal_marker(k, txn, mask)`, created
by the writer at open.

### Commit (writer)

1. **Markers.** `Conn.commit` counts the members whose WAL write lock is
   held. For two or more it numbers the transaction (see
   [Transaction numbers](#transaction-numbers)), updates the marker row in each of those members to `(txn, mask of
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
- The two orderings that matter are a store followed by a load: the
  checkpointer's increment before it reads the read marks, and the reader's
  read mark before it re-reads the counter. A sequentially consistent
  read-modify-write does not order a later plain load on ARM64, so the VFS
  issues a full barrier (`xShmBarrier`) after the increment and before the
  release-time load, instead of relying on barriers inside SQLite.

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
between commits). A connection outside the protocol can checkpoint it;
recovery detects that and refuses (see [Enforcement](#enforcement)). Truncating only removes frames, so recovery is idempotent
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
  committed state. The new writer removes those frames at open (see
  [Unpublished frames](#unpublished-frames)). If the set is closed first,
  recovery finds the frames, sees the marker missing elsewhere and removes
  them.

### Transaction numbers

A marker number must name one transaction for the life of the set, also
after a writer died with a number in flight that was never published or that
recovery removed: otherwise a later transaction with the same number but a
different member set would look like the same transaction to recovery. Each
writer, at open, durably increments an epoch kept in `main`'s marker table
(row `k = 1`, taken as at least the newest published epoch) and numbers its
cross-file transactions `epoch << 32 | 1, 2, ...`. A number is consumed
before `COMMIT`, so a failed commit never reuses it. Recovery refuses
(`ProtocolViolation`) members that share the newest number with different
masks.

### Unpublished frames

A writer killed after writing a member's commit frames but before
publishing them leaves valid frames past that member's `mxFrame`. SQLite
ignores them while some process has the wal-index mapped, but whenever a
process maps a wal-index that no other process has mapped, SQLite rebuilds
it from the WAL file and accepts every valid frame. With more than two files
a later writer may never write that member again, so the dead writer's frames
would later appear as a committed, torn transaction. Three rules prevent it:

- **Discard at writer open.** A writer, after mapping every member, takes
  each member's WAL write lock and truncates its WAL to the published end
  (`32 + mxFrame × (24 + page size)`, after checking the file's salts match
  the wal-index), then fsyncs.
- **Open/close gate.** A handle holds `-gate` from before it tests `-alive`
  until SQLite has mapped every member, and while it unmaps them and
  releases `-alive`. So while the gate is free, every `-alive` holder has
  every wal-index mapped, and an opener that finds another holder cannot be
  the process that rebuilds a wal-index.
- **Second `-alive` test.** A holder can still die while an opener holds the
  gate. After mapping, the opener tries `-alive` exclusively again; if no
  holder is left, its mapping may have rebuilt a wal-index, so it closes
  SQLite without a checkpoint, runs recovery as the first handle would, and
  reopens.

A commit whose WAL fsync cannot read a member's wal-index header to open the
window fails that fsync (`SQLITE_IOERR_FSYNC`) before any member publishes.

### Enforcement

Statements on a CWAL handle that would bypass the protocol are refused, and
a set that a connection outside the protocol has damaged is refused rather
than repaired wrongly:

- **Authorizer.** Every CWAL handle installs an authorizer
  (`sqlite3_set_authorizer`) that denies writing, dropping or altering
  `cwal_marker`, triggers on it, `PRAGMA journal_mode`, `locking_mode`,
  `synchronous` and `writable_schema` with a value, and `ATTACH`/`DETACH`.
  `Conn.commit` turns it off for its own marker updates. `VACUUM` is denied
  too, because SQLite runs it through an internal `ATTACH`. Reading these
  pragmas is allowed.
- **Commit-frame guard.** The VFS fails (`SQLITE_IOERR_WRITE`) a WAL commit
  frame written outside a commit the commit hook approved. A path that skips
  the commit hook (`VACUUM` does) would otherwise publish a member with no
  window, or write from a reader handle. It is a second layer behind the
  authorizer.
- **WAL mode at open.** Opening runs `PRAGMA journal_mode=WAL` on every
  member and requires the result `wal` (`ProtocolViolation` otherwise). A
  member left in rollback-journal mode is switched back (WAL mode persists);
  a member that another connection holds open in another mode cannot be,
  and the open fails.
- **Foreign checkpoints.** Recovery reads each member's `-shm` before
  SQLite maps it (the first connection to open a member truncates it). It
  refuses with `ProtocolViolation` if a torn commit is already in the
  database file, where truncating the WAL would not remove it: the
  wal-index belongs to the member's WAL (same salts) and its `nBackfill`
  (frames a completed checkpoint copied) reaches past the truncation point;
  or the wal-index is one WAL restart ahead of the WAL (SQLite restarts a
  WAL only after checkpointing all of it); or the WAL's last commit does
  not write the marker table's root page, so it is not the torn commit.
  CWAL never checkpoints a torn commit, so only an outside connection gets
  there. Every member is checked before any is truncated, so a refused set
  is left as the crash left it.
- **Member ownership.** A member file belongs to one set at a time, so a
  set's recovery and checkpoints never run on a member another set has
  open (the set's own locks live next to its main file). Before anything
  else, an opener takes each member's `<member>-cwal-mgate` exclusively and
  tries `<member>-cwal-own` exclusively without blocking. If that works, no
  handle owns the member: the opener writes its set identity (every
  member's resolved path, in order) into the file and keeps the lock
  shared. Otherwise it joins only if the recorded identity is its own, and
  fails with `MemberOwned` if not. The record changes only under the
  exclusive lock, which needs every owner gone. The locks are `flock`, so
  handles and threads of one process exclude each other like processes do.
  A set that lists one file twice is refused (`ProtocolViolation`).
- **Wal-index heads on a shared open.** A shared opener reads every
  member's `-shm` head before SQLite maps it, for the late-alone path
  (R3). Opening and closing a `-shm` drops every POSIX lock the process
  holds on it, so the heads are skipped when another handle of the same set
  is open in the process. Such a handle keeps `-alive` held, which rules out
  the late-alone path anyway. Member ownership guarantees that no handle of
  another set has the file open.

## Running

```bash
cd prototypes/cwal
zig build                      # Debug, for torture
python3 torture.py --work /tmp/cwal-torture
zig build -Doptimize=ReleaseFast
./bench.sh /tmp/cwal-bench     # filesystem chosen by the directory
./workload.py --dir /tmp/cwal-wl   # realistic workloads, all modes
```

`zig-out/bin/cwal` commands: `seed`, `writer`, `reader`, `check`, `recover`,
`state` (prints the seqlock page), `bench`, `benchrw`, and for sets of 2 to
32 files (`--files N`) `nseed`, `nwriter`, `nwriters` (competing writer
threads), `nsem`, `nreader`, `ncheck`, and `nexec` (runs each stdin line as
SQL on one handle, `--role writer|reader`; `!commit`, `!rollback` and
`!autocommit <sql>` call the `Conn` methods; prints `ok` or `err <name>` per
line), and the workload commands `wseed` (a five-file Zova-like set,
`--journal wal|delete`) and `wrun` (`--mode plain|journal|cwal --scenario
mixed|objects|vectors|graph --rate R --readers N --read-rate R --duration-s S
--report-s S`). `workload.py` seeds once per journal mode, calibrates each
mode's maximum writer rate, then runs every mode at `--fraction` (0.5) of the
slowest, or at `--rate`; `--report` prints interval lines for long runs.
Fault injection is
controlled by environment: `CWAL_CRASH_AT=n` (SIGKILL at event n),
`CWAL_CRASH_TAG=t[,t...]` (count only events with these tags), `CWAL_POWERLOSS=1` +
`CWAL_SEED`, `CWAL_TRACE=1`, and `CWAL_MUTATE=…[,…]` (test-only defects, to show
the tests catch them; see the mutation table). `CWAL_WINDOW_DELAY_US`,
`CWAL_CKPT_OPEN_DELAY_US`, `CWAL_CKPT_SCAN_DELAY_US` and
`CWAL_ALIVE_DELAY_US` widen races for tests, and
`CWAL_DELAY_POINTS=name=us[,...]` pauses at named checkpoint-counter points
(`ckpt-pre-inc`, `ckpt-locked`, `ckpt-pre-dec`, `ckpt-post-dec`,
`open-take`, `open-release`, `reset-held`), which are also fault events.
`CWAL_PAUSE_AT=open-shared` with `CWAL_PAUSE_FILE=path` stops a shared open
after it has read the wal-index heads and before SQLite maps them: it
creates `path.reached` and waits for `path.go`. Two crash probes, selected
only by `CWAL_CRASH_TAG` and not counted as events, kill a writer at a WAL
sync inside a cross-file commit: `commit-sync-first` (window not open,
nothing published) and `commit-sync-next` (window open, earlier members
published). `nexec` takes `--ready 1` (print `ready` once open), `--hold
DIR --hold-files N` (first open another set in the same process), and
replaces `$txn` in statements with the next marker number. `nown` runs the
ownership race.
`CWAL_DEBUG=1` appends each handle's open, recovery, discard and commit
decisions to `main.db-cwal-debug`. I/O errors are injected with
`CWAL_FAIL_TAG=t[,t...]` and `CWAL_FAIL_AT=n` (the nth matching operation
fails); `CWAL_FAIL_STICKY=1` fails every later one too, and
`CWAL_FAIL_KIND=full` returns `SQLITE_FULL` (ENOSPC) for writes instead of
`SQLITE_IOERR_WRITE` (EIO). Tags: `write-wal`, `write-db`, `sync-wal`,
`sync-db`, `truncate`, `read-wal`, `read-db`, `open-wal`, `open-db`, and the
protocol's own `recover-truncate`, `recover-fsync`, `discard-truncate`,
`discard-fsync`. `CWAL_PL_LOG=path` appends a line per power loss saying what
the model dropped, tore, revived or undid. `nwriter --tolerate 1` keeps going
after a failed commit (printing `fail k txn`) and stops after 5 failures in a
row; `ncheck --failed-file` accepts those keys as absent, and `nreader
--allow-gaps 1` checks atomicity but not the prefix property. `bench.sh` and `torture.py` take
`CWAL_BIN` to run another build (for example an aarch64 binary under qemu).
`torture.py --split-dirs DIR...` places members of each N-file set in these
directories as well, through symlinks from the set directory (member 1 in
the first, and so on, round-robin with the set directory). `sudo
./fs-setup.sh` mounts 3 GB loop-backed ext4, XFS and NTFS (`ntfs3`) images
under `~/.cache/cwal-fs/mnt`, owned by the calling user; `--down` unmounts
them.

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
| Power loss | As above, but writes not yet fsynced are kept in memory; at the crash each is dropped, persisted, torn to a prefix, or scattered (each 512-byte sector kept or not), so unsynced writes can be lost, reordered or torn (3 seeds). Metadata is volatile too: a new file's directory entry until its directory is synced, a deletion likewise, and a truncation until the file is synced. A failed fsync persists some pending writes and keeps the rest visible only to the failing process (Linux after a writeback error). Also during recovery. |
| Concurrent snapshots | One writer process and two reader processes with two threads each. Readers pause between pinning members, attempt `PASSIVE` checkpoints, and close/reopen read-write connections (close-time checkpoints). Besides the pair and bulk counts, a reader also requires the single-file commits to be in order (`solo_s` equals `solo` or is one behind). The writer's window is widened by 300 µs, and the test runs twice: with all checkpoint modes (`RESTART`/`TRUNCATE` wait for readers, so the writer commits little while readers run) and with `PASSIVE` only. |
| Surviving readers | Kill the writer at a random fsync or at the phase-two notification (inside the window) while reader processes keep running; restart a writer while they run; check afterwards. Half the trials use `PASSIVE` checkpoints only. |
| Checkpoint race | The writer pauses 3 ms inside each `PASSIVE` checkpoint, after choosing how far to copy and before recording it; one reader thread pauses 1 ms inside each skipped checkpoint lock and stays in each read 5 ms. Every read checks that no checkpoint recorded an intent to copy past its snapshot (`nBackfillAttempted` ≤ the snapshot's `mxFrame`). |
| Checkpoint counter reset | Kill the writer right after it is granted its 1st…5th checkpoint lock, so the counter stays raised. Start a reader, then a new writer (window widened, `PASSIVE` checkpoints); after it closes the active count must be 0, and the set must check. |
| Close-time checkpoint | One reader connection stays open while the writer is killed at each of its first 40 fsyncs; the reader then closes as the last connection, which makes SQLite try to checkpoint. |
| Mutations | Rerun with each protocol piece disabled. |

N-file tests (`--files`, default 2 3 4 8 16 32) use one table `t(k, txn,
mask, n, v)` per file. Odd rounds are single-file autocommits on a random
file; even rounds are a transaction over a random subset of 2 or more files,
each row recording the subset (`mask`) and the marker number (`txn`); every
10th round is a checkpoint. The N-file checker requires `integrity_check`,
that each `k` is in exactly the files of its mask with the same `txn`, that
the `k` values form a prefix, that no two transactions share a number, that
each file's marker equals its newest cross-file row, and that every
acknowledged `(k, txn)` survived.

| Test | What it does |
| --- | --- |
| N-file process crash | SIGKILL the writer at every commit-boundary event of every participating file (WAL write, fsync, wal-index barrier, commit hook, gate, phase two), capped at 3,000 sampled points; also crash recovery itself for 8 torn states at 3, 8 and 32 files. |
| N-file power loss | As above with the power-loss model, 3 seeds, at 3, 8 and 32 files. |
| Writer restart chain | 15 writers in a row on one set, 80% killed at a random event, with readers kept running and restarted; every 5th writer opens alone. Random working sets, `PASSIVE` checkpoints. Requires unique attempted marker numbers across the whole chain (writer restarts included) and 0 mixed reads. 4 seeds per file count. |
| Unpublished frames | A reader keeps the set open (and sleeps 20 ms between finding the writer alive and mapping, `CWAL_ALIVE_DELAY_US`); the writer is killed at each of its first 60 fsyncs; a second writer runs 6 rounds without ever touching file x, for each x; then check. |
| Delay points (T2) | Deterministic, 3 files, a reader holding the set. `no-cross-flag`: the writer is killed at `commit-sync-next`; a new writer must exit `Broken`, readers must read nothing mixed, and recovery after the holder closes must roll back. `no-late-alone`: the writer is killed at `commit-sync-first`; an opener pauses at `open-shared` while the holder is killed, and must take the late-alone path and read nothing mixed. R3: as `no-cross-flag`, then an ordinary connection checkpoints main and the seqlock page is deleted; the paused opener must refuse (`ProtocolViolation`) with every WAL unchanged, also with a handle on another set in its process. |
| Member ownership (T3) | Set A (3 files), set B (2 files) whose `s1.db` is a symlink to A's `s2.db`, and A's main with 2 members. Each overlapping open must fail with `MemberOwned` while the other set is held, in another process and in the same process, in both roles; the same set must open twice in one process and from two processes; a killed owner must release ownership; a set listing a file twice must be refused. Races: 2 processes × 2 threads open and close two overlapping sets at random for 2 s; the held intervals of the two sets must never overlap. |
| N-file live readers | A writer (window widened 200 µs) and 2 reader processes × 2 threads, all and `PASSIVE` checkpoints. |

Transaction-semantics workload (`nsem`, torture sections `nsem` and
`nsemcrash`). One writer connection (`foreign_keys=on`, a 10-page cache)
cycles through 15 scenarios on the same `t` tables, and every 16th round
checkpoints. Each file also has an `audit` table filled by an ordinary
per-file trigger on `t`, so every commit includes trigger writes. One
cross-file DDL transaction creates the triggers and tables.

| Scenario | What it does and what it requires |
| --- | --- |
| `explicit` | `BEGIN`, inserts into 2 or more files, `COMMIT`. |
| `solo` | Single-file autocommit (an implicit transaction). |
| `trigger` | A TEMP trigger writes to a random subset of files; the statement runs through `Conn.autocommit`. |
| `trigger-direct` | The same statement issued as a plain autocommit: CWAL must refuse it (`SQLITE_CONSTRAINT_COMMITHOOK`) and leave no rows. |
| `savepoint` | Nested savepoints; `ROLLBACK TO` the inner one (its rows must be gone, the outer ones kept), sometimes also the outer one, then more writes and commit. |
| `savepoint-outer` | `SAVEPOINT` as the outermost transaction, written to 2 or more files: CWAL refuses the `RELEASE` that would commit it without markers; it is then redone with markers. |
| `constraint` | A primary-key violation inside a cross-file transaction, including a failed statement on a file the transaction had not written yet; the transaction continues and commits. |
| `or-rollback` | `INSERT OR ROLLBACK` conflict: the whole cross-file transaction is gone. |
| `raise-abort` | The TEMP trigger raises `ABORT` after its writes: the statement is undone, the transaction continues and commits. |
| `raise-rollback` | The TEMP trigger raises `ROLLBACK`: nothing remains in any file. |
| `deferred-fk` | A deferred foreign key fails at `COMMIT`: the transaction stays open, is fixed, and commits. |
| `busy` | Another connection holds a write lock on one file: `SQLITE_BUSY` with the transaction still open, then a retry or rollback. |
| `spill` | 30–50 KB rows in several files, more than the page cache, so SQLite writes uncommitted frames to the WALs before the commit. |
| `immediate` | `BEGIN IMMEDIATE` locks every file; the commit covers all of them. |
| `prepared` | Cached prepared inserts, and a `SELECT` stepped partway before the commit and finished after it. |

Before each checkpoint the writer makes a commit that writes only TEMP
tables, and the checkpoint must not be refused. `ncheck` also requires
every file's `audit` keys to equal its `t` keys, and the `audit` table in
all files or none. In the `nsem` section, readers hold each read
transaction 2 ms and read it again, and both reads must be the same.

| Test | What it does |
| --- | --- |
| nsem with long-lived readers | `nsem` (320 rounds, 3 ms apart, window widened 300 µs) with 2 reader processes × 2 threads; 2 seeds per file count. |
| nsem process crash | The N-file crash matrix with `nsem` (32 rounds: every scenario twice) as the writer, at 2, 3, 8 and 32 files (32 sampled to 3,000); crash recovery itself for 8 torn states at 8 files. |
| nsem power loss | As above with the power-loss model, 3 seeds, at 3 and 8 files (sampled to 3,000). |

Concurrency tests (torture sections `scale`, `writers`, `longsnap`,
`ckptpoints`, `ckptkill`). The writer runs without delay unless stated, and
the harness reads every process's output as it arrives and timestamps each
acknowledged commit, so it measures the writer's commit rate and its longest
gap between commits. Every run ends with `ncheck`; the writer is stopped by
`SIGKILL`.

| Test | What it does |
| --- | --- |
| Reader scaling | 1, 4, 8, 16 and 32 readers (processes × threads: 1×1, 2×2, 2×4, 4×4, 4×8) for 2 s against a writer committing as fast as it can, at 3, 8 and 32 files, with `PASSIVE` or all checkpoint modes. Records reads by the slowest thread (reader starvation), commits per second and the longest gap between commits (writer starvation), and the peak WAL size. |
| Competing writers | `nwriters` processes × threads (1×8, 4×1, 4×4) for 3 s, each thread repeatedly opening a writer handle, running 1–12 rounds and closing; `WriterBusy` and `Broken` are retried after 0.1–1 ms. 2×2 readers run throughout. Two of three seeds `SIGKILL` one writer process at a random time and start a replacement. At 2, 3, 8 and 32 files. |
| Long-lived snapshot | One reader holds each snapshot 1.5 s while 1×2 other readers and a saturating writer run for 3 s, at 3 and 32 files, both checkpoint settings. |
| Checkpoint-counter pauses | A 3 ms pause at each point around the counter's increment, decrement and reset, and 1 ms at a snapshot open's take and release; the writer checkpoints (`PASSIVE`, scan widened 3 ms) and one reader holds each read 5 ms and checks `nBackfillAttempted` as in the checkpoint race test. `reset-held` uses a chain of writers so the reset runs repeatedly. At 2 and 8 files. |
| Checkpoint-counter kills | Kill the writer at the 1st, 2nd and 5th time it reaches each counter point, at the reset, and at six wal-index barriers. Then a new writer opens (pausing while it holds every checkpoint lock) while readers are either already running or start 5 ms before it. Requires the active count to be 0 after that writer, and `ncheck`. At 2 and 8 files. |

Crash-recovery and durability tests (torture sections `ioerr`,
`ioerrreaders`, `permissions`, `allevents`, `recchain`, `readerkill`). A
failed commit's outcome is unknown to the application, so the checks accept
it present or absent, but never torn, and every acknowledged commit must
survive.

| Test | What it does |
| --- | --- |
| Injected I/O errors | The writer (power-loss model on, `--tolerate`, 40 rounds) meets one error, or a sticky one: ENOSPC or EIO on a WAL write, ENOSPC on a database write (checkpoint), EIO on a WAL or database fsync, a truncate, a WAL or database read, or a WAL open. 12 failure points spread over each case's operations, each run either ending normally or crashing at a random commit-boundary event. Then `ncheck` (recovering the set), a fault-free writer that must commit 10 rounds, and `ncheck` again. At 2, 3 and 8 files, plus a plain-WAL baseline at 3. |
| I/O errors with readers | WAL write, WAL fsync (EIO, ENOSPC sticky) and database fsync errors at the 5th, 20th and 60th operation while 2 reader processes × 2 threads read (no power loss: the model is single-process). At 3 and 8 files. |
| Permission errors | One file made read-only (a member database, a WAL, the wal-index, each lock file; the directory 0555) on a clean set and on one left torn by a crash; a writer and a reader then run. Each must work or fail with an error, without a crash or a mixed read; after the mode is restored, `ncheck` with every acknowledged commit. At 3 files. |
| Crash at every event | The N-file crash matrix over every fault event of any kind (opens, lock files, WAL creation and deletion at close, checkpoints, closes), not only commit boundaries; process crash and power loss (3 seeds), sampled to 4,000 at 8 and 32 files. A metadata matrix crashes at every file creation, deletion, truncation and fsync of a 30-round run (round 29 is a `TRUNCATE` checkpoint), under power loss. |
| Recovery chains | From 10 torn states per mode at 3 and 8 files, run recovery 5 times in a row, each crashed at a random recovery event (half with power loss), then check. |
| Reader kills | A writer (`PASSIVE` checkpoints) and 2 × 2 surviving readers run 2.5 s while 6 victim readers die: 3 crash at a random event of their own (snapshot opens, counter steps, wal-index rebuilds), 3 are `SIGKILL`ed at random times. Survivors must see no mixed state, the writer must keep committing, and the next writer must clear any checkpoint count the victims left. At 2, 3, 8 and 32 files, 3 seeds. |

Filesystem tests run torture sections on real filesystems with real fsyncs
instead of tmpfs. The power-loss model is the same VFS model on every
filesystem; no filesystem is cut off from power.

| Test | What it does |
| --- | --- |
| Filesystem profile | `--files 3 8 --powerloss-seeds 1 --ncap 600 --restart-seeds 2`, sections `crash`, `recovery`, `nfiles`, `nrestart`, `ndangle`, `nreaders`, `nsem`, `writers`, `ckptkill`, `permissions`, `readerkill`. On btrfs (the root filesystem), ext4 and XFS. |
| Short profile | `--files 3 --powerloss-seeds 1 --ncap 200`, sections `nfiles`, `nreaders`, `permissions`, `readerkill`. On NTFS, and on split sets. |
| Split sets (several filesystems) | The set directory and `main.db` on btrfs, member 1 on tmpfs, member 2 on ext4 (`--split-dirs`), so one commit spans three filesystems with their own WALs, fsyncs and directory entries. |

Enforcement tests (`--only enforce`, 3 files) use Python's `sqlite3` module
(the system SQLite) as the connection outside the protocol.

| Test | What it does |
| --- | --- |
| Bypass statements | 24 statements per role (writer, reader) on a CWAL handle through `nexec`: marker writes, drops, alters and triggers; cross-file commits through `COMMIT`, `END`, `RELEASE` and a TEMP trigger; journal, locking, sync and writable-schema pragmas; `ATTACH`, `DETACH`, `VACUUM`; and 3 allowed controls (`Conn.commit`, a checkpoint, reading pragmas). Each bypass must fail, and a writer must then open the set and `ncheck` must pass. |
| Ordinary connections, live | An ordinary connection loops over the members (reads, `PASSIVE` or `TRUNCATE` checkpoints, or single-file writes) while a CWAL writer commits 200 rounds. |
| Crashed sets | A writer is killed at each of its first 48 WAL writes (21 leave a torn set). Then an outsider acts: an ordinary connection opens a member (and checkpoints on close), checkpoints every member with `TRUNCATE`, writes one member, or checkpoints every member (`PASSIVE`, `FULL`, `RESTART`) and dies without closing, or checkpoints `s1.db`, writes it and dies (also with the old WAL bytes put back: died before writing the new WAL header); or `-cwal-snap` or a member's `-shm` is deleted, or the snapshot page overwritten. A silent tear fails, and so do a refused open where CWAL alone needs no rollback and a refused open that changed a WAL file. |
| Journal modes | A member left in `DELETE` mode, then opened; a member held open in `DELETE` mode by an ordinary connection while CWAL opens; an ordinary connection switching a member to `DELETE` while a CWAL reader has the set open. |
| Lost metadata | Each lock file deleted from a closed set; a marker row changed, or the marker table dropped, by an ordinary connection. |

## Results

Linux 7.2, x86_64, 8 CPUs, SQLite 3.53.4 (vendored, built with
`SQLITE_ENABLE_SNAPSHOT`), Zig 0.17.0. Measured on 2026-11-25.

### Correctness

| Test | Plain WAL (baseline) | CWAL |
| --- | --- | --- |
| Process crash at every writer event | 135 / 1,338 torn | **0 / 1,651**; 151 recoveries rolled back a torn transaction |
| Crash during recovery, once and twice (40 torn states) | — | **0 / 8,000** |
| Power loss at every writer event, 3 seeds | 405 / 4,014 torn | **0 / 4,953**; 453 rolled back |
| Power loss during recovery (20 torn states, 3 seeds) | — | **0 / 12,000** |
| Concurrent snapshots, 2 processes × 2 threads, both checkpoint workloads | 76 mixed reads | **0 mixed** / 1,586; 203 snapshot reads; 60/60 reader checkpoints denied |
| Writer killed, readers survive (20 trials) | 85,221 mixed reads, 5 torn sets | **0 mixed** / 335,095; 2,463 snapshot reads; 51 `Broken` reopens; 0 torn |
| Checkpoint race (widened) | — | 26 checkpoints started during a snapshot open; each read retried; **0** violated its snapshot |
| Checkpoint counter reset (5 crash points) | — | active count 1 after each crash, **0** after the next writer; 0–1 real-lock fallbacks per run |
| Last reader closes after writer killed at each of 40 fsyncs | 8 / 40 torn | **0 / 40** |

Mutations. Each test-only defect is caught:

| Mutation | Caught by |
| --- | --- |
| `no-markers` (cross-file commits write no markers) | 135 / 1,601 torn sets in the crash matrix |
| `no-marker-rollback` (recovery detects a torn transaction but keeps it) | 151 / 1,651 torn sets under power loss (1 seed) |
| `no-cross-flag` (a new writer closes a dead writer's cross-file window without recovery) | 72,495 mixed reads and 4 torn sets in the survivor test (only when a kill lands in a cross-file window); always in the delay-point test: the new writer opens, 1,228 mixed reads, a torn set |
| `no-gate` (no publication window) | 90 mixed reads |
| `no-seq-check` (accept a read without rechecking the sequence) | 35 mixed reads |
| `no-snapshot-open` (inside a window, pin current state instead of the saved headers) | 110 mixed reads |
| `no-solo-window` (no window for single-file commits) | 18 mixed reads (out-of-order solo commits) |
| `no-lock-gate` (close-time checkpoints allowed) | 10 / 40 sets refused by recovery (`ProtocolViolation`: a torn transaction reached a database file) in the close test |
| `no-ckpt-gate` (`WAL_CKPT_LOCK` not gated) | 2 / 40 sets refused by recovery in the close test |
| `no-ckpt-validate` (accept a skipped checkpoint lock without checking the counter) | 37 violations in 37 races |
| `no-ckpt-reset` (a writer does not clear a dead checkpointer) | active count stays 1; every snapshot open takes the real lock (2 fallbacks per snapshot read) |
| `no-discard-unpublished` (a writer keeps a dead writer's frames past `mxFrame`) | unpublished-frames test: 3 / 153 torn at 3 files, 7 / 480 at 8 files; 5,808 mixed reads |
| `no-late-alone` (no second `-alive` test after mapping) | unpublished-frames test: 13 / 153 torn at 3 files, 10,445 mixed reads (0 at 8 files), only when the race lines up; always in the delay-point test: 100 mixed reads, and the R3 opener serves the set |
| `no-early-heads` (the late-alone path reads the wal-index heads after mapping) | delay-point R3 cases: the opener truncates `main.db-wal` although the torn commit is in `main.db` |
| `heads-process-wide` (the pre-T2 condition: heads only when no other handle is in the process) | delay-point R3 case with a handle on another set in the opener's process: the same truncation |
| `no-ownership` (no member ownership) | ownership: all 10 refusal cases open; the two races show 369 and 50 overlapping intervals |
| `no-open-gate` (opens and closes do not take `-gate`) | unpublished-frames test: 4 / 153 torn at 3 files, 2,984 mixed reads (0 at 8 files) |
| `no-txn-epoch` (marker numbers continue from the newest published one) | restart chains: all 8 chains (3 and 8 files) reuse 2–6 marker numbers |
| `no-authorizer` (no authorizer) | enforcement: 20 bypass statements succeed (writer: marker writes, pragmas, `ATTACH`/`DETACH`; reader: pragmas, `ATTACH`/`DETACH`) |
| `no-authorizer,no-frame-guard` | the same, and `VACUUM` succeeds in both roles (22) |
| `no-frame-guard` (commit frames accepted outside a commit) | enforcement: `VACUUM` succeeds in both roles once the handle's authorizer is removed (as an application installing its own would) |
| `no-backfill-check` (recovery ignores foreign checkpoints) | enforcement: 5 / 48 crashed sets silently torn after an ordinary checkpoint that died, 13 / 48 after one that also wrote |

`no-ckpt-skip` (always take the real checkpoint lock) is a control: 0
violations. `REVIEW.md` has the section 8 review, model check and
build-mode runs.

### N-file atomicity

Same machine, 2026-11-25, tmpfs, Debug build.

| Test | Files | Plain WAL (baseline) | CWAL |
| --- | --- | --- | --- |
| Process crash at every commit-boundary event | 2 / 3 / 4 / 8 / 16 / 32 | 40, 67, 74, 175, 407, 729 torn | **0** / 347, 409, 451, 731, 1,355, 2,367; 66–1,008 rollbacks per count |
| Crash during recovery, 8 torn states | 3 / 8 / 32 | — | **0** / 2,372, 6,256, 24,676 |
| Power loss, 3 seeds (32 files sampled to 3,000) | 3 / 8 / 32 | 201, 525, 1,457 torn | **0** / 1,227, 2,193, 3,000 |
| Writer restart chains, 4 × 15 writers | 2 … 32 | — | **0 mixed** / 181,561 reads; 278 writers killed; 2,457 acked commits all present; no marker number reused |
| Unpublished frames, next writer skips a file | 2 / 3 / 4 / 8 / 16 / 32 | — | **0** / 80, 153, 232, 480, 960, 1,920; 0 mixed reads |
| Live readers, 2 × 2 threads | 2 … 32 | 3 and 8 files: 26–264 mixed reads | **0 mixed**, 0 checkpoint violations |

With 32 files, `PASSIVE` checkpoints and the widened window, readers
completed only 4 reads in the test's time (751 sequence retries, 290 waits
for a window): a read pins 32 members, which rarely fits between windows.
That is a liveness cost under a saturating writer, not a correctness
failure.

### Transaction semantics

Same machine, 2026-11-25, tmpfs, Debug build.

| Test | Files | Plain WAL (baseline) | CWAL |
| --- | --- | --- | --- |
| nsem with long-lived readers, 2 seeds | 2 / 3 / 4 / 8 / 16 / 32 | 97, 115, 172, 166, 183, 103 mixed reads | **0 mixed** / 2,364, 2,022, 1,826, 1,313, 951, 528 reads; every scenario ran 20 times per run; all acked commits present |
| nsem process crash | 2 / 3 / 8 / 32 | 228, 344, 739, 1,663 torn | **0** / 1,056, 1,259, 2,136, 3,000; 286–1,526 rollbacks per count |
| Crash during recovery, 8 torn states | 8 | — | **0** / 6,228 |
| nsem power loss, 3 seeds | 3 / 8 | 1,032, 1,352 torn | **0** / 3,000, 3,000 |

SQLite behavior found while writing these tests:

- A refused `RELEASE` of an outermost savepoint rolls the data back, but
  SQLite then leaves the connection in an empty open transaction
  (`OP_Savepoint` sets `autoCommit = 0` after the failed commit). The
  caller must `ROLLBACK`.
- A deferred foreign-key failure at `COMMIT` leaves the transaction open,
  and the commit hook is not called.
- `RAISE(ABORT)` and `RAISE(ROLLBACK)` return the base
  `SQLITE_CONSTRAINT`, not an extended code.
- A TEMP trigger can write any attached schema; a non-TEMP trigger only
  its own.
- A commit that writes only TEMP tables calls the commit hook, but no
  member reaches phase two or the rollback hook. The prototype left
  `in_commit` set and refused the writer's checkpoints until its next
  member commit. Fixed: the commit hook ends a commit that write-locked no
  member.

No mutation was run against `nsem`: with `no-markers` its own checks (the
marker number of each commit, the refused autocommit) fail on every run.
The plain-WAL baseline shows that the checker detects torn commits in this
workload.

### Concurrency

Same machine, 2026-11-25, tmpfs, Debug build. All runs below passed `ncheck`
with 0 mixed reads and 0 checkpoint violations for CWAL; the plain-WAL
baseline had mixed reads in every `PASSIVE` run, and 5 of its runs failed
`ncheck` with a torn transaction when the writer was killed at the end.

Reader scaling, CWAL (plain WAL in parentheses), 2 s each:

| Files | Checkpoints | Readers | Commits/s | Longest writer gap | Reads by slowest thread | Peak WAL |
| --- | --- | --- | --- | --- | --- | --- |
| 3 | `PASSIVE` | 1 / 32 | 7,651 / 1,813 (10,488 / 2,349) | 2 / 20 ms | 46 / 10 (33 / 12) | 195 / 46 MB |
| 8 | `PASSIVE` | 1 / 32 | 4,834 / 1,084 (6,670 / 2,009) | 2 / 15 ms | 45 / 13 (37 / 10) | 114 / 51 MB |
| 32 | `PASSIVE` | 1 / 32 | 1,593 / 508 (2,232 / 411) | 5 / 21 ms | 49 / 4 (37 / 12) | 185 / 78 MB |
| 3 / 8 / 32 | all | 1–32 | 12–141 (18–380) | 0.2–2.0 s (0.1–2.0 s) | 23–339 (34–275) | under 2 MB |

- No reader starved: at 32 readers every thread completed reads in every
  configuration. Reads get slower as the WAL grows under `PASSIVE`
  checkpoints, in both modes.
- With all checkpoint modes, the writer waits up to the busy timeout in
  each `RESTART`/`TRUNCATE` checkpoint while readers keep the WAL in use, so
  writer gaps of about 2 s (the length of the run) occur in both modes.
- With `PASSIVE` checkpoints the writer never waits more than 21 ms, but
  the WAL reached 46–227 MB in 2 s.

| Test | Files | Result |
| --- | --- | --- |
| Competing writers, 36 runs | 2 / 3 / 8 / 32 | **0 mixed**, all acked commits present; 31–637 writer opens and 470–4,171 commits per run; 3,249–39,968 `WriterBusy` retries. One 4×4 kill run saw 245 `Broken` opens and 11 broken reader opens while the killed writer's commit awaited recovery. |
| Long-lived snapshot (1.5 s) | 3 / 32 | **0 mixed** in the held and the other readers. `PASSIVE`: writer gap 10–13 ms, WAL 309 and 357 MB after 3 s (plain 226 and 286 MB). All modes: writer gap 1.5–3.0 s in both modes. |
| Checkpoint-counter pauses, 14 runs | 2 / 8 | **0 violations**, 0 mixed; 0–218 checkpoint races and 0–735 fallbacks to the real lock per run; active count 0 afterwards. |
| Checkpoint-counter kills, 76 runs | 2 / 8 | **0 mixed**, all checks pass. 26 kills left the active count raised (inside the lock); the next writer cleared it in all 76. |
| aarch64 build under qemu: reader scaling, competing writers, counter pauses and kills | 3 (2 for the counter tests) | **0 mixed**, 0 violations, all checks pass in 10 CWAL scaling runs, 9 writer runs, 7 pause runs and 38 kill runs. qemu runs on the x86_64 host's memory ordering, so this checks the build and logic, not ARM ordering. |

Findings:

- The counter reset never waited for a live checkpointer (`reset_waits=0`
  in all 76 kill runs). Before the reset, the opening writer discards
  unpublished frames while holding every member's WAL write lock. The only
  other exclusive checkpoint-lock holder is wal-index recovery, which needs
  the same write lock, and the first opener's recovery runs under the open
  gate. So a reset concurrent with a counted checkpointer was not
  produced; the kill test covers the nearest case (a reader's wal-index
  recovery in progress when the writer died).
- The first version of these tests read the writer's output only at the
  end. The writer filled the 64 KB pipe and blocked, which looked like
  writer starvation. The harness now reads output as it arrives. Earlier
  live-reader tests (sections above) still read at the end; their writers
  are throttled by a per-round delay, but may still pause once about 5,000
  commits are buffered.

### Crash recovery and durability

Same machine, 2026-11-25, tmpfs, ReleaseSafe build. **No CWAL failure.**
A failed commit's rows were present or absent, never torn, and no
acknowledged commit was lost.
The complete suite (sections 1–4, `python3 torture.py --jobs 8`) then
passed in 63 minutes.

| Test | Files | Plain WAL | CWAL |
| --- | --- | --- | --- |
| Injected I/O errors (13 cases × 12 points × clean or crash) | 2 / 3 / 8 | 67 / 294 failed at 3 files (torn transactions in 10 of 13 cases) | **0** / 276, 300, 312; the broken flag set in 49, 63, 89 runs, recovery rolled back 46, 69, 122 |
| I/O errors with 2 × 2 readers, 24 runs | 3 / 8 | — | **0 mixed**, all checks pass; in 11 runs readers got `error.Broken` (7–10 times each) instead of a view |
| Permission errors, 16 cases | 3 | — | **0** crashes, 0 mixed; every check passed once the mode was restored |
| Crash at every event (process crash / power loss, 3 seeds) | 3 | — | **0** / 954 and 2,862 |
| | 8 | — | **0** / 1,884 and 4,000 (sampled) |
| | 32 | — | **0** / 4,000 and 4,000 (sampled from 6,502 events) |
| Power loss at every metadata event, 3 seeds | 3 / 8 | — | **0** / 291, 591 |
| Recovery chains, 5 crashes each | 3 / 8 | — | **0** / 60, 60 |
| Reader kills, 6 victims per run | 2 / 3 / 8 / 32 | — | **0 mixed**, all checks pass in 12 runs; longest writer gap 4–10 ms |

What the runs exercised:

- **Rollback after a member published.** A WAL write or fsync error on a
  later member of a cross-file commit, after an earlier member published,
  set the broken flag in 201 of the 888 CWAL I/O-error runs. Later commits
  were refused, readers got `error.Broken`, and the next alone opener rolled
  the transaction back. Before section 4 no test reached this path.
- **Power-loss model.** Over the all-event and metadata matrices: 11,744
  power losses, 4,574 unsynced writes dropped, persisted, torn or scattered
  (911 scattered), 14,581 directory entries of new files lost (WALs and lock
  files), 825 deleted WALs brought back, and 257 truncations undone. In the
  CWAL I/O-error runs, failed fsyncs left 9 writes visible only to the
  failing process when it crashed.
- **Errors the writer cannot continue after.** A failed read of a member
  database or a failed WAL open usually fails the writer's open
  (`writer-open-error`, or the test driver's first query); the set checks
  afterwards. A read-only database, WAL or lock file, or a read-only
  directory before the WALs exist, fails the open with an error; a read-only
  `-shm` or directory after the WALs exist does not stop a writer.
- **Readers.** The checkpoint count was left raised after 1 of the 12
  reader-kill runs (by a victim, or by the writer stopped at the end); the
  next writer cleared it.

The plain-WAL baseline tore transactions in 10 of its 13 error cases,
including ENOSPC during a checkpoint and a failed database fsync, which
show the oracle catches a partial multi-file commit.

### Filesystems

Same machine, 2026-11-26, ReleaseSafe build, one SATA SSD. ext4, XFS and
NTFS are loop images stored on the btrfs root filesystem. **No CWAL
failure.**

| Filesystem | Profile | Time | CWAL crash, power-loss and recovery runs | Other CWAL checks | Plain WAL |
| --- | --- | --- | --- | --- | --- |
| btrfs | full | 36 min | **0** / 21,324 | **0** / 86 | 619 / 2,754 torn |
| ext4 | full | 26 min | **0** / 21,324 | **0** / 86 | 619 / 2,754 torn |
| XFS | full | 28 min | **0** / 21,324 | **0** / 86 | 619 / 2,754 torn |
| NTFS (`ntfs3`) | short | 2 min | **0** / 2,924 | **0** / 21 | 107 / 400 torn |
| btrfs + tmpfs + ext4 (split set) | short | 3.5 min | **0** / 2,924 | **0** / 21 | 107 / 400 torn |

"Other CWAL checks" are the reader, transaction-semantics, competing-writer,
checkpoint-counter, permission and reader-kill runs: 0 mixed reads, 0
checkpoint violations, and every `ncheck` passed.

- **Symlinked members (bug, fixed).** The first split-set run failed 102
  of 1,227 CWAL power-loss runs with `open ProtocolViolation`. SQLite
  resolves symlinks and keeps a database's `-wal` and `-shm` next to the
  real file, but CWAL built those names from the path the caller passed.
  Recovery could not open a symlinked member's WAL, and discarding
  unpublished frames skipped it without an error. `Conn.open` now resolves
  every path with the unix VFS's `xFullPathname`, as SQLite does; the same
  run then passed (0 / 409 crashes, 0 / 1,227 power losses, 309 of them
  rolled back).
- **Writer gaps.** The longest gap between commits while readers were
  killed was 59–118 ms on btrfs and XFS, 33–78 ms on NTFS, and up to 715 ms
  on ext4 and 762 ms on the split set. Not investigated; the gaps include
  fsyncs through a loop device onto btrfs.
- **32-bit targets.** The prototype does not build for 32-bit x86: the
  shared snapshot page uses 64-bit atomics (`seq`, `ckpt`), which Zig does
  not provide there. Zova's native packages are all 64-bit (x64 and arm64),
  so this was not pursued.

### Protocol enforcement

Same machine, 2026-11-26, tmpfs, ReleaseSafe build, 3 files. Before the
fixes, probes found these bypasses (all now refused):

- A writer handle could update or delete `cwal_marker`; the set then failed
  every open with `ProtocolViolation`. Dropping it lost the marker history.
- `PRAGMA synchronous=OFF`/`NORMAL` and `locking_mode=EXCLUSIVE` let
  cross-file commits succeed without a publication window (with no WAL
  fsync, the window never opened). `journal_mode=DELETE`/`MEMORY`/`OFF` made
  the set unopenable. `DETACH` made the next cross-file commit fail with an
  I/O error.
- `VACUUM` skips the commit hook, so a reader handle could write, and a
  writer's `VACUUM` published with no window.
- **Recovery could tear silently (bug, fixed).** When an ordinary
  connection checkpointed a torn member and died before deleting its WAL,
  recovery truncated frames that were already in the database file: 9 of 48
  crashed sets per checkpoint mode ended torn. Recovery now checks the
  wal-index first (see [Enforcement](#enforcement)).

| Test | Result |
| --- | --- |
| Bypass statements, writer and reader | **42 / 42** refused (`VACUUM` by the authorizer); 6 / 6 controls allowed; the set opened and checked after each |
| Ordinary connections while a writer commits (read, `PASSIVE`, `TRUNCATE`, write) | **4 / 4** pass; 63–75 ordinary operations each, all succeeded |
| Crashed sets, 15 outsiders × 48 crash points (21 torn) | **0** silent tears, **0** refusals of a set CWAL alone recovers, **0** refusals that changed a WAL file. Refused (`ProtocolViolation`) exactly when the outsider applied the torn commit: all 21 torn sets for each outsider that checkpoints every member, 16 and 13 for an ordinary open of `main.db` and `s1.db`, 0 for `s2.db` (no torn commit reached its WAL at these crash points), 13 for each outsider that checkpoints and writes `s1.db` (the two added in section 8; before the fix 13 and 5 of those were silent tears). Deleted `-shm`, `-cwal-snap` or a junk snapshot page: all 48 recover. |
| Member left in `DELETE` mode | switched back to WAL at open, 3 / 3 |
| Member held open in `DELETE` mode | open fails (`database is locked`); after release, opens and checks |
| Ordinary connection switches a member to `DELETE` under a CWAL reader | refused by SQLite (`database is locked`) |
| Lock files deleted from a closed set | recreated, 5 / 5 |
| Marker row changed or table dropped by an ordinary connection | 5 / 6 refused; the sixth (dropped in a member outside the newest cross-file transaction) opens and checks: that marker is not needed |

The short profile (`nfiles`, `nreaders`, `permissions`, `readerkill`) and the
checkpoint and recovery sections (`ckptkill`, `ckptpoints`, `ckptreset`,
`closeckpt`, `ndangle`, `recchain`, `nrestart`) at 3 files passed with the
changes: 0 failures in 200 crash, 200 power-loss and 2,524 recovery-crash
runs, 45 and 47 rollbacks.

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

### Realistic workloads

`workload.py`, ReleaseSafe, 10 s per run, each run from a fresh copy of a
seeded set. The set is laid out like Zova's stores, with Zova's table and index
definitions: relational `docs` rows in `main.db`, objects
(`_zova_objects`, `_zova_chunks`, `_zova_object_chunks`, chunks SHA-256
hashed) in `s1.db`, 384-dimension f32 vectors in `s2.db`, graph nodes and
edges in `s3.db`, `_zova_kv` in `s4.db`. Seeded with 2,000 documents (16 KiB
object, vector, node with 3 edges, metadata pair each) and four 16 MiB
objects, about 105 MB.

| Scenario | Writer transaction | Reader transaction |
| --- | --- | --- |
| mixed | 40% ingest a document into all five files (1 KiB row, 64 KiB object, vector, node + 3 edges, pair); 30% update a row + pair; 20% two edges + row touch; 10% one pair | 50% a document with its object, vector, node and pair; 10% exact top-10 vector search; 40% two-hop traversal |
| objects | a 16 MiB object in 1 MiB chunks, row and pair | stream a random 16 MiB object |
| vectors | 32 rows + 32 vectors | exact top-10 search over all vectors |
| graph | node + 4 edges, pair, row touch | two-hop traversal |

Modes: plain WAL (`Conn` plain mode), rollback journal (`journal_mode=DELETE`:
SQLite's super-journal makes multi-file commits atomic, but readers and the
writer block each other), and CWAL; `synchronous=FULL` in all three. The
writer and 2 readers run open-loop at fixed rates. Latency is measured from
each operation's scheduled time, so stalls are charged to the operations
queued behind them. The WAL modes run a PASSIVE checkpoint every 100 writer
operations, counted in that operation's latency. Journal-mode readers use a 5 ms busy timeout and retry.
Otherwise a reader holding `main.db` and a writer that has spilled to
`s1.db` would wait on each other until the 10 s timeout.

Writer rate is half the slowest mode's calibrated maximum. Write
amplification is bytes written by `write()` (and, on btrfs, the block
layer's `write_bytes`) over logical payload bytes, including the final
checkpoint that brings the WAL modes to the journal mode's end state.

btrfs / SSD (writer 8 ops/s, objects 1.3 ops/s; 80 or 13 writer
operations per run, so p99 is the maximum):

| Scenario | Mode | Max writer ops/s | Write p50 / p99 | Read p50 / p99 | Read retries | Write amp (disk) | fsyncs / op |
| --- | --- | --- | --- | --- | --- | --- | --- |
| mixed | plain | 44 | 56 / 166 ms | 0.45 / 79 ms | 0 | 5.3 (15.5) | 3.1 |
| mixed | journal | 16 | 63 / 228 ms | 33 / 273 ms | 1,569 | 7.0 (47.8) | 9.6 |
| mixed | CWAL | 50 | 44 / 98 ms | 0.46 / 77 ms | 0 | 5.8 (12.9) | 3.0 |
| objects | plain | 2.8 | 562 / 2,131 ms | 16 / 85 ms | 0 | 2.0 (2.1) | 3.7 |
| objects | journal | 2.6 | 407 / 448 ms | 32 / 382 ms | 1,242 | 1.0 (1.1) | 12 |
| objects | CWAL | 2.7 | 348 / 499 ms | 22 / 98 ms | 0 | 2.0 (2.0) | 3.8 |
| vectors | plain | 80 | 70 / 95 ms | 15 / 24 ms | 0 | 3.4 (6.2) | 2.1 |
| vectors | journal | 16 | 67 / 312 ms | 40 / 357 ms | 1,031 | 2.7 (14.7) | 7.0 |
| vectors | CWAL | 95 | 48 / 68 ms | 16 / 28 ms | 0 | 3.5 (6.1) | 2.1 |
| graph | plain | 62 | 45 / 57 ms | 0.37 / 0.57 ms | 0 | 562 (1,660) | 3.1 |
| graph | journal | 15 | 68 / 121 ms | 7.3 / 79 ms | 1,437 | 1,148 (6,102) | 10 |
| graph | CWAL | 57 | 68 / 85 ms | 0.36 / 0.66 ms | 0 | 636 (1,936) | 3.1 |

tmpfs (writer at half the journal mode's maximum: mixed 372, objects 2.6,
vectors 72, graph 666 ops/s):

| Scenario | Mode | Max writer ops/s | Write p50 / p99 | Read p50 / p99 | Read retries | Write amp | Peak WAL |
| --- | --- | --- | --- | --- | --- | --- | --- |
| mixed | plain | 2,024 | 0.38 / 9.0 ms | 0.37 / 14 ms | 0 | 5.0 | 44 MB |
| mixed | journal | 745 | 10 / 161 ms | 2.7 / 38 ms | 486 | 6.6 | — |
| mixed | CWAL | 1,896 | 0.46 / 9.8 ms | 0.35 / 15 ms | 0 | 5.5 | 68 MB |
| objects | plain | 5.2 | 229 / 237 ms | 11 / 35 ms | 0 | 2.0 | 423 MB |
| objects | journal | 5.5 | 216 / 220 ms | 25 / 166 ms | 922 | 1.0 | — |
| objects | CWAL | 5.1 | 229 / 237 ms | 12 / 39 ms | 0 | 2.0 | 424 MB |
| vectors | plain | 1,463 | 0.88 / 4.5 ms | 24 / 42 ms | 0 | 3.4 | 69 MB |
| vectors | journal | 144 | 61 / 1,694 ms (fell behind: 60 of 72 ops/s) | 46 / 365 ms | 833 | 2.7 | — |
| vectors | CWAL | 1,387 | 1.1 / 5.2 ms | 25 / 44 ms | 0 | 3.5 | 73 MB |
| graph | plain | 4,980 | 0.71 / 4.7 ms | 0.41 / 0.61 ms | 0 | 609 | 9.5 MB |
| graph | journal | 1,332 | 0.88 / 9.6 ms | 0.30 / 3.4 ms | 4 | 1,194 | — |
| graph | CWAL | 4,330 | 0.70 / 4.3 ms | 0.37 / 0.60 ms | 0 | 681 | 11 MB |

- On btrfs, CWAL's latency, CPU, RSS (73–84 MB in every mode) and fsyncs
  per operation match plain WAL's. Differences between the two are within
  the run-to-run variance. Four repeated graph runs gave plain p50s of 34–63 ms and
  CWAL p50s of 39–70 ms; paired, CWAL was 3–7 ms higher on graph.
- The rollback journal, the other way to get atomic multi-file commits, costs 3–4 times the
  fsyncs, a third of the maximum write rate, and blocks readers. On btrfs, readers wait 7–40 ms at p50 against under 1 ms with
  WAL, and they retried 1,000–1,600 times per run.
- Write amplification is about 10% higher with CWAL than plain WAL,
  from the marker frame per member per cross-file commit. It is highest for
  small graph transactions, where every commit writes whole pages in three
  files. The journal mode writes less with `write()` for new data (no WAL
  copy). On disk it writes 2–4 times more than either WAL mode, because each
  commit writes a journal and a super-journal and fsyncs every file.
- CWAL's peak WAL is up to 1.5 times plain's on tmpfs. The marker frames
  account for part of it; checkpoints waiting at the gate may account for
  the rest (not measured).
- Readers on tmpfs are as fast with CWAL as with plain WAL at these rates;
  the snapshot path's advantage shows only under heavier read load (see
  [Overhead](#overhead)).

#### Ten-minute runs

Mixed scenario, 10 minutes per run on btrfs, with 2, 8 and 16 readers at 50
reads/s each. The writer runs at 5.13 ops/s in every mode, half the journal
mode's maximum with 16 readers (plain 64.5, journal 10.3, CWAL 61.7 ops/s).
That gives 3,079 writer transactions per run and 30 checkpoint runs in each
WAL mode. Interval reports every 30 s. `wcheck` ran after every run: SQLite's
`integrity_check` and `foreign_key_check` on all five files, plus cross-file
invariants. Every document with an object must have that object, with
complete chunks, its vector and its pair. Every vector and pair must belong
to an existing document. Every object must be referenced by a row.

| Readers | Mode | Write p50 / p95 / p99 | Read p50 / p99 | Read retries | CPU s | RSS | Disk write amp | fsyncs / op | Peak WAL | Full checkpoints |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | plain | 54 / 83 / 136 ms | 0.50 / 18 ms | 0 | 120 | 86 MB | 12.6 | 3.3 | 12 MB | 29 / 30 |
| 2 | journal | 95 / 166 / 1,191 ms | 15 / 2,181 ms | 81,608 | 175 | 86 MB | 38.5 | 10.2 | — | — |
| 2 | CWAL | 54 / 83 / 145 ms | 0.53 / 18 ms | 0 | 122 | 86 MB | 13.1 | 3.3 | 26 MB | 23 / 30 |
| 8 | plain | 54 / 81 / 141 ms | 0.46 / 18 ms | 0 | 396 | 108 MB | 12.6 | 3.3 | 12 MB | 26 / 30 |
| 8 | journal | 98 / 174 / 1,359 ms | 20 / 2,919 ms | 336,513 | 539 | 112 MB | 38.0 | 10.2 | — | — |
| 8 | CWAL | 55 / 85 / 141 ms | 0.46 / 18 ms | 0 | 399 | 109 MB | 13.2 | 3.2 | 30 MB | 15 / 30 |
| 16 | plain | 52 / 81 / 133 ms | 0.36 / 17 ms | 0 | 630 | 136 MB | 12.6 | 3.3 | 12 MB | 28 / 30 |
| 16 | journal | 123 / 289 / 1,460 ms | 85 / 4,899 ms | 801,955 | 1,451 | 143 MB | 38.0 | 10.2 | — | — |
| 16 | CWAL | 52 / 83 / 149 ms | 0.35 / 16 ms | 0 | 627 | 136 MB | 13.1 | 3.2 | 30 MB | 16 / 30 |

"Full checkpoints" counts PASSIVE checkpoint runs that copied every frame
of every member.

- **Integrity:** all 9 runs passed `wcheck`, and every mode ended with the
  same row counts (3,244 documents, 10,864 edges, 3,555 pairs). The writer's
  random stream is seeded, so all modes apply the same transactions.
- **No progressive memory growth:** RSS stays within ±10 MB of one level
  per reader count, from the first interval to the last, in every mode.
- **No throughput degradation:** the writer completed all of its offered
  transactions (3,079 of 3,078 scheduled) at 5.13 ops/s in every interval.
  Write p99 per interval varies with btrfs (107–359 ms) but does not trend
  upward in either WAL mode.
- **Starvation:** WAL-mode readers completed all of their offered reads
  (30,000 each) and never fell behind, and no WAL-mode writer retried.
  - With 16 readers, the journal mode starved readers: they fell to 41
    reads/s in the worst interval, completed 29,934–29,993 of 30,000 reads,
    and their worst read took 7.2 s.
  - Journal readers spent their CPU retrying (2.3 times the WAL modes' CPU
    at 16 readers), and journal writes reached p99 1.2–1.5 s.
- **Write amplification and fsyncs:** CWAL matches plain within 4% on disk
  bytes (13.1–13.2 against 12.6) and fsyncs. The journal mode writes three
  times the disk bytes and issues three times the fsyncs.
- **WAL growth: the one difference between CWAL and plain WAL.** CWAL
  completes fewer checkpoints (50–77% against 87–97%), and its WAL file
  reaches 2–2.5 times plain's size. The file keeps its high-water size, and
  it grew in steps through the first six or so minutes of each run.
  - An accelerated run at 30 writer ops/s with 16 readers (18,001
    transactions, 180 checkpoint runs, 10 minutes) showed where it levels
    off. Plain's WAL levelled at 21 MB, CWAL's at 47 MB, flat for the last
    4 minutes. 82% of plain's checkpoint runs completed, against 37% of
    CWAL's.
  - Both sets passed `wcheck`, with the same latency, CPU and disk bytes.
  - Probable cause, not verified: a read that starts during a publication
    window opens snapshots at the headers saved before that commit, so it
    holds a read mark on older frames. A checkpoint then stops short of the
    WAL end, and the next write cannot restart the WAL from the beginning.
    The accelerated run had more snapshot reads and fewer full
    checkpoints, which is consistent with this.
  - The WAL is not unbounded in these runs, but a high-water mark can still
    step up rarely over a longer run. A production version should cap it:
    `journal_size_limit`, or a periodic RESTART or TRUNCATE checkpoint by
    the writer.

Shorter filesystem comparison: 2 minutes per mode, 8 readers, same writer
rate (616 transactions and 6 checkpoint runs per WAL run). The ext4 and
XFS images are loop-backed on the same SSD.

| Filesystem | Mode | Write p50 / p99 | Read p50 / p99 | Read retries | Disk write amp | fsyncs / op | Peak WAL | Full checkpoints |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ext4 | plain | 61 / 136 ms | 0.46 / 15 ms | 0 | 7.3 | 3.2 | 10 MB | 5 / 6 |
| ext4 | journal | 112 / 1,015 ms | 40 / 2,919 ms | 80,035 | 26.8 | 9.9 | — | — |
| ext4 | CWAL | 59 / 141 ms | 0.46 / 15 ms | 0 | 7.7 | 3.1 | 18 MB | 4 / 6 |
| XFS | plain | 60 / 373 ms | 0.46 / 15 ms | 0 | 5.6 | 3.2 | 10 MB | 6 / 6 |
| XFS | journal | 102 / 199 ms | 25 / 315 ms | 71,551 | 7.8 | 9.9 | — | — |
| XFS | CWAL | 59 / 136 ms | 0.46 / 15 ms | 0 | 6.1 | 3.1 | 20 MB | 3 / 6 |

The same picture holds on all three filesystems, and all 6 runs passed
`wcheck`. CWAL matches plain WAL; the journal mode blocks readers and costs
three times the fsyncs. CWAL's WAL is twice plain's here too.

- **Not run: long-duration endurance.** The 12–24 h sustained runs are
  reserved for the integrated Zova implementation. This prototype's
  longest runs are 10 minutes, so slow leaks, WAL high-water creep and
  fragmentation over hours or days are untested. `workload.py --duration
  … --report …` runs them when wanted. NTFS was not compared.

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
  SQLite connection to a member (CLI, backup tool) can read mixed states and
  checkpoint. If it checkpoints a torn commit, recovery refuses
  (`ProtocolViolation`) and the set needs manual repair. Not detected: a
  checkpointer that died before finishing (SQLite advances `nBackfill` only
  after the database fsync), or one whose `-shm` was then deleted (unless
  it also wrote: the WAL's last commit is then not the torn one).
- Recovery refuses whenever a foreign checkpoint reached past the truncation
  point, including when the kept frames happen to rewrite every page the
  torn commit wrote (then truncating would still be correct).
- Readers must start transactions with `beginRead`; a plain `BEGIN` gets no
  cross-file snapshot.
- Requires `synchronous=FULL` (or `EXTRA`) on every member; the publication
  window begins at the commit-time WAL fsync, which `NORMAL` does not issue.
  `NORMAL` would also not be power-safe across files.
- Cross-file writes must commit through `Conn.commit` or `Conn.autocommit`; a
  cross-file autocommit statement issued directly is refused by the commit
  hook, and so is a `RELEASE` that would commit a cross-file savepoint
  transaction (which then leaves an empty transaction open). Each member holds a `cwal_marker` table, which a production version
  would hide from the public API.
- The authorizer occupies `sqlite3_set_authorizer`; an application that
  installs its own replaces it. `VACUUM`, `ATTACH` and `DETACH` are
  unavailable on CWAL handles.
- After a writer crash in the middle of a cross-file commit, the set is
  unreadable until every handle has closed and one reopens (recovery needs
  exclusive access). Readers get `error.Broken` rather than a mixed view.
- Recovery opens each member with a separate SQLite connection to read its
  marker.
- Tested for at most 10 minutes of sustained load per run (see
  [Ten-minute runs](#ten-minute-runs)); long-duration endurance is left to
  the integrated implementation. Under steady reads, CWAL's WAL file
  reaches about twice plain WAL's size; nothing caps it yet.
- At most 32 files per set (`SQLITE_MAX_ATTACHED=31`, and the marker mask is
  32 bits).
- The power-loss model runs in one process: reader tests with I/O errors
  run without it. Process-crash tests are multi-process. It does not model
  the wal-index (`-shm`), which SQLite rebuilds after a crash. Injected
  errors are returned by this VFS; real disks were not filled or failed.
- One writer per set, enforced with `flock`. Lock files assume a local
  filesystem.
- Member ownership compares resolved paths. A hard link or bind mount gives
  one file two paths and is not detected. Each member gets two lock files
  (`-cwal-own`, `-cwal-mgate`) next to it.
- An outside connection that checkpoints a torn commit while recovery runs
  (after recovery read the wal-index heads) is not detected (REVIEW.md R6,
  from code reading).
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
- Tested on Linux x86_64 with SQLite 3.53.4 (the vendored copy), on tmpfs,
  btrfs, and loop-backed ext4, XFS and NTFS (the Linux `ntfs3` driver), one
  SATA SSD. Not tested: APFS, Windows (the prototype has no Windows VFS;
  NTFS under Windows has different locking and shared memory), network
  filesystems, separate physical drives, and real power loss. An aarch64
  build ran a subset under qemu user emulation on the same x86_64 host,
  which does not reproduce ARM's weaker memory ordering; ARM64 ordering
  rests on review of the barriers, not on tests.
- Lock files are named after `main.db`'s resolved path. Two handles that
  reach the same set through different names that SQLite does not resolve
  to one path (hard links, bind mounts) would use different lock files.
- The shared snapshot page uses 64-bit atomics, so 32-bit targets do not
  build.
- A reader holding one snapshot for a long time either stalls the writer
  (`RESTART`/`TRUNCATE` checkpoints wait for it, up to the busy timeout) or
  lets the WAL grow without bound (`PASSIVE`). This is SQLite WAL behavior
  and the same with the protocol off.
