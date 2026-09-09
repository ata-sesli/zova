#!/bin/sh
# Issue #95 bounded trial runner: baseline vs candidate, alternating order.
# One warmup per variant, then three measured trials per variant in
# B,C,C,B,B,C order. Each process gets a fresh database file.
set -eu
root=${1:?external benchmark directory required}
base_bin=$root/base/bin/zova_graph_index_ddl_95_benchmark
cand_bin=$root/cand/bin/zova_graph_index_ddl_95_benchmark
results=$(mktemp -d "$root/issue95-trials.XXXXXX")
printf 'Results: %s\n' "$results"

run_one() {
    variant=$1 edges=$2 mode=$3 store=$4 run=$5
    case "$variant" in
        baseline) bin=$base_bin ;;
        *) bin=$cand_bin ;;
    esac
    printf '%s edges=%s mode=%s store=%s run=%s: ' "$variant" "$edges" "$mode" "$store" "$run"
    db=$results/$variant-$edges-$mode-$store-$run.zova
    output=$results/$variant-$edges-$mode-$store-$run.txt
    # A pipeline ending in sed hides benchmark failures under POSIX sh.
    if timeout 60 "$bin" "$db" "$edges" "$mode" "$store" > "$output" 2>&1; then
        sed "s|^|$variant run=$run |" "$output"
    else
        status=$?
        cat "$output" >&2
        return "$status"
    fi
    rm -f "$db" "$db-store.zova" "$db-wal" "$db-shm"
}

for edges in 1 16 1024; do
    for mode in steady dropped; do
        for store in main bound; do
            printf 'WARMUP edges=%s mode=%s store=%s\n' "$edges" "$mode" "$store"
            run_one baseline "$edges" "$mode" "$store" warmup > /dev/null
            run_one candidate "$edges" "$mode" "$store" warmup > /dev/null
            run_one baseline "$edges" "$mode" "$store" 0
            run_one candidate "$edges" "$mode" "$store" 0
            run_one candidate "$edges" "$mode" "$store" 1
            run_one baseline "$edges" "$mode" "$store" 1
            run_one baseline "$edges" "$mode" "$store" 2
            run_one candidate "$edges" "$mode" "$store" 2
        done
    done
done
