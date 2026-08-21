#!/usr/bin/env bash
#
# Export immutable format-9 storage fixtures using the released Zova v0.26.1
# build. Fixtures are genuine outputs of released code; never hand-edit them or
# create them by editing metadata in a newer database.
#
# The script checks out the release tag into a temporary worktree, links a small
# exporter against that exact source tree plus its vendored SQLite amalgamation,
# runs it into a staging directory, verifies every output reports format
# version 9, copies results into tests/fixtures/, and refreshes
# tests/fixtures/format-9.sha256.
#
# Usage: scripts/export-format-9-fixtures.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="v0.26.1"
FIXTURE_DIR="$ROOT/tests/fixtures"
EXPORTER_SOURCE="$ROOT/scripts/fixtures/export-format-9-generator.zig"

for tool in zig python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

STAGE="$(mktemp -d)"
cleanup() {
  git -C "$ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

WORKTREE="$STAGE/worktree"
OUTPUT_DIR="$STAGE/output"
mkdir -p "$OUTPUT_DIR"

git -C "$ROOT" worktree add --detach "$WORKTREE" "$TAG" >/dev/null

echo "building exporter against $TAG ..."
(
  cd "$WORKTREE"
  zig build-lib -O ReleaseSafe -lc vendor/sqlite3.53.2/sqlite3.c \
    -Ivendor/sqlite3.53.2 \
    -DSQLITE_THREADSAFE=1 \
    -DSQLITE_ENABLE_FTS5 \
    -DSQLITE_ENABLE_DBSTAT_VTAB \
    -femit-bin="$STAGE/libzovasqlite3.a"
  zig build-exe -O ReleaseSafe -lc -Ivendor/sqlite3.53.2 \
    --dep zova \
    -Mroot="$EXPORTER_SOURCE" \
    -Mzova=src/root.zig \
    -L"$STAGE" -lzovasqlite3 \
    -femit-bin="$STAGE/export-format-9-fixtures"
)

echo "exporting format-9 fixtures ..."
"$STAGE/export-format-9-fixtures" "$OUTPUT_DIR"

FIXTURES=(
  empty-main-format-9.zova
  format-9.zova
  bound-main-format-9.zova
  bound-main-format-9.objects.zova
  bound-main-format-9.vectors.zova
  bound-main-format-9.graphs.zova
  empty-vector-store-format-9.zova
  empty-graph-store-format-9.zova
)

for fixture in "${FIXTURES[@]}"; do
  [ -s "$OUTPUT_DIR/$fixture" ] || { echo "error: exporter did not produce $fixture" >&2; exit 1; }
done

python3 - "$OUTPUT_DIR" <<'PY'
import pathlib
import sqlite3
import sys

output_dir = pathlib.Path(sys.argv[1])
for path in sorted(output_dir.glob("*.zova")):
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        row = connection.execute(
            "select value from _zova_meta where key = 'format_version'"
        ).fetchone()
        if row is None or row[0] != "9":
            raise SystemExit(f"error: {path.name} does not report format version 9")
    finally:
        connection.close()

# Bound stores must be recorded as portable relative sibling names, never
# absolute paths into the exporter's temporary directory.
main_path = output_dir / "bound-main-format-9.zova"
connection = sqlite3.connect(f"file:{main_path}?mode=ro", uri=True)
try:
    rows = connection.execute(
        "select role, path from _zova_bound_stores order by role"
    ).fetchall()
finally:
    connection.close()

expected = {
    "graph_store": "bound-main-format-9.graphs.zova",
    "object_store": "bound-main-format-9.objects.zova",
    "vector_store": "bound-main-format-9.vectors.zova",
}
for role, stored_path in rows:
    if pathlib.Path(stored_path).is_absolute() or expected.get(role) != stored_path:
        raise SystemExit(
            f"error: bound {role} records non-portable path {stored_path!r}"
        )
print("verified format version 9 and portable bound-store paths")
PY

cp "${FIXTURES[@]/#/$OUTPUT_DIR/}" "$FIXTURE_DIR/"

(
  cd "$FIXTURE_DIR"
  sha256sum "${FIXTURES[@]}" > format-9.sha256
)

echo "format-9 fixtures refreshed:"
cat "$FIXTURE_DIR/format-9.sha256"
