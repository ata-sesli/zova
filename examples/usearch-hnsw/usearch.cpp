#include "index.hpp"
#include <sstream>
namespace {
using namespace reference;
int32_t ZOVA_PLUGIN_CALL install(const zova_plugin_host_v1 *h, void *c) noexcept {
    const char *sql = "CREATE TABLE _zova_ext_usearch_indexes(name TEXT PRIMARY KEY,dims INTEGER NOT NULL,type TEXT NOT NULL,metric TEXT NOT NULL,connectivity INTEGER NOT NULL,expansion INTEGER NOT NULL,incarnation BLOB NOT NULL,token BLOB NOT NULL,revision INTEGER NOT NULL,size INTEGER NOT NULL,hash BLOB NOT NULL);"
        "CREATE TABLE _zova_ext_usearch_chunks(name TEXT NOT NULL,ordinal INTEGER NOT NULL,data BLOB NOT NULL,PRIMARY KEY(name,ordinal));";
    return h->exec_sql(c, sql, std::strlen(sql));
}
int32_t ZOVA_PLUGIN_CALL drop(const zova_plugin_host_v1 *h, void *c) noexcept {
    const char *sql = "DROP TABLE _zova_ext_usearch_chunks; DROP TABLE _zova_ext_usearch_indexes;";
    return h->exec_sql(c, sql, std::strlen(sql));
}
int32_t ZOVA_PLUGIN_CALL verify(const zova_plugin_host_v1 *h, void *c) noexcept {
    return boundary([&] {
        Host host(h, c); std::vector<std::string> names;
        host.sql("SELECT name FROM main._zova_ext_usearch_indexes LIMIT 257", {}, [&](auto v, auto n) {
            require(n == 1 && names.size() < 256, ZOVA_PLUGIN_LIMIT); names.push_back(string(v[0]));
        });
        for (const auto &name : names) load(host, name, stored(host, name));
    });
}
int32_t ZOVA_PLUGIN_CALL rebuild(const zova_plugin_host_v1 *h, void *c, zova_plugin_bytes_v1) noexcept {
    return boundary([&] {
        Host host(h, c); struct Entry { std::string name; size_t m, ef; }; std::vector<Entry> entries;
        host.sql("SELECT name,connectivity,expansion FROM main._zova_ext_usearch_indexes LIMIT 257", {}, [&](auto v, auto n) {
            require(n == 3 && entries.size() < 256 && v[1].kind == 1 && v[2].kind == 1 && v[1].integer >= 2 &&
                    v[1].integer <= 64 && v[2].integer >= v[1].integer && v[2].integer <= 1024);
            entries.push_back({string(v[0]), size_t(v[1].integer), size_t(v[2].integer)});
        });
        for (const auto &entry : entries) {
            auto config = metadata(host, entry.name); config.connectivity = entry.m; config.expansion = entry.ef;
            Times times; persist(host, entry.name, *build(host, entry.name, config, times), times);
        }
    });
}
int32_t ZOVA_PLUGIN_CALL build_operation(const zova_plugin_host_v1 *h, void *c, void *, const zova_plugin_operation_call_v1 *call) noexcept {
    return boundary([&] {
        require(call && call->arguments && call->argument_count == 3, ZOVA_PLUGIN_INVALID_ARGUMENT);
        auto a = call->arguments; auto name = string(a[0]);
        require(!name.empty() && a[1].kind == 1 && a[2].kind == 1 && a[1].integer >= 2 && a[1].integer <= 64 &&
                a[2].integer >= a[1].integer && a[2].integer <= 1024, ZOVA_PLUGIN_INVALID_ARGUMENT);
        Host host(h, c); auto config = metadata(host, name); config.connectivity = a[1].integer; config.expansion = a[2].integer;
        // Bound the number of persisted collections and caches independently.
        int64_t existing = 0;
        host.sql("SELECT count(*) FROM main._zova_ext_usearch_indexes WHERE name<>?", {text(name)}, [&](auto v, auto n) {
            require(n == 1 && v[0].kind == 1); existing = v[0].integer;
        }); require(existing < 256, ZOVA_PLUGIN_LIMIT);
        Times times; auto base = build(host, name, config, times); persist(host, name, *base, times);
        std::ostringstream report;
        report << "{\"vectors\":" << base->ids.size() << ",\"load_ms\":" << times.load << ",\"convert_ms\":" << times.convert
               << ",\"index_ms\":" << times.index << ",\"persist_ms\":" << times.persist << "}";
        const auto result = report.str(); auto value = text(result); check(call->row(call->user_data, &value, 1));
    });
}
int32_t ZOVA_PLUGIN_CALL refresh_operation(const zova_plugin_host_v1 *h, void *c, void *, const zova_plugin_operation_call_v1 *call) noexcept {
    return boundary([&] {
        require(call && call->arguments && call->argument_count == 1, ZOVA_PLUGIN_INVALID_ARGUMENT);
        const auto name = string(call->arguments[0]); Host host(h,c); auto record = stored(host,name);
        auto config = metadata(host,name); config.connectivity = record.config.connectivity; config.expansion = record.config.expansion;
        Times times; auto start = Clock::now(); std::shared_ptr<Base> next;
        size_t changed = 0; bool reconstructed = false;
        if (config.dims == record.config.dims && config.type == record.config.type && config.metric == record.config.metric) {
            auto base = load(host,name,record); Delta delta;
            try { delta = changes(host,name,*base); }
            catch (const Failure &e) {
                if (e.status != ZOVA_PLUGIN_HISTORY_UNAVAILABLE && e.status != ZOVA_PLUGIN_SOURCE_CHANGED) throw;
                reconstructed = true;
            }
            changed = delta.size();
            // Compact identity tombstones before hitting bounded representation limits.
            if (!reconstructed && base->ids.size() + delta.size() <= max_vectors &&
                (base->ids.size() + delta.size()) * config.dims * 4 <= max_matrix) {
                next = std::make_shared<Base>(base->config);
                auto copied = base->index.copy(); result_ok(copied,ZOVA_PLUGIN_OUT_OF_MEMORY);
                next->index = std::move(copied.index); next->ids = base->ids;
                require(next->index.try_reserve({base->ids.size()+delta.size(),1}),ZOVA_PLUGIN_OUT_OF_MEMORY);
                std::unordered_map<std::string,size_t> labels;
                for (size_t i = 0; i < next->ids.size(); ++i) if (!next->ids[i].empty()) labels.emplace(next->ids[i],i);
                // Stable BINARY order for new labels and update application.
                std::vector<std::string> ids; for (const auto &[id,vector] : delta) ids.push_back(id); std::sort(ids.begin(),ids.end());
                for (const auto &id : ids) {
                    auto existing = labels.find(id); size_t label;
                    if (existing != labels.end()) {
                        label = existing->second; auto removed = next->index.remove(label); result_ok(removed,ZOVA_PLUGIN_OUT_OF_MEMORY);
                        require(removed.completed == 1); if (delta.at(id).empty()) { next->ids[label].clear(); continue; }
                    } else { if (delta.at(id).empty()) continue; label = next->ids.size(); next->ids.push_back(id); }
                    auto added = next->index.add(label,delta.at(id).data(),0); result_ok(added,ZOVA_PLUGIN_OUT_OF_MEMORY);
                }
                next->config.count = next->ids.size(); next->coverage = host.view(name);
                require(next->index.size() == config.count); times.index = elapsed(start);
            }
        }
        if (!next) { reconstructed = true; next = build(host,name,config,times); }
        persist(host,name,*next,times);
        std::ostringstream report; report << "{\"changed\":" << changed << ",\"rebuilt\":" << int(reconstructed)
            << ",\"index_ms\":" << times.index << ",\"persist_ms\":" << times.persist << "}";
        auto result = report.str(); auto value = text(result); check(call->row(call->user_data,&value,1));
    });
}
int32_t ZOVA_PLUGIN_CALL search_open(const zova_plugin_host_v1 *h, void *c, void *raw,
    const zova_plugin_value_v1 *a, uint64_t n, void **out) noexcept {
    if (!out) return ZOVA_PLUGIN_INVALID_ARGUMENT;
    *out = nullptr;
    return boundary([&] {
        require(a && n == 4 && a[2].kind == 1 && a[3].kind == 1 && a[2].integer >= 1 && a[2].integer <= 4096 &&
                a[3].integer >= a[2].integer && a[3].integer <= 100000, ZOVA_PLUGIN_INVALID_ARGUMENT);
        auto name = string(a[0]); require(!name.empty(), ZOVA_PLUGIN_INVALID_ARGUMENT);
        Host host(h, c); auto config = metadata(host, name); auto record = stored(host, name);
        config.connectivity = record.config.connectivity; config.expansion = record.config.expansion;
        auto query = decode(a[1], config); auto cursor = std::make_unique<Cursor>();
        auto &state = *static_cast<State *>(raw); std::shared_ptr<Base> base;
        Delta delta; auto start = Clock::now();
        const bool incompatible = config.dims != record.config.dims || config.type != record.config.type || config.metric != record.config.metric;
        if (!incompatible) {
            // Cache identity contains the visible persisted bytes AND coverage branch.
            if (state.base && state.name == name && state.hash == record.hash && same_config(state.base->config,record.config) &&
                std::memcmp(state.base->coverage.incarnation, record.coverage.incarnation, 16) == 0 &&
                std::memcmp(state.base->coverage.token, record.coverage.token, 16) == 0 && state.base->coverage.revision == record.coverage.revision)
                base = state.base;
            else base = load(host, name, record);
            try { delta = changes(host, name, *base); }
            catch (const Failure &e) {
                if (e.status != ZOVA_PLUGIN_HISTORY_UNAVAILABLE && e.status != ZOVA_PLUGIN_SOURCE_CHANGED) throw;
                cursor->strategy = 1; base.reset(); delta.clear();
            }
        } else cursor->strategy = 1;
        if (!base) base = build(host, name, config, cursor->times);
        cursor->times.reconcile = elapsed(start);
        // Only persisted immutable bases enter the cache. No provisional delta survives.
        if (!cursor->strategy) { state.name = name; state.hash = record.hash; state.base = base; }
        cursor->revision = host.view(name).revision; cursor->delta = delta.size(); start = Clock::now();
        base->index.change_expansion_search(a[3].integer);
        const size_t limit = a[2].integer, wanted = std::min(base->ids.size(), limit + delta.size());
        if (wanted) {
            auto found = base->index.filtered_search(query.data(), wanted, [&](auto member) {
                const size_t key = member;
                return key < base->ids.size() && delta.find(base->ids[key]) == delta.end();
            }, 0);
            result_ok(found); std::vector<float> vector(config.dims);
            for (size_t i = 0; i < found.size(); ++i) {
                const size_t key = found[i].member.key; require(key < base->ids.size() && base->index.get(key, vector.data()) == 1);
                cursor->rows.push_back({base->ids[key], distance(query, vector, config)});
            }
        }
        for (const auto &[id, vector] : delta) if (!vector.empty()) cursor->rows.push_back({id, distance(query, vector, config)});
        std::sort(cursor->rows.begin(), cursor->rows.end(), [](const auto &a, const auto &b) {
            return a.distance != b.distance ? a.distance < b.distance : a.id < b.id;
        });
        if (cursor->rows.size() > limit) cursor->rows.resize(limit);
        cursor->times.search = elapsed(start); *out = cursor.release();
    });
}
int32_t ZOVA_PLUGIN_CALL search_next(const zova_plugin_host_v1 *, void *, void *raw,
    zova_plugin_row_v1 row, void *context, uint32_t *has_row) noexcept {
    if (!has_row) return ZOVA_PLUGIN_INVALID_ARGUMENT;
    *has_row = 0;
    return boundary([&] {
        require(raw && row, ZOVA_PLUGIN_INVALID_ARGUMENT); auto &cursor = *static_cast<Cursor *>(raw);
        if (cursor.pos == cursor.rows.size()) return;
        const auto &result = cursor.rows[cursor.pos];
        zova_plugin_value_v1 values[] = {text(result.id), {}, integer(cursor.revision), integer(cursor.delta), integer(cursor.strategy), {}, {}};
        values[1].kind = 2; values[1].real = result.distance;
        values[5].kind = 2; values[5].real = cursor.times.reconcile; values[6].kind = 2; values[6].real = cursor.times.search;
        check(row(context, values, 7)); ++cursor.pos; *has_row = 1;
    });
}
void ZOVA_PLUGIN_CALL close(void *p) noexcept { delete static_cast<Cursor *>(p); }
void ZOVA_PLUGIN_CALL destroy(void *p) noexcept { delete static_cast<State *>(p); }
zova_plugin_operation_column_v1 column(const char *name, uint32_t type) {
    return {{reinterpret_cast<const uint8_t *>(name), std::strlen(name)}, type, 0};
}
int32_t ZOVA_PLUGIN_CALL register_sql(const zova_plugin_host_v1 *h, void *c) noexcept {
    return boundary([&] {
        auto ops = service<zova_plugin_operation_service_v1>(h, c, 5);
        const zova_plugin_operation_column_v1 build_args[] = {column("collection", 3), column("connectivity", 1), column("expansion_add", 1)};
        const auto result = column("report", 3);
        zova_plugin_operation_v1 op{}; op.struct_size = sizeof(op); op.kind = ZOVA_PLUGIN_OPERATION_SCALAR;
        op.flags = ZOVA_PLUGIN_OPERATION_APPROXIMATE | ZOVA_PLUGIN_OPERATION_MUTATING;
        op.name = {reinterpret_cast<const uint8_t *>("build"), 5}; op.arguments = build_args; op.argument_count = 3;
        op.columns = &result; op.column_count = 1; op.scalar = build_operation; check(ops->register_operation(c, &op));
        const auto refresh_arg = column("collection",3);
        op.name = {reinterpret_cast<const uint8_t *>("refresh"),7}; op.arguments = &refresh_arg; op.argument_count = 1;
        op.scalar = refresh_operation; check(ops->register_operation(c,&op));
        const zova_plugin_operation_column_v1 args[] = {column("collection", 3), column("query", 4), column("limit", 1), column("expansion_search", 1)};
        const zova_plugin_operation_column_v1 columns[] = {column("vector_id", 3), column("distance", 2), column("revision", 1),
            column("delta_count", 1), column("rebuilt", 1), column("reconcile_ms", 2), column("search_ms", 2)};
        auto state = std::make_unique<State>(); op = {}; op.struct_size = sizeof(op); op.kind = ZOVA_PLUGIN_OPERATION_TABLE;
        op.flags = ZOVA_PLUGIN_OPERATION_APPROXIMATE | ZOVA_PLUGIN_OPERATION_ORDERED;
        op.name = {reinterpret_cast<const uint8_t *>("search"), 6}; op.arguments = args; op.argument_count = 4; op.columns = columns; op.column_count = 7;
        op.user_data = state.get(); op.destroy = destroy; op.open = search_open; op.next = search_next; op.close = close;
        check(ops->register_operation(c, &op)); state.release();
    });
}
static const zova_plugin_recovery_descriptor_v1 descriptor = {{ {{
    sizeof(zova_plugin_recovery_descriptor_v1), ZOVA_PLUGIN_ABI_V1,
    ZOVA_PLUGIN_REQUIRES_DATA_V1 | ZOVA_PLUGIN_REQUIRES_STORAGE_V1 | ZOVA_PLUGIN_REQUIRES_OPERATIONS_V1 |
    ZOVA_PLUGIN_REQUIRES_VECTOR_MAINTENANCE_V1 | ZOVA_PLUGIN_HAS_DATA_COMPATIBILITY_V1 | ZOVA_PLUGIN_HAS_RECOVERY_V1,
    "usearch", "1.0.0", "_zova_ext_usearch_", "1.2.0", "", install, verify, drop, register_sql
}, nullptr, nullptr}, "1.0.0", "1.0.0"}, rebuild, nullptr};
} // namespace
extern "C" ZOVA_PLUGIN_EXPORT const zova_plugin_descriptor_v1 *ZOVA_PLUGIN_CALL
zova_plugin_entry_v1(uint32_t version) {
    return version == ZOVA_PLUGIN_ABI_V1 ? &descriptor.base.base.base : nullptr;
}
