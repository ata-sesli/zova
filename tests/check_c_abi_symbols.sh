#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: tests/check_c_abi_symbols.sh <libzova.a>" >&2
    exit 2
fi

ARCHIVE="$1"
TMP="${TMPDIR:-/tmp}/zova-symbols.$$"

cleanup() {
    rm -f "$TMP"
}
trap cleanup EXIT INT TERM

nm -g "$ARCHIVE" >"$TMP"

require_symbol() {
    if ! grep -Eq "[[:space:]]_?$1$" "$TMP"; then
        echo "missing required C ABI symbol: $1" >&2
        exit 1
    fi
}

require_symbol zova_database_create
require_symbol zova_database_create_memory
require_symbol zova_database_create_with_extensions
require_symbol zova_database_open
require_symbol zova_database_open_with_extensions
require_symbol zova_database_close
require_symbol zova_extension_bundle_verify
require_symbol zova_extension_bundle_trust
require_symbol zova_extension_bundle_untrust
require_symbol zova_database_register_function
require_symbol zova_object_put
require_symbol zova_object_get
require_symbol zova_object_read_range
require_symbol zova_object_manifest_get
require_symbol zova_object_chunk_get
require_symbol zova_object_chunk_put
require_symbol zova_object_assemble_from_chunks
require_symbol zova_object_writer_create
require_symbol zova_object_writer_finish
require_symbol zova_graph_create
require_symbol zova_graph_node_put
require_symbol zova_graph_edge_put
require_symbol zova_graph_neighbors
require_symbol zova_graph_walk
require_symbol zova_graph_walk_direction
require_symbol zova_graph_walk_direction_profiled
require_symbol zova_database_extension_install
require_symbol zova_database_extension_list
require_symbol zova_database_extension_info
require_symbol zova_database_extension_check
require_symbol zova_database_extension_check_all
require_symbol zova_database_extension_drop
require_symbol zova_database_restore_to_memory
require_symbol zova_status_name

if grep -E '(^|[[:space:]])_?(Zova|zova)[A-Za-z0-9_]*$' "$TMP" | grep -Ev '(^|[[:space:]])_?zova_' >/dev/null; then
    echo "found exported Zova-looking symbol without zova_ prefix" >&2
    grep -E '(^|[[:space:]])_?(Zova|zova)[A-Za-z0-9_]*$' "$TMP" | grep -Ev '(^|[[:space:]])_?zova_' >&2
    exit 1
fi
