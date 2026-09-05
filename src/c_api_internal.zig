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

const zova_version = @import("version.zig");

const kv_impl = @import("kv.zig");

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

const databaseHandle = @import("c_api/handles.zig").databaseHandle;

const f32AbiValues = @import("c_api/values.zig").f32AbiValues;

const i8AbiValues = @import("c_api/values.zig").i8AbiValues;

const emptyNotification = @import("c_api/results.zig").emptyNotification;

const emptyVector = @import("c_api/results.zig").emptyVector;

const emptyVectorSearchResults = @import("c_api/results.zig").emptyVectorSearchResults;

const emptyVectorCollectionInfo = @import("c_api/results.zig").emptyVectorCollectionInfo;

const emptyExtensionInfo = @import("c_api/results.zig").emptyExtensionInfo;

const emptyExtensionList = @import("c_api/results.zig").emptyExtensionList;

test "c abi validates null pointers" {
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_create(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_create_with_extensions(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_open_with_options(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_open_with_extensions(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_extension_bundle_verify(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_extension_bundle_trust(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_extension_bundle_untrust(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_register_function(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_set_busy_timeout(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_object_id_from_bytes(null, 1, null));
    var id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_object_id_from_bytes(null, 1, &id));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_collection_create(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_put(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_multi_i8(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_collection_info_get(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_collections_list(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_put_many(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_collection_delete(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_within(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_in_within(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_by_id(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_by_id_in(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_by_id_within(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_by_id_in_within(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_begin(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_begin_immediate(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_commit(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_rollback(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_vacuum(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_savepoint(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_rollback_to_savepoint(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_release_savepoint(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_backup(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_compact(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_restore(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_last_insert_rowid(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_changes(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_total_changes(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_notify(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_listen(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_subscription_try_receive(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_subscription_close(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_create(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_exists(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_info_get(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graphs_list(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_delete(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_put(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_put_many(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_put_many_keyed(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_build_fresh_keyed(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_build_fresh_prepared_keyed(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_get(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_exists(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_delete(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_delete_many(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_put(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_put_many(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_put_many_keyed(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_delete_many(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_get(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_exists(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_delete(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_neighbors(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_neighbors_keyed(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_degree(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_degree_many_keyed(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_scan(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_walk(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_walk_direction(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_delete_many(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_prepare(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_finalize(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_step(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_reset(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_clear_bindings(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_bind_null(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_bind_int64(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_bind_double(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_bind_text(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_bind_blob(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_parameter_count(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_parameter_index(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_column_count(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_column_name(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_column_type(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_column_int64(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_column_double(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_column_text(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_column_blob(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_buffer_free_and_status_for_test());
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_probe_format(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_migrate(null));
}

test "c abi probe and migrate cover compatibility success failure and immutability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    // helpers
    const copyFixture = struct {
        fn call(fixture: []const u8, dest: [:0]const u8) !void {
            const io2 = std.Io.Threaded.global_single_threaded.io();
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io2, fixture, std.testing.allocator, .limited(64 * 1024 * 1024));
            defer std.testing.allocator.free(bytes);
            try std.Io.Dir.cwd().writeFile(io2, .{ .sub_path = dest, .data = bytes });
        }
    }.call;
    const fileHash = struct {
        fn call(path: [:0]const u8) ![32]u8 {
            const io2 = std.Io.Threaded.global_single_threaded.io();
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io2, path, std.testing.allocator, .limited(64 * 1024 * 1024));
            defer std.testing.allocator.free(bytes);
            var d: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
            return d;
        }
    }.call;

    // Current format probe
    {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&buf, ".zig-cache/tmp/{s}/c-probe-current.zova", .{tmp.sub_path[0..]});
        {
            var db = try zova.Database.create(path);
            defer db.deinit();
        }
        var out: zova_database_format_info = undefined;
        out = .{ .format_version = 0xdeadbeef, .compatibility = 0x7fffffff };
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        try std.testing.expectEqual(zova_status.OK, zova_database_probe_format(&.{ .path = path, .out_info = &out, .out_error_message = &msg }));
        try std.testing.expectEqual(@as(u32, 11), out.format_version);
        try std.testing.expectEqual(@intFromEnum(zova_format_compatibility.CURRENT), out.compatibility);
    }
    // Migratable fixture
    {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src = try std.fmt.bufPrintZ(&src_buf, ".zig-cache/tmp/{s}/c-probe-migratable.zova", .{tmp.sub_path[0..]});
        try copyFixture("tests/fixtures/format-9.zova", src);
        var out: zova_database_format_info = undefined;
        out = .{};
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        try std.testing.expectEqual(zova_status.OK, zova_database_probe_format(&.{ .path = src, .out_info = &out, .out_error_message = &msg }));
        try std.testing.expectEqual(@as(u32, 9), out.format_version);
        try std.testing.expectEqual(@intFromEnum(zova_format_compatibility.MIGRATABLE), out.compatibility);
    }
    // Future and legacy synthetic
    for ([_]struct { ver: []const u8, expected: zova_format_compatibility }{
        .{ .ver = "12", .expected = .UNSUPPORTED_FUTURE },
        .{ .ver = "8", .expected = .UNSUPPORTED_LEGACY },
    }) |case| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&buf, ".zig-cache/tmp/{s}/c-probe-{s}.zova", .{ tmp.sub_path[0..], case.ver });
        {
            var db = try zova.Database.create(path);
            defer db.deinit();
        }
        {
            var raw = try sqlite.Database.open(path);
            defer raw.deinit();
            var stmt = try raw.prepare("update _zova_meta set value = ? where key = 'format_version'");
            defer stmt.deinit();
            try stmt.bindText(1, case.ver);
            _ = try stmt.step();
        }
        var out: zova_database_format_info = undefined;
        out = .{};
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        try std.testing.expectEqual(zova_status.OK, zova_database_probe_format(&.{ .path = path, .out_info = &out, .out_error_message = &msg }));
        try std.testing.expectEqual(@intFromEnum(case.expected), out.compatibility);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, case.ver, 10), out.format_version);
    }
    // Successful migrate with source immutability and bound-store reporting
    {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src = try std.fmt.bufPrintZ(&src_buf, ".zig-cache/tmp/{s}/c-migrate-src.zova", .{tmp.sub_path[0..]});
        try copyFixture("tests/fixtures/format-9.zova", src);
        const before = try fileHash(src);
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst = try std.fmt.bufPrintZ(&dst_buf, ".zig-cache/tmp/{s}/c-migrate-dst.zova", .{tmp.sub_path[0..]});
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        try std.testing.expectEqual(zova_status.OK, zova_database_migrate(&.{ .source_path = src, .destination_path = dst, .flags = 0, .out_error_message = &msg }));
        const after = try fileHash(src);
        try std.testing.expectEqualSlices(u8, &before, &after);
        var out: zova_database_format_info = undefined;
        out = .{};
        var probe_msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&probe_msg);
        try std.testing.expectEqual(zova_status.OK, zova_database_probe_format(&.{ .path = dst, .out_info = &out, .out_error_message = &probe_msg }));
        try std.testing.expectEqual(@as(u32, 11), out.format_version);
        try std.testing.expectEqual(@intFromEnum(zova_format_compatibility.CURRENT), out.compatibility);
        // destination is openable and no private names leaked via C output (checked via probe/migrate out_info)
        var db = try zova.Database.open(dst);
        defer db.deinit();
        try std.testing.expectEqual(@as(u32, 11), try std.fmt.parseInt(u32, zova_version.format_version, 10));
    }
    // Destination exists
    {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src = try std.fmt.bufPrintZ(&src_buf, ".zig-cache/tmp/{s}/c-migrate-dest-exists-src.zova", .{tmp.sub_path[0..]});
        try copyFixture("tests/fixtures/format-9.zova", src);
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst = try std.fmt.bufPrintZ(&dst_buf, ".zig-cache/tmp/{s}/c-migrate-dest-exists-dst.zova", .{tmp.sub_path[0..]});
        {
            var db = try zova.Database.create(dst);
            defer db.deinit();
        }
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        try std.testing.expectEqual(zova_status.DESTINATION_EXISTS, zova_database_migrate(&.{ .source_path = src, .destination_path = dst, .flags = 0, .out_error_message = &msg }));
    }
    // Unsupported future/legacy via C
    for ([_]struct { ver: []const u8, expected: zova_status }{
        .{ .ver = "12", .expected = .UNSUPPORTED_FUTURE_FORMAT },
        .{ .ver = "8", .expected = .UNSUPPORTED_LEGACY_FORMAT },
    }) |case| {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src = try std.fmt.bufPrintZ(&src_buf, ".zig-cache/tmp/{s}/c-migrate-unsupported-{s}.zova", .{ tmp.sub_path[0..], case.ver });
        {
            var db = try zova.Database.create(src);
            defer db.deinit();
        }
        {
            var raw = try sqlite.Database.open(src);
            defer raw.deinit();
            var stmt = try raw.prepare("update _zova_meta set value = ? where key = 'format_version'");
            defer stmt.deinit();
            try stmt.bindText(1, case.ver);
            _ = try stmt.step();
        }
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst = try std.fmt.bufPrintZ(&dst_buf, ".zig-cache/tmp/{s}/c-migrate-unsupported-{s}-dst.zova", .{ tmp.sub_path[0..], case.ver });
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        const status = zova_database_migrate(&.{ .source_path = src, .destination_path = dst, .flags = 0, .out_error_message = &msg });
        try std.testing.expectEqual(case.expected, status);
        // no destination published
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, dst, .{}));
    }
    // NoMigrationPath (migrate current)
    {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src = try std.fmt.bufPrintZ(&src_buf, ".zig-cache/tmp/{s}/c-migrate-current.zova", .{tmp.sub_path[0..]});
        {
            var db = try zova.Database.create(src);
            defer db.deinit();
        }
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst = try std.fmt.bufPrintZ(&dst_buf, ".zig-cache/tmp/{s}/c-migrate-current-dst.zova", .{tmp.sub_path[0..]});
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        try std.testing.expectEqual(zova_status.NO_MIGRATION_PATH, zova_database_migrate(&.{ .source_path = src, .destination_path = dst, .flags = 0, .out_error_message = &msg }));
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, dst, .{}));
    }
    // Busy source
    {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src = try std.fmt.bufPrintZ(&src_buf, ".zig-cache/tmp/{s}/c-migrate-busy.zova", .{tmp.sub_path[0..]});
        try copyFixture("tests/fixtures/format-9.zova", src);
        var lock = try sqlite.Database.open(src);
        defer lock.deinit();
        try lock.exec("begin immediate");
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst = try std.fmt.bufPrintZ(&dst_buf, ".zig-cache/tmp/{s}/c-migrate-busy-dst.zova", .{tmp.sub_path[0..]});
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        const status = zova_database_migrate(&.{ .source_path = src, .destination_path = dst, .flags = 0, .out_error_message = &msg });
        try std.testing.expect(status == .BUSY or status == .LOCKED);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, dst, .{}));
    }
    // Verification failure (corrupt _zova_chunks)
    {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src = try std.fmt.bufPrintZ(&src_buf, ".zig-cache/tmp/{s}/c-migrate-verify-fail.zova", .{tmp.sub_path[0..]});
        try copyFixture("tests/fixtures/format-9.zova", src);
        {
            var raw = try sqlite.Database.open(src);
            defer raw.deinit();
            try raw.exec("update _zova_chunks set data = randomblob(size_bytes) where rowid = (select rowid from _zova_chunks limit 1)");
        }
        const before = try fileHash(src);
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst = try std.fmt.bufPrintZ(&dst_buf, ".zig-cache/tmp/{s}/c-migrate-verify-dst.zova", .{tmp.sub_path[0..]});
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        const status = zova_database_migrate(&.{ .source_path = src, .destination_path = dst, .flags = 0, .out_error_message = &msg });
        // verification failure maps to check_failed (CORRUPT etc) -> non-OK, not DEST exists
        try std.testing.expect(status != .OK);
        try std.testing.expect(status != .DESTINATION_EXISTS);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, dst, .{}));
        const after = try fileHash(src);
        try std.testing.expectEqualSlices(u8, &before, &after);
        // with NO_VERIFY it would succeed
        var dst2_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst2 = try std.fmt.bufPrintZ(&dst2_buf, ".zig-cache/tmp/{s}/c-migrate-verify-dst2.zova", .{tmp.sub_path[0..]});
        var msg2 = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg2);
        try std.testing.expectEqual(zova_status.OK, zova_database_migrate(&.{ .source_path = src, .destination_path = dst2, .flags = ZOVA_MIGRATE_NO_VERIFY, .out_error_message = &msg2 }));
        _ = try std.Io.Dir.cwd().statFile(io, dst2, .{});
    }
    // Zero output before work: probe with invalid path must zero out_info
    {
        var out: zova_database_format_info = undefined;
        out = .{ .format_version = 0xdeadbeef, .compatibility = 0x7fffffff };
        var msg = zova_message{ .data = null, .len = 0 };
        defer zova_message_free(&msg);
        try std.testing.expectEqual(zova_status.NOT_ZOVA_PATH, zova_database_probe_format(&.{ .path = "bad.txt", .out_info = &out, .out_error_message = &msg }));
        try std.testing.expectEqual(@as(u32, 0), out.format_version);
        try std.testing.expectEqual(@as(c_int, 0), out.compatibility);
    }
}

const SqlFunctionTestState = struct {
    calls: usize = 0,
    destroyed: bool = false,
    saw_user_data: bool = false,
    saw_null: bool = false,
    saw_int: bool = false,
    saw_float: bool = false,
    saw_text: bool = false,
    saw_blob: bool = false,
};

fn sqlFunctionDestroy(user_data: ?*anyopaque) callconv(.c) void {
    const state: *SqlFunctionTestState = @ptrCast(@alignCast(user_data.?));
    state.destroyed = true;
}

fn sqlFunctionMixed(user_data: ?*anyopaque, call: ?*const zova_sql_function_call, out: ?*zova_sql_result) callconv(.c) void {
    const state: *SqlFunctionTestState = @ptrCast(@alignCast(user_data.?));
    const args = call.?.argv.?[0..call.?.argc];
    state.calls += 1;
    state.saw_user_data = call.?.user_data == user_data;
    state.saw_null = args[0].value_type == .NULL;
    state.saw_int = args[1].value_type == .INTEGER and args[1].int64_value == 7;
    state.saw_float = args[2].value_type == .FLOAT and args[2].double_value == 2.5;
    state.saw_text = args[3].value_type == .TEXT and args[3].data_len == 3 and std.mem.eql(u8, bytesFromAny(args[3].data, args[3].data_len), "abc");
    state.saw_blob = args[4].value_type == .BLOB and args[4].data_len == 3 and std.mem.eql(u8, bytesFromAny(args[4].data, args[4].data_len), &.{ 0x0a, 0x0b, 0x0c });
    out.?.* = .{ .result_type = @intFromEnum(zova_sql_result_type.INTEGER), .int64_value = 42 };
}

fn sqlFunctionText(_: ?*anyopaque, _: ?*const zova_sql_function_call, out: ?*zova_sql_result) callconv(.c) void {
    out.?.* = .{ .result_type = @intFromEnum(zova_sql_result_type.TEXT), .data = "hello".ptr, .data_len = 5 };
}

const sql_function_blob_bytes = [_]u8{ 1, 2, 3, 4 };

fn sqlFunctionBlob(_: ?*anyopaque, _: ?*const zova_sql_function_call, out: ?*zova_sql_result) callconv(.c) void {
    out.?.* = .{ .result_type = @intFromEnum(zova_sql_result_type.BLOB), .data = &sql_function_blob_bytes, .data_len = sql_function_blob_bytes.len };
}

fn sqlFunctionError(_: ?*anyopaque, _: ?*const zova_sql_function_call, out: ?*zova_sql_result) callconv(.c) void {
    out.?.* = .{ .result_type = @intFromEnum(zova_sql_result_type.ERROR), .error_message = "callback failed".ptr, .error_message_len = "callback failed".len };
}

fn sqlFunctionContains(_: ?*anyopaque, call: ?*const zova_sql_function_call, out: ?*zova_sql_result) callconv(.c) void {
    const args = call.?.argv.?[0..call.?.argc];
    if (args.len != 2 or args[0].value_type != .TEXT or args[1].value_type != .TEXT) {
        out.?.* = .{ .result_type = @intFromEnum(zova_sql_result_type.ERROR), .error_message = "regexp expects two text args".ptr, .error_message_len = "regexp expects two text args".len };
        return;
    }
    const needle = bytesFromAny(args[0].data, args[0].data_len);
    const haystack = bytesFromAny(args[1].data, args[1].data_len);
    const matched = std.mem.indexOf(u8, haystack, needle) != null;
    out.?.* = .{ .result_type = @intFromEnum(zova_sql_result_type.INTEGER), .int64_value = @intFromBool(matched) };
}

fn sqlFunctionContainsIgnoreCase(_: ?*anyopaque, call: ?*const zova_sql_function_call, out: ?*zova_sql_result) callconv(.c) void {
    const args = call.?.argv.?[0..call.?.argc];
    if (args.len != 2 or args[0].value_type != .TEXT or args[1].value_type != .TEXT) {
        out.?.* = .{ .result_type = @intFromEnum(zova_sql_result_type.ERROR), .error_message = "iregexp expects two text args".ptr, .error_message_len = "iregexp expects two text args".len };
        return;
    }
    const needle = bytesFromAny(args[0].data, args[0].data_len);
    const haystack = bytesFromAny(args[1].data, args[1].data_len);
    const matched = asciiContainsIgnoreCase(haystack, needle);
    out.?.* = .{ .result_type = @intFromEnum(zova_sql_result_type.INTEGER), .int64_value = @intFromBool(matched) };
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var matched = true;
        for (needle, 0..) |needle_byte, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle_byte)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn bytesFromAny(ptr: ?*const anyopaque, len: usize) []const u8 {
    const many: [*]const u8 = @ptrCast(ptr.?);
    return many[0..len];
}

test "c abi validates scalar sql function registration requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-sql-function-validation.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    var state = SqlFunctionTestState{};
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_register_function(&.{
        .db = null,
        .name = "app_fn",
        .arity = 0,
        .flags = 0,
        .user_data = &state,
        .callback = sqlFunctionMixed,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_register_function(&.{
        .db = db,
        .name = null,
        .arity = 0,
        .flags = 0,
        .user_data = &state,
        .callback = sqlFunctionMixed,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_register_function(&.{
        .db = db,
        .name = "1bad",
        .arity = 0,
        .flags = 0,
        .user_data = &state,
        .callback = sqlFunctionMixed,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_register_function(&.{
        .db = db,
        .name = "zova_private",
        .arity = 0,
        .flags = 0,
        .user_data = &state,
        .callback = sqlFunctionMixed,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_register_function(&.{
        .db = db,
        .name = "app_fn",
        .arity = -2,
        .flags = 0,
        .user_data = &state,
        .callback = sqlFunctionMixed,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_register_function(&.{
        .db = db,
        .name = "app_fn",
        .arity = 128,
        .flags = 0,
        .user_data = &state,
        .callback = sqlFunctionMixed,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_register_function(&.{
        .db = db,
        .name = "app_fn",
        .arity = 0,
        .flags = 0xffff_ffff,
        .user_data = &state,
        .callback = sqlFunctionMixed,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_register_function(&.{
        .db = db,
        .name = "app_fn",
        .arity = 0,
        .flags = 0,
        .user_data = &state,
        .callback = null,
        .destroy = null,
    }));

    try std.testing.expectEqual(zova_status.OK, zova_database_register_function(&.{
        .db = db,
        .name = "app_fn",
        .arity = 0,
        .flags = ZOVA_SQL_FUNCTION_DETERMINISTIC,
        .user_data = &state,
        .callback = sqlFunctionText,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_register_function(&.{
        .db = db,
        .name = "app_fn",
        .arity = 0,
        .flags = 0,
        .user_data = &state,
        .callback = sqlFunctionText,
        .destroy = null,
    }));
}

test "c abi registers scalar sql functions on zova owned connections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-sql-functions.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));

    var state = SqlFunctionTestState{};
    try std.testing.expectEqual(zova_status.OK, zova_database_register_function(&.{
        .db = db,
        .name = "app_mix",
        .arity = 5,
        .flags = ZOVA_SQL_FUNCTION_DETERMINISTIC | ZOVA_SQL_FUNCTION_INNOCUOUS,
        .user_data = &state,
        .callback = sqlFunctionMixed,
        .destroy = sqlFunctionDestroy,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_register_function(&.{
        .db = db,
        .name = "app_text",
        .arity = 0,
        .flags = ZOVA_SQL_FUNCTION_DIRECT_ONLY,
        .user_data = null,
        .callback = sqlFunctionText,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_register_function(&.{
        .db = db,
        .name = "app_blob",
        .arity = -1,
        .flags = 0,
        .user_data = null,
        .callback = sqlFunctionBlob,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_register_function(&.{
        .db = db,
        .name = "app_fail",
        .arity = 0,
        .flags = 0,
        .user_data = null,
        .callback = sqlFunctionError,
        .destroy = null,
    }));

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select app_mix(null, 7, 2.5, 'abc', x'0a0b0c'), app_text(), app_blob(1, 2)",
        .out_statement = &stmt,
    }));
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);

    var int_value: i64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = stmt, .index = 0, .out_value = &int_value }));
    try std.testing.expectEqual(@as(i64, 42), int_value);

    var text = zova_text{ .data = null, .len = 0 };
    defer zova_text_free(&text);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_text(&.{ .statement = stmt, .index = 1, .out_text = &text }));
    try std.testing.expectEqualStrings("hello", text.data.?[0..text.len]);

    var blob = zova_buffer{ .data = null, .len = 0 };
    defer zova_buffer_free(&blob);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_blob(&.{ .statement = stmt, .index = 2, .out_buffer = &blob }));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, blob.data.?[0..blob.len]);
    try std.testing.expectEqual(zova_status.OK, zova_statement_finalize(stmt));

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.saw_user_data);
    try std.testing.expect(state.saw_null);
    try std.testing.expect(state.saw_int);
    try std.testing.expect(state.saw_float);
    try std.testing.expect(state.saw_text);
    try std.testing.expect(state.saw_blob);

    try std.testing.expectEqual(zova_status.SQLITE_ERROR, zova_database_exec(&.{ .db = db, .sql = "select app_fail()" }));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zova_database_last_error_message(db)), "callback failed") != null);

    try std.testing.expect(!state.destroyed);
    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
    try std.testing.expect(state.destroyed);
}

test "c abi app regexp callbacks coexist with fts5 on zova owned connection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-fts-regexp.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_register_function(&.{
        .db = db,
        .name = "regexp",
        .arity = 2,
        .flags = ZOVA_SQL_FUNCTION_DETERMINISTIC | ZOVA_SQL_FUNCTION_INNOCUOUS,
        .user_data = null,
        .callback = sqlFunctionContains,
        .destroy = null,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_register_function(&.{
        .db = db,
        .name = "iregexp",
        .arity = 2,
        .flags = ZOVA_SQL_FUNCTION_DETERMINISTIC | ZOVA_SQL_FUNCTION_INNOCUOUS,
        .user_data = null,
        .callback = sqlFunctionContainsIgnoreCase,
        .destroy = null,
    }));

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql =
        \\create virtual table docs using fts5(body);
        \\insert into docs (body) values ('zova wraps sqlite');
        \\insert into docs (body) values ('plain unrelated row');
    }));

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select body from docs where docs match 'sqlite' and regexp('zova', body) and iregexp('SQLITE', body)",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);

    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);

    var text = zova_text{ .data = null, .len = 0 };
    defer zova_text_free(&text);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_text(&.{ .statement = stmt, .index = 0, .out_text = &text }));
    try std.testing.expectEqualStrings("zova wraps sqlite", text.data.?[0..text.len]);

    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.DONE, step_result);
}

test "c abi app callbacks coexist with bundled extension vector graph and notification sql" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-coexistence.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_register_function(&.{
        .db = db,
        .name = "regexp",
        .arity = 2,
        .flags = ZOVA_SQL_FUNCTION_DETERMINISTIC | ZOVA_SQL_FUNCTION_INNOCUOUS,
        .user_data = null,
        .callback = sqlFunctionContains,
        .destroy = null,
    }));

    try std.testing.expectEqual(zova_status.OK, zova_database_extension_install(&.{
        .db = db,
        .name = "trgm",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_extension_check(&.{
        .db = db,
        .name = "trgm",
    }));

    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&.{
        .db = db,
        .name = "co_vectors",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = @intFromEnum(zova_vector_element_type.I8) },
    }));
    const near = [_]i8{ 1, 0 };
    const far = [_]i8{ 5, 0 };
    try std.testing.expectEqual(zova_status.OK, zova_vector_put(&.{
        .db = db,
        .collection_name = "co_vectors",
        .vector_id = "near",
        .values = i8AbiValues(&near),
    }));
    try std.testing.expectEqual(zova_status.OK, zova_vector_put(&.{
        .db = db,
        .collection_name = "co_vectors",
        .vector_id = "far",
        .values = i8AbiValues(&far),
    }));

    try std.testing.expectEqual(zova_status.OK, zova_graph_create(&.{ .db = db, .name = "co_graph" }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_put(&.{
        .db = db,
        .graph_name = "co_graph",
        .node_id = "near",
        .kind = "vector",
        .target_type = @intFromEnum(zova_graph_target_type.VECTOR),
        .target_namespace = "co_vectors",
        .target_ref = "near",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_put(&.{
        .db = db,
        .graph_name = "co_graph",
        .node_id = "far",
        .kind = "vector",
        .target_type = @intFromEnum(zova_graph_target_type.VECTOR),
        .target_namespace = "co_vectors",
        .target_ref = "far",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_put(&.{
        .db = db,
        .graph_name = "co_graph",
        .from_node_id = "near",
        .edge_type = "compares_to",
        .to_node_id = "far",
    }));

    {
        var statement: ?*zova_statement = null;
        try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
            .db = db,
            .sql = "select regexp('zova', 'zova callbacks')",
            .out_statement = &statement,
        }));
        defer _ = zova_statement_finalize(statement);

        var step_result: zova_step_result = undefined;
        try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = statement, .out_result = &step_result }));
        try std.testing.expectEqual(zova_step_result.ROW, step_result);
        var matched: i64 = 0;
        try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = statement, .index = 0, .out_value = &matched }));
        try std.testing.expectEqual(@as(i64, 1), matched);
    }

    {
        var statement: ?*zova_statement = null;
        try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
            .db = db,
            .sql = "select zova_notify('coexistence', 'ok')",
            .out_statement = &statement,
        }));
        defer _ = zova_statement_finalize(statement);

        var step_result: zova_step_result = undefined;
        try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = statement, .out_result = &step_result }));
        try std.testing.expectEqual(zova_step_result.ROW, step_result);
    }

    {
        const query = [_]u8{ 1, 0 };
        var statement: ?*zova_statement = null;
        try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
            .db = db,
            .sql = "select vector_id from zova_vector_search where collection = 'co_vectors' and query_vector = zova_vector_encode_i8(?) and top_k = 1 order by rank",
            .out_statement = &statement,
        }));
        defer _ = zova_statement_finalize(statement);
        try std.testing.expectEqual(zova_status.OK, zova_statement_bind_blob(&.{ .statement = statement, .index = 1, .data = &query, .len = query.len }));

        var step_result: zova_step_result = undefined;
        try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = statement, .out_result = &step_result }));
        try std.testing.expectEqual(zova_step_result.ROW, step_result);

        var text = zova_text{ .data = null, .len = 0 };
        defer zova_text_free(&text);
        try std.testing.expectEqual(zova_status.OK, zova_statement_column_text(&.{ .statement = statement, .index = 0, .out_text = &text }));
        try std.testing.expectEqualStrings("near", text.data.?[0..text.len]);
    }

    {
        var statement: ?*zova_statement = null;
        try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
            .db = db,
            .sql =
            \\select node_id
            \\from zova_graph_neighbors
            \\where graph_name = 'co_graph'
            \\  and source_node_id = 'near'
            \\  and direction = 'outgoing'
            \\  and "limit" = 1
            ,
            .out_statement = &statement,
        }));
        defer _ = zova_statement_finalize(statement);

        var step_result: zova_step_result = undefined;
        try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = statement, .out_result = &step_result }));
        try std.testing.expectEqual(zova_step_result.ROW, step_result);

        var text = zova_text{ .data = null, .len = 0 };
        defer zova_text_free(&text);
        try std.testing.expectEqual(zova_status.OK, zova_statement_column_text(&.{ .statement = statement, .index = 0, .out_text = &text }));
        try std.testing.expectEqualStrings("far", text.data.?[0..text.len]);
    }
}

test "c abi maps incompatible storage formats to unsupported zova version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct { file_name: []const u8, version_value: []const u8, expected: zova_status }{
        .{ .file_name = "c-abi-format-9.zova", .version_value = "9", .expected = .MIGRATION_REQUIRED },
        .{ .file_name = "c-abi-format-8.zova", .version_value = "8", .expected = .UNSUPPORTED_LEGACY_FORMAT },
        .{ .file_name = "c-abi-format-12.zova", .version_value = "12", .expected = .UNSUPPORTED_FUTURE_FORMAT },
    };

    for (cases) |case| {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], case.file_name });

        {
            var raw = try sqlite.Database.open(db_path);
            defer raw.deinit();
            try raw.exec("create table _zova_meta (key text primary key, value text not null)");
            try raw.exec("insert into _zova_meta (key, value) values ('magic', 'zova')");
            var insert = try raw.prepare("insert into _zova_meta (key, value) values ('format_version', ?)");
            defer insert.deinit();
            try insert.bindText(1, case.version_value);
            _ = try insert.step();
        }

        var db: ?*zova_database = null;
        const status = zova_database_open(&.{
            .path = db_path,
            .out_db = &db,
            .out_error_message = null,
        });
        try std.testing.expectEqual(case.expected, status);
        try std.testing.expect(db == null);
    }

    // The genuine released format-9 fixture through the public ABI.
    var fixture_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture_path = try std.fmt.bufPrintZ(&fixture_buffer, "tests/fixtures/format-9.zova", .{});
    var fixture_db: ?*zova_database = null;
    const fixture_status = zova_database_open(&.{
        .path = fixture_path,
        .out_db = &fixture_db,
        .out_error_message = null,
    });
    try std.testing.expectEqual(zova_status.MIGRATION_REQUIRED, fixture_status);
    try std.testing.expect(fixture_db == null);
}

test "c abi open options validate flags and support read-only handles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-readonly.zova", .{tmp.sub_path[0..]});

    var writable: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &writable,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = writable, .sql = "create table notes (body text not null)" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = writable, .sql = "insert into notes (body) values ('kept')" }));
    var object_id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.OK, zova_object_put(&.{
        .db = writable,
        .data = "readonly object",
        .len = "readonly object".len,
        .out_id = &object_id,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&.{
        .db = writable,
        .name = "chunks",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = @intFromEnum(zova_vector_element_type.F32) },
    }));
    const values = [_]f32{ 1.0, 2.0 };
    try std.testing.expectEqual(zova_status.OK, zova_vector_put(&.{
        .db = writable,
        .collection_name = "chunks",
        .vector_id = "v1",
        .values = f32AbiValues(&values),
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_close(writable));

    var invalid_message = zova_message{ .data = null, .len = 0 };
    var invalid_db: ?*zova_database = null;
    const invalid_request = zova_database_open_options_request{
        .path = db_path,
        .flags = 0xffff_ffff,
        .busy_timeout_ms = 0,
        .out_db = &invalid_db,
        .out_error_message = &invalid_message,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_open_with_options(&invalid_request));
    try std.testing.expect(invalid_db == null);
    zova_message_free(&invalid_message);

    var readonly: ?*zova_database = null;
    const readonly_request = zova_database_open_options_request{
        .path = db_path,
        .flags = ZOVA_OPEN_READ_ONLY,
        .busy_timeout_ms = 1,
        .out_db = &readonly,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_open_with_options(&readonly_request));
    defer _ = zova_database_close(readonly);

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = readonly,
        .sql = "select body from notes",
        .out_statement = &stmt,
    }));
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    try std.testing.expectEqual(zova_status.OK, zova_statement_finalize(stmt));

    var object_exists: u8 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_object_exists(&.{
        .db = readonly,
        .id = object_id,
        .out_exists = &object_exists,
    }));
    try std.testing.expectEqual(@as(u8, 1), object_exists);

    var exists: u8 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_vector_exists(&.{
        .db = readonly,
        .collection_name = "chunks",
        .vector_id = "v1",
        .out_exists = &exists,
    }));
    try std.testing.expectEqual(@as(u8, 1), exists);

    var distance_stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = readonly,
        .sql = "select zova_vector_distance('chunks', 'v1', ?1)",
        .out_statement = &distance_stmt,
    }));
    const query_bytes = std.mem.asBytes(&values);
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_blob(&.{
        .statement = distance_stmt,
        .index = 1,
        .data = query_bytes.ptr,
        .len = query_bytes.len,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = distance_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    try std.testing.expectEqual(zova_status.OK, zova_statement_finalize(distance_stmt));

    try std.testing.expectEqual(zova_status.READ_ONLY, zova_database_exec(&.{ .db = readonly, .sql = "insert into notes (body) values ('blocked')" }));
    var blocked_object_id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    const blocked_object_status = zova_object_put(&.{
        .db = readonly,
        .data = "blocked object",
        .len = "blocked object".len,
        .out_id = &blocked_object_id,
    });
    try std.testing.expect(blocked_object_status != .OK);
    try std.testing.expectEqual(zova_status.READ_ONLY, zova_vector_put(&.{
        .db = readonly,
        .collection_name = "chunks",
        .vector_id = "v2",
        .values = f32AbiValues(&values),
    }));
    const vacuum_status = zova_database_vacuum(&.{ .db = readonly });
    try std.testing.expect(vacuum_status == .READ_ONLY or vacuum_status == .SQLITE_ERROR);
    try std.testing.expectEqual(zova_status.OK, zova_database_set_busy_timeout(&.{ .db = readonly, .milliseconds = 0 }));
    try std.testing.expectEqual(zova_status.OK, zova_database_set_busy_timeout(&.{ .db = readonly, .milliseconds = 2 }));
}

test "c abi exposes graph lifecycle nodes edges and traversal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-graph.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqualStrings("ZOVA_GRAPH_NOT_FOUND", std.mem.span(zova_status_name(@intFromEnum(zova_status.GRAPH_NOT_FOUND))));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_create(&.{ .db = db, .name = null }));
    try std.testing.expectEqual(zova_status.GRAPH_INVALID, zova_graph_create(&.{ .db = db, .name = "_zova_private" }));

    try std.testing.expectEqual(zova_status.OK, zova_graph_create(&.{ .db = db, .name = "app" }));
    try std.testing.expectEqual(zova_status.GRAPH_EXISTS, zova_graph_create(&.{ .db = db, .name = "app" }));

    var exists: u8 = 0;
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_exists(&.{ .db = db, .name = "app", .out_exists = null }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_exists(&.{ .db = db, .name = "app", .out_exists = &exists }));
    try std.testing.expectEqual(@as(u8, 1), exists);

    try std.testing.expectEqual(zova_status.OK, zova_graph_node_put(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "message:1",
        .kind = "message",
        .target_type = @intFromEnum(zova_graph_target_type.RECORD),
        .target_namespace = null,
        .target_ref = "messages:1",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_put(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "message:2",
        .kind = "message",
        .target_type = @intFromEnum(zova_graph_target_type.RECORD),
        .target_namespace = null,
        .target_ref = "messages:2",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_put(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "attachment:1",
        .kind = "attachment",
        .target_type = @intFromEnum(zova_graph_target_type.EXTERNAL),
        .target_namespace = "attachments",
        .target_ref = "",
    }));
    try std.testing.expectEqual(zova_status.GRAPH_INVALID, zova_graph_node_put(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "_zova_bad",
        .kind = "message",
        .target_type = @intFromEnum(zova_graph_target_type.NONE),
        .target_namespace = null,
        .target_ref = null,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_put(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "bad-target",
        .kind = "message",
        .target_type = 99,
        .target_namespace = null,
        .target_ref = null,
    }));

    var info = zova_graph_info{ .name = null, .name_len = 0, .node_count = 0, .edge_count = 0 };
    defer zova_graph_info_free(&info);
    try std.testing.expectEqual(zova_status.OK, zova_graph_info_get(&.{ .db = db, .name = "app", .out_info = &info }));
    try std.testing.expectEqualStrings("app", info.name.?[0..info.name_len]);
    try std.testing.expectEqual(@as(u64, 3), info.node_count);
    zova_graph_info_free(&info);

    var graphs = zova_graph_list{ .items = null, .len = 0 };
    defer zova_graph_list_free(&graphs);
    try std.testing.expectEqual(zova_status.OK, zova_graphs_list(&.{ .db = db, .out_list = &graphs }));
    try std.testing.expectEqual(@as(usize, 1), graphs.len);

    var node = zova_graph_node{
        .graph_name = null,
        .graph_name_len = 0,
        .node_id = null,
        .node_id_len = 0,
        .kind = null,
        .kind_len = 0,
        .target_type = @intFromEnum(zova_graph_target_type.NONE),
        .target_namespace = null,
        .target_namespace_len = 0,
        .target_ref = null,
        .target_ref_len = 0,
        .has_target_namespace = 0,
        .has_target_ref = 0,
    };
    defer zova_graph_node_free(&node);
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_get(&.{ .db = db, .graph_name = "app", .node_id = "attachment:1", .out_node = &node }));
    try std.testing.expectEqualStrings("attachment:1", node.node_id.?[0..node.node_id_len]);
    try std.testing.expectEqual(@as(u8, 1), node.has_target_namespace);
    try std.testing.expectEqualStrings("attachments", node.target_namespace.?[0..node.target_namespace_len]);
    try std.testing.expectEqual(@as(u8, 1), node.has_target_ref);
    try std.testing.expectEqual(@as(usize, 0), node.target_ref_len);

    try std.testing.expectEqual(zova_status.GRAPH_NODE_NOT_FOUND, zova_graph_edge_put(&.{
        .db = db,
        .graph_name = "app",
        .from_node_id = "message:1",
        .edge_type = "missing",
        .to_node_id = "missing",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_put(&.{ .db = db, .graph_name = "app", .from_node_id = "message:1", .edge_type = "replies_to", .to_node_id = "message:2" }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_put(&.{ .db = db, .graph_name = "app", .from_node_id = "message:1", .edge_type = "has_attachment", .to_node_id = "attachment:1" }));

    var edge = zova_graph_edge{ .graph_name = null, .graph_name_len = 0, .from_node_id = null, .from_node_id_len = 0, .edge_type = null, .edge_type_len = 0, .to_node_id = null, .to_node_id_len = 0 };
    defer zova_graph_edge_free(&edge);
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_get(&.{ .db = db, .graph_name = "app", .from_node_id = "message:1", .edge_type = "has_attachment", .to_node_id = "attachment:1", .out_edge = &edge }));
    try std.testing.expectEqualStrings("has_attachment", edge.edge_type.?[0..edge.edge_type_len]);

    var edge_exists: u8 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_exists(&.{ .db = db, .graph_name = "app", .from_node_id = "message:1", .edge_type = "has_attachment", .to_node_id = "attachment:1", .out_exists = &edge_exists }));
    try std.testing.expectEqual(@as(u8, 1), edge_exists);

    var neighbors = zova_graph_neighbor_results{ .items = null, .len = 0 };
    defer zova_graph_neighbor_results_free(&neighbors);
    try std.testing.expectEqual(zova_status.OK, zova_graph_neighbors(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "message:1",
        .direction = @intFromEnum(zova_graph_neighbor_direction.OUTGOING),
        .edge_type = null,
        .limit = 10,
        .out_results = &neighbors,
    }));
    try std.testing.expectEqual(@as(usize, 2), neighbors.len);
    zova_graph_neighbor_results_free(&neighbors);
    try std.testing.expectEqual(zova_status.OK, zova_graph_neighbors(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "message:2",
        .direction = @intFromEnum(zova_graph_neighbor_direction.INCOMING),
        .edge_type = "replies_to",
        .limit = 0,
        .out_results = &neighbors,
    }));
    try std.testing.expectEqual(@as(usize, 0), neighbors.len);

    const too_large_limit: usize = @as(usize, @intCast(std.math.maxInt(i64))) + 1;
    try std.testing.expectEqual(zova_status.GRAPH_INVALID, zova_graph_neighbors(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "message:1",
        .direction = @intFromEnum(zova_graph_neighbor_direction.OUTGOING),
        .edge_type = null,
        .limit = too_large_limit,
        .out_results = &neighbors,
    }));

    var walk = zova_graph_walk_results{ .items = null, .len = 0 };
    defer zova_graph_walk_results_free(&walk);
    try std.testing.expectEqual(zova_status.OK, zova_graph_walk(&.{
        .db = db,
        .graph_name = "app",
        .start_node_id = "message:1",
        .edge_type = null,
        .max_depth = 1,
        .limit = 10,
        .out_results = &walk,
    }));
    try std.testing.expectEqual(@as(usize, 3), walk.len);
    try std.testing.expectEqual(@as(u32, 0), walk.items.?[0].depth);
    try std.testing.expectEqual(@as(u32, 1), walk.items.?[1].depth);
    try std.testing.expectEqual(@as(u8, 1), walk.items.?[1].has_predecessor_node_id);
    zova_graph_walk_results_free(&walk);
    try std.testing.expectEqual(zova_status.OK, zova_graph_walk_direction(&.{
        .db = db,
        .graph_name = "app",
        .start_node_id = "message:1",
        .direction = @intFromEnum(zova_graph_neighbor_direction.OUTGOING),
        .edge_type = "replies_to",
        .max_depth = 1,
        .limit = 10,
        .out_results = &walk,
    }));
    try std.testing.expectEqual(@as(usize, 2), walk.len);
    try std.testing.expectEqualStrings("message:1", walk.items.?[0].node_id.?[0..walk.items.?[0].node_id_len]);
    try std.testing.expectEqualStrings("message:2", walk.items.?[1].node_id.?[0..walk.items.?[1].node_id_len]);
    zova_graph_walk_results_free(&walk);
    try std.testing.expectEqual(zova_status.OK, zova_graph_walk_direction(&.{
        .db = db,
        .graph_name = "app",
        .start_node_id = "message:2",
        .direction = @intFromEnum(zova_graph_neighbor_direction.INCOMING),
        .edge_type = "replies_to",
        .max_depth = 1,
        .limit = 10,
        .out_results = &walk,
    }));
    try std.testing.expectEqual(@as(usize, 2), walk.len);
    try std.testing.expectEqualStrings("message:2", walk.items.?[0].node_id.?[0..walk.items.?[0].node_id_len]);
    try std.testing.expectEqualStrings("message:1", walk.items.?[1].node_id.?[0..walk.items.?[1].node_id_len]);
    zova_graph_walk_results_free(&walk);

    var walk_profile: zova_graph_walk_profile = .{};
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_walk_direction_profiled(&.{
        .db = db,
        .graph_name = "app",
        .start_node_id = "message:1",
        .direction = @intFromEnum(zova_graph_neighbor_direction.OUTGOING),
        .edge_type = "replies_to",
        .max_depth = 1,
        .limit = 10,
        .out_results = &walk,
        .out_profile = null,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_walk_direction_profiled(&.{
        .db = db,
        .graph_name = "app",
        .start_node_id = "message:1",
        .direction = @intFromEnum(zova_graph_neighbor_direction.OUTGOING),
        .edge_type = "replies_to",
        .max_depth = 1,
        .limit = 10,
        .out_results = null,
        .out_profile = &walk_profile,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_walk_direction_profiled(&.{
        .db = db,
        .graph_name = "app",
        .start_node_id = "message:1",
        .direction = @intFromEnum(zova_graph_neighbor_direction.OUTGOING),
        .edge_type = "replies_to",
        .max_depth = 1,
        .limit = 10,
        .out_results = &walk,
        .out_profile = &walk_profile,
    }));
    try std.testing.expectEqual(@as(usize, 2), walk.len);
    try std.testing.expectEqualStrings("message:1", walk.items.?[0].node_id.?[0..walk.items.?[0].node_id_len]);
    try std.testing.expectEqualStrings("message:2", walk.items.?[1].node_id.?[0..walk.items.?[1].node_id_len]);
    try std.testing.expectEqual(@as(u64, 1), walk_profile.frontier_expansions);
    try std.testing.expectEqual(@as(u64, 1), walk_profile.adjacency_query_binds);
    try std.testing.expectEqual(@as(u64, 1), walk_profile.adjacency_rows_stepped);
    try std.testing.expectEqual(@as(u64, 2), walk_profile.result_count);
    try std.testing.expect(walk_profile.mutex_wait_ms >= 0);
    try std.testing.expect(walk_profile.root_lookup_ms >= 0);
    try std.testing.expect(walk_profile.adjacency_prepare_ms >= 0);
    try std.testing.expect(walk_profile.adjacency_execute_ms >= 0);
    try std.testing.expect(walk_profile.bfs_bookkeeping_allocation_ms >= 0);
    try std.testing.expect(walk_profile.c_abi_result_export_ms >= 0);
    try std.testing.expect(walk_profile.total_profiled_ms >= walk_profile.c_abi_result_export_ms);
    const accounted_profile_ms = walk_profile.mutex_wait_ms + walk_profile.root_lookup_ms +
        walk_profile.adjacency_prepare_ms + walk_profile.adjacency_execute_ms +
        walk_profile.bfs_bookkeeping_allocation_ms + walk_profile.c_abi_result_export_ms;
    try std.testing.expect(walk_profile.total_profiled_ms >= accounted_profile_ms);
    zova_graph_walk_results_free(&walk);

    try std.testing.expectEqual(zova_status.OK, zova_graph_walk_direction_profiled(&.{
        .db = db,
        .graph_name = "app",
        .start_node_id = "message:2",
        .direction = @intFromEnum(zova_graph_neighbor_direction.INCOMING),
        .edge_type = "replies_to",
        .max_depth = 1,
        .limit = 10,
        .out_results = &walk,
        .out_profile = &walk_profile,
    }));
    try std.testing.expectEqual(@as(usize, 2), walk.len);
    try std.testing.expectEqualStrings("message:2", walk.items.?[0].node_id.?[0..walk.items.?[0].node_id_len]);
    try std.testing.expectEqualStrings("message:1", walk.items.?[1].node_id.?[0..walk.items.?[1].node_id_len]);
    try std.testing.expectEqual(@as(u64, 2), walk_profile.result_count);
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_walk_direction(&.{
        .db = db,
        .graph_name = "app",
        .start_node_id = "message:2",
        .direction = 99,
        .edge_type = null,
        .max_depth = 1,
        .limit = 10,
        .out_results = &walk,
    }));
    zova_graph_walk_results_free(&walk);
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_walk_direction(&.{
        .db = db,
        .graph_name = null,
        .start_node_id = "message:2",
        .direction = @intFromEnum(zova_graph_neighbor_direction.INCOMING),
        .edge_type = null,
        .max_depth = 1,
        .limit = 10,
        .out_results = &walk,
    }));
    try std.testing.expectEqual(zova_status.GRAPH_INVALID, zova_graph_walk(&.{
        .db = db,
        .graph_name = "app",
        .start_node_id = "message:1",
        .edge_type = null,
        .max_depth = 1,
        .limit = too_large_limit,
        .out_results = &walk,
    }));

    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_walk_direction(&.{
        .db = db,
        .graph_name = "app",
        .start_node_id = "message:2",
        .direction = @intFromEnum(zova_graph_neighbor_direction.INCOMING),
        .edge_type = "replies_to",
        .max_depth = 1,
        .limit = 10,
        .out_results = &walk,
    }));
    try std.testing.expectEqual(@as(usize, 2), walk.len);
    zova_graph_walk_results_free(&walk);
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_put(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "message:rollback",
        .kind = "message",
        .target_type = @intFromEnum(zova_graph_target_type.NONE),
        .target_namespace = null,
        .target_ref = null,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_rollback(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.GRAPH_NODE_NOT_FOUND, zova_graph_node_get(&.{ .db = db, .graph_name = "app", .node_id = "message:rollback", .out_node = &node }));

    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
    db = null;

    var readonly: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_open_with_options(&.{
        .path = db_path,
        .flags = ZOVA_OPEN_READ_ONLY,
        .busy_timeout_ms = 0,
        .out_db = &readonly,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(readonly);
    try std.testing.expectEqual(zova_status.OK, zova_graph_exists(&.{ .db = readonly, .name = "app", .out_exists = &exists }));
    try std.testing.expectEqual(zova_status.READ_ONLY, zova_graph_create(&.{ .db = readonly, .name = "readonly_new" }));
}

test "c abi validates vector request shapes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-vector-validation.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));
    defer _ = zova_database_close(db);

    const invalid_metric_request = zova_vector_collection_create_request{
        .db = db,
        .name = "bad",
        .options = .{ .dimensions = 2, .metric = 99, .element_type = @intFromEnum(zova_vector_element_type.F32) },
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_collection_create(&invalid_metric_request));

    const create_collection_request = zova_vector_collection_create_request{
        .db = db,
        .name = "chunks",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = @intFromEnum(zova_vector_element_type.F32) },
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&create_collection_request));

    const bad_values_request = zova_vector_put_request{
        .db = db,
        .collection_name = "chunks",
        .vector_id = "id",
        .values = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = null, .f16_values = null, .i8_values = null, .values_len = 2 },
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_put(&bad_values_request));

    var search_results = zova_vector_search_results{ .items = null, .len = 0 };
    const bad_search_request = zova_vector_search_request{
        .db = db,
        .collection_name = "chunks",
        .query = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = null, .f16_values = null, .i8_values = null, .values_len = 2 },
        .limit = 10,
        .out_results = &search_results,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search(&bad_search_request));

    const bad_candidates_request = zova_vector_search_in_request{
        .db = db,
        .collection_name = "chunks",
        .query = f32AbiValues(&.{}),
        .candidate_ids = null,
        .candidate_count = 1,
        .limit = 10,
        .out_results = &search_results,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_in(&bad_candidates_request));

    const null_candidate_entries = [_]?[*:0]const u8{null};
    const bad_candidate_entry_request = zova_vector_search_in_request{
        .db = db,
        .collection_name = "chunks",
        .query = f32AbiValues(&.{}),
        .candidate_ids = &null_candidate_entries,
        .candidate_count = null_candidate_entries.len,
        .limit = 10,
        .out_results = &search_results,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_in(&bad_candidate_entry_request));

    const bad_many_request = zova_vector_put_many_request{
        .db = db,
        .collection_name = "chunks",
        .vectors = null,
        .vectors_len = 1,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_put_many(&bad_many_request));

    const bad_input_values = [_]zova_vector_input{.{
        .id = "id",
        .values = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = null, .f16_values = null, .i8_values = null, .values_len = 2 },
    }};
    const bad_input_values_request = zova_vector_put_many_request{
        .db = db,
        .collection_name = "chunks",
        .vectors = &bad_input_values,
        .vectors_len = bad_input_values.len,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_put_many(&bad_input_values_request));

    const bad_by_id_candidates = zova_vector_search_by_id_in_request{
        .db = db,
        .collection_name = "chunks",
        .source_vector_id = "id",
        .candidate_ids = null,
        .candidate_count = 1,
        .limit = 10,
        .out_results = &search_results,
    };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_by_id_in(&bad_by_id_candidates));

    zova_vector_search_results_free(&search_results);
}

test "c abi vector delete many validates atomically and does not retain inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-vector-delete-many.zova", .{tmp.sub_path[0..]});
    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{ .path = db_path, .out_db = &db, .out_error_message = null }));
    defer _ = zova_database_close(db);
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&.{
        .db = db,
        .name = "chunks",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = @intFromEnum(zova_vector_element_type.F32) },
    }));
    const values = [_]f32{ 1, 2 };
    try std.testing.expectEqual(zova_status.OK, zova_vector_put(&.{ .db = db, .collection_name = "chunks", .vector_id = "a", .values = f32AbiValues(&values) }));

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_delete_many(&.{ .db = db, .collection_name = "chunks", .vector_ids = null, .vector_count = 1 }));
    const invalid_ids = [_]?[*:0]const u8{ "a", null };
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_delete_many(&.{ .db = db, .collection_name = "chunks", .vector_ids = &invalid_ids, .vector_count = invalid_ids.len }));

    var exists: u8 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_vector_exists(&.{ .db = db, .collection_name = "chunks", .vector_id = "a", .out_exists = &exists }));
    try std.testing.expectEqual(@as(u8, 1), exists);

    var ids = [_]?[*:0]const u8{ "a", "missing", "a" };
    try std.testing.expectEqual(zova_status.OK, zova_database_begin(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_vector_delete_many(&.{ .db = db, .collection_name = "chunks", .vector_ids = &ids, .vector_count = ids.len }));
    try std.testing.expectEqual(zova_status.OK, zova_database_rollback(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_vector_exists(&.{ .db = db, .collection_name = "chunks", .vector_id = "a", .out_exists = &exists }));
    try std.testing.expectEqual(@as(u8, 1), exists);

    try std.testing.expectEqual(zova_status.OK, zova_vector_delete_many(&.{ .db = db, .collection_name = "chunks", .vector_ids = &ids, .vector_count = ids.len }));
    ids[0] = "borrowed-input-was-not-retained";
    exists = 1;
    try std.testing.expectEqual(zova_status.OK, zova_vector_exists(&.{ .db = db, .collection_name = "chunks", .vector_id = "a", .out_exists = &exists }));
    try std.testing.expectEqual(@as(u8, 0), exists);
    try std.testing.expectEqual(zova_status.OK, zova_vector_delete_many(&.{ .db = db, .collection_name = "chunks", .vector_ids = null, .vector_count = 0 }));
    try std.testing.expectEqual(zova_status.VECTOR_COLLECTION_NOT_FOUND, zova_vector_delete_many(&.{ .db = db, .collection_name = "missing", .vector_ids = null, .vector_count = 0 }));
}

test "c abi exposes vector collection management batch writes and expanded search" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-vector-parity.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));
    defer _ = zova_database_close(db);

    const create_chunks = zova_vector_collection_create_request{
        .db = db,
        .name = "chunks",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = @intFromEnum(zova_vector_element_type.F32) },
    };
    const create_docs = zova_vector_collection_create_request{
        .db = db,
        .name = "docs",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.DOT), .element_type = @intFromEnum(zova_vector_element_type.F32) },
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&create_docs));
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&create_chunks));

    const source_values = [_]f32{ 0.0, 0.0 };
    const near_values = [_]f32{ 1.0, 0.0 };
    const near_updated = [_]f32{ 1.0, 1.0 };
    const tie_values = [_]f32{ 2.0, 0.0 };
    const far_values = [_]f32{ 10.0, 0.0 };
    const inputs = [_]zova_vector_input{
        .{ .id = "source", .values = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = &source_values, .f16_values = null, .i8_values = null, .values_len = source_values.len } },
        .{ .id = "near", .values = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = &near_values, .f16_values = null, .i8_values = null, .values_len = near_values.len } },
        .{ .id = "tie", .values = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = &tie_values, .f16_values = null, .i8_values = null, .values_len = tie_values.len } },
        .{ .id = "far", .values = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = &far_values, .f16_values = null, .i8_values = null, .values_len = far_values.len } },
        .{ .id = "near", .values = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = &near_updated, .f16_values = null, .i8_values = null, .values_len = near_updated.len } },
    };
    const put_many = zova_vector_put_many_request{
        .db = db,
        .collection_name = "chunks",
        .vectors = &inputs,
        .vectors_len = inputs.len,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_put_many(&put_many));

    var fetched = emptyVector();
    const get_near = zova_vector_get_request{
        .db = db,
        .collection_name = "chunks",
        .vector_id = "near",
        .out_vector = &fetched,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_get(&get_near));
    try std.testing.expectEqualStrings("near", fetched.id.?[0..fetched.id_len]);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(zova_vector_element_type.F32)), fetched.element_type);
    try std.testing.expectEqualSlices(f32, &near_updated, fetched.f32_values.?[0..fetched.values_len]);
    zova_vector_free(&fetched);

    var info = zova_vector_collection_info{
        .name = null,
        .name_len = 0,
        .dimensions = 0,
        .metric = 0,
        .element_type = 0,
        .vector_count = 0,
    };
    const info_request = zova_vector_collection_info_get_request{
        .db = db,
        .name = "chunks",
        .out_info = &info,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_info_get(&info_request));
    try std.testing.expectEqualStrings("chunks", info.name.?[0..info.name_len]);
    try std.testing.expectEqual(@as(u32, 2), info.dimensions);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(zova_vector_metric.L2)), info.metric);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(zova_vector_element_type.F32)), info.element_type);
    try std.testing.expectEqual(@as(u64, 4), info.vector_count);
    zova_vector_collection_info_free(&info);

    var list = zova_vector_collection_list{ .items = null, .len = 0 };
    const list_request = zova_vector_collections_list_request{
        .db = db,
        .out_list = &list,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_collections_list(&list_request));
    defer zova_vector_collection_list_free(&list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("chunks", list.items.?[0].name.?[0..list.items.?[0].name_len]);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(zova_vector_element_type.F32)), list.items.?[0].element_type);
    try std.testing.expectEqualStrings("docs", list.items.?[1].name.?[0..list.items.?[1].name_len]);

    var results = zova_vector_search_results{ .items = null, .len = 0 };
    const query = [_]f32{ 0.0, 0.0 };
    const within_request = zova_vector_search_within_request{
        .db = db,
        .collection_name = "chunks",
        .query = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = &query, .f16_values = null, .i8_values = null, .values_len = query.len },
        .max_distance = 2.0,
        .limit = 10,
        .out_results = &results,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_search_within(&within_request));
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("source", results.items.?[0].id.?[0..results.items.?[0].id_len]);
    zova_vector_search_results_free(&results);

    const candidates = [_]?[*:0]const u8{ "far", "missing", "near", "source", "near" };
    const by_id_in_request = zova_vector_search_by_id_in_request{
        .db = db,
        .collection_name = "chunks",
        .source_vector_id = "source",
        .candidate_ids = &candidates,
        .candidate_count = candidates.len,
        .limit = 10,
        .out_results = &results,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_search_by_id_in(&by_id_in_request));
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("near", results.items.?[0].id.?[0..results.items.?[0].id_len]);
    try std.testing.expectEqualStrings("far", results.items.?[1].id.?[0..results.items.?[1].id_len]);
    zova_vector_search_results_free(&results);

    const by_id_within_request = zova_vector_search_by_id_within_request{
        .db = db,
        .collection_name = "chunks",
        .source_vector_id = "source",
        .max_distance = 2.0,
        .limit = 10,
        .out_results = &results,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_search_by_id_within(&by_id_within_request));
    try std.testing.expectEqual(@as(usize, 2), results.len);
    zova_vector_search_results_free(&results);

    const by_id_in_within_request = zova_vector_search_by_id_in_within_request{
        .db = db,
        .collection_name = "chunks",
        .source_vector_id = "source",
        .candidate_ids = &candidates,
        .candidate_count = candidates.len,
        .max_distance = 2.0,
        .limit = 10,
        .out_results = &results,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_search_by_id_in_within(&by_id_in_within_request));
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("near", results.items.?[0].id.?[0..results.items.?[0].id_len]);
    zova_vector_search_results_free(&results);

    const search_in_within_request = zova_vector_search_in_within_request{
        .db = db,
        .collection_name = "chunks",
        .query = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = &query, .f16_values = null, .i8_values = null, .values_len = query.len },
        .candidate_ids = &candidates,
        .candidate_count = candidates.len,
        .max_distance = 2.0,
        .limit = 10,
        .out_results = &results,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_search_in_within(&search_in_within_request));
    try std.testing.expectEqual(@as(usize, 2), results.len);
    zova_vector_search_results_free(&results);

    const source_search = zova_vector_search_by_id_request{
        .db = db,
        .collection_name = "chunks",
        .source_vector_id = "source",
        .limit = 10,
        .out_results = &results,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_search_by_id(&source_search));
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expect(!std.mem.eql(u8, "source", results.items.?[0].id.?[0..results.items.?[0].id_len]));
    zova_vector_search_results_free(&results);

    const dot_values = [_]f32{ 2.0, 0.0 };
    const dot_inputs = [_]zova_vector_input{.{
        .id = "dot-a",
        .values = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = &dot_values, .f16_values = null, .i8_values = null, .values_len = dot_values.len },
    }};
    const dot_many = zova_vector_put_many_request{
        .db = db,
        .collection_name = "docs",
        .vectors = &dot_inputs,
        .vectors_len = dot_inputs.len,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_put_many(&dot_many));
    const dot_query = [_]f32{ 1.0, 0.0 };
    const dot_within = zova_vector_search_within_request{
        .db = db,
        .collection_name = "docs",
        .query = .{ .element_type = @intFromEnum(zova_vector_element_type.F32), .f32_values = &dot_query, .f16_values = null, .i8_values = null, .values_len = dot_query.len },
        .max_distance = -1.0,
        .limit = 10,
        .out_results = &results,
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_search_within(&dot_within));
    try std.testing.expectEqual(@as(usize, 1), results.len);
    zova_vector_search_results_free(&results);

    const delete_collection = zova_vector_collection_delete_request{
        .db = db,
        .name = "chunks",
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_delete(&delete_collection));
    try std.testing.expectEqual(zova_status.VECTOR_COLLECTION_NOT_FOUND, zova_vector_get(&get_near));
    try std.testing.expectEqual(zova_status.VECTOR_COLLECTION_NOT_FOUND, zova_vector_collection_delete(&delete_collection));
}

test "c abi exposes raw typed i8 and f16 vectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-typed-vectors.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_collection_create(&.{
        .db = db,
        .name = "bad",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = 99 },
    }));

    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&.{
        .db = db,
        .name = "bytes",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = @intFromEnum(zova_vector_element_type.I8) },
    }));
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&.{
        .db = db,
        .name = "halves",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = @intFromEnum(zova_vector_element_type.F16) },
    }));

    const near_i8 = [_]i8{ 1, 0 };
    const far_i8 = [_]i8{ 5, 0 };
    const query_i8 = [_]i8{ 0, 0 };
    try std.testing.expectEqual(zova_status.OK, zova_vector_put(&.{
        .db = db,
        .collection_name = "bytes",
        .vector_id = "near",
        .values = .{ .element_type = @intFromEnum(zova_vector_element_type.I8), .f32_values = null, .f16_values = null, .i8_values = &near_i8, .values_len = near_i8.len },
    }));
    try std.testing.expectEqual(zova_status.OK, zova_vector_put(&.{
        .db = db,
        .collection_name = "bytes",
        .vector_id = "far",
        .values = .{ .element_type = @intFromEnum(zova_vector_element_type.I8), .f32_values = null, .f16_values = null, .i8_values = &far_i8, .values_len = far_i8.len },
    }));

    const near_f16 = [_]u16{ 0x3c00, 0x0000 };
    const far_f16 = [_]u16{ 0x4400, 0x0000 };
    const f16_inputs = [_]zova_vector_input{
        .{ .id = "near", .values = .{ .element_type = @intFromEnum(zova_vector_element_type.F16), .f32_values = null, .f16_values = &near_f16, .i8_values = null, .values_len = near_f16.len } },
        .{ .id = "far", .values = .{ .element_type = @intFromEnum(zova_vector_element_type.F16), .f32_values = null, .f16_values = &far_f16, .i8_values = null, .values_len = far_f16.len } },
    };
    try std.testing.expectEqual(zova_status.OK, zova_vector_put_many(&.{
        .db = db,
        .collection_name = "halves",
        .vectors = &f16_inputs,
        .vectors_len = f16_inputs.len,
    }));

    var fetched = emptyVector();
    try std.testing.expectEqual(zova_status.OK, zova_vector_get(&.{
        .db = db,
        .collection_name = "bytes",
        .vector_id = "near",
        .out_vector = &fetched,
    }));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(zova_vector_element_type.I8)), fetched.element_type);
    try std.testing.expectEqualStrings("near", fetched.id.?[0..fetched.id_len]);
    try std.testing.expectEqualSlices(i8, &near_i8, fetched.i8_values.?[0..fetched.values_len]);
    zova_vector_free(&fetched);

    var results = emptyVectorSearchResults();
    try std.testing.expectEqual(zova_status.OK, zova_vector_search(&.{
        .db = db,
        .collection_name = "bytes",
        .query = .{ .element_type = @intFromEnum(zova_vector_element_type.I8), .f32_values = null, .f16_values = null, .i8_values = &query_i8, .values_len = query_i8.len },
        .limit = 2,
        .out_results = &results,
    }));
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("near", results.items.?[0].id.?[0..results.items.?[0].id_len]);
    zova_vector_search_results_free(&results);

    const typed_candidates = [_]?[*:0]const u8{"far"};
    try std.testing.expectEqual(zova_status.OK, zova_vector_search_in(&.{
        .db = db,
        .collection_name = "bytes",
        .query = .{ .element_type = @intFromEnum(zova_vector_element_type.I8), .f32_values = null, .f16_values = null, .i8_values = &query_i8, .values_len = query_i8.len },
        .candidate_ids = &typed_candidates,
        .candidate_count = typed_candidates.len,
        .limit = 2,
        .out_results = &results,
    }));
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("far", results.items.?[0].id.?[0..results.items.?[0].id_len]);
    zova_vector_search_results_free(&results);

    try std.testing.expectEqual(zova_status.OK, zova_vector_get(&.{
        .db = db,
        .collection_name = "halves",
        .vector_id = "near",
        .out_vector = &fetched,
    }));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(zova_vector_element_type.F16)), fetched.element_type);
    try std.testing.expectEqualSlices(u16, &near_f16, fetched.f16_values.?[0..fetched.values_len]);
    zova_vector_free(&fetched);

    var info = emptyVectorCollectionInfo();
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_info_get(&.{ .db = db, .name = "halves", .out_info = &info }));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(zova_vector_element_type.F16)), info.element_type);
    zova_vector_collection_info_free(&info);
}

test "c abi searches multi-query raw i8 cosine vectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-multi-i8.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{ .path = db_path, .out_db = &db, .out_error_message = null }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&.{
        .db = db,
        .name = "bytes",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.COSINE), .element_type = @intFromEnum(zova_vector_element_type.I8) },
    }));
    const balanced = [_]i8{ 10, 10 };
    const east = [_]i8{ 10, 0 };
    const inputs = [_]struct { id: [*:0]const u8, values: []const i8 }{
        .{ .id = "balanced", .values = &balanced },
        .{ .id = "east", .values = &east },
    };
    for (inputs) |input| {
        try std.testing.expectEqual(zova_status.OK, zova_vector_put(&.{
            .db = db,
            .collection_name = "bytes",
            .vector_id = input.id,
            .values = .{ .element_type = @intFromEnum(zova_vector_element_type.I8), .f32_values = null, .f16_values = null, .i8_values = input.values.ptr, .values_len = input.values.len },
        }));
    }

    const queries = [_]i8{ 10, 0, 0, 10 };
    var results = emptyVectorSearchResults();
    try std.testing.expectEqual(zova_status.OK, zova_vector_search_multi_i8(&.{
        .db = db,
        .collection_name = "bytes",
        .query_values = &queries,
        .query_values_len = queries.len,
        .query_count = 2,
        .dimensions = 2,
        .candidate_ids = null,
        .candidate_count = 0,
        .mode = @intFromEnum(zova_vector_multi_i8_search_mode.GLOBAL_MIN_COSINE),
        .aggregation = @intFromEnum(zova_vector_multi_i8_aggregation.MIN_COSINE),
        .prefilter_query_index = 0,
        .prefilter_limit = 0,
        .limit = 1,
        .out_results = &results,
    }));
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("balanced", results.items.?[0].id.?[0..results.items.?[0].id_len]);
    zova_vector_search_results_free(&results);

    const only_east = [_]?[*:0]const u8{"east"};
    try std.testing.expectEqual(zova_status.OK, zova_vector_search_multi_i8(&.{
        .db = db,
        .collection_name = "bytes",
        .query_values = &queries,
        .query_values_len = queries.len,
        .query_count = 2,
        .dimensions = 2,
        .candidate_ids = &only_east,
        .candidate_count = only_east.len,
        .mode = @intFromEnum(zova_vector_multi_i8_search_mode.GLOBAL_MIN_COSINE),
        .aggregation = @intFromEnum(zova_vector_multi_i8_aggregation.MIN_COSINE),
        .prefilter_query_index = 0,
        .prefilter_limit = 0,
        .limit = 1,
        .out_results = &results,
    }));
    try std.testing.expectEqualStrings("east", results.items.?[0].id.?[0..results.items.?[0].id_len]);
    zova_vector_search_results_free(&results);

    try std.testing.expectEqual(zova_status.OK, zova_vector_search_multi_i8(&.{
        .db = db,
        .collection_name = "bytes",
        .query_values = &queries,
        .query_values_len = queries.len,
        .query_count = 2,
        .dimensions = 2,
        .candidate_ids = null,
        .candidate_count = 0,
        .mode = @intFromEnum(zova_vector_multi_i8_search_mode.CBM_PREFILTER_MIN_COSINE),
        .aggregation = @intFromEnum(zova_vector_multi_i8_aggregation.MIN_COSINE),
        .prefilter_query_index = 0,
        .prefilter_limit = 1,
        .limit = 1,
        .out_results = &results,
    }));
    try std.testing.expectEqualStrings("east", results.items.?[0].id.?[0..results.items.?[0].id_len]);
    zova_vector_search_results_free(&results);

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_vector_search_multi_i8(&.{
        .db = db,
        .collection_name = "bytes",
        .query_values = &queries,
        .query_values_len = queries.len - 1,
        .query_count = 2,
        .dimensions = 2,
        .candidate_ids = null,
        .candidate_count = 0,
        .mode = @intFromEnum(zova_vector_multi_i8_search_mode.GLOBAL_MIN_COSINE),
        .aggregation = @intFromEnum(zova_vector_multi_i8_aggregation.MIN_COSINE),
        .prefilter_query_index = 0,
        .prefilter_limit = 0,
        .limit = 1,
        .out_results = &results,
    }));

    const zero_query = [_]i8{ 0, 0 };
    try std.testing.expectEqual(zova_status.VECTOR_INVALID, zova_vector_search_multi_i8(&.{
        .db = db,
        .collection_name = "bytes",
        .query_values = &zero_query,
        .query_values_len = zero_query.len,
        .query_count = 1,
        .dimensions = 2,
        .candidate_ids = null,
        .candidate_count = 0,
        .mode = @intFromEnum(zova_vector_multi_i8_search_mode.GLOBAL_MIN_COSINE),
        .aggregation = @intFromEnum(zova_vector_multi_i8_aggregation.MIN_COSINE),
        .prefilter_query_index = 0,
        .prefilter_limit = 0,
        .limit = 1,
        .out_results = &results,
    }));
}

fn zova_buffer_free_and_status_for_test() zova_status {
    zova_buffer_free(null);
    return .INVALID_ARGUMENT;
}

test "c abi exposes transaction helpers and vacuum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-vacuum.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "create table notes (body text not null)" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_begin(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "insert into notes (body) values ('rollback')" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_rollback(&.{ .db = db }));

    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "insert into notes (body) values ('commit')" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_commit(&.{ .db = db }));

    const object_id = try databaseHandle(db).?.db.putObject("vacuum keeps objects");
    const deleted_id = try databaseHandle(db).?.db.putObject("vacuum after delete");
    try databaseHandle(db).?.db.deleteObject(deleted_id);
    try databaseHandle(db).?.db.createVectorCollection("vectors", .{ .dimensions = 2, .metric = .l2 });
    try databaseHandle(db).?.db.putVector("vectors", "v1", .{ .f32 = &.{ 1.0, 2.0 } });

    try std.testing.expectEqual(zova_status.OK, zova_database_vacuum(&.{ .db = db }));

    try std.testing.expect(try databaseHandle(db).?.db.hasObject(object_id));
    try std.testing.expect(!try databaseHandle(db).?.db.hasObject(deleted_id));
    try std.testing.expect(try databaseHandle(db).?.db.hasVector("vectors", "v1"));
    var count_stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{ .db = db, .sql = "select count(*) from notes where body = 'commit'", .out_statement = &count_stmt }));
    defer _ = zova_statement_finalize(count_stmt);
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = count_stmt, .out_result = &step_result }));
    var count: i64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = count_stmt, .index = 0, .out_value = &count }));
    try std.testing.expectEqual(@as(i64, 1), count);
}

fn expectCAbiOperationalCopy(path: [:0]const u8, object_id: zova_object_id) !void {
    var db: ?*zova_database = null;
    var open_request = zova_database_open_request{
        .path = path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_open(&open_request));
    defer _ = zova_database_close(db);

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select count(*) from records where body = 'kept'",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);

    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);

    var count: i64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = stmt, .index = 0, .out_value = &count }));
    try std.testing.expectEqual(@as(i64, 1), count);

    var exists: u8 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_object_exists(&.{
        .db = db,
        .id = object_id,
        .out_exists = &exists,
    }));
    try std.testing.expectEqual(@as(u8, 1), exists);

    exists = 0;
    try std.testing.expectEqual(zova_status.OK, zova_vector_exists(&.{
        .db = db,
        .collection_name = "records",
        .vector_id = "r1",
        .out_exists = &exists,
    }));
    try std.testing.expectEqual(@as(u8, 1), exists);
}

test "c abi backs up compacts and restores zova databases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, ".zig-cache/tmp/{s}/c-api-ops-source.zova", .{tmp.sub_path[0..]});

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try std.fmt.bufPrintZ(&backup_buffer, ".zig-cache/tmp/{s}/c-api-ops-backup.zova", .{tmp.sub_path[0..]});

    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try std.fmt.bufPrintZ(&compact_buffer, ".zig-cache/tmp/{s}/c-api-ops-compact.zova", .{tmp.sub_path[0..]});

    var restored_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restored_path = try std.fmt.bufPrintZ(&restored_buffer, ".zig-cache/tmp/{s}/c-api-ops-restored.zova", .{tmp.sub_path[0..]});

    var existing_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const existing_path = try std.fmt.bufPrintZ(&existing_buffer, ".zig-cache/tmp/{s}/c-api-ops-existing.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = source_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "create table records (body text not null); insert into records (body) values ('kept')",
    }));

    var object_id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.OK, zova_object_put(&.{
        .db = db,
        .data = "c abi backup object",
        .len = "c abi backup object".len,
        .out_id = &object_id,
    }));

    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&.{
        .db = db,
        .name = "records",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = @intFromEnum(zova_vector_element_type.F32) },
    }));
    const values = [_]f32{ 1.0, 2.0 };
    try std.testing.expectEqual(zova_status.OK, zova_vector_put(&.{
        .db = db,
        .collection_name = "records",
        .vector_id = "r1",
        .values = f32AbiValues(&values),
    }));

    try std.testing.expectEqual(zova_status.OK, zova_database_backup(&.{
        .db = db,
        .destination_path = backup_path,
        .flags = 0,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_compact(&.{
        .db = db,
        .destination_path = compact_path,
        .flags = ZOVA_COMPACT_NO_VERIFY,
    }));

    var restore_message = zova_message{ .data = null, .len = 0 };
    defer zova_message_free(&restore_message);
    try std.testing.expectEqual(zova_status.OK, zova_database_restore(&.{
        .source_path = backup_path,
        .destination_path = restored_path,
        .flags = 0,
        .out_error_message = &restore_message,
    }));

    try expectCAbiOperationalCopy(backup_path, object_id);
    try expectCAbiOperationalCopy(compact_path, object_id);
    try expectCAbiOperationalCopy(restored_path, object_id);

    var existing: ?*zova_database = null;
    var existing_request = zova_database_open_request{
        .path = existing_path,
        .out_db = &existing,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&existing_request));
    try std.testing.expectEqual(zova_status.OK, zova_database_close(existing));

    try std.testing.expectEqual(zova_status.DESTINATION_EXISTS, zova_database_backup(&.{
        .db = db,
        .destination_path = existing_path,
        .flags = 0,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_backup(&.{
        .db = db,
        .destination_path = backup_path,
        .flags = 0xffff_ffff,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_restore(&.{
        .source_path = backup_path,
        .destination_path = restored_path,
        .flags = 0xffff_ffff,
        .out_error_message = &restore_message,
    }));
}

test "c abi serializes mixed object vector and database calls on one handle" {
    const Worker = struct {
        db: ?*zova_database,
        worker_index: usize,
        object_id: zova_object_id = .{ .bytes = [_]u8{0} ** 32 },
        status: zova_status = .OK,

        fn run(ctx: *@This()) void {
            if (ctx.worker_index % 2 == 0) {
                var data_buffer: [64]u8 = undefined;
                const data = std.fmt.bufPrint(&data_buffer, "threaded object {d}", .{ctx.worker_index}) catch {
                    ctx.status = .OUT_OF_MEMORY;
                    return;
                };
                ctx.status = zova_object_put(&.{
                    .db = ctx.db,
                    .data = data.ptr,
                    .len = data.len,
                    .out_id = &ctx.object_id,
                });
            } else {
                var id_buffer: [32]u8 = undefined;
                const vector_id = std.fmt.bufPrintZ(&id_buffer, "v-{d}", .{ctx.worker_index}) catch {
                    ctx.status = .OUT_OF_MEMORY;
                    return;
                };
                const values = [_]f32{ @floatFromInt(ctx.worker_index), 1.0 };
                ctx.status = zova_vector_put(&.{
                    .db = ctx.db,
                    .collection_name = "mixed",
                    .vector_id = vector_id.ptr,
                    .values = f32AbiValues(&values),
                });
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-threaded-mixed.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "create table events (body text)" }));
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&.{
        .db = db,
        .name = "mixed",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = @intFromEnum(zova_vector_element_type.F32) },
    }));

    var contexts: [12]Worker = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    for (&contexts, 0..) |*context, index| {
        context.* = .{ .db = db, .worker_index = index };
    }
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{context});
    }
    for (threads) |thread| thread.join();
    for (contexts) |context| try std.testing.expectEqual(zova_status.OK, context.status);

    var object_count: usize = 0;
    for (contexts) |context| {
        if (context.worker_index % 2 != 0) continue;
        var exists: u8 = 0;
        try std.testing.expectEqual(zova_status.OK, zova_object_exists(&.{
            .db = db,
            .id = context.object_id,
            .out_exists = &exists,
        }));
        try std.testing.expectEqual(@as(u8, 1), exists);
        object_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), object_count);

    var info = emptyVectorCollectionInfo();
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_info_get(&.{
        .db = db,
        .name = "mixed",
        .out_info = &info,
    }));
    defer zova_vector_collection_info_free(&info);
    try std.testing.expectEqual(@as(u64, 6), info.vector_count);
}

test "c abi multi-handle reads and vector search follow sqlite locking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-multi-handle-read.zova", .{tmp.sub_path[0..]});

    var writer: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &writer,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(writer);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = writer, .sql = "create table records (body text not null)" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = writer, .sql = "insert into records (body) values ('visible')" }));
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&.{
        .db = writer,
        .name = "vectors",
        .options = .{ .dimensions = 2, .metric = @intFromEnum(zova_vector_metric.L2), .element_type = @intFromEnum(zova_vector_element_type.F32) },
    }));
    const values = [_]f32{ 1.0, 2.0 };
    try std.testing.expectEqual(zova_status.OK, zova_vector_put(&.{
        .db = writer,
        .collection_name = "vectors",
        .vector_id = "v1",
        .values = f32AbiValues(&values),
    }));

    var reader: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_open(&.{
        .path = db_path,
        .out_db = &reader,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(reader);

    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = writer }));
    defer _ = zova_database_rollback(&.{ .db = writer });

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = reader,
        .sql = "select count(*) from records",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    var count: i64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = stmt, .index = 0, .out_value = &count }));
    try std.testing.expectEqual(@as(i64, 1), count);

    var results = emptyVectorSearchResults();
    try std.testing.expectEqual(zova_status.OK, zova_vector_search(&.{
        .db = reader,
        .collection_name = "vectors",
        .query = f32AbiValues(&values),
        .limit = 1,
        .out_results = &results,
    }));
    defer zova_vector_search_results_free(&results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "c abi notifications are transaction aware and SQL callable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-notify.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));

    var subscription: ?*zova_subscription = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_listen(&.{
        .db = db,
        .channel = "messages",
        .out_subscription = &subscription,
    }));

    try std.testing.expectEqual(zova_status.MISUSE, zova_database_close(db));

    var out = emptyNotification();
    defer zova_notification_free(&out);
    var has_notification: u8 = 0;

    const invalid_utf8_channel = [_:0]u8{ 0xc3, 0xa9 };
    const invalid_payload = [_]u8{0xff};
    const invalid_channels = [_][*:0]const u8{
        "",
        "bad channel",
        "_zova_private",
        &invalid_utf8_channel,
    };
    for (invalid_channels) |channel| {
        var invalid_subscription: ?*zova_subscription = null;
        try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_listen(&.{
            .db = db,
            .channel = channel,
            .out_subscription = &invalid_subscription,
        }));
        try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_notify(&.{
            .db = db,
            .channel = channel,
            .payload = "payload",
            .payload_len = "payload".len,
        }));
    }
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_notify(&.{
        .db = db,
        .channel = "messages",
        .payload = invalid_payload[0..].ptr,
        .payload_len = invalid_payload.len,
    }));

    try std.testing.expectEqual(zova_status.OK, zova_database_notify(&.{
        .db = db,
        .channel = "messages",
        .payload = "outside",
        .payload_len = "outside".len,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_subscription_try_receive(&.{
        .subscription = subscription,
        .out_notification = &out,
        .out_has_notification = &has_notification,
    }));
    try std.testing.expectEqual(@as(u8, 1), has_notification);
    try std.testing.expectEqualStrings("messages", out.channel.?[0..out.channel_len]);
    try std.testing.expectEqualStrings("outside", out.payload.?[0..out.payload_len]);

    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_database_notify(&.{
        .db = db,
        .channel = "messages",
        .payload = "committed",
        .payload_len = "committed".len,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_subscription_try_receive(&.{
        .subscription = subscription,
        .out_notification = &out,
        .out_has_notification = &has_notification,
    }));
    try std.testing.expectEqual(@as(u8, 0), has_notification);
    try std.testing.expectEqual(zova_status.OK, zova_database_commit(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_subscription_try_receive(&.{
        .subscription = subscription,
        .out_notification = &out,
        .out_has_notification = &has_notification,
    }));
    try std.testing.expectEqual(@as(u8, 1), has_notification);
    try std.testing.expectEqualStrings("committed", out.payload.?[0..out.payload_len]);

    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_database_notify(&.{
        .db = db,
        .channel = "messages",
        .payload = "rolled-back",
        .payload_len = "rolled-back".len,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_rollback(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_subscription_try_receive(&.{
        .subscription = subscription,
        .out_notification = &out,
        .out_has_notification = &has_notification,
    }));
    try std.testing.expectEqual(@as(u8, 0), has_notification);

    var statement: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select zova_notify('messages', 'from-sql')",
        .out_statement = &statement,
    }));
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = statement, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    try std.testing.expectEqual(zova_status.OK, zova_statement_finalize(statement));
    try std.testing.expectEqual(zova_status.OK, zova_subscription_try_receive(&.{
        .subscription = subscription,
        .out_notification = &out,
        .out_has_notification = &has_notification,
    }));
    try std.testing.expectEqual(@as(u8, 1), has_notification);
    try std.testing.expectEqualStrings("from-sql", out.payload.?[0..out.payload_len]);

    try std.testing.expectEqual(zova_status.SQLITE_ERROR, zova_database_exec(&.{
        .db = db,
        .sql = "select zova_notify('_zova_private', 'payload')",
    }));
    try std.testing.expectEqual(zova_status.SQLITE_ERROR, zova_database_exec(&.{
        .db = db,
        .sql = "select zova_notify('messages', cast(x'ff' as text))",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_subscription_try_receive(&.{
        .subscription = subscription,
        .out_notification = &out,
        .out_has_notification = &has_notification,
    }));
    try std.testing.expectEqual(@as(u8, 0), has_notification);

    try std.testing.expectEqual(zova_status.OK, zova_subscription_close(subscription));
    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
}

test "c abi in-memory notifications follow transaction boundaries and close ordering" {
    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create_memory(&.{
        .out_db = &db,
        .out_error_message = null,
    }));

    var subscription: ?*zova_subscription = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_listen(&.{
        .db = db,
        .channel = "messages",
        .out_subscription = &subscription,
    }));

    var out = emptyNotification();
    defer zova_notification_free(&out);
    var has_notification: u8 = 0;

    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_database_notify(&.{
        .db = db,
        .channel = "messages",
        .payload = "committed",
        .payload_len = "committed".len,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_subscription_try_receive(&.{
        .subscription = subscription,
        .out_notification = &out,
        .out_has_notification = &has_notification,
    }));
    try std.testing.expectEqual(@as(u8, 0), has_notification);
    try std.testing.expectEqual(zova_status.OK, zova_database_commit(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_subscription_try_receive(&.{
        .subscription = subscription,
        .out_notification = &out,
        .out_has_notification = &has_notification,
    }));
    try std.testing.expectEqual(@as(u8, 1), has_notification);
    try std.testing.expectEqualStrings("committed", out.payload.?[0..out.payload_len]);
    try std.testing.expectEqual(@as(u64, 1), out.sequence);
    try std.testing.expectEqual(@as(u64, 0), out.dropped_before);

    try std.testing.expectEqual(zova_status.MISUSE, zova_database_close(db));
    try std.testing.expectEqual(zova_status.OK, zova_database_notify(&.{
        .db = db,
        .channel = "messages",
        .payload = "after-rejected-close",
        .payload_len = "after-rejected-close".len,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_subscription_try_receive(&.{
        .subscription = subscription,
        .out_notification = &out,
        .out_has_notification = &has_notification,
    }));
    try std.testing.expectEqual(@as(u8, 1), has_notification);
    try std.testing.expectEqualStrings("after-rejected-close", out.payload.?[0..out.payload_len]);

    try std.testing.expectEqual(zova_status.OK, zova_subscription_close(subscription));
    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
}

test "c abi in-memory kv failure discards state and pending notifications" {
    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create_memory(&.{
        .out_db = &db,
        .out_error_message = null,
    }));

    var subscription: ?*zova_subscription = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_listen(&.{
        .db = db,
        .channel = "cache:search-results",
        .out_subscription = &subscription,
    }));

    var out = emptyNotification();
    defer zova_notification_free(&out);
    var has_notification: u8 = 0;

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "insert into _zova_kv(namespace, key, value) values (cast('search-results' as blob), cast('stable' as blob), cast('kept' as blob))",
    }));

    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_database_notify(&.{
        .db = db,
        .channel = "cache:search-results",
        .payload = "generation:1",
        .payload_len = "generation:1".len,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "create trigger zova_kv_fail before insert on _zova_kv when new.value = cast('boom' as blob) begin select raise(abort,'injected kv failure'); end",
    }));
    try std.testing.expectEqual(zova_status.CONSTRAINT, zova_database_exec(&.{
        .db = db,
        .sql = "insert into _zova_kv(namespace, key, value) values (cast('search-results' as blob), cast('boom' as blob), cast('boom' as blob))",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_rollback(&.{ .db = db }));

    try std.testing.expectEqual(zova_status.OK, zova_subscription_try_receive(&.{
        .subscription = subscription,
        .out_notification = &out,
        .out_has_notification = &has_notification,
    }));
    try std.testing.expectEqual(@as(u8, 0), has_notification);

    var statement: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select count(*) from _zova_kv where namespace = cast('search-results' as blob)",
        .out_statement = &statement,
    }));
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = statement, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    var kv_count: i64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{
        .statement = statement,
        .index = 0,
        .out_value = &kv_count,
    }));
    try std.testing.expectEqual(@as(i64, 1), kv_count);
    try std.testing.expectEqual(zova_status.OK, zova_statement_finalize(statement));

    try std.testing.expectEqual(zova_status.OK, zova_subscription_close(subscription));
    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
}

test "c abi fresh builder loads predeclared tables fts graph payloads and vectors atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/fresh-builder.zova", .{tmp.sub_path[0..]});
    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{ .path = path, .out_db = &db, .out_error_message = null }));
    defer _ = zova_database_close(db);
    const handle = databaseHandle(db).?;
    try handle.db.exec("pragma cache_size=-4096");

    try std.testing.expectEqual(zova_status.OK, zova_database_begin(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "create table records(id integer primary key,body text not null); create index records_body_idx on records(body); create virtual table records_fts using fts5(body); create table topology_refs(node_key integer not null,edge_key integer not null); create virtual table topology_fts using fts5(node_key unindexed,body)",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_vector_collection_create(&.{
        .db = db,
        .name = "embedding",
        .options = .{ .dimensions = 2, .metric = 0, .element_type = 2 },
    }));

    var build: ?*zova_fresh_build = null;
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_begin(&.{ .db = db, .out_build = &build }));
    defer zova_fresh_build_destroy(build);
    {
        var cache_size = try handle.db.prepare("pragma cache_size");
        defer cache_size.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try cache_size.step());
        try std.testing.expectEqual(@as(i64, -4096), cache_size.columnInt64(0));
    }
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_exec(&.{ .db = db, .sql = "select 1" }));

    const columns = [_]?[*:0]const u8{ "id", "body" };
    const values = [_]zova_fresh_value{
        .{ .value_type = 1, .int64_value = 1, .float64_value = 0, .bytes = null, .bytes_len = 0 },
        .{ .value_type = 3, .int64_value = 0, .float64_value = 0, .bytes = "first", .bytes_len = 5 },
        .{ .value_type = 1, .int64_value = 2, .float64_value = 0, .bytes = null, .bytes_len = 0 },
        .{ .value_type = 3, .int64_value = 0, .float64_value = 0, .bytes = "second", .bytes_len = 6 },
    };
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_table_rows(&.{
        .build = build,
        .table_name = "records",
        .column_names = &columns,
        .column_count = columns.len,
        .values = &values,
        .row_count = 2,
    }));
    const fts_columns = [_]?[*:0]const u8{"body"};
    const fts_values = [_]zova_fresh_value{
        .{ .value_type = 3, .int64_value = 0, .float64_value = 0, .bytes = "first", .bytes_len = 5 },
        .{ .value_type = 3, .int64_value = 0, .float64_value = 0, .bytes = "second", .bytes_len = 6 },
    };
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_fts_rows(&.{
        .build = build,
        .table_name = "records_fts",
        .column_names = &fts_columns,
        .column_count = 1,
        .values = &fts_values,
        .row_count = 2,
    }));

    const nodes = [_]zova_graph_fresh_node_input{
        .{ .node_id = "a", .kind = "node", .target_type = 0, .target_namespace = null, .target_ref = null },
        .{ .node_id = "b", .kind = "node", .target_type = 0, .target_namespace = null, .target_ref = null },
    };
    const payload = [_]u8{ 1, 2, 3, 4 };
    const edges = [_]zova_graph_fresh_edge_payload_input{
        .{ .from_node_ordinal = 0, .edge_type = "links", .to_node_ordinal = 1, .payload = &payload, .payload_len = payload.len },
    };
    var provisional_node_keys = [_]i64{ -1, -1 };
    var provisional_edge_keys = [_]i64{-1};
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_graph(&.{
        .build = build,
        .graph_name = "app",
        .nodes = &nodes,
        .nodes_len = nodes.len,
        .edges = &edges,
        .edges_len = edges.len,
        .out_node_keys = &provisional_node_keys,
        .out_node_keys_capacity = provisional_node_keys.len,
        .out_edge_keys = &provisional_edge_keys,
        .out_edge_keys_capacity = provisional_edge_keys.len,
    }));
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, &provisional_node_keys);
    try std.testing.expectEqualSlices(i64, &.{1}, &provisional_edge_keys);
    const topology_columns = [_]?[*:0]const u8{ "node_key", "edge_key" };
    const topology_values = [_]zova_fresh_value{
        .{ .value_type = 1, .int64_value = provisional_node_keys[1], .float64_value = 0, .bytes = null, .bytes_len = 0 },
        .{ .value_type = 1, .int64_value = provisional_edge_keys[0], .float64_value = 0, .bytes = null, .bytes_len = 0 },
    };
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_table_rows(&.{
        .build = build,
        .table_name = "topology_refs",
        .column_names = &topology_columns,
        .column_count = topology_columns.len,
        .values = &topology_values,
        .row_count = 1,
    }));
    const topology_fts_columns = [_]?[*:0]const u8{ "node_key", "body" };
    const topology_fts_values = [_]zova_fresh_value{
        .{ .value_type = 1, .int64_value = provisional_node_keys[0], .float64_value = 0, .bytes = null, .bytes_len = 0 },
        .{ .value_type = 3, .int64_value = 0, .float64_value = 0, .bytes = "linked", .bytes_len = 6 },
    };
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_fts_rows(&.{
        .build = build,
        .table_name = "topology_fts",
        .column_names = &topology_fts_columns,
        .column_count = topology_fts_columns.len,
        .values = &topology_fts_values,
        .row_count = 1,
    }));
    const vector_values = [_]i8{ 3, 4 };
    var vector_id_buffer: [32]u8 = undefined;
    const vector_id = try std.fmt.bufPrintZ(&vector_id_buffer, "edge:{d}", .{provisional_edge_keys[0]});
    const vectors = [_]zova_vector_input{.{
        .id = vector_id,
        .values = .{ .element_type = 2, .f32_values = null, .f16_values = null, .i8_values = &vector_values, .values_len = vector_values.len },
    }};
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_vectors(&.{ .build = build, .collection_name = "embedding", .vectors = &vectors, .vectors_len = 1 }));

    var node_keys = [_]i64{ 91, 92 };
    var edge_keys = [_]i64{93};
    var profile: zova_fresh_build_profile = .{};
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_finish(&.{
        .build = build,
        .out_node_keys = &node_keys,
        .out_node_keys_capacity = node_keys.len,
        .out_edge_keys = &edge_keys,
        .out_edge_keys_capacity = edge_keys.len,
        .out_profile = &profile,
    }));
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, &node_keys);
    try std.testing.expectEqualSlices(i64, &.{1}, &edge_keys);
    try std.testing.expectEqual(@as(u64, 3), profile.table_rows);
    try std.testing.expectEqual(@as(u64, 3), profile.fts_rows);
    try std.testing.expectEqual(@as(u64, 1), profile.vector_rows);
    try std.testing.expectEqual(@as(u64, 4), profile.payload_bytes);
    try std.testing.expect(freshBuildCacheDiagnostics(build).?.cache_restore_ms > 0);

    {
        var cache_size = try handle.db.prepare("pragma cache_size");
        defer cache_size.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try cache_size.step());
        try std.testing.expectEqual(@as(i64, -4096), cache_size.columnInt64(0));
    }
    {
        var rows = try handle.db.prepare("select count(*) from records");
        defer rows.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try rows.step());
        try std.testing.expectEqual(@as(i64, 2), rows.columnInt64(0));
        var index = try handle.db.prepare("select count(*) from sqlite_schema where name='records_body_idx'");
        defer index.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try index.step());
        try std.testing.expectEqual(@as(i64, 1), index.columnInt64(0));
        var refs = try handle.db.prepare("select node_key,edge_key from topology_refs");
        defer refs.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try refs.step());
        try std.testing.expectEqual(provisional_node_keys[1], refs.columnInt64(0));
        try std.testing.expectEqual(provisional_edge_keys[0], refs.columnInt64(1));
        var fts = try handle.db.prepare("select node_key from topology_fts where topology_fts match 'linked'");
        defer fts.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try fts.step());
        try std.testing.expectEqual(provisional_node_keys[0], fts.columnInt64(0));
    }
    var stored_vector: zova_vector = .{ .id = null, .id_len = 0, .element_type = 0, .f32_values = null, .f16_values = null, .i8_values = null, .values_len = 0 };
    defer zova_vector_free(&stored_vector);
    try std.testing.expectEqual(zova_status.OK, zova_vector_get(&.{ .db = db, .collection_name = "embedding", .vector_id = vector_id, .out_vector = &stored_vector }));

    var payload_results: zova_graph_edge_payload_results = .{ .items = null, .len = 0 };
    defer zova_graph_edge_payload_results_free(&payload_results);
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_payload_get_many(&.{
        .db = db,
        .graph_name = "app",
        .edge_keys = &edge_keys,
        .key_count = 1,
        .out_results = &payload_results,
    }));
    try std.testing.expectEqualSlices(u8, &payload, payload_results.items.?[0].payload.?[0..payload.len]);
    const replacement_payload = [_]u8{9};
    const replacements = [_]zova_graph_edge_payload_replacement{.{ .edge_key = edge_keys[0], .payload = &replacement_payload, .payload_len = 1 }};
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_payload_replace_many(&.{
        .db = db,
        .graph_name = "app",
        .replacements = &replacements,
        .replacement_count = 1,
    }));
    zova_graph_edge_payload_results_free(&payload_results);
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_payload_get_many(&.{
        .db = db,
        .graph_name = "app",
        .edge_keys = &edge_keys,
        .key_count = 1,
        .out_results = &payload_results,
    }));
    try std.testing.expectEqualSlices(u8, &replacement_payload, payload_results.items.?[0].payload.?[0..1]);

    try std.testing.expectEqual(zova_status.OK, zova_database_rollback(&.{ .db = db }));
    {
        var schema = try handle.db.prepare("select count(*) from sqlite_schema where name='records'");
        defer schema.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try schema.step());
        try std.testing.expectEqual(@as(i64, 0), schema.columnInt64(0));
    }

    {
        var capacity_build: ?*zova_fresh_build = null;
        try std.testing.expectEqual(zova_status.OK, zova_fresh_build_begin(&.{ .db = db, .out_build = &capacity_build }));
        defer zova_fresh_build_destroy(capacity_build);
        var capacity_node_keys = [_]i64{ 31, 32 };
        var capacity_edge_keys = [_]i64{33};
        try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_fresh_build_graph(&.{
            .build = capacity_build,
            .graph_name = "capacity-rejected",
            .nodes = &nodes,
            .nodes_len = nodes.len,
            .edges = &edges,
            .edges_len = edges.len,
            .out_node_keys = &capacity_node_keys,
            .out_node_keys_capacity = 1,
            .out_edge_keys = &capacity_edge_keys,
            .out_edge_keys_capacity = capacity_edge_keys.len,
        }));
        try std.testing.expectEqualSlices(i64, &.{ 31, 32 }, &capacity_node_keys);
        try std.testing.expectEqualSlices(i64, &.{33}, &capacity_edge_keys);
        try std.testing.expect(!(try handle.db.hasGraph("capacity-rejected")));
    }

    {
        var aborted_build: ?*zova_fresh_build = null;
        try std.testing.expectEqual(zova_status.OK, zova_fresh_build_begin(&.{ .db = db, .out_build = &aborted_build }));
        defer zova_fresh_build_destroy(aborted_build);
        var aborted_node_keys = [_]i64{ -1, -1 };
        var aborted_edge_keys = [_]i64{-1};
        try std.testing.expectEqual(zova_status.OK, zova_fresh_build_graph(&.{
            .build = aborted_build,
            .graph_name = "aborted",
            .nodes = &nodes,
            .nodes_len = nodes.len,
            .edges = &edges,
            .edges_len = edges.len,
            .out_node_keys = &aborted_node_keys,
            .out_node_keys_capacity = aborted_node_keys.len,
            .out_edge_keys = &aborted_edge_keys,
            .out_edge_keys_capacity = aborted_edge_keys.len,
        }));
        try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, &aborted_node_keys);
        try std.testing.expectEqualSlices(i64, &.{1}, &aborted_edge_keys);
        try std.testing.expectEqual(zova_status.OK, zova_fresh_build_abort(aborted_build));
        try std.testing.expect(!(try handle.db.hasGraph("aborted")));
        var cache_size = try handle.db.prepare("pragma cache_size");
        defer cache_size.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try cache_size.step());
        try std.testing.expectEqual(@as(i64, -4096), cache_size.columnInt64(0));
    }

    var rejected_build: ?*zova_fresh_build = null;
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_begin(&.{ .db = db, .out_build = &rejected_build }));
    defer zova_fresh_build_destroy(rejected_build);
    var unchanged_node_keys = [_]i64{ 71, 72 };
    var unchanged_edge_keys = [_]i64{73};
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_graph(&.{
        .build = rejected_build,
        .graph_name = "rejected",
        .nodes = &nodes,
        .nodes_len = nodes.len,
        .edges = &edges,
        .edges_len = edges.len,
        .out_node_keys = &unchanged_node_keys,
        .out_node_keys_capacity = unchanged_node_keys.len,
        .out_edge_keys = &unchanged_edge_keys,
        .out_edge_keys_capacity = unchanged_edge_keys.len,
    }));
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, &unchanged_node_keys);
    try std.testing.expectEqualSlices(i64, &.{1}, &unchanged_edge_keys);
    var finish_node_keys = [_]i64{ 71, 72 };
    var finish_edge_keys = [_]i64{73};
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_fresh_build_finish(&.{
        .build = rejected_build,
        .out_node_keys = &finish_node_keys,
        .out_node_keys_capacity = 0,
        .out_edge_keys = &finish_edge_keys,
        .out_edge_keys_capacity = 0,
        .out_profile = null,
    }));
    try std.testing.expectEqualSlices(i64, &.{ 71, 72 }, &finish_node_keys);
    try std.testing.expectEqualSlices(i64, &.{73}, &finish_edge_keys);
    try std.testing.expect(!(try handle.db.hasGraph("rejected")));
    {
        var cache_size = try handle.db.prepare("pragma cache_size");
        defer cache_size.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try cache_size.step());
        try std.testing.expectEqual(@as(i64, -4096), cache_size.columnInt64(0));
    }

    var finish_only_build: ?*zova_fresh_build = null;
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_begin(&.{ .db = db, .out_build = &finish_only_build }));
    defer zova_fresh_build_destroy(finish_only_build);
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_graph(&.{
        .build = finish_only_build,
        .graph_name = "finish-only",
        .nodes = &nodes,
        .nodes_len = nodes.len,
        .edges = &edges,
        .edges_len = edges.len,
        .out_node_keys = null,
        .out_node_keys_capacity = 0,
        .out_edge_keys = null,
        .out_edge_keys_capacity = 0,
    }));
    var finish_only_node_keys = [_]i64{ -1, -1 };
    var finish_only_edge_keys = [_]i64{-1};
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_finish(&.{
        .build = finish_only_build,
        .out_node_keys = &finish_only_node_keys,
        .out_node_keys_capacity = finish_only_node_keys.len,
        .out_edge_keys = &finish_only_edge_keys,
        .out_edge_keys_capacity = finish_only_edge_keys.len,
        .out_profile = null,
    }));
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, &finish_only_node_keys);
    try std.testing.expectEqualSlices(i64, &.{1}, &finish_only_edge_keys);
}

test "c abi fresh builder reuses enforced foreign-key validation evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/fresh-builder-validation-evidence.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    var build: ?*zova_fresh_build = null;
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_begin(&.{ .db = db, .out_build = &build }));
    defer zova_fresh_build_destroy(build);
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_finish(&.{
        .build = build,
        .out_node_keys = null,
        .out_node_keys_capacity = 0,
        .out_edge_keys = null,
        .out_edge_keys_capacity = 0,
        .out_profile = null,
    }));

    const diagnostics = freshBuildCacheDiagnostics(build).?;
    try std.testing.expect(diagnostics.baseline_foreign_key_check_ran);
    try std.testing.expect(diagnostics.validation_fast_path);
    try std.testing.expect(!diagnostics.foreign_key_check_ran);
    try std.testing.expect(!diagnostics.deferred_foreign_keys_pending);
}

test "c abi fresh builder retains full validation for unresolved deferred foreign keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/fresh-builder-deferred-foreign-key.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql =
        \\create table parents(id integer primary key);
        \\create table children(
        \\  parent_id integer references parents(id) deferrable initially deferred
        \\);
        ,
    }));
    var build: ?*zova_fresh_build = null;
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_begin(&.{ .db = db, .out_build = &build }));
    defer zova_fresh_build_destroy(build);
    const columns = [_]?[*:0]const u8{"parent_id"};
    const values = [_]zova_fresh_value{.{
        .value_type = 1,
        .int64_value = 42,
        .float64_value = 0,
        .bytes = null,
        .bytes_len = 0,
    }};
    try std.testing.expectEqual(zova_status.OK, zova_fresh_build_table_rows(&.{
        .build = build,
        .table_name = "children",
        .column_names = &columns,
        .column_count = columns.len,
        .values = &values,
        .row_count = 1,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_fresh_build_finish(&.{
        .build = build,
        .out_node_keys = null,
        .out_node_keys_capacity = 0,
        .out_edge_keys = null,
        .out_edge_keys_capacity = 0,
        .out_profile = null,
    }));

    const diagnostics = freshBuildCacheDiagnostics(build).?;
    try std.testing.expect(!diagnostics.validation_fast_path);
    try std.testing.expect(diagnostics.foreign_key_check_ran);
    try std.testing.expect(diagnostics.deferred_foreign_keys_pending);
    const handle = databaseHandle(db).?;
    var children = try handle.db.prepare("select count(*) from children");
    defer children.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try children.step());
    try std.testing.expectEqual(@as(i64, 0), children.columnInt64(0));
}

test "c abi manages bundled extension lifecycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-extension-lifecycle.zova", .{tmp.sub_path[0..]});

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_extension_install(null));

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_extension_list(&.{
        .db = db,
        .out_list = null,
    }));
    try std.testing.expectEqual(zova_status.EXTENSION_NOT_FOUND, zova_database_extension_install(&.{
        .db = db,
        .name = "missing_ext",
    }));
    try std.testing.expectEqual(zova_status.EXTENSION_INVALID, zova_database_extension_install(&.{
        .db = db,
        .name = "bad name",
    }));

    try std.testing.expectEqual(zova_status.OK, zova_database_extension_install(&.{
        .db = db,
        .name = "trgm",
    }));
    try std.testing.expectEqual(zova_status.EXTENSION_EXISTS, zova_database_extension_install(&.{
        .db = db,
        .name = "trgm",
    }));

    var info = emptyExtensionInfo();
    defer zova_extension_info_free(&info);
    try std.testing.expectEqual(zova_status.OK, zova_database_extension_info(&.{
        .db = db,
        .name = "trgm",
        .out_info = &info,
    }));
    try std.testing.expectEqualStrings("trgm", info.name.?[0..info.name_len]);
    try std.testing.expectEqualStrings("0.1.0", info.version.?[0..info.version_len]);
    try std.testing.expectEqualStrings("_zova_ext_trgm_", info.storage_prefix.?[0..info.storage_prefix_len]);
    try std.testing.expectEqualStrings("1.0.0", info.zova_abi_min.?[0..info.zova_abi_min_len]);
    try std.testing.expectEqualStrings("sql,trgm", info.capabilities.?[0..info.capabilities_len]);
    try std.testing.expectEqual(@as(u8, 1), info.required);

    try std.testing.expectEqual(zova_status.OK, zova_database_extension_check(&.{
        .db = db,
        .name = "trgm",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_extension_check_all(&.{ .db = db }));

    var list = emptyExtensionList();
    defer zova_extension_list_free(&list);
    try std.testing.expectEqual(zova_status.OK, zova_database_extension_list(&.{
        .db = db,
        .out_list = &list,
    }));
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("trgm", list.items.?[0].name.?[0..list.items.?[0].name_len]);

    try std.testing.expectEqual(zova_status.OK, zova_database_extension_drop(&.{
        .db = db,
        .name = "trgm",
    }));
    try std.testing.expectEqual(zova_status.EXTENSION_NOT_FOUND, zova_database_extension_info(&.{
        .db = db,
        .name = "trgm",
        .out_info = &info,
    }));
    try std.testing.expectEqual(zova_status.EXTENSION_NOT_FOUND, zova_database_extension_check(&.{
        .db = db,
        .name = "trgm",
    }));

    zova_extension_info_free(null);
    zova_extension_list_free(null);
}
