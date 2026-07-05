#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

symbol_list() {
    nm -g "$1" |
        sed -n \
            -e 's/^.*[[:space:]]_\(zova_[A-Za-z0-9_]*\)$/zova_\1/p' \
            -e 's/^.*[[:space:]]\(zova_[A-Za-z0-9_]*\)$/\1/p' |
        sort -u
}

require_command zig
require_command clang
require_command nm
require_command diff
require_command wc

COMPILER_RUNTIME_ARGS=""
if [ "$(uname -s)" = "Linux" ]; then
    RUNTIME_LIB="$(clang --print-libgcc-file-name 2>/dev/null || true)"
    if [ -n "$RUNTIME_LIB" ] && [ -f "$RUNTIME_LIB" ]; then
        COMPILER_RUNTIME_ARGS="$RUNTIME_LIB -lgcc -lgcc_s"
    else
        COMPILER_RUNTIME_ARGS="-lgcc -lgcc_s"
    fi
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

TMP="${TMPDIR:-/tmp}/zova-generated-c-check.$$"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

BUNDLE="$TMP/bundle"

echo "building canonical Zig C ABI for symbol comparison"
zig build c-abi

echo "emitting generated C bundle"
"$ROOT/scripts/update-generated-c.sh" "$BUNDLE"

echo "generated C size:"
wc -l "$BUNDLE/zova_c.c"
wc -c "$BUNDLE/zova_c.c"

echo "compiling generated C with clang"
clang -std=c11 \
    -Werror \
    -Wno-incompatible-pointer-types \
    -I "$BUNDLE" \
    -O2 \
    -c "$BUNDLE/zova_c.c" \
    -o "$TMP/zova_c.o"

echo "compiling vendored SQLite"
clang -std=c99 \
    -fno-sanitize=undefined \
    -DSQLITE_THREADSAFE=1 \
    -DSQLITE_ENABLE_FTS5 \
    -I "$BUNDLE" \
    -O2 \
    -c "$BUNDLE/sqlite3.c" \
    -o "$TMP/sqlite3.o"

echo "linking generated-C C ABI smoke binary"
if [ -n "$COMPILER_RUNTIME_ARGS" ]; then
    echo "compiler runtime link args: $COMPILER_RUNTIME_ARGS"
fi
clang -std=c99 \
    -I "$BUNDLE" \
    tests/c_abi_smoke.c \
    "$TMP/zova_c.o" \
    "$TMP/sqlite3.o" \
    -pthread \
    -lm \
    $COMPILER_RUNTIME_ARGS \
    -o "$TMP/zova_c_abi_smoke"

echo "running generated-C C ABI smoke"
"$TMP/zova_c_abi_smoke" "$TMP/generated-c-smoke.zova"

echo "comparing exported C ABI symbols"
symbol_list zig-out/lib/libzova_c.a >"$TMP/zig-symbols.txt"
symbol_list "$TMP/zova_c.o" >"$TMP/generated-c-symbols.txt"
diff -u "$TMP/zig-symbols.txt" "$TMP/generated-c-symbols.txt"

if [ "$(uname -s)" = "Linux" ] && command -v gcc >/dev/null 2>&1; then
    echo "probing generated C with GCC on Linux"
    if gcc -std=c11 \
        -Werror \
        -Wno-incompatible-pointer-types \
        -I "$BUNDLE" \
        -O2 \
        -c "$BUNDLE/zova_c.c" \
        -o "$TMP/zova_c_gcc.o"; then
        echo "GCC generated-C probe: ok"
    elif [ "${ZOVA_GENERATED_C_REQUIRE_GCC:-0}" = "1" ]; then
        echo "GCC generated-C probe failed" >&2
        exit 1
    else
        echo "GCC generated-C probe failed; clang remains the required compiler for now" >&2
    fi
fi

echo "generated-C check: ok"
