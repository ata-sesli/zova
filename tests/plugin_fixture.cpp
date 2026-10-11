// Compile the same descriptor and hooks as C++ to verify the authoring header.
#ifdef ZOVA_PACKAGE_DEPENDENCY
#include <stdint.h>
extern "C" int64_t zova_package_dependency_value(void) noexcept;
#endif
#include "plugin_fixture.c"
