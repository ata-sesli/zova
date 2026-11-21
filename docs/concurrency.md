# Concurrency With Multiple Handles

One Zova database handle is one SQLite connection, and calls on it run one at a
time (see [Thread safety](../API_STABILITY.md#thread-safety)). Real concurrency
comes from opening several handles on the same `.zova` file. This guide gives a
recommended setup for one writer and several readers, and states what Zova
guarantees under it.

Everything here follows ordinary SQLite locking. Zova adds no locking of its
own between handles, changes no SQLite default, and starts no threads. The
behavior described below is covered by `src/database_concurrency_tests.zig`.

## Recommended setup

Use one handle for all writes and one handle per concurrent reader.

1. **Writer handle.** Open one read-write handle. Start write transactions with
   an immediate transaction (`beginImmediate`, `BEGIN IMMEDIATE`), so that lock
   conflicts surface when the transaction starts and not in the middle of it.
2. **Reader handles.** Open each reader with the read-only open option.
   Read-only handles cannot write by accident, and each one reads
   independently of the others.
3. **Busy timeout.** Set a busy timeout on every handle. Without one, a handle
   that meets a lock fails at once with a busy error (`error.Busy`,
   `ZOVA_BUSY`). With one, it waits up to that long for the lock to clear.
4. **Journal mode.** For a database without bound stores, switch the file to
   WAL once, after creating it:

   ```sql
   pragma journal_mode=wal;
   ```

   The journal mode is stored in the file. Later opens, from any handle or
   process, use it without setting it again. For a database with bound stores,
   read [Bound stores](#bound-stores) before choosing.

Zova leaves `synchronous` at SQLite's default. SQLite documents that
`synchronous=NORMAL` in WAL mode keeps the file consistent but can lose the
most recent commits on power loss. That trade is the application's to make.

The busy timeout is available at open and on an open handle:

| Surface | Open option | On an open handle |
| --- | --- | --- |
| Zig | `OpenOptions.busy_timeout_ms` | `Database.setBusyTimeout` |
| C ABI | `busy_timeout_ms` in the open-with-options request | `zova_database_set_busy_timeout` |
| Rust | `OpenOptions::busy_timeout_ms` | `set_busy_timeout` |
| Go | `OpenOptions.BusyTimeoutMS` | |
| Python | `busy_timeout_ms` | |
| JavaScript | `busyTimeoutMs` | `setBusyTimeout` |

## What readers see

These rules hold for SQL rows, objects, vectors, graphs and key-value entries
alike, because all of them are rows in the same SQLite files.

### WAL mode

- **Readers do not block the writer, and the writer does not block readers.** A
  reader can read while a write transaction is open and while it commits.
- **Readers see only committed data.** Writes inside an open write transaction
  are visible to the writer handle only.
- **A read outside a transaction sees the latest commit** at the moment that
  call starts.
- **A read transaction keeps one view.** After a reader begins a transaction
  and reads, later commits by the writer stay invisible to it until the reader
  ends the transaction. Bound stores add an exception, described below.

### Rollback-journal mode (the default)

- **The writer can start and stage changes beside open readers,** and those
  readers keep seeing the committed state.
- **The writer's commit needs exclusive access.** While any reader holds a read
  transaction open, the commit fails with a busy error, or waits for the busy
  timeout. The write transaction stays open, and the commit succeeds once the
  readers finish.
- **Readers wait in turn** while a commit is being written.

In this mode long-running readers delay writes. That is the reason WAL is
recommended for single-file databases.

### Two writers

In either journal mode only one handle can hold a write transaction. A second
handle that starts an immediate transaction or performs a write fails with a
busy error at once when it has no busy timeout, and waits for the first writer
to finish when it has one. Funnel writes through one handle to avoid this.

## Bound stores

A bound object, vector or graph store is a separate file attached to the main
database. Each file has its own journal mode, so each one is switched
separately:

```sql
pragma main.journal_mode=wal;
pragma object_store.journal_mode=wal;
pragma vector_store.journal_mode=wal;
pragma graph_store.journal_mode=wal;
```

With bound stores, WAL mode gives up two guarantees that rollback-journal mode
keeps. Choose with these in mind.

**1. A transaction that spans files is not atomic across a crash in WAL mode.**
SQLite commits a multi-file transaction atomically only in rollback-journal
mode. In WAL mode each file is updated atomically on its own, and SQLite
documents that a crash or power loss during the commit can leave some files
with the transaction and others without it. A Zova write that touches the main
database and a bound store in one transaction (for example a SQL row and the
object it refers to) is such a transaction.

**2. A read transaction can see files at different points in time in WAL
mode.** A reader fixes its view of each file when it first reads that file
inside the transaction. If the writer commits one transaction across the main
file and a store between the reader's first read of the main file and its
first read of the store, that reader sees the main file from before the commit
and the store from after it. Each single call still sees only committed data.

In rollback-journal mode neither happens: a multi-file commit is atomic, and it
cannot complete while a reader holds a read transaction on a file it changes.

Recommendation:

- **No bound stores:** use WAL.
- **Bound stores, and transactions that must stay consistent across files:**
  stay in rollback-journal mode, keep reader transactions short, and set a busy
  timeout on the writer.
- **Bound stores, with concurrency more important than cross-file
  consistency:** WAL is usable, with the two limits above.

Every handle that opens the main database attaches the bound stores recorded
in it, so readers need no extra setup.

## Notifications do not cross handles

Notifications are in-memory and belong to the handle that published them. A
subscription created on a reader handle does not receive notifications
published on the writer handle, in the same process or in another one.

A reader handle still sees the committed data. To react to writes made through
another handle, deliver the signal in the application: subscribe on the writer
handle and forward from there, or poll the reader.

## Other per-handle state

- **Prepared statements.** Each handle prepares and caches its own statements.
  Nothing is shared between handles, so the first call of each kind on a new
  handle pays the preparation cost.
- **Transactions and savepoints** belong to one handle.
- **Registered SQL functions and extensions** are registered per handle. Open
  every handle with the same extensions.

## Operating notes for WAL

- **Extra files.** A WAL-mode file `app.zova` has `app.zova-wal` and
  `app.zova-shm` beside it while handles are open. Copy a live database with
  `zova backup` or the backup API, not by copying files.
- **Read-only handles need the directory to be writable,** or the `-wal` and
  `-shm` files to exist already, because every handle uses the shared `-shm`
  file.
- **Same host only.** SQLite's WAL mode requires all handles to be on the same
  machine. It does not work across a network filesystem.
- **Long read transactions make the WAL file grow.** SQLite moves WAL content
  back into the database file in checkpoints, and a checkpoint cannot pass a
  point that an open read transaction still needs. Keep reader transactions
  short.

## Not provided

- A reader pool. Applications open and manage their own handles.
- Cross-handle or cross-process notifications.
- Background threads inside Zova.
