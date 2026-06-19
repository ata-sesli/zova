#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

zig fmt --check build.zig build.zig.zon src/root.zig src/sqlite.zig src/zova.zig src/main.zig
zig build test
zig build test -Doptimize=ReleaseSafe
zig build
zig build run
