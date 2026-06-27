#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "usage: scripts/package-release.sh <version> [out-dir]" >&2
    echo "example: scripts/package-release.sh 0.17.0" >&2
}

run() {
    echo "+ $*"
    "$@"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage
    exit 2
fi

VERSION="${1#v}"
TAG="v$VERSION"
OUT_DIR="${2:-$ROOT/zig-out/release}"
MANIFEST_VERSION="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n 1)"

if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "invalid version: $1" >&2
    usage
    exit 2
fi

if [ -z "$MANIFEST_VERSION" ]; then
    echo "could not read version from build.zig.zon" >&2
    exit 1
fi

if [ "$VERSION" != "$MANIFEST_VERSION" ]; then
    echo "version argument ($VERSION) does not match build.zig.zon ($MANIFEST_VERSION)" >&2
    exit 1
fi

PKG="zova-$VERSION"
ARCHIVE="$OUT_DIR/$PKG.tar.gz"
TMP="${TMPDIR:-/tmp}/zova-release.$$"
TAG_CREATED=0

cleanup() {
    status=$?
    if [ "$status" -ne 0 ] && [ "$TAG_CREATED" -eq 1 ]; then
        git -C "$ROOT" tag -d "$TAG" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP"
    exit "$status"
}
trap cleanup EXIT INT TERM

cd "$ROOT"

require_command git
require_command gh
require_command tar
require_command cargo
require_command go
require_command uv

if ! gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI is not authenticated. Run: gh auth login" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "working tree is not clean; commit or stash changes before tagging a release" >&2
    git status --short >&2
    exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [ -z "$CURRENT_BRANCH" ]; then
    echo "could not determine current git branch" >&2
    exit 1
fi

HEAD_COMMIT="$(git rev-parse HEAD)"
LOCAL_TAG_COMMIT=""
REMOTE_TAG_COMMIT="$(git ls-remote --tags origin "refs/tags/$TAG^{}" | awk 'NR == 1 {print $1}')"
if [ -z "$REMOTE_TAG_COMMIT" ]; then
    REMOTE_TAG_COMMIT="$(git ls-remote --tags origin "refs/tags/$TAG" | awk 'NR == 1 {print $1}')"
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    LOCAL_TAG_COMMIT="$(git rev-list -n 1 "$TAG")"
    if [ "$LOCAL_TAG_COMMIT" != "$HEAD_COMMIT" ]; then
        echo "local tag $TAG does not point at HEAD" >&2
        exit 1
    fi
fi

if [ -n "$REMOTE_TAG_COMMIT" ] && [ "$REMOTE_TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    echo "origin tag $TAG does not point at HEAD" >&2
    exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "GitHub Release already exists: $TAG" >&2
    exit 1
fi

"$ROOT/scripts/check-release.sh"

rm -rf "$TMP"
mkdir -p "$TMP/$PKG" "$OUT_DIR"

cp build.zig build.zig.zon LICENSE README.md "$TMP/$PKG/"
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

if find "$TMP/$PKG" -name '*.md' ! -path "$TMP/$PKG/README.md" ! -path "$TMP/$PKG/bindings/rust/README.md" ! -path "$TMP/$PKG/bindings/rust/zova-sys/README.md" ! -path "$TMP/$PKG/bindings/rust/zova/README.md" ! -path "$TMP/$PKG/bindings/go/README.md" ! -path "$TMP/$PKG/bindings/python/README.md" | grep -q .; then
    echo "release package contains unexpected markdown files" >&2
    find "$TMP/$PKG" -name '*.md' ! -path "$TMP/$PKG/README.md" ! -path "$TMP/$PKG/bindings/rust/README.md" ! -path "$TMP/$PKG/bindings/rust/zova-sys/README.md" ! -path "$TMP/$PKG/bindings/rust/zova/README.md" ! -path "$TMP/$PKG/bindings/go/README.md" ! -path "$TMP/$PKG/bindings/python/README.md" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/LICENSE" ]; then
    echo "release package is missing LICENSE" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/include/zova.h" ]; then
    echo "release package is missing include/zova.h" >&2
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

if [ ! -f "$TMP/$PKG/bindings/rust/zova-sys/README.md" ]; then
    echo "release package is missing bindings/rust/zova-sys/README.md" >&2
    exit 1
fi

if [ ! -d "$TMP/$PKG/bindings/rust/zova" ]; then
    echo "release package is missing bindings/rust/zova" >&2
    exit 1
fi

if [ ! -f "$TMP/$PKG/bindings/rust/zova/README.md" ]; then
    echo "release package is missing bindings/rust/zova/README.md" >&2
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

tar -czf "$ARCHIVE" -C "$TMP" "$PKG"

VERIFY_DIR="$TMP/verify"
mkdir -p "$VERIFY_DIR"
tar -xzf "$ARCHIVE" -C "$VERIFY_DIR"
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
CARGO_TARGET_DIR="$TMP/cargo-target/verify" cargo fmt --all --manifest-path bindings/rust/Cargo.toml --check
CARGO_TARGET_DIR="$TMP/cargo-target/verify" cargo test --workspace --manifest-path bindings/rust/Cargo.toml
CARGO_TARGET_DIR="$TMP/cargo-target/verify" cargo check --examples --manifest-path bindings/rust/Cargo.toml
(cd bindings/go && GOCACHE="$TMP/go-cache/verify" go test ./...)
(cd bindings/go && GOCACHE="$TMP/go-cache/verify" go vet ./...)
CARGO_TARGET_DIR="$TMP/cargo-target/python-verify" cargo fmt --manifest-path bindings/python/Cargo.toml --check
CARGO_TARGET_DIR="$TMP/cargo-target/python-verify" cargo test --manifest-path bindings/python/Cargo.toml
CARGO_TARGET_DIR="$TMP/cargo-target/python-verify" uv run --isolated --with maturin --with pytest --directory bindings/python maturin develop
uv run --isolated --with pytest --directory bindings/python python -m pytest
mkdir -p "$TMP/python-wheels/verify"
CARGO_TARGET_DIR="$TMP/cargo-target/python-verify" uv run --isolated --with maturin --directory bindings/python maturin build --out "$TMP/python-wheels/verify"

cd "$ROOT"
if [ -z "$LOCAL_TAG_COMMIT" ]; then
    run git tag -a "$TAG" -m "Zova $VERSION"
    TAG_CREATED=1
else
    echo "reusing local tag: $TAG"
fi
run git push origin "$CURRENT_BRANCH"
if [ -z "$REMOTE_TAG_COMMIT" ]; then
    run git push origin "$TAG"
else
    echo "reusing origin tag: $TAG"
fi
run gh release create "$TAG" "$ARCHIVE" --title "Zova $TAG" --notes "Zova $TAG" --verify-tag

TAG_CREATED=0
echo "release source archive: $ARCHIVE"
echo "release tag: $TAG"
echo "pushed branch: $CURRENT_BRANCH"
echo "GitHub Release: $TAG"
