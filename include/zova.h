#ifndef ZOVA_H
#define ZOVA_H

#include <stddef.h>
#include <stdint.h>

/*
 * Zova C ABI, v0.19.0 pre-1.0.
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
 *   ObjectWriter, and native vectors.
 * - Vector metadata remains application-owned in user SQL tables. Vector search
 *   returns vector ids and distances only.
 * - zova_database connections register read-only SQL vector helpers:
 *   zova_vector_distance, zova_vector_distance_by_id, and zova_vector_search.
 *   Query vector blobs for those SQL helpers are little-endian IEEE-754 f32
 *   arrays with exactly the collection dimension count.
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
} zova_status;

typedef enum zova_vector_metric {
    ZOVA_VECTOR_METRIC_COSINE = 0,
    ZOVA_VECTOR_METRIC_L2 = 1,
    ZOVA_VECTOR_METRIC_DOT = 2,
} zova_vector_metric;

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
} zova_vector_collection_options;

/* Owned vector returned by Zova. Free with zova_vector_free. */
typedef struct zova_vector {
    char *id;
    size_t id_len;
    float *values;
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
    const float *values;
    size_t values_len;
} zova_vector_input;

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
    const float *values;
    size_t values_len;
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
    const float *query;
    size_t query_len;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_request;

typedef struct zova_vector_search_in_request {
    zova_database *db;
    const char *collection_name;
    const float *query;
    size_t query_len;
    const char *const *candidate_ids;
    size_t candidate_count;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_in_request;

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

typedef struct zova_vector_collection_delete_request {
    zova_database *db;
    const char *name;
} zova_vector_collection_delete_request;

typedef struct zova_vector_search_within_request {
    zova_database *db;
    const char *collection_name;
    const float *query;
    size_t query_len;
    double max_distance;
    size_t limit;
    zova_vector_search_results *out_results;
} zova_vector_search_within_request;

typedef struct zova_vector_search_in_within_request {
    zova_database *db;
    const char *collection_name;
    const float *query;
    size_t query_len;
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

/* Database lifecycle, SQL passthrough, prepared statements, and conversion. */
zova_status zova_database_create(const zova_database_open_request *request);
zova_status zova_database_open(const zova_database_open_request *request);
zova_status zova_database_open_with_options(const zova_database_open_options_request *request);
zova_status zova_database_close(zova_database *db);
zova_status zova_database_exec(const zova_database_exec_request *request);
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
 * Vector values are borrowed float arrays for the duration of the call.
 * Search returns vector ids and lower-is-better distances only; applications
 * should query their own SQL tables for metadata.
 */
zova_status zova_vector_collection_create(const zova_vector_collection_create_request *request);
zova_status zova_vector_collection_exists(const zova_vector_collection_exists_request *request);
zova_status zova_vector_collection_info_get(const zova_vector_collection_info_get_request *request);
zova_status zova_vector_collections_list(const zova_vector_collections_list_request *request);
zova_status zova_vector_put(const zova_vector_put_request *request);
zova_status zova_vector_put_many(const zova_vector_put_many_request *request);
zova_status zova_vector_get(const zova_vector_get_request *request);
zova_status zova_vector_exists(const zova_vector_exists_request *request);
zova_status zova_vector_delete(const zova_vector_delete_request *request);
zova_status zova_vector_collection_delete(const zova_vector_collection_delete_request *request);
zova_status zova_vector_search(const zova_vector_search_request *request);
zova_status zova_vector_search_in(const zova_vector_search_in_request *request);
zova_status zova_vector_search_within(const zova_vector_search_within_request *request);
zova_status zova_vector_search_in_within(const zova_vector_search_in_within_request *request);
zova_status zova_vector_search_by_id(const zova_vector_search_by_id_request *request);
zova_status zova_vector_search_by_id_in(const zova_vector_search_by_id_in_request *request);
zova_status zova_vector_search_by_id_within(const zova_vector_search_by_id_within_request *request);
zova_status zova_vector_search_by_id_in_within(const zova_vector_search_by_id_in_within_request *request);

#ifdef __cplusplus
}
#endif

#endif
