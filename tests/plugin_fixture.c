#include "zova_plugin.h"
#include <stddef.h>

#ifdef __cplusplus
static_assert(offsetof(zova_plugin_descriptor_v1, flags) == 8, "descriptor prefix");
#else
_Static_assert(offsetof(zova_plugin_descriptor_v1, flags) == 8, "descriptor prefix");
#endif

static int32_t ZOVA_PLUGIN_CALL install(const zova_plugin_host_v1 *host, void *db) {
    const char sql[] = "CREATE TABLE _zova_ext_c_test_data(id INTEGER)";
    if (host->abi_version != ZOVA_PLUGIN_ABI_V1 || host->struct_size < sizeof(*host))
        return ZOVA_PLUGIN_ERROR;
    return host->exec_sql(db, sql, sizeof(sql) - 1);
}

static int32_t ZOVA_PLUGIN_CALL drop(const zova_plugin_host_v1 *host, void *db) {
    const char sql[] = "DROP TABLE _zova_ext_c_test_data";
    return host->exec_sql(db, sql, sizeof(sql) - 1);
}

#ifdef ZOVA_UPGRADE_FIXTURE
static int32_t ZOVA_PLUGIN_CALL upgrade(const zova_plugin_host_v1 *host, void *db) {
    const char sql[] = "ALTER TABLE _zova_ext_c_test_data ADD COLUMN upgraded INTEGER DEFAULT 9";
    return host->exec_sql(db, sql, sizeof(sql) - 1);
}
static int32_t ZOVA_PLUGIN_CALL check(const zova_plugin_host_v1 *host, void *db) {
    const char sql[] = "SELECT upgraded FROM _zova_ext_c_test_data";
    return host->exec_sql(db, sql, sizeof(sql) - 1);
}
static const zova_plugin_upgrade_descriptor_v1 upgraded_descriptor = {
    { sizeof(zova_plugin_upgrade_descriptor_v1), ZOVA_PLUGIN_ABI_V1, ZOVA_PLUGIN_HAS_UPGRADE_V1,
      "c_test", "2.0.0", "_zova_ext_c_test_", "1.0.0", "", install, check, drop, NULL },
    "1.0.0", upgrade
};
#else
static const zova_plugin_descriptor_v1 descriptor = {
    sizeof(zova_plugin_descriptor_v1), ZOVA_PLUGIN_ABI_V1, 0,
    "c_test", "1.0.0", "_zova_ext_c_test_", "1.0.0", "",
    install, NULL, drop, NULL
};
#endif

const zova_plugin_descriptor_v1 *ZOVA_PLUGIN_CALL zova_plugin_entry_v1(uint32_t version) {
#ifdef ZOVA_UPGRADE_FIXTURE
    return version == ZOVA_PLUGIN_ABI_V1 ? &upgraded_descriptor.base : NULL;
#else
    return version == ZOVA_PLUGIN_ABI_V1 ? &descriptor : NULL;
#endif
}
