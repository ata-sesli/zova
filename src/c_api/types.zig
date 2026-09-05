//! C ABI opaque handles, numeric constants, and extern request/result layouts.

pub const zova_database = opaque {};

pub const zova_object_writer = opaque {};

pub const zova_object_reader = opaque {};

pub const zova_statement = opaque {};

pub const zova_subscription = opaque {};

pub const zova_fresh_build = opaque {};

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
    MIGRATION_REQUIRED = 35,
    UNSUPPORTED_FUTURE_FORMAT = 36,
    UNSUPPORTED_LEGACY_FORMAT = 37,
    NO_MIGRATION_PATH = 38,
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
    OBJECT_READER_CLOSED = 63,
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
    KV_TOO_LARGE = 95,
    KV_CORRUPT = 96,
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

/// Additive object storage profile values. The underlying field is a raw C
/// integer in request structs so invalid foreign values can be rejected
/// without triggering Zig enum safety traps.
pub const zova_object_storage_profile = enum(c_int) {
    DEDUPLICATION = 0,
    STREAMING = 1,
};

pub const zova_object_put_options = extern struct {
    profile: c_int = @intFromEnum(zova_object_storage_profile.DEDUPLICATION),
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

pub const zova_graph_keyed_neighbor_result = extern struct {
    edge_key: i64,
    neighbor_node_key: i64,
    node_id: ?[*]u8,
    node_id_len: usize,
    kind: ?[*]u8,
    kind_len: usize,
    edge_type: ?[*]u8,
    edge_type_len: usize,
};

pub const zova_graph_keyed_neighbor_results = extern struct {
    items: ?[*]zova_graph_keyed_neighbor_result,
    len: usize,
};

pub const zova_graph_keyed_node_result = extern struct {
    found: u8,
    node_key: i64,
    node_id: ?[*]u8,
    node_id_len: usize,
    kind: ?[*]u8,
    kind_len: usize,
    created_order: i64,
};

pub const zova_graph_keyed_node_results = extern struct { items: ?[*]zova_graph_keyed_node_result, len: usize };

pub const zova_graph_keyed_edge_result = extern struct {
    found: u8,
    edge_key: i64,
    source_node_key: i64,
    edge_type: ?[*]u8,
    edge_type_len: usize,
    target_node_key: i64,
    created_order: i64,
};

pub const zova_graph_keyed_edge_results = extern struct { items: ?[*]zova_graph_keyed_edge_result, len: usize };

pub const zova_graph_edge_payload_result = extern struct {
    found: u8,
    edge_key: i64,
    payload: ?[*]u8,
    payload_len: usize,
};

pub const zova_graph_edge_payload_results = extern struct { items: ?[*]zova_graph_edge_payload_result, len: usize };

pub const zova_fresh_build_profile = extern struct {
    validation_ms: f64 = 0,
    table_load_ms: f64 = 0,
    fts_load_ms: f64 = 0,
    graph_load_ms: f64 = 0,
    graph_validation_ms: f64 = 0,
    graph_key_generation_ms: f64 = 0,
    graph_node_load_ms: f64 = 0,
    graph_edge_load_ms: f64 = 0,
    vector_load_ms: f64 = 0,
    index_build_ms: f64 = 0,
    commit_ms: f64 = 0,
    table_rows: u64 = 0,
    fts_rows: u64 = 0,
    vector_rows: u64 = 0,
    payload_bytes: u64 = 0,
};

pub const zova_fresh_value = extern struct {
    value_type: c_int,
    int64_value: i64,
    float64_value: f64,
    bytes: ?[*]const u8,
    bytes_len: usize,
};

pub const zova_graph_scan_cursor = extern struct {
    created_order: i64,
    key: i64,
};

pub const zova_graph_scan_node = extern struct {
    node_key: i64,
    node_id: ?[*]u8,
    node_id_len: usize,
    kind: ?[*]u8,
    kind_len: usize,
    created_order: i64,
};

pub const zova_graph_scan_edge = extern struct {
    edge_key: i64,
    source_node_key: i64,
    edge_type: ?[*]u8,
    edge_type_len: usize,
    target_node_key: i64,
    created_order: i64,
};

pub const zova_graph_scan_results = extern struct {
    nodes: ?[*]zova_graph_scan_node,
    nodes_len: usize,
    edges: ?[*]zova_graph_scan_edge,
    edges_len: usize,
    has_more_nodes: u8,
    has_more_edges: u8,
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

pub const ZOVA_MIGRATE_NO_VERIFY: u32 = 1 << 0;

pub const zova_format_compatibility = enum(c_int) {
    CURRENT = 0,
    MIGRATABLE = 1,
    UNSUPPORTED_LEGACY = 2,
    UNSUPPORTED_FUTURE = 3,
};

pub const zova_database_format_info = extern struct {
    format_version: u32 = 0,
    compatibility: c_int = 0,
};

pub const zova_database_probe_format_request = extern struct {
    path: ?[*:0]const u8 = null,
    out_info: ?*zova_database_format_info = null,
    out_error_message: ?*zova_message = null,
};

pub const zova_database_migrate_request = extern struct {
    source_path: ?[*:0]const u8 = null,
    destination_path: ?[*:0]const u8 = null,
    flags: u32 = 0,
    out_error_message: ?*zova_message = null,
};

pub const zova_database_open_request = extern struct {
    path: ?[*:0]const u8,
    out_db: ?*?*zova_database,
    out_error_message: ?*zova_message,
};

pub const zova_database_create_memory_request = extern struct {
    out_db: ?*?*zova_database,
    out_error_message: ?*zova_message,
};

pub const zova_database_restore_to_memory_request = extern struct {
    source_path: ?[*:0]const u8,
    flags: u32,
    out_db: ?*?*zova_database,
    out_error_message: ?*zova_message,
};

pub const zova_database_create_options_request = extern struct {
    path: ?[*:0]const u8,
    page_size: u32,
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

pub const zova_object_put_with_options_request = extern struct {
    db: ?*zova_database,
    data: ?[*]const u8,
    len: usize,
    options: zova_object_put_options,
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

pub const zova_object_chunk_put_with_options_request = extern struct {
    db: ?*zova_database,
    expected_hash: zova_object_chunk_id,
    data: ?[*]const u8,
    len: usize,
    options: zova_object_put_options,
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

pub const zova_object_assemble_from_chunks_with_options_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    size_bytes: u64,
    chunks: ?[*]const zova_object_manifest_chunk,
    chunk_count: usize,
    options: zova_object_put_options,
};

pub const zova_object_writer_create_request = extern struct {
    db: ?*zova_database,
    out_writer: ?*?*zova_object_writer,
};

pub const zova_object_writer_create_with_options_request = extern struct {
    db: ?*zova_database,
    options: zova_object_put_options,
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

pub const zova_object_reader_create_request = extern struct {
    db: ?*zova_database,
    id: zova_object_id,
    out_reader: ?*?*zova_object_reader,
};

pub const zova_object_reader_read_request = extern struct {
    reader: ?*zova_object_reader,
    buffer: ?[*]u8,
    buffer_len: usize,
    out_read: ?*usize,
};

pub const zova_object_reader_destroy_request = extern struct {
    reader: ?*?*zova_object_reader,
};

/// Borrowed byte slice for key-value operations. Zova copies caller input
/// during the call and retains no caller memory.
pub const zova_kv_bytes = extern struct {
    data: ?[*]const u8,
    len: usize,
};

/// Owned key-value get result. Free with `zova_kv_get_result_free`.
pub const zova_kv_get_result = extern struct {
    found: u8,
    value: zova_buffer,
};

/// Owned many-get results. Free with `zova_kv_get_many_results_free`.
pub const zova_kv_get_many_results = extern struct {
    items: ?[*]zova_kv_get_result,
    len: usize,
};

/// Borrowed batch put entry.
pub const zova_kv_put_entry = extern struct {
    key: zova_kv_bytes,
    value: zova_kv_bytes,
};

pub const zova_kv_get_request = extern struct {
    db: ?*zova_database,
    ns: zova_kv_bytes,
    key: zova_kv_bytes,
    out_result: ?*zova_kv_get_result,
};

pub const zova_kv_get_many_request = extern struct {
    db: ?*zova_database,
    ns: zova_kv_bytes,
    keys: ?[*]const zova_kv_bytes,
    keys_len: usize,
    out_results: ?*zova_kv_get_many_results,
};

pub const zova_kv_put_request = extern struct {
    db: ?*zova_database,
    ns: zova_kv_bytes,
    key: zova_kv_bytes,
    value: zova_kv_bytes,
};

pub const zova_kv_put_many_request = extern struct {
    db: ?*zova_database,
    ns: zova_kv_bytes,
    entries: ?[*]const zova_kv_put_entry,
    entries_len: usize,
};

pub const zova_kv_delete_request = extern struct {
    db: ?*zova_database,
    ns: zova_kv_bytes,
    key: zova_kv_bytes,
};

pub const zova_kv_delete_many_request = extern struct {
    db: ?*zova_database,
    ns: zova_kv_bytes,
    keys: ?[*]const zova_kv_bytes,
    keys_len: usize,
};

pub const zova_kv_count_request = extern struct {
    db: ?*zova_database,
    ns: zova_kv_bytes,
    out_count: ?*u64,
};

pub const zova_kv_clear_namespace_request = extern struct {
    db: ?*zova_database,
    ns: zova_kv_bytes,
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

pub const zova_vector_delete_many_request = extern struct {
    db: ?*zova_database,
    collection_name: ?[*:0]const u8,
    vector_ids: ?[*]const ?[*:0]const u8,
    vector_count: usize,
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

pub const zova_graph_node_put_many_keyed_request = extern struct {
    db: ?*zova_database,
    nodes: ?[*]const zova_graph_node_input,
    nodes_len: usize,
    out_node_keys: ?[*]i64,
    out_node_keys_capacity: usize,
};

pub const zova_graph_fresh_node_input = extern struct {
    node_id: ?[*:0]const u8,
    kind: ?[*:0]const u8,
    target_type: c_int,
    target_namespace: ?[*:0]const u8,
    target_ref: ?[*:0]const u8,
};

pub const zova_graph_fresh_edge_input = extern struct {
    from_node_ordinal: usize,
    edge_type: ?[*:0]const u8,
    to_node_ordinal: usize,
};

pub const zova_graph_fresh_edge_payload_input = extern struct {
    from_node_ordinal: usize,
    edge_type: ?[*:0]const u8,
    to_node_ordinal: usize,
    payload: ?[*]const u8,
    payload_len: usize,
};

pub const zova_graph_build_fresh_keyed_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    nodes: ?[*]const zova_graph_fresh_node_input,
    nodes_len: usize,
    edges: ?[*]const zova_graph_fresh_edge_input,
    edges_len: usize,
    out_node_keys: ?[*]i64,
    out_node_keys_capacity: usize,
    out_edge_keys: ?[*]i64,
    out_edge_keys_capacity: usize,
};

pub const zova_graph_build_fresh_prepared_keyed_with_payloads_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    nodes: ?[*]const zova_graph_fresh_node_input,
    nodes_len: usize,
    edges: ?[*]const zova_graph_fresh_edge_payload_input,
    edges_len: usize,
    out_node_keys: ?[*]i64,
    out_node_keys_capacity: usize,
    out_edge_keys: ?[*]i64,
    out_edge_keys_capacity: usize,
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

pub const zova_graph_edge_put_many_keyed_request = extern struct {
    db: ?*zova_database,
    edges: ?[*]const zova_graph_edge_input,
    edges_len: usize,
    out_edge_keys: ?[*]i64,
    out_edge_keys_capacity: usize,
};

pub const zova_graph_edge_delete_many_request = extern struct {
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

pub const zova_graph_neighbors_keyed_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_id: ?[*:0]const u8,
    direction: c_int,
    edge_type: ?[*:0]const u8,
    limit: usize,
    out_results: ?*zova_graph_keyed_neighbor_results,
};

pub const zova_graph_nodes_get_many_keyed_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_keys: ?[*]const i64,
    key_count: usize,
    out_results: ?*zova_graph_keyed_node_results,
};

pub const zova_graph_edges_get_many_keyed_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    edge_keys: ?[*]const i64,
    key_count: usize,
    out_results: ?*zova_graph_keyed_edge_results,
};

pub const zova_graph_edge_payload_get_many_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    edge_keys: ?[*]const i64,
    key_count: usize,
    out_results: ?*zova_graph_edge_payload_results,
};

pub const zova_graph_edge_payload_replacement = extern struct {
    edge_key: i64,
    payload: ?[*]const u8,
    payload_len: usize,
};

pub const zova_graph_edge_payload_replace_many_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    replacements: ?[*]const zova_graph_edge_payload_replacement,
    replacement_count: usize,
};

pub const zova_fresh_build_begin_request = extern struct {
    db: ?*zova_database,
    out_build: ?*?*zova_fresh_build,
};

pub const zova_fresh_build_rows_request = extern struct {
    build: ?*zova_fresh_build,
    table_name: ?[*:0]const u8,
    column_names: ?[*]const ?[*:0]const u8,
    column_count: usize,
    values: ?[*]const zova_fresh_value,
    row_count: usize,
};

pub const zova_fresh_build_graph_request = extern struct {
    build: ?*zova_fresh_build,
    graph_name: ?[*:0]const u8,
    nodes: ?[*]const zova_graph_fresh_node_input,
    nodes_len: usize,
    edges: ?[*]const zova_graph_fresh_edge_payload_input,
    edges_len: usize,
    out_node_keys: ?[*]i64,
    out_node_keys_capacity: usize,
    out_edge_keys: ?[*]i64,
    out_edge_keys_capacity: usize,
};

pub const zova_fresh_build_vectors_request = extern struct {
    build: ?*zova_fresh_build,
    collection_name: ?[*:0]const u8,
    vectors: ?[*]const zova_vector_input,
    vectors_len: usize,
};

pub const zova_fresh_build_finish_request = extern struct {
    build: ?*zova_fresh_build,
    out_node_keys: ?[*]i64,
    out_node_keys_capacity: usize,
    out_edge_keys: ?[*]i64,
    out_edge_keys_capacity: usize,
    out_profile: ?*zova_fresh_build_profile,
};

pub const zova_graph_degree_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_id: ?[*:0]const u8,
    direction: c_int,
    edge_type: ?[*:0]const u8,
    out_degree: ?*u64,
};

pub const zova_graph_degree_many_keyed_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_keys: ?[*]const i64,
    node_count: usize,
    direction: c_int,
    edge_type: ?[*:0]const u8,
    out_degrees: ?[*]u64,
    out_degrees_capacity: usize,
};

pub const zova_graph_scan_request = extern struct {
    db: ?*zova_database,
    graph_name: ?[*:0]const u8,
    node_after: zova_graph_scan_cursor,
    edge_after: zova_graph_scan_cursor,
    node_limit: usize,
    edge_limit: usize,
    out_results: ?*zova_graph_scan_results,
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
