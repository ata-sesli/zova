#!/bin/sh
# Issue #159 bounded trial runner: baseline (before format-12 change tracking)
# vs candidate, alternating order, one warmup then seven measured samples per
# variant/store/type/count/mode. 768 short invocations and a few MiB
# of scratch database at a time, removed as each sample finishes.
set -eu
root=${1:?benchmark directory with base/ and cand/ install prefixes required}
base_bin=$root/base/bin/zova_vector_norms_94_benchmark
cand_bin=$root/cand/bin/zova_vector_norms_94_benchmark
results=$(mktemp -d "$root/issue159-trials.XXXXXX")
printf 'Results: %s\n' "$results"
for store in main bound; do
    for count in 256 2048; do
        for typ in f32 f16 i8; do
            for mode in fresh replay single delete; do
                for run in 0 1 2 3 4 5 6 7; do
                    case "$run" in
                        0|2|4|6) variants='baseline candidate' ;;
                        *) variants='candidate baseline' ;;
                    esac
                    for variant in $variants; do
                        db=$results/$variant-$store-$typ-$count-$mode-$run.zova
                        if [ "$variant" = baseline ]; then bin=$base_bin; else bin=$cand_bin; fi
                        if [ "$store" = bound ]; then
                            "$bin" "$db" "$typ" "$count" "$mode" bound 2> "$results/out.txt"
                        else
                            "$bin" "$db" "$typ" "$count" "$mode" 2> "$results/out.txt"
                        fi
                        bytes=$(cat "$db" "$db.vectors.zova" 2>/dev/null | wc -c | tr -d ' ')
                        printf '%s run=%s bytes=%s %s\n' "$variant" "$run" "$bytes" "$(cat "$results/out.txt")" |
                            tee -a "$results/samples.txt"
                        rm -f "$db" "$db.vectors.zova" "$results/out.txt"
                    done
                done
            done
        done
    done
done
printf 'Samples retained in %s\n' "$results/samples.txt"
