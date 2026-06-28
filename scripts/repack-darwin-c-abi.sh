#!/usr/bin/env sh
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
    exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${1:-$ROOT/zig-out/lib/libzova_c.a}"

if [ ! -f "$LIB" ]; then
    echo "missing C ABI static library: $LIB" >&2
    exit 1
fi

TMP="${TMPDIR:-/tmp}/zova-repack-darwin-c-abi.$$"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP"
cp "$LIB" "$TMP/original.a"

cd "$TMP"
MEMBERS="$(ar -t original.a | sed -n '/\.o$/p')"
if [ -z "$MEMBERS" ]; then
    echo "C ABI archive contains no object members: $LIB" >&2
    exit 1
fi

ar -x original.a
for member in $MEMBERS; do
    chmod 644 "$member"
done

# Zig's macOS archive is accepted by many linkers, but GitHub's macOS cgo
# path can reject a member layout from that archive. Repack the same object
# files with Apple's libtool so clang/ld see a native Darwin static library.
libtool -static -o libzova_c.a $MEMBERS
ranlib libzova_c.a
cp libzova_c.a "$LIB"
