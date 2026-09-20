# Zova agent guide

## Scope and design

- Understand the existing implementation before editing it. Prefer the smallest
  coherent change and follow nearby patterns.
- Keep Zova generic. Do not add CBM-specific behavior or modify another
  repository unless the task explicitly includes it.
- Preserve public API behavior, deterministic ordering, transaction semantics,
  bound-store routing, and opaque-key contracts.
- Batch mutations must be operation-atomic, including inside caller-owned
  transactions; use the established transaction/savepoint patterns.
- Private tables and storage details must not leak through public APIs.

## Versions and storage

- Package version, C ABI identity, and on-disk format are separate contracts.
- Never bump the package, ABI, storage format, migration floor, or SQLite
  version without explicit authorization.
- A storage-format change requires schema validation, immutable retained
  fixtures, migration coverage, and updated compatibility documentation.
- Preserve historical release statements when updating current-version prose.
- Put implementation plans and investigation reports in `notes/`; reserve
  `docs/` for maintained user documentation.

## Generated and vendored sources

- Do not hand-edit generated C or bundled binding snapshots.
- Regenerate canonical C with `scripts/update-generated-c.sh` and verify it with
  `scripts/check-generated-c.sh`.
- Synchronize Rust and Python native snapshots through their existing `tools/`
  scripts, then run the matching check scripts.
- Do not edit vendored SQLite unless the task explicitly requires it.

## Verification

- Use the focused Zig suite while developing (`zig build test-graphs`,
  `test-objects`, `test-vectors`, `test-migration`, `test-c-api`, and related
  steps). Keep `zig build test` as the complete Zig gate.
- Use `cargo nextest run`, not ordinary `cargo test`, for Rust test execution.
- Before release work, run `scripts/check-versions.sh` and the complete
  `scripts/check-release.sh` from a clean, synchronized tree.
- Run `git diff --check` before handing off changes.
- Treat `.badbox/` findings as advisory structural evidence, not proof of a bug
  or a replacement for tests and query-plan/performance checks.

## Performance work

- Measure a baseline and candidate under the same build, cache, filesystem, and
  fixture conditions. Include all added preparation work in reported timings.
- Use bounded benchmark scripts, show progress, and state expected resource use
  before launching expensive runs. Do not start multi-hour or very large
  benchmarks without explicit approval.
- Retain an optimization only when parity, correctness, storage, and the stated
  performance gates pass. Do not weaken gates or stack unrelated experiments.

## Git and release safety

- Preserve existing dirty and staged work. Never reset, unstage, rewrite
  history, commit, push, merge, tag, publish, or trigger release workflows
  unless the user explicitly requests that action.
- When release publication is requested, require the exact release commit's CI
  and artifact workflow to succeed before running the publish workflow.
