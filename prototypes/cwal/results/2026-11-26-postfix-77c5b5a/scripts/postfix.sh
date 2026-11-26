#!/bin/bash
# Post-fix regression on the frozen baseline: build 3 modes, reduced suite each, mutation sweep, model check.
S=/tmp/claude-1000/-home-atawirtz-workspace-zova/daa0c463-140c-4b37-9672-84b77de94139/scratchpad
P=/home/atawirtz/workspace/zova/prototypes/cwal
. ~/tools/zova-wasm-env.sh
cd $P
echo "BASELINE $(git rev-parse HEAD) $(date -Is)"
for m in Debug ReleaseSafe ReleaseFast; do
  rm -rf $S/base-$m
  zig build -Doptimize=$m -p $S/base-$m || { echo "BUILD FAIL $m"; exit 1; }
  echo "BUILT $m $(sha256sum $S/base-$m/bin/cwal | cut -c1-16)"
done
O="--jobs 8 --powerloss-seeds 1 --ncap 300 --allcap 400 --survivor-trials 5 --restart-seeds 1 --io-positions 4 --files 2 3 8"
for m in Debug ReleaseSafe ReleaseFast; do
  t=$(date +%s); echo "SUITE $m start $(date +%T)"
  CWAL_BIN=$S/base-$m/bin/cwal python3 -u torture.py --work $S/reg-w $O > $S/post-$m.log 2>&1
  echo "SUITE $m rc=$? $(tail -1 $S/post-$m.log | head -c 80) $(( $(date +%s)-t ))s"
  rm -rf $S/reg-w
done
sed -e "s#out-ReleaseSafe#base-ReleaseSafe#" -e "s#mut-\$mu.log#post-mut-\$mu.log#" $S/mutsweep.sh > $S/postmut.sh
bash $S/postmut.sh
t=$(date +%s)
CWAL_BIN=$S/base-Debug/bin/cwal CWAL_MUTATE=no-late-alone python3 torture.py --work $S/mut-w --only ndangle --jobs 8 --powerloss-seeds 1 --survivor-trials 10 --restart-seeds 2 --files 3 8 > $S/post-mut-late-alone-debug.log 2>&1
echo "MUT no-late-alone [ndangle, Debug] rc=$? $(( $(date +%s)-t ))s"; rm -rf $S/mut-w
t=$(date +%s); python3 model.py > $S/post-model.log 2>&1
echo "MODEL rc=$? $(( $(date +%s)-t ))s"
echo ALL-DONE $(date -Is)
