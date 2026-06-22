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

PKG="zova-$MANIFEST_VERSION"
TMP="${TMPDIR:-/tmp}/zova-check-release.$$"
CARGO_TARGET_REPO="$TMP/cargo-target/repo"
CARGO_TARGET_VERIFY="$TMP/cargo-target/verify"
PY_CARGO_TARGET_REPO="$TMP/cargo-target/python-repo"
PY_CARGO_TARGET_VERIFY="$TMP/cargo-target/python-verify"
PY_WHEEL_REPO="$TMP/python-wheels/repo"
PY_WHEEL_VERIFY="$TMP/python-wheels/verify"
GO_CACHE_REPO="$TMP/go-cache/repo"
GO_CACHE_VERIFY="$TMP/go-cache/verify"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

require_command tar
require_command cargo
require_command go
require_command uv

zig fmt --check build.zig build.zig.zon src/root.zig src/sqlite.zig src/zova.zig src/zova_test_support.zig src/object.zig src/object_fastcdc.zig src/object_tests.zig src/vector.zig src/vector_tests.zig src/vector_sql.zig src/vector_sql_tests.zig src/c_api.zig src/c_api_internal.zig src/c_api_tests.zig src/cli.zig src/main.zig tests/e2e.zig tests/cli.zig
zig build test
zig build e2e
zig build c-abi
zig build c-abi-test
zig build cli-test
zig build test -Doptimize=ReleaseSafe
zig build
zig build run
CARGO_TARGET_DIR="$CARGO_TARGET_REPO" cargo fmt --all --manifest-path bindings/rust/Cargo.toml --check
CARGO_TARGET_DIR="$CARGO_TARGET_REPO" cargo test --workspace --manifest-path bindings/rust/Cargo.toml
CARGO_TARGET_DIR="$CARGO_TARGET_REPO" cargo check --examples --manifest-path bindings/rust/Cargo.toml
(cd bindings/go && GOCACHE="$GO_CACHE_REPO" go test ./...)
(cd bindings/go && GOCACHE="$GO_CACHE_REPO" go vet ./...)
CARGO_TARGET_DIR="$PY_CARGO_TARGET_REPO" cargo fmt --manifest-path bindings/python/Cargo.toml --check
CARGO_TARGET_DIR="$PY_CARGO_TARGET_REPO" cargo test --manifest-path bindings/python/Cargo.toml
CARGO_TARGET_DIR="$PY_CARGO_TARGET_REPO" uv run --isolated --with maturin --with pytest --directory bindings/python maturin develop
uv run --isolated --with pytest --directory bindings/python python -m pytest
mkdir -p "$PY_WHEEL_REPO"
CARGO_TARGET_DIR="$PY_CARGO_TARGET_REPO" uv run --isolated --with maturin --directory bindings/python maturin build --out "$PY_WHEEL_REPO"
rm -rf bindings/python/target bindings/python/.venv bindings/python/.pytest_cache bindings/python/dist
find bindings/python -type d -name '__pycache__' -prune -exec rm -rf {} +
find bindings/python \( -name '*.so' -o -name '*.pyd' -o -name '*.dylib' -o -name '*.dll' -o -name '*.whl' \) -delete

rm -rf "$TMP"
mkdir -p "$TMP/$PKG"

cp build.zig build.zig.zon README.md "$TMP/$PKG/"
cp -R bindings "$TMP/$PKG/"
cp -R include "$TMP/$PKG/"
cp -R src "$TMP/$PKG/"
cp -R tests "$TMP/$PKG/"
cp -R vendor "$TMP/$PKG/"
rm -rf "$TMP/$PKG/bindings/rust/target"
rm -rf "$TMP/$PKG/bindings/python/target"
rm -rf "$TMP/$PKG/bindings/python/.venv"
rm -rf "$TMP/$PKG/bindings/python/.pytest_cache"
rm -rf "$TMP/$PKG/bindings/python/dist"
find "$TMP/$PKG/bindings/python" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$TMP/$PKG/bindings/python" \( -name '*.so' -o -name '*.pyd' -o -name '*.dylib' -o -name '*.dll' -o -name '*.whl' \) -delete

if find "$TMP/$PKG" -name '*.md' ! -path "$TMP/$PKG/README.md" ! -path "$TMP/$PKG/bindings/rust/README.md" ! -path "$TMP/$PKG/bindings/go/README.md" ! -path "$TMP/$PKG/bindings/python/README.md" | grep -q .; then
    echo "release package contains unexpected markdown files" >&2
    find "$TMP/$PKG" -name '*.md' ! -path "$TMP/$PKG/README.md" ! -path "$TMP/$PKG/bindings/rust/README.md" ! -path "$TMP/$PKG/bindings/go/README.md" ! -path "$TMP/$PKG/bindings/python/README.md" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/README.md" ]; then
    echo "release package is missing README.md" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/src" ]; then
    echo "release package is missing src" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/include/zova.h" ]; then
    echo "release package is missing include/zova.h" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/tests" ]; then
    echo "release package is missing tests" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/vendor" ]; then
    echo "release package is missing vendor" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/bindings/rust/Cargo.toml" ]; then
    echo "release package is missing bindings/rust/Cargo.toml" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/bindings/rust/README.md" ]; then
    echo "release package is missing bindings/rust/README.md" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/bindings/rust/zova-sys" ]; then
    echo "release package is missing bindings/rust/zova-sys" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/bindings/rust/zova" ]; then
    echo "release package is missing bindings/rust/zova" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/bindings/go/go.mod" ]; then
    echo "release package is missing bindings/go/go.mod" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/bindings/go/README.md" ]; then
    echo "release package is missing bindings/go/README.md" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/bindings/go/zova.go" ]; then
    echo "release package is missing bindings/go/zova.go" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/bindings/go/examples/basic" ]; then
    echo "release package is missing bindings/go/examples/basic" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/bindings/go/examples/objects" ]; then
    echo "release package is missing bindings/go/examples/objects" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/bindings/go/examples/vectors" ]; then
    echo "release package is missing bindings/go/examples/vectors" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/bindings/python/pyproject.toml" ]; then
    echo "release package is missing bindings/python/pyproject.toml" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/bindings/python/Cargo.toml" ]; then
    echo "release package is missing bindings/python/Cargo.toml" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/bindings/python/README.md" ]; then
    echo "release package is missing bindings/python/README.md" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/bindings/python/python/zova" ]; then
    echo "release package is missing bindings/python/python/zova" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/bindings/python/src" ]; then
    echo "release package is missing bindings/python/src" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/bindings/python/tests" ]; then
    echo "release package is missing bindings/python/tests" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/bindings/python/examples" ]; then
    echo "release package is missing bindings/python/examples" >&2
    exit 1
fi

if [ -e "$TMP/$PKG/zig-out" ]; then
    echo "release package must not contain compiled CLI artifacts" >&2
    exit 1
fi

if [ -e "$TMP/$PKG/bindings/rust/target" ]; then
    echo "release package must not contain compiled Rust artifacts" >&2
    exit 1
fi

if [ -e "$TMP/$PKG/bindings/python/target" ] || [ -e "$TMP/$PKG/bindings/python/dist" ] || [ -e "$TMP/$PKG/bindings/python/.venv" ]; then
    echo "release package must not contain compiled Python artifacts" >&2
    exit 1
fi

if find "$TMP/$PKG/bindings/python" \( -name '__pycache__' -o -name '.pytest_cache' -o -name '*.so' -o -name '*.pyd' -o -name '*.dylib' -o -name '*.dll' -o -name '*.whl' \) | grep -q .; then
    echo "release package must not contain Python cache/native/wheel artifacts" >&2
    find "$TMP/$PKG/bindings/python" \( -name '__pycache__' -o -name '.pytest_cache' -o -name '*.so' -o -name '*.pyd' -o -name '*.dylib' -o -name '*.dll' -o -name '*.whl' \) >&2
    exit 1
fi

tar -czf "$TMP/$PKG.tar.gz" -C "$TMP" "$PKG"

VERIFY_DIR="$TMP/verify"
mkdir -p "$VERIFY_DIR"
tar -xzf "$TMP/$PKG.tar.gz" -C "$VERIFY_DIR"
cd "$VERIFY_DIR/$PKG"

zig fmt --check build.zig build.zig.zon src/root.zig src/sqlite.zig src/zova.zig src/zova_test_support.zig src/object.zig src/object_fastcdc.zig src/object_tests.zig src/vector.zig src/vector_tests.zig src/vector_sql.zig src/vector_sql_tests.zig src/c_api.zig src/c_api_internal.zig src/c_api_tests.zig src/cli.zig src/main.zig tests/e2e.zig tests/cli.zig
zig build test
zig build e2e
zig build c-abi
zig build c-abi-test
zig build cli-test
zig build test -Doptimize=ReleaseSafe
zig build
zig build run
CARGO_TARGET_DIR="$CARGO_TARGET_VERIFY" cargo fmt --all --manifest-path bindings/rust/Cargo.toml --check
CARGO_TARGET_DIR="$CARGO_TARGET_VERIFY" cargo test --workspace --manifest-path bindings/rust/Cargo.toml
CARGO_TARGET_DIR="$CARGO_TARGET_VERIFY" cargo check --examples --manifest-path bindings/rust/Cargo.toml
(cd bindings/go && GOCACHE="$GO_CACHE_VERIFY" go test ./...)
(cd bindings/go && GOCACHE="$GO_CACHE_VERIFY" go vet ./...)
CARGO_TARGET_DIR="$PY_CARGO_TARGET_VERIFY" cargo fmt --manifest-path bindings/python/Cargo.toml --check
CARGO_TARGET_DIR="$PY_CARGO_TARGET_VERIFY" cargo test --manifest-path bindings/python/Cargo.toml
CARGO_TARGET_DIR="$PY_CARGO_TARGET_VERIFY" uv run --isolated --with maturin --with pytest --directory bindings/python maturin develop
uv run --isolated --with pytest --directory bindings/python python -m pytest
mkdir -p "$PY_WHEEL_VERIFY"
CARGO_TARGET_DIR="$PY_CARGO_TARGET_VERIFY" uv run --isolated --with maturin --directory bindings/python maturin build --out "$PY_WHEEL_VERIFY"
