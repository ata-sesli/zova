#include "zova.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { SAMPLES = 512, WARMUPS = 32, ROWS = 128 };
typedef struct {
    void *library;
    zova_status (*create)(const zova_database_create_memory_request *);
    zova_status (*close)(zova_database *);
    zova_status (*collection)(const zova_vector_collection_create_request *);
    zova_status (*put)(const zova_vector_put_request *);
    zova_status (*search)(const zova_vector_search_request *);
    zova_status (*search_in)(const zova_vector_search_in_request *);
    void (*free_results)(zova_vector_search_results *);
} api;

static void check(zova_status status) {
    if (status != ZOVA_OK) { fprintf(stderr, "Zova status %d\n", status); exit(1); }
}

static void *symbol(void *library, const char *name) {
    void *result = dlsym(library, name);
    if (!result) { fprintf(stderr, "%s: %s\n", name, dlerror()); exit(1); }
    return result;
}

static api load(const char *path) {
    api a = {0};
    a.library = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    if (!a.library) { fprintf(stderr, "%s\n", dlerror()); exit(1); }
#define LOAD(field, name) a.field = (__typeof__(a.field))symbol(a.library, name)
    LOAD(create, "zova_database_create_memory");
    LOAD(close, "zova_database_close");
    LOAD(collection, "zova_vector_collection_create");
    LOAD(put, "zova_vector_put");
    LOAD(search, "zova_vector_search");
    LOAD(search_in, "zova_vector_search_in");
    LOAD(free_results, "zova_vector_search_results_free");
#undef LOAD
    return a;
}

static uint64_t ticks(clockid_t clock) {
    struct timespec t;
    if (clock_gettime(clock, &t)) { perror("clock_gettime"); exit(1); }
    return (uint64_t)t.tv_sec * 1000000000 + (uint64_t)t.tv_nsec;
}

static uint64_t digest(const zova_vector_search_results *results) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < results->len; ++i) {
        const zova_vector_search_result *r = &results->items[i];
        for (size_t j = 0; j < r->id_len; ++j) hash = (hash ^ (unsigned char)r->id[j]) * UINT64_C(1099511628211);
        const unsigned char *bytes = (const unsigned char *)&r->distance;
        for (size_t j = 0; j < sizeof(r->distance); ++j) hash = (hash ^ bytes[j]) * UINT64_C(1099511628211);
    }
    return hash;
}

typedef struct { uint64_t wall, cpu, digest; } sample;

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    api implementations[2] = {load(argv[1]), load(argv[2])};
    if (implementations[0].search == implementations[1].search) {
        fprintf(stderr, "Libraries resolved to the same implementation\n"); return 1;
    }
    printf("case,phase,run,sample,variant,wall_ns,cpu_ns,digest\n");
    for (int fixture = 0; fixture < 2; ++fixture) {
        const int type = fixture == 0 ? ZOVA_VECTOR_ELEMENT_TYPE_F16 : ZOVA_VECTOR_ELEMENT_TYPE_F32;
        const int metric = fixture == 0 ? ZOVA_VECTOR_METRIC_DOT : ZOVA_VECTOR_METRIC_L2;
        const size_t dimensions = fixture == 0 ? 33 : 384;
        float floats[384]; uint16_t halves[384];
        char names[ROWS][16]; const char *ids[ROWS];
        zova_database *db[2] = {0};
        for (int v = 0; v < 2; ++v) {
            check(implementations[v].create(&(zova_database_create_memory_request){.out_db=&db[v]}));
            check(implementations[v].collection(&(zova_vector_collection_create_request){.db=db[v], .name="bench", .options={.dimensions=(uint32_t)dimensions,.metric=metric,.element_type=type}}));
        }
        zova_vector_values values = {.element_type=type, .values_len=dimensions};
        if (fixture == 0) values.f16_values = halves; else values.f32_values = floats;
        for (size_t row = 0; row < ROWS; ++row) {
            snprintf(names[row], sizeof(names[row]), "v-%03zu", row); ids[row] = names[row];
            for (size_t col = 0; col < dimensions; ++col) {
                floats[col] = (float)((int)((row*17+col*13)%127)-63)/16;
                _Float16 half = (_Float16)floats[col]; memcpy(&halves[col], &half, sizeof(half));
            }
            for (int v = 0; v < 2; ++v) check(implementations[v].put(&(zova_vector_put_request){.db=db[v],.collection_name="bench",.vector_id=ids[row],.values=values}));
        }
        for (int phase = 0; phase < 2; ++phase) {
            for (int run = 0; run < 7; ++run) {
                sample samples[2][SAMPLES];
                for (int i = -WARMUPS; i < SAMPLES; ++i) {
                    uint64_t hashes[2];
                    for (int position = 0; position < 2; ++position) {
                        const int v = (position + run + i + WARMUPS) % 2;
                        api *a = &implementations[v];
                        zova_vector_search_results results = {0};
                        const uint64_t cpu_start = ticks(CLOCK_THREAD_CPUTIME_ID);
                        const uint64_t wall_start = ticks(CLOCK_MONOTONIC);
                        zova_status status;
                        if (fixture == 1 && phase == 0) {
                            status = a->search_in(&(zova_vector_search_in_request){.db=db[v],.collection_name="bench",.query=values,.candidate_ids=ids,.candidate_count=16,.limit=10,.out_results=&results});
                        } else {
                            status = a->search(&(zova_vector_search_request){.db=db[v],.collection_name="bench",.query=values,.limit=phase==0?10:0,.out_results=&results});
                        }
                        const uint64_t wall_end = ticks(CLOCK_MONOTONIC);
                        const uint64_t cpu_end = ticks(CLOCK_THREAD_CPUTIME_ID);
                        check(status);
                        hashes[v] = digest(&results);
                        if (i >= 0) samples[v][i] = (sample){wall_end-wall_start,cpu_end-cpu_start,hashes[v]};
                        a->free_results(&results);
                    }
                    if (hashes[0] != hashes[1]) { fprintf(stderr, "Parity failure\n"); return 1; }
                }
                for (int i = 0; i < SAMPLES; ++i) for (int v = 0; v < 2; ++v) {
                    sample s = samples[v][i];
                    printf("%s,%s,%d,%d,%s,%llu,%llu,%llx\n",fixture==0?"f16-dot-33-full":"f32-l2-384-candidate",phase==0?"search":"prepare-control",run+1,i+1,v==0?"baseline":"candidate",(unsigned long long)s.wall,(unsigned long long)s.cpu,(unsigned long long)s.digest);
                }
            }
        }
        for (int v = 0; v < 2; ++v) check(implementations[v].close(db[v]));
    }
    for (int v = 0; v < 2; ++v) dlclose(implementations[v].library);
    return 0;
}
