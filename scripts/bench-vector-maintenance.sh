#!/usr/bin/env sh
# Bounded host-maintenance measurement: no large objects or ANN dependency.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:?usage: sh scripts/bench-vector-maintenance.sh <external-cache-directory>}"
mkdir -p "$BASE"
OUT="$(mktemp -d "$BASE/vector-maintenance-136.XXXXXX")"
export TMPDIR="$OUT"
export ZIG_GLOBAL_CACHE_DIR="$BASE/zig-global"
cd "$ROOT"
echo "2,048 32-dimensional i8 vectors; main/bound; 1 warmup + 7 measured calls each. Output: $OUT"
zig build bench-vector-maintenance -Doptimize=ReleaseFast -j2 --cache-dir "$BASE/zig-local" --prefix "$OUT/install" -- "$OUT" 2>"$OUT/results.log"
sed -n '1,80p' "$OUT/results.log"
echo "Artifacts retained in $OUT"
