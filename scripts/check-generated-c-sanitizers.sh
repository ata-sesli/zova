#!/usr/bin/env sh
# Build the generated C bundle (Zova and vendored SQLite) with AddressSanitizer
# and UndefinedBehaviorSanitizer, then run the C ABI smoke test against it.
# This is a diagnostic build only: production compiler flags are unchanged.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

require_command zig
require_command clang

TMP="${TMPDIR:-/tmp}/zova-generated-c-sanitizers.$$"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

BUNDLE="$TMP/bundle"
# Zig's C backend emits opaque pointer parameters such as *sqlite3_context as
# void *, so every Zig callback SQLite calls has a declared type that differs
# from SQLite's callback type while sharing its ABI. -fsanitize=function rejects
# each such call, so that one check is excluded.
SANITIZE="-fsanitize=address,undefined -fno-sanitize=function -fno-sanitize-recover=all -fno-omit-frame-pointer -g -O1"

echo "emitting generated C bundle"
"$ROOT/scripts/update-generated-c.sh" "$BUNDLE"

echo "compiling generated C with ASan and UBSan"
# shellcheck disable=SC2086
clang -std=c11 \
    -Werror \
    -Wno-incompatible-pointer-types \
    $SANITIZE \
    -I "$BUNDLE" \
    -c "$BUNDLE/zova_c.c" \
    -o "$TMP/zova_c.o"

echo "compiling vendored SQLite with ASan and UBSan"
# shellcheck disable=SC2086
clang -std=c99 \
    $SANITIZE \
    -DSQLITE_THREADSAFE=1 \
    -DSQLITE_ENABLE_FTS5 \
    -DSQLITE_ENABLE_DBSTAT_VTAB \
    -DSQLITE_ENABLE_RTREE \
    -DSQLITE_ENABLE_GEOPOLY \
    -DSQLITE_ENABLE_CARRAY \
    -DSQLITE_ENABLE_MATH_FUNCTIONS \
    -I "$BUNDLE" \
    -c "$BUNDLE/sqlite3.c" \
    -o "$TMP/sqlite3.o"

echo "linking sanitized C ABI smoke binary"
DYNAMIC_LIBS=""
if [ "$(uname -s)" = "Linux" ]; then DYNAMIC_LIBS="-ldl"; fi
# shellcheck disable=SC2086
clang -std=c99 \
    $SANITIZE \
    -I "$BUNDLE" \
    tests/c_abi_smoke.c \
    "$TMP/zova_c.o" \
    "$TMP/sqlite3.o" \
    -pthread \
    -lm \
    $DYNAMIC_LIBS \
    -o "$TMP/zova_c_abi_smoke"

echo "running sanitized C ABI smoke"
ASAN_OPTIONS="detect_leaks=1:abort_on_error=1:strict_string_checks=1" \
    UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1" \
    "$TMP/zova_c_abi_smoke" "$TMP/sanitized-smoke.zova"

echo "generated-C sanitizer check: ok"
