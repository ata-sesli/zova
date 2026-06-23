#include "zova.h"

#include <cstddef>
#include <cstdint>

static_assert(sizeof(zova_object_id) == 32, "object ids are fixed 32-byte SHA-256 values");
static_assert(sizeof(zova_object_chunk_id) == 32, "chunk ids are fixed 32-byte SHA-256 values");
static_assert(ZOVA_VECTOR_METRIC_COSINE == 0, "vector metric values are stable");
static_assert(ZOVA_VECTOR_METRIC_L2 == 1, "vector metric values are stable");
static_assert(ZOVA_VECTOR_METRIC_DOT == 2, "vector metric values are stable");
static_assert(ZOVA_STEP_ROW == 1, "step result values are stable");
static_assert(ZOVA_STEP_DONE == 2, "step result values are stable");
static_assert(ZOVA_COLUMN_INTEGER == 1, "column type values are stable");
static_assert(ZOVA_COLUMN_NULL == 5, "column type values are stable");
static_assert(ZOVA_VECTOR_INVALID == 75, "vector status values are stable");

int main() {
    zova_database *db = nullptr;
    zova_statement *statement = nullptr;
    zova_buffer buffer = {};
    zova_text text = {};
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
    zova_database_prepare_request prepare_request = {};
    prepare_request.out_statement = &statement;
    zova_database_last_insert_rowid_request last_rowid_request = {};
    int64_t last_rowid = 0;
    last_rowid_request.out_rowid = &last_rowid;
    zova_database_changes_request changes_request = {};
    int64_t changes = 0;
    changes_request.out_changes = &changes;
    zova_database_total_changes_request total_changes_request = {};
    int64_t total_changes = 0;
    total_changes_request.out_total_changes = &total_changes;
    zova_statement_step_request step_request = {};
    step_request.statement = statement;
    zova_step_result step_result = ZOVA_STEP_DONE;
    step_request.out_result = &step_result;
    zova_statement_bind_text_request bind_text_request = {};
    bind_text_request.data = reinterpret_cast<const uint8_t *>("hello");
    bind_text_request.len = 5;
    zova_statement_column_type_request column_type_request = {};
    zova_column_type column_type = ZOVA_COLUMN_NULL;
    column_type_request.out_type = &column_type;
    zova_statement_column_name_request column_name_request = {};
    column_name_request.out_name = &text;
    zova_statement_column_text_request column_text_request = {};
    column_text_request.out_text = &text;
    zova_statement_column_blob_request column_blob_request = {};
    column_blob_request.out_buffer = &buffer;
    zova_database_simple_request simple_request = {};
    simple_request.db = db;
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
    zova_text_free(&text);
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
                   prepare_request.out_statement == &statement &&
                   last_rowid_request.out_rowid == &last_rowid &&
                   changes_request.out_changes == &changes &&
                   total_changes_request.out_total_changes == &total_changes &&
                   step_request.out_result == &step_result &&
                   bind_text_request.len == 5 &&
                   column_type_request.out_type == &column_type &&
                   column_name_request.out_name == &text &&
                   column_text_request.out_text == &text &&
                   column_blob_request.out_buffer == &buffer &&
                   simple_request.db == db &&
                   id.bytes[0] == 0
               ? 0
               : 1;
}
