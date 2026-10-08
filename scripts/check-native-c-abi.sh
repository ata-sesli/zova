#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != "--go" ]; }; then
    echo "usage: sh scripts/check-native-c-abi.sh <install-prefix-or-c-abi.tar.gz> [--go]" >&2
    exit 2
fi
INPUT="$1"
CHECK_GO="${2:-}"

case "$(uname -s)" in
    Linux) set -- -pthread -ldl -lm ;;
    Darwin) set -- -pthread -lm ;;
    *) echo "native system-linker check requires Linux or macOS" >&2; exit 2 ;;
esac

CC="${CC:-cc}"
CXX="${CXX:-c++}"
command -v "$CC" >/dev/null
command -v "$CXX" >/dev/null
if [ "$CHECK_GO" = "--go" ]; then
    command -v go >/dev/null
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zova-native-c-abi.XXXXXX")"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

case "$INPUT" in
    *.tar.gz)
        echo "extracting native C ABI archive: $INPUT"
        mkdir "$TMP/unpacked"
        tar -xzf "$INPUT" -C "$TMP/unpacked"
        PREFIX="$TMP/unpacked/$(basename "$INPUT" .tar.gz)"
        ;;
    *) PREFIX="$(cd "$INPUT" && pwd)" ;;
esac

LIB="$PREFIX/lib/libzova_c.a"
test -f "$LIB"
test -f "$PREFIX/include/zova.h"
test -f "$PREFIX/include/zova_plugin.h"

# Use the actual system linker, which cannot inject Zig's compiler runtime.
# These existing consumers pull the public ABI and exercise its real behavior.
echo "linking native C ABI smoke with $CC"
"$CC" -std=c99 -I "$PREFIX/include" -I "$ROOT/vendor/sqlite3.53.4" \
    "$ROOT/tests/c_abi_smoke.c" "$LIB" "$@" -o "$TMP/c-smoke"
echo "running native C ABI smoke"
"$TMP/c-smoke" "$TMP/c-smoke.zova"

echo "linking native C++ header smoke with $CXX"
"$CXX" -std=c++17 -I "$PREFIX/include" \
    "$ROOT/tests/c_abi_header_smoke.cpp" "$LIB" "$@" -o "$TMP/cxx-smoke"
"$TMP/cxx-smoke"

if [ "$CHECK_GO" = "--go" ]; then
    echo "testing Go/cgo against the native C ABI prefix"
    # Fresh Go cache prevents a previously linked test executable from masking
    # a changed archive. This prefix precedes the binding's default search path.
    (
        cd "$ROOT/bindings/go"
        CGO_ENABLED=1 GOCACHE="$TMP/go-cache" \
            CGO_CFLAGS="-I$PREFIX/include ${CGO_CFLAGS:-}" \
            CGO_LDFLAGS="-L$PREFIX/lib ${CGO_LDFLAGS:-}" \
            go test -count=1 ./...
    )
fi

echo "native C ABI system-linker check: ok"
