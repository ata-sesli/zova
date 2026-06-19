#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$ROOT/zig-out/release}"
VERSION="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n 1)"

if [ -z "$VERSION" ]; then
    echo "could not read version from build.zig.zon" >&2
    exit 1
fi

PKG="zova-$VERSION"
ARCHIVE="$OUT_DIR/$PKG.tar.gz"
TMP="${TMPDIR:-/tmp}/zova-release.$$"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

cd "$ROOT"
"$ROOT/scripts/check-release.sh"

rm -rf "$TMP"
mkdir -p "$TMP/$PKG" "$OUT_DIR"

cp build.zig build.zig.zon README.md "$TMP/$PKG/"
cp -R src "$TMP/$PKG/"
cp -R vendor "$TMP/$PKG/"

if find "$TMP/$PKG" -name '*.md' ! -name README.md | grep -q .; then
    echo "release package contains markdown files other than README.md" >&2
    find "$TMP/$PKG" -name '*.md' ! -name README.md >&2
    exit 1
fi

tar -czf "$ARCHIVE" -C "$TMP" "$PKG"

VERIFY_DIR="$TMP/verify"
mkdir -p "$VERIFY_DIR"
tar -xzf "$ARCHIVE" -C "$VERIFY_DIR"
cd "$VERIFY_DIR/$PKG"

zig fmt --check build.zig build.zig.zon src/root.zig src/sqlite.zig src/main.zig
zig build test
zig build test -Doptimize=ReleaseSafe
zig build
zig build run

echo "release source archive: $ARCHIVE"
