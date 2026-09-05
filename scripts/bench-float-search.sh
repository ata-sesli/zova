#!/bin/sh
set -eu
root=${1:?external benchmark directory required}
mode=${2:-compare}
binary_prefix=${3:-issue42}
fixture=${4:-all}
case "$fixture" in
    all|short) ;;
    *) exit 2 ;;
esac
case "$mode" in
    baseline) runs=0 ;;
    compare) runs='0 1 2 3 4 5 6 7' ;;
    *) exit 2 ;;
esac
results=$(mktemp -d "$root/issue42-trials.XXXXXX")
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
        if [ "$fixture" = short ]; then
            "$root/$binary_prefix-$variant/bin/zova_float_search_benchmark" short 2> "$results/$variant-$run.txt"
        else
            "$root/$binary_prefix-$variant/bin/zova_float_search_benchmark" 2> "$results/$variant-$run.txt"
        fi
        printf 'saved %s\n' "$results/$variant-$run.txt"
    done
done
