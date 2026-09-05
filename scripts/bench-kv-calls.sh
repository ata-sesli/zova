#!/bin/sh
# Prebuild baseline and candidate with build-kv-calls; run one bounded batch.
set -eu
root=${1:?external benchmark directory required}
mode=${2:-compare}
case "$mode" in
    baseline) runs=0 ;;
    compare) runs='0 1 2 3 4 5 6 7' ;;
    *) exit 2 ;;
esac
results=$(mktemp -d "$root/issue45-trials.XXXXXX")
printf 'Results: %s\n' "$results"
for run in $runs; do
    if [ "$mode" = baseline ]; then
        variants=baseline
    else
        case "$run" in
            0|2|4|6) variants='baseline candidate' ;;
            *) variants='candidate baseline' ;;
        esac
    fi
    for variant in $variants; do
        printf '%s run=%s\n' "$variant" "$run"
        "$root/issue45-$variant/bin/zova_kv_calls_benchmark" \
            "$results/$variant-$run.zova" 2> "$results/$variant-$run.txt"
        cat "$results/$variant-$run.txt"
    done
done
