#include "sqlite3.h"
#include <stdio.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "SQLite diagnostics failed at line %d: %s\n", __LINE__, #expr); return 1; } } while (0)

#ifdef ZOVA_SQLITE_DIAGNOSTICS
static int scalar(sqlite3 *db, const char *sql, int expected) {
    sqlite3_stmt *stmt = NULL;
    CHECK(sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK);
    CHECK(sqlite3_step(stmt) == SQLITE_ROW);
    CHECK(sqlite3_column_int(stmt, 0) == expected);
    CHECK(sqlite3_finalize(stmt) == SQLITE_OK);
    return 0;
}

static int scan(sqlite3 *db, const char *sql, int enabled, sqlite3_int64 expected,
                const char *plan) {
    sqlite3_stmt *stmt = NULL;
    CHECK(sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK);
    CHECK(sqlite3_step(stmt) == SQLITE_ROW);
    CHECK(sqlite3_step(stmt) == SQLITE_DONE);
    sqlite3_int64 visits = -1, loops = -1;
    int rc = sqlite3_stmt_scanstatus_v2(stmt, 0, SQLITE_SCANSTAT_NVISIT, 0, &visits);
    if (enabled) {
        const char *explain = NULL;
        CHECK(rc == 0 && visits == expected);
        CHECK(sqlite3_stmt_scanstatus_v2(stmt, 0, SQLITE_SCANSTAT_NLOOP, 0, &loops) == 0);
        CHECK(loops == 1);
        CHECK(sqlite3_stmt_scanstatus_v2(stmt, 0, SQLITE_SCANSTAT_EXPLAIN, 0, &explain) == 0);
        CHECK(explain && strstr(explain, plan));
        printf("diagnostic fixture: %s, loops=%lld visits=%lld\n", plan,
               (long long)loops, (long long)visits);
        sqlite3_stmt_scanstatus_reset(stmt);
        CHECK(sqlite3_stmt_scanstatus_v2(stmt, 0, SQLITE_SCANSTAT_NVISIT, 0, &visits) == 0);
        CHECK(visits == 0);
    } else {
        CHECK(rc != 0);
    }
    CHECK(sqlite3_finalize(stmt) == SQLITE_OK);
    return 0;
}
#endif

int main(void) {
    const char *options[] = {"ENABLE_STMT_SCANSTATUS", "ENABLE_BYTECODE_VTAB",
        "ENABLE_STMTVTAB", "ENABLE_EXPLAIN_COMMENTS", "ENABLE_API_ARMOR"};
    for (unsigned i = 0; i < sizeof(options) / sizeof(options[0]); ++i) {
#ifdef ZOVA_SQLITE_DIAGNOSTICS
        CHECK(sqlite3_compileoption_used(options[i]) == 1);
#else
        CHECK(sqlite3_compileoption_used(options[i]) == 0);
#endif
    }
#ifdef ZOVA_SQLITE_INVARIANTS
    CHECK(sqlite3_compileoption_used("DEBUG") == 1);
#else
    CHECK(sqlite3_compileoption_used("DEBUG") == 0);
#endif
    CHECK(sqlite3_compileoption_used("ENABLE_DBPAGE_VTAB") == 0);
    CHECK(sqlite3_compileoption_used("ENABLE_DBPTR_VTAB") == 0);
#ifdef ZOVA_SQLITE_DIAGNOSTICS
    // Repeat after shutdown: the diagnostic default must cover every connection.
    for (int attempt = 0; attempt < 2; ++attempt) {
        sqlite3 *db = NULL;
        sqlite3_stmt *busy = NULL;
        int enabled = -1;
        CHECK(sqlite3_open(":memory:", &db) == SQLITE_OK);
        CHECK(sqlite3_db_config(db, SQLITE_DBCONFIG_STMT_SCANSTATUS, -1, &enabled) == SQLITE_OK);
        CHECK(enabled == 0);
        CHECK(sqlite3_exec(db, "CREATE TABLE probe(k INTEGER PRIMARY KEY);"
            "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100)"
            "INSERT INTO probe SELECT x FROM n;", NULL, NULL, NULL) == SQLITE_OK);
        CHECK(scan(db, "SELECT k FROM probe WHERE k=42", 0, 0, NULL) == 0);
        CHECK(sqlite3_db_config(db, SQLITE_DBCONFIG_STMT_SCANSTATUS, 1, NULL) == SQLITE_OK);
        CHECK(scan(db, "SELECT k FROM probe WHERE k=42", 1, 1, "SEARCH") == 0);
        CHECK(scan(db, "SELECT k FROM probe NOT INDEXED WHERE +k=42", 1, 100, "SCAN") == 0);
        CHECK(sqlite3_db_config(db, SQLITE_DBCONFIG_STMT_SCANSTATUS, 0, NULL) == SQLITE_OK);
        CHECK(scan(db, "SELECT k FROM probe WHERE k=42", 0, 0, NULL) == 0);
        CHECK(scalar(db, "SELECT count(*)>0 FROM bytecode('SELECT k FROM probe') WHERE comment IS NOT NULL", 1) == 0);
        CHECK(scalar(db, "SELECT count(*)>0 FROM tables_used('SELECT k FROM probe')", 1) == 0);
        CHECK(sqlite3_prepare_v2(db, "SELECT k FROM probe", -1, &busy, NULL) == SQLITE_OK);
        CHECK(sqlite3_step(busy) == SQLITE_ROW);
        CHECK(scalar(db, "SELECT count(*) FROM sqlite_stmt WHERE sql='SELECT k FROM probe' AND busy=1", 1) == 0);
        CHECK(sqlite3_reset(busy) == SQLITE_OK);
        CHECK(scalar(db, "SELECT count(*) FROM sqlite_stmt WHERE sql='SELECT k FROM probe' AND busy=1", 0) == 0);
        CHECK(sqlite3_finalize(busy) == SQLITE_OK);
        CHECK(sqlite3_bind_int(NULL, 1, 42) == SQLITE_MISUSE);
        CHECK(sqlite3_prepare_v2(db, NULL, -1, &busy, NULL) == SQLITE_MISUSE);
        CHECK(sqlite3_close(db) == SQLITE_OK);
        CHECK(sqlite3_shutdown() == SQLITE_OK);
    }
#endif
    return 0;
}
