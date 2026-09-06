#!/usr/bin/env sh
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:?usage: sh bindings/wasm/tools/build-wasm.sh <output-directory>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
export EM_CACHE="${EM_CACHE:-$OUT/em-cache}"
export TMPDIR="$OUT"
SOURCE="${ZOVA_SQLITE_WASM_SOURCE:-}"
if [ -z "$SOURCE" ]; then
    SOURCE="$(bun "$ROOT/bindings/wasm/tools/prepare-opfs-source.mjs" "$OUT/upstream")"
fi
echo "building Zova with bundled SQLite and OPFS adapter"
bun "$ROOT/bindings/wasm/tools/build-opfs.mjs" "$SOURCE" "$OUT" "$OUT"
wc -c "$OUT/zova.mjs" "$OUT/zova.wasm"
