#include "sqlite_capabilities.h"
int main(void) {
    /* Native only: browser builds keep SQLite's defaults for these. */
    static const char *const native_options[] = {"ENABLE_SNAPSHOT", "MAX_ATTACHED=30"};
    for (size_t i = 0; i < sizeof native_options / sizeof native_options[0]; i++) {
        if (!sqlite3_compileoption_used(native_options[i])) {
            fprintf(stderr, "missing SQLite option: %s\n", native_options[i]);
            return 1;
        }
    }
    return zova_sqlite_capabilities();
}
