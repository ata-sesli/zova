#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/bindings/rust/zova-sys/native/generated}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

require_command zig

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

zig build-lib "$ROOT/src/c_api.zig" \
    -ofmt=c \
    -O ReleaseSafe \
    -I "$ROOT/vendor/sqlite3.53.2" \
    -lc \
    -femit-bin="$OUT/zova_c.c" \
    --cache-dir "$TMP/zig-cache" \
    --global-cache-dir "$TMP/global-zig-cache"

cp "$ZIG_LIB_DIR/zig.h" "$OUT/zig.h"
cp "$ROOT/include/zova.h" "$OUT/zova.h"
cp "$ROOT/vendor/sqlite3.53.2/sqlite3.c" "$OUT/sqlite3.c"
cp "$ROOT/vendor/sqlite3.53.2/sqlite3.h" "$OUT/sqlite3.h"
cp "$ROOT/vendor/sqlite3.53.2/sqlite3ext.h" "$OUT/sqlite3ext.h"

echo "generated C bundle written to $OUT"
