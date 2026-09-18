// The dedicated dependency-aware plugin fixture for the Windows-only contract
// that plugin dependencies resolve from the bundle directory rather than the
// process current directory. It links against plugin_dependency_fixture.dll
// (see build.zig) and only succeeds when the real dependency was loaded.
// Ordinary plugin fixtures must stay dependency-free; do not fold this back
// into tests/plugin_fixture.c.
#include "zova_plugin.h"
#include <stddef.h>

#ifdef __cplusplus
static_assert(offsetof(zova_plugin_descriptor_v1, flags) == 8, "descriptor prefix");
#else
_Static_assert(offsetof(zova_plugin_descriptor_v1, flags) == 8, "descriptor prefix");
#endif

#if defined(_WIN32)
/* Fixture plumbing only: the dependency DLL exports this marker and this
 * plugin's hooks refuse to run unless the import resolved to it. This is not
 * part of the Zova plugin contract and must stay out of include/zova_plugin.h.
 */
int32_t ZOVA_PLUGIN_CALL zova_plugin_dependency_marker_v1(void);

static int32_t ZOVA_PLUGIN_CALL install(const zova_plugin_host_v1 *host, void *db) {
    const char sql[] = "CREATE TABLE _zova_ext_c_test_data(id INTEGER)";
    if (host->abi_version != ZOVA_PLUGIN_ABI_V1 || host->struct_size < sizeof(*host))
        return ZOVA_PLUGIN_ERROR;
    if (zova_plugin_dependency_marker_v1() != ZOVA_PLUGIN_OK)
        return ZOVA_PLUGIN_ERROR;
    return host->exec_sql(db, sql, sizeof(sql) - 1);
}

static int32_t ZOVA_PLUGIN_CALL drop(const zova_plugin_host_v1 *host, void *db) {
    const char sql[] = "DROP TABLE _zova_ext_c_test_data";
    if (zova_plugin_dependency_marker_v1() != ZOVA_PLUGIN_OK)
        return ZOVA_PLUGIN_ERROR;
    return host->exec_sql(db, sql, sizeof(sql) - 1);
}
#else
static int32_t ZOVA_PLUGIN_CALL install(const zova_plugin_host_v1 *host, void *db) {
    (void)host;
    (void)db;
    return ZOVA_PLUGIN_OK;
}

static int32_t ZOVA_PLUGIN_CALL drop(const zova_plugin_host_v1 *host, void *db) {
    (void)host;
    (void)db;
    return ZOVA_PLUGIN_OK;
}
#endif

static const zova_plugin_descriptor_v1 descriptor = {
    sizeof(zova_plugin_descriptor_v1), ZOVA_PLUGIN_ABI_V1, 0,
    "c_test", "1.0.0", "_zova_ext_c_test_", "1.0.0", "",
    install, NULL, drop, NULL
};

const zova_plugin_descriptor_v1 *ZOVA_PLUGIN_CALL zova_plugin_entry_v1(uint32_t version) {
    return version == ZOVA_PLUGIN_ABI_V1 ? &descriptor : NULL;
}
