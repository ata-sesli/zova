# Zova 1.x API stability

This document defines the stable public contract for Zova 1.x. The
`1.0.0` release establishes the compatibility commitments below, following
the release-candidate validation period. The current `1.5.0` release extends
the implementation without weakening those commitments.

The separate `zova-wasm` browser package was experimental from rc.3 through
1.4.0 and excluded from this commitment. From 1.5.0 it is a stable 1.x surface
with the exceptions named in [Browser package](#browser-package-zova-wasm).
JavaScript/TypeScript elsewhere in this document refers to the native `zova-js`
package.

## Supported public surfaces

The following capabilities are part of the stable 1.x contract wherever a
binding exposes them:

- database create, open, read-only open, in-memory create, close, backup,
  compact, in-place free-page reclaim, restore, SQL execution, prepared
  statements, transactions, and savepoints;
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
| Opaque-key topology, payloads, scans, fresh build | Yes | Yes | Yes | Yes | Yes | Yes |
| Store create/bind/split management | Zig/CLI | Selected operations | No | No | No | No |
| Application-authored callbacks/extensions | Selected surfaces | Selected surfaces | SQL functions, linked plugins | SQL functions, linked plugins | SQL functions, linked plugins | SQL functions, linked plugins |

The low-level opaque-key and fresh-build APIs are supported C ABI contracts,
not private implementation hooks. The safe Rust crate, the Python package,
the Go package, and the native JavaScript/TypeScript package expose every C
ABI function. In JavaScript the low-level surfaces are on the synchronous
`Database`; `AsyncDatabase` remains a queued subset.

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

Synchronous object mutations are operation-atomic and join a caller-owned
transaction. `putObject`, `putObjectWithOptions`, chunk writes, object
assembly, and `deleteObject` own a `begin immediate` transaction when no
transaction is active, and otherwise take an internal savepoint. A failure
undoes only that operation's own chunks, manifests, and metadata; the caller
transaction is never committed or rolled back on its behalf, and earlier caller
work in the same transaction survives.

The streaming `ObjectWriter` is the documented exception. It holds no
transaction across `write` calls, so a main-store object writer used inside an
active caller transaction still fails with `ZOVA_OBJECT_TRANSACTION_ACTIVE`.
Its contract and lifetime are unchanged, and a bound object store still allows
the writer inside caller transactions.

Notifications are explicit, same-process, in-memory events attached to one open
database handle. They are delivered only after the owning transaction commits.
Rollback discards pending events; savepoint rollback discards inner events;
savepoint release preserves them for the outer transaction. They are not a
cross-process log, durable queue, replication stream, or automatic change feed.

Raw SQL transaction scopes are rejected for notification publication when Zova
cannot track their lifetime. Each subscription has the documented bounded queue
and overflow report behavior.

## Scoped helper cleanup

A scoped transaction or savepoint helper unwinds its scope on every exit path.
Returning an error rolls back. A panic unwinding the closure also rolls back
before the helper releases its connection lock, and then propagates unchanged.
Cleanup never panics and never re-acquires the lock to discard the scope.

Cleanup applies to unwinding panics only. `panic = "abort"` profiles and process
termination are outside this contract; the native connection is then reclaimed by
SQLite's own crash recovery.

If a rollback itself fails, the connection's transaction state is unknown and
that handle is retired: subsequent calls on it fail with a documented error
instead of silently continuing on possibly-open work. Drop the handle and open a
new one.

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
`major.minor.patch`; the release reports numeric ABI components `1.5.0` and
the full release identity `1.5.0` separately.

In published 1.0.0/1.1.0, the experimental bundle-producer CLI and
application-authored callback surfaces are outside the stable authoring contract.
Dynamic native extensions run in-process and retain their documented trust and
platform boundaries.

The portable plugin descriptor and explicit extension-data upgrade APIs are
included in 1.0.0; authoring in those releases remains experimental as above.
Those historical 1.0.0/1.1.0 guarantees do not include generated-C dynamic loading
or high-level bundle-selection wrappers. The 1.2.0 authoring contract
targets the versioned common C descriptor, negotiated host services, typed SQL
operations and documented lifecycle/ownership rules. Zig helpers use the same
C layouts, not a separate plugin ABI. Legacy Zig bundle production, algorithm
reference implementations and high-level callback-authoring wrappers are not
promoted to stable APIs merely by inclusion in the repository.
The [authoring support matrix](docs/extension-authoring.md#support-and-compatibility)
separates current support from earlier release guarantees.

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
| `openForExtensionUpgradeWithExtensions` / C `zova_database_open_for_extension_upgrade` and `zova_database_open_for_extension_upgrade_with_plugins` | Explicit extension maintenance without normal installed-hook initialization. Upgrade, close, and reopen normally before application use; no implicit upgrade occurs. |
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

## Browser package (`zova-wasm`)

From 1.5.0, `zova-wasm` keeps these commitments throughout 1.x:

- **API.** The declarations in `bindings/wasm/api/index.d.ts` are the public
  surface. They follow native `zova-js` names, argument shapes and results, as
  mapped in the [parity table](bindings/wasm/README.md#native-api-parity).
  Changes within 1.x are additions. CI fails when the emitted declarations
  differ from that file, or when a `zova-js` name has no row in the table.
- **Calls.** Every database method returns a promise. Each database owns one
  dedicated worker, and its calls run in request order.
- **Errors.** Failures reject with `ZovaError`: `code` is the status name and
  `status` its number, the same values as the C ABI and `zova-js`.
  `ZovaWasmError` and `statusCode` remain as deprecated aliases throughout 1.x.
- **Storage and ownership.** A persistent name matches
  `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`. Its database lives in the origin's
  private file system (OPFS) in the directory `.zova-<name>`; a
  `.zova-<name>.pending` entry marks an import or copy in progress. One owner
  holds a name at a time through the Web Lock `zova:opfs:<name>`, requested
  without waiting; a second opener rejects with `ZOVA_BUSY`. Applications must
  not change those entries or take that lock. Files inside the directory are
  implementation details.
- **Browsers.** Chromium-based desktop browsers, version 149 or later, and
  desktop Firefox, version 155 or later, in a secure context with module
  workers, Web Locks and OPFS synchronous access handles. Releases are tested
  in Helium (Chromium 149), Playwright Chromium (153) and Playwright Firefox
  (155). Safari, WebKit, mobile and private browsing are not qualified.

Named exceptions to native parity, each a browser constraint:

- Calls that take a file path in `zova-js` take a persistent name.
- There are no run-time extension bundles, trust store or `LinkedPlugin`;
  plugins are linked into a custom module at build time.
- SQL functions are `{ module, export }` worker modules, because SQLite calls
  them synchronously inside the worker.
- One connection per name at a time; a database is not shared between
  workers or tabs. Notifications stay within one worker.
- Bound stores are created only by the Zig API and CLI, and a named browser
  database is one file, so a database with bound stores cannot be migrated
  (`ZOVA_BOUND_STORE_INVALID`).
- `Step` is a constant object rather than a TypeScript enum,
  `parameterCount` is a property, and `Statement.close()` is `finalize()`.

The worker message protocol, the `channel`, `runtime` and `worker` modules,
bridge operation numbers, and real quota, crash and performance behavior beyond
the tested cases are not public contracts.

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
