#include "zova.h"
#include "sqlite3.h"

/* Private #38 go/no-go fixture, not a browser API. */
int64_t zova_wasm_smoke(void) {
    zova_database *db = NULL;
    zova_statement *statement = NULL;
    zova_message message = {0};
    int result = 1;
    if (sqlite3_threadsafe() != 0) return 2;
    zova_database_create_memory_request create = {&db, &message};
    if (zova_database_create_memory(&create) != ZOVA_OK) goto done;
    zova_database_exec_request exec = {
        db, "CREATE TABLE smoke(value INTEGER); INSERT INTO smoke VALUES(42);"
    };
    result = 3;
    if (zova_database_exec(&exec) != ZOVA_OK) goto done;
    /* Prove this is Zova's initialized format, not an independent SQLite DB. */
    zova_database_prepare_request prepare = {
        db, "SELECT value, CAST((SELECT value FROM _zova_meta WHERE key = 'format_version') AS INTEGER) FROM smoke",
        &statement
    };
    result = 4;
    if (zova_database_prepare(&prepare) != ZOVA_OK) goto done;
    zova_step_result step = ZOVA_STEP_DONE;
    zova_statement_step_request step_request = {statement, &step};
    result = 5;
    if (zova_statement_step(&step_request) != ZOVA_OK || step != ZOVA_STEP_ROW) goto done;
    int64_t value = 0;
    zova_statement_column_int64_request column = {statement, 0, &value};
    result = 6;
    if (zova_statement_column_int64(&column) != ZOVA_OK || value != 42) goto done;
    column.index = 1;
    result = 7;
    if (zova_statement_column_int64(&column) != ZOVA_OK || value != 11) goto done;
    result = 8;
    if (zova_statement_step(&step_request) != ZOVA_OK || step != ZOVA_STEP_DONE) goto done;
    result = 0;
done:
    if (statement && zova_statement_finalize(statement) != ZOVA_OK) result = 9;
    if (db && zova_database_close(db) != ZOVA_OK) result = 10;
    zova_message_free(&message);
    return result;
}
