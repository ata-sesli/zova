#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "usage: scripts/package-release.sh <version> [out-dir]" >&2
    echo "example: scripts/package-release.sh 0.1.0" >&2
}

run() {
    echo "+ $*"
    "$@"
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
        git tag -d "$TAG" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP"
    exit "$status"
}
trap cleanup EXIT INT TERM

cd "$ROOT"

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

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "tag already exists: $TAG" >&2
    exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "tag already exists on origin: $TAG" >&2
    exit 1
fi

"$ROOT/scripts/check-release.sh"
run git tag -a "$TAG" -m "Zova $VERSION"
TAG_CREATED=1

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

run git push origin "$CURRENT_BRANCH"
run git push origin "$TAG"

TAG_CREATED=0
echo "release source archive: $ARCHIVE"
echo "release tag: $TAG"
echo "pushed branch: $CURRENT_BRANCH"
