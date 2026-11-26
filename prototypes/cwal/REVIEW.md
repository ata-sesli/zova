# CWAL correctness review (section 8)

This file records the protocol's safety properties, the invariants that
provide them, the state transitions, and the results of the review, the
model check, the build-mode runs and the mutation sweep. Line references
are to `src/cwal.zig`.

## Safety properties

- **S1. Atomic visibility.** A reader sees every member at one point between
  commits: never one member after a cross-file commit and another before it,
  and never a later single-member commit without an earlier one.
- **S2. Crash atomicity.** After a crash or power loss at any point, the next
  open leaves the newest cross-file commit either on every member it wrote or
  on none.
- **S3. Durability.** A commit that returned success survives a crash
  (`synchronous=FULL` or `EXTRA`).
- **S4. Unique transaction numbers.** A marker number identifies one
  transaction for the life of the set, including numbers a dead writer used.
- **S5. Refuse rather than corrupt.** A state the protocol cannot repair
  (broken set, torn commit already checkpointed, inconsistent markers, a
  member outside WAL mode) makes open or read fail; it is never served.

## Shared state

| State | Where | Meaning |
|---|---|---|
| `seq` | `-cwal-snap` page | Seqlock. Odd while a publication window is open. |
| `hdr[m]` | `-cwal-snap` page | Each member's wal-index header saved just before the window opened. |
| `cross` | `-cwal-snap` page | The current or last window belongs to a cross-file commit. |
| `broken` | `-cwal-snap` page | A cross-file commit rolled back after a member published. |
| `ckpt` | `-cwal-snap` page | Low 32 bits: handles holding an exclusive checkpoint lock. High 32 bits: checkpoints started. |
| `cwal_marker` row 0 | every member | `(txn, mask)` of the last cross-file commit that wrote this member. |
| `cwal_marker` row 1 | main | Writer epoch. |
| `-gate` | flock | Held exclusively while a handle opens (until every wal-index is mapped) or closes. |
| `-alive` | flock | Shared by every open handle; exclusive for an opener that finds no other. |
| `-writer` | flock | Exclusive: the one writer. |
| `-live` | flock | Exclusive: a live writer whose open found the set readable. |
| `<member>-cwal-own` | flock + contents, next to every member | Shared by every open handle of the set that owns the member; contains that set's identity (every member's resolved path, in order). |
| `<member>-cwal-mgate` | flock, next to every member | Held exclusively, briefly, while an opener decides whether it may own the member. |

## Invariants

| # | Invariant | Maintained by |
|---|---|---|
| I1 | `seq` is odd exactly while a writer is between its first commit-time WAL sync and phase two or rollback, or died there. | `startPublication` 1715 (from `ioSync` 711), `commitPhaseTwo` 1739, `rollbackHook` 1751 |
| I2 | While `seq` is odd, `hdr[m]` is every member's last committed header before the window: no member had published yet when it was copied. | `startPublication` copies before `seq += 1`; it runs at the first WAL sync, before any wal-index update |
| I3 | Every cross-file commit writes `(txn, mask)` to each member it writes, inside that member's transaction. A cross-file commit without markers is refused. | `commit` 1767, `commitHook` 1707 |
| I4 | Only the newest cross-file transaction can be torn. The one writer starts its next commit only after every member of the current one is durable. | `-writer` lock; `synchronous=FULL` required at open 1155 |
| I5 | Only the writer checkpoints, and only outside a commit, outside a window, and while the set is not broken. | `checkpointAllowed` 1566 from `ioShmLock` 813 and `ioLock` 758 |
| I6 | `ckpt` low half counts exactly the handles holding an exclusive checkpoint lock, plus dead ones not yet reset. The increment is visible before the holder loads any read mark; the decrement follows everything it wrote. | `ioShmLock` 816–847, `resetCheckpointers` 1581 |
| I7 | A snapshot open that skips SQLite's shared checkpoint lock is kept only if no checkpointer was active when it was "taken" and none started before it was "released" (after the read mark is stored). | `ckptLockShared` 1848, retry in `beginSnapshotRead` 1938 |
| I8 | While `-gate` is free, every holder of `-alive` has every member's wal-index mapped. So an opener that gets `-alive` exclusively is the first mapper: SQLite rebuilds wal-indexes only for it, after recovery. | `openCoordination` 1412, `close` 1321, `aloneAfterMapping` 1240 |
| I9 | After a writer opens, no member's WAL holds frames past its `mxFrame`. | `discardUnpublished` 1615 under each member's WAL write lock |
| I10 | `txn = epoch << 32 \| n`, and the epoch is raised durably before the writer numbers anything. | `open` 1188–1201 |
| I11 | `-live` is held by the writer of the current window, if that writer is alive. A writer that finds an interrupted cross-file window fails open and never takes it. | `openCoordination` 1437, 1449 |
| I12 | `broken = 1`, or `seq` odd with `cross = 1` and no live writer, makes the set unreadable until an alone opener recovers it. | `markersReadable` 1546 |
| I13 | Application statements cannot write the marker tables, change journal mode, locking mode, sync level or writable schema, or attach/detach. A commit frame written outside an approved commit (VACUUM and other hook bypasses) is refused. | `authorize` 1214, `observeWalWrite` 1669 |
| I14 | While any handle has a member open, every open handle that lists the member belongs to one set (same identity). So only handles of the set that owns a member recover, checkpoint or read its `-shm`. | `acquireMembers` 1596, `acquireMember` 1608, `close` 1379 |

## State transitions

### Seqlock page

```
            first WAL sync of a commit
            (save hdr[*], set cross)
  EVEN ─────────────────────────────────▶ ODD
   ▲                                      │
   │  phase two: seq += 1                 │
   ├──────────────────────────────────────┤
   │  rollback: if cross and a commit     │
   │  frame was written, broken = 1;      │
   │  seq += 1                            │
   ├──────────────────────────────────────┤
   │  writer dies:                        │
   │   cross = 0 → next writer's open     │
   │               does seq += 1          │
   │   cross = 1 → unreadable (I12) until │
   │               alone open: seq = 0,   │
   │               cross = 0, broken = 0  │
   └──────────────────────────────────────┘
```

### Writer commit

1. `commit()`: if two or more members are write-locked, write the markers
   with `txn + 1` and keep that number even if the commit fails.
2. SQLite `COMMIT` → `commitHook`: `in_commit = true`; compute `cross`;
   refuse if `broken`, or if cross-file without markers.
3. Phase one, per member: write frames (`observeWalWrite` accepts commit
   frames only while `in_commit`), sync the WAL, publish in the wal-index.
   The first WAL sync opens the window (`startPublication`); if a header
   cannot be read the sync fails before any member publishes.
4. Phase two (`SQLITE_FCNTL_COMMIT_PHASETWO` on main): close the window.
5. Any failure → `rollbackHook`: mark `broken` if a cross-file commit frame
   was already written, close the window.

### Reader

1. Load `s1 = seq`. Refuse if the set is unreadable (I12).
2. `s1` even: begin, pin members in order, recheck `seq == s1`, else retry.
3. `s1` odd: copy `hdr[*]`, recheck `seq` with a read-modify-write, begin,
   open each member at its saved header with `sqlite3_snapshot_open`. The
   shared checkpoint lock is skipped and validated (I7). A checkpoint race
   retries. A failed open waits for the window to end, or fails with
   `Broken` if the writer died.

### Open and recovery

0. Own every member (I14), or fail with `MemberOwned`; a set that lists
   one file twice fails with `ProtocolViolation`.
1. Take `-gate`. Writer: take `-writer` or fail with `WriterBusy`.
2. Try `-alive` exclusively.
   - Got it (alone): `recover()`, reset the page, share `-alive`.
   - Otherwise share `-alive`; refuse an unreadable set; read the
     wal-index heads unless another handle of this set is open in this
     process.
3. Writer: close a dead writer's single-member window (`seq` odd → even);
   take `-live`.
4. Open SQLite on every member; require WAL mode; map every wal-index.
5. If no other handle holds `-alive` any more (`aloneAfterMapping`): close
   without checkpointing, recover as an alone opener, reopen.
6. Writer: discard unpublished frames (I9), reset dead checkpointers (I6),
   create the marker tables, raise the epoch (I10).
7. Release `-gate`; install the authorizer.

### Recovery decisions (`recover` 1481)

| Markers found | Decision |
|---|---|
| No member has a marker (`txn = 0`) | Nothing to do. |
| Newest marker's mask names a member outside the set | `ProtocolViolation` |
| A member has the newest number with a different mask, or is not in the mask | `ProtocolViolation` |
| Every member in the newest mask has the newest number | Complete: keep it. |
| Some member in the newest mask lacks the newest number | Torn: on each member that has it, truncate the WAL at the start of its last commit. First every such member is checked, and any failure refuses with `ProtocolViolation` before anything is truncated: the WAL must exist and end in a commit that writes the marker table's root page, and the member's wal-index (read before SQLite mapped it) must not show that commit checkpointed (`nBackfill` past its start, or the wal-index one WAL restart ahead). |

Then every `-shm` is unlinked so SQLite rebuilds the wal-indexes from the
truncated WALs. Recovery is idempotent; a crash during it reruns it.

## Mutations

Each mutation removes one mechanism. The suite must fail with each one.

| Mutation | Removes |
|---|---|
| `no-gate` | Publication window (I1) |
| `no-solo-window` | Window for single-member commits (S1) |
| `no-seq-check` | Reader recheck of `seq` (S1) |
| `no-snapshot-open` | Snapshot opens inside a window (S1) |
| `no-ckpt-gate` | Checkpoint gate on the shared-memory lock (I5) |
| `no-lock-gate` | Checkpoint gate on the EXCLUSIVE file lock (I5) |
| `no-ckpt-skip` | The skip itself (performance only; must stay correct) |
| `no-ckpt-validate` | Snapshot-open validation (I7) |
| `no-ckpt-reset` | Reset of dead checkpointers (I6) |
| `no-markers` | Commit markers (I3) |
| `no-marker-rollback` | Torn-commit rollback (S2) |
| `no-backfill-check` | Detection of a checkpointed torn commit (S5) |
| `no-cross-flag` | Unreadable interrupted cross-file window (I12) |
| `no-discard-unpublished` | Discard of unpublished frames (I9) |
| `no-txn-epoch` | Writer epochs (I10) |
| `no-open-gate` | Open/close gate (I8) |
| `no-late-alone` | Recheck of `-alive` after mapping (I8) |
| `no-authorizer` | Authorizer (I13) |
| `no-frame-guard` | Commit-frame guard (I13) |
| `no-early-heads` | Heads read before mapping on the late-alone path (S5, R3) |
| `heads-process-wide` | The pre-T2 condition for reading heads on the shared path (S5, R3) |
| `no-ownership` | Member ownership (I14) |

## Review findings

An independent reviewer (a separate agent given the code and SQLite's
source, not this file) checked recovery decisions and checkpoint-counter
ordering. Its findings, verified here:

### Confirmed and fixed

**R1. Recovery silently kept a torn commit after an outside connection
checkpointed it and then wrote.**
- Component: CWAL prototype, `recover`, `backfilledPast`.
- Bug: the set reopened torn (one member has transaction N, another does
  not). Nothing was refused.
- Cause: `backfilledPast` trusted `nBackfill` only while the `-shm` salts
  match the WAL. An outsider that checkpoints everything and then writes
  makes SQLite restart the WAL (`walRestartLog`): new salts, `nBackfill = 0`,
  and new frames. N is then in the database file, and the last commit in the
  WAL is the outsider's. Recovery saw marker N, found the set torn, and
  truncated the outsider's commit. An outsider that dies between restarting
  the `-shm` and writing the new WAL header leaves the old frames with old
  salts, and the check was skipped the same way.
- Fix (applied): recovery also refuses if the last commit on a member does
  not write `cwal_marker`'s root page (N's commit always does; `readMarker`
  now returns the root page and `walLastCommit` reports it), or if the
  wal-index is one restart ahead of the WAL (its salt-1 is the WAL's plus
  one; SQLite restarts a WAL only after checkpointing all of it).
- Evidence: two outsiders added to the crashed-set test, acting on `s1.db`
  (13 of the 21 torn sets have the torn commit in its WAL): checkpoint,
  write, die; and the same with the old WAL bytes put back (died before the
  new header). Pre-fix binary: 13 and 5 silent tears. Fixed: 13 and 13
  refused, 0 tears. `no-backfill-check` (which now disables all three
  checks) tears with both.

**R2. Recovery could truncate some members and then refuse on a later one.**
- Component: `recover`.
- Bug: members were checked and truncated one at a time, so a
  `ProtocolViolation` on member j (no WAL, no commit, already checkpointed)
  came after earlier members were truncated.
- Impact: the set was still refused, not served, but manual repair then
  started from a partly rolled-back set.
- Fix (applied): every member is checked first, then all are truncated.
- Evidence: the crashed-set test now fails a refusal that changed any WAL
  file (`PARTIAL`). Pre-fix binary: 8 `PARTIAL` each for "plain open s1.db"
  and "plain write s1" (`main.db` truncated, then `s1.db` refused). Fixed: 0.

**R3. The late-alone path could not see a foreign checkpoint.**
- Component: `open` → `recoverAlone` → `recover`.
- Bug: `recover` read each `-shm` itself, but on this path SQLite has
  already mapped (and so possibly rebuilt) the `-shm`, which zeroes
  `nBackfill`. `backfilledPast` could not fire.
- Impact: narrow: a foreign checkpoint of a torn commit, plus the last other
  handle closing during this handle's open.
- Fix (applied): `openCoordination` reads the heads (`readShmHeads`) before
  `openSqlite`, and `recover` uses them. On the shared path it reads them
  only when no other handle of this process is registered: closing a
  descriptor of a `-shm` drops every POSIX lock the process holds on it, so
  reading under another connection's locks breaks that connection (the
  first version of this fix did, and the concurrent-readers test failed
  with `disk I/O error`). A handle of the same process with the set open
  rules out the late-alone path anyway (closes take `-gate`); a handle of
  another set in the same process means this case stays undetected.
- Evidence: code reading only; the timing is not reproduced by a test.
- Follow-up (T2, closed): the shared path now reads the heads unless
  another handle of *this set* is open in the process (`otherHandleOfSet`,
  a per-slot set-identity hash). This is safe because of member ownership
  (R4/I14): no handle of another set can have one of this set's members
  open, so reading a member's `-shm` drops no other set's locks. The
  `delaypoints` torture section reproduces the timing deterministically: a
  reader holds the set; the writer is killed at `commit-sync-next` (main
  published and checkpointed by an ordinary connection, `s1` durable but
  unpublished, `s2` not written); the seqlock page is deleted; the opener
  pauses at `open-shared` (`CWAL_PAUSE_AT`) while the holder is killed.
  The opener must refuse with `ProtocolViolation` and leave every WAL
  unchanged, with and without a handle on another set in its process.
  `heads-process-wide` (the old condition) fails only the second case: the
  opener truncates `main.db-wal` although the torn commit is already in
  `main.db`.
- Reachability: the case needs the seqlock page lost or reset. With the
  page intact, the dead writer's open cross-file window makes every shared
  opener fail with `Broken` before it reaches the late-alone path, and
  frames that were never published cannot be checkpointed by an outside
  connection while a CWAL handle keeps the wal-index mapped.

### Suspected / design limits

**R4. "Alone" is decided per main database, not per member file.** `-alive`,
`-gate` and the checkpoint counter live next to `paths[0]`. A member shared
by two sets, or one main opened with different member lists, lets one set
recover (truncate) a WAL another set's handles are reading.
- Fix (T3, applied): exclusive member ownership (I14, `acquireMembers`).
  Before anything else, an opener takes each member's `-cwal-mgate`
  exclusively and tries `-cwal-own` exclusively without blocking. Success
  means no handle owns the member: it writes its set identity and keeps the
  lock shared. Failure means owners hold it shared; the opener joins only if
  the recorded identity equals its own, else fails with `MemberOwned`. The
  record changes only under the exclusive lock, which needs every owner
  gone, and every decision is made under the member gate, so two sets can
  never hold one member at once. Locks are `flock`, which belongs to the
  open file description, so threads and handles of one process exclude each
  other too. `F_GETLK` is not used: it reports only other processes' POSIX
  locks and only at the instant of the call, so it can't serialise two
  openers.
- Evidence: the `ownership` torture section. Static cases, in another
  process and in the same process (`nexec --hold`): a set sharing a member
  through a symlink, and A's main with a different member list, are refused
  with `MemberOwned` in both roles; the owner's WALs are unchanged; the same
  set opens twice in one process and from two processes; a killed owner
  releases ownership; a set listing one file twice is refused. Race cases
  (`nown`): 2 processes × 2 threads open and close the two overlapping sets
  at random for 2 s; no interval in which a handle of one set was open
  overlaps one of the other. `no-ownership` fails every static refusal and
  both races.
- Limit: identity is by resolved path. A hard link or bind mount gives one
  file two paths and is not detected.

**R6. An outside checkpoint during recovery is not detected.** Found while
writing the T2 tests; code reading only, not reproduced.
- Component: `openCoordination` → `recover`.
- Bug: the foreign-checkpoint check uses wal-index heads read before
  recovery starts. An ordinary connection that opens a member after that
  read, checkpoints the torn commit and exits without closing leaves its
  `nBackfill` only in a `-shm` that recovery's own connection then
  rebuilds. Recovery truncates the WAL although the torn commit is in the
  database file.
- Impact: needs an outside connection racing recovery itself; the same
  class as the undetected cases in README "Limits" (a dead checkpointer, a
  lost `-shm`). CWAL handles cannot cause it.
- Fix: not attempted (outside T2/T3 scope, and it would change recovery).
  In Zova, raw access to members is not a supported path.

**R5. ARM64 ordering is argued, not tested on hardware.** The counter's
correctness on ARM64 depends on the two `xShmBarrier` calls (store-buffer
pattern; SQLite's own atomics are relaxed). The qemu runs used x86 ordering.

### Verified correct

- Marker rule: newest number wins; equal numbers with different masks, a
  member missing from its own mask, or mask bits past the set are refused.
  Only the newest cross-file transaction can be torn.
- Epoch numbering gives unique numbers across writer crashes.
- `walLastCommitStart` accepts exactly the frames SQLite's WAL recovery
  accepts; `backfilledPast` and `truncateUnpublished` decode the `-shm` as
  SQLite does.
- Recovery order: truncate, fsync, unlink `-shm`, reset the page. Reruns are
  idempotent.
- `discardUnpublished` holds the WAL write lock, which also excludes a
  wal-index rebuild, and never cuts below `mxFrame`.
- The open gate covers the `-alive` test, the mapping and the late re-test.
- Checkpoint counter: a checkpointer that finished before the reader's
  "take" is visible through its `nBackfillAttempted` (stored before its
  decrement); one that starts during the open changes the started count;
  one that starts after the release sees the reader's read mark (full
  barriers on both sides). Wal-index and snapshot recovery are counted; a
  close-time checkpoint holds the EXCLUSIVE file lock instead, which the
  file-lock gate covers. A dead checkpointer only costs readers the real
  lock until the next writer resets the count.

## Model check

`model.py` is an explicit-state breadth-first search over every
interleaving of two small models (no TLA+ toolchain is installed; Python
keeps it next to the prototype). `./model.py` runs both models, then each
mutation; it exits non-zero if the correct protocol violates a property or
a mutation goes undetected.

**Protocol model.** Three members, one writer, one reader, up to three
transactions, each writing `{0}`, `{1}`, `{0,1}` or `{1,2}`. Steps: frame
write, WAL sync (opens the window; may fail and roll back), wal-index
publish, phase two, writer checkpoint, reader seqlock read (pin path,
snapshot path, failed snapshot open), one writer kill followed by a writer
reopen (seq repair, discard, numbering) while the reader stays, one crash
of every process (kill, or power loss that drops unsynced frames and the
`-shm`), and alone recovery. Checks S1 on every completed read, S2 and S3
after recovery, S4 at every number assignment, and that the correct
protocol is never refused.

**Checkpoint-counter model.** One member, a reader opening a snapshot at
frame 1 while the WAL has 3, against a checkpointer making two passes.
Reader: take (counter; real shared lock if a checkpointer is active),
snapshot check, read mark, release (validate). Checkpointer: lock, counter
increment, read-mark scan, `nBackfillAttempted`, counter decrement, unlock.
Checks that no open snapshot has `nBackfillAttempted` past it. The model
is sequentially consistent; the prototype issues full barriers at the two
points where that matters (`ioShmLock` 843, `ckptLockShared` 1868).

Results (2026-11-26, Python 3, 1.8 GB peak):

| Run | States | Result |
|---|---|---|
| Protocol, correct | 1,388,569 | **No violation, no refusal** |
| Protocol, foreign checkpoints at any time, process kills only | 3,756,700 | **No violation**; 706 recoveries refused (`torn commit already checkpointed`) |
| Protocol, foreign checkpoints and power loss | 2,084 | Violation: a lost `-shm` hides the checkpoint (known limit, see below) |
| `no-gate`, `no-seq-check`, `no-snapshot-open` | 7k–9k | S1: a read sees a cross-file commit on one member only |
| `no-solo-window` | 62,595 | S1: a read sees t2 without the earlier committed t1 |
| `no-markers`, `no-marker-rollback` | 172 | S2: a torn commit survives recovery |
| `no-cross-flag` | 8,760 | S2: a new writer closes a dead cross-file window and checkpoints half of it |
| `no-discard-unpublished` | 4,557 | S2: a dead writer's unpublished frame on member 0 is revived by recovery |
| `no-txn-epoch` | 177 | S4: the reopened writer reuses marker number 1 |
| `no-ckpt-gate` | 2,084 | S2: a reader checkpoints a published half-commit, then power loss |
| `no-backfill-check` (foreign checkpoints) | 1,843 | S2: recovery truncates a WAL whose torn commit is already in the database |
| Counter, correct | 137 | **No violation** |
| `no-ckpt-skip` (control: always the real lock) | 33 | No violation |
| `no-ckpt-validate` | 51 | Violation |
| `ckpt-inc-late` (increment after the read-mark scan) | 56 | Violation |
| `ckpt-dec-early` (decrement before `nBackfillAttempted`) | 78 | Violation |

The last two are not prototype mutations: they confirm that both orderings
in `ioShmLock` are needed.

What the model does not cover: SQLite internals below its API (wal-index
rebuild timing, which the open gate and the late `-alive` check handle; the
authorizer; the frame guard), WAL restarts, more than one reader, and the
checkpoint lock's own fairness. The torture suite covers those.

Known limit confirmed by the model: recovery detects a foreign checkpoint
of a torn commit from the `-shm` (`backfilledPast` 970). After power loss
that file may be gone, and the tear is then silent. This needs an outside
connection to checkpoint during a window, which the protocol forbids but
cannot prevent.

## Build modes

2026-11-26, tmpfs, 8 jobs. Every one of the 29 torture sections, with
reduced samples: `--powerloss-seeds 1 --ncap 300 --allcap 400
--survivor-trials 5 --restart-seeds 1 --io-positions 4 --files 2 3 8`.
(The complete suite took 63 minutes in ReleaseSafe for sections 1–4 alone;
three full runs would take several hours.)

| Build | Time | Result |
|---|---|---|
| ReleaseFast | 18.8 min | **PASS**: 0 failures, 0 mixed reads, 0 snapshot violations in 180 CWAL result lines; 70/70 enforcement cases |
| ReleaseSafe | 18.7 min | **PASS**: same (179 lines; 70/70) |
| Debug | 19.5 min | **PASS**: same (179 lines; 70/70) |
| ReleaseSafe, after the R1–R3 fixes | 18.8 min | **PASS**: 0 CWAL failures, mixed reads or violations; 70/70; crashed sets with the two R1 outsiders: 0 tears, 0 partial refusals |
| Debug / ReleaseSafe / ReleaseFast, with T2/T3 | 21.9 / 21.3 / 21.3 min | **PASS** on each: 91/91 `pass` lines (70 enforcement, 4 delay-point, 17 ownership), 0 `FAIL`; the two new sections also pass 30 of 30 repeats per build (`results/2026-11-26-t2t3-3498a53/`) |

No safety check fired in ReleaseSafe or Debug, and ReleaseFast, which has
none, gave the same results.

## Mutation results

2026-11-26, tmpfs, ReleaseSafe, `cwal.zig` as of 0355feb (before the
R1–R3 fixes; `no-backfill-check` was rerun after them). Each mutation ran only the sections that should catch it
(`--powerloss-seeds 1 --survivor-trials 10 --restart-seeds 2 --files 3 8`);
detected means `torture.py` failed. The same sections with no mutation pass
(224 s).

| Mutation | Sections | Result |
|---|---|---|
| `no-markers` | crash | detected |
| `no-marker-rollback` | powerloss | detected |
| `no-cross-flag` | survivors | detected |
| `no-gate` | readers | detected |
| `no-seq-check` | readers | detected |
| `no-snapshot-open` | readers | detected |
| `no-solo-window` | readers | detected |
| `no-lock-gate` | closeckpt | detected |
| `no-ckpt-gate` | closeckpt | detected |
| `no-ckpt-validate` | ckptrace | detected |
| `no-ckpt-reset` | ckptreset | detected |
| `no-discard-unpublished` | ndangle | detected |
| `no-open-gate` | ndangle | detected |
| `no-late-alone` | ndangle | **not detected in ReleaseSafe** (0 / 153 and 0 / 480); detected with the Debug build in 2 of 2 runs (1–2 / 153 torn at 3 files, 640–1,463 mixed reads) |
| `no-txn-epoch` | nrestart | detected |
| `no-authorizer` | enforce | detected |
| `no-frame-guard` | enforce | detected (new case: `VACUUM` after `!noauth` removes the authorizer) |
| `no-backfill-check` | enforce | detected; after the fixes also 13 / 48 and 5 / 48 silent tears with the two R1 outsiders |
| `no-ckpt-skip` (control) | ckptrace | passes, as it should |

All 18 defect mutations are detected, and the model check catches the 11
it covers. Two weaknesses:

- `no-late-alone` is caught only when the race lines up. The test widens
  the gap between the `-alive` check and the mapping with a 20 ms sleep,
  but the writer kill lands in it under the slower Debug build only. A
  deterministic test would pause the opener inside that gap and kill the
  last other handle there. (Done in T2; see below.)
- `no-frame-guard` needed a test hook (`nexec !noauth`) because the
  authorizer refuses `VACUUM` first. That matches the real exposure: an
  application that installs its own authorizer removes CWAL's.

### T2/T3 sweep

2026-11-26, tmpfs, ReleaseSafe, `3498a53` plus the T2/T3 changes
(`results/2026-11-26-t2t3-3498a53/`). Same options as above. The swept
sections, now including `delaypoints` and `ownership`, pass with no
mutation (237 s). All 18 earlier defect mutations are detected again,
except `no-late-alone` by `ndangle` (0 / 153 and 0 / 480, as before); the
`no-ckpt-skip` control passes.

| Mutation | Sections | Result |
|---|---|---|
| `no-cross-flag` | delaypoints | detected (2 s): the new writer opens, 1,228 mixed reads, check finds a torn set |
| `no-late-alone` | delaypoints | detected (2 s): 100 mixed reads; both R3 openers serve the set |
| `no-early-heads` | delaypoints | detected: both R3 openers truncate `main.db-wal` past a checkpointed torn commit |
| `heads-process-wide` | delaypoints | detected by the same-process R3 case only, as intended |
| `no-ownership` | ownership | detected: 10 refusal cases open; 369 and 50 overlapping intervals in the races |
