#!/usr/bin/env bash
# Commit latency, fsyncs per commit, journal size and concurrent read
# throughput: plain SQLite WAL vs CWAL, same VFS, same build.
# CWAL variants: base (synced COMMITTED, reader gate), lazy (lazy COMMITTED
# with roll-forward recovery), snap (seqlock snapshot reads), both.
# usage: bench.sh DIR [REPS]   (DIR selects the filesystem)
set -euo pipefail
BIN=${CWAL_BIN:-"$(dirname "$0")/zig-out/bin/cwal"}
DIR=$1; REPS=${2:-3}
fresh() { rm -rf "$DIR/b"; mkdir -p "$DIR/b"; "$BIN" seed "$DIR/b" >/dev/null; }
# name lazy snapshot
VARIANTS=("base 0 0" "lazy 1 0" "snap 0 1" "both 1 1")
for rep in $(seq "$REPS"); do
  echo "# rep $rep/$REPS" >&2
  for kind in pair solo; do
    for cfg in "plain FULL" "plain NORMAL"; do
      set -- $cfg; fresh
      printf 'variant=- '
      "$BIN" bench "$DIR/b" --mode "$1" --sync "$2" --kind "$kind" --commits 500
    done
    for v in "${VARIANTS[@]}"; do
      set -- $v; fresh
      printf 'variant=%s ' "$1"
      CWAL_LAZY_COMMIT=$2 CWAL_SNAPSHOT_READS=$3 "$BIN" bench "$DIR/b" --mode cwal --sync FULL --kind "$kind" --commits 500
    done
  done
  fresh
  printf 'variant=- '
  "$BIN" benchrw "$DIR/b" --mode plain --readers 4 --duration-ms 3000
  for v in "${VARIANTS[@]}"; do
    set -- $v; fresh
    printf 'variant=%s ' "$1"
    CWAL_LAZY_COMMIT=$2 CWAL_SNAPSHOT_READS=$3 "$BIN" benchrw "$DIR/b" --mode cwal --readers 4 --duration-ms 3000
  done
done
rm -rf "$DIR/b"
