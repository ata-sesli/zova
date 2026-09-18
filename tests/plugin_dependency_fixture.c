// The dependency DLL for the Windows-only sibling-resolution fixture. It has
// an unqualified import name (plugin_dependency_fixture.dll) and a single
// marker export; the fixture plugin refuses to run unless this exact function
// was resolved through the import table. See build.zig and
// tests/plugin_with_dependency_fixture.c.
//
// The rogue build (-DZOVA_ROGUE_DEPENDENCY_FIXTURE) returns an error marker so
// a copy placed in the process current directory is distinguishable from the
// bundle sibling: the plugin hooks only succeed when the bundle dependency won.
#include "zova_plugin.h"

#ifdef ZOVA_ROGUE_DEPENDENCY_FIXTURE
ZOVA_PLUGIN_EXPORT int32_t ZOVA_PLUGIN_CALL zova_plugin_dependency_marker_v1(void) {
    return ZOVA_PLUGIN_ERROR;
}
#else
ZOVA_PLUGIN_EXPORT int32_t ZOVA_PLUGIN_CALL zova_plugin_dependency_marker_v1(void) {
    return ZOVA_PLUGIN_OK;
}
#endif
