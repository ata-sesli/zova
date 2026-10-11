// Compile the exact plugin implementation into this boundary test. This permits
// deterministic C++ allocation faults without production test hooks/interposition.
#include <cstdlib>
#include <new>
static long fail_after = -1;
void *operator new(std::size_t size) {
    if (fail_after == 0) throw std::bad_alloc();
    if (fail_after > 0) --fail_after;
    if (void *p = std::malloc(size ? size : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }
#include "../examples/usearch-hnsw/usearch.cpp"
#include <cstdio>

namespace {
struct Fixture {
    reference::Stored record;
    std::vector<uint8_t> data;
    int fault = 0;
};
int32_t ZOVA_PLUGIN_CALL read(void *raw, const zova_plugin_data_request_v1 *q, zova_plugin_data_page_v1 *out) {
    auto &f = *static_cast<Fixture *>(raw); *out = {};
    const std::string type = "f32", metric = "l2";
    zova_plugin_value_v1 row[] = {reference::integer(2), reference::text(type), reference::text(metric), reference::integer(1)};
    auto status = q->row(q->user_data,row,4);
    if (status) return status;
    if (f.fault == 1) return ZOVA_PLUGIN_OUT_OF_MEMORY;
    out->rows = 1; return 0;
}
int32_t ZOVA_PLUGIN_CALL storage(void *raw, const zova_plugin_query_request_v1 *q) {
    auto &f = *static_cast<Fixture *>(raw); auto &r = f.record;
    if (std::strstr(q->sql,"SELECT dims")) {
        zova_plugin_value_v1 row[] = {reference::integer(2),reference::text(r.config.type),reference::text(r.config.metric),
            reference::integer(16),reference::integer(64),reference::blob(r.coverage.incarnation,16),reference::blob(r.coverage.token,16),
            reference::integer(0),reference::integer(f.data.size()),reference::blob(&r.hash,8)};
        auto status = q->row(q->user_data,row,10);
        if (status) return status;
        return f.fault == 2 ? ZOVA_PLUGIN_OUT_OF_MEMORY : 0;
    }
    if (std::strstr(q->sql,"SELECT data")) {
        auto value = reference::blob(f.data.data(),f.data.size()); return q->row(q->user_data,&value,1);
    }
    return ZOVA_PLUGIN_ERROR;
}
int32_t ZOVA_PLUGIN_CALL view(void *raw, zova_plugin_bytes_v1, zova_plugin_vector_view_v1 *out) {
    *out = static_cast<Fixture *>(raw)->record.coverage; return 0;
}
int32_t ZOVA_PLUGIN_CALL changes(void *raw, const zova_plugin_vector_changes_request_v1 *q, zova_plugin_vector_changes_page_v1 *out) {
    auto &f = *static_cast<Fixture *>(raw); *out = {};
    if (f.fault >= 3) {
        const std::string id = "a";
        zova_plugin_value_v1 row[] = {reference::integer(1),reference::text(id),reference::integer(0),{}};
        auto status = q->row(q->user_data,row,4); if (status) return status;
        return f.fault == 3 ? ZOVA_PLUGIN_OUT_OF_MEMORY : ZOVA_PLUGIN_CANCELED;
    }
    out->view = f.record.coverage; return 0;
}
const zova_plugin_data_service_v1 data_service{sizeof(data_service),1,read};
const zova_plugin_storage_service_v1 storage_service{sizeof(storage_service),1,storage};
const zova_plugin_vector_maintenance_service_v1 maintenance_service{sizeof(maintenance_service),1,view,changes};
int32_t ZOVA_PLUGIN_CALL services(void *,uint32_t id,uint32_t,uint32_t,const void **out) {
    *out = id == 3 ? static_cast<const void *>(&data_service) : id == 4 ? static_cast<const void *>(&storage_service) :
           id == 6 ? static_cast<const void *>(&maintenance_service) : nullptr;
    return *out ? 0 : ZOVA_PLUGIN_UNSUPPORTED;
}
int32_t ZOVA_PLUGIN_CALL cancel(void *,const zova_plugin_value_v1 *,uint64_t) { return ZOVA_PLUGIN_CANCELED; }
int32_t ZOVA_PLUGIN_CALL row(void *,const zova_plugin_value_v1 *v,uint64_t n) {
    return n == 7 && v[1].real == 0 ? 0 : ZOVA_PLUGIN_ERROR;
}
}
int main() {
    try {
        Fixture fixture; fixture.record.config = {2,1,16,64,"f32","l2"};
        reference::Base base(fixture.record.config); base.ids.push_back("a"); float vector[] = {1,0};
        reference::require(bool(base.index.add(0,vector,0)));
        fixture.data = reference::serialize(base); fixture.record.hash = reference::digest(fixture.data);
        zova_plugin_service_host_v1 host{{sizeof(host),1,nullptr},services};
        reference::State state; const std::string name = "fixture";
        zova_plugin_value_v1 args[] = {reference::text(name),reference::blob(vector,sizeof(vector)),reference::integer(1),reference::integer(64)};
        for (int fault = 1; fault <= 4; ++fault) {
            fixture.fault = fault; void *cursor = reinterpret_cast<void *>(1);
            auto status = search_open(&host.base,&fixture,&state,args,4,&cursor);
            reference::require(status == (fault == 4 ? ZOVA_PLUGIN_CANCELED : ZOVA_PLUGIN_OUT_OF_MEMORY) && !cursor);
        }
        fixture.fault = 0;
        // Fail successive allocations until one invocation succeeds. All failed
        // opens must return OOM and publish no partially initialized cursor.
        int failures = 0;
        for (long allocation = 0; allocation < 128; ++allocation) {
            void *cursor = reinterpret_cast<void *>(1); fail_after = allocation;
            auto status = search_open(&host.base,&fixture,&state,args,4,&cursor); fail_after = -1;
            if (!status) { close(cursor); break; }
            reference::require(status == ZOVA_PLUGIN_OUT_OF_MEMORY && !cursor); ++failures;
        }
        reference::require(failures > 0);
        void *cursor = nullptr; reference::check(search_open(&host.base,&fixture,&state,args,4,&cursor));
        uint32_t has_row = 99;
        reference::require(search_next(nullptr,nullptr,cursor,cancel,nullptr,&has_row) == ZOVA_PLUGIN_CANCELED && !has_row);
        reference::check(search_next(nullptr,nullptr,cursor,row,nullptr,&has_row)); reference::require(has_row == 1);
        reference::check(search_next(nullptr,nullptr,cursor,row,nullptr,&has_row)); reference::require(!has_row); close(cursor);
        // A forged entry-level header must not reach HNSW traversal. Recompute
        // the checksum so the structural parser, not only FNV, is exercised.
        const auto valid_data = fixture.data;
        reference::Reader reader{fixture.data}; reader.u32(); auto identities = reader.u32();
        for (uint32_t i = 0; i < identities; ++i) { auto length = reader.u32(); reader.pos += length; }
        auto slots = reader.u32(); auto width = reader.u32(); reader.pos += slots * width + 64;
        const size_t graph_offset = reader.pos;
        auto graph = reader.take<reference::ann::index_serialized_header_t>(); graph.max_level = 32;
        std::memcpy(fixture.data.data()+graph_offset,&graph,sizeof(graph));
        fixture.record.hash = reference::digest(fixture.data); state.base.reset(); cursor = reinterpret_cast<void *>(1);
        reference::require(search_open(&host.base,&fixture,&state,args,4,&cursor) != 0 && !cursor);
        fixture.data = valid_data;
        // Corrupted graph bytes must fail before upstream graph allocation/use.
        fixture.data.back() ^= 1; state.base.reset(); fixture.record.hash = reference::digest(fixture.data);
        cursor = reinterpret_cast<void *>(1);
        // Padding can change harmlessly; truncation is unambiguously invalid.
        fixture.data.pop_back(); fixture.record.hash = reference::digest(fixture.data);
        reference::require(search_open(&host.base,&fixture,&state,args,4,&cursor) != 0 && !cursor);
        std::printf("USearch boundary faults/ownership passed (%d allocation failures)\n",failures); return 0;
    } catch (...) { fail_after = -1; std::fputs("USearch fault test failed\n",stderr); return 1; }
}
