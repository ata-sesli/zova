#include "sqlite3.h"
int main(void) {
    sqlite3 *db = 0;
    int result = sqlite3_open(":memory:", &db);
    sqlite3_close(db);
    return result;
}
