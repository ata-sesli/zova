#!/bin/sh
# Issue #227 bounded trial runner: object ingest and reads without and with
# LZ4 chunk compression, against the pre-#227 baseline. Variants: baseline
# (compression none), candidate none, candidate lz4. Per profile and fixture
# (compressible text, incompressible noise): one warmup then three measured
# samples, rotating variant order, a new database per sample that is removed
# after the run. Expected cost: about 256 MiB of disk and 600 MiB of memory
# per live sample, and about 12 minutes on an i7-6700HQ.
set -eu
root=${1:?external benchmark directory required}
total=${2:-268435456}
base_bin=$root/base/bin/zova_object_compression_227_benchmark
cand_bin=$root/cand/bin/zova_object_compression_227_benchmark
results=$(mktemp -d "$root/issue227-trials.XXXXXX")
printf 'Results: %s\n' "$results"
for profile in streaming deduplication; do
    for data in text noise; do
        for run in 0 1 2 3; do
            case "$run" in
                0) variants='baseline candidate-none candidate-lz4' ;;
                1) variants='candidate-lz4 baseline candidate-none' ;;
                2) variants='candidate-none candidate-lz4 baseline' ;;
                *) variants='baseline candidate-lz4 candidate-none' ;;
            esac
            for variant in $variants; do
                case "$variant" in
                    baseline) bin=$base_bin compression=none ;;
                    candidate-none) bin=$cand_bin compression=none ;;
                    *) bin=$cand_bin compression=lz4 ;;
                esac
                db=$results/$variant-$profile-$data-$run.zova
                output=$results/out-$variant-$profile-$data-$run.txt
                printf '%s %s %s run=%s: ' "$variant" "$profile" "$data" "$run"
                "$bin" "$db" "$profile" "$compression" "$data" "$total" 2> "$output"
                rm -f "$db" "$db-journal"
                cat "$output"
            done
        done
    done
done
