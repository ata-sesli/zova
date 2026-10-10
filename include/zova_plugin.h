#ifndef ZOVA_PLUGIN_H
#define ZOVA_PLUGIN_H

#include <stdint.h>

#if defined(_WIN32)
#define ZOVA_PLUGIN_CALL __cdecl
#define ZOVA_PLUGIN_EXPORT __declspec(dllexport)
#else
#define ZOVA_PLUGIN_CALL
#define ZOVA_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define ZOVA_PLUGIN_ABI_V1 UINT32_C(1)
#define ZOVA_PLUGIN_OK INT32_C(0)
#define ZOVA_PLUGIN_ERROR INT32_C(1)
#define ZOVA_PLUGIN_OUT_OF_MEMORY INT32_C(2)
#define ZOVA_PLUGIN_INVALID_ARGUMENT INT32_C(3)
#define ZOVA_PLUGIN_UNSUPPORTED INT32_C(4)
#define ZOVA_PLUGIN_LIMIT INT32_C(5)
#define ZOVA_PLUGIN_CANCELED INT32_C(6)
#define ZOVA_PLUGIN_HAS_UPGRADE_V1 UINT64_C(1)
#define ZOVA_PLUGIN_REQUIRES_QUERY_V1 UINT64_C(2)
#define ZOVA_PLUGIN_REQUIRES_DIAGNOSTICS_V1 UINT64_C(4)
#define ZOVA_PLUGIN_SERVICE_QUERY UINT32_C(1)
#define ZOVA_PLUGIN_SERVICE_DIAGNOSTICS UINT32_C(2)
#define ZOVA_PLUGIN_REQUIRES_DATA_V1 UINT64_C(8)
#define ZOVA_PLUGIN_REQUIRES_STORAGE_V1 UINT64_C(16)
#define ZOVA_PLUGIN_SERVICE_DATA UINT32_C(3)
#define ZOVA_PLUGIN_SERVICE_STORAGE UINT32_C(4)

/* Independent of the database format and Zova's application C ABI.
 * All calls use the platform C calling convention; C++ exceptions must not
 * cross this boundary. No structure packing overrides are permitted.
 * The host and connection handles are borrowed only for the current hook.
 * Never retain them or call them from another thread. The host copies SQL;
 * input bytes need remain valid only until exec_sql returns. No allocations
 * cross the boundary. Plugins free their own allocations before returning.
 * Hooks must not issue transaction/savepoint commands or reenter Zova APIs.
 * Nonzero hook results fail the operation; unknown statuses are generic errors.
 * Translate recoverable Zig errors into statuses. Rust panics and C++ exceptions
 * must not unwind across C. A Zig panic, native crash or process abort is not
 * recoverable by the host and cannot be made transaction-safe by this ABI.
 */
typedef struct zova_plugin_host_v1 {
    uint32_t struct_size;
    uint32_t abi_version;
    int32_t (ZOVA_PLUGIN_CALL *exec_sql)(void *connection, const char *sql, uint64_t sql_len);
} zova_plugin_host_v1;

/* Append-only host prefix: check base.struct_size before accessing get_service.
 * Required services must also be declared in descriptor.flags so older hosts
 * reject the plugin before any hook. Optional services may be probed at runtime.
 * get_service clears *out_service on error; unsupported IDs, versions or minimum
 * sizes return UNSUPPORTED. Service tables are immutable and host-owned. The
 * connection is opaque, never a public SQLite handle. Use services only during
 * the current hook, on its thread; row callbacks must not reenter host services.
 */
typedef struct zova_plugin_service_host_v1 {
    zova_plugin_host_v1 base;
    int32_t (ZOVA_PLUGIN_CALL *get_service)(void *connection, uint32_t service_id,
        uint32_t service_version, uint32_t min_struct_size, const void **out_service);
} zova_plugin_service_host_v1;

#define ZOVA_PLUGIN_VALUE_NULL UINT32_C(0)
#define ZOVA_PLUGIN_VALUE_INTEGER UINT32_C(1)
#define ZOVA_PLUGIN_VALUE_FLOAT UINT32_C(2)
#define ZOVA_PLUGIN_VALUE_TEXT UINT32_C(3)
#define ZOVA_PLUGIN_VALUE_BLOB UINT32_C(4)
typedef struct zova_plugin_value_v1 {
    uint32_t kind;
    uint32_t reserved; /* Must be zero. Initialize all unused fields to zero. */
    int64_t integer;
    double real;
    const uint8_t *bytes;
    uint64_t bytes_len;
} zova_plugin_value_v1;

typedef int32_t (ZOVA_PLUGIN_CALL *zova_plugin_row_v1)(void *user_data,
    const zova_plugin_value_v1 *values, uint64_t value_count);

/* One read-only SELECT/WITH statement; no PRAGMAs or transaction/attachment
 * commands. Exact parameter count, at most 256 parameters, 128 result columns,
 * 4096 rows and 1 MiB SQL/input/result bytes. row_limit and byte_limit must be
 * nonzero and within those maxima. byte_limit counts Value records plus text/
 * blob bytes cumulatively. A row exceeding either budget is not delivered.
 * Inputs stay valid/unchanged until query returns. Text is UTF-8 and may contain
 * NUL; SQL cannot. Empty text/blob can have NULL bytes and zero bytes_len.
 * Result values and bytes are borrowed only during each row callback. Copy what
 * must survive it. Return OK, OUT_OF_MEMORY or CANCELED; other callback statuses
 * become INVALID_ARGUMENT. row and user_data are plugin-owned and borrowed only
 * until query returns; callbacks never run after that return. There is no state
 * ownership transfer or destroy callback: the plugin releases its callback state
 * on every return path, including failures. The library must stay loaded through
 * the call. Hook-local state must not be confused with future persistent state.
 * Failure can follow already delivered rows: plugins
 * must discard partial results. All statements are finalized before return.
 * This bounds delivery, not SQL CPU time or SQLite's internal working memory.
 * Query functions must not perform side effects. Native plugins remain trusted,
 * not sandboxed. No result allocation/free or CRT ownership crosses this ABI.
 */
typedef struct zova_plugin_query_request_v1 {
    uint32_t struct_size;
    uint32_t flags; /* Zero. Unknown flags are rejected. */
    const char *sql;
    uint64_t sql_len;
    const zova_plugin_value_v1 *parameters;
    uint64_t parameter_count;
    uint64_t row_limit;
    uint64_t byte_limit;
    zova_plugin_row_v1 row;
    void *user_data;
} zova_plugin_query_request_v1;

typedef struct zova_plugin_query_service_v1 {
    uint32_t struct_size;
    uint32_t version;
    int32_t (ZOVA_PLUGIN_CALL *query)(void *connection,
        const zova_plugin_query_request_v1 *request);
} zova_plugin_query_service_v1;

/* Copy SQLite's current connection diagnostic, not a retained error object.
 * Capacity is at most 1024 bytes. No NUL terminator is added. *written is zeroed
 * before validation. Truncation returns LIMIT with the copied length. A NULL
 * buffer is valid only for zero capacity. Diagnostics may change after another
 * host call; validation/limit/cancellation errors need not set SQLite's message.
 */
typedef struct zova_plugin_diagnostics_service_v1 {
    uint32_t struct_size;
    uint32_t version;
    int32_t (ZOVA_PLUGIN_CALL *copy_sqlite_error)(void *connection,
        uint8_t *buffer, uint64_t capacity, uint64_t *written);
} zova_plugin_diagnostics_service_v1;

typedef struct zova_plugin_bytes_v1 {
    const uint8_t *data;
    uint64_t len;
} zova_plugin_bytes_v1;
typedef struct zova_plugin_cursor_v1 {
    int64_t created_order;
    int64_t key;
} zova_plugin_cursor_v1;
typedef struct zova_plugin_data_page_v1 {
    uint64_t rows;
    uint32_t has_more;
    uint32_t reserved;
    zova_plugin_cursor_v1 next;
} zova_plugin_data_page_v1;

#define ZOVA_PLUGIN_GRAPH_NODES_SCAN UINT32_C(1)
#define ZOVA_PLUGIN_GRAPH_EDGES_SCAN UINT32_C(2)
#define ZOVA_PLUGIN_GRAPH_NODES_GET UINT32_C(3)
#define ZOVA_PLUGIN_GRAPH_EDGES_GET UINT32_C(4)
#define ZOVA_PLUGIN_GRAPH_NEIGHBORS UINT32_C(5)
#define ZOVA_PLUGIN_VECTOR_METADATA UINT32_C(6)
#define ZOVA_PLUGIN_VECTORS_SCAN UINT32_C(7)
#define ZOVA_PLUGIN_VECTORS_GET UINT32_C(8)
#define ZOVA_PLUGIN_OUTGOING UINT32_C(0)
#define ZOVA_PLUGIN_INCOMING UINT32_C(1)

/* All inputs and the callback borrow only until read returns; Value row bytes
 * borrow only during the callback. No allocations or cursors cross the ABI.
 * 1..4096 row_limit, 1..1 MiB byte_limit (Value records plus variable bytes).
 * Input names/vector IDs are UTF-8, at most 255 bytes each; graph node IDs
 * at most 512 bytes. Aggregate vector IDs <=1 MiB. Vector IDs may contain NUL.
 * Keys are positive opaque i64s. Batches <=row_limit preserve input ordinals,
 * duplicates, and misses (found=0, unavailable fields=NULL), including keys
 * from another graph. Missing graph/collection/node is ERROR, not an empty
 * source. Empty batches still validate the source. Zero all unused fields.
 *
 * Row layouts (INTEGER unless noted):
 * NODES_SCAN: node_key, node_id(TEXT), kind(TEXT), created_order.
 * EDGES_SCAN: edge_key, source_node_key, edge_type(TEXT), target_node_key, order.
 * NODES_GET: ordinal, found, input_key, node_id(TEXT), kind(TEXT), order.
 * EDGES_GET: ordinal, found, input_key, source_key, edge_type(TEXT), target_key, order.
 * NEIGHBORS: edge_key, neighbor_key, node_id(TEXT), kind(TEXT), edge_type(TEXT), order.
 * VECTOR_METADATA: dimensions, element_type(TEXT: f32/f16/i8), metric(TEXT:
 * cosine/l2/dot), vector_count. No private vector key is exposed.
 * VECTORS_SCAN: vector_id(TEXT), values(BLOB).
 * VECTORS_GET: ordinal, found, input_id(TEXT), values(BLOB or NULL).
 * Vector bytes are exact little-endian IEEE754 f32/f16 or raw signed i8, not
 * quantized or widened. Use collection metadata to decode; BLOB pointers need
 * not be aligned. Consumers account for their own conversion/work memory.
 *
 * Graph scans/adjacency use exclusive (order,key) cursors: (0,0) starts; otherwise
 * both fields must be positive. next advances only on complete success.
 * Adjacency requires node_id, direction and optional edge_type (empty=all).
 * Ordering matches existing APIs. Vectors scan by BINARY public ID; copy the
 * last delivered ID and pass it as after_id. has_more uses one lookahead row.
 * Output is zeroed on every error. Discard any already delivered partial rows.
 * Return CANCELED from a callback to stop; statements/temporary memory finalize
 * on all paths. Row/byte bounds do not sandbox plugin CPU or SQLite work.
 *
 * All source reads in one hook share the hook's transaction/savepoint snapshot,
 * including bound stores and caller-visible earlier writes. Never interleave
 * source mutation/reenter services from callbacks. This does not promise a
 * simultaneous cross-file WAL snapshot or durable source incarnation tokens;
 * persistent freshness/change tracking is a separate service contract.
 */
typedef struct zova_plugin_data_request_v1 {
    uint32_t struct_size;
    uint32_t operation;
    zova_plugin_bytes_v1 name;
    const int64_t *keys;
    uint64_t key_count;
    const zova_plugin_bytes_v1 *ids;
    uint64_t id_count;
    zova_plugin_cursor_v1 after;
    zova_plugin_bytes_v1 after_id;
    zova_plugin_bytes_v1 node_id;
    zova_plugin_bytes_v1 edge_type;
    uint32_t direction;
    uint32_t reserved;
    uint64_t row_limit;
    uint64_t byte_limit;
    zova_plugin_row_v1 row;
    void *user_data;
} zova_plugin_data_request_v1;
typedef struct zova_plugin_data_service_v1 {
    uint32_t struct_size;
    uint32_t version;
    int32_t (ZOVA_PLUGIN_CALL *read)(void *connection,
        const zova_plugin_data_request_v1 *request, zova_plugin_data_page_v1 *out_page);
} zova_plugin_data_service_v1;

/* Parameterized SELECT/WITH/INSERT/UPDATE/DELETE on the calling plugin's main
 * private tables only. QueryRequest budgets/lifetimes apply, including a row
 * callback for commands without results. Supports RETURNING. Each call owns an
 * internal savepoint; errors (including callback cancellation/limits) undo the
 * whole statement, preserving earlier hook/caller work. The hook scope rolls
 * back on hook failure and remains provisional inside a caller transaction.
 * Read-only connections can read but mutations fail normally.
 * Tables/indexes must be declared by the existing install/upgrade lifecycle.
 * Qualify tables as main.<private_name>, particularly for count(*)/EXISTS where
 * SQLite otherwise supplies no resolved schema to the authorizer.
 * No DDL, transaction commands, PRAGMAs, attachments, triggers/views, core or
 * another plugin's tables. Only documented built-in pure SQL functions are
 * permitted; no user-defined functions. Native code remains trusted, not
 * sandboxed. Old exec_sql/query behavior is unchanged.
 */
typedef struct zova_plugin_storage_service_v1 {
    uint32_t struct_size;
    uint32_t version;
    int32_t (ZOVA_PLUGIN_CALL *execute)(void *connection,
        const zova_plugin_query_request_v1 *request);
} zova_plugin_storage_service_v1;

typedef int32_t (ZOVA_PLUGIN_CALL *zova_plugin_hook_v1)(
    const zova_plugin_host_v1 *host, void *connection);

/* Return a static, immutable descriptor and NUL-terminated strings, valid until
 * library unload. No ownership transfers. Query must be side-effect-free;
 * return NULL for an unsupported host ABI. Host checks size/version/flags and
 * identity before calling hooks. All hook pointers are optional (NULL=no-op).
 * capabilities may be NULL (empty); other strings are required. flags must be
 * a combination of HAS_UPGRADE_V1, REQUIRES_QUERY_V1 and
 * REQUIRES_DIAGNOSTICS_V1, REQUIRES_DATA_V1 and REQUIRES_STORAGE_V1; unknown bits
 * fail negotiation. struct_size must be at
 * least sizeof(zova_plugin_descriptor_v1); hosts
 * ignore trailing fields. A new incompatible layout uses a new ABI/entrypoint.
 */
typedef struct zova_plugin_descriptor_v1 {
    uint32_t struct_size;
    uint32_t abi_version;
    uint64_t flags;
    const char *name;
    const char *version;
    const char *storage_prefix;
    const char *zova_abi_min;
    const char *capabilities;
    zova_plugin_hook_v1 install;
    zova_plugin_hook_v1 check;
    zova_plugin_hook_v1 drop;
    zova_plugin_hook_v1 register_sql;
} zova_plugin_descriptor_v1;

/* Optional, explicitly flagged tail. Return &descriptor.base from the same
 * v1 entrypoint. Set base.struct_size to sizeof(this structure) and base.flags
 * to ZOVA_PLUGIN_HAS_UPGRADE_V1 plus any required-service flags. Older hosts
 * reject unsupported flags, not reinterpret them.
 * from_version and base.version declare one exact forward major.minor.patch
 * path. The host rejects equal versions/downgrades. upgrade is required here;
 * use a no-op hook for a code-only update. It changes data, never extension
 * metadata or transaction boundaries. The host checks the target before
 * atomically updating metadata. Normal opens never invoke this hook.
 */
typedef struct zova_plugin_upgrade_descriptor_v1 {
    zova_plugin_descriptor_v1 base;
    const char *from_version;
    zova_plugin_hook_v1 upgrade;
} zova_plugin_upgrade_descriptor_v1;

ZOVA_PLUGIN_EXPORT const zova_plugin_descriptor_v1 *ZOVA_PLUGIN_CALL
zova_plugin_entry_v1(uint32_t host_abi_version);

#ifdef __cplusplus
}
#endif
#endif
