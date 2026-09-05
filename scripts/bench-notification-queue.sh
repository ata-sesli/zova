#!/bin/sh
# One warmup and seven measured trials, reversing variant order each time.
set -eu
root=${1:?external benchmark directory required}
mode=${2:-compare}
case "$mode" in
    baseline) runs=0 ;;
    compare) runs='0 1 2 3 4 5 6 7' ;;
    *) exit 2 ;;
esac
results=$(mktemp -d "$root/issue46-trials.XXXXXX")
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
        "$root/issue46-$variant/bin/zova_notifications_benchmark" queue \
            2> "$results/$variant-$run.txt"
        cat "$results/$variant-$run.txt"
    done
done
