#ifndef ZOVA_PLUGIN_H
#define ZOVA_PLUGIN_H

#include <stdint.h>

#if defined(_WIN32)
#define ZOVA_PLUGIN_CALL __cdecl
#define ZOVA_PLUGIN_EXPORT __declspec(dllexport)
#else
#define ZOVA_PLUGIN_CALL
#define ZOVA_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define ZOVA_PLUGIN_ABI_V1 UINT32_C(1)
#define ZOVA_PLUGIN_OK INT32_C(0)
#define ZOVA_PLUGIN_ERROR INT32_C(1)
#define ZOVA_PLUGIN_OUT_OF_MEMORY INT32_C(2)
#define ZOVA_PLUGIN_INVALID_ARGUMENT INT32_C(3)
#define ZOVA_PLUGIN_HAS_UPGRADE_V1 UINT64_C(1)

/* Independent of the database format and Zova's application C ABI.
 * All calls use the platform C calling convention; C++ exceptions must not
 * cross this boundary. No structure packing overrides are permitted.
 * The host and connection handles are borrowed only for the current hook.
 * Never retain them or call them from another thread. The host copies SQL;
 * input bytes need remain valid only until exec_sql returns. No allocations
 * cross the boundary. Plugins free their own allocations before returning.
 * Hooks must not issue transaction/savepoint commands or reenter Zova APIs.
 * Nonzero hook results fail the operation; unknown statuses are generic errors.
 */
typedef struct zova_plugin_host_v1 {
    uint32_t struct_size;
    uint32_t abi_version;
    int32_t (ZOVA_PLUGIN_CALL *exec_sql)(void *connection, const char *sql, uint64_t sql_len);
} zova_plugin_host_v1;

typedef int32_t (ZOVA_PLUGIN_CALL *zova_plugin_hook_v1)(
    const zova_plugin_host_v1 *host, void *connection);

/* Return a static, immutable descriptor and NUL-terminated strings, valid until
 * library unload. No ownership transfers. Query must be side-effect-free;
 * return NULL for an unsupported host ABI. Host checks size/version/flags and
 * identity before calling hooks. All hook pointers are optional (NULL=no-op).
 * capabilities may be NULL (empty); other strings are required. flags must be
 * zero or ZOVA_PLUGIN_HAS_UPGRADE_V1. struct_size must be at least sizeof(zova_plugin_descriptor_v1); hosts
 * ignore trailing fields. A new incompatible layout uses a new ABI/entrypoint.
 */
typedef struct zova_plugin_descriptor_v1 {
    uint32_t struct_size;
    uint32_t abi_version;
    uint64_t flags;
    const char *name;
    const char *version;
    const char *storage_prefix;
    const char *zova_abi_min;
    const char *capabilities;
    zova_plugin_hook_v1 install;
    zova_plugin_hook_v1 check;
    zova_plugin_hook_v1 drop;
    zova_plugin_hook_v1 register_sql;
} zova_plugin_descriptor_v1;

/* Optional, explicitly flagged tail. Return &descriptor.base from the same
 * v1 entrypoint. Set base.struct_size to sizeof(this structure) and base.flags
 * to ZOVA_PLUGIN_HAS_UPGRADE_V1. Older hosts reject the flag, not reinterpret it.
 * from_version and base.version declare one exact forward major.minor.patch
 * path. The host rejects equal versions/downgrades. upgrade is required here;
 * use a no-op hook for a code-only update. It changes data, never extension
 * metadata or transaction boundaries. The host checks the target before
 * atomically updating metadata. Normal opens never invoke this hook.
 */
typedef struct zova_plugin_upgrade_descriptor_v1 {
    zova_plugin_descriptor_v1 base;
    const char *from_version;
    zova_plugin_hook_v1 upgrade;
} zova_plugin_upgrade_descriptor_v1;

ZOVA_PLUGIN_EXPORT const zova_plugin_descriptor_v1 *ZOVA_PLUGIN_CALL
zova_plugin_entry_v1(uint32_t host_abi_version);

#ifdef __cplusplus
}
#endif
#endif
