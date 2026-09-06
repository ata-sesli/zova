#!/usr/bin/env sh
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:?usage: sh bindings/wasm/tools/build-wasm.sh <output-directory>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
export EM_CACHE="${EM_CACHE:-$OUT/em-cache}"
export TMPDIR="$OUT"
EMCC="${EMCC:-emcc}"
# Pin the installed and validated SDK; do not use the host native-C snapshot.
EXPECTED="$(cat "$ROOT/bindings/wasm/emscripten-version.txt")"
ACTUAL="$("$EMCC" -dumpversion)"
test "${ACTUAL%-git}" = "$EXPECTED" || {
    echo "Emscripten $EXPECTED is required; found $ACTUAL" >&2; exit 1;
}
SQLITE_VERSION="$(sed -n 's/^pub const sqlite_version = "\([^"]*\)";.*/\1/p' "$ROOT/src/version.zig")"
SQLITE="$ROOT/vendor/sqlite$SQLITE_VERSION"
ZIG_LIB="$(zig env | sed -n 's/^[[:space:]]*\.lib_dir = "\([^"]*\)",/\1/p')"
echo "emitting real Zova core for wasm32-emscripten (ReleaseSafe)"
zig build-lib -ofmt=c -O ReleaseSafe -target wasm32-emscripten -fsingle-threaded \
    -I "$SQLITE" -lc -femit-bin="$OUT/zova_c.c" \
    --cache-dir "${ZIG_LOCAL_CACHE_DIR:-$OUT/zig-cache}" \
    --global-cache-dir "${ZIG_GLOBAL_CACHE_DIR:-$OUT/zig-global-cache}" \
    --dep zova_build_options -Mroot="$ROOT/src/c_api.zig" \
    -Mzova_build_options="$ROOT/bindings/wasm/native/build_options.zig"
echo "linking Zova, bundled SQLite, and private smoke bridge"
# Emscripten 6 enables bigint integration by default. Keep volatile MEMFS:
# FILESYSTEM=0 syscall stubs can make SQLite's Unix robust_open loop forever.
"$EMCC" -O2 -I "$ZIG_LIB" -I "$ROOT/include" -I "$SQLITE" \
    -Werror -Wno-incompatible-pointer-types \
    -DSQLITE_THREADSAFE=0 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_DBSTAT_VTAB \
    -DSQLITE_OMIT_LOAD_EXTENSION \
    "$OUT/zova_c.c" "$SQLITE/sqlite3.c" "$ROOT/bindings/wasm/native/smoke.c" \
    "$ROOT/bindings/wasm/native/bridge.c" \
    --no-entry -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=worker \
    -sALLOW_MEMORY_GROWTH=1 \
    -sEXPORTED_FUNCTIONS='["_zova_wasm_smoke","_malloc","_free"]' \
    -sEXPORTED_RUNTIME_METHODS='["HEAPU8","UTF8ToString"]' \
    -o "$OUT/zova.mjs"
wc -c "$OUT/zova.mjs" "$OUT/zova.wasm"
