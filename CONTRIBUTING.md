# Contributing To Zova

Thanks for taking a look at Zova. This project is still pre-1.0, so the best
contributions are small, careful changes that make the storage runtime easier
to trust: bug fixes, tests, docs, examples, binding polish, and focused API
improvements.

## Before You Start

Please open an issue or discussion before working on changes that affect:

- `.zova` file format or `format_version`
- private `_zova_*` schema
- C ABI shapes, status codes, or ownership rules
- Rust, Go, or Python public APIs
- extension host trust/loading behavior
- object/vector bound-store behavior
- release, packaging, or publishing scripts

Small docs fixes, test fixes, typo fixes, and narrow bug fixes usually do not
need prior discussion.

## Development Setup

Zova vendors SQLite. You do not need a system SQLite install.

Expected tools:

- Zig `0.16.0` or newer
- Rust `1.79` or newer
- Go `1.22` or newer
- Python `3.10` or newer
- `uv`
- a C compiler/linker

Useful local checks:

```sh
zig build test
zig build check-storage-compat
zig build cli-test
zig build c-abi-test
cargo test --workspace --manifest-path bindings/rust/Cargo.toml
cd bindings/go && go test ./...
cargo test --manifest-path bindings/python/Cargo.toml
uv run --isolated --with pytest --directory bindings/python python -m pytest
```

Run the full release smoke path before release-facing changes:

```sh
scripts/check-release.sh
```

Do not run publishing commands unless you are the maintainer preparing an
approved release.

## Formatting

Use the project formatters:

```sh
zig fmt --check build.zig build.zig.zon src/root.zig src/sqlite.zig src/zova.zig src/zova_error.zig src/zova_test_support.zig src/extension.zig src/extension_dynamic.zig src/notify.zig src/object.zig src/object_fastcdc.zig src/object_tests.zig src/vector.zig src/vector_tests.zig src/vector_sql.zig src/vector_sql_tests.zig src/graph.zig src/graph_tests.zig src/graph_sql.zig src/graph_sql_tests.zig src/trgm.zig src/trgm_tests.zig src/c_api.zig src/c_api_internal.zig src/c_api_tests.zig src/cli.zig src/main.zig src/storage_compat_check.zig tests/dynamic_extension_fixture.zig tests/e2e.zig tests/cli.zig
cargo fmt --all --manifest-path bindings/rust/Cargo.toml --check
cargo fmt --manifest-path bindings/python/Cargo.toml --check
cd bindings/go && go vet ./...
```

## Tests

Add or update tests with behavior changes.

- Zig storage behavior belongs in `src/*_tests.zig` or `tests/*.zig`.
- C ABI changes need C ABI tests and smoke coverage.
- Rust changes need `bindings/rust` tests.
- Go changes need `bindings/go` tests.
- Python changes need pytest coverage under `bindings/python/tests`.
- CLI behavior needs `tests/cli.zig`.

Public API and CLI changes should also update the README or the relevant
binding README.

## Generated Native Source

`bindings/rust/zova-sys/native/` is generated and gitignored. Do not edit it by
hand.

When Zig/C ABI source changes need to be reflected in the Rust package snapshot,
run:

```sh
sh bindings/rust/zova-sys/tools/sync-native-source.sh
sh bindings/rust/zova-sys/tools/check-native-source.sh
```

The snapshot should be synced for release/package checks, but it should remain
untracked in git.

## Pull Requests

Please keep PRs focused. A good PR includes:

- a short explanation of the behavior change
- tests that prove the change
- docs updates when public behavior changes
- notes about generated/package files if relevant
- the exact commands you ran

Avoid broad rewrites, unrelated refactors, and release/publishing changes mixed
with feature work.

## Releases

Only the maintainer publishes releases, crates, PyPI packages, Go tags, or
GitHub releases.

Release-oriented scripts may run dry-runs or package checks. Publishing scripts
and commands should not be run from contributor PRs unless explicitly approved.

## Security

Please do not report security issues in public issues. See `SECURITY.md`.
