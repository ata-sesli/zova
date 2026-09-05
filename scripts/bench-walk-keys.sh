#!/bin/sh
set -eu
root=${1:?external benchmark directory required}
mode=${2:-compare}
case "$mode" in
    baseline) runs=0 ;;
    compare) runs='0 1 2 3 4 5 6 7' ;;
    *) exit 2 ;;
esac
results=$(mktemp -d "$root/issue43-trials.XXXXXX")
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
        "$root/issue43-$variant/bin/zova_walk_keys_benchmark" 2> "$results/$variant-$run.txt"
        cat "$results/$variant-$run.txt"
    done
done
