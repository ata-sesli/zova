#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
NATIVE="$ROOT/bindings/rust/zova-sys/native"

if [ ! -f "$NATIVE/build.zig" ]; then
    echo "missing bundled native source; run bindings/rust/zova-sys/tools/sync-native-source.sh" >&2
    exit 1
fi

check_path() {
    source="$1"
    bundled="$2"
    if ! diff -qr "$source" "$bundled" >/dev/null; then
        echo "bundled native source is stale for $source" >&2
        echo "run bindings/rust/zova-sys/tools/sync-native-source.sh" >&2
        diff -qr "$source" "$bundled" >&2 || true
        exit 1
    fi
}

check_path "$ROOT/build.zig" "$NATIVE/build.zig"
check_path "$ROOT/build.zig.zon" "$NATIVE/build.zig.zon"
check_path "$ROOT/LICENSE" "$NATIVE/LICENSE"
check_path "$ROOT/include" "$NATIVE/include"
check_path "$ROOT/src" "$NATIVE/src"
check_path "$ROOT/tests" "$NATIVE/tests"
check_path "$ROOT/vendor" "$NATIVE/vendor"
