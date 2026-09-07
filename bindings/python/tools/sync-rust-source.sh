#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST="$ROOT/bindings/python/rust"
VERSION="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "$ROOT/bindings/rust/Cargo.toml" | head -n 1)"

python3 "$ROOT/scripts/generate-rust-platforms.py" --host

mkdir -p "$DEST"
rm -f "$DEST/Cargo.toml" "$DEST/Cargo.lock"

rsync -a --checksum --delete "$ROOT/bindings/rust/zova/" "$DEST/zova/"
rsync -a --checksum --delete \
    --exclude native \
    "$ROOT/bindings/rust/zova-sys/" \
    "$DEST/zova-sys/"

for backend in linux-x64 linux-arm64 darwin-x64 darwin-arm64 windows-x64; do
    rsync -a --checksum --delete "$ROOT/bindings/rust/zova-sys-$backend/" "$DEST/zova-sys-$backend/"
done

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
repository = "https://github.com/ata-sesli/zova"
homepage = "https://github.com/ata-sesli/zova"
"""

for path in [zova_manifest, sys_manifest, *sys_manifest.parent.parent.glob('zova-sys-*/Cargo.toml')]:
    text = path.read_text()
    text = text.replace("rust-version.workspace = true\n", "")
    text = text.replace("version.workspace = true\n", "")
    text = text.replace("edition.workspace = true\n", "")
    text = text.replace("license.workspace = true\n", "")
    text = text.replace("repository.workspace = true\n", "")
    text = text.replace("homepage.workspace = true\n", "")
    text = text.replace("[package]\n", "[package]\n" + common, 1)
    path.write_text(text)
PY

mkdir -p "$DEST/zova-sys/native"
rsync -a --checksum --delete "$ROOT/LICENSE" "$DEST/zova-sys/native/LICENSE"
"$ROOT/scripts/update-generated-c.sh" "$DEST/zova-sys/native/generated"

rm -rf "$DEST/target" "$DEST/zova/target" "$DEST/zova-sys/target"
find "$DEST" \( -name '.DS_Store' -o -name '*.zova' -o -name '*.zova-wal' -o -name '*.zova-shm' \) \
    ! -path '*/tests/fixtures/*' -delete
