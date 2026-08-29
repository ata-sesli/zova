#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_ZIG="$ROOT/src/version.zig"

usage() {
    echo "usage: scripts/bump-version.sh <major.minor.patch[-rc.N]>" >&2
    exit 2
}

[ "$#" -eq 1 ] || usage
new_version="$1"
core_version="${new_version%%-*}"
prerelease=""
if [ "$core_version" != "$new_version" ]; then
    prerelease="${new_version#*-}"
    case "$prerelease" in
        rc.[0-9]*) ;;
        *) usage ;;
    esac
fi

case "$core_version" in
    *[!0-9.]* | .* | *. | *..*) usage ;;
esac

major="${core_version%%.*}"
rest="${core_version#*.}"
[ "$rest" != "$core_version" ] || usage
minor="${rest%%.*}"
patch="${rest#*.}"
[ "$patch" != "$rest" ] || usage
case "$patch" in
    *.*) usage ;;
esac

[ "$major.$minor.$patch" = "$core_version" ] || usage
[ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] || usage

python_version="$core_version"
if [ -n "$prerelease" ]; then
    rc_number="${prerelease#rc.}"
    case "$rc_number" in
        0 | [1-9] | [1-9][0-9]*) ;;
        *) usage ;;
    esac
    python_version="${core_version}rc${rc_number}"
fi

old_version="$(sed -n 's/^[[:space:]]*pub const package_version[[:space:]]*=[[:space:]]*"\([^"]*\)";.*/\1/p' "$VERSION_ZIG" | head -n 1)"
[ -n "$old_version" ] || {
    echo "could not read package_version from src/version.zig" >&2
    exit 1
}

replace_literal() {
    file="$1"
    old_value="$2"
    new_value="$3"
    [ -f "$file" ] || return 0
    old_re="$(printf '%s' "$old_value" | sed 's/[.[\*^$()+?{}|]/\\&/g')"
    tmp="${file}.tmp.$$"
    cp -p "$file" "$tmp"
    sed "s/$old_re/$new_value/g" "$file" >"$tmp"
    mv "$tmp" "$file"
}

replace_all() {
    replace_literal "$1" "$old_version" "$new_version"
}

replace_line() {
    file="$1"
    pattern="$2"
    replacement="$3"
    [ -f "$file" ] || return 0
    tmp="${file}.tmp.$$"
    cp -p "$file" "$tmp"
    sed "s/$pattern/$replacement/" "$file" >"$tmp"
    mv "$tmp" "$file"
}

replace_all "$VERSION_ZIG"
replace_line "$VERSION_ZIG" 'pub const abi_version_major: u32 = [0-9][0-9]*;' "pub const abi_version_major: u32 = $major;"
replace_line "$VERSION_ZIG" 'pub const abi_version_minor: u32 = [0-9][0-9]*;' "pub const abi_version_minor: u32 = $minor;"
replace_line "$VERSION_ZIG" 'pub const abi_version_patch: u32 = [0-9][0-9]*;' "pub const abi_version_patch: u32 = $patch;"

for file in \
    "$ROOT/build.zig.zon" \
    "$ROOT/README.md" \
    "$ROOT/API_STABILITY.md" \
    "$ROOT/docs/extensions.md" \
    "$ROOT/docs/storage-compatibility.md" \
    "$ROOT/include/zova.h" \
    "$ROOT/examples/zig_bridge/bridge.zig" \
    "$ROOT/scripts/package-release.sh" \
    "$ROOT/scripts/build-release-artifacts.sh" \
    "$ROOT/tests/cli.zig" \
    "$ROOT/bindings/rust/Cargo.toml" \
    "$ROOT/bindings/rust/Cargo.lock" \
    "$ROOT/bindings/rust/README.md" \
    "$ROOT/bindings/rust/zova/Cargo.toml" \
    "$ROOT/bindings/rust/zova-sys/README.md" \
    "$ROOT/bindings/rust/zova-sys/tests/abi.rs" \
    "$ROOT/bindings/go/README.md" \
    "$ROOT/bindings/go/zova_test.go" \
    "$ROOT/bindings/python/Cargo.toml" \
    "$ROOT/bindings/python/Cargo.lock" \
    "$ROOT/bindings/python/README.md" \
    "$ROOT/bindings/python/rust/zova/Cargo.toml" \
    "$ROOT/bindings/python/rust/zova-sys/Cargo.toml" \
    "$ROOT/bindings/python/rust/zova-sys/tests/abi.rs" \
    "$ROOT/bindings/rust/zova-sys/native/build.zig.zon" \
    "$ROOT/bindings/rust/zova-sys/native/include/zova.h" \
    "$ROOT/bindings/rust/zova-sys/native/src/version.zig" \
    "$ROOT/bindings/rust/zova-sys/native/tests/cli.zig" \
    "$ROOT/bindings/rust/zova-sys/native/src/c_api_internal.zig" \
    "$ROOT/bindings/python/rust/zova-sys/native/build.zig.zon" \
    "$ROOT/bindings/python/rust/zova-sys/native/include/zova.h" \
    "$ROOT/bindings/python/rust/zova-sys/native/src/version.zig" \
    "$ROOT/bindings/python/rust/zova-sys/native/tests/cli.zig" \
    "$ROOT/bindings/python/rust/zova-sys/native/src/c_api_internal.zig" \
    "$ROOT/bindings/javascript/Cargo.toml" \
    "$ROOT/bindings/javascript/Cargo.lock" \
    "$ROOT/bindings/javascript/package.json" \
    "$ROOT/bindings/javascript/bun.lock" \
    "$ROOT/bindings/javascript/index.js" \
    "$ROOT/bindings/javascript/README.md" \
    "$ROOT/bindings/javascript/tests/package-names.test.ts" \
    "$ROOT/bindings/javascript/tests/load.test.ts" \
    "$ROOT/bindings/javascript/tests/runtime-smoke.mjs" \
    "$ROOT/bindings/javascript/tests/runtime-smoke.cjs"
do
    replace_all "$file"
done

# Extension manifests deliberately use numeric major.minor.patch ABI minima,
# even when the package release itself is a prerelease.
replace_line "$ROOT/examples/zig_bridge/bridge.zig" '\.zova_abi_min = "[^"]*"' ".zova_abi_min = \"$core_version\""
replace_line "$ROOT/tests/cli.zig" '\.zova_abi_min = "[^"]*"' ".zova_abi_min = \"$core_version\""

old_python_version="$old_version"
case "$old_version" in
    *-rc.*) old_python_version="${old_version%%-rc.*}rc${old_version##*-rc.}" ;;
esac

for file in \
    "$ROOT/bindings/python/pyproject.toml" \
    "$ROOT/bindings/python/python/zova/__init__.py" \
    "$ROOT/bindings/python/tests/test_lifecycle.py"
do
    replace_literal "$file" "$old_python_version" "$python_version"
done

for file in \
    "$ROOT/bindings/rust/zova-sys/tests/abi.rs" \
    "$ROOT/bindings/python/rust/zova-sys/tests/abi.rs"
do
    replace_line "$file" 'zova_abi_version_major(), [0-9][0-9]*' "zova_abi_version_major(), $major"
    replace_line "$file" 'zova_abi_version_minor(), [0-9][0-9]*' "zova_abi_version_minor(), $minor"
    replace_line "$file" 'zova_abi_version_patch(), [0-9][0-9]*' "zova_abi_version_patch(), $patch"
done

replace_line "$ROOT/bindings/go/zova_test.go" 'major != [0-9][0-9]* || minor != [0-9][0-9]* || patch != [0-9][0-9]*' "major != $major || minor != $minor || patch != $patch"

echo "bumped Zova version: $old_version -> $new_version"
echo "run: sh scripts/check-versions.sh"
echo "then sync generated/native mirrors if needed"
