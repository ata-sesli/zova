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
//! The C ABI is pre-1.0. It is still designed as if consumers will generate
//! bindings from it: stable numeric statuses, opaque handles, explicit free
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
//! runs it automatically and never changes connection PRAGMAs such as
//! `foreign_keys`, journal mode, or synchronous mode on behalf of callers.
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

const allocator = std.heap.c_allocator;

const AbiMutex = struct {
    state: std.Io.Mutex = .init,

    fn lock(self: *AbiMutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    fn unlock(self: *AbiMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

// These opaque declarations match `include/zova.h`. The real state lives in
// DatabaseHandle and WriterHandle below so C callers cannot depend on layout.
pub const zova_database = opaque {};
pub const zova_object_writer = opaque {};
pub const zova_statement = opaque {};
pub const zova_subscription = opaque {};

const DatabaseHandle = struct {
    db: zova.Database,
    dynamic_extensions: ?zova.DynamicExtensionSet = null,
    extension_registry: ?zova.DynamicExtensionOwnedRegistry = null,
    // One C ABI database handle is internally serialized. This mutex protects
    // the SQLite/Zova handle, child-handle counts, and connection-scoped error
    // message. It is intentionally per-handle, not global; separate handles can
    // still run independently and follow normal SQLite locking behavior.
    mutex: AbiMutex = .{},
    live_statements: usize = 0,
    live_writers: usize = 0,
    live_subscriptions: usize = 0,
    sql_functions: std.ArrayList(SqlFunctionRegistration) = .empty,
    // Connection-scoped diagnostic text. This mirrors SQLite's model closely:
    // callers can ask the database handle for the most recent useful message,
    // and the pointer is borrowed until another call on the handle replaces it.
    last_error: ?[:0]u8 = null,
};

const SqlFunctionRegistration = struct {
    name: [:0]u8,
    arity: c_int,

    fn deinit(self: *SqlFunctionRegistration) void {
        allocator.free(self.name);
    }
};

const SqlScalarFunctionContext = struct {
    user_data: ?*anyopaque,
    callback: *const fn (?*anyopaque, ?*const zova_sql_function_call, ?*zova_sql_result) callconv(.c) void,
    destroy: zova_sql_destroy_callback,
};

const WriterHandle = struct {
    // Writers are child handles tied to one database handle. Writer methods
    // serialize through the parent database mutex.
    db: *DatabaseHandle,
    writer: zova.ObjectWriter,
};

const StatementHandle = struct {
    // Statements borrow their parent database handle and must be finalized
    // before closing the database. Statement methods serialize through the
    // parent database mutex.
    db: *DatabaseHandle,
    statement: sqlite.Statement,
};

const SubscriptionHandle = struct {
    // Subscriptions are child handles tied to one database handle. Receive and
    // close operations serialize through the parent database mutex.
    db: *DatabaseHandle,
    subscription: zova.NotificationSubscription,
};

// Keep these numeric values synchronized with `include/zova.h`. Existing values
// should be treated as ABI surface once a release containing them is published.
pub const zova_status = enum(c_int) {
    OK = 0,
    INVALID_ARGUMENT = 1,
    OUT_OF_MEMORY = 2,
    BUSY = 10,
    LOCKED = 11,
    CONSTRAINT = 12,
    CANT_OPEN = 13,
    READ_ONLY = 14,
    CORRUPT = 15,
    MISUSE = 16,
    SQLITE_ERROR = 17,
    NOT_ZOVA_PATH = 30,
    NOT_ZOVA_DATABASE = 31,
    UNSUPPORTED_ZOVA_VERSION = 32,
    DESTINATION_EXISTS = 33,
    ZOVA_NAME_CONFLICT = 34,
    OBJECT_NOT_FOUND = 50,
    OBJECT_ALREADY_EXISTS = 51,
    OBJECT_CHUNK_NOT_FOUND = 52,
    OBJECT_CHUNK_HASH_MISMATCH = 53,
    OBJECT_CORRUPT = 54,
    OBJECT_MANIFEST_INVALID = 55,
    OBJECT_RANGE_INVALID = 56,
    OBJECT_TOO_LARGE = 57,
    OBJECT_TRANSACTION_ACTIVE = 58,
    OBJECT_WRITER_CLOSED = 59,
    BOUND_STORE_EXISTS = 60,
    BOUND_STORE_NOT_FOUND = 61,
    BOUND_STORE_INVALID = 62,
    VECTOR_COLLECTION_EXISTS = 70,
    VECTOR_COLLECTION_NOT_FOUND = 71,
    VECTOR_NOT_FOUND = 72,
    VECTOR_DIMENSION_MISMATCH = 73,
    VECTOR_CORRUPT = 74,
    VECTOR_INVALID = 75,
    GRAPH_EXISTS = 80,
    GRAPH_NOT_FOUND = 81,
    GRAPH_NODE_NOT_FOUND = 82,
    GRAPH_EDGE_NOT_FOUND = 83,
    GRAPH_INVALID = 84,
    EXTENSION_NOT_FOUND = 90,
    EXTENSION_EXISTS = 91,
    EXTENSION_INVALID = 92,
    EXTENSION_INCOMPATIBLE = 93,
    EXTENSION_UNAVAILABLE = 94,
};

pub const zova_step_result = enum(c_int) {
    ROW = 1,
    DONE = 2,
};

pub const zova_column_type = enum(c_int) {
    INTEGER = 1,
    FLOAT = 2,
    TEXT = 3,
    BLOB = 4,
    NULL = 5,
};

pub const zova_sql_value_type = enum(c_int) {
    NULL = 0,
    INTEGER = 1,
    FLOAT = 2,
    TEXT = 3,
    BLOB = 4,
};

pub const zova_sql_result_type = enum(c_int) {
    NULL = 0,
    INTEGER = 1,
    FLOAT = 2,
    TEXT = 3,
    BLOB = 4,
    ERROR = 5,
};

pub const ZOVA_SQL_FUNCTION_DETERMINISTIC: u32 = 1 << 0;
pub const ZOVA_SQL_FUNCTION_DIRECT_ONLY: u32 = 1 << 1;
pub const ZOVA_SQL_FUNCTION_INNOCUOUS: u32 = 1 << 2;

pub const zova_sql_value = extern struct {
    value_type: zova_sql_value_type = .NULL,
    int64_value: i64 = 0,
    double_value: f64 = 0,
    data: ?*const anyopaque = null,
    data_len: usize = 0,
};

pub const zova_sql_result = extern struct {
    // Raw C integer so invalid callback result types can be reported as SQLite
    // callback errors instead of becoming Zig enum-safety traps.
    result_type: c_int = @intFromEnum(zova_sql_result_type.NULL),
    int64_value: i64 = 0,
    double_value: f64 = 0,
    data: ?*const anyopaque = null,
    data_len: usize = 0,
    error_message: ?[*]const u8 = null,
    error_message_len: usize = 0,
};

pub const zova_sql_function_call = extern struct {
    user_data: ?*anyopaque,
    argc: usize,
    argv: ?[*]const zova_sql_value,
};

pub const zova_sql_scalar_callback = ?*const fn (?*anyopaque, ?*const zova_sql_function_call, ?*zova_sql_result) callconv(.c) void;
pub const zova_sql_destroy_callback = ?*const fn (?*anyopaque) callconv(.c) void;

pub const zova_object_id = extern struct {
    bytes: [32]u8,
};

pub const zova_object_chunk_id = extern struct {
    bytes: [32]u8,
};

pub const zova_buffer = extern struct {
    data: ?[*]u8,
    len: usize,
};

pub const zova_message = extern struct {
    data: ?[*]u8,
    len: usize,
};

pub const zova_text = extern struct {
    data: ?[*]u8,
    len: usize,
};

pub const zova_notification = extern struct {
    channel: ?[*]u8,
    channel_len: usize,
    payload: ?[*]u8,
    payload_len: usize,
    sequence: u64,
    dropped_before: u64,
};

pub const zova_object_manifest_chunk = extern struct {
    index: u64,
    hash: zova_object_chunk_id,
    offset: u64,
    size_bytes: u64,
};

pub const zova_object_manifest = extern struct {
    object_id: zova_object_id,
    size_bytes: u64,
    chunk_count: u64,
    chunker: ?[*:0]const u8,
    chunks: ?[*]zova_object_manifest_chunk,
    chunks_len: usize,
};

pub const zova_vector_metric = enum(c_int) {
    COSINE = 0,
    L2 = 1,
    DOT = 2,
};

pub const zova_vector_element_type = enum(c_int) {
    F32 = 0,
    F16 = 1,
    I8 = 2,
};

pub const zova_vector_multi_i8_search_mode = enum(c_int) {
    GLOBAL_MIN_COSINE = 0,
    CBM_PREFILTER_MIN_COSINE = 1,
};

pub const zova_vector_multi_i8_aggregation = enum(c_int) {
    MIN_COSINE = 0,
};

pub const zova_graph_target_type = enum(c_int) {
    NONE = 0,
    RECORD = 1,
    OBJECT = 2,
    OBJECT_CHUNK = 3,
    VECTOR = 4,
    ENTITY = 5,
    FACT = 6,
    CONCEPT = 7,
    EXTERNAL = 8,
};

pub const zova_graph_neighbor_direction = enum(c_int) {
    OUTGOING = 0,
    INCOMING = 1,
};

pub const zova_vector_collection_options = extern struct {
    dimensions: u32,
    // Keep this as a raw C integer instead of a Zig enum field so invalid C
    // enum values can be reported as ZOVA_INVALID_ARGUMENT rather than tripping
    // Zig enum safety checks.
    metric: c_int,
    element_type: c_int,
};

pub const zova_vector_values = extern struct {
    element_type: c_int,
    f32_values: ?[*]const f32,
    f16_values: ?[*]const u16,
    i8_values: ?[*]const i8,
    values_len: usize,
};

pub const zova_vector = extern struct {
    id: ?[*]u8,
    id_len: usize,
    element_type: c_int,
    f32_values: ?[*]f32,
    f16_values: ?[*]u16,
    i8_values: ?[*]i8,
    values_len: usize,
};

pub const zova_vector_search_result = extern struct {
    id: ?[*]u8,
    id_len: usize,
    distance: f64,
};

pub const zova_vector_search_results = extern struct {
    items: ?[*]zova_vector_search_result,
    len: usize,
};

pub const zova_vector_collection_info = extern struct {
    name: ?[*]u8,
    name_len: usize,
    dimensions: u32,
    metric: c_int,
    element_type: c_int,
    vector_count: u64,
};

pub const zova_vector_collection_list = extern struct {
    items: ?[*]zova_vector_collection_info,
    len: usize,
};

pub const zova_vector_input = extern struct {
    id: ?[*:0]const u8,
    values: zova_vector_values,
};

pub const zova_graph_info = extern struct {
    name: ?[*]u8,
    name_len: usize,
    node_count: u64,
    edge_count: u64,
};

pub const zova_graph_list = extern struct {
    items: ?[*]zova_graph_info,
    len: usize,
};

pub const zova_extension_info = extern struct {
    name: ?[*]u8,
    name_len: usize,
    version: ?[*]u8,
    version_len: usize,
    storage_prefix: ?[*]u8,
    storage_prefix_len: usize,
    zova_abi_min: ?[*]u8,
    zova_abi_min_len: usize,
    capabilities: ?[*]u8,
    capabilities_len: usize,
    required: u8,
    installed_at_unix: i64,
    manifest_json: ?[*]u8,
    manifest_json_len: usize,
};

pub const zova_extension_list = extern struct {
    items: ?[*]zova_extension_info,
    len: usize,
};

pub const zova_graph_node = extern struct {
    graph_name: ?[*]u8,
    graph_name_len: usize,
    node_id: ?[*]u8,
    node_id_len: usize,
    kind: ?[*]u8,
    kind_len: usize,
    target_type: c_int,
    target_namespace: ?[*]u8,
    target_namespace_len: usize,
    has_target_namespace: u8,
    target_ref: ?[*]u8,
    target_ref_len: usize,
    has_target_ref: u8,
};

pub const zova_graph_edge = extern struct {
    graph_name: ?[*]u8,
    graph_name_len: usize,
    from_node_id: ?[*]u8,
    from_node_id_len: usize,
    edge_type: ?[*]u8,
    edge_type_len: usize,
    to_node_id: ?[*]u8,
    to_node_id_len: usize,
};

pub const zova_graph_neighbor_result = extern struct {
    node_id: ?[*]u8,
    node_id_len: usize,
    kind: ?[*]u8,
    kind_len: usize,
    edge_type: ?[*]u8,
    edge_type_len: usize,
};

pub const zova_graph_neighbor_results = extern struct {
    items: ?[*]zova_graph_neighbor_result,
    len: usize,
};

pub const zova_graph_walk_result = extern struct {
    node_id: ?[*]u8,
    node_id_len: usize,
    kind: ?[*]u8,
    kind_len: usize,
    depth: u32,
    predecessor_node_id: ?[*]u8,
    predecessor_node_id_len: usize,
    has_predecessor_node_id: u8,
    edge_type: ?[*]u8,
    edge_type_len: usize,
    has_edge_type: u8,
};

pub const zova_graph_walk_results = extern struct {
    items: ?[*]zova_graph_walk_result,
    len: usize,
};

pub const zova_graph_walk_profile = extern struct {
    mutex_wait_ms: f64 = 0,
    root_lookup_ms: f64 = 0,
    adjacency_prepare_ms: f64 = 0,
    adjacency_execute_ms: f64 = 0,
    bfs_bookkeeping_allocation_ms: f64 = 0,
    c_abi_result_export_ms: f64 = 0,
    total_profiled_ms: f64 = 0,
    frontier_expansions: u64 = 0,
    adjacency_query_binds: u64 = 0,
    adjacency_rows_stepped: u64 = 0,
    result_count: u64 = 0,
};

pub const ZOVA_OPEN_READ_ONLY: u32 = 1 << 0;
pub const ZOVA_BACKUP_NO_VERIFY: u32 = 1 << 0;
pub const ZOVA_COMPACT_NO_VERIFY: u32 = 1 << 0;
pub const ZOVA_RESTORE_NO_VERIFY: u32 = 1 << 0;

pub const zova_database_open_request = extern struct {
    path: ?[*:0]const u8,
    out_db: ?*?*zova_database,
    out_error_message: ?*zova_message,
};

pub const zova_database_open_options_request = extern struct {
    path: ?[*:0]const u8,
    flags: u32,
    busy_timeout_ms: u32,
    out_db: ?*?*zova_database,
    out_error_message: ?*zova_message,
};

pub const zova_database_open_extensions_request = extern struct {
    path: ?[*:0]const u8,
    flags: u32,
    busy_timeout_ms: u32,
    extension_bundle_paths: ?[*]const ?[*:0]const u8,
    extension_bundle_count: usize,
    trust_store_path: ?[*:0]const u8,
    out_db: ?*?*zova_database,
    out_error_message: ?*zova_message,
};

pub const zova_extension_bundle_request = extern struct {
    bundle_path: ?[*:0]const u8,
    trust_store_path: ?[*:0]const u8,
    out_error_message: ?*zova_message,
};

pub const zova_extension_bundle_untrust_request = extern struct {
    identifier: ?[*:0]const u8,
    trust_store_path: ?[*:0]const u8,
    out_removed: ?*u8,
    out_error_message: ?*zova_message,
};

pub const zova_convert_sqlite_to_zova_request = extern struct {
    source_path: ?[*:0]const u8,
    dest_path: ?[*:0]const u8,
    out_error_message: ?*zova_message,
};

pub const zova_database_backup_request = extern struct {
    db: ?*zova_database,
    destination_path: ?[*:0]const u8,
    flags: u32,
};

pub const zova_database_compact_request = extern struct {
    db: ?*zova_database,
    destination_path: ?[*:0]const u8,
    flags: u32,
};

pub const zova_database_restore_request = extern struct {
    source_path: ?[*:0]const u8,
    destination_path: ?[*:0]const u8,
    flags: u32,
    out_error_message: ?*zova_message,
};

pub const zova_database_exec_request = extern struct {
    db: ?*zova_database,
    sql: ?[*:0]const u8,
};

pub const zova_sql_function_register_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
    arity: c_int,
    flags: u32,
    user_data: ?*anyopaque,
    callback: zova_sql_scalar_callback,
    destroy: zova_sql_destroy_callback,
};

pub const zova_database_simple_request = extern struct {
    db: ?*zova_database,
};

pub const zova_database_savepoint_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
};

pub const zova_database_busy_timeout_request = extern struct {
    db: ?*zova_database,
    milliseconds: u32,
};

pub const zova_database_last_insert_rowid_request = extern struct {
    db: ?*zova_database,
    out_rowid: ?*i64,
};

pub const zova_database_changes_request = extern struct {
    db: ?*zova_database,
    out_changes: ?*i64,
};

pub const zova_database_total_changes_request = extern struct {
    db: ?*zova_database,
    out_total_changes: ?*i64,
};

pub const zova_database_notify_request = extern struct {
    db: ?*zova_database,
    channel: ?[*:0]const u8,
    payload: ?[*]const u8,
    payload_len: usize,
};

pub const zova_database_listen_request = extern struct {
    db: ?*zova_database,
    channel: ?[*:0]const u8,
    out_subscription: ?*?*zova_subscription,
};

pub const zova_subscription_try_receive_request = extern struct {
    subscription: ?*zova_subscription,
    out_notification: ?*zova_notification,
    out_has_notification: ?*u8,
};

pub const zova_database_prepare_request = extern struct {
    db: ?*zova_database,
    sql: ?[*:0]const u8,
    out_statement: ?*?*zova_statement,
};

pub const zova_statement_step_request = extern struct {
    statement: ?*zova_statement,
    out_result: ?*zova_step_result,
};

pub const zova_statement_bind_null_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
};

pub const zova_statement_bind_int64_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
    value: i64,
};

pub const zova_statement_bind_double_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
    value: f64,
};

pub const zova_statement_bind_text_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
    data: ?[*]const u8,
    len: usize,
};

pub const zova_statement_bind_blob_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
    data: ?[*]const u8,
    len: usize,
};

pub const zova_statement_parameter_count_request = extern struct {
    statement: ?*zova_statement,
    out_count: ?*c_int,
};

pub const zova_statement_parameter_index_request = extern struct {
    statement: ?*zova_statement,
    name: ?[*:0]const u8,
    out_index: ?*c_int,
};

pub const zova_statement_column_count_request = extern struct {
    statement: ?*zova_statement,
    out_count: ?*c_int,
};

pub const zova_statement_column_name_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
    out_name: ?*zova_text,
};

pub const zova_statement_column_type_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
    out_type: ?*zova_column_type,
};

pub const zova_statement_column_int64_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
    out_value: ?*i64,
};

pub const zova_statement_column_double_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
    out_value: ?*f64,
};

pub const zova_statement_column_text_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
    out_text: ?*zova_text,
};

pub const zova_statement_column_blob_request = extern struct {
    statement: ?*zova_statement,
    index: c_int,
    out_buffer: ?*zova_buffer,
};

pub const zova_object_put_request = extern struct {
    db: ?*zova_database,
    data: ?[*]const u8,
    len: usize,
    out_id: ?*zova_object_id,
};

pub const zova_object_get_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_buffer: ?*zova_buffer,
};

pub const zova_object_read_range_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    offset: u64,
    buffer: ?[*]u8,
    buffer_len: usize,
    out_copied: ?*usize,
};

pub const zova_object_exists_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_exists: ?*u8,
};

pub const zova_object_size_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_size: ?*u64,
};

pub const zova_object_chunk_count_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_count: ?*u64,
};

pub const zova_object_delete_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
};

pub const zova_object_manifest_get_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_manifest: ?*zova_object_manifest,
};

pub const zova_object_chunk_get_request = extern struct {
    db: ?*zova_database,
    hash: zova_object_chunk_id,
    out_buffer: ?*zova_buffer,
};

pub const zova_object_chunk_put_request = extern struct {
    db: ?*zova_database,
    expected_hash: zova_object_chunk_id,
    data: ?[*]const u8,
    len: usize,
};

pub const zova_object_chunk_delete_request = extern struct {
    db: ?*zova_database,
    hash: zova_object_chunk_id,
    out_deleted: ?*u8,
};

pub const zova_object_assemble_from_chunks_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    size_bytes: u64,
    chunks: ?[*]const zova_object_manifest_chunk,
    chunk_count: usize,
};

pub const zova_object_writer_create_request = extern struct {
    db: ?*zova_database,
    out_writer: ?*?*zova_object_writer,
};

pub const zova_object_writer_write_request = extern struct {
    writer: ?*zova_object_writer,
    data: ?[*]const u8,
    len: usize,
};

pub const zova_object_writer_finish_request = extern struct {
    writer: ?*zova_object_writer,
    out_id: ?*zova_object_id,
};

pub const zova_object_writer_cancel_request = extern struct {
    writer: ?*zova_object_writer,
};

pub const zova_vector_collection_create_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
    options: zova_vector_collection_options,
};

pub const zova_vector_collection_exists_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
    out_exists: ?*u8,
};

pub const zova_vector_put_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    vector_id: ?[*:0]const u8,
    values: zova_vector_values,
};

pub const zova_vector_get_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    vector_id: ?[*:0]const u8,
    out_vector: ?*zova_vector,
};

pub const zova_vector_exists_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    vector_id: ?[*:0]const u8,
    out_exists: ?*u8,
};

pub const zova_vector_delete_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    vector_id: ?[*:0]const u8,
};

pub const zova_vector_search_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    query: zova_vector_values,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

pub const zova_vector_search_in_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    query: zova_vector_values,
    candidate_ids: ?[*]const ?[*:0]const u8,
    candidate_count: usize,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

pub const zova_vector_search_multi_i8_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    query_values: ?[*]const i8,
    query_values_len: usize,
    query_count: usize,
    dimensions: usize,
    candidate_ids: ?[*]const ?[*:0]const u8,
    candidate_count: usize,
    mode: c_int,
    aggregation: c_int,
    prefilter_query_index: usize,
    prefilter_limit: usize,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

pub const zova_vector_collection_info_get_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
    out_info: ?*zova_vector_collection_info,
};

pub const zova_vector_collections_list_request = extern struct {
    db: ?*zova_database,
    out_list: ?*zova_vector_collection_list,
};

pub const zova_vector_put_many_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    vectors: ?[*]const zova_vector_input,
    vectors_len: usize,
};

pub const zova_vector_collection_delete_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
};

pub const zova_vector_search_within_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    query: zova_vector_values,
    max_distance: f64,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

pub const zova_vector_search_in_within_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    query: zova_vector_values,
    candidate_ids: ?[*]const ?[*:0]const u8,
    candidate_count: usize,
    max_distance: f64,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

pub const zova_vector_search_by_id_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    source_vector_id: ?[*:0]const u8,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

pub const zova_vector_search_by_id_in_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    source_vector_id: ?[*:0]const u8,
    candidate_ids: ?[*]const ?[*:0]const u8,
    candidate_count: usize,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

pub const zova_vector_search_by_id_within_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    source_vector_id: ?[*:0]const u8,
    max_distance: f64,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

pub const zova_vector_search_by_id_in_within_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    source_vector_id: ?[*:0]const u8,
    candidate_ids: ?[*]const ?[*:0]const u8,
    candidate_count: usize,
    max_distance: f64,
    limit: usize,
    out_results: ?*zova_vector_search_results,
};

pub const zova_graph_create_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
};

pub const zova_graph_exists_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
    out_exists: ?*u8,
};

pub const zova_graph_info_get_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
    out_info: ?*zova_graph_info,
};

pub const zova_graph_list_request = extern struct {
    db: ?*zova_database,
    out_list: ?*zova_graph_list,
};

pub const zova_database_extension_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
};

pub const zova_database_extension_info_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
    out_info: ?*zova_extension_info,
};

pub const zova_database_extension_list_request = extern struct {
    db: ?*zova_database,
    out_list: ?*zova_extension_list,
};

pub const zova_graph_delete_request = extern struct {
    db: ?*zova_database,
    name: ?[*:0]const u8,
};

pub const zova_graph_node_put_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_id: ?[*:0]const u8,
    kind: ?[*:0]const u8,
    target_type: c_int,
    target_namespace: ?[*:0]const u8,
    target_ref: ?[*:0]const u8,
};

/// Borrowed graph node input for zova_graph_node_put_many.
pub const zova_graph_node_input = extern struct {
    graph_name: ?[*:0]const u8,
    node_id: ?[*:0]const u8,
    kind: ?[*:0]const u8,
    target_type: c_int,
    target_namespace: ?[*:0]const u8,
    target_ref: ?[*:0]const u8,
};

pub const zova_graph_node_put_many_request = extern struct {
    db: ?*zova_database,
    nodes: ?[*]const zova_graph_node_input,
    nodes_len: usize,
};

pub const zova_graph_node_get_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_id: ?[*:0]const u8,
    out_node: ?*zova_graph_node,
};

pub const zova_graph_node_exists_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_id: ?[*:0]const u8,
    out_exists: ?*u8,
};

pub const zova_graph_node_delete_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_id: ?[*:0]const u8,
};

pub const zova_graph_node_delete_many_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_ids: ?[*]const ?[*:0]const u8,
    node_count: usize,
};

pub const zova_graph_edge_put_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    from_node_id: ?[*:0]const u8,
    edge_type: ?[*:0]const u8,
    to_node_id: ?[*:0]const u8,
};

/// Borrowed graph edge input for zova_graph_edge_put_many.
pub const zova_graph_edge_input = extern struct {
    graph_name: ?[*:0]const u8,
    from_node_id: ?[*:0]const u8,
    edge_type: ?[*:0]const u8,
    to_node_id: ?[*:0]const u8,
};

pub const zova_graph_edge_put_many_request = extern struct {
    db: ?*zova_database,
    edges: ?[*]const zova_graph_edge_input,
    edges_len: usize,
};

pub const zova_graph_edge_get_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    from_node_id: ?[*:0]const u8,
    edge_type: ?[*:0]const u8,
    to_node_id: ?[*:0]const u8,
    out_edge: ?*zova_graph_edge,
};

pub const zova_graph_edge_exists_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    from_node_id: ?[*:0]const u8,
    edge_type: ?[*:0]const u8,
    to_node_id: ?[*:0]const u8,
    out_exists: ?*u8,
};

pub const zova_graph_edge_delete_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    from_node_id: ?[*:0]const u8,
    edge_type: ?[*:0]const u8,
    to_node_id: ?[*:0]const u8,
};

pub const zova_graph_neighbors_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_id: ?[*:0]const u8,
    direction: c_int,
    edge_type: ?[*:0]const u8,
    limit: usize,
    out_results: ?*zova_graph_neighbor_results,
};

pub const zova_graph_degree_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_id: ?[*:0]const u8,
    direction: c_int,
    edge_type: ?[*:0]const u8,
    out_degree: ?*u64,
};

pub const zova_graph_walk_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    start_node_id: ?[*:0]const u8,
    edge_type: ?[*:0]const u8,
    max_depth: u32,
    limit: usize,
    out_results: ?*zova_graph_walk_results,
};

pub const zova_graph_walk_direction_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    start_node_id: ?[*:0]const u8,
    direction: c_int,
    edge_type: ?[*:0]const u8,
    max_depth: u32,
    limit: usize,
    out_results: ?*zova_graph_walk_results,
};

pub const zova_graph_walk_direction_profiled_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    start_node_id: ?[*:0]const u8,
    direction: c_int,
    edge_type: ?[*:0]const u8,
    max_depth: u32,
    limit: usize,
    out_results: ?*zova_graph_walk_results,
    out_profile: ?*zova_graph_walk_profile,
};

// Version helpers describe the C ABI boundary, not the .zova file format.
pub fn zova_abi_version_major() callconv(.c) u32 {
    return zova_version.abi_version_major;
}

pub fn zova_abi_version_minor() callconv(.c) u32 {
    return zova_version.abi_version_minor;
}

pub fn zova_abi_version_patch() callconv(.c) u32 {
    return zova_version.abi_version_patch;
}

pub fn zova_abi_version_string() callconv(.c) [*:0]const u8 {
    return zova_version.abi_version_string;
}

// Accept a raw integer instead of a Zig enum so accidental or future C enum
// values cannot trigger a Zig enum safety check.
pub fn zova_status_name(status: c_int) callconv(.c) [*:0]const u8 {
    return statusName(status);
}

// Free functions are null-safe and reset containers. That makes repeated frees
// harmless for callers that follow the container API instead of freeing fields.
pub fn zova_buffer_free(buffer: ?*zova_buffer) callconv(.c) void {
    const out = buffer orelse return;
    if (out.data) |data| {
        allocator.free(data[0..out.len]);
    }
    out.* = .{ .data = null, .len = 0 };
}

pub fn zova_message_free(message: ?*zova_message) callconv(.c) void {
    const out = message orelse return;
    if (out.data) |data| {
        allocator.free(data[0 .. out.len + 1]);
    }
    out.* = .{ .data = null, .len = 0 };
}

pub fn zova_text_free(text: ?*zova_text) callconv(.c) void {
    const out = text orelse return;
    if (out.data) |data| {
        allocator.free(data[0 .. out.len + 1]);
    }
    out.* = emptyText();
}

pub fn zova_notification_free(notification: ?*zova_notification) callconv(.c) void {
    const out = notification orelse return;
    if (out.channel) |channel| {
        allocator.free(channel[0 .. out.channel_len + 1]);
    }
    if (out.payload) |payload| {
        allocator.free(payload[0 .. out.payload_len + 1]);
    }
    out.* = emptyNotification();
}

pub fn zova_object_manifest_free(manifest: ?*zova_object_manifest) callconv(.c) void {
    const out = manifest orelse return;
    if (out.chunks) |chunks| {
        allocator.free(chunks[0..out.chunks_len]);
    }
    out.* = emptyManifest();
}

pub fn zova_vector_free(vector: ?*zova_vector) callconv(.c) void {
    const out = vector orelse return;
    if (out.id) |id| {
        allocator.free(id[0 .. out.id_len + 1]);
    }
    if (out.f32_values) |values| {
        allocator.free(values[0..out.values_len]);
    }
    if (out.f16_values) |values| {
        allocator.free(values[0..out.values_len]);
    }
    if (out.i8_values) |values| {
        allocator.free(values[0..out.values_len]);
    }
    out.* = emptyVector();
}

pub fn zova_vector_search_results_free(results: ?*zova_vector_search_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |item| {
            if (item.id) |id| {
                allocator.free(id[0 .. item.id_len + 1]);
            }
        }
        allocator.free(items[0..out.len]);
    }
    out.* = emptyVectorSearchResults();
}

pub fn zova_vector_collection_info_free(info: ?*zova_vector_collection_info) callconv(.c) void {
    const out = info orelse return;
    freeVectorCollectionInfo(out);
    out.* = emptyVectorCollectionInfo();
}

pub fn zova_vector_collection_list_free(list: ?*zova_vector_collection_list) callconv(.c) void {
    const out = list orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeVectorCollectionInfo(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyVectorCollectionList();
}

pub fn zova_graph_info_free(info: ?*zova_graph_info) callconv(.c) void {
    const out = info orelse return;
    freeGraphInfo(out);
    out.* = emptyGraphInfo();
}

pub fn zova_graph_list_free(list: ?*zova_graph_list) callconv(.c) void {
    const out = list orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeGraphInfo(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyGraphList();
}

pub fn zova_extension_info_free(info: ?*zova_extension_info) callconv(.c) void {
    const out = info orelse return;
    freeExtensionInfo(out);
    out.* = emptyExtensionInfo();
}

pub fn zova_extension_list_free(list: ?*zova_extension_list) callconv(.c) void {
    const out = list orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeExtensionInfo(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyExtensionList();
}

pub fn zova_graph_node_free(node: ?*zova_graph_node) callconv(.c) void {
    const out = node orelse return;
    freeGraphNode(out);
    out.* = emptyGraphNode();
}

pub fn zova_graph_edge_free(edge: ?*zova_graph_edge) callconv(.c) void {
    const out = edge orelse return;
    freeGraphEdge(out);
    out.* = emptyGraphEdge();
}

pub fn zova_graph_neighbor_results_free(results: ?*zova_graph_neighbor_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeGraphNeighborResult(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyGraphNeighborResults();
}

pub fn zova_graph_walk_results_free(results: ?*zova_graph_walk_results) callconv(.c) void {
    const out = results orelse return;
    if (out.items) |items| {
        for (items[0..out.len]) |*item| freeGraphWalkResult(item);
        allocator.free(items[0..out.len]);
    }
    out.* = emptyGraphWalkResults();
}

pub fn zova_database_create(request: ?*const zova_database_open_request) callconv(.c) zova_status {
    return openDatabase(request, .create);
}

pub fn zova_database_create_with_extensions(request: ?*const zova_database_open_extensions_request) callconv(.c) zova_status {
    return openDatabaseWithExtensions(request, .create);
}

pub fn zova_database_open(request: ?*const zova_database_open_request) callconv(.c) zova_status {
    return openDatabase(request, .open);
}

pub fn zova_database_open_with_options(request: ?*const zova_database_open_options_request) callconv(.c) zova_status {
    return openDatabaseWithOptions(request);
}

pub fn zova_database_open_with_extensions(request: ?*const zova_database_open_extensions_request) callconv(.c) zova_status {
    return openDatabaseWithExtensions(request, .open);
}

pub fn zova_extension_bundle_verify(request: ?*const zova_extension_bundle_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const bundle_path = req.bundle_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    zova.extension_dynamic.verifyBundleEntrypoint(allocator, std.mem.span(bundle_path)) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    return .OK;
}

pub fn zova_extension_bundle_trust(request: ?*const zova_extension_bundle_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const bundle_path = req.bundle_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    var record = zova.extension_dynamic.trustBundle(allocator, std.mem.span(bundle_path), trustStoreOptions(req.trust_store_path)) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    record.deinit(allocator);
    return .OK;
}

pub fn zova_extension_bundle_untrust(request: ?*const zova_extension_bundle_untrust_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const identifier = req.identifier orelse return failMessage(req.out_error_message, error.InvalidArgument);
    const removed = zova.extension_dynamic.untrust(allocator, std.mem.span(identifier), trustStoreOptions(req.trust_store_path)) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    if (req.out_removed) |out| out.* = if (removed) 1 else 0;
    return .OK;
}

pub fn zova_database_close(db: ?*zova_database) callconv(.c) zova_status {
    const handle = databaseHandle(db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    if (handle.live_statements != 0 or handle.live_writers != 0 or handle.live_subscriptions != 0) {
        defer handle.mutex.unlock();
        var message_buffer: [192]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "cannot close database with live child handles: {d} statements, {d} object writers, {d} subscriptions",
            .{ handle.live_statements, handle.live_writers, handle.live_subscriptions },
        ) catch "cannot close database with live child handles";
        return failDbStatusString(handle, .MISUSE, message);
    }
    clearLastError(handle);
    handle.db.deinit();
    if (handle.extension_registry) |*registry| registry.deinit();
    if (handle.dynamic_extensions) |*dynamic_extensions| dynamic_extensions.deinit();
    deinitSqlFunctionRegistrations(handle);
    handle.mutex.unlock();
    allocator.destroy(handle);
    return .OK;
}

pub fn zova_database_exec(request: ?*const zova_database_exec_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const sql = req.sql orelse return failDb(handle, error.InvalidArgument);
    handle.db.exec(std.mem.span(sql)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_register_function(request: ?*const zova_sql_function_register_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();

    const name_z = req.name orelse return failDb(handle, error.InvalidArgument);
    const name = std.mem.span(name_z);
    validateSqlFunctionName(name) catch |err| return failDb(handle, err);
    if (!isValidSqlFunctionArity(req.arity)) return failDb(handle, error.InvalidArgument);
    if ((req.flags & ~allowed_sql_function_flags) != 0) return failDb(handle, error.InvalidArgument);
    const callback = req.callback orelse return failDb(handle, error.InvalidArgument);
    if (hasRegisteredSqlFunction(handle, name, req.arity)) return failDb(handle, error.InvalidArgument);

    handle.sql_functions.ensureUnusedCapacity(allocator, 1) catch |err| return failDb(handle, err);

    const context = allocator.create(SqlScalarFunctionContext) catch |err| return failDb(handle, err);
    context.* = .{
        .user_data = req.user_data,
        .callback = callback,
        .destroy = req.destroy,
    };

    const name_copy = allocator.dupeZ(u8, name) catch |err| {
        destroySqlScalarContext(@ptrCast(context));
        return failDb(handle, err);
    };

    const rc = sqlite.c.sqlite3_create_function_v2(
        handle.db.sqlite_db.handle,
        name_z,
        req.arity,
        sqlFunctionFlagsToSqlite(req.flags),
        context,
        sqlScalarTrampoline,
        null,
        null,
        destroySqlScalarContext,
    );
    if (rc != sqlite.c.SQLITE_OK) {
        allocator.free(name_copy);
        return failDbSqliteResult(handle, rc);
    }

    handle.sql_functions.appendAssumeCapacity(.{ .name = name_copy, .arity = req.arity });

    return okDb(handle);
}

pub fn zova_database_begin(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    handle.db.begin() catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_begin_immediate(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    handle.db.beginImmediate() catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_commit(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    handle.db.commit() catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_rollback(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    handle.db.rollback() catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return databaseSavepoint(request, .savepoint);
}

pub fn zova_database_rollback_to_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return databaseSavepoint(request, .rollback_to);
}

pub fn zova_database_release_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return databaseSavepoint(request, .release);
}

pub fn zova_database_vacuum(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    handle.db.vacuum() catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_backup(request: ?*const zova_database_backup_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const destination_path = req.destination_path orelse return failDb(handle, error.InvalidArgument);
    if ((req.flags & ~ZOVA_BACKUP_NO_VERIFY) != 0) return failDb(handle, error.InvalidArgument);

    handle.db.backupTo(std.mem.span(destination_path), .{
        .verify = (req.flags & ZOVA_BACKUP_NO_VERIFY) == 0,
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_compact(request: ?*const zova_database_compact_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const destination_path = req.destination_path orelse return failDb(handle, error.InvalidArgument);
    if ((req.flags & ~ZOVA_COMPACT_NO_VERIFY) != 0) return failDb(handle, error.InvalidArgument);

    handle.db.compactTo(std.mem.span(destination_path), .{
        .verify = (req.flags & ZOVA_COMPACT_NO_VERIFY) == 0,
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_set_busy_timeout(request: ?*const zova_database_busy_timeout_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    if (req.milliseconds > std.math.maxInt(c_int)) return failDb(handle, error.InvalidArgument);
    handle.db.setBusyTimeout(req.milliseconds) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_last_insert_rowid(request: ?*const zova_database_last_insert_rowid_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_rowid orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.lastInsertRowid();
    return okDb(handle);
}

pub fn zova_database_changes(request: ?*const zova_database_changes_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_changes orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.changes();
    return okDb(handle);
}

pub fn zova_database_total_changes(request: ?*const zova_database_total_changes_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_total_changes orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.totalChanges();
    return okDb(handle);
}

pub fn zova_database_notify(request: ?*const zova_database_notify_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const channel = req.channel orelse return failDb(handle, error.InvalidArgument);
    const payload = bytesConst(req.payload, req.payload_len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.notify(std.mem.span(channel), payload) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_listen(request: ?*const zova_database_listen_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const channel = req.channel orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_subscription orelse return failDb(handle, error.InvalidArgument);
    out.* = null;

    const subscription = handle.db.listen(std.mem.span(channel)) catch |err| return failDb(handle, err);
    const subscription_handle = allocator.create(SubscriptionHandle) catch |err| {
        var cleanup = subscription;
        cleanup.deinit();
        return failDb(handle, err);
    };
    subscription_handle.* = .{ .db = handle, .subscription = subscription };
    handle.live_subscriptions += 1;
    out.* = @ptrCast(subscription_handle);
    return okDb(handle);
}

pub fn zova_subscription_try_receive(request: ?*const zova_subscription_try_receive_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = subscriptionHandle(req.subscription) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out_notification = req.out_notification orelse return failDb(handle.db, error.InvalidArgument);
    const out_has_notification = req.out_has_notification orelse return failDb(handle.db, error.InvalidArgument);

    zova_notification_free(out_notification);
    out_has_notification.* = 0;
    var notification = handle.subscription.tryReceive(allocator) catch |err| return failDb(handle.db, err);
    if (notification) |*value| {
        defer value.deinit(allocator);
        fillNotification(out_notification, value.*) catch |err| return failDb(handle.db, err);
        out_has_notification.* = 1;
    }
    return okDb(handle.db);
}

pub fn zova_subscription_close(subscription: ?*zova_subscription) callconv(.c) zova_status {
    const handle = subscriptionHandle(subscription) orelse return .INVALID_ARGUMENT;
    const db_handle = handle.db;
    db_handle.mutex.lock();
    defer db_handle.mutex.unlock();
    handle.subscription.deinit();
    std.debug.assert(db_handle.live_subscriptions > 0);
    db_handle.live_subscriptions -= 1;
    allocator.destroy(handle);
    return okDb(db_handle);
}

const SavepointOperation = enum {
    savepoint,
    rollback_to,
    release,
};

fn databaseSavepoint(request: ?*const zova_database_savepoint_request, operation: SavepointOperation) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const result = switch (operation) {
        .savepoint => handle.db.savepoint(std.mem.span(name)),
        .rollback_to => handle.db.rollbackToSavepoint(std.mem.span(name)),
        .release => handle.db.releaseSavepoint(std.mem.span(name)),
    };
    result catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_prepare(request: ?*const zova_database_prepare_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const sql = req.sql orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_statement orelse return failDb(handle, error.InvalidArgument);
    out.* = null;

    const statement = handle.db.prepare(std.mem.span(sql)) catch |err| return failDb(handle, err);
    const statement_handle = allocator.create(StatementHandle) catch |err| {
        var cleanup = statement;
        cleanup.deinit();
        return failDb(handle, err);
    };
    statement_handle.* = .{ .db = handle, .statement = statement };
    handle.live_statements += 1;
    out.* = @ptrCast(statement_handle);
    return okDb(handle);
}

pub fn zova_statement_finalize(statement: ?*zova_statement) callconv(.c) zova_status {
    const handle = statementHandle(statement) orelse return .INVALID_ARGUMENT;
    const db_handle = handle.db;
    db_handle.mutex.lock();
    defer db_handle.mutex.unlock();
    handle.statement.deinit();
    std.debug.assert(db_handle.live_statements > 0);
    db_handle.live_statements -= 1;
    allocator.destroy(handle);
    return okDb(db_handle);
}

pub fn zova_statement_step(request: ?*const zova_statement_step_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_result orelse return failDb(handle.db, error.InvalidArgument);
    const result = handle.statement.step() catch |err| return failDb(handle.db, err);
    out.* = switch (result) {
        .row => .ROW,
        .done => .DONE,
    };
    return okDb(handle.db);
}

pub fn zova_statement_reset(statement: ?*zova_statement) callconv(.c) zova_status {
    const handle = statementHandle(statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.statement.reset() catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_clear_bindings(statement: ?*zova_statement) callconv(.c) zova_status {
    const handle = statementHandle(statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.statement.clearBindings() catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_bind_null(request: ?*const zova_statement_bind_null_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.statement.bindNull(req.index) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_bind_int64(request: ?*const zova_statement_bind_int64_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.statement.bindInt64(req.index, req.value) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_bind_double(request: ?*const zova_statement_bind_double_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.statement.bindDouble(req.index, req.value) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_bind_text(request: ?*const zova_statement_bind_text_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle.db, error.InvalidArgument);
    handle.statement.bindText(req.index, bytes) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_bind_blob(request: ?*const zova_statement_bind_blob_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle.db, error.InvalidArgument);
    handle.statement.bindBlob(req.index, bytes) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_statement_parameter_count(request: ?*const zova_statement_parameter_count_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_count orelse return failDb(handle.db, error.InvalidArgument);
    out.* = handle.statement.parameterCount();
    return okDb(handle.db);
}

pub fn zova_statement_parameter_index(request: ?*const zova_statement_parameter_index_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const name = req.name orelse return failDb(handle.db, error.InvalidArgument);
    const out = req.out_index orelse return failDb(handle.db, error.InvalidArgument);
    out.* = handle.statement.parameterIndex(std.mem.span(name));
    return okDb(handle.db);
}

pub fn zova_statement_column_count(request: ?*const zova_statement_column_count_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_count orelse return failDb(handle.db, error.InvalidArgument);
    out.* = handle.statement.columnCount();
    return okDb(handle.db);
}

pub fn zova_statement_column_name(request: ?*const zova_statement_column_name_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_name orelse return failDb(handle.db, error.InvalidArgument);
    zova_text_free(out);

    const name = handle.statement.columnName(req.index) catch |err| return failDb(handle.db, err);
    const copy = allocator.alloc(u8, name.len + 1) catch |err| return failDb(handle.db, err);
    @memcpy(copy[0..name.len], name);
    copy[name.len] = 0;
    out.* = .{ .data = copy.ptr, .len = name.len };
    return okDb(handle.db);
}

pub fn zova_statement_column_type(request: ?*const zova_statement_column_type_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_type orelse return failDb(handle.db, error.InvalidArgument);
    out.* = columnTypeToAbi(handle.statement.columnType(req.index));
    return okDb(handle.db);
}

pub fn zova_statement_column_int64(request: ?*const zova_statement_column_int64_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_value orelse return failDb(handle.db, error.InvalidArgument);
    out.* = handle.statement.columnInt64(req.index);
    return okDb(handle.db);
}

pub fn zova_statement_column_double(request: ?*const zova_statement_column_double_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_value orelse return failDb(handle.db, error.InvalidArgument);
    out.* = handle.statement.columnDouble(req.index);
    return okDb(handle.db);
}

pub fn zova_statement_column_text(request: ?*const zova_statement_column_text_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_text orelse return failDb(handle.db, error.InvalidArgument);
    zova_text_free(out);

    if (handle.statement.columnType(req.index) == .null) return okDb(handle.db);
    const text = handle.statement.columnText(req.index);
    const copy = allocator.alloc(u8, text.len + 1) catch |err| return failDb(handle.db, err);
    @memcpy(copy[0..text.len], text);
    copy[text.len] = 0;
    out.* = .{ .data = copy.ptr, .len = text.len };
    return okDb(handle.db);
}

pub fn zova_statement_column_blob(request: ?*const zova_statement_column_blob_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = statementHandle(req.statement) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_buffer orelse return failDb(handle.db, error.InvalidArgument);
    zova_buffer_free(out);

    if (handle.statement.columnType(req.index) == .null) return okDb(handle.db);
    const blob = handle.statement.columnBlob(req.index);
    if (blob.len == 0) return okDb(handle.db);

    const copy = allocator.alloc(u8, blob.len) catch |err| return failDb(handle.db, err);
    @memcpy(copy, blob);
    out.* = .{ .data = copy.ptr, .len = copy.len };
    return okDb(handle.db);
}

pub fn zova_database_last_error_message(db: ?*zova_database) callconv(.c) [*:0]const u8 {
    const handle = databaseHandle(db) orelse return "invalid database handle";
    handle.mutex.lock();
    defer handle.mutex.unlock();
    if (handle.last_error) |message| return message.ptr;
    return "";
}

// No-handle operations cannot use connection-scoped diagnostics, so request
// structs optionally carry an owned zova_message for callers that want details.
pub fn zova_convert_sqlite_to_zova(request: ?*const zova_convert_sqlite_to_zova_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const source_path = req.source_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    const dest_path = req.dest_path orelse return failMessage(req.out_error_message, error.InvalidArgument);

    zova.convertSqliteToZova(std.mem.span(source_path), std.mem.span(dest_path)) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    return .OK;
}

pub fn zova_database_restore(request: ?*const zova_database_restore_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const source_path = req.source_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    const destination_path = req.destination_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    if ((req.flags & ~ZOVA_RESTORE_NO_VERIFY) != 0) return failMessage(req.out_error_message, error.InvalidArgument);

    zova.restoreBackup(std.mem.span(source_path), std.mem.span(destination_path), .{
        .verify = (req.flags & ZOVA_RESTORE_NO_VERIFY) == 0,
    }) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    return .OK;
}

// The public helper name is not `zova_object_id`: in C, typedef names and
// function names share one namespace, so that would collide with the id type.
pub fn zova_object_id_from_bytes(data: ?[*]const u8, len: usize, out_id: ?*zova_object_id) callconv(.c) zova_status {
    const out = out_id orelse return .INVALID_ARGUMENT;
    const bytes = bytesConst(data, len) orelse return .INVALID_ARGUMENT;
    out.* = fromObjectId(zova.objectId(bytes));
    return .OK;
}

pub fn zova_object_chunk_id_from_bytes(
    data: ?[*]const u8,
    len: usize,
    out_id: ?*zova_object_chunk_id,
) callconv(.c) zova_status {
    const out = out_id orelse return .INVALID_ARGUMENT;
    const bytes = bytesConst(data, len) orelse return .INVALID_ARGUMENT;
    out.* = fromChunkId(zova.objectChunkId(bytes));
    return .OK;
}

pub fn zova_object_put(request: ?*const zova_object_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_id orelse return failDb(handle, error.InvalidArgument);
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle, error.InvalidArgument);
    const id = handle.db.putObject(bytes) catch |err| return failDb(handle, err);
    out.* = fromObjectId(id);
    return okDb(handle);
}

pub fn zova_object_get(request: ?*const zova_object_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_buffer orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyBuffer();
    var object = handle.db.getObject(allocator, toObjectId(req.id)) catch |err| return failDb(handle, err);
    // Transfer ownership of the allocation from zova.Object to zova_buffer.
    out.* = .{ .data = object.bytes.ptr, .len = object.bytes.len };
    object.bytes = &.{};
    return okDb(handle);
}

pub fn zova_object_read_range(request: ?*const zova_object_read_range_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_copied orelse return failDb(handle, error.InvalidArgument);
    out.* = 0;
    const buffer = bytesMut(req.buffer, req.buffer_len) orelse return failDb(handle, error.InvalidArgument);
    const copied = handle.db.readObjectRange(toObjectId(req.id), req.offset, buffer) catch |err| return failDb(handle, err);
    out.* = copied;
    return okDb(handle);
}

pub fn zova_object_delete(request: ?*const zova_object_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    handle.db.deleteObject(toObjectId(req.id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_exists(request: ?*const zova_object_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasObject(toObjectId(req.id)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_object_size(request: ?*const zova_object_size_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_size orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.objectSize(toObjectId(req.id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_chunk_count(request: ?*const zova_object_chunk_count_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_count orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.objectChunkCount(toObjectId(req.id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_manifest_get(request: ?*const zova_object_manifest_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_manifest orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyManifest();

    var manifest = handle.db.objectManifest(allocator, toObjectId(req.id)) catch |err| return failDb(handle, err);
    defer manifest.deinit(allocator);

    const chunks = allocator.alloc(zova_object_manifest_chunk, manifest.chunks.len) catch |err| return failDb(handle, err);
    errdefer allocator.free(chunks);
    for (manifest.chunks, chunks) |chunk, *out_chunk| {
        out_chunk.* = .{
            .index = chunk.index,
            .hash = fromChunkId(chunk.hash),
            .offset = chunk.offset,
            .size_bytes = chunk.size_bytes,
        };
    }

    out.* = .{
        .object_id = fromObjectId(manifest.object_id),
        .size_bytes = manifest.size_bytes,
        .chunk_count = manifest.chunk_count,
        .chunker = "fastcdc-v1",
        .chunks = if (chunks.len == 0) null else chunks.ptr,
        .chunks_len = chunks.len,
    };
    return okDb(handle);
}

pub fn zova_object_chunk_get(request: ?*const zova_object_chunk_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_buffer orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyBuffer();
    var chunk = handle.db.getObjectChunk(allocator, toChunkId(req.hash)) catch |err| return failDb(handle, err);
    // Transfer ownership of the allocation from zova.ObjectChunkData to zova_buffer.
    out.* = .{ .data = chunk.bytes.ptr, .len = chunk.bytes.len };
    chunk.bytes = &.{};
    return okDb(handle);
}

pub fn zova_object_chunk_put(request: ?*const zova_object_chunk_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle, error.InvalidArgument);
    handle.db.putObjectChunk(toChunkId(req.expected_hash), bytes) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_chunk_delete(request: ?*const zova_object_chunk_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_deleted orelse return failDb(handle, error.InvalidArgument);
    const deleted = handle.db.deleteObjectChunk(toChunkId(req.hash)) catch |err| return failDb(handle, err);
    out.* = if (deleted) 1 else 0;
    return okDb(handle);
}

pub fn zova_object_assemble_from_chunks(
    request: ?*const zova_object_assemble_from_chunks_request,
) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const input_chunks = manifestChunks(req.chunks, req.chunk_count) orelse return failDb(handle, error.InvalidArgument);
    const chunks = allocator.alloc(zova.ObjectChunk, input_chunks.len) catch |err| return failDb(handle, err);
    defer allocator.free(chunks);
    for (input_chunks, chunks) |chunk, *out_chunk| {
        out_chunk.* = .{
            .index = chunk.index,
            .hash = toChunkId(chunk.hash),
            .offset = chunk.offset,
            .size_bytes = chunk.size_bytes,
        };
    }
    handle.db.assembleObjectFromChunks(toObjectId(req.id), req.size_bytes, chunks) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_object_writer_create(request: ?*const zova_object_writer_create_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_writer orelse return failDb(handle, error.InvalidArgument);
    out.* = null;

    var writer = handle.db.objectWriter(allocator) catch |err| return failDb(handle, err);
    const writer_handle = allocator.create(WriterHandle) catch |err| {
        writer.deinit();
        return failDb(handle, err);
    };
    writer_handle.* = .{ .db = handle, .writer = writer };
    handle.live_writers += 1;
    out.* = @ptrCast(writer_handle);
    return okDb(handle);
}

pub fn zova_object_writer_write(request: ?*const zova_object_writer_write_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = writerHandle(req.writer) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const bytes = bytesConst(req.data, req.len) orelse return failDb(handle.db, error.InvalidArgument);
    handle.writer.write(bytes) catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_object_writer_finish(request: ?*const zova_object_writer_finish_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = writerHandle(req.writer) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    const out = req.out_id orelse return failDb(handle.db, error.InvalidArgument);
    const id = handle.writer.finish() catch |err| return failDb(handle.db, err);
    out.* = fromObjectId(id);
    return okDb(handle.db);
}

pub fn zova_object_writer_cancel(request: ?*const zova_object_writer_cancel_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = writerHandle(req.writer) orelse return .INVALID_ARGUMENT;
    handle.db.mutex.lock();
    defer handle.db.mutex.unlock();
    handle.writer.cancel() catch |err| return failDb(handle.db, err);
    return okDb(handle.db);
}

pub fn zova_object_writer_destroy(writer: ?*zova_object_writer) callconv(.c) zova_status {
    const handle = writerHandle(writer) orelse return .INVALID_ARGUMENT;
    const db_handle = handle.db;
    db_handle.mutex.lock();
    defer db_handle.mutex.unlock();
    handle.writer.deinit();
    std.debug.assert(db_handle.live_writers > 0);
    db_handle.live_writers -= 1;
    allocator.destroy(handle);
    return okDb(db_handle);
}

pub fn zova_vector_collection_create(request: ?*const zova_vector_collection_create_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const metric = vectorMetricFromAbi(req.options.metric) orelse return failDb(handle, error.InvalidArgument);
    const element_type = vectorElementTypeFromAbi(req.options.element_type) orelse return failDb(handle, error.InvalidArgument);

    handle.db.createVectorCollection(std.mem.span(name), .{
        .dimensions = req.options.dimensions,
        .metric = metric,
        .element_type = element_type,
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_collection_exists(request: ?*const zova_vector_collection_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasVectorCollection(std.mem.span(name)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_vector_put(request: ?*const zova_vector_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);
    const values = vectorValuesConst(req.values) orelse return failDb(handle, error.InvalidArgument);

    handle.db.putVector(std.mem.span(collection_name), std.mem.span(vector_id), values) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_get(request: ?*const zova_vector_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_vector orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVector();

    var vector = handle.db.getVector(allocator, std.mem.span(collection_name), std.mem.span(vector_id)) catch |err| return failDb(handle, err);
    errdefer vector.deinit(allocator);
    fillVector(out, &vector) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_exists(request: ?*const zova_vector_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasVector(std.mem.span(collection_name), std.mem.span(vector_id)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_vector_delete(request: ?*const zova_vector_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const vector_id = req.vector_id orelse return failDb(handle, error.InvalidArgument);

    handle.db.deleteVector(std.mem.span(collection_name), std.mem.span(vector_id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search(request: ?*const zova_vector_search_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const query = vectorValuesConst(req.query) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    var results = handle.db.searchVectors(allocator, std.mem.span(collection_name), query, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_in(request: ?*const zova_vector_search_in_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const query = vectorValuesConst(req.query) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchVectorsIn(allocator, std.mem.span(collection_name), query, candidates, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_multi_i8(request: ?*const zova_vector_search_multi_i8_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();
    const mode = multiI8SearchModeFromAbi(req.mode) orelse return failDb(handle, error.InvalidArgument);
    if (multiI8AggregationFromAbi(req.aggregation) == null) return failDb(handle, error.InvalidArgument);

    const queries = multiI8QuerySlices(req.query_values, req.query_values_len, req.query_count, req.dimensions) catch |err| return failDb(handle, err);
    defer allocator.free(queries);
    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchMultiI8Cosine(allocator, std.mem.span(collection_name), .{
        .queries = queries,
        .candidate_ids = if (req.candidate_count == 0) null else candidates,
        .mode = mode,
        .prefilter_query_index = req.prefilter_query_index,
        .prefilter_limit = req.prefilter_limit,
    }, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_collection_info_get(request: ?*const zova_vector_collection_info_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_info orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorCollectionInfo();

    var info = handle.db.vectorCollectionInfo(allocator, std.mem.span(name)) catch |err| return failDb(handle, err);
    defer info.deinit(allocator);

    fillVectorCollectionInfo(out, info) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_collections_list(request: ?*const zova_vector_collections_list_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_list orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorCollectionList();

    var list = handle.db.listVectorCollections(allocator) catch |err| return failDb(handle, err);
    defer list.deinit(allocator);

    fillVectorCollectionList(out, list.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_put_many(request: ?*const zova_vector_put_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);

    const vectors = vectorInputSlices(req.vectors, req.vectors_len) catch |err| return failDb(handle, err);
    defer if (vectors.len != 0) allocator.free(vectors);

    handle.db.putVectors(std.mem.span(collection_name), vectors) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_collection_delete(request: ?*const zova_vector_collection_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);

    handle.db.deleteVectorCollection(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_within(request: ?*const zova_vector_search_within_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const query = vectorValuesConst(req.query) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    var results = handle.db.searchVectorsWithin(allocator, std.mem.span(collection_name), query, req.max_distance, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_in_within(request: ?*const zova_vector_search_in_within_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const query = vectorValuesConst(req.query) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchVectorsInWithin(allocator, std.mem.span(collection_name), query, candidates, req.max_distance, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_by_id(request: ?*const zova_vector_search_by_id_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const source_vector_id = req.source_vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    var results = handle.db.searchVectorsById(allocator, std.mem.span(collection_name), std.mem.span(source_vector_id), req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_by_id_in(request: ?*const zova_vector_search_by_id_in_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const source_vector_id = req.source_vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchVectorsByIdIn(allocator, std.mem.span(collection_name), std.mem.span(source_vector_id), candidates, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_by_id_within(request: ?*const zova_vector_search_by_id_within_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const source_vector_id = req.source_vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    var results = handle.db.searchVectorsByIdWithin(allocator, std.mem.span(collection_name), std.mem.span(source_vector_id), req.max_distance, req.limit) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_vector_search_by_id_in_within(request: ?*const zova_vector_search_by_id_in_within_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const collection_name = req.collection_name orelse return failDb(handle, error.InvalidArgument);
    const source_vector_id = req.source_vector_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyVectorSearchResults();

    const candidates = candidateIdSlices(req.candidate_ids, req.candidate_count) catch |err| return failDb(handle, err);
    defer if (candidates.len != 0) allocator.free(candidates);

    var results = handle.db.searchVectorsByIdInWithin(
        allocator,
        std.mem.span(collection_name),
        std.mem.span(source_vector_id),
        candidates,
        req.max_distance,
        req.limit,
    ) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);

    fillSearchResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_create(request: ?*const zova_graph_create_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    handle.db.createGraph(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_exists(request: ?*const zova_graph_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasGraph(std.mem.span(name)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_graph_info_get(request: ?*const zova_graph_info_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_info orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphInfo();
    var info = handle.db.graphInfo(allocator, std.mem.span(name)) catch |err| return failDb(handle, err);
    defer info.deinit(allocator);
    fillGraphInfo(out, info) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graphs_list(request: ?*const zova_graph_list_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_list orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphList();
    var list = handle.db.listGraphs(allocator) catch |err| return failDb(handle, err);
    defer list.deinit(allocator);
    fillGraphList(out, list.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_extension_install(request: ?*const zova_database_extension_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    handle.db.installExtension(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_extension_list(request: ?*const zova_database_extension_list_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const out = req.out_list orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyExtensionList();
    var list = handle.db.listExtensions(allocator) catch |err| return failDb(handle, err);
    defer list.deinit(allocator);
    fillExtensionList(out, list.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_extension_info(request: ?*const zova_database_extension_info_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_info orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyExtensionInfo();
    var info = handle.db.extensionInfo(allocator, std.mem.span(name)) catch |err| return failDb(handle, err);
    defer info.deinit(allocator);
    fillExtensionInfo(out, info) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_extension_check(request: ?*const zova_database_extension_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    handle.db.checkExtension(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_extension_check_all(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    var list = handle.db.listExtensions(allocator) catch |err| return failDb(handle, err);
    defer list.deinit(allocator);
    for (list.items) |item| {
        handle.db.checkExtension(item.name) catch |err| return failDb(handle, err);
    }
    return okDb(handle);
}

pub fn zova_database_extension_drop(request: ?*const zova_database_extension_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    handle.db.dropExtension(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_delete(request: ?*const zova_graph_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    handle.db.deleteGraph(std.mem.span(name)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_node_put(request: ?*const zova_graph_node_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const kind = req.kind orelse return failDb(handle, error.InvalidArgument);
    const target_type = graphTargetTypeFromAbi(req.target_type) orelse return failDb(handle, error.InvalidArgument);
    handle.db.putGraphNode(.{
        .graph_name = std.mem.span(graph_name),
        .node_id = std.mem.span(node_id),
        .kind = std.mem.span(kind),
        .target_type = target_type,
        .target_namespace = optionalCStringSpan(req.target_namespace),
        .target_ref = optionalCStringSpan(req.target_ref),
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_node_put_many(request: ?*const zova_graph_node_put_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const nodes = graphNodeInputSlices(req.nodes, req.nodes_len) catch |err| return failDb(handle, err);
    defer if (nodes.len != 0) allocator.free(nodes);
    handle.db.putGraphNodes(nodes) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_node_get(request: ?*const zova_graph_node_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_node orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphNode();
    var node = handle.db.getGraphNode(allocator, std.mem.span(graph_name), std.mem.span(node_id)) catch |err| return failDb(handle, err);
    defer node.deinit(allocator);
    fillGraphNode(out, node) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_node_exists(request: ?*const zova_graph_node_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasGraphNode(std.mem.span(graph_name), std.mem.span(node_id)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_graph_node_delete(request: ?*const zova_graph_node_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    handle.db.deleteGraphNode(std.mem.span(graph_name), std.mem.span(node_id)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_node_delete_many(request: ?*const zova_graph_node_delete_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_ids = candidateIdSlices(req.node_ids, req.node_count) catch |err| return failDb(handle, err);
    defer if (node_ids.len != 0) allocator.free(node_ids);
    handle.db.deleteGraphNodes(std.mem.span(graph_name), node_ids) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_put(request: ?*const zova_graph_edge_put_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const from_node_id = req.from_node_id orelse return failDb(handle, error.InvalidArgument);
    const edge_type = req.edge_type orelse return failDb(handle, error.InvalidArgument);
    const to_node_id = req.to_node_id orelse return failDb(handle, error.InvalidArgument);
    handle.db.putGraphEdge(.{
        .graph_name = std.mem.span(graph_name),
        .from_node_id = std.mem.span(from_node_id),
        .edge_type = std.mem.span(edge_type),
        .to_node_id = std.mem.span(to_node_id),
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_put_many(request: ?*const zova_graph_edge_put_many_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const edges = graphEdgeInputSlices(req.edges, req.edges_len) catch |err| return failDb(handle, err);
    defer if (edges.len != 0) allocator.free(edges);
    handle.db.putGraphEdges(edges) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_get(request: ?*const zova_graph_edge_get_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const from_node_id = req.from_node_id orelse return failDb(handle, error.InvalidArgument);
    const edge_type = req.edge_type orelse return failDb(handle, error.InvalidArgument);
    const to_node_id = req.to_node_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_edge orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphEdge();
    var edge = handle.db.getGraphEdge(allocator, std.mem.span(graph_name), std.mem.span(from_node_id), std.mem.span(edge_type), std.mem.span(to_node_id)) catch |err| return failDb(handle, err);
    defer edge.deinit(allocator);
    fillGraphEdge(out, edge) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_edge_exists(request: ?*const zova_graph_edge_exists_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const from_node_id = req.from_node_id orelse return failDb(handle, error.InvalidArgument);
    const edge_type = req.edge_type orelse return failDb(handle, error.InvalidArgument);
    const to_node_id = req.to_node_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_exists orelse return failDb(handle, error.InvalidArgument);
    const exists = handle.db.hasGraphEdge(std.mem.span(graph_name), std.mem.span(from_node_id), std.mem.span(edge_type), std.mem.span(to_node_id)) catch |err| return failDb(handle, err);
    out.* = if (exists) 1 else 0;
    return okDb(handle);
}

pub fn zova_graph_edge_delete(request: ?*const zova_graph_edge_delete_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const from_node_id = req.from_node_id orelse return failDb(handle, error.InvalidArgument);
    const edge_type = req.edge_type orelse return failDb(handle, error.InvalidArgument);
    const to_node_id = req.to_node_id orelse return failDb(handle, error.InvalidArgument);
    handle.db.deleteGraphEdge(.{
        .graph_name = std.mem.span(graph_name),
        .from_node_id = std.mem.span(from_node_id),
        .edge_type = std.mem.span(edge_type),
        .to_node_id = std.mem.span(to_node_id),
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_neighbors(request: ?*const zova_graph_neighbors_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const direction = graphDirectionFromAbi(req.direction) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphNeighborResults();
    var results = handle.db.graphNeighbors(allocator, .{
        .graph_name = std.mem.span(graph_name),
        .node_id = std.mem.span(node_id),
        .direction = direction,
        .edge_type = optionalCStringSpan(req.edge_type),
        .limit = req.limit,
    }) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphNeighborResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_degree(request: ?*const zova_graph_degree_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const node_id = req.node_id orelse return failDb(handle, error.InvalidArgument);
    const direction = graphDirectionFromAbi(req.direction) orelse return failDb(handle, error.InvalidArgument);
    const out_degree = req.out_degree orelse return failDb(handle, error.InvalidArgument);
    out_degree.* = handle.db.graphDegree(.{
        .graph_name = std.mem.span(graph_name),
        .node_id = std.mem.span(node_id),
        .direction = direction,
        .edge_type = optionalCStringSpan(req.edge_type),
    }) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_walk(request: ?*const zova_graph_walk_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const start_node_id = req.start_node_id orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphWalkResults();
    var results = handle.db.graphWalk(allocator, .{
        .graph_name = std.mem.span(graph_name),
        .start_node_id = std.mem.span(start_node_id),
        .edge_type = optionalCStringSpan(req.edge_type),
        .max_depth = req.max_depth,
        .limit = req.limit,
    }) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphWalkResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_walk_direction(request: ?*const zova_graph_walk_direction_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    defer handle.mutex.unlock();
    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const start_node_id = req.start_node_id orelse return failDb(handle, error.InvalidArgument);
    const direction = graphDirectionFromAbi(req.direction) orelse return failDb(handle, error.InvalidArgument);
    const out = req.out_results orelse return failDb(handle, error.InvalidArgument);
    out.* = emptyGraphWalkResults();
    var results = handle.db.graphWalkDirection(allocator, .{
        .graph_name = std.mem.span(graph_name),
        .start_node_id = std.mem.span(start_node_id),
        .direction = direction,
        .edge_type = optionalCStringSpan(req.edge_type),
        .max_depth = req.max_depth,
        .limit = req.limit,
    }) catch |err| return failDb(handle, err);
    defer results.deinit(allocator);
    fillGraphWalkResults(out, results.items) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_graph_walk_direction_profiled(request: ?*const zova_graph_walk_direction_profiled_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const out = req.out_results orelse return .INVALID_ARGUMENT;
    const out_profile = req.out_profile orelse return .INVALID_ARGUMENT;
    out.* = emptyGraphWalkResults();
    out_profile.* = .{};

    const handle = databaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    const total_start = cAbiProfileTimestamp();
    const mutex_start = cAbiProfileTimestamp();
    handle.mutex.lock();
    out_profile.mutex_wait_ms = cAbiProfileElapsedMs(mutex_start);
    defer handle.mutex.unlock();

    const graph_name = req.graph_name orelse return failDb(handle, error.InvalidArgument);
    const start_node_id = req.start_node_id orelse return failDb(handle, error.InvalidArgument);
    const direction = graphDirectionFromAbi(req.direction) orelse return failDb(handle, error.InvalidArgument);
    var scan_profile: graph.GraphWalkScanProfile = .{};
    const traversal_start = cAbiProfileTimestamp();
    var results = handle.db.graphWalkDirectionProfiled(allocator, .{
        .graph_name = std.mem.span(graph_name),
        .start_node_id = std.mem.span(start_node_id),
        .direction = direction,
        .edge_type = optionalCStringSpan(req.edge_type),
        .max_depth = req.max_depth,
        .limit = req.limit,
    }, &scan_profile) catch |err| return failDb(handle, err);
    var results_active = true;
    defer if (results_active) results.deinit(allocator);
    const traversal_ms = cAbiProfileElapsedMs(traversal_start);

    out_profile.root_lookup_ms = scan_profile.root_lookup_ms;
    out_profile.adjacency_prepare_ms = scan_profile.adjacency_prepare_ms;
    out_profile.adjacency_execute_ms = scan_profile.adjacency_execute_ms;
    const traversal_accounted_ms = scan_profile.root_lookup_ms + scan_profile.adjacency_prepare_ms + scan_profile.adjacency_execute_ms;
    out_profile.bfs_bookkeeping_allocation_ms = @max(0, traversal_ms - traversal_accounted_ms);
    out_profile.frontier_expansions = scan_profile.frontier_expansions;
    out_profile.adjacency_query_binds = scan_profile.adjacency_query_binds;
    out_profile.adjacency_rows_stepped = scan_profile.adjacency_rows_stepped;
    out_profile.result_count = scan_profile.result_count;

    const export_start = cAbiProfileTimestamp();
    fillGraphWalkResults(out, results.items) catch |err| return failDb(handle, err);
    out_profile.c_abi_result_export_ms = cAbiProfileElapsedMs(export_start);
    const cleanup_start = cAbiProfileTimestamp();
    results.deinit(allocator);
    results_active = false;
    out_profile.bfs_bookkeeping_allocation_ms += cAbiProfileElapsedMs(cleanup_start);
    out_profile.total_profiled_ms = cAbiProfileElapsedMs(total_start);
    return okDb(handle);
}

fn cAbiProfileIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn cAbiProfileTimestamp() std.Io.Timestamp {
    return std.Io.Clock.awake.now(cAbiProfileIo());
}

fn cAbiProfileElapsedMs(start: std.Io.Timestamp) f64 {
    const elapsed_ns = start.durationTo(cAbiProfileTimestamp()).toNanoseconds();
    if (elapsed_ns <= 0) return 0;
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms);
}

const OpenMode = enum { create, open };

fn openDatabase(request: ?*const zova_database_open_request, mode: OpenMode) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const out = req.out_db orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = null;
    const path = req.path orelse return failMessage(req.out_error_message, error.InvalidArgument);

    var db = switch (mode) {
        .create => zova.Database.create(std.mem.span(path)),
        .open => zova.Database.open(std.mem.span(path)),
    } catch |err| return failMessage(req.out_error_message, err);

    const handle = allocator.create(DatabaseHandle) catch |err| {
        db.deinit();
        return failMessage(req.out_error_message, err);
    };
    handle.* = .{ .db = db };
    out.* = @ptrCast(handle);
    return .OK;
}

fn openDatabaseWithOptions(request: ?*const zova_database_open_options_request) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const out = req.out_db orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = null;
    const path = req.path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    if ((req.flags & ~ZOVA_OPEN_READ_ONLY) != 0) return failMessage(req.out_error_message, error.InvalidArgument);
    if (req.busy_timeout_ms > std.math.maxInt(c_int)) return failMessage(req.out_error_message, error.InvalidArgument);

    var db = zova.Database.openWithOptions(std.mem.span(path), .{
        .read_only = (req.flags & ZOVA_OPEN_READ_ONLY) != 0,
        .busy_timeout_ms = req.busy_timeout_ms,
    }) catch |err| return failMessage(req.out_error_message, err);

    const handle = allocator.create(DatabaseHandle) catch |err| {
        db.deinit();
        return failMessage(req.out_error_message, err);
    };
    handle.* = .{ .db = db };
    out.* = @ptrCast(handle);
    return .OK;
}

fn openDatabaseWithExtensions(request: ?*const zova_database_open_extensions_request, mode: OpenMode) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const out = req.out_db orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = null;
    const path = req.path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    if ((req.flags & ~ZOVA_OPEN_READ_ONLY) != 0) return failMessage(req.out_error_message, error.InvalidArgument);
    if (mode == .create and (req.flags != 0 or req.busy_timeout_ms != 0)) return failMessage(req.out_error_message, error.InvalidArgument);
    if (req.busy_timeout_ms > std.math.maxInt(c_int)) return failMessage(req.out_error_message, error.InvalidArgument);

    const bundle_paths = bundlePathSlices(allocator, req.extension_bundle_paths, req.extension_bundle_count) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    defer allocator.free(bundle_paths);

    if (bundle_paths.len == 0) {
        return switch (mode) {
            .create => openDatabase(&.{
                .path = req.path,
                .out_db = req.out_db,
                .out_error_message = req.out_error_message,
            }, .create),
            .open => openDatabaseWithOptions(&.{
                .path = req.path,
                .flags = req.flags,
                .busy_timeout_ms = req.busy_timeout_ms,
                .out_db = req.out_db,
                .out_error_message = req.out_error_message,
            }),
        };
    }

    var dynamic_extensions = zova.DynamicExtensionSet.loadTrustedBundles(
        allocator,
        bundle_paths,
        trustStoreOptions(req.trust_store_path),
    ) catch |err| return failMessage(req.out_error_message, err);

    var owned_registry = zova.DynamicExtensionOwnedRegistry.init(allocator, &.{
        zova.bundledExtensionRegistry(),
        dynamic_extensions.registry(),
    }) catch |err| {
        dynamic_extensions.deinit();
        return failMessage(req.out_error_message, err);
    };

    var db = switch (mode) {
        .create => zova.Database.createWithExtensions(std.mem.span(path), owned_registry.registry()),
        .open => zova.Database.openWithOptionsAndExtensions(std.mem.span(path), .{
            .read_only = (req.flags & ZOVA_OPEN_READ_ONLY) != 0,
            .busy_timeout_ms = req.busy_timeout_ms,
        }, owned_registry.registry()),
    } catch |err| {
        owned_registry.deinit();
        dynamic_extensions.deinit();
        return failMessage(req.out_error_message, err);
    };

    const handle = allocator.create(DatabaseHandle) catch |err| {
        db.deinit();
        owned_registry.deinit();
        dynamic_extensions.deinit();
        return failMessage(req.out_error_message, err);
    };
    handle.* = .{
        .db = db,
        .dynamic_extensions = dynamic_extensions,
        .extension_registry = owned_registry,
    };
    out.* = @ptrCast(handle);
    return .OK;
}

fn bundlePathSlices(gpa: std.mem.Allocator, paths: ?[*]const ?[*:0]const u8, count: usize) ![]const []const u8 {
    if (count == 0) return try gpa.alloc([]const u8, 0);
    const raw_paths = paths orelse return error.InvalidArgument;
    const out = try gpa.alloc([]const u8, count);
    errdefer gpa.free(out);
    for (raw_paths[0..count], 0..) |path, index| {
        const path_z = path orelse return error.InvalidArgument;
        out[index] = std.mem.span(path_z);
    }
    return out;
}

fn trustStoreOptions(path: ?[*:0]const u8) zova.DynamicExtensionTrustStoreOptions {
    return .{ .path = if (path) |value| std.mem.span(value) else null };
}

// Opaque handles are just erased DatabaseHandle/WriterHandle pointers. Casts
// stay local to this module so the ABI can keep exposing incomplete C structs.
fn databaseHandle(db: ?*zova_database) ?*DatabaseHandle {
    const ptr = db orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn writerHandle(writer: ?*zova_object_writer) ?*WriterHandle {
    const ptr = writer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn statementHandle(statement: ?*zova_statement) ?*StatementHandle {
    const ptr = statement orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn subscriptionHandle(subscription: ?*zova_subscription) ?*SubscriptionHandle {
    const ptr = subscription orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// A null pointer is valid only for empty byte slices. That keeps empty objects
// and zero-length range buffers ergonomic while still catching bad lengths.
fn bytesConst(data: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

fn bytesMut(data: ?[*]u8, len: usize) ?[]u8 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

const allowed_sql_function_flags =
    ZOVA_SQL_FUNCTION_DETERMINISTIC |
    ZOVA_SQL_FUNCTION_DIRECT_ONLY |
    ZOVA_SQL_FUNCTION_INNOCUOUS;

fn validateSqlFunctionName(name: []const u8) error{InvalidArgument}!void {
    if (name.len == 0 or name.len > 64) return error.InvalidArgument;
    if (hasAsciiInsensitivePrefix(name, "zova_") or hasAsciiInsensitivePrefix(name, "_zova_")) return error.InvalidArgument;
    if (!isAsciiIdentStart(name[0])) return error.InvalidArgument;
    for (name[1..]) |byte| {
        if (!isAsciiIdentContinue(byte)) return error.InvalidArgument;
    }
}

fn isValidSqlFunctionArity(arity: c_int) bool {
    return arity == -1 or (arity >= 0 and arity <= 127);
}

fn hasRegisteredSqlFunction(handle: *DatabaseHandle, name: []const u8, arity: c_int) bool {
    for (handle.sql_functions.items) |item| {
        if (item.arity == arity and asciiInsensitiveEql(item.name, name)) return true;
    }
    return false;
}

fn sqlFunctionFlagsToSqlite(flags: u32) c_int {
    var sqlite_flags: c_int = sqlite.c.SQLITE_UTF8;
    if ((flags & ZOVA_SQL_FUNCTION_DETERMINISTIC) != 0) sqlite_flags |= sqlite.c.SQLITE_DETERMINISTIC;
    if ((flags & ZOVA_SQL_FUNCTION_DIRECT_ONLY) != 0) sqlite_flags |= sqlite.c.SQLITE_DIRECTONLY;
    if ((flags & ZOVA_SQL_FUNCTION_INNOCUOUS) != 0) sqlite_flags |= sqlite.c.SQLITE_INNOCUOUS;
    return sqlite_flags;
}

fn deinitSqlFunctionRegistrations(handle: *DatabaseHandle) void {
    for (handle.sql_functions.items) |*item| item.deinit();
    handle.sql_functions.deinit(allocator);
}

fn destroySqlScalarContext(user_data: ?*anyopaque) callconv(.c) void {
    const context_ptr = user_data orelse return;
    const context: *SqlScalarFunctionContext = @ptrCast(@alignCast(context_ptr));
    if (context.destroy) |destroy| destroy(context.user_data);
    allocator.destroy(context);
}

fn sqlScalarTrampoline(
    sqlite_context: ?*sqlite.c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*sqlite.c.sqlite3_value,
) callconv(.c) void {
    const raw_context = sqlite_context orelse return;
    const user_data = sqlite.c.sqlite3_user_data(raw_context) orelse {
        sqlite.c.sqlite3_result_error(raw_context, "missing zova sql callback context", -1);
        return;
    };
    const context: *SqlScalarFunctionContext = @ptrCast(@alignCast(user_data));
    if (argc < 0) {
        sqlite.c.sqlite3_result_error(raw_context, "invalid zova sql callback argc", -1);
        return;
    }

    const count: usize = @intCast(argc);
    const values = allocator.alloc(zova_sql_value, count) catch {
        sqlite.c.sqlite3_result_error_nomem(raw_context);
        return;
    };
    defer allocator.free(values);

    for (values, 0..) |*value, index| {
        const sqlite_value = argv[index] orelse {
            sqlite.c.sqlite3_result_error(raw_context, "invalid zova sql callback argv", -1);
            return;
        };
        value.* = sqlValueFromSqlite(sqlite_value);
    }

    var call = zova_sql_function_call{
        .user_data = context.user_data,
        .argc = count,
        .argv = if (values.len == 0) null else values.ptr,
    };
    var result = zova_sql_result{};
    context.callback(context.user_data, &call, &result);
    applySqlResult(raw_context, result);
}

fn sqlValueFromSqlite(value: *sqlite.c.sqlite3_value) zova_sql_value {
    return switch (sqlite.c.sqlite3_value_type(value)) {
        sqlite.c.SQLITE_INTEGER => .{
            .value_type = .INTEGER,
            .int64_value = sqlite.c.sqlite3_value_int64(value),
        },
        sqlite.c.SQLITE_FLOAT => .{
            .value_type = .FLOAT,
            .double_value = sqlite.c.sqlite3_value_double(value),
        },
        sqlite.c.SQLITE_TEXT => textSqlValue(value),
        sqlite.c.SQLITE_BLOB => blobSqlValue(value),
        sqlite.c.SQLITE_NULL => .{ .value_type = .NULL },
        else => .{ .value_type = .NULL },
    };
}

fn textSqlValue(value: *sqlite.c.sqlite3_value) zova_sql_value {
    const len_raw = sqlite.c.sqlite3_value_bytes(value);
    const len: usize = if (len_raw <= 0) 0 else @intCast(len_raw);
    const ptr = sqlite.c.sqlite3_value_text(value);
    return .{
        .value_type = .TEXT,
        .data = if (ptr == null) null else @ptrCast(ptr),
        .data_len = len,
    };
}

fn blobSqlValue(value: *sqlite.c.sqlite3_value) zova_sql_value {
    const len_raw = sqlite.c.sqlite3_value_bytes(value);
    const len: usize = if (len_raw <= 0) 0 else @intCast(len_raw);
    const ptr = sqlite.c.sqlite3_value_blob(value);
    return .{
        .value_type = .BLOB,
        .data = if (ptr == null) null else @ptrCast(ptr),
        .data_len = len,
    };
}

fn applySqlResult(sqlite_context: *sqlite.c.sqlite3_context, result: zova_sql_result) void {
    switch (result.result_type) {
        @intFromEnum(zova_sql_result_type.NULL) => sqlite.c.sqlite3_result_null(sqlite_context),
        @intFromEnum(zova_sql_result_type.INTEGER) => sqlite.c.sqlite3_result_int64(sqlite_context, result.int64_value),
        @intFromEnum(zova_sql_result_type.FLOAT) => sqlite.c.sqlite3_result_double(sqlite_context, result.double_value),
        @intFromEnum(zova_sql_result_type.TEXT) => applySqlTextResult(sqlite_context, result.data, result.data_len),
        @intFromEnum(zova_sql_result_type.BLOB) => applySqlBlobResult(sqlite_context, result.data, result.data_len),
        @intFromEnum(zova_sql_result_type.ERROR) => applySqlErrorResult(sqlite_context, result.error_message, result.error_message_len),
        else => sqlite.c.sqlite3_result_error(sqlite_context, "invalid zova sql callback result type", -1),
    }
}

fn applySqlTextResult(sqlite_context: *sqlite.c.sqlite3_context, data: ?*const anyopaque, len: usize) void {
    const copy = copySqlResultBytes(sqlite_context, data, len, true) orelse return;
    sqlite.c.sqlite3_result_text64(sqlite_context, @ptrCast(copy), @intCast(len), sqlite.c.sqlite3_free, sqlite.c.SQLITE_UTF8);
}

fn applySqlBlobResult(sqlite_context: *sqlite.c.sqlite3_context, data: ?*const anyopaque, len: usize) void {
    const copy = copySqlResultBytes(sqlite_context, data, len, false) orelse return;
    sqlite.c.sqlite3_result_blob64(sqlite_context, copy, @intCast(len), sqlite.c.sqlite3_free);
}

fn applySqlErrorResult(sqlite_context: *sqlite.c.sqlite3_context, message: ?[*]const u8, len: usize) void {
    if (message == null or len == 0) {
        sqlite.c.sqlite3_result_error(sqlite_context, "zova sql callback error", -1);
        return;
    }
    if (len > std.math.maxInt(c_int)) {
        sqlite.c.sqlite3_result_error(sqlite_context, "zova sql callback error too large", -1);
        return;
    }
    sqlite.c.sqlite3_result_error(sqlite_context, @ptrCast(message), @intCast(len));
}

fn copySqlResultBytes(sqlite_context: *sqlite.c.sqlite3_context, data: ?*const anyopaque, len: usize, nul_terminate: bool) ?*anyopaque {
    if (data == null and len != 0) {
        sqlite.c.sqlite3_result_error(sqlite_context, "zova sql callback result has null data", -1);
        return null;
    }
    const extra: usize = if (nul_terminate) 1 else 0;
    const alloc_len = std.math.add(usize, len, extra) catch {
        sqlite.c.sqlite3_result_error_nomem(sqlite_context);
        return null;
    };
    const effective_alloc_len = @max(alloc_len, 1);
    const copy = sqlite.c.sqlite3_malloc64(@intCast(effective_alloc_len)) orelse {
        sqlite.c.sqlite3_result_error_nomem(sqlite_context);
        return null;
    };
    const dest: [*]u8 = @ptrCast(copy);
    if (len != 0) {
        const src: [*]const u8 = @ptrCast(data.?);
        @memcpy(dest[0..len], src[0..len]);
    }
    if (nul_terminate) dest[len] = 0;
    return copy;
}

fn isAsciiIdentStart(byte: u8) bool {
    return byte == '_' or (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}

fn isAsciiIdentContinue(byte: u8) bool {
    return isAsciiIdentStart(byte) or (byte >= '0' and byte <= '9');
}

fn hasAsciiInsensitivePrefix(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return asciiInsensitiveEql(value[0..prefix.len], prefix);
}

fn asciiInsensitiveEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (asciiLower(left) != asciiLower(right)) return false;
    }
    return true;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn manifestChunks(chunks: ?[*]const zova_object_manifest_chunk, len: usize) ?[]const zova_object_manifest_chunk {
    if (len == 0) return &.{};
    const ptr = chunks orelse return null;
    return ptr[0..len];
}

fn floatsConst(data: ?[*]const f32, len: usize) ?[]const f32 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

fn u16Const(data: ?[*]const u16, len: usize) ?[]const u16 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

fn i8Const(data: ?[*]const i8, len: usize) ?[]const i8 {
    if (len == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..len];
}

fn candidateIdSlices(
    candidate_ids: ?[*]const ?[*:0]const u8,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const []const u8) {
    if (len == 0) return &.{};
    const ptr = candidate_ids orelse return error.InvalidArgument;
    const candidates = try allocator.alloc([]const u8, len);
    errdefer allocator.free(candidates);
    for (ptr[0..len], candidates) |candidate, *out| {
        const id = candidate orelse return error.InvalidArgument;
        out.* = std.mem.span(id);
    }
    return candidates;
}

fn graphNodeInputSlices(
    inputs: ?[*]const zova_graph_node_input,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const zova.GraphNodeInput) {
    if (len == 0) return &.{};
    const ptr = inputs orelse return error.InvalidArgument;
    const result = try allocator.alloc(zova.GraphNodeInput, len);
    errdefer allocator.free(result);
    for (ptr[0..len], result) |input, *out| {
        const graph_name = input.graph_name orelse return error.InvalidArgument;
        const node_id = input.node_id orelse return error.InvalidArgument;
        const kind = input.kind orelse return error.InvalidArgument;
        const target_type = graphTargetTypeFromAbi(input.target_type) orelse return error.InvalidArgument;
        out.* = .{
            .graph_name = std.mem.span(graph_name),
            .node_id = std.mem.span(node_id),
            .kind = std.mem.span(kind),
            .target_type = target_type,
            .target_namespace = optionalCStringSpan(input.target_namespace),
            .target_ref = optionalCStringSpan(input.target_ref),
        };
    }
    return result;
}

fn graphEdgeInputSlices(
    inputs: ?[*]const zova_graph_edge_input,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const zova.GraphEdgeInput) {
    if (len == 0) return &.{};
    const ptr = inputs orelse return error.InvalidArgument;
    const result = try allocator.alloc(zova.GraphEdgeInput, len);
    errdefer allocator.free(result);
    for (ptr[0..len], result) |input, *out| {
        const graph_name = input.graph_name orelse return error.InvalidArgument;
        const from_node_id = input.from_node_id orelse return error.InvalidArgument;
        const edge_type = input.edge_type orelse return error.InvalidArgument;
        const to_node_id = input.to_node_id orelse return error.InvalidArgument;
        out.* = .{
            .graph_name = std.mem.span(graph_name),
            .from_node_id = std.mem.span(from_node_id),
            .edge_type = std.mem.span(edge_type),
            .to_node_id = std.mem.span(to_node_id),
        };
    }
    return result;
}

fn multiI8QuerySlices(
    query_values: ?[*]const i8,
    query_values_len: usize,
    query_count: usize,
    dimensions: usize,
) (error{ OutOfMemory, InvalidArgument }![]const []const i8) {
    if (query_count == 0 or dimensions == 0) return error.InvalidArgument;
    const expected_len = std.math.mul(usize, query_count, dimensions) catch return error.InvalidArgument;
    if (query_values_len != expected_len) return error.InvalidArgument;
    const values = (query_values orelse return error.InvalidArgument)[0..query_values_len];
    const queries = try allocator.alloc([]const i8, query_count);
    errdefer allocator.free(queries);
    for (queries, 0..) |*query, index| {
        const start = index * dimensions;
        query.* = values[start .. start + dimensions];
    }
    return queries;
}

fn vectorInputSlices(
    vector_inputs: ?[*]const zova_vector_input,
    len: usize,
) (error{ OutOfMemory, InvalidArgument }![]const zova.VectorInput) {
    if (len == 0) return &.{};
    const ptr = vector_inputs orelse return error.InvalidArgument;
    const inputs = try allocator.alloc(zova.VectorInput, len);
    errdefer allocator.free(inputs);

    for (ptr[0..len], inputs) |input, *out| {
        const id = input.id orelse return error.InvalidArgument;
        const values = vectorValuesConst(input.values) orelse return error.InvalidArgument;
        out.* = .{ .id = std.mem.span(id), .values = values };
    }

    return inputs;
}

fn vectorMetricFromAbi(metric: c_int) ?zova.VectorMetric {
    return switch (metric) {
        @intFromEnum(zova_vector_metric.COSINE) => .cosine,
        @intFromEnum(zova_vector_metric.L2) => .l2,
        @intFromEnum(zova_vector_metric.DOT) => .dot,
        else => null,
    };
}

fn multiI8SearchModeFromAbi(mode: c_int) ?zova.MultiI8CosineSearchMode {
    return switch (mode) {
        @intFromEnum(zova_vector_multi_i8_search_mode.GLOBAL_MIN_COSINE) => .global_min_cosine,
        @intFromEnum(zova_vector_multi_i8_search_mode.CBM_PREFILTER_MIN_COSINE) => .cbm_prefilter_min_cosine,
        else => null,
    };
}

fn multiI8AggregationFromAbi(aggregation: c_int) ?void {
    return switch (aggregation) {
        @intFromEnum(zova_vector_multi_i8_aggregation.MIN_COSINE) => {},
        else => null,
    };
}

fn vectorMetricToAbi(metric: zova.VectorMetric) c_int {
    return switch (metric) {
        .cosine => @intFromEnum(zova_vector_metric.COSINE),
        .l2 => @intFromEnum(zova_vector_metric.L2),
        .dot => @intFromEnum(zova_vector_metric.DOT),
    };
}

fn vectorElementTypeFromAbi(element_type: c_int) ?zova.VectorElementType {
    return switch (element_type) {
        @intFromEnum(zova_vector_element_type.F32) => .f32,
        @intFromEnum(zova_vector_element_type.F16) => .f16,
        @intFromEnum(zova_vector_element_type.I8) => .i8,
        else => null,
    };
}

fn vectorElementTypeToAbi(element_type: zova.VectorElementType) c_int {
    return switch (element_type) {
        .f32 => @intFromEnum(zova_vector_element_type.F32),
        .f16 => @intFromEnum(zova_vector_element_type.F16),
        .i8 => @intFromEnum(zova_vector_element_type.I8),
    };
}

fn vectorValuesConst(values: zova_vector_values) ?zova.VectorValuesConst {
    const element_type = vectorElementTypeFromAbi(values.element_type) orelse return null;
    return switch (element_type) {
        .f32 => .{ .f32 = floatsConst(values.f32_values, values.values_len) orelse return null },
        .f16 => .{ .f16 = u16Const(values.f16_values, values.values_len) orelse return null },
        .i8 => .{ .i8 = i8Const(values.i8_values, values.values_len) orelse return null },
    };
}

fn f32AbiValues(values: []const f32) zova_vector_values {
    return .{
        .element_type = @intFromEnum(zova_vector_element_type.F32),
        .f32_values = if (values.len == 0) null else values.ptr,
        .f16_values = null,
        .i8_values = null,
        .values_len = values.len,
    };
}

fn i8AbiValues(values: []const i8) zova_vector_values {
    return .{
        .element_type = @intFromEnum(zova_vector_element_type.I8),
        .f32_values = null,
        .f16_values = null,
        .i8_values = if (values.len == 0) null else values.ptr,
        .values_len = values.len,
    };
}

fn graphTargetTypeFromAbi(target_type: c_int) ?zova.GraphTargetType {
    return switch (target_type) {
        @intFromEnum(zova_graph_target_type.NONE) => .none,
        @intFromEnum(zova_graph_target_type.RECORD) => .record,
        @intFromEnum(zova_graph_target_type.OBJECT) => .object,
        @intFromEnum(zova_graph_target_type.OBJECT_CHUNK) => .object_chunk,
        @intFromEnum(zova_graph_target_type.VECTOR) => .vector,
        @intFromEnum(zova_graph_target_type.ENTITY) => .entity,
        @intFromEnum(zova_graph_target_type.FACT) => .fact,
        @intFromEnum(zova_graph_target_type.CONCEPT) => .concept,
        @intFromEnum(zova_graph_target_type.EXTERNAL) => .external,
        else => null,
    };
}

fn graphTargetTypeToAbi(target_type: zova.GraphTargetType) c_int {
    return switch (target_type) {
        .none => @intFromEnum(zova_graph_target_type.NONE),
        .record => @intFromEnum(zova_graph_target_type.RECORD),
        .object => @intFromEnum(zova_graph_target_type.OBJECT),
        .object_chunk => @intFromEnum(zova_graph_target_type.OBJECT_CHUNK),
        .vector => @intFromEnum(zova_graph_target_type.VECTOR),
        .entity => @intFromEnum(zova_graph_target_type.ENTITY),
        .fact => @intFromEnum(zova_graph_target_type.FACT),
        .concept => @intFromEnum(zova_graph_target_type.CONCEPT),
        .external => @intFromEnum(zova_graph_target_type.EXTERNAL),
    };
}

fn graphDirectionFromAbi(direction: c_int) ?zova.GraphNeighborDirection {
    return switch (direction) {
        @intFromEnum(zova_graph_neighbor_direction.OUTGOING) => .outgoing,
        @intFromEnum(zova_graph_neighbor_direction.INCOMING) => .incoming,
        else => null,
    };
}

fn optionalCStringSpan(value: ?[*:0]const u8) ?[]const u8 {
    const ptr = value orelse return null;
    return std.mem.span(ptr);
}

fn toObjectId(id: zova_object_id) zova.ObjectId {
    return id.bytes;
}

fn fromObjectId(id: zova.ObjectId) zova_object_id {
    return .{ .bytes = id };
}

fn toChunkId(id: zova_object_chunk_id) zova.ObjectChunkId {
    return id.bytes;
}

fn fromChunkId(id: zova.ObjectChunkId) zova_object_chunk_id {
    return .{ .bytes = id };
}

fn emptyBuffer() zova_buffer {
    return .{ .data = null, .len = 0 };
}

fn emptyText() zova_text {
    return .{ .data = null, .len = 0 };
}

fn emptyNotification() zova_notification {
    return .{
        .channel = null,
        .channel_len = 0,
        .payload = null,
        .payload_len = 0,
        .sequence = 0,
        .dropped_before = 0,
    };
}

fn emptyManifest() zova_object_manifest {
    return .{
        .object_id = .{ .bytes = [_]u8{0} ** 32 },
        .size_bytes = 0,
        .chunk_count = 0,
        .chunker = null,
        .chunks = null,
        .chunks_len = 0,
    };
}

fn emptyVector() zova_vector {
    return .{
        .id = null,
        .id_len = 0,
        .element_type = @intFromEnum(zova_vector_element_type.F32),
        .f32_values = null,
        .f16_values = null,
        .i8_values = null,
        .values_len = 0,
    };
}

fn emptyVectorSearchResults() zova_vector_search_results {
    return .{ .items = null, .len = 0 };
}

fn emptyVectorCollectionInfo() zova_vector_collection_info {
    return .{
        .name = null,
        .name_len = 0,
        .dimensions = 0,
        .metric = 0,
        .element_type = @intFromEnum(zova_vector_element_type.F32),
        .vector_count = 0,
    };
}

fn emptyVectorCollectionList() zova_vector_collection_list {
    return .{ .items = null, .len = 0 };
}

fn emptyGraphInfo() zova_graph_info {
    return .{ .name = null, .name_len = 0, .node_count = 0, .edge_count = 0 };
}

fn emptyGraphList() zova_graph_list {
    return .{ .items = null, .len = 0 };
}

fn emptyExtensionInfo() zova_extension_info {
    return .{
        .name = null,
        .name_len = 0,
        .version = null,
        .version_len = 0,
        .storage_prefix = null,
        .storage_prefix_len = 0,
        .zova_abi_min = null,
        .zova_abi_min_len = 0,
        .capabilities = null,
        .capabilities_len = 0,
        .required = 0,
        .installed_at_unix = 0,
        .manifest_json = null,
        .manifest_json_len = 0,
    };
}

fn emptyExtensionList() zova_extension_list {
    return .{ .items = null, .len = 0 };
}

fn emptyGraphNode() zova_graph_node {
    return .{
        .graph_name = null,
        .graph_name_len = 0,
        .node_id = null,
        .node_id_len = 0,
        .kind = null,
        .kind_len = 0,
        .target_type = @intFromEnum(zova_graph_target_type.NONE),
        .target_namespace = null,
        .target_namespace_len = 0,
        .has_target_namespace = 0,
        .target_ref = null,
        .target_ref_len = 0,
        .has_target_ref = 0,
    };
}

fn emptyGraphEdge() zova_graph_edge {
    return .{
        .graph_name = null,
        .graph_name_len = 0,
        .from_node_id = null,
        .from_node_id_len = 0,
        .edge_type = null,
        .edge_type_len = 0,
        .to_node_id = null,
        .to_node_id_len = 0,
    };
}

fn emptyGraphNeighborResults() zova_graph_neighbor_results {
    return .{ .items = null, .len = 0 };
}

fn emptyGraphWalkResults() zova_graph_walk_results {
    return .{ .items = null, .len = 0 };
}

fn columnTypeToAbi(column_type: sqlite.ColumnType) zova_column_type {
    return switch (column_type) {
        .integer => .INTEGER,
        .float => .FLOAT,
        .text => .TEXT,
        .blob => .BLOB,
        .null => .NULL,
    };
}

fn freeVectorCollectionInfo(info: *zova_vector_collection_info) void {
    if (info.name) |name| allocator.free(name[0 .. info.name_len + 1]);
}

fn freeGraphInfo(info: *zova_graph_info) void {
    if (info.name) |name| allocator.free(name[0 .. info.name_len + 1]);
}

fn freeExtensionInfo(info: *zova_extension_info) void {
    if (info.name) |value| allocator.free(value[0 .. info.name_len + 1]);
    if (info.version) |value| allocator.free(value[0 .. info.version_len + 1]);
    if (info.storage_prefix) |value| allocator.free(value[0 .. info.storage_prefix_len + 1]);
    if (info.zova_abi_min) |value| allocator.free(value[0 .. info.zova_abi_min_len + 1]);
    if (info.capabilities) |value| allocator.free(value[0 .. info.capabilities_len + 1]);
    if (info.manifest_json) |value| allocator.free(value[0 .. info.manifest_json_len + 1]);
}

fn freeGraphNode(node: *zova_graph_node) void {
    if (node.graph_name) |value| allocator.free(value[0 .. node.graph_name_len + 1]);
    if (node.node_id) |value| allocator.free(value[0 .. node.node_id_len + 1]);
    if (node.kind) |value| allocator.free(value[0 .. node.kind_len + 1]);
    if (node.target_namespace) |value| allocator.free(value[0 .. node.target_namespace_len + 1]);
    if (node.target_ref) |value| allocator.free(value[0 .. node.target_ref_len + 1]);
}

fn freeGraphEdge(edge: *zova_graph_edge) void {
    if (edge.graph_name) |value| allocator.free(value[0 .. edge.graph_name_len + 1]);
    if (edge.from_node_id) |value| allocator.free(value[0 .. edge.from_node_id_len + 1]);
    if (edge.edge_type) |value| allocator.free(value[0 .. edge.edge_type_len + 1]);
    if (edge.to_node_id) |value| allocator.free(value[0 .. edge.to_node_id_len + 1]);
}

fn freeGraphNeighborResult(result: *zova_graph_neighbor_result) void {
    if (result.node_id) |value| allocator.free(value[0 .. result.node_id_len + 1]);
    if (result.kind) |value| allocator.free(value[0 .. result.kind_len + 1]);
    if (result.edge_type) |value| allocator.free(value[0 .. result.edge_type_len + 1]);
}

fn freeGraphWalkResult(result: *zova_graph_walk_result) void {
    if (result.node_id) |value| allocator.free(value[0 .. result.node_id_len + 1]);
    if (result.kind) |value| allocator.free(value[0 .. result.kind_len + 1]);
    if (result.predecessor_node_id) |value| allocator.free(value[0 .. result.predecessor_node_id_len + 1]);
    if (result.edge_type) |value| allocator.free(value[0 .. result.edge_type_len + 1]);
}

fn fillSearchResults(out: *zova_vector_search_results, items: []const zova.VectorSearchResult) error{OutOfMemory}!void {
    out.* = emptyVectorSearchResults();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_vector_search_result, items.len);
    errdefer {
        for (abi_items[0..items.len]) |item| {
            if (item.id) |id| allocator.free(id[0 .. item.id_len + 1]);
        }
        allocator.free(abi_items);
    }

    for (abi_items) |*item| item.* = .{ .id = null, .id_len = 0, .distance = 0 };
    for (items, abi_items) |item, *abi_item| {
        const id = try allocator.dupeZ(u8, item.id);
        abi_item.* = .{
            .id = id.ptr,
            .id_len = id.len,
            .distance = item.distance,
        };
    }

    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

fn fillVector(out: *zova_vector, vector: *zova.Vector) error{OutOfMemory}!void {
    out.* = emptyVector();
    const id = try allocator.dupeZ(u8, vector.id);
    errdefer allocator.free(id);

    out.id = id.ptr;
    out.id_len = id.len;
    allocator.free(vector.id);
    vector.id = &.{};

    switch (vector.values) {
        .f32 => |values| {
            out.element_type = vectorElementTypeToAbi(.f32);
            out.f32_values = if (values.len == 0) null else values.ptr;
            out.values_len = values.len;
        },
        .f16 => |values| {
            out.element_type = vectorElementTypeToAbi(.f16);
            out.f16_values = if (values.len == 0) null else values.ptr;
            out.values_len = values.len;
        },
        .i8 => |values| {
            out.element_type = vectorElementTypeToAbi(.i8);
            out.i8_values = if (values.len == 0) null else values.ptr;
            out.values_len = values.len;
        },
    }
}

fn fillGraphInfo(out: *zova_graph_info, info: zova.GraphInfo) error{OutOfMemory}!void {
    out.* = emptyGraphInfo();
    const name = try allocator.dupeZ(u8, info.name);
    out.* = .{
        .name = name.ptr,
        .name_len = name.len,
        .node_count = info.node_count,
        .edge_count = info.edge_count,
    };
}

fn fillGraphList(out: *zova_graph_list, items: []const zova.GraphInfo) error{OutOfMemory}!void {
    out.* = emptyGraphList();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_graph_info, items.len);
    errdefer {
        for (abi_items[0..items.len]) |*item| freeGraphInfo(item);
        allocator.free(abi_items);
    }

    for (abi_items) |*item| item.* = emptyGraphInfo();
    for (items, abi_items) |item, *abi_item| try fillGraphInfo(abi_item, item);
    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

fn fillExtensionInfo(out: *zova_extension_info, info: zova.ExtensionInfo) error{OutOfMemory}!void {
    out.* = emptyExtensionInfo();
    const name = try allocator.dupeZ(u8, info.name);
    errdefer allocator.free(name);
    const version = try allocator.dupeZ(u8, info.version);
    errdefer allocator.free(version);
    const storage_prefix = try allocator.dupeZ(u8, info.storage_prefix);
    errdefer allocator.free(storage_prefix);
    const zova_abi_min = try allocator.dupeZ(u8, info.zova_abi_min);
    errdefer allocator.free(zova_abi_min);
    const capabilities = try allocator.dupeZ(u8, info.capabilities);
    errdefer allocator.free(capabilities);
    const manifest_json = try allocator.dupeZ(u8, info.manifest_json);
    errdefer allocator.free(manifest_json);

    out.* = .{
        .name = name.ptr,
        .name_len = name.len,
        .version = version.ptr,
        .version_len = version.len,
        .storage_prefix = storage_prefix.ptr,
        .storage_prefix_len = storage_prefix.len,
        .zova_abi_min = zova_abi_min.ptr,
        .zova_abi_min_len = zova_abi_min.len,
        .capabilities = capabilities.ptr,
        .capabilities_len = capabilities.len,
        .required = if (info.required) 1 else 0,
        .installed_at_unix = info.installed_at_unix,
        .manifest_json = manifest_json.ptr,
        .manifest_json_len = manifest_json.len,
    };
}

fn fillExtensionList(out: *zova_extension_list, items: []const zova.ExtensionInfo) error{OutOfMemory}!void {
    out.* = emptyExtensionList();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_extension_info, items.len);
    errdefer {
        for (abi_items[0..items.len]) |*item| freeExtensionInfo(item);
        allocator.free(abi_items);
    }

    for (abi_items) |*item| item.* = emptyExtensionInfo();
    for (items, abi_items) |item, *abi_item| try fillExtensionInfo(abi_item, item);
    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

fn fillGraphNode(out: *zova_graph_node, node: zova.GraphNode) error{OutOfMemory}!void {
    out.* = emptyGraphNode();
    const graph_name = try allocator.dupeZ(u8, node.graph_name);
    errdefer allocator.free(graph_name);
    const node_id = try allocator.dupeZ(u8, node.node_id);
    errdefer allocator.free(node_id);
    const kind = try allocator.dupeZ(u8, node.kind);
    errdefer allocator.free(kind);
    const target_namespace = if (node.target_namespace) |value| try allocator.dupeZ(u8, value) else null;
    errdefer if (target_namespace) |value| allocator.free(value);
    const target_ref = if (node.target_ref) |value| try allocator.dupeZ(u8, value) else null;
    errdefer if (target_ref) |value| allocator.free(value);

    out.* = .{
        .graph_name = graph_name.ptr,
        .graph_name_len = graph_name.len,
        .node_id = node_id.ptr,
        .node_id_len = node_id.len,
        .kind = kind.ptr,
        .kind_len = kind.len,
        .target_type = graphTargetTypeToAbi(node.target_type),
        .target_namespace = if (target_namespace) |value| value.ptr else null,
        .target_namespace_len = if (target_namespace) |value| value.len else 0,
        .has_target_namespace = if (target_namespace != null) 1 else 0,
        .target_ref = if (target_ref) |value| value.ptr else null,
        .target_ref_len = if (target_ref) |value| value.len else 0,
        .has_target_ref = if (target_ref != null) 1 else 0,
    };
}

fn fillGraphEdge(out: *zova_graph_edge, edge: zova.GraphEdge) error{OutOfMemory}!void {
    out.* = emptyGraphEdge();
    const graph_name = try allocator.dupeZ(u8, edge.graph_name);
    errdefer allocator.free(graph_name);
    const from_node_id = try allocator.dupeZ(u8, edge.from_node_id);
    errdefer allocator.free(from_node_id);
    const edge_type = try allocator.dupeZ(u8, edge.edge_type);
    errdefer allocator.free(edge_type);
    const to_node_id = try allocator.dupeZ(u8, edge.to_node_id);
    errdefer allocator.free(to_node_id);

    out.* = .{
        .graph_name = graph_name.ptr,
        .graph_name_len = graph_name.len,
        .from_node_id = from_node_id.ptr,
        .from_node_id_len = from_node_id.len,
        .edge_type = edge_type.ptr,
        .edge_type_len = edge_type.len,
        .to_node_id = to_node_id.ptr,
        .to_node_id_len = to_node_id.len,
    };
}

fn fillGraphNeighborResults(out: *zova_graph_neighbor_results, items: []const zova.GraphNeighbor) error{OutOfMemory}!void {
    out.* = emptyGraphNeighborResults();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_graph_neighbor_result, items.len);
    errdefer {
        for (abi_items[0..items.len]) |*item| freeGraphNeighborResult(item);
        allocator.free(abi_items);
    }

    for (abi_items) |*item| item.* = .{ .node_id = null, .node_id_len = 0, .kind = null, .kind_len = 0, .edge_type = null, .edge_type_len = 0 };
    for (items, abi_items) |item, *abi_item| {
        const node_id = try allocator.dupeZ(u8, item.node_id);
        errdefer allocator.free(node_id);
        const kind = try allocator.dupeZ(u8, item.kind);
        errdefer allocator.free(kind);
        const edge_type = try allocator.dupeZ(u8, item.edge_type);
        abi_item.* = .{
            .node_id = node_id.ptr,
            .node_id_len = node_id.len,
            .kind = kind.ptr,
            .kind_len = kind.len,
            .edge_type = edge_type.ptr,
            .edge_type_len = edge_type.len,
        };
    }

    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

fn fillGraphWalkResults(out: *zova_graph_walk_results, items: []const zova.GraphWalkItem) error{OutOfMemory}!void {
    out.* = emptyGraphWalkResults();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_graph_walk_result, items.len);
    errdefer {
        for (abi_items[0..items.len]) |*item| freeGraphWalkResult(item);
        allocator.free(abi_items);
    }

    for (abi_items) |*item| {
        item.* = .{
            .node_id = null,
            .node_id_len = 0,
            .kind = null,
            .kind_len = 0,
            .depth = 0,
            .predecessor_node_id = null,
            .predecessor_node_id_len = 0,
            .has_predecessor_node_id = 0,
            .edge_type = null,
            .edge_type_len = 0,
            .has_edge_type = 0,
        };
    }

    for (items, abi_items) |item, *abi_item| {
        const node_id = try allocator.dupeZ(u8, item.node_id);
        errdefer allocator.free(node_id);
        const kind = try allocator.dupeZ(u8, item.kind);
        errdefer allocator.free(kind);
        const predecessor = if (item.predecessor_node_id) |value| try allocator.dupeZ(u8, value) else null;
        errdefer if (predecessor) |value| allocator.free(value);
        const edge_type = if (item.edge_type) |value| try allocator.dupeZ(u8, value) else null;

        abi_item.* = .{
            .node_id = node_id.ptr,
            .node_id_len = node_id.len,
            .kind = kind.ptr,
            .kind_len = kind.len,
            .depth = item.depth,
            .predecessor_node_id = if (predecessor) |value| value.ptr else null,
            .predecessor_node_id_len = if (predecessor) |value| value.len else 0,
            .has_predecessor_node_id = if (predecessor != null) 1 else 0,
            .edge_type = if (edge_type) |value| value.ptr else null,
            .edge_type_len = if (edge_type) |value| value.len else 0,
            .has_edge_type = if (edge_type != null) 1 else 0,
        };
    }

    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

fn fillVectorCollectionInfo(out: *zova_vector_collection_info, info: zova.VectorCollectionInfo) error{OutOfMemory}!void {
    out.* = emptyVectorCollectionInfo();
    const name = try allocator.dupeZ(u8, info.name);
    out.* = .{
        .name = name.ptr,
        .name_len = name.len,
        .dimensions = info.dimensions,
        .metric = vectorMetricToAbi(info.metric),
        .element_type = vectorElementTypeToAbi(info.element_type),
        .vector_count = info.vector_count,
    };
}

fn fillVectorCollectionList(out: *zova_vector_collection_list, items: []const zova.VectorCollectionInfo) error{OutOfMemory}!void {
    out.* = emptyVectorCollectionList();
    if (items.len == 0) return;

    const abi_items = try allocator.alloc(zova_vector_collection_info, items.len);
    errdefer {
        for (abi_items[0..items.len]) |*item| freeVectorCollectionInfo(item);
        allocator.free(abi_items);
    }

    for (abi_items) |*item| item.* = emptyVectorCollectionInfo();
    for (items, abi_items) |item, *abi_item| {
        try fillVectorCollectionInfo(abi_item, item);
    }

    out.* = .{ .items = abi_items.ptr, .len = abi_items.len };
}

fn fillNotification(out: *zova_notification, notification: zova.Notification) error{OutOfMemory}!void {
    const channel = try allocator.alloc(u8, notification.channel.len + 1);
    errdefer allocator.free(channel);
    @memcpy(channel[0..notification.channel.len], notification.channel);
    channel[notification.channel.len] = 0;

    const payload = try allocator.alloc(u8, notification.payload.len + 1);
    errdefer allocator.free(payload);
    @memcpy(payload[0..notification.payload.len], notification.payload);
    payload[notification.payload.len] = 0;

    out.* = .{
        .channel = channel.ptr,
        .channel_len = notification.channel.len,
        .payload = payload.ptr,
        .payload_len = notification.payload.len,
        .sequence = notification.sequence,
        .dropped_before = notification.dropped_before,
    };
}

fn failDb(handle: *DatabaseHandle, err: anyerror) zova_status {
    const status = statusFromError(err);
    setLastError(handle, err);
    return status;
}

fn failDbSqliteResult(handle: *DatabaseHandle, rc: c_int) zova_status {
    const sqlite_message = handle.db.errorMessage();
    if (!std.mem.eql(u8, sqlite_message, "not an error") and sqlite_message.len > 0) {
        setLastErrorString(handle, sqlite_message);
    } else {
        setLastErrorString(handle, "SQLite error");
    }
    return statusFromSqliteResultCode(rc);
}

fn failDbStatusString(handle: *DatabaseHandle, status: zova_status, message: []const u8) zova_status {
    setLastErrorString(handle, message);
    return status;
}

fn okDb(handle: *DatabaseHandle) zova_status {
    clearLastError(handle);
    return .OK;
}

fn failMessage(message: ?*zova_message, err: anyerror) zova_status {
    setMessage(message, @errorName(err));
    return statusFromError(err);
}

// Prefer SQLite's detailed connection error when it has one; fall back to the
// Zig error name for Zova-native failures or argument validation.
fn setLastError(handle: *DatabaseHandle, err: anyerror) void {
    const sqlite_message = handle.db.errorMessage();
    if (!std.mem.eql(u8, sqlite_message, "not an error") and sqlite_message.len > 0) {
        setLastErrorString(handle, sqlite_message);
    } else {
        setLastErrorString(handle, @errorName(err));
    }
}

fn setLastErrorString(handle: *DatabaseHandle, message: []const u8) void {
    clearLastError(handle);
    handle.last_error = allocator.dupeZ(u8, message) catch null;
}

fn clearLastError(handle: *DatabaseHandle) void {
    if (handle.last_error) |message| {
        allocator.free(message);
    }
    handle.last_error = null;
}

fn setMessage(message: ?*zova_message, text: []const u8) void {
    const out = message orelse return;
    clearMessage(out);
    const copy = allocator.dupeZ(u8, text) catch return;
    out.* = .{ .data = copy.ptr, .len = text.len };
}

fn clearMessage(message: ?*zova_message) void {
    const out = message orelse return;
    zova_message_free(out);
}

// This is the only error translation table for the ABI. New public Zova errors
// should be considered here deliberately instead of leaking as SQLITE_ERROR.
fn statusFromError(err: anyerror) zova_status {
    return switch (err) {
        error.OutOfMemory, error.NoMemory => .OUT_OF_MEMORY,
        error.Busy => .BUSY,
        error.Locked => .LOCKED,
        error.Constraint => .CONSTRAINT,
        error.CantOpen => .CANT_OPEN,
        error.ReadOnly => .READ_ONLY,
        error.Corrupt => .CORRUPT,
        error.Misuse => .MISUSE,
        error.NotZovaPath => .NOT_ZOVA_PATH,
        error.NotZovaDatabase => .NOT_ZOVA_DATABASE,
        error.UnsupportedZovaVersion => .UNSUPPORTED_ZOVA_VERSION,
        error.DestinationExists => .DESTINATION_EXISTS,
        error.ZovaNameConflict => .ZOVA_NAME_CONFLICT,
        error.ObjectNotFound => .OBJECT_NOT_FOUND,
        error.ObjectAlreadyExists => .OBJECT_ALREADY_EXISTS,
        error.ObjectChunkNotFound => .OBJECT_CHUNK_NOT_FOUND,
        error.ObjectChunkHashMismatch => .OBJECT_CHUNK_HASH_MISMATCH,
        error.ObjectCorrupt => .OBJECT_CORRUPT,
        error.ObjectManifestInvalid => .OBJECT_MANIFEST_INVALID,
        error.ObjectRangeInvalid => .OBJECT_RANGE_INVALID,
        error.ObjectTooLarge => .OBJECT_TOO_LARGE,
        error.ObjectTransactionActive => .OBJECT_TRANSACTION_ACTIVE,
        error.ObjectWriterClosed => .OBJECT_WRITER_CLOSED,
        error.BoundStoreExists => .BOUND_STORE_EXISTS,
        error.BoundStoreNotFound => .BOUND_STORE_NOT_FOUND,
        error.BoundStoreInvalid => .BOUND_STORE_INVALID,
        error.VectorCollectionExists => .VECTOR_COLLECTION_EXISTS,
        error.VectorCollectionNotFound => .VECTOR_COLLECTION_NOT_FOUND,
        error.VectorNotFound => .VECTOR_NOT_FOUND,
        error.VectorDimensionMismatch => .VECTOR_DIMENSION_MISMATCH,
        error.VectorCorrupt => .VECTOR_CORRUPT,
        error.VectorInvalid => .VECTOR_INVALID,
        error.GraphExists => .GRAPH_EXISTS,
        error.GraphNotFound => .GRAPH_NOT_FOUND,
        error.GraphNodeNotFound => .GRAPH_NODE_NOT_FOUND,
        error.GraphEdgeNotFound => .GRAPH_EDGE_NOT_FOUND,
        error.GraphInvalid => .GRAPH_INVALID,
        error.ExtensionNotFound => .EXTENSION_NOT_FOUND,
        error.ExtensionExists => .EXTENSION_EXISTS,
        error.ExtensionInvalid => .EXTENSION_INVALID,
        error.ExtensionIncompatible => .EXTENSION_INCOMPATIBLE,
        error.ExtensionUnavailable => .EXTENSION_UNAVAILABLE,
        error.ExtensionUntrusted => .EXTENSION_UNAVAILABLE,
        error.ExtensionLoadFailed => .EXTENSION_UNAVAILABLE,
        error.InvalidArgument => .INVALID_ARGUMENT,
        else => .SQLITE_ERROR,
    };
}

fn statusFromSqliteResultCode(rc: c_int) zova_status {
    return switch (rc) {
        sqlite.c.SQLITE_OK => .OK,
        sqlite.c.SQLITE_BUSY => .BUSY,
        sqlite.c.SQLITE_LOCKED => .LOCKED,
        sqlite.c.SQLITE_CONSTRAINT => .CONSTRAINT,
        sqlite.c.SQLITE_CANTOPEN => .CANT_OPEN,
        sqlite.c.SQLITE_READONLY => .READ_ONLY,
        sqlite.c.SQLITE_CORRUPT => .CORRUPT,
        sqlite.c.SQLITE_MISUSE => .MISUSE,
        sqlite.c.SQLITE_NOMEM => .OUT_OF_MEMORY,
        else => .SQLITE_ERROR,
    };
}

fn statusName(status: c_int) [*:0]const u8 {
    return switch (status) {
        @intFromEnum(zova_status.OK) => "ZOVA_OK",
        @intFromEnum(zova_status.INVALID_ARGUMENT) => "ZOVA_INVALID_ARGUMENT",
        @intFromEnum(zova_status.OUT_OF_MEMORY) => "ZOVA_OUT_OF_MEMORY",
        @intFromEnum(zova_status.BUSY) => "ZOVA_BUSY",
        @intFromEnum(zova_status.LOCKED) => "ZOVA_LOCKED",
        @intFromEnum(zova_status.CONSTRAINT) => "ZOVA_CONSTRAINT",
        @intFromEnum(zova_status.CANT_OPEN) => "ZOVA_CANT_OPEN",
        @intFromEnum(zova_status.READ_ONLY) => "ZOVA_READ_ONLY",
        @intFromEnum(zova_status.CORRUPT) => "ZOVA_CORRUPT",
        @intFromEnum(zova_status.MISUSE) => "ZOVA_MISUSE",
        @intFromEnum(zova_status.SQLITE_ERROR) => "ZOVA_SQLITE_ERROR",
        @intFromEnum(zova_status.NOT_ZOVA_PATH) => "ZOVA_NOT_ZOVA_PATH",
        @intFromEnum(zova_status.NOT_ZOVA_DATABASE) => "ZOVA_NOT_ZOVA_DATABASE",
        @intFromEnum(zova_status.UNSUPPORTED_ZOVA_VERSION) => "ZOVA_UNSUPPORTED_ZOVA_VERSION",
        @intFromEnum(zova_status.DESTINATION_EXISTS) => "ZOVA_DESTINATION_EXISTS",
        @intFromEnum(zova_status.ZOVA_NAME_CONFLICT) => "ZOVA_ZOVA_NAME_CONFLICT",
        @intFromEnum(zova_status.OBJECT_NOT_FOUND) => "ZOVA_OBJECT_NOT_FOUND",
        @intFromEnum(zova_status.OBJECT_ALREADY_EXISTS) => "ZOVA_OBJECT_ALREADY_EXISTS",
        @intFromEnum(zova_status.OBJECT_CHUNK_NOT_FOUND) => "ZOVA_OBJECT_CHUNK_NOT_FOUND",
        @intFromEnum(zova_status.OBJECT_CHUNK_HASH_MISMATCH) => "ZOVA_OBJECT_CHUNK_HASH_MISMATCH",
        @intFromEnum(zova_status.OBJECT_CORRUPT) => "ZOVA_OBJECT_CORRUPT",
        @intFromEnum(zova_status.OBJECT_MANIFEST_INVALID) => "ZOVA_OBJECT_MANIFEST_INVALID",
        @intFromEnum(zova_status.OBJECT_RANGE_INVALID) => "ZOVA_OBJECT_RANGE_INVALID",
        @intFromEnum(zova_status.OBJECT_TOO_LARGE) => "ZOVA_OBJECT_TOO_LARGE",
        @intFromEnum(zova_status.OBJECT_TRANSACTION_ACTIVE) => "ZOVA_OBJECT_TRANSACTION_ACTIVE",
        @intFromEnum(zova_status.OBJECT_WRITER_CLOSED) => "ZOVA_OBJECT_WRITER_CLOSED",
        @intFromEnum(zova_status.BOUND_STORE_EXISTS) => "ZOVA_BOUND_STORE_EXISTS",
        @intFromEnum(zova_status.BOUND_STORE_NOT_FOUND) => "ZOVA_BOUND_STORE_NOT_FOUND",
        @intFromEnum(zova_status.BOUND_STORE_INVALID) => "ZOVA_BOUND_STORE_INVALID",
        @intFromEnum(zova_status.VECTOR_COLLECTION_EXISTS) => "ZOVA_VECTOR_COLLECTION_EXISTS",
        @intFromEnum(zova_status.VECTOR_COLLECTION_NOT_FOUND) => "ZOVA_VECTOR_COLLECTION_NOT_FOUND",
        @intFromEnum(zova_status.VECTOR_NOT_FOUND) => "ZOVA_VECTOR_NOT_FOUND",
        @intFromEnum(zova_status.VECTOR_DIMENSION_MISMATCH) => "ZOVA_VECTOR_DIMENSION_MISMATCH",
        @intFromEnum(zova_status.VECTOR_CORRUPT) => "ZOVA_VECTOR_CORRUPT",
        @intFromEnum(zova_status.VECTOR_INVALID) => "ZOVA_VECTOR_INVALID",
        @intFromEnum(zova_status.GRAPH_EXISTS) => "ZOVA_GRAPH_EXISTS",
        @intFromEnum(zova_status.GRAPH_NOT_FOUND) => "ZOVA_GRAPH_NOT_FOUND",
        @intFromEnum(zova_status.GRAPH_NODE_NOT_FOUND) => "ZOVA_GRAPH_NODE_NOT_FOUND",
        @intFromEnum(zova_status.GRAPH_EDGE_NOT_FOUND) => "ZOVA_GRAPH_EDGE_NOT_FOUND",
        @intFromEnum(zova_status.GRAPH_INVALID) => "ZOVA_GRAPH_INVALID",
        @intFromEnum(zova_status.EXTENSION_NOT_FOUND) => "ZOVA_EXTENSION_NOT_FOUND",
        @intFromEnum(zova_status.EXTENSION_EXISTS) => "ZOVA_EXTENSION_EXISTS",
        @intFromEnum(zova_status.EXTENSION_INVALID) => "ZOVA_EXTENSION_INVALID",
        @intFromEnum(zova_status.EXTENSION_INCOMPATIBLE) => "ZOVA_EXTENSION_INCOMPATIBLE",
        @intFromEnum(zova_status.EXTENSION_UNAVAILABLE) => "ZOVA_EXTENSION_UNAVAILABLE",
        else => "ZOVA_UNKNOWN_STATUS",
    };
}

test "c abi status names and versions are stable" {
    try std.testing.expectEqual(zova_version.abi_version_major, zova_abi_version_major());
    try std.testing.expectEqual(zova_version.abi_version_minor, zova_abi_version_minor());
    try std.testing.expectEqual(zova_version.abi_version_patch, zova_abi_version_patch());
    try std.testing.expectEqualStrings(zova_version.abi_version_string, std.mem.span(zova_abi_version_string()));
    try std.testing.expectEqualStrings("ZOVA_OK", std.mem.span(zova_status_name(@intFromEnum(zova_status.OK))));
    try std.testing.expectEqualStrings("ZOVA_OBJECT_NOT_FOUND", std.mem.span(zova_status_name(@intFromEnum(zova_status.OBJECT_NOT_FOUND))));
    try std.testing.expectEqualStrings("ZOVA_BOUND_STORE_INVALID", std.mem.span(zova_status_name(@intFromEnum(zova_status.BOUND_STORE_INVALID))));
    try std.testing.expectEqualStrings("ZOVA_VECTOR_INVALID", std.mem.span(zova_status_name(@intFromEnum(zova_status.VECTOR_INVALID))));
    try std.testing.expectEqualStrings("ZOVA_GRAPH_INVALID", std.mem.span(zova_status_name(@intFromEnum(zova_status.GRAPH_INVALID))));
    try std.testing.expectEqualStrings("ZOVA_EXTENSION_UNAVAILABLE", std.mem.span(zova_status_name(@intFromEnum(zova_status.EXTENSION_UNAVAILABLE))));
    try std.testing.expectEqualStrings("ZOVA_UNKNOWN_STATUS", std.mem.span(zova_status_name(-1)));
}

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
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_get(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_exists(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_delete(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_node_delete_many(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_put(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_put_many(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_get(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_exists(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_edge_delete(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_neighbors(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_degree(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_walk(null));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_graph_walk_direction(null));
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
}

test "c abi validates external extension bundle requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-external-extension-validation.zova", .{tmp.sub_path[0..]});
    var message = zova_message{ .data = null, .len = 0 };
    defer zova_message_free(&message);

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_extension_bundle_verify(&.{
        .bundle_path = null,
        .trust_store_path = null,
        .out_error_message = &message,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_extension_bundle_trust(&.{
        .bundle_path = null,
        .trust_store_path = null,
        .out_error_message = &message,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_extension_bundle_untrust(&.{
        .identifier = null,
        .trust_store_path = null,
        .out_removed = null,
        .out_error_message = &message,
    }));

    var db: ?*zova_database = null;
    const null_bundles = [_]?[*:0]const u8{null};
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_create_with_extensions(&.{
        .path = db_path,
        .flags = 0,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = null,
        .extension_bundle_count = 1,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_open_with_extensions(&.{
        .path = db_path,
        .flags = 0,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = &null_bundles,
        .extension_bundle_count = 1,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_create_with_extensions(&.{
        .path = db_path,
        .flags = ZOVA_OPEN_READ_ONLY,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = null,
        .extension_bundle_count = 0,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));

    try std.testing.expectEqual(zova_status.OK, zova_database_create_with_extensions(&.{
        .path = db_path,
        .flags = 0,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = null,
        .extension_bundle_count = 0,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));
    try std.testing.expect(db != null);
    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
    db = null;

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_open_with_extensions(&.{
        .path = db_path,
        .flags = 0xffff_ffff,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = null,
        .extension_bundle_count = 0,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_open_with_extensions(&.{
        .path = db_path,
        .flags = 0,
        .busy_timeout_ms = 0,
        .extension_bundle_paths = null,
        .extension_bundle_count = 0,
        .trust_store_path = null,
        .out_db = &db,
        .out_error_message = &message,
    }));
    try std.testing.expect(db != null);
    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
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

test "c abi exposes sql record helper functions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-record-helpers.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "create table records (id integer primary key, name text not null)" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "insert into records (name) values ('one')" }));

    var rowid: i64 = 0;
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_last_insert_rowid(&.{ .db = db, .out_rowid = null }));
    try std.testing.expectEqual(zova_status.OK, zova_database_last_insert_rowid(&.{ .db = db, .out_rowid = &rowid }));
    try std.testing.expectEqual(@as(i64, 1), rowid);

    var changes: i64 = 0;
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_changes(&.{ .db = db, .out_changes = null }));
    try std.testing.expectEqual(zova_status.OK, zova_database_changes(&.{ .db = db, .out_changes = &changes }));
    try std.testing.expectEqual(@as(i64, 1), changes);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "update records set name = 'two' where id = 1" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_changes(&.{ .db = db, .out_changes = &changes }));
    try std.testing.expectEqual(@as(i64, 1), changes);

    var total_changes: i64 = 0;
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_total_changes(&.{ .db = db, .out_total_changes = null }));
    try std.testing.expectEqual(zova_status.OK, zova_database_total_changes(&.{ .db = db, .out_total_changes = &total_changes }));
    try std.testing.expect(total_changes >= 2);

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select id as record_id, name from records",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);

    var name = zova_text{ .data = null, .len = 0 };
    defer zova_text_free(&name);
    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_statement_column_name(&.{ .statement = stmt, .index = 0, .out_name = null }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_name(&.{ .statement = stmt, .index = 0, .out_name = &name }));
    try std.testing.expectEqualStrings("record_id", name.data.?[0..name.len]);
    zova_text_free(&name);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_name(&.{ .statement = stmt, .index = 1, .out_name = &name }));
    try std.testing.expectEqualStrings("name", name.data.?[0..name.len]);
    try std.testing.expectEqual(zova_status.MISUSE, zova_statement_column_name(&.{ .statement = stmt, .index = 2, .out_name = &name }));
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

test "c abi batches graph mutations and reads degree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-graph-batches.zova", .{tmp.sub_path[0..]});
    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{ .path = db_path, .out_db = &db, .out_error_message = null }));
    defer _ = zova_database_close(db);
    try std.testing.expectEqual(zova_status.OK, zova_graph_create(&.{ .db = db, .name = "app" }));

    const nodes = [_]zova_graph_node_input{
        .{ .graph_name = "app", .node_id = "a", .kind = "function", .target_type = @intFromEnum(zova_graph_target_type.NONE), .target_namespace = null, .target_ref = null },
        .{ .graph_name = "app", .node_id = "b", .kind = "function", .target_type = @intFromEnum(zova_graph_target_type.NONE), .target_namespace = null, .target_ref = null },
    };
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_put_many(&.{ .db = db, .nodes = &nodes, .nodes_len = nodes.len }));

    const edges = [_]zova_graph_edge_input{
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
        .{ .graph_name = "app", .from_node_id = "a", .edge_type = "calls", .to_node_id = "b" },
    };
    try std.testing.expectEqual(zova_status.OK, zova_graph_edge_put_many(&.{ .db = db, .edges = &edges, .edges_len = edges.len }));

    var degree: u64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_graph_degree(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "a",
        .direction = @intFromEnum(zova_graph_neighbor_direction.OUTGOING),
        .edge_type = "calls",
        .out_degree = &degree,
    }));
    try std.testing.expectEqual(@as(u64, 1), degree);

    const delete_ids = [_]?[*:0]const u8{ "b", "missing" };
    try std.testing.expectEqual(zova_status.OK, zova_graph_node_delete_many(&.{ .db = db, .graph_name = "app", .node_ids = &delete_ids, .node_count = delete_ids.len }));
    try std.testing.expectEqual(zova_status.OK, zova_graph_degree(&.{
        .db = db,
        .graph_name = "app",
        .node_id = "a",
        .direction = @intFromEnum(zova_graph_neighbor_direction.OUTGOING),
        .edge_type = null,
        .out_degree = &degree,
    }));
    try std.testing.expectEqual(@as(u64, 0), degree);
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

test "c abi no-handle create error can return owned message" {
    var message = zova_message{ .data = null, .len = 0 };
    var db: ?*zova_database = null;
    const request = zova_database_open_request{
        .path = "not-zova.db",
        .out_db = &db,
        .out_error_message = &message,
    };
    try std.testing.expectEqual(zova_status.NOT_ZOVA_PATH, zova_database_create(&request));
    try std.testing.expect(db == null);
    try std.testing.expect(message.data != null);
    try std.testing.expect(message.len > 0);
    zova_message_free(&message);
}

test "c abi exposes prepared statement sql lifecycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-statements.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));
    defer _ = zova_database_close(db);

    var bad_stmt: ?*zova_statement = null;
    const bad_prepare = zova_database_prepare_request{
        .db = db,
        .sql = "select from definitely invalid sql",
        .out_statement = &bad_stmt,
    };
    try std.testing.expectEqual(zova_status.SQLITE_ERROR, zova_database_prepare(&bad_prepare));
    try std.testing.expect(bad_stmt == null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zova_database_last_error_message(db)), "syntax") != null);

    var create_stmt: ?*zova_statement = null;
    const prepare_create = zova_database_prepare_request{
        .db = db,
        .sql = "create table records (id integer primary key, i integer, r real, t text, b blob, n text)",
        .out_statement = &create_stmt,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&prepare_create));
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{
        .statement = create_stmt,
        .out_result = &step_result,
    }));
    try std.testing.expectEqual(zova_step_result.DONE, step_result);
    try std.testing.expectEqual(zova_status.OK, zova_statement_finalize(create_stmt));

    var insert_stmt: ?*zova_statement = null;
    const prepare_insert = zova_database_prepare_request{
        .db = db,
        .sql = "insert into records (i, r, t, b, n) values (:i, :r, :t, :b, :n)",
        .out_statement = &insert_stmt,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&prepare_insert));
    defer _ = zova_statement_finalize(insert_stmt);

    var param_count: i32 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_parameter_count(&.{
        .statement = insert_stmt,
        .out_count = &param_count,
    }));
    try std.testing.expectEqual(@as(i32, 5), param_count);

    var text_index: i32 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_parameter_index(&.{
        .statement = insert_stmt,
        .name = ":t",
        .out_index = &text_index,
    }));
    try std.testing.expectEqual(@as(i32, 3), text_index);

    const text = "hello";
    const blob = [_]u8{ 0, 1, 2, 3 };
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_int64(&.{ .statement = insert_stmt, .index = 1, .value = 42 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_double(&.{ .statement = insert_stmt, .index = 2, .value = 3.5 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_text(&.{ .statement = insert_stmt, .index = 3, .data = text.ptr, .len = text.len }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_blob(&.{ .statement = insert_stmt, .index = 4, .data = &blob, .len = blob.len }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_null(&.{ .statement = insert_stmt, .index = 5 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = insert_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.DONE, step_result);

    try std.testing.expectEqual(zova_status.OK, zova_statement_reset(insert_stmt));
    try std.testing.expectEqual(zova_status.OK, zova_statement_clear_bindings(insert_stmt));
    const empty = "";
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_int64(&.{ .statement = insert_stmt, .index = 1, .value = 7 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_double(&.{ .statement = insert_stmt, .index = 2, .value = 0.25 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_text(&.{ .statement = insert_stmt, .index = 3, .data = empty.ptr, .len = 0 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_blob(&.{ .statement = insert_stmt, .index = 4, .data = empty.ptr, .len = 0 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_bind_null(&.{ .statement = insert_stmt, .index = 5 }));
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = insert_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.DONE, step_result);

    var select_stmt: ?*zova_statement = null;
    const prepare_select = zova_database_prepare_request{
        .db = db,
        .sql = "select i, r, t, b, n from records order by id",
        .out_statement = &select_stmt,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&prepare_select));
    defer _ = zova_statement_finalize(select_stmt);

    var column_count: i32 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_count(&.{ .statement = select_stmt, .out_count = &column_count }));
    try std.testing.expectEqual(@as(i32, 5), column_count);

    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = select_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);

    var column_type: zova_column_type = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_type(&.{ .statement = select_stmt, .index = 0, .out_type = &column_type }));
    try std.testing.expectEqual(zova_column_type.INTEGER, column_type);

    var int_value: i64 = 0;
    var double_value: f64 = 0;
    var text_value = zova_text{ .data = null, .len = 0 };
    var blob_value = zova_buffer{ .data = null, .len = 0 };
    defer zova_text_free(&text_value);
    defer zova_buffer_free(&blob_value);

    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = select_stmt, .index = 0, .out_value = &int_value }));
    try std.testing.expectEqual(@as(i64, 42), int_value);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_double(&.{ .statement = select_stmt, .index = 1, .out_value = &double_value }));
    try std.testing.expectEqual(@as(f64, 3.5), double_value);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_text(&.{ .statement = select_stmt, .index = 2, .out_text = &text_value }));
    try std.testing.expectEqualStrings("hello", text_value.data.?[0..text_value.len]);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_blob(&.{ .statement = select_stmt, .index = 3, .out_buffer = &blob_value }));
    try std.testing.expectEqualSlices(u8, &blob, blob_value.data.?[0..blob_value.len]);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_type(&.{ .statement = select_stmt, .index = 4, .out_type = &column_type }));
    try std.testing.expectEqual(zova_column_type.NULL, column_type);

    zova_text_free(&text_value);
    zova_buffer_free(&blob_value);
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = select_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_text(&.{ .statement = select_stmt, .index = 2, .out_text = &text_value }));
    try std.testing.expect(text_value.data != null);
    try std.testing.expectEqual(@as(usize, 0), text_value.len);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_blob(&.{ .statement = select_stmt, .index = 3, .out_buffer = &blob_value }));
    try std.testing.expectEqual(@as(usize, 0), blob_value.len);
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

test "c abi exposes savepoint helpers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-savepoint.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "create table notes (body text not null)" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = db }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "insert into notes (body) values ('outer')" }));

    try std.testing.expectEqual(zova_status.OK, zova_database_savepoint(&.{ .db = db, .name = "sp_one" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "insert into notes (body) values ('rolled back')" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_rollback_to_savepoint(&.{ .db = db, .name = "sp_one" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_release_savepoint(&.{ .db = db, .name = "sp_one" }));

    try std.testing.expectEqual(zova_status.OK, zova_database_savepoint(&.{ .db = db, .name = "sp_two" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "insert into notes (body) values ('released')" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_release_savepoint(&.{ .db = db, .name = "sp_two" }));
    try std.testing.expectEqual(zova_status.OK, zova_database_commit(&.{ .db = db }));

    try std.testing.expectEqual(zova_status.INVALID_ARGUMENT, zova_database_savepoint(&.{ .db = db, .name = "bad name" }));
    try std.testing.expectEqual(zova_status.SQLITE_ERROR, zova_database_release_savepoint(&.{ .db = db, .name = "missing_sp" }));
    const message = std.mem.span(zova_database_last_error_message(db));
    try std.testing.expect(std.mem.indexOf(u8, message, "no such savepoint") != null);

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select count(*) from notes where body = 'rolled back'",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = stmt, .out_result = &step_result }));
    var count: i64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = stmt, .index = 0, .out_value = &count }));
    try std.testing.expectEqual(@as(i64, 0), count);
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

test "c abi rejects database close while statement or writer children are live" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-live-children.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    var create_request = zova_database_open_request{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    };
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&create_request));

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select 1",
        .out_statement = &stmt,
    }));

    try std.testing.expectEqual(zova_status.MISUSE, zova_database_close(db));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zova_database_last_error_message(db)), "live child") != null);

    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{
        .statement = stmt,
        .out_result = &step_result,
    }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    try std.testing.expectEqual(zova_status.OK, zova_statement_finalize(stmt));

    var writer: ?*zova_object_writer = null;
    try std.testing.expectEqual(zova_status.OK, zova_object_writer_create(&.{
        .db = db,
        .out_writer = &writer,
    }));

    try std.testing.expectEqual(zova_status.MISUSE, zova_database_close(db));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zova_database_last_error_message(db)), "live child") != null);

    try std.testing.expectEqual(zova_status.OK, zova_object_writer_destroy(writer));
    try std.testing.expectEqual(zova_status.OK, zova_database_close(db));
}

test "c abi serializes concurrent sql calls on one database handle" {
    const Worker = struct {
        const inserts_per_worker = 24;

        db: ?*zova_database,
        worker_index: usize,
        status: zova_status = .OK,

        fn run(ctx: *@This()) void {
            var sql_buffer: [160]u8 = undefined;
            for (0..inserts_per_worker) |insert_index| {
                const sql = std.fmt.bufPrintZ(
                    &sql_buffer,
                    "insert into records (worker, item) values ({d}, {d})",
                    .{ ctx.worker_index, insert_index },
                ) catch {
                    ctx.status = .OUT_OF_MEMORY;
                    return;
                };
                const status = zova_database_exec(&.{ .db = ctx.db, .sql = sql.ptr });
                if (status != .OK) {
                    ctx.status = status;
                    return;
                }
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-threaded-sql.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = db, .sql = "create table records (worker integer not null, item integer not null)" }));

    var contexts: [8]Worker = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    for (&contexts, 0..) |*context, index| {
        context.* = .{ .db = db, .worker_index = index };
    }
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{context});
    }
    for (threads) |thread| thread.join();
    for (contexts) |context| try std.testing.expectEqual(zova_status.OK, context.status);

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select count(*) from records",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);

    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);

    var count: i64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_int64(&.{ .statement = stmt, .index = 0, .out_value = &count }));
    try std.testing.expectEqual(@as(i64, contexts.len * Worker.inserts_per_worker), count);
}

test "c abi serializes concurrent statement metadata calls on one statement" {
    const Worker = struct {
        const calls_per_worker = 32;

        statement: ?*zova_statement,
        status: zova_status = .OK,

        fn run(ctx: *@This()) void {
            for (0..calls_per_worker) |_| {
                var column_count: i32 = 0;
                var column_name = zova_text{ .data = null, .len = 0 };
                defer zova_text_free(&column_name);

                ctx.status = zova_statement_column_count(&.{
                    .statement = ctx.statement,
                    .out_count = &column_count,
                });
                if (ctx.status != .OK) return;
                if (column_count != 2) {
                    ctx.status = .MISUSE;
                    return;
                }

                ctx.status = zova_statement_column_name(&.{
                    .statement = ctx.statement,
                    .index = 0,
                    .out_name = &column_name,
                });
                if (ctx.status != .OK) return;
                if (!std.mem.eql(u8, column_name.data.?[0..column_name.len], "one")) {
                    ctx.status = .MISUSE;
                    return;
                }
                zova_text_free(&column_name);
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-threaded-statement.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    var stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select 1 as one, 2 as two",
        .out_statement = &stmt,
    }));
    defer _ = zova_statement_finalize(stmt);

    var contexts: [8]Worker = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    for (&contexts) |*context| {
        context.* = .{ .statement = stmt };
    }
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{context});
    }
    for (threads) |thread| thread.join();
    for (contexts) |context| try std.testing.expectEqual(zova_status.OK, context.status);
}

test "c abi serializes concurrent object writer writes on one writer" {
    const Worker = struct {
        const payload = "x";
        const writes_per_worker = 64;

        writer: ?*zova_object_writer,
        status: zova_status = .OK,

        fn run(ctx: *@This()) void {
            for (0..writes_per_worker) |_| {
                ctx.status = zova_object_writer_write(&.{
                    .writer = ctx.writer,
                    .data = payload.ptr,
                    .len = payload.len,
                });
                if (ctx.status != .OK) return;
            }
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-threaded-writer.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    var writer: ?*zova_object_writer = null;
    try std.testing.expectEqual(zova_status.OK, zova_object_writer_create(&.{
        .db = db,
        .out_writer = &writer,
    }));
    defer _ = zova_object_writer_destroy(writer);

    var contexts: [8]Worker = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    for (&contexts) |*context| {
        context.* = .{ .writer = writer };
    }
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{context});
    }
    for (threads) |thread| thread.join();
    for (contexts) |context| try std.testing.expectEqual(zova_status.OK, context.status);

    var object_id = zova_object_id{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expectEqual(zova_status.OK, zova_object_writer_finish(&.{
        .writer = writer,
        .out_id = &object_id,
    }));

    var size: u64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_object_size(&.{
        .db = db,
        .id = object_id,
        .out_size = &size,
    }));
    try std.testing.expectEqual(@as(u64, contexts.len * Worker.writes_per_worker * Worker.payload.len), size);
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

test "c abi multi-handle write contention returns busy or locked with short timeout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-multi-handle-busy.zova", .{tmp.sub_path[0..]});

    var first: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &first,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(first);
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{ .db = first, .sql = "create table records (body text not null)" }));

    var second: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_open_with_options(&.{
        .path = db_path,
        .flags = 0,
        .busy_timeout_ms = 1,
        .out_db = &second,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(second);

    try std.testing.expectEqual(zova_status.OK, zova_database_begin_immediate(&.{ .db = first }));
    defer _ = zova_database_rollback(&.{ .db = first });

    const status = zova_database_begin_immediate(&.{ .db = second });
    try std.testing.expect(status == .BUSY or status == .LOCKED);
}

test "c abi last error remains useful after concurrent serialized failures" {
    const Worker = struct {
        db: ?*zova_database,
        status: zova_status = .OK,

        fn run(ctx: *@This()) void {
            ctx.status = zova_database_exec(&.{ .db = ctx.db, .sql = "select * from no_such_table" });
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-threaded-errors.zova", .{tmp.sub_path[0..]});

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_create(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    var contexts: [6]Worker = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    for (&contexts) |*context| {
        context.* = .{ .db = db };
    }
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{context});
    }
    for (threads) |thread| thread.join();
    for (contexts) |context| try std.testing.expectEqual(zova_status.SQLITE_ERROR, context.status);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(zova_database_last_error_message(db)), "no_such_table") != null);
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

test "c abi can query bundled trgm SQL surface through prepared statements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buffer, ".zig-cache/tmp/{s}/c-api-trgm.zova", .{tmp.sub_path[0..]});

    {
        var native = try zova.Database.create(db_path);
        defer native.deinit();
        try native.installExtension("trgm");
    }

    var db: ?*zova_database = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_open(&.{
        .path = db_path,
        .out_db = &db,
        .out_error_message = null,
    }));
    defer _ = zova_database_close(db);

    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "select zova_trgm_create_index('docs')",
    }));
    try std.testing.expectEqual(zova_status.OK, zova_database_exec(&.{
        .db = db,
        .sql = "select zova_trgm_put('docs', 'doc:1', 'record', 'messages', '1', 'attachment upload failed')",
    }));

    var similarity_stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql = "select zova_trgm_similarity('attachment', 'attachement')",
        .out_statement = &similarity_stmt,
    }));
    defer _ = zova_statement_finalize(similarity_stmt);
    var step_result: zova_step_result = undefined;
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = similarity_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    var score: f64 = 0;
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_double(&.{ .statement = similarity_stmt, .index = 0, .out_value = &score }));
    try std.testing.expect(score > 0.5);

    var search_stmt: ?*zova_statement = null;
    try std.testing.expectEqual(zova_status.OK, zova_database_prepare(&.{
        .db = db,
        .sql =
        \\select document_id, score
        \\from zova_trgm_search
        \\where index_name = 'docs'
        \\  and query = 'attachement failed'
        \\  and "limit" = 1
        \\order by rank
        ,
        .out_statement = &search_stmt,
    }));
    defer _ = zova_statement_finalize(search_stmt);
    try std.testing.expectEqual(zova_status.OK, zova_statement_step(&.{ .statement = search_stmt, .out_result = &step_result }));
    try std.testing.expectEqual(zova_step_result.ROW, step_result);
    var document_id = zova_text{ .data = null, .len = 0 };
    defer zova_text_free(&document_id);
    try std.testing.expectEqual(zova_status.OK, zova_statement_column_text(&.{ .statement = search_stmt, .index = 0, .out_text = &document_id }));
    try std.testing.expectEqualStrings("doc:1", document_id.data.?[0..document_id.len]);
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
    try std.testing.expectEqualStrings("0.21.0", info.zova_abi_min.?[0..info.zova_abi_min_len]);
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
