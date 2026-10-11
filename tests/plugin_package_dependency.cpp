#include "zova_plugin.h"
#include <vector>

extern "C" ZOVA_PLUGIN_EXPORT int64_t zova_package_dependency_value(void) noexcept {
    try {
        const std::vector<int64_t> values{20, 22};
        return values[0] + values[1];
    } catch (...) {
        // No C++ exception may cross the plugin's C boundary.
        return 0;
    }
}
