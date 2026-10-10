#include "zova_plugin.h"
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#ifdef __cplusplus
static_assert(offsetof(zova_plugin_descriptor_v1, flags) == 8, "descriptor prefix");
#else
_Static_assert(offsetof(zova_plugin_descriptor_v1, flags) == 8, "descriptor prefix");
#endif

#ifdef ZOVA_SERVICES_FIXTURE
#ifdef __cplusplus
#define ZOVA_LAYOUT_ASSERT static_assert
#else
#define ZOVA_LAYOUT_ASSERT _Static_assert
#endif
ZOVA_LAYOUT_ASSERT(offsetof(zova_plugin_service_host_v1, base) == 0, "host prefix");
ZOVA_LAYOUT_ASSERT(offsetof(zova_plugin_value_v1, integer) == 8, "value prefix");
ZOVA_LAYOUT_ASSERT(offsetof(zova_plugin_query_request_v1, sql) == 8, "request prefix");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_host_v1) == 16, "host layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_service_host_v1) == 24, "service host layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_descriptor_v1) == 88, "descriptor layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_upgrade_descriptor_v1) == 104, "upgrade layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_value_v1) == 40, "value layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_query_request_v1) == 72, "query layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_data_request_v1) == 160, "data layout");
ZOVA_LAYOUT_ASSERT(offsetof(zova_plugin_data_request_v1, row_limit) == 128, "data budget");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_data_page_v1) == 32, "page layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_operation_column_v1) == 24, "column layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_operation_call_v1) == 40, "call layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_operation_v1) == 104, "operation layout");
ZOVA_LAYOUT_ASSERT(offsetof(zova_plugin_operation_v1, scalar) == 72, "scalar offset");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_vector_view_v1) == 40, "vector view layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_vector_changes_request_v1) == 104, "vector changes layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_vector_changes_page_v1) == 64, "vector changes page layout");
ZOVA_LAYOUT_ASSERT(sizeof(zova_plugin_vector_maintenance_service_v1) == 24, "vector maintenance layout");

static int32_t ZOVA_PLUGIN_CALL echo_operation(const zova_plugin_host_v1 *host,
        void *connection, void *state, const zova_plugin_operation_call_v1 *call) {
    (void)host; (void)connection; (void)state;
    return call->row(call->user_data, call->arguments, 1);
}
typedef struct series_cursor { int64_t position; int64_t count; } series_cursor;
static int32_t ZOVA_PLUGIN_CALL series_open(const zova_plugin_host_v1 *host,
        void *connection, void *state, const zova_plugin_value_v1 *arguments,
        uint64_t count, void **out) {
    series_cursor *cursor;
    (void)host; (void)connection; (void)state; (void)count;
    *out = NULL;
    cursor = (series_cursor *)calloc(1, sizeof(*cursor));
    if (!cursor) return ZOVA_PLUGIN_OUT_OF_MEMORY;
    cursor->count = arguments[0].integer;
    *out = cursor;
    return ZOVA_PLUGIN_OK;
}
static int32_t ZOVA_PLUGIN_CALL series_next(const zova_plugin_host_v1 *host,
        void *connection, void *raw, zova_plugin_row_v1 row, void *context,
        uint32_t *has_row) {
    series_cursor *cursor = (series_cursor *)raw;
    zova_plugin_value_v1 value = {0};
    (void)host; (void)connection;
    *has_row = 0;
    if (cursor->position >= cursor->count) return ZOVA_PLUGIN_OK;
    value.kind = ZOVA_PLUGIN_VALUE_INTEGER;
    value.integer = cursor->position++;
    *has_row = 1;
    return row(context, &value, 1);
}
static void ZOVA_PLUGIN_CALL series_close(void *cursor) { free(cursor); }
static int32_t ZOVA_PLUGIN_CALL register_operations(const zova_plugin_host_v1 *host, void *db) {
    const zova_plugin_service_host_v1 *extended = (const zova_plugin_service_host_v1 *)host;
    const void *raw = NULL;
    const zova_plugin_operation_service_v1 *service;
    const zova_plugin_operation_column_v1 argument = {{(const uint8_t *)"input", 5}, ZOVA_PLUGIN_VALUE_INTEGER, 0};
    const zova_plugin_operation_column_v1 column = {{(const uint8_t *)"value", 5}, ZOVA_PLUGIN_VALUE_INTEGER, 0};
    zova_plugin_operation_v1 operation = {0};
    if (extended->get_service(db, ZOVA_PLUGIN_SERVICE_OPERATIONS, 1, sizeof(*service), &raw) != 0)
        return ZOVA_PLUGIN_ERROR;
    service = (const zova_plugin_operation_service_v1 *)raw;
    if (service->register_operation(db, NULL) != ZOVA_PLUGIN_INVALID_ARGUMENT) return ZOVA_PLUGIN_ERROR;
    operation.struct_size = sizeof(operation);
    operation.kind = ZOVA_PLUGIN_OPERATION_SCALAR;
    operation.flags = ZOVA_PLUGIN_OPERATION_EXACT;
    operation.name.data = (const uint8_t *)"echo";
    operation.name.len = 4;
    operation.arguments = &argument;
    operation.argument_count = 1;
    operation.columns = &column;
    operation.column_count = 1;
    operation.scalar = echo_operation;
    if (service->register_operation(db, &operation) != 0) return ZOVA_PLUGIN_ERROR;
    if (service->register_operation(db, &operation) != ZOVA_PLUGIN_INVALID_ARGUMENT) return ZOVA_PLUGIN_ERROR;
    operation.kind = ZOVA_PLUGIN_OPERATION_TABLE;
    operation.flags |= ZOVA_PLUGIN_OPERATION_ORDERED;
    operation.name.data = (const uint8_t *)"series";
    operation.name.len = 6;
    operation.scalar = NULL;
    operation.open = series_open;
    operation.next = series_next;
    operation.close = series_close;
    return service->register_operation(db, &operation);
}

typedef struct query_state {
    int valid;
    const zova_plugin_service_host_v1 *host;
    void *connection;
} query_state;

static int32_t ZOVA_PLUGIN_CALL receive(void *raw, const zova_plugin_value_v1 *v, uint64_t count) {
    query_state *state = (query_state *)raw;
    const void *service = state->host;
    state->valid = count == 5 && v[0].kind == ZOVA_PLUGIN_VALUE_INTEGER && v[0].integer == 42 &&
        v[1].kind == ZOVA_PLUGIN_VALUE_FLOAT && v[1].real == 1.25 &&
        v[2].kind == ZOVA_PLUGIN_VALUE_TEXT && v[2].bytes_len == 3 &&
        memcmp(v[2].bytes, "a\0b", 3) == 0 && v[3].kind == ZOVA_PLUGIN_VALUE_BLOB &&
        v[3].bytes_len == 0 && v[4].kind == ZOVA_PLUGIN_VALUE_NULL;
    /* Deliberately violate the callback rule: the host must reject reentry and
     * clear the output, also when called across a real C/C++ plugin boundary. */
    if (state->host->get_service(state->connection, ZOVA_PLUGIN_SERVICE_QUERY, 1,
            sizeof(zova_plugin_query_service_v1), &service) != ZOVA_PLUGIN_INVALID_ARGUMENT || service != NULL)
        state->valid = 0;
    return ZOVA_PLUGIN_OK;
}

static int32_t ZOVA_PLUGIN_CALL check_services(const zova_plugin_host_v1 *host, void *db) {
    const zova_plugin_service_host_v1 *extended;
    const zova_plugin_query_service_v1 *query;
    const zova_plugin_diagnostics_service_v1 *diagnostics;
    const void *service = NULL;
    zova_plugin_value_v1 parameters[5] = {0};
    zova_plugin_query_request_v1 request = {0};
    uint8_t diagnostic[1024];
    uint64_t written = 0;
    query_state state = {0};
    if (host->struct_size < sizeof(zova_plugin_service_host_v1)) return ZOVA_PLUGIN_UNSUPPORTED;
    extended = (const zova_plugin_service_host_v1 *)host;
    state.host = extended;
    state.connection = db;
    if (extended->get_service(db, 999, 1, 0, &service) != ZOVA_PLUGIN_UNSUPPORTED || service != NULL)
        return ZOVA_PLUGIN_ERROR;
    if (extended->get_service(db, ZOVA_PLUGIN_SERVICE_QUERY, 1, sizeof(*query), &service) != 0)
        return ZOVA_PLUGIN_ERROR;
    query = (const zova_plugin_query_service_v1 *)service;
    parameters[0].kind = ZOVA_PLUGIN_VALUE_INTEGER;
    parameters[0].integer = 42;
    parameters[1].kind = ZOVA_PLUGIN_VALUE_FLOAT;
    parameters[1].real = 1.25;
    parameters[2].kind = ZOVA_PLUGIN_VALUE_TEXT;
    parameters[2].bytes = (const uint8_t *)"a\0b";
    parameters[2].bytes_len = 3;
    parameters[3].kind = ZOVA_PLUGIN_VALUE_BLOB;
    request.struct_size = sizeof(request);
    request.sql = "SELECT ?, ?, ?, ?, ?";
    request.sql_len = strlen(request.sql);
    request.parameters = parameters;
    request.parameter_count = 5;
    request.row_limit = 1;
    request.byte_limit = 1024;
    request.row = receive;
    request.user_data = &state;
    if (query->query(db, &request) != 0 || !state.valid) return ZOVA_PLUGIN_ERROR;
    {
        const zova_plugin_storage_service_v1 *storage;
        const zova_plugin_data_service_v1 *data;
        zova_plugin_data_request_v1 invalid = {0};
        zova_plugin_data_page_v1 page = {9, 1, 0, {1, 1}};
        if (extended->get_service(db, ZOVA_PLUGIN_SERVICE_STORAGE, 1, sizeof(*storage), &service) != 0)
            return ZOVA_PLUGIN_ERROR;
        storage = (const zova_plugin_storage_service_v1 *)service;
        if (storage->execute(db, &request) != 0 || !state.valid) return ZOVA_PLUGIN_ERROR;
        if (extended->get_service(db, ZOVA_PLUGIN_SERVICE_DATA, 1, sizeof(*data), &service) != 0)
            return ZOVA_PLUGIN_ERROR;
        data = (const zova_plugin_data_service_v1 *)service;
        invalid.struct_size = sizeof(invalid);
        if (data->read(db, &invalid, &page) != ZOVA_PLUGIN_INVALID_ARGUMENT ||
            page.rows != 0 || page.has_more != 0 || page.next.key != 0)
            return ZOVA_PLUGIN_ERROR;
        {
            const zova_plugin_vector_maintenance_service_v1 *maintenance;
            zova_plugin_vector_view_v1 view;
            zova_plugin_vector_changes_page_v1 changes;
            zova_plugin_bytes_v1 empty = {NULL, 0};
            memset(&view, 0xff, sizeof(view));
            memset(&changes, 0xff, sizeof(changes));
            if (extended->get_service(db, ZOVA_PLUGIN_SERVICE_VECTOR_MAINTENANCE, 1, sizeof(*maintenance), &service) != 0)
                return ZOVA_PLUGIN_ERROR;
            maintenance = (const zova_plugin_vector_maintenance_service_v1 *)service;
            if (maintenance->view(db, empty, &view) != ZOVA_PLUGIN_INVALID_ARGUMENT || view.revision != 0 || view.token[0] != 0)
                return ZOVA_PLUGIN_ERROR;
            if (maintenance->read_changes(db, NULL, &changes) != ZOVA_PLUGIN_INVALID_ARGUMENT || changes.rows != 0 || changes.view.revision != 0)
                return ZOVA_PLUGIN_ERROR;
        }
    }
    if (extended->get_service(db, ZOVA_PLUGIN_SERVICE_DIAGNOSTICS, 1, sizeof(*diagnostics), &service) != 0)
        return ZOVA_PLUGIN_ERROR;
    diagnostics = (const zova_plugin_diagnostics_service_v1 *)service;
    if (host->exec_sql(db, "not SQL", 7) != ZOVA_PLUGIN_ERROR) return ZOVA_PLUGIN_ERROR;
    if (diagnostics->copy_sqlite_error(db, diagnostic, sizeof(diagnostic), &written) != 0 || written == 0)
        return ZOVA_PLUGIN_ERROR;
    return ZOVA_PLUGIN_OK;
}
#endif

static int32_t ZOVA_PLUGIN_CALL install(const zova_plugin_host_v1 *host, void *db) {
    const char sql[] = "CREATE TABLE _zova_ext_c_test_data(id INTEGER)";
    if (host->abi_version != ZOVA_PLUGIN_ABI_V1 || host->struct_size < sizeof(*host))
        return ZOVA_PLUGIN_ERROR;
    return host->exec_sql(db, sql, sizeof(sql) - 1);
}

static int32_t ZOVA_PLUGIN_CALL drop(const zova_plugin_host_v1 *host, void *db) {
    const char sql[] = "DROP TABLE _zova_ext_c_test_data";
    return host->exec_sql(db, sql, sizeof(sql) - 1);
}


#ifdef ZOVA_UPGRADE_FIXTURE
static int32_t ZOVA_PLUGIN_CALL upgrade(const zova_plugin_host_v1 *host, void *db) {
    const char sql[] = "ALTER TABLE _zova_ext_c_test_data ADD COLUMN upgraded INTEGER DEFAULT 9";
    return host->exec_sql(db, sql, sizeof(sql) - 1);
}
static int32_t ZOVA_PLUGIN_CALL check(const zova_plugin_host_v1 *host, void *db) {
    const char sql[] = "SELECT upgraded FROM _zova_ext_c_test_data";
    return host->exec_sql(db, sql, sizeof(sql) - 1);
}
static const zova_plugin_upgrade_descriptor_v1 upgraded_descriptor = {
    { sizeof(zova_plugin_upgrade_descriptor_v1), ZOVA_PLUGIN_ABI_V1, ZOVA_PLUGIN_HAS_UPGRADE_V1,
      "c_test", "2.0.0", "_zova_ext_c_test_", "1.0.0", "", install, check, drop, NULL },
    "1.0.0", upgrade
};
#else
static const zova_plugin_descriptor_v1 descriptor = {
    sizeof(zova_plugin_descriptor_v1), ZOVA_PLUGIN_ABI_V1,
#ifdef ZOVA_SERVICES_FIXTURE
    ZOVA_PLUGIN_REQUIRES_QUERY_V1 | ZOVA_PLUGIN_REQUIRES_DIAGNOSTICS_V1 |
        ZOVA_PLUGIN_REQUIRES_DATA_V1 | ZOVA_PLUGIN_REQUIRES_STORAGE_V1 |
        ZOVA_PLUGIN_REQUIRES_OPERATIONS_V1,
#else
    0,
#endif
    "c_test", "1.0.0", "_zova_ext_c_test_", "1.0.0", "",
    install,
#ifdef ZOVA_SERVICES_FIXTURE
    check_services,
#else
    NULL,
#endif
    drop,
#ifdef ZOVA_SERVICES_FIXTURE
    register_operations
#else
    NULL
#endif
};
#endif

const zova_plugin_descriptor_v1 *ZOVA_PLUGIN_CALL zova_plugin_entry_v1(uint32_t version) {
#ifdef ZOVA_UPGRADE_FIXTURE
    return version == ZOVA_PLUGIN_ABI_V1 ? &upgraded_descriptor.base : NULL;
#else
    return version == ZOVA_PLUGIN_ABI_V1 ? &descriptor : NULL;
#endif
}
