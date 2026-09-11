#include "sqlite3.h"

/* SQLITE_EXTRA_AUTOEXT runs for every connection, before application statements.
 * Linked only into explicitly diagnostic builds. No global registration or
 * initialization race, logging, or changes to production connection handling.
 */
int sqliteDiagnosticsConfigure(sqlite3 *db) {
    return sqlite3_db_config(db, SQLITE_DBCONFIG_STMT_SCANSTATUS, 0, (int *)0);
}
