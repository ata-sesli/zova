#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEST="$ROOT/bindings/python/rust"
VERSION="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "$ROOT/bindings/rust/Cargo.toml" | head -n 1)"

if [ ! -f "$DEST/zova/Cargo.toml" ]; then
    echo "missing Python bundled Rust source; run bindings/python/tools/sync-rust-source.sh" >&2
    exit 1
fi

if [ -f "$DEST/Cargo.toml" ] || [ -f "$DEST/Cargo.lock" ]; then
    echo "Python bundled Rust source has stale root workspace files; run bindings/python/tools/sync-rust-source.sh" >&2
    exit 1
fi

check_path() {
    source="$1"
    bundled="$2"
    if ! diff -qr "$source" "$bundled" >/dev/null; then
        echo "Python bundled Rust source is stale for $source" >&2
        echo "run bindings/python/tools/sync-rust-source.sh" >&2
        diff -qr "$source" "$bundled" >&2 || true
        exit 1
    fi
}

TMP="${TMPDIR:-/tmp}/zova-python-rust-source-check.$$"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP/zova" "$TMP/zova-sys" "$TMP/zova-sys-bundled"
rsync -a --delete "$ROOT/bindings/rust/zova/" "$TMP/zova/"
rsync -a --delete \
    --exclude native \
    "$ROOT/bindings/rust/zova-sys/" \
    "$TMP/zova-sys/"
rsync -a --delete \
    --exclude native \
    "$DEST/zova-sys/" \
    "$TMP/zova-sys-bundled/"

python3 - "$TMP/zova/Cargo.toml" "$TMP/zova-sys/Cargo.toml" "$VERSION" <<'PY'
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

check_path "$TMP/zova" "$DEST/zova"
check_path "$TMP/zova-sys" "$TMP/zova-sys-bundled"

for generated_file in zova_c.c zig.h zova.h sqlite3.c sqlite3.h sqlite3ext.h; do
    if [ ! -f "$DEST/zova-sys/native/generated/$generated_file" ]; then
        echo "missing Python generated C bundle file: $generated_file" >&2
        echo "run bindings/python/tools/sync-rust-source.sh" >&2
        exit 1
    fi
done
