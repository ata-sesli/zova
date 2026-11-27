#!/bin/bash
# Native Apple Silicon torture run for T1: the prototype at 0f418a0 plus
# source.patch (portability only), Debug build, scratch on the external APFS disk.
# One section per invocation; each capped at 30 minutes.
P=/Users/atasesli/Desktop/VsCode/zova/prototypes/cwal
R=$P/results/2026-11-27-macos-arm64-0f418a0
W=/Volumes/wipesides/codebase-memory-mcp-cache/cwal-t1-w
OPTS="--jobs 6 --powerloss-seeds 1 --ncap 300 --allcap 400 --survivor-trials 5 --restart-seeds 1 --io-positions 4 --files 2 3 8"
cd $P
export CWAL_BIN=$P/zig-out/bin/cwal
echo "BIN $(shasum -a 256 $CWAL_BIN | cut -c1-16) $(date +%Y-%m-%dT%H:%M:%S%z)"
one() { # name, log, sections...
  local name=$1 log=$2; shift 2
  local t=$(date +%s)
  perl -e 'alarm 1800; exec @ARGV' python3 -u torture.py --work $W $OPTS --only "$@" > $R/logs/$log 2>&1
  echo "$name rc=$? $(tail -n 1 $R/logs/$log | head -c 60) $(( $(date +%s)-t ))s"
  rm -rf $W
}
for s in ownership delaypoints readers ckptrace ckptreset closeckpt nreaders crash powerloss; do
  one $s $s.log $s
done
# `recovery` runs only inside `crash` (it needs that section's torn states).
one crash+recovery crash-recovery.log crash recovery
echo SECTIONS-DONE
