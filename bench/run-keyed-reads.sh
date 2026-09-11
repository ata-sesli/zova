#!/bin/sh
# Pass two binaries built from the same harness and a pre-existing fixture.
set -eu
if [ "$#" -ne 4 ]; then
    printf 'usage: sh bench/run-keyed-reads.sh BASELINE CANDIDATE FIXTURE RESULTS\n' >&2
    exit 2
fi
baseline=$1
candidate=$2
fixture=$3
results=$4
mkdir -p "$results"
for kind in nodes edges; do
    for size in 1 100 10000 100000; do
        for input in hits mixed; do
            block=0
            for variant in a b b a b a a b; do
                block=$((block + 1))
                if [ "$variant" = a ]; then binary=$baseline; else binary=$candidate; fi
                log="$results/$kind-$size-$input-$block-$variant.log"
                if [ -e "$log" ]; then
                    printf 'refusing to overwrite %s\n' "$log" >&2
                    exit 1
                fi
                "$binary" "$fixture" case "$kind" "$size" "$input" >"$log" 2>&1
                printf 'completed %s %s %s block=%s variant=%s\n' "$kind" "$size" "$input" "$block" "$variant"
            done
        done
    done
done
