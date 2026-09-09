#!/bin/sh
# Issue #94 bounded trial runner: baseline vs candidate, alternating order,
# one warmup then seven measured samples per variant/type/count/mode.
set -eu
root=${1:?external benchmark directory required}
base_bin=$root/base/bin/zova_vector_norms_94_benchmark
cand_bin=$root/cand/bin/zova_vector_norms_94_benchmark
results=$(mktemp -d "$root/issue94-trials.XXXXXX")
printf 'Results: %s\n' "$results"
for count in 256 2048; do
    for typ in f32 f16 i8; do
        for mode in fresh replay; do
            for run in 0 1 2 3 4 5 6 7; do
                case "$run" in
                    0|2|4|6) variants='baseline candidate' ;;
                    *) variants='candidate baseline' ;;
                esac
                for variant in $variants; do
                    printf '%s %s count=%s mode=%s run=%s: ' "$variant" "$typ" "$count" "$mode" "$run"
                    if [ "$variant" = baseline ]; then
                        "$base_bin" "$results/base-$typ-$count-$mode-$run.zova" "$typ" "$count" "$mode" \
                            2> "$results/out-$variant-$typ-$count-$mode-$run.txt"
                    else
                        "$cand_bin" "$results/cand-$typ-$count-$mode-$run.zova" "$typ" "$count" "$mode" \
                            2> "$results/out-$variant-$typ-$count-$mode-$run.txt"
                    fi
                    cat "$results/out-$variant-$typ-$count-$mode-$run.txt"
                done
            done
        done
    done
done
