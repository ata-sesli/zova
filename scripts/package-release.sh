#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "usage: scripts/package-release.sh <version> [out-dir]" >&2
    echo "example: scripts/package-release.sh 0.12.1" >&2
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

if [ ! -f "$TMP/$PKG/include/zova.h" ]; then
    echo "release package is missing include/zova.h" >&2
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
