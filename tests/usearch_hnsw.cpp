#include "zova.h"
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>
#include <cmath>
#include <chrono>
#include <algorithm>
#include <cstring>
#if defined(__unix__) || defined(__APPLE__)
#include <sys/resource.h>
#endif
static void ok(zova_status status) {
    if (status != ZOVA_OK) throw std::runtime_error(zova_status_name(status));
}
static void exec(zova_database *db, const char *sql) {
    zova_database_exec_request request{db, sql}; ok(zova_database_exec(&request));
}
static void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
struct Statement {
    zova_statement *value = nullptr;
    Statement(zova_database *db, const char *sql) { zova_database_prepare_request q{db, sql, &value}; ok(zova_database_prepare(&q)); }
    ~Statement() { if (value) zova_statement_finalize(value); }
    bool step() { zova_step_result result; zova_statement_step_request q{value, &result}; ok(zova_statement_step(&q)); return result == ZOVA_STEP_ROW; }
    std::string text(int column) { zova_text out{}; zova_statement_column_text_request q{value, column, &out};
        ok(zova_statement_column_text(&q)); std::string result(out.data, out.len); zova_text_free(&out); return result; }
    int64_t integer(int column) { int64_t out; zova_statement_column_int64_request q{value, column, &out}; ok(zova_statement_column_int64(&q)); return out; }
    double real(int column) { double out; zova_statement_column_double_request q{value, column, &out}; ok(zova_statement_column_double(&q)); return out; }
};
static void put(zova_database *db, const char *collection, const char *id, const std::vector<float> &v) {
    zova_vector_put_request q{db, collection, id, {ZOVA_VECTOR_ELEMENT_TYPE_F32, v.data(), nullptr, nullptr, v.size()}}; ok(zova_vector_put(&q));
}
struct Hit { std::string id; double distance; int64_t delta, rebuilt; };
static std::vector<Hit> search(zova_database *db, const char *collection, const std::vector<float> &v, int limit = 10) {
    Statement s(db, "SELECT vector_id,distance,delta_count,rebuilt FROM zova_usearch_search(?,?,?,128)");
    zova_statement_bind_text_request name{s.value, 1, reinterpret_cast<const uint8_t *>(collection), std::strlen(collection)}; ok(zova_statement_bind_text(&name));
    zova_statement_bind_blob_request query{s.value, 2, reinterpret_cast<const uint8_t *>(v.data()), v.size() * 4}; ok(zova_statement_bind_blob(&query));
    zova_statement_bind_int64_request count{s.value, 3, limit}; ok(zova_statement_bind_int64(&count));
    std::vector<Hit> result; while (s.step()) result.push_back({s.text(0), s.real(1), s.integer(2), s.integer(3)}); return result;
}
static void fails(zova_database *db, const char *sql) {
    zova_database_exec_request q{db, sql}; require(zova_database_exec(&q) != ZOVA_OK, "invalid operation must fail");
}
static std::string build(zova_database *db, const char *name) {
    Statement s(db, ("SELECT zova_usearch_build('" + std::string(name) + "',16,64)").c_str());
    require(s.step(), "build report row"); auto result = s.text(0); require(!s.step(), "one report"); return result;
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
        bool bound = argc == 5 && std::string(argv[4]) == "bound";
        bool checking = argc == 5 && std::string(argv[4]) == "check";
        if (checking) open.flags = ZOVA_OPEN_READ_ONLY;
        ok((bound || checking) ? zova_database_open_with_extensions(&open) : zova_database_create_with_extensions(&open)); zova_message_free(&message);
        if (checking) { require(search(db,"points",{0,0})[0].id == "one","restored persistent index/source parity");
            ok(zova_database_close(db)); std::puts("USearch restored copy: ok"); return 0; }
        if (argc == 5 && std::string(argv[4]) == "create") { ok(zova_database_close(db)); return 0; }
        zova_database_extension_request install{db, "usearch"}; ok(zova_database_extension_install(&install));
        zova_vector_collection_create_request collection{db, "points", {2, ZOVA_VECTOR_METRIC_L2, ZOVA_VECTOR_ELEMENT_TYPE_F32}};
        ok(zova_vector_collection_create(&collection));
        const float values[] = {1, 0};
        zova_vector_put_request first{db, "points", "one", {ZOVA_VECTOR_ELEMENT_TYPE_F32, values, nullptr, nullptr, 2}};
        ok(zova_vector_put(&first));
        exec(db, "SELECT zova_usearch_build('points',16,64)");
        put(db, "points", "two", {2,0}); put(db, "points", "zero", {0,0});
        auto hits = search(db, "points", {0,0});
        require(hits.size() == 3 && hits[0].id == "zero" && hits[1].id == "one" && hits[2].id == "two", "automatic additions and exact L2 distances");
        require(hits[0].delta == 2 && hits[0].distance == 0 && hits[1].distance == 1, "delta and distance semantics");
        exec(db,"SELECT zova_usearch_refresh('points')");
        require(search(db,"points",{0,0})[0].delta == 0,"incremental refresh persists reconciled HNSW generation");
        put(db, "points", "one", {5,0});
        zova_vector_delete_request remove{db, "points", "two"}; ok(zova_vector_delete(&remove));
        hits = search(db, "points", {0,0}); require(hits.size() == 2 && hits[1].id == "one" && hits[1].distance == 5, "replace and delete reconcile");
        exec(db,"SELECT zova_usearch_refresh('points')");
        require(search(db,"points",{0,0})[0].delta == 0,"replacement/deletion refresh");
        exec(db, "BEGIN"); put(db, "points", "uncommitted", {0.1f,0});
        hits = search(db, "points", {0,0}); require(hits.size() == 3 && hits[1].id == "uncommitted", "read your writes");
        exec(db, "SAVEPOINT inner"); put(db, "points", "zero", {9,0});
        require(search(db, "points", {0,0})[0].id == "uncommitted", "savepoint writes");
        exec(db, "ROLLBACK TO inner"); exec(db, "RELEASE inner");
        require(search(db, "points", {0,0})[0].id == "zero", "savepoint rollback");
        exec(db,"SELECT zova_usearch_refresh('points')"); require(search(db, "points", {0,0})[0].delta == 0, "provisional generation searchable");
        exec(db, "ROLLBACK"); hits = search(db, "points", {0,0}); require(hits.size() == 2 && hits[0].id == "zero", "rollback rejects newer cached generation");
        exec(db, "BEGIN"); put(db, "points", "different-branch", {0.25f,0});
        hits = search(db, "points", {0,0}); require(hits[1].id == "different-branch", "reused revision cannot reuse provisional token"); exec(db, "ROLLBACK");
        std::puts("USearch incremental and savepoint checks passed");
        // Runtime SQL failure must undo the whole build, preserving prior caller work.
        exec(db, "CREATE TABLE marker(value); BEGIN; INSERT INTO marker VALUES(1)");
        exec(db, "CREATE TRIGGER fail_index BEFORE INSERT ON _zova_ext_usearch_chunks BEGIN SELECT RAISE(ABORT,'injected'); END");
        fails(db, "SELECT zova_usearch_build('points',16,64)");
        fails(db, "SELECT zova_usearch_refresh('points')");
        exec(db, "DROP TRIGGER fail_index"); hits = search(db, "points", {0,0}); require(hits.size() == 2, "failed build preserves old generation");
        { Statement s(db, "SELECT count(*) FROM marker"); require(s.step() && s.integer(0) == 1, "failed build preserves earlier caller work"); }
        exec(db, "ROLLBACK");
        for (const char *sql : {"SELECT zova_usearch_build('points',1,64)", "SELECT zova_usearch_build('missing',16,64)",
            "SELECT * FROM zova_usearch_search('points',x'00',10,128)", "SELECT * FROM zova_usearch_search('points',x'0000000000000000',0,128)"}) fails(db, sql);
        // Reopen exercises serialized HNSW, not only a warm connection-local cache.
        ok(zova_database_close(db)); db = nullptr; ok(zova_database_open_with_extensions(&open)); zova_message_free(&message);
        require(search(db, "points", {0,0}).size() == 2, "persistent reopen");
        std::puts("USearch persistence and failure checks passed");
        exec(db, "PRAGMA main.journal_mode=WAL; BEGIN");
        require(search(db, "points", {0,0}).size() == 2, "pin reader snapshot");
        zova_database *writer = nullptr; open.out_db = &writer; ok(zova_database_open_with_extensions(&open)); zova_message_free(&message);
        put(writer, "points", "committed", {0.5f,0}); build(writer, "points");
        require(search(db, "points", {0,0}).size() == 2, "old snapshot ignores newer generation and vectors");
        exec(db, "COMMIT"); require(search(db, "points", {0,0}).size() == 3, "next snapshot sees writer commit");
        ok(zova_database_close(writer)); open.out_db = &db;
        // History retirement must reconstruct against the visible snapshot.
        exec(db, "BEGIN"); for (int i = 0; i < 4400; ++i) put(db, "points", "committed", {float(i % 3),0}); exec(db, "COMMIT");
        hits = search(db, "points", {0,0}); require(hits[0].rebuilt == 1, "retired history triggers snapshot reconstruction");
        build(db, "points"); require(search(db, "points", {0,0})[0].rebuilt == 0, "rebuild restores incremental base");
        // New incarnation, same public collection name and different dimensions.
        zova_vector_collection_delete_request del{db, "points"}; ok(zova_vector_collection_delete(&del));
        collection.db = db; collection.options.dimensions = 3; ok(zova_vector_collection_create(&collection)); put(db, "points", "new", {0,0,1});
        hits = search(db, "points", {0,0,1}); require(hits.size() == 1 && hits[0].id == "new" && hits[0].rebuilt == 1, "collection recreation invalidates base");
        // Restore the portable-consumer fixture.
        ok(zova_vector_collection_delete(&del)); collection.options.dimensions = 2; ok(zova_vector_collection_create(&collection));
        put(db, "points", "one", {1,0}); put(db, "points", "two", {2,0}); build(db, "points");
        for (int type : {ZOVA_VECTOR_ELEMENT_TYPE_F32, ZOVA_VECTOR_ELEMENT_TYPE_F16, ZOVA_VECTOR_ELEMENT_TYPE_I8}) {
            for (int metric : {ZOVA_VECTOR_METRIC_L2, ZOVA_VECTOR_METRIC_COSINE, ZOVA_VECTOR_METRIC_DOT}) {
                std::string name = "typed" + std::to_string(type) + std::to_string(metric);
                std::printf("Checking %s\n", name.c_str()); std::fflush(stdout);
                zova_vector_collection_create_request typed{db,name.c_str(),{2,metric,type}}; ok(zova_vector_collection_create(&typed));
                float f32[] = {1,0}; uint16_t f16[] = {0x3c00,0}; int8_t i8[] = {1,0};
                zova_vector_values data{type,type == 0 ? f32 : nullptr,type == 1 ? f16 : nullptr,type == 2 ? i8 : nullptr,2};
                zova_vector_input rows[] = {{"b",data},{"a",data}};
                zova_vector_put_many_request many{db,name.c_str(),rows,2}; ok(zova_vector_put_many(&many)); build(db,name.c_str());
                Statement s(db,"SELECT vector_id,distance FROM zova_usearch_search(?,?,2,64)");
                zova_statement_bind_text_request nm{s.value,1,reinterpret_cast<const uint8_t *>(name.data()),name.size()}; ok(zova_statement_bind_text(&nm));
                const uint8_t *p = type == 0 ? reinterpret_cast<uint8_t *>(f32) : type == 1 ? reinterpret_cast<uint8_t *>(f16) : reinterpret_cast<uint8_t *>(i8);
                zova_statement_bind_blob_request query{s.value,2,p,size_t(type == 0 ? 8 : type == 1 ? 4 : 2)}; ok(zova_statement_bind_blob(&query));
                require(s.step() && s.text(0) == "a" && s.real(1) == (metric == ZOVA_VECTOR_METRIC_DOT ? -1 : 0), "type/metric/tie semantics");
                require(s.step() && s.text(0) == "b" && !s.step(), "ordered equal-distance results");
            }
        }
        zova_vector_collection_create_request empty{db,"empty",{2,ZOVA_VECTOR_METRIC_L2,ZOVA_VECTOR_ELEMENT_TYPE_F32}};
        std::puts("Checking empty index"); std::fflush(stdout);
        ok(zova_vector_collection_create(&empty)); build(db,"empty"); require(search(db,"empty",{0,0}).empty(), "empty collection");
        float earlier[] = {1,0}, other[] = {2,0}, final[] = {3,0};
        zova_vector_input batch[] = {
            {"same",{ZOVA_VECTOR_ELEMENT_TYPE_F32,earlier,nullptr,nullptr,2}},
            {"other",{ZOVA_VECTOR_ELEMENT_TYPE_F32,other,nullptr,nullptr,2}},
            {"same",{ZOVA_VECTOR_ELEMENT_TYPE_F32,final,nullptr,nullptr,2}}};
        zova_vector_put_many_request batch_put{db,"empty",batch,3}; ok(zova_vector_put_many(&batch_put));
        hits = search(db,"empty",{0,0}); require(hits.size() == 2 && hits[0].id == "other" && hits[1].distance == 3,"batch final occurrence and additions");
        exec(db,"SELECT zova_usearch_refresh('empty')");
        const char *deleted[] = {"other","missing","other"};
        zova_vector_delete_many_request batch_delete{db,"empty",deleted,3}; ok(zova_vector_delete_many(&batch_delete));
        hits = search(db,"empty",{0,0}); require(hits.size() == 1 && hits[0].id == "same","idempotent batch deletion");
        exec(db,"SELECT zova_usearch_refresh('empty')");
        // Wide rows: 256 of them exceed the host's 1 MiB page budget, so paging must shrink.
        // Each case is rolled back so it does not stay in the portable-consumer database.
        struct Wide { const char *name; int dims, type, count; };
        for (const Wide &wide : {Wide{"wide_f32",1536,ZOVA_VECTOR_ELEMENT_TYPE_F32,300}, Wide{"wide_f16",3072,ZOVA_VECTOR_ELEMENT_TYPE_F16,260},
                                 Wide{"wide_i8",4096,ZOVA_VECTOR_ELEMENT_TYPE_I8,260}, Wide{"widest_f32",4096,ZOVA_VECTOR_ELEMENT_TYPE_F32,130}}) {
            std::printf("Checking %s\n", wide.name); std::fflush(stdout);
            exec(db,"BEGIN");
            zova_vector_collection_create_request create{db,wide.name,{uint32_t(wide.dims),ZOVA_VECTOR_METRIC_L2,wide.type}}; ok(zova_vector_collection_create(&create));
            // Vector `slot` is the grid point (slot % 100, slot / 100), exact in every element type.
            auto put_wide = [&](const std::string &id, int slot) {
                std::vector<float> f32(wide.dims); std::vector<uint16_t> f16(wide.dims); std::vector<int8_t> i8(wide.dims);
                for (int axis = 0; axis < 2; ++axis) { int value = axis ? slot / 100 : slot % 100; if (!value) continue;
                    f32[axis] = float(value); i8[axis] = int8_t(value);
                    int exponent = std::ilogb(float(value)); f16[axis] = uint16_t((exponent + 15) << 10 | ((value << (10 - exponent)) & 1023)); }
                zova_vector_put_request q{db,wide.name,id.c_str(),{wide.type,wide.type == 0 ? f32.data() : nullptr,
                    wide.type == 1 ? f16.data() : nullptr,wide.type == 2 ? i8.data() : nullptr,size_t(wide.dims)}}; ok(zova_vector_put(&q));
            };
            auto nearest = [&](int slot) {
                std::vector<float> f32(wide.dims); std::vector<uint16_t> f16(wide.dims); std::vector<int8_t> i8(wide.dims);
                for (int axis = 0; axis < 2; ++axis) { int value = axis ? slot / 100 : slot % 100; if (!value) continue;
                    f32[axis] = float(value); i8[axis] = int8_t(value);
                    int exponent = std::ilogb(float(value)); f16[axis] = uint16_t((exponent + 15) << 10 | ((value << (10 - exponent)) & 1023)); }
                const uint8_t *p = wide.type == 0 ? reinterpret_cast<uint8_t *>(f32.data()) : wide.type == 1 ? reinterpret_cast<uint8_t *>(f16.data()) : reinterpret_cast<uint8_t *>(i8.data());
                Statement s(db,"SELECT vector_id,distance,delta_count,rebuilt FROM zova_usearch_search(?,?,1,128)");
                zova_statement_bind_text_request nm{s.value,1,reinterpret_cast<const uint8_t *>(wide.name),std::strlen(wide.name)}; ok(zova_statement_bind_text(&nm));
                zova_statement_bind_blob_request query{s.value,2,p,size_t(wide.dims) * (wide.type == 0 ? 4 : wide.type == 1 ? 2 : 1)}; ok(zova_statement_bind_blob(&query));
                require(s.step(), "wide search row"); Hit hit{s.text(0),s.real(1),s.integer(2),s.integer(3)}; require(!s.step(), "one wide hit"); return hit;
            };
            auto id = [](const char *prefix, int slot) { char text[32]; std::snprintf(text,sizeof text,"%s%05d",prefix,slot); return std::string(text); };
            for (int i = 0; i < wide.count; ++i) put_wide(id("v",i),i);
            build(db,wide.name);
            for (int i : {0, wide.count / 2, wide.count - 1}) { auto hit = nearest(i);
                require(hit.id == id("v",i) && hit.distance == 0 && hit.delta == 0 && hit.rebuilt == 0, "wide build reads every page"); }
            // More than one change page: move every vector to a fresh grid point under a new ID.
            for (int i = 0; i < wide.count; ++i) { const std::string old = id("v",i); zova_vector_delete_request gone{db,wide.name,old.c_str()}; ok(zova_vector_delete(&gone));
                put_wide(id("w",i),wide.count + i); }
            for (int i : {0, wide.count / 2, wide.count - 1}) { auto hit = nearest(wide.count + i);
                require(hit.id == id("w",i) && hit.distance == 0 && hit.delta == 2 * wide.count && hit.rebuilt == 0, "wide incremental reconciliation"); }
            require(nearest(0).id != id("v",0), "wide deletions reconcile");
            exec(db,(std::string("SELECT zova_usearch_refresh('") + wide.name + "')").c_str());
            { auto hit = nearest(wide.count); require(hit.id == id("w",0) && hit.distance == 0 && hit.delta == 0 && hit.rebuilt == 0, "wide refresh persists reconciled generation"); }
            exec(db,"ROLLBACK");
        }
        // Deletions must not count as full-width vectors against the 32 MiB delta bound:
        // 2,200 changed IDs x 3,900 dimensions x 4 bytes exceeds it, the 1,100 live rows do not.
        // Rolled back so the wide fixture does not stay in the portable-consumer database.
        {
            std::puts("Checking wide delta with deletions"); std::fflush(stdout);
            const int dims = 3900, count = 1100;
            auto point = [&](int slot) { std::vector<int8_t> v(dims); v[0] = int8_t(slot % 100); v[1] = int8_t(slot / 100); return v; };
            auto id = [](const char *prefix, int slot) { char text[32]; std::snprintf(text,sizeof text,"%s%05d",prefix,slot); return std::string(text); };
            auto put_point = [&](const std::string &name, int slot) { auto v = point(slot);
                zova_vector_put_request q{db,"delta",name.c_str(),{ZOVA_VECTOR_ELEMENT_TYPE_I8,nullptr,nullptr,v.data(),size_t(dims)}}; ok(zova_vector_put(&q)); };
            auto nearest = [&](int slot) { auto v = point(slot);
                Statement s(db,"SELECT vector_id,distance,delta_count,rebuilt FROM zova_usearch_search('delta',?,1,128)");
                zova_statement_bind_blob_request query{s.value,1,reinterpret_cast<const uint8_t *>(v.data()),v.size()}; ok(zova_statement_bind_blob(&query));
                require(s.step(), "delta search row"); return Hit{s.text(0),s.real(1),s.integer(2),s.integer(3)}; };
            exec(db,"BEGIN");
            zova_vector_collection_create_request create{db,"delta",{uint32_t(dims),ZOVA_VECTOR_METRIC_L2,ZOVA_VECTOR_ELEMENT_TYPE_I8}}; ok(zova_vector_collection_create(&create));
            for (int i = 0; i < count; ++i) put_point(id("v",i),i);
            build(db,"delta");
            for (int i = 0; i < count; ++i) { zova_vector_delete_request gone{db,"delta",id("v",i).c_str()}; ok(zova_vector_delete(&gone));
                put_point(id("w",i),count + i); }
            for (int i : {0, count / 2, count - 1}) { auto hit = nearest(count + i);
                require(hit.id == id("w",i) && hit.distance == 0 && hit.delta == 2 * count && hit.rebuilt == 0, "deletions do not exhaust the delta bound"); }
            require(nearest(0).id != id("v",0), "wide delta deletions reconcile");
            // Refresh may compact by reconstruction here; it must succeed either way.
            exec(db,"SELECT zova_usearch_refresh('delta')");
            { auto hit = nearest(count); require(hit.id == id("w",0) && hit.distance == 0 && hit.delta == 0 && hit.rebuilt == 0, "wide delta refresh persists"); }
            exec(db,"ROLLBACK");
        }
        if (argc == 5 && std::string(argv[4]) == "bench") {
            zova_vector_collection_create_request bench{db, "bench", {32, ZOVA_VECTOR_METRIC_L2, ZOVA_VECTOR_ELEMENT_TYPE_F32}};
            ok(zova_vector_collection_create(&bench)); uint32_t random = 0x5a6f7661;
            std::vector<std::vector<float>> vectors(2048, std::vector<float>(32)); std::vector<std::string> ids;
            for (size_t i = 0; i < vectors.size(); ++i) { ids.push_back("v" + std::to_string(i)); for (auto &v : vectors[i]) {
                random ^= random << 13; random ^= random >> 17; random ^= random << 5; v = float(random % 1000) / 1000; } }
            exec(db, "BEGIN"); for (size_t i = 0; i < vectors.size(); ++i) put(db, "bench", ids[i].c_str(), vectors[i]); exec(db, "COMMIT");
            for (int i = -1; i < 3; ++i) {
                auto start = std::chrono::steady_clock::now(); exec(db, "BEGIN"); auto report = build(db, "bench");
                auto before_commit = std::chrono::steady_clock::now(); exec(db, "COMMIT");
                double total = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
                double commit = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-before_commit).count();
                if (i >= 0) std::printf("BUILD sample=%d report=%s commit_ms=%.6f total_ms=%.6f\n", i, report.c_str(), commit, total);
            }
            double recall = 0; std::vector<double> samples, exact_samples;
            for (int i = 0; i < 40; ++i) {
                auto start = std::chrono::steady_clock::now(); auto approximate = search(db, "bench", vectors[i]);
                samples.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());
                zova_vector_search_results exact{}; zova_vector_search_request q{db,"bench",{ZOVA_VECTOR_ELEMENT_TYPE_F32,vectors[i].data(),nullptr,nullptr,32},10,&exact};
                start = std::chrono::steady_clock::now(); ok(zova_vector_search(&q));
                const double exact_ms = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
                for (const auto &hit : approximate) for (size_t j = 0; j < exact.len; ++j)
                    if (hit.id == std::string(exact.items[j].id,exact.items[j].id_len)) ++recall;
                auto free_start = std::chrono::steady_clock::now(); zova_vector_search_results_free(&exact);
                exact_samples.push_back(exact_ms+std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-free_start).count());
                std::printf("SEARCH_SAMPLE sample=%d ann_ms=%.6f exact_ms=%.6f\n",i,samples.back(),exact_samples.back());
            }
            std::sort(samples.begin(),samples.end()); require(recall/400 >= 0.9, "bounded fixture recall@10 >= 90%");
            std::printf("SEARCH vectors=2048 dims=32 calls=40 recall_at_10=%.6f p50_ms=%.6f p95_ms=%.6f\n",recall/400,(samples[19]+samples[20])/2,samples[37]);
            std::sort(exact_samples.begin(),exact_samples.end());
            std::printf("EXACT_C_API calls=40 p50_ms=%.6f p95_ms=%.6f\n",(exact_samples[19]+exact_samples[20])/2,exact_samples[37]);
            for (int i = -1; i < 3; ++i) { auto start = std::chrono::steady_clock::now(); exec(db,"BEGIN");
                for (int j = 0; j < 16; ++j) put(db,"bench",ids[j].c_str(),vectors[(j+1)%2048]);
                auto hits = search(db,"bench",vectors[1]);
                std::string refresh_report;
                { Statement refresh(db,"SELECT zova_usearch_refresh('bench')"); require(refresh.step(),"refresh report"); refresh_report = refresh.text(0); require(!refresh.step(),"one refresh report"); }
                require(search(db,"bench",vectors[1])[0].delta == 0,"incremental HNSW refresh visible before commit");
                auto before_commit = std::chrono::steady_clock::now(); exec(db,"COMMIT");
                double commit = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-before_commit).count();
                if (i >= 0) std::printf("INCREMENTAL sample=%d rows=16 report=%s commit_ms=%.6f total_ms=%.6f delta=%lld\n",i,refresh_report.c_str(),commit,
                    std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count(),(long long)hits[0].delta); }
#if defined(__unix__) || defined(__APPLE__)
            rusage usage{}; getrusage(RUSAGE_SELF,&usage);
#ifdef __APPLE__
            std::printf("PEAK_RSS_MiB %.3f\n",usage.ru_maxrss/(1024.0*1024.0));
#else
            std::printf("PEAK_RSS_MiB %.3f\n",usage.ru_maxrss/1024.0);
#endif
#endif
        }
        zova_database_extension_request repair{db,"usearch"};
        exec(db,"BEGIN; UPDATE _zova_ext_usearch_chunks SET data=x'00' WHERE name='points'");
        ok(zova_database_extension_rebuild(&repair));
        require(search(db,"points",{0,0})[0].id == "one","recovery rebuild repairs derived corruption");
        exec(db,"ROLLBACK");
        const std::string backup_path = std::string(argv[2])+".backup.zova";
        zova_database_backup_request backup{db,backup_path.c_str(),0}; ok(zova_database_backup(&backup));
        zova_database *copy = nullptr; auto copy_open = open; copy_open.path = backup_path.c_str(); copy_open.out_db = &copy;
        ok(zova_database_open_with_extensions(&copy_open)); zova_message_free(&message);
        require(search(copy,"points",{0,0})[0].id == "one","backup includes persistent index and source"); ok(zova_database_close(copy));
        // Read-only opens can reconcile and query but cannot replace persisted bases.
        ok(zova_database_close(db)); db = nullptr; open.flags = ZOVA_OPEN_READ_ONLY;
        ok(zova_database_open_with_extensions(&open)); zova_message_free(&message);
        require(search(db,"points",{0,0})[0].id == "one", "read-only search"); fails(db,"SELECT zova_usearch_build('points',16,64)");
        // Use bundled SQLite capabilities, not the runner's Python SQLite.
        { Statement sizes(db,"SELECT s.name,sum(d.pgsize) FROM dbstat d JOIN sqlite_schema s ON s.name=d.name WHERE s.tbl_name LIKE '_zova_ext_usearch_%' GROUP BY s.name");
          while (sizes.step()) std::printf("PLUGIN_DBSTAT name=%s bytes=%lld\n",sizes.text(0).c_str(),(long long)sizes.integer(1)); }
        ok(zova_database_close(db)); db = nullptr;
        std::puts("USearch behavior checks passed"); return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "USearch test: %s\n", error.what());
        if (db) zova_database_close(db);
        return 1;
    }
}
