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

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

require_command tar

zig fmt --check build.zig build.zig.zon src/root.zig src/sqlite.zig src/zova.zig src/object.zig src/object_fastcdc.zig src/vector.zig src/vector_sql.zig src/c_api.zig src/c_api_internal.zig src/c_api_tests.zig src/cli.zig src/main.zig tests/e2e.zig tests/cli.zig
zig build test
zig build e2e
zig build c-abi
zig build c-abi-test
zig build cli-test
zig build test -Doptimize=ReleaseSafe
zig build
zig build run

rm -rf "$TMP"
mkdir -p "$TMP/$PKG"

cp build.zig build.zig.zon README.md "$TMP/$PKG/"
cp -R include "$TMP/$PKG/"
cp -R src "$TMP/$PKG/"
cp -R tests "$TMP/$PKG/"
cp -R vendor "$TMP/$PKG/"

if find "$TMP/$PKG" -name '*.md' ! -name README.md | grep -q .; then
    echo "release package contains markdown files other than README.md" >&2
    find "$TMP/$PKG" -name '*.md' ! -name README.md >&2
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

if [ -e "$TMP/$PKG/zig-out" ]; then
    echo "release package must not contain compiled CLI artifacts" >&2
    exit 1
fi

tar -czf "$TMP/$PKG.tar.gz" -C "$TMP" "$PKG"

VERIFY_DIR="$TMP/verify"
mkdir -p "$VERIFY_DIR"
tar -xzf "$TMP/$PKG.tar.gz" -C "$VERIFY_DIR"
cd "$VERIFY_DIR/$PKG"

zig fmt --check build.zig build.zig.zon src/root.zig src/sqlite.zig src/zova.zig src/object.zig src/object_fastcdc.zig src/vector.zig src/vector_sql.zig src/c_api.zig src/c_api_internal.zig src/c_api_tests.zig src/cli.zig src/main.zig tests/e2e.zig tests/cli.zig
zig build test
zig build e2e
zig build c-abi
zig build c-abi-test
zig build cli-test
zig build test -Doptimize=ReleaseSafe
zig build
zig build run
