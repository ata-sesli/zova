#!/bin/bash
# False-positive check for the recovery-only torn-page check (R6 partial
# checkpoint): the prototype at a0f73da plus source.patch, ReleaseSafe.
cd /tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad/r6p/prototypes/cwal
export CWAL_BIN=/tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad/r6p/bin-ReleaseSafe/bin/cwal
echo "BIN $(sha256sum $CWAL_BIN | cut -c1-16) $(date -Is)"
t=$(date +%s); pass=0; fail=0
for i in 1 2 3 4 5; do
  if python3 -u torture.py --work /tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad/r6p-rep --only delaypoints > /tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad/r6p/logs/repeat-$i.log 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
rm -rf /tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad/r6p-rep
echo "REPEAT delaypoints pass=$pass fail=$fail $(( $(date +%s)-t ))s"
t=$(date +%s); echo "SUITE start $(date +%T)"
python3 -u torture.py --work /tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad/r6p-w --jobs 8 --powerloss-seeds 1 --ncap 300 --allcap 400 --survivor-trials 5 --restart-seeds 1 --io-positions 4 --files 2 3 8 > /tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad/r6p/logs/suite-ReleaseSafe.log 2>&1
echo "SUITE rc=$? $(tail -n 1 /tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad/r6p/logs/suite-ReleaseSafe.log | head -c 80) $(( $(date +%s)-t ))s"
rm -rf /tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad/r6p-w
echo ALL-DONE
