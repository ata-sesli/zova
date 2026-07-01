//! Exported C ABI entrypoints for Zova.
//!
//! Keep this file as the auditable C boundary: exported functions and public
//! ABI type aliases only. Implementation details live in `c_api_internal.zig`.
const internal = @import("c_api_internal.zig");
pub const zova_database = internal.zova_database;
pub const zova_object_writer = internal.zova_object_writer;
pub const zova_statement = internal.zova_statement;
pub const zova_subscription = internal.zova_subscription;
pub const zova_status = internal.zova_status;
pub const zova_step_result = internal.zova_step_result;
pub const zova_column_type = internal.zova_column_type;
pub const zova_object_id = internal.zova_object_id;
pub const zova_object_chunk_id = internal.zova_object_chunk_id;
pub const zova_buffer = internal.zova_buffer;
pub const zova_message = internal.zova_message;
pub const zova_text = internal.zova_text;
pub const zova_notification = internal.zova_notification;
pub const zova_object_manifest_chunk = internal.zova_object_manifest_chunk;
pub const zova_object_manifest = internal.zova_object_manifest;
pub const zova_vector_metric = internal.zova_vector_metric;
pub const zova_vector_collection_options = internal.zova_vector_collection_options;
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
pub const zova_graph_node = internal.zova_graph_node;
pub const zova_graph_edge = internal.zova_graph_edge;
pub const zova_graph_neighbor_result = internal.zova_graph_neighbor_result;
pub const zova_graph_neighbor_results = internal.zova_graph_neighbor_results;
pub const zova_graph_walk_result = internal.zova_graph_walk_result;
pub const zova_graph_walk_results = internal.zova_graph_walk_results;
pub const ZOVA_OPEN_READ_ONLY = internal.ZOVA_OPEN_READ_ONLY;
pub const ZOVA_BACKUP_NO_VERIFY = internal.ZOVA_BACKUP_NO_VERIFY;
pub const ZOVA_COMPACT_NO_VERIFY = internal.ZOVA_COMPACT_NO_VERIFY;
pub const ZOVA_RESTORE_NO_VERIFY = internal.ZOVA_RESTORE_NO_VERIFY;
pub const zova_database_open_request = internal.zova_database_open_request;
pub const zova_database_open_options_request = internal.zova_database_open_options_request;
pub const zova_convert_sqlite_to_zova_request = internal.zova_convert_sqlite_to_zova_request;
pub const zova_database_backup_request = internal.zova_database_backup_request;
pub const zova_database_compact_request = internal.zova_database_compact_request;
pub const zova_database_restore_request = internal.zova_database_restore_request;
pub const zova_database_exec_request = internal.zova_database_exec_request;
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
pub const zova_object_get_request = internal.zova_object_get_request;
pub const zova_object_read_range_request = internal.zova_object_read_range_request;
pub const zova_object_exists_request = internal.zova_object_exists_request;
pub const zova_object_size_request = internal.zova_object_size_request;
pub const zova_object_chunk_count_request = internal.zova_object_chunk_count_request;
pub const zova_object_delete_request = internal.zova_object_delete_request;
pub const zova_object_manifest_get_request = internal.zova_object_manifest_get_request;
pub const zova_object_chunk_get_request = internal.zova_object_chunk_get_request;
pub const zova_object_chunk_put_request = internal.zova_object_chunk_put_request;
pub const zova_object_chunk_delete_request = internal.zova_object_chunk_delete_request;
pub const zova_object_assemble_from_chunks_request = internal.zova_object_assemble_from_chunks_request;
pub const zova_object_writer_create_request = internal.zova_object_writer_create_request;
pub const zova_object_writer_write_request = internal.zova_object_writer_write_request;
pub const zova_object_writer_finish_request = internal.zova_object_writer_finish_request;
pub const zova_object_writer_cancel_request = internal.zova_object_writer_cancel_request;
pub const zova_vector_collection_create_request = internal.zova_vector_collection_create_request;
pub const zova_vector_collection_exists_request = internal.zova_vector_collection_exists_request;
pub const zova_vector_put_request = internal.zova_vector_put_request;
pub const zova_vector_get_request = internal.zova_vector_get_request;
pub const zova_vector_exists_request = internal.zova_vector_exists_request;
pub const zova_vector_delete_request = internal.zova_vector_delete_request;
pub const zova_vector_search_request = internal.zova_vector_search_request;
pub const zova_vector_search_in_request = internal.zova_vector_search_in_request;
pub const zova_vector_collection_info_get_request = internal.zova_vector_collection_info_get_request;
pub const zova_vector_collections_list_request = internal.zova_vector_collections_list_request;
pub const zova_vector_put_many_request = internal.zova_vector_put_many_request;
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
pub const zova_graph_delete_request = internal.zova_graph_delete_request;
pub const zova_graph_node_put_request = internal.zova_graph_node_put_request;
pub const zova_graph_node_get_request = internal.zova_graph_node_get_request;
pub const zova_graph_node_exists_request = internal.zova_graph_node_exists_request;
pub const zova_graph_node_delete_request = internal.zova_graph_node_delete_request;
pub const zova_graph_edge_put_request = internal.zova_graph_edge_put_request;
pub const zova_graph_edge_get_request = internal.zova_graph_edge_get_request;
pub const zova_graph_edge_exists_request = internal.zova_graph_edge_exists_request;
pub const zova_graph_edge_delete_request = internal.zova_graph_edge_delete_request;
pub const zova_graph_neighbors_request = internal.zova_graph_neighbors_request;
pub const zova_graph_walk_request = internal.zova_graph_walk_request;

export fn zova_abi_version_major() callconv(.c) u32 {
    return internal.zova_abi_version_major();
}

export fn zova_abi_version_minor() callconv(.c) u32 {
    return internal.zova_abi_version_minor();
}

export fn zova_abi_version_patch() callconv(.c) u32 {
    return internal.zova_abi_version_patch();
}

export fn zova_abi_version_string() callconv(.c) [*:0]const u8 {
    return internal.zova_abi_version_string();
}

export fn zova_status_name(status: c_int) callconv(.c) [*:0]const u8 {
    return internal.zova_status_name(status);
}

export fn zova_buffer_free(buffer: ?*zova_buffer) callconv(.c) void {
    return internal.zova_buffer_free(buffer);
}

export fn zova_message_free(message: ?*zova_message) callconv(.c) void {
    return internal.zova_message_free(message);
}

export fn zova_text_free(text: ?*zova_text) callconv(.c) void {
    return internal.zova_text_free(text);
}

export fn zova_notification_free(notification: ?*zova_notification) callconv(.c) void {
    return internal.zova_notification_free(notification);
}

export fn zova_object_manifest_free(manifest: ?*zova_object_manifest) callconv(.c) void {
    return internal.zova_object_manifest_free(manifest);
}

export fn zova_vector_free(vector: ?*zova_vector) callconv(.c) void {
    return internal.zova_vector_free(vector);
}

export fn zova_vector_search_results_free(results: ?*zova_vector_search_results) callconv(.c) void {
    return internal.zova_vector_search_results_free(results);
}

export fn zova_vector_collection_info_free(info: ?*zova_vector_collection_info) callconv(.c) void {
    return internal.zova_vector_collection_info_free(info);
}

export fn zova_vector_collection_list_free(list: ?*zova_vector_collection_list) callconv(.c) void {
    return internal.zova_vector_collection_list_free(list);
}

export fn zova_graph_info_free(info: ?*zova_graph_info) callconv(.c) void {
    return internal.zova_graph_info_free(info);
}

export fn zova_graph_list_free(list: ?*zova_graph_list) callconv(.c) void {
    return internal.zova_graph_list_free(list);
}

export fn zova_graph_node_free(node: ?*zova_graph_node) callconv(.c) void {
    return internal.zova_graph_node_free(node);
}

export fn zova_graph_edge_free(edge: ?*zova_graph_edge) callconv(.c) void {
    return internal.zova_graph_edge_free(edge);
}

export fn zova_graph_neighbor_results_free(results: ?*zova_graph_neighbor_results) callconv(.c) void {
    return internal.zova_graph_neighbor_results_free(results);
}

export fn zova_graph_walk_results_free(results: ?*zova_graph_walk_results) callconv(.c) void {
    return internal.zova_graph_walk_results_free(results);
}

export fn zova_database_create(request: ?*const zova_database_open_request) callconv(.c) zova_status {
    return internal.zova_database_create(request);
}

export fn zova_database_open(request: ?*const zova_database_open_request) callconv(.c) zova_status {
    return internal.zova_database_open(request);
}

export fn zova_database_open_with_options(request: ?*const zova_database_open_options_request) callconv(.c) zova_status {
    return internal.zova_database_open_with_options(request);
}

export fn zova_database_close(db: ?*zova_database) callconv(.c) zova_status {
    return internal.zova_database_close(db);
}

export fn zova_database_exec(request: ?*const zova_database_exec_request) callconv(.c) zova_status {
    return internal.zova_database_exec(request);
}

export fn zova_database_begin(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_begin(request);
}

export fn zova_database_begin_immediate(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_begin_immediate(request);
}

export fn zova_database_commit(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_commit(request);
}

export fn zova_database_rollback(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_rollback(request);
}

export fn zova_database_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return internal.zova_database_savepoint(request);
}

export fn zova_database_rollback_to_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return internal.zova_database_rollback_to_savepoint(request);
}

export fn zova_database_release_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return internal.zova_database_release_savepoint(request);
}

export fn zova_database_vacuum(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    return internal.zova_database_vacuum(request);
}

export fn zova_database_backup(request: ?*const zova_database_backup_request) callconv(.c) zova_status {
    return internal.zova_database_backup(request);
}

export fn zova_database_compact(request: ?*const zova_database_compact_request) callconv(.c) zova_status {
    return internal.zova_database_compact(request);
}

export fn zova_database_set_busy_timeout(request: ?*const zova_database_busy_timeout_request) callconv(.c) zova_status {
    return internal.zova_database_set_busy_timeout(request);
}

export fn zova_database_last_insert_rowid(request: ?*const zova_database_last_insert_rowid_request) callconv(.c) zova_status {
    return internal.zova_database_last_insert_rowid(request);
}

export fn zova_database_changes(request: ?*const zova_database_changes_request) callconv(.c) zova_status {
    return internal.zova_database_changes(request);
}

export fn zova_database_total_changes(request: ?*const zova_database_total_changes_request) callconv(.c) zova_status {
    return internal.zova_database_total_changes(request);
}

export fn zova_database_notify(request: ?*const zova_database_notify_request) callconv(.c) zova_status {
    return internal.zova_database_notify(request);
}

export fn zova_database_listen(request: ?*const zova_database_listen_request) callconv(.c) zova_status {
    return internal.zova_database_listen(request);
}

export fn zova_subscription_try_receive(request: ?*const zova_subscription_try_receive_request) callconv(.c) zova_status {
    return internal.zova_subscription_try_receive(request);
}

export fn zova_subscription_close(subscription: ?*zova_subscription) callconv(.c) zova_status {
    return internal.zova_subscription_close(subscription);
}

export fn zova_database_prepare(request: ?*const zova_database_prepare_request) callconv(.c) zova_status {
    return internal.zova_database_prepare(request);
}

export fn zova_statement_finalize(statement: ?*zova_statement) callconv(.c) zova_status {
    return internal.zova_statement_finalize(statement);
}

export fn zova_statement_step(request: ?*const zova_statement_step_request) callconv(.c) zova_status {
    return internal.zova_statement_step(request);
}

export fn zova_statement_reset(statement: ?*zova_statement) callconv(.c) zova_status {
    return internal.zova_statement_reset(statement);
}

export fn zova_statement_clear_bindings(statement: ?*zova_statement) callconv(.c) zova_status {
    return internal.zova_statement_clear_bindings(statement);
}

export fn zova_statement_bind_null(request: ?*const zova_statement_bind_null_request) callconv(.c) zova_status {
    return internal.zova_statement_bind_null(request);
}

export fn zova_statement_bind_int64(request: ?*const zova_statement_bind_int64_request) callconv(.c) zova_status {
    return internal.zova_statement_bind_int64(request);
}

export fn zova_statement_bind_double(request: ?*const zova_statement_bind_double_request) callconv(.c) zova_status {
    return internal.zova_statement_bind_double(request);
}

export fn zova_statement_bind_text(request: ?*const zova_statement_bind_text_request) callconv(.c) zova_status {
    return internal.zova_statement_bind_text(request);
}

export fn zova_statement_bind_blob(request: ?*const zova_statement_bind_blob_request) callconv(.c) zova_status {
    return internal.zova_statement_bind_blob(request);
}

export fn zova_statement_parameter_count(request: ?*const zova_statement_parameter_count_request) callconv(.c) zova_status {
    return internal.zova_statement_parameter_count(request);
}

export fn zova_statement_parameter_index(request: ?*const zova_statement_parameter_index_request) callconv(.c) zova_status {
    return internal.zova_statement_parameter_index(request);
}

export fn zova_statement_column_count(request: ?*const zova_statement_column_count_request) callconv(.c) zova_status {
    return internal.zova_statement_column_count(request);
}

export fn zova_statement_column_name(request: ?*const zova_statement_column_name_request) callconv(.c) zova_status {
    return internal.zova_statement_column_name(request);
}

export fn zova_statement_column_type(request: ?*const zova_statement_column_type_request) callconv(.c) zova_status {
    return internal.zova_statement_column_type(request);
}

export fn zova_statement_column_int64(request: ?*const zova_statement_column_int64_request) callconv(.c) zova_status {
    return internal.zova_statement_column_int64(request);
}

export fn zova_statement_column_double(request: ?*const zova_statement_column_double_request) callconv(.c) zova_status {
    return internal.zova_statement_column_double(request);
}

export fn zova_statement_column_text(request: ?*const zova_statement_column_text_request) callconv(.c) zova_status {
    return internal.zova_statement_column_text(request);
}

export fn zova_statement_column_blob(request: ?*const zova_statement_column_blob_request) callconv(.c) zova_status {
    return internal.zova_statement_column_blob(request);
}

export fn zova_database_last_error_message(db: ?*zova_database) callconv(.c) [*:0]const u8 {
    return internal.zova_database_last_error_message(db);
}

export fn zova_convert_sqlite_to_zova(request: ?*const zova_convert_sqlite_to_zova_request) callconv(.c) zova_status {
    return internal.zova_convert_sqlite_to_zova(request);
}

export fn zova_database_restore(request: ?*const zova_database_restore_request) callconv(.c) zova_status {
    return internal.zova_database_restore(request);
}

export fn zova_object_id_from_bytes(data: ?[*]const u8, len: usize, out_id: ?*zova_object_id) callconv(.c) zova_status {
    return internal.zova_object_id_from_bytes(data, len, out_id);
}

export fn zova_object_chunk_id_from_bytes(
    data: ?[*]const u8,
    len: usize,
    out_id: ?*zova_object_chunk_id,
) callconv(.c) zova_status {
    return internal.zova_object_chunk_id_from_bytes(data, len, out_id);
}

export fn zova_object_put(request: ?*const zova_object_put_request) callconv(.c) zova_status {
    return internal.zova_object_put(request);
}

export fn zova_object_get(request: ?*const zova_object_get_request) callconv(.c) zova_status {
    return internal.zova_object_get(request);
}

export fn zova_object_read_range(request: ?*const zova_object_read_range_request) callconv(.c) zova_status {
    return internal.zova_object_read_range(request);
}

export fn zova_object_delete(request: ?*const zova_object_delete_request) callconv(.c) zova_status {
    return internal.zova_object_delete(request);
}

export fn zova_object_exists(request: ?*const zova_object_exists_request) callconv(.c) zova_status {
    return internal.zova_object_exists(request);
}

export fn zova_object_size(request: ?*const zova_object_size_request) callconv(.c) zova_status {
    return internal.zova_object_size(request);
}

export fn zova_object_chunk_count(request: ?*const zova_object_chunk_count_request) callconv(.c) zova_status {
    return internal.zova_object_chunk_count(request);
}

export fn zova_object_manifest_get(request: ?*const zova_object_manifest_get_request) callconv(.c) zova_status {
    return internal.zova_object_manifest_get(request);
}

export fn zova_object_chunk_get(request: ?*const zova_object_chunk_get_request) callconv(.c) zova_status {
    return internal.zova_object_chunk_get(request);
}

export fn zova_object_chunk_put(request: ?*const zova_object_chunk_put_request) callconv(.c) zova_status {
    return internal.zova_object_chunk_put(request);
}

export fn zova_object_chunk_delete(request: ?*const zova_object_chunk_delete_request) callconv(.c) zova_status {
    return internal.zova_object_chunk_delete(request);
}

export fn zova_object_assemble_from_chunks(
    request: ?*const zova_object_assemble_from_chunks_request,
) callconv(.c) zova_status {
    return internal.zova_object_assemble_from_chunks(request);
}

export fn zova_object_writer_create(request: ?*const zova_object_writer_create_request) callconv(.c) zova_status {
    return internal.zova_object_writer_create(request);
}

export fn zova_object_writer_write(request: ?*const zova_object_writer_write_request) callconv(.c) zova_status {
    return internal.zova_object_writer_write(request);
}

export fn zova_object_writer_finish(request: ?*const zova_object_writer_finish_request) callconv(.c) zova_status {
    return internal.zova_object_writer_finish(request);
}

export fn zova_object_writer_cancel(request: ?*const zova_object_writer_cancel_request) callconv(.c) zova_status {
    return internal.zova_object_writer_cancel(request);
}

export fn zova_object_writer_destroy(writer: ?*zova_object_writer) callconv(.c) zova_status {
    return internal.zova_object_writer_destroy(writer);
}

export fn zova_vector_collection_create(request: ?*const zova_vector_collection_create_request) callconv(.c) zova_status {
    return internal.zova_vector_collection_create(request);
}

export fn zova_vector_collection_exists(request: ?*const zova_vector_collection_exists_request) callconv(.c) zova_status {
    return internal.zova_vector_collection_exists(request);
}

export fn zova_vector_put(request: ?*const zova_vector_put_request) callconv(.c) zova_status {
    return internal.zova_vector_put(request);
}

export fn zova_vector_get(request: ?*const zova_vector_get_request) callconv(.c) zova_status {
    return internal.zova_vector_get(request);
}

export fn zova_vector_exists(request: ?*const zova_vector_exists_request) callconv(.c) zova_status {
    return internal.zova_vector_exists(request);
}

export fn zova_vector_delete(request: ?*const zova_vector_delete_request) callconv(.c) zova_status {
    return internal.zova_vector_delete(request);
}

export fn zova_vector_search(request: ?*const zova_vector_search_request) callconv(.c) zova_status {
    return internal.zova_vector_search(request);
}

export fn zova_vector_search_in(request: ?*const zova_vector_search_in_request) callconv(.c) zova_status {
    return internal.zova_vector_search_in(request);
}

export fn zova_vector_collection_info_get(request: ?*const zova_vector_collection_info_get_request) callconv(.c) zova_status {
    return internal.zova_vector_collection_info_get(request);
}

export fn zova_vector_collections_list(request: ?*const zova_vector_collections_list_request) callconv(.c) zova_status {
    return internal.zova_vector_collections_list(request);
}

export fn zova_vector_put_many(request: ?*const zova_vector_put_many_request) callconv(.c) zova_status {
    return internal.zova_vector_put_many(request);
}

export fn zova_vector_collection_delete(request: ?*const zova_vector_collection_delete_request) callconv(.c) zova_status {
    return internal.zova_vector_collection_delete(request);
}

export fn zova_vector_search_within(request: ?*const zova_vector_search_within_request) callconv(.c) zova_status {
    return internal.zova_vector_search_within(request);
}

export fn zova_vector_search_in_within(request: ?*const zova_vector_search_in_within_request) callconv(.c) zova_status {
    return internal.zova_vector_search_in_within(request);
}

export fn zova_vector_search_by_id(request: ?*const zova_vector_search_by_id_request) callconv(.c) zova_status {
    return internal.zova_vector_search_by_id(request);
}

export fn zova_vector_search_by_id_in(request: ?*const zova_vector_search_by_id_in_request) callconv(.c) zova_status {
    return internal.zova_vector_search_by_id_in(request);
}

export fn zova_vector_search_by_id_within(request: ?*const zova_vector_search_by_id_within_request) callconv(.c) zova_status {
    return internal.zova_vector_search_by_id_within(request);
}

export fn zova_vector_search_by_id_in_within(request: ?*const zova_vector_search_by_id_in_within_request) callconv(.c) zova_status {
    return internal.zova_vector_search_by_id_in_within(request);
}

export fn zova_graph_create(request: ?*const zova_graph_create_request) callconv(.c) zova_status {
    return internal.zova_graph_create(request);
}

export fn zova_graph_exists(request: ?*const zova_graph_exists_request) callconv(.c) zova_status {
    return internal.zova_graph_exists(request);
}

export fn zova_graph_info_get(request: ?*const zova_graph_info_get_request) callconv(.c) zova_status {
    return internal.zova_graph_info_get(request);
}

export fn zova_graphs_list(request: ?*const zova_graph_list_request) callconv(.c) zova_status {
    return internal.zova_graphs_list(request);
}

export fn zova_graph_delete(request: ?*const zova_graph_delete_request) callconv(.c) zova_status {
    return internal.zova_graph_delete(request);
}

export fn zova_graph_node_put(request: ?*const zova_graph_node_put_request) callconv(.c) zova_status {
    return internal.zova_graph_node_put(request);
}

export fn zova_graph_node_get(request: ?*const zova_graph_node_get_request) callconv(.c) zova_status {
    return internal.zova_graph_node_get(request);
}

export fn zova_graph_node_exists(request: ?*const zova_graph_node_exists_request) callconv(.c) zova_status {
    return internal.zova_graph_node_exists(request);
}

export fn zova_graph_node_delete(request: ?*const zova_graph_node_delete_request) callconv(.c) zova_status {
    return internal.zova_graph_node_delete(request);
}

export fn zova_graph_edge_put(request: ?*const zova_graph_edge_put_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_put(request);
}

export fn zova_graph_edge_get(request: ?*const zova_graph_edge_get_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_get(request);
}

export fn zova_graph_edge_exists(request: ?*const zova_graph_edge_exists_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_exists(request);
}

export fn zova_graph_edge_delete(request: ?*const zova_graph_edge_delete_request) callconv(.c) zova_status {
    return internal.zova_graph_edge_delete(request);
}

export fn zova_graph_neighbors(request: ?*const zova_graph_neighbors_request) callconv(.c) zova_status {
    return internal.zova_graph_neighbors(request);
}

export fn zova_graph_walk(request: ?*const zova_graph_walk_request) callconv(.c) zova_status {
    return internal.zova_graph_walk(request);
}

test {
    _ = @import("c_api_tests.zig");
}
