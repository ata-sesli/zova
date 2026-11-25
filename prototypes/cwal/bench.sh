#!/usr/bin/env bash
# Commit latency, fsyncs per commit and concurrent read throughput: plain
# SQLite WAL vs CWAL, same VFS, same build.
# usage: bench.sh DIR [REPS]   (DIR selects the filesystem)
set -euo pipefail
BIN=${CWAL_BIN:-"$(dirname "$0")/zig-out/bin/cwal"}
DIR=$1; REPS=${2:-3}
fresh() { rm -rf "$DIR/b"; mkdir -p "$DIR/b"; "$BIN" seed "$DIR/b" >/dev/null; }
for rep in $(seq "$REPS"); do
  echo "# rep $rep/$REPS" >&2
  for kind in pair solo; do
    for cfg in "plain FULL" "plain NORMAL" "cwal FULL"; do
      set -- $cfg; fresh
      "$BIN" bench "$DIR/b" --mode "$1" --sync "$2" --kind "$kind" --commits 500
    done
  done
  for mode in plain cwal; do
    fresh
    "$BIN" benchrw "$DIR/b" --mode "$mode" --readers 4 --duration-ms 3000
  done
done
rm -rf "$DIR/b"
