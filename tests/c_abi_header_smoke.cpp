#include "zova.h"

#include <cstddef>
#include <cstdint>

static_assert(sizeof(zova_object_id) == 32, "object ids are fixed 32-byte SHA-256 values");
static_assert(sizeof(zova_object_chunk_id) == 32, "chunk ids are fixed 32-byte SHA-256 values");
static_assert(ZOVA_VECTOR_METRIC_COSINE == 0, "vector metric values are stable");
static_assert(ZOVA_VECTOR_METRIC_L2 == 1, "vector metric values are stable");
static_assert(ZOVA_VECTOR_METRIC_DOT == 2, "vector metric values are stable");
static_assert(ZOVA_VECTOR_INVALID == 75, "vector status values are stable");

int main() {
    zova_database *db = nullptr;
    zova_buffer buffer = {};
    zova_object_manifest manifest = {};
    zova_object_id id = {};
    zova_vector vector = {};
    zova_vector_search_results search_results = {};
    zova_vector_collection_options options = {
        3,
        ZOVA_VECTOR_METRIC_COSINE,
    };
    zova_vector_search_request search_request = {};
    search_request.collection_name = "chunks";
    search_request.query = nullptr;
    search_request.query_len = 0;
    search_request.limit = 0;
    search_request.out_results = &search_results;

    zova_buffer_free(&buffer);
    zova_object_manifest_free(&manifest);
    zova_vector_free(&vector);
    zova_vector_search_results_free(&search_results);

    return zova_database_close(db) == ZOVA_INVALID_ARGUMENT &&
                   options.metric == ZOVA_VECTOR_METRIC_COSINE &&
                   zova_status_name(ZOVA_VECTOR_INVALID) != nullptr &&
                   zova_status_name(ZOVA_OK) != nullptr &&
                   zova_abi_version_string() != nullptr &&
                   id.bytes[0] == 0
               ? 0
               : 1;
}
