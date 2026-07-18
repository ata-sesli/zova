#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
NATIVE="$ROOT/bindings/rust/zova-sys/native"

mkdir -p "$NATIVE"

rsync -a --checksum --delete "$ROOT/build.zig" "$NATIVE/build.zig"
rsync -a --checksum --delete "$ROOT/build.zig.zon" "$NATIVE/build.zig.zon"
rsync -a --checksum --delete "$ROOT/LICENSE" "$NATIVE/LICENSE"
rsync -a --checksum --delete "$ROOT/include/" "$NATIVE/include/"
rsync -a --checksum --delete "$ROOT/bench/" "$NATIVE/bench/"
rsync -a --checksum --delete "$ROOT/src/" "$NATIVE/src/"
rsync -a --checksum --delete "$ROOT/tests/" "$NATIVE/tests/"
rsync -a --checksum --delete "$ROOT/vendor/" "$NATIVE/vendor/"
"$ROOT/scripts/update-generated-c.sh" "$NATIVE/generated"

rm -rf "$NATIVE/.zig-cache" "$NATIVE/zig-out"
find "$NATIVE" -name '.DS_Store' -delete
find "$NATIVE" -type f \( -name '*.zova' -o -name '*.zova-wal' -o -name '*.zova-shm' \) \
    ! -path "$NATIVE/tests/fixtures/*" -delete
