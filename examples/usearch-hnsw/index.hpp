#include "zova_plugin.h"
#include <usearch/index_dense.hpp>
#include <algorithm>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace reference {
namespace ann = unum::usearch;
using Clock = std::chrono::steady_clock;
constexpr size_t max_vectors = 100000, max_dimensions = 4096;
constexpr size_t max_matrix = 32 * 1024 * 1024, max_blob = 64 * 1024 * 1024;
constexpr size_t chunk_size = 256 * 1024;
struct Failure { int32_t status; };
void check(int32_t status) { if (status) throw Failure{status}; }
void require(bool condition, int32_t status = ZOVA_PLUGIN_ERROR) { if (!condition) throw Failure{status}; }
double elapsed(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
template <class F> int32_t boundary(F &&fn) noexcept {
    try { fn(); return ZOVA_PLUGIN_OK; }
    catch (const Failure &e) { return e.status; }
    catch (const std::bad_alloc &) { return ZOVA_PLUGIN_OUT_OF_MEMORY; }
    catch (...) { return ZOVA_PLUGIN_ERROR; }
}
template <class Result> void result_ok(Result &result, int32_t status = ZOVA_PLUGIN_ERROR) {
    if (!result) { result.error.release(); throw Failure{status}; }
}
std::string string(const zova_plugin_value_v1 &v) {
    require(v.kind == ZOVA_PLUGIN_VALUE_TEXT && v.bytes_len <= 255 && (v.bytes || !v.bytes_len));
    return v.bytes_len ? std::string(reinterpret_cast<const char *>(v.bytes), v.bytes_len) : std::string{};
}
zova_plugin_bytes_v1 bytes(const std::string &s) { return {reinterpret_cast<const uint8_t *>(s.data()), s.size()}; }
zova_plugin_value_v1 text(const std::string &s) {
    zova_plugin_value_v1 v{}; v.kind = ZOVA_PLUGIN_VALUE_TEXT; v.bytes = bytes(s).data; v.bytes_len = s.size(); return v;
}
zova_plugin_value_v1 integer(int64_t n) { zova_plugin_value_v1 v{}; v.kind = 1; v.integer = n; return v; }
zova_plugin_value_v1 blob(const void *p, size_t size) {
    zova_plugin_value_v1 v{}; v.kind = 4; v.bytes = static_cast<const uint8_t *>(p); v.bytes_len = size; return v;
}
template <class S> const S *service(const zova_plugin_host_v1 *host, void *c, uint32_t id) {
    require(host && host->struct_size >= sizeof(zova_plugin_service_host_v1), ZOVA_PLUGIN_UNSUPPORTED);
    const void *out = nullptr;
    check(reinterpret_cast<const zova_plugin_service_host_v1 *>(host)->get_service(c, id, 1, sizeof(S), &out));
    require(out, ZOVA_PLUGIN_UNSUPPORTED); return static_cast<const S *>(out);
}
using Receive = std::function<void(const zova_plugin_value_v1 *, uint64_t)>;
struct Receiver { Receive fn; int32_t error = 0; };
int32_t ZOVA_PLUGIN_CALL receive(void *raw, const zova_plugin_value_v1 *v, uint64_t n) noexcept {
    auto &r = *static_cast<Receiver *>(raw);
    r.error = boundary([&] { require(v || !n); r.fn(v, n); });
    return r.error ? ZOVA_PLUGIN_CANCELED : ZOVA_PLUGIN_OK;
}
struct Host {
    void *connection;
    const zova_plugin_data_service_v1 *data;
    const zova_plugin_storage_service_v1 *storage;
    const zova_plugin_vector_maintenance_service_v1 *maintenance;
    Host(const zova_plugin_host_v1 *h, void *c) : connection(c),
        data(service<zova_plugin_data_service_v1>(h, c, 3)), storage(service<zova_plugin_storage_service_v1>(h, c, 4)),
        maintenance(service<zova_plugin_vector_maintenance_service_v1>(h, c, 6)) {}
    void sql(const char *sql, std::initializer_list<zova_plugin_value_v1> params, Receive fn = [](auto, auto) {}) {
        Receiver r{std::move(fn)}; zova_plugin_query_request_v1 q{};
        q.struct_size = sizeof(q); q.sql = sql; q.sql_len = std::strlen(sql);
        q.parameters = params.begin(); q.parameter_count = params.size(); q.row_limit = 4096;
        q.byte_limit = 1024 * 1024; q.row = receive; q.user_data = &r;
        auto status = storage->execute(connection, &q); check(r.error); check(status);
    }
    zova_plugin_vector_view_v1 view(const std::string &name) {
        zova_plugin_vector_view_v1 v{}; check(maintenance->view(connection, bytes(name), &v)); return v;
    }
};
struct Config { size_t dims = 0, count = 0, connectivity = 16, expansion = 64; std::string type, metric; };
bool same_config(const Config &a,const Config &b) {
    return a.dims == b.dims && a.type == b.type && a.metric == b.metric &&
           a.connectivity == b.connectivity && a.expansion == b.expansion;
}
Config metadata(Host &host, const std::string &name) {
    Config c; bool got = false;
    Receiver r{[&](auto v, auto n) {
        require(n == 4 && !got && v[0].kind == 1 && v[3].kind == 1);
        require(v[0].integer > 0 && v[0].integer <= int64_t(max_dimensions) &&
                v[3].integer >= 0 && v[3].integer <= int64_t(max_vectors), ZOVA_PLUGIN_LIMIT);
        c.dims = v[0].integer; c.count = v[3].integer; c.type = string(v[1]); c.metric = string(v[2]); got = true;
    }};
    zova_plugin_data_request_v1 q{}; q.struct_size = sizeof(q); q.operation = ZOVA_PLUGIN_VECTOR_METADATA;
    q.name = bytes(name); q.row_limit = 1; q.byte_limit = 4096; q.row = receive; q.user_data = &r;
    zova_plugin_data_page_v1 page{}; auto status = host.data->read(host.connection, &q, &page); check(r.error); check(status);
    require(got && (c.type == "f32" || c.type == "f16" || c.type == "i8") &&
            (c.metric == "cosine" || c.metric == "l2" || c.metric == "dot"));
    require(c.count * c.dims * 4 <= max_matrix, ZOVA_PLUGIN_LIMIT); return c;
}
std::vector<float> decode(const zova_plugin_value_v1 &v, const Config &c) {
    size_t width = c.type == "f32" ? 4 : c.type == "f16" ? 2 : 1;
    require(v.kind == 4 && v.bytes && v.bytes_len == c.dims * width, ZOVA_PLUGIN_INVALID_ARGUMENT);
    std::vector<float> out(c.dims); double norm = 0;
    for (size_t i = 0; i < c.dims; ++i) {
        auto p = v.bytes + i * width;
        if (width == 4) out[i] = std::bit_cast<float>(uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24);
        else if (width == 2) {
            uint16_t h = uint16_t(p[0]) | uint16_t(p[1]) << 8; unsigned e = (h >> 10) & 31, f = h & 1023;
            out[i] = e == 31 ? std::numeric_limits<float>::infinity() : std::ldexp(float(e ? f + 1024 : f), e ? int(e) - 25 : -24);
            if (h & 0x8000) out[i] = -out[i];
        } else out[i] = float(std::bit_cast<int8_t>(*p));
        require(std::isfinite(out[i]), ZOVA_PLUGIN_INVALID_ARGUMENT); norm += double(out[i]) * out[i];
    }
    require(c.metric != "cosine" || norm > 0, ZOVA_PLUGIN_INVALID_ARGUMENT); return out;
}
ann::metric_kind_t metric(const Config &c) {
    return c.metric == "l2" ? ann::metric_kind_t::l2sq_k : c.metric == "dot" ? ann::metric_kind_t::ip_k : ann::metric_kind_t::cos_k;
}
struct Base {
    Config config; zova_plugin_vector_view_v1 coverage{}; std::vector<std::string> ids; ann::index_dense_t index;
    explicit Base(Config c) : config(std::move(c)) {
        ann::index_dense_config_t settings; settings.connectivity = config.connectivity; settings.expansion_add = config.expansion;
        auto made = ann::index_dense_t::make(ann::metric_punned_t(config.dims, metric(config), ann::scalar_kind_t::f32_k),
                                            settings, UINT64_MAX, {0, 1});
        result_ok(made, ZOVA_PLUGIN_OUT_OF_MEMORY); index = std::move(made.index);
        require(index.try_reserve({config.count, 1}), ZOVA_PLUGIN_OUT_OF_MEMORY); ids.reserve(config.count);
    }
};
struct Times { double load = 0, convert = 0, index = 0, persist = 0, reconcile = 0, search = 0; };
std::shared_ptr<Base> build(Host &host, const std::string &name, Config c, Times &t) {
    auto start = Clock::now(); auto base = std::make_shared<Base>(std::move(c)); base->coverage = host.view(name);
    Receiver r{[&](auto v, auto n) {
        require(n == 2 && base->ids.size() < base->config.count);
        auto id = string(v[0]); require(!id.empty() && (base->ids.empty() || base->ids.back() < id));
        auto begin = Clock::now(); auto vector = decode(v[1], base->config); t.convert += elapsed(begin);
        begin = Clock::now(); auto added = base->index.add(base->ids.size(), vector.data(), 0);
        result_ok(added, ZOVA_PLUGIN_OUT_OF_MEMORY); t.index += elapsed(begin); base->ids.push_back(std::move(id));
    }};
    zova_plugin_data_request_v1 q{}; q.struct_size = sizeof(q); q.operation = ZOVA_PLUGIN_VECTORS_SCAN; q.name = bytes(name);
    q.row_limit = 256; q.byte_limit = 1024 * 1024; q.row = receive; q.user_data = &r;
    do {
        zova_plugin_data_page_v1 page{}; auto status = host.data->read(host.connection, &q, &page); check(r.error); check(status);
        if (!page.has_more) break;
        require(page.rows && !base->ids.empty()); q.after_id = bytes(base->ids.back());
    } while (true);
    require(base->ids.size() == base->config.count); t.load = elapsed(start) - t.convert - t.index; return base;
}
// FNV detects accidental corruption, not hostile edits. Native plugins are trusted.
uint64_t digest(const std::vector<uint8_t> &data) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (auto b : data) { hash ^= b; hash *= UINT64_C(1099511628211); } return hash;
}
void append32(std::vector<uint8_t> &data, uint32_t n) { for (unsigned i = 0; i < 4; ++i) data.push_back(uint8_t(n >> (8 * i))); }
struct Reader {
    const std::vector<uint8_t> &data; size_t pos = 0;
    template <class T> T take() {
        require(sizeof(T) <= data.size() - pos); T v; std::memcpy(&v, data.data() + pos, sizeof(T)); pos += sizeof(T); return v;
    }
    uint32_t u32() {
        require(4 <= data.size() - pos); uint32_t n = 0;
        for (unsigned i = 0; i < 4; ++i) n |= uint32_t(data[pos++]) << (8 * i); return n;
    }
};
std::vector<uint8_t> serialize(const Base &base) {
    std::vector<uint8_t> data; append32(data, 1); append32(data, uint32_t(base.ids.size()));
    for (const auto &id : base.ids) { append32(data, uint32_t(id.size())); data.insert(data.end(), id.begin(), id.end()); }
    require(data.size() <= max_blob && base.index.serialized_length() <= max_blob - data.size(), ZOVA_PLUGIN_LIMIT);
    data.reserve(data.size() + base.index.serialized_length());
    auto saved = base.index.save_to_stream([&](const void *p, size_t n) {
        if (n > max_blob - data.size()) return false;
        auto first = static_cast<const uint8_t *>(p); data.insert(data.end(), first, first + n); return true;
    }); result_ok(saved); return data;
}
struct Stored { Config config; zova_plugin_vector_view_v1 coverage{}; size_t size = 0; uint64_t hash = 0; };
Stored stored(Host &host, const std::string &name) {
    Stored record; bool found = false;
    host.sql("SELECT dims,type,metric,connectivity,expansion,incarnation,token,revision,size,hash FROM main._zova_ext_usearch_indexes WHERE name=?", {text(name)}, [&](auto v, auto n) {
        require(n == 10 && !found); for (auto i : {0, 3, 4, 7, 8}) require(v[i].kind == 1);
        record.config.dims = v[0].integer; record.config.type = string(v[1]); record.config.metric = string(v[2]);
        require((record.config.type == "f32" || record.config.type == "f16" || record.config.type == "i8") &&
                (record.config.metric == "l2" || record.config.metric == "cosine" || record.config.metric == "dot"));
        record.config.connectivity = v[3].integer; record.config.expansion = v[4].integer;
        require(record.config.dims > 0 && record.config.dims <= max_dimensions && record.config.connectivity >= 2 &&
                record.config.connectivity <= 64 && record.config.expansion >= record.config.connectivity && record.config.expansion <= 1024);
        require(v[5].kind == 4 && v[5].bytes_len == 16 && v[6].kind == 4 && v[6].bytes_len == 16 &&
                v[9].kind == 4 && v[9].bytes_len == 8 && v[8].integer > 0 && v[8].integer <= int64_t(max_blob));
        std::memcpy(record.coverage.incarnation, v[5].bytes, 16); std::memcpy(record.coverage.token, v[6].bytes, 16);
        record.coverage.revision = v[7].integer; require(record.coverage.revision >= 0);
        record.size = v[8].integer; std::memcpy(&record.hash, v[9].bytes, 8); found = true;
    }); require(found, ZOVA_PLUGIN_INVALID_ARGUMENT); return record;
}
void persist(Host &host, const std::string &name, const Base &base, Times &t) {
    auto start = Clock::now(); auto data = serialize(base); auto hash = digest(data);
    host.sql("DELETE FROM main._zova_ext_usearch_chunks WHERE name=?", {text(name)});
    host.sql("DELETE FROM main._zova_ext_usearch_indexes WHERE name=?", {text(name)});
    host.sql("INSERT INTO main._zova_ext_usearch_indexes VALUES(?,?,?,?,?,?,?,?,?,?,?)",
        {text(name), integer(base.config.dims), text(base.config.type), text(base.config.metric), integer(base.config.connectivity),
         integer(base.config.expansion), blob(base.coverage.incarnation, 16), blob(base.coverage.token, 16),
         integer(base.coverage.revision), integer(data.size()), blob(&hash, 8)});
    for (size_t offset = 0, ordinal = 0; offset < data.size(); offset += chunk_size, ++ordinal)
        host.sql("INSERT INTO main._zova_ext_usearch_chunks VALUES(?,?,?)",
                 {text(name), integer(ordinal), blob(data.data() + offset, std::min(chunk_size, data.size() - offset))});
    t.persist = elapsed(start);
}
// Validate all sizes and graph links before the upstream deserializer allocates.
// This parser is intentionally tied to the immutable USearch pin and data version.
std::shared_ptr<Base> load(Host &host, const std::string &name, Stored record) {
    std::vector<uint8_t> data; data.reserve(record.size);
    for (size_t ordinal = 0; data.size() < record.size; ++ordinal) {
        bool found = false;
        host.sql("SELECT data FROM main._zova_ext_usearch_chunks WHERE name=? AND ordinal=?", {text(name), integer(ordinal)}, [&](auto v, auto n) {
            require(n == 1 && !found && v[0].kind == 4 && v[0].bytes_len == std::min(chunk_size, record.size - data.size()));
            data.insert(data.end(), v[0].bytes, v[0].bytes + v[0].bytes_len); found = true;
        }); require(found);
    }
    require(digest(data) == record.hash); Reader r{data}; require(r.u32() == 1);
    const size_t count = r.u32(); require(count <= max_vectors); record.config.count = count;
    require(count * record.config.dims * 4 <= max_matrix, ZOVA_PLUGIN_LIMIT);
    auto base = std::make_shared<Base>(record.config); base->coverage = record.coverage;
    std::unordered_map<std::string,size_t> labels;
    for (size_t i = 0; i < count; ++i) {
        auto len = r.u32(); require(len <= 255 && len <= data.size() - r.pos);
        std::string id(reinterpret_cast<const char *>(data.data() + r.pos), len); r.pos += len;
        if (!id.empty()) require(labels.emplace(id,i).second);
        base->ids.push_back(std::move(id));
    }
    size_t ann_start = r.pos;
    const size_t slots = r.u32(); require(slots <= count && labels.size() <= slots && r.u32() == record.config.dims * 4);
    require(slots * record.config.dims * 4 <= data.size() - r.pos);
    // Stored f32 values also must remain finite and valid for the metric.
    for (size_t i = 0; i < slots; ++i) {
        Config decoded = record.config; decoded.type = "f32";
        decode(blob(data.data() + r.pos, decoded.dims * 4), decoded); r.pos += decoded.dims * 4;
    }
    ann::index_dense_head_buffer_t buffer{};
    require(sizeof(buffer) <= data.size() - r.pos); std::memcpy(buffer, data.data() + r.pos, sizeof(buffer)); r.pos += sizeof(buffer);
    ann::index_dense_head_t head{buffer};
    require(std::memcmp(buffer, "usearch", 7) == 0 && head.version_major == USEARCH_VERSION_MAJOR &&
            head.count_present == labels.size() && head.count_deleted == slots-labels.size() && head.dimensions == record.config.dims &&
            *reinterpret_cast<const uint8_t *>(head.multi.ptr()) == 0 &&
            head.kind_scalar == ann::scalar_kind_t::f32_k && head.kind_key == ann::scalar_kind_t::u64_k &&
            head.kind_compressed_slot == ann::scalar_kind_t::u32_k && head.kind_metric == metric(record.config));
    const auto graph = r.take<ann::index_serialized_header_t>();
    require(graph.size == slots && graph.connectivity == record.config.connectivity &&
            graph.connectivity_base == record.config.connectivity * 2 &&
            (slots == 0 || (graph.entry_slot < slots && graph.max_level <= 32)));
    std::vector<int16_t> levels(slots);
    for (auto &level : levels) { level = r.take<int16_t>(); require(level >= 0 && uint64_t(level) <= graph.max_level); }
    require(!slots || uint64_t(levels[graph.entry_slot]) == graph.max_level);
    std::vector<bool> seen(count);
    for (size_t slot = 0; slot < slots; ++slot) {
        auto key = r.take<uint64_t>();
        if (key != UINT64_MAX) { require(key < count && !base->ids[key].empty() && !seen[key]); seen[key] = true; }
        require(r.take<int16_t>() == levels[slot]);
        for (int level = 0; level <= levels[slot]; ++level) {
            auto capacity = level ? graph.connectivity : graph.connectivity_base;
            auto n = r.take<uint32_t>(); require(n <= capacity);
            for (size_t j = 0; j < capacity; ++j) { auto neighbor = r.take<uint32_t>(); if (j < n) require(neighbor < slots && levels[neighbor] >= level); }
        }
    }
    require(r.pos == data.size() && size_t(std::count(seen.begin(),seen.end(),true)) == labels.size()); size_t position = ann_start;
    auto loaded = base->index.load_from_stream([&](void *p, size_t n) {
        if (n > data.size() - position) return false;
        std::memcpy(p, data.data() + position, n); position += n; return true;
    }); result_ok(loaded); require(position == data.size() && base->index.size() == labels.size());
    return base;
}
using Delta = std::unordered_map<std::string, std::vector<float>>; // Empty means deleted.
Delta changes(Host &host, const std::string &name, const Base &base) {
    Delta delta; Receiver r{[&](auto v, auto n) {
        require(n == 4 && v[0].kind == 1 && v[2].kind == 1 && (v[2].integer == 0 || v[2].integer == 1));
        auto id = string(v[1]); require(!id.empty());
        delta[id] = v[2].integer ? decode(v[3], base.config) : std::vector<float>{};
        require(delta.size() * base.config.dims * 4 <= max_matrix, ZOVA_PLUGIN_LIMIT);
    }};
    zova_plugin_vector_changes_request_v1 q{}; q.struct_size = sizeof(q); q.name = bytes(name); q.since = base.coverage;
    q.row_limit = 256; q.byte_limit = 1024 * 1024; q.row = receive; q.user_data = &r;
    do {
        zova_plugin_vector_changes_page_v1 page{};
        auto status = host.maintenance->read_changes(host.connection, &q, &page); check(r.error); check(status);
        if (!page.has_more) break;
        require(page.rows && page.next_revision > q.after_revision); q.after_revision = page.next_revision;
    } while (true); return delta;
}
double distance(const std::vector<float> &a, const std::vector<float> &b, const Config &c) {
    double dot = 0, aa = 0, bb = 0, square = 0;
    for (size_t i = 0; i < a.size(); ++i) { dot += double(a[i]) * b[i]; aa += double(a[i]) * a[i]; bb += double(b[i]) * b[i];
        double diff = double(a[i]) - b[i]; square += diff * diff; }
    return c.metric == "l2" ? std::sqrt(square) : c.metric == "dot" ? -dot : 1 - dot / (std::sqrt(aa) * std::sqrt(bb));
}
struct State { std::string name; uint64_t hash = 0; std::shared_ptr<Base> base; };
struct Result { std::string id; double distance; };
struct Cursor { std::vector<Result> rows; size_t pos = 0, delta = 0; int strategy = 0; Times times; int64_t revision = 0; };
} // namespace reference
