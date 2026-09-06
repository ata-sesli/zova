#include "zova.h"
#include <emscripten.h>
#include <string.h>
extern zova_status zova_opfs_create(const zova_database_open_request *);
extern zova_status zova_opfs_open(const zova_database_open_request *);

static int expect_text(zova_database *db, const char *sql, const char *expected) {
    zova_statement *stmt = NULL;
    zova_database_prepare_request prepare = {db, sql, &stmt};
    int status = zova_database_prepare(&prepare);
    if (status != ZOVA_OK) return status;
    zova_step_result result = ZOVA_STEP_DONE;
    zova_statement_step_request step = {stmt, &result};
    status = zova_statement_step(&step);
    zova_text text = {0};
    if (status == ZOVA_OK && result == ZOVA_STEP_ROW) {
        zova_statement_column_text_request column = {stmt, 0, &text};
        status = zova_statement_column_text(&column);
        if (status == ZOVA_OK && (text.len != strlen(expected) || memcmp(text.data, expected, text.len))) status = 1001;
    } else if (status == ZOVA_OK) status = 1002;
    zova_text_free(&text);
    int closed = zova_statement_finalize(stmt);
    return status == ZOVA_OK ? closed : status;
}

/* phase 2 intentionally leaves an uncommitted handle alive for worker death. */
EMSCRIPTEN_KEEPALIVE int zova_opfs_smoke(int phase) {
    zova_database *db = NULL;
    zova_message error = {0};
    int status;
    if (phase == 1) {
        zova_database_open_request request = {"/spike.zova", &db, &error};
        status = zova_opfs_create(&request);
    } else {
        zova_database_open_request request = {"/spike.zova", &db, &error};
        status = zova_opfs_open(&request);
    }
    zova_message_free(&error);
    if (status != ZOVA_OK) return status;
    zova_database_exec_request exec = {db, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;"};
    status = zova_database_exec(&exec);
    if (status == ZOVA_OK) status = expect_text(db, "PRAGMA journal_mode", "delete");
    if (status == ZOVA_OK) status = expect_text(db, "PRAGMA synchronous", "2");
    if (status != ZOVA_OK) goto done;
    if (phase == 2) {
        exec.sql = "PRAGMA cache_size=1; BEGIN IMMEDIATE; UPDATE proof SET value=99;"
            "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<128) "
            "INSERT INTO proof SELECT zeroblob(4096) FROM n;";
        status = zova_database_exec(&exec);
        if (status == ZOVA_OK) return status;
        goto done;
    }
    const uint8_t ns[] = {1}, key[] = {0, 2}, value[] = {0, 3, 255};
    if (phase == 1) {
        exec.sql = "CREATE TABLE proof(value); INSERT INTO proof VALUES(42); BEGIN; UPDATE proof SET value=7; ROLLBACK;";
        status = zova_database_exec(&exec);
        if (status != ZOVA_OK) goto done;
        zova_kv_put_request put = {db, {ns, sizeof ns}, {key, sizeof key}, {value, sizeof value}};
        status = zova_kv_put(&put);
        if (status != ZOVA_OK) goto done;
    }
    zova_kv_get_result found = {0};
    zova_kv_get_request get = {db, {ns, sizeof ns}, {key, sizeof key}, &found};
    status = zova_kv_get(&get);
    if (status == ZOVA_OK && (!found.found || found.value.len != sizeof value || memcmp(found.value.data, value, sizeof value))) status = 1003;
    zova_kv_get_result_free(&found);
    if (status == ZOVA_OK) status = expect_text(db, "SELECT count(*) || ':' || min(value) FROM proof", "1:42");
    if (status == ZOVA_OK) status = expect_text(db, "PRAGMA integrity_check", "ok");
done:;
    int closed = zova_database_close(db);
    return status == ZOVA_OK ? closed : status;
}
