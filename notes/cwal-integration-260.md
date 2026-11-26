# CWAL integration design (#260)

Status: experimental integration approved (2026-11-26). The design and the
frozen baseline are approved, and so are the §12 decisions. Production
release is a separate gate. This note records the frozen prototype baseline and the
design for putting CWAL into Zova. It is an engineering plan, not user
documentation.

CWAL (`prototypes/cwal/`) gives a WAL-mode set of SQLite files cross-file
crash atomicity and consistent cross-file snapshots. In Zova, that set is a main
`.zova` file and its bound object, vector and graph stores. Its protocol,
invariants and review are in `prototypes/cwal/README.md` and `REVIEW.md`.
This note does not change the protocol. Integration changes only where it
hooks into Zova.

## 1. Frozen baseline

The baseline is commit `77c5b5a` on `work/cwal-prototype`: the prototype as
reviewed in section 8 plus the R1–R3 fixes. Integration starts by porting
`prototypes/cwal/src/cwal.zig` from this commit, unchanged in behavior,
together with the T2/T3 additions (member ownership and the same-set
heads check, §2). Later
protocol changes need a concrete integration requirement, and must rerun the
suites and mutation sweep below against the changed code.

Tagged `cwal-prototype-baseline` (local tag, not pushed).

| Item | Value |
|---|---|
| Commit | `77c5b5aba1f341c388b288b63316caa863275873` |
| SQLite | 3.53.4 (vendored), built with `SQLITE_ENABLE_SNAPSHOT`, `SQLITE_MAX_ATTACHED=31` |
| Zig | 0.17 |
| Binary SHA-256 prefix, Debug | `fae20388412b758a` |
| Binary SHA-256 prefix, ReleaseSafe | `24bfbf761ed838b3` |
| Binary SHA-256 prefix, ReleaseFast | `0dbb0ed97df94063` |

The hashes are for this host's builds (Linux x86_64) and identify the
binaries the post-fix runs below used. They are not reproducible-build
claims.

### Post-fix regression and mutation results

Run on 2026-11-26 on tmpfs with 8 jobs, using the three binaries above.
The raw logs, scripts, binary hashes and host details are in
`prototypes/cwal/results/2026-11-26-postfix-77c5b5a/`.

**Regression.** All 29 torture sections ran with reduced samples (the
options in `prototypes/cwal/REVIEW.md`, "Build modes"):

| Build | Time | Result |
|---|---|---|
| Debug | 19.6 min | PASS |
| ReleaseSafe | 19.0 min | PASS |
| ReleaseFast | 18.9 min | PASS |

In every build:
- No CWAL result line has a mixed read, a checkpoint violation or a
  failed check.
- All 70 enforcement cases pass.
- Crashed sets: no tear and no partial refusal for any of the 15
  outsiders. The two R1 outsiders are refused in all 13 torn sets they
  reach.

**Model check.** `model.py` passes (114 s). The correct protocol has no
violation. With foreign checkpoints it has no violation and 706
refusals. All 11 protocol mutations and the 3 counter orderings are
caught.

**Mutation sweep.** Run on ReleaseSafe with the sections and options of
REVIEW.md, "Mutation results". The unmutated control passes.
- Detected: 17 of the 18 defect mutations.
- `no-ckpt-skip` (control) passes.
- `no-late-alone` was detected in ReleaseSafe this time, and in Debug.
- `no-cross-flag` was **not detected** with 10 survivor trials.

Rerunning `no-cross-flag` with 40 trials detects it in both the post-fix
binary (4 of 40 trials fail the check, 90,347 mixed reads) and the pre-fix
binary (3 of 40). So the miss is the sample size, not a regression: each
trial catches the mutation only when the writer kill lands inside a
cross-file window, roughly one trial in ten. Section 8's run also caught
it in only 1 of 10. Integrated qualification should run this mutation
with at least 40 trials.

Like `no-late-alone`, `no-cross-flag` depends on a race. Both need
deterministic delay-point tests (T2).

## 2. Tracked open items

These stay open until closed with evidence. Each phase that touches the
area must report on it.

| Id | Item | State | Closing evidence |
|---|---|---|---|
| T1 (R5) | Native ARM64 validation. The checkpoint counter relies on two `xShmBarrier` calls; qemu runs used x86 ordering. | Deferred | Torture `readers`, `ckptrace`, `ckptreset`, `closeckpt`, `nreaders` and the crash sections pass natively on ARM64 Linux (`ubuntu-24.04-arm` is already a CI runner) and on Apple Silicon macOS, plus a mutation run of `no-ckpt-validate` detected there. |
| T2 (R3) | R3 timing case: a foreign checkpoint of a torn commit, combined with the last other handle closing during this handle's open. On the shared path the heads were read only when no other handle of the process was registered, so a handle of another set in the same process left this undetected. | Closed in the prototype (2026-11-26) | Torture section `delaypoints`: a pause point (`CWAL_PAUSE_AT=open-shared`) and two crash probes (`commit-sync-first`, `commit-sync-next`) make R3, `no-late-alone` and `no-cross-flag` deterministic. The shared path now skips the heads only when another handle of the same set is open in the process; member ownership (T3) makes that safe. `no-cross-flag`, `no-late-alone`, `no-early-heads` and `heads-process-wide` are each detected. R3 needs a lost seqlock page to be reachable (REVIEW.md R3). Raw results: `prototypes/cwal/results/2026-11-26-t2t3-3498a53/`. |
| T3 (R4) | Member ownership was decided per main file. | Closed in the prototype (2026-11-26) | Per-member `flock` ownership with a recorded set identity (§3). Torture section `ownership`: cross-process and same-process refusals (`MemberOwned`), same-set sharing, release on kill, and a two-set open/close race with no overlapping intervals; `no-ownership` is detected. Same raw results directory. |
| T4 | Endurance: 12–24 h sustained workloads (deferred from section 7). | Deferred | Run against the integrated implementation, not the prototype. |
| T5 | Windows: no Windows VFS or lock layer exists. | Deferred; out of scope for the experiment (§9). | — |
| T6 (R6) | Suspected from code reading: an outside connection that opens a member after recovery read its wal-index heads, checkpoints the torn commit and exits without closing can leave recovery with stale heads, so the torn commit stays in the database file. | Confirmed and fixed in the prototype (2026-11-26) | Reproduced deterministically with pause points `recover-begin` and `recover-truncate` (0 / 3 before the fix, outsider dying and staying open). Fix, recovery only and only for a torn set: each member to truncate is opened in exclusive locking mode, which keeps every other connection from reading or checkpointing it until the truncation; under that lock recovery rereads the marker and the `-shm` and compares the database file's root page with the torn commit's copy. An outsider holding the member open makes the open fail with `ProtocolViolation`. Clean opens and steady state are unchanged. Mutations `no-root-check` and `no-repair-lock` are each detected; the model's foreign-checkpoint-with-power-loss run now passes. Remaining limit: a checkpointer that died after a partial copy, before copying the root page and before advancing `nBackfill`. Raw results: `prototypes/cwal/results/2026-11-26-r6-2d00c0d/`. |
| T7 | Alias-safe ownership. Ownership is keyed by resolved path, so a hard link or a bind mount of a member gives a second path to the same file and is not detected. | Open; must close before production release | Identity-based ownership using device and inode, with torture cases for a hard-linked member and a bind-mounted member directory. |

## 3. Exclusive member ownership

**Problem.** CWAL's lock files, seqlock page and checkpoint counter live
next to the main file. A member file used by two sets, or a main file
opened with two different member lists, lets one set's recovery truncate a
WAL that another set's handles are reading (R4).

**What Zova already gives.** A store is tied to one main file through
`store_id`, `bound_set_id` and the epoch in both the store's `_zova_meta` and
main's `_zova_bound_stores` row (`src/database/bound_stores.zig:92-117`).
Binding a store again writes a fresh `bound_set_id`, so the main file it was
bound to before fails to open (`src/zova.zig:2839-2848`). The member list is
therefore fixed by the main file, and Zova never opens one store with two main
files on purpose.

**Design.**

1. The CWAL set is exactly main plus the stores recorded in main's
   `_zova_bound_stores` at open, in a fixed order: main, object, vector,
   graph. Members that are not bound are absent. Sets have at most four
   members, so the prototype's 32-member limit and `SQLITE_MAX_ATTACHED=31`
   are not needed (SQLite's default of 10 is enough).
2. Recovery checks ownership **before** it truncates anything. Each store's
   `bound_set_id` and `store_id`, read through the recovery connection,
   must match main's row. A mismatch refuses the open (`ProtocolViolation`),
   so recovery never repairs a file that belongs to another set.
3. Every open owns each member before it takes the set's gate or runs
   recovery (implemented and tested in the prototype, T3). Per member,
   `<member>-cwal-own` is held shared by every handle of the owning set
   and records the set's identity (the members' resolved paths, in order).
   An opener decides under `<member>-cwal-mgate` (exclusive, held
   briefly): an exclusive non-blocking lock on `-cwal-own` means no owner,
   so it records its identity and keeps the lock shared; otherwise it joins
   only a matching identity and fails with `MemberOwned`. Locks are `flock`,
   per open file description, so handles in one process exclude each other
   too. This replaces the `fcntl(F_GETLK)` test first proposed for R4:
   `F_GETLK` sees only other processes' POSIX locks, at one instant, so it
   cannot serialise two openers. Ownership does not cover connections
   outside the protocol; recovery's repair lock (§8, T6) does. The
   protocol is unchanged.
4. Lock-file names come from main's resolved path (as in the prototype).
   Store paths are stored verbatim and resolved against the process working
   directory (`src/database/paths.zig:111-125`), so two processes in
   different directories can resolve a relative store path to different
   files. Check 2 refuses that case. The docs will recommend absolute
   store paths for CWAL sets.
5. Bind, unbind and split change membership. On a CWAL set they need the
   set open alone (`-alive` exclusive), with nothing torn and every member
   fully checkpointed. A new member gets its marker table in the same
   operation (§6).

Tests:
- a store bound to a second main file (the first then fails open, as today);
- a hand-copied store with the same ids opened beside its original;
- a relative store path opened from two working directories;
- a store opened as a member of a second CWAL set while the first is open,
  in another process and in the same process: refused with `MemberOwned`,
  and no WAL changes (the prototype's `ownership` section, ported).

## 4. Transaction interception

**Today.** A transaction is one SQLite transaction on the handle's single
connection, across the attached schemas (`src/zova.zig:1119-1134`). Zova
installs no commit, rollback or update hooks and no persistent authorizer.

**Commit points.** On a CWAL set, every point where Zova ends a write
transaction goes through CWAL's commit, which writes markers when two or
more members are write-locked:

- `Database.commit` (`src/zova.zig:1247`);
- internal `beginImmediate` + commit scopes: batch mutations
  (`zova.zig:2699-2723`), object mutations (`src/object.zig:2228-2243`),
  bound graph mutations (`zova.zig:2674-2679`), `split`, `reclaimSpace`
  steps and fresh-build sessions (`src/c_api/fresh_build.zig`);
- `RELEASE` of an outermost savepoint that was opened in autocommit mode,
  which commits. Zova's own savepoint scopes (`zova_batch_mutation`,
  `zova_object_mutation`, `fresh_build_session`) are used only inside a
  caller's transaction, so they never commit. CWAL's commit hook still
  refuses a cross-file commit without markers, which catches any path
  missed here.

Object mutations call `sqlite.Database.commit` directly, not through the
`Database` facade. So the change sits one layer down, in `sqlite.Database`:
on a connection that has a CWAL coordinator attached, `commit` and
`releaseSavepoint` route through it. Notifications stay as they are:
`notifications.commit()` runs only after the CWAL commit succeeds.

**Read points.** CWAL readers must start through `beginRead` (seqlock and
pin, or snapshot open):

- Zova's internal read scope for multi-statement calls
  (`Database.beginRead`, `zova.zig:2686-2697`, a deferred `begin`) starts
  a CWAL read;
- `Database.begin` (deferred) on a CWAL handle also becomes `beginRead`, so
  a caller's read transaction sees all members at one commit;
- `beginImmediate` is a write transaction and needs no snapshot.

**Raw SQL.** Callers can run SQL through `exec` and `prepare` in every
binding.

- A cross-file write committed by SQL text (`COMMIT`, `END`, an outermost
  `RELEASE`, or an autocommit statement that writes two schemas) is refused
  by the commit hook. The error tells the caller to use Zova's
  transaction API.
- Single-file autocommit writes work unchanged (no markers needed).
- A single autocommit `SELECT` that reads several schemas gets no
  cross-file snapshot unless it runs inside a Zova read call or a
  `begin`/`commit` pair. This is a documented limit. Wrapping every raw
  statement step would mean intercepting `sqlite3_step`, which is out of
  scope.

No binding writes transaction control as SQL text; all of them call the C
ABI's begin, commit and rollback.

## 5. Private marker-table protection

- **Name.** `cwal_marker` becomes `_zova_cwal_marker`, inside Zova's private
  `_zova_` namespace. Conversion from plain SQLite already rejects `_zova_`
  names (`bound_stores.zig:263-277`), and so does the savepoint rule.
  Columns and rows are unchanged: row 0 holds `(txn, mask)` in every member,
  and row 1 holds the writer epoch in main.
- **Authorizer.** Zova installs `sqlite3_set_authorizer` only temporarily
  today, and always clears it to NULL afterwards (plugin storage and
  lifecycle in `src/extension_plugin.zig:464-465`, `527-528`, `557-558`, and
  `src/extension_operations.zig:30`, `40`). That would silently remove
  CWAL's authorizer. The fix is one persistent Zova authorizer per CWAL
  handle:
  - CWAL's denials come first: writes, DDL and triggers on
    `_zova_cwal_marker`; `journal_mode`, `locking_mode`, `synchronous` and
    `writable_schema` with a value; `ATTACH`, `DETACH` and `VACUUM`;
  - then an optional inner authorizer that the plugin code pushes and pops
    instead of calling `setAuthorizer` itself.

  `sqlite.zig`'s `setAuthorizer` routes through this layer, so no caller
  can clear CWAL's checks by accident.
- **Internal bypass.** CWAL's own marker updates, and the Zova operations
  that must attach, detach or vacuum (§6), suspend the CWAL checks for
  their own statements only, as `Conn.commit` does in the prototype.
- **Second layer.** The VFS commit-frame guard still refuses a WAL commit
  frame that no approved commit wrote. The Zig escape hatch
  (`sqlite_db.handle`) can replace the authorizer, and the frame guard
  catches the commits that follow. The C ABI and the bindings expose no
  raw `sqlite3*`.
- **Visibility.**
  - `zova info`, `doctor` and the schema listings treat
    `_zova_cwal_marker` like any other private table.
  - Exact-schema validation adds it to each member's expected schema when
    the set is in CWAL mode (§7).
  - Backup, compact and migrate outputs that leave CWAL drop it (§6).

## 6. Maintenance operations

**Secondary connections.** Several operations open extra SQLite
connections. On a CWAL set each of these must either go through the CWAL
VFS as a reader, whose checkpoints are refused by the gate, or be opened
read-only. A read-write plain connection to a member is an outsider: it
can checkpoint a torn commit when it closes. These connections are:

- migration: the lock connection, sources and staging (`zova.zig:718-775`);
- backup and compact destinations (`zova.zig:1721`, `2760`);
- CLI diagnostics (`src/cli/diagnostics.zig:191`);
- salvage.

| Operation | Today | On a CWAL set |
|---|---|---|
| `backupTo` / `zova backup` | Backup API main→main under a held read snapshot, then stores copied in by SQL and their rows deleted (`zova.zig:1716-1728`, `2757-2804`) | Hold one CWAL `beginRead` across the main copy and the store copies, so the backup is cross-file consistent (an improvement on WAL today). The output is a single file: drop `_zova_cwal_marker` and the CWAL meta key in the destination. |
| `compactTo` | `VACUUM INTO`, then stores copied in (`zova.zig:1757-1781`) | `VACUUM INTO` cannot run inside a transaction, so hold the CWAL writer lock for the whole operation, which stops commits during it. Internal bypass for `VACUUM INTO` (it writes only the destination). Drop the marker table in the output. |
| `vacuum` (in place, main only) | Plain `VACUUM` (`zova.zig:1312`) | Run as the writer, with the authorizer suspended and the commit marked approved as a single-file commit, so the frame guard accepts it and the solo publication window still opens. Needs a dedicated test: VACUUM skips the commit hook. |
| `reclaimSpace` | `incremental_vacuum` per member, one immediate transaction per step | Unchanged: each step is a single-file commit through the normal path. |
| `checkpoint` | `sqlite3_wal_checkpoint_v2` per schema | Allowed on the writer handle outside a commit. On a reader handle it returns busy (checkpoint gate), so the docs say to checkpoint from the writer. |
| `setJournalMode` | Switches every member together | Refused on a CWAL set unless the mode is `wal`. Leaving WAL requires disabling CWAL first (§7). |
| `migrate` | Copy-forward, stores first and main last (`zova.zig:667-808`) | The lock connection is a CWAL writer handle, so no commit happens during the copy. Sources are read through CWAL readers or read-only connections. The output set is a new set: it keeps CWAL mode, with fresh markers and epoch 1. Leftover `-wal`/`-shm` handling in `migration_publication.zig:125-140` also covers the `-cwal-*` sidecars. |
| `bind` / `unbind` / `split` | `bind` writes store meta and main's row as separate autocommit statements (`zova.zig:2841-2848`) | Needs the set open alone and clean (§3). `bind` becomes one CWAL transaction: marker table and meta in the store, row in main. `ATTACH`/`DETACH` use the internal bypass. |
| `validate`, `check --deep`, `doctor` | Read-only checks per schema | Also report CWAL state per member (marker, seqlock parity, broken flag, writer present), and run inside one `beginRead`. `doctor` reports a torn or broken set; it does not repair it. |
| `salvage` | Read-only source, new destination | On a set that refuses to open, salvage opens members read-only one at a time and reports which members hold the newest marker. The destination is not CWAL. |
| Fresh-build sessions | `beginImmediate` + commit | Commit through the CWAL path (§4). Usually main only, so single-file. |
| `restore`, `convertSqliteToZova` | Write a new file | Output is not CWAL. |

## 7. Storage compatibility

**Enabling is explicit and stored in the file.** CWAL mode is a property
of a set, turned on by an explicit call on a set opened alone. It is
recorded durably in three places:

- the marker table in every member;
- `_zova_meta` key `commit_protocol = 'cwal-1'` in main;
- a raw-readable flag (below).

Disabling checkpoints every member fully, drops the marker tables, clears
the key and the flag, and leaves the set in WAL mode.

**Detection before SQLite opens.** CWAL must run recovery, and capture
every member's `-shm` head, before SQLite maps any member (README,
"Foreign checkpoints"; R3). So the open path must know a set is CWAL
before opening it through SQLite, and `_zova_meta` cannot tell it: its
current value may be in the WAL. Decided (§12): the flag is SQLite's
`application_id` header field. Zova does not set it today (no references in
`src/`).
- The open path reads main's first 100 bytes raw. If `application_id`
  holds the CWAL value, it takes the CWAL path: lock files, `-shm` heads,
  recovery, then SQLite.
- After SQLite opens, the open path compares the raw value with
  `pragma application_id`. They differ only when a transition committed
  the flag to the WAL but crashed before checkpointing it. That case is
  handled under the transition rules below.

**Crash-safe transitions.** The flag is the single commit point of
enabling and of disabling. Both run on a set opened alone, by its one
writer.

Enable:
1. Create `_zova_cwal_marker` in every member and set `commit_protocol` in
   main. These may be separate commits.
2. Run a full `TRUNCATE` checkpoint of every member.
3. Set `application_id` in main: one single-file commit.
4. Run a `TRUNCATE` checkpoint of main, so the raw header shows the flag.

Disable:
1. Run recovery, then a full `TRUNCATE` checkpoint of every member.
2. Clear `application_id` (one commit), then run a `TRUNCATE` checkpoint
   of main.
3. Drop the marker tables and clear `commit_protocol`.

Reconciling at open:
- **Raw flag clear, SQLite flag clear.** A plain set. Marker tables or the
  meta key left without the flag are an interrupted enable, or the tail of
  a disable. The next writable open removes them. No CWAL commit ever ran
  without the raw flag, so nothing depends on them.
- **Raw flag clear, SQLite flag set.** Enable crashed between steps 3 and
  4. Every member was already checkpointed and holds its marker table, and
  no handle has opened the set as CWAL. The opener finishes step 4 and
  reopens on the CWAL path.
- **Raw flag set, SQLite flag clear.** Disable crashed between its commit
  and its checkpoint. The open runs the CWAL path, including recovery,
  then finishes the checkpoint and the rest of the disable.
- **Raw flag set, a member without its marker table.** Cannot happen by
  construction. The open refuses with `ProtocolViolation`.

A crash test must kill each transition at every step and check that the
next open lands in one of these rows.

**Member list before SQLite opens.** Main's `_zova_bound_stores` holds the
member list. Proposed order:
1. take `-gate` and `-alive` (keyed by main's path only);
2. read main's `-shm` head;
3. open main through the non-checkpointing recovery connection and read
   the bound-store rows and main's marker;
4. read each store's `-shm` head;
5. open the stores' recovery connections.

Opening main in step 3 maps main's `-shm`, which is safe because the opener
holds `-alive` exclusively and step 2 already captured the head. This order
needs its own test, with a foreign checkpoint of main and of a store.

**Format.** Adding `_zova_cwal_marker` changes the exact schema
validation, so a CWAL set is a storage-format change (AGENTS.md):
- exact-schema validation accepts the marker table only when
  `commit_protocol` is set;
- retained fixtures cover a format-14 set, and a CWAL set both clean and
  torn;
- `docs/storage-compatibility.md` records the rule.

Older Zova versions must not open a CWAL set as plain WAL: they would act
as outsiders and could checkpoint a torn commit. A format value they
classify as `unsupported_future` gives that for free
(`src/database/format.zig:12-46`).

**Decided (§12):** format 15, with 14→15 a no-op migration and CWAL
optional within 15. The bump lands with the open-path phase, not before.

**Other on-disk effects.**
- Five sidecars sit beside main: `-cwal-snap`, `-cwal-alive`,
  `-cwal-writer`, `-cwal-live` and `-cwal-gate`.
- CWAL needs every member in WAL mode with `synchronous=FULL` or `EXTRA`.
  Zova leaves `synchronous` at SQLite's default today
  (`docs/concurrency.md`). On a CWAL set it sets FULL and refuses lower.
- Read-only handles need a writable directory or existing sidecars, as
  WAL needs already.

## 8. Recovery

- **When.** At open, when the handle gets `-alive` exclusively (the
  prototype's rule). It runs before Zova's own open validation
  (bound-store ids and epochs, schema). The epochs are mirrored in the same
  transaction as the data, so a torn commit shows up as an epoch mismatch
  (`BoundStoreInvalid`) if validation runs first. With CWAL, recovery rolls
  the torn commit back, then validation passes.
- **Decision table.** Unchanged from REVIEW.md: the newest marker wins,
  and torn members are truncated to the start of their last commit. The
  open refuses with `ProtocolViolation` when the torn commit was already
  checkpointed by an outsider, or when markers are inconsistent. §3 adds
  the ownership and mapped-member checks, run before any truncation.
- **Repair lock (T6).** For a torn set, each member to truncate is
  opened in exclusive locking mode before the decision, and the lock is
  held until the truncation. Under it recovery rereads the marker and the
  `-shm` and compares the database file's root page with the torn commit's
  copy; a match means an outsider checkpointed it, and the open refuses
  with `ProtocolViolation`. An outsider holding the member open also makes
  the open fail with `ProtocolViolation` after a 1 s busy wait. Reads under
  the lock go through the lock connection's file handle, because closing
  any other descriptor of the file drops the process's POSIX locks. Clean
  opens skip this step.
- **Errors.** CWAL's `Broken` (a crash mid-commit while other handles have
  the set open) and `ProtocolViolation` (cannot repair safely) need Zova
  errors and C ABI result codes. Proposal: `error.CommitSetBroken` (close
  every handle and reopen) and `error.CommitSetNeedsRepair`, as additive
  C ABI codes. This is an ABI extension and needs approval with the format
  decision.
- **Late alone path.** Ported as-is, with the same-set heads check (T2).
- **`MemberOwned`.** New in T3. It gets its own Zova error and a
  dedicated additive C ABI result code, exposed the same way in every
  native binding (approved 2026-11-26, §12).
- **Debug log.** `CWAL_DEBUG` becomes a test-only option. Production
  builds keep no per-open log file.

## 9. Platform qualification

| Platform | Experiment | Evidence needed |
|---|---|---|
| Linux x86_64 (ext4, XFS, btrfs, tmpfs) | Supported | Prototype results at the baseline. Rerun through the integrated code (§11). |
| Linux ARM64 | Supported once T1 closes | Native CI run on `ubuntu-24.04-arm` |
| macOS (Apple Silicon) | Supported once T1 closes | Native CI run on `macos-latest`. Check `flock` and `mmap` behavior on APFS, and SQLite's `fullfsync` setting. |
| Windows | Enabling CWAL fails with `Unsupported` | Needs a Windows VFS shim, `LockFileEx` instead of `flock`, and Windows shared memory. Separate project (T5). |
| Browser WASM (OPFS) | Not applicable | Forces `journal_mode=DELETE`, has no shared memory, and does not support bound stores. |
| 32-bit targets | Enabling CWAL fails with `Unsupported` | The seqlock page needs 64-bit atomics. |
| Network filesystems | Unsupported, documented | WAL itself requires one host. |

**Build.** Snapshot reads need `SQLITE_ENABLE_SNAPSHOT`, which Zova's
SQLite builds do not set. That copy of SQLite is built in several places,
and the flag must match across all of them:
- `build.zig:3-18`;
- `bindings/rust/zova-sys/build.rs`;
- the generated-C metadata and checks (`scripts/generated-c-metadata.py`,
  `scripts/check-generated-c.sh`, the sanitizer variant);
- `scripts/build-go-windows-archive.sh`;
- the Python and JavaScript snapshots, through their sync tools.

The flag adds API without changing behavior. Proposal: set it on every
native build, rather than only in experimental builds, so the generated C
does not fork. CWAL itself sits behind a build option,
`-Dexperimental-cwal`, off by default. With the option off, enabling CWAL
returns `Unsupported`, and opening a CWAL set refuses rather than opening
it plainly.

## 10. Binding behavior

- **No new open option.** All native bindings open through the C ABI and
  none opens its own connection. A CWAL set is detected at open (§7), so
  opening needs no new option.
- **Enabling.** One new C ABI call, wrapped in each binding:
  `zova_database_set_commit_protocol(handle, ZOVA_COMMIT_PROTOCOL_CWAL |
  NONE)`. It is an additive ABI change.
- **Errors.** The two new result codes map to each binding's error type.
  A cross-file commit refused because it came from SQL text surfaces as the
  existing misuse/constraint error, with a message naming the transaction
  API.
- **Transactions.** Unchanged API. `begin` gives a cross-file snapshot on a
  CWAL set. `commit` writes markers. Raw `exec("COMMIT")` across files is
  refused (§4).
- **Threads.** Each C handle serializes its calls with its own mutex
  (`src/c_api/handles.zig:44-52`). CWAL's in-process registry is global and
  already handles several handles per process (concurrent-readers test).
- **Several SQLite copies in one process.** Rust, Python, JS and Go each
  link their own copy of SQLite. If the application opens a member file
  through another SQLite (Python's `sqlite3`, for example) and closes it,
  POSIX releases this process's fcntl locks on that file, including CWAL's
  connections' locks. This is SQLite's documented hazard. It also caused
  the bug in the first version of the R3 fix. The docs will say: do not
  open CWAL member files with another SQLite in the same process.
- **WASM.** Unchanged. `set_commit_protocol` is not exported.

## 11. Phases

Each phase lands with its tests. Nothing ships outside
`-Dexperimental-cwal` until the production gate.

1. **Build plumbing.**
   - `SQLITE_ENABLE_SNAPSHOT` everywhere (§9), with generated C regenerated
     and checked through the existing scripts.
   - The `experimental-cwal` build option.
2. **Port.**
   - `prototypes/cwal/src/cwal.zig` into `src/cwal/`: VFS registered under
     its own name, never as the default; fault and delay hooks only in
     test builds.
   - The prototype's unit-level behavior tests come with it.
3. **Open path.**
   - Header-flag detection, member list from main, ownership checks and
     recovery ordering (§3, §7, §8).
   - Enable and disable calls.
4. **Transactions.** Commit and read interception (§4) and the authorizer
   layer (§5).
5. **Maintenance.** The §6 table, one operation at a time.
6. **C ABI and bindings.** §10, with ABI and format decisions approved
   first.
7. **Qualification.**
   - Port `torture.py` to drive Zova's CLI or a Zig test driver, keeping
     the plain-WAL baseline oracle.
   - Rerun the crash, power-loss, readers, checkpoint, enforcement and
     N-file sections, plus the mutation sweep.
   - Close T1. Rerun the T2/T3 sections on the integrated build. Run the
     12–24 h endurance runs (T4).

## 12. Decisions (approved 2026-11-26)

1. **Format.** Storage format 15, with CWAL optional within it (§7).
2. **Detection.** SQLite's `application_id` header field is the raw CWAL
   flag (§7). Enabling and disabling CWAL must be crash-safe: a crash at
   any point of either transition must leave a set that opens correctly,
   either in the old mode or in the new one.
3. **C ABI.** The proposed additive error codes and
   `zova_database_set_commit_protocol` are approved (§8, §10).
4. **SQLite build.** `SQLITE_ENABLE_SNAPSHOT` is enabled in all native
   builds (§9).
5. **Baseline tag.** `cwal-prototype-baseline` at `77c5b5a` (§1).
6. **`MemberOwned` ABI code** (2026-11-26, after T2/T3). A dedicated
   additive C ABI result code, exposed consistently across the native
   bindings (§8).
7. **Tracking** (2026-11-26, after T2/T3). Alias-safe ownership (T7) must
   close before production release. R6 (T6) is investigated with a
   deterministic reproducer before any fix. The explicit-state model
   covers member ownership and its interaction with recovery. Raw
   artifacts of every run are kept. Integration continues while T1, T4,
   T6 and T7 stay tracked. Windows (T5) stays deferred. Production release
   is not authorized.

Scope now: T2 and T3 only, closed with implementation and test evidence in
the prototype before the broader integration starts. T1, T4 and T5 stay
tracked and deferred: no endurance runs, no platform qualification and no
Windows work at this stage. Raw test results are kept under
`prototypes/cwal/results/` from now on.
