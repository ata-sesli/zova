#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "${ZOVA_INCLUDE_DIR+x}" ]; then
  export CGO_CFLAGS="${CGO_CFLAGS:-} -I$ZOVA_INCLUDE_DIR"
fi

if [ "${ZOVA_LIB_DIR+x}" ]; then
  export CGO_LDFLAGS="${CGO_LDFLAGS:-} -L$ZOVA_LIB_DIR -lzova_c"
fi

cd "$script_dir"
go test ./...
