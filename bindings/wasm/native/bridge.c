#include "bridge.h"
#include "zova.h"
#include <stdlib.h>
#include <string.h>
#ifdef ZOVA_WASM_OPFS
#include "sqlite3.h"
#include <stdio.h>
#endif
#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#define EXPORTED EMSCRIPTEN_KEEPALIVE
#else
#define EXPORTED
#endif

/* One instance per dedicated worker/module. No native handles cross to clients. */
static zova_database *db;
/* Open statements by handle; `statement` is the one selected for bind/step/column. */
static zova_statement **statements;
static int statement_count;
static int current = -1;
static zova_statement *statement;
/* Notification subscriptions by handle. */
static zova_subscription **subscriptions;
static int subscription_count;
/* Encoded reply of zw_call, owned until the next operation. */
static uint8_t *out;
static size_t out_len;
static size_t out_cap;
static int out_bad;
static zova_message message;
static zova_text text;
static zova_buffer buffer;
static int number;
static int64_t integer;
static double real;
static const uint8_t *bytes;
static size_t length;
static void clear_output(void);
static void streams_close(void);
#ifdef ZOVA_WASM_OPFS
static void export_end(void);
static int import_end(int commit);
static void fresh_end(void);
#endif

/* A module built with its own plugins (ZOVA_WASM_PLUGIN_SOURCES) defines this
 * to return its statically linked plugin descriptors; the package has none. */
__attribute__((weak)) const struct zova_plugin_descriptor_v1 *const *zova_wasm_linked_plugins(size_t *count) {
    *count = 0;
    return NULL;
}

#ifdef ZOVA_WASM_OPFS
extern zova_status zova_opfs_create(const zova_database_open_request *);
extern zova_status zova_opfs_open(const zova_database_open_request *);
extern zova_status zova_opfs_create_plugins(const zova_database_open_plugins_request *);
extern zova_status zova_opfs_open_plugins(const zova_database_open_plugins_request *);
extern zova_status zova_opfs_open_options(const zova_database_open_options_request *);
extern zova_status zova_opfs_create_options(const zova_database_create_options_request *);
extern zova_status zova_opfs_open_upgrade(const zova_database_open_extensions_request *);
extern zova_status zova_opfs_open_upgrade_plugins(const zova_database_open_plugins_request *);
extern zova_status zova_opfs_convert(const zova_convert_sqlite_to_zova_request *);

enum { OPEN_CREATE = 0, OPEN_EXISTING = 1, OPEN_UPGRADE = 2 };
static char bridge_error[160];

/* Opens or creates `path` with the linked plugins, if the module has any. The
 * C ABI has no create call taking both plugins and a page size. */
static int open_with_plugins(const char *path, int mode, uint32_t page_size, uint32_t flags, uint32_t busy_timeout_ms, int *used) {
    size_t count = 0;
    const struct zova_plugin_descriptor_v1 *const *plugins = zova_wasm_linked_plugins(&count);
    *used = count != 0;
    if (!count) return ZOVA_OK;
    if (page_size) {
        snprintf(bridge_error, sizeof(bridge_error), "pageSize is unavailable in a module with linked plugins");
        return ZOVA_INVALID_ARGUMENT;
    }
    zova_database_open_plugins_request request = {0};
    request.path = path;
    request.flags = flags;
    request.busy_timeout_ms = busy_timeout_ms;
    request.plugins = plugins;
    request.plugin_count = count;
    request.out_db = &db;
    request.out_error_message = &message;
    return mode == OPEN_CREATE ? zova_opfs_create_plugins(&request) :
        mode == OPEN_UPGRADE ? zova_opfs_open_upgrade_plugins(&request) : zova_opfs_open_plugins(&request);
}

/* Creates, opens, or opens for extension upgrade, as `mode` selects. */
EXPORTED int zw_open_file(int mode, uint32_t page_size, uint32_t flags, uint32_t busy_timeout_ms) {
    if (db) return ZOVA_INVALID_ARGUMENT;
    zova_message_free(&message);
    bridge_error[0] = 0;
    /* Normal open validates without migration, but permits SQLite to recover
     * an abandoned rollback journal. A preliminary read-only open blocks that
     * recovery. Clean incompatible files are still rejected without mutation. */
    int used = 0;
    int status = open_with_plugins("/db.zova", mode, page_size, flags, busy_timeout_ms, &used);
    if (used) return status;
    if (mode == OPEN_UPGRADE) {
        zova_database_open_extensions_request request = {0};
        request.path = "/db.zova";
        request.flags = flags;
        request.busy_timeout_ms = busy_timeout_ms;
        request.out_db = &db;
        request.out_error_message = &message;
        return zova_opfs_open_upgrade(&request);
    }
    if (mode == OPEN_CREATE && page_size) {
        zova_database_create_options_request request = {"/db.zova", page_size, &db, &message};
        return zova_opfs_create_options(&request);
    }
    if (mode == OPEN_EXISTING && (flags || busy_timeout_ms)) {
        zova_database_open_options_request request = {"/db.zova", flags, busy_timeout_ms, &db, &message};
        return zova_opfs_open_options(&request);
    }
    zova_database_open_request request = {"/db.zova", &db, &message};
    return mode == OPEN_EXISTING ? zova_opfs_open(&request) : zova_opfs_create(&request);
}

/* Converts an imported plain SQLite file to a new /db.zova; no database is open. */
EXPORTED int zw_convert(void) {
    if (db) return ZOVA_INVALID_ARGUMENT;
    zova_message_free(&message);
    bridge_error[0] = 0;
    zova_convert_sqlite_to_zova_request request = {"/convert-source.sqlite", "/db.zova", &message};
    return zova_opfs_convert(&request);
}

/* Maintenance calls run in a worker that holds the database's lock but has
 * no open database. Progress goes to the worker runtime, which forwards it. */
EM_JS(int, zw_progress_js, (int phase, int member, double done, double total), {
    return Module["zovaProgress"] ? Module["zovaProgress"](phase, member, done, total) : 0;
});
static int32_t report_progress(void *context, const zova_progress *progress) {
    (void)context;
    return zw_progress_js((int)progress->phase, (int)progress->member, (double)progress->done, (double)progress->total);
}
static int sqlite_failure(sqlite3 *raw, int rc) {
    snprintf(bridge_error, sizeof(bridge_error), "%s", raw ? sqlite3_errmsg(raw) : sqlite3_errstr(rc));
    return rc == SQLITE_BUSY ? ZOVA_BUSY : rc == SQLITE_CANTOPEN ? ZOVA_CANT_OPEN : ZOVA_SQLITE_ERROR;
}

/* Opening read-write rolls back a journal abandoned by a terminated writer,
 * so later read-only probes see committed state. Reports the file size
 * through zw_float. A missing file is left for the probe to report. */
static void recover_main(void) {
    sqlite3 *raw = NULL;
    if (sqlite3_open_v2("/db.zova", &raw, SQLITE_OPEN_READWRITE, NULL) == SQLITE_OK) {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(raw, "select page_count * page_size from pragma_page_count, pragma_page_size", -1, &stmt, NULL) == SQLITE_OK &&
            sqlite3_step(stmt) == SQLITE_ROW) real = (double)sqlite3_column_int64(stmt, 0);
        sqlite3_finalize(stmt);
    }
    sqlite3_close(raw);
}

/* Format of /db.zova: compatibility through zw_number, version through zw_integer. */
EXPORTED int zw_probe(void) {
    clear_output();
    zova_message_free(&message);
    recover_main();
    zova_database_format_info info = {0};
    zova_database_probe_format_request request = {"/db.zova", &info, &message};
    int status = zova_database_probe_format(&request);
    number = info.compatibility;
    integer = info.format_version;
    return status;
}

/* Copy, migrate and verify /db.zova into /migrate.zova, which must not exist. */
EXPORTED int zw_migrate_stage(int verify) {
    clear_output();
    zova_message_free(&message);
    zova_database_migrate_progress_request request = {0};
    request.source_path = "/db.zova";
    request.destination_path = "/migrate.zova";
    request.flags = verify ? 0 : ZOVA_MIGRATE_NO_VERIFY;
    request.progress = report_progress;
    request.out_error_message = &message;
    request.plugins = zova_wasm_linked_plugins(&request.plugin_count);
    return zova_database_migrate_with_progress(&request);
}

/* Replace /db.zova with the verified /migrate.zova in one SQLite write
 * transaction. The source's rollback journal makes the replacement atomic:
 * a worker stopped before the commit leaves a hot journal that the next
 * read-write open rolls back, restoring the original database. */
EXPORTED int zw_migrate_publish(void) {
    clear_output();
    sqlite3 *source = NULL;
    sqlite3 *target = NULL;
    int rc = sqlite3_open_v2("/migrate.zova", &source, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) rc = sqlite_failure(source, rc);
    else if ((rc = sqlite3_open_v2("/db.zova", &target, SQLITE_OPEN_READWRITE, NULL)) != SQLITE_OK ||
        (rc = sqlite3_exec(target, "pragma journal_mode=delete; pragma synchronous=full", NULL, NULL, NULL)) != SQLITE_OK) {
        rc = sqlite_failure(target, rc);
    } else {
        sqlite3_backup *backup = sqlite3_backup_init(target, "main", source, "main");
        if (!backup) rc = sqlite_failure(target, sqlite3_errcode(target));
        else {
            rc = sqlite3_backup_step(backup, -1);
            int finished = sqlite3_backup_finish(backup);
            rc = rc == SQLITE_DONE ? finished : rc;
            rc = rc == SQLITE_OK ? ZOVA_OK : sqlite_failure(target, rc);
        }
    }
    sqlite3_close(source);
    sqlite3_close(target);
    return rc;
}
#endif

static void clear_output(void) {
    zova_text_free(&text);
    zova_buffer_free(&buffer);
    if (out_cap > 65536) {
        free(out);
        out = NULL;
        out_cap = 0;
    }
    out_len = 0;
    out_bad = 0;
    bytes = NULL;
    length = 0;
    number = 0;
    integer = 0;
    real = 0;
#ifdef ZOVA_WASM_OPFS
    bridge_error[0] = 0;
#endif
}

EXPORTED int zw_number(void) { return number; }
EXPORTED void zw_release(void) { clear_output(); }
EXPORTED int64_t zw_integer(void) { return integer; }
EXPORTED double zw_float(void) { return real; }
EXPORTED const uint8_t *zw_bytes(void) { return bytes; }
EXPORTED size_t zw_length(void) { return length; }
EXPORTED const char *zw_error(void) {
#ifdef ZOVA_WASM_OPFS
    if (bridge_error[0]) return bridge_error;
#endif
    return db ? zova_database_last_error_message(db) : message.data;
}
EXPORTED const char *zw_status_name(int status) { return zova_status_name(status); }

EXPORTED int zw_create(uint32_t page_size) {
    if (db) return ZOVA_INVALID_ARGUMENT;
    zova_message_free(&message);
#ifdef ZOVA_WASM_OPFS
    bridge_error[0] = 0;
    int used = 0;
    int status = open_with_plugins(":memory:", OPEN_CREATE, page_size, 0, 0, &used);
    if (used) return status;
    if (page_size) {
        zova_database_create_options_request request = {":memory:", page_size, &db, &message};
        return zova_opfs_create_options(&request);
    }
#else
    if (page_size) return ZOVA_INVALID_ARGUMENT;
#endif
    zova_database_create_memory_request request = {&db, &message};
    return zova_database_create_memory(&request);
}
EXPORTED int zw_finalize(void) {
    clear_output();
    if (!statement) return ZOVA_OK;
    int status = zova_statement_finalize(statement);
    statements[current] = NULL;
    statement = NULL;
    current = -1;
    return status;
}
EXPORTED int zw_select(int handle) {
    if (handle < 0 || handle >= statement_count || !statements[handle]) return ZOVA_INVALID_ARGUMENT;
    current = handle;
    statement = statements[handle];
    return ZOVA_OK;
}
EXPORTED int zw_reset(void) {
    clear_output();
    if (!statement) return ZOVA_INVALID_ARGUMENT;
    int status = zova_statement_reset(statement);
    int cleared = zova_statement_clear_bindings(statement);
    return status == ZOVA_OK ? cleared : status;
}
EXPORTED int zw_transaction(int operation) {
    clear_output();
    zova_database_simple_request request = {db};
    switch (operation) {
        case 0: return zova_database_begin_immediate(&request);
        case 1: return zova_database_commit(&request);
        case 2: return zova_database_rollback(&request);
        case 3: return zova_database_begin(&request);
        default: return ZOVA_INVALID_ARGUMENT;
    }
}
EXPORTED int zw_close(void) {
    int status = ZOVA_OK;
    clear_output();
    for (int index = 0; index < statement_count; index++) {
        if (!statements[index]) continue;
        int finalized = zova_statement_finalize(statements[index]);
        if (status == ZOVA_OK) status = finalized;
    }
    free(statements);
    statements = NULL;
    statement_count = 0;
    for (int index = 0; index < subscription_count; index++) {
        if (subscriptions[index]) zova_subscription_close(subscriptions[index]);
    }
    free(subscriptions);
    subscriptions = NULL;
    subscription_count = 0;
    streams_close();
#ifdef ZOVA_WASM_OPFS
    fresh_end();
    export_end();
    import_end(0);
#endif
    statement = NULL;
    current = -1;
    free(out);
    out = NULL;
    out_cap = 0;
    if (db) {
        int closed = zova_database_close(db);
        if (closed == ZOVA_OK) db = NULL;
        if (status == ZOVA_OK) status = closed;
    }
    zova_message_free(&message);
    return status;
}
EXPORTED int zw_exec(const char *sql) {
    clear_output();
    zova_database_exec_request request = {db, sql};
    return zova_database_exec(&request);
}
/* Prepares into a free handle, selects it, and reports it through zw_number. */
EXPORTED int zw_prepare(const char *sql) {
    clear_output();
    statement = NULL;
    current = -1;
    int handle = 0;
    while (handle < statement_count && statements[handle]) handle++;
    if (handle == statement_count) {
        zova_statement **grown = realloc(statements, sizeof(*statements) * (size_t)(statement_count + 8));
        if (!grown) return ZOVA_OUT_OF_MEMORY;
        memset(grown + statement_count, 0, sizeof(*grown) * 8);
        statements = grown;
        statement_count += 8;
    }
    zova_statement *prepared = NULL;
    zova_database_prepare_request request = {db, sql, &prepared};
    int status = zova_database_prepare(&request);
    if (status != ZOVA_OK) return status;
    statements[handle] = prepared;
    statement = prepared;
    current = handle;
    number = handle;
    return ZOVA_OK;
}
EXPORTED int zw_bind(int index, int type, int64_t value, double floating, const uint8_t *data, size_t len) {
    switch (type) {
        case 0: {
            zova_statement_bind_null_request r = {statement, index};
            return zova_statement_bind_null(&r);
        }
        case 1: {
            zova_statement_bind_int64_request r = {statement, index, value};
            return zova_statement_bind_int64(&r);
        }
        case 2: {
            zova_statement_bind_double_request r = {statement, index, floating};
            return zova_statement_bind_double(&r);
        }
        case 3: {
            zova_statement_bind_text_request r = {statement, index, data, len};
            return zova_statement_bind_text(&r);
        }
        case 4: {
            zova_statement_bind_blob_request r = {statement, index, data, len};
            return zova_statement_bind_blob(&r);
        }
        default: return ZOVA_INVALID_ARGUMENT;
    }
}
EXPORTED int zw_step(void) {
    clear_output();
    zova_step_result result = ZOVA_STEP_DONE;
    zova_statement_step_request request = {statement, &result};
    int status = zova_statement_step(&request);
    number = result;
    return status;
}
EXPORTED int zw_count(int parameters) {
    clear_output();
    if (parameters) {
        zova_statement_parameter_count_request r = {statement, &number};
        return zova_statement_parameter_count(&r);
    }
    zova_statement_column_count_request r = {statement, &number};
    return zova_statement_column_count(&r);
}
EXPORTED int zw_name(int index) {
    clear_output();
    zova_statement_column_name_request r = {statement, index, &text};
    int status = zova_statement_column_name(&r);
    bytes = (const uint8_t *)text.data;
    length = text.len;
    return status;
}
EXPORTED int zw_column(int index) {
    clear_output();
    zova_column_type type;
    zova_statement_column_type_request r = {statement, index, &type};
    int status = zova_statement_column_type(&r);
    if (status != ZOVA_OK) return status;
    number = type;
    switch (type) {
        case ZOVA_COLUMN_INTEGER: {
            zova_statement_column_int64_request value = {statement, index, &integer};
            return zova_statement_column_int64(&value);
        }
        case ZOVA_COLUMN_FLOAT: {
            zova_statement_column_double_request value = {statement, index, &real};
            return zova_statement_column_double(&value);
        }
        case ZOVA_COLUMN_TEXT: {
            zova_statement_column_text_request value = {statement, index, &text};
            status = zova_statement_column_text(&value);
            bytes = (const uint8_t *)text.data;
            length = text.len;
            return status;
        }
        case ZOVA_COLUMN_BLOB: {
            zova_statement_column_blob_request value = {statement, index, &buffer};
            status = zova_statement_column_blob(&value);
            bytes = buffer.data;
            length = buffer.len;
            return status;
        }
        case ZOVA_COLUMN_NULL: return ZOVA_OK;
        default: return ZOVA_INVALID_ARGUMENT;
    }
}
EXPORTED int zw_kv(int operation, const uint8_t *ns, size_t ns_len, const uint8_t *key, size_t key_len, const uint8_t *value, size_t value_len) {
    clear_output();
    if (operation == 1) {
        zova_kv_put_request r = {db, {ns, ns_len}, {key, key_len}, {value, value_len}};
        return zova_kv_put(&r);
    }
    if (operation != 0 && operation != 2) return ZOVA_INVALID_ARGUMENT;
    zova_kv_get_result result = {0};
    zova_kv_get_request r = {db, {ns, ns_len}, {key, key_len}, &result};
    int status = zova_kv_get(&r);
    if (status == ZOVA_OK) {
        number = result.found;
        if (operation == 0) {
            buffer = result.value;
            result.value = (zova_buffer){0};
            bytes = buffer.data;
            length = buffer.len;
        } else {
            zova_kv_delete_request remove = {db, {ns, ns_len}, {key, key_len}};
            status = zova_kv_delete(&remove);
        }
    }
    zova_kv_get_result_free(&result);
    return status;
}

/* Object, vector and graph calls share one entry point. Requests and replies
 * are little-endian fields padded to four bytes, so typed vector data stays
 * aligned. Strings carry a trailing NUL; UINT32_MAX marks an absent one. */
typedef struct reader {
    const uint8_t *at;
    size_t left;
    int bad;
} reader;

static const uint8_t *rd_take(reader *r, size_t len) {
    size_t padded = (len + 3) & ~(size_t)3;
    if (r->bad || padded < len || padded > r->left) {
        r->bad = 1;
        return NULL;
    }
    const uint8_t *data = r->at;
    r->at += padded;
    r->left -= padded;
    return data;
}
static uint32_t rd_u32(reader *r) {
    uint32_t value = 0;
    const uint8_t *data = rd_take(r, 4);
    if (data) memcpy(&value, data, 4);
    return value;
}
static uint64_t rd_u64(reader *r) {
    uint64_t value = 0;
    const uint8_t *data = rd_take(r, 8);
    if (data) memcpy(&value, data, 8);
    return value;
}
static const char *rd_str(reader *r) {
    uint32_t len = rd_u32(r);
    if (len == UINT32_MAX) return NULL;
    const uint8_t *data = rd_take(r, (size_t)len + 1);
    if (data && (data[len] != 0 || memchr(data, 0, len))) r->bad = 1;
    return r->bad ? NULL : (const char *)data;
}
static zova_object_id rd_object_id(reader *r) {
    zova_object_id id = {{0}};
    const uint8_t *data = rd_take(r, sizeof(id.bytes));
    if (data) memcpy(id.bytes, data, sizeof(id.bytes));
    return id;
}
static zova_vector_values rd_values(reader *r) {
    zova_vector_values values = {0};
    uint32_t type = rd_u32(r);
    uint32_t count = rd_u32(r);
    size_t width = type == ZOVA_VECTOR_ELEMENT_TYPE_F32 ? 4 : type == ZOVA_VECTOR_ELEMENT_TYPE_F16 ? 2 : 1;
    if (type > ZOVA_VECTOR_ELEMENT_TYPE_I8 || count > r->left) r->bad = 1;
    const uint8_t *data = rd_take(r, (size_t)count * width);
    values.element_type = (int)type;
    values.values_len = count;
    if (type == ZOVA_VECTOR_ELEMENT_TYPE_F32) values.f32_values = (const float *)data;
    else if (type == ZOVA_VECTOR_ELEMENT_TYPE_F16) values.f16_values = (const uint16_t *)data;
    else values.i8_values = (const int8_t *)data;
    return values;
}
static zova_graph_node_input rd_node(reader *r) {
    zova_graph_node_input node = {0};
    node.graph_name = rd_str(r);
    node.node_id = rd_str(r);
    node.kind = rd_str(r);
    node.target_type = (int)rd_u32(r);
    node.target_namespace = rd_str(r);
    node.target_ref = rd_str(r);
    return node;
}
static zova_graph_edge_input rd_edge(reader *r) {
    zova_graph_edge_input edge = {0};
    edge.graph_name = rd_str(r);
    edge.from_node_id = rd_str(r);
    edge.edge_type = rd_str(r);
    edge.to_node_id = rd_str(r);
    return edge;
}
/* A counted array of at least four-byte items cannot exceed the request. */
static void *rd_array(reader *r, uint32_t count, size_t item) {
    if (r->bad || count > r->left / 4) {
        r->bad = 1;
        return NULL;
    }
    void *items = calloc(count ? count : 1, item);
    if (!items) out_bad = 1;
    return items;
}

static uint8_t *wr_reserve(size_t len) {
    size_t padded = (len + 3) & ~(size_t)3;
    if (out_bad || padded < len || padded > SIZE_MAX - out_len) {
        out_bad = 1;
        return NULL;
    }
    if (padded > out_cap - out_len) {
        size_t cap = out_cap < 256 ? 256 : out_cap;
        while (cap - out_len < padded) cap = cap > SIZE_MAX / 2 ? SIZE_MAX : cap * 2;
        uint8_t *grown = realloc(out, cap);
        if (!grown) {
            out_bad = 1;
            return NULL;
        }
        out = grown;
        out_cap = cap;
    }
    uint8_t *data = out + out_len;
    memset(data + len, 0, padded - len);
    out_len += padded;
    return data;
}
static void wr(const void *data, size_t len) {
    uint8_t *target = wr_reserve(len);
    if (target && len) memcpy(target, data, len);
}
static void wr_u32(uint32_t value) { wr(&value, 4); }
static void wr_u64(uint64_t value) { wr(&value, 8); }
static void wr_f64(double value) { wr(&value, 8); }
static void wr_blob(const void *data, size_t len) {
    if (len >= UINT32_MAX) {
        out_bad = 1;
        return;
    }
    wr_u32((uint32_t)len);
    wr(data, len);
}
static void wr_optional(const void *data, size_t len, int present) {
    if (present) wr_blob(data, len);
    else wr_u32(UINT32_MAX);
}
static void wr_collection(const zova_vector_collection_info *info) {
    wr_blob(info->name, info->name_len);
    wr_u32(info->dimensions);
    wr_u32((uint32_t)info->metric);
    wr_u32((uint32_t)info->element_type);
    wr_u64(info->vector_count);
}
static void wr_graph(const zova_graph_info *info) {
    wr_blob(info->name, info->name_len);
    wr_u64(info->node_count);
    wr_u64(info->edge_count);
}
static void wr_search(const zova_vector_search_results *results) {
    wr_u32((uint32_t)results->len);
    for (size_t index = 0; index < results->len; index++) {
        wr_blob(results->items[index].id, results->items[index].id_len);
        wr_f64(results->items[index].distance);
    }
}

#define PARSED do { if (r->bad || r->left) return ZOVA_INVALID_ARGUMENT; } while (0)

static int call_object(int op, reader *r) {
    switch (op) {
        case 1: {
            uint32_t len = rd_u32(r);
            const uint8_t *data = rd_take(r, len);
            PARSED;
            zova_object_id id;
            zova_object_put_request request = {db, data, len, &id};
            int status = zova_object_put(&request);
            if (status == ZOVA_OK) wr(id.bytes, sizeof(id.bytes));
            return status;
        }
        case 2: {
            zova_object_get_request request = {db, rd_object_id(r), &buffer};
            PARSED;
            int status = zova_object_get(&request);
            bytes = buffer.data;
            length = buffer.len;
            return status;
        }
        case 3: {
            zova_object_id id = rd_object_id(r);
            uint64_t offset = rd_u64(r);
            uint32_t size = rd_u32(r);
            PARSED;
            uint8_t *target = wr_reserve(size);
            if (!target) return ZOVA_OUT_OF_MEMORY;
            size_t copied = 0;
            zova_object_read_range_request request = {db, id, offset, target, size, &copied};
            int status = zova_object_read_range(&request);
            bytes = target;
            length = copied;
            return status;
        }
        case 4: {
            uint8_t exists = 0;
            zova_object_exists_request request = {db, rd_object_id(r), &exists};
            PARSED;
            int status = zova_object_exists(&request);
            number = exists;
            return status;
        }
        case 5: {
            uint64_t size = 0;
            zova_object_size_request request = {db, rd_object_id(r), &size};
            PARSED;
            int status = zova_object_size(&request);
            integer = (int64_t)size;
            return status;
        }
        case 6: {
            zova_object_delete_request request = {db, rd_object_id(r)};
            PARSED;
            return zova_object_delete(&request);
        }
        default: return ZOVA_INVALID_ARGUMENT;
    }
}

static int call_vector(int op, reader *r) {
    const char *name = rd_str(r);
    switch (op) {
        case 10: {
            zova_vector_collection_create_request request = {db, name, {0}};
            request.options.dimensions = rd_u32(r);
            request.options.metric = (int)rd_u32(r);
            request.options.element_type = (int)rd_u32(r);
            PARSED;
            return zova_vector_collection_create(&request);
        }
        case 11: {
            uint8_t exists = 0;
            zova_vector_collection_exists_request request = {db, name, &exists};
            PARSED;
            int status = zova_vector_collection_exists(&request);
            number = exists;
            return status;
        }
        case 12: {
            zova_vector_collection_info info = {0};
            zova_vector_collection_info_get_request request = {db, name, &info};
            PARSED;
            int status = zova_vector_collection_info_get(&request);
            if (status == ZOVA_OK) wr_collection(&info);
            zova_vector_collection_info_free(&info);
            return status;
        }
        case 13: {
            zova_vector_collection_list list = {0};
            zova_vector_collections_list_request request = {db, &list};
            if (r->bad || r->left || name) return ZOVA_INVALID_ARGUMENT;
            int status = zova_vector_collections_list(&request);
            if (status == ZOVA_OK) {
                wr_u32((uint32_t)list.len);
                for (size_t index = 0; index < list.len; index++) wr_collection(&list.items[index]);
            }
            zova_vector_collection_list_free(&list);
            return status;
        }
        case 14: {
            zova_vector_collection_delete_request request = {db, name};
            PARSED;
            return zova_vector_collection_delete(&request);
        }
        case 15: {
            uint32_t count = rd_u32(r);
            zova_vector_input *inputs = rd_array(r, count, sizeof(*inputs));
            for (uint32_t index = 0; inputs && index < count; index++) {
                inputs[index].id = rd_str(r);
                inputs[index].values = rd_values(r);
            }
            int status = ZOVA_INVALID_ARGUMENT;
            if (inputs && !r->bad && !r->left) {
                zova_vector_put_many_request request = {db, name, inputs, count};
                status = zova_vector_put_many(&request);
            }
            free(inputs);
            return status;
        }
        case 16: {
            zova_vector vector = {0};
            zova_vector_get_request request = {db, name, rd_str(r), &vector};
            PARSED;
            int status = zova_vector_get(&request);
            if (status == ZOVA_OK) {
                size_t width = vector.element_type == ZOVA_VECTOR_ELEMENT_TYPE_F32 ? 4 :
                    vector.element_type == ZOVA_VECTOR_ELEMENT_TYPE_F16 ? 2 : 1;
                const void *data = vector.element_type == ZOVA_VECTOR_ELEMENT_TYPE_F32 ? (const void *)vector.f32_values :
                    vector.element_type == ZOVA_VECTOR_ELEMENT_TYPE_F16 ? (const void *)vector.f16_values : (const void *)vector.i8_values;
                wr_blob(vector.id, vector.id_len);
                wr_u32((uint32_t)vector.element_type);
                wr_u32((uint32_t)vector.values_len);
                wr(data, vector.values_len * width);
            }
            zova_vector_free(&vector);
            return status;
        }
        case 17: {
            uint8_t exists = 0;
            zova_vector_exists_request request = {db, name, rd_str(r), &exists};
            PARSED;
            int status = zova_vector_exists(&request);
            number = exists;
            return status;
        }
        case 18: {
            zova_vector_delete_request request = {db, name, rd_str(r)};
            PARSED;
            return zova_vector_delete(&request);
        }
        case 19: {
            uint32_t count = rd_u32(r);
            const char **ids = rd_array(r, count, sizeof(*ids));
            for (uint32_t index = 0; ids && index < count; index++) ids[index] = rd_str(r);
            int status = ZOVA_INVALID_ARGUMENT;
            if (ids && !r->bad && !r->left) {
                zova_vector_delete_many_request request = {db, name, ids, count};
                status = zova_vector_delete_many(&request);
            }
            free(ids);
            return status;
        }
        case 20: {
            zova_vector_search_results results = {0};
            zova_vector_search_request request = {db, name, rd_values(r), 0, &results};
            request.limit = rd_u32(r);
            PARSED;
            int status = zova_vector_search(&request);
            if (status == ZOVA_OK) wr_search(&results);
            zova_vector_search_results_free(&results);
            return status;
        }
        case 21: {
            zova_vector_search_results results = {0};
            zova_vector_search_by_id_request request = {db, name, rd_str(r), 0, &results};
            request.limit = rd_u32(r);
            PARSED;
            int status = zova_vector_search_by_id(&request);
            if (status == ZOVA_OK) wr_search(&results);
            zova_vector_search_results_free(&results);
            return status;
        }
        case 22: case 23: {
            /* Filtered search, by query (22) or stored vector (23), choosing
             * the native variant from the candidate and distance options. */
            zova_vector_values query = {0};
            const char *source = NULL;
            if (op == 22) query = rd_values(r);
            else source = rd_str(r);
            size_t limit = rd_u32(r);
            uint32_t has_candidates = rd_u32(r);
            uint32_t count = has_candidates ? rd_u32(r) : 0;
            const char **ids = has_candidates ? rd_array(r, count, sizeof(*ids)) : NULL;
            for (uint32_t index = 0; ids && index < count; index++) {
                ids[index] = rd_str(r);
                if (!ids[index]) r->bad = 1;
            }
            uint32_t has_max = rd_u32(r);
            double max = 0;
            if (has_max) {
                const uint8_t *data = rd_take(r, 8);
                if (data) memcpy(&max, data, 8);
            }
            int status = ZOVA_INVALID_ARGUMENT;
            zova_vector_search_results results = {0};
            if (!r->bad && !r->left && (!has_candidates || ids)) {
                if (op == 22 && !has_candidates && !has_max) {
                    zova_vector_search_request request = {db, name, query, limit, &results};
                    status = zova_vector_search(&request);
                } else if (op == 22 && !has_max) {
                    zova_vector_search_in_request request = {db, name, query, ids, count, limit, &results};
                    status = zova_vector_search_in(&request);
                } else if (op == 22 && !has_candidates) {
                    zova_vector_search_within_request request = {db, name, query, max, limit, &results};
                    status = zova_vector_search_within(&request);
                } else if (op == 22) {
                    zova_vector_search_in_within_request request = {db, name, query, ids, count, max, limit, &results};
                    status = zova_vector_search_in_within(&request);
                } else if (!has_candidates && !has_max) {
                    zova_vector_search_by_id_request request = {db, name, source, limit, &results};
                    status = zova_vector_search_by_id(&request);
                } else if (!has_max) {
                    zova_vector_search_by_id_in_request request = {db, name, source, ids, count, limit, &results};
                    status = zova_vector_search_by_id_in(&request);
                } else if (!has_candidates) {
                    zova_vector_search_by_id_within_request request = {db, name, source, max, limit, &results};
                    status = zova_vector_search_by_id_within(&request);
                } else {
                    zova_vector_search_by_id_in_within_request request = {db, name, source, ids, count, max, limit, &results};
                    status = zova_vector_search_by_id_in_within(&request);
                }
            }
            if (status == ZOVA_OK) wr_search(&results);
            zova_vector_search_results_free(&results);
            free(ids);
            return status;
        }
        default: return ZOVA_INVALID_ARGUMENT;
    }
}

static int call_graph(int op, reader *r) {
    switch (op) {
        case 30: {
            zova_graph_create_request request = {db, rd_str(r)};
            PARSED;
            return zova_graph_create(&request);
        }
        case 31: {
            uint8_t exists = 0;
            zova_graph_exists_request request = {db, rd_str(r), &exists};
            PARSED;
            int status = zova_graph_exists(&request);
            number = exists;
            return status;
        }
        case 32: {
            zova_graph_info info = {0};
            zova_graph_info_get_request request = {db, rd_str(r), &info};
            PARSED;
            int status = zova_graph_info_get(&request);
            if (status == ZOVA_OK) wr_graph(&info);
            zova_graph_info_free(&info);
            return status;
        }
        case 33: {
            zova_graph_list list = {0};
            zova_graph_list_request request = {db, &list};
            PARSED;
            int status = zova_graphs_list(&request);
            if (status == ZOVA_OK) {
                wr_u32((uint32_t)list.len);
                for (size_t index = 0; index < list.len; index++) wr_graph(&list.items[index]);
            }
            zova_graph_list_free(&list);
            return status;
        }
        case 34: {
            zova_graph_delete_request request = {db, rd_str(r)};
            PARSED;
            return zova_graph_delete(&request);
        }
        case 35: {
            uint32_t count = rd_u32(r);
            zova_graph_node_input *nodes = rd_array(r, count, sizeof(*nodes));
            for (uint32_t index = 0; nodes && index < count; index++) nodes[index] = rd_node(r);
            int status = ZOVA_INVALID_ARGUMENT;
            if (nodes && !r->bad && !r->left) {
                zova_graph_node_put_many_request request = {db, nodes, count};
                status = zova_graph_node_put_many(&request);
            }
            free(nodes);
            return status;
        }
        case 36: {
            zova_graph_node node = {0};
            const char *graph = rd_str(r);
            zova_graph_node_get_request request = {db, graph, rd_str(r), &node};
            PARSED;
            int status = zova_graph_node_get(&request);
            if (status == ZOVA_OK) {
                wr_blob(node.graph_name, node.graph_name_len);
                wr_blob(node.node_id, node.node_id_len);
                wr_blob(node.kind, node.kind_len);
                wr_u32((uint32_t)node.target_type);
                wr_optional(node.target_namespace, node.target_namespace_len, node.has_target_namespace);
                wr_optional(node.target_ref, node.target_ref_len, node.has_target_ref);
            }
            zova_graph_node_free(&node);
            return status;
        }
        case 37: {
            uint8_t exists = 0;
            const char *graph = rd_str(r);
            zova_graph_node_exists_request request = {db, graph, rd_str(r), &exists};
            PARSED;
            int status = zova_graph_node_exists(&request);
            number = exists;
            return status;
        }
        case 38: {
            const char *graph = rd_str(r);
            zova_graph_node_delete_request request = {db, graph, rd_str(r)};
            PARSED;
            return zova_graph_node_delete(&request);
        }
        case 39: {
            const char *graph = rd_str(r);
            uint32_t count = rd_u32(r);
            const char **ids = rd_array(r, count, sizeof(*ids));
            for (uint32_t index = 0; ids && index < count; index++) ids[index] = rd_str(r);
            int status = ZOVA_INVALID_ARGUMENT;
            if (ids && !r->bad && !r->left) {
                zova_graph_node_delete_many_request request = {db, graph, ids, count};
                status = zova_graph_node_delete_many(&request);
            }
            free(ids);
            return status;
        }
        case 40: case 41: {
            uint32_t count = rd_u32(r);
            zova_graph_edge_input *edges = rd_array(r, count, sizeof(*edges));
            for (uint32_t index = 0; edges && index < count; index++) edges[index] = rd_edge(r);
            int status = ZOVA_INVALID_ARGUMENT;
            if (edges && !r->bad && !r->left) {
                if (op == 40) {
                    zova_graph_edge_put_many_request request = {db, edges, count};
                    status = zova_graph_edge_put_many(&request);
                } else {
                    zova_graph_edge_delete_many_request request = {db, edges, count};
                    status = zova_graph_edge_delete_many(&request);
                }
            }
            free(edges);
            return status;
        }
        case 42: {
            zova_graph_edge found = {0};
            zova_graph_edge_input edge = rd_edge(r);
            zova_graph_edge_get_request request = {db, edge.graph_name, edge.from_node_id, edge.edge_type, edge.to_node_id, &found};
            PARSED;
            int status = zova_graph_edge_get(&request);
            zova_graph_edge_free(&found);
            return status;
        }
        case 43: {
            uint8_t exists = 0;
            zova_graph_edge_input edge = rd_edge(r);
            zova_graph_edge_exists_request request = {db, edge.graph_name, edge.from_node_id, edge.edge_type, edge.to_node_id, &exists};
            PARSED;
            int status = zova_graph_edge_exists(&request);
            number = exists;
            return status;
        }
        case 44: {
            zova_graph_edge_input edge = rd_edge(r);
            zova_graph_edge_delete_request request = {db, edge.graph_name, edge.from_node_id, edge.edge_type, edge.to_node_id};
            PARSED;
            return zova_graph_edge_delete(&request);
        }
        case 45: {
            zova_graph_neighbor_results results = {0};
            zova_graph_neighbors_request request = {db, NULL, NULL, 0, NULL, 0, &results};
            request.graph_name = rd_str(r);
            request.node_id = rd_str(r);
            request.direction = (int)rd_u32(r);
            request.edge_type = rd_str(r);
            request.limit = rd_u32(r);
            PARSED;
            int status = zova_graph_neighbors(&request);
            if (status == ZOVA_OK) {
                wr_u32((uint32_t)results.len);
                for (size_t index = 0; index < results.len; index++) {
                    const zova_graph_neighbor_result *item = &results.items[index];
                    wr_blob(item->node_id, item->node_id_len);
                    wr_blob(item->kind, item->kind_len);
                    wr_blob(item->edge_type, item->edge_type_len);
                }
            }
            zova_graph_neighbor_results_free(&results);
            return status;
        }
        case 46: {
            uint64_t degree = 0;
            zova_graph_degree_request request = {db, NULL, NULL, 0, NULL, &degree};
            request.graph_name = rd_str(r);
            request.node_id = rd_str(r);
            request.direction = (int)rd_u32(r);
            request.edge_type = rd_str(r);
            PARSED;
            int status = zova_graph_degree(&request);
            integer = (int64_t)degree;
            return status;
        }
        case 47: {
            zova_graph_walk_results results = {0};
            zova_graph_walk_direction_request request = {db, NULL, NULL, 0, NULL, 0, 0, &results};
            request.graph_name = rd_str(r);
            request.start_node_id = rd_str(r);
            request.direction = (int)rd_u32(r);
            request.edge_type = rd_str(r);
            request.max_depth = rd_u32(r);
            request.limit = rd_u32(r);
            PARSED;
            int status = zova_graph_walk_direction(&request);
            if (status == ZOVA_OK) {
                wr_u32((uint32_t)results.len);
                for (size_t index = 0; index < results.len; index++) {
                    const zova_graph_walk_result *item = &results.items[index];
                    wr_blob(item->node_id, item->node_id_len);
                    wr_blob(item->kind, item->kind_len);
                    wr_u32(item->depth);
                    wr_optional(item->predecessor_node_id, item->predecessor_node_id_len, item->has_predecessor_node_id);
                    wr_optional(item->edge_type, item->edge_type_len, item->has_edge_type);
                }
            }
            zova_graph_walk_results_free(&results);
            return status;
        }
        default: return ZOVA_INVALID_ARGUMENT;
    }
}

static zova_kv_bytes rd_bytes(reader *r) {
    uint32_t len = rd_u32(r);
    zova_kv_bytes value = {rd_take(r, len), len};
    return value;
}
static int simple_status(int status, int64_t value) {
    integer = value;
    return status;
}

/* Transactions, connection state, KV batches, notifications and statement
 * controls. Statement calls act on the statement selected by zw_select. */
static int call_database(int op, reader *r) {
    switch (op) {
        case 50: {
            zova_kv_bytes ns = rd_bytes(r);
            uint32_t count = rd_u32(r);
            zova_kv_bytes *keys = rd_array(r, count, sizeof(*keys));
            for (uint32_t index = 0; keys && index < count; index++) keys[index] = rd_bytes(r);
            int status = ZOVA_INVALID_ARGUMENT;
            if (keys && !r->bad && !r->left) {
                zova_kv_get_many_results results = {0};
                zova_kv_get_many_request request = {db, ns, keys, count, &results};
                status = zova_kv_get_many(&request);
                if (status == ZOVA_OK) {
                    wr_u32((uint32_t)results.len);
                    for (size_t index = 0; index < results.len; index++) {
                        wr_u32(results.items[index].found);
                        if (results.items[index].found) wr_blob(results.items[index].value.data, results.items[index].value.len);
                    }
                }
                zova_kv_get_many_results_free(&results);
            }
            free(keys);
            return status;
        }
        case 51: {
            zova_kv_bytes ns = rd_bytes(r);
            uint32_t count = rd_u32(r);
            zova_kv_put_entry *entries = rd_array(r, count, sizeof(*entries));
            for (uint32_t index = 0; entries && index < count; index++) {
                entries[index].key = rd_bytes(r);
                entries[index].value = rd_bytes(r);
            }
            int status = ZOVA_INVALID_ARGUMENT;
            if (entries && !r->bad && !r->left) {
                zova_kv_put_many_request request = {db, ns, entries, count};
                status = zova_kv_put_many(&request);
            }
            free(entries);
            return status;
        }
        case 52: {
            zova_kv_bytes ns = rd_bytes(r);
            uint32_t count = rd_u32(r);
            zova_kv_bytes *keys = rd_array(r, count, sizeof(*keys));
            for (uint32_t index = 0; keys && index < count; index++) keys[index] = rd_bytes(r);
            int status = ZOVA_INVALID_ARGUMENT;
            if (keys && !r->bad && !r->left) {
                zova_kv_delete_many_request request = {db, ns, keys, count};
                status = zova_kv_delete_many(&request);
            }
            free(keys);
            return status;
        }
        case 53: {
            uint64_t count = 0;
            zova_kv_count_request request = {db, rd_bytes(r), &count};
            PARSED;
            return simple_status(zova_kv_count(&request), (int64_t)count);
        }
        case 54: {
            zova_kv_clear_namespace_request request = {db, rd_bytes(r)};
            PARSED;
            return zova_kv_clear_namespace(&request);
        }
        case 55: case 56: case 57: {
            zova_database_savepoint_request request = {db, rd_str(r)};
            PARSED;
            return op == 55 ? zova_database_savepoint(&request) :
                op == 56 ? zova_database_release_savepoint(&request) : zova_database_rollback_to_savepoint(&request);
        }
        case 58: case 59: case 60: {
            int64_t value = 0;
            PARSED;
            if (op == 58) {
                zova_database_changes_request request = {db, &value};
                return simple_status(zova_database_changes(&request), value);
            }
            if (op == 59) {
                zova_database_total_changes_request request = {db, &value};
                return simple_status(zova_database_total_changes(&request), value);
            }
            zova_database_last_insert_rowid_request request = {db, &value};
            return simple_status(zova_database_last_insert_rowid(&request), value);
        }
        case 61: {
            zova_database_busy_timeout_request request = {db, rd_u32(r)};
            PARSED;
            return zova_database_set_busy_timeout(&request);
        }
        case 62: {
            const char *channel = rd_str(r);
            zova_kv_bytes payload = rd_bytes(r);
            PARSED;
            zova_database_notify_request request = {db, channel, payload.data, payload.len};
            return zova_database_notify(&request);
        }
        case 63: {
            const char *channel = rd_str(r);
            PARSED;
            int handle = 0;
            while (handle < subscription_count && subscriptions[handle]) handle++;
            if (handle == subscription_count) {
                zova_subscription **grown = realloc(subscriptions, sizeof(*subscriptions) * (size_t)(subscription_count + 8));
                if (!grown) return ZOVA_OUT_OF_MEMORY;
                memset(grown + subscription_count, 0, sizeof(*grown) * 8);
                subscriptions = grown;
                subscription_count += 8;
            }
            zova_database_listen_request request = {db, channel, &subscriptions[handle]};
            number = handle;
            return zova_database_listen(&request);
        }
        case 64: case 65: {
            uint32_t handle = rd_u32(r);
            PARSED;
            if (handle >= (uint32_t)subscription_count || !subscriptions[handle]) return ZOVA_INVALID_ARGUMENT;
            if (op == 65) {
                int status = zova_subscription_close(subscriptions[handle]);
                subscriptions[handle] = NULL;
                return status;
            }
            zova_notification notification = {0};
            uint8_t has = 0;
            zova_subscription_try_receive_request request = {subscriptions[handle], &notification, &has};
            int status = zova_subscription_try_receive(&request);
            if (status == ZOVA_OK) {
                wr_u32(has);
                if (has) {
                    wr_blob(notification.channel, notification.channel_len);
                    wr_blob(notification.payload, notification.payload_len);
                    wr_u64(notification.sequence);
                    wr_u64(notification.dropped_before);
                }
            }
            zova_notification_free(&notification);
            return status;
        }
        case 66: {
            const char *name = rd_str(r);
            PARSED;
            zova_statement_parameter_index_request request = {statement, name, &number};
            return zova_statement_parameter_index(&request);
        }
        case 67: PARSED; return statement ? zova_statement_reset(statement) : ZOVA_INVALID_ARGUMENT;
        case 68: PARSED; return statement ? zova_statement_clear_bindings(statement) : ZOVA_INVALID_ARGUMENT;
        default: return ZOVA_INVALID_ARGUMENT;
    }
}

/* Object writers and readers by handle. */
enum { STREAM_WRITER = 1, STREAM_READER = 2, STREAM_SEEKABLE = 3 };
typedef struct stream_slot {
    int kind;
    void *handle;
} stream_slot;
static stream_slot *streams;
static int stream_count;

static int stream_add(int kind, void *handle) {
    int index = 0;
    while (index < stream_count && streams[index].kind) index++;
    if (index == stream_count) {
        stream_slot *grown = realloc(streams, sizeof(*streams) * (size_t)(stream_count + 8));
        if (!grown) return -1;
        memset(grown + stream_count, 0, sizeof(*grown) * 8);
        streams = grown;
        stream_count += 8;
    }
    streams[index].kind = kind;
    streams[index].handle = handle;
    return index;
}
static void *stream_get(uint32_t index, int kind) {
    return index < (uint32_t)stream_count && streams[index].kind == kind ? streams[index].handle : NULL;
}
static void stream_destroy(uint32_t index) {
    if (index >= (uint32_t)stream_count || !streams[index].kind) return;
    void *handle = streams[index].handle;
    if (streams[index].kind == STREAM_WRITER) zova_object_writer_destroy(handle);
    else if (streams[index].kind == STREAM_READER) {
        zova_object_reader *reader = handle;
        zova_object_reader_destroy_request request = {&reader};
        zova_object_reader_destroy(&request);
    } else {
        zova_object_seekable_reader *reader = handle;
        zova_object_seekable_reader_destroy_request request = {&reader};
        zova_object_seekable_reader_destroy(&request);
    }
    streams[index].kind = 0;
    streams[index].handle = NULL;
}
static void streams_close(void) {
    for (int index = 0; index < stream_count; index++) stream_destroy((uint32_t)index);
    free(streams);
    streams = NULL;
    stream_count = 0;
}
/* UINT32_MAX selects the default profile, as the calls without options. */
static int rd_profile(reader *r, zova_object_put_options *options) {
    uint32_t profile = rd_u32(r);
    options->profile = (int)profile;
    return profile != UINT32_MAX;
}
static zova_object_chunk_id rd_chunk_id(reader *r) {
    zova_object_chunk_id id = {{0}};
    const uint8_t *data = rd_take(r, sizeof(id.bytes));
    if (data) memcpy(id.bytes, data, sizeof(id.bytes));
    return id;
}
/* Reads up to `size` bytes into the reply; `seekable` selects the reader type. */
static int read_stream(void *handle, int seekable, uint32_t size) {
    uint8_t *target = wr_reserve(size);
    if (!target) return ZOVA_OUT_OF_MEMORY;
    size_t read = 0;
    int status;
    if (seekable) {
        zova_object_seekable_reader_read_request request = {handle, target, size, &read};
        status = zova_object_seekable_reader_read(&request);
    } else {
        zova_object_reader_read_request request = {handle, target, size, &read};
        status = zova_object_reader_read(&request);
    }
    bytes = target;
    length = read;
    return status;
}

static int call_object_stream(int op, reader *r) {
    switch (op) {
        case 70: {
            zova_object_put_options options = {0};
            int explicit_profile = rd_profile(r, &options);
            PARSED;
            zova_object_writer *writer = NULL;
            int status;
            if (explicit_profile) {
                zova_object_writer_create_with_options_request request = {db, options, &writer};
                status = zova_object_writer_create_with_options(&request);
            } else {
                zova_object_writer_create_request request = {db, &writer};
                status = zova_object_writer_create(&request);
            }
            if (status != ZOVA_OK) return status;
            number = stream_add(STREAM_WRITER, writer);
            if (number < 0) {
                zova_object_writer_destroy(writer);
                return ZOVA_OUT_OF_MEMORY;
            }
            return ZOVA_OK;
        }
        case 71: {
            zova_object_writer *writer = stream_get(rd_u32(r), STREAM_WRITER);
            zova_kv_bytes data = rd_bytes(r);
            PARSED;
            if (!writer) return ZOVA_OBJECT_WRITER_CLOSED;
            zova_object_writer_write_request request = {writer, data.data, data.len};
            return zova_object_writer_write(&request);
        }
        case 72: case 73: {
            uint32_t handle = rd_u32(r);
            PARSED;
            zova_object_writer *writer = stream_get(handle, STREAM_WRITER);
            if (!writer) return ZOVA_OBJECT_WRITER_CLOSED;
            int status;
            if (op == 72) {
                zova_object_id id;
                zova_object_writer_finish_request request = {writer, &id};
                status = zova_object_writer_finish(&request);
                if (status == ZOVA_OK) wr(id.bytes, sizeof(id.bytes));
            } else {
                zova_object_writer_cancel_request request = {writer};
                status = zova_object_writer_cancel(&request);
            }
            stream_destroy(handle);
            return status;
        }
        case 74: case 76: {
            zova_object_id id = rd_object_id(r);
            PARSED;
            int status;
            void *handle = NULL;
            uint64_t size = 0;
            if (op == 74) {
                zova_object_reader_create_request request = {db, id, (zova_object_reader **)&handle};
                status = zova_object_reader_create(&request);
            } else {
                zova_object_seekable_reader_create_request request = {db, id, (zova_object_seekable_reader **)&handle, &size};
                status = zova_object_seekable_reader_create(&request);
            }
            if (status != ZOVA_OK) return status;
            number = stream_add(op == 74 ? STREAM_READER : STREAM_SEEKABLE, handle);
            integer = (int64_t)size;
            if (number >= 0) return ZOVA_OK;
            if (op == 74) {
                zova_object_reader_destroy_request destroy = {(zova_object_reader **)&handle};
                zova_object_reader_destroy(&destroy);
            } else {
                zova_object_seekable_reader_destroy_request destroy = {(zova_object_seekable_reader **)&handle};
                zova_object_seekable_reader_destroy(&destroy);
            }
            return ZOVA_OUT_OF_MEMORY;
        }
        case 75: case 77: {
            void *handle = stream_get(rd_u32(r), op == 75 ? STREAM_READER : STREAM_SEEKABLE);
            uint32_t size = rd_u32(r);
            PARSED;
            if (!handle) return ZOVA_OBJECT_READER_CLOSED;
            return read_stream(handle, op == 77, size);
        }
        case 78: {
            zova_object_seekable_reader *reader = stream_get(rd_u32(r), STREAM_SEEKABLE);
            uint64_t offset = rd_u64(r);
            PARSED;
            if (!reader) return ZOVA_OBJECT_READER_CLOSED;
            zova_object_seekable_reader_seek_request request = {reader, offset};
            return zova_object_seekable_reader_seek(&request);
        }
        case 79: {
            uint32_t handle = rd_u32(r);
            PARSED;
            stream_destroy(handle);
            return ZOVA_OK;
        }
        case 80: {
            zova_object_chunk_id hash = rd_chunk_id(r);
            zova_kv_bytes data = rd_bytes(r);
            zova_object_put_options options = {0};
            int explicit_profile = rd_profile(r, &options);
            PARSED;
            if (explicit_profile) {
                zova_object_chunk_put_with_options_request request = {db, hash, data.data, data.len, options};
                return zova_object_chunk_put_with_options(&request);
            }
            zova_object_chunk_put_request request = {db, hash, data.data, data.len};
            return zova_object_chunk_put(&request);
        }
        case 81: case 82: {
            zova_object_chunk_get_request request = {db, rd_chunk_id(r), &buffer};
            PARSED;
            int status = zova_object_chunk_get(&request);
            if (op == 82) {
                zova_buffer_free(&buffer);
                if (status == ZOVA_OBJECT_CHUNK_NOT_FOUND) return ZOVA_OK;
                number = status == ZOVA_OK;
                return status;
            }
            bytes = buffer.data;
            length = buffer.len;
            return status;
        }
        case 83: {
            uint8_t deleted = 0;
            zova_object_chunk_delete_request request = {db, rd_chunk_id(r), &deleted};
            PARSED;
            int status = zova_object_chunk_delete(&request);
            number = deleted;
            return status;
        }
        case 84: {
            uint64_t count = 0;
            zova_object_chunk_count_request request = {db, rd_object_id(r), &count};
            PARSED;
            return simple_status(zova_object_chunk_count(&request), (int64_t)count);
        }
        case 85: {
            zova_object_manifest manifest = {0};
            zova_object_manifest_get_request request = {db, rd_object_id(r), &manifest};
            PARSED;
            int status = zova_object_manifest_get(&request);
            if (status == ZOVA_OK) {
                wr(manifest.object_id.bytes, sizeof(manifest.object_id.bytes));
                wr_u64(manifest.size_bytes);
                wr_u64(manifest.chunk_count);
                wr_blob(manifest.chunker, strlen(manifest.chunker));
                wr_u32((uint32_t)manifest.chunks_len);
                for (size_t index = 0; index < manifest.chunks_len; index++) {
                    const zova_object_manifest_chunk *chunk = &manifest.chunks[index];
                    wr_u64(chunk->index);
                    wr(chunk->hash.bytes, sizeof(chunk->hash.bytes));
                    wr_u64(chunk->offset);
                    wr_u64(chunk->size_bytes);
                }
            }
            zova_object_manifest_free(&manifest);
            return status;
        }
        case 86: {
            zova_object_id id = rd_object_id(r);
            uint64_t size = rd_u64(r);
            zova_object_put_options options = {0};
            int explicit_profile = rd_profile(r, &options);
            uint32_t count = rd_u32(r);
            zova_object_manifest_chunk *chunks = rd_array(r, count, sizeof(*chunks));
            for (uint32_t index = 0; chunks && index < count; index++) {
                chunks[index].index = rd_u64(r);
                chunks[index].hash = rd_chunk_id(r);
                chunks[index].offset = rd_u64(r);
                chunks[index].size_bytes = rd_u64(r);
            }
            int status = ZOVA_INVALID_ARGUMENT;
            if (chunks && !r->bad && !r->left) {
                if (explicit_profile) {
                    zova_object_assemble_from_chunks_with_options_request request = {db, id, size, chunks, count, options};
                    status = zova_object_assemble_from_chunks_with_options(&request);
                } else {
                    zova_object_assemble_from_chunks_request request = {db, id, size, chunks, count};
                    status = zova_object_assemble_from_chunks(&request);
                }
            }
            free(chunks);
            return status;
        }
        case 87: {
            zova_kv_bytes data = rd_bytes(r);
            zova_object_put_options options = {0};
            rd_profile(r, &options);
            PARSED;
            zova_object_id id;
            zova_object_put_with_options_request request = {db, data.data, data.len, options, &id};
            int status = zova_object_put_with_options(&request);
            if (status == ZOVA_OK) wr(id.bytes, sizeof(id.bytes));
            return status;
        }
        case 88: case 89: {
            zova_kv_bytes data = rd_bytes(r);
            PARSED;
            zova_object_id id;
            int status = op == 88 ? zova_object_id_from_bytes(data.data, data.len, &id)
                : zova_object_chunk_id_from_bytes(data.data, data.len, (zova_object_chunk_id *)&id);
            if (status == ZOVA_OK) wr(id.bytes, sizeof(id.bytes));
            return status;
        }
        default: return ZOVA_INVALID_ARGUMENT;
    }
}

#ifdef ZOVA_WASM_OPFS
/* Browser-private exports of the core (src/c_api.zig), not C ABI. */
extern void *zova_wasm_sqlite_handle(zova_database *database);
extern zova_status zova_wasm_verify_copy(const char *path, const struct zova_plugin_descriptor_v1 *const *plugins,
    size_t plugin_count, zova_message *out_error_message);

/* Whole-database export in bounded reads: the stored file, read through the
 * connection's own file handle while the caller holds the database, or a
 * serialized copy of a memory database. */
static sqlite3_file *export_file;
static unsigned char *export_memory;
static sqlite3_int64 export_size;

static void export_end(void) {
    sqlite3_free(export_memory);
    export_memory = NULL;
    export_file = NULL;
    export_size = 0;
}
static int export_begin(reader *r) {
    PARSED;
    export_end();
    sqlite3 *raw = zova_wasm_sqlite_handle(db);
    if (!raw) return ZOVA_MISUSE;
    if (sqlite3_txn_state(raw, NULL) != SQLITE_TXN_NONE) {
        snprintf(bridge_error, sizeof(bridge_error), "Export rejects while a transaction is open");
        return ZOVA_MISUSE;
    }
    sqlite3_file *file = NULL;
    if (sqlite3_file_control(raw, "main", SQLITE_FCNTL_FILE_POINTER, &file) == SQLITE_OK && file && file->pMethods) {
        if (file->pMethods->xFileSize(file, &export_size) != SQLITE_OK) return sqlite_failure(NULL, SQLITE_IOERR);
        export_file = file;
    } else {
        export_memory = sqlite3_serialize(raw, "main", &export_size, 0);
        if (!export_memory) return ZOVA_OUT_OF_MEMORY;
    }
    integer = export_size;
    return ZOVA_OK;
}
static int export_read(uint64_t offset, uint32_t size) {
    if (!export_file && !export_memory) return ZOVA_MISUSE;
    if (offset >= (uint64_t)export_size) size = 0;
    else if ((uint64_t)size > (uint64_t)export_size - offset) size = (uint32_t)((uint64_t)export_size - offset);
    uint8_t *target = wr_reserve(size);
    if (!target) return ZOVA_OUT_OF_MEMORY;
    if (export_memory) memcpy(target, export_memory + offset, size);
    else if (size && export_file->pMethods->xRead(export_file, target, (int)size, (sqlite3_int64)offset) != SQLITE_OK) {
        return sqlite_failure(NULL, SQLITE_IOERR);
    }
    bytes = target;
    length = size;
    return ZOVA_OK;
}

/* Streamed import: chunks are written in order straight into /db.zova, or
 * the conversion source, of the default VFS, which must not exist; the
 * caller converts, verifies and opens it. SQLite keeps the name until close. */
static const char convert_source[] = "/convert-source.sqlite";
static sqlite3_file *import_file;
static sqlite3_int64 import_offset;

static int import_end(int commit) {
    if (!import_file) return commit ? ZOVA_MISUSE : ZOVA_OK;
    int rc = commit ? import_file->pMethods->xSync(import_file, SQLITE_SYNC_FULL) : SQLITE_OK;
    import_file->pMethods->xClose(import_file);
    sqlite3_free(import_file);
    import_file = NULL;
    import_offset = 0;
    return rc == SQLITE_OK ? ZOVA_OK : sqlite_failure(NULL, rc);
}
static int import_begin(const char *path) {
    if (import_file || db) return ZOVA_MISUSE;
    sqlite3_vfs *vfs = sqlite3_vfs_find(NULL);
    if (!vfs) return ZOVA_CANT_OPEN;
    import_file = sqlite3_malloc(vfs->szOsFile);
    if (!import_file) return ZOVA_OUT_OF_MEMORY;
    memset(import_file, 0, (size_t)vfs->szOsFile);
    int flags = 0;
    int rc = vfs->xOpen(vfs, path, import_file, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_MAIN_DB, &flags);
    if (rc != SQLITE_OK) {
        sqlite3_free(import_file);
        import_file = NULL;
        return sqlite_failure(NULL, rc);
    }
    import_offset = 0;
    return ZOVA_OK;
}
static int import_write(const uint8_t *data, size_t len) {
    if (!import_file) return ZOVA_MISUSE;
    if (len > INT32_MAX) return ZOVA_INVALID_ARGUMENT;
    int rc = len ? import_file->pMethods->xWrite(import_file, data, (int)len, import_offset) : SQLITE_OK;
    if (rc != SQLITE_OK) return sqlite_failure(NULL, rc);
    import_offset += (sqlite3_int64)len;
    return ZOVA_OK;
}

static void wr_extension(const zova_extension_info *info) {
    wr_blob(info->name, info->name_len);
    wr_blob(info->version, info->version_len);
    wr_blob(info->storage_prefix, info->storage_prefix_len);
    wr_blob(info->zova_abi_min, info->zova_abi_min_len);
    wr_blob(info->capabilities, info->capabilities_len);
    wr_u32(info->required);
    wr_u64((uint64_t)info->installed_at_unix);
    wr_blob(info->manifest_json, info->manifest_json_len);
}

/* Vacuum, reclaim, verified copies and their publication into another pool. */
static int call_maintenance(int op, reader *r) {
    switch (op) {
        case 90: {
            PARSED;
            zova_database_simple_request request = {db};
            return zova_database_vacuum(&request);
        }
        case 91: {
            zova_reclaim_result result = {0};
            uint64_t max_pages = rd_u64(r);
            uint32_t step_pages = rd_u32(r);
            PARSED;
            zova_database_reclaim_request request = {db, max_pages, step_pages, &result};
            int status = zova_database_reclaim(&request);
            if (status == ZOVA_OK) {
                wr_u32((uint32_t)result.member_count);
                for (size_t index = 0; index < result.member_count; index++) {
                    const zova_reclaimed_member *member = &result.members[index];
                    wr_u32(member->member);
                    wr_u32(member->auto_vacuum);
                    wr_u32(member->page_size);
                    wr_u64(member->pages_released);
                    wr_u64(member->free_pages_left);
                }
            }
            return status;
        }
        case 92: {
            /* Verified backup (0) or compact (1) copy into a new path of the open pool. */
            const char *path = rd_str(r);
            uint32_t compact = rd_u32(r);
            uint32_t verify = rd_u32(r);
            PARSED;
            if (compact) {
                zova_database_compact_progress_request request = {db, path, verify ? 0 : ZOVA_COMPACT_NO_VERIFY, report_progress, NULL};
                return zova_database_compact_with_progress(&request);
            }
            zova_database_backup_progress_request request = {db, path, verify ? 0 : ZOVA_BACKUP_NO_VERIFY, report_progress, NULL};
            return zova_database_backup_with_progress(&request);
        }
        case 93: {
            /* Copies a closed database file of the default VFS to /db.zova of
             * the named VFS in one SQLite write transaction. */
            const char *source_path = rd_str(r);
            const char *vfs = rd_str(r);
            PARSED;
            sqlite3 *source = NULL;
            sqlite3 *target = NULL;
            int rc = sqlite3_open_v2(source_path, &source, SQLITE_OPEN_READONLY, NULL);
            if (rc != SQLITE_OK) rc = sqlite_failure(source, rc);
            else if ((rc = sqlite3_open_v2("/db.zova", &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, vfs)) != SQLITE_OK ||
                (rc = sqlite3_exec(target, "pragma journal_mode=delete; pragma synchronous=full", NULL, NULL, NULL)) != SQLITE_OK) {
                rc = sqlite_failure(target, rc);
            } else {
                sqlite3_backup *backup = sqlite3_backup_init(target, "main", source, "main");
                if (!backup) rc = sqlite_failure(target, sqlite3_errcode(target));
                else {
                    rc = sqlite3_backup_step(backup, -1);
                    int finished = sqlite3_backup_finish(backup);
                    rc = rc == SQLITE_DONE ? finished : rc;
                    rc = rc == SQLITE_OK ? ZOVA_OK : sqlite_failure(target, rc);
                }
            }
            sqlite3_close(source);
            sqlite3_close(target);
            return rc;
        }
        case 94: {
            const char *source_path = rd_str(r);
            uint32_t verify = rd_u32(r);
            PARSED;
            if (db) return ZOVA_INVALID_ARGUMENT;
            zova_message_free(&message);
            zova_database_restore_to_memory_request request = {source_path, verify ? 0 : ZOVA_RESTORE_NO_VERIFY, &db, &message};
            return zova_database_restore_to_memory(&request);
        }
        case 95: return export_begin(r);
        case 96: {
            uint64_t offset = rd_u64(r);
            uint32_t size = rd_u32(r);
            PARSED;
            return export_read(offset, size);
        }
        case 97: PARSED; export_end(); return ZOVA_OK;
        case 98: {
            uint32_t convert = rd_u32(r);
            PARSED;
            return import_begin(convert ? convert_source : "/db.zova");
        }
        case 99: {
            zova_kv_bytes data = rd_bytes(r);
            PARSED;
            return import_write(data.data, data.len);
        }
        case 100: {
            uint32_t commit = rd_u32(r);
            PARSED;
            return import_end(commit);
        }
        case 101: {
            PARSED;
            zova_message_free(&message);
            size_t count = 0;
            const struct zova_plugin_descriptor_v1 *const *plugins = zova_wasm_linked_plugins(&count);
            return zova_wasm_verify_copy("/db.zova", plugins, count, &message);
        }
        case 102: case 103: case 106: {
            /* Install, drop or check one extension. */
            zova_database_extension_request request = {db, rd_str(r)};
            PARSED;
            return op == 102 ? zova_database_extension_install(&request) :
                op == 103 ? zova_database_extension_drop(&request) : zova_database_extension_check(&request);
        }
        case 104: {
            zova_extension_list list = {0};
            zova_database_extension_list_request request = {db, &list};
            PARSED;
            int status = zova_database_extension_list(&request);
            if (status == ZOVA_OK) {
                wr_u32((uint32_t)list.len);
                for (size_t index = 0; index < list.len; index++) wr_extension(&list.items[index]);
            }
            zova_extension_list_free(&list);
            return status;
        }
        case 105: {
            zova_extension_info info = {0};
            zova_database_extension_info_request request = {db, rd_str(r), &info};
            PARSED;
            int status = zova_database_extension_info(&request);
            if (status == ZOVA_OK) wr_extension(&info);
            zova_extension_info_free(&info);
            return status;
        }
        case 107: {
            PARSED;
            zova_database_simple_request request = {db};
            return zova_database_extension_check_all(&request);
        }
        default: return ZOVA_INVALID_ARGUMENT;
    }
}

/* App-defined SQL functions call into the worker runtime, which runs the
 * function synchronously and answers through zw_sql_result. Arguments go in
 * their own buffer: a function can run in the middle of another reply. */
EM_JS(void, zw_sql_call_js, (int id, const uint8_t *args, size_t len), {
    Module["zovaSqlFunction"](id, args, len);
});
EM_JS(void, zw_sql_destroy_js, (int id), {
    if (Module["zovaSqlDestroy"]) Module["zovaSqlDestroy"](id);
});
static zova_sql_result *sql_result;
static uint8_t *sql_data;
static const uint8_t sql_empty[1];
static const char sql_unanswered[] = "SQL function returned no result";
static const char sql_no_memory[] = "out of memory";

EXPORTED void zw_sql_result(int type, int64_t value, double floating, const uint8_t *data, size_t len) {
    if (!sql_result) return;
    free(sql_data);
    sql_data = NULL;
    const uint8_t *copy = sql_empty;
    if (type >= ZOVA_SQL_RESULT_TEXT && len) {
        sql_data = malloc(len);
        if (!sql_data) {
            sql_result->result_type = ZOVA_SQL_RESULT_ERROR;
            sql_result->error_message = sql_no_memory;
            sql_result->error_message_len = sizeof(sql_no_memory) - 1;
            return;
        }
        memcpy(sql_data, data, len);
        copy = sql_data;
    }
    sql_result->result_type = type;
    sql_result->int64_value = value;
    sql_result->double_value = floating;
    if (type == ZOVA_SQL_RESULT_ERROR) {
        sql_result->error_message = (const char *)copy;
        sql_result->error_message_len = len;
    } else if (type >= ZOVA_SQL_RESULT_TEXT) {
        sql_result->data = copy;
        sql_result->data_len = len;
    }
}
static void sql_put(uint8_t *target, size_t *at, const void *data, size_t len) {
    if (len) memcpy(target + *at, data, len);
    size_t padded = (len + 3) & ~(size_t)3;
    memset(target + *at + len, 0, padded - len);
    *at += padded;
}
/* Arguments: u32 count, then per value u32 type and an i64, an f64, or u32
 * length and bytes. */
static void sql_call(void *user_data, const zova_sql_function_call *call, zova_sql_result *result) {
    result->result_type = ZOVA_SQL_RESULT_ERROR;
    result->error_message = sql_no_memory;
    result->error_message_len = sizeof(sql_no_memory) - 1;
    size_t size = 4;
    for (size_t index = 0; index < call->argc; index++) {
        const zova_sql_value *value = &call->argv[index];
        if (value->value_type == ZOVA_SQL_VALUE_TEXT || value->value_type == ZOVA_SQL_VALUE_BLOB) {
            if (value->data_len >= UINT32_MAX) return;
            size += 8 + ((value->data_len + 3) & ~(size_t)3);
        } else size += value->value_type == ZOVA_SQL_VALUE_NULL ? 4 : 12;
    }
    uint8_t *args = malloc(size);
    if (!args) return;
    size_t at = 0;
    uint32_t argc = (uint32_t)call->argc;
    sql_put(args, &at, &argc, 4);
    for (size_t index = 0; index < call->argc; index++) {
        const zova_sql_value *value = &call->argv[index];
        uint32_t type = (uint32_t)value->value_type;
        sql_put(args, &at, &type, 4);
        if (type == ZOVA_SQL_VALUE_INTEGER) sql_put(args, &at, &value->int64_value, 8);
        else if (type == ZOVA_SQL_VALUE_FLOAT) sql_put(args, &at, &value->double_value, 8);
        else if (type != ZOVA_SQL_VALUE_NULL) {
            uint32_t len = (uint32_t)value->data_len;
            sql_put(args, &at, &len, 4);
            sql_put(args, &at, value->data, len);
        }
    }
    result->error_message = sql_unanswered;
    result->error_message_len = sizeof(sql_unanswered) - 1;
    zova_sql_result *previous = sql_result;
    sql_result = result;
    zw_sql_call_js((int)(intptr_t)user_data, args, at);
    sql_result = previous;
    free(args);
}
static void sql_destroy(void *user_data) { zw_sql_destroy_js((int)(intptr_t)user_data); }

/* The one fresh-build session of this database, and the key counts its
 * finish reports. A failed step has already rolled the session back. */
static zova_fresh_build *fresh;
static size_t fresh_nodes;
static size_t fresh_edges;
static void fresh_end(void) {
    if (!fresh) return;
    zova_fresh_build_abort(fresh);
    zova_fresh_build_destroy(fresh);
    fresh = NULL;
    fresh_nodes = 0;
    fresh_edges = 0;
}
static int fresh_step(int status) {
    if (status != ZOVA_OK) fresh_end();
    return status;
}

static double rd_f64(reader *r) {
    double value = 0;
    const uint8_t *data = rd_take(r, 8);
    if (data) memcpy(&value, data, 8);
    return value;
}
static int64_t *rd_keys(reader *r, uint32_t *count) {
    *count = rd_u32(r);
    int64_t *keys = rd_array(r, *count, sizeof(*keys));
    for (uint32_t index = 0; keys && index < *count; index++) keys[index] = (int64_t)rd_u64(r);
    return keys;
}
static void wr_keys(const int64_t *keys, size_t count) {
    wr_u32((uint32_t)count);
    for (size_t index = 0; index < count; index++) wr_u64((uint64_t)keys[index]);
}
/* Optional bytes: a presence flag, then the bytes. */
static zova_kv_bytes rd_optional_bytes(reader *r, uint8_t *present) {
    *present = rd_u32(r) != 0;
    zova_kv_bytes value = {NULL, 0};
    if (*present) value = rd_bytes(r);
    return value;
}
static zova_graph_fresh_node_input rd_fresh_node(reader *r) {
    zova_graph_fresh_node_input node = {0};
    node.node_id = rd_str(r);
    node.kind = rd_str(r);
    node.target_type = (int)rd_u32(r);
    node.target_namespace = rd_str(r);
    node.target_ref = rd_str(r);
    return node;
}
static zova_graph_fresh_edge_payload_input rd_fresh_edge(reader *r) {
    zova_graph_fresh_edge_payload_input edge = {0};
    edge.from_node_ordinal = rd_u32(r);
    edge.edge_type = rd_str(r);
    edge.to_node_ordinal = rd_u32(r);
    zova_kv_bytes payload = rd_bytes(r);
    edge.payload = payload.data;
    edge.payload_len = payload.len;
    return edge;
}
/* A fresh graph: name, nodes, then edges with payloads. */
static int rd_fresh_graph(reader *r, const char **name, zova_graph_fresh_node_input **nodes, uint32_t *node_count,
    zova_graph_fresh_edge_payload_input **edges, uint32_t *edge_count) {
    *name = rd_str(r);
    *node_count = rd_u32(r);
    *nodes = rd_array(r, *node_count, sizeof(**nodes));
    for (uint32_t index = 0; *nodes && index < *node_count; index++) (*nodes)[index] = rd_fresh_node(r);
    *edge_count = rd_u32(r);
    *edges = *nodes ? rd_array(r, *edge_count, sizeof(**edges)) : NULL;
    for (uint32_t index = 0; *edges && index < *edge_count; index++) (*edges)[index] = rd_fresh_edge(r);
    return *nodes && *edges && !r->bad && !r->left;
}
static void wr_walk_items(const zova_graph_walk_results *results) {
    wr_u32((uint32_t)results->len);
    for (size_t index = 0; index < results->len; index++) {
        const zova_graph_walk_result *item = &results->items[index];
        wr_blob(item->node_id, item->node_id_len);
        wr_blob(item->kind, item->kind_len);
        wr_u32(item->depth);
        wr_optional(item->predecessor_node_id, item->predecessor_node_id_len, item->has_predecessor_node_id);
        wr_optional(item->edge_type, item->edge_type_len, item->has_edge_type);
    }
}

/* C ABI calls added for parity with the native bindings. */
static int call_parity(int op, reader *r) {
    switch (op) {
        case 110: {
            zova_kv_scan_results results = {0};
            zova_kv_scan_request request = {0};
            request.db = db;
            request.ns = rd_bytes(r);
            request.prefix = rd_bytes(r);
            request.start = rd_optional_bytes(r, &request.has_start);
            request.end = rd_optional_bytes(r, &request.has_end);
            request.after = rd_optional_bytes(r, &request.has_after);
            request.limit = rd_u32(r);
            request.keys_only = rd_u32(r) != 0;
            request.out_results = &results;
            PARSED;
            int status = zova_kv_scan(&request);
            if (status == ZOVA_OK) {
                wr_u32(results.has_more);
                wr_u32((uint32_t)results.len);
                for (size_t index = 0; index < results.len; index++) {
                    wr_blob(results.items[index].key.data, results.items[index].key.len);
                    wr_blob(results.items[index].value.data, results.items[index].value.len);
                }
            }
            zova_kv_scan_results_free(&results);
            return status;
        }
        case 111: case 112: case 113: {
            /* Put if absent, compare and put, compare and delete. */
            uint8_t applied = 0;
            zova_kv_bytes ns = rd_bytes(r);
            zova_kv_bytes key = rd_bytes(r);
            zova_kv_bytes expected = op == 111 ? (zova_kv_bytes){NULL, 0} : rd_bytes(r);
            zova_kv_bytes value = op == 113 ? (zova_kv_bytes){NULL, 0} : rd_bytes(r);
            PARSED;
            int status;
            if (op == 111) {
                zova_kv_put_if_absent_request request = {db, ns, key, value, &applied};
                status = zova_kv_put_if_absent(&request);
            } else if (op == 112) {
                zova_kv_compare_and_put_request request = {db, ns, key, expected, value, &applied};
                status = zova_kv_compare_and_put(&request);
            } else {
                zova_kv_compare_and_delete_request request = {db, ns, key, expected, &applied};
                status = zova_kv_compare_and_delete(&request);
            }
            number = applied;
            return status;
        }
        case 114: {
            zova_object_set_compression_request request = {db, (int)rd_u32(r)};
            PARSED;
            return zova_object_set_compression(&request);
        }
        case 115: {
            zova_vector_search_results results = {0};
            zova_vector_search_multi_i8_request request = {0};
            request.db = db;
            request.collection_name = rd_str(r);
            zova_kv_bytes query = rd_bytes(r);
            request.query_values = (const int8_t *)query.data;
            request.query_values_len = query.len;
            request.query_count = rd_u32(r);
            request.dimensions = rd_u32(r);
            uint32_t has_candidates = rd_u32(r);
            uint32_t count = has_candidates ? rd_u32(r) : 0;
            const char **ids = has_candidates ? rd_array(r, count, sizeof(*ids)) : NULL;
            for (uint32_t index = 0; ids && index < count; index++) {
                ids[index] = rd_str(r);
                if (!ids[index]) r->bad = 1;
            }
            request.candidate_ids = ids;
            request.candidate_count = count;
            request.mode = (int)rd_u32(r);
            request.aggregation = (int)rd_u32(r);
            request.prefilter_query_index = rd_u32(r);
            request.prefilter_limit = rd_u32(r);
            request.limit = rd_u32(r);
            request.out_results = &results;
            int status = ZOVA_INVALID_ARGUMENT;
            if (!r->bad && !r->left && (!has_candidates || ids)) status = zova_vector_search_multi_i8(&request);
            if (status == ZOVA_OK) wr_search(&results);
            zova_vector_search_results_free(&results);
            free(ids);
            return status;
        }
        case 116: {
            uint32_t count = rd_u32(r);
            zova_graph_node_input *nodes = rd_array(r, count, sizeof(*nodes));
            for (uint32_t index = 0; nodes && index < count; index++) nodes[index] = rd_node(r);
            int64_t *keys = nodes ? calloc(count ? count : 1, sizeof(*keys)) : NULL;
            int status = keys ? ZOVA_INVALID_ARGUMENT : ZOVA_OUT_OF_MEMORY;
            if (keys && !r->bad && !r->left) {
                zova_graph_node_put_many_keyed_request request = {db, nodes, count, keys, count};
                status = zova_graph_node_put_many_keyed(&request);
                if (status == ZOVA_OK) wr_keys(keys, count);
            }
            free(keys);
            free(nodes);
            return status;
        }
        case 117: {
            uint32_t count = rd_u32(r);
            zova_graph_edge_input *edges = rd_array(r, count, sizeof(*edges));
            for (uint32_t index = 0; edges && index < count; index++) edges[index] = rd_edge(r);
            int64_t *keys = edges ? calloc(count ? count : 1, sizeof(*keys)) : NULL;
            int status = keys ? ZOVA_INVALID_ARGUMENT : ZOVA_OUT_OF_MEMORY;
            if (keys && !r->bad && !r->left) {
                zova_graph_edge_put_many_keyed_request request = {db, edges, count, keys, count};
                status = zova_graph_edge_put_many_keyed(&request);
                if (status == ZOVA_OK) wr_keys(keys, count);
            }
            free(keys);
            free(edges);
            return status;
        }
        case 118: case 119: case 122: {
            /* Nodes, edges or edge payloads by key; missing keys report not found. */
            const char *graph = rd_str(r);
            uint32_t count = 0;
            int64_t *keys = rd_keys(r, &count);
            int status = ZOVA_INVALID_ARGUMENT;
            if (keys && !r->bad && !r->left) {
                if (op == 118) {
                    zova_graph_keyed_node_results results = {0};
                    zova_graph_nodes_get_many_keyed_request request = {db, graph, keys, count, &results};
                    status = zova_graph_nodes_get_many_keyed(&request);
                    if (status == ZOVA_OK) {
                        wr_u32((uint32_t)results.len);
                        for (size_t index = 0; index < results.len; index++) {
                            const zova_graph_keyed_node_result *item = &results.items[index];
                            wr_u32(item->found);
                            if (!item->found) continue;
                            wr_u64((uint64_t)item->node_key);
                            wr_blob(item->node_id, item->node_id_len);
                            wr_blob(item->kind, item->kind_len);
                            wr_u64((uint64_t)item->created_order);
                        }
                    }
                    zova_graph_keyed_node_results_free(&results);
                } else if (op == 119) {
                    zova_graph_keyed_edge_results results = {0};
                    zova_graph_edges_get_many_keyed_request request = {db, graph, keys, count, &results};
                    status = zova_graph_edges_get_many_keyed(&request);
                    if (status == ZOVA_OK) {
                        wr_u32((uint32_t)results.len);
                        for (size_t index = 0; index < results.len; index++) {
                            const zova_graph_keyed_edge_result *item = &results.items[index];
                            wr_u32(item->found);
                            if (!item->found) continue;
                            wr_u64((uint64_t)item->edge_key);
                            wr_u64((uint64_t)item->source_node_key);
                            wr_blob(item->edge_type, item->edge_type_len);
                            wr_u64((uint64_t)item->target_node_key);
                            wr_u64((uint64_t)item->created_order);
                        }
                    }
                    zova_graph_keyed_edge_results_free(&results);
                } else {
                    zova_graph_edge_payload_results results = {0};
                    zova_graph_edge_payload_get_many_request request = {db, graph, keys, count, &results};
                    status = zova_graph_edge_payload_get_many(&request);
                    if (status == ZOVA_OK) {
                        wr_u32((uint32_t)results.len);
                        for (size_t index = 0; index < results.len; index++) {
                            const zova_graph_edge_payload_result *item = &results.items[index];
                            wr_u32(item->found);
                            if (item->found) wr_blob(item->payload, item->payload_len);
                        }
                    }
                    zova_graph_edge_payload_results_free(&results);
                }
            }
            free(keys);
            return status;
        }
        case 120: {
            zova_graph_keyed_neighbor_results results = {0};
            zova_graph_neighbors_keyed_request request = {db, NULL, NULL, 0, NULL, 0, &results};
            request.graph_name = rd_str(r);
            request.node_id = rd_str(r);
            request.direction = (int)rd_u32(r);
            request.edge_type = rd_str(r);
            request.limit = rd_u32(r);
            PARSED;
            int status = zova_graph_neighbors_keyed(&request);
            if (status == ZOVA_OK) {
                wr_u32((uint32_t)results.len);
                for (size_t index = 0; index < results.len; index++) {
                    const zova_graph_keyed_neighbor_result *item = &results.items[index];
                    wr_u64((uint64_t)item->edge_key);
                    wr_u64((uint64_t)item->neighbor_node_key);
                    wr_blob(item->node_id, item->node_id_len);
                    wr_blob(item->kind, item->kind_len);
                    wr_blob(item->edge_type, item->edge_type_len);
                }
            }
            zova_graph_keyed_neighbor_results_free(&results);
            return status;
        }
        case 121: {
            const char *graph = rd_str(r);
            uint32_t count = 0;
            int64_t *keys = rd_keys(r, &count);
            int direction = (int)rd_u32(r);
            const char *edge_type = rd_str(r);
            uint64_t *degrees = keys ? calloc(count ? count : 1, sizeof(*degrees)) : NULL;
            int status = keys && !degrees ? ZOVA_OUT_OF_MEMORY : ZOVA_INVALID_ARGUMENT;
            if (degrees && !r->bad && !r->left) {
                zova_graph_degree_many_keyed_request request = {db, graph, keys, count, direction, edge_type, degrees, count};
                status = zova_graph_degree_many_keyed(&request);
                if (status == ZOVA_OK) {
                    wr_u32(count);
                    for (uint32_t index = 0; index < count; index++) wr_u64(degrees[index]);
                }
            }
            free(degrees);
            free(keys);
            return status;
        }
        case 123: {
            const char *graph = rd_str(r);
            uint32_t count = rd_u32(r);
            zova_graph_edge_payload_replacement *items = rd_array(r, count, sizeof(*items));
            for (uint32_t index = 0; items && index < count; index++) {
                items[index].edge_key = (int64_t)rd_u64(r);
                zova_kv_bytes payload = rd_bytes(r);
                items[index].payload = payload.data;
                items[index].payload_len = payload.len;
            }
            int status = ZOVA_INVALID_ARGUMENT;
            if (items && !r->bad && !r->left) {
                zova_graph_edge_payload_replace_many_request request = {db, graph, items, count};
                status = zova_graph_edge_payload_replace_many(&request);
            }
            free(items);
            return status;
        }
        case 124: {
            zova_graph_scan_results results = {0};
            zova_graph_scan_request request = {0};
            request.db = db;
            request.graph_name = rd_str(r);
            request.node_after.created_order = (int64_t)rd_u64(r);
            request.node_after.key = (int64_t)rd_u64(r);
            request.edge_after.created_order = (int64_t)rd_u64(r);
            request.edge_after.key = (int64_t)rd_u64(r);
            request.node_limit = rd_u32(r);
            request.edge_limit = rd_u32(r);
            request.out_results = &results;
            PARSED;
            int status = zova_graph_scan(&request);
            if (status == ZOVA_OK) {
                wr_u32(results.has_more_nodes);
                wr_u32(results.has_more_edges);
                wr_u32((uint32_t)results.nodes_len);
                for (size_t index = 0; index < results.nodes_len; index++) {
                    const zova_graph_scan_node *item = &results.nodes[index];
                    wr_u64((uint64_t)item->node_key);
                    wr_blob(item->node_id, item->node_id_len);
                    wr_blob(item->kind, item->kind_len);
                    wr_u64((uint64_t)item->created_order);
                }
                wr_u32((uint32_t)results.edges_len);
                for (size_t index = 0; index < results.edges_len; index++) {
                    const zova_graph_scan_edge *item = &results.edges[index];
                    wr_u64((uint64_t)item->edge_key);
                    wr_u64((uint64_t)item->source_node_key);
                    wr_blob(item->edge_type, item->edge_type_len);
                    wr_u64((uint64_t)item->target_node_key);
                    wr_u64((uint64_t)item->created_order);
                }
            }
            zova_graph_scan_results_free(&results);
            return status;
        }
        case 125: {
            zova_graph_walk_results results = {0};
            zova_graph_walk_profile profile = {0};
            zova_graph_walk_direction_profiled_request request = {db, NULL, NULL, 0, NULL, 0, 0, &results, &profile};
            request.graph_name = rd_str(r);
            request.start_node_id = rd_str(r);
            request.direction = (int)rd_u32(r);
            request.edge_type = rd_str(r);
            request.max_depth = rd_u32(r);
            request.limit = rd_u32(r);
            PARSED;
            int status = zova_graph_walk_direction_profiled(&request);
            if (status == ZOVA_OK) {
                wr_walk_items(&results);
                const double timings[] = {profile.mutex_wait_ms, profile.root_lookup_ms, profile.adjacency_prepare_ms,
                    profile.adjacency_execute_ms, profile.bfs_bookkeeping_allocation_ms, profile.c_abi_result_export_ms,
                    profile.total_profiled_ms};
                for (size_t index = 0; index < 7; index++) wr_f64(timings[index]);
                wr_u64(profile.frontier_expansions);
                wr_u64(profile.adjacency_query_binds);
                wr_u64(profile.adjacency_rows_stepped);
                wr_u64(profile.result_count);
            }
            zova_graph_walk_results_free(&results);
            return status;
        }
        case 126: case 127: case 128: {
            /* Fresh graph builders: normalizing, prepared, and prepared with
             * payloads. Only the last one accepts payloads. */
            const char *graph = NULL;
            zova_graph_fresh_node_input *nodes = NULL;
            zova_graph_fresh_edge_payload_input *edges = NULL;
            uint32_t node_count = 0, edge_count = 0;
            int parsed = rd_fresh_graph(r, &graph, &nodes, &node_count, &edges, &edge_count);
            zova_graph_fresh_edge_input *plain = parsed ? calloc(edge_count ? edge_count : 1, sizeof(*plain)) : NULL;
            int64_t *node_keys = parsed ? calloc(node_count ? node_count : 1, sizeof(*node_keys)) : NULL;
            int64_t *edge_keys = parsed ? calloc(edge_count ? edge_count : 1, sizeof(*edge_keys)) : NULL;
            int status = !parsed ? ZOVA_INVALID_ARGUMENT : !plain || !node_keys || !edge_keys ? ZOVA_OUT_OF_MEMORY : ZOVA_OK;
            for (uint32_t index = 0; status == ZOVA_OK && index < edge_count; index++) {
                if (op != 128 && edges[index].payload_len) status = ZOVA_INVALID_ARGUMENT;
                plain[index] = (zova_graph_fresh_edge_input){edges[index].from_node_ordinal, edges[index].edge_type, edges[index].to_node_ordinal};
            }
            if (status == ZOVA_OK && op == 128) {
                zova_graph_build_fresh_prepared_keyed_with_payloads_request request = {db, graph, nodes, node_count, edges, edge_count,
                    node_keys, node_count, edge_keys, edge_count};
                status = zova_graph_build_fresh_prepared_keyed_with_payloads(&request);
            } else if (status == ZOVA_OK) {
                zova_graph_build_fresh_keyed_request request = {db, graph, nodes, node_count, plain, edge_count,
                    node_keys, node_count, edge_keys, edge_count};
                status = op == 126 ? zova_graph_build_fresh_keyed(&request) : zova_graph_build_fresh_prepared_keyed(&request);
            }
            if (status == ZOVA_OK) {
                wr_keys(node_keys, node_count);
                wr_keys(edge_keys, edge_count);
            }
            free(edge_keys);
            free(node_keys);
            free(plain);
            free(edges);
            free(nodes);
            return status;
        }
        case 129: {
            PARSED;
            if (fresh) {
                snprintf(bridge_error, sizeof(bridge_error), "A fresh build is already active on this database");
                return ZOVA_MISUSE;
            }
            zova_fresh_build_begin_request request = {db, &fresh};
            return zova_fresh_build_begin(&request);
        }
        case 130: case 131: {
            /* Table or FTS rows: table, columns, row count, then the values row by row. */
            const char *table = rd_str(r);
            uint32_t columns = rd_u32(r);
            const char **names = rd_array(r, columns, sizeof(*names));
            for (uint32_t index = 0; names && index < columns; index++) {
                names[index] = rd_str(r);
                if (!names[index]) r->bad = 1;
            }
            uint32_t rows = rd_u32(r);
            uint64_t total = (uint64_t)rows * columns;
            zova_fresh_value *values = names && total <= UINT32_MAX ? rd_array(r, (uint32_t)total, sizeof(*values)) : NULL;
            for (uint64_t index = 0; values && index < total; index++) {
                zova_fresh_value *value = &values[index];
                value->value_type = (int)rd_u32(r);
                if (value->value_type == ZOVA_FRESH_VALUE_INT64) value->int64_value = (int64_t)rd_u64(r);
                else if (value->value_type == ZOVA_FRESH_VALUE_FLOAT64) value->float64_value = rd_f64(r);
                else if (value->value_type == ZOVA_FRESH_VALUE_TEXT || value->value_type == ZOVA_FRESH_VALUE_BLOB) {
                    zova_kv_bytes data = rd_bytes(r);
                    value->bytes = data.data;
                    value->bytes_len = data.len;
                } else if (value->value_type != ZOVA_FRESH_VALUE_NULL) r->bad = 1;
            }
            int status = ZOVA_INVALID_ARGUMENT;
            if (!fresh) status = ZOVA_MISUSE;
            else if (values && !r->bad && !r->left) {
                zova_fresh_build_rows_request request = {fresh, table, names, columns, values, rows};
                status = op == 130 ? zova_fresh_build_table_rows(&request) : zova_fresh_build_fts_rows(&request);
            }
            free(values);
            free(names);
            return fresh_step(status);
        }
        case 132: {
            const char *graph = NULL;
            zova_graph_fresh_node_input *nodes = NULL;
            zova_graph_fresh_edge_payload_input *edges = NULL;
            uint32_t node_count = 0, edge_count = 0;
            int status = ZOVA_INVALID_ARGUMENT;
            if (!rd_fresh_graph(r, &graph, &nodes, &node_count, &edges, &edge_count)) status = ZOVA_INVALID_ARGUMENT;
            else if (!fresh) status = ZOVA_MISUSE;
            else {
                zova_fresh_build_graph_request request = {fresh, graph, nodes, node_count, edges, edge_count, NULL, 0, NULL, 0};
                status = zova_fresh_build_graph(&request);
                if (status == ZOVA_OK) {
                    fresh_nodes = node_count;
                    fresh_edges = edge_count;
                }
            }
            free(edges);
            free(nodes);
            return fresh_step(status);
        }
        case 133: {
            const char *collection = rd_str(r);
            uint32_t count = rd_u32(r);
            zova_vector_input *inputs = rd_array(r, count, sizeof(*inputs));
            for (uint32_t index = 0; inputs && index < count; index++) {
                inputs[index].id = rd_str(r);
                inputs[index].values = rd_values(r);
            }
            int status = ZOVA_INVALID_ARGUMENT;
            if (!fresh) status = ZOVA_MISUSE;
            else if (inputs && !r->bad && !r->left) {
                zova_fresh_build_vectors_request request = {fresh, collection, inputs, count};
                status = zova_fresh_build_vectors(&request);
            }
            free(inputs);
            return fresh_step(status);
        }
        case 134: {
            PARSED;
            if (!fresh) return ZOVA_MISUSE;
            zova_fresh_build_profile profile = {0};
            int64_t *node_keys = calloc(fresh_nodes ? fresh_nodes : 1, sizeof(*node_keys));
            int64_t *edge_keys = calloc(fresh_edges ? fresh_edges : 1, sizeof(*edge_keys));
            int status = ZOVA_OUT_OF_MEMORY;
            if (node_keys && edge_keys) {
                zova_fresh_build_finish_request request = {fresh, node_keys, fresh_nodes, edge_keys, fresh_edges, &profile};
                status = zova_fresh_build_finish(&request);
            }
            if (status == ZOVA_OK) {
                wr_keys(node_keys, fresh_nodes);
                wr_keys(edge_keys, fresh_edges);
                const double timings[] = {profile.validation_ms, profile.table_load_ms, profile.fts_load_ms, profile.graph_load_ms,
                    profile.graph_validation_ms, profile.graph_key_generation_ms, profile.graph_node_load_ms,
                    profile.graph_edge_load_ms, profile.vector_load_ms, profile.index_build_ms, profile.commit_ms};
                for (size_t index = 0; index < 11; index++) wr_f64(timings[index]);
                wr_u64(profile.table_rows);
                wr_u64(profile.fts_rows);
                wr_u64(profile.vector_rows);
                wr_u64(profile.payload_bytes);
            }
            free(node_keys);
            free(edge_keys);
            fresh_end();
            return status;
        }
        case 135: {
            PARSED;
            if (!fresh) return ZOVA_OK;
            int status = zova_fresh_build_abort(fresh);
            fresh_end();
            return status;
        }
        case 136: {
            const char *name = rd_str(r);
            int32_t arity = (int32_t)rd_u32(r);
            uint32_t flags = rd_u32(r);
            uint32_t id = rd_u32(r);
            PARSED;
            zova_sql_function_register_request request = {db, name, arity, flags, (void *)(intptr_t)id, sql_call, sql_destroy};
            return zova_database_register_function(&request);
        }
        case 137: {
            PARSED;
            const char *version = zova_abi_version_string();
            wr_u32(zova_abi_version_major());
            wr_u32(zova_abi_version_minor());
            wr_u32(zova_abi_version_patch());
            wr_blob(version, strlen(version));
            return ZOVA_OK;
        }
        case 138: case 139: {
            zova_database_extension_request request = {db, rd_str(r)};
            PARSED;
            return op == 138 ? zova_database_extension_upgrade(&request) : zova_database_extension_rebuild(&request);
        }
        default: return ZOVA_INVALID_ARGUMENT;
    }
}
#endif

/* Operation numbers are shared with src/runtime.mjs. */
EXPORTED int zw_call(int op, const uint8_t *input, size_t input_len) {
    clear_output();
    reader r = {input, input_len, 0};
    int status = op < 10 ? call_object(op, &r) : op < 30 ? call_vector(op, &r) : op < 50 ? call_graph(op, &r) :
        op < 70 ? call_database(op, &r) : op < 90 ? call_object_stream(op, &r) :
#ifdef ZOVA_WASM_OPFS
        op < 110 ? call_maintenance(op, &r) : call_parity(op, &r);
#else
        ZOVA_INVALID_ARGUMENT;
#endif
    if (out_bad) status = ZOVA_OUT_OF_MEMORY;
    if (status == ZOVA_OK && !bytes) {
        bytes = out;
        length = out_len;
    }
    return status;
}
