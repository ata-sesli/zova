#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

find src -type f -name '*.zig' \
    ! -name '*_tests.zig' \
    ! -name 'migration_red_tests.zig' \
    ! -name 'zova_test_support.zig' \
    ! -path 'src/c_api/types.zig' \
    ! -path 'src/database/types.zig' \
    ! -path 'src/extension_dynamic.zig' \
    -print0 |
    xargs -0 badbox check
