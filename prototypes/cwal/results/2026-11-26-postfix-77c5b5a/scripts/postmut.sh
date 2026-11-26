#!/bin/bash
# Each mutation against the torture section(s) that should catch it.
# Detected = torture.py exits non-zero (RESULT FAIL); no-ckpt-skip must pass.
S=/tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad
cd /home/atawirtz/workspace/zova/prototypes/cwal
export CWAL_BIN=$S/base-ReleaseSafe/bin/cwal
O="--jobs 8 --powerloss-seeds 1 --survivor-trials 10 --restart-seeds 2 --files 3 8"
while read -r mu secs; do
  [ -z "$mu" ] && continue
  t=$(date +%s)
  CWAL_MUTATE=$mu python3 torture.py --work $S/mut-w --only $secs $O > $S/post-mut-$mu.log 2>&1
  rc=$?
  if [ "$mu" = no-ckpt-skip ]; then v=$([ $rc = 0 ] && echo "pass (control)" || echo "UNEXPECTED FAIL"); else v=$([ $rc != 0 ] && echo detected || echo "NOT DETECTED"); fi
  echo "MUT $mu [$secs] rc=$rc $v $(( $(date +%s) - t ))s"
  rm -rf $S/mut-w
done <<'LIST'
none crash readers survivors ckptrace ckptreset closeckpt ndangle nrestart enforce
no-markers crash
no-marker-rollback powerloss
no-cross-flag survivors
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
no-open-gate ndangle
no-txn-epoch nrestart
no-authorizer enforce
no-frame-guard enforce
no-backfill-check enforce
LIST
echo SWEEP-DONE
