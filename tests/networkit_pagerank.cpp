#include "zova.h"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <vector>
#if defined(__unix__) || defined(__APPLE__)
#include <sys/resource.h>
#endif

static void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
static void ok(zova_status status) {
    if (status != ZOVA_OK) throw std::runtime_error(zova_status_name(status));
}
struct Statement {
    zova_statement *value = nullptr;
    Statement(zova_database *db, const std::string &sql) {
        zova_database_prepare_request request{db, sql.c_str(), &value};
        ok(zova_database_prepare(&request));
    }
    ~Statement() { if (value) zova_statement_finalize(value); }
    void finalize() { ok(zova_statement_finalize(value)); value = nullptr; }
    bool step() {
        zova_step_result result;
        zova_statement_step_request request{value, &result};
        ok(zova_statement_step(&request));
        return result == ZOVA_STEP_ROW;
    }
    int64_t integer(int column) {
        int64_t result;
        zova_statement_column_int64_request request{value, column, &result};
        ok(zova_statement_column_int64(&request)); return result;
    }
    double real(int column) {
        double result;
        zova_statement_column_double_request request{value, column, &result};
        ok(zova_statement_column_double(&request)); return result;
    }
    std::string text(int column) {
        zova_text result{};
        zova_statement_column_text_request request{value, column, &result};
        ok(zova_statement_column_text(&request));
        std::string copy(result.data, result.len);
        zova_text_free(&result); return copy;
    }
};
static void exec(zova_database *db, const char *sql) {
    zova_database_exec_request request{db, sql};
    const auto status = zova_database_exec(&request);
    if (status != ZOVA_OK) std::fprintf(stderr, "exec failed: %s: %s\n", sql, zova_database_last_error_message(db));
    ok(status);
}
static std::vector<int64_t> nodes(zova_database *db, const char *graph,
                                const std::vector<std::string> &ids) {
    zova_graph_create_request create{db, graph}; ok(zova_graph_create(&create));
    std::vector<zova_graph_node_input> inputs;
    for (const auto &id : ids) inputs.push_back({graph, id.c_str(), "node", 0, nullptr, nullptr});
    std::vector<int64_t> keys(ids.size());
    zova_graph_node_put_many_keyed_request put{db, inputs.data(), inputs.size(), keys.data(), keys.size()};
    ok(zova_graph_node_put_many_keyed(&put)); return keys;
}
static void edge(zova_database *db, const char *graph, const char *from,
                 const char *to, const char *type = "link") {
    zova_graph_edge_put_request put{db, graph, from, type, to}; ok(zova_graph_edge_put(&put));
}
struct Score { int64_t key; std::string id; double score; int64_t iterations, converged; };
static std::vector<Score> scores(zova_database *db, const std::string &graph,
                                int iterations = 200, int max_nodes = 10000, int max_edges = 40000) {
    const std::string sql = "SELECT * FROM zova_networkit_pagerank('" + graph +
        "',0.85,1e-12," + std::to_string(iterations) + "," +
        std::to_string(max_nodes) + "," + std::to_string(max_edges) + ")";
    Statement statement(db, sql);
    std::vector<Score> result;
    while (statement.step()) result.push_back({statement.integer(0), statement.text(1),
        statement.real(2), statement.integer(3), statement.integer(4)});
    return result;
}
static void sql_error(zova_database *db, const char *sql) {
    zova_statement *statement = nullptr;
    zova_database_prepare_request prepare{db, sql, &statement};
    auto status = zova_database_prepare(&prepare);
    if (status == ZOVA_OK) {
        zova_step_result step;
        zova_statement_step_request request{statement, &step};
        status = zova_statement_step(&request);
        zova_statement_finalize(statement);
    }
    require(status != ZOVA_OK, "invalid PageRank input must fail");
}
static void probability(const std::vector<Score> &rank) {
    double sum = 0;
    for (const auto &row : rank) {
        require(std::isfinite(row.score) && row.score >= 0, "finite nonnegative probability");
        sum += row.score;
    }
    require(rank.empty() || std::abs(sum - 1) < 1e-10, "probabilities sum to one");
}
int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) return 2;
    zova_database *db = nullptr;
    try {
        const char *bundles[] = {argv[1]};
        zova_message message{};
        zova_extension_bundle_request trust{argv[1], argv[3], &message};
        ok(zova_extension_bundle_trust(&trust)); zova_message_free(&message);
        zova_database_open_extensions_request open{argv[2], 0, 0, bundles, 1, argv[3], &db, &message};
        const bool bound = argc == 5 && std::string(argv[4]) == "bound";
        ok(bound ? zova_database_open_with_extensions(&open) : zova_database_create_with_extensions(&open));
        zova_message_free(&message);
        if (argc == 5 && std::string(argv[4]) == "create") { ok(zova_database_close(db)); return 0; }
        zova_database_extension_request install{db, "networkit"}; ok(zova_database_extension_install(&install));
        auto keys = nodes(db, "cycle", {"last", "first", "middle"});
        edge(db, "cycle", "last", "first"); edge(db, "cycle", "first", "middle"); edge(db, "cycle", "middle", "last");
        auto rank = scores(db, "cycle");
        require(rank.size() == 3, "PageRank must return all nodes");
        for (size_t i = 0; i < rank.size(); ++i) {
            require(rank[i].key == keys[i], "input identity and created ordering");
            require(std::abs(rank[i].score - 1.0 / 3) < 1e-10, "cycle score");
            require(rank[i].converged == 1, "cycle converged");
        }
        nodes(db, "dangling", {"a", "b", "isolated"});
        edge(db, "dangling", "a", "b");
        rank = scores(db, "dangling"); probability(rank);
        require(std::abs(rank[0].score - 0.25974025974026) < 1e-10, "dangling source");
        require(std::abs(rank[1].score - 0.48051948051948) < 1e-10, "dangling destination");
        require(std::abs(rank[2].score - rank[0].score) < 1e-10, "isolated node participates");
        rank = scores(db, "dangling", 1); probability(rank);
        require(rank[0].iterations == 1 && rank[0].converged == 0, "iteration cap is not convergence");
        nodes(db, "isolated", {"\xce\xb1", "id'quoted"});
        rank = scores(db, "isolated"); probability(rank);
        require(rank[0].id == "\xce\xb1" && rank[1].id == "id'quoted", "public identities preserved");
        require(rank[0].score == 0.5 && rank[1].score == 0.5, "all dangling nodes uniform");
        nodes(db, "empty", {}); require(scores(db, "empty", 1, 0, 0).empty(), "empty graph");
        nodes(db, "self", {"one"}); edge(db, "self", "one", "one");
        rank = scores(db, "self"); require(rank[0].score == 1, "self loop");
        nodes(db, "parallel", {"a", "b", "c"});
        edge(db, "parallel", "a", "b", "first"); edge(db, "parallel", "a", "b", "second");
        edge(db, "parallel", "a", "c"); edge(db, "parallel", "b", "a"); edge(db, "parallel", "c", "a");
        rank = scores(db, "parallel"); probability(rank);
        require(rank[1].score > rank[2].score, "typed edges retain multiplicity");
        require(std::abs(rank[0].score - 0.9 / 1.85) < 1e-10, "weighted center score");
        require(std::abs(rank[1].score - (0.05 + 0.85 * (2.0 / 3) * rank[0].score)) < 1e-10, "weighted destination score");
        const auto again = scores(db, "parallel");
        for (size_t i = 0; i < rank.size(); ++i) require(rank[i].score == again[i].score, "deterministic single-thread scores");
        for (const char *sql : {
            "SELECT * FROM zova_networkit_pagerank('missing',0.85,1e-8,10,10,10)",
            "SELECT * FROM zova_networkit_pagerank('cycle',1.0,1e-8,10,10,10)",
            "SELECT * FROM zova_networkit_pagerank('cycle',0.85,0.0,10,10,10)",
            "SELECT * FROM zova_networkit_pagerank('cycle',0.85,1e-8,0,10,10)",
            "SELECT * FROM zova_networkit_pagerank('cycle',0.85,1e-8,10,2,10)",
            "SELECT * FROM zova_networkit_pagerank('cycle',0.85,1e-8,10,10,2)"}) sql_error(db, sql);
        require(scores(db, "cycle").size() == 3, "error cleanup permits subsequent calls");
        for (int i = 0; i < 20; ++i) {
            Statement partial(db, "SELECT * FROM zova_networkit_pagerank('cycle',0.85,1e-8,10,10,10) LIMIT 1");
            require(partial.step(), "early finalization row");
            require(zova_database_close(db) == ZOVA_MISUSE, "live result owns its library");
        }
        // A caller-held WAL snapshot must never be replaced by a newest cache.
        std::puts("PageRank semantics/limits passed; checking WAL snapshots");
        exec(db, "PRAGMA main.journal_mode=WAL");
        exec(db, "BEGIN");
        require(scores(db, "cycle").size() == 3, "pin old source snapshot");
        zova_database *writer = nullptr;
        open.out_db = &writer;
        ok(zova_database_open_with_extensions(&open)); zova_message_free(&message);
        zova_graph_node_put_request extra{writer, "cycle", "new", "node", 0, nullptr, nullptr};
        std::puts("PageRank pinned snapshot; committing writer topology");
        const auto write_status = zova_graph_node_put(&extra);
        if (write_status != ZOVA_OK) std::fprintf(stderr, "writer node put: %s\n", zova_database_last_error_message(writer));
        ok(write_status); ok(zova_database_close(writer));
        require(scores(db, "cycle").size() == 3, "older snapshot stays correct");
        exec(db, "COMMIT"); require(scores(db, "cycle").size() == 4, "new snapshot sees change");
        exec(db, "BEGIN");
        extra.db = db; extra.node_id = "provisional"; ok(zova_graph_node_put(&extra));
        require(scores(db, "cycle").size() == 5, "caller-visible uncommitted topology");
        exec(db, "ROLLBACK"); require(scores(db, "cycle").size() == 4, "rollback excludes provisional node");
        if (argc == 5 && std::string(argv[4]) == "bench") {
            std::vector<std::string> ids;
            for (int i = 0; i < 2048; ++i) ids.push_back("n" + std::to_string(i));
            nodes(db, "bench", ids);
            std::vector<zova_graph_edge_input> inputs;
            for (size_t i = 0; i < ids.size(); ++i)
                for (size_t jump : {1, 3, 11, 29})
                    inputs.push_back({"bench", ids[i % 17 == 0 ? 0 : i].c_str(), "link", ids[(4 * i + jump) % ids.size()].c_str()});
            zova_graph_edge_put_many_request put{db, inputs.data(), inputs.size()};
            ok(zova_graph_edge_put_many(&put));
            for (int sample = -1; sample < 3; ++sample) {
                const auto start = std::chrono::steady_clock::now();
                Statement query(db, "SELECT * FROM zova_networkit_pagerank('bench',0.85,1e-10,200,2048,8192)");
                double times[4]{}; size_t count = 0; double sum = 0;
                while (query.step()) {
                    if (!count) for (int j = 0; j < 4; ++j) times[j] = query.real(j + 5);
                    require(query.integer(0) > 0 && !query.text(1).empty(), "profile consumes identities");
                    sum += query.real(2); ++count;
                }
                query.finalize();
                const auto total = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
                require(count == 2048 && std::abs(sum - 1) < 1e-10, "profile parity");
                if (sample >= 0) std::printf("PROFILE sample=%d nodes=%zu edges=8192 load_ms=%.6f convert_ms=%.6f compute_ms=%.6f result_ms=%.6f total_ms=%.6f\n",
                    sample, count, times[0], times[1], times[2], times[3], total);
            }
#if defined(__unix__) || defined(__APPLE__)
            rusage usage{}; getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
            std::printf("PEAK_RSS_MiB %.3f\n", usage.ru_maxrss / (1024.0 * 1024.0));
#else
            std::printf("PEAK_RSS_MiB %.3f\n", usage.ru_maxrss / 1024.0);
#endif
#endif
        }
        ok(zova_database_close(db)); db = nullptr;
        open.out_db = &db; open.flags = ZOVA_OPEN_READ_ONLY;
        const auto reopen_status = zova_database_open_with_extensions(&open);
        if (reopen_status != ZOVA_OK) std::fprintf(stderr, "read-only reopen: %s\n", message.data ? message.data : "no diagnostic");
        ok(reopen_status); zova_message_free(&message);
        std::puts("read-only reopen succeeded");
        probability(scores(db, "cycle")); ok(zova_database_close(db)); db = nullptr;
        std::puts("NetworKit PageRank behavior: ok");
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "PageRank test failed: %s\n", error.what());
        if (db) zova_database_close(db);
        return 1;
    }
}
