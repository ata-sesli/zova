#!/bin/bash
# R6 verification: build 3 modes; 20 repeats of delaypoints (now with the R6
# cases) per build; reduced suite on each build; mutation sweep with
# no-root-check and no-repair-lock added.
S=/tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad
P=/home/atawirtz/workspace/zova/prototypes/cwal
L=$S/r6run/logs
. ~/tools/zova-wasm-env.sh
cd $P
echo "SOURCE $(git rev-parse HEAD) + working tree (source.patch sha256 $(git diff HEAD -- src torture.py | sha256sum | cut -c1-16)) $(date -Is)"
git diff HEAD -- src torture.py > $S/r6run/source.patch
for m in Debug ReleaseSafe ReleaseFast; do
  rm -rf $S/r6run-$m
  zig build -Doptimize=$m -p $S/r6run-$m || { echo "BUILD FAIL $m"; exit 1; }
  echo "BUILT $m $(sha256sum $S/r6run-$m/bin/cwal | cut -c1-16)"
done
for m in Debug ReleaseSafe ReleaseFast; do
  t=$(date +%s); pass=0; fail=0
  for i in $(seq 1 20); do
    if CWAL_BIN=$S/r6run-$m/bin/cwal python3 -u torture.py --work $S/rep-w --only delaypoints > $L/repeat-$m-$i.log 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); fi
  done
  rm -rf $S/rep-w
  echo "REPEAT $m delaypoints pass=$pass fail=$fail $(( $(date +%s)-t ))s"
done
O="--jobs 8 --powerloss-seeds 1 --ncap 300 --allcap 400 --survivor-trials 5 --restart-seeds 1 --io-positions 4 --files 2 3 8"
for m in Debug ReleaseSafe ReleaseFast; do
  t=$(date +%s); echo "SUITE $m start $(date +%T)"
  CWAL_BIN=$S/r6run-$m/bin/cwal python3 -u torture.py --work $S/reg-w $O > $L/suite-$m.log 2>&1
  echo "SUITE $m rc=$? $(tail -n 1 $L/suite-$m.log | head -c 80) $(( $(date +%s)-t ))s"
  rm -rf $S/reg-w
done
export CWAL_BIN=$S/r6run-ReleaseSafe/bin/cwal
O="--jobs 8 --powerloss-seeds 1 --survivor-trials 10 --restart-seeds 2 --files 3 8"
while read -r mu secs; do
  [ -z "$mu" ] && continue
  t=$(date +%s)
  tag=$mu; [ "$mu" != none ] && [ "$secs" = delaypoints ] && tag=$mu-delaypoints
  CWAL_MUTATE=$mu python3 torture.py --work $S/mut-w --only $secs $O > $L/mut-$tag.log 2>&1
  rc=$?
  if [ "$mu" = no-ckpt-skip ] || [ "$mu" = none ]; then v=$([ $rc = 0 ] && echo "pass (control)" || echo "UNEXPECTED FAIL"); else v=$([ $rc != 0 ] && echo detected || echo "NOT DETECTED"); fi
  echo "MUT $mu [$secs] rc=$rc $v $(( $(date +%s) - t ))s"
  rm -rf $S/mut-w
done <<'LIST'
none crash readers survivors ckptrace ckptreset closeckpt ndangle nrestart enforce delaypoints ownership
no-markers crash
no-marker-rollback powerloss
no-cross-flag survivors
no-cross-flag delaypoints
no-gate readers
no-seq-check readers
no-snapshot-open readers
no-solo-window readers
no-lock-gate closeckpt
no-ckpt-gate closeckpt
no-ckpt-validate ckptrace
no-ckpt-skip ckptrace
no-ckpt-reset ckptreset
no-discard-unpublished ndangle
no-late-alone ndangle
no-late-alone delaypoints
no-early-heads delaypoints
heads-process-wide delaypoints
no-ownership ownership
no-root-check delaypoints
no-repair-lock delaypoints
no-open-gate ndangle
no-txn-epoch nrestart
no-authorizer enforce
no-frame-guard enforce
no-backfill-check enforce
LIST
echo ALL-DONE $(date -Is)
