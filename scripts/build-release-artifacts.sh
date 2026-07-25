#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/build-release-artifacts.sh <version> <artifact-id> [out-dir]
example: scripts/build-release-artifacts.sh 0.26.0 macos-arm64 zig-out/artifacts

Builds host-platform release artifacts:
  - CLI archive
  - C ABI static-library archive
  - generated-C source archive
  - SHA-256 checksum file

This script does not tag, publish, or upload anything.
EOF
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

sha256_file() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file"
    else
        shasum -a 256 "$file"
    fi
}

manifest_version() {
    sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n 1
}

write_manifest() {
    destination="$1"
    name="$2"
    version="$3"
    artifact_id="$4"

    {
        echo "name: $name"
        echo "version: $version"
        echo "artifact_id: $artifact_id"
        echo "commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "source: https://github.com/atasesli/zova"
    } >"$destination/MANIFEST.txt"
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    usage
    exit 2
fi

VERSION="${1#v}"
ARTIFACT_ID="$2"
OUT_DIR="${3:-$ROOT/zig-out/artifacts}"
MANIFEST_VERSION="$(manifest_version)"

if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "invalid version: $VERSION" >&2
    usage
    exit 2
fi

if [ "$VERSION" != "$MANIFEST_VERSION" ]; then
    echo "version argument ($VERSION) does not match build.zig.zon ($MANIFEST_VERSION)" >&2
    exit 1
fi

require_command git
require_command zig
require_command tar

TMP="${TMPDIR:-/tmp}/zova-build-release-artifacts.$$"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

rm -rf "$TMP"
mkdir -p "$TMP" "$OUT_DIR"

CLI_PREFIX="$TMP/cli-install"
CABI_PREFIX="$TMP/c-abi-install"

echo "building CLI artifact for $ARTIFACT_ID"
zig build -Doptimize=ReleaseSafe -p "$CLI_PREFIX"

CLI_BIN="$CLI_PREFIX/bin/zova"
CLI_ARCHIVE="$OUT_DIR/zova-v$VERSION-$ARTIFACT_ID-cli.tar.gz"
if [ -f "$CLI_PREFIX/bin/zova.exe" ]; then
    CLI_BIN="$CLI_PREFIX/bin/zova.exe"
fi
if [ ! -f "$CLI_BIN" ]; then
    echo "missing built CLI binary under $CLI_PREFIX/bin" >&2
    exit 1
fi

CLI_DIR="$TMP/zova-v$VERSION-$ARTIFACT_ID-cli"
mkdir -p "$CLI_DIR/bin"
cp "$CLI_BIN" "$CLI_DIR/bin/"
cp "$ROOT/LICENSE" "$CLI_DIR/LICENSE"
write_manifest "$CLI_DIR" "zova-cli" "$VERSION" "$ARTIFACT_ID"
"$CLI_DIR/bin/$(basename "$CLI_BIN")" --version
tar -czf "$CLI_ARCHIVE" -C "$TMP" "$(basename "$CLI_DIR")"

echo "building C ABI artifact for $ARTIFACT_ID"
zig build c-abi -Doptimize=ReleaseSafe -p "$CABI_PREFIX"
if [ "$(uname -s)" = "Darwin" ]; then
    sh "$ROOT/scripts/repack-darwin-c-abi.sh" "$CABI_PREFIX/lib/libzova_c.a"
fi

CABI_LIB="$CABI_PREFIX/lib/libzova_c.a"
if [ -f "$CABI_PREFIX/lib/zova_c.lib" ]; then
    CABI_LIB="$CABI_PREFIX/lib/zova_c.lib"
fi
if [ ! -f "$CABI_LIB" ]; then
    echo "missing built C ABI static library under $CABI_PREFIX/lib" >&2
    exit 1
fi

CABI_DIR="$TMP/zova-v$VERSION-$ARTIFACT_ID-c-abi"
mkdir -p "$CABI_DIR/lib" "$CABI_DIR/include"
cp "$CABI_LIB" "$CABI_DIR/lib/"
cp "$ROOT/include/zova.h" "$CABI_DIR/include/zova.h"
cp "$ROOT/LICENSE" "$CABI_DIR/LICENSE"
write_manifest "$CABI_DIR" "zova-c-abi" "$VERSION" "$ARTIFACT_ID"
CABI_ARCHIVE="$OUT_DIR/zova-v$VERSION-$ARTIFACT_ID-c-abi.tar.gz"
tar -czf "$CABI_ARCHIVE" -C "$TMP" "$(basename "$CABI_DIR")"

echo "building generated-C source artifact"
GENERATED_DIR="$TMP/zova-v$VERSION-$ARTIFACT_ID-generated-c"
mkdir -p "$GENERATED_DIR"
sh "$ROOT/scripts/update-generated-c.sh" "$GENERATED_DIR"
cp "$ROOT/LICENSE" "$GENERATED_DIR/LICENSE"
write_manifest "$GENERATED_DIR" "zova-generated-c" "$VERSION" "$ARTIFACT_ID"
GENERATED_ARCHIVE="$OUT_DIR/zova-v$VERSION-$ARTIFACT_ID-generated-c.tar.gz"
tar -czf "$GENERATED_ARCHIVE" -C "$TMP" "$(basename "$GENERATED_DIR")"

CHECKSUMS="$OUT_DIR/zova-v$VERSION-$ARTIFACT_ID-checksums.txt"
: >"$CHECKSUMS"
sha256_file "$CLI_ARCHIVE" >>"$CHECKSUMS"
sha256_file "$CABI_ARCHIVE" >>"$CHECKSUMS"
sha256_file "$GENERATED_ARCHIVE" >>"$CHECKSUMS"

echo "release artifacts written to $OUT_DIR"
ls -lh "$CLI_ARCHIVE" "$CABI_ARCHIVE" "$GENERATED_ARCHIVE" "$CHECKSUMS"
