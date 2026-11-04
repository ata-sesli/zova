# Storage format 13: chunk-reference index (#195) and incremental auto-vacuum (#197)

Plan written before #193 and #194 landed, kept below as approved. The
implementation report and measurements are in the next two sections; where the
implementation differs from the plan, the report says so.

**Approved by the maintainer (2026-11-05):**
1. The bump is 12 → 13 (`format_version = "13"`, minimum migratable format
   stays 9), with format-12 fixtures retained from the unmodified `v1.3.0`
   build.
2. Reclaim is option B: an explicit bounded `reclaimSpace` call plus
   `zova reclaim`. Migrated files keep `auto_vacuum = none`; `zova compact` is
   the conversion path; both modes are valid in format 13.
3. Reclaim's C ABI and bindings follow in a separate PR right after the
   format PR.

## Implementation report

Branch `work/format-13-195-197`, on `main` at `dbf3596` plus the retained
format-12 fixtures.

- **Index (#195).** `object_chunks_chunk_hash_index_sql` in `src/object.zig`;
  `initializeObjectSchema` creates it in every new file (main, object, vector
  and graph stores, `:memory:`, and `convertSqliteToZova`). No delete
  statement changed: the plan regressions show both the `not exists` check and
  the `_zova_chunks` foreign-key child check use `COVERING INDEX
  _zova_object_chunks_chunk_hash_idx (chunk_hash=?)` in `main.` and
  `object_store.`.
- **Validation.** `validateObjectSchemaExpected` accepts formats 11 and 12 only
  without the index and format 13 only with the exact index
  (`validateObjectChunkIndex`, also run for an attached object store). The
  10 → 11 step now validates against format 11 explicitly.
- **Migration.** `migrateFormat12To13` creates the index inside the existing
  per-step transaction and leaves `auto_vacuum` unchanged.
- **Auto-vacuum (#197).** `enableIncrementalAutoVacuum` runs before the first
  table in `Database.create` (after `applyCreateOptions`, so page size still
  applies) and in the three store constructors; `compactTo` sets
  `pragma main.auto_vacuum = incremental` before `VACUUM INTO`. Backup,
  restore, migrate and convert keep the source's mode.
- **Reclaim.** `Database.reclaimSpace(ReclaimOptions)` in `src/zova.zig`, with
  the step loop in `src/database/reclaim.zig`, and `zova reclaim [--json]
  [--max-pages <n>] <file.zova>` in `src/cli/maintenance.zig`. Two deviations
  from the sketch:
  - it returns a fixed-size `ReclaimResult` (at most four members) instead of
    an allocated slice, so it takes no allocator;
  - it reports no progress events; `--max-pages` bounds one run instead.
  It refuses only an open write or explicit transaction
  (`sqlite3_get_autocommit == 0`); an open `ObjectReader` is allowed, and the
  test reads verified bytes through one across a reclaim.
- **Not in this PR (as approved):** `zova_database_reclaim` and the binding
  wrappers.

## Measurements (2026-11-05)

Harness: `bench/object_delete_195.zig` (`zig build build-object-delete-195
-Doptimize=ReleaseFast`), one sample per process. Apple M1, 16 GiB, APFS on an
external USB SSD (`/Volumes/wipesides`), SQLite 3.53.4, default rollback
journal, 4 KiB pages, `foreign_keys = on`. The payload is 64 MiB of
deterministic incompressible bytes written in 1 MiB `ObjectWriter.write`
calls: `deduplication` (FastCDC) gives 7,157 chunks, `streaming` gives 64.
Background rows are 1,000-row synthetic objects with one 1-byte chunk per
row, loaded untimed. `no-index none` is the format-12 schema, `index none` a
migrated format-13 file, `index incremental` a new format-13 file. Medians of 5
runs, except the `no-index` 1M FastCDC cell, which is a single run (721 s).

Driver: a zsh loop over the matrix that deletes the scratch file between runs
(`<prefix>/bin/zova_object_delete_195_benchmark <db> <index|no-index>
<none|incremental> <rows> <profile> 67108864`).

### Delete (#195): one `deleteObject` of the 64 MiB object

| Background rows | Profile | Format 12 (no index) | Format 13, `none` | Format 13, `incremental` | Speedup |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | FastCDC | 0.101 s | 0.109 s | 0.106 s | ≈1× |
| 0 | streaming | 0.0166 s | 0.0169 s | 0.0090 s | ≈1× |
| 100,000 | FastCDC | 67.0 s | 0.106 s | 0.105 s | ≈640× |
| 100,000 | streaming | 0.642 s | 0.0168 s | 0.0092 s | ≈38× |
| 1,000,000 | FastCDC | 721.7 s (1 run) | 0.112 s | 0.111 s | ≈6,500× |
| 1,000,000 | streaming | 6.40 s | 0.0172 s | 0.0095 s | ≈370× |

Without the index the delete cost is (chunks deleted) × (manifest rows): every
chunk deletion scans `_zova_object_chunks` twice (the `not exists` check and
the foreign-key child check). With the index it is flat in the manifest size.

### Insert cost of the index

| Background rows | Profile | Put, no index | Put, index (`none`) | Change |
| ---: | --- | ---: | ---: | ---: |
| 0 | FastCDC | 0.354 s | 0.361 s | +1.9% |
| 0 | streaming | 0.161 s | 0.161 s | +0.4% |
| 100,000 | FastCDC | 0.387 s | 0.435 s | +12% |
| 100,000 | streaming | 0.276 s | 0.279 s | +1.1% |
| 1,000,000 | FastCDC | 0.414 s (1 run) | 0.380 s | −8% |
| 1,000,000 | streaming | 0.238 s | 0.241 s | +1.2% |

The streaming cells (64 index entries) show the index cost itself, about 1%.
The FastCDC cells add 7,157 index entries per object; their spread between
background sizes (+12% and −8%) is larger than any consistent index effect, so
the cost there is within run-to-run variation (single runs in the 100,000-row
indexed cell range from 0.41 s to 0.48 s).

Index size, from `dbstat`: 47,431,680 bytes for 1,007,157 manifest rows, i.e.
**47.1 bytes per manifest row** (32-byte hash plus rowid key and b-tree
overhead). A 64 MiB FastCDC object adds about 315 KiB of index; a 64 MiB
streaming object adds one page.

### Auto-vacuum (#197)

| Background rows | Profile | Put, `none` | Put, `incremental` | Change |
| ---: | --- | ---: | ---: | ---: |
| 0 | FastCDC | 0.361 s | 0.388 s | +7.6% |
| 0 | streaming | 0.161 s | 0.259 s | +61% |
| 100,000 | FastCDC | 0.435 s | 0.401 s | −8% |
| 100,000 | streaming | 0.279 s | 0.272 s | −2.5% |
| 1,000,000 | FastCDC | 0.380 s | 0.383 s | +0.9% |
| 1,000,000 | streaming | 0.241 s | 0.242 s | +0.4% |

- The one clear cost is the streaming put into an empty file: +0.1 s for 64
  MiB. With 100,000 or more background rows the difference disappears. The
  investigation below finds the cause: macOS write-behind, not extra work in
  incremental mode.
- Delete is faster in incremental mode (streaming 0.009 s vs 0.017 s); FastCDC
  deletes are unchanged.
- **Reclaim:** releasing all ≈17,900 free pages (≈70 MiB) after the delete in
  1,024-page transactions takes 0.10–0.14 s in every cell (≈500–700 MiB/s), and
  the file is truncated by the released pages (the bench does not record file
  size; `src/database_space_tests.zig` checks that `page_count` drops). In
  `none` mode the same pages stay on the
  freelist (`zova reclaim` reports 0 released).
- Not measured, compared with the plan: 256 MiB payloads, and `step_pages`
  16,384 (the CLI always uses 1,024).

### Investigation: the empty-file streaming put

The extra time is the commit's database `fsync`, not CPU or extra I/O. The
write-behind of a stream of appends stops after one rewrite of an
already-written page behind the write head, so the data is still dirty at
commit. In a new incremental file that page is page 2, the first pointer-map
page. In every file with existing b-tree pages, `none` mode rewrites such pages
too and pays the same flush. The `none` empty-file cell was the outlier.

Evidence (64 MiB streaming put, indexed schema; tools in the session scratch
directory, not retained: an `fsync`/`pwrite` interposer loaded with
`DYLD_INSERT_LIBRARIES`, and a replayer of logged write offsets):

1. **Repeat, 10 runs per cell, median `put_seconds`:**

   | Disk | Background rows | Profile | `none` | `incremental` | Change |
   | --- | ---: | --- | ---: | ---: | ---: |
   | internal (APFS) | 0 | streaming | 0.170 s | 0.178 s | +5% |
   | internal (APFS) | 0 | FastCDC | 0.304 s | 0.326 s | +7% |
   | internal (APFS) | 100,000 | streaming | 0.183 s | 0.177 s | −3% |
   | internal (APFS) | 100,000 | FastCDC | 0.290 s | 0.293 s | +1% |
   | external USB SSD | 0 | streaming | 0.163 s | 0.285 s | +75% |
   | external USB SSD | 0 | FastCDC | 0.382 s | 0.413 s | +8% |
   | external USB SSD | 100,000 | streaming | 0.285 s | 0.290 s | +2% |
   | external USB SSD | 100,000 | FastCDC | 0.415 s | 0.404 s | −3% |

   The external `none` cell with 100,000 rows (0.285 s) equals the
   incremental empty-file cell: the `none` empty-file put is the fast
   exception.
2. **CPU is equal.** user 0.16–0.17 s in both modes; sys 0.09–0.10 vs
   0.11–0.12 s.
3. **The gap is sync-bound.** With `pragma synchronous = off` the two modes are
   equal (0.150 vs 0.151 s), and with `journal_mode = memory` incremental is
   not slower. A 256 MiB page cache (no spill) does not remove it.
4. **Same syncs and bytes.** During the put both modes do 2 journal `fsync`s and
   1 database `fsync`. They write 16,409 vs 16,430 distinct pages, each once:
   the extra 21 are pointer-map pages. Journal bytes are a few KiB in both.
5. **The commit `fsync` is what differs:** 3.3–3.5 ms (`none`) vs 28–91 ms
   (incremental) internal, and 20 ms vs 132–149 ms external. The write phase
   is not slower: in the replays below it takes 63–83 ms (incremental) vs
   75–108 ms (`none`). With 100,000 background rows the
   commit `fsync` is 129–132 ms in `none` and 130–145 ms in incremental.
6. **Replaying the logged write sequences outside SQLite reproduces it.** The
   `none` sequence gives a 15–20 ms fsync on the external disk and the
   incremental sequence 116–149 ms.
   - Adding to the `none` sequence one rewrite of page 2 at the first spill
     raises it to 137–150 ms.
   - Removing that single page-2 rewrite from the incremental sequence lowers it
     to 16–20 ms.
   - A synthetic stream of appends shows the same effect with one rewrite of an
     already-written page at any distance of 768 pages or more (120–150 ms),
     but not with later fills of skipped pages (holes).
7. **Setup order is not involved.** The pragma runs before the first table, so
   it only sets the header flag. There is no `VACUUM` or rewrite on create; the
   new file has 9 pages instead of 8 (the pointer-map page).

Conclusion: incremental mode does not add I/O. It loses the overlap between
writing and flushing that an append-only first fill of a new `none` file gets
on macOS. The write volume and sync count are the same, and the effect
disappears once the file has content, in both modes. The size of the effect
depends on the device: +5% on the internal SSD, +75% on the external one. Linux
writeback was not measured.

No cheap fix in Zova: the pointer-map page is SQLite's, and which pages spill
when is the pager's decision. Alternatives for the maintainer:

| Option | Effect on this cost | Cost |
| --- | --- | --- |
| Keep `incremental` for every new file (current PR) | about 0.1 s once, on the first large put into an empty file on slow storage | none beyond that |
| `none` for new main databases, `incremental` only for object, vector and graph stores | removed for main files only; a new object store's first fill keeps it | an object kept in the main file cannot be reclaimed in place without `zova compact` |
| `none` everywhere | removed | drops #197's in-place reclaim; `zova compact` stays the only path |

Recommendation: keep `incremental` for every new file. The effect is a one-time
loss of write-behind overlap on the first fill of a new file, not a steady-state
throughput cost. With existing content, the measured put cost is within
−3% to +8% in every cell.

Resources: the whole matrix ran in 26 minutes on one core; the largest scratch
file was about 250 MB and each was deleted after its run.

## Format numbering

The authorization speaks of a bump "from 11 to 12", following the issue texts.
On `main` the current storage format is already **12**: `src/version.zig`
`format_version = "12"` since `2ad543e` (Zova 1.2.0, vector change tracking),
and `docs/storage-compatibility.md` documents migrations of formats 9, 10 and 11
to format 12. Issues #195 and #197 say "storage format 11" in error.

This plan therefore bumps **12 → 13**, keeps `minimum_migratable_format = "9"`
(`src/database/types.zig`), and retains new **format-12** fixtures. The package
version, ABI version and SQLite version stay unchanged.

## Scope

1. **#195:** add `_zova_object_chunks_chunk_hash_idx` on
   `_zova_object_chunks(chunk_hash)`.
2. **#197:** create new files with `auto_vacuum = incremental`, and add bounded
   reclaim through `pragma incremental_vacuum`.
3. The format-13 bump that #195 needs, with a migration step, exact
   validation, retained format-12 fixtures and documentation.

Out of scope:
- the integer-reference manifest layout from #92;
- an in-place, index-only migration step;
- moving chunk collection out of the delete transaction (#195, "Write
  transactions stay long").

## #195: chunk-reference index

### Schema

```sql
create index _zova_object_chunks_chunk_hash_idx on _zova_object_chunks(chunk_hash)
```

- **One index serves both scans.** It covers the `not exists` reference check
  in `deleteUnreferencedCandidateChunks` and `deleteObjectChunk`, and SQLite's
  foreign-key child check for `_zova_chunks` deletes. It also covers the
  writer's loose-chunk cleanup.
- **Naming** follows the graph indexes (`_zova_graph_edges_from_node_idx`).
- **Placement:** an `object_chunks_chunk_hash_index_sql` constant next to the
  object schema constants in `src/object.zig`. That file is Track A's, and its
  #193 PR edits it, so this edit waits for #193. It is limited to the constant,
  plus any statement-text change a plan test shows is needed.

### Where it is created

| Path | Change |
| --- | --- |
| `initializeObjectSchema` (`src/database/lifecycle.zig`) | Execute the index after the three tables. Every new file gets it (main, object, vector and graph store, `:memory:`), because every file carries the object tables. |
| Migration 12 → 13 (`src/database/migration.zig`) | `migrateFormat12To13` creates the index where `_zova_object_chunks` exists, like `migrateFormat11To12` does for vector tables. It runs inside the existing per-step transaction, so a failure rolls back. |
| `migrateFormat10To11` | Unchanged. It recreates the format-11 tables, and the 12 → 13 step adds the index later in the chain. |
| `convertSqliteToZova` | Covered through `initializeZovaSchema`. |

### Validation

Today, validation compares table SQL only and never inspects indexes. That is
why the index cannot simply appear without a format bump: a format-12 reader
would accept a file that has it, and a format-13 reader must be able to rely on
it.

- Add `validateObjectChunkIndex(db, prefix)`. It compares the
  `sqlite_schema` row (`type = 'index'`, `name`, `tbl_name`) with the constant
  through the existing `schemaSqlEqual`, following `validateVectorMaintenance`.
- Call it from `validateObjectSchemaExpected` when the expected format is 13 or
  newer. Format 12 must *not* have the index, so a source claiming format 12
  with the index fails migration preflight, as other schema drift does.
- Also call it for an attached bound object store, from
  `validateAttachedObjectSchema`.
- A missing index or different index SQL on a format-13 file gives
  `NotZovaDatabase`.

### Query plans

Add plan regressions with `src/query_plan_test_support.zig`, following the
graph cases. The delete reference check and the foreign-key child check must
show `SEARCH _zova_object_chunks USING COVERING INDEX
_zova_object_chunks_chunk_hash_idx (chunk_hash=?)` and no `SCAN`. Cover both
main and `object_store.` schemas.

### Migration cost

The step builds the index on the staged copy. That costs one read of the
manifest table, not of the chunk data. The full copy that every migration
already makes stays the dominant cost at media scale; see #195,
"Migration is expensive".

## #197: incremental auto-vacuum

### SQLite behavior, verified on SQLite 3.53.4

The probe was a Python `sqlite3` module linked against 3.53.4. The vendored
`vacuum.c` agrees: `sqlite3BtreeSetAutoVacuum(pTemp, db->nextAutovac >= 0 ?
db->nextAutovac : sqlite3BtreeGetAutoVacuum(pMain))`.

| Operation | Destination mode |
| --- | --- |
| Backup API (`sqlite3_backup_*`) | Always the source's mode. A `pragma auto_vacuum` set on the empty destination first is overwritten. |
| `VACUUM INTO` | The source's mode, unless the connection ran `pragma auto_vacuum = X` earlier. Then it is `X`, for every later `VACUUM`/`VACUUM INTO` on that connection and every schema (`nextAutovac` is per connection). On a non-empty file the pragma returns no error and does not change that file. |
| New empty file | Whatever `pragma auto_vacuum` says before the first table is created. |
| `pragma incremental_vacuum(N)` | Releases up to N free pages and truncates the file. A read statement open on another table of the same connection keeps reading correct rows, and `integrity_check` stays `ok`. |

### What each Zova path produces

| Zova path | Mechanism | Format-13 result |
| --- | --- | --- |
| `Database.create`, `createObjectStore`, `createVectorStore`, `createGraphStore` | new file | **incremental**: set right after `applyCreateOptions` (page size), before any table |
| `splitObjectStore` / `splitVectorStore` / `splitGraphStore` | creates the store, then copies rows | incremental (to be confirmed by a test) |
| `convertSqliteToZova` | backup API from the user's SQLite file | the user file's mode (unchanged; documented) |
| `backupTo`, `restoreBackup`, restore into memory | backup API; bound stores inlined by row copy | the source main's mode |
| `compactTo` | `VACUUM INTO`; bound stores inlined by row copy | **incremental**: run `pragma main.auto_vacuum = incremental` on the connection before `VACUUM INTO`. This is the conversion path for older files. |
| `migrate` | stepped backup API per member (`copyForwardMember`) | the source member's mode (see below) |

**`compactTo` side effect.** The pragma persists on the caller's connection.
Any later `VACUUM` on that connection produces incremental files too. Because
that is the format-13 creation policy anyway, this plan documents the effect
rather than working around it with a second connection.

### What existing format-12 stores get on migration

They keep `auto_vacuum = none`.

- Converting a file means rewriting it: a full `VACUUM` of the staged copy, or
  replacing the stepped backup copy with `VACUUM INTO`.
- A `VACUUM` of the staged copy doubles the migration's write volume and
  temporary space. At media scale, migration already copies the whole set (#195).
- `VACUUM INTO` would give up the 1024-page progress steps and the
  one-snapshot copy that #199 just added. It also rebuilds every b-tree
  instead of copying pages.
- An operator who wants space reclaim on an existing set runs `compactTo`
  (`zova compact`). It already rewrites everything and now produces an
  incremental file. `split*` can then restore the bound layout.

Because both modes are valid in format 13, validation does not inspect
`auto_vacuum`. The mode is a creation default, not a format invariant. The
reclaim call reports the mode, so callers can tell when only `compact` helps.

### Overhead to measure

- Incremental mode keeps pointer-map pages: about 1 page per 819 at 4 KiB
  (0.12%).
- Page allocation and freeing update the pointer map, so ingest and delete
  throughput are measured in both modes (see "Measurements").

## Reclaim timing (decided: option B)

#197 offers two options. Both are viable. **I recommend option B**, an explicit
bounded maintenance call plus a CLI command.

**Option A: bounded reclaim inside each `deleteObject`.**
- Reclaiming N pages moves up to N pages of other data and journals them,
  inside the delete's write transaction or the caller's savepoint.
- With a small N, a large delete never catches up. A 40 GB object frees about
  10 million 4 KiB pages; at 1024 pages per delete, that is about 10,000 later
  deletes before the space is back.
- With an unbounded N, the delete holds the write lock while it moves up to
  the freed amount of data. That is the cost #195 is trying to remove, and the
  same tradeoff as `auto_vacuum = full`, which #197 already rejected.
- It also runs inside caller transactions that may roll back, and inside
  ObjectWriter cancel paths. That would be wasted work there.

**Option B: explicit maintenance call (recommended).**
- The caller chooses when to pay for the page moves.
- Each step is its own short transaction. Other writers interleave, and an
  interruption keeps the steps already committed.
- It covers every member of a bound set, not only objects.
- `deleteObject` keeps its current cost, with the index from #195.
- Progress reporting from #199 fits it directly.
- Option A can be added later as an opt-in setting without changing format 13.

### Option B sketch

```zig
pub const ReclaimOptions = struct {
    /// Most pages released by this call across all members; 0 releases all.
    max_pages: u64 = 0,
    /// Pages released per transaction, so other writers can run in between.
    step_pages: u32 = 1024,
};

pub const ReclaimedMember = struct {
    member: ProgressMember,          // main, object_store, vector_store, graph_store
    auto_vacuum: enum { none, full, incremental },
    page_size: u32,
    pages_released: u64,
    free_pages_left: u64,
};

pub fn reclaimSpace(self: *Database, allocator: std.mem.Allocator, options: ReclaimOptions) Error![]ReclaimedMember
```

- **Steps.** Each step runs `pragma <schema>.incremental_vacuum(step_pages)`
  in its own `begin immediate` transaction.
- **Transactions.** The call rejects an active caller transaction with the
  existing transaction-active error, because it owns its step boundaries.
- **Modes.** A member in `none` mode is reported with `pages_released = 0`.
  `full` mode needs no reclaim.
- **WAL.** In WAL mode the file shrinks only at a checkpoint. The call
  documents this rather than forcing `wal_checkpoint(TRUNCATE)`.
- **CLI:** `zova reclaim [--max-pages N] [--json] <db.zova>`, next to
  `compact`. It prints each member's mode, pages released, pages left and
  bytes. A `none` member points at `zova compact`.
- **C ABI and bindings.** `zova_database_reclaim` and the Rust, Go, Python and
  JS wrappers are a second, smaller choice. They could go in the format PR or
  in a follow-up right after it. I recommend the follow-up, so the format PR
  stays reviewable. The bindings' database files are not Track A's object
  wrappers.

## Format-bump checklist (`AGENTS.md`)

- `src/version.zig`: `format_version = "13"`. `minimum_migratable_format`
  stays `"9"`.
- `src/database/migration.zig`: register `{12, 13, migrateFormat12To13}`.
- `src/database/validation.zig`:
  - `validateObjectSchemaExpected` accepts 11 and 12 without the index, and 13
    with it.
  - The attached object store needs the same check.
- **Retained fixtures, format 12.**
  - Produce them with the unmodified `v1.3.0` tag before format 13 is
    activated, as the format-11 set was produced with the baseline CLI. Build
    the tag's CLI in a temporary worktree, then:
    - migrate `empty-main-format-11.zova`, `format-11.zova` and the
      `bound-main-format-11` set to format 12;
    - create `empty-vector-store-format-12.zova` with that build.
  - Never hand-edit them.
  - Record the commands and hashes in this note, and add the hashes to
    `tests/fixtures/fixtures.sha256`.
- `src/storage_compat_check.zig`: add the three format-12 migration sets. The
  check derives classification from the version constants.
- **Tests that hard-code the current format** (the same set `2ad543e`
  touched):
  - `tests/cli.zig`, `tests/c_abi_smoke.c`;
  - `src/migration_tests.zig`, `src/migration_red_tests.zig`;
  - Rust `zova/tests/migration.rs`, Go `migration_test.go`, Python
    `test_migration.py`;
  - JS `load.test.ts` and runtime smokes, WASM `release-gate.test.mjs`.
- `docs/storage-compatibility.md`:
  - current format 13;
  - "Migrating formats 9, 10, 11 and 12 to format 13";
  - add the index and the auto-vacuum policy to the list of intended private
    differences;
  - say what migration, backup, compact and convert produce;
  - keep every historical statement.
- Binding READMEs that show `app-format-12.zova` examples.
- Regenerate local generated C and Rust platform sources, and re-sync the
  Python snapshot as local checks. They are untracked, so there is nothing to
  commit.

## Retained format-12 fixtures (produced 2026-11-05)

Produced before format 13 was activated, with the CLI built from the
unmodified `v1.3.0` tag (`a30581e`, `zova 1.3.0`, `format_version = "12"`):

```sh
git worktree add --detach <tmp>/v130 v1.3.0
(cd <tmp>/v130 && zig build -Doptimize=ReleaseSafe)
# In one directory holding copies of the retained format-11 fixtures, so the
# bound-store paths stay bare relative names as in the format-11 set:
zova migrate --json empty-main-format-11.zova empty-main-format-12.zova
zova migrate --json format-11.zova format-12.zova
zova migrate --json bound-main-format-11.zova bound-main-format-12.zova
zova vector-store create --json empty-vector-store-format-12.zova
```

- Every migration reported `verified: true`. The format-11 copies stayed
  byte-identical.
- Every output has `format_version = 12`, `auto_vacuum = 0` (none) and
  `integrity_check = ok`.
- Row counts match the format-11 sources table by table.
- `bound-main-format-12.zova` binds `bound-main-format-12.{objects,vectors,graphs}.zova`.

| File | SHA-256 |
| --- | --- |
| `bound-main-format-12.graphs.zova` | `6234bd66c9a94d084589ef2bf56610a9f0b7fec8e7f25df3abeae46a379df2c4` |
| `bound-main-format-12.objects.zova` | `270a49cfce82568b9991b4d82956503ec8ccf8ddbba3b64ce437576fc1e538fb` |
| `bound-main-format-12.vectors.zova` | `ba77977909c1babddb19e6f6ea2dd8ef021cd1defe4a86ca315b8453dde4d169` |
| `bound-main-format-12.zova` | `39a10e6acf8586f43ffce7d9196a9767c7fc9c5c09670618db53d2320f5893ba` |
| `empty-main-format-12.zova` | `1b62b27c26afcfb7ffe9a4b21dee7ee3de873b4ab1a6b87af4d75151b0379c60` |
| `empty-vector-store-format-12.zova` | `46418f825b434cd3eeb5f8d5c1c7f4d45a5768d37944c6976a631a3887916c09` |
| `format-12.zova` | `39eebff70511277466aa0a66c271f00f5c1d68c7720c9043b506a673f43fc922` |

`zig build check-storage-compat` on current `main` with these files pinned:
154 checks, 0 failures. They classify as `current` until format 13 is active.
The format-12 migration sets are added to `src/storage_compat_check.zig`
together with the format-13 bump.

## Tests, in TDD order

1. **Validation.**
   - Format-13 fresh files have the index, and its SQL matches exactly.
   - Dropping it, or altering its SQL, makes open fail with
     `NotZovaDatabase`, for main and for a bound object store.
   - A format-12 source carrying the index fails migration preflight.
2. **Migration.**
   - Each format-12 fixture set migrates to 13 with the index in every member
     that has object tables, and the source stays byte-identical.
   - The step is atomic under the existing fault points.
   - Migrated members keep `auto_vacuum = none`.
3. **Query plans:** delete and foreign-key checks use the index in main and
   `object_store.`.
4. **Delete semantics with the index:**
   - shared chunks survive;
   - unreferenced chunks are collected;
   - rollback inside a caller transaction restores everything;
   - bound object store parity.

   The existing object delete tests already cover most of this; extend them
   where a case is missing.
5. **Auto-vacuum.**
   - `create`, `createObjectStore`/`VectorStore`/`GraphStore`, `split*` and
     `compactTo` produce incremental files.
   - `backupTo`, `restoreBackup`, `convertSqliteToZova` and `migrate` keep the
     source's mode. Each case asserts the mode explicitly.
   - A custom `page_size` still applies.
6. **Reclaim (after the decision).**
   - Store and delete a 256 MiB streaming object, reclaim, and check that
     `page_count` drops to about the remaining data.
   - `max_pages` and `step_pages` are honored.
   - A `none` member reports zero.
   - An active transaction is rejected.
   - An `ObjectReader` open during reclaim still reads verified bytes.
   - `integrity_check` is `ok`.
   - Bound-set members are covered.
   - The CLI gets text and JSON cases.

Focused suites: `zig build test-objects`, `test-migration`, `test-c-api`,
`check-storage-compat`, then `zig build test` and the binding suites that
hard-code the format.

## Measurements

These go in the PR. The harness is a new bounded
`bench/object_delete_195.zig`, modeled on `bench/object_writer_196.zig`:
production schema, `foreign_keys = on`, default rollback journal, 4 KiB pages,
deterministic payloads. Baseline and candidate run on the same build,
filesystem and fixture, with the median of 5 runs reported. The external
benchmark volume (`/Volumes/wipesides`) holds the scratch files.

- **Delete (#195).** One `deleteObject` of a 64 MiB streaming object (64
  chunks) with 0, 100,000 and 1,000,000 background manifest rows, without and
  with the index.
- **Insert cost (#92).**
  - `putObject` and `ObjectWriter` ingest of 64 MiB FastCDC (about 7,000
    chunks) and 256 MiB streaming objects, without and with the index, at 0 and
    1,000,000 background rows.
  - Index bytes per manifest row, from `dbstat`.
- **Auto-vacuum (#197).**
  - Ingest and delete time in `none` versus `incremental`.
  - File size after deleting a 256 MiB object, then after `reclaimSpace`.
  - Reclaim throughput for `step_pages` 1024 and 16384.
- **Resources.** Expected peak disk is under 2 GB of scratch space, and the
  whole matrix should take a few minutes. I will state the measured figures
  before running anything larger.

## Sequencing

1. Wait for #193 (Track A, edits `src/object.zig`) to merge.
2. #194: streaming verification PR, from my saved patch.
3. This change, from `origin/main` after both, on `work/format-13-195-197`.
   - First produce the format-12 fixtures from `v1.3.0`.
   - Then measure the baseline with the bench harness on unmodified `main`.
   - Then follow the TDD order above.
4. The PR goes against `main` with `Fixes #195` and `Fixes #197`. It also
   resolves the optional part of #182, which stays open only for that index;
   closing #182 is the maintainer's call.

## Open questions

- Reclaim timing: decided, option B.
- Reclaim C ABI and bindings: decided, a follow-up PR.
- Should `zova inspect`/`stats` show `auto_vacuum` and `freelist_count`?
  That is not required by #197; `zova reclaim` reports both.
