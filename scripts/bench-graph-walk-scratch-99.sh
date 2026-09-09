#!/bin/sh
# Issue #99 bounded trial runner. Usage: sh ... EXTERNAL_BENCH_DIR
set -eu
root=${1:?external benchmark directory required}
base_bin=$root/base/bin/zova_graph_walk_scratch_99_benchmark
cand_bin=$root/cand/bin/zova_graph_walk_scratch_99_benchmark
results=$(mktemp -d "$root/issue99-trials.XXXXXX")
printf 'Results: %s\n' "$results"
run_one() {
    variant=$1 store=$2 run=$3
    case "$variant" in baseline) bin=$base_bin;; candidate) bin=$cand_bin;; esac
    db=$results/$variant-$store-$run.zova
    printf '%s store=%s run=%s\n' "$variant" "$store" "$run"
    timeout 60 "$bin" "$db" "$store" 2>&1 | sed "s|^|$variant run=$run |"
    rm -f "$db" "$db-store.zova" "$db-wal" "$db-shm"
}
for store in main bound; do
    printf 'WARMUP store=%s\n' "$store"
    run_one baseline "$store" warmup >/dev/null
    run_one candidate "$store" warmup >/dev/null
    run_one baseline "$store" 0
    run_one candidate "$store" 0
    run_one candidate "$store" 1
    run_one baseline "$store" 1
    run_one baseline "$store" 2
    run_one candidate "$store" 2
done
