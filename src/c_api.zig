//! Exported C ABI entrypoints for Zova.
//!
//! Keep this file as the auditable C boundary: exported functions and public
//! ABI type aliases only. Implementation details live in `c_api_internal.zig`.
const internal = @import("c_api_internal.zig");
// Browser safety failures trap; they cannot print through native process I/O.
pub const panic = if (@import("builtin").os.tag == .emscripten)
    @import("std").debug.FullPanic(struct {
        fn panic(_: []const u8, _: ?usize) noreturn {
            @trap();
        }
    }.panic)
else
    @import("std").debug.FullPanic(@import("std").debug.defaultPanic);
pub const zova_database = internal.zova_database;
pub const zova_fresh_build = internal.zova_fresh_build;
pub const zova_object_writer = internal.zova_object_writer;
pub const zova_object_reader = internal.zova_object_reader;
pub const zova_statement = internal.zova_statement;
pub const zova_subscription = internal.zova_subscription;
pub const zova_status = internal.zova_status;
pub const zova_step_result = internal.zova_step_result;
pub const zova_column_type = internal.zova_column_type;
pub const zova_sql_value_type = internal.zova_sql_value_type;
pub const zova_sql_result_type = internal.zova_sql_result_type;
pub const zova_sql_value = internal.zova_sql_value;
pub const zova_sql_result = internal.zova_sql_result;
pub const zova_sql_function_call = internal.zova_sql_function_call;
pub const zova_sql_scalar_callback = internal.zova_sql_scalar_callback;
pub const zova_sql_destroy_callback = internal.zova_sql_destroy_callback;
pub const zova_object_id = internal.zova_object_id;
pub const zova_object_chunk_id = internal.zova_object_chunk_id;
pub const zova_buffer = internal.zova_buffer;
pub const zova_message = internal.zova_message;
pub const zova_text = internal.zova_text;
pub const zova_notification = internal.zova_notification;
pub const zova_object_manifest_chunk = internal.zova_object_manifest_chunk;
pub const zova_object_manifest = internal.zova_object_manifest;
pub const zova_object_storage_profile = internal.zova_object_storage_profile;
pub const zova_object_put_options = internal.zova_object_put_options;
pub const zova_vector_metric = internal.zova_vector_metric;
pub const zova_vector_element_type = internal.zova_vector_element_type;
pub const zova_vector_multi_i8_search_mode = internal.zova_vector_multi_i8_search_mode;
pub const zova_vector_multi_i8_aggregation = internal.zova_vector_multi_i8_aggregation;
pub const zova_vector_collection_options = internal.zova_vector_collection_options;
pub const zova_vector_values = internal.zova_vector_values;
pub const zova_vector = internal.zova_vector;
pub const zova_vector_search_result = internal.zova_vector_search_result;
pub const zova_vector_search_results = internal.zova_vector_search_results;
pub const zova_vector_collection_info = internal.zova_vector_collection_info;
pub const zova_vector_collection_list = internal.zova_vector_collection_list;
pub const zova_vector_input = internal.zova_vector_input;
pub const zova_graph_target_type = internal.zova_graph_target_type;
pub const zova_graph_neighbor_direction = internal.zova_graph_neighbor_direction;
pub const zova_graph_info = internal.zova_graph_info;
pub const zova_graph_list = internal.zova_graph_list;
pub const zova_extension_info = internal.zova_extension_info;
pub const zova_extension_list = internal.zova_extension_list;
pub const zova_graph_node = internal.zova_graph_node;
pub const zova_graph_edge = internal.zova_graph_edge;
pub const zova_graph_neighbor_result = internal.zova_graph_neighbor_result;
pub const zova_graph_neighbor_results = internal.zova_graph_neighbor_results;
pub const zova_graph_keyed_neighbor_result = internal.zova_graph_keyed_neighbor_result;
pub const zova_graph_keyed_neighbor_results = internal.zova_graph_keyed_neighbor_results;
pub const zova_graph_scan_cursor = internal.zova_graph_scan_cursor;
pub const zova_graph_scan_node = internal.zova_graph_scan_node;
pub const zova_graph_scan_edge = internal.zova_graph_scan_edge;
pub const zova_graph_scan_results = internal.zova_graph_scan_results;
pub const zova_graph_walk_result = internal.zova_graph_walk_result;
pub const zova_graph_walk_results = internal.zova_graph_walk_results;
pub const zova_graph_walk_profile = internal.zova_graph_walk_profile;
pub const ZOVA_OPEN_READ_ONLY = internal.ZOVA_OPEN_READ_ONLY;
pub const ZOVA_BACKUP_NO_VERIFY = internal.ZOVA_BACKUP_NO_VERIFY;
pub const ZOVA_COMPACT_NO_VERIFY = internal.ZOVA_COMPACT_NO_VERIFY;
pub const ZOVA_RESTORE_NO_VERIFY = internal.ZOVA_RESTORE_NO_VERIFY;
pub const ZOVA_MIGRATE_NO_VERIFY = internal.ZOVA_MIGRATE_NO_VERIFY;
pub const zova_format_compatibility = internal.zova_format_compatibility;
pub const zova_database_format_info = internal.zova_database_format_info;
pub const zova_database_probe_format_request = internal.zova_database_probe_format_request;
pub const zova_database_migrate_request = internal.zova_database_migrate_request;
pub const ZOVA_SQL_FUNCTION_DETERMINISTIC = internal.ZOVA_SQL_FUNCTION_DETERMINISTIC;
pub const ZOVA_SQL_FUNCTION_DIRECT_ONLY = internal.ZOVA_SQL_FUNCTION_DIRECT_ONLY;
pub const ZOVA_SQL_FUNCTION_INNOCUOUS = internal.ZOVA_SQL_FUNCTION_INNOCUOUS;
pub const zova_database_open_request = internal.zova_database_open_request;
pub const zova_database_create_memory_request = internal.zova_database_create_memory_request;
pub const zova_database_restore_to_memory_request = internal.zova_database_restore_to_memory_request;
pub const zova_database_create_options_request = internal.zova_database_create_options_request;
pub const zova_database_open_options_request = internal.zova_database_open_options_request;
pub const zova_database_open_extensions_request = internal.zova_database_open_extensions_request;
pub const zova_extension_bundle_request = internal.zova_extension_bundle_request;
pub const zova_extension_bundle_untrust_request = internal.zova_extension_bundle_untrust_request;
pub const zova_convert_sqlite_to_zova_request = internal.zova_convert_sqlite_to_zova_request;
pub const zova_database_backup_request = internal.zova_database_backup_request;
pub const zova_database_compact_request = internal.zova_database_compact_request;
pub const zova_database_restore_request = internal.zova_database_restore_request;
pub const zova_database_exec_request = internal.zova_database_exec_request;
pub const zova_sql_function_register_request = internal.zova_sql_function_register_request;
pub const zova_database_simple_request = internal.zova_database_simple_request;
pub const zova_database_savepoint_request = internal.zova_database_savepoint_request;
pub const zova_database_busy_timeout_request = internal.zova_database_busy_timeout_request;
pub const zova_database_last_insert_rowid_request = internal.zova_database_last_insert_rowid_request;
pub const zova_database_changes_request = internal.zova_database_changes_request;
pub const zova_database_total_changes_request = internal.zova_database_total_changes_request;
pub const zova_database_notify_request = internal.zova_database_notify_request;
pub const zova_database_listen_request = internal.zova_database_listen_request;
pub const zova_subscription_try_receive_request = internal.zova_subscription_try_receive_request;
pub const zova_database_prepare_request = internal.zova_database_prepare_request;
pub const zova_statement_step_request = internal.zova_statement_step_request;
pub const zova_statement_bind_null_request = internal.zova_statement_bind_null_request;
pub const zova_statement_bind_int64_request = internal.zova_statement_bind_int64_request;
pub const zova_statement_bind_double_request = internal.zova_statement_bind_double_request;
pub const zova_statement_bind_text_request = internal.zova_statement_bind_text_request;
pub const zova_statement_bind_blob_request = internal.zova_statement_bind_blob_request;
pub const zova_statement_parameter_count_request = internal.zova_statement_parameter_count_request;
pub const zova_statement_parameter_index_request = internal.zova_statement_parameter_index_request;
pub const zova_statement_column_count_request = internal.zova_statement_column_count_request;
pub const zova_statement_column_name_request = internal.zova_statement_column_name_request;
pub const zova_statement_column_type_request = internal.zova_statement_column_type_request;
pub const zova_statement_column_int64_request = internal.zova_statement_column_int64_request;
pub const zova_statement_column_double_request = internal.zova_statement_column_double_request;
pub const zova_statement_column_text_request = internal.zova_statement_column_text_request;
pub const zova_statement_column_blob_request = internal.zova_statement_column_blob_request;
pub const zova_object_put_request = internal.zova_object_put_request;
pub const zova_object_put_with_options_request = internal.zova_object_put_with_options_request;
pub const zova_object_get_request = internal.zova_object_get_request;
pub const zova_object_read_range_request = internal.zova_object_read_range_request;
pub const zova_object_exists_request = internal.zova_object_exists_request;
pub const zova_object_size_request = internal.zova_object_size_request;
pub const zova_object_chunk_count_request = internal.zova_object_chunk_count_request;
pub const zova_object_delete_request = internal.zova_object_delete_request;
pub const zova_object_manifest_get_request = internal.zova_object_manifest_get_request;
pub const zova_object_chunk_get_request = internal.zova_object_chunk_get_request;
pub const zova_object_chunk_put_request = internal.zova_object_chunk_put_request;
pub const zova_object_chunk_put_with_options_request = internal.zova_object_chunk_put_with_options_request;
pub const zova_object_chunk_delete_request = internal.zova_object_chunk_delete_request;
pub const zova_object_assemble_from_chunks_request = internal.zova_object_assemble_from_chunks_request;
pub const zova_object_assemble_from_chunks_with_options_request = internal.zova_object_assemble_from_chunks_with_options_request;
pub const zova_object_writer_create_request = internal.zova_object_writer_create_request;
pub const zova_object_writer_create_with_options_request = internal.zova_object_writer_create_with_options_request;
pub const zova_object_writer_write_request = internal.zova_object_writer_write_request;
pub const zova_object_writer_finish_request = internal.zova_object_writer_finish_request;
pub const zova_object_writer_cancel_request = internal.zova_object_writer_cancel_request;
pub const zova_object_reader_create_request = internal.zova_object_reader_create_request;
pub const zova_object_reader_read_request = internal.zova_object_reader_read_request;
pub const zova_object_reader_destroy_request = internal.zova_object_reader_destroy_request;
pub const zova_kv_bytes = internal.zova_kv_bytes;
pub const zova_kv_get_result = internal.zova_kv_get_result;
pub const zova_kv_get_many_results = internal.zova_kv_get_many_results;
pub const zova_kv_put_entry = internal.zova_kv_put_entry;
pub const zova_kv_get_request = internal.zova_kv_get_request;
pub const zova_kv_get_many_request = internal.zova_kv_get_many_request;
pub const zova_kv_put_request = internal.zova_kv_put_request;
pub const zova_kv_put_many_request = internal.zova_kv_put_many_request;
pub const zova_kv_delete_request = internal.zova_kv_delete_request;
pub const zova_kv_delete_many_request = internal.zova_kv_delete_many_request;
pub const zova_kv_count_request = internal.zova_kv_count_request;
pub const zova_kv_clear_namespace_request = internal.zova_kv_clear_namespace_request;
pub const zova_vector_collection_create_request = internal.zova_vector_collection_create_request;
pub const zova_vector_collection_exists_request = internal.zova_vector_collection_exists_request;
pub const zova_vector_put_request = internal.zova_vector_put_request;
pub const zova_vector_get_request = internal.zova_vector_get_request;
pub const zova_vector_exists_request = internal.zova_vector_exists_request;
pub const zova_vector_delete_request = internal.zova_vector_delete_request;
pub const zova_vector_search_request = internal.zova_vector_search_request;
pub const zova_vector_search_in_request = internal.zova_vector_search_in_request;
pub const zova_vector_search_multi_i8_request = internal.zova_vector_search_multi_i8_request;
pub const zova_vector_collection_info_get_request = internal.zova_vector_collection_info_get_request;
pub const zova_vector_collections_list_request = internal.zova_vector_collections_list_request;
pub const zova_vector_put_many_request = internal.zova_vector_put_many_request;
pub const zova_vector_delete_many_request = internal.zova_vector_delete_many_request;
pub const zova_vector_collection_delete_request = internal.zova_vector_collection_delete_request;
pub const zova_vector_search_within_request = internal.zova_vector_search_within_request;
pub const zova_vector_search_in_within_request = internal.zova_vector_search_in_within_request;
pub const zova_vector_search_by_id_request = internal.zova_vector_search_by_id_request;
pub const zova_vector_search_by_id_in_request = internal.zova_vector_search_by_id_in_request;
pub const zova_vector_search_by_id_within_request = internal.zova_vector_search_by_id_within_request;
pub const zova_vector_search_by_id_in_within_request = internal.zova_vector_search_by_id_in_within_request;
pub const zova_graph_create_request = internal.zova_graph_create_request;
pub const zova_graph_exists_request = internal.zova_graph_exists_request;
pub const zova_graph_info_get_request = internal.zova_graph_info_get_request;
pub const zova_graph_list_request = internal.zova_graph_list_request;
pub const zova_database_extension_request = internal.zova_database_extension_request;
pub const zova_database_extension_info_request = internal.zova_database_extension_info_request;
pub const zova_database_extension_list_request = internal.zova_database_extension_list_request;
pub const zova_graph_delete_request = internal.zova_graph_delete_request;
pub const zova_graph_node_put_request = internal.zova_graph_node_put_request;
pub const zova_graph_node_input = internal.zova_graph_node_input;
pub const zova_graph_node_put_many_request = internal.zova_graph_node_put_many_request;
pub const zova_graph_node_put_many_keyed_request = internal.zova_graph_node_put_many_keyed_request;
pub const zova_graph_fresh_node_input = internal.zova_graph_fresh_node_input;
pub const zova_graph_fresh_edge_input = internal.zova_graph_fresh_edge_input;
pub const zova_graph_fresh_edge_payload_input = internal.zova_graph_fresh_edge_payload_input;
pub const zova_graph_build_fresh_keyed_request = internal.zova_graph_build_fresh_keyed_request;
pub const zova_graph_build_fresh_prepared_keyed_with_payloads_request = internal.zova_graph_build_fresh_prepared_keyed_with_payloads_request;
pub const zova_graph_node_get_request = internal.zova_graph_node_get_request;
pub const zova_graph_node_exists_request = internal.zova_graph_node_exists_request;
pub const zova_graph_node_delete_request = internal.zova_graph_node_delete_request;
pub const zova_graph_node_delete_many_request = internal.zova_graph_node_delete_many_request;
pub const zova_graph_edge_put_request = internal.zova_graph_edge_put_request;
pub const zova_graph_edge_input = internal.zova_graph_edge_input;
pub const zova_graph_edge_put_many_request = internal.zova_graph_edge_put_many_request;
pub const zova_graph_edge_put_many_keyed_request = internal.zova_graph_edge_put_many_keyed_request;
pub const zova_graph_edge_delete_many_request = internal.zova_graph_edge_delete_many_request;
pub const zova_graph_edge_get_request = internal.zova_graph_edge_get_request;
pub const zova_graph_edge_exists_request = internal.zova_graph_edge_exists_request;
pub const zova_graph_edge_delete_request = internal.zova_graph_edge_delete_request;
pub const zova_graph_neighbors_request = internal.zova_graph_neighbors_request;
pub const zova_graph_neighbors_keyed_request = internal.zova_graph_neighbors_keyed_request;
pub const zova_graph_keyed_node_result = internal.zova_graph_keyed_node_result;
pub const zova_graph_keyed_node_results = internal.zova_graph_keyed_node_results;
pub const zova_graph_keyed_edge_result = internal.zova_graph_keyed_edge_result;
pub const zova_graph_keyed_edge_results = internal.zova_graph_keyed_edge_results;
pub const zova_graph_nodes_get_many_keyed_request = internal.zova_graph_nodes_get_many_keyed_request;
pub const zova_graph_edges_get_many_keyed_request = internal.zova_graph_edges_get_many_keyed_request;
pub const zova_graph_edge_payload_result = internal.zova_graph_edge_payload_result;
pub const zova_graph_edge_payload_results = internal.zova_graph_edge_payload_results;
pub const zova_graph_edge_payload_get_many_request = internal.zova_graph_edge_payload_get_many_request;
pub const zova_graph_edge_payload_replacement = internal.zova_graph_edge_payload_replacement;
pub const zova_graph_edge_payload_replace_many_request = internal.zova_graph_edge_payload_replace_many_request;
pub const zova_fresh_build_profile = internal.zova_fresh_build_profile;
pub const zova_fresh_value = internal.zova_fresh_value;
pub const zova_fresh_build_begin_request = internal.zova_fresh_build_begin_request;
pub const zova_fresh_build_rows_request = internal.zova_fresh_build_rows_request;
pub const zova_fresh_build_graph_request = internal.zova_fresh_build_graph_request;
pub const zova_fresh_build_vectors_request = internal.zova_fresh_build_vectors_request;
pub const zova_fresh_build_finish_request = internal.zova_fresh_build_finish_request;
pub const zova_graph_degree_request = internal.zova_graph_degree_request;
pub const zova_graph_degree_many_keyed_request = internal.zova_graph_degree_many_keyed_request;
pub const zova_graph_scan_request = internal.zova_graph_scan_request;
pub const zova_graph_walk_request = internal.zova_graph_walk_request;
pub const zova_graph_walk_direction_request = internal.zova_graph_walk_direction_request;
pub const zova_graph_walk_direction_profiled_request = internal.zova_graph_walk_direction_profiled_request;

pub fn zova_abi_version_major() callconv(.c) u32 {
    return internal.zova_abi_version_major();
}

pub fn zova_abi_version_minor() callconv(.c) u32 {
    return internal.zova_abi_version_minor();
}

pub fn zova_abi_version_patch() callconv(.c) u32 {
    return internal.zova_abi_version_patch();
}

pub fn zova_abi_version_string() callconv(.c) [*:0]const u8 {
    return internal.zova_abi_version_string();
}

pub fn zova_status_name(status: c_int) callconv(.c) [*:0]const u8 {
    return internal.zova_status_name(status);
}

pub fn zova_buffer_free(buffer: ?*zova_buffer) callconv(.c) void {
    return internal.zova_buffer_free(buffer);
}

pub fn zova_kv_get_result_free(result: ?*zova_kv_get_result) callconv(.c) void {
    return internal.zova_kv_get_result_free(result);
}

pub fn zova_kv_get_many_results_free(results: ?*zova_kv_get_many_results) callconv(.c) void {
    return internal.zova_kv_get_many_results_free(results);
}

pub fn zova_message_free(message: ?*zova_message) callconv(.c) void {
    return internal.zova_message_free(message);
}

pub fn zova_text_free(text: ?*zova_text) callconv(.c) void {
    return internal.zova_text_free(text);
}

pub fn zova_notification_free(notification: ?*zova_notification) callconv(.c) void {
    return internal.zova_notification_free(notification);
}

pub fn zova_object_manifest_free(manifest: ?*zova_object_manifest) callconv(.c) void {
    return internal.zova_object_manifest_free(manifest);
}

pub fn zova_vector_free(vector: ?*zova_vector) callconv(.c) void {
    return internal.zova_vector_free(vector);
}

pub fn zova_vector_search_results_free(results: ?*zova_vector_search_results) callconv(.c) void {
    return internal.zova_vector_search_results_free(results);
}

pub fn zova_vector_collection_info_free(info: ?*zova_vector_collection_info) callconv(.c) void {
    return internal.zova_vector_collection_info_free(info);
}

pub fn zova_vector_collection_list_free(list: ?*zova_vector_collection_list) callconv(.c) void {
    return internal.zova_vector_collection_list_free(list);
}

pub fn zova_graph_info_free(info: ?*zova_graph_info) callconv(.c) void {
    return internal.zova_graph_info_free(info);
}

pub fn zova_graph_list_free(list: ?*zova_graph_list) callconv(.c) void {
    return internal.zova_graph_list_free(list);
}

pub fn zova_extension_info_free(info: ?*zova_extension_info) callconv(.c) void {
    return internal.zova_extension_info_free(info);
}

pub fn zova_extension_list_free(list: ?*zova_extension_list) callconv(.c) void {
    return internal.zova_extension_list_free(list);
}

pub fn zova_graph_node_free(node: ?*zova_graph_node) callconv(.c) void {
    return internal.zova_graph_node_free(node);
}

pub fn zova_graph_edge_free(edge: ?*zova_graph_edge) callconv(.c) void {
    return internal.zova_graph_edge_free(edge);
}

pub fn zova_graph_neighbor_results_free(results: ?*zova_graph_neighbor_results) callconv(.c) void {
    return internal.zova_graph_neighbor_results_free(results);
}

pub fn zova_graph_keyed_neighbor_results_free(results: ?*zova_graph_keyed_neighbor_results) callconv(.c) void {
    return internal.zova_graph_keyed_neighbor_results_free(results);
}
pub fn zova_graph_keyed_node_results_free(results: ?*zova_graph_keyed_node_results) callconv(.c) void {
    return internal.zova_graph_keyed_node_results_free(results);
}
pub fn zova_graph_keyed_edge_results_free(results: ?*zova_graph_keyed_edge_results) callconv(.c) void {
    return internal.zova_graph_keyed_edge_results_free(results);
}
pub fn zova_graph_edge_payload_results_free(results: ?*zova_graph_edge_payload_results) callconv(.c) void {
    return internal.zova_graph_edge_payload_results_free(results);
}

pub fn zova_fresh_build_begin(request: ?*const zova_fresh_build_begin_request) callconv(.c) zova_status {
    return internal.zova_fresh_build_begin(request);
}
pub fn zova_fresh_build_table_rows(request: ?*const zova_fresh_build_rows_request) callconv(.c) zova_status {
    return internal.zova_fresh_build_table_rows(request);
}
pub fn zova_fresh_build_fts_rows(request: ?*const zova_fresh_build_rows_request) callconv(.c) zova_status {
    return internal.zova_fresh_build_fts_rows(request);
}
pub fn zova_fresh_build_graph(request: ?*const zova_fresh_build_graph_request) callconv(.c) zova_status {
    return internal.zova_fresh_build_graph(request);
}
pub fn zova_fresh_build_vectors(request: ?*const zova_fresh_build_vectors_request) callconv(.c) zova_status {
    return internal.zova_fresh_build_vectors(request);
}
pub fn zova_fresh_build_finish(request: ?*const zova_fresh_build_finish_request) callconv(.c) zova_status {
    return internal.zova_fresh_build_finish(request);
}
pub fn zova_fresh_build_abort(build: ?*zova_fresh_build) callconv(.c) zova_status {
    return internal.zova_fresh_build_abort(build);
}
pub fn zova_fresh_build_destroy(build: ?*zova_fresh_build) callconv(.c) void {
    return internal.zova_fresh_build_destroy(build);
}

pub fn zova_graph_scan_results_free(results: ?*zova_graph_scan_results) callconv(.c) void {
    return internal.zova_graph_scan_results_free(results);
}

pub fn zova_graph_walk_results_free(results: ?*zova_graph_walk_results) callconv(.c) void {
    return internal.zova_graph_walk_results_free(results);
}

pub fn zova_database_create(request: ?*const zova_database_open_request) callconv(.c) zova_status {
    return internal.zova_database_create(request);
}

pub fn zova_database_create_memory(request: ?*const zova_database_create_memory_request) callconv(.c) zova_status {
    return internal.zova_database_create_memory(request);
}

pub fn zova_database_restore_to_memory(request: ?*const zova_database_restore_to_memory_request) callconv(.c) zova_status {
    return internal.zova_database_restore_to_memory(request);
}

pub fn zova_database_create_with_options(request: ?*const zova_database_create_options_request) callconv(.c) zova_status {
    return internal.zova_database_create_with_options(request);
}

pub fn zova_database_create_with_extensions(request: ?*const zova_database_open_extensions_request) callconv(.c) zova_status {
    return internal.zova_database_create_with_extensions(request);
}

pub fn zova_database_open(request: ?*const zova_database_open_request) callconv(.c) zova_status {
    return internal.zova_database_open(request);
}

pub fn zova_database_open_with_options(request: ?*const zova_database_open_options_request) callconv(.c) zova_status {
    return internal.zova_database_open_with_options(request);
}

pub fn zova_database_open_with_extensions(request: ?*const zova_database_open_extensions_request) callconv(.c) zova_status {
    return internal.zova_database_open_with_extensions(request);
}

pub fn zova_extension_bundle_verify(request: ?*const zova_extension_bundle_request) callconv(.c) zova_status {
    return internal.zova_extension_bundle_verify(request);
}

pub fn zova_extension_bundle_trust(request: ?*const zova_extension_bundle_request) callconv(.c) zova_status {
    return internal.zova_extension_bundle_trust(request);
}

pub fn zova_extension_bundle_untrust(request: ?*const zova_extension_bundle_untrust_request) callconv(.c) zova_status {
    return internal.zova_extension_bundle_untrust(request);
}

pub fn zova_database_close(db: ?*zova_database) callconv(.c) zova_status {
    return internal.zova_database_close(db);
}

pub fn zova_database_exec(request: ?*const zova_database_exec_request) callconv(.c) zova_status {
    return internal.zova_database_exec(request);
}

pub fn zova_database_register_function(request: ?*const zova_sql_function_register_request) callconv(.c) zova_status {
    return internal.zova_database_register_function(request);
}

pub fn zova_database_begin(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_begin(request);
}

pub fn zova_database_begin_immediate(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_begin_immediate(request);
}

pub fn zova_database_commit(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_commit(request);
}

pub fn zova_database_rollback(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_rollback(request);
}

pub fn zova_database_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return internal.zova_database_savepoint(request);
}

pub fn zova_database_rollback_to_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return internal.zova_database_rollback_to_savepoint(request);
}

pub fn zova_database_release_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return internal.zova_database_release_savepoint(request);
}

pub fn zova_database_vacuum(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_vacuum(request);
}

pub fn zova_database_backup(request: ?*const zova_database_backup_request) callconv(.c) zova_status {
    return internal.zova_database_backup(request);
}

pub fn zova_database_compact(request: ?*const zova_database_compact_request) callconv(.c) zova_status {
    return internal.zova_database_compact(request);
}

pub fn zova_database_set_busy_timeout(request: ?*const zova_database_busy_timeout_request) callconv(.c) zova_status {
    return internal.zova_database_set_busy_timeout(request);
}

pub fn zova_database_last_insert_rowid(request: ?*const zova_database_last_insert_rowid_request) callconv(.c) zova_status {
    return internal.zova_database_last_insert_rowid(request);
}

pub fn zova_database_changes(request: ?*const zova_database_changes_request) callconv(.c) zova_status {
    return internal.zova_database_changes(request);
}

pub fn zova_database_total_changes(request: ?*const zova_database_total_changes_request) callconv(.c) zova_status {
    return internal.zova_database_total_changes(request);
}

pub fn zova_database_notify(request: ?*const zova_database_notify_request) callconv(.c) zova_status {
    return internal.zova_database_notify(request);
}

pub fn zova_database_listen(request: ?*const zova_database_listen_request) callconv(.c) zova_status {
    return internal.zova_database_listen(request);
}

pub fn zova_subscription_try_receive(request: ?*const zova_subscription_try_receive_request) callconv(.c) zova_status {
    return internal.zova_subscription_try_receive(request);
}

pub fn zova_subscription_close(subscription: ?*zova_subscription) callconv(.c) zova_status {
    return internal.zova_subscription_close(subscription);
}

pub fn zova_database_prepare(request: ?*const zova_database_prepare_request) callconv(.c) zova_status {
    return internal.zova_database_prepare(request);
}

pub fn zova_statement_finalize(statement: ?*zova_statement) callconv(.c) zova_status {
    return internal.zova_statement_finalize(statement);
}

pub fn zova_statement_step(request: ?*const zova_statement_step_request) callconv(.c) zova_status {
    return internal.zova_statement_step(request);
}

pub fn zova_statement_reset(statement: ?*zova_statement) callconv(.c) zova_status {
    return internal.zova_statement_reset(statement);
}

pub fn zova_statement_clear_bindings(statement: ?*zova_statement) callconv(.c) zova_status {
    return internal.zova_statement_clear_bindings(statement);
}

pub fn zova_statement_bind_null(request: ?*const zova_statement_bind_null_request) callconv(.c) zova_status {
    return internal.zova_statement_bind_null(request);
}

pub fn zova_statement_bind_int64(request: ?*const zova_statement_bind_int64_request) callconv(.c) zova_status {
    return internal.zova_statement_bind_int64(request);
}

pub fn zova_statement_bind_double(request: ?*const zova_statement_bind_double_request) callconv(.c) zova_status {
    return internal.zova_statement_bind_double(request);
}

pub fn zova_statement_bind_text(request: ?*const zova_statement_bind_text_request) callconv(.c) zova_status {
    return internal.zova_statement_bind_text(request);
}

pub fn zova_statement_bind_blob(request: ?*const zova_statement_bind_blob_request) callconv(.c) zova_status {
    return internal.zova_statement_bind_blob(request);
}

pub fn zova_statement_parameter_count(request: ?*const zova_statement_parameter_count_request) callconv(.c) zova_status {
    return internal.zova_statement_parameter_count(request);
}

pub fn zova_statement_parameter_index(request: ?*const zova_statement_parameter_index_request) callconv(.c) zova_status {
    return internal.zova_statement_parameter_index(request);
}

pub fn zova_statement_column_count(request: ?*const zova_statement_column_count_request) callconv(.c) zova_status {
    return internal.zova_statement_column_count(request);
}

pub fn zova_statement_column_name(request: ?*const zova_statement_column_name_request) callconv(.c) zova_status {
    return internal.zova_statement_column_name(request);
}

pub fn zova_statement_column_type(request: ?*const zova_statement_column_type_request) callconv(.c) zova_status {
    return internal.zova_statement_column_type(request);
}

pub fn zova_statement_column_int64(request: ?*const zova_statement_column_int64_request) callconv(.c) zova_status {
    return internal.zova_statement_column_int64(request);
}

pub fn zova_statement_column_double(request: ?*const zova_statement_column_double_request) callconv(.c) zova_status {
    return internal.zova_statement_column_double(request);
}

pub fn zova_statement_column_text(request: ?*const zova_statement_column_text_request) callconv(.c) zova_status {
    return internal.zova_statement_column_text(request);
}

pub fn zova_statement_column_blob(request: ?*const zova_statement_column_blob_request) callconv(.c) zova_status {
    return internal.zova_statement_column_blob(request);
}

pub fn zova_database_last_error_message(db: ?*zova_database) callconv(.c) [*:0]const u8 {
    return internal.zova_database_last_error_message(db);
}

pub fn zova_convert_sqlite_to_zova(request: ?*const zova_convert_sqlite_to_zova_request) callconv(.c) zova_status {
    return internal.zova_convert_sqlite_to_zova(request);
}

pub fn zova_database_restore(request: ?*const zova_database_restore_request) callconv(.c) zova_status {
    return internal.zova_database_restore(request);
}

pub fn zova_database_probe_format(request: ?*const zova_database_probe_format_request) callconv(.c) zova_status {
    return internal.zova_database_probe_format(request);
}

pub fn zova_database_migrate(request: ?*const zova_database_migrate_request) callconv(.c) zova_status {
    return internal.zova_database_migrate(request);
}

pub fn zova_object_id_from_bytes(data: ?[*]const u8, len: usize, out_id: ?*zova_object_id) callconv(.c) zova_status {
    return internal.zova_object_id_from_bytes(data, len, out_id);
}

pub fn zova_object_chunk_id_from_bytes(
    data: ?[*]const u8,
    len: usize,
    out_id: ?*zova_object_chunk_id,
) callconv(.c) zova_status {
    return internal.zova_object_chunk_id_from_bytes(data, len, out_id);
}

pub fn zova_object_put(request: ?*const zova_object_put_request) callconv(.c) zova_status {
    return internal.zova_object_put(request);
}

pub fn zova_object_put_with_options(
    request: ?*const zova_object_put_with_options_request,
) callconv(.c) zova_status {
    return internal.zova_object_put_with_options(request);
}

pub fn zova_object_get(request: ?*const zova_object_get_request) callconv(.c) zova_status {
    return internal.zova_object_get(request);
}

pub fn zova_object_read_range(request: ?*const zova_object_read_range_request) callconv(.c) zova_status {
    return internal.zova_object_read_range(request);
}

pub fn zova_object_delete(request: ?*const zova_object_delete_request) callconv(.c) zova_status {
    return internal.zova_object_delete(request);
}

pub fn zova_object_exists(request: ?*const zova_object_exists_request) callconv(.c) zova_status {
    return internal.zova_object_exists(request);
}

pub fn zova_object_size(request: ?*const zova_object_size_request) callconv(.c) zova_status {
    return internal.zova_object_size(request);
}

pub fn zova_object_chunk_count(request: ?*const zova_object_chunk_count_request) callconv(.c) zova_status {
    return internal.zova_object_chunk_count(request);
}

pub fn zova_kv_get(request: ?*const zova_kv_get_request) callconv(.c) zova_status {
    return internal.zova_kv_get(request);
}

pub fn zova_kv_get_many(request: ?*const zova_kv_get_many_request) callconv(.c) zova_status {
    return internal.zova_kv_get_many(request);
}

pub fn zova_kv_put(request: ?*const zova_kv_put_request) callconv(.c) zova_status {
    return internal.zova_kv_put(request);
}

pub fn zova_kv_put_many(request: ?*const zova_kv_put_many_request) callconv(.c) zova_status {
    return internal.zova_kv_put_many(request);
}

pub fn zova_kv_delete(request: ?*const zova_kv_delete_request) callconv(.c) zova_status {
    return internal.zova_kv_delete(request);
}

pub fn zova_kv_delete_many(request: ?*const zova_kv_delete_many_request) callconv(.c) zova_status {
    return internal.zova_kv_delete_many(request);
}

pub fn zova_kv_count(request: ?*const zova_kv_count_request) callconv(.c) zova_status {
    return internal.zova_kv_count(request);
}

pub fn zova_kv_clear_namespace(request: ?*const zova_kv_clear_namespace_request) callconv(.c) zova_status {
    return internal.zova_kv_clear_namespace(request);
}

pub fn zova_object_manifest_get(request: ?*const zova_object_manifest_get_request) callconv(.c) zova_status {
    return internal.zova_object_manifest_get(request);
}

pub fn zova_object_chunk_get(request: ?*const zova_object_chunk_get_request) callconv(.c) zova_status {
    return internal.zova_object_chunk_get(request);
}

pub fn zova_object_chunk_put(request: ?*const zova_object_chunk_put_request) callconv(.c) zova_status {
    return internal.zova_object_chunk_put(request);
}

pub fn zova_object_chunk_put_with_options(
    request: ?*const zova_object_chunk_put_with_options_request,
) callconv(.c) zova_status {
    return internal.zova_object_chunk_put_with_options(request);
}

pub fn zova_object_chunk_delete(request: ?*const zova_object_chunk_delete_request) callconv(.c) zova_status {
    return internal.zova_object_chunk_delete(request);
}

pub fn zova_object_assemble_from_chunks(
    request: ?*const zova_object_assemble_from_chunks_request,
) callconv(.c) zova_status {
    return internal.zova_object_assemble_from_chunks(request);
}

pub fn zova_object_assemble_from_chunks_with_options(
    request: ?*const zova_object_assemble_from_chunks_with_options_request,
) callconv(.c) zova_status {
    return internal.zova_object_assemble_from_chunks_with_options(request);
}

pub fn zova_object_writer_create(request: ?*const zova_object_writer_create_request) callconv(.c) zova_status {
    return internal.zova_object_writer_create(request);
}

pub fn zova_object_writer_create_with_options(
    request: ?*const zova_object_writer_create_with_options_request,
) callconv(.c) zova_status {
    return internal.zova_object_writer_create_with_options(request);
}

pub fn zova_object_writer_write(request: ?*const zova_object_writer_write_request) callconv(.c) zova_status {
    return internal.zova_object_writer_write(request);
}

pub fn zova_object_writer_finish(request: ?*const zova_object_writer_finish_request) callconv(.c) zova_status {
    return internal.zova_object_writer_finish(request);
}

pub fn zova_object_writer_cancel(request: ?*const zova_object_writer_cancel_request) callconv(.c) zova_status {
    return internal.zova_object_writer_cancel(request);
}

pub fn zova_object_writer_destroy(writer: ?*zova_object_writer) callconv(.c) zova_status {
    return internal.zova_object_writer_destroy(writer);
}

pub fn zova_object_reader_create(
    request: ?*const zova_object_reader_create_request,
) callconv(.c) zova_status {
    return internal.zova_object_reader_create(request);
}

pub fn zova_object_reader_read(
    request: ?*const zova_object_reader_read_request,
) callconv(.c) zova_status {
    return internal.zova_object_reader_read(request);
}

pub fn zova_object_reader_destroy(
    request: ?*const zova_object_reader_destroy_request,
) callconv(.c) zova_status {
    return internal.zova_object_reader_destroy(request);
}

pub fn zova_vector_collection_create(request: ?*const zova_vector_collection_create_request) callconv(.c) zova_status {
    return internal.zova_vector_collection_create(request);
}

pub fn zova_vector_collection_exists(request: ?*const zova_vector_collection_exists_request) callconv(.c) zova_status {
    return internal.zova_vector_collection_exists(request);
}

pub fn zova_vector_put(request: ?*const zova_vector_put_request) callconv(.c) zova_status {
    return internal.zova_vector_put(request);
}

pub fn zova_vector_get(request: ?*const zova_vector_get_request) callconv(.c) zova_status {
    return internal.zova_vector_get(request);
}

pub fn zova_vector_exists(request: ?*const zova_vector_exists_request) callconv(.c) zova_status {
    return internal.zova_vector_exists(request);
}

pub fn zova_vector_delete(request: ?*const zova_vector_delete_request) callconv(.c) zova_status {
    return internal.zova_vector_delete(request);
}

pub fn zova_vector_search(request: ?*const zova_vector_search_request) callconv(.c) zova_status {
    return internal.zova_vector_search(request);
}

pub fn zova_vector_search_in(request: ?*const zova_vector_search_in_request) callconv(.c) zova_status {
    return internal.zova_vector_search_in(request);
}

pub fn zova_vector_search_multi_i8(request: ?*const zova_vector_search_multi_i8_request) callconv(.c) zova_status {
    return internal.zova_vector_search_multi_i8(request);
}

pub fn zova_vector_collection_info_get(request: ?*const zova_vector_collection_info_get_request) callconv(.c) zova_status {
    return internal.zova_vector_collection_info_get(request);
}

pub fn zova_vector_collections_list(request: ?*const zova_vector_collections_list_request) callconv(.c) zova_status {
    return internal.zova_vector_collections_list(request);
}

pub fn zova_vector_put_many(request: ?*const zova_vector_put_many_request) callconv(.c) zova_status {
    return internal.zova_vector_put_many(request);
}

pub fn zova_vector_delete_many(request: ?*const zova_vector_delete_many_request) callconv(.c) zova_status {
    return internal.zova_vector_delete_many(request);
}

pub fn zova_vector_collection_delete(request: ?*const zova_vector_collection_delete_request) callconv(.c) zova_status {
    return internal.zova_vector_collection_delete(request);
}

pub fn zova_vector_search_within(request: ?*const zova_vector_search_within_request) callconv(.c) zova_status {
    return internal.zova_vector_search_within(request);
}

pub fn zova_vector_search_in_within(request: ?*const zova_vector_search_in_within_request) callconv(.c) zova_status {
    return internal.zova_vector_search_in_within(request);
}

pub fn zova_vector_search_by_id(request: ?*const zova_vector_search_by_id_request) callconv(.c) zova_status {
    return internal.zova_vector_search_by_id(request);
}

pub fn zova_vector_search_by_id_in(request: ?*const zova_vector_search_by_id_in_request) callconv(.c) zova_status {
    return internal.zova_vector_search_by_id_in(request);
}

pub fn zova_vector_search_by_id_within(request: ?*const zova_vector_search_by_id_within_request) callconv(.c) zova_status {
    return internal.zova_vector_search_by_id_within(request);
}

pub fn zova_vector_search_by_id_in_within(request: ?*const zova_vector_search_by_id_in_within_request) callconv(.c) zova_status {
    return internal.zova_vector_search_by_id_in_within(request);
}

pub fn zova_graph_create(request: ?*const zova_graph_create_request) callconv(.c) zova_status {
    return internal.zova_graph_create(request);
}

pub fn zova_graph_exists(request: ?*const zova_graph_exists_request) callconv(.c) zova_status {
    return internal.zova_graph_exists(request);
}

pub fn zova_graph_info_get(request: ?*const zova_graph_info_get_request) callconv(.c) zova_status {
    return internal.zova_graph_info_get(request);
}

pub fn zova_graphs_list(request: ?*const zova_graph_list_request) callconv(.c) zova_status {
    return internal.zova_graphs_list(request);
}

pub fn zova_database_extension_install(request: ?*const zova_database_extension_request) callconv(.c) zova_status {
    return internal.zova_database_extension_install(request);
}

pub fn zova_database_extension_list(request: ?*const zova_database_extension_list_request) callconv(.c) zova_status {
    return internal.zova_database_extension_list(request);
}

pub fn zova_database_extension_info(request: ?*const zova_database_extension_info_request) callconv(.c) zova_status {
    return internal.zova_database_extension_info(request);
}

pub fn zova_database_extension_check(request: ?*const zova_database_extension_request) callconv(.c) zova_status {
    return internal.zova_database_extension_check(request);
}

pub fn zova_database_extension_check_all(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_extension_check_all(request);
}

pub fn zova_database_extension_drop(request: ?*const zova_database_extension_request) callconv(.c) zova_status {
    return internal.zova_database_extension_drop(request);
}

pub fn zova_graph_delete(request: ?*const zova_graph_delete_request) callconv(.c) zova_status {
    return internal.zova_graph_delete(request);
}

pub fn zova_graph_node_put(request: ?*const zova_graph_node_put_request) callconv(.c) zova_status {
    return internal.zova_graph_node_put(request);
}

pub fn zova_graph_node_put_many(request: ?*const zova_graph_node_put_many_request) callconv(.c) zova_status {
    return internal.zova_graph_node_put_many(request);
}

pub fn zova_graph_node_put_many_keyed(request: ?*const zova_graph_node_put_many_keyed_request) callconv(.c) zova_status {
    return internal.zova_graph_node_put_many_keyed(request);
}

pub fn zova_graph_build_fresh_keyed(request: ?*const zova_graph_build_fresh_keyed_request) callconv(.c) zova_status {
    return internal.zova_graph_build_fresh_keyed(request);
}

pub fn zova_graph_build_fresh_prepared_keyed(request: ?*const zova_graph_build_fresh_keyed_request) callconv(.c) zova_status {
    return internal.zova_graph_build_fresh_prepared_keyed(request);
}

pub fn zova_graph_build_fresh_prepared_keyed_with_payloads(request: ?*const zova_graph_build_fresh_prepared_keyed_with_payloads_request) callconv(.c) zova_status {
    return internal.zova_graph_build_fresh_prepared_keyed_with_payloads(request);
}

pub fn zova_graph_node_get(request: ?*const zova_graph_node_get_request) callconv(.c) zova_status {
    return internal.zova_graph_node_get(request);
}

pub fn zova_graph_node_exists(request: ?*const zova_graph_node_exists_request) callconv(.c) zova_status {
    return internal.zova_graph_node_exists(request);
}

pub fn zova_graph_node_delete(request: ?*const zova_graph_node_delete_request) callconv(.c) zova_status {
    return internal.zova_graph_node_delete(request);
}

pub fn zova_graph_node_delete_many(request: ?*const zova_graph_node_delete_many_request) callconv(.c) zova_status {
    return internal.zova_graph_node_delete_many(request);
}

pub fn zova_graph_edge_put(request: ?*const zova_graph_edge_put_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_put(request);
}

pub fn zova_graph_edge_put_many(request: ?*const zova_graph_edge_put_many_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_put_many(request);
}

pub fn zova_graph_edge_put_many_keyed(request: ?*const zova_graph_edge_put_many_keyed_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_put_many_keyed(request);
}

pub fn zova_graph_edge_delete_many(request: ?*const zova_graph_edge_delete_many_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_delete_many(request);
}

pub fn zova_graph_edge_get(request: ?*const zova_graph_edge_get_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_get(request);
}

pub fn zova_graph_edge_exists(request: ?*const zova_graph_edge_exists_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_exists(request);
}

pub fn zova_graph_edge_delete(request: ?*const zova_graph_edge_delete_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_delete(request);
}

pub fn zova_graph_neighbors(request: ?*const zova_graph_neighbors_request) callconv(.c) zova_status {
    return internal.zova_graph_neighbors(request);
}

pub fn zova_graph_neighbors_keyed(request: ?*const zova_graph_neighbors_keyed_request) callconv(.c) zova_status {
    return internal.zova_graph_neighbors_keyed(request);
}
pub fn zova_graph_nodes_get_many_keyed(request: ?*const zova_graph_nodes_get_many_keyed_request) callconv(.c) zova_status {
    return internal.zova_graph_nodes_get_many_keyed(request);
}
pub fn zova_graph_edges_get_many_keyed(request: ?*const zova_graph_edges_get_many_keyed_request) callconv(.c) zova_status {
    return internal.zova_graph_edges_get_many_keyed(request);
}
pub fn zova_graph_edge_payload_get_many(request: ?*const zova_graph_edge_payload_get_many_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_payload_get_many(request);
}
pub fn zova_graph_edge_payload_replace_many(request: ?*const zova_graph_edge_payload_replace_many_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_payload_replace_many(request);
}

pub fn zova_graph_degree(request: ?*const zova_graph_degree_request) callconv(.c) zova_status {
    return internal.zova_graph_degree(request);
}

pub fn zova_graph_degree_many_keyed(request: ?*const zova_graph_degree_many_keyed_request) callconv(.c) zova_status {
    return internal.zova_graph_degree_many_keyed(request);
}

pub fn zova_graph_scan(request: ?*const zova_graph_scan_request) callconv(.c) zova_status {
    return internal.zova_graph_scan(request);
}

pub fn zova_graph_walk(request: ?*const zova_graph_walk_request) callconv(.c) zova_status {
    return internal.zova_graph_walk(request);
}

pub fn zova_graph_walk_direction(request: ?*const zova_graph_walk_direction_request) callconv(.c) zova_status {
    return internal.zova_graph_walk_direction(request);
}

pub fn zova_graph_walk_direction_profiled(request: ?*const zova_graph_walk_direction_profiled_request) callconv(.c) zova_status {
    return internal.zova_graph_walk_direction_profiled(request);
}

test {
    _ = @import("c_api_tests.zig");
}

// Native builds retain the complete C ABI. The browser spike exports only the
// lifecycle/query subset so unsupported filesystem/process paths stay unreachable.
comptime {
    @setEvalBranchQuota(10000);
    if (@import("builtin").os.tag == .emscripten) {
        if (!@import("builtin").single_threaded) @compileError("browser ABI requires -fsingle-threaded");
        if (@import("zova_build_options").enable_dynamic_extensions) @compileError("browser ABI requires dynamic extensions disabled");
        const allowed = [_][]const u8{
            "zova_database_create_memory",
            "zova_database_close",
            "zova_database_exec",
            "zova_database_prepare",
            "zova_statement_step",
            "zova_statement_column_int64",
            "zova_statement_finalize",
            "zova_message_free",
            "zova_database_last_error_message",
            "zova_status_name",
            "zova_text_free",
            "zova_buffer_free",
            "zova_statement_bind_null",
            "zova_statement_bind_int64",
            "zova_statement_bind_double",
            "zova_statement_bind_text",
            "zova_statement_bind_blob",
            "zova_statement_parameter_count",
            "zova_statement_column_count",
            "zova_statement_column_name",
            "zova_statement_column_type",
            "zova_statement_column_double",
            "zova_statement_column_text",
            "zova_statement_column_blob",
            "zova_kv_get",
            "zova_kv_put",
            "zova_kv_delete",
            "zova_kv_get_result_free",
        };
        for (allowed) |name| {
            @export(&@field(@This(), name), .{ .name = name });
        }
    } else {
        for (@typeInfo(@This()).@"struct".decls) |decl| {
            if (!@import("std").mem.startsWith(u8, decl.name, "zova_")) continue;
            const value = @field(@This(), decl.name);
            if (@typeInfo(@TypeOf(value)) == .@"fn") @export(&value, .{ .name = decl.name });
        }
    }
}
