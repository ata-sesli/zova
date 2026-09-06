#include "bridge.h"
#include "zova.h"
#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#define EXPORTED EMSCRIPTEN_KEEPALIVE
#else
#define EXPORTED
#endif

/* One instance per dedicated worker/module. No native handles cross to clients. */
static zova_database *db;
static zova_statement *statement;
static zova_message message;
static zova_text text;
static zova_buffer buffer;
static int number;
static int64_t integer;
static double real;
static const uint8_t *bytes;
static size_t length;

static void clear_output(void) {
    zova_text_free(&text);
    zova_buffer_free(&buffer);
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
    statement = NULL;
    return status;
}
EXPORTED int zw_close(void) {
    int status = zw_finalize();
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
EXPORTED int zw_prepare(const char *sql) {
    if (statement) return ZOVA_INVALID_ARGUMENT;
    clear_output();
    zova_database_prepare_request request = {db, sql, &statement};
    return zova_database_prepare(&request);
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
