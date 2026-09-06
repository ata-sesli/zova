#!/usr/bin/env sh
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:?usage: check-browser-package.sh <build-output-directory>}"
OUT="$(cd "$OUT" && pwd)"
if [ "${CI:-}" != "true" ]; then
  : "${HELIUM_EXECUTABLE:?Set HELIUM_EXECUTABLE to the installed Helium binary}"
fi
export npm_config_cache="${npm_config_cache:-$OUT/npm-cache}"
export TMPDIR="$OUT/browser-tmp"
mkdir -p "$TMPDIR"
VERSION="$(bun -p "require('$ROOT/bindings/wasm/package.json').version")"
mkdir -p "$OUT/artifacts" "$OUT/fixture"
npm pack "$OUT/package" --ignore-scripts --pack-destination "$OUT/artifacts"
ARCHIVE="$OUT/artifacts/zova-wasm-$VERSION.tgz"
bun "$ROOT/bindings/wasm/tools/check-package.mjs" "$ARCHIVE"
npm install --prefix "$OUT/fixture" --ignore-scripts --no-audit --no-fund --package-lock=false "$ARCHIVE"
bun "$ROOT/bindings/wasm/tests/playwright-browser.mjs" "$OUT/fixture/node_modules/zova-wasm"
wc -c "$ARCHIVE" "$OUT/package/zova.wasm"
