#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/bindings/rust/zova-sys/native/generated}"
VERSION_ZIG="$ROOT/src/version.zig"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

require_command zig

SQLITE_VERSION="$(sed -n 's/^[[:space:]]*pub const sqlite_version[[:space:]]*=[[:space:]]*"\([^"]*\)";.*/\1/p' "$VERSION_ZIG" | head -n 1)"
if [ -z "$SQLITE_VERSION" ]; then
    echo "could not read sqlite_version from src/version.zig" >&2
    exit 1
fi
SQLITE_DIR="$ROOT/vendor/sqlite$SQLITE_VERSION"
if [ ! -d "$SQLITE_DIR" ]; then
    echo "missing SQLite vendor directory: $SQLITE_DIR" >&2
    exit 1
fi

ZIG_LIB_DIR="$(zig env | sed -n 's/^[[:space:]]*\.lib_dir[[:space:]]*=[[:space:]]*"\([^"]*\)",[[:space:]]*$/\1/p')"
if [ -z "$ZIG_LIB_DIR" ]; then
    echo "could not determine Zig lib_dir from zig env" >&2
    exit 1
fi

if [ ! -f "$ZIG_LIB_DIR/zig.h" ]; then
    echo "missing Zig generated-C support header: $ZIG_LIB_DIR/zig.h" >&2
    exit 1
fi

TMP="${TMPDIR:-/tmp}/zova-update-generated-c.$$"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

rm -rf "$TMP" "$OUT"
mkdir -p "$TMP" "$OUT"

BUILD_OPTIONS="$TMP/zova_build_options.zig"
printf '%s\n' 'pub const enable_dynamic_extensions = false;' >"$BUILD_OPTIONS"

zig build-lib \
    -ofmt=c \
    -O ReleaseSafe \
    -I "$SQLITE_DIR" \
    -lc \
    -femit-bin="$OUT/zova_c.c" \
    --cache-dir "$TMP/zig-cache" \
    --global-cache-dir "$TMP/global-zig-cache" \
    --dep zova_build_options \
    -Mroot="$ROOT/src/c_api.zig" \
    -Mzova_build_options="$BUILD_OPTIONS"

cp "$ZIG_LIB_DIR/zig.h" "$OUT/zig.h"
cp "$ROOT/include/zova.h" "$OUT/zova.h"
cp "$SQLITE_DIR/sqlite3.c" "$OUT/sqlite3.c"
cp "$SQLITE_DIR/sqlite3.h" "$OUT/sqlite3.h"
cp "$SQLITE_DIR/sqlite3ext.h" "$OUT/sqlite3ext.h"

echo "generated C bundle written to $OUT"
