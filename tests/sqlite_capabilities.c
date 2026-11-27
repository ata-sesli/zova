#include "sqlite_capabilities.h"
int main(void) {
    /* Native only: browser builds do not enable the snapshot interface. */
    if (!sqlite3_compileoption_used("ENABLE_SNAPSHOT")) {
        fprintf(stderr, "missing SQLite option: ENABLE_SNAPSHOT\n");
        return 1;
    }
    return zova_sqlite_capabilities();
}
