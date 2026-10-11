# Portable native plugin loading (#139)

Base: merged #138, `a938b19336b2a3ce9ca1a55dcd299409a8090497`.
Branch: `work/portable-plugin-loading-139`. Changes remain uncommitted.

## Implementation

The generated-C generator now enables the existing native loader. No second
loader or trust policy is introduced. Explicit process-selected bundle paths
still require matching trust records. Database metadata never chooses code to
load. Registry composition and library cleanup remain owned by the C handle.
Windows retains the restricted LoadLibraryExW search policy; Linux/macOS retain
their platform loader. Bundles must match OS, CPU and deployment targets. C++
dependencies are packaged by the plugin author, not automatically downloaded.

Safe Rust adds `ExtensionOptions`, `create_with_extensions` and
`open_with_extensions` for both Database and SharedDatabase. Existing Copy
OpenOptions and constructor behavior remain unchanged. Python exposes optional
keyword bundle/trust-store selection; Node/Bun expose it for sync and async
handles; Go adds explicit extension-selecting constructors. No input is retained
after the synchronous create/open call. Opening never grants trust.

Package/application ABI stay 1.1.0, plugin ABI v1 and storage format 12.
No persistent schema, migration, CBM, WASM loader or release changes. Browser
WASM remains outside native-library loading. Documentation marks this as
development support, not a feature already published in 1.1.0.

## Tests

`scripts/check-plugin-packages.py <new-output-directory>` builds once with two
jobs and runs real C and C++ plugins against generated C, safe/shared Rust,
Go/cgo, an installed abi3 Python wheel and an installed npm tarball under Node
and Bun. The C++ plugin uses a sibling shared library exercising the C++ runtime.
Its C boundary catches exceptions rather than unwinding through host callbacks.

Checks cover trust/install/query/read-only reopen, missing code, incompatible
descriptors, changed manifests and dependency bytes, missing dependencies,
child-handle/library lifetime, and malformed input before mutation. The C++
fixture uses only bundle-relative rpaths; Zig's automatic build-tree rpath was
removed after it concealed a missing-dependency failure in the first check.
New CI runs the same package check on Linux x64/arm64, macOS x64/arm64 and
Windows x64. The immutable Rust-artifact workflow also executes the new fixture
test from the extracted safe crate with its packaged platform sources, not a
source/archive override. CI has not been triggered by this local implementation.

## Local evidence

macOS arm64, Zig 0.17.0, Python 3.14; external build/cache/artifact root:
`/Volumes/wipesides/codebase-memory-mcp-cache/zova-1.1.0-release/zig17-verification/issue139`.

- Clean full package-check script: passed (`packages-4` artifacts).
- Complete Debug Zig/C/C++/e2e/storage-compatibility gate: passed; 140 immutable
  storage checks, zero failures.
- Full raw/safe Rust: 92 passed, 2 ignored fixture tests; new fixture test also
  executed explicitly for both bundles and passed. JavaScript Rust crate: 2 passed.
- Full Go tests and vet against generated C: passed.
- Full installed Python wheel suite: 48 passed.
- Full JavaScript suite/typecheck: 59 passed; installed tarball consumers passed
  under Node and Bun for both C and C++ bundles.
- Generated C emitted successfully for all five native distribution targets.
- ReleaseSafe extension suites: 94 passed, 3 skipped; C/C++ smoke and
  native/generated exported-symbol parity passed.
- Workflow/package configuration regression tests: 11 passed.
- Formatting, version and git diff --check: passed.

Nonfatal local diagnostics: Rust/dSYM missing-object warnings during relink and
Go test-archive macOS deployment-version warnings. Other native platforms were
not executed locally; cross-target C emission is not runtime verification.
No benchmarks, commits, pushes, PRs, release workflows or publication.
