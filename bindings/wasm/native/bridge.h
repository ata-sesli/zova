#ifndef ZOVA_WASM_BRIDGE_H
#define ZOVA_WASM_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
/* Private single-worker interface. Returned bytes remain owned by the bridge
 * until the next operation or close. Copy them before making another call. */
int zw_create(void);
#ifdef ZOVA_WASM_OPFS
int zw_open_file(int exists);
#endif
int zw_close(void);
void zw_release(void);
int zw_exec(const char *sql);
int zw_prepare(const char *sql);
int zw_finalize(void);
int zw_bind(int index, int type, int64_t integer, double number, const uint8_t *data, size_t len);
int zw_step(void);
int zw_count(int parameters);
int zw_name(int index);
int zw_column(int index);
int zw_kv(int operation, const uint8_t *ns, size_t ns_len, const uint8_t *key, size_t key_len, const uint8_t *value, size_t value_len);
int zw_number(void);
int64_t zw_integer(void);
double zw_float(void);
const uint8_t *zw_bytes(void);
size_t zw_length(void);
const char *zw_error(void);
const char *zw_status_name(int status);
#endif
