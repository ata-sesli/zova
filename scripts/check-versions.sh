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

expect_not_contains() {
    file="$1"
    needle="$2"
    if grep -F "$needle" "$file" >/dev/null 2>&1; then
        fail "$file unexpectedly contains: $needle"
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
package_core="${package_version%%-*}"
expect_value "ABI numeric string" "$abi_major.$abi_minor.$abi_patch" "$package_core"

python_version="$package_version"
case "$package_version" in
    *-rc.*)
        python_version="${package_version%%-rc.*}rc${package_version##*-rc.}"
        ;;
esac

manifest_version="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n 1)"
manifest_min_zig="$(sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n 1)"
expect_value "build.zig.zon .version" "$package_version" "$manifest_version"
expect_value "build.zig.zon .minimum_zig_version" "$minimum_zig_version" "$manifest_min_zig"

[ -d "$ROOT/vendor/sqlite${sqlite_version}" ] || fail "missing vendor/sqlite${sqlite_version}"
# The published SQLite version must agree with src/version.zig everywhere a
# reader can observe it, so a bump cannot leave stale docs behind.
expect_contains "$ROOT/README.md" "| SQLite | vendored \`${sqlite_version}\` |"
expect_contains "$ROOT/README.md" "SQLite is vendored in \`vendor/sqlite${sqlite_version}\` and is public domain."
expect_contains "$ROOT/docs/storage-compatibility.md" "\`sqlite_version\` | \`${sqlite_version}\` |"
expect_contains "$ROOT/build.zig" 'src/version.zig'
expect_contains "$ROOT/src/database/types.zig" 'pub const format_version = version.format_version;'
expect_contains "$ROOT/src/zova.zig" 'const format_version = @import("database/types.zig").format_version;'
expect_contains "$ROOT/src/cli/maintenance.zig" 'zova.version.format_version'
expect_contains "$ROOT/src/cli/extensions.zig" 'zova.version.sqlite_version'
expect_contains "$ROOT/tests/cli.zig" 'zova.version.sqlite_version'
expect_contains "$ROOT/scripts/update-generated-c.sh" 'sqlite_version'
expect_contains "$ROOT/include/zova.h" "Zova C ABI, v${abi_version_string}."

expect_contains "$ROOT/README.md" "Current package version: \`${package_version}\`."
expect_contains "$ROOT/README.md" "format_version\` is \`${format_version}\`"
expect_contains "$ROOT/API_STABILITY.md" "\`${package_version}\` release"
expect_contains "$ROOT/.github/release-notes/v${package_version}.md" "Zova ${package_version}"
expect_contains "$ROOT/examples/zig_bridge/bridge.zig" ".zova_abi_min = \"${package_core}\""
expect_contains "$ROOT/README.md" "zova = \"${package_version}\""
expect_contains "$ROOT/README.md" "zova-sys = \"${package_version}\""
expect_contains "$ROOT/README.md" "bindings/go@v${package_version}"
expect_contains "$ROOT/README.md" "zova-v${package_version}-<platform>-c-abi"
expect_contains "$ROOT/README.md" "zova-v${package_version}-<platform>-cli"
expect_contains "$ROOT/README.md" "Zova \`${package_version}\` does not include:"
expect_contains "$ROOT/docs/extensions.md" "In v${package_version}, the bundled \`trgm\` extension"

# The 1.x storage compatibility contract must describe the formats this tree
# actually ships, so a format bump cannot leave the published promise stale.
expect_contains "$ROOT/docs/storage-compatibility.md" "minimum_migratable_format"
expect_contains "$ROOT/docs/storage-compatibility.md" "\`${format_version}\`"
expect_contains "$ROOT/README.md" "earliest migratable format is \`9\`"
expect_contains "$ROOT/scripts/package-release.sh" "scripts/package-release.sh ${package_version}"
expect_contains "$ROOT/scripts/build-release-artifacts.sh" "scripts/build-release-artifacts.sh ${package_version}"

expect_contains "$ROOT/bindings/rust/Cargo.toml" "version = \"${package_version}\""
expect_contains "$ROOT/bindings/rust/Cargo.toml" "repository = \"https://github.com/ata-sesli/zova\""
expect_contains "$ROOT/bindings/rust/zova/Cargo.toml" "zova-sys = { version = \"${package_version}\""
expect_contains "$ROOT/bindings/rust/zova-sys/tests/abi.rs" "zova_abi_version_major(), ${abi_major}"
expect_contains "$ROOT/bindings/rust/zova-sys/tests/abi.rs" "zova_abi_version_minor(), ${abi_minor}"
expect_contains "$ROOT/bindings/rust/zova-sys/tests/abi.rs" "zova_abi_version_patch(), ${abi_patch}"
expect_contains "$ROOT/bindings/rust/zova-sys/tests/abi.rs" "\"${abi_version_string}\""

expect_contains "$ROOT/bindings/go/README.md" "bindings/go/v${package_version}"
expect_contains "$ROOT/bindings/go/go.mod" "module github.com/ata-sesli/zova/bindings/go"
expect_contains "$ROOT/bindings/go/zova_test.go" "got != \"${abi_version_string}\""
expect_contains "$ROOT/bindings/go/zova_test.go" "major != ${abi_major} || minor != ${abi_minor} || patch != ${abi_patch}"

expect_contains "$ROOT/bindings/python/pyproject.toml" "version = \"${python_version}\""
expect_contains "$ROOT/bindings/python/pyproject.toml" "Repository = \"https://github.com/ata-sesli/zova\""
expect_contains "$ROOT/bindings/python/pyproject.toml" 'requires-python = ">=3.13"'
expect_contains "$ROOT/bindings/python/pyproject.toml" 'Programming Language :: Python :: 3.13'
expect_contains "$ROOT/bindings/python/pyproject.toml" 'Programming Language :: Python :: 3.14'
expect_not_contains "$ROOT/bindings/python/pyproject.toml" 'Programming Language :: Python :: 3.10'
expect_not_contains "$ROOT/bindings/python/pyproject.toml" 'Programming Language :: Python :: 3.11'
expect_not_contains "$ROOT/bindings/python/pyproject.toml" 'Programming Language :: Python :: 3.12'
expect_not_contains "$ROOT/bindings/python/pyproject.toml" 'format = "sdist"'
expect_contains "$ROOT/bindings/python/Cargo.toml" "version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/Cargo.toml" "zova\", version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/Cargo.toml" 'features = ["extension-module", "abi3-py313"]'
expect_contains "$ROOT/bindings/python/python/zova/__init__.py" "__version__ = \"${python_version}\""
expect_contains "$ROOT/bindings/python/tests/test_lifecycle.py" "zova.__version__ == \"${python_version}\""
expect_contains "$ROOT/bindings/python/rust/zova/Cargo.toml" "version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/rust/zova/Cargo.toml" "zova-sys = { version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/rust/zova-sys/Cargo.toml" "version = \"${package_version}\""
expect_contains "$ROOT/bindings/python/rust/zova-sys/tests/abi.rs" "zova_abi_version_major(), ${abi_major}"
expect_contains "$ROOT/bindings/python/rust/zova-sys/tests/abi.rs" "zova_abi_version_minor(), ${abi_minor}"
expect_contains "$ROOT/bindings/python/rust/zova-sys/tests/abi.rs" "zova_abi_version_patch(), ${abi_patch}"
expect_contains "$ROOT/bindings/python/rust/zova-sys/tests/abi.rs" "\"${abi_version_string}\""

expect_contains "$ROOT/bindings/javascript/Cargo.toml" "version = \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/Cargo.toml" "zova = { version = \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/Cargo.toml" "zova-sys = { version = \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/package.json" "\"version\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/package.json" "\"name\": \"zova-js\""
expect_contains "$ROOT/bindings/javascript/package.json" "\"url\": \"git+https://github.com/ata-sesli/zova.git\""
expect_contains "$ROOT/bindings/javascript/bun.lock" "\"name\": \"zova-js\""
expect_contains "$ROOT/bindings/javascript/package.json" "\"zova-db-darwin-arm64\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/package.json" "\"zova-db-darwin-x64\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/package.json" "\"zova-db-linux-arm64-gnu\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/package.json" "\"zova-db-linux-x64-gnu\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/package.json" "\"zova-db-windows-x64\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/bun.lock" "\"zova-db-darwin-arm64\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/bun.lock" "\"zova-db-darwin-x64\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/bun.lock" "\"zova-db-linux-arm64-gnu\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/bun.lock" "\"zova-db-linux-x64-gnu\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/bun.lock" "\"zova-db-windows-x64\": \"${package_version}\""
expect_contains "$ROOT/bindings/javascript/tests/load.test.ts" "expect(packageVersion).toBe(\"${package_version}\")"
expect_contains "$ROOT/bindings/javascript/tests/load.test.ts" "expect(abiVersion).toBe(\"${abi_version_string}\")"
expect_contains "$ROOT/bindings/javascript/tests/runtime-smoke.mjs" "assert.equal(packageVersion, \"${package_version}\")"
expect_contains "$ROOT/bindings/javascript/tests/runtime-smoke.mjs" "assert.equal(abiVersion, \"${abi_version_string}\")"
expect_contains "$ROOT/bindings/javascript/tests/runtime-smoke.cjs" "assert.equal(packageVersion, \"${package_version}\")"
expect_contains "$ROOT/bindings/javascript/tests/runtime-smoke.cjs" "assert.equal(abiVersion, \"${abi_version_string}\")"
expect_contains "$ROOT/.github/workflows/publish-release.yml" "id-token: write"
expect_contains "$ROOT/.github/workflows/publish-release.yml" "npm install --global npm@11"
expect_contains "$ROOT/.github/workflows/publish-release.yml" 'release_flags="--prerelease --latest=false"'
expect_contains "$ROOT/.github/workflows/publish-release.yml" 'npm_tag="next"'
expect_contains "$ROOT/.github/workflows/publish-release.yml" 'npm publish "$tarball" --access public --tag "$npm_tag"'
expect_contains "$ROOT/.github/workflows/release-artifacts.yml" 'python_version="${version%%-rc.*}rc${version##*-rc.}"'
expect_contains "$ROOT/.github/workflows/ci.yml" 'python-version: ["3.13", "3.14"]'
expect_not_contains "$ROOT/.github/workflows/release-artifacts.yml" 'python-sdist:'
expect_not_contains "$ROOT/.github/workflows/release-artifacts.yml" 'maturin build --sdist'
expect_contains "$ROOT/.github/workflows/release-artifacts.yml" 'manylinux: 2_28'
expect_contains "$ROOT/.github/workflows/release-artifacts.yml" 'maturin-version: v1.15.0'
expect_contains "$ROOT/.github/workflows/release-artifacts.yml" 'quay.io/pypa/manylinux_2_28_aarch64:latest'
expect_not_contains "$ROOT/.github/workflows/publish-release.yml" 'zova-${python_version}.tar.gz'
expect_contains "$ROOT/.github/workflows/publish-release.yml" 'expected_wheel_count=4'
expect_not_contains "$ROOT/scripts/check-release.sh" 'maturin build --sdist'
expect_not_contains "$ROOT/scripts/distribute-release.sh" 'maturin build --sdist'
expect_not_contains "$ROOT/scripts/distribute-release.sh" 'release_python_package'
expect_not_contains "$ROOT/scripts/verify-source-package.sh" 'maturin build --sdist'
expect_contains "$ROOT/scripts/verify-source-package.sh" 'PYTHON_DISTRIBUTION_VERSION="${VERSION%%-rc.*}rc${VERSION##*-rc.}"'
expect_contains "$ROOT/scripts/verify-source-package.sh" 'zova-$PYTHON_DISTRIBUTION_VERSION-cp313-abi3-*.whl'
expect_not_contains "$ROOT/.github/workflows/publish-release.yml" "NODE_AUTH_TOKEN"

expect_contains "$ROOT/bindings/wasm/package.json" "\"version\": \"${package_version}\""
expect_contains "$ROOT/bindings/wasm/package.json" '"name": "zova-wasm"'
expect_contains "$ROOT/bindings/wasm/bun.lock" '"name": "zova-wasm"'
expect_contains "$ROOT/.github/workflows/ci.yml" 'uses: ./.github/workflows/wasm.yml'
expect_contains "$ROOT/.github/workflows/release-artifacts.yml" 'uses: ./.github/workflows/wasm.yml'

echo "version check ok: ${package_version}"
