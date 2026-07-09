#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_ZIG="$ROOT/src/version.zig"

read_zig_string() {
    name="$1"
    sed -n "s/^[[:space:]]*pub const ${name}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\";.*/\1/p" "$VERSION_ZIG" | head -n 1
}

read_zig_u32() {
    name="$1"
    sed -n "s/^[[:space:]]*pub const ${name}[[:space:]]*:[[:space:]]*u32[[:space:]]*=[[:space:]]*\([0-9][0-9]*\);.*/\1/p" "$VERSION_ZIG" | head -n 1
}

fail() {
    echo "version check failed: $*" >&2
    exit 1
}

expect_value() {
    label="$1"
    expected="$2"
    actual="$3"
    if [ "$expected" != "$actual" ]; then
        fail "$label expected '$expected' but found '$actual'"
    fi
}

expect_contains() {
    file="$1"
    needle="$2"
    if ! grep -F "$needle" "$file" >/dev/null 2>&1; then
        fail "$file does not contain: $needle"
    fi
}

package_version="$(read_zig_string package_version)"
abi_major="$(read_zig_u32 abi_version_major)"
abi_minor="$(read_zig_u32 abi_version_minor)"
abi_patch="$(read_zig_u32 abi_version_patch)"
abi_version_string="$(read_zig_string abi_version_string)"
format_version="$(read_zig_string format_version)"
sqlite_version="$(read_zig_string sqlite_version)"
minimum_zig_version="$(read_zig_string minimum_zig_version)"

[ -n "$package_version" ] || fail "missing src/version.zig package_version"
[ -n "$abi_major" ] || fail "missing src/version.zig abi_version_major"
[ -n "$abi_minor" ] || fail "missing src/version.zig abi_version_minor"
[ -n "$abi_patch" ] || fail "missing src/version.zig abi_version_patch"
[ -n "$format_version" ] || fail "missing src/version.zig format_version"
[ -n "$sqlite_version" ] || fail "missing src/version.zig sqlite_version"
[ -n "$minimum_zig_version" ] || fail "missing src/version.zig minimum_zig_version"

expect_value "package ABI version" "$package_version" "$abi_version_string"
expect_value "ABI numeric string" "$abi_major.$abi_minor.$abi_patch" "$abi_version_string"

manifest_version="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n 1)"
manifest_min_zig="$(sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n 1)"
expect_value "build.zig.zon .version" "$package_version" "$manifest_version"
expect_value "build.zig.zon .minimum_zig_version" "$minimum_zig_version" "$manifest_min_zig"

[ -d "$ROOT/vendor/sqlite${sqlite_version}" ] || fail "missing vendor/sqlite${sqlite_version}"
expect_contains "$ROOT/build.zig" 'src/version.zig'
expect_contains "$ROOT/src/zova.zig" 'const format_version = version.format_version;'
expect_contains "$ROOT/src/cli.zig" 'zova.version.format_version'
expect_contains "$ROOT/src/cli.zig" 'zova.version.sqlite_version'
expect_contains "$ROOT/tests/cli.zig" 'zova.version.sqlite_version'
expect_contains "$ROOT/scripts/update-generated-c.sh" 'sqlite_version'
expect_contains "$ROOT/include/zova.h" "Zova C ABI, v${abi_version_string} pre-1.0."

expect_contains "$ROOT/README.md" "Current package version: \`${package_version}\`."
expect_contains "$ROOT/README.md" "format_version\` is \`${format_version}\`"

expect_contains "$ROOT/bindings/rust/Cargo.toml" "version = \"${package_version}\""
expect_contains "$ROOT/bindings/rust/zova/Cargo.toml" "zova-sys = { version = \"${package_version}\""
expect_contains "$ROOT/bindings/rust/zova-sys/tests/abi.rs" "zova_abi_version_major(), ${abi_major}"
expect_contains "$ROOT/bindings/rust/zova-sys/tests/abi.rs" "zova_abi_version_minor(), ${abi_minor}"
expect_contains "$ROOT/bindings/rust/zova-sys/tests/abi.rs" "zova_abi_version_patch(), ${abi_patch}"
expect_contains "$ROOT/bindings/rust/zova-sys/tests/abi.rs" "\"${abi_version_string}\""

expect_contains "$ROOT/bindings/go/README.md" "bindings/go/v${package_version}"
expect_contains "$ROOT/bindings/go/zova_test.go" "got != \"${abi_version_string}\""

expect_contains "$ROOT/bindings/python/pyproject.toml" "version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/Cargo.toml" "version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/Cargo.toml" "zova\", version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/python/zova/__init__.py" "__version__ = \"${package_version}\""
expect_contains "$ROOT/bindings/python/tests/test_lifecycle.py" "zova.__version__ == \"${package_version}\""
expect_contains "$ROOT/bindings/python/rust/zova/Cargo.toml" "version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/rust/zova/Cargo.toml" "zova-sys = { version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/rust/zova-sys/Cargo.toml" "version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/rust/zova-sys/tests/abi.rs" "zova_abi_version_major(), ${abi_major}"
expect_contains "$ROOT/bindings/python/rust/zova-sys/tests/abi.rs" "zova_abi_version_minor(), ${abi_minor}"
expect_contains "$ROOT/bindings/python/rust/zova-sys/tests/abi.rs" "zova_abi_version_patch(), ${abi_patch}"
expect_contains "$ROOT/bindings/python/rust/zova-sys/tests/abi.rs" "\"${abi_version_string}\""

echo "version check ok: ${package_version}"
