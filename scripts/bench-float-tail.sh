#!/bin/sh
# Darwin diagnostic: separately linked dylibs, alternating in one thread/process.
set -eu
root=${1:?external artifact directory required}
baseline_source=${2:?exported baseline source directory required}
case "$(uname -s)" in Darwin) ;; *) echo 'This diagnostic currently requires Darwin' >&2; exit 2;; esac
out=$(mktemp -d "$root/issue42-same-process.XXXXXX")
printf 'Artifacts: %s\n' "$out"
for variant in baseline candidate; do
    printf 'Building %s\n' "$variant"
    if [ "$variant" = baseline ]; then source="$baseline_source"; else source=$(pwd); fi
    (cd "$source" && zig build c-abi -Doptimize=ReleaseFast --cache-dir "$root/local" --global-cache-dir "$root/../zig-global" --prefix "$out/$variant")
    clang -dynamiclib -Wl,-all_load "$out/$variant/lib/libzova_c.a" -o "$out/$variant.dylib"
done
clang -std=c11 -O2 -Wall -Wextra -Werror -I include bench/float_tail.c -o "$out/float-tail"
printf 'Sampling two cases, 7 x 512 paired samples per phase; no concurrent builds\n'
"$out/float-tail" "$out/baseline.dylib" "$out/candidate.dylib" > "$out/samples.csv"
printf 'Completed: %s/samples.csv\n' "$out"
