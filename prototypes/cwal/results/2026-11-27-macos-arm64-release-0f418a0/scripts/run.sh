#!/bin/bash
# Native Apple Silicon torture runs for T1 in release builds: the prototype
# at 0f418a0 plus source.patch (portability only). Scratch and binaries on
# the external APFS disk. Usage: run.sh MODE [sections|ckptrace]...
#   sections: the torture sections, one --only call each (not for Debug,
#             which ../2026-11-27-macos-arm64-0f418a0 already covers)
#   ckptrace: 20 unmutated ckptrace runs, then one with
#             CWAL_MUTATE=no-ckpt-validate, which must fail
P=/Users/atasesli/Desktop/VsCode/zova/prototypes/cwal
R=$P/results/2026-11-27-macos-arm64-release-0f418a0
MODE=$1; shift
W=/Volumes/wipesides/codebase-memory-mcp-cache/cwal-t1-w
OPTS="--jobs 6 --powerloss-seeds 1 --ncap 300 --allcap 400 --survivor-trials 5 --restart-seeds 1 --io-positions 4 --files 2 3 8"
L=$R/logs/$MODE
mkdir -p $L
cd $P
export CWAL_BIN=/Volumes/wipesides/codebase-memory-mcp-cache/cwal-t1-bin/$MODE/bin/cwal
echo "BIN $MODE $(shasum -a 256 $CWAL_BIN | cut -c1-16) $(date +%Y-%m-%dT%H:%M:%S%z)"
one() { # name, log, sections...
  local name=$1 log=$2; shift 2
  local t=$(date +%s)
  perl -e 'alarm 1800; exec @ARGV' python3 -u torture.py --work $W $OPTS --only "$@" > $L/$log 2>&1
  echo "$MODE $name rc=$? $(tail -n 1 $L/$log | head -c 60) $(( $(date +%s)-t ))s"
  rm -rf $W
}
counts() { grep -ho "'ckpt_races': [0-9]*, 'ckpt_fallbacks': [0-9]*, 'ckpt_violations': [0-9]*" $L/$1 | tr -d "':,"; }
for what in "$@"; do
  if [ $what = sections ]; then
    for s in ownership delaypoints readers ckptrace ckptreset closeckpt nreaders powerloss; do
      one $s $s.log $s
    done
    # `recovery` runs only inside `crash` (it needs that section's torn states).
    one crash+recovery crash-recovery.log crash recovery
  else
    for i in $(seq -w 1 20); do
      one "ckptrace#$i" ckptrace-run$i.log ckptrace
      echo "    $(counts ckptrace-run$i.log)"
    done
    export CWAL_MUTATE=no-ckpt-validate
    one ckptrace-mutated ckptrace-mutated-no-ckpt-validate.log ckptrace
    echo "    $(counts ckptrace-mutated-no-ckpt-validate.log)"
    unset CWAL_MUTATE
  fi
done
echo "$MODE DONE"
