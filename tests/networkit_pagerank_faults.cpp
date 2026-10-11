#include "zova_plugin.h"
#include <csignal>
#include <cstdio>
#include <stdexcept>
#include <filesystem>
#include <omp.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {
struct HostState {
    zova_plugin_operation_open_v1 open = nullptr;
    zova_plugin_operation_next_v1 next = nullptr;
    zova_plugin_operation_close_v1 close = nullptr;
    int fault = 0;
};
void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
int32_t ZOVA_PLUGIN_CALL capture(void *raw, const zova_plugin_operation_v1 *operation) {
    auto &state = *static_cast<HostState *>(raw);
    state.open = operation->open; state.next = operation->next; state.close = operation->close;
    return ZOVA_PLUGIN_OK;
}
int32_t ZOVA_PLUGIN_CALL read(void *raw, const zova_plugin_data_request_v1 *request,
                            zova_plugin_data_page_v1 *page) {
    auto &state = *static_cast<HostState *>(raw);
    *page = {};
    zova_plugin_value_v1 row[5]{};
    if (request->operation == ZOVA_PLUGIN_GRAPH_NODES_SCAN) {
        row[0].kind = 1; row[0].integer = 77;
        row[1].kind = 3; row[1].bytes = reinterpret_cast<const uint8_t *>("node"); row[1].bytes_len = 4;
        row[2] = row[1]; row[3].kind = 1; row[3].integer = 5;
        auto status = request->row(request->user_data, row, 4);
        if (status != 0) return status;
        // A real host may fail after having delivered partial rows. The plugin
        // must discard them, not publish an incompletely allocated cursor.
        if (state.fault == 1) return ZOVA_PLUGIN_OUT_OF_MEMORY;
        if (state.fault == 2) return ZOVA_PLUGIN_CANCELED;
        page->rows = 1; return 0;
    }
    if (state.fault == 3) return ZOVA_PLUGIN_ERROR;
    row[0].kind = 1; row[0].integer = 99;
    row[1].kind = 1; row[1].integer = 77;
    row[2].kind = 3; row[2].bytes = reinterpret_cast<const uint8_t *>("link"); row[2].bytes_len = 4;
    row[3].kind = 1; row[3].integer = state.fault == 4 ? 88 : 77;
    row[4].kind = 1; row[4].integer = 8;
    auto status = request->row(request->user_data, row, 5);
    if (status == 0) page->rows = 1;
    return status;
}
const zova_plugin_data_service_v1 data{sizeof(data), 1, read};
const zova_plugin_operation_service_v1 operations{sizeof(operations), 1, capture};
int32_t ZOVA_PLUGIN_CALL service(void *, uint32_t id, uint32_t, uint32_t, const void **out) {
    *out = id == ZOVA_PLUGIN_SERVICE_DATA ? static_cast<const void *>(&data) :
        id == ZOVA_PLUGIN_SERVICE_OPERATIONS ? static_cast<const void *>(&operations) : nullptr;
    return *out ? ZOVA_PLUGIN_OK : ZOVA_PLUGIN_UNSUPPORTED;
}
void handler(int) {}
int32_t ZOVA_PLUGIN_CALL canceled_row(void *, const zova_plugin_value_v1 *, uint64_t) { return ZOVA_PLUGIN_CANCELED; }
int32_t ZOVA_PLUGIN_CALL receive(void *, const zova_plugin_value_v1 *values, uint64_t count) {
    if (count != 9 || values[0].integer != 77 || values[2].real != 1) return ZOVA_PLUGIN_ERROR;
    return 0;
}
} // namespace

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    try {
#ifdef _WIN32
        auto library = LoadLibraryExW(std::filesystem::path(argv[1]).c_str(), nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        require(library != nullptr, "load plugin");
        auto entry = reinterpret_cast<const zova_plugin_descriptor_v1 *(ZOVA_PLUGIN_CALL *)(uint32_t)>(GetProcAddress(library, "zova_plugin_entry_v1"));
#else
        auto library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        require(library != nullptr, "load plugin");
        auto entry = reinterpret_cast<const zova_plugin_descriptor_v1 *(*)(uint32_t)>(dlsym(library, "zova_plugin_entry_v1"));
#endif
        require(entry != nullptr, "entrypoint");
        const auto *descriptor = entry(1);
        require(descriptor && !entry(99), "ABI negotiation");
        HostState state;
        zova_plugin_service_host_v1 host{{sizeof(host), 1, nullptr}, service};
        require(descriptor->register_sql(&host.base, &state) == 0, "register operation");
        zova_plugin_value_v1 args[6]{};
        args[0].kind = 3; args[0].bytes = reinterpret_cast<const uint8_t *>("fixture"); args[0].bytes_len = 7;
        args[1].kind = 2; args[1].real = 0.85; args[2].kind = 2; args[2].real = 1e-10;
        args[3].kind = 1; args[3].integer = 10; args[4].kind = 1; args[4].integer = 1; args[5].kind = 1; args[5].integer = 1;
        const int32_t expected[] = {0, ZOVA_PLUGIN_OUT_OF_MEMORY, ZOVA_PLUGIN_CANCELED, ZOVA_PLUGIN_ERROR, ZOVA_PLUGIN_ERROR};
        for (int fault = 1; fault <= 4; ++fault) {
            state.fault = fault;
            void *cursor = reinterpret_cast<void *>(1);
            require(state.open(&host.base, &state, nullptr, args, 6, &cursor) == expected[fault], "fault status preserved");
            require(cursor == nullptr, "failed open publishes no cursor");
        }
        state.fault = 0;
        const int threads = omp_get_max_threads(); omp_set_num_threads(2);
        auto prior_handler = std::signal(SIGINT, handler);
        void *cursor = nullptr;
        require(state.open(&host.base, &state, nullptr, args, 6, &cursor) == 0 && cursor, "success after faults");
        require(omp_get_max_threads() == 2, "thread policy restored");
        require(std::signal(SIGINT, prior_handler) == handler, "process signal handler preserved");
        omp_set_num_threads(threads);
        uint32_t has_row = 99;
        require(state.next(&host.base, &state, cursor, canceled_row, nullptr, &has_row) == ZOVA_PLUGIN_CANCELED && has_row == 0, "row cancellation");
        require(state.next(&host.base, &state, cursor, receive, nullptr, &has_row) == 0 && has_row == 1, "failed delivery does not advance");
        require(state.next(&host.base, &state, cursor, receive, nullptr, &has_row) == 0 && has_row == 0, "EOF");
        state.close(cursor);
#ifdef _WIN32
        FreeLibrary(library);
#else
        dlclose(library);
#endif
        std::puts("NetworKit PageRank faults/ownership: ok");
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "PageRank fault test: %s\n", error.what()); return 1;
    }
}
