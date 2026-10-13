# zova-sys

`zova-sys` is the raw Rust FFI crate for Zova's C ABI.

Most Rust users should depend on the safe `zova` crate instead. Use
`zova-sys` when you need direct access to the C request structs and exported
functions from `include/zova.h`.

## Native Build

Default registry builds require Rust and Clang (clang-cl with the Visual Studio
C++ tools on Windows). Zig is not required. Cargo selects an exact-version source
package for the consumer target: Linux GNU x86_64/arm64, macOS x86_64/arm64,
or Windows MSVC x86_64. Cross builds require a suitable target compiler/linker/SDK.

The five `zova-sys-{linux-x64,linux-arm64,darwin-x64,darwin-arm64,windows-x64}`
crates carry explicitly targeted generated C, SQLite, headers, license and hashed
provenance metadata. This crate contains only the dispatcher and FFI. No native
sources are downloaded by build scripts and no host-target fallback is used.

Build order:

1. `ZOVA_LIB_DIR`: link a caller-provided compatible static library.
2. `ZOVA_SOURCE_DIR`: build an explicit Zig source tree for Cargo's target
   (requires Zig 0.16.0).
3. Compile the matching platform package with Clang.

`ZOVA_INCLUDE_DIR` overrides exported header metadata. `CC`, `CFLAGS`,
`AR` and their target-qualified cc-rs variants remain supported for generated C.
Other automatic targets fail explicitly; custom native libraries remain possible.
Each platform's `native/metadata.json` records the Cargo target, Zova/SQLite/Zig
versions, source revision and file hashes. The release pipeline packages all
seven crates once, tests the same immutable set on five native runners, then
publishes platform crates before this dispatcher and the safe crate.

The current release uses `.zova` format 12, and the earliest
migratable format is 9. Open never migrates silently: format-9, format-10 and
format-11 databases are reported as migration-required and left byte-identical. Migrate
them explicitly with `zova_database_probe_format` and `zova_database_migrate`,
or with `zova format` and `zova migrate` on the CLI. Migration publishes a
separately validated format-12 destination. Keep a backup before migrating, and
see `docs/storage-compatibility.md` in the Zova repository for the full
compatibility contract.

## Safety

This crate exposes raw C ABI declarations. It does not manage pointer lifetime,
owned buffers, or error mapping for you. The safe `zova` crate handles those
details.

`zova-sys` exposes the low-level C ABI surface, including
opaque-key graph batch mutation and lookup, keyed neighbors and topology scans,
edge payload access, prepared fresh graph builds, and the generic fresh-build
session. These declarations are unsafe raw FFI; the safe `zova` crate does not
yet wrap the new graph publication APIs.

It exposes the raw C ABI structs and functions for scalar SQL registration and
trusted `.zovaext` bundle loading. Callbacks are unsafe FFI: argument pointers
are borrowed for the duration of the call, text/blob/error result bytes are
copied by Zova before SQLite observes them, and callbacks must not re-enter the
same `zova_database` handle.

From 1.2.0, the safe Rust `zova` crate exposes explicit trusted bundle selection
at create/open; app-defined SQL callbacks remain raw C/sys. Go and Python
callback APIs are also deferred.

From 1.2.0, generated-C packages enable the same trusted native loader as Zig
hosts on Linux, macOS and Windows. This is not present in published 1.1.0
packages. Select compatible bundles through `zova_database_create_with_extensions`
or `zova_database_open_with_extensions`; opening never grants trust or loads
paths from database metadata. Libraries remain owned by the C handle until all
callbacks and child resources are released. C++ runtime/dependency packaging
belongs to the author. Browser WASM remains separate. The source tree also
declares explicit extension-data upgrade APIs; safe wrappers are separate work.
See the [extension capability matrix](../../../docs/extensions.md#availability-and-binding-matrix).
