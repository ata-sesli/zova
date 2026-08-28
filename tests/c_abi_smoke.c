#include "zova.h"
#include "sqlite3.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void expect_status(zova_status actual, zova_status expected, const char *label) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %s, got %s\n", label, zova_status_name(expected), zova_status_name(actual));
        exit(1);
    }
}

static void expect_bytes(const uint8_t *actual, const uint8_t *expected, size_t len, const char *label) {
    if (memcmp(actual, expected, len) != 0) {
        fprintf(stderr, "%s: byte mismatch\n", label);
        exit(1);
    }
}

static void expect_id_equal(zova_object_id left, zova_object_id right, const char *label) {
    if (memcmp(left.bytes, right.bytes, sizeof(left.bytes)) != 0) {
        fprintf(stderr, "%s: object id mismatch\n", label);
        exit(1);
    }
}

static void expect_chunk_id_equal(zova_object_chunk_id left, zova_object_chunk_id right, const char *label) {
    if (memcmp(left.bytes, right.bytes, sizeof(left.bytes)) != 0) {
        fprintf(stderr, "%s: chunk id mismatch\n", label);
        exit(1);
    }
}

static void expect_float_values(const float *actual, const float *expected, size_t len, const char *label) {
    for (size_t i = 0; i < len; i += 1) {
        if (actual[i] != expected[i]) {
            fprintf(stderr, "%s: float mismatch at %zu\n", label, i);
            exit(1);
        }
    }
}

static zova_vector_values f32_values(const float *values, size_t len) {
    return (zova_vector_values){
        .element_type = ZOVA_VECTOR_ELEMENT_TYPE_F32,
        .f32_values = values,
        .f16_values = NULL,
        .i8_values = NULL,
        .values_len = len,
    };
}

static void expect_result_id(const zova_vector_search_results *results, size_t index, const char *expected, const char *label) {
    size_t expected_len = strlen(expected);
    if (index >= results->len || results->items[index].id_len != expected_len ||
        memcmp(results->items[index].id, expected, expected_len) != 0) {
        fprintf(stderr, "%s: unexpected vector search id at %zu\n", label, index);
        exit(1);
    }
}

static void expect_collection_info(
    const zova_vector_collection_info *info,
    const char *expected_name,
    uint32_t expected_dimensions,
    int expected_metric,
    int expected_element_type,
    uint64_t expected_count,
    const char *label
) {
    size_t expected_len = strlen(expected_name);
    if (info->name_len != expected_len || memcmp(info->name, expected_name, expected_len) != 0 ||
        info->dimensions != expected_dimensions || info->metric != expected_metric ||
        info->element_type != expected_element_type || info->vector_count != expected_count) {
        fprintf(stderr, "%s: unexpected collection info\n", label);
        exit(1);
    }
}

static void expect_graph_text(const char *actual, size_t actual_len, const char *expected, const char *label) {
    size_t expected_len = strlen(expected);
    if (actual_len != expected_len || memcmp(actual, expected, expected_len) != 0) {
        fprintf(stderr, "%s: unexpected graph text\n", label);
        exit(1);
    }
}

static void expect_message_contains(zova_message *message, const char *needle, const char *label) {
    size_t needle_len = strlen(needle);
    int found = 0;
    if (message->data != NULL && message->len >= needle_len) {
        for (size_t i = 0; i + needle_len <= message->len; i += 1) {
            if (memcmp(message->data + i, needle, needle_len) == 0) {
                found = 1;
                break;
            }
        }
    }
    if (!found) {
        fprintf(stderr, "%s: expected message containing %s\n", label, needle);
        exit(1);
    }
}

static void copy_file(const char *source_path, const char *dest_path, const char *label) {
    FILE *source = fopen(source_path, "rb");
    if (source == NULL) {
        fprintf(stderr, "%s: unable to open source\n", label);
        exit(1);
    }
    FILE *dest = fopen(dest_path, "wb");
    if (dest == NULL) {
        fclose(source);
        fprintf(stderr, "%s: unable to open destination\n", label);
        exit(1);
    }
    unsigned char buffer[4096];
    size_t n = 0;
    while ((n = fread(buffer, 1, sizeof(buffer), source)) != 0) {
        if (fwrite(buffer, 1, n, dest) != n) {
            fclose(source);
            fclose(dest);
            fprintf(stderr, "%s: write failed\n", label);
            exit(1);
        }
    }
    if (ferror(source)) {
        fclose(source);
        fclose(dest);
        fprintf(stderr, "%s: read failed\n", label);
        exit(1);
    }
    fclose(source);
    fclose(dest);
}

static void write_text_file(const char *path, const char *data, const char *label) {
    FILE *file = fopen(path, "wb");
    if (file == NULL) {
        fprintf(stderr, "%s: unable to open file\n", label);
        exit(1);
    }
    size_t len = strlen(data);
    if (fwrite(data, 1, len, file) != len) {
        fclose(file);
        fprintf(stderr, "%s: write failed\n", label);
        exit(1);
    }
    fclose(file);
}

static void path_join(char *out, size_t out_len, const char *dir, const char *name) {
    int written = snprintf(out, out_len, "%s/%s", dir, name);
    if (written < 0 || (size_t)written >= out_len) {
        fprintf(stderr, "path too long\n");
        exit(1);
    }
}

static void make_dyn_test_bundle(const char *library_path, const char *bundle_path) {
    char library_dest[1024];
    char manifest_path[1024];
    path_join(library_dest, sizeof(library_dest), bundle_path, "libdyn_test");
    path_join(manifest_path, sizeof(manifest_path), bundle_path, "extension.json");
    remove(library_dest);
    remove(manifest_path);
    rmdir(bundle_path);
    if (mkdir(bundle_path, 0700) != 0) {
        fprintf(stderr, "make dyn bundle: mkdir failed\n");
        exit(1);
    }
    copy_file(library_path, library_dest, "copy dyn library");
    write_text_file(
        manifest_path,
        "{\n"
        "  \"name\": \"dyn_test\",\n"
        "  \"version\": \"0.1.0\",\n"
        "  \"storage_prefix\": \"_zova_ext_dyn_test_\",\n"
        "  \"zova_abi_min\": \"0.21.0\",\n"
        "  \"capabilities\": \"sql,dynamic-test\",\n"
        "  \"library\": \"libdyn_test\"\n"
        "}\n",
        "write dyn manifest"
    );
}

typedef struct sql_callback_state {
    int calls;
    int saw_user_data;
    int destroyed;
} sql_callback_state;

static void smoke_sql_destroy(void *user_data) {
    sql_callback_state *state = (sql_callback_state *)user_data;
    state->destroyed = 1;
}

static void smoke_sql_mix(void *user_data, const zova_sql_function_call *call, zova_sql_result *out_result) {
    sql_callback_state *state = (sql_callback_state *)user_data;
    state->calls += 1;
    state->saw_user_data = call->user_data == user_data;
    if (call->argc != 3 ||
        call->argv[0].value_type != ZOVA_SQL_VALUE_INTEGER ||
        call->argv[0].int64_value != 4 ||
        call->argv[1].value_type != ZOVA_SQL_VALUE_TEXT ||
        call->argv[1].data_len != 3 ||
        memcmp(call->argv[1].data, "cat", 3) != 0 ||
        call->argv[2].value_type != ZOVA_SQL_VALUE_BLOB ||
        call->argv[2].data_len != 2) {
        out_result->result_type = ZOVA_SQL_RESULT_ERROR;
        out_result->error_message = "bad callback arguments";
        out_result->error_message_len = strlen(out_result->error_message);
        return;
    }
    out_result->result_type = ZOVA_SQL_RESULT_INTEGER;
    out_result->int64_value = 99;
}

static void smoke_sql_text(void *user_data, const zova_sql_function_call *call, zova_sql_result *out_result) {
    (void)user_data;
    (void)call;
    out_result->result_type = ZOVA_SQL_RESULT_TEXT;
    out_result->data = "from-c";
    out_result->data_len = strlen("from-c");
}

static void smoke_sql_error(void *user_data, const zova_sql_function_call *call, zova_sql_result *out_result) {
    (void)user_data;
    (void)call;
    out_result->result_type = ZOVA_SQL_RESULT_ERROR;
    out_result->error_message = "c callback failed";
    out_result->error_message_len = strlen(out_result->error_message);
}

static void run_sql_function_smoke(zova_database *db, sql_callback_state *state) {
    expect_status(zova_database_register_function(&(zova_sql_function_register_request){
                      .db = db,
                      .name = "app_c_mix",
                      .arity = 3,
                      .flags = ZOVA_SQL_FUNCTION_DETERMINISTIC | ZOVA_SQL_FUNCTION_INNOCUOUS,
                      .user_data = state,
                      .callback = smoke_sql_mix,
                      .destroy = smoke_sql_destroy,
                  }),
                  ZOVA_OK,
                  "register c sql mix");
    expect_status(zova_database_register_function(&(zova_sql_function_register_request){
                      .db = db,
                      .name = "app_c_text",
                      .arity = 0,
                      .flags = ZOVA_SQL_FUNCTION_DIRECT_ONLY,
                      .user_data = NULL,
                      .callback = smoke_sql_text,
                      .destroy = NULL,
                  }),
                  ZOVA_OK,
                  "register c sql text");
    expect_status(zova_database_register_function(&(zova_sql_function_register_request){
                      .db = db,
                      .name = "app_c_fail",
                      .arity = 0,
                      .flags = 0,
                      .user_data = NULL,
                      .callback = smoke_sql_error,
                      .destroy = NULL,
                  }),
                  ZOVA_OK,
                  "register c sql error");
    expect_status(zova_database_register_function(&(zova_sql_function_register_request){
                      .db = db,
                      .name = "app_c_mix",
                      .arity = 3,
                      .flags = 0,
                      .user_data = state,
                      .callback = smoke_sql_mix,
                      .destroy = NULL,
                  }),
                  ZOVA_INVALID_ARGUMENT,
                  "register duplicate c sql function");

    zova_statement *stmt = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select app_c_mix(4, 'cat', x'0102'), app_c_text()",
                      .out_statement = &stmt,
                  }),
                  ZOVA_OK,
                  "prepare c sql function");
    zova_step_result step = ZOVA_STEP_DONE;
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = stmt,
                      .out_result = &step,
                  }),
                  ZOVA_OK,
                  "step c sql function");
    if (step != ZOVA_STEP_ROW) {
        fprintf(stderr, "step c sql function: expected row\n");
        exit(1);
    }
    int64_t value = 0;
    expect_status(zova_statement_column_int64(&(zova_statement_column_int64_request){
                      .statement = stmt,
                      .index = 0,
                      .out_value = &value,
                  }),
                  ZOVA_OK,
                  "c sql function int result");
    if (value != 99 || state->calls != 1 || !state->saw_user_data) {
        fprintf(stderr, "c sql function int result: unexpected callback state\n");
        exit(1);
    }
    zova_text text = {0};
    expect_status(zova_statement_column_text(&(zova_statement_column_text_request){
                      .statement = stmt,
                      .index = 1,
                      .out_text = &text,
                  }),
                  ZOVA_OK,
                  "c sql function text result");
    if (text.len != strlen("from-c") || memcmp(text.data, "from-c", text.len) != 0) {
        fprintf(stderr, "c sql function text result: unexpected text\n");
        exit(1);
    }
    zova_text_free(&text);
    expect_status(zova_statement_finalize(stmt), ZOVA_OK, "finalize c sql function statement");

    expect_status(zova_database_exec(&(zova_database_exec_request){
                      .db = db,
                      .sql = "select app_c_fail()",
                  }),
                  ZOVA_SQLITE_ERROR,
                  "c sql function callback error");
    const char *message = zova_database_last_error_message(db);
    if (message == NULL || strstr(message, "c callback failed") == NULL) {
        fprintf(stderr, "c sql function callback error: missing diagnostic\n");
        exit(1);
    }
}

static void run_graph_smoke(zova_database *db) {
    expect_status(zova_graph_create(&(zova_graph_create_request){
                      .db = db,
                      .name = "app",
                  }),
                  ZOVA_OK,
                  "graph create");
    expect_status(zova_graph_create(&(zova_graph_create_request){
                      .db = db,
                      .name = "app",
                  }),
                  ZOVA_GRAPH_EXISTS,
                  "graph create duplicate");

    uint8_t exists = 0;
    expect_status(zova_graph_exists(&(zova_graph_exists_request){
                      .db = db,
                      .name = "app",
                      .out_exists = &exists,
                  }),
                  ZOVA_OK,
                  "graph exists");
    if (!exists) {
        fprintf(stderr, "graph exists: expected true\n");
        exit(1);
    }

    expect_status(zova_graph_node_put(&(zova_graph_node_put_request){
                      .db = db,
                      .graph_name = "app",
                      .node_id = "message:1",
                      .kind = "message",
                      .target_type = ZOVA_GRAPH_TARGET_RECORD,
                      .target_namespace = NULL,
                      .target_ref = "messages:1",
                  }),
                  ZOVA_OK,
                  "graph node put message 1");
    expect_status(zova_graph_node_put(&(zova_graph_node_put_request){
                      .db = db,
                      .graph_name = "app",
                      .node_id = "message:2",
                      .kind = "message",
                      .target_type = ZOVA_GRAPH_TARGET_RECORD,
                      .target_namespace = NULL,
                      .target_ref = "messages:2",
                  }),
                  ZOVA_OK,
                  "graph node put message 2");
    expect_status(zova_graph_node_put(&(zova_graph_node_put_request){
                      .db = db,
                      .graph_name = "app",
                      .node_id = "attachment:1",
                      .kind = "attachment",
                      .target_type = ZOVA_GRAPH_TARGET_EXTERNAL,
                      .target_namespace = "attachments",
                      .target_ref = "",
                  }),
                  ZOVA_OK,
                  "graph node put attachment");

    zova_graph_node node = {0};
    expect_status(zova_graph_node_get(&(zova_graph_node_get_request){
                      .db = db,
                      .graph_name = "app",
                      .node_id = "attachment:1",
                      .out_node = &node,
                  }),
                  ZOVA_OK,
                  "graph node get");
    expect_graph_text(node.node_id, node.node_id_len, "attachment:1", "graph node id");
    if (!node.has_target_namespace || !node.has_target_ref || node.target_ref_len != 0) {
        fprintf(stderr, "graph node get: unexpected optional target fields\n");
        exit(1);
    }
    zova_graph_node_free(&node);

    expect_status(zova_graph_edge_put(&(zova_graph_edge_put_request){
                      .db = db,
                      .graph_name = "app",
                      .from_node_id = "message:1",
                      .edge_type = "replies_to",
                      .to_node_id = "message:2",
                  }),
                  ZOVA_OK,
                  "graph edge put reply");
    expect_status(zova_graph_edge_put(&(zova_graph_edge_put_request){
                      .db = db,
                      .graph_name = "app",
                      .from_node_id = "message:1",
                      .edge_type = "has_attachment",
                      .to_node_id = "attachment:1",
                  }),
                  ZOVA_OK,
                  "graph edge put attachment");

    zova_graph_edge edge = {0};
    expect_status(zova_graph_edge_get(&(zova_graph_edge_get_request){
                      .db = db,
                      .graph_name = "app",
                      .from_node_id = "message:1",
                      .edge_type = "has_attachment",
                      .to_node_id = "attachment:1",
                      .out_edge = &edge,
                  }),
                  ZOVA_OK,
                  "graph edge get");
    expect_graph_text(edge.edge_type, edge.edge_type_len, "has_attachment", "graph edge type");
    zova_graph_edge_free(&edge);

    zova_graph_info info = {0};
    expect_status(zova_graph_info_get(&(zova_graph_info_get_request){
                      .db = db,
                      .name = "app",
                      .out_info = &info,
                  }),
                  ZOVA_OK,
                  "graph info");
    if (info.node_count != 3 || info.edge_count != 2) {
        fprintf(stderr, "graph info: unexpected counts\n");
        exit(1);
    }
    zova_graph_info_free(&info);

    zova_graph_list list = {0};
    expect_status(zova_graphs_list(&(zova_graph_list_request){
                      .db = db,
                      .out_list = &list,
                  }),
                  ZOVA_OK,
                  "graph list");
    if (list.len != 1) {
        fprintf(stderr, "graph list: unexpected count\n");
        exit(1);
    }
    zova_graph_list_free(&list);

    const zova_graph_node_input batch_nodes[] = {
        {.graph_name = "app", .node_id = "batch:1", .kind = "function", .target_type = ZOVA_GRAPH_TARGET_NONE, .target_namespace = NULL, .target_ref = NULL},
        {.graph_name = "app", .node_id = "batch:2", .kind = "function", .target_type = ZOVA_GRAPH_TARGET_NONE, .target_namespace = NULL, .target_ref = NULL},
    };
    expect_status(zova_graph_node_put_many(&(zova_graph_node_put_many_request){
                      .db = db,
                      .nodes = batch_nodes,
                      .nodes_len = sizeof(batch_nodes) / sizeof(batch_nodes[0]),
                  }),
                  ZOVA_OK,
                  "graph node batch put");
    const zova_graph_edge_input batch_edges[] = {
        {.graph_name = "app", .from_node_id = "batch:1", .edge_type = "calls", .to_node_id = "batch:2"},
        {.graph_name = "app", .from_node_id = "batch:1", .edge_type = "calls", .to_node_id = "batch:2"},
    };
    expect_status(zova_graph_edge_put_many(&(zova_graph_edge_put_many_request){
                      .db = db,
                      .edges = batch_edges,
                      .edges_len = sizeof(batch_edges) / sizeof(batch_edges[0]),
                  }),
                  ZOVA_OK,
                  "graph edge batch put");

    const zova_graph_node_input keyed_nodes[] = {
        {.graph_name = "app", .node_id = "keyed:z", .kind = "first", .target_type = ZOVA_GRAPH_TARGET_NONE},
        {.graph_name = "app", .node_id = "keyed:a", .kind = "neighbor", .target_type = ZOVA_GRAPH_TARGET_NONE},
        {.graph_name = "app", .node_id = "keyed:z", .kind = "final", .target_type = ZOVA_GRAPH_TARGET_NONE},
    };
    int64_t node_keys[] = {-1, -1, -1};
    expect_status(zova_graph_node_put_many_keyed(&(zova_graph_node_put_many_keyed_request){
                      .db = db,
                      .nodes = keyed_nodes,
                      .nodes_len = 3,
                      .out_node_keys = node_keys,
                      .out_node_keys_capacity = 2,
                  }),
                  ZOVA_INVALID_ARGUMENT,
                  "keyed node capacity");
    if (node_keys[0] != -1 || node_keys[1] != -1 || node_keys[2] != -1) {
        fprintf(stderr, "keyed node capacity changed output\n");
        exit(1);
    }
    expect_status(zova_graph_node_put_many_keyed(&(zova_graph_node_put_many_keyed_request){
                      .db = db,
                      .nodes = keyed_nodes,
                      .nodes_len = 3,
                      .out_node_keys = node_keys,
                      .out_node_keys_capacity = 3,
                  }),
                  ZOVA_OK,
                  "keyed node put many");
    if (node_keys[0] <= 0 || node_keys[1] <= 0 || node_keys[0] != node_keys[2] || node_keys[0] == node_keys[1]) {
        fprintf(stderr, "keyed node outputs are not aligned or stable\n");
        exit(1);
    }

    const zova_graph_edge_input keyed_edges[] = {
        {.graph_name = "app", .from_node_id = "keyed:z", .edge_type = "calls", .to_node_id = "keyed:a"},
        {.graph_name = "app", .from_node_id = "keyed:z", .edge_type = "calls", .to_node_id = "keyed:a"},
    };
    int64_t edge_keys[] = {-1, -1};
    expect_status(zova_graph_edge_put_many_keyed(&(zova_graph_edge_put_many_keyed_request){
                      .db = db,
                      .edges = keyed_edges,
                      .edges_len = 2,
                      .out_edge_keys = edge_keys,
                      .out_edge_keys_capacity = 2,
                  }),
                  ZOVA_OK,
                  "keyed edge put many");
    if (edge_keys[0] <= 0 || edge_keys[0] != edge_keys[1]) {
        fprintf(stderr, "keyed duplicate edge did not return one stable key\n");
        exit(1);
    }
    int64_t untouched_edge_keys[] = {-7, -8};
    expect_status(zova_graph_edge_put_many_keyed(&(zova_graph_edge_put_many_keyed_request){
                      .db = db,
                      .edges = keyed_edges,
                      .edges_len = 2,
                      .out_edge_keys = untouched_edge_keys,
                      .out_edge_keys_capacity = 1,
                  }),
                  ZOVA_INVALID_ARGUMENT,
                  "keyed edge capacity");
    if (untouched_edge_keys[0] != -7 || untouched_edge_keys[1] != -8) {
        fprintf(stderr, "keyed edge capacity changed output\n");
        exit(1);
    }

    zova_graph_keyed_neighbor_results keyed_neighbors = {0};
    expect_status(zova_graph_neighbors_keyed(&(zova_graph_neighbors_keyed_request){
                      .db = db,
                      .graph_name = "app",
                      .node_id = "keyed:z",
                      .direction = ZOVA_GRAPH_NEIGHBOR_OUTGOING,
                      .edge_type = "calls",
                      .limit = 10,
                      .out_results = &keyed_neighbors,
                  }),
                  ZOVA_OK,
                  "keyed graph neighbors");
    if (keyed_neighbors.len != 1 || keyed_neighbors.items[0].edge_key != edge_keys[0] ||
        keyed_neighbors.items[0].neighbor_node_key != node_keys[1]) {
        fprintf(stderr, "keyed graph neighbor keys are incorrect\n");
        exit(1);
    }
    zova_graph_keyed_neighbor_results_free(&keyed_neighbors);
    zova_graph_keyed_neighbor_results_free(&keyed_neighbors);

    const int64_t read_node_keys[] = {node_keys[1], node_keys[0], node_keys[1], INT64_MAX};
    zova_graph_keyed_node_results keyed_node_rows = {0};
    expect_status(zova_graph_nodes_get_many_keyed(&(zova_graph_nodes_get_many_keyed_request){
                      .db = db, .graph_name = "app", .node_keys = read_node_keys,
                      .key_count = 4, .out_results = &keyed_node_rows}),
                  ZOVA_OK, "keyed node get many");
    if (keyed_node_rows.len != 4 || !keyed_node_rows.items[0].found ||
        keyed_node_rows.items[0].node_key != node_keys[1] ||
        keyed_node_rows.items[2].node_key != node_keys[1] || keyed_node_rows.items[3].found) {
        fprintf(stderr, "keyed node batch read alignment is incorrect\n");
        exit(1);
    }
    zova_graph_keyed_node_results_free(&keyed_node_rows);
    zova_graph_keyed_node_results_free(&keyed_node_rows);

    const int64_t read_edge_keys[] = {edge_keys[0], edge_keys[0], INT64_MAX};
    zova_graph_keyed_edge_results keyed_edge_rows = {0};
    expect_status(zova_graph_edges_get_many_keyed(&(zova_graph_edges_get_many_keyed_request){
                      .db = db, .graph_name = "app", .edge_keys = read_edge_keys,
                      .key_count = 3, .out_results = &keyed_edge_rows}),
                  ZOVA_OK, "keyed edge get many");
    if (keyed_edge_rows.len != 3 || !keyed_edge_rows.items[0].found ||
        keyed_edge_rows.items[0].edge_key != edge_keys[0] ||
        keyed_edge_rows.items[1].edge_key != edge_keys[0] || keyed_edge_rows.items[2].found) {
        fprintf(stderr, "keyed edge batch read alignment is incorrect\n");
        exit(1);
    }
    zova_graph_keyed_edge_results_free(&keyed_edge_rows);
    zova_graph_keyed_edge_results_free(&keyed_edge_rows);

    const int64_t degree_keys[] = {node_keys[0], node_keys[1], node_keys[0]};
    uint64_t keyed_degrees[] = {99, 99, 99};
    expect_status(zova_graph_degree_many_keyed(&(zova_graph_degree_many_keyed_request){
                      .db = db,
                      .graph_name = "app",
                      .node_keys = degree_keys,
                      .node_count = 3,
                      .direction = ZOVA_GRAPH_NEIGHBOR_OUTGOING,
                      .edge_type = "calls",
                      .out_degrees = keyed_degrees,
                      .out_degrees_capacity = 3,
                  }),
                  ZOVA_OK,
                  "keyed graph degree many");
    if (keyed_degrees[0] != 1 || keyed_degrees[1] != 0 || keyed_degrees[2] != 1) {
        fprintf(stderr, "keyed graph degrees are incorrect\n");
        exit(1);
    }
    const int64_t missing_degree_key = INT64_MAX;
    uint64_t untouched_degree = 1234;
    expect_status(zova_graph_degree_many_keyed(&(zova_graph_degree_many_keyed_request){
                      .db = db,
                      .graph_name = "app",
                      .node_keys = &missing_degree_key,
                      .node_count = 1,
                      .direction = ZOVA_GRAPH_NEIGHBOR_OUTGOING,
                      .out_degrees = &untouched_degree,
                      .out_degrees_capacity = 1,
                  }),
                  ZOVA_GRAPH_NODE_NOT_FOUND,
                  "keyed graph degree missing key");
    if (untouched_degree != 1234) {
        fprintf(stderr, "failed keyed degree changed caller output\n");
        exit(1);
    }

    zova_graph_scan_results scan = {0};
    expect_status(zova_graph_scan(&(zova_graph_scan_request){
                      .db = db,
                      .graph_name = "app",
                      .node_after = {0, 0},
                      .edge_after = {0, 0},
                      .node_limit = 1,
                      .edge_limit = 1,
                      .out_results = &scan,
                  }),
                  ZOVA_OK,
                  "keyed graph scan");
    if (scan.nodes_len != 1 || scan.edges_len != 1 || !scan.has_more_nodes || !scan.has_more_edges ||
        scan.nodes[0].node_key <= 0 || scan.edges[0].edge_key <= 0) {
        fprintf(stderr, "keyed graph scan page is incorrect\n");
        exit(1);
    }
    zova_graph_scan_results_free(&scan);
    zova_graph_scan_results_free(&scan);
    expect_status(zova_graph_scan(&(zova_graph_scan_request){
                      .db = db,
                      .graph_name = "app",
                      .node_after = {1, 0},
                      .edge_after = {0, 0},
                      .node_limit = 1,
                      .out_results = &scan,
                  }),
                  ZOVA_INVALID_ARGUMENT,
                  "keyed graph scan malformed cursor");
    if (scan.nodes != NULL || scan.nodes_len != 0 || scan.edges != NULL || scan.edges_len != 0) {
        fprintf(stderr, "failed keyed scan did not retain empty output\n");
        exit(1);
    }

    expect_status(zova_database_begin(&(zova_database_simple_request){.db = db}), ZOVA_OK, "keyed begin caller transaction");
    const zova_graph_node_input rollback_node = {
        .graph_name = "app", .node_id = "keyed:rollback", .kind = "temporary", .target_type = ZOVA_GRAPH_TARGET_NONE};
    int64_t rollback_key = 0;
    expect_status(zova_graph_node_put_many_keyed(&(zova_graph_node_put_many_keyed_request){
                      .db = db,
                      .nodes = &rollback_node,
                      .nodes_len = 1,
                      .out_node_keys = &rollback_key,
                      .out_node_keys_capacity = 1,
                  }),
                  ZOVA_OK,
                  "keyed put in caller transaction");
    expect_status(zova_database_rollback(&(zova_database_simple_request){.db = db}), ZOVA_OK, "keyed caller rollback");
    uint8_t rollback_exists = 1;
    expect_status(zova_graph_node_exists(&(zova_graph_node_exists_request){
                      .db = db, .graph_name = "app", .node_id = "keyed:rollback", .out_exists = &rollback_exists}),
                  ZOVA_OK,
                  "keyed rollback exists");
    if (rollback_exists) {
        fprintf(stderr, "keyed caller rollback retained node\n");
        exit(1);
    }
    uint64_t degree = 0;
    expect_status(zova_graph_degree(&(zova_graph_degree_request){
                      .db = db,
                      .graph_name = "app",
                      .node_id = "batch:1",
                      .direction = ZOVA_GRAPH_NEIGHBOR_OUTGOING,
                      .edge_type = "calls",
                      .out_degree = &degree,
                  }),
                  ZOVA_OK,
                  "graph degree");
    if (degree != 1) {
        fprintf(stderr, "graph degree: unexpected count\n");
        exit(1);
    }
    const char *batch_delete_ids[] = {"batch:2", "missing"};
    expect_status(zova_graph_node_delete_many(&(zova_graph_node_delete_many_request){
                      .db = db,
                      .graph_name = "app",
                      .node_ids = batch_delete_ids,
                      .node_count = sizeof(batch_delete_ids) / sizeof(batch_delete_ids[0]),
                  }),
                  ZOVA_OK,
                  "graph node batch delete");

    zova_graph_neighbor_results neighbors = {0};
    expect_status(zova_graph_neighbors(&(zova_graph_neighbors_request){
                      .db = db,
                      .graph_name = "app",
                      .node_id = "message:1",
                      .direction = ZOVA_GRAPH_NEIGHBOR_OUTGOING,
                      .edge_type = NULL,
                      .limit = 10,
                      .out_results = &neighbors,
                  }),
                  ZOVA_OK,
                  "graph neighbors");
    if (neighbors.len != 2) {
        fprintf(stderr, "graph neighbors: unexpected count\n");
        exit(1);
    }
    zova_graph_neighbor_results_free(&neighbors);

    zova_graph_walk_results walk = {0};
    expect_status(zova_graph_walk(&(zova_graph_walk_request){
                      .db = db,
                      .graph_name = "app",
                      .start_node_id = "message:1",
                      .edge_type = NULL,
                      .max_depth = 1,
                      .limit = 10,
                      .out_results = &walk,
                  }),
                  ZOVA_OK,
                  "graph walk");
    if (walk.len != 3 || walk.items[0].depth != 0 || walk.items[1].depth != 1 ||
        !walk.items[1].has_predecessor_node_id) {
        fprintf(stderr, "graph walk: unexpected result shape\n");
        exit(1);
    }
    zova_graph_walk_results_free(&walk);

    expect_status(zova_graph_walk_direction(&(zova_graph_walk_direction_request){
                      .db = db,
                      .graph_name = "app",
                      .start_node_id = "message:1",
                      .direction = ZOVA_GRAPH_NEIGHBOR_OUTGOING,
                      .edge_type = "replies_to",
                      .max_depth = 1,
                      .limit = 10,
                      .out_results = &walk,
                  }),
                  ZOVA_OK,
                  "directional outgoing graph walk");
    if (walk.len != 2 || walk.items[0].depth != 0 || walk.items[1].depth != 1) {
        fprintf(stderr, "directional outgoing graph walk: unexpected result shape\n");
        exit(1);
    }
    zova_graph_walk_results_free(&walk);

    expect_status(zova_graph_walk_direction(&(zova_graph_walk_direction_request){
                      .db = db,
                      .graph_name = "app",
                      .start_node_id = "message:2",
                      .direction = ZOVA_GRAPH_NEIGHBOR_INCOMING,
                      .edge_type = "replies_to",
                      .max_depth = 1,
                      .limit = 10,
                      .out_results = &walk,
                  }),
                  ZOVA_OK,
                  "directional incoming graph walk");
    if (walk.len != 2 || walk.items[0].depth != 0 || walk.items[1].depth != 1 ||
        walk.items[1].node_id_len != strlen("message:1") ||
        memcmp(walk.items[1].node_id, "message:1", walk.items[1].node_id_len) != 0) {
        fprintf(stderr, "directional incoming graph walk: unexpected result shape\n");
        exit(1);
    }
    zova_graph_walk_results_free(&walk);

    zova_graph_walk_profile walk_profile = {0};
    expect_status(zova_graph_walk_direction_profiled(
                      &(zova_graph_walk_direction_profiled_request){
                          .db = db,
                          .graph_name = "app",
                          .start_node_id = "message:1",
                          .direction = ZOVA_GRAPH_NEIGHBOR_OUTGOING,
                          .edge_type = "replies_to",
                          .max_depth = 1,
                          .limit = 10,
                          .out_results = &walk,
                          .out_profile = &walk_profile,
                      }),
                  ZOVA_OK,
                  "profiled directional outgoing graph walk");
    if (walk.len != 2 || walk_profile.frontier_expansions != 1 ||
        walk_profile.adjacency_query_binds != 1 || walk_profile.adjacency_rows_stepped != 1 ||
        walk_profile.result_count != 2 || walk_profile.mutex_wait_ms < 0 ||
        walk_profile.root_lookup_ms < 0 || walk_profile.adjacency_prepare_ms < 0 ||
        walk_profile.adjacency_execute_ms < 0 ||
        walk_profile.bfs_bookkeeping_allocation_ms < 0 ||
        walk_profile.c_abi_result_export_ms < 0 ||
        walk_profile.total_profiled_ms < walk_profile.mutex_wait_ms + walk_profile.root_lookup_ms +
                                             walk_profile.adjacency_prepare_ms +
                                             walk_profile.adjacency_execute_ms +
                                             walk_profile.bfs_bookkeeping_allocation_ms +
                                             walk_profile.c_abi_result_export_ms) {
        fprintf(stderr, "profiled directional graph walk: unexpected profile\n");
        exit(1);
    }
    zova_graph_walk_results_free(&walk);

    zova_statement *sql_graph_neighbors = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select node_id, edge_type from zova_graph_neighbors where graph_name = 'app' and source_node_id = 'message:1' and \"limit\" = 1 order by rank",
                      .out_statement = &sql_graph_neighbors,
                  }),
                  ZOVA_OK,
                  "prepare sql graph neighbors");
    zova_step_result step_result = 0;
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = sql_graph_neighbors,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "step sql graph neighbors");
    if (step_result != ZOVA_STEP_ROW) {
        fprintf(stderr, "step sql graph neighbors: expected row\n");
        exit(1);
    }
    zova_text sql_graph_node = {0};
    expect_status(zova_statement_column_text(&(zova_statement_column_text_request){
                      .statement = sql_graph_neighbors,
                      .index = 0,
                      .out_text = &sql_graph_node,
                  }),
                  ZOVA_OK,
                  "read sql graph neighbor node");
    expect_graph_text(sql_graph_node.data, sql_graph_node.len, "message:2", "sql graph neighbor node");
    zova_text_free(&sql_graph_node);
    expect_status(zova_statement_finalize(sql_graph_neighbors), ZOVA_OK, "finalize sql graph neighbors");

    zova_statement *sql_graph_walk = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select node_id, depth from zova_graph_walk where graph_name = 'app' and start_node_id = 'message:1' and max_depth = 1 and \"limit\" = 2 order by rank",
                      .out_statement = &sql_graph_walk,
                  }),
                  ZOVA_OK,
                  "prepare sql graph walk");
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = sql_graph_walk,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "step sql graph walk");
    if (step_result != ZOVA_STEP_ROW) {
        fprintf(stderr, "step sql graph walk: expected row\n");
        exit(1);
    }
    expect_status(zova_statement_column_text(&(zova_statement_column_text_request){
                      .statement = sql_graph_walk,
                      .index = 0,
                      .out_text = &sql_graph_node,
                  }),
                  ZOVA_OK,
                  "read sql graph walk node");
    expect_graph_text(sql_graph_node.data, sql_graph_node.len, "message:1", "sql graph walk node");
    zova_text_free(&sql_graph_node);
    expect_status(zova_statement_finalize(sql_graph_walk), ZOVA_OK, "finalize sql graph walk");

    expect_status(zova_graph_node_delete(&(zova_graph_node_delete_request){
                      .db = db,
                      .graph_name = "app",
                      .node_id = "message:2",
                  }),
                  ZOVA_OK,
                  "graph node delete");
    expect_status(zova_graph_edge_get(&(zova_graph_edge_get_request){
                      .db = db,
                      .graph_name = "app",
                      .from_node_id = "message:1",
                      .edge_type = "replies_to",
                      .to_node_id = "message:2",
                      .out_edge = &edge,
                  }),
                  ZOVA_GRAPH_EDGE_NOT_FOUND,
                  "graph edge removed with node");
}

static void run_extension_smoke(zova_database *db) {
    expect_status(zova_database_extension_install(&(zova_database_extension_request){
                      .db = db,
                      .name = "missing_ext",
                  }),
                  ZOVA_EXTENSION_NOT_FOUND,
                  "extension install missing");
    expect_status(zova_database_extension_install(&(zova_database_extension_request){
                      .db = db,
                      .name = "trgm",
                  }),
                  ZOVA_OK,
                  "extension install trgm");
    expect_status(zova_database_extension_install(&(zova_database_extension_request){
                      .db = db,
                      .name = "trgm",
                  }),
                  ZOVA_EXTENSION_EXISTS,
                  "extension duplicate install");

    zova_extension_info info = {0};
    expect_status(zova_database_extension_info(&(zova_database_extension_info_request){
                      .db = db,
                      .name = "trgm",
                      .out_info = &info,
                  }),
                  ZOVA_OK,
                  "extension info trgm");
    expect_graph_text(info.name, info.name_len, "trgm", "extension info name");
    expect_graph_text(info.storage_prefix, info.storage_prefix_len, "_zova_ext_trgm_", "extension info prefix");
    if (!info.required) {
        fprintf(stderr, "extension info: expected required\n");
        exit(1);
    }
    zova_extension_info_free(&info);

    zova_extension_list list = {0};
    expect_status(zova_database_extension_list(&(zova_database_extension_list_request){
                      .db = db,
                      .out_list = &list,
                  }),
                  ZOVA_OK,
                  "extension list");
    if (list.len != 1) {
        fprintf(stderr, "extension list: unexpected count\n");
        exit(1);
    }
    zova_extension_list_free(&list);

    expect_status(zova_database_extension_check(&(zova_database_extension_request){
                      .db = db,
                      .name = "trgm",
                  }),
                  ZOVA_OK,
                  "extension check trgm");
    expect_status(zova_database_extension_check_all(&(zova_database_simple_request){.db = db}),
                  ZOVA_OK,
                  "extension check all");
    expect_status(zova_database_extension_drop(&(zova_database_extension_request){
                      .db = db,
                      .name = "trgm",
                  }),
                  ZOVA_OK,
                  "extension drop trgm");
    expect_status(zova_database_extension_info(&(zova_database_extension_info_request){
                      .db = db,
                      .name = "trgm",
                      .out_info = &info,
                  }),
                  ZOVA_EXTENSION_NOT_FOUND,
                  "extension info dropped");
    zova_extension_info_free(NULL);
    zova_extension_list_free(NULL);
}

static void verify_operational_copy(const char *path, zova_object_id object_id, const char *label) {
    zova_database *copy = NULL;
    zova_message message = {0};
    expect_status(zova_database_open(&(zova_database_open_request){
                      .path = path,
                      .out_db = &copy,
                      .out_error_message = &message,
                  }),
                  ZOVA_OK,
                  label);
    zova_message_free(&message);

    zova_statement *stmt = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = copy,
                      .sql = "select count(*) from notes where body = 'committed note'",
                      .out_statement = &stmt,
                  }),
                  ZOVA_OK,
                  "copy prepare notes");
    zova_step_result step = ZOVA_STEP_DONE;
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = stmt,
                      .out_result = &step,
                  }),
                  ZOVA_OK,
                  "copy step notes");
    int64_t count = 0;
    expect_status(zova_statement_column_int64(&(zova_statement_column_int64_request){
                      .statement = stmt,
                      .index = 0,
                      .out_value = &count,
                  }),
                  ZOVA_OK,
                  "copy read notes");
    if (count != 1) {
        fprintf(stderr, "%s: unexpected notes count\n", label);
        exit(1);
    }
    expect_status(zova_statement_finalize(stmt), ZOVA_OK, "copy finalize notes");

    uint8_t exists = 0;
    expect_status(zova_object_exists(&(zova_object_exists_request){
                      .db = copy,
                      .id = object_id,
                      .out_exists = &exists,
                  }),
                  ZOVA_OK,
                  "copy object exists");
    if (!exists) {
        fprintf(stderr, "%s: object missing\n", label);
        exit(1);
    }

    exists = 0;
    expect_status(zova_vector_exists(&(zova_vector_exists_request){
                      .db = copy,
                      .collection_name = "cosine",
                      .vector_id = "east",
                      .out_exists = &exists,
                  }),
                  ZOVA_OK,
                  "copy vector exists");
    if (!exists) {
        fprintf(stderr, "%s: vector missing\n", label);
        exit(1);
    }

    expect_status(zova_database_close(copy), ZOVA_OK, "copy close");
}

typedef struct threaded_sql_context {
    zova_database *db;
    int worker_index;
    zova_status status;
} threaded_sql_context;

static void *threaded_sql_worker(void *arg) {
    threaded_sql_context *ctx = (threaded_sql_context *)arg;
    char sql[160];
    for (int i = 0; i < 12; i += 1) {
        snprintf(sql, sizeof(sql), "insert into threaded_records(worker, item) values (%d, %d)", ctx->worker_index, i);
        ctx->status = zova_database_exec(&(zova_database_exec_request){
            .db = ctx->db,
            .sql = sql,
        });
        if (ctx->status != ZOVA_OK) {
            return NULL;
        }
    }
    return NULL;
}

typedef struct threaded_mixed_context {
    zova_database *db;
    int worker_index;
    zova_object_id object_id;
    zova_status status;
} threaded_mixed_context;

static void *threaded_mixed_worker(void *arg) {
    threaded_mixed_context *ctx = (threaded_mixed_context *)arg;
    if ((ctx->worker_index % 2) == 0) {
        const uint8_t bytes[] = "threaded object bytes";
        ctx->status = zova_object_put(&(zova_object_put_request){
            .db = ctx->db,
            .data = bytes,
            .len = sizeof(bytes) - 1,
            .out_id = &ctx->object_id,
        });
        return NULL;
    }

    char vector_id[32];
    snprintf(vector_id, sizeof(vector_id), "thread-v-%d", ctx->worker_index);
    float values[] = {(float)ctx->worker_index, 1.0f};
    ctx->status = zova_vector_put(&(zova_vector_put_request){
        .db = ctx->db,
        .collection_name = "threaded_vectors",
        .vector_id = vector_id,
        .values = f32_values(values, 2),
    });
    return NULL;
}

static void run_threaded_same_handle_smoke(zova_database *db) {
    expect_status(zova_database_exec(&(zova_database_exec_request){
                      .db = db,
                      .sql = "create table threaded_records(worker integer not null, item integer not null)",
                  }),
                  ZOVA_OK,
                  "threaded create records");

    pthread_t sql_threads[4];
    threaded_sql_context sql_contexts[4];
    for (size_t i = 0; i < sizeof(sql_threads) / sizeof(sql_threads[0]); i += 1) {
        sql_contexts[i] = (threaded_sql_context){.db = db, .worker_index = (int)i, .status = ZOVA_OK};
        if (pthread_create(&sql_threads[i], NULL, threaded_sql_worker, &sql_contexts[i]) != 0) {
            fprintf(stderr, "threaded sql: pthread_create failed\n");
            exit(1);
        }
    }
    for (size_t i = 0; i < sizeof(sql_threads) / sizeof(sql_threads[0]); i += 1) {
        pthread_join(sql_threads[i], NULL);
        expect_status(sql_contexts[i].status, ZOVA_OK, "threaded sql worker");
    }

    zova_statement *count_stmt = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select count(*) from threaded_records",
                      .out_statement = &count_stmt,
                  }),
                  ZOVA_OK,
                  "threaded count prepare");
    zova_step_result step_result = ZOVA_STEP_DONE;
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = count_stmt,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "threaded count step");
    int64_t count = 0;
    expect_status(zova_statement_column_int64(&(zova_statement_column_int64_request){
                      .statement = count_stmt,
                      .index = 0,
                      .out_value = &count,
                  }),
                  ZOVA_OK,
                  "threaded count read");
    if (count != 48) {
        fprintf(stderr, "threaded count: unexpected count\n");
        exit(1);
    }
    expect_status(zova_statement_finalize(count_stmt), ZOVA_OK, "threaded count finalize");

    expect_status(zova_vector_collection_create(&(zova_vector_collection_create_request){
                      .db = db,
                      .name = "threaded_vectors",
                      .options = {.dimensions = 2, .metric = ZOVA_VECTOR_METRIC_L2, .element_type = ZOVA_VECTOR_ELEMENT_TYPE_F32},
                  }),
                  ZOVA_OK,
                  "threaded create vectors");
    pthread_t mixed_threads[6];
    threaded_mixed_context mixed_contexts[6];
    for (size_t i = 0; i < sizeof(mixed_threads) / sizeof(mixed_threads[0]); i += 1) {
        mixed_contexts[i] = (threaded_mixed_context){.db = db, .worker_index = (int)i, .status = ZOVA_OK};
        if (pthread_create(&mixed_threads[i], NULL, threaded_mixed_worker, &mixed_contexts[i]) != 0) {
            fprintf(stderr, "threaded mixed: pthread_create failed\n");
            exit(1);
        }
    }
    for (size_t i = 0; i < sizeof(mixed_threads) / sizeof(mixed_threads[0]); i += 1) {
        pthread_join(mixed_threads[i], NULL);
        expect_status(mixed_contexts[i].status, ZOVA_OK, "threaded mixed worker");
    }
    for (size_t i = 0; i < sizeof(mixed_contexts) / sizeof(mixed_contexts[0]); i += 2) {
        uint8_t exists = 0;
        expect_status(zova_object_exists(&(zova_object_exists_request){
                          .db = db,
                          .id = mixed_contexts[i].object_id,
                          .out_exists = &exists,
                      }),
                      ZOVA_OK,
                      "threaded object exists");
        if (!exists) {
            fprintf(stderr, "threaded object exists: expected true\n");
            exit(1);
        }
    }
    zova_vector_collection_info info = {0};
    expect_status(zova_vector_collection_info_get(&(zova_vector_collection_info_get_request){
                      .db = db,
                      .name = "threaded_vectors",
                      .out_info = &info,
                  }),
                  ZOVA_OK,
                  "threaded vector info");
    if (info.vector_count != 3) {
        fprintf(stderr, "threaded vector info: unexpected count\n");
        exit(1);
    }
    zova_vector_collection_info_free(&info);
}

static void run_notification_smoke(zova_database *db) {
    zova_subscription *subscription = NULL;
    expect_status(zova_database_listen(&(zova_database_listen_request){
                      .db = db,
                      .channel = "message:1:attachments",
                      .out_subscription = &subscription,
                  }),
                  ZOVA_OK,
                  "listen notification");
    expect_status(zova_database_close(db), ZOVA_MISUSE, "close with live subscription");

    const uint8_t payload[] = "changed";
    expect_status(zova_database_begin_immediate(&(zova_database_simple_request){.db = db}), ZOVA_OK, "notify begin immediate");
    expect_status(zova_database_notify(&(zova_database_notify_request){
                      .db = db,
                      .channel = "message:1:attachments",
                      .payload = payload,
                      .payload_len = sizeof(payload) - 1,
                  }),
                  ZOVA_OK,
                  "notify in transaction");

    zova_notification notification = {0};
    uint8_t has_notification = 1;
    expect_status(zova_subscription_try_receive(&(zova_subscription_try_receive_request){
                      .subscription = subscription,
                      .out_notification = &notification,
                      .out_has_notification = &has_notification,
                  }),
                  ZOVA_OK,
                  "receive before commit");
    if (has_notification != 0) {
        fprintf(stderr, "receive before commit: expected empty queue\n");
        exit(1);
    }

    expect_status(zova_database_commit(&(zova_database_simple_request){.db = db}), ZOVA_OK, "notify commit");
    expect_status(zova_subscription_try_receive(&(zova_subscription_try_receive_request){
                      .subscription = subscription,
                      .out_notification = &notification,
                      .out_has_notification = &has_notification,
                  }),
                  ZOVA_OK,
                  "receive after commit");
    if (has_notification != 1 || notification.payload_len != sizeof(payload) - 1 ||
        memcmp(notification.payload, payload, sizeof(payload) - 1) != 0) {
        fprintf(stderr, "receive after commit: unexpected notification\n");
        exit(1);
    }
    zova_notification_free(&notification);

    zova_statement *notify_stmt = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select zova_notify('message:1:attachments', 'from-sql')",
                      .out_statement = &notify_stmt,
                  }),
                  ZOVA_OK,
                  "prepare sql notify");
    zova_step_result step = ZOVA_STEP_DONE;
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = notify_stmt,
                      .out_result = &step,
                  }),
                  ZOVA_OK,
                  "step sql notify");
    expect_status(zova_statement_finalize(notify_stmt), ZOVA_OK, "finalize sql notify");

    expect_status(zova_subscription_try_receive(&(zova_subscription_try_receive_request){
                      .subscription = subscription,
                      .out_notification = &notification,
                      .out_has_notification = &has_notification,
                  }),
                  ZOVA_OK,
                  "receive sql notify");
    if (has_notification != 1 || notification.payload_len != strlen("from-sql") ||
        memcmp(notification.payload, "from-sql", strlen("from-sql")) != 0) {
        fprintf(stderr, "receive sql notify: unexpected notification\n");
        exit(1);
    }
    zova_notification_free(&notification);

    expect_status(zova_subscription_close(subscription), ZOVA_OK, "close subscription");
}

static void expect_dyn_test_value(zova_database *db, const char *label) {
    zova_statement *stmt = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select zova_dyn_test_value()",
                      .out_statement = &stmt,
                  }),
                  ZOVA_OK,
                  label);
    zova_step_result step = ZOVA_STEP_DONE;
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = stmt,
                      .out_result = &step,
                  }),
                  ZOVA_OK,
                  "dynamic extension sql step");
    if (step != ZOVA_STEP_ROW) {
        fprintf(stderr, "dynamic extension sql: expected row\n");
        exit(1);
    }
    int64_t value = 0;
    expect_status(zova_statement_column_int64(&(zova_statement_column_int64_request){
                      .statement = stmt,
                      .index = 0,
                      .out_value = &value,
                  }),
                  ZOVA_OK,
                  "dynamic extension sql value");
    if (value != 21) {
        fprintf(stderr, "dynamic extension sql: unexpected value\n");
        exit(1);
    }
    expect_status(zova_statement_finalize(stmt), ZOVA_OK, "dynamic extension sql finalize");
}

static void expect_dynamic_vector_sql_helper(zova_database *db) {
    float query_vector_blob[] = {1.0f, 2.0f};
    zova_statement *stmt = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select vector_id from zova_vector_search where collection = 'dynamic_vectors' and query_vector = ? and top_k = 1",
                      .out_statement = &stmt,
                  }),
                  ZOVA_OK,
                  "prepare dynamic vector sql search");
    expect_status(zova_statement_bind_blob(&(zova_statement_bind_blob_request){
                      .statement = stmt,
                      .index = 1,
                      .data = (const uint8_t *)query_vector_blob,
                      .len = sizeof(query_vector_blob),
                  }),
                  ZOVA_OK,
                  "bind dynamic vector sql search query");
    zova_step_result step = ZOVA_STEP_DONE;
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = stmt,
                      .out_result = &step,
                  }),
                  ZOVA_OK,
                  "step dynamic vector sql search");
    if (step != ZOVA_STEP_ROW) {
        fprintf(stderr, "dynamic vector sql search: expected row\n");
        exit(1);
    }
    zova_text vector_id = {0};
    expect_status(zova_statement_column_text(&(zova_statement_column_text_request){
                      .statement = stmt,
                      .index = 0,
                      .out_text = &vector_id,
                  }),
                  ZOVA_OK,
                  "read dynamic vector sql search id");
    expect_graph_text(vector_id.data, vector_id.len, "v1", "dynamic vector sql search id");
    zova_text_free(&vector_id);
    expect_status(zova_statement_finalize(stmt), ZOVA_OK, "finalize dynamic vector sql search");
}

static void expect_dynamic_sql_coexistence(zova_database *db) {
    expect_status(zova_database_exec(&(zova_database_exec_request){
                      .db = db,
                      .sql = "create table dynamic_candidates (vector_id text primary key, keep integer not null)",
                  }),
                  ZOVA_OK,
                  "create dynamic vector candidates");
    expect_status(zova_database_exec(&(zova_database_exec_request){
                      .db = db,
                      .sql = "insert into dynamic_candidates (vector_id, keep) values ('v1', 1)",
                  }),
                  ZOVA_OK,
                  "insert dynamic vector candidates");

    float query_vector_blob[] = {1.0f, 2.0f};
    zova_statement *prefilter = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select s.vector_id "
                             "from dynamic_candidates c "
                             "join zova_vector_search s on s.vector_id = c.vector_id "
                             "where s.collection = 'dynamic_vectors' "
                             "and s.query_vector = ? "
                             "and s.top_k = 1 "
                             "and c.keep = 1 "
                             "and app_c_mix(4, 'cat', x'0102') = 99",
                      .out_statement = &prefilter,
                  }),
                  ZOVA_OK,
                  "prepare dynamic vector sql prefilter");
    expect_status(zova_statement_bind_blob(&(zova_statement_bind_blob_request){
                      .statement = prefilter,
                      .index = 1,
                      .data = (const uint8_t *)query_vector_blob,
                      .len = sizeof(query_vector_blob),
                  }),
                  ZOVA_OK,
                  "bind dynamic vector sql prefilter");
    zova_step_result step = ZOVA_STEP_DONE;
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = prefilter,
                      .out_result = &step,
                  }),
                  ZOVA_OK,
                  "step dynamic vector sql prefilter");
    if (step != ZOVA_STEP_ROW) {
        fprintf(stderr, "dynamic vector sql prefilter: expected row\n");
        exit(1);
    }
    zova_text vector_id = {0};
    expect_status(zova_statement_column_text(&(zova_statement_column_text_request){
                      .statement = prefilter,
                      .index = 0,
                      .out_text = &vector_id,
                  }),
                  ZOVA_OK,
                  "read dynamic vector sql prefilter id");
    expect_graph_text(vector_id.data, vector_id.len, "v1", "dynamic vector sql prefilter id");
    zova_text_free(&vector_id);
    expect_status(zova_statement_finalize(prefilter), ZOVA_OK, "finalize dynamic vector sql prefilter");

    expect_status(zova_database_exec(&(zova_database_exec_request){
                      .db = db,
                      .sql = "create virtual table dynamic_docs using fts5(body)",
                  }),
                  ZOVA_OK,
                  "create dynamic fts table");
    expect_status(zova_database_exec(&(zova_database_exec_request){
                      .db = db,
                      .sql = "insert into dynamic_docs (body) values ('alpha beta')",
                  }),
                  ZOVA_OK,
                  "insert dynamic fts row");

    zova_statement *fts = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select app_c_text(), zova_dyn_test_value(), rowid from dynamic_docs where dynamic_docs match 'alpha'",
                      .out_statement = &fts,
                  }),
                  ZOVA_OK,
                  "prepare dynamic fts coexistence");
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = fts,
                      .out_result = &step,
                  }),
                  ZOVA_OK,
                  "step dynamic fts coexistence");
    if (step != ZOVA_STEP_ROW) {
        fprintf(stderr, "dynamic fts coexistence: expected row\n");
        exit(1);
    }
    zova_text text = {0};
    expect_status(zova_statement_column_text(&(zova_statement_column_text_request){
                      .statement = fts,
                      .index = 0,
                      .out_text = &text,
                  }),
                  ZOVA_OK,
                  "read dynamic fts c function text");
    expect_graph_text(text.data, text.len, "from-c", "dynamic fts c function text");
    zova_text_free(&text);
    int64_t extension_value = 0;
    expect_status(zova_statement_column_int64(&(zova_statement_column_int64_request){
                      .statement = fts,
                      .index = 1,
                      .out_value = &extension_value,
                  }),
                  ZOVA_OK,
                  "read dynamic fts extension value");
    if (extension_value != 21) {
        fprintf(stderr, "dynamic fts extension value: unexpected value\n");
        exit(1);
    }
    int64_t rowid = 0;
    expect_status(zova_statement_column_int64(&(zova_statement_column_int64_request){
                      .statement = fts,
                      .index = 2,
                      .out_value = &rowid,
                  }),
                  ZOVA_OK,
                  "read dynamic fts rowid");
    if (rowid != 1) {
        fprintf(stderr, "dynamic fts rowid: unexpected rowid\n");
        exit(1);
    }
    expect_status(zova_statement_finalize(fts), ZOVA_OK, "finalize dynamic fts coexistence");
}

static void run_dynamic_extension_bundle_smoke(
    const char *base_db_path,
    const char *library_path,
    const char *bundle_path,
    const char *trust_path
) {
    char ext_db_path[1024];
    snprintf(ext_db_path, sizeof(ext_db_path), "%s.dynamic.zova", base_db_path);
    remove(ext_db_path);
    remove(trust_path);
    make_dyn_test_bundle(library_path, bundle_path);

    zova_message message = {0};
    expect_status(zova_extension_bundle_verify(&(zova_extension_bundle_request){
                      .bundle_path = bundle_path,
                      .trust_store_path = trust_path,
                      .out_error_message = &message,
                  }),
                  ZOVA_OK,
                  "verify dynamic bundle");
    zova_message_free(&message);

    const char *bundle_paths[1] = {bundle_path};
    zova_database *db = NULL;
    zova_status untrusted = zova_database_create_with_extensions(&(zova_database_open_extensions_request){
        .path = ext_db_path,
        .flags = 0,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = bundle_paths,
        .extension_bundle_count = 1,
        .trust_store_path = trust_path,
        .out_db = &db,
        .out_error_message = &message,
    });
    if (untrusted != ZOVA_EXTENSION_UNAVAILABLE) {
        fprintf(stderr,
                "create with untrusted extension: expected %s, got %s\n",
                zova_status_name(ZOVA_EXTENSION_UNAVAILABLE),
                zova_status_name(untrusted));
        exit(1);
    }
    expect_message_contains(&message, "ExtensionUntrusted", "create with untrusted extension");
    zova_message_free(&message);

    expect_status(zova_extension_bundle_trust(&(zova_extension_bundle_request){
                      .bundle_path = bundle_path,
                      .trust_store_path = trust_path,
                      .out_error_message = &message,
                  }),
                  ZOVA_OK,
                  "trust dynamic bundle");
    zova_message_free(&message);

    expect_status(zova_database_create_with_extensions(&(zova_database_open_extensions_request){
                      .path = ext_db_path,
                      .flags = 0,
                      .busy_timeout_ms = 0,
                      .extension_bundle_paths = bundle_paths,
                      .extension_bundle_count = 1,
                      .trust_store_path = trust_path,
                      .out_db = &db,
                      .out_error_message = &message,
                  }),
                  ZOVA_OK,
                  "create with trusted dynamic bundle");
    zova_message_free(&message);

    expect_status(zova_database_extension_install(&(zova_database_extension_request){
                      .db = db,
                      .name = "dyn_test",
                  }),
                  ZOVA_OK,
                  "install dynamic extension");
    expect_status(zova_database_extension_check(&(zova_database_extension_request){
                      .db = db,
                      .name = "dyn_test",
                  }),
                  ZOVA_OK,
                  "check dynamic extension");
    expect_dyn_test_value(db, "prepare dynamic extension sql after install");

    sql_callback_state state = {0};
    run_sql_function_smoke(db, &state);
    if (state.destroyed) {
        fprintf(stderr, "dynamic extension c callback destructor ran too early\n");
        exit(1);
    }

    expect_status(zova_vector_collection_create(&(zova_vector_collection_create_request){
                      .db = db,
                      .name = "dynamic_vectors",
                      .options = {.dimensions = 2, .metric = ZOVA_VECTOR_METRIC_L2, .element_type = ZOVA_VECTOR_ELEMENT_TYPE_F32},
                  }),
                  ZOVA_OK,
                  "dynamic vector collection");
    float vector_values[] = {1.0f, 2.0f};
    expect_status(zova_vector_put(&(zova_vector_put_request){
                      .db = db,
                      .collection_name = "dynamic_vectors",
                      .vector_id = "v1",
                      .values = f32_values(vector_values, 2),
                  }),
                  ZOVA_OK,
                  "dynamic vector put");
    expect_dynamic_vector_sql_helper(db);
    expect_dynamic_sql_coexistence(db);
    run_graph_smoke(db);
    run_notification_smoke(db);
    expect_status(zova_database_close(db), ZOVA_OK, "close dynamic extension db");
    if (!state.destroyed) {
        fprintf(stderr, "close dynamic extension db: expected SQL callback destructor\n");
        exit(1);
    }
    db = NULL;

    expect_status(zova_database_open(&(zova_database_open_request){
                      .path = ext_db_path,
                      .out_db = &db,
                      .out_error_message = &message,
                  }),
                  ZOVA_EXTENSION_UNAVAILABLE,
                  "open installed dynamic extension without bundle code");
    expect_message_contains(&message, "ExtensionUnavailable", "open without dynamic bundle message");
    if (message.data != NULL && strstr(message.data, bundle_path) != NULL) {
        fprintf(stderr, "open without dynamic bundle leaked bundle path\n");
        exit(1);
    }
    if (message.data != NULL && strstr(message.data, "create table") != NULL) {
        fprintf(stderr, "open without dynamic bundle leaked private schema\n");
        exit(1);
    }
    zova_message_free(&message);

    expect_status(zova_database_open_with_extensions(&(zova_database_open_extensions_request){
                      .path = ext_db_path,
                      .flags = 0,
                      .busy_timeout_ms = 0,
                      .extension_bundle_paths = bundle_paths,
                      .extension_bundle_count = 1,
                      .trust_store_path = trust_path,
                      .out_db = &db,
                      .out_error_message = &message,
                  }),
                  ZOVA_OK,
                  "reopen with trusted dynamic bundle");
    zova_message_free(&message);
    expect_dyn_test_value(db, "prepare dynamic extension sql after reopen");
    expect_status(zova_database_close(db), ZOVA_OK, "close reopened dynamic extension db");

    char manifest_path[1024];
    path_join(manifest_path, sizeof(manifest_path), bundle_path, "extension.json");
    write_text_file(
        manifest_path,
        "{\n"
        "  \"name\": \"dyn_test\",\n"
        "  \"version\": \"0.1.1\",\n"
        "  \"storage_prefix\": \"_zova_ext_dyn_test_\",\n"
        "  \"zova_abi_min\": \"0.21.0\",\n"
        "  \"capabilities\": \"sql,dynamic-test\",\n"
        "  \"library\": \"libdyn_test\"\n"
        "}\n",
        "modify dynamic manifest"
    );
    zova_status mismatch = zova_database_open_with_extensions(&(zova_database_open_extensions_request){
        .path = ext_db_path,
        .flags = 0,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = bundle_paths,
        .extension_bundle_count = 1,
        .trust_store_path = trust_path,
        .out_db = &db,
        .out_error_message = &message,
    });
    if (mismatch != ZOVA_EXTENSION_UNAVAILABLE) {
        fprintf(stderr,
                "reopen with modified trusted bundle: expected %s, got %s\n",
                zova_status_name(ZOVA_EXTENSION_UNAVAILABLE),
                zova_status_name(mismatch));
        exit(1);
    }
    expect_message_contains(&message, "ExtensionUntrusted", "modified trusted bundle message");
    zova_message_free(&message);

    uint8_t removed = 0;
    expect_status(zova_extension_bundle_untrust(&(zova_extension_bundle_untrust_request){
                      .identifier = "dyn_test",
                      .trust_store_path = trust_path,
                      .out_removed = &removed,
                      .out_error_message = &message,
                  }),
                  ZOVA_OK,
                  "untrust dynamic bundle");
    if (removed != 1) {
        fprintf(stderr, "untrust dynamic bundle: expected removed\n");
        exit(1);
    }
    zova_message_free(&message);
}

static void run_probe_migrate_smoke(void) {
    // Null request validation
    expect_status(zova_database_probe_format(NULL), ZOVA_INVALID_ARGUMENT, "probe null request");
    expect_status(zova_database_migrate(NULL), ZOVA_INVALID_ARGUMENT, "migrate null request");

    // Probe: null out_info must be INVALID_ARGUMENT and not crash; out_info zeroed check
    {
        zova_message msg = {0};
        zova_database_format_info out = {.format_version = 0xDEADBEEF, .compatibility = 0x7FFFFFFF};
        expect_status(zova_database_probe_format(&(zova_database_probe_format_request){
                          .path = "/tmp/zova_probe_dummy.zova",
                          .out_info = NULL,
                          .out_error_message = &msg,
                      }),
                      ZOVA_INVALID_ARGUMENT, "probe null out_info");
        zova_message_free(&msg);
        // out remains unchanged (we didn't pass it, so not zeroed - just check no crash)
        (void)out;
    }
    // Probe: null path -> INVALID_ARGUMENT and out zeroed
    {
        zova_message msg = {0};
        zova_database_format_info out = {.format_version = 0xDEADBEEF, .compatibility = 0x7FFFFFFF};
        expect_status(zova_database_probe_format(&(zova_database_probe_format_request){
                          .path = NULL,
                          .out_info = &out,
                          .out_error_message = &msg,
                      }),
                      ZOVA_INVALID_ARGUMENT, "probe null path");
        if (out.format_version != 0 || out.compatibility != 0) {
            fprintf(stderr, "probe null path: expected zeroed out_info\n");
            exit(1);
        }
        zova_message_free(&msg);
    }
    // Probe: path without .zova -> NOT_ZOVA_PATH and zeroed
    {
        zova_message msg = {0};
        zova_database_format_info out = {.format_version = 0xDEADBEEF, .compatibility = 0x7FFFFFFF};
        expect_status(zova_database_probe_format(&(zova_database_probe_format_request){
                          .path = "/tmp/bad.txt",
                          .out_info = &out,
                          .out_error_message = &msg,
                      }),
                      ZOVA_NOT_ZOVA_PATH, "probe bad path suffix");
        if (out.format_version != 0 || out.compatibility != 0) {
            fprintf(stderr, "probe bad path: expected zeroed out_info\n");
            exit(1);
        }
        zova_message_free(&msg);
    }
    // Probe: invalid flags not applicable for probe, but test unknown path (non-existent .zova) -> NOT_ZOVA_DATABASE
    {
        zova_message msg = {0};
        zova_database_format_info out = {0};
        expect_status(zova_database_probe_format(&(zova_database_probe_format_request){
                          .path = "/tmp/zova_probe_nonexistent_xyz123.zova",
                          .out_info = &out,
                          .out_error_message = &msg,
                      }),
                      ZOVA_NOT_ZOVA_DATABASE, "probe nonexistent .zova");
        if (out.format_version != 0 || out.compatibility != 0) {
            fprintf(stderr, "probe nonexistent: expected zeroed out_info\n");
            exit(1);
        }
        zova_message_free(&msg);
    }
    // Probe: current format (fresh DB)
    {
        const char *path = "/tmp/zova_probe_current.zova";
        remove(path);
        zova_database *db = NULL;
        zova_message msg = {0};
        expect_status(zova_database_create(&(zova_database_open_request){.path = path, .out_db = &db, .out_error_message = &msg}), ZOVA_OK, "create current for probe");
        zova_message_free(&msg);
        expect_status(zova_database_close(db), ZOVA_OK, "close current for probe");
        zova_database_format_info out = {0};
        expect_status(zova_database_probe_format(&(zova_database_probe_format_request){.path = path, .out_info = &out, .out_error_message = &msg}), ZOVA_OK, "probe current");
        if (out.format_version != 10 || out.compatibility != ZOVA_FORMAT_CURRENT) {
            fprintf(stderr, "probe current: expected 10/CURRENT got %u/%d\n", out.format_version, out.compatibility);
            exit(1);
        }
        zova_message_free(&msg);
        remove(path);
    }
    // Probe: migratable fixture
    {
        const char *src = "tests/fixtures/format-9.zova";
        const char *dst = "/tmp/zova_probe_migratable.zova";
        // copy fixture via file copy
        FILE *in = fopen(src, "rb");
        FILE *outf = fopen(dst, "wb");
        if (!in || !outf) { fprintf(stderr, "copy fixture failed\n"); exit(1); }
        char buf[8192]; size_t n; while ((n = fread(buf,1,sizeof(buf),in))>0) fwrite(buf,1,n,outf);
        fclose(in); fclose(outf);
        zova_database_format_info out = {0};
        zova_message msg = {0};
        expect_status(zova_database_probe_format(&(zova_database_probe_format_request){.path = dst, .out_info = &out, .out_error_message = &msg}), ZOVA_OK, "probe migratable");
        if (out.format_version != 9 || out.compatibility != ZOVA_FORMAT_MIGRATABLE) {
            fprintf(stderr, "probe migratable: expected 9/MIGRATABLE got %u/%d\n", out.format_version, out.compatibility);
            exit(1);
        }
        zova_message_free(&msg);
        remove(dst);
    }
    // Migrate: null source/destination, invalid flags, destination exists, busy, unsupported, no-migration-path, success, immutability, no-verify, verification failure
    {
        // null source
        zova_message msg = {0};
        expect_status(zova_database_migrate(&(zova_database_migrate_request){.source_path = NULL, .destination_path = "/tmp/dst.zova", .flags = 0, .out_error_message = &msg}), ZOVA_INVALID_ARGUMENT, "migrate null source");
        zova_message_free(&msg);
        // null dest
        expect_status(zova_database_migrate(&(zova_database_migrate_request){.source_path = "/tmp/src.zova", .destination_path = NULL, .flags = 0, .out_error_message = &msg}), ZOVA_INVALID_ARGUMENT, "migrate null dest");
        zova_message_free(&msg);
        // invalid flags
        expect_status(zova_database_migrate(&(zova_database_migrate_request){.source_path = "/tmp/src.zova", .destination_path = "/tmp/dst.zova", .flags = 0xDEADBEEF, .out_error_message = &msg}), ZOVA_INVALID_ARGUMENT, "migrate invalid flags");
        zova_message_free(&msg);
    }
    // Migrate: current format -> NO_MIGRATION_PATH
    {
        const char *src = "/tmp/zova_migrate_current_src.zova";
        const char *dst = "/tmp/zova_migrate_current_dst.zova";
        remove(src); remove(dst);
        zova_database *db = NULL; zova_message msg = {0};
        expect_status(zova_database_create(&(zova_database_open_request){.path = src, .out_db = &db, .out_error_message = &msg}), ZOVA_OK, "create current src");
        zova_message_free(&msg);
        expect_status(zova_database_close(db), ZOVA_OK, "close current src");
        zova_message err = {0};
        expect_status(zova_database_migrate(&(zova_database_migrate_request){.source_path = src, .destination_path = dst, .flags = 0, .out_error_message = &err}), ZOVA_NO_MIGRATION_PATH, "migrate current -> no path");
        zova_message_free(&err);
        if (access(dst, F_OK) == 0) { fprintf(stderr, "migrate current: dest should not exist\n"); exit(1); }
        remove(src);
    }
    // Migrate: unsupported future/legacy
    {
        const char *src = "/tmp/zova_migrate_future_src.zova";
        const char *dst = "/tmp/zova_migrate_future_dst.zova";
        remove(src); remove(dst);
        zova_database *db = NULL; zova_message msg = {0};
        expect_status(zova_database_create(&(zova_database_open_request){.path = src, .out_db = &db, .out_error_message = &msg}), ZOVA_OK, "create future base");
        zova_message_free(&msg);
        expect_status(zova_database_close(db), ZOVA_OK, "close future base");
        // patch format_version to 11
        zova_database *raw = NULL;
        // use sqlite via zova exec to update meta
        // reopen as zova to exec? Instead open via sqlite is easier but not exposed; use zova_database_open then exec
        // For synthetic, use direct sqlite via zova_database_exec on a temporary handle that bypasses version check? Use raw sqlite via file open
        // Simpler: open via sqlite directly using system sqlite3? Instead use zova's internal sqlite via exec on a fresh handle before close above we already closed
        // We'll reopen with sqlite directly using zova's sqlite wrapper not exposed; fallback to using zova_database_open which will fail for future version, so we need to use low-level sqlite open
        // Use sqlite3 directly via zova's sqlite is not exposed to C, but we can use system sqlite3 command via system()
        char cmd[1024];
        snprintf(cmd, sizeof(cmd), "sqlite3 %s \"update _zova_meta set value='11' where key='format_version'\"", src);
        if (system(cmd) != 0) { fprintf(stderr, "patch future format failed\n"); exit(1); }
        zova_message err = {0};
        expect_status(zova_database_migrate(&(zova_database_migrate_request){.source_path = src, .destination_path = dst, .flags = 0, .out_error_message = &err}), ZOVA_UNSUPPORTED_FUTURE_FORMAT, "migrate future");
        zova_message_free(&err);
        if (access(dst, F_OK) == 0) { fprintf(stderr, "migrate future: dest should not exist\n"); exit(1); }
        remove(src);
        // legacy 8
        const char *src2 = "/tmp/zova_migrate_legacy_src.zova";
        const char *dst2 = "/tmp/zova_migrate_legacy_dst.zova";
        remove(src2); remove(dst2);
        zova_database *db2 = NULL; zova_message msg2 = {0};
        expect_status(zova_database_create(&(zova_database_open_request){.path = src2, .out_db = &db2, .out_error_message = &msg2}), ZOVA_OK, "create legacy base");
        zova_message_free(&msg2);
        expect_status(zova_database_close(db2), ZOVA_OK, "close legacy base");
        snprintf(cmd, sizeof(cmd), "sqlite3 %s \"update _zova_meta set value='8' where key='format_version'\"", src2);
        if (system(cmd) != 0) { fprintf(stderr, "patch legacy format failed\n"); exit(1); }
        zova_message err2 = {0};
        expect_status(zova_database_migrate(&(zova_database_migrate_request){.source_path = src2, .destination_path = dst2, .flags = 0, .out_error_message = &err2}), ZOVA_UNSUPPORTED_LEGACY_FORMAT, "migrate legacy");
        zova_message_free(&err2);
        if (access(dst2, F_OK) == 0) { fprintf(stderr, "migrate legacy: dest should not exist\n"); exit(1); }
        remove(src2);
    }
    // Migrate: success with source immutability and destination exists check, plus busy
    {
        const char *src = "/tmp/zova_migrate_success_src.zova";
        const char *dst = "/tmp/zova_migrate_success_dst.zova";
        remove(src); remove(dst);
        // copy fixture
        FILE *in = fopen("tests/fixtures/format-9.zova", "rb");
        FILE *outf = fopen(src, "wb");
        if (!in || !outf) { fprintf(stderr, "copy for success src failed\n"); exit(1); }
        char b[8192]; size_t nn; while ((nn = fread(b,1,sizeof(b),in))>0) fwrite(b,1,nn,outf);
        fclose(in); fclose(outf);
        // hash before
        FILE *f = fopen(src, "rb"); fseek(f,0,SEEK_END); long sz = ftell(f); fseek(f,0,SEEK_SET); char *data = malloc(sz); fread(data,1,sz,f); fclose(f);
        // we don't compute hash, just check size preserved
        long before_size = sz; free(data);
        zova_message msg = {0};
        expect_status(zova_database_migrate(&(zova_database_migrate_request){.source_path = src, .destination_path = dst, .flags = 0, .out_error_message = &msg}), ZOVA_OK, "migrate success");
        zova_message_free(&msg);
        // source still exists and size same
        f = fopen(src, "rb"); fseek(f,0,SEEK_END); long after_size = ftell(f); fclose(f);
        if (before_size != after_size) { fprintf(stderr, "migrate success: source size changed\n"); exit(1); }
        // dest exists and probe is current
        zova_database_format_info out = {0}; zova_message pmsg = {0};
        expect_status(zova_database_probe_format(&(zova_database_probe_format_request){.path = dst, .out_info = &out, .out_error_message = &pmsg}), ZOVA_OK, "probe migrated dest");
        if (out.format_version != 10 || out.compatibility != ZOVA_FORMAT_CURRENT) { fprintf(stderr, "migrate dest probe wrong\n"); exit(1); }
        zova_message_free(&pmsg);
        // second migrate with same dest should be DESTINATION_EXISTS
        zova_message err2 = {0};
        expect_status(zova_database_migrate(&(zova_database_migrate_request){.source_path = src, .destination_path = dst, .flags = 0, .out_error_message = &err2}), ZOVA_DESTINATION_EXISTS, "migrate dest exists");
        zova_message_free(&err2);
        // busy: hold lock via raw sqlite (format-9 cannot be opened via zova)
        sqlite3 *lock_raw = NULL;
        if (sqlite3_open(src, &lock_raw) != SQLITE_OK) { fprintf(stderr, "open lock raw failed: %s\n", sqlite3_errmsg(lock_raw)); exit(1); }
        char *lock_err = NULL;
        if (sqlite3_exec(lock_raw, "begin immediate", NULL, NULL, &lock_err) != SQLITE_OK) { fprintf(stderr, "begin immediate failed: %s\n", lock_err); sqlite3_free(lock_err); exit(1); }
        const char *busy_dst = "/tmp/zova_migrate_busy_dst.zova";
        remove(busy_dst);
        zova_message bmsg = {0};
        zova_status busy_st = zova_database_migrate(&(zova_database_migrate_request){.source_path = src, .destination_path = busy_dst, .flags = 0, .out_error_message = &bmsg});
        if (busy_st != ZOVA_BUSY && busy_st != ZOVA_LOCKED) { fprintf(stderr, "migrate busy: expected BUSY/LOCKED got %s\n", zova_status_name(busy_st)); exit(1); }
        zova_message_free(&bmsg);
        if (access(busy_dst, F_OK) == 0) { fprintf(stderr, "migrate busy: dest should not exist\n"); exit(1); }
        if (sqlite3_exec(lock_raw, "rollback", NULL, NULL, &lock_err) != SQLITE_OK) { fprintf(stderr, "rollback failed: %s\n", lock_err); sqlite3_free(lock_err); exit(1); }
        sqlite3_close(lock_raw);
        // verification failure: corrupt _zova_chunks
        const char *corrupt_src = "/tmp/zova_migrate_corrupt_src.zova";
        const char *corrupt_dst = "/tmp/zova_migrate_corrupt_dst.zova";
        remove(corrupt_src); remove(corrupt_dst);
        in = fopen("tests/fixtures/format-9.zova", "rb"); outf = fopen(corrupt_src, "wb");
        if (!in || !outf) { fprintf(stderr, "copy corrupt src failed\n"); exit(1); }
        while ((nn = fread(b,1,sizeof(b),in))>0) fwrite(b,1,nn,outf);
        fclose(in); fclose(outf);
        char corrupt_cmd[1024];
        snprintf(corrupt_cmd, sizeof(corrupt_cmd), "sqlite3 %s \"update _zova_chunks set data = randomblob(size_bytes) where rowid = (select rowid from _zova_chunks limit 1)\"", corrupt_src);
        if (system(corrupt_cmd) != 0) { fprintf(stderr, "corrupt chunks failed\n"); exit(1); }
        zova_message cmsg = {0};
        zova_status cst = zova_database_migrate(&(zova_database_migrate_request){.source_path = corrupt_src, .destination_path = corrupt_dst, .flags = 0, .out_error_message = &cmsg});
        if (cst == ZOVA_OK) { fprintf(stderr, "migrate corrupt: expected failure\n"); exit(1); }
        zova_message_free(&cmsg);
        if (access(corrupt_dst, F_OK) == 0) { fprintf(stderr, "migrate corrupt: dest should not exist\n"); exit(1); }
        // with NO_VERIFY it should succeed
        const char *corrupt_dst2 = "/tmp/zova_migrate_corrupt_dst2.zova";
        remove(corrupt_dst2);
        zova_message cmsg2 = {0};
        expect_status(zova_database_migrate(&(zova_database_migrate_request){.source_path = corrupt_src, .destination_path = corrupt_dst2, .flags = ZOVA_MIGRATE_NO_VERIFY, .out_error_message = &cmsg2}), ZOVA_OK, "migrate corrupt no-verify");
        zova_message_free(&cmsg2);
        if (access(corrupt_dst2, F_OK) != 0) { fprintf(stderr, "migrate corrupt no-verify: dest should exist\n"); exit(1); }
        // cleanup
        remove(src); remove(dst); remove(corrupt_src); remove(corrupt_dst); remove(corrupt_dst2); remove(busy_dst);
        // ensure no _zova_ leakage in messages (already checked via not exposing private names)
    }
}

int main(int argc, char **argv) {
    expect_status(zova_graph_build_fresh_keyed(NULL), ZOVA_INVALID_ARGUMENT, "fresh graph null request");
    expect_status(zova_graph_build_fresh_prepared_keyed(NULL), ZOVA_INVALID_ARGUMENT, "prepared fresh graph null request");
    expect_status(zova_graph_build_fresh_prepared_keyed_with_payloads(NULL), ZOVA_INVALID_ARGUMENT, "prepared payload graph null request");
    expect_status(zova_graph_edge_payload_get_many(NULL), ZOVA_INVALID_ARGUMENT, "payload get null request");
    expect_status(zova_graph_edge_payload_replace_many(NULL), ZOVA_INVALID_ARGUMENT, "payload replace null request");
    expect_status(zova_fresh_build_begin(NULL), ZOVA_INVALID_ARGUMENT, "fresh builder null begin");
    expect_status(zova_fresh_build_table_rows(NULL), ZOVA_INVALID_ARGUMENT, "fresh builder null table rows");
    expect_status(zova_fresh_build_fts_rows(NULL), ZOVA_INVALID_ARGUMENT, "fresh builder null fts rows");
    expect_status(zova_fresh_build_graph(NULL), ZOVA_INVALID_ARGUMENT, "fresh builder null graph");
    expect_status(zova_fresh_build_vectors(NULL), ZOVA_INVALID_ARGUMENT, "fresh builder null vectors");
    expect_status(zova_fresh_build_finish(NULL), ZOVA_INVALID_ARGUMENT, "fresh builder null finish");
    expect_status(zova_fresh_build_abort(NULL), ZOVA_INVALID_ARGUMENT, "fresh builder null abort");
    zova_fresh_build_destroy(NULL);
    run_probe_migrate_smoke();
    if (argc != 2 && argc != 5) {
        fprintf(stderr, "usage: %s <db-path> [dynamic-library bundle-path trust-store-path]\n", argv[0]);
        return 2;
    }

    const char *db_path = argv[1];
    remove(db_path);

    char backup_path[1024];
    char compact_path[1024];
    char restored_path[1024];
    snprintf(backup_path, sizeof(backup_path), "%s.backup.zova", db_path);
    snprintf(compact_path, sizeof(compact_path), "%s.compact.zova", db_path);
    snprintf(restored_path, sizeof(restored_path), "%s.restored.zova", db_path);
    remove(backup_path);
    remove(compact_path);
    remove(restored_path);

    if (argc == 5) {
        run_dynamic_extension_bundle_smoke(db_path, argv[2], argv[3], argv[4]);
    }

    zova_database *db = NULL;
    zova_message open_message = {0};
    zova_database_create_options_request create_req = {
        .path = db_path,
        .page_size = 65536,
        .out_db = &db,
        .out_error_message = &open_message,
    };
    expect_status(zova_database_create_with_options(&create_req), ZOVA_OK, "create database with options");
    zova_message_free(&open_message);

    zova_statement *page_size_statement = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "pragma page_size",
                      .out_statement = &page_size_statement,
                  }),
                  ZOVA_OK,
                  "prepare page size");
    zova_step_result page_size_step = ZOVA_STEP_DONE;
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = page_size_statement,
                      .out_result = &page_size_step,
                  }),
                  ZOVA_OK,
                  "step page size");
    if (page_size_step != ZOVA_STEP_ROW) {
        fprintf(stderr, "page size row missing\n");
        exit(1);
    }
    int64_t page_size = 0;
    expect_status(zova_statement_column_int64(&(zova_statement_column_int64_request){
                      .statement = page_size_statement,
                      .index = 0,
                      .out_value = &page_size,
                  }),
                  ZOVA_OK,
                  "read page size");
    if (page_size != 65536) {
        fprintf(stderr, "unexpected page size\n");
        exit(1);
    }
    expect_status(zova_statement_finalize(page_size_statement), ZOVA_OK, "finalize page size");

    zova_database_exec_request exec_req = {
        .db = db,
        .sql = "create table refs (id integer primary key, object_id blob not null)",
    };
    expect_status(zova_database_exec(&exec_req), ZOVA_OK, "exec sql");
    expect_status(zova_database_exec(&(zova_database_exec_request){
                      .db = db,
                      .sql = "create table notes (id integer primary key, body text not null, payload blob not null)",
                  }),
                  ZOVA_OK,
                  "exec notes table");

    sql_callback_state sql_state = {0};
    run_sql_function_smoke(db, &sql_state);

    expect_status(zova_database_begin(&(zova_database_simple_request){.db = db}), ZOVA_OK, "begin transaction");
    expect_status(zova_database_exec(&(zova_database_exec_request){
                      .db = db,
                      .sql = "insert into notes (body, payload) values ('rolled back', x'00')",
                  }),
                  ZOVA_OK,
                  "transaction insert");
    expect_status(zova_database_rollback(&(zova_database_simple_request){.db = db}), ZOVA_OK, "rollback transaction");

    expect_status(zova_database_begin_immediate(&(zova_database_simple_request){.db = db}), ZOVA_OK, "begin savepoint transaction");
    expect_status(zova_database_savepoint(&(zova_database_savepoint_request){
                      .db = db,
                      .name = "sp_one",
                  }),
                  ZOVA_OK,
                  "create savepoint");
    expect_status(zova_database_exec(&(zova_database_exec_request){
                      .db = db,
                      .sql = "insert into notes (body, payload) values ('savepoint rolled back', x'01')",
                  }),
                  ZOVA_OK,
                  "savepoint insert");
    expect_status(zova_database_rollback_to_savepoint(&(zova_database_savepoint_request){
                      .db = db,
                      .name = "sp_one",
                  }),
                  ZOVA_OK,
                  "rollback to savepoint");
    expect_status(zova_database_release_savepoint(&(zova_database_savepoint_request){
                      .db = db,
                      .name = "sp_one",
                  }),
                  ZOVA_OK,
                  "release savepoint");
    expect_status(zova_database_savepoint(&(zova_database_savepoint_request){
                      .db = db,
                      .name = "bad name",
                  }),
                  ZOVA_INVALID_ARGUMENT,
                  "invalid savepoint name");
    expect_status(zova_database_release_savepoint(&(zova_database_savepoint_request){
                      .db = db,
                      .name = "missing_sp",
                  }),
                  ZOVA_SQLITE_ERROR,
                  "missing savepoint release");
    const char *savepoint_error = zova_database_last_error_message(db);
    if (savepoint_error == NULL || strstr(savepoint_error, "no such savepoint") == NULL) {
        fprintf(stderr, "missing savepoint release: missing diagnostic\n");
        return 1;
    }
    expect_status(zova_database_commit(&(zova_database_simple_request){.db = db}), ZOVA_OK, "commit savepoint transaction");

    zova_statement *insert_note = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "insert into notes (body, payload) values (:body, :payload)",
                      .out_statement = &insert_note,
                  }),
                  ZOVA_OK,
                  "prepare note insert");
    int body_index = 0;
    expect_status(zova_statement_parameter_index(&(zova_statement_parameter_index_request){
                      .statement = insert_note,
                      .name = ":body",
                      .out_index = &body_index,
                  }),
                  ZOVA_OK,
                  "note body parameter");
    if (body_index != 1) {
        fprintf(stderr, "note body parameter: unexpected index\n");
        return 1;
    }
    const char *note_body = "committed note";
    const uint8_t note_payload[] = {9, 8, 7};
    expect_status(zova_database_begin_immediate(&(zova_database_simple_request){.db = db}), ZOVA_OK, "begin immediate transaction");
    expect_status(zova_statement_bind_text(&(zova_statement_bind_text_request){
                      .statement = insert_note,
                      .index = 1,
                      .data = (const uint8_t *)note_body,
                      .len = strlen(note_body),
                  }),
                  ZOVA_OK,
                  "bind note text");
    expect_status(zova_statement_bind_blob(&(zova_statement_bind_blob_request){
                      .statement = insert_note,
                      .index = 2,
                      .data = note_payload,
                      .len = sizeof(note_payload),
                  }),
                  ZOVA_OK,
                  "bind note blob");
    zova_step_result step_result = ZOVA_STEP_DONE;
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = insert_note,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "step note insert");
    if (step_result != ZOVA_STEP_DONE) {
        fprintf(stderr, "step note insert: expected done\n");
        return 1;
    }
    int64_t rowid = 0;
    expect_status(zova_database_last_insert_rowid(&(zova_database_last_insert_rowid_request){
                      .db = db,
                      .out_rowid = &rowid,
                  }),
                  ZOVA_OK,
                  "last insert rowid");
    if (rowid != 1) {
        fprintf(stderr, "last insert rowid: unexpected value\n");
        return 1;
    }
    int64_t changes = 0;
    expect_status(zova_database_changes(&(zova_database_changes_request){
                      .db = db,
                      .out_changes = &changes,
                  }),
                  ZOVA_OK,
                  "changes");
    if (changes != 1) {
        fprintf(stderr, "changes: unexpected value\n");
        return 1;
    }
    int64_t total_changes = 0;
    expect_status(zova_database_total_changes(&(zova_database_total_changes_request){
                      .db = db,
                      .out_total_changes = &total_changes,
                  }),
                  ZOVA_OK,
                  "total changes");
    if (total_changes < 1) {
        fprintf(stderr, "total changes: unexpected value\n");
        return 1;
    }
    expect_status(zova_database_commit(&(zova_database_simple_request){.db = db}), ZOVA_OK, "commit transaction");
    expect_status(zova_statement_finalize(insert_note), ZOVA_OK, "finalize note insert");

    zova_statement *select_note = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select body, payload from notes",
                      .out_statement = &select_note,
                  }),
                  ZOVA_OK,
                  "prepare note select");
    int column_count = 0;
    expect_status(zova_statement_column_count(&(zova_statement_column_count_request){
                      .statement = select_note,
                      .out_count = &column_count,
                  }),
                  ZOVA_OK,
                  "note column count");
    if (column_count != 2) {
        fprintf(stderr, "note column count: unexpected count\n");
        return 1;
    }
    zova_text column_name = {0};
    expect_status(zova_statement_column_name(&(zova_statement_column_name_request){
                      .statement = select_note,
                      .index = 0,
                      .out_name = &column_name,
                  }),
                  ZOVA_OK,
                  "note column name");
    if (column_name.len != 4 || memcmp(column_name.data, "body", column_name.len) != 0) {
        fprintf(stderr, "note column name: unexpected value\n");
        return 1;
    }
    zova_text_free(&column_name);
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = select_note,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "step note select");
    if (step_result != ZOVA_STEP_ROW) {
        fprintf(stderr, "step note select: expected row\n");
        return 1;
    }
    zova_column_type note_type = ZOVA_COLUMN_NULL;
    expect_status(zova_statement_column_type(&(zova_statement_column_type_request){
                      .statement = select_note,
                      .index = 0,
                      .out_type = &note_type,
                  }),
                  ZOVA_OK,
                  "note text column type");
    if (note_type != ZOVA_COLUMN_TEXT) {
        fprintf(stderr, "note text column type: expected text\n");
        return 1;
    }
    zova_text selected_body = {0};
    zova_buffer selected_payload = {0};
    expect_status(zova_statement_column_text(&(zova_statement_column_text_request){
                      .statement = select_note,
                      .index = 0,
                      .out_text = &selected_body,
                  }),
                  ZOVA_OK,
                  "note text column");
    if (selected_body.len != strlen(note_body) || memcmp(selected_body.data, note_body, selected_body.len) != 0) {
        fprintf(stderr, "note text column: unexpected value\n");
        return 1;
    }
    expect_status(zova_statement_column_blob(&(zova_statement_column_blob_request){
                      .statement = select_note,
                      .index = 1,
                      .out_buffer = &selected_payload,
                  }),
                  ZOVA_OK,
                  "note blob column");
    expect_bytes(selected_payload.data, note_payload, selected_payload.len, "note blob column");
    zova_text_free(&selected_body);
    zova_buffer_free(&selected_payload);
    expect_status(zova_statement_finalize(select_note), ZOVA_OK, "finalize note select");

    zova_vector_collection_create_request vector_collection_req = {
        .db = db,
        .name = "chunks",
        .options = {.dimensions = 2, .metric = ZOVA_VECTOR_METRIC_L2, .element_type = ZOVA_VECTOR_ELEMENT_TYPE_F32},
    };
    expect_status(zova_vector_collection_create(&vector_collection_req), ZOVA_OK, "create vector collection");
    expect_status(zova_vector_collection_create(&vector_collection_req), ZOVA_VECTOR_COLLECTION_EXISTS, "duplicate vector collection");

    uint8_t collection_exists = 0;
    zova_vector_collection_exists_request collection_exists_req = {
        .db = db,
        .name = "chunks",
        .out_exists = &collection_exists,
    };
    expect_status(zova_vector_collection_exists(&collection_exists_req), ZOVA_OK, "vector collection exists");
    if (!collection_exists) {
        fprintf(stderr, "vector collection exists: expected true\n");
        return 1;
    }

    const float near_values[] = {1.0f, 0.0f};
    const float tie_a_values[] = {2.0f, 0.0f};
    const float tie_b_values[] = {0.0f, 2.0f};
    const float far_values[] = {10.0f, 0.0f};
    const float query_values[] = {0.0f, 0.0f};

    const float updated_near_values[] = {1.0f, 1.0f};
    zova_vector_input many_inputs[] = {
        {.id = "near", .values = f32_values(near_values, 2)},
        {.id = "tie-a", .values = f32_values(tie_a_values, 2)},
        {.id = "tie-b", .values = f32_values(tie_b_values, 2)},
        {.id = "far", .values = f32_values(far_values, 2)},
        {.id = "near", .values = f32_values(updated_near_values, 2)},
    };
    zova_vector_put_many_request put_many_req = {
        .db = db,
        .collection_name = "chunks",
        .vectors = many_inputs,
        .vectors_len = sizeof(many_inputs) / sizeof(many_inputs[0]),
    };
    expect_status(zova_vector_put_many(&put_many_req), ZOVA_OK, "put many vectors");

    uint8_t vector_exists = 0;
    zova_vector_exists_request vector_exists_req = {
        .db = db,
        .collection_name = "chunks",
        .vector_id = "near",
        .out_exists = &vector_exists,
    };
    expect_status(zova_vector_exists(&vector_exists_req), ZOVA_OK, "vector exists");
    if (!vector_exists) {
        fprintf(stderr, "vector exists: expected true\n");
        return 1;
    }

    zova_vector fetched = {0};
    zova_vector_get_request vector_get_req = {
        .db = db,
        .collection_name = "chunks",
        .vector_id = "near",
        .out_vector = &fetched,
    };
    expect_status(zova_vector_get(&vector_get_req), ZOVA_OK, "get vector");
    if (fetched.id_len != strlen("near") || memcmp(fetched.id, "near", fetched.id_len) != 0 || fetched.values_len != 2) {
        fprintf(stderr, "get vector: unexpected vector shape\n");
        return 1;
    }
    if (fetched.element_type != ZOVA_VECTOR_ELEMENT_TYPE_F32) {
        fprintf(stderr, "get vector: unexpected element type\n");
        return 1;
    }
    expect_float_values(fetched.f32_values, updated_near_values, 2, "get vector values");
    zova_vector_free(&fetched);

    zova_vector_collection_info info = {0};
    zova_vector_collection_info_get_request info_req = {
        .db = db,
        .name = "chunks",
        .out_info = &info,
    };
    expect_status(zova_vector_collection_info_get(&info_req), ZOVA_OK, "collection info");
    expect_collection_info(&info, "chunks", 2, ZOVA_VECTOR_METRIC_L2, ZOVA_VECTOR_ELEMENT_TYPE_F32, 4, "collection info");
    zova_vector_collection_info_free(&info);

    zova_vector_collection_list collection_list = {0};
    zova_vector_collections_list_request list_req = {
        .db = db,
        .out_list = &collection_list,
    };
    expect_status(zova_vector_collections_list(&list_req), ZOVA_OK, "collection list");
    if (collection_list.len != 1) {
        fprintf(stderr, "collection list: unexpected length\n");
        return 1;
    }
    expect_collection_info(&collection_list.items[0], "chunks", 2, ZOVA_VECTOR_METRIC_L2, ZOVA_VECTOR_ELEMENT_TYPE_F32, 4, "collection list");
    zova_vector_collection_list_free(&collection_list);

    zova_vector_search_results l2_results = {0};
    zova_vector_search_request search_req = {
        .db = db,
        .collection_name = "chunks",
        .query = f32_values(query_values, 2),
        .limit = 3,
        .out_results = &l2_results,
    };
    expect_status(zova_vector_search(&search_req), ZOVA_OK, "l2 vector search");
    if (l2_results.len != 3) {
        fprintf(stderr, "l2 vector search: unexpected result length\n");
        return 1;
    }
    expect_result_id(&l2_results, 0, "near", "l2 vector search");
    expect_result_id(&l2_results, 1, "tie-a", "l2 vector search");
    expect_result_id(&l2_results, 2, "tie-b", "l2 vector search");
    zova_vector_search_results_free(&l2_results);

    const char *candidate_ids[] = {"far", "missing", "tie-b", "near", "tie-a", "near"};
    zova_vector_search_results filtered_results = {0};
    zova_vector_search_in_request search_in_req = {
        .db = db,
        .collection_name = "chunks",
        .query = f32_values(query_values, 2),
        .candidate_ids = candidate_ids,
        .candidate_count = sizeof(candidate_ids) / sizeof(candidate_ids[0]),
        .limit = 2,
        .out_results = &filtered_results,
    };
    expect_status(zova_vector_search_in(&search_in_req), ZOVA_OK, "candidate vector search");
    if (filtered_results.len != 2) {
        fprintf(stderr, "candidate vector search: unexpected result length\n");
        return 1;
    }
    expect_result_id(&filtered_results, 0, "near", "candidate vector search");
    expect_result_id(&filtered_results, 1, "tie-a", "candidate vector search");
    zova_vector_search_results_free(&filtered_results);

    zova_vector_collection_create_request byte_collection_req = {
        .db = db,
        .name = "byte_chunks",
        .options = {.dimensions = 2, .metric = ZOVA_VECTOR_METRIC_L2, .element_type = ZOVA_VECTOR_ELEMENT_TYPE_I8},
    };
    expect_status(zova_vector_collection_create(&byte_collection_req), ZOVA_OK, "create i8 vector collection");
    const int8_t byte_near_values[] = {1, 0};
    const int8_t byte_far_values[] = {5, 0};
    const int8_t byte_query_values[] = {0, 0};
    expect_status(zova_vector_put(&(zova_vector_put_request){
                      .db = db,
                      .collection_name = "byte_chunks",
                      .vector_id = "near",
                      .values = {.element_type = ZOVA_VECTOR_ELEMENT_TYPE_I8, .f32_values = NULL, .f16_values = NULL, .i8_values = byte_near_values, .values_len = 2},
                  }),
                  ZOVA_OK,
                  "put typed i8 near vector");
    expect_status(zova_vector_put(&(zova_vector_put_request){
                      .db = db,
                      .collection_name = "byte_chunks",
                      .vector_id = "far",
                      .values = {.element_type = ZOVA_VECTOR_ELEMENT_TYPE_I8, .f32_values = NULL, .f16_values = NULL, .i8_values = byte_far_values, .values_len = 2},
                  }),
                  ZOVA_OK,
                  "put typed i8 far vector");
    const char *typed_candidate_ids[] = {"far"};
    zova_vector_search_results typed_filtered_results = {0};
    expect_status(zova_vector_search_in(&(zova_vector_search_in_request){
                      .db = db,
                      .collection_name = "byte_chunks",
                      .query = {.element_type = ZOVA_VECTOR_ELEMENT_TYPE_I8, .f32_values = NULL, .f16_values = NULL, .i8_values = byte_query_values, .values_len = 2},
                      .candidate_ids = typed_candidate_ids,
                      .candidate_count = sizeof(typed_candidate_ids) / sizeof(typed_candidate_ids[0]),
                      .limit = 2,
                      .out_results = &typed_filtered_results,
                  }),
                  ZOVA_OK,
                  "typed candidate vector search");
    if (typed_filtered_results.len != 1) {
        fprintf(stderr, "typed candidate vector search: unexpected result length\n");
        return 1;
    }
    expect_result_id(&typed_filtered_results, 0, "far", "typed candidate vector search");
    zova_vector_search_results_free(&typed_filtered_results);

    expect_status(zova_vector_collection_create(&(zova_vector_collection_create_request){
                      .db = db,
                      .name = "multi_i8",
                      .options = {.dimensions = 2, .metric = ZOVA_VECTOR_METRIC_COSINE, .element_type = ZOVA_VECTOR_ELEMENT_TYPE_I8},
                  }),
                  ZOVA_OK,
                  "create multi-query i8 cosine collection");
    const int8_t multi_balanced[] = {10, 10};
    const int8_t multi_east[] = {10, 0};
    expect_status(zova_vector_put(&(zova_vector_put_request){
                      .db = db,
                      .collection_name = "multi_i8",
                      .vector_id = "balanced",
                      .values = {.element_type = ZOVA_VECTOR_ELEMENT_TYPE_I8, .f32_values = NULL, .f16_values = NULL, .i8_values = multi_balanced, .values_len = 2},
                  }),
                  ZOVA_OK,
                  "put multi-query balanced vector");
    expect_status(zova_vector_put(&(zova_vector_put_request){
                      .db = db,
                      .collection_name = "multi_i8",
                      .vector_id = "east",
                      .values = {.element_type = ZOVA_VECTOR_ELEMENT_TYPE_I8, .f32_values = NULL, .f16_values = NULL, .i8_values = multi_east, .values_len = 2},
                  }),
                  ZOVA_OK,
                  "put multi-query east vector");
    const int8_t multi_queries[] = {10, 0, 0, 10};
    zova_vector_search_results multi_results = {0};
    expect_status(zova_vector_search_multi_i8(&(zova_vector_search_multi_i8_request){
                      .db = db,
                      .collection_name = "multi_i8",
                      .query_values = multi_queries,
                      .query_values_len = sizeof(multi_queries) / sizeof(multi_queries[0]),
                      .query_count = 2,
                      .dimensions = 2,
                      .candidate_ids = NULL,
                      .candidate_count = 0,
                      .mode = ZOVA_VECTOR_MULTI_I8_SEARCH_GLOBAL_MIN_COSINE,
                      .aggregation = ZOVA_VECTOR_MULTI_I8_AGGREGATION_MIN_COSINE,
                      .prefilter_query_index = 0,
                      .prefilter_limit = 0,
                      .limit = 1,
                      .out_results = &multi_results,
                  }),
                  ZOVA_OK,
                  "global multi-query i8 cosine search");
    expect_result_id(&multi_results, 0, "balanced", "global multi-query i8 cosine search");
    zova_vector_search_results_free(&multi_results);
    expect_status(zova_vector_search_multi_i8(&(zova_vector_search_multi_i8_request){
                      .db = db,
                      .collection_name = "multi_i8",
                      .query_values = multi_queries,
                      .query_values_len = sizeof(multi_queries) / sizeof(multi_queries[0]),
                      .query_count = 2,
                      .dimensions = 2,
                      .candidate_ids = NULL,
                      .candidate_count = 0,
                      .mode = ZOVA_VECTOR_MULTI_I8_SEARCH_CBM_PREFILTER_MIN_COSINE,
                      .aggregation = ZOVA_VECTOR_MULTI_I8_AGGREGATION_MIN_COSINE,
                      .prefilter_query_index = 0,
                      .prefilter_limit = 1,
                      .limit = 1,
                      .out_results = &multi_results,
                  }),
                  ZOVA_OK,
                  "CBM-compatible multi-query i8 cosine search");
    expect_result_id(&multi_results, 0, "east", "CBM-compatible multi-query i8 cosine search");
    zova_vector_search_results_free(&multi_results);

    zova_vector_search_within_request within_req = {
        .db = db,
        .collection_name = "chunks",
        .query = f32_values(query_values, 2),
        .max_distance = 2.0,
        .limit = 10,
        .out_results = &filtered_results,
    };
    expect_status(zova_vector_search_within(&within_req), ZOVA_OK, "threshold vector search");
    if (filtered_results.len != 3) {
        fprintf(stderr, "threshold vector search: unexpected result length\n");
        return 1;
    }
    zova_vector_search_results_free(&filtered_results);

    zova_vector_search_in_within_request in_within_req = {
        .db = db,
        .collection_name = "chunks",
        .query = f32_values(query_values, 2),
        .candidate_ids = candidate_ids,
        .candidate_count = sizeof(candidate_ids) / sizeof(candidate_ids[0]),
        .max_distance = 2.0,
        .limit = 10,
        .out_results = &filtered_results,
    };
    expect_status(zova_vector_search_in_within(&in_within_req), ZOVA_OK, "candidate threshold vector search");
    if (filtered_results.len != 3) {
        fprintf(stderr, "candidate threshold vector search: unexpected result length\n");
        return 1;
    }
    zova_vector_search_results_free(&filtered_results);

    zova_vector_search_by_id_request by_id_req = {
        .db = db,
        .collection_name = "chunks",
        .source_vector_id = "near",
        .limit = 3,
        .out_results = &filtered_results,
    };
    expect_status(zova_vector_search_by_id(&by_id_req), ZOVA_OK, "search by id");
    if (filtered_results.len != 3) {
        fprintf(stderr, "search by id: unexpected result length\n");
        return 1;
    }
    expect_result_id(&filtered_results, 0, "tie-a", "search by id");
    zova_vector_search_results_free(&filtered_results);

    zova_vector_search_by_id_in_request by_id_in_req = {
        .db = db,
        .collection_name = "chunks",
        .source_vector_id = "near",
        .candidate_ids = candidate_ids,
        .candidate_count = sizeof(candidate_ids) / sizeof(candidate_ids[0]),
        .limit = 10,
        .out_results = &filtered_results,
    };
    expect_status(zova_vector_search_by_id_in(&by_id_in_req), ZOVA_OK, "candidate search by id");
    if (filtered_results.len != 3) {
        fprintf(stderr, "candidate search by id: unexpected result length\n");
        return 1;
    }
    zova_vector_search_results_free(&filtered_results);

    zova_vector_search_by_id_within_request by_id_within_req = {
        .db = db,
        .collection_name = "chunks",
        .source_vector_id = "near",
        .max_distance = 2.0,
        .limit = 10,
        .out_results = &filtered_results,
    };
    expect_status(zova_vector_search_by_id_within(&by_id_within_req), ZOVA_OK, "threshold search by id");
    if (filtered_results.len != 2) {
        fprintf(stderr, "threshold search by id: unexpected result length\n");
        return 1;
    }
    zova_vector_search_results_free(&filtered_results);

    zova_vector_search_by_id_in_within_request by_id_in_within_req = {
        .db = db,
        .collection_name = "chunks",
        .source_vector_id = "near",
        .candidate_ids = candidate_ids,
        .candidate_count = sizeof(candidate_ids) / sizeof(candidate_ids[0]),
        .max_distance = 2.0,
        .limit = 10,
        .out_results = &filtered_results,
    };
    expect_status(zova_vector_search_by_id_in_within(&by_id_in_within_req), ZOVA_OK, "candidate threshold search by id");
    if (filtered_results.len != 2) {
        fprintf(stderr, "candidate threshold search by id: unexpected result length\n");
        return 1;
    }
    zova_vector_search_results_free(&filtered_results);

    zova_vector_delete_request delete_vector_req = {
        .db = db,
        .collection_name = "chunks",
        .vector_id = "far",
    };
    expect_status(zova_vector_delete(&delete_vector_req), ZOVA_OK, "delete vector");
    expect_status(zova_vector_delete(&delete_vector_req), ZOVA_VECTOR_NOT_FOUND, "delete missing vector");

    zova_vector_get_request missing_vector_get_req = {
        .db = db,
        .collection_name = "chunks",
        .vector_id = "far",
        .out_vector = &fetched,
    };
    expect_status(zova_vector_get(&missing_vector_get_req), ZOVA_VECTOR_NOT_FOUND, "get missing vector");

    zova_vector_put_request missing_collection_put = {
        .db = db,
        .collection_name = "missing",
        .vector_id = "id",
        .values = f32_values(near_values, 2),
    };
    expect_status(zova_vector_put(&missing_collection_put), ZOVA_VECTOR_COLLECTION_NOT_FOUND, "put missing vector collection");

    zova_vector_collection_create_request cosine_collection_req = {
        .db = db,
        .name = "cosine",
        .options = {.dimensions = 2, .metric = ZOVA_VECTOR_METRIC_COSINE, .element_type = ZOVA_VECTOR_ELEMENT_TYPE_F32},
    };
    zova_vector_collection_create_request dot_collection_req = {
        .db = db,
        .name = "dot",
        .options = {.dimensions = 2, .metric = ZOVA_VECTOR_METRIC_DOT, .element_type = ZOVA_VECTOR_ELEMENT_TYPE_F32},
    };
    expect_status(zova_vector_collection_create(&cosine_collection_req), ZOVA_OK, "create cosine collection");
    expect_status(zova_vector_collection_create(&dot_collection_req), ZOVA_OK, "create dot collection");

    const float east[] = {1.0f, 0.0f};
    const float north[] = {0.0f, 1.0f};
    const float northeast[] = {1.0f, 1.0f};
    zova_vector_put_request put_cosine_east = {
        .db = db,
        .collection_name = "cosine",
        .vector_id = "east",
        .values = f32_values(east, 2),
    };
    zova_vector_put_request put_cosine_north = {
        .db = db,
        .collection_name = "cosine",
        .vector_id = "north",
        .values = f32_values(north, 2),
    };
    zova_vector_put_request put_cosine_northeast = {
        .db = db,
        .collection_name = "cosine",
        .vector_id = "northeast",
        .values = f32_values(northeast, 2),
    };
    expect_status(zova_vector_put(&put_cosine_east), ZOVA_OK, "put cosine east");
    expect_status(zova_vector_put(&put_cosine_north), ZOVA_OK, "put cosine north");
    expect_status(zova_vector_put(&put_cosine_northeast), ZOVA_OK, "put cosine northeast");

    zova_vector_search_results cosine_results = {0};
    zova_vector_search_request cosine_search_req = {
        .db = db,
        .collection_name = "cosine",
        .query = f32_values(east, 2),
        .limit = 3,
        .out_results = &cosine_results,
    };
    expect_status(zova_vector_search(&cosine_search_req), ZOVA_OK, "cosine vector search");
    if (cosine_results.len != 3) {
        fprintf(stderr, "cosine vector search: unexpected result length\n");
        return 1;
    }
    expect_result_id(&cosine_results, 0, "east", "cosine vector search");
    expect_result_id(&cosine_results, 1, "northeast", "cosine vector search");
    expect_result_id(&cosine_results, 2, "north", "cosine vector search");
    zova_vector_search_results_free(&cosine_results);

    const float dot_large[] = {3.0f, 0.0f};
    const float dot_small[] = {1.0f, 0.0f};
    const float dot_negative[] = {-1.0f, 0.0f};
    zova_vector_put_request put_dot_large = {
        .db = db,
        .collection_name = "dot",
        .vector_id = "large",
        .values = f32_values(dot_large, 2),
    };
    zova_vector_put_request put_dot_small = {
        .db = db,
        .collection_name = "dot",
        .vector_id = "small",
        .values = f32_values(dot_small, 2),
    };
    zova_vector_put_request put_dot_negative = {
        .db = db,
        .collection_name = "dot",
        .vector_id = "negative",
        .values = f32_values(dot_negative, 2),
    };
    expect_status(zova_vector_put(&put_dot_large), ZOVA_OK, "put dot large");
    expect_status(zova_vector_put(&put_dot_small), ZOVA_OK, "put dot small");
    expect_status(zova_vector_put(&put_dot_negative), ZOVA_OK, "put dot negative");

    zova_vector_search_results dot_results = {0};
    zova_vector_search_request dot_search_req = {
        .db = db,
        .collection_name = "dot",
        .query = f32_values(east, 2),
        .limit = 3,
        .out_results = &dot_results,
    };
    expect_status(zova_vector_search(&dot_search_req), ZOVA_OK, "dot vector search");
    if (dot_results.len != 3) {
        fprintf(stderr, "dot vector search: unexpected result length\n");
        return 1;
    }
    expect_result_id(&dot_results, 0, "large", "dot vector search");
    expect_result_id(&dot_results, 1, "small", "dot vector search");
    expect_result_id(&dot_results, 2, "negative", "dot vector search");
    zova_vector_search_results_free(&dot_results);

    zova_vector_search_within_request dot_threshold_req = {
        .db = db,
        .collection_name = "dot",
        .query = f32_values(east, 2),
        .max_distance = -1.0,
        .limit = 3,
        .out_results = &dot_results,
    };
    expect_status(zova_vector_search_within(&dot_threshold_req), ZOVA_OK, "dot threshold vector search");
    if (dot_results.len != 2) {
        fprintf(stderr, "dot threshold vector search: unexpected result length\n");
        return 1;
    }
    zova_vector_search_results_free(&dot_results);

    const uint8_t zero_query_blob[] = {0, 0, 0, 0, 0, 0, 0, 0};
    zova_statement *sql_distance = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select zova_vector_distance('chunks', 'near', ?)",
                      .out_statement = &sql_distance,
                  }),
                  ZOVA_OK,
                  "prepare sql vector distance");
    expect_status(zova_statement_bind_blob(&(zova_statement_bind_blob_request){
                      .statement = sql_distance,
                      .index = 1,
                      .data = zero_query_blob,
                      .len = sizeof(zero_query_blob),
                  }),
                  ZOVA_OK,
                  "bind sql vector query blob");
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = sql_distance,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "step sql vector distance");
    if (step_result != ZOVA_STEP_ROW) {
        fprintf(stderr, "step sql vector distance: expected row\n");
        return 1;
    }
    double sql_distance_value = 0.0;
    expect_status(zova_statement_column_double(&(zova_statement_column_double_request){
                      .statement = sql_distance,
                      .index = 0,
                      .out_value = &sql_distance_value,
                  }),
                  ZOVA_OK,
                  "read sql vector distance");
    if (sql_distance_value < 1.4 || sql_distance_value > 1.5) {
        fprintf(stderr, "read sql vector distance: unexpected distance\n");
        return 1;
    }
    expect_status(zova_statement_finalize(sql_distance), ZOVA_OK, "finalize sql vector distance");

    zova_statement *sql_search = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select rank, vector_id, distance from zova_vector_search where collection = 'chunks' and query_vector = ? and top_k = 2 order by rank",
                      .out_statement = &sql_search,
                  }),
                  ZOVA_OK,
                  "prepare sql vector search");
    expect_status(zova_statement_bind_blob(&(zova_statement_bind_blob_request){
                      .statement = sql_search,
                      .index = 1,
                      .data = zero_query_blob,
                      .len = sizeof(zero_query_blob),
                  }),
                  ZOVA_OK,
                  "bind sql vector search query blob");
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = sql_search,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "step sql vector search first row");
    if (step_result != ZOVA_STEP_ROW) {
        fprintf(stderr, "step sql vector search first row: expected row\n");
        return 1;
    }
    int64_t sql_rank = 0;
    expect_status(zova_statement_column_int64(&(zova_statement_column_int64_request){
                      .statement = sql_search,
                      .index = 0,
                      .out_value = &sql_rank,
                  }),
                  ZOVA_OK,
                  "read sql vector search rank");
    if (sql_rank != 1) {
        fprintf(stderr, "read sql vector search rank: unexpected rank\n");
        return 1;
    }
    zova_text sql_vector_id = {0};
    expect_status(zova_statement_column_text(&(zova_statement_column_text_request){
                      .statement = sql_search,
                      .index = 1,
                      .out_text = &sql_vector_id,
                  }),
                  ZOVA_OK,
                  "read sql vector search id");
    if (sql_vector_id.len != strlen("near") || memcmp(sql_vector_id.data, "near", sql_vector_id.len) != 0) {
        fprintf(stderr, "read sql vector search id: unexpected id\n");
        return 1;
    }
    zova_text_free(&sql_vector_id);
    expect_status(zova_statement_finalize(sql_search), ZOVA_OK, "finalize sql vector search");

    zova_statement *sql_distance_by_id = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select zova_vector_distance_by_id('chunks', 'tie-a', 'near')",
                      .out_statement = &sql_distance_by_id,
                  }),
                  ZOVA_OK,
                  "prepare sql vector distance by id");
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = sql_distance_by_id,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "step sql vector distance by id");
    if (step_result != ZOVA_STEP_ROW) {
        fprintf(stderr, "step sql vector distance by id: expected row\n");
        return 1;
    }
    expect_status(zova_statement_column_double(&(zova_statement_column_double_request){
                      .statement = sql_distance_by_id,
                      .index = 0,
                      .out_value = &sql_distance_value,
                  }),
                  ZOVA_OK,
                  "read sql vector distance by id");
    if (sql_distance_value < 1.4 || sql_distance_value > 1.5) {
        fprintf(stderr, "read sql vector distance by id: unexpected distance\n");
        return 1;
    }
    expect_status(zova_statement_finalize(sql_distance_by_id), ZOVA_OK, "finalize sql vector distance by id");

    run_graph_smoke(db);
    run_extension_smoke(db);
    run_threaded_same_handle_smoke(db);
    run_notification_smoke(db);

    zova_statement *live_stmt = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select 1",
                      .out_statement = &live_stmt,
                  }),
                  ZOVA_OK,
                  "live statement prepare");
    expect_status(zova_database_close(db), ZOVA_MISUSE, "close with live statement");
    expect_status(zova_statement_finalize(live_stmt), ZOVA_OK, "finalize live statement");

    zova_object_writer *live_writer = NULL;
    expect_status(zova_object_writer_create(&(zova_object_writer_create_request){
                      .db = db,
                      .out_writer = &live_writer,
                  }),
                  ZOVA_OK,
                  "live writer create");
    expect_status(zova_database_close(db), ZOVA_MISUSE, "close with live writer");
    expect_status(zova_object_writer_destroy(live_writer), ZOVA_OK, "destroy live writer");

    zova_database *readonly_db = NULL;
    expect_status(zova_database_open_with_options(&(zova_database_open_options_request){
                      .path = db_path,
                      .flags = ZOVA_OPEN_READ_ONLY,
                      .busy_timeout_ms = 1,
                      .out_db = &readonly_db,
                      .out_error_message = NULL,
                  }),
                  ZOVA_OK,
                  "read-only open");
    zova_statement *readonly_stmt = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = readonly_db,
                      .sql = "select count(*) from notes",
                      .out_statement = &readonly_stmt,
                  }),
                  ZOVA_OK,
                  "read-only prepare");
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = readonly_stmt,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "read-only step");
    expect_status(zova_statement_finalize(readonly_stmt), ZOVA_OK, "read-only finalize");
    expect_status(zova_database_exec(&(zova_database_exec_request){
                      .db = readonly_db,
                      .sql = "insert into notes(body, payload) values ('blocked', x'00')",
                  }),
                  ZOVA_READ_ONLY,
                  "read-only write");
    expect_status(zova_database_close(readonly_db), ZOVA_OK, "read-only close");

    zova_database *contender = NULL;
    expect_status(zova_database_open_with_options(&(zova_database_open_options_request){
                      .path = db_path,
                      .flags = 0,
                      .busy_timeout_ms = 1,
                      .out_db = &contender,
                      .out_error_message = NULL,
                  }),
                  ZOVA_OK,
                  "contender open");
    expect_status(zova_database_begin_immediate(&(zova_database_simple_request){.db = db}), ZOVA_OK, "busy holder begin immediate");
    zova_status contender_status = zova_database_begin_immediate(&(zova_database_simple_request){.db = contender});
    if (contender_status != ZOVA_BUSY && contender_status != ZOVA_LOCKED) {
        fprintf(stderr, "contender begin immediate: expected busy or locked, got %s\n", zova_status_name(contender_status));
        return 1;
    }
    expect_status(zova_database_rollback(&(zova_database_simple_request){.db = db}), ZOVA_OK, "busy holder rollback");
    expect_status(zova_database_close(contender), ZOVA_OK, "contender close");

    zova_vector_collection_delete_request delete_collection_req = {
        .db = db,
        .name = "chunks",
    };
    expect_status(zova_vector_collection_delete(&delete_collection_req), ZOVA_OK, "delete vector collection");
    expect_status(zova_vector_get(&vector_get_req), ZOVA_VECTOR_COLLECTION_NOT_FOUND, "get vector after collection delete");

    const uint8_t object_bytes[] = "hello from c abi";
    zova_object_id expected_id = {0};
    expect_status(zova_object_id_from_bytes(object_bytes, sizeof(object_bytes) - 1, &expected_id), ZOVA_OK, "object id");

    zova_object_id object_id = {0};
    zova_object_put_request put_req = {
        .db = db,
        .data = object_bytes,
        .len = sizeof(object_bytes) - 1,
        .out_id = &object_id,
    };
    expect_status(zova_object_put(&put_req), ZOVA_OK, "put object");
    expect_id_equal(object_id, expected_id, "put object id");

    zova_statement *insert_ref = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "insert into refs (object_id) values (?)",
                      .out_statement = &insert_ref,
                  }),
                  ZOVA_OK,
                  "prepare ref insert");
    expect_status(zova_statement_bind_blob(&(zova_statement_bind_blob_request){
                      .statement = insert_ref,
                      .index = 1,
                      .data = object_id.bytes,
                      .len = sizeof(object_id.bytes),
                  }),
                  ZOVA_OK,
                  "bind object id ref");
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = insert_ref,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "step ref insert");
    if (step_result != ZOVA_STEP_DONE) {
        fprintf(stderr, "step ref insert: expected done\n");
        return 1;
    }
    expect_status(zova_statement_finalize(insert_ref), ZOVA_OK, "finalize ref insert");

    zova_statement *select_ref = NULL;
    expect_status(zova_database_prepare(&(zova_database_prepare_request){
                      .db = db,
                      .sql = "select object_id from refs",
                      .out_statement = &select_ref,
                  }),
                  ZOVA_OK,
                  "prepare ref select");
    expect_status(zova_statement_step(&(zova_statement_step_request){
                      .statement = select_ref,
                      .out_result = &step_result,
                  }),
                  ZOVA_OK,
                  "step ref select");
    if (step_result != ZOVA_STEP_ROW) {
        fprintf(stderr, "step ref select: expected row\n");
        return 1;
    }
    zova_buffer selected_object_id = {0};
    expect_status(zova_statement_column_blob(&(zova_statement_column_blob_request){
                      .statement = select_ref,
                      .index = 0,
                      .out_buffer = &selected_object_id,
                  }),
                  ZOVA_OK,
                  "read object id ref");
    expect_bytes(selected_object_id.data, object_id.bytes, sizeof(object_id.bytes), "read object id ref");
    zova_buffer_free(&selected_object_id);
    expect_status(zova_statement_finalize(select_ref), ZOVA_OK, "finalize ref select");

    uint8_t range[5] = {0};
    size_t copied = 0;
    zova_object_read_range_request range_req = {
        .db = db,
        .id = object_id,
        .offset = 6,
        .buffer = range,
        .buffer_len = sizeof(range),
        .out_copied = &copied,
    };
    expect_status(zova_object_read_range(&range_req), ZOVA_OK, "range read");
    if (copied != sizeof(range)) {
        fprintf(stderr, "range read: wrong copied length\n");
        return 1;
    }
    expect_bytes(range, (const uint8_t *)"from ", sizeof(range), "range read");

    zova_buffer full = {0};
    zova_object_get_request get_req = {
        .db = db,
        .id = object_id,
        .out_buffer = &full,
    };
    expect_status(zova_object_get(&get_req), ZOVA_OK, "get object");
    if (full.len != sizeof(object_bytes) - 1) {
        fprintf(stderr, "get object: wrong length\n");
        return 1;
    }
    expect_bytes(full.data, object_bytes, full.len, "get object");
    zova_buffer_free(&full);

    zova_object_manifest manifest = {0};
    zova_object_manifest_get_request manifest_req = {
        .db = db,
        .id = object_id,
        .out_manifest = &manifest,
    };
    expect_status(zova_object_manifest_get(&manifest_req), ZOVA_OK, "manifest");
    if (manifest.chunks_len != 1 || manifest.chunk_count != 1 || manifest.size_bytes != sizeof(object_bytes) - 1) {
        fprintf(stderr, "manifest: unexpected shape\n");
        return 1;
    }

    zova_buffer chunk = {0};
    zova_object_chunk_get_request chunk_get_req = {
        .db = db,
        .hash = manifest.chunks[0].hash,
        .out_buffer = &chunk,
    };
    expect_status(zova_object_chunk_get(&chunk_get_req), ZOVA_OK, "get chunk");
    expect_bytes(chunk.data, object_bytes, chunk.len, "get chunk");
    zova_buffer_free(&chunk);

    const uint8_t assembled_bytes[] = "left-right";
    const uint8_t left[] = "left-";
    const uint8_t right[] = "right";
    zova_object_id assembled_id = {0};
    zova_object_chunk_id left_hash = {0};
    zova_object_chunk_id right_hash = {0};
    expect_status(zova_object_id_from_bytes(assembled_bytes, sizeof(assembled_bytes) - 1, &assembled_id), ZOVA_OK, "assembled id");
    expect_status(zova_object_chunk_id_from_bytes(left, sizeof(left) - 1, &left_hash), ZOVA_OK, "left hash");
    expect_status(zova_object_chunk_id_from_bytes(right, sizeof(right) - 1, &right_hash), ZOVA_OK, "right hash");

    zova_object_chunk_put_request left_put = {
        .db = db,
        .expected_hash = left_hash,
        .data = left,
        .len = sizeof(left) - 1,
    };
    zova_object_chunk_put_request right_put = {
        .db = db,
        .expected_hash = right_hash,
        .data = right,
        .len = sizeof(right) - 1,
    };
    expect_status(zova_object_chunk_put(&left_put), ZOVA_OK, "put left chunk");
    expect_status(zova_object_chunk_put(&right_put), ZOVA_OK, "put right chunk");

    zova_object_manifest_chunk chunks[2] = {
        {.index = 0, .hash = left_hash, .offset = 0, .size_bytes = sizeof(left) - 1},
        {.index = 1, .hash = right_hash, .offset = sizeof(left) - 1, .size_bytes = sizeof(right) - 1},
    };
    zova_object_assemble_from_chunks_request assemble_req = {
        .db = db,
        .id = assembled_id,
        .size_bytes = sizeof(assembled_bytes) - 1,
        .chunks = chunks,
        .chunk_count = 2,
    };
    expect_status(zova_object_assemble_from_chunks(&assemble_req), ZOVA_OK, "assemble object");

    zova_object_writer *writer = NULL;
    zova_object_writer_create_request writer_create_req = {
        .db = db,
        .out_writer = &writer,
    };
    expect_status(zova_object_writer_create(&writer_create_req), ZOVA_OK, "writer create");
    zova_object_writer_write_request writer_write_1 = {
        .writer = writer,
        .data = (const uint8_t *)"streamed ",
        .len = 9,
    };
    zova_object_writer_write_request writer_write_2 = {
        .writer = writer,
        .data = (const uint8_t *)"object",
        .len = 6,
    };
    expect_status(zova_object_writer_write(&writer_write_1), ZOVA_OK, "writer write 1");
    expect_status(zova_object_writer_write(&writer_write_2), ZOVA_OK, "writer write 2");
    zova_object_id streamed_id = {0};
    zova_object_writer_finish_request writer_finish_req = {
        .writer = writer,
        .out_id = &streamed_id,
    };
    expect_status(zova_object_writer_finish(&writer_finish_req), ZOVA_OK, "writer finish");
    expect_status(zova_object_writer_destroy(writer), ZOVA_OK, "writer destroy");

    {
        zova_kv_bytes settings_namespace = {(const uint8_t *)"settings", 8};
        zova_kv_put_request kv_put = {
            .db = db,
            .ns = settings_namespace,
            .key = (zova_kv_bytes){(const uint8_t *)"theme", 5},
            .value = (zova_kv_bytes){(const uint8_t *)"dark", 4},
        };
        expect_status(zova_kv_put(&kv_put), ZOVA_OK, "kv put");

        zova_kv_get_result kv_result = {0};
        zova_kv_get_request kv_get = {
            .db = db,
            .ns = settings_namespace,
            .key = (zova_kv_bytes){(const uint8_t *)"theme", 5},
            .out_result = &kv_result,
        };
        expect_status(zova_kv_get(&kv_get), ZOVA_OK, "kv get");
        if (!kv_result.found || kv_result.value.len != 4) {
            fprintf(stderr, "kv get: unexpected result\n");
            return 1;
        }
        expect_bytes(kv_result.value.data, (const uint8_t *)"dark", 4, "kv get value");
        zova_kv_get_result_free(&kv_result);
        if (kv_result.found) {
            fprintf(stderr, "kv get result free: not idempotent\n");
            return 1;
        }

        zova_kv_get_result kv_missing = {0};
        zova_kv_get_request kv_get_missing = {
            .db = db,
            .ns = settings_namespace,
            .key = (zova_kv_bytes){(const uint8_t *)"ghost", 5},
            .out_result = &kv_missing,
        };
        expect_status(zova_kv_get(&kv_get_missing), ZOVA_OK, "kv get missing");
        if (kv_missing.found) {
            fprintf(stderr, "kv get missing: should not be found\n");
            return 1;
        }
        zova_kv_get_result_free(&kv_missing);

        zova_kv_get_many_results kv_many = {0};
        zova_kv_bytes kv_keys[2] = {
            {(const uint8_t *)"theme", 5},
            {(const uint8_t *)"ghost", 5},
        };
        zova_kv_get_many_request kv_get_many = {
            .db = db,
            .ns = settings_namespace,
            .keys = kv_keys,
            .keys_len = 2,
            .out_results = &kv_many,
        };
        expect_status(zova_kv_get_many(&kv_get_many), ZOVA_OK, "kv get many");
        if (kv_many.len != 2 || !kv_many.items[0].found || kv_many.items[1].found) {
            fprintf(stderr, "kv get many: unexpected alignment\n");
            return 1;
        }
        zova_kv_get_many_results_free(&kv_many);
        if (kv_many.len != 0) {
            fprintf(stderr, "kv get many free: not idempotent\n");
            return 1;
        }

        uint64_t kv_count = 0;
        zova_kv_count_request kv_count_req = {
            .db = db,
            .ns = settings_namespace,
            .out_count = &kv_count,
        };
        expect_status(zova_kv_count(&kv_count_req), ZOVA_OK, "kv count");
        if (kv_count != 1) {
            fprintf(stderr, "kv count: expected 1, got %llu\n", (unsigned long long)kv_count);
            return 1;
        }

        zova_kv_put_entry kv_batch[2] = {
            {(zova_kv_bytes){(const uint8_t *)"retries", 7}, (zova_kv_bytes){(const uint8_t *)"\x00\x01\x02", 3}},
            {(zova_kv_bytes){(const uint8_t *)"theme", 5}, (zova_kv_bytes){(const uint8_t *)"light", 5}},
        };
        zova_kv_put_many_request kv_put_many = {
            .db = db,
            .ns = settings_namespace,
            .entries = kv_batch,
            .entries_len = 2,
        };
        expect_status(zova_kv_put_many(&kv_put_many), ZOVA_OK, "kv put many");

        zova_kv_delete_many_request kv_delete_many = {
            .db = db,
            .ns = settings_namespace,
            .keys = kv_keys,
            .keys_len = 2,
        };
        expect_status(zova_kv_delete_many(&kv_delete_many), ZOVA_OK, "kv delete many");

        kv_count_req.out_count = &kv_count;
        expect_status(zova_kv_count(&kv_count_req), ZOVA_OK, "kv count after delete");
        if (kv_count != 1) {
            fprintf(stderr, "kv count after delete: expected 1, got %llu\n", (unsigned long long)kv_count);
            return 1;
        }

        zova_kv_clear_namespace_request kv_clear = {
            .db = db,
            .ns = settings_namespace,
        };
        expect_status(zova_kv_clear_namespace(&kv_clear), ZOVA_OK, "kv clear namespace");
        kv_count_req.out_count = &kv_count;
        expect_status(zova_kv_count(&kv_count_req), ZOVA_OK, "kv count after clear");
        if (kv_count != 0) {
            fprintf(stderr, "kv count after clear: expected 0, got %llu\n", (unsigned long long)kv_count);
            return 1;
        }
    }

    zova_object_delete_request missing_delete = {
        .db = db,
        .id = {{0}},
    };
    expect_status(zova_object_delete(&missing_delete), ZOVA_OBJECT_NOT_FOUND, "missing object");

    zova_object_manifest_free(&manifest);
    expect_status(zova_database_backup(&(zova_database_backup_request){
                      .db = db,
                      .destination_path = backup_path,
                      .flags = 0,
                  }),
                  ZOVA_OK,
                  "backup database");
    expect_status(zova_database_compact(&(zova_database_compact_request){
                      .db = db,
                      .destination_path = compact_path,
                      .flags = ZOVA_COMPACT_NO_VERIFY,
                  }),
                  ZOVA_OK,
                  "compact database");
    expect_status(zova_database_restore(&(zova_database_restore_request){
                      .source_path = backup_path,
                      .destination_path = restored_path,
                      .flags = 0,
                      .out_error_message = &open_message,
                  }),
                  ZOVA_OK,
                  "restore database");
    zova_message_free(&open_message);
    verify_operational_copy(backup_path, object_id, "backup copy");
    verify_operational_copy(compact_path, object_id, "compact copy");
    verify_operational_copy(restored_path, object_id, "restored copy");

    expect_status(zova_database_vacuum(&(zova_database_simple_request){.db = db}), ZOVA_OK, "explicit vacuum");
    expect_status(zova_database_close(db), ZOVA_OK, "close database");
    if (!sql_state.destroyed) {
        fprintf(stderr, "close database: expected SQL callback destructor\n");
        return 1;
    }

    db = NULL;
    zova_database_open_request open_req = {
        .path = db_path,
        .out_db = &db,
        .out_error_message = &open_message,
    };
    expect_status(zova_database_open(&open_req), ZOVA_OK, "reopen database");
    zova_message_free(&open_message);

    memset(range, 0, sizeof(range));
    copied = 0;
    range_req.db = db;
    expect_status(zova_object_read_range(&range_req), ZOVA_OK, "range read after reopen");
    if (copied != sizeof(range)) {
        fprintf(stderr, "range read after reopen: wrong copied length\n");
        return 1;
    }
    expect_bytes(range, (const uint8_t *)"from ", sizeof(range), "range read after reopen");

    expect_status(zova_database_close(db), ZOVA_OK, "close reopened database");

    /* In-memory mode: create_memory is fully usable and backup can persist it. */
    {
        zova_database *mem = NULL;
        expect_status(zova_database_create_memory(&(zova_database_create_memory_request){
                          .out_db = &mem,
                          .out_error_message = &open_message,
                      }),
                      ZOVA_OK,
                      "create in-memory database");
        zova_message_free(&open_message);
        expect_status(zova_database_exec(&(zova_database_exec_request){
                          .db = mem,
                          .sql = "create table memory_rows (id integer primary key, value text not null)",
                      }),
                      ZOVA_OK,
                      "in-memory exec sql");
        expect_status(zova_database_exec(&(zova_database_exec_request){
                          .db = mem,
                          .sql = "insert into memory_rows (value) values ('in-memory data')",
                      }),
                      ZOVA_OK,
                      "in-memory insert");
        char mem_backup[1024];
        snprintf(mem_backup, sizeof(mem_backup), "%s.memory.zova", db_path);
        remove(mem_backup);
        expect_status(zova_database_backup(&(zova_database_backup_request){
                          .db = mem,
                          .destination_path = mem_backup,
                          .flags = ZOVA_BACKUP_NO_VERIFY,
                      }),
                      ZOVA_OK,
                      "backup in-memory database");

        zova_database *mem_copy = NULL;
        expect_status(zova_database_open(&(zova_database_open_request){
                          .path = mem_backup,
                          .out_db = &mem_copy,
                          .out_error_message = &open_message,
                      }),
                      ZOVA_OK,
                      "open in-memory backup copy");
        zova_message_free(&open_message);
        zova_statement *mem_count_statement = NULL;
        zova_step_result mem_count_step = ZOVA_STEP_DONE;
        int64_t mem_row_count = 0;
        expect_status(zova_database_prepare(&(zova_database_prepare_request){
                          .db = mem_copy,
                          .sql = "select count(*) from memory_rows",
                          .out_statement = &mem_count_statement,
                      }),
                      ZOVA_OK,
                      "prepare in-memory backup count");
        expect_status(zova_statement_step(&(zova_statement_step_request){
                          .statement = mem_count_statement,
                          .out_result = &mem_count_step,
                      }),
                      ZOVA_OK,
                      "step in-memory backup count");
        expect_status(zova_statement_column_int64(&(zova_statement_column_int64_request){
                          .statement = mem_count_statement,
                          .index = 0,
                          .out_value = &mem_row_count,
                      }),
                      ZOVA_OK,
                      "read in-memory backup count");
        if (mem_row_count != 1) {
            fprintf(stderr, "in-memory backup: wrong row count\n");
            return 1;
        }
        expect_status(zova_statement_finalize(mem_count_statement), ZOVA_OK, "finalize in-memory backup count");
        expect_status(zova_database_close(mem_copy), ZOVA_OK, "close in-memory backup copy");

        zova_database *restored = NULL;
        expect_status(zova_database_restore_to_memory(&(zova_database_restore_to_memory_request){
                          .source_path = mem_backup,
                          .flags = 0,
                          .out_db = &restored,
                          .out_error_message = &open_message,
                      }),
                      ZOVA_OK,
                      "restore backup into in-memory database");
        zova_message_free(&open_message);
        zova_statement *count_statement = NULL;
        expect_status(zova_database_prepare(&(zova_database_prepare_request){
                          .db = restored,
                          .sql = "select count(*) from memory_rows",
                          .out_statement = &count_statement,
                      }),
                      ZOVA_OK,
                      "prepare in-memory restore count");
        zova_step_result count_step = ZOVA_STEP_DONE;
        expect_status(zova_statement_step(&(zova_statement_step_request){
                          .statement = count_statement,
                          .out_result = &count_step,
                      }),
                      ZOVA_OK,
                      "step in-memory restore count");
        int64_t row_count = 0;
        expect_status(zova_statement_column_int64(&(zova_statement_column_int64_request){
                          .statement = count_statement,
                          .index = 0,
                          .out_value = &row_count,
                      }),
                      ZOVA_OK,
                      "read in-memory restore count");
        if (row_count != 1) {
            fprintf(stderr, "in-memory restore: wrong row count\n");
            return 1;
        }
        expect_status(zova_statement_finalize(count_statement), ZOVA_OK, "finalize in-memory restore count");
        expect_status(zova_database_close(restored), ZOVA_OK, "close in-memory restore");
        expect_status(zova_database_close(mem), ZOVA_OK, "close in-memory database");
        remove(mem_backup);
    }

    return 0;
}
