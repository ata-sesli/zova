# Zova 1.x API stability

This document defines the candidate public contract for Zova 1.x. The
`1.0.0-rc.2` release continues the contract introduced in `1.0.0-rc.1`. Release
candidate fixes may still correct inconsistencies before `1.0.0`, but the RC
line is closed to open-ended feature expansion.

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
the full release identity `1.0.0-rc.2` separately.

The experimental bundle-producer CLI and application-authored callback surfaces
remain outside the stable 1.x authoring contract. Dynamic native extensions run
in-process and retain their documented trust and platform boundaries.

## Not public contracts

Private `_zova_*` tables, indexes, query plans, generated private integer keys
other than explicitly returned opaque keys, benchmark counters, TEMP tables,
and internal cache sizes are implementation details. Applications must not read
or modify private storage directly.

Human-readable CLI diagnostics are not a machine protocol. Use documented JSON
output or library APIs where available.

## Storage compatibility

API stability does not mean every release opens every file directly. The
separate [storage compatibility contract](docs/storage-compatibility.md) governs
format probing and explicit migration. Zova 1.x never migrates silently.
