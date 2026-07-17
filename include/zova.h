#ifndef ZOVA_H
#define ZOVA_H

#include <stddef.h>
#include <stdint.h>

/*
 * Zova C ABI, v0.24.0 pre-1.0.
 *
 * This header exposes a C-compatible object and vector API over Zova's Zig
 * implementation. The ABI is intentionally conservative: opaque handles,
 * request structs, fixed-size ids, explicit status codes, and caller-visible
 * ownership rules.
 *
 * Threading:
 * - A single zova_database handle may be called from multiple threads. Calls
 *   on the same handle are internally serialized and execute one at a time.
 * - Statements, object writers, and notification subscriptions are child
 *   handles of their parent database; their calls use the same parent
 *   serialization boundary.
 * - zova_database_close fails with ZOVA_MISUSE while live statements, object
 *   writers, or subscriptions still exist. Finalize/destroy/close child
 *   handles before closing.
 * - After a successful close, statement finalize, or writer destroy, that C
 *   pointer is invalid and must not be used again. Coordinate these terminal
 *   calls so no other thread can still call through the same pointer.
 * - Multiple database handles may point at the same file for true concurrency;
 *   cross-handle locking follows normal SQLite behavior.
 * - Serialization is not callback reentrancy. Do not call back into the same
 *   handle from code that is already executing inside a Zova/SQLite callback.
 *
 * Strings and bytes:
 * - Paths and SQL are null-terminated C strings.
 * - Arbitrary object/chunk bytes and vector values use pointer + length.
 * - Vector input/output floats are expected to be IEEE-754 single precision.
 * - A null pointer with a non-zero length is invalid.
 *
 * Ownership:
 * - Buffers/messages/manifests/vectors/search results returned by Zova are
 *   library-owned and must be released with the matching zova_*_free function.
 * - Input pointers are borrowed only for the duration of the call.
 * - zova_database_last_error_message returns a borrowed pointer scoped to the
 *   database handle; it is valid until the next call on that handle or close.
 *   Another thread's next serialized call on the same handle may replace it, so
 *   bindings should copy diagnostics immediately.
 *
 * Scope:
 * - This ABI exposes database lifecycle, SQL exec, prepared statements,
 *   explicit transactions, explicit vacuum, conversion, backup, compact copy,
 *   restore-to-new-file, objects, chunks, manifests, range reads, assembly,
 *   ObjectWriter, native vectors, and native graph relationships.
 * - Vector metadata remains application-owned in user SQL tables. Vector search
 *   returns vector ids and distances only.
 * - zova_database connections register read-only SQL vector helpers:
 *   zova_vector_distance, zova_vector_distance_by_id, and zova_vector_search.
 *   Query vector blobs for f32 collections are little-endian IEEE-754 f32
 *   arrays. Typed collections use blobs matching their collection element type:
 *   f16 blobs are little-endian uint16 bit patterns and i8 blobs are raw signed
 *   bytes.
 * - zova_database connections register read-only SQL graph virtual tables:
 *   zova_graph_neighbors and zova_graph_walk. These are connection-local
 *   helpers for joining returned graph node ids back to application SQL rows.
 * - Zova does not automatically run VACUUM or change SQLite PRAGMAs.
 * - App notifications are same-process, in-memory, local to one database
 *   handle, non-persistent, and delivered only to subscription queues. They
 *   are transaction-aware when callers use Zova transaction/savepoint helpers;
 *   raw SQL transaction scopes that Zova cannot track are rejected for
 *   zova_notify().
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handles. Callers must only pass them back to Zova functions. */
typedef struct zova_database zova_database;
typedef struct zova_object_writer zova_object_writer;
typedef struct zova_statement zova_statement;
typedef struct zova_subscription zova_subscription;

/* Stable status values for the pre-1.0 ABI surface. */
typedef enum zova_status {
    ZOVA_OK = 0,
    ZOVA_INVALID_ARGUMENT = 1,
    ZOVA_OUT_OF_MEMORY = 2,
    ZOVA_BUSY = 10,
    ZOVA_LOCKED = 11,
    ZOVA_CONSTRAINT = 12,
    ZOVA_CANT_OPEN = 13,
    ZOVA_READ_ONLY = 14,
    ZOVA_CORRUPT = 15,
    ZOVA_MISUSE = 16,
    ZOVA_SQLITE_ERROR = 17,
    ZOVA_NOT_ZOVA_PATH = 30,
    ZOVA_NOT_ZOVA_DATABASE = 31,
    ZOVA_UNSUPPORTED_ZOVA_VERSION = 32,
    ZOVA_DESTINATION_EXISTS = 33,
    ZOVA_ZOVA_NAME_CONFLICT = 34,
    ZOVA_OBJECT_NOT_FOUND = 50,
    ZOVA_OBJECT_ALREADY_EXISTS = 51,
    ZOVA_OBJECT_CHUNK_NOT_FOUND = 52,
    ZOVA_OBJECT_CHUNK_HASH_MISMATCH = 53,
    ZOVA_OBJECT_CORRUPT = 54,
    ZOVA_OBJECT_MANIFEST_INVALID = 55,
    ZOVA_OBJECT_RANGE_INVALID = 56,
    ZOVA_OBJECT_TOO_LARGE = 57,
    ZOVA_OBJECT_TRANSACTION_ACTIVE = 58,
    ZOVA_OBJECT_WRITER_CLOSED = 59,
    ZOVA_BOUND_STORE_EXISTS = 60,
    ZOVA_BOUND_STORE_NOT_FOUND = 61,
    ZOVA_BOUND_STORE_INVALID = 62,
    ZOVA_VECTOR_COLLECTION_EXISTS = 70,
    ZOVA_VECTOR_COLLECTION_NOT_FOUND = 71,
    ZOVA_VECTOR_NOT_FOUND = 72,
    ZOVA_VECTOR_DIMENSION_MISMATCH = 73,
    ZOVA_VECTOR_CORRUPT = 74,
    ZOVA_VECTOR_INVALID = 75,
    ZOVA_GRAPH_EXISTS = 80,
    ZOVA_GRAPH_NOT_FOUND = 81,
    ZOVA_GRAPH_NODE_NOT_FOUND = 82,
    ZOVA_GRAPH_EDGE_NOT_FOUND = 83,
    ZOVA_GRAPH_INVALID = 84,
    ZOVA_EXTENSION_NOT_FOUND = 90,
    ZOVA_EXTENSION_EXISTS = 91,
    ZOVA_EXTENSION_INVALID = 92,
    ZOVA_EXTENSION_INCOMPATIBLE = 93,
    ZOVA_EXTENSION_UNAVAILABLE = 94,
} zova_status;

typedef enum zova_vector_metric {
    ZOVA_VECTOR_METRIC_COSINE = 0,
    ZOVA_VECTOR_METRIC_L2 = 1,
    ZOVA_VECTOR_METRIC_DOT = 2,
} zova_vector_metric;

typedef enum zova_vector_element_type {
    ZOVA_VECTOR_ELEMENT_TYPE_F32 = 0,
    ZOVA_VECTOR_ELEMENT_TYPE_F16 = 1,
    ZOVA_VECTOR_ELEMENT_TYPE_I8 = 2,
} zova_vector_element_type;

typedef enum zova_vector_multi_i8_search_mode {
    ZOVA_VECTOR_MULTI_I8_SEARCH_GLOBAL_MIN_COSINE = 0,
    ZOVA_VECTOR_MULTI_I8_SEARCH_CBM_PREFILTER_MIN_COSINE = 1,
} zova_vector_multi_i8_search_mode;

typedef enum zova_vector_multi_i8_aggregation {
    ZOVA_VECTOR_MULTI_I8_AGGREGATION_MIN_COSINE = 0,
} zova_vector_multi_i8_aggregation;

typedef enum zova_graph_target_type {
    ZOVA_GRAPH_TARGET_NONE = 0,
    ZOVA_GRAPH_TARGET_RECORD = 1,
    ZOVA_GRAPH_TARGET_OBJECT = 2,
    ZOVA_GRAPH_TARGET_OBJECT_CHUNK = 3,
    ZOVA_GRAPH_TARGET_VECTOR = 4,
    ZOVA_GRAPH_TARGET_ENTITY = 5,
    ZOVA_GRAPH_TARGET_FACT = 6,
    ZOVA_GRAPH_TARGET_CONCEPT = 7,
    ZOVA_GRAPH_TARGET_EXTERNAL = 8,
} zova_graph_target_type;

typedef enum zova_graph_neighbor_direction {
    ZOVA_GRAPH_NEIGHBOR_OUTGOING = 0,
    ZOVA_GRAPH_NEIGHBOR_INCOMING = 1,
} zova_graph_neighbor_direction;

typedef enum zova_step_result {
    ZOVA_STEP_ROW = 1,
    ZOVA_STEP_DONE = 2,
} zova_step_result;

typedef enum zova_column_type {
    ZOVA_COLUMN_INTEGER = 1,
    ZOVA_COLUMN_FLOAT = 2,
    ZOVA_COLUMN_TEXT = 3,
    ZOVA_COLUMN_BLOB = 4,
    ZOVA_COLUMN_NULL = 5,
} zova_column_type;

typedef enum zova_sql_value_type {
    ZOVA_SQL_VALUE_NULL = 0,
    ZOVA_SQL_VALUE_INTEGER = 1,
    ZOVA_SQL_VALUE_FLOAT = 2,
    ZOVA_SQL_VALUE_TEXT = 3,
    ZOVA_SQL_VALUE_BLOB = 4,
} zova_sql_value_type;

typedef enum zova_sql_result_type {
    ZOVA_SQL_RESULT_NULL = 0,
    ZOVA_SQL_RESULT_INTEGER = 1,
    ZOVA_SQL_RESULT_FLOAT = 2,
    ZOVA_SQL_RESULT_TEXT = 3,
    ZOVA_SQL_RESULT_BLOB = 4,
    ZOVA_SQL_RESULT_ERROR = 5,
} zova_sql_result_type;

enum {
    ZOVA_SQL_FUNCTION_DETERMINISTIC = 1u << 0,
    ZOVA_SQL_FUNCTION_DIRECT_ONLY = 1u << 1,
    ZOVA_SQL_FUNCTION_INNOCUOUS = 1u << 2
};

/* Borrowed SQLite argument value, valid only during the callback. */
typedef struct zova_sql_value {
    zova_sql_value_type value_type;
    int64_t int64_value;
    double double_value;
    const void *data;
    size_t data_len;
} zova_sql_value;

/*
 * Callback result. Zova copies text/blob/error bytes before the callback result
 * is applied. `result_type` is an int so invalid foreign values can be reported
 * as SQLite callback errors.
 */
typedef struct zova_sql_result {
    int result_type;
    int64_t int64_value;
    double double_value;
    const void *data;
    size_t data_len;
    const char *error_message;
    size_t error_message_len;
} zova_sql_result;

typedef struct zova_sql_function_call {
    void *user_data;
    size_t argc;
    const zova_sql_value *argv;
} zova_sql_function_call;

typedef void (*zova_sql_scalar_callback)(void *user_data, const zova_sql_function_call *call, zova_sql_result *out_result);
typedef void (*zova_sql_destroy_callback)(void *user_data);

/* SHA-256 identity of full object bytes. */
typedef struct zova_object_id {
    uint8_t bytes[32];
} zova_object_id;

/* SHA-256 identity of one stored object chunk. */
typedef struct zova_object_chunk_id {
    uint8_t bytes[32];
} zova_object_chunk_id;

/* Owned byte buffer returned by Zova. Free with zova_buffer_free. */
typedef struct zova_buffer {
    uint8_t *data;
    size_t len;
} zova_buffer;

/* Owned message returned by no-handle operations. Free with zova_message_free. */
typedef struct zova_message {
    char *data;
    size_t len;
} zova_message;

/* Owned text returned by Zova. Free with zova_text_free. */
typedef struct zova_text {
    char *data;
    size_t len;
} zova_text;

/* Owned app notification returned by Zova. Free with zova_notification_free. */
typedef struct zova_notification {
    char *channel;
    size_t channel_len;
    char *payload;
    size_t payload_len;
    uint64_t sequence;
    uint64_t dropped_before;
} zova_notification;

/* One flat manifest row. Chunks are ordered by index. */
typedef struct zova_object_manifest_chunk {
    uint64_t index;
    zova_object_chunk_id hash;
    uint64_t offset;
    uint64_t size_bytes;
} zova_object_manifest_chunk;

/* Owned flat object manifest. Free with zova_object_manifest_free. */
typedef struct zova_object_manifest {
    zova_object_id object_id;
    uint64_t size_bytes;
    uint64_t chunk_count;
    const char *chunker;
    zova_object_manifest_chunk *chunks;
    size_t chunks_len;
} zova_object_manifest;

typedef struct zova_vector_collection_options {
    uint32_t dimensions;
    /*
     * Raw C int for ABI layout stability. Use ZOVA_VECTOR_METRIC_* constants.
     * This avoids enum-size differences from compiler options such as
     * -fshort-enums while still keeping named metric values.
     */
    int metric;
    int element_type;
} zova_vector_collection_options;

typedef struct zova_vector_values {
    int element_type;
    const float *f32_values;
    const uint16_t *f16_values;
    const int8_t *i8_values;
    size_t values_len;
} zova_vector_values;

/* Owned vector returned by Zova. Free with zova_vector_free. */
typedef struct zova_vector {
    char *id;
    size_t id_len;
    int element_type;
    float *f32_values;
    uint16_t *f16_values;
    int8_t *i8_values;
    size_t values_len;
} zova_vector;

typedef struct zova_vector_search_result {
    char *id;
    size_t id_len;
    double distance;
} zova_vector_search_result;

/* Owned vector search results. Free with zova_vector_search_results_free. */
typedef struct zova_vector_search_results {
    zova_vector_search_result *items;
    size_t len;
} zova_vector_search_results;

/* Owned vector collection info. Free with zova_vector_collection_info_free. */
typedef struct zova_vector_collection_info {
    char *name;
    size_t name_len;
    uint32_t dimensions;
    int metric;
    int element_type;
    uint64_t vector_count;
} zova_vector_collection_info;

/* Owned vector collection list. Free with zova_vector_collection_list_free. */
typedef struct zova_vector_collection_list {
    zova_vector_collection_info *items;
    size_t len;
} zova_vector_collection_list;

/* Borrowed input row for zova_vector_put_many. */
typedef struct zova_vector_input {
    const char *id;
    zova_vector_values values;
} zova_vector_input;

/* Owned graph info. Free with zova_graph_info_free. */
typedef struct zova_graph_info {
    char *name;
    size_t name_len;
    uint64_t node_count;
    uint64_t edge_count;
} zova_graph_info;

/* Owned graph list. Free with zova_graph_list_free. */
typedef struct zova_graph_list {
    zova_graph_info *items;
    size_t len;
} zova_graph_list;

/* Owned extension info. Free with zova_extension_info_free. */
typedef struct zova_extension_info {
    char *name;
    size_t name_len;
    char *version;
    size_t version_len;
    char *storage_prefix;
    size_t storage_prefix_len;
    char *zova_abi_min;
    size_t zova_abi_min_len;
    char *capabilities;
    size_t capabilities_len;
    uint8_t required;
    int64_t installed_at_unix;
    char *manifest_json;
    size_t manifest_json_len;
} zova_extension_info;

/* Owned extension info list. Free with zova_extension_list_free. */
typedef struct zova_extension_list {
    zova_extension_info *items;
    size_t len;
} zova_extension_list;

/* Owned graph node. Free with zova_graph_node_free. */
typedef struct zova_graph_node {
    char *graph_name;
    size_t graph_name_len;
    char *node_id;
    size_t node_id_len;
    char *kind;
    size_t kind_len;
    int target_type;
    char *target_namespace;
    size_t target_namespace_len;
    uint8_t has_target_namespace;
    char *target_ref;
    size_t target_ref_len;
    uint8_t has_target_ref;
} zova_graph_node;

/* Owned exact graph edge. Free with zova_graph_edge_free. */
typedef struct zova_graph_edge {
    char *graph_name;
    size_t graph_name_len;
    char *from_node_id;
    size_t from_node_id_len;
    char *edge_type;
    size_t edge_type_len;
    char *to_node_id;
    size_t to_node_id_len;
} zova_graph_edge;

typedef struct zova_graph_neighbor_result {
    char *node_id;
    size_t node_id_len;
    char *kind;
    size_t kind_len;
    char *edge_type;
    size_t edge_type_len;
} zova_graph_neighbor_result;

/* Owned graph neighbor results. Free with zova_graph_neighbor_results_free. */
typedef struct zova_graph_neighbor_results {
    zova_graph_neighbor_result *items;
    size_t len;
} zova_graph_neighbor_results;

typedef struct zova_graph_walk_result {
    char *node_id;
    size_t node_id_len;
    char *kind;
    size_t kind_len;
    uint32_t depth;
    char *predecessor_node_id;
    size_t predecessor_node_id_len;
    uint8_t has_predecessor_node_id;
    char *edge_type;
    size_t edge_type_len;
    uint8_t has_edge_type;
} zova_graph_walk_result;

/* Owned graph walk results. Free with zova_graph_walk_results_free. */
typedef struct zova_graph_walk_results {
    zova_graph_walk_result *items;
    size_t len;
} zova_graph_walk_results;

/* Diagnostic stages and counters for one profiled directional graph walk. */
typedef struct zova_graph_walk_profile {
    double mutex_wait_ms;
    double root_lookup_ms;
    double adjacency_prepare_ms;
    double adjacency_execute_ms;
    double bfs_bookkeeping_allocation_ms;
    double c_abi_result_export_ms;
    double total_profiled_ms;
    uint64_t frontier_expansions;
    uint64_t adjacency_query_binds;
    uint64_t adjacency_rows_stepped;
    uint64_t result_count;
} zova_graph_walk_profile;

enum {
    ZOVA_OPEN_READ_ONLY = 1u << 0
};

enum {
    ZOVA_BACKUP_NO_VERIFY = 1u << 0,
    ZOVA_COMPACT_NO_VERIFY = 1u << 0,
    ZOVA_RESTORE_NO_VERIFY = 1u << 0
};

/* Open/create requests use C strings and may return an owned error message. */
typedef struct zova_database_open_request {
    const char *path;
    zova_database **out_db;
    zova_message *out_error_message;
} zova_database_open_request;

/* Fresh-database options. page_size = 0 preserves SQLite's default. */
typedef struct zova_database_create_options_request {
    const char *path;
    uint32_t page_size;
    zova_database **out_db;
    zova_message *out_error_message;
} zova_database_create_options_request;

/*
 * Additive open options for existing .zova files. flags = 0 opens read/write.
 * ZOVA_OPEN_READ_ONLY opens the SQLite handle read-only. busy_timeout_ms = 0
 * leaves SQLite's default busy handling unchanged.
 */
typedef struct zova_database_open_options_request {
    const char *path;
    uint32_t flags;
    uint32_t busy_timeout_ms;
    zova_database **out_db;
    zova_message *out_error_message;
} zova_database_open_options_request;

/*
 * Open/create while loading explicitly trusted local .zovaext bundles. The
 * bundle code is kept loaded for the lifetime of the returned database handle.
 * Passing extension_bundle_count = 0 is equivalent to the normal bundled
 * registry path. create_with_extensions requires flags = 0 and
 * busy_timeout_ms = 0; open_with_extensions accepts ZOVA_OPEN_READ_ONLY and a
 * busy timeout like zova_database_open_with_options.
 */
typedef struct zova_database_open_extensions_request {
    const char *path;
    uint32_t flags;
    uint32_t busy_timeout_ms;
    const char *const *extension_bundle_paths;
    size_t extension_bundle_count;
    const char *trust_store_path;
    zova_database **out_db;
    zova_message *out_error_message;
} zova_database_open_extensions_request;

/*
 * Local extension bundle management. verify loads the entrypoint without
 * trusting the bundle. trust records the manifest/library hash in the selected
 * trust store. A NULL trust_store_path uses Zova's default trust store.
 */
typedef struct zova_extension_bundle_request {
    const char *bundle_path;
    const char *trust_store_path;
    zova_message *out_error_message;
} zova_extension_bundle_request;

typedef struct zova_extension_bundle_untrust_request {
    const char *identifier;
    const char *trust_store_path;
    uint8_t *out_removed;
    zova_message *out_error_message;
} zova_extension_bundle_untrust_request;

/* Conversion never mutates the source and never overwrites the destination. */
typedef struct zova_convert_sqlite_to_zova_request {
    const char *source_path;
    const char *dest_path;
    zova_message *out_error_message;
} zova_convert_sqlite_to_zova_request;

/*
 * Operational copy requests never overwrite destination files. By default Zova
 * opens and verifies the destination after the copy. Use *_NO_VERIFY flags only
 * when the caller will verify separately.
 */
typedef struct zova_database_backup_request {
    zova_database *db;
    const char *destination_path;
    uint32_t flags;
} zova_database_backup_request;

typedef struct zova_database_compact_request {
    zova_database *db;
    const char *destination_path;
    uint32_t flags;
} zova_database_compact_request;

typedef struct zova_database_restore_request {
    const char *source_path;
    const char *destination_path;
    uint32_t flags;
    zova_message *out_error_message;
} zova_database_restore_request;

/* SQL is passed through to SQLite unchanged. */
typedef struct zova_database_exec_request {
    zova_database *db;
    const char *sql;
} zova_database_exec_request;

/*
 * Register an app-defined scalar SQL function on this Zova-owned connection.
 * Function names are ASCII identifiers, 1-64 bytes, and may not use a zova_
 * or _zova_ prefix. Arity is -1 for varargs or 0..127 for fixed arity.
 *
 * Callbacks run inside the database handle serialization boundary. They must
 * not re-enter the same zova_database handle. Argument pointers are borrowed
 * for the callback only. Text/blob/error result pointers are copied by Zova
 * before SQLite observes the result.
 */
typedef struct zova_sql_function_register_request {
    zova_database *db;
    const char *name;
    int arity;
    uint32_t flags;
    void *user_data;
    zova_sql_scalar_callback callback;
    zova_sql_destroy_callback destroy;
} zova_sql_function_register_request;

typedef struct zova_database_simple_request {
    zova_database *db;
} zova_database_simple_request;

/*
 * Savepoint names are strict ASCII identifiers: 1-64 bytes, first byte
 * [A-Za-z_], remaining bytes [A-Za-z0-9_], and no case-insensitive _zova_
 * prefix. ROLLBACK TO keeps the savepoint active; RELEASE removes it.
 * Savepoint calls are serialized with the database handle, but they are not
 * callback-reentrant and do not change child statement/writer lifetime rules.
 */
typedef struct zova_database_savepoint_request {
    zova_database *db;
    const char *name;
} zova_database_savepoint_request;

typedef struct zova_database_busy_timeout_request {
    zova_database *db;
    uint32_t milliseconds;
} zova_database_busy_timeout_request;

typedef struct zova_database_last_insert_rowid_request {
    zova_database *db;
    int64_t *out_rowid;
} zova_database_last_insert_rowid_request;

typedef struct zova_database_changes_request {
    zova_database *db;
    int64_t *out_changes;
} zova_database_changes_request;

typedef struct zova_database_total_changes_request {
    zova_database *db;
    int64_t *out_total_changes;
} zova_database_total_changes_request;

typedef struct zova_database_notify_request {
    zova_database *db;
    const char *channel;
    const uint8_t *payload;
    size_t payload_len;
} zova_database_notify_request;

typedef struct zova_database_listen_request {
    zova_database *db;
    const char *channel;
    zova_subscription **out_subscription;
} zova_database_listen_request;

typedef struct zova_subscription_try_receive_request {
    zova_subscription *subscription;
    zova_notification *out_notification;
    uint8_t *out_has_notification;
} zova_subscription_try_receive_request;

typedef struct zova_database_prepare_request {
    zova_database *db;
    const char *sql;
    zova_statement **out_statement;
} zova_database_prepare_request;

typedef struct zova_statement_step_request {
    zova_statement *statement;
    zova_step_result *out_result;
} zova_statement_step_request;

typedef struct zova_statement_bind_null_request {
    zova_statement *statement;
    int index;
} zova_statement_bind_null_request;

typedef struct zova_statement_bind_int64_request {
    zova_statement *statement;
    int index;
    int64_t value;
} zova_statement_bind_int64_request;

typedef struct zova_statement_bind_double_request {
    zova_statement *statement;
    int index;
    double value;
} zova_statement_bind_double_request;

typedef struct zova_statement_bind_text_request {
    zova_statement *statement;
    int index;
    const uint8_t *data;
    size_t len;
} zova_statement_bind_text_request;

typedef struct zova_statement_bind_blob_request {
    zova_statement *statement;
    int index;
    const uint8_t *data;
    size_t len;
} zova_statement_bind_blob_request;

typedef struct zova_statement_parameter_count_request {
    zova_statement *statement;
    int *out_count;
} zova_statement_parameter_count_request;

typedef struct zova_statement_parameter_index_request {
    zova_statement *statement;
    const char *name;
    int *out_index;
} zova_statement_parameter_index_request;

typedef struct zova_statement_column_count_request {
    zova_statement *statement;
    int *out_count;
} zova_statement_column_count_request;

typedef struct zova_statement_column_name_request {
    zova_statement *statement;
    int index;
    zova_text *out_name;
} zova_statement_column_name_request;

typedef struct zova_statement_column_type_request {
    zova_statement *statement;
    int index;
    zova_column_type *out_type;
} zova_statement_column_type_request;

typedef struct zova_statement_column_int64_request {
    zova_statement *statement;
    int index;
    int64_t *out_value;
} zova_statement_column_int64_request;

typedef struct zova_statement_column_double_request {
    zova_statement *statement;
    int index;
    double *out_value;
} zova_statement_column_double_request;

typedef struct zova_statement_column_text_request {
    zova_statement *statement;
    int index;
    zova_text *out_text;
} zova_statement_column_text_request;

typedef struct zova_statement_column_blob_request {
    zova_statement *statement;
    int index;
    zova_buffer *out_buffer;
} zova_statement_column_blob_request;

/* Stores caller bytes as a complete content-addressed object. */
typedef struct zova_object_put_request {
    zova_database *db;
    const uint8_t *data;
    size_t len;
    zova_object_id *out_id;
} zova_object_put_request;

/* Returns full object bytes in an owned zova_buffer. */
typedef struct zova_object_get_request {
    zova_database *db;
    zova_object_id id;
    zova_buffer *out_buffer;
} zova_object_get_request;

/* Copies a byte range into caller-provided memory. */
typedef struct zova_object_read_range_request {
    zova_database *db;
    zova_object_id id;
    uint64_t offset;
    uint8_t *buffer;
    size_t buffer_len;
    size_t *out_copied;
} zova_object_read_range_request;

typedef struct zova_object_exists_request {
    zova_database *db;
    zova_object_id id;
    uint8_t *out_exists;
} zova_object_exists_request;

typedef struct zova_object_size_request {
    zova_database *db;
    zova_object_id id;
    uint64_t *out_size;
} zova_object_size_request;

typedef struct zova_object_chunk_count_request {
    zova_database *db;
    zova_object_id id;
    uint64_t *out_count;
} zova_object_chunk_count_request;

typedef struct zova_object_delete_request {
    zova_database *db;
    zova_object_id id;
} zova_object_delete_request;

typedef struct zova_object_manifest_get_request {
    zova_database *db;
    zova_object_id id;
    zova_object_manifest *out_manifest;
} zova_object_manifest_get_request;

typedef struct zova_object_chunk_get_request {
    zova_database *db;
    zova_object_chunk_id hash;
    zova_buffer *out_buffer;
} zova_object_chunk_get_request;

typedef struct zova_object_chunk_put_request {
    zova_database *db;
    zova_object_chunk_id expected_hash;
    const uint8_t *data;
    size_t len;
} zova_object_chunk_put_request;

typedef struct zova_object_chunk_delete_request {
    zova_database *db;
    zova_object_chunk_id hash;
    uint8_t *out_deleted;
} zova_object_chunk_delete_request;

typedef struct zova_object_assemble_from_chunks_request {
    zova_database *db;
    zova_object_id id;
    uint64_t size_bytes;
    const zova_object_manifest_chunk *chunks;
    size_t chunk_count;
} zova_object_assemble_from_chunks_request;

/* Streaming writers are explicit resources; destroy them when finished. */
typedef struct zova_object_writer_create_request {
    zova_database *db;
    zova_object_writer **out_writer;
} zova_object_writer_create_request;

typedef struct zova_object_writer_write_request {
    zova_object_writer *writer;
    const uint8_t *data;
    size_t len;
} zova_object_writer_write_request;

typedef struct zova_object_writer_finish_request {
    zova_object_writer *writer;
    zova_object_id *out_id;
} zova_object_writer_finish_request;

typedef struct zova_object_writer_cancel_request {
    zova_object_writer *writer;
} zova_object_writer_cancel_request;

typedef struct zova_vector_collection_create_request {
    zova_database *db;
    const char *name;
    zova_vector_collection_options options;
} zova_vector_collection_create_request;

typedef struct zova_vector_collection_exists_request {
    zova_database *db;
    const char *name;
    uint8_t *out_exists;
} zova_vector_collection_exists_request;

typedef struct zova_vector_put_request {
    zova_database *db;
    const char *collection_name;
    const char *vector_id;
    zova_vector_values values;
} zova_vector_put_request;

typedef struct zova_vector_get_request {
    zova_database *db;
    const char *collection_name;
    const char *vector_id;
    zova_vector *out_vector;
} zova_vector_get_request;

typedef struct zova_vector_exists_request {
    zova_database *db;
    const char *collection_name;
    const char *vector_id;
    uint8_t *out_exists;
} zova_vector_exists_request;

typedef struct zova_vector_delete_request {
    zova_database *db;
    const char *collection_name;
    const char *vector_id;
} zova_vector_delete_request;

typedef struct zova_vector_search_request {
    zova_database *db;
    const char *collection_name;
    zova_vector_values query;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_request;

typedef struct zova_vector_search_in_request {
    zova_database *db;
    const char *collection_name;
    zova_vector_values query;
    const char *const *candidate_ids;
    size_t candidate_count;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_in_request;

/*
 * Search a raw-i8 cosine collection with one or more contiguous query rows.
 * query_values_len must equal query_count * dimensions. Results use distance
 * = 1 - min cosine similarity, sorted by distance and then vector id. With
 * candidate_count == 0, the whole collection is searched.
 */
typedef struct zova_vector_search_multi_i8_request {
    zova_database *db;
    const char *collection_name;
    const int8_t *query_values;
    size_t query_values_len;
    size_t query_count;
    size_t dimensions;
    const char *const *candidate_ids;
    size_t candidate_count;
    int mode;
    int aggregation;
    size_t prefilter_query_index;
    size_t prefilter_limit;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_multi_i8_request;

typedef struct zova_vector_collection_info_get_request {
    zova_database *db;
    const char *name;
    zova_vector_collection_info *out_info;
} zova_vector_collection_info_get_request;

typedef struct zova_vector_collections_list_request {
    zova_database *db;
    zova_vector_collection_list *out_list;
} zova_vector_collections_list_request;

typedef struct zova_vector_put_many_request {
    zova_database *db;
    const char *collection_name;
    const zova_vector_input *vectors;
    size_t vectors_len;
} zova_vector_put_many_request;

typedef struct zova_vector_delete_many_request {
    zova_database *db;
    const char *collection_name;
    const char *const *vector_ids;
    size_t vector_count;
} zova_vector_delete_many_request;

typedef struct zova_vector_collection_delete_request {
    zova_database *db;
    const char *name;
} zova_vector_collection_delete_request;

typedef struct zova_vector_search_within_request {
    zova_database *db;
    const char *collection_name;
    zova_vector_values query;
    double max_distance;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_within_request;

typedef struct zova_vector_search_in_within_request {
    zova_database *db;
    const char *collection_name;
    zova_vector_values query;
    const char *const *candidate_ids;
    size_t candidate_count;
    double max_distance;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_in_within_request;

typedef struct zova_vector_search_by_id_request {
    zova_database *db;
    const char *collection_name;
    const char *source_vector_id;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_by_id_request;

typedef struct zova_vector_search_by_id_in_request {
    zova_database *db;
    const char *collection_name;
    const char *source_vector_id;
    const char *const *candidate_ids;
    size_t candidate_count;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_by_id_in_request;

typedef struct zova_vector_search_by_id_within_request {
    zova_database *db;
    const char *collection_name;
    const char *source_vector_id;
    double max_distance;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_by_id_within_request;

typedef struct zova_vector_search_by_id_in_within_request {
    zova_database *db;
    const char *collection_name;
    const char *source_vector_id;
    const char *const *candidate_ids;
    size_t candidate_count;
    double max_distance;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_by_id_in_within_request;

typedef struct zova_graph_create_request {
    zova_database *db;
    const char *name;
} zova_graph_create_request;

typedef struct zova_graph_exists_request {
    zova_database *db;
    const char *name;
    uint8_t *out_exists;
} zova_graph_exists_request;

typedef struct zova_graph_info_get_request {
    zova_database *db;
    const char *name;
    zova_graph_info *out_info;
} zova_graph_info_get_request;

typedef struct zova_graph_list_request {
    zova_database *db;
    zova_graph_list *out_list;
} zova_graph_list_request;

typedef struct zova_database_extension_request {
    zova_database *db;
    const char *name;
} zova_database_extension_request;

typedef struct zova_database_extension_info_request {
    zova_database *db;
    const char *name;
    zova_extension_info *out_info;
} zova_database_extension_info_request;

typedef struct zova_database_extension_list_request {
    zova_database *db;
    zova_extension_list *out_list;
} zova_database_extension_list_request;

typedef struct zova_graph_delete_request {
    zova_database *db;
    const char *name;
} zova_graph_delete_request;

typedef struct zova_graph_node_put_request {
    zova_database *db;
    const char *graph_name;
    const char *node_id;
    const char *kind;
    int target_type;
    const char *target_namespace;
    const char *target_ref;
} zova_graph_node_put_request;

/* Borrowed input row for zova_graph_node_put_many. */
typedef struct zova_graph_node_input {
    const char *graph_name;
    const char *node_id;
    const char *kind;
    int target_type;
    const char *target_namespace;
    const char *target_ref;
} zova_graph_node_input;

/*
 * All node inputs are validated before this atomic batch mutates the graph.
 * It joins an active Zova transaction; otherwise Zova opens and commits one
 * immediate transaction for the whole batch.
 */
typedef struct zova_graph_node_put_many_request {
    zova_database *db;
    const zova_graph_node_input *nodes;
    size_t nodes_len;
} zova_graph_node_put_many_request;

typedef struct zova_graph_node_get_request {
    zova_database *db;
    const char *graph_name;
    const char *node_id;
    zova_graph_node *out_node;
} zova_graph_node_get_request;

typedef struct zova_graph_node_exists_request {
    zova_database *db;
    const char *graph_name;
    const char *node_id;
    uint8_t *out_exists;
} zova_graph_node_exists_request;

typedef struct zova_graph_node_delete_request {
    zova_database *db;
    const char *graph_name;
    const char *node_id;
} zova_graph_node_delete_request;

/*
 * Missing ids are ignored; every incident edge of an existing node is removed.
 * It joins an active Zova transaction; otherwise Zova owns one transaction.
 */
typedef struct zova_graph_node_delete_many_request {
    zova_database *db;
    const char *graph_name;
    const char *const *node_ids;
    size_t node_count;
} zova_graph_node_delete_many_request;

typedef struct zova_graph_edge_put_request {
    zova_database *db;
    const char *graph_name;
    const char *from_node_id;
    const char *edge_type;
    const char *to_node_id;
} zova_graph_edge_put_request;

/* Borrowed input row for zova_graph_edge_put_many. */
typedef struct zova_graph_edge_input {
    const char *graph_name;
    const char *from_node_id;
    const char *edge_type;
    const char *to_node_id;
} zova_graph_edge_input;

/*
 * All endpoints are validated before this atomic batch mutates the graph.
 * Exact duplicate edges are idempotent. It joins an active Zova transaction;
 * otherwise Zova opens and commits one immediate transaction for the batch.
 */
typedef struct zova_graph_edge_put_many_request {
    zova_database *db;
    const zova_graph_edge_input *edges;
    size_t edges_len;
} zova_graph_edge_put_many_request;

typedef struct zova_graph_edge_delete_many_request {
    zova_database *db;
    const zova_graph_edge_input *edges;
    size_t edges_len;
} zova_graph_edge_delete_many_request;

typedef struct zova_graph_edge_get_request {
    zova_database *db;
    const char *graph_name;
    const char *from_node_id;
    const char *edge_type;
    const char *to_node_id;
    zova_graph_edge *out_edge;
} zova_graph_edge_get_request;

typedef struct zova_graph_edge_exists_request {
    zova_database *db;
    const char *graph_name;
    const char *from_node_id;
    const char *edge_type;
    const char *to_node_id;
    uint8_t *out_exists;
} zova_graph_edge_exists_request;

typedef struct zova_graph_edge_delete_request {
    zova_database *db;
    const char *graph_name;
    const char *from_node_id;
    const char *edge_type;
    const char *to_node_id;
} zova_graph_edge_delete_request;

/*
 * Neighbors are emitted in edge insertion order, then neighbor node id. limit
 * bounds emitted neighbor rows; an existing source node with limit 0 succeeds
 * with an empty result.
 */
typedef struct zova_graph_neighbors_request {
    zova_database *db;
    const char *graph_name;
    const char *node_id;
    int direction;
    const char *edge_type;
    size_t limit;
    zova_graph_neighbor_results *out_results;
} zova_graph_neighbors_request;

/* Count edges adjacent to one existing node, optionally filtered by type. */
typedef struct zova_graph_degree_request {
    zova_database *db;
    const char *graph_name;
    const char *node_id;
    int direction;
    const char *edge_type;
    uint64_t *out_degree;
} zova_graph_degree_request;

/*
 * Walk follows outgoing edges in breadth-first order. The start node is the
 * first emitted row at depth 0; limit bounds emitted walk rows, including it.
 */
typedef struct zova_graph_walk_request {
    zova_database *db;
    const char *graph_name;
    const char *start_node_id;
    const char *edge_type;
    uint32_t max_depth;
    size_t limit;
    zova_graph_walk_results *out_results;
} zova_graph_walk_request;

/*
 * Directional bounded BFS. The start node is emitted at depth 0 and limit
 * counts emitted rows including it. Outgoing walks use edge insertion order
 * then destination node ID; incoming walks use edge insertion order then
 * source node ID.
 */
typedef struct zova_graph_walk_direction_request {
    zova_database *db;
    const char *graph_name;
    const char *start_node_id;
    int direction;
    const char *edge_type;
    uint32_t max_depth;
    size_t limit;
    zova_graph_walk_results *out_results;
} zova_graph_walk_direction_request;

/* ABI-additive diagnostic variant of zova_graph_walk_direction. */
typedef struct zova_graph_walk_direction_profiled_request {
    zova_database *db;
    const char *graph_name;
    const char *start_node_id;
    int direction;
    const char *edge_type;
    uint32_t max_depth;
    size_t limit;
    zova_graph_walk_results *out_results;
    zova_graph_walk_profile *out_profile;
} zova_graph_walk_direction_profiled_request;

/* ABI version helpers describe this C boundary, not the .zova file format. */
uint32_t zova_abi_version_major(void);
uint32_t zova_abi_version_minor(void);
uint32_t zova_abi_version_patch(void);
const char *zova_abi_version_string(void);
const char *zova_status_name(zova_status status);

/* Free functions are null-safe and reset the passed container to empty. */
void zova_buffer_free(zova_buffer *buffer);
void zova_message_free(zova_message *message);
void zova_text_free(zova_text *text);
void zova_notification_free(zova_notification *notification);
void zova_object_manifest_free(zova_object_manifest *manifest);
void zova_vector_free(zova_vector *vector);
void zova_vector_search_results_free(zova_vector_search_results *results);
void zova_vector_collection_info_free(zova_vector_collection_info *info);
void zova_vector_collection_list_free(zova_vector_collection_list *list);
void zova_graph_info_free(zova_graph_info *info);
void zova_graph_list_free(zova_graph_list *list);
void zova_extension_info_free(zova_extension_info *info);
void zova_extension_list_free(zova_extension_list *list);
void zova_graph_node_free(zova_graph_node *node);
void zova_graph_edge_free(zova_graph_edge *edge);
void zova_graph_neighbor_results_free(zova_graph_neighbor_results *results);
void zova_graph_walk_results_free(zova_graph_walk_results *results);

/* Database lifecycle, SQL passthrough, prepared statements, and conversion. */
zova_status zova_database_create(const zova_database_open_request *request);
zova_status zova_database_create_with_options(const zova_database_create_options_request *request);
zova_status zova_database_create_with_extensions(const zova_database_open_extensions_request *request);
zova_status zova_database_open(const zova_database_open_request *request);
zova_status zova_database_open_with_options(const zova_database_open_options_request *request);
zova_status zova_database_open_with_extensions(const zova_database_open_extensions_request *request);
zova_status zova_extension_bundle_verify(const zova_extension_bundle_request *request);
zova_status zova_extension_bundle_trust(const zova_extension_bundle_request *request);
zova_status zova_extension_bundle_untrust(const zova_extension_bundle_untrust_request *request);
zova_status zova_database_close(zova_database *db);
zova_status zova_database_exec(const zova_database_exec_request *request);
zova_status zova_database_register_function(const zova_sql_function_register_request *request);
zova_status zova_database_begin(const zova_database_simple_request *request);
zova_status zova_database_begin_immediate(const zova_database_simple_request *request);
zova_status zova_database_commit(const zova_database_simple_request *request);
zova_status zova_database_rollback(const zova_database_simple_request *request);
zova_status zova_database_savepoint(const zova_database_savepoint_request *request);
zova_status zova_database_rollback_to_savepoint(const zova_database_savepoint_request *request);
zova_status zova_database_release_savepoint(const zova_database_savepoint_request *request);
zova_status zova_database_vacuum(const zova_database_simple_request *request);
zova_status zova_database_backup(const zova_database_backup_request *request);
zova_status zova_database_compact(const zova_database_compact_request *request);
zova_status zova_database_set_busy_timeout(const zova_database_busy_timeout_request *request);
zova_status zova_database_last_insert_rowid(const zova_database_last_insert_rowid_request *request);
zova_status zova_database_changes(const zova_database_changes_request *request);
zova_status zova_database_total_changes(const zova_database_total_changes_request *request);
zova_status zova_database_notify(const zova_database_notify_request *request);
zova_status zova_database_listen(const zova_database_listen_request *request);
zova_status zova_subscription_try_receive(const zova_subscription_try_receive_request *request);
zova_status zova_subscription_close(zova_subscription *subscription);
zova_status zova_database_prepare(const zova_database_prepare_request *request);
const char *zova_database_last_error_message(zova_database *db);
zova_status zova_convert_sqlite_to_zova(const zova_convert_sqlite_to_zova_request *request);
zova_status zova_database_restore(const zova_database_restore_request *request);

/*
 * Prepared statements.
 *
 * Parameter indexes are 1-based. Column indexes are 0-based. Text and blob
 * bind inputs are borrowed for the call; column text/blob outputs are owned by
 * Zova and must be freed with zova_text_free or zova_buffer_free.
 */
zova_status zova_statement_finalize(zova_statement *statement);
zova_status zova_statement_step(const zova_statement_step_request *request);
zova_status zova_statement_reset(zova_statement *statement);
zova_status zova_statement_clear_bindings(zova_statement *statement);
zova_status zova_statement_bind_null(const zova_statement_bind_null_request *request);
zova_status zova_statement_bind_int64(const zova_statement_bind_int64_request *request);
zova_status zova_statement_bind_double(const zova_statement_bind_double_request *request);
zova_status zova_statement_bind_text(const zova_statement_bind_text_request *request);
zova_status zova_statement_bind_blob(const zova_statement_bind_blob_request *request);
zova_status zova_statement_parameter_count(const zova_statement_parameter_count_request *request);
zova_status zova_statement_parameter_index(const zova_statement_parameter_index_request *request);
zova_status zova_statement_column_count(const zova_statement_column_count_request *request);
zova_status zova_statement_column_name(const zova_statement_column_name_request *request);
zova_status zova_statement_column_type(const zova_statement_column_type_request *request);
zova_status zova_statement_column_int64(const zova_statement_column_int64_request *request);
zova_status zova_statement_column_double(const zova_statement_column_double_request *request);
zova_status zova_statement_column_text(const zova_statement_column_text_request *request);
zova_status zova_statement_column_blob(const zova_statement_column_blob_request *request);

/*
 * Object/chunk helpers and lifecycle operations.
 *
 * The id helpers use *_from_bytes names because C typedef names share the
 * ordinary identifier namespace, so a function named zova_object_id would
 * collide with the zova_object_id typedef.
 */
zova_status zova_object_id_from_bytes(const uint8_t *data, size_t len, zova_object_id *out_id);
zova_status zova_object_chunk_id_from_bytes(const uint8_t *data, size_t len, zova_object_chunk_id *out_id);
zova_status zova_object_put(const zova_object_put_request *request);
zova_status zova_object_get(const zova_object_get_request *request);
zova_status zova_object_read_range(const zova_object_read_range_request *request);
zova_status zova_object_delete(const zova_object_delete_request *request);
zova_status zova_object_exists(const zova_object_exists_request *request);
zova_status zova_object_size(const zova_object_size_request *request);
zova_status zova_object_chunk_count(const zova_object_chunk_count_request *request);
zova_status zova_object_manifest_get(const zova_object_manifest_get_request *request);
zova_status zova_object_chunk_get(const zova_object_chunk_get_request *request);
zova_status zova_object_chunk_put(const zova_object_chunk_put_request *request);
zova_status zova_object_chunk_delete(const zova_object_chunk_delete_request *request);
zova_status zova_object_assemble_from_chunks(const zova_object_assemble_from_chunks_request *request);

/* ObjectWriter streams bytes into verified chunks and finishes as one object. */
zova_status zova_object_writer_create(const zova_object_writer_create_request *request);
zova_status zova_object_writer_write(const zova_object_writer_write_request *request);
zova_status zova_object_writer_finish(const zova_object_writer_finish_request *request);
zova_status zova_object_writer_cancel(const zova_object_writer_cancel_request *request);
zova_status zova_object_writer_destroy(zova_object_writer *writer);

/*
 * Native vector operations.
 *
 * Collection names and vector ids are null-terminated UTF-8 C strings.
 * Value APIs use zova_vector_values and support raw f32, f16 IEEE-754
 * binary16 bits, and signed i8 values without quantization.
 * Search returns vector ids and lower-is-better distances only; applications
 * should query their own SQL tables for metadata.
 */
zova_status zova_vector_collection_create(const zova_vector_collection_create_request *request);
zova_status zova_vector_collection_exists(const zova_vector_collection_exists_request *request);
zova_status zova_vector_collection_info_get(const zova_vector_collection_info_get_request *request);
zova_status zova_vector_collections_list(const zova_vector_collections_list_request *request);
zova_status zova_vector_put(const zova_vector_put_request *request);
zova_status zova_vector_put_many(const zova_vector_put_many_request *request);
zova_status zova_vector_delete_many(const zova_vector_delete_many_request *request);
zova_status zova_vector_get(const zova_vector_get_request *request);
zova_status zova_vector_exists(const zova_vector_exists_request *request);
zova_status zova_vector_delete(const zova_vector_delete_request *request);
zova_status zova_vector_collection_delete(const zova_vector_collection_delete_request *request);
zova_status zova_vector_search(const zova_vector_search_request *request);
zova_status zova_vector_search_in(const zova_vector_search_in_request *request);
zova_status zova_vector_search_multi_i8(const zova_vector_search_multi_i8_request *request);
zova_status zova_vector_search_within(const zova_vector_search_within_request *request);
zova_status zova_vector_search_in_within(const zova_vector_search_in_within_request *request);
zova_status zova_vector_search_by_id(const zova_vector_search_by_id_request *request);
zova_status zova_vector_search_by_id_in(const zova_vector_search_by_id_in_request *request);
zova_status zova_vector_search_by_id_within(const zova_vector_search_by_id_within_request *request);
zova_status zova_vector_search_by_id_in_within(const zova_vector_search_by_id_in_within_request *request);

/*
 * Native graph operations.
 *
 * Graph names, node ids, node kinds, and edge types are application-owned
 * UTF-8 strings validated by Zova. Graph results contain topology and target
 * references only; applications should query their own SQL tables for metadata.
 * zova_graphs_list uses a plural name because zova_graph_list is the owned
 * result container typedef.
 */
zova_status zova_graph_create(const zova_graph_create_request *request);
zova_status zova_graph_exists(const zova_graph_exists_request *request);
zova_status zova_graph_info_get(const zova_graph_info_get_request *request);
zova_status zova_graphs_list(const zova_graph_list_request *request);

/*
 * Extension lifecycle helpers manage extensions already present in the process
 * registry. Normal C-created handles use Zova's bundled registry, including
 * bundled extensions such as trgm. The C ABI also exposes controlled scalar SQL
 * callback registration and trusted .zovaext bundle loading; it does not expose
 * raw sqlite3 handles as the normal extension path.
 */
zova_status zova_database_extension_install(const zova_database_extension_request *request);
zova_status zova_database_extension_list(const zova_database_extension_list_request *request);
zova_status zova_database_extension_info(const zova_database_extension_info_request *request);
zova_status zova_database_extension_check(const zova_database_extension_request *request);
zova_status zova_database_extension_check_all(const zova_database_simple_request *request);
zova_status zova_database_extension_drop(const zova_database_extension_request *request);

zova_status zova_graph_delete(const zova_graph_delete_request *request);
zova_status zova_graph_node_put(const zova_graph_node_put_request *request);
zova_status zova_graph_node_put_many(const zova_graph_node_put_many_request *request);
zova_status zova_graph_node_get(const zova_graph_node_get_request *request);
zova_status zova_graph_node_exists(const zova_graph_node_exists_request *request);
zova_status zova_graph_node_delete(const zova_graph_node_delete_request *request);
zova_status zova_graph_node_delete_many(const zova_graph_node_delete_many_request *request);
zova_status zova_graph_edge_put(const zova_graph_edge_put_request *request);
zova_status zova_graph_edge_put_many(const zova_graph_edge_put_many_request *request);
zova_status zova_graph_edge_delete_many(const zova_graph_edge_delete_many_request *request);
zova_status zova_graph_edge_get(const zova_graph_edge_get_request *request);
zova_status zova_graph_edge_exists(const zova_graph_edge_exists_request *request);
zova_status zova_graph_edge_delete(const zova_graph_edge_delete_request *request);
zova_status zova_graph_neighbors(const zova_graph_neighbors_request *request);
zova_status zova_graph_degree(const zova_graph_degree_request *request);
zova_status zova_graph_walk(const zova_graph_walk_request *request);
zova_status zova_graph_walk_direction(const zova_graph_walk_direction_request *request);
zova_status zova_graph_walk_direction_profiled(const zova_graph_walk_direction_profiled_request *request);

#ifdef __cplusplus
}
#endif

#endif
