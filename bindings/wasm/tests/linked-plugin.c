/* Links the repository's C plugin fixture into a custom browser module:
 *   ZOVA_WASM_PLUGIN_SOURCES=tests/plugin_fixture.c:bindings/wasm/tests/linked-plugin.c
 * The bridge calls zova_wasm_linked_plugins for every open and create. */
#include "zova_plugin.h"
#include <stddef.h>

const zova_plugin_descriptor_v1 *ZOVA_PLUGIN_CALL zova_plugin_entry_v1(uint32_t version);

const struct zova_plugin_descriptor_v1 *const *zova_wasm_linked_plugins(size_t *count) {
    static const struct zova_plugin_descriptor_v1 *plugins[1];
    plugins[0] = zova_plugin_entry_v1(ZOVA_PLUGIN_ABI_V1);
    *count = 1;
    return plugins;
}
