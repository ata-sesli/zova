#include "zova_plugin.h"
#include <networkit/GlobalState.hpp>
#include <networkit/centrality/PageRank.hpp>
#include <networkit/graph/Graph.hpp>
#include <omp.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
struct Failure { int32_t status; };
void check(int32_t status) { if (status != ZOVA_PLUGIN_OK) throw Failure{status}; }
double elapsed(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
struct Node { int64_t key; std::string id; };
struct Cursor {
    std::vector<Node> nodes;
    std::vector<double> scores;
    uint64_t position = 0, iterations = 0;
    bool converged = false;
    double load_ms = 0, convert_ms = 0, compute_ms = 0, result_ms = 0;
};
struct Load {
    Cursor &cursor;
    std::vector<std::pair<int64_t, int64_t>> edges;
    uint64_t max_nodes, max_edges;
    int32_t error = ZOVA_PLUGIN_OK;
};
bool positive(const zova_plugin_value_v1 &value) {
    return value.kind == ZOVA_PLUGIN_VALUE_INTEGER && value.integer > 0;
}
int32_t ZOVA_PLUGIN_CALL receive_nodes(void *raw, const zova_plugin_value_v1 *values,
                                     uint64_t count) noexcept {
    auto &load = *static_cast<Load *>(raw);
    try {
        if (!values || count != 4 || !positive(values[0]) ||
            values[1].kind != ZOVA_PLUGIN_VALUE_TEXT || !values[1].bytes ||
            values[1].bytes_len == 0 || values[1].bytes_len > 512)
            throw Failure{ZOVA_PLUGIN_ERROR};
        if (load.cursor.nodes.size() >= load.max_nodes) throw Failure{ZOVA_PLUGIN_LIMIT};
        load.cursor.nodes.push_back({values[0].integer,
            std::string(reinterpret_cast<const char *>(values[1].bytes), values[1].bytes_len)});
        return ZOVA_PLUGIN_OK;
    } catch (const Failure &failure) { load.error = failure.status; }
      catch (const std::bad_alloc &) { load.error = ZOVA_PLUGIN_OUT_OF_MEMORY; }
      catch (...) { load.error = ZOVA_PLUGIN_ERROR; }
    return ZOVA_PLUGIN_CANCELED;
}
int32_t ZOVA_PLUGIN_CALL receive_edges(void *raw, const zova_plugin_value_v1 *values,
                                     uint64_t count) noexcept {
    auto &load = *static_cast<Load *>(raw);
    try {
        if (!values || count != 5 || !positive(values[0]) ||
            !positive(values[1]) || !positive(values[3])) throw Failure{ZOVA_PLUGIN_ERROR};
        if (load.edges.size() >= load.max_edges) throw Failure{ZOVA_PLUGIN_LIMIT};
        load.edges.emplace_back(values[1].integer, values[3].integer);
        return ZOVA_PLUGIN_OK;
    } catch (const Failure &failure) { load.error = failure.status; }
      catch (const std::bad_alloc &) { load.error = ZOVA_PLUGIN_OUT_OF_MEMORY; }
      catch (...) { load.error = ZOVA_PLUGIN_ERROR; }
    return ZOVA_PLUGIN_CANCELED;
}
template <typename Service>
const Service *service(const zova_plugin_host_v1 *host, void *connection, uint32_t id) {
    if (!host || host->struct_size < sizeof(zova_plugin_service_host_v1))
        throw Failure{ZOVA_PLUGIN_UNSUPPORTED};
    const auto *extended = reinterpret_cast<const zova_plugin_service_host_v1 *>(host);
    const void *result = nullptr;
    check(extended->get_service(connection, id, 1, sizeof(Service), &result));
    if (!result) throw Failure{ZOVA_PLUGIN_UNSUPPORTED};
    return static_cast<const Service *>(result);
}
void scan(const zova_plugin_data_service_v1 *data, void *connection,
          zova_plugin_bytes_v1 name, uint32_t operation, Load &load,
          zova_plugin_row_v1 row) {
    zova_plugin_data_request_v1 request{};
    request.struct_size = sizeof(request); request.operation = operation;
    request.name = name; request.row_limit = 256; request.byte_limit = 1024 * 1024;
    request.row = row; request.user_data = &load;
    do {
        zova_plugin_data_page_v1 page{};
        const auto status = data->read(connection, &request, &page);
        check(load.error); check(status);
        if (!page.has_more) break;
        if (!page.rows || page.next.created_order <= 0 || page.next.key <= 0 ||
            std::pair{page.next.created_order, page.next.key} <=
            std::pair{request.after.created_order, request.after.key}) throw Failure{ZOVA_PLUGIN_ERROR};
        request.after = page.next;
    } while (true);
}
// Each bundle owns a hidden static NetworKit instance. Serialize computations
// and suppress its temporary process-wide SIGINT handler, using its public
// GlobalState controls. Restore both that state and the calling OpenMP task's
// thread budget even on exceptions. No host services run under this guard.
std::mutex computation_mutex;
struct ComputeGuard {
    std::unique_lock<std::mutex> lock{computation_mutex};
    int threads = omp_get_max_threads();
    bool root_set = NetworKit::GlobalState::getRootSet();
    ComputeGuard() {
        omp_set_num_threads(1);
        NetworKit::GlobalState::setRootSet(true);
    }
    ~ComputeGuard() {
        NetworKit::GlobalState::setRootSet(root_set);
        omp_set_num_threads(threads);
    }
};
int32_t ZOVA_PLUGIN_CALL open(const zova_plugin_host_v1 *host, void *connection,
                            void *, const zova_plugin_value_v1 *args,
                            uint64_t count, void **out) noexcept {
    if (!out) return ZOVA_PLUGIN_INVALID_ARGUMENT;
    *out = nullptr;
    try {
        if (!args || count != 6 || args[0].kind != ZOVA_PLUGIN_VALUE_TEXT ||
            !args[0].bytes || !args[0].bytes_len || args[0].bytes_len > 255 ||
            args[1].kind != ZOVA_PLUGIN_VALUE_FLOAT || !std::isfinite(args[1].real) ||
            args[1].real < 0 || args[1].real >= 1 ||
            args[2].kind != ZOVA_PLUGIN_VALUE_FLOAT || !std::isfinite(args[2].real) ||
            args[2].real <= 0 || args[2].real > 1 ||
            !positive(args[3]) || args[3].integer > 1000 ||
            args[4].kind != ZOVA_PLUGIN_VALUE_INTEGER || args[4].integer < 0 || args[4].integer > 250000 ||
            args[5].kind != ZOVA_PLUGIN_VALUE_INTEGER || args[5].integer < 0 || args[5].integer > 1000000)
            throw Failure{ZOVA_PLUGIN_INVALID_ARGUMENT};
        const auto start = Clock::now();
        const auto *data = service<zova_plugin_data_service_v1>(host, connection, ZOVA_PLUGIN_SERVICE_DATA);
        auto cursor = std::make_unique<Cursor>();
        Load load{*cursor, {}, static_cast<uint64_t>(args[4].integer), static_cast<uint64_t>(args[5].integer)};
        const zova_plugin_bytes_v1 name{args[0].bytes, args[0].bytes_len};
        scan(data, connection, name, ZOVA_PLUGIN_GRAPH_NODES_SCAN, load, receive_nodes);
        scan(data, connection, name, ZOVA_PLUGIN_GRAPH_EDGES_SCAN, load, receive_edges);
        const auto n = cursor->nodes.size();
        // Bound potential iterative work, including hostile nearly-unit damping.
        if ((n + load.edges.size()) * static_cast<uint64_t>(args[3].integer) > 100000000)
            throw Failure{ZOVA_PLUGIN_LIMIT};
        cursor->load_ms = elapsed(start);
        if (!n) { *out = cursor.release(); return ZOVA_PLUGIN_OK; }
        auto phase = Clock::now();
        std::unordered_map<int64_t, NetworKit::node> mapping;
        mapping.reserve(n);
        for (size_t i = 0; i < n; ++i)
            if (!mapping.emplace(cursor->nodes[i].key, i).second) throw Failure{ZOVA_PLUGIN_ERROR};
        for (auto &edge : load.edges) {
            const auto from = mapping.find(edge.first), to = mapping.find(edge.second);
            if (from == mapping.end() || to == mapping.end()) throw Failure{ZOVA_PLUGIN_ERROR};
            edge = {static_cast<int64_t>(from->second), static_cast<int64_t>(to->second)};
        }
        std::sort(load.edges.begin(), load.edges.end());
        NetworKit::Graph graph(n, true, true);
        // Multiple public edge types between the same endpoints contribute
        // multiplicity, not accidental multiedges or discarded topology.
        for (size_t i = 0; i < load.edges.size();) {
            size_t end = i + 1;
            while (end < load.edges.size() && load.edges[end] == load.edges[i]) ++end;
            graph.addEdge(load.edges[i].first, load.edges[i].second, static_cast<double>(end - i));
            i = end;
        }
        cursor->convert_ms = elapsed(phase);
        phase = Clock::now();
        ComputeGuard guard;
        NetworKit::PageRank algorithm(graph, args[1].real, args[2].real, false,
                                     NetworKit::PageRank::DISTRIBUTE_SINKS);
        algorithm.maxIterations = args[3].integer;
        algorithm.norm = NetworKit::PageRank::L1_NORM;
        algorithm.run();
        cursor->iterations = algorithm.numberOfIterations();
        cursor->compute_ms = elapsed(phase);
        phase = Clock::now();
        cursor->scores = algorithm.scores();
        double sum = 0;
        for (double score : cursor->scores) {
            if (!std::isfinite(score) || score < 0) throw Failure{ZOVA_PLUGIN_ERROR};
            sum += score;
        }
        if (!std::isfinite(sum) || sum <= 0) throw Failure{ZOVA_PLUGIN_ERROR};
        for (double &score : cursor->scores) score /= sum;
        // The upstream stopping condition also fires at maxIterations. Report
        // convergence independently using the final vector's L1 residual.
        double sink = 0, residual = 0;
        graph.forNodes([&](NetworKit::node u) {
            if (!graph.degree(u)) sink += cursor->scores[u];
        });
        graph.forNodes([&](NetworKit::node u) {
            double next = (1 - args[1].real + args[1].real * sink) / n;
            graph.forInEdgesOf(u, [&](NetworKit::node, NetworKit::node v, double weight) {
                next += args[1].real * cursor->scores[v] * weight / graph.weightedDegree(v);
            });
            residual += std::abs(next - cursor->scores[u]);
        });
        cursor->converged = residual <= args[2].real;
        cursor->result_ms = elapsed(phase);
        *out = cursor.release();
        return ZOVA_PLUGIN_OK;
    } catch (const Failure &failure) { return failure.status; }
      catch (const std::bad_alloc &) { return ZOVA_PLUGIN_OUT_OF_MEMORY; }
      catch (...) { return ZOVA_PLUGIN_ERROR; }
}
int32_t ZOVA_PLUGIN_CALL next(const zova_plugin_host_v1 *, void *, void *raw,
                            zova_plugin_row_v1 row, void *context, uint32_t *has_row) noexcept {
    if (!has_row) return ZOVA_PLUGIN_INVALID_ARGUMENT;
    *has_row = 0;
    if (!raw || !row) return ZOVA_PLUGIN_INVALID_ARGUMENT;
    const auto &cursor = *static_cast<Cursor *>(raw);
    if (cursor.position == cursor.nodes.size()) return ZOVA_PLUGIN_OK;
    const auto &node = cursor.nodes[cursor.position];
    zova_plugin_value_v1 values[9]{};
    values[0].kind = ZOVA_PLUGIN_VALUE_INTEGER; values[0].integer = node.key;
    values[1].kind = ZOVA_PLUGIN_VALUE_TEXT;
    values[1].bytes = reinterpret_cast<const uint8_t *>(node.id.data()); values[1].bytes_len = node.id.size();
    values[2].kind = ZOVA_PLUGIN_VALUE_FLOAT; values[2].real = cursor.scores[cursor.position];
    values[3].kind = ZOVA_PLUGIN_VALUE_INTEGER; values[3].integer = cursor.iterations;
    values[4].kind = ZOVA_PLUGIN_VALUE_INTEGER; values[4].integer = cursor.converged;
    const double times[] = {cursor.load_ms, cursor.convert_ms, cursor.compute_ms, cursor.result_ms};
    for (size_t i = 0; i < 4; ++i) { values[i + 5].kind = ZOVA_PLUGIN_VALUE_FLOAT; values[i + 5].real = times[i]; }
    const auto status = row(context, values, 9);
    if (status != ZOVA_PLUGIN_OK) return status;
    ++static_cast<Cursor *>(raw)->position;
    *has_row = 1;
    return ZOVA_PLUGIN_OK;
}
void ZOVA_PLUGIN_CALL close(void *raw) noexcept { delete static_cast<Cursor *>(raw); }
zova_plugin_operation_column_v1 column(const char *name, uint32_t kind, size_t length) {
    return {{reinterpret_cast<const uint8_t *>(name), length}, kind, 0};
}
int32_t ZOVA_PLUGIN_CALL register_sql(const zova_plugin_host_v1 *host, void *connection) noexcept {
    try {
        const auto *operations = service<zova_plugin_operation_service_v1>(host, connection, ZOVA_PLUGIN_SERVICE_OPERATIONS);
        const zova_plugin_operation_column_v1 args[] = {
            column("graph", 3, 5), column("damping", 2, 7), column("tolerance", 2, 9),
            column("max_iterations", 1, 14), column("max_nodes", 1, 9), column("max_edges", 1, 9)};
        const zova_plugin_operation_column_v1 columns[] = {
            column("node_key", 1, 8), column("node_id", 3, 7), column("score", 2, 5),
            column("iterations", 1, 10), column("converged", 1, 9), column("load_ms", 2, 7),
            column("convert_ms", 2, 10), column("compute_ms", 2, 10), column("result_ms", 2, 9)};
        zova_plugin_operation_v1 operation{};
        operation.struct_size = sizeof(operation); operation.kind = ZOVA_PLUGIN_OPERATION_TABLE;
        operation.flags = ZOVA_PLUGIN_OPERATION_APPROXIMATE | ZOVA_PLUGIN_OPERATION_ORDERED;
        operation.name = {reinterpret_cast<const uint8_t *>("pagerank"), 8};
        operation.arguments = args; operation.argument_count = 6;
        operation.columns = columns; operation.column_count = 9;
        operation.open = open; operation.next = next; operation.close = close;
        return operations->register_operation(connection, &operation);
    } catch (const Failure &failure) { return failure.status; }
      catch (...) { return ZOVA_PLUGIN_ERROR; }
}
} // namespace

static const zova_plugin_descriptor_v1 descriptor = {
    sizeof(zova_plugin_descriptor_v1), ZOVA_PLUGIN_ABI_V1,
    ZOVA_PLUGIN_REQUIRES_DATA_V1 | ZOVA_PLUGIN_REQUIRES_OPERATIONS_V1,
    "networkit", "1.0.0", "_zova_ext_networkit_", "1.1.0", "", nullptr, nullptr, nullptr, register_sql
};
extern "C" ZOVA_PLUGIN_EXPORT const zova_plugin_descriptor_v1 *ZOVA_PLUGIN_CALL
zova_plugin_entry_v1(uint32_t version) {
    return version == ZOVA_PLUGIN_ABI_V1 ? &descriptor : nullptr;
}
