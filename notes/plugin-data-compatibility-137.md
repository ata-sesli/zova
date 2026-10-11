# Plugin code and data compatibility (#137)

## Format-neutral contract

Keep format 12 and the existing extension metadata schema. The installed
`version` is the stored-data version. For legacy descriptors it is also the
required code version, exactly as before. No database is rewritten on open.

New plugins explicitly opt in through a flagged, size-checked C descriptor
tail. The base `version` remains the code release identity (also checked against
the trusted bundle manifest). The tail declares a target data version and an
exact comma-separated list of accepted data versions. Versions are canonical
`major.minor.patch`; no ranges, implicit acceptance, or inferred migration.
The target must be accepted. Native Zig registries use the same declarations
in a separate compatibility list; the legacy native descriptor layout stays
unchanged.

Install records the target data version. Open, check, drop, SQL registration,
and salvage require explicit acceptance of the stored version. Code may move
forward or backward if it explicitly accepts that data; data downgrades are
never supported. ABI requirements are still checked independently. A mismatch
returns ExtensionIncompatible (ZOVA_EXTENSION_INCOMPATIBLE at the C boundary);
installed-info identifies the stored version, the bundle identifies code, and
the declaration identifies accepted/target versions.

Explicit upgrade paths use source/target **data** versions, not code releases.
Only a declared forward path is executed. Existing lifecycle savepoints keep
data and metadata atomic and preserve earlier caller work. Registration tags
callbacks with the visible data version, so rollback restores the matching
callback generation. Compatible code-only replacement needs no upgrade hook
and performs no metadata writes. Existing databases need no migration: their
legacy stored version is accepted only when the new declaration lists it.

The compatibility tail embeds the existing upgrade descriptor first, retaining
its offsets; unused upgrade fields are null. Old hosts reject the new flag.
Declarations/strings remain immutable and library-owned until unload, as with
the existing descriptor. Registry copies must retain compatibility declarations
alongside copied base descriptors, not read tails from truncated copies.

## Verification

Test legacy matching, code-only reopen, explicit rejection, install target,
forward upgrades and fault rollback, caller rollback, backup/restore, malformed
and truncated tails, registry-copy allocation failures, and callback generations.
Run focused Debug/ReleaseSafe extension tests, C/C++ headers, full Zig gates,
generated-C parity and synchronized native-source checks. No version bumps.
