#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
NATIVE="$ROOT/bindings/rust/zova-sys/native"

mkdir -p "$NATIVE"

rsync -a --delete "$ROOT/build.zig" "$NATIVE/build.zig"
rsync -a --delete "$ROOT/build.zig.zon" "$NATIVE/build.zig.zon"
rsync -a --delete "$ROOT/LICENSE" "$NATIVE/LICENSE"
rsync -a --delete "$ROOT/include/" "$NATIVE/include/"
rsync -a --delete "$ROOT/src/" "$NATIVE/src/"
rsync -a --delete "$ROOT/tests/" "$NATIVE/tests/"
rsync -a --delete "$ROOT/vendor/" "$NATIVE/vendor/"

rm -rf "$NATIVE/.zig-cache" "$NATIVE/zig-out"
find "$NATIVE" \( -name '.DS_Store' -o -name '*.zova' -o -name '*.zova-wal' -o -name '*.zova-shm' \) -delete
