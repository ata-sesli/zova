#include "../native/bridge.h"
#include "zova.h"
#include <assert.h>
#include <string.h>

int main(void) {
    for (int cycle = 0; cycle < 10; cycle++) {
        assert(zw_create() == ZOVA_OK);
        assert(zw_prepare("SELECT ?, ?, ?, ?, ?") == ZOVA_OK);
        assert(zw_bind(1, 0, 0, 0, NULL, 0) == ZOVA_OK);
        assert(zw_bind(2, 1, INT64_MIN, 0, NULL, 0) == ZOVA_OK);
        assert(zw_bind(3, 2, 0, 1.25, NULL, 0) == ZOVA_OK);
        assert(zw_bind(4, 3, 0, 0, (const uint8_t *)"a\0b", 3) == ZOVA_OK);
        assert(zw_bind(5, 4, 0, 0, (const uint8_t *)"\0\xff", 2) == ZOVA_OK);
        assert(zw_step() == ZOVA_OK && zw_number() == ZOVA_STEP_ROW);
        assert(zw_column(1) == ZOVA_OK && zw_integer() == INT64_MIN);
        assert(zw_column(2) == ZOVA_OK && zw_float() == 1.25);
        assert(zw_column(3) == ZOVA_OK && zw_length() == 3);
        assert(memcmp(zw_bytes(), "a\0b", 3) == 0);
        assert(zw_column(4) == ZOVA_OK && zw_length() == 2);
        assert(zw_finalize() == ZOVA_OK);
        assert(zw_prepare("not valid sql") != ZOVA_OK);
        assert(zw_finalize() == ZOVA_OK);
        assert(zw_kv(1, (const uint8_t *)"n", 1, (const uint8_t *)"k", 1, NULL, 0) == ZOVA_OK);
        assert(zw_kv(0, (const uint8_t *)"n", 1, (const uint8_t *)"k", 1, NULL, 0) == ZOVA_OK);
        assert(zw_number() == 1 && zw_length() == 0);
        assert(zw_kv(2, (const uint8_t *)"n", 1, (const uint8_t *)"k", 1, NULL, 0) == ZOVA_OK);
        assert(zw_number() == 1);
        assert(zw_kv(2, (const uint8_t *)"n", 1, (const uint8_t *)"k", 1, NULL, 0) == ZOVA_OK);
        assert(zw_number() == 0);
        zw_release();
        assert(zw_length() == 0 && zw_bytes() == NULL);
        assert(zw_close() == ZOVA_OK);
        assert(zw_close() == ZOVA_OK);
    }
}
