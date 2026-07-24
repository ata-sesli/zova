#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "usage: scripts/verify-source-package.sh <zova-version.tar.gz>" >&2
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

ARCHIVE="$1"
if [ ! -f "$ARCHIVE" ]; then
    echo "source archive does not exist: $ARCHIVE" >&2
    exit 1
fi

require_command tar
require_command zig
require_command cargo
require_command go
require_command uv
require_command bun
require_command node
require_command npm

TMP="${TMPDIR:-/tmp}/zova-verify-source-package.$$"
CARGO_TARGET_VERIFY="$TMP/cargo-target/rust"
PY_CARGO_TARGET_VERIFY="$TMP/cargo-target/python"
JS_CARGO_TARGET_VERIFY="$TMP/cargo-target/javascript"
GO_CACHE_VERIFY="$TMP/go-cache"
PY_WHEEL_VERIFY="$TMP/python-wheels"
NPM_CACHE_VERIFY="$TMP/npm-cache"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP"
tar -xzf "$ARCHIVE" -C "$TMP"

PACKAGE_DIR="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'zova-*' | head -n 1)"
if [ -z "$PACKAGE_DIR" ]; then
    echo "source archive did not contain a zova-* directory" >&2
    exit 1
fi

cd "$PACKAGE_DIR"
VERSION="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon | head -n 1)"
if [ -z "$VERSION" ]; then
    echo "could not read source package version from build.zig.zon" >&2
    exit 1
fi

if [ -e zig-out ]; then
    echo "source package must not contain compiled Zig artifacts" >&2
    exit 1
fi
if [ -e bindings/rust/target ]; then
    echo "source package must not contain compiled Rust artifacts" >&2
    exit 1
fi
if [ -e bindings/python/rust ]; then
    echo "source package must not contain generated Python Rust snapshot" >&2
    exit 1
fi
if find bindings/go \( -name '*.test' -o -name '*.out' -o -name '*.exe' -o -name 'coverage.txt' -o -name 'coverage.out' \) | grep -q .; then
    echo "source package must not contain Go build/test artifacts" >&2
    exit 1
fi
if find bindings/python \( -name '__pycache__' -o -name '.pytest_cache' -o -name '*.so' -o -name '*.pyd' -o -name '*.dylib' -o -name '*.dll' -o -name '*.whl' \) | grep -q .; then
    echo "source package must not contain Python cache/native/wheel artifacts" >&2
    exit 1
fi
if [ -e bindings/javascript/node_modules ] || [ -e bindings/javascript/target ] || [ -e bindings/javascript/dist ] || [ -e bindings/javascript/examples/dist ] || [ -e bindings/javascript/npm ] || [ -e bindings/javascript/package ] || [ -e bindings/javascript/package-smoke ]; then
    echo "source package must not contain compiled JavaScript binding artifacts" >&2
    exit 1
fi
if find bindings/javascript -maxdepth 1 \( -name '*.node' -o -name 'index.js' -o -name 'index.d.ts' \) | grep -q .; then
    echo "source package must not contain generated JavaScript binding artifacts" >&2
    exit 1
fi

zig fmt --check build.zig build.zig.zon src/root.zig src/sqlite.zig src/zova.zig src/zova_error.zig src/zova_test_support.zig src/extension.zig src/extension_dynamic.zig src/notify.zig src/object.zig src/object_fastcdc.zig src/object_tests.zig src/vector.zig src/vector_tests.zig src/vector_sql.zig src/vector_sql_tests.zig src/graph.zig src/graph_tests.zig src/graph_sql.zig src/graph_sql_tests.zig src/trgm.zig src/trgm_tests.zig src/c_api.zig src/c_api_internal.zig src/c_api_tests.zig src/cli.zig src/main.zig tests/dynamic_extension_fixture.zig tests/e2e.zig tests/cli.zig
zig build c-abi
zig build
zig build run
sh scripts/check-generated-c.sh

CARGO_TARGET_DIR="$CARGO_TARGET_VERIFY" cargo fmt --all --manifest-path bindings/rust/Cargo.toml --check
CARGO_TARGET_DIR="$CARGO_TARGET_VERIFY" cargo check --workspace --manifest-path bindings/rust/Cargo.toml
CARGO_TARGET_DIR="$CARGO_TARGET_VERIFY" cargo check --examples --manifest-path bindings/rust/Cargo.toml
sh bindings/rust/zova-sys/tools/sync-native-source.sh
sh bindings/rust/zova-sys/tools/check-native-source.sh
ZOVA_SYS_PACKAGE_LIST="$TMP/zova-sys-package-list.txt"
CARGO_TARGET_DIR="$CARGO_TARGET_VERIFY" cargo package --allow-dirty --list -p zova-sys --manifest-path bindings/rust/Cargo.toml >"$ZOVA_SYS_PACKAGE_LIST"
if ! grep -qx 'native/LICENSE' "$ZOVA_SYS_PACKAGE_LIST"; then
    echo "zova-sys crate package is missing native/LICENSE" >&2
    exit 1
fi
if ! grep -qx 'native/generated/zova_c.c' "$ZOVA_SYS_PACKAGE_LIST"; then
    echo "zova-sys crate package is missing generated C source" >&2
    exit 1
fi
if grep -q '^native/src/' "$ZOVA_SYS_PACKAGE_LIST"; then
    echo "zova-sys crate package must not include the full Zig source snapshot" >&2
    exit 1
fi

sh scripts/repack-darwin-c-abi.sh
(cd bindings/go && GOCACHE="$GO_CACHE_VERIFY" go test ./...)

sh bindings/python/tools/sync-rust-source.sh
sh bindings/python/tools/check-rust-source.sh
CARGO_TARGET_DIR="$PY_CARGO_TARGET_VERIFY" cargo fmt --manifest-path bindings/python/Cargo.toml --check
CARGO_TARGET_DIR="$PY_CARGO_TARGET_VERIFY" cargo check --manifest-path bindings/python/Cargo.toml
mkdir -p "$PY_WHEEL_VERIFY"
CARGO_TARGET_DIR="$PY_CARGO_TARGET_VERIFY" uv run --isolated --with maturin --directory bindings/python maturin build --sdist --out "$PY_WHEEL_VERIFY"
if ! find "$PY_WHEEL_VERIFY" -name "zova-$VERSION-*.whl" | grep -q .; then
    echo "Python source package verification is missing a wheel" >&2
    exit 1
fi
if [ ! -f "$PY_WHEEL_VERIFY/zova-$VERSION.tar.gz" ]; then
    echo "Python source package verification is missing an sdist" >&2
    exit 1
fi

(cd bindings/javascript && bun install --frozen-lockfile)
CARGO_TARGET_DIR="$JS_CARGO_TARGET_VERIFY" cargo fmt --manifest-path bindings/javascript/Cargo.toml --check
CARGO_TARGET_DIR="$JS_CARGO_TARGET_VERIFY" cargo nextest run --manifest-path bindings/javascript/Cargo.toml
(cd bindings/javascript && bun run build)
(cd bindings/javascript && bun run typecheck)
(cd bindings/javascript && bun test)
node bindings/javascript/tests/runtime-smoke.mjs
node bindings/javascript/tests/runtime-smoke.cjs
bun bindings/javascript/tests/runtime-smoke.mjs
(cd bindings/javascript && npm_config_cache="$NPM_CACHE_VERIFY" npm pack --dry-run --ignore-scripts >/dev/null)

echo "source package verification ok: $ARCHIVE"
