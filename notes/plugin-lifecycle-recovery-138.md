# Extension lifecycle and recovery (#138)

Format-neutral implementation over merged #137. No package/application ABI,
plugin ABI, SQLite, or persistent format bump.

## Contract

Portable check/registration are read-only; install/upgrade/drop/rebuild are
savepoint-controlled. Transaction/savepoint/attachment/PRAGMA boundaries cannot
be changed through portable lifecycle SQL. Native direct-access hooks remain
trusted code with documented author obligations, not a sandbox.

Callback generations need more than data-version tags: rebuild and code-only
registration can keep that version unchanged. A connection-local TEMP owner/
generation marker is changed inside the SQL savepoint. Caller rollback selects
the prior retained callback generation. No persistent metadata changes. State
destruction follows rollback/publication; libraries outlive all callbacks and
child handles. Arbitrary mutable caches and external effects remain plugin-owned.

## Explicit recovery

An opt-in descriptor tail (flag 256) embeds the existing compatibility/upgrade
prefixes and adds rebuild/salvage callbacks. Unused prefixes are null. Base
descriptor copies retain a separate validated recovery sidecar.

Rebuild receives the installed data version, repairs private state, then runs
registration/check/ownership/core validation atomically. It cannot become a data
upgrade or modify authoritative metadata. Zig, C/raw Rust and CLI expose the
explicit operation through existing named requests/maintenance-open facilities.

Portable salvage has borrowed source/destination hosts and a bounded callback
contract. Source reads stay snapshot-pinned; plans have no destination. Source
changes are discarded. Copy validates the recovered plugin and preserves the
source data version; errors and skips roll back partial state. The core never
guesses private storage meaning. Atomicity is per extension and SQLite scope,
not across unrelated files or external effects.

## Verification

Regression tests cover lifecycle writes/transaction escape, metadata rewrites,
same-version rebuild rollback, SQL generation-publication failure, allocation
failures, skipped recovery, source preservation, rejected destination checks,
real C/C++ bundles, live children at close, read-only initialization, bound-store
rebuild, backup/restore, legacy/trgm behavior and raw binding layouts.
Build/test caches and artifacts remain on the external disk with two build jobs.

Final macOS-arm64 verification: full Debug gate 924 passed, 6 skipped; C/C++
ABI smoke passed; immutable compatibility matrix 140 checks, zero failures.
ReleaseSafe extension/plugin suites: 94 passed, 3 skipped. Rust nextest:
91 passed, 1 skipped. Native snapshots synchronized and checked. Generated-C
compile/smoke/exported-symbol parity, production WASM C ABI compilation,
version check, Zig/Rust formatting and git diff --check all passed. Linux/Windows
execution and browser runtime checks remain CI responsibilities. No benchmarks.
