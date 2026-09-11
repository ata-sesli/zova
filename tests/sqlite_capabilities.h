#ifndef ZOVA_SQLITE_CAPABILITIES_H
#define ZOVA_SQLITE_CAPABILITIES_H
#include "sqlite3.h"
#include <stdio.h>

/* Shared by native and browser smoke tests; no public Zova API. */
static int zova_sqlite_capabilities(void) {
    const char *options[] = {"ENABLE_RTREE", "ENABLE_GEOPOLY", "ENABLE_CARRAY", "ENABLE_MATH_FUNCTIONS"};
    sqlite3 *db = NULL;
    sqlite3_stmt *stmt = NULL;
    int values[] = {3, 7, 11};
    int result = 1;
    for (unsigned i = 0; i < sizeof(options) / sizeof(options[0]); ++i) {
        if (!sqlite3_compileoption_used(options[i])) {
            fprintf(stderr, "missing SQLite option: %s\n", options[i]);
            return 1;
        }
    }
    if (sqlite3_open(":memory:", &db) != SQLITE_OK) goto done;
    if (sqlite3_exec(db,
        "CREATE VIRTUAL TABLE boxes USING rtree(id,x0,x1,y0,y1);"
        "INSERT INTO boxes VALUES(1,0,10,0,10);"
        "CREATE VIRTUAL TABLE zones USING geopoly;"
        "INSERT INTO zones(_shape) VALUES('[[0,0],[10,0],[10,10],[0,10],[0,0]]');",
        NULL, NULL, NULL) != SQLITE_OK) goto done;
    if (sqlite3_prepare_v2(db,
        "SELECT (SELECT count(*) FROM boxes WHERE x0<=5 AND x1>=5),"
        "(SELECT count(*) FROM zones WHERE geopoly_contains_point(_shape,5,5)),"
        "sqrt(81),pow(2,3),cos(0)", -1, &stmt, NULL) != SQLITE_OK) goto done;
    if (sqlite3_step(stmt) != SQLITE_ROW || sqlite3_column_int(stmt,0) != 1 ||
        sqlite3_column_int(stmt,1) != 1 || sqlite3_column_double(stmt,2) != 9 ||
        sqlite3_column_double(stmt,3) != 8 || sqlite3_column_double(stmt,4) != 1) goto done;
    sqlite3_finalize(stmt);
    stmt = NULL;
    if (sqlite3_prepare_v2(db, "SELECT sum(value) FROM carray(?)", -1, &stmt, NULL) != SQLITE_OK) goto done;
    if (sqlite3_carray_bind(stmt, 1, values, 3, SQLITE_CARRAY_INT32, SQLITE_STATIC) != SQLITE_OK) goto done;
    if (sqlite3_step(stmt) != SQLITE_ROW || sqlite3_column_int(stmt,0) != 21) goto done;
    result = 0;
done:
    if (result && db) fprintf(stderr, "SQLite capability probe: %s\n", sqlite3_errmsg(db));
    sqlite3_finalize(stmt);
    if (db) sqlite3_close(db);
    return result;
}
#endif
