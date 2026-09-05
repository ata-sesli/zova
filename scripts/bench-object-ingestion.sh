#!/bin/sh
# Three prebuilt variants; one warmup then seven measured samples per profile.
set -eu
root=${1:?external benchmark directory required}
results=$(mktemp -d "$root/issue44-trials.XXXXXX")
printf 'Results: %s\n' "$results"
for profile in deduplication streaming; do
    for run in 0 1 2 3 4 5 6 7; do
        case "$run" in
            0|2|4|6) variants='baseline count borrowed' ;;
            *) variants='borrowed count baseline' ;;
        esac
        for variant in $variants; do
            printf '%s %s run=%s: ' "$variant" "$profile" "$run"
            "$root/issue44-$variant/bin/zova_object_ingestion_benchmark" \
                "$results/$variant-$profile-$run.zova" "$profile" \
                2> "$results/$variant-$profile-$run.txt"
            cat "$results/$variant-$profile-$run.txt"
        done
    done
done
