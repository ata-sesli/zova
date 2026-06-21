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
    zova_vector_collection_info collection_info = {};
    zova_vector_collection_list collection_list = {};
    zova_vector_collection_options options = {
        3,
        ZOVA_VECTOR_METRIC_COSINE,
    };
    zova_vector_input vector_inputs[1] = {};
    vector_inputs[0].id = "chunk-001";
    vector_inputs[0].values = nullptr;
    vector_inputs[0].values_len = 0;
    zova_vector_put_many_request put_many_request = {};
    put_many_request.vectors = vector_inputs;
    put_many_request.vectors_len = 1;
    zova_vector_collection_info_get_request info_request = {};
    info_request.out_info = &collection_info;
    zova_vector_collections_list_request list_request = {};
    list_request.out_list = &collection_list;
    zova_vector_collection_delete_request delete_collection_request = {};
    delete_collection_request.name = "chunks";
    zova_vector_search_request search_request = {};
    search_request.collection_name = "chunks";
    search_request.query = nullptr;
    search_request.query_len = 0;
    search_request.limit = 0;
    search_request.out_results = &search_results;
    zova_vector_search_within_request within_request = {};
    within_request.collection_name = "chunks";
    within_request.max_distance = 0.0;
    zova_vector_search_in_within_request in_within_request = {};
    in_within_request.collection_name = "chunks";
    in_within_request.candidate_ids = nullptr;
    zova_vector_search_by_id_request by_id_request = {};
    by_id_request.collection_name = "chunks";
    by_id_request.source_vector_id = "chunk-001";
    zova_vector_search_by_id_in_request by_id_in_request = {};
    by_id_in_request.collection_name = "chunks";
    by_id_in_request.source_vector_id = "chunk-001";
    by_id_in_request.candidate_ids = nullptr;
    zova_vector_search_by_id_within_request by_id_within_request = {};
    by_id_within_request.collection_name = "chunks";
    by_id_within_request.source_vector_id = "chunk-001";
    zova_vector_search_by_id_in_within_request by_id_in_within_request = {};
    by_id_in_within_request.collection_name = "chunks";
    by_id_in_within_request.source_vector_id = "chunk-001";
    by_id_in_within_request.candidate_ids = nullptr;

    zova_buffer_free(&buffer);
    zova_object_manifest_free(&manifest);
    zova_vector_free(&vector);
    zova_vector_search_results_free(&search_results);
    zova_vector_collection_info_free(&collection_info);
    zova_vector_collection_list_free(&collection_list);

    return zova_database_close(db) == ZOVA_INVALID_ARGUMENT &&
                   options.metric == ZOVA_VECTOR_METRIC_COSINE &&
                   put_many_request.vectors_len == 1 &&
                   info_request.out_info == &collection_info &&
                   list_request.out_list == &collection_list &&
                   delete_collection_request.name != nullptr &&
                   within_request.max_distance == 0.0 &&
                   in_within_request.candidate_ids == nullptr &&
                   by_id_request.source_vector_id != nullptr &&
                   by_id_in_request.candidate_ids == nullptr &&
                   by_id_within_request.source_vector_id != nullptr &&
                   by_id_in_within_request.candidate_ids == nullptr &&
                   zova_status_name(ZOVA_VECTOR_INVALID) != nullptr &&
                   zova_status_name(ZOVA_OK) != nullptr &&
                   zova_abi_version_string() != nullptr &&
                   id.bytes[0] == 0
               ? 0
               : 1;
}
