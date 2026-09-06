#!/usr/bin/env sh
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:?usage: sh tools/build-package.sh <external-output-directory>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TSC="${TSC:-$ROOT/bindings/wasm/node_modules/typescript/bin/tsc}"
test -f "$TSC" || { echo "Install package development dependencies with bun install first" >&2; exit 1; }
sh "$ROOT/bindings/wasm/tools/build-wasm.sh" "$OUT/native"
mkdir -p "$OUT/package"
bun "$TSC" --project "$ROOT/bindings/wasm/tsconfig.json" --outDir "$OUT/package/dist"
cp "$OUT/native/zova.mjs" "$OUT/native/zova.wasm" "$OUT/package/"
cp "$ROOT/bindings/wasm/package.json" "$ROOT/bindings/wasm/README.md" "$ROOT/LICENSE" "$OUT/package/"
echo "Browser package staged at $OUT/package"
