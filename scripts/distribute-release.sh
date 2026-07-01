#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
    cat >&2 <<'EOF'
usage: scripts/distribute-release.sh <version> [--dry-run] [--yes]
example: scripts/distribute-release.sh 0.19.0

Publishes distribution channels in this order:
  1. Rust crates: zova-sys, then zova
  2. Python package artifacts to PyPI

Options:
  --dry-run  run publish dry-runs where supported and do not push/upload
  --yes      skip the interactive confirmation for real publishing
EOF
}

run() {
    echo "+ $*"
    "$@"
}

die() {
    echo "$*" >&2
    exit 1
}

usage_error() {
    echo "$*" >&2
    usage
    exit 2
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "missing required command: $1"
    fi
}

manifest_version() {
    sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon" | head -n 1
}

rust_workspace_version() {
    sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/bindings/rust/Cargo.toml" | head -n 1
}

python_project_version() {
    sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/bindings/python/pyproject.toml" | head -n 1
}

crate_published() {
    crate="$1"
    cargo info "$crate@$VERSION" >/dev/null 2>&1
}

wait_for_crate() {
    crate="$1"

    if [ "$DRY_RUN" -eq 1 ]; then
        return
    fi

    attempt=1
    while [ "$attempt" -le 20 ]; do
        if crate_published "$crate"; then
            return
        fi
        echo "crates.io has not indexed $crate $VERSION yet; retrying in 15s ($attempt/20)" >&2
        attempt=$((attempt + 1))
        sleep 15
    done

    die "timed out waiting for crates.io to index $crate $VERSION"
}

publish_crate() {
    crate="$1"

    if [ "$DRY_RUN" -eq 1 ]; then
        run cargo publish --allow-dirty --dry-run -p "$crate" --manifest-path bindings/rust/Cargo.toml
        return
    fi

    if crate_published "$crate"; then
        echo "crate already published: $crate $VERSION"
        return
    fi

    run cargo publish --allow-dirty -p "$crate" --manifest-path bindings/rust/Cargo.toml
}

release_rust_crates() {
    run sh bindings/rust/zova-sys/tools/sync-native-source.sh
    run sh bindings/rust/zova-sys/tools/check-native-source.sh

    publish_crate zova-sys
    wait_for_crate zova-sys
    publish_crate zova
    wait_for_crate zova
}

release_python_package() {
    wheel_dir="$TMP/python-dist"
    mkdir -p "$wheel_dir"

    run uv run --isolated --with maturin --directory bindings/python maturin build --sdist --out "$wheel_dir"

    if ! find "$wheel_dir" -name "zova-$VERSION-*.whl" | grep -q .; then
        die "Python release artifacts are missing a wheel"
    fi
    if [ ! -f "$wheel_dir/zova-$VERSION.tar.gz" ]; then
        die "Python release artifacts are missing an sdist"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        run uv publish --dry-run --check-url https://pypi.org/simple/ "$wheel_dir"/zova-"$VERSION"*
    else
        run uv publish --check-url https://pypi.org/simple/ "$wheel_dir"/zova-"$VERSION"*
    fi
}

VERSION=""
DRY_RUN=0
YES=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --yes)
            YES=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            usage_error "unknown option: $1"
            ;;
        *)
            if [ -n "$VERSION" ]; then
                usage_error "unexpected extra argument: $1"
            fi
            VERSION="${1#v}"
            ;;
    esac
    shift
done

if [ -z "$VERSION" ]; then
    usage_error "missing version"
fi

if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    usage_error "invalid version: $VERSION"
fi

MANIFEST_VERSION="$(manifest_version)"
RUST_VERSION="$(rust_workspace_version)"
PYTHON_VERSION="$(python_project_version)"

if [ "$VERSION" != "$MANIFEST_VERSION" ]; then
    die "version argument ($VERSION) does not match build.zig.zon ($MANIFEST_VERSION)"
fi
if [ "$VERSION" != "$RUST_VERSION" ]; then
    die "version argument ($VERSION) does not match bindings/rust/Cargo.toml ($RUST_VERSION)"
fi
if [ "$VERSION" != "$PYTHON_VERSION" ]; then
    die "version argument ($VERSION) does not match bindings/python/pyproject.toml ($PYTHON_VERSION)"
fi

require_command git
require_command cargo
require_command uv

if [ "$DRY_RUN" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
    echo "working tree is not clean; commit or stash changes before publishing distributions" >&2
    git status --short >&2
    exit 1
fi

TMP="${TMPDIR:-/tmp}/zova-distribute-release.$$"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM
mkdir -p "$TMP"

if [ "$DRY_RUN" -eq 0 ] && [ "$YES" -eq 0 ]; then
    echo "This will publish Zova $VERSION to crates.io and PyPI."
    echo "Type 'release $VERSION' to continue:"
    read answer
    if [ "$answer" != "release $VERSION" ]; then
        echo "aborted" >&2
        exit 2
    fi
fi

echo "==> Rust crates"
release_rust_crates

echo "==> Python package"
release_python_package

echo "distributed Zova $VERSION"
