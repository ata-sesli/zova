/* A C author using only the public, versioned plugin ABI. No SQLite handles. */
#include "zova_plugin.h"
#include <stddef.h>
#include <string.h>

static int32_t get_service(const zova_plugin_host_v1 *host, void *connection,
        uint32_t id, uint32_t size, const void **out) {
    *out = NULL;
    if (host->struct_size < sizeof(zova_plugin_service_host_v1)) return ZOVA_PLUGIN_UNSUPPORTED;
    return ((const zova_plugin_service_host_v1 *)host)->get_service(connection, id, 1, size, out);
}

static int32_t ZOVA_PLUGIN_CALL install(const zova_plugin_host_v1 *host, void *connection) {
    const char *sql = "CREATE TABLE _zova_ext_c_test_data(id INTEGER)";
    return host->exec_sql(connection, sql, strlen(sql));
}

static int32_t ZOVA_PLUGIN_CALL receive(void *raw, const zova_plugin_value_v1 *values,
        uint64_t count) {
    if (count != 1 || values == NULL) return ZOVA_PLUGIN_ERROR;
    *(int *)raw = values[0].kind == ZOVA_PLUGIN_VALUE_INTEGER && values[0].integer == 1;
    return ZOVA_PLUGIN_OK;
}

static int32_t ZOVA_PLUGIN_CALL check(const zova_plugin_host_v1 *host, void *connection) {
    const void *raw = NULL;
    int found = 0;
    const char *sql = "SELECT count(*) FROM _zova_ext_c_test_data WHERE id = ?";
    zova_plugin_value_v1 parameter = {0};
    zova_plugin_query_request_v1 request = {0};
    int32_t status = get_service(host, connection, ZOVA_PLUGIN_SERVICE_QUERY,
        sizeof(zova_plugin_query_service_v1), &raw);
    if (status != ZOVA_PLUGIN_OK) return status;
    parameter.kind = ZOVA_PLUGIN_VALUE_INTEGER;
    parameter.integer = 1;
    request.struct_size = sizeof(request);
    request.sql = sql;
    request.sql_len = strlen(sql);
    request.parameters = &parameter;
    request.parameter_count = 1;
    request.row_limit = 1;
    request.byte_limit = 1024;
    request.row = receive;
    request.user_data = &found;
    status = ((const zova_plugin_query_service_v1 *)raw)->query(connection, &request);
    return status != ZOVA_PLUGIN_OK ? status : (found ? ZOVA_PLUGIN_OK : ZOVA_PLUGIN_ERROR);
}

static int32_t ZOVA_PLUGIN_CALL drop(const zova_plugin_host_v1 *host, void *connection) {
    const char *sql = "DROP TABLE _zova_ext_c_test_data";
    return host->exec_sql(connection, sql, strlen(sql));
}

static int32_t ZOVA_PLUGIN_CALL echo(const zova_plugin_host_v1 *host, void *connection,
        void *state, const zova_plugin_operation_call_v1 *call) {
    (void)host; (void)connection; (void)state;
    return call->row(call->user_data, call->arguments, 1);
}

static int32_t ZOVA_PLUGIN_CALL register_sql(const zova_plugin_host_v1 *host, void *connection) {
    const void *raw = NULL;
    const zova_plugin_operation_column_v1 argument = {{(const uint8_t *)"input", 5}, ZOVA_PLUGIN_VALUE_INTEGER, 0};
    const zova_plugin_operation_column_v1 column = {{(const uint8_t *)"value", 5}, ZOVA_PLUGIN_VALUE_INTEGER, 0};
    zova_plugin_operation_v1 operation = {0};
    int32_t status = get_service(host, connection, ZOVA_PLUGIN_SERVICE_OPERATIONS,
        sizeof(zova_plugin_operation_service_v1), &raw);
    if (status != ZOVA_PLUGIN_OK) return status;
    operation.struct_size = sizeof(operation);
    operation.kind = ZOVA_PLUGIN_OPERATION_SCALAR;
    operation.flags = ZOVA_PLUGIN_OPERATION_EXACT;
    operation.name = (zova_plugin_bytes_v1){(const uint8_t *)"echo", 4};
    operation.arguments = &argument;
    operation.argument_count = 1;
    operation.columns = &column;
    operation.column_count = 1;
    operation.scalar = echo;
    return ((const zova_plugin_operation_service_v1 *)raw)->register_operation(connection, &operation);
}

static const zova_plugin_descriptor_v1 descriptor = {
    sizeof(zova_plugin_descriptor_v1), ZOVA_PLUGIN_ABI_V1,
    ZOVA_PLUGIN_REQUIRES_QUERY_V1 | ZOVA_PLUGIN_REQUIRES_OPERATIONS_V1,
    "c_test", "1.0.0", "_zova_ext_c_test_", "1.0.0", "",
    install, check, drop, register_sql
};

ZOVA_PLUGIN_EXPORT const zova_plugin_descriptor_v1 *ZOVA_PLUGIN_CALL
zova_plugin_entry_v1(uint32_t version) {
    return version == ZOVA_PLUGIN_ABI_V1 ? &descriptor : NULL;
}
