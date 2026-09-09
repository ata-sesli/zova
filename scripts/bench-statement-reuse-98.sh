#!/bin/sh
# Issue #98 bounded trial runner: baseline vs candidate, alternating order.
# One warmup per variant, then three measured trials per variant in
# B,C,C,B,B,C order. Each process gets a fresh database file.
# Usage: sh scripts/bench-statement-reuse-98.sh EXTERNAL_BENCH_DIR
set -eu
root=${1:?external benchmark directory required}
base_bin=$root/base/bin/zova_statement_reuse_98_benchmark
cand_bin=$root/cand/bin/zova_statement_reuse_98_benchmark
results=$(mktemp -d "$root/issue98-trials.XXXXXX")
printf 'Results: %s\n' "$results"

run_one() {
    variant=$1 workload=$2 store=$3 run=$4
    case "$variant" in
        baseline) bin=$base_bin ;;
        *) bin=$cand_bin ;;
    esac
    printf '%s workload=%s store=%s run=%s\n' "$variant" "$workload" "$store" "$run"
    db=$results/$variant-$workload-$store-$run.zova
    timeout 60 "$bin" "$db" "$workload" "$store" 2>&1 |
        sed "s|^|$variant run=$run |"
    rm -f "$db" "$db-store.zova" "$db-wal" "$db-shm"
}

for workload in graph object; do
    for store in main bound; do
        printf 'WARMUP workload=%s store=%s\n' "$workload" "$store"
        run_one baseline "$workload" "$store" warmup > /dev/null
        run_one candidate "$workload" "$store" warmup > /dev/null
        run_one baseline "$workload" "$store" 0
        run_one candidate "$workload" "$store" 0
        run_one candidate "$workload" "$store" 1
        run_one baseline "$workload" "$store" 1
        run_one baseline "$workload" "$store" 2
        run_one candidate "$workload" "$store" 2
    done
done
