#ifndef ZOVA_H
#define ZOVA_H

#include <stddef.h>
#include <stdint.h>

/*
 * Zova C ABI, v0.9 pre-1.0.
 *
 * This header exposes a C-compatible object API over Zova's Zig
 * implementation. The ABI is intentionally conservative: opaque handles,
 * request structs, fixed-size ids, explicit status codes, and caller-visible
 * ownership rules.
 *
 * Threading:
 * - Do not use the same zova_database or zova_object_writer handle
 *   concurrently from multiple threads.
 * - Multiple database handles may point at the same file; locking follows
 *   normal SQLite behavior.
 *
 * Strings and bytes:
 * - Paths and SQL are null-terminated C strings.
 * - Arbitrary object/chunk bytes use pointer + length.
 * - A null pointer with a non-zero length is invalid.
 *
 * Ownership:
 * - Buffers/messages/manifests returned by Zova are library-owned and must be
 *   released with the matching zova_*_free function.
 * - Input pointers are borrowed only for the duration of the call.
 * - zova_database_last_error_message returns a borrowed pointer scoped to the
 *   database handle; it is valid until the next call on that handle or close.
 *
 * Scope:
 * - This v0.9 ABI exposes database lifecycle, SQL exec, conversion, objects,
 *   chunks, manifests, range reads, assembly, and ObjectWriter.
 * - Vector APIs are intentionally not part of this C ABI slice.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handles. Callers must only pass them back to Zova functions. */
typedef struct zova_database zova_database;
typedef struct zova_object_writer zova_object_writer;

/* Stable status values for the v0.9 ABI surface. */
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
} zova_status;

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

/* Open/create requests use C strings and may return an owned error message. */
typedef struct zova_database_open_request {
    const char *path;
    zova_database **out_db;
    zova_message *out_error_message;
} zova_database_open_request;

/* Conversion never mutates the source and never overwrites the destination. */
typedef struct zova_convert_sqlite_to_zova_request {
    const char *source_path;
    const char *dest_path;
    zova_message *out_error_message;
} zova_convert_sqlite_to_zova_request;

/* SQL is passed through to SQLite unchanged. */
typedef struct zova_database_exec_request {
    zova_database *db;
    const char *sql;
} zova_database_exec_request;

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

/* ABI version helpers describe this C boundary, not the .zova file format. */
uint32_t zova_abi_version_major(void);
uint32_t zova_abi_version_minor(void);
uint32_t zova_abi_version_patch(void);
const char *zova_abi_version_string(void);
const char *zova_status_name(zova_status status);

/* Free functions are null-safe and reset the passed container to empty. */
void zova_buffer_free(zova_buffer *buffer);
void zova_message_free(zova_message *message);
void zova_object_manifest_free(zova_object_manifest *manifest);

/* Database lifecycle, SQL passthrough, and SQLite-to-Zova conversion. */
zova_status zova_database_create(const zova_database_open_request *request);
zova_status zova_database_open(const zova_database_open_request *request);
zova_status zova_database_close(zova_database *db);
zova_status zova_database_exec(const zova_database_exec_request *request);
const char *zova_database_last_error_message(zova_database *db);
zova_status zova_convert_sqlite_to_zova(const zova_convert_sqlite_to_zova_request *request);

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

#ifdef __cplusplus
}
#endif

#endif
