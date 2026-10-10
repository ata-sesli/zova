//! Source-local transactional history. No vector payloads are duplicated here.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const api = @import("extension_plugin_api.zig");
const data = @import("extension_data.zig");
const vector = @import("vector.zig");
pub const Error = data.Error || error{ HistoryUnavailable, SourceChanged };

/// Retire rows in blocks; the pruning range is empty between retirement points.
pub const retained_changes = 4096;
pub const retirement_block = 256;
pub const sources_sql =
    \\create table _zova_vector_sources (
    \\  collection_key integer primary key references _zova_vector_collections(collection_key) on delete cascade,
    \\  incarnation blob not null unique default (_zova_vector_nonce()) check (length(incarnation)=16),
    \\  revision integer not null default 0 check (revision>=0),
    \\  token blob not null default (zeroblob(16)) check (length(token)=16),
    \\  floor integer not null default 0 check (floor>=0 and floor<=revision),
    \\  floor_token blob not null default (zeroblob(16)) check (length(floor_token)=16)
    \\)
;
pub const changes_sql =
    \\create table _zova_vector_changes (
    \\  collection_key integer not null references _zova_vector_sources(collection_key) on delete cascade,
    \\  revision integer not null check (revision>0),
    \\  token blob not null check (length(token)=16),
    \\  vector_id text not null check (length(vector_id)>0),
    \\  primary key (collection_key,revision)
    \\) without rowid
;
const source_insert_sql =
    \\create trigger _zova_vector_source_insert after insert on _zova_vector_collections begin
    \\  insert into _zova_vector_sources(collection_key) values(new.collection_key);
    \\  update _zova_vector_sources set token=incarnation,floor_token=incarnation where collection_key=new.collection_key;
    \\end
;

fn changeBody(comptime row: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\select case when exists(select 1 from _zova_vector_collections where collection_key={0s}.collection_key)
        \\and not exists(select 1 from _zova_vector_sources where collection_key={0s}.collection_key)
        \\then raise(abort,'vector source tracking missing') end;
        \\select case when exists(select 1 from _zova_vector_sources where collection_key={0s}.collection_key and revision=9223372036854775807)
        \\then raise(abort,'vector source revision exhausted') end;
        \\update _zova_vector_sources set revision=revision+1,token=_zova_vector_nonce() where collection_key={0s}.collection_key;
        \\insert into _zova_vector_changes(collection_key,revision,token,vector_id)
        \\select collection_key,revision,token,{0s}.vector_id from _zova_vector_sources where collection_key={0s}.collection_key;
        \\update _zova_vector_sources set floor=revision-4096,
        \\floor_token=(select token from _zova_vector_changes where collection_key={0s}.collection_key and revision=_zova_vector_sources.revision-4096)
        \\where collection_key={0s}.collection_key and revision>4096 and revision%256=0;
        \\delete from _zova_vector_changes where collection_key={0s}.collection_key and revision<=(select floor from _zova_vector_sources where collection_key={0s}.collection_key);
    , .{row});
}
pub const triggers = .{
    .{ .name = "_zova_vector_source_insert", .sql = source_insert_sql },
    .{ .name = "_zova_vector_change_insert", .sql = "create trigger _zova_vector_change_insert after insert on _zova_vectors begin\n" ++ changeBody("new") ++ "\nend" },
    .{ .name = "_zova_vector_change_update", .sql = "create trigger _zova_vector_change_update after update on _zova_vectors begin\n" ++ changeBody("new") ++ "\nend" },
    .{ .name = "_zova_vector_change_move", .sql = "create trigger _zova_vector_change_move after update on _zova_vectors when old.collection_key<>new.collection_key or old.vector_id<>new.vector_id begin\n" ++ changeBody("old") ++ "\nend" },
    .{ .name = "_zova_vector_change_delete", .sql = "create trigger _zova_vector_change_delete after delete on _zova_vectors begin\n" ++ changeBody("old") ++ "\nend" },
};

/// Called only during create or the explicit adjacent migration, never on open.
pub fn initialize(db: *sqlite.Database) sqlite.Error!void {
    try register(db);
    try db.exec(sources_sql);
    try db.exec(changes_sql);
    // Existing collections get new tracking identities; public identities,
    // private row keys, values and ordering are untouched by this migration.
    try db.exec("insert into _zova_vector_sources(collection_key) select collection_key from _zova_vector_collections");
    try db.exec("update _zova_vector_sources set token=incarnation,floor_token=incarnation");
    inline for (triggers) |trigger| try db.exec(trigger.sql);
}

/// Core-private function; the application C ABI already reserves _zova_ names.
/// Do not depend on an application-shadowable SQL randomblob() implementation.
pub fn register(db: *sqlite.Database) sqlite.Error!void {
    const rc = sqlite.c.sqlite3_create_function_v2(db.handle, "_zova_vector_nonce", 0, sqlite.c.SQLITE_UTF8 | sqlite.c.SQLITE_INNOCUOUS, null, nonce, null, null, null);
    if (rc != sqlite.c.SQLITE_OK) return if (rc == sqlite.c.SQLITE_NOMEM) error.NoMemory else error.SqliteError;
}

fn nonce(context: ?*sqlite.c.sqlite3_context, _: c_int, _: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    const bytes = sqlite.c.sqlite3_malloc64(16) orelse {
        sqlite.c.sqlite3_result_error_nomem(context);
        return;
    };
    sqlite.c.sqlite3_randomness(16, bytes);
    sqlite.c.sqlite3_result_blob64(context, bytes, 16, sqlite.c.sqlite3_free);
}

fn prepare(db: *sqlite.Database, buffer: []u8, comptime sql: []const u8, args: anytype) Error!sqlite.Statement {
    return db.prepare(std.fmt.bufPrintSentinel(buffer, sql, args, 0) catch return error.InvalidArgument);
}

const State = struct {
    view: api.VectorView,
    key: i64,
    floor: i64,
    floor_token: [16]u8,
    dimensions: u32,
    element: vector.VectorElementType,
    metric: vector.VectorMetric,
};
fn load(db: *sqlite.Database, prefix: []const u8, name: []const u8) Error!State {
    vector.validateVectorCollectionName(name) catch return error.InvalidArgument;
    var buffer: [1024]u8 = undefined;
    var stmt = try prepare(db, &buffer, "select c.collection_key,s.incarnation,s.token,s.revision,s.floor,s.floor_token,c.dimensions,c.element_type,c.metric from {s}_zova_vector_collections c left join {s}_zova_vector_sources s on s.collection_key=c.collection_key where c.name=?1", .{ prefix, prefix });
    defer stmt.deinit();
    try stmt.bindTextBorrowed(1, name);
    if (try stmt.step() != .row) return error.SourceNotFound;
    const incarnation = stmt.columnBlob(1);
    try stmt.checkColumnError();
    const head_token = stmt.columnBlob(2);
    try stmt.checkColumnError();
    const floor_token = stmt.columnBlob(5);
    try stmt.checkColumnError();
    if (incarnation.len != 16 or head_token.len != 16 or floor_token.len != 16) return error.Corrupt;
    var state: State = .{
        .view = .{ .revision = stmt.columnInt64(3) },
        .key = stmt.columnInt64(0),
        .floor = stmt.columnInt64(4),
        .floor_token = undefined,
        .dimensions = std.math.cast(u32, stmt.columnInt64(6)) orelse return error.Corrupt,
        .element = std.meta.stringToEnum(vector.VectorElementType, stmt.columnText(7)) orelse return error.Corrupt,
        .metric = std.meta.stringToEnum(vector.VectorMetric, stmt.columnText(8)) orelse return error.Corrupt,
    };
    if (state.key <= 0 or state.view.revision < 0 or state.floor < 0 or state.floor > state.view.revision or state.dimensions == 0 or state.dimensions > vector.max_vector_dimensions) return error.Corrupt;
    if (state.view.revision - state.floor > retained_changes + retirement_block - 1) return error.Corrupt;
    @memcpy(&state.view.incarnation, incarnation);
    @memcpy(&state.view.token, head_token);
    @memcpy(&state.floor_token, floor_token);
    if (state.view.revision == 0) {
        if (!std.mem.eql(u8, &state.view.token, &state.view.incarnation) or !std.mem.eql(u8, &state.floor_token, &state.view.incarnation)) return error.Corrupt;
    } else {
        var head = try prepare(db, &buffer, "select token from {s}_zova_vector_changes where collection_key=?1 and revision=?2", .{prefix});
        defer head.deinit();
        try head.bindInt64(1, state.key);
        try head.bindInt64(2, state.view.revision);
        if (try head.step() != .row) return error.Corrupt;
        const token = head.columnBlob(0);
        try head.checkColumnError();
        if (!std.mem.eql(u8, token, &state.view.token)) return error.Corrupt;
    }
    return state;
}

pub fn view(db: *sqlite.Database, prefix: []const u8, name: []const u8) Error!api.VectorView {
    return (try load(db, prefix, name)).view;
}

/// One snapshot for ancestry, history, and authoritative current values. The
/// caller discards partial delivery on any error; no cache is mutated by host.
pub fn read(db: *sqlite.Database, prefix: []const u8, r: *const api.VectorChangesRequest) Error!api.VectorChangesPage {
    if (r.struct_size < @sizeOf(api.VectorChangesRequest) or r.reserved != 0 or r.row == null or r.since.revision < 0 or r.after_revision < 0) return error.InvalidArgument;
    if (r.row_limit == 0 or r.row_limit > data.max_rows or r.byte_limit == 0 or r.byte_limit > data.max_bytes) return error.InvalidArgument;
    const name = try data.bytes(r.name);
    try db.savepoint("zova_vector_history_read");
    var released = false;
    defer if (!released) {
        db.rollbackToSavepoint("zova_vector_history_read") catch {};
        db.releaseSavepoint("zova_vector_history_read") catch {};
    };
    const state = try load(db, prefix, name);
    if (!std.mem.eql(u8, &state.view.incarnation, &r.since.incarnation) or r.since.revision > state.view.revision) return error.SourceChanged;
    if (r.since.revision < state.floor) return error.HistoryUnavailable;
    const after = if (r.after_revision == 0) r.since.revision else r.after_revision;
    if (after < r.since.revision or after > state.view.revision) return error.InvalidArgument;
    var buffer: [1024]u8 = undefined;
    {
        const expected = if (r.since.revision == state.floor) state.floor_token else blk: {
            var ancestry = try prepare(db, &buffer, "select token from {s}_zova_vector_changes where collection_key=?1 and revision=?2", .{prefix});
            defer ancestry.deinit();
            try ancestry.bindInt64(1, state.key);
            try ancestry.bindInt64(2, r.since.revision);
            if (try ancestry.step() != .row) return error.Corrupt;
            const bytes = ancestry.columnBlob(0);
            try ancestry.checkColumnError();
            if (bytes.len != 16) return error.Corrupt;
            var token: [16]u8 = undefined;
            @memcpy(&token, bytes);
            break :blk token;
        };
        if (!std.mem.eql(u8, &expected, &r.since.token)) return error.SourceChanged;
    }
    var page: api.VectorChangesPage = .{ .view = state.view, .next_revision = after };
    {
        var stmt = try prepare(db, &buffer, "select j.revision,j.vector_id,v.vector_id is not null,v.\"values\" from {s}_zova_vector_changes j left join {s}_zova_vectors v on v.collection_key=j.collection_key and v.vector_id=j.vector_id where j.collection_key=?1 and j.revision>?2 order by j.revision limit ?3", .{ prefix, prefix });
        defer stmt.deinit();
        try stmt.bindInt64(1, state.key);
        try stmt.bindInt64(2, after);
        try stmt.bindInt64(3, @intCast(r.row_limit + 1));
        var used: u64 = 0;
        while (try stmt.step() == .row) {
            if (stmt.columnInt64(0) != page.next_revision + 1) return error.Corrupt;
            if (page.rows == r.row_limit) {
                page.has_more = 1;
                break;
            }
            var values: [4]api.Value = undefined;
            const size = try data.readRow(&stmt, &values);
            if (size > r.byte_limit - used) return error.PluginLimit;
            if (values[2].integer != 0) {
                const bytes = stmt.columnBlob(3);
                vector.validateEncodedValues(state.element, state.metric, state.dimensions, bytes) catch return error.Corrupt;
            }
            try data.callback(r.row.?, r.user_data, &values);
            page.rows += 1;
            page.next_revision = stmt.columnInt64(0);
            used += size;
        }
        if (page.has_more == 0 and page.next_revision != state.view.revision) return error.Corrupt;
    }
    try db.releaseSavepoint("zova_vector_history_read");
    released = true;
    return page;
}
