#!/bin/sh
# Issue #100 bounded scope-audit runner. No production candidate is expected
# unless the audit identifies a safe repeated lookup. Baseline and candidate
# use the common protocol and fresh databases for comparison.
set -eu
root=${1:?external benchmark directory required}
base_bin=$root/base/bin/zova_resolution_scope_100_benchmark
cand_bin=$root/cand/bin/zova_resolution_scope_100_benchmark
results=$(mktemp -d "$root/issue100-trials.XXXXXX")
printf 'Results: %s\n' "$results"
run_one() {
    variant=$1 workload=$2 store=$3 run=$4
    case "$variant" in baseline) bin=$base_bin;; candidate) bin=$cand_bin;; esac
    db=$results/$variant-$workload-$store-$run.zova
    printf '%s workload=%s store=%s run=%s\n' "$variant" "$workload" "$store" "$run"
    timeout 60 "$bin" "$db" "$workload" "$store" 2>&1 | sed "s|^|$variant run=$run |"
    rm -f "$db" "$db-store.zova" "$db-wal" "$db-shm"
}
for workload in graph object; do
    for store in main bound; do
        printf 'WARMUP workload=%s store=%s\n' "$workload" "$store"
        run_one baseline "$workload" "$store" warmup >/dev/null
        run_one candidate "$workload" "$store" warmup >/dev/null
        run_one baseline "$workload" "$store" 0
        run_one candidate "$workload" "$store" 0
        run_one candidate "$workload" "$store" 1
        run_one baseline "$workload" "$store" 1
        run_one baseline "$workload" "$store" 2
        run_one candidate "$workload" "$store" 2
    done
done
