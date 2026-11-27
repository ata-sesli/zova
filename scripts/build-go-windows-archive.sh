#!/usr/bin/env sh
# Builds libzova_c.a for Go/cgo on Windows x86_64.
#
# cgo uses MinGW GCC there, not the MSVC toolchain of the release C ABI
# archive (zova_c.lib), so the archive is compiled from x86_64-windows-gnu
# generated C, as scripts/check-plugin-packages.py does. Zig cross-compiles,
# so this runs on any host.
#
#   scripts/build-go-windows-archive.sh <out-dir>   writes <out-dir>/libzova_c.a
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: scripts/build-go-windows-archive.sh <out-dir>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TMP="${TMPDIR:-/tmp}/zova-go-windows-archive.$$"
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP"

sh "$ROOT/scripts/update-generated-c.sh" "$TMP/generated" x86_64-pc-windows-gnu
CC="zig cc -target x86_64-windows-gnu"
$CC -std=c11 -O2 -Wno-incompatible-pointer-types -I "$TMP/generated" \
    -c "$TMP/generated/zova_c.c" -o "$TMP/zova.o"
# The same SQLite options as scripts/check-plugin-packages.py.
$CC -std=c99 -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_DBSTAT_VTAB \
    -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_GEOPOLY -DSQLITE_ENABLE_CARRAY -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_SNAPSHOT -DSQLITE_MAX_ATTACHED=30 \
    -I "$TMP/generated" -c "$TMP/generated/sqlite3.c" -o "$TMP/sqlite.o"
rm -f "$OUT/libzova_c.a"
zig ar rcs "$OUT/libzova_c.a" "$TMP/zova.o" "$TMP/sqlite.o"
echo "wrote $OUT/libzova_c.a"
