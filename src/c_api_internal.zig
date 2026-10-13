//! Internal implementation for the Zova C ABI bridge.
//!
//! This module deliberately exposes only C-compatible handles, request structs,
//! fixed-width ids, status values, and owned buffers. It does not expose Zig
//! slices, Zig allocators, Zig error unions, or private `_zova_*` schema.
//!
//! Header contract versus implementation contract:
//! - `include/zova.h` documents what C/Rust/foreign callers may rely on.
//! - this file documents the bridge decisions maintainers must preserve.
//!
//! The C ABI is the candidate 1.x contract. Consumers may generate bindings
//! from it: stable numeric statuses, opaque handles, explicit free
//! functions, no global mutable error state, and `zova_`-prefixed symbols.
//!
//! Exported functions should never let Zig implementation details escape. Convert
//! every Zig error into `zova_status`, return owned data through C containers,
//! and keep borrowed pointers scoped to the documented lifetime.
//!
//! Vectors follow the same ABI pattern as objects: collection names and vector
//! ids are borrowed C strings, vector values are borrowed `float` arrays, and
//! returned vectors/search results are library-owned containers with explicit
//! free functions. Vector metadata remains application-owned in normal SQL
//! tables; this bridge only exposes native vector storage and exact search.
//!
//! Prepared statements intentionally mirror the thin Zig SQLite wrapper so
//! language bindings can use one Zova database handle for application records
//! plus native object/vector operations. Statement column text/blob outputs are
//! copied into owned C ABI containers to avoid exposing SQLite's borrowed
//! statement-scoped column lifetimes across FFI boundaries.
//!
//! Maintenance is explicit. The ABI exposes in-place `VACUUM`, but Zova never
//! runs it automatically. Format-8 handles enable `foreign_keys` so private
//! graph endpoint constraints and cascades are enforced; journal and
//! synchronous modes remain caller-controlled.
//!
//! Runtime model: one `zova_database` handle is internally serialized by a
//! per-handle mutex. Calls on that handle are safe from multiple threads but
//! execute one at a time. Statements and object writers are child handles and
//! use the parent database mutex. Multiple database handles remain the explicit
//! path for true concurrency and follow normal SQLite locking behavior.
//! This is not callback reentrancy support: the mutex is intentionally
//! non-recursive, and C ABI entrypoints must not call back into the same handle
//! while already executing inside a Zova/SQLite callback.
//! Successful close/finalize/destroy calls are still terminal C pointer lifetime
//! events and must be coordinated by callers as final uses of those pointers.

const std = @import("std");

const zova = @import("zova.zig");

const graph = @import("graph.zig");

const sqlite = @import("sqlite.zig");

pub const zova_database = @import("c_api/types.zig").zova_database;

pub const zova_object_writer = @import("c_api/types.zig").zova_object_writer;

pub const zova_object_reader = @import("c_api/types.zig").zova_object_reader;

pub const zova_statement = @import("c_api/types.zig").zova_statement;

pub const zova_subscription = @import("c_api/types.zig").zova_subscription;

pub const zova_fresh_build = @import("c_api/types.zig").zova_fresh_build;

pub const FreshBuildCachePolicy = @import("c_api/handles.zig").FreshBuildCachePolicy;

pub const FreshBuildCacheDiagnostics = @import("c_api/handles.zig").FreshBuildCacheDiagnostics;

/// Internal benchmark control. This is intentionally not exported through the C ABI.
pub const setFreshBuildCachePolicyForBenchmark = @import("c_api/fresh_build.zig").setFreshBuildCachePolicyForBenchmark;

/// Internal benchmark diagnostics. The build handle remains owned until destroy.
pub const freshBuildCacheDiagnostics = @import("c_api/fresh_build.zig").freshBuildCacheDiagnostics;

pub const zova_status = @import("c_api/types.zig").zova_status;

pub const zova_step_result = @import("c_api/types.zig").zova_step_result;

pub const zova_column_type = @import("c_api/types.zig").zova_column_type;

pub const zova_sql_value_type = @import("c_api/types.zig").zova_sql_value_type;

pub const zova_sql_result_type = @import("c_api/types.zig").zova_sql_result_type;

pub const ZOVA_SQL_FUNCTION_DETERMINISTIC = @import("c_api/types.zig").ZOVA_SQL_FUNCTION_DETERMINISTIC;

pub const ZOVA_SQL_FUNCTION_DIRECT_ONLY = @import("c_api/types.zig").ZOVA_SQL_FUNCTION_DIRECT_ONLY;

pub const ZOVA_SQL_FUNCTION_INNOCUOUS = @import("c_api/types.zig").ZOVA_SQL_FUNCTION_INNOCUOUS;

pub const zova_sql_value = @import("c_api/types.zig").zova_sql_value;

pub const zova_sql_result = @import("c_api/types.zig").zova_sql_result;

pub const zova_sql_function_call = @import("c_api/types.zig").zova_sql_function_call;

pub const zova_sql_scalar_callback = @import("c_api/types.zig").zova_sql_scalar_callback;

pub const zova_sql_destroy_callback = @import("c_api/types.zig").zova_sql_destroy_callback;

pub const zova_object_id = @import("c_api/types.zig").zova_object_id;

pub const zova_object_chunk_id = @import("c_api/types.zig").zova_object_chunk_id;

pub const zova_buffer = @import("c_api/types.zig").zova_buffer;

pub const zova_message = @import("c_api/types.zig").zova_message;

pub const zova_text = @import("c_api/types.zig").zova_text;

pub const zova_notification = @import("c_api/types.zig").zova_notification;

pub const zova_object_manifest_chunk = @import("c_api/types.zig").zova_object_manifest_chunk;

pub const zova_object_manifest = @import("c_api/types.zig").zova_object_manifest;

/// Additive object storage profile values. The underlying field is a raw C
/// integer in request structs so invalid foreign values can be rejected
/// without triggering Zig enum safety traps.
pub const zova_object_storage_profile = @import("c_api/types.zig").zova_object_storage_profile;

pub const zova_object_put_options = @import("c_api/types.zig").zova_object_put_options;

pub const zova_vector_metric = @import("c_api/types.zig").zova_vector_metric;

pub const zova_vector_element_type = @import("c_api/types.zig").zova_vector_element_type;

pub const zova_vector_multi_i8_search_mode = @import("c_api/types.zig").zova_vector_multi_i8_search_mode;

pub const zova_vector_multi_i8_aggregation = @import("c_api/types.zig").zova_vector_multi_i8_aggregation;

pub const zova_graph_target_type = @import("c_api/types.zig").zova_graph_target_type;

pub const zova_graph_neighbor_direction = @import("c_api/types.zig").zova_graph_neighbor_direction;

pub const zova_vector_collection_options = @import("c_api/types.zig").zova_vector_collection_options;

pub const zova_vector_values = @import("c_api/types.zig").zova_vector_values;

pub const zova_vector = @import("c_api/types.zig").zova_vector;

pub const zova_vector_search_result = @import("c_api/types.zig").zova_vector_search_result;

pub const zova_vector_search_results = @import("c_api/types.zig").zova_vector_search_results;

pub const zova_vector_collection_info = @import("c_api/types.zig").zova_vector_collection_info;

pub const zova_vector_collection_list = @import("c_api/types.zig").zova_vector_collection_list;

pub const zova_vector_input = @import("c_api/types.zig").zova_vector_input;

pub const zova_graph_info = @import("c_api/types.zig").zova_graph_info;

pub const zova_graph_list = @import("c_api/types.zig").zova_graph_list;

pub const zova_extension_info = @import("c_api/types.zig").zova_extension_info;

pub const zova_extension_list = @import("c_api/types.zig").zova_extension_list;

pub const zova_graph_node = @import("c_api/types.zig").zova_graph_node;

pub const zova_graph_edge = @import("c_api/types.zig").zova_graph_edge;

pub const zova_graph_neighbor_result = @import("c_api/types.zig").zova_graph_neighbor_result;

pub const zova_graph_neighbor_results = @import("c_api/types.zig").zova_graph_neighbor_results;

pub const zova_graph_keyed_neighbor_result = @import("c_api/types.zig").zova_graph_keyed_neighbor_result;

pub const zova_graph_keyed_neighbor_results = @import("c_api/types.zig").zova_graph_keyed_neighbor_results;

pub const zova_graph_keyed_node_result = @import("c_api/types.zig").zova_graph_keyed_node_result;

pub const zova_graph_keyed_node_results = @import("c_api/types.zig").zova_graph_keyed_node_results;

pub const zova_graph_keyed_edge_result = @import("c_api/types.zig").zova_graph_keyed_edge_result;

pub const zova_graph_keyed_edge_results = @import("c_api/types.zig").zova_graph_keyed_edge_results;

pub const zova_graph_edge_payload_result = @import("c_api/types.zig").zova_graph_edge_payload_result;

pub const zova_graph_edge_payload_results = @import("c_api/types.zig").zova_graph_edge_payload_results;

pub const zova_fresh_build_profile = @import("c_api/types.zig").zova_fresh_build_profile;

pub const zova_fresh_value = @import("c_api/types.zig").zova_fresh_value;

pub const zova_graph_scan_cursor = @import("c_api/types.zig").zova_graph_scan_cursor;

pub const zova_graph_scan_node = @import("c_api/types.zig").zova_graph_scan_node;

pub const zova_graph_scan_edge = @import("c_api/types.zig").zova_graph_scan_edge;

pub const zova_graph_scan_results = @import("c_api/types.zig").zova_graph_scan_results;

pub const zova_graph_walk_result = @import("c_api/types.zig").zova_graph_walk_result;

pub const zova_graph_walk_results = @import("c_api/types.zig").zova_graph_walk_results;

pub const zova_graph_walk_profile = @import("c_api/types.zig").zova_graph_walk_profile;

pub const ZOVA_OPEN_READ_ONLY = @import("c_api/types.zig").ZOVA_OPEN_READ_ONLY;

pub const ZOVA_BACKUP_NO_VERIFY = @import("c_api/types.zig").ZOVA_BACKUP_NO_VERIFY;

pub const ZOVA_COMPACT_NO_VERIFY = @import("c_api/types.zig").ZOVA_COMPACT_NO_VERIFY;

pub const ZOVA_RESTORE_NO_VERIFY = @import("c_api/types.zig").ZOVA_RESTORE_NO_VERIFY;

pub const ZOVA_MIGRATE_NO_VERIFY = @import("c_api/types.zig").ZOVA_MIGRATE_NO_VERIFY;

pub const zova_format_compatibility = @import("c_api/types.zig").zova_format_compatibility;

pub const zova_database_format_info = @import("c_api/types.zig").zova_database_format_info;

pub const zova_database_probe_format_request = @import("c_api/types.zig").zova_database_probe_format_request;

pub const zova_database_migrate_request = @import("c_api/types.zig").zova_database_migrate_request;

pub const zova_database_open_request = @import("c_api/types.zig").zova_database_open_request;

pub const zova_database_create_memory_request = @import("c_api/types.zig").zova_database_create_memory_request;

pub const zova_database_restore_to_memory_request = @import("c_api/types.zig").zova_database_restore_to_memory_request;

pub const zova_database_create_options_request = @import("c_api/types.zig").zova_database_create_options_request;

pub const zova_database_open_options_request = @import("c_api/types.zig").zova_database_open_options_request;

pub const zova_database_open_extensions_request = @import("c_api/types.zig").zova_database_open_extensions_request;
pub const zova_database_open_plugins_request = @import("c_api/types.zig").zova_database_open_plugins_request;
pub const zova_database_migrate_extensions_request = @import("c_api/types.zig").zova_database_migrate_extensions_request;
pub const zova_plugin_descriptor_v1 = @import("c_api/types.zig").zova_plugin_descriptor_v1;

pub const zova_extension_bundle_request = @import("c_api/types.zig").zova_extension_bundle_request;

pub const zova_extension_bundle_untrust_request = @import("c_api/types.zig").zova_extension_bundle_untrust_request;

pub const zova_convert_sqlite_to_zova_request = @import("c_api/types.zig").zova_convert_sqlite_to_zova_request;

pub const zova_database_backup_request = @import("c_api/types.zig").zova_database_backup_request;

pub const zova_database_compact_request = @import("c_api/types.zig").zova_database_compact_request;

pub const zova_database_restore_request = @import("c_api/types.zig").zova_database_restore_request;

pub const zova_database_exec_request = @import("c_api/types.zig").zova_database_exec_request;

pub const zova_sql_function_register_request = @import("c_api/types.zig").zova_sql_function_register_request;

pub const zova_database_simple_request = @import("c_api/types.zig").zova_database_simple_request;

pub const zova_database_savepoint_request = @import("c_api/types.zig").zova_database_savepoint_request;

pub const zova_database_busy_timeout_request = @import("c_api/types.zig").zova_database_busy_timeout_request;

pub const zova_database_last_insert_rowid_request = @import("c_api/types.zig").zova_database_last_insert_rowid_request;

pub const zova_database_changes_request = @import("c_api/types.zig").zova_database_changes_request;

pub const zova_database_total_changes_request = @import("c_api/types.zig").zova_database_total_changes_request;

pub const zova_database_notify_request = @import("c_api/types.zig").zova_database_notify_request;

pub const zova_database_listen_request = @import("c_api/types.zig").zova_database_listen_request;

pub const zova_subscription_try_receive_request = @import("c_api/types.zig").zova_subscription_try_receive_request;

pub const zova_database_prepare_request = @import("c_api/types.zig").zova_database_prepare_request;

pub const zova_statement_step_request = @import("c_api/types.zig").zova_statement_step_request;

pub const zova_statement_bind_null_request = @import("c_api/types.zig").zova_statement_bind_null_request;

pub const zova_statement_bind_int64_request = @import("c_api/types.zig").zova_statement_bind_int64_request;

pub const zova_statement_bind_double_request = @import("c_api/types.zig").zova_statement_bind_double_request;

pub const zova_statement_bind_text_request = @import("c_api/types.zig").zova_statement_bind_text_request;

pub const zova_statement_bind_blob_request = @import("c_api/types.zig").zova_statement_bind_blob_request;

pub const zova_statement_parameter_count_request = @import("c_api/types.zig").zova_statement_parameter_count_request;

pub const zova_statement_parameter_index_request = @import("c_api/types.zig").zova_statement_parameter_index_request;

pub const zova_statement_column_count_request = @import("c_api/types.zig").zova_statement_column_count_request;

pub const zova_statement_column_name_request = @import("c_api/types.zig").zova_statement_column_name_request;

pub const zova_statement_column_type_request = @import("c_api/types.zig").zova_statement_column_type_request;

pub const zova_statement_column_int64_request = @import("c_api/types.zig").zova_statement_column_int64_request;

pub const zova_statement_column_double_request = @import("c_api/types.zig").zova_statement_column_double_request;

pub const zova_statement_column_text_request = @import("c_api/types.zig").zova_statement_column_text_request;

pub const zova_statement_column_blob_request = @import("c_api/types.zig").zova_statement_column_blob_request;

pub const zova_object_put_request = @import("c_api/types.zig").zova_object_put_request;

pub const zova_object_put_with_options_request = @import("c_api/types.zig").zova_object_put_with_options_request;

pub const zova_object_get_request = @import("c_api/types.zig").zova_object_get_request;

pub const zova_object_read_range_request = @import("c_api/types.zig").zova_object_read_range_request;

pub const zova_object_exists_request = @import("c_api/types.zig").zova_object_exists_request;

pub const zova_object_size_request = @import("c_api/types.zig").zova_object_size_request;

pub const zova_object_chunk_count_request = @import("c_api/types.zig").zova_object_chunk_count_request;

pub const zova_object_delete_request = @import("c_api/types.zig").zova_object_delete_request;

pub const zova_object_manifest_get_request = @import("c_api/types.zig").zova_object_manifest_get_request;

pub const zova_object_chunk_get_request = @import("c_api/types.zig").zova_object_chunk_get_request;

pub const zova_object_chunk_put_request = @import("c_api/types.zig").zova_object_chunk_put_request;

pub const zova_object_chunk_put_with_options_request = @import("c_api/types.zig").zova_object_chunk_put_with_options_request;

pub const zova_object_chunk_delete_request = @import("c_api/types.zig").zova_object_chunk_delete_request;

pub const zova_object_assemble_from_chunks_request = @import("c_api/types.zig").zova_object_assemble_from_chunks_request;

pub const zova_object_assemble_from_chunks_with_options_request = @import("c_api/types.zig").zova_object_assemble_from_chunks_with_options_request;

pub const zova_object_writer_create_request = @import("c_api/types.zig").zova_object_writer_create_request;

pub const zova_object_writer_create_with_options_request = @import("c_api/types.zig").zova_object_writer_create_with_options_request;

pub const zova_object_writer_write_request = @import("c_api/types.zig").zova_object_writer_write_request;

pub const zova_object_writer_finish_request = @import("c_api/types.zig").zova_object_writer_finish_request;

pub const zova_object_writer_cancel_request = @import("c_api/types.zig").zova_object_writer_cancel_request;

pub const zova_object_reader_create_request = @import("c_api/types.zig").zova_object_reader_create_request;

pub const zova_object_reader_read_request = @import("c_api/types.zig").zova_object_reader_read_request;

pub const zova_object_reader_destroy_request = @import("c_api/types.zig").zova_object_reader_destroy_request;

/// Borrowed byte slice for key-value operations. Zova copies caller input
/// during the call and retains no caller memory.
pub const zova_kv_bytes = @import("c_api/types.zig").zova_kv_bytes;

/// Owned key-value get result. Free with `zova_kv_get_result_free`.
pub const zova_kv_get_result = @import("c_api/types.zig").zova_kv_get_result;

/// Owned many-get results. Free with `zova_kv_get_many_results_free`.
pub const zova_kv_get_many_results = @import("c_api/types.zig").zova_kv_get_many_results;

/// Borrowed batch put entry.
pub const zova_kv_put_entry = @import("c_api/types.zig").zova_kv_put_entry;

pub const zova_kv_get_request = @import("c_api/types.zig").zova_kv_get_request;

pub const zova_kv_get_many_request = @import("c_api/types.zig").zova_kv_get_many_request;

pub const zova_kv_put_request = @import("c_api/types.zig").zova_kv_put_request;

pub const zova_kv_put_many_request = @import("c_api/types.zig").zova_kv_put_many_request;

pub const zova_kv_delete_request = @import("c_api/types.zig").zova_kv_delete_request;

pub const zova_kv_delete_many_request = @import("c_api/types.zig").zova_kv_delete_many_request;

pub const zova_kv_count_request = @import("c_api/types.zig").zova_kv_count_request;

pub const zova_kv_clear_namespace_request = @import("c_api/types.zig").zova_kv_clear_namespace_request;

pub const zova_vector_collection_create_request = @import("c_api/types.zig").zova_vector_collection_create_request;

pub const zova_vector_collection_exists_request = @import("c_api/types.zig").zova_vector_collection_exists_request;

pub const zova_vector_put_request = @import("c_api/types.zig").zova_vector_put_request;

pub const zova_vector_get_request = @import("c_api/types.zig").zova_vector_get_request;

pub const zova_vector_exists_request = @import("c_api/types.zig").zova_vector_exists_request;

pub const zova_vector_delete_request = @import("c_api/types.zig").zova_vector_delete_request;

pub const zova_vector_search_request = @import("c_api/types.zig").zova_vector_search_request;

pub const zova_vector_search_in_request = @import("c_api/types.zig").zova_vector_search_in_request;

pub const zova_vector_search_multi_i8_request = @import("c_api/types.zig").zova_vector_search_multi_i8_request;

pub const zova_vector_collection_info_get_request = @import("c_api/types.zig").zova_vector_collection_info_get_request;

pub const zova_vector_collections_list_request = @import("c_api/types.zig").zova_vector_collections_list_request;

pub const zova_vector_put_many_request = @import("c_api/types.zig").zova_vector_put_many_request;

pub const zova_vector_delete_many_request = @import("c_api/types.zig").zova_vector_delete_many_request;

pub const zova_vector_collection_delete_request = @import("c_api/types.zig").zova_vector_collection_delete_request;

pub const zova_vector_search_within_request = @import("c_api/types.zig").zova_vector_search_within_request;

pub const zova_vector_search_in_within_request = @import("c_api/types.zig").zova_vector_search_in_within_request;

pub const zova_vector_search_by_id_request = @import("c_api/types.zig").zova_vector_search_by_id_request;

pub const zova_vector_search_by_id_in_request = @import("c_api/types.zig").zova_vector_search_by_id_in_request;

pub const zova_vector_search_by_id_within_request = @import("c_api/types.zig").zova_vector_search_by_id_within_request;

pub const zova_vector_search_by_id_in_within_request = @import("c_api/types.zig").zova_vector_search_by_id_in_within_request;

pub const zova_graph_create_request = @import("c_api/types.zig").zova_graph_create_request;

pub const zova_graph_exists_request = @import("c_api/types.zig").zova_graph_exists_request;

pub const zova_graph_info_get_request = @import("c_api/types.zig").zova_graph_info_get_request;

pub const zova_graph_list_request = @import("c_api/types.zig").zova_graph_list_request;

pub const zova_database_extension_request = @import("c_api/types.zig").zova_database_extension_request;

pub const zova_database_extension_info_request = @import("c_api/types.zig").zova_database_extension_info_request;

pub const zova_database_extension_list_request = @import("c_api/types.zig").zova_database_extension_list_request;

pub const zova_graph_delete_request = @import("c_api/types.zig").zova_graph_delete_request;

pub const zova_graph_node_put_request = @import("c_api/types.zig").zova_graph_node_put_request;

/// Borrowed graph node input for zova_graph_node_put_many.
pub const zova_graph_node_input = @import("c_api/types.zig").zova_graph_node_input;

pub const zova_graph_node_put_many_request = @import("c_api/types.zig").zova_graph_node_put_many_request;

pub const zova_graph_node_put_many_keyed_request = @import("c_api/types.zig").zova_graph_node_put_many_keyed_request;

pub const zova_graph_fresh_node_input = @import("c_api/types.zig").zova_graph_fresh_node_input;

pub const zova_graph_fresh_edge_input = @import("c_api/types.zig").zova_graph_fresh_edge_input;

pub const zova_graph_fresh_edge_payload_input = @import("c_api/types.zig").zova_graph_fresh_edge_payload_input;

pub const zova_graph_build_fresh_keyed_request = @import("c_api/types.zig").zova_graph_build_fresh_keyed_request;

pub const zova_graph_build_fresh_prepared_keyed_with_payloads_request = @import("c_api/types.zig").zova_graph_build_fresh_prepared_keyed_with_payloads_request;

pub const zova_graph_node_get_request = @import("c_api/types.zig").zova_graph_node_get_request;

pub const zova_graph_node_exists_request = @import("c_api/types.zig").zova_graph_node_exists_request;

pub const zova_graph_node_delete_request = @import("c_api/types.zig").zova_graph_node_delete_request;

pub const zova_graph_node_delete_many_request = @import("c_api/types.zig").zova_graph_node_delete_many_request;

pub const zova_graph_edge_put_request = @import("c_api/types.zig").zova_graph_edge_put_request;

/// Borrowed graph edge input for zova_graph_edge_put_many.
pub const zova_graph_edge_input = @import("c_api/types.zig").zova_graph_edge_input;

pub const zova_graph_edge_put_many_request = @import("c_api/types.zig").zova_graph_edge_put_many_request;

pub const zova_graph_edge_put_many_keyed_request = @import("c_api/types.zig").zova_graph_edge_put_many_keyed_request;

pub const zova_graph_edge_delete_many_request = @import("c_api/types.zig").zova_graph_edge_delete_many_request;

pub const zova_graph_edge_get_request = @import("c_api/types.zig").zova_graph_edge_get_request;

pub const zova_graph_edge_exists_request = @import("c_api/types.zig").zova_graph_edge_exists_request;

pub const zova_graph_edge_delete_request = @import("c_api/types.zig").zova_graph_edge_delete_request;

pub const zova_graph_neighbors_request = @import("c_api/types.zig").zova_graph_neighbors_request;

pub const zova_graph_neighbors_keyed_request = @import("c_api/types.zig").zova_graph_neighbors_keyed_request;

pub const zova_graph_nodes_get_many_keyed_request = @import("c_api/types.zig").zova_graph_nodes_get_many_keyed_request;

pub const zova_graph_edges_get_many_keyed_request = @import("c_api/types.zig").zova_graph_edges_get_many_keyed_request;

pub const zova_graph_edge_payload_get_many_request = @import("c_api/types.zig").zova_graph_edge_payload_get_many_request;

pub const zova_graph_edge_payload_replacement = @import("c_api/types.zig").zova_graph_edge_payload_replacement;

pub const zova_graph_edge_payload_replace_many_request = @import("c_api/types.zig").zova_graph_edge_payload_replace_many_request;

pub const zova_fresh_build_begin_request = @import("c_api/types.zig").zova_fresh_build_begin_request;

pub const zova_fresh_build_rows_request = @import("c_api/types.zig").zova_fresh_build_rows_request;

pub const zova_fresh_build_graph_request = @import("c_api/types.zig").zova_fresh_build_graph_request;

pub const zova_fresh_build_vectors_request = @import("c_api/types.zig").zova_fresh_build_vectors_request;

pub const zova_fresh_build_finish_request = @import("c_api/types.zig").zova_fresh_build_finish_request;

pub const zova_graph_degree_request = @import("c_api/types.zig").zova_graph_degree_request;

pub const zova_graph_degree_many_keyed_request = @import("c_api/types.zig").zova_graph_degree_many_keyed_request;

pub const zova_graph_scan_request = @import("c_api/types.zig").zova_graph_scan_request;

pub const zova_graph_walk_request = @import("c_api/types.zig").zova_graph_walk_request;

pub const zova_graph_walk_direction_request = @import("c_api/types.zig").zova_graph_walk_direction_request;

pub const zova_graph_walk_direction_profiled_request = @import("c_api/types.zig").zova_graph_walk_direction_profiled_request;

pub const zova_abi_version_major = @import("c_api/errors.zig").zova_abi_version_major;

pub const zova_abi_version_minor = @import("c_api/errors.zig").zova_abi_version_minor;

pub const zova_abi_version_patch = @import("c_api/errors.zig").zova_abi_version_patch;

pub const zova_abi_version_string = @import("c_api/errors.zig").zova_abi_version_string;

pub const zova_status_name = @import("c_api/errors.zig").zova_status_name;

pub const zova_buffer_free = @import("c_api/results.zig").zova_buffer_free;

pub const zova_kv_get_result_free = @import("c_api/results.zig").zova_kv_get_result_free;

pub const zova_kv_get_many_results_free = @import("c_api/results.zig").zova_kv_get_many_results_free;

pub const zova_message_free = @import("c_api/results.zig").zova_message_free;

pub const zova_text_free = @import("c_api/results.zig").zova_text_free;

pub const zova_notification_free = @import("c_api/results.zig").zova_notification_free;

pub const zova_object_manifest_free = @import("c_api/results.zig").zova_object_manifest_free;

pub const zova_vector_free = @import("c_api/results.zig").zova_vector_free;

pub const zova_vector_search_results_free = @import("c_api/results.zig").zova_vector_search_results_free;

pub const zova_vector_collection_info_free = @import("c_api/results.zig").zova_vector_collection_info_free;

pub const zova_vector_collection_list_free = @import("c_api/results.zig").zova_vector_collection_list_free;

pub const zova_graph_info_free = @import("c_api/results.zig").zova_graph_info_free;

pub const zova_graph_list_free = @import("c_api/results.zig").zova_graph_list_free;

pub const zova_extension_info_free = @import("c_api/results.zig").zova_extension_info_free;

pub const zova_extension_list_free = @import("c_api/results.zig").zova_extension_list_free;

pub const zova_graph_node_free = @import("c_api/results.zig").zova_graph_node_free;

pub const zova_graph_edge_free = @import("c_api/results.zig").zova_graph_edge_free;

pub const zova_graph_neighbor_results_free = @import("c_api/results.zig").zova_graph_neighbor_results_free;

pub const zova_graph_keyed_neighbor_results_free = @import("c_api/results.zig").zova_graph_keyed_neighbor_results_free;

pub const zova_graph_keyed_node_results_free = @import("c_api/results.zig").zova_graph_keyed_node_results_free;

pub const zova_graph_keyed_edge_results_free = @import("c_api/results.zig").zova_graph_keyed_edge_results_free;

pub const zova_graph_edge_payload_results_free = @import("c_api/results.zig").zova_graph_edge_payload_results_free;

pub const zova_graph_scan_results_free = @import("c_api/results.zig").zova_graph_scan_results_free;

pub const zova_graph_walk_results_free = @import("c_api/results.zig").zova_graph_walk_results_free;

pub const zova_database_create = @import("c_api/database.zig").zova_database_create;

pub const zova_database_create_memory = @import("c_api/database.zig").zova_database_create_memory;

pub const zova_database_create_with_options = @import("c_api/database.zig").zova_database_create_with_options;

pub const zova_database_create_with_extensions = @import("c_api/database.zig").zova_database_create_with_extensions;

pub const zova_database_open = @import("c_api/database.zig").zova_database_open;

pub const zova_database_open_with_options = @import("c_api/database.zig").zova_database_open_with_options;

pub const zova_database_open_with_extensions = @import("c_api/database.zig").zova_database_open_with_extensions;

pub const zova_extension_bundle_verify = @import("c_api/extensions.zig").zova_extension_bundle_verify;

pub const zova_extension_bundle_trust = @import("c_api/extensions.zig").zova_extension_bundle_trust;

pub const zova_extension_bundle_untrust = @import("c_api/extensions.zig").zova_extension_bundle_untrust;

pub const zova_database_close = @import("c_api/database.zig").zova_database_close;

pub const zova_database_exec = @import("c_api/database.zig").zova_database_exec;

pub const zova_database_register_function = @import("c_api/sql_functions.zig").zova_database_register_function;

pub const zova_database_begin = @import("c_api/database.zig").zova_database_begin;

pub const zova_database_begin_immediate = @import("c_api/database.zig").zova_database_begin_immediate;

pub const zova_database_commit = @import("c_api/database.zig").zova_database_commit;

pub const zova_database_rollback = @import("c_api/database.zig").zova_database_rollback;

pub const zova_database_savepoint = @import("c_api/database.zig").zova_database_savepoint;

pub const zova_database_rollback_to_savepoint = @import("c_api/database.zig").zova_database_rollback_to_savepoint;

pub const zova_database_release_savepoint = @import("c_api/database.zig").zova_database_release_savepoint;

pub const zova_database_vacuum = @import("c_api/database.zig").zova_database_vacuum;

pub const zova_database_backup = @import("c_api/database.zig").zova_database_backup;

pub const zova_database_compact = @import("c_api/database.zig").zova_database_compact;

pub const zova_database_set_busy_timeout = @import("c_api/database.zig").zova_database_set_busy_timeout;

pub const zova_database_last_insert_rowid = @import("c_api/database.zig").zova_database_last_insert_rowid;

pub const zova_database_changes = @import("c_api/database.zig").zova_database_changes;

pub const zova_database_total_changes = @import("c_api/database.zig").zova_database_total_changes;

pub const zova_database_notify = @import("c_api/notifications.zig").zova_database_notify;

pub const zova_database_listen = @import("c_api/notifications.zig").zova_database_listen;

pub const zova_subscription_try_receive = @import("c_api/notifications.zig").zova_subscription_try_receive;

pub const zova_subscription_close = @import("c_api/notifications.zig").zova_subscription_close;

pub const zova_database_prepare = @import("c_api/statements.zig").zova_database_prepare;

pub const zova_statement_finalize = @import("c_api/statements.zig").zova_statement_finalize;

pub const zova_statement_step = @import("c_api/statements.zig").zova_statement_step;

pub const zova_statement_reset = @import("c_api/statements.zig").zova_statement_reset;

pub const zova_statement_clear_bindings = @import("c_api/statements.zig").zova_statement_clear_bindings;

pub const zova_statement_bind_null = @import("c_api/statements.zig").zova_statement_bind_null;

pub const zova_statement_bind_int64 = @import("c_api/statements.zig").zova_statement_bind_int64;

pub const zova_statement_bind_double = @import("c_api/statements.zig").zova_statement_bind_double;

pub const zova_statement_bind_text = @import("c_api/statements.zig").zova_statement_bind_text;

pub const zova_statement_bind_blob = @import("c_api/statements.zig").zova_statement_bind_blob;

pub const zova_statement_parameter_count = @import("c_api/statements.zig").zova_statement_parameter_count;

pub const zova_statement_parameter_index = @import("c_api/statements.zig").zova_statement_parameter_index;

pub const zova_statement_column_count = @import("c_api/statements.zig").zova_statement_column_count;

pub const zova_statement_column_name = @import("c_api/statements.zig").zova_statement_column_name;

pub const zova_statement_column_type = @import("c_api/statements.zig").zova_statement_column_type;

pub const zova_statement_column_int64 = @import("c_api/statements.zig").zova_statement_column_int64;

pub const zova_statement_column_double = @import("c_api/statements.zig").zova_statement_column_double;

pub const zova_statement_column_text = @import("c_api/statements.zig").zova_statement_column_text;

pub const zova_statement_column_blob = @import("c_api/statements.zig").zova_statement_column_blob;

pub const zova_database_last_error_message = @import("c_api/errors.zig").zova_database_last_error_message;

pub const zova_convert_sqlite_to_zova = @import("c_api/database.zig").zova_convert_sqlite_to_zova;

pub const zova_database_restore = @import("c_api/database.zig").zova_database_restore;

pub const zova_database_probe_format = @import("c_api/database.zig").zova_database_probe_format;

pub const zova_database_migrate = @import("c_api/database.zig").zova_database_migrate;

pub const zova_database_restore_to_memory = @import("c_api/database.zig").zova_database_restore_to_memory;

pub const zova_object_id_from_bytes = @import("c_api/objects.zig").zova_object_id_from_bytes;

pub const zova_object_chunk_id_from_bytes = @import("c_api/objects.zig").zova_object_chunk_id_from_bytes;

pub const zova_object_put = @import("c_api/objects.zig").zova_object_put;

pub const zova_object_put_with_options = @import("c_api/objects.zig").zova_object_put_with_options;

pub const zova_object_get = @import("c_api/objects.zig").zova_object_get;

pub const zova_object_read_range = @import("c_api/objects.zig").zova_object_read_range;

pub const zova_object_delete = @import("c_api/objects.zig").zova_object_delete;

pub const zova_object_exists = @import("c_api/objects.zig").zova_object_exists;

pub const zova_object_size = @import("c_api/objects.zig").zova_object_size;

pub const zova_object_chunk_count = @import("c_api/objects.zig").zova_object_chunk_count;

pub const zova_kv_get = @import("c_api/kv.zig").zova_kv_get;

pub const zova_kv_get_many = @import("c_api/kv.zig").zova_kv_get_many;

pub const zova_kv_put = @import("c_api/kv.zig").zova_kv_put;

pub const zova_kv_put_many = @import("c_api/kv.zig").zova_kv_put_many;

pub const zova_kv_delete = @import("c_api/kv.zig").zova_kv_delete;

pub const zova_kv_delete_many = @import("c_api/kv.zig").zova_kv_delete_many;

pub const zova_kv_count = @import("c_api/kv.zig").zova_kv_count;

pub const zova_kv_clear_namespace = @import("c_api/kv.zig").zova_kv_clear_namespace;

pub const zova_object_manifest_get = @import("c_api/objects.zig").zova_object_manifest_get;

pub const zova_object_chunk_get = @import("c_api/objects.zig").zova_object_chunk_get;

pub const zova_object_chunk_put = @import("c_api/objects.zig").zova_object_chunk_put;

pub const zova_object_chunk_put_with_options = @import("c_api/objects.zig").zova_object_chunk_put_with_options;

pub const zova_object_chunk_delete = @import("c_api/objects.zig").zova_object_chunk_delete;

pub const zova_object_assemble_from_chunks = @import("c_api/objects.zig").zova_object_assemble_from_chunks;

pub const zova_object_assemble_from_chunks_with_options = @import("c_api/objects.zig").zova_object_assemble_from_chunks_with_options;

pub const zova_object_writer_create = @import("c_api/objects.zig").zova_object_writer_create;

pub const zova_object_writer_create_with_options = @import("c_api/objects.zig").zova_object_writer_create_with_options;

pub const zova_object_writer_write = @import("c_api/objects.zig").zova_object_writer_write;

pub const zova_object_writer_finish = @import("c_api/objects.zig").zova_object_writer_finish;

pub const zova_object_writer_cancel = @import("c_api/objects.zig").zova_object_writer_cancel;

pub const zova_object_writer_destroy = @import("c_api/objects.zig").zova_object_writer_destroy;

pub const zova_object_reader_create = @import("c_api/objects.zig").zova_object_reader_create;

pub const zova_object_reader_read = @import("c_api/objects.zig").zova_object_reader_read;

pub const zova_object_reader_destroy = @import("c_api/objects.zig").zova_object_reader_destroy;

pub const zova_vector_collection_create = @import("c_api/vectors.zig").zova_vector_collection_create;

pub const zova_vector_collection_exists = @import("c_api/vectors.zig").zova_vector_collection_exists;

pub const zova_vector_put = @import("c_api/vectors.zig").zova_vector_put;

pub const zova_vector_get = @import("c_api/vectors.zig").zova_vector_get;

pub const zova_vector_exists = @import("c_api/vectors.zig").zova_vector_exists;

pub const zova_vector_delete = @import("c_api/vectors.zig").zova_vector_delete;

pub const zova_vector_search = @import("c_api/vectors.zig").zova_vector_search;

pub const zova_vector_search_in = @import("c_api/vectors.zig").zova_vector_search_in;

pub const zova_vector_search_multi_i8 = @import("c_api/vectors.zig").zova_vector_search_multi_i8;

pub const zova_vector_collection_info_get = @import("c_api/vectors.zig").zova_vector_collection_info_get;

pub const zova_vector_collections_list = @import("c_api/vectors.zig").zova_vector_collections_list;

pub const zova_vector_put_many = @import("c_api/vectors.zig").zova_vector_put_many;

pub const zova_vector_delete_many = @import("c_api/vectors.zig").zova_vector_delete_many;

pub const zova_vector_collection_delete = @import("c_api/vectors.zig").zova_vector_collection_delete;

pub const zova_vector_search_within = @import("c_api/vectors.zig").zova_vector_search_within;

pub const zova_vector_search_in_within = @import("c_api/vectors.zig").zova_vector_search_in_within;

pub const zova_vector_search_by_id = @import("c_api/vectors.zig").zova_vector_search_by_id;

pub const zova_vector_search_by_id_in = @import("c_api/vectors.zig").zova_vector_search_by_id_in;

pub const zova_vector_search_by_id_within = @import("c_api/vectors.zig").zova_vector_search_by_id_within;

pub const zova_vector_search_by_id_in_within = @import("c_api/vectors.zig").zova_vector_search_by_id_in_within;

pub const zova_graph_create = @import("c_api/graphs.zig").zova_graph_create;

pub const zova_graph_exists = @import("c_api/graphs.zig").zova_graph_exists;

pub const zova_graph_info_get = @import("c_api/graphs.zig").zova_graph_info_get;

pub const zova_graphs_list = @import("c_api/graphs.zig").zova_graphs_list;

pub const zova_database_extension_install = @import("c_api/extensions.zig").zova_database_extension_install;
pub const zova_database_extension_upgrade = @import("c_api/extensions.zig").zova_database_extension_upgrade;
pub const zova_database_extension_rebuild = @import("c_api/extensions.zig").zova_database_extension_rebuild;
pub const zova_database_open_for_extension_upgrade = @import("c_api/database.zig").zova_database_open_for_extension_upgrade;
pub const zova_database_create_with_plugins = @import("c_api/database.zig").zova_database_create_with_plugins;
pub const zova_database_open_with_plugins = @import("c_api/database.zig").zova_database_open_with_plugins;
pub const zova_database_open_for_extension_upgrade_with_plugins = @import("c_api/database.zig").zova_database_open_for_extension_upgrade_with_plugins;
pub const zova_database_migrate_with_extensions = @import("c_api/database.zig").zova_database_migrate_with_extensions;

pub const zova_database_extension_list = @import("c_api/extensions.zig").zova_database_extension_list;

pub const zova_database_extension_info = @import("c_api/extensions.zig").zova_database_extension_info;

pub const zova_database_extension_check = @import("c_api/extensions.zig").zova_database_extension_check;

pub const zova_database_extension_check_all = @import("c_api/extensions.zig").zova_database_extension_check_all;

pub const zova_database_extension_drop = @import("c_api/extensions.zig").zova_database_extension_drop;

pub const zova_fresh_build_begin = @import("c_api/fresh_build.zig").zova_fresh_build_begin;

pub const zova_fresh_build_table_rows = @import("c_api/fresh_build.zig").zova_fresh_build_table_rows;

pub const zova_fresh_build_fts_rows = @import("c_api/fresh_build.zig").zova_fresh_build_fts_rows;

pub const zova_fresh_build_graph = @import("c_api/fresh_build.zig").zova_fresh_build_graph;

pub const zova_fresh_build_vectors = @import("c_api/fresh_build.zig").zova_fresh_build_vectors;

pub const zova_fresh_build_finish = @import("c_api/fresh_build.zig").zova_fresh_build_finish;

pub const zova_fresh_build_abort = @import("c_api/fresh_build.zig").zova_fresh_build_abort;

pub const zova_fresh_build_destroy = @import("c_api/fresh_build.zig").zova_fresh_build_destroy;

pub const zova_graph_delete = @import("c_api/graphs.zig").zova_graph_delete;

pub const zova_graph_node_put = @import("c_api/graphs.zig").zova_graph_node_put;

pub const zova_graph_node_put_many = @import("c_api/graphs.zig").zova_graph_node_put_many;

pub const zova_graph_node_put_many_keyed = @import("c_api/graphs.zig").zova_graph_node_put_many_keyed;

pub const zova_graph_build_fresh_keyed = @import("c_api/graphs.zig").zova_graph_build_fresh_keyed;

pub const zova_graph_build_fresh_prepared_keyed = @import("c_api/graphs.zig").zova_graph_build_fresh_prepared_keyed;

pub const zova_graph_build_fresh_prepared_keyed_with_payloads = @import("c_api/graphs.zig").zova_graph_build_fresh_prepared_keyed_with_payloads;

pub const zova_graph_node_get = @import("c_api/graphs.zig").zova_graph_node_get;

pub const zova_graph_node_exists = @import("c_api/graphs.zig").zova_graph_node_exists;

pub const zova_graph_node_delete = @import("c_api/graphs.zig").zova_graph_node_delete;

pub const zova_graph_node_delete_many = @import("c_api/graphs.zig").zova_graph_node_delete_many;

pub const zova_graph_edge_put = @import("c_api/graphs.zig").zova_graph_edge_put;

pub const zova_graph_edge_put_many = @import("c_api/graphs.zig").zova_graph_edge_put_many;

pub const zova_graph_edge_put_many_keyed = @import("c_api/graphs.zig").zova_graph_edge_put_many_keyed;

pub const zova_graph_edge_delete_many = @import("c_api/graphs.zig").zova_graph_edge_delete_many;

pub const zova_graph_edge_get = @import("c_api/graphs.zig").zova_graph_edge_get;

pub const zova_graph_edge_exists = @import("c_api/graphs.zig").zova_graph_edge_exists;

pub const zova_graph_edge_delete = @import("c_api/graphs.zig").zova_graph_edge_delete;

pub const zova_graph_neighbors = @import("c_api/graphs.zig").zova_graph_neighbors;

pub const zova_graph_neighbors_keyed = @import("c_api/graphs.zig").zova_graph_neighbors_keyed;

pub const zova_graph_nodes_get_many_keyed = @import("c_api/graphs.zig").zova_graph_nodes_get_many_keyed;

pub const zova_graph_edges_get_many_keyed = @import("c_api/graphs.zig").zova_graph_edges_get_many_keyed;

pub const zova_graph_edge_payload_get_many = @import("c_api/graphs.zig").zova_graph_edge_payload_get_many;

pub const zova_graph_edge_payload_replace_many = @import("c_api/graphs.zig").zova_graph_edge_payload_replace_many;

pub const zova_graph_degree = @import("c_api/graphs.zig").zova_graph_degree;

pub const zova_graph_degree_many_keyed = @import("c_api/graphs.zig").zova_graph_degree_many_keyed;

pub const zova_graph_scan = @import("c_api/graphs.zig").zova_graph_scan;

pub const zova_graph_walk = @import("c_api/graphs.zig").zova_graph_walk;

pub const zova_graph_walk_direction = @import("c_api/graphs.zig").zova_graph_walk_direction;

pub const zova_graph_walk_direction_profiled = @import("c_api/graphs.zig").zova_graph_walk_direction_profiled;

const databaseHandleRaw = @import("c_api/handles.zig").databaseHandleRaw;

const f32AbiValues = @import("c_api/values.zig").f32AbiValues;

const i8AbiValues = @import("c_api/values.zig").i8AbiValues;

const emptyNotification = @import("c_api/results.zig").emptyNotification;

const emptyVector = @import("c_api/results.zig").emptyVector;

const emptyVectorSearchResults = @import("c_api/results.zig").emptyVectorSearchResults;

const emptyVectorCollectionInfo = @import("c_api/results.zig").emptyVectorCollectionInfo;

const emptyExtensionInfo = @import("c_api/results.zig").emptyExtensionInfo;

const emptyExtensionList = @import("c_api/results.zig").emptyExtensionList;
