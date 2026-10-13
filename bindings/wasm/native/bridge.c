#include "bridge.h"
#include "zova.h"
#include <stdlib.h>
#include <string.h>
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

#ifdef ZOVA_WASM_OPFS
extern zova_status zova_opfs_create(const zova_database_open_request *);
extern zova_status zova_opfs_open(const zova_database_open_request *);

EXPORTED int zw_open_file(int exists) {
    if (db) return ZOVA_INVALID_ARGUMENT;
    zova_message_free(&message);
    /* Normal open validates without migration, but permits SQLite to recover
     * an abandoned rollback journal. A preliminary read-only open blocks that
     * recovery. Clean incompatible files are still rejected without mutation. */
    zova_database_open_request request = {"/db.zova", &db, &message};
    return exists ? zova_opfs_open(&request) : zova_opfs_create(&request);
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
}

EXPORTED int zw_number(void) { return number; }
EXPORTED void zw_release(void) { clear_output(); }
EXPORTED int64_t zw_integer(void) { return integer; }
EXPORTED double zw_float(void) { return real; }
EXPORTED const uint8_t *zw_bytes(void) { return bytes; }
EXPORTED size_t zw_length(void) { return length; }
EXPORTED const char *zw_error(void) {
    return db ? zova_database_last_error_message(db) : message.data;
}
EXPORTED const char *zw_status_name(int status) { return zova_status_name(status); }

EXPORTED int zw_create(void) {
    if (db) return ZOVA_INVALID_ARGUMENT;
    zova_message_free(&message);
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

/* Operation numbers are shared with src/runtime.mjs. */
EXPORTED int zw_call(int op, const uint8_t *input, size_t input_len) {
    clear_output();
    reader r = {input, input_len, 0};
    int status = op < 10 ? call_object(op, &r) : op < 30 ? call_vector(op, &r) : call_graph(op, &r);
    if (out_bad) status = ZOVA_OUT_OF_MEMORY;
    if (status == ZOVA_OK && !bytes) {
        bytes = out;
        length = out_len;
    }
    return status;
}
