#!/usr/bin/env sh
# Compare linked SQLite code size, not database size. No timing benchmark.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: measure-sqlite-modules.sh <output-directory>}"
mkdir -p "$OUT"
for variant in baseline modules; do
    set -- -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_DBSTAT_VTAB
    if [ "$variant" = modules ]; then
        set -- "$@" -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_GEOPOLY -DSQLITE_ENABLE_CARRAY -DSQLITE_ENABLE_MATH_FUNCTIONS
    fi
    echo "building SQLite size probe: $variant"
    zig cc -O2 -DNDEBUG "$@" -I "$ROOT/vendor/sqlite3.53.4" \
        "$ROOT/tests/sqlite_size.c" "$ROOT/vendor/sqlite3.53.4/sqlite3.c" \
        -o "$OUT/$variant.exe" -lm
done
baseline=$(wc -c < "$OUT/baseline.exe")
modules=$(wc -c < "$OUT/modules.exe")
echo "SQLite linked probe bytes ($(uname -sm), Zig $(zig version), -O2 -DNDEBUG)"
echo "baseline=$baseline modules=$modules delta=$((modules - baseline))"
