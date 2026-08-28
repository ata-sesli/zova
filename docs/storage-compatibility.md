# Zova storage compatibility

This document is the normative storage compatibility contract for the Zova 1.x
series. It states what Zova promises about `.zova` files across releases, what it
deliberately does not promise, and how a database moves from one storage format
to the next.

Migration behavior itself lives in the code. This document describes the
contract that `scripts/check-release.sh` enforces through
`zig build check-storage-compat`.

## Four independent versions

Zova reports four unrelated version numbers. Changing one never implies a change
in another.

| Version | Meaning | Declared in | Current |
| --- | --- | --- | --- |
| Package version | Zova release identity across every distribution channel | `src/version.zig` `package_version` | `0.26.1` |
| C ABI version | Compatibility of the exported C ABI and generated C | `src/version.zig` `abi_version_*` | `0.26.1` |
| SQLite version | The vendored SQLite amalgamation, and separately SQLite's own file format | `src/version.zig` `sqlite_version` | `3.53.2` |
| Zova storage format | The layout of a `.zova` database, recorded in `_zova_meta.format_version` | `src/version.zig` `format_version` | `11` |

A SQLite upgrade does not change the Zova storage format and never requires a
Zova migration. A package or ABI release does not by itself change the storage
format either. Only `format_version` describes what a `.zova` file contains.

## The 1.x promise

- Every Zova 1.x release can migrate databases created by every earlier 1.x
  release.
- Format 9 is the only pre-1.0 format guaranteed a direct migration into 1.0.
  Databases created by released Zova 0.26.1 use format 9.
- Formats older than 9 are unsupported legacy. They are rejected, not migrated.
- Downgrades are unsupported. No release migrates a database backward, and no
  release promises to open a format newer than itself.
- `_zova_meta.format_version` remains the sole authoritative Zova format value.

## Opening a database never migrates

Migration is always explicit. `Database.open` reports the situation and refuses
rather than transforming anything:

| Format | Classification | Open result | C ABI status |
| --- | --- | --- | --- |
| Current format | `current` | opens | `ZOVA_OK` |
| From the earliest migratable format through the current one minus one | `migratable` | `MigrationRequired`, no mutation | `ZOVA_MIGRATION_REQUIRED` (`35`) |
| Older than the earliest migratable format | `unsupported_legacy` | `UnsupportedLegacyFormat`, no mutation | `ZOVA_UNSUPPORTED_LEGACY_FORMAT` (`37`) |
| Newer than this release | `unsupported_future` | `UnsupportedFutureFormat`, no mutation | `ZOVA_UNSUPPORTED_FUTURE_FORMAT` (`36`) |

Every one of these results leaves the file byte-identical. No open path writes,
attaches bound stores, or repairs a schema.

Probing is separate from opening and is always safe: `zova format` and
`probeDatabaseFormat` open a read-only raw SQLite connection, read only the
identity metadata required for classification, and never write.

## Migrating formats 9 and 10 to format 11

A migration runs offline, writes only to a new destination, and leaves the source
untouched. Probe first, then migrate.

### CLI

```sh
zova format app.zova
zova migrate app.zova app-format-11.zova
```

`zova format` prints the source format, the current format, the earliest
migratable format, the compatibility class, and the recommended action. Add
`--json` for machine-readable output. `zova migrate` accepts `--json` and
`--no-verify`; verification is on by default and reopens the migrated destination
set through the full open path.

### C ABI

```c
#include <zova.h>

zova_message message = {0};
zova_database_format_info info = {0};
zova_database_probe_format_request probe = {
    .path = "app.zova",
    .out_info = &info,
    .out_error_message = &message,
};
zova_status status = zova_database_probe_format(&probe);
/* info.compatibility == ZOVA_FORMAT_MIGRATABLE, info.format_version == 9 */

zova_database_migrate_request migrate = {
    .source_path = "app.zova",
    .destination_path = "app-format-11.zova",
    .flags = 0, /* ZOVA_MIGRATE_NO_VERIFY skips destination verification */
    .out_error_message = &message,
};
status = zova_database_migrate(&migrate);
```

A source with no registered path to the current format returns
`ZOVA_NO_MIGRATION_PATH` (`38`).

### Rust

```rust
use zova::{migrate_database, probe_format, MigrateOptions};

let info = probe_format("app.zova")?;
assert_eq!(info.compatibility, zova::FormatCompatibility::Migratable);
migrate_database("app.zova", "app-format-11.zova", MigrateOptions::default())?;
```

### Python

```python
import zova

info = zova.probe_format("app.zova")
assert info.compatibility is zova.FormatCompatibility.MIGRATABLE
zova.migrate_database("app.zova", "app-format-11.zova")  # verify=True by default
```

### Go

```go
info, err := zova.ProbeFormat("app.zova")
if info.Compatibility != zova.FormatMigratable {
    return fmt.Errorf("unexpected compatibility: %v", info.Compatibility)
}
if err := zova.MigrateDatabase("app.zova", "app-format-11.zova"); err != nil {
    return err
}
```

The zero-value `zova.MigrateOptions` verifies the migrated destination; set
`NoVerify: true` to skip it.

### JavaScript / TypeScript

```ts
import { migrateDatabase, probeFormat } from "zova-js";

const info = probeFormat("app.zova");
if (info.compatibility !== "migratable") throw new Error("cannot migrate");
migrateDatabase("app.zova", "app-format-11.zova"); // verify defaults to true
```

`asyncProbeFormat` and `asyncMigrateDatabase` are the promise-returning variants.

## Operational rules

These rules follow from the implementation and are worth planning around before
running a migration.

- **The destination must not exist.** Neither the destination main database nor
  its bound-store siblings may already exist; a migration reserves each of them
  before copying anything. Pre-existing files are never deleted by cleanup.
- **Bound stores migrate as one logical set.** A database with bound object,
  vector, and graph stores produces destination siblings named
  `<destination-stem>.objects.zova`, `<destination-stem>.vectors.zova`, and
  `<destination-stem>.graphs.zova` in the same directory as the destination.
- **Staging needs room.** Each member is copied to a hidden staging file in the
  destination directory, named `.<stem>.migrate-<random hex>.zova`, transformed
  there, and published by rename. Budget free space roughly equal to the size of
  the whole source set, in the destination filesystem.
- **The source is locked while staging runs.** Migration takes a write lock on
  the source before planning the bound set, so no writer can unbind or rebind a
  store mid-flight. Concurrent writers receive `Busy`/`Locked` rather than
  causing a torn snapshot.
- **Publication is ordered.** Bound stores are published first and the main
  database last, as the commit marker. A published main database can therefore
  never be missing or half-migrated stores.
- **Interruption recovery.** A crashed or cancelled migration leaves only
  unpublished staging files. Delete any leftover `.*.migrate-*.zova` files in the
  destination directory and re-run the migration. Never hand-publish a staging
  file.
- **Extensions.** Both adjacent migration steps leave extension-owned tables
  unchanged. Normal open-time extension compatibility validation applies to the
  migrated destination, exactly as it does when opening any database.

## What a migration preserves

A migration preserves the logical database. User SQLite schema and rows are
copied unchanged, and Zova preserves public identities, values, ordering,
payloads, opaque keys, extension records, store IDs, bound-set IDs, and epochs.
The intended private differences are the key-value schema introduced by format
10, the canonical object schemas required by format 11, and the format metadata
itself, which is updated last inside each atomic adjacent step. Public objects,
chunks, manifests, and their ordering remain unchanged.

## Retained fixtures and the release check

`tests/fixtures/` holds the retained fixture set, and
`tests/fixtures/fixtures.sha256` pins every one of them. The format-9 fixtures are
genuine exports of the released Zova 0.26.1 build, regenerated by
`scripts/export-format-9-fixtures.sh`; they are never hand-edited and never
produced by editing metadata in a newer database.

`zig build check-storage-compat` is a release gate. It runs in
`scripts/check-release.sh` and in CI, and it verifies that:

- every pinned fixture is byte-identical to its recorded hash;
- every fixture classifies exactly as this document requires, with the expected
  classification derived from `format_version` and `minimum_migratable_format`
  rather than from a hardcoded list;
- a complete chain of adjacent migration steps exists from every promised format
  up to the current format;
- every promised format migrates to the current format and reopens, with its
  source left byte-identical; and
- every migratable main database is covered by the migration matrix.

The check derives expectations from the declared policy, so removing a
registered migration step, lowering the earliest migratable format without
retaining fixtures, or adding a migratable fixture without migration evidence
each fails the release. Correctness, atomicity, source preservation, and binding
parity remain hard gates; the timing and size figures the check reports are
diagnostic and cannot weaken them.

## Appendix: recorded adjacent format-9 to format-10 step

The first adjacent step was recorded from `tests/fixtures/format-9.zova`, a
genuine export of the released Zova 0.26.1 build, with verification enabled:

```sh
zova format app.zova
zova migrate app.zova app-format-10.zova
```

`zova format` reported `source_format: 9`, `current_format: 10`,
`minimum_migratable_format: 9`, `compatibility: migratable`, and recommended
`zova migrate <source> <destination>`.

| | Source `app.zova` | Destination `app-format-10.zova` |
| --- | --- | --- |
| SHA-256 | `6d7371d9c9d45c07c568989c738f83ec9fae7470ab3c73523bdf6ab71387bc11` | `6a3d3fd36d5719b82fd302d8b9d5b7c6e410efef8311ff3a9c1d18007af8a29b` |
| Size | 544,768 bytes | 548,864 bytes |
| `format_version` | 9 | 10 |
| User tables | 2 | 2 |
| Objects | 3 | 3 |
| Object chunks | 34 | 34 |
| Vectors | 6 | 6 |
| Graph nodes | 4 | 4 |
| Graph edges | 3 | 3 |
| Extension records | 1 | 1 |
| `_zova_kv` | absent | present, 0 rows |
| `pragma integrity_check` | ok | ok |

Elapsed wall time was 0.15 s and verification passed: the CLI reported
`verified: true`, and the migrated destination reopens through the full open
path. The source hash is identical before and after, and the only structural
difference is the private key-value schema format 10 introduces.

This recorded adjacent step is evidence, not a gate. Current migrations continue
through format 10 to format 11. The gates are the correctness, atomicity,
source-preservation, and binding-parity assertions in
`zig build check-storage-compat`, which recompute hashes, sizes, and counts on
every run against every retained fixture.
