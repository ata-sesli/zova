#!/bin/sh
# Issue #196 bounded trial runner: baseline vs candidate ObjectWriter ingest.
# One warmup then three measured samples per variant/profile/write size, in
# alternating order. Each sample uses a new database that is removed after the
# run. Expected cost: about 256 MiB of disk per live sample and under 10 minutes
# on an i7-6700HQ.
set -eu
root=${1:?external benchmark directory required}
total=${2:-268435456}
base_bin=$root/base/bin/zova_object_writer_196_benchmark
cand_bin=$root/cand/bin/zova_object_writer_196_benchmark
results=$(mktemp -d "$root/issue196-trials.XXXXXX")
printf 'Results: %s\n' "$results"
for profile in streaming deduplication; do
    for write in 1048576 8388608 67108864; do
        for run in 0 1 2 3; do
            case "$run" in
                0|2) variants='baseline candidate' ;;
                *) variants='candidate baseline' ;;
            esac
            for variant in $variants; do
                if [ "$variant" = baseline ]; then bin=$base_bin; else bin=$cand_bin; fi
                db=$results/$variant-$profile-$write-$run.zova
                output=$results/out-$variant-$profile-$write-$run.txt
                printf '%s %s write=%s run=%s: ' "$variant" "$profile" "$write" "$run"
                "$bin" "$db" "$profile" "$write" "$total" 2> "$output"
                rm -f "$db" "$db-journal"
                cat "$output"
            done
        done
    done
done
