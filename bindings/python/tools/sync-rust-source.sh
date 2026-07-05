#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST="$ROOT/bindings/python/rust"
VERSION="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "$ROOT/bindings/rust/Cargo.toml" | head -n 1)"

mkdir -p "$DEST"
rm -f "$DEST/Cargo.toml" "$DEST/Cargo.lock"

rsync -a --delete "$ROOT/bindings/rust/zova/" "$DEST/zova/"
rsync -a --delete \
    --exclude native \
    "$ROOT/bindings/rust/zova-sys/" \
    "$DEST/zova-sys/"

python3 - "$DEST/zova/Cargo.toml" "$DEST/zova-sys/Cargo.toml" "$VERSION" <<'PY'
from pathlib import Path
import sys

zova_manifest = Path(sys.argv[1])
sys_manifest = Path(sys.argv[2])
version = sys.argv[3]

common = f"""version = "{version}"
edition = "2021"
rust-version = "1.79"
license = "MIT"
repository = "https://github.com/atasesli/zova"
homepage = "https://github.com/atasesli/zova"
"""

for path in (zova_manifest, sys_manifest):
    text = path.read_text()
    text = text.replace("rust-version.workspace = true\n", "")
    text = text.replace("version.workspace = true\n", "")
    text = text.replace("edition.workspace = true\n", "")
    text = text.replace("license.workspace = true\n", "")
    text = text.replace("repository.workspace = true\n", "")
    text = text.replace("homepage.workspace = true\n", common)
    path.write_text(text)
PY

mkdir -p "$DEST/zova-sys/native"
rsync -a --delete "$ROOT/LICENSE" "$DEST/zova-sys/native/LICENSE"
"$ROOT/scripts/update-generated-c.sh" "$DEST/zova-sys/native/generated"

rm -rf "$DEST/target" "$DEST/zova/target" "$DEST/zova-sys/target"
find "$DEST" \( -name '.DS_Store' -o -name '*.zova' -o -name '*.zova-wal' -o -name '*.zova-shm' \) -delete
