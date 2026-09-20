#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
run_root=${ZOVA_GRAPH_BIND_BENCH_ROOT:-/Volumes/wipesides/codebase-memory-mcp-cache/zova-graph-borrowed-bindings}
node_count=${ZOVA_GRAPH_BIND_NODES:-25000}
edge_count=${ZOVA_GRAPH_BIND_EDGES:-100000}

if [ ! -d "$(dirname "$run_root")" ]; then
    echo "external benchmark parent does not exist: $(dirname "$run_root")" >&2
    exit 1
fi

rm -rf "$run_root"
mkdir -p "$run_root/baseline-src" "$run_root/build" "$run_root/db" "$run_root/logs"

git -C "$repo_root" archive HEAD | tar -x -C "$run_root/baseline-src"
cp "$repo_root/build.zig" "$run_root/baseline-src/build.zig"
cp "$repo_root/bench/graph_borrowed_bindings.zig" "$run_root/baseline-src/bench/graph_borrowed_bindings.zig"

build_variant() {
    variant=$1
    source=$2
    echo "building $variant benchmark"
    (
        cd "$source"
        ZIG_GLOBAL_CACHE_DIR="$run_root/build/global-cache" \
        ZIG_LOCAL_CACHE_DIR="$run_root/build/$variant-cache" \
            zig build build-graph-borrowed-bindings -Doptimize=ReleaseFast \
            --prefix "$run_root/build/$variant"
    )
}

build_variant baseline "$run_root/baseline-src"
build_variant candidate "$repo_root"

baseline="$run_root/build/baseline/bin/zova_graph_borrowed_bindings_benchmark"
candidate="$run_root/build/candidate/bin/zova_graph_borrowed_bindings_benchmark"
samples="$run_root/logs/samples.tsv"
: >"$samples"

run_one() {
    mode=$1
    variant=$2
    sample=$3
    binary=$baseline
    if [ "$variant" = candidate ]; then binary=$candidate; fi
    db="$run_root/db/$mode-$variant-$sample.zova"
    output=$($binary "$mode" "$db" "$node_count" "$edge_count" 2>&1)
    printf '%s\n' "$output" >>"$run_root/logs/$mode-$variant.log"
    value=$(printf '%s\n' "$output" | sed -n 's/^result .* total_ms=\([0-9.]*\)$/\1/p')
    if [ -z "$value" ]; then
        echo "missing benchmark result for $mode $variant sample $sample" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$mode" "$variant" "$sample" "$value" | tee -a "$samples"
}

for mode in fresh endpoints; do
    echo "warming $mode"
    run_one "$mode" baseline warmup
    run_one "$mode" candidate warmup
    sample=0
    for variant in baseline candidate candidate baseline baseline candidate candidate baseline baseline candidate candidate baseline baseline candidate; do
        sample=$((sample + 1))
        run_one "$mode" "$variant" "$sample"
    done
done

summarize() {
    mode=$1
    variant=$2
    values="$run_root/logs/$mode-$variant.values"
    awk -F '\t' -v mode="$mode" -v variant="$variant" \
        '$1 == mode && $2 == variant && $3 != "warmup" { print $4 }' "$samples" | sort -n >"$values"
    median=$(sed -n '4p' "$values")
    mad=$(awk -v median="$median" '{ delta = $1 - median; if (delta < 0) delta = -delta; print delta }' "$values" | sort -n | sed -n '4p')
    printf 'summary mode=%s variant=%s median_ms=%s mad_ms=%s\n' "$mode" "$variant" "$median" "$mad"
}

for mode in fresh endpoints; do
    summarize "$mode" baseline
    summarize "$mode" candidate
done

echo "artifacts=$run_root"
