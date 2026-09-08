# Zova 1.x API stability

This document defines the candidate public contract for Zova 1.x. The
`1.0.0-rc.3` release continues the contract introduced in `1.0.0-rc.1`. Release
candidate fixes may still correct inconsistencies before `1.0.0`, but the RC
line is closed to open-ended feature expansion.

The separate `zova-wasm` browser package introduced in rc.3 is experimental
and excluded from this native compatibility commitment. Its SQL/KV subset,
worker lifecycle, and OPFS APIs do not promise stable browser APIs or full
native parity. JavaScript/TypeScript below refers to the native `zova-js` package.

## Supported public surfaces

The following capabilities are part of the candidate 1.x contract wherever a
binding exposes them:

- database create, open, read-only open, in-memory create, close, backup,
  compact, restore, SQL execution, prepared statements, transactions, and
  savepoints;
- explicit format probing and copy-forward migration;
- transactional byte-key/byte-value storage and atomic batches;
- content-addressed objects, manifests, chunks, range reads, assembly,
  streaming writers, and chunking-policy selection;
- f32, f16, and i8 vector collections, exact search, candidates, and batches;
- public graph CRUD, batches, neighbors, degree, and directional walks;
- bundled extension lifecycle operations;
- same-process application notifications; and
- version, status, and diagnostic reporting.

Public names, argument meanings, status/error categories, ownership rules,
transaction semantics, deterministic ordering, and documented thread-safety
guarantees are compatibility commitments. Additive APIs may appear in 1.x.
Removing an API or changing accepted data, ownership, ordering, or successful
behavior requires a new major version unless the old behavior is a correctness
or safety defect.

## Binding boundary

The bindings intentionally differ where a low-level facility does not have an
idiomatic safe representation.

| Capability | Zig | C | Rust | Python | Go | JavaScript/TypeScript |
| --- | --- | --- | --- | --- | --- | --- |
| SQL, lifecycle, transactions, backup | Yes | Yes | Yes | Yes | Yes | Yes |
| In-memory databases | Yes | Yes | Yes | Yes | Yes | Yes |
| Format probe and migration | Yes | Yes | Yes | Yes | Yes | Yes |
| KV and notifications | Yes | Yes | Yes | Yes | Yes | Yes |
| Objects and exact vectors | Yes | Yes | Yes | Yes | Yes | Yes |
| Public graph CRUD and traversal | Yes | Yes | Yes | Yes | Yes | Yes |
| Opaque-key topology, payloads, scans, fresh build | Yes | Yes | raw `zova-sys` | No | No | No |
| Store create/bind/split management | Zig/CLI | Selected operations | No | No | No | No |
| Application-authored callbacks/extensions | Selected surfaces | Selected surfaces | No safe wrapper | No safe wrapper | No safe wrapper | No safe wrapper |

The low-level opaque-key and fresh-build APIs are supported C ABI contracts,
not private implementation hooks. Their absence from high-level bindings is
deliberate and does not make the high-level packages incomplete.

## Errors and statuses

- C status numbers and their meanings are stable throughout 1.x. New statuses
  may be added; existing values are not renumbered.
- Bindings preserve the underlying Zova status category when they return a
  language-native error or exception.
- Invalid pointers, lengths, capacities, enum values, UTF-8, and malformed
  requests fail before authoritative mutation where documented.
- Batch operations are atomic. They either own a transaction or use an internal
  savepoint when joining a caller transaction.
- Migration-required, unsupported-future, unsupported-legacy, and
  no-migration-path are distinct outcomes.

## Ownership and lifetimes

- C request inputs are borrowed for the duration of the call unless a specific
  API states otherwise.
- C outputs described as owned must be released with their matching Zova free
  function. Free functions are safe for zeroed outputs and are idempotent where
  documented.
- Database, statement, writer, subscription, and fresh-build handles have
  explicit terminal operations. A pointer is invalid after successful terminal
  cleanup.
- Opaque graph keys are database-local identities. They are not portable public
  IDs and remain valid only for the lifetime of their underlying row.
- High-level bindings copy native diagnostics and owned results before another
  serialized call can replace native scratch storage.

## Transactions and notifications

SQLite remains the transaction and locking engine. Zova helpers preserve normal
SQLite commit, rollback, savepoint, busy, and locking behavior.

Notifications are explicit, same-process, in-memory events attached to one open
database handle. They are delivered only after the owning transaction commits.
Rollback discards pending events; savepoint rollback discards inner events;
savepoint release preserves them for the outer transaction. They are not a
cross-process log, durable queue, replication stream, or automatic change feed.

Raw SQL transaction scopes are rejected for notification publication when Zova
cannot track their lifetime. Each subscription has the documented bounded queue
and overflow report behavior.

## Thread safety

One C database handle may be called from multiple threads, but calls on that
handle are serialized. Child handles share the same serialization boundary.
This is safety, not parallel execution. Use separate database handles for true
concurrent SQLite work.

Language bindings may impose a stricter policy. Rust's single-owner `Database`
is not `Send` or `Sync`; `SharedDatabase` is the explicit serialized shared
surface. JavaScript `AsyncDatabase` queues work FIFO. Binding documentation is
authoritative for these stricter rules.

## Extensions

The bundled-extension lifecycle, manifest validation, ABI minimum enforcement,
and extension records are supported. Extension minimum ABI values use numeric
`major.minor.patch`; the running RC reports numeric ABI components `1.0.0` and
the full release identity `1.0.0-rc.3` separately.

The experimental bundle-producer CLI and application-authored callback surfaces
remain outside the stable 1.x authoring contract. Dynamic native extensions run
in-process and retain their documented trust and platform boundaries.

The source-tree portable plugin descriptor and explicit extension-data upgrade
APIs are additions after published rc.3, not retroactive release promises.
They do not add Windows/generated-C dynamic loading or high-level binding
wrappers. The [extension capability matrix](docs/extensions.md#availability-and-binding-matrix)
is authoritative for these distinctions.

## Zig implementation state and raw SQLite access

The supported Zig application surface consists of documented operations and
documented input/result types. Accessibility of a field in the exported
`Database` struct does not make that field a supported application interface.
Its field layout, cache state, notification hub, bound-store bookkeeping, and
registry storage are implementation details. Applications must use the methods
rather than construct, replace, or mutate that state directly. Internal fields
may change as implementation evolves; this is a documentation boundary, not
an assertion that Zig enforces field privacy.

The currently accessible `sqlite_db` connection is an advanced escape hatch,
not a promise to preserve the `Database` representation. Prefer Zova's `exec`,
`prepare`, transaction helpers, and subsystem methods. Low-level access must
not modify private storage, close or replace the connection, manage Zova's
attachments, or bypass its notification/transaction bookkeeping. It does not
inherit the C handle's serialization guarantees. This boundary does not remove
the separately exported `sqlite` wrapper or change existing function signatures.

## Maintenance connection modes

Maintenance APIs remain available under their existing names. They are advanced
operations with narrower usage contracts, not interchangeable alternatives to
normal `open`/`openWithOptions`:

| Operation | Intended use and restrictions |
| --- | --- |
| `openForExtensionInspection` / `openForExtensionInspectionWithExtensions` | Read-only inspection of core schema and installed extension metadata; installed extension code/checks/SQL hooks are not automatically required or run. Do not assume ordinary extension initialization occurred. |
| `openForExtensionUpgradeWithExtensions` / C `zova_database_open_for_extension_upgrade` | Explicit extension maintenance without normal installed-hook initialization. Upgrade, close, and reopen normally before application use; no implicit upgrade occurs. |
| `openForObjectStoreManagement` / `openForObjectStoreManagementWithExtensions` | Repair or replace bound-store metadata by opening only the main file. Object/vector/graph operations do not access the configured external stores through this handle. Close and reopen normally after maintenance. |
| `unknownExtensionStorage` | Diagnose extension-private storage without a registered installed owner; not an application-data enumeration API. |
| `registerExtensionSqlForDiagnostics` | Explicitly register the SQL facilities needed for extension diagnostics. This does not turn an inspection handle into a normally initialized application connection. |

Use ordinary open methods for application CRUD. These restrictions document
existing modes; they do not introduce new runtime access controls or rename APIs.

## Public profiling contracts

Public graph-walk and fresh-build profiling interfaces are distinct from
private benchmark instrumentation. Their existing C symbols, request/result
layouts, field types, units, and documented meanings remain compatibility
commitments. Calling them diagnostic does not permit an ABI-breaking change.

- Fields ending in `_ms` report elapsed milliseconds for their named scope,
  not CPU time or a performance guarantee. Instrumentation affects execution.
- Row/result/expansion counters count the named events. Bind/prepare/statement
  counters describe actual execution work, not logical input cardinality; an
  optimization may reduce them without changing query results.
- A stage that is not executed contributes zero. A measured stage may also
  report zero because of timer resolution. Zero alone is not a cache-hit flag.
- Existing structures have no general availability flag. A new unavailable
  measurement must not silently be encoded as zero, NaN, or a negative value.
  If availability or a new stage model cannot be expressed compatibly, add a
  separately specified interface with explicit availability/versioning.
- Cached operations still account for work performed within the existing named
  scope. For example, adjacency preparation currently includes statement setup
  and constant binding, not only SQL compilation; a cache hit does not imply
  that this entire scope must be zero.
- Totals and component scopes are not universally additive. Fresh-build graph
  subphases sit within graph work, and public graph-walk bookkeeping includes
  residual traversal time and cleanup rather than an independently timed
  allocator-only measurement. Do not sum every field to estimate wall time.
- Interpret complete profiles only after a successful call. Error-path values
  are not a complete or comparable sample unless explicitly documented otherwise.

Preserve these meanings as implementations change. Do not relabel an existing
field to describe a different operation, append fields to an unversioned C
output struct in place, or remove a profiling function. New incompatible
measurement models require an additive interface or a major-version decision.
Compare profiled runs with equivalent instrumentation; use unprofiled calls
for authoritative application performance measurements.

## Not public contracts

Private `_zova_*` tables, indexes, query plans, generated private integer keys
other than explicitly returned opaque keys, private benchmark counters, TEMP tables,
and internal cache sizes are implementation details. Applications must not read
or modify private storage directly.

Human-readable CLI diagnostics are not a machine protocol. Use documented JSON
output or library APIs where available.

## Storage compatibility

API stability does not mean every release opens every file directly. The
separate [storage compatibility contract](docs/storage-compatibility.md) governs
format probing and explicit migration. Zova 1.x never migrates silently.
