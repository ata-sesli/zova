#!/bin/bash
# ckptrace again: three more unmutated runs, then one with the checkpoint
# counter validation removed (CWAL_MUTATE=no-ckpt-validate), which must fail.
P=/Users/atasesli/Desktop/VsCode/zova/prototypes/cwal
R=$P/results/2026-11-27-macos-arm64-0f418a0
W=/Volumes/wipesides/codebase-memory-mcp-cache/cwal-t1-w
OPTS="--jobs 6 --powerloss-seeds 1 --ncap 300 --allcap 400 --survivor-trials 5 --restart-seeds 1 --io-positions 4 --files 2 3 8"
cd $P
export CWAL_BIN=$P/zig-out/bin/cwal
run() { # log
  local t=$(date +%s)
  perl -e 'alarm 1800; exec @ARGV' python3 -u torture.py --work $W $OPTS --only ckptrace > $R/logs/$1 2>&1
  echo "$1 rc=$? $(grep -h 'ckpt_violations' $R/logs/$1 | tail -n 1 | head -c 200) | $(tail -n 1 $R/logs/$1 | head -c 60) $(( $(date +%s)-t ))s"
  rm -rf $W
}
for i in 2 3 4; do run ckptrace-run$i.log; done
export CWAL_MUTATE=no-ckpt-validate
run ckptrace-mutated-no-ckpt-validate.log
echo CKPTRACE-DONE
