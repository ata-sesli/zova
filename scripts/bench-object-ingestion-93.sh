#!/bin/sh
# Issue #93 bounded trial runner: baseline vs candidate, alternating order,
# one warmup then seven measured samples per variant/profile/size.
set -eu
root=${1:?external benchmark directory required}
# Build the same size-aware harness against both revisions. The older
# zova_object_ingestion_benchmark has a fixed 1 MiB fixture and is not valid here.
base_bin=$root/base/bin/zova_object_ingestion_93_benchmark
cand_bin=$root/cand/bin/zova_object_ingestion_93_benchmark
results=$(mktemp -d "$root/issue93-trials.XXXXXX")
printf 'Results: %s\n' "$results"
for size in 1048576 8388608; do
    for profile in deduplication streaming; do
        for run in 0 1 2 3 4 5 6 7; do
            case "$run" in
                0|2|4|6) variants='baseline candidate' ;;
                *) variants='candidate baseline' ;;
            esac
            for variant in $variants; do
                printf '%s %s size=%s run=%s: ' "$variant" "$profile" "$size" "$run"
                if [ "$variant" = baseline ]; then
                    "$base_bin" "$results/base-$profile-$size-$run.zova" "$profile" "$size" \
                        2> "$results/out-$variant-$profile-$size-$run.txt"
                else
                    "$cand_bin" "$results/cand-$profile-$size-$run.zova" "$profile" "$size" \
                        2> "$results/out-$variant-$profile-$size-$run.txt"
                fi
                output=$results/out-$variant-$profile-$size-$run.txt
                if ! grep -q "^profile=$profile bytes=$size " "$output"; then
                    printf 'Benchmark reported the wrong profile/size: %s\n' "$output" >&2
                    exit 1
                fi
                cat "$output"
            done
        done
    done
done
