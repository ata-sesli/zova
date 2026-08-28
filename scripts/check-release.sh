#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

MANIFEST_VERSION="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n 1)"
if [ -z "$MANIFEST_VERSION" ]; then
    echo "could not read version from build.zig.zon" >&2
    exit 1
fi
RUST_WORKSPACE_VERSION="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/bindings/rust/Cargo.toml" | head -n 1)"
if [ -z "$RUST_WORKSPACE_VERSION" ]; then
    echo "could not read version from bindings/rust/Cargo.toml" >&2
    exit 1
fi

TMP="${TMPDIR:-/tmp}/zova-check-release.$$"
CARGO_TARGET_REPO="$TMP/cargo-target/repo"
PY_CARGO_TARGET_REPO="$TMP/cargo-target/python-repo"
PY_WHEEL_REPO="$TMP/python-wheels/repo"
GO_CACHE_REPO="$TMP/go-cache/repo"
JS_CARGO_TARGET_REPO="$TMP/cargo-target/javascript-repo"
NPM_CACHE_REPO="$TMP/npm-cache"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

require_command zig
require_command cargo
require_command go
require_command uv
require_command bun
require_command node
require_command npm

sh scripts/check-versions.sh
zig fmt --check build.zig build.zig.zon src/root.zig src/version.zig src/sqlite.zig src/zova.zig src/zova_error.zig src/zova_test_support.zig src/extension.zig src/extension_dynamic.zig src/notify.zig src/object.zig src/object_fastcdc.zig src/object_tests.zig src/vector.zig src/vector_tests.zig src/vector_sql.zig src/vector_sql_tests.zig src/graph.zig src/graph_tests.zig src/graph_sql.zig src/graph_sql_tests.zig src/trgm.zig src/trgm_tests.zig src/c_api.zig src/c_api_internal.zig src/c_api_tests.zig src/cli.zig src/main.zig src/storage_compat_check.zig tests/dynamic_extension_fixture.zig tests/e2e.zig tests/cli.zig
zig build test
# The 1.x storage compatibility promise is a release gate: every retained
# fixture must probe, migrate, and reopen exactly as docs/storage-compatibility.md
# states, and no promised migration path may be missing.
zig build check-storage-compat
zig build e2e
zig build c-abi
zig build c-abi-test
sh scripts/check-generated-c.sh
zig build cli-test
zig build test -Doptimize=ReleaseSafe
zig build
zig build run
# Binding tests must consume native snapshots generated from the current tree,
# not ignored files left behind by an earlier release version.
sh bindings/rust/zova-sys/tools/sync-native-source.sh
sh bindings/rust/zova-sys/tools/check-native-source.sh
CARGO_TARGET_DIR="$CARGO_TARGET_REPO" cargo fmt --all --manifest-path bindings/rust/Cargo.toml --check
CARGO_TARGET_DIR="$CARGO_TARGET_REPO" cargo test --workspace --manifest-path bindings/rust/Cargo.toml
CARGO_TARGET_DIR="$CARGO_TARGET_REPO" cargo check --examples --manifest-path bindings/rust/Cargo.toml
# zova-sys intentionally packages a generated native source snapshot that stays
# git-ignored in the repository. Sync and check it first. Release smoke may run
# before committing local changes, so package dry-runs use the current tree.
CARGO_TARGET_DIR="$CARGO_TARGET_REPO" cargo package --allow-dirty --list -p zova-sys --manifest-path bindings/rust/Cargo.toml >/dev/null
CARGO_TARGET_DIR="$CARGO_TARGET_REPO" cargo package --allow-dirty --list -p zova --manifest-path bindings/rust/Cargo.toml >/dev/null
CARGO_TARGET_DIR="$CARGO_TARGET_REPO" cargo publish --allow-dirty --dry-run -p zova-sys --manifest-path bindings/rust/Cargo.toml
if [ "${ZOVA_CHECK_PUBLISHED_RUST_SAFE_CRATE:-0}" = "1" ]; then
    CARGO_TARGET_DIR="$CARGO_TARGET_REPO" cargo publish --allow-dirty --dry-run -p zova --manifest-path bindings/rust/Cargo.toml
else
    echo "skipping zova publish dry-run until zova-sys $RUST_WORKSPACE_VERSION is published"
fi
sh scripts/repack-darwin-c-abi.sh
(cd bindings/go && GOCACHE="$GO_CACHE_REPO" go test ./...)
(cd bindings/go && GOCACHE="$GO_CACHE_REPO" go vet ./...)
sh bindings/python/tools/sync-rust-source.sh
sh bindings/python/tools/check-rust-source.sh
CARGO_TARGET_DIR="$PY_CARGO_TARGET_REPO" cargo fmt --manifest-path bindings/python/Cargo.toml --check
CARGO_TARGET_DIR="$PY_CARGO_TARGET_REPO" cargo test --manifest-path bindings/python/Cargo.toml
CARGO_TARGET_DIR="$PY_CARGO_TARGET_REPO" uv run --isolated --with maturin --with pytest --directory bindings/python maturin develop
uv run --isolated --with pytest --directory bindings/python python -m pytest
mkdir -p "$PY_WHEEL_REPO"
CARGO_TARGET_DIR="$PY_CARGO_TARGET_REPO" uv run --isolated --with maturin --directory bindings/python maturin build --sdist --out "$PY_WHEEL_REPO"
if ! find "$PY_WHEEL_REPO" -name "zova-$MANIFEST_VERSION-*.whl" | grep -q .; then
    echo "Python release artifacts are missing a wheel" >&2
    exit 1
fi
if [ ! -f "$PY_WHEEL_REPO/zova-$MANIFEST_VERSION.tar.gz" ]; then
    echo "Python release artifacts are missing an sdist" >&2
    exit 1
fi
rm -rf bindings/python/target bindings/python/.venv bindings/python/.pytest_cache bindings/python/dist
find bindings/python -type d -name '__pycache__' -prune -exec rm -rf {} +
find bindings/python \( -name '*.so' -o -name '*.pyd' -o -name '*.dylib' -o -name '*.dll' -o -name '*.whl' \) -delete

(cd bindings/javascript && bun install --frozen-lockfile)
CARGO_TARGET_DIR="$JS_CARGO_TARGET_REPO" cargo fmt --manifest-path bindings/javascript/Cargo.toml --check
CARGO_TARGET_DIR="$JS_CARGO_TARGET_REPO" cargo nextest run --manifest-path bindings/javascript/Cargo.toml
(cd bindings/javascript && bun run build)
(cd bindings/javascript && bun run typecheck)
(cd bindings/javascript && bun run test)
node bindings/javascript/tests/runtime-smoke.mjs
node bindings/javascript/tests/runtime-smoke.cjs
bun bindings/javascript/tests/runtime-smoke.mjs
(cd bindings/javascript && npm_config_cache="$NPM_CACHE_REPO" npm pack --dry-run --ignore-scripts >/dev/null)
rm -rf bindings/javascript/target bindings/javascript/dist bindings/javascript/npm
find bindings/javascript -maxdepth 1 -name '*.node' -delete

echo "release check ok: $MANIFEST_VERSION"
