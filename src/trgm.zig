//! Bundled `trgm` extension.
//!
//! This is Zova's first official extension. It is process-provided and uses
//! the extension host lifecycle, while exposing its runtime surface as ordinary
//! SQLite functions and a read-only eponymous virtual table.

const std = @import("std");
const extension_impl = @import("extension.zig");
const graph = @import("graph.zig");
const sqlite = @import("sqlite.zig");

const c = sqlite.c;
const allocator = std.heap.c_allocator;

pub const name = "trgm";
pub const version = "0.1.0";
pub const storage_prefix = "_zova_ext_trgm_";

const max_index_name_bytes: usize = 128;
const max_document_id_bytes: usize = 512;
const max_target_text_bytes: usize = 512;
const default_search_limit: usize = 10;

const indexes_table = storage_prefix ++ "indexes";
const documents_table = storage_prefix ++ "documents";
const terms_table = storage_prefix ++ "terms";
const postings_table = storage_prefix ++ "postings";
const meta_table = storage_prefix ++ "meta";

const Error = sqlite.Error || error{
    ExtensionInvalid,
    TrgmInvalid,
    TrgmIndexNotFound,
    TrgmDocumentNotFound,
    OutOfMemory,
};

const TargetType = enum {
    record,
    object,
    object_chunk,
    vector,
    graph,
    entity,
    fact,
    concept,
    external,
};

const TermCount = struct {
    term: [3]u8,
    count: u32,
};

const SearchRow = struct {
    document_id: []u8,
    target_type: []u8,
    target_namespace: ?[]u8,
    target_ref: ?[]u8,
    score: f64,

    fn deinit(self: *SearchRow) void {
        allocator.free(self.document_id);
        allocator.free(self.target_type);
        if (self.target_namespace) |value| allocator.free(value);
        if (self.target_ref) |value| allocator.free(value);
    }
};

const SearchTable = extern struct {
    base: c.sqlite3_vtab,
    db: ?*c.sqlite3,
};

const SearchCursor = extern struct {
    base: c.sqlite3_vtab_cursor,
    db: ?*c.sqlite3,
    rows: ?[*]SearchRow = null,
    rows_len: usize = 0,
    index: usize = 0,
};

const SearchConstraintBits = packed struct(u8) {
    index_name: bool = false,
    query: bool = false,
    limit: bool = false,
    threshold: bool = false,
    _: u4 = 0,
};

const SearchColumn = enum(c_int) {
    rank = 0,
    document_id = 1,
    target_type = 2,
    target_namespace = 3,
    target_ref = 4,
    score = 5,
    index_name = 6,
    query = 7,
    limit = 8,
    threshold = 9,
};

pub fn extension() extension_impl.Extension {
    return .{
        .manifest = .{
            .name = name,
            .version = version,
            .storage_prefix = storage_prefix,
            .zova_abi_min = "0.21.0",
            .capabilities = "sql,trgm",
            .manifest_json = "{\"extension\":\"trgm\",\"version\":\"0.1.0\"}",
        },
        .install = install,
        .check = check,
        .drop = drop,
        .register_sql = registerSql,
        .salvage = salvage,
    };
}

fn install(db: *sqlite.Database, manifest: extension_impl.Manifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec(
        \\create table _zova_ext_trgm_meta (
        \\  key text primary key,
        \\  value text not null
        \\)
    );
    try db.exec(
        \\create table _zova_ext_trgm_indexes (
        \\  name text primary key,
        \\  created_order integer not null unique
        \\)
    );
    try db.exec(
        \\create table _zova_ext_trgm_documents (
        \\  index_name text not null,
        \\  document_id text not null,
        \\  target_type text not null check (target_type in ('record', 'object', 'object_chunk', 'vector', 'graph', 'entity', 'fact', 'concept', 'external')),
        \\  target_namespace text,
        \\  target_ref text,
        \\  normalized_len integer not null check (normalized_len >= 0),
        \\  text_hash blob not null check (length(text_hash) = 32),
        \\  term_count integer not null check (term_count >= 0),
        \\  updated_at_unix integer not null,
        \\  primary key (index_name, document_id)
        \\)
    );
    try db.exec(
        \\create table _zova_ext_trgm_terms (
        \\  index_name text not null,
        \\  term blob not null check (length(term) = 3),
        \\  document_count integer not null check (document_count > 0),
        \\  primary key (index_name, term)
        \\)
    );
    try db.exec(
        \\create table _zova_ext_trgm_postings (
        \\  index_name text not null,
        \\  term blob not null check (length(term) = 3),
        \\  document_id text not null,
        \\  count integer not null check (count > 0),
        \\  primary key (index_name, term, document_id)
        \\)
    );

    var stmt = try db.prepare("insert into _zova_ext_trgm_meta (key, value) values ('schema_version', '1'), ('extension_version', ?)");
    defer stmt.deinit();
    try stmt.bindText(1, manifest.version);
    std.debug.assert((try stmt.step()) == .done);
}

fn check(db: *sqlite.Database, manifest: extension_impl.Manifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    checkInternal(db, manifest) catch return error.ExtensionInvalid;
}

fn drop(db: *sqlite.Database, manifest: extension_impl.Manifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table if exists _zova_ext_trgm_postings");
    try db.exec("drop table if exists _zova_ext_trgm_terms");
    try db.exec("drop table if exists _zova_ext_trgm_documents");
    try db.exec("drop table if exists _zova_ext_trgm_indexes");
    try db.exec("drop table if exists _zova_ext_trgm_meta");
}

fn salvage(context: extension_impl.SalvageContext, manifest: extension_impl.Manifest) extension_impl.Error!extension_impl.SalvageResult {
    try extension_impl.validateManifest(manifest);
    // TODO(v0.21.1): rebuild or copy valid trigram index rows through a real
    // trgm-owned salvage strategy. v0.21 intentionally skips derived indexes.
    const private_objects = try extension_impl.countPrivateStorageObjects(context.source, manifest.storage_prefix);
    return .{
        .skipped_extensions = 1,
        .skipped_private_objects = private_objects,
    };
}

fn registerSql(db: *sqlite.Database, manifest: extension_impl.Manifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try register(db);
}

pub fn register(db: *sqlite.Database) sqlite.Error!void {
    const scalar_flags = c.SQLITE_UTF8;
    const readonly_flags = c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC | c.SQLITE_INNOCUOUS;

    var rc = c.sqlite3_create_function_v2(db.handle, "zova_trgm_similarity", 2, readonly_flags, null, similarityFunc, null, null, null);
    if (rc != c.SQLITE_OK) return mapResultCode(rc);

    rc = c.sqlite3_create_function_v2(db.handle, "zova_trgm_create_index", 1, scalar_flags, null, createIndexFunc, null, null, null);
    if (rc != c.SQLITE_OK) return mapResultCode(rc);

    rc = c.sqlite3_create_function_v2(db.handle, "zova_trgm_drop_index", 1, scalar_flags, null, dropIndexFunc, null, null, null);
    if (rc != c.SQLITE_OK) return mapResultCode(rc);

    rc = c.sqlite3_create_function_v2(db.handle, "zova_trgm_put", 6, scalar_flags, null, putFunc, null, null, null);
    if (rc != c.SQLITE_OK) return mapResultCode(rc);

    rc = c.sqlite3_create_function_v2(db.handle, "zova_trgm_delete", 2, scalar_flags, null, deleteFunc, null, null, null);
    if (rc != c.SQLITE_OK) return mapResultCode(rc);

    rc = c.sqlite3_create_module_v2(db.handle, "zova_trgm_search", &search_module, db.handle, null);
    if (rc != c.SQLITE_OK) return mapResultCode(rc);
}

fn checkInternal(db: *sqlite.Database, manifest: extension_impl.Manifest) Error!void {
    if (!try tableExists(db, meta_table)) return error.ExtensionInvalid;
    if (!try tableExists(db, indexes_table)) return error.ExtensionInvalid;
    if (!try tableExists(db, documents_table)) return error.ExtensionInvalid;
    if (!try tableExists(db, terms_table)) return error.ExtensionInvalid;
    if (!try tableExists(db, postings_table)) return error.ExtensionInvalid;

    var meta = try db.prepare("select value from _zova_ext_trgm_meta where key = 'extension_version'");
    defer meta.deinit();
    switch (try meta.step()) {
        .row => if (!std.mem.eql(u8, meta.columnText(0), manifest.version)) return error.ExtensionInvalid,
        .done => return error.ExtensionInvalid,
    }

    var documents = try db.prepare(
        \\select index_name, document_id, target_type, target_namespace, target_ref, term_count
        \\from _zova_ext_trgm_documents
        \\order by index_name, document_id
    );
    defer documents.deinit();
    while (try documents.step() == .row) {
        const index_name = documents.columnText(0);
        const document_id = documents.columnText(1);
        try validateIndexName(index_name);
        try validateDocumentId(document_id);
        if (!try indexExists(db, index_name)) return error.ExtensionInvalid;
        const target_type = try parseTargetType(documents.columnText(2));
        const target_namespace = if (documents.columnType(3) == .null) null else documents.columnText(3);
        const target_ref = if (documents.columnType(4) == .null) null else documents.columnText(4);
        try validateTarget(db, target_type, target_namespace, target_ref);
        if (documents.columnInt64(5) < 0) return error.ExtensionInvalid;

        var postings_count = try db.prepare(
            \\select count(*)
            \\from _zova_ext_trgm_postings
            \\where index_name = ? and document_id = ?
        );
        defer postings_count.deinit();
        try postings_count.bindText(1, index_name);
        try postings_count.bindText(2, document_id);
        std.debug.assert((try postings_count.step()) == .row);
        if (postings_count.columnInt64(0) != documents.columnInt64(5)) return error.ExtensionInvalid;
    }

    try expectNoRows(db,
        \\select 1
        \\from _zova_ext_trgm_postings p
        \\left join _zova_ext_trgm_documents d
        \\  on d.index_name = p.index_name and d.document_id = p.document_id
        \\where d.document_id is null
        \\limit 1
    );
    try expectNoRows(db,
        \\select 1
        \\from _zova_ext_trgm_postings p
        \\left join _zova_ext_trgm_terms t
        \\  on t.index_name = p.index_name and t.term = p.term
        \\where t.term is null
        \\limit 1
    );
    try expectNoRows(db,
        \\select 1
        \\from _zova_ext_trgm_terms t
        \\left join _zova_ext_trgm_indexes i on i.name = t.index_name
        \\where i.name is null
        \\limit 1
    );
    try expectNoRows(db,
        \\select 1
        \\from _zova_ext_trgm_terms t
        \\where t.document_count != (
        \\  select count(distinct p.document_id)
        \\  from _zova_ext_trgm_postings p
        \\  where p.index_name = t.index_name and p.term = t.term
        \\)
        \\limit 1
    );
}

fn similarityFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const context = ctx orelse return;
    if (argc != 2) {
        resultError(context, "zova_trgm_similarity expects 2 arguments");
        return;
    }
    const score = computeSimilarityValues(argv[0] orelse {
        resultError(context, "missing first text");
        return;
    }, argv[1] orelse {
        resultError(context, "missing second text");
        return;
    }) catch |err| {
        resultError(context, errorMessage(err));
        return;
    };
    c.sqlite3_result_double(context, score);
}

fn createIndexFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const context = ctx orelse return;
    if (argc != 1) {
        resultError(context, "zova_trgm_create_index expects 1 argument");
        return;
    }
    const index_name = valueText(argv[0] orelse {
        resultError(context, "missing index_name");
        return;
    }) catch |err| {
        resultError(context, errorMessage(err));
        return;
    };
    var db = sqlite.Database{ .handle = c.sqlite3_context_db_handle(context) orelse {
        resultError(context, "missing SQLite handle");
        return;
    } };
    createIndex(&db, index_name) catch |err| {
        resultError(context, errorMessage(err));
        return;
    };
    c.sqlite3_result_int64(context, 1);
}

fn dropIndexFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const context = ctx orelse return;
    if (argc != 1) {
        resultError(context, "zova_trgm_drop_index expects 1 argument");
        return;
    }
    const index_name = valueText(argv[0] orelse {
        resultError(context, "missing index_name");
        return;
    }) catch |err| {
        resultError(context, errorMessage(err));
        return;
    };
    var db = sqlite.Database{ .handle = c.sqlite3_context_db_handle(context) orelse {
        resultError(context, "missing SQLite handle");
        return;
    } };
    dropIndex(&db, index_name) catch |err| {
        resultError(context, errorMessage(err));
        return;
    };
    c.sqlite3_result_int64(context, 1);
}

fn putFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const context = ctx orelse return;
    if (argc != 6) {
        resultError(context, "zova_trgm_put expects 6 arguments");
        return;
    }
    const input = PutInput{
        .index_name = valueText(argv[0] orelse return resultError(context, "missing index_name")) catch |err| return resultError(context, errorMessage(err)),
        .document_id = valueText(argv[1] orelse return resultError(context, "missing document_id")) catch |err| return resultError(context, errorMessage(err)),
        .target_type = valueText(argv[2] orelse return resultError(context, "missing target_type")) catch |err| return resultError(context, errorMessage(err)),
        .target_namespace = valueNullableText(argv[3] orelse return resultError(context, "missing target_namespace")) catch |err| return resultError(context, errorMessage(err)),
        .target_ref = valueNullableText(argv[4] orelse return resultError(context, "missing target_ref")) catch |err| return resultError(context, errorMessage(err)),
        .text = valueText(argv[5] orelse return resultError(context, "missing text")) catch |err| return resultError(context, errorMessage(err)),
    };
    var db = sqlite.Database{ .handle = c.sqlite3_context_db_handle(context) orelse return resultError(context, "missing SQLite handle") };
    putDocument(&db, input) catch |err| return resultError(context, errorMessage(err));
    c.sqlite3_result_int64(context, 1);
}

fn deleteFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const context = ctx orelse return;
    if (argc != 2) {
        resultError(context, "zova_trgm_delete expects 2 arguments");
        return;
    }
    const index_name = valueText(argv[0] orelse return resultError(context, "missing index_name")) catch |err| return resultError(context, errorMessage(err));
    const document_id = valueText(argv[1] orelse return resultError(context, "missing document_id")) catch |err| return resultError(context, errorMessage(err));
    var db = sqlite.Database{ .handle = c.sqlite3_context_db_handle(context) orelse return resultError(context, "missing SQLite handle") };
    deleteDocument(&db, index_name, document_id) catch |err| return resultError(context, errorMessage(err));
    c.sqlite3_result_int64(context, 1);
}

const PutInput = struct {
    index_name: []const u8,
    document_id: []const u8,
    target_type: []const u8,
    target_namespace: ?[]const u8,
    target_ref: ?[]const u8,
    text: []const u8,
};

fn createIndex(db: *sqlite.Database, index_name: []const u8) Error!void {
    try ensureWritable(db);
    try validateIndexName(index_name);

    var stmt = try db.prepare(
        \\insert into _zova_ext_trgm_indexes (name, created_order)
        \\values (?, coalesce((select max(created_order) + 1 from _zova_ext_trgm_indexes), 1))
    );
    defer stmt.deinit();
    try stmt.bindText(1, index_name);
    _ = stmt.step() catch |err| switch (err) {
        error.Constraint => return error.TrgmInvalid,
        else => return err,
    };
}

fn dropIndex(db: *sqlite.Database, index_name: []const u8) Error!void {
    try ensureWritable(db);
    try validateIndexName(index_name);
    if (!try indexExists(db, index_name)) return error.TrgmIndexNotFound;

    try deleteByIndex(db, "delete from _zova_ext_trgm_postings where index_name = ?", index_name);
    try deleteByIndex(db, "delete from _zova_ext_trgm_terms where index_name = ?", index_name);
    try deleteByIndex(db, "delete from _zova_ext_trgm_documents where index_name = ?", index_name);
    try deleteByIndex(db, "delete from _zova_ext_trgm_indexes where name = ?", index_name);
}

fn putDocument(db: *sqlite.Database, input: PutInput) Error!void {
    try ensureWritable(db);
    try validateIndexName(input.index_name);
    try validateDocumentId(input.document_id);
    if (!try indexExists(db, input.index_name)) return error.TrgmIndexNotFound;
    const target_type = try parseTargetType(input.target_type);
    try validateTarget(db, target_type, input.target_namespace, input.target_ref);
    if (!std.unicode.utf8ValidateSlice(input.text)) return error.TrgmInvalid;

    var normalized = try normalize(allocator, input.text);
    defer normalized.deinit(allocator);
    const terms = try extractTermCounts(allocator, normalized.items);
    defer allocator.free(terms);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input.text, &hash, .{});

    try deleteDocumentRows(db, input.index_name, input.document_id);

    var doc = try db.prepare(
        \\insert into _zova_ext_trgm_documents
        \\  (index_name, document_id, target_type, target_namespace, target_ref, normalized_len, text_hash, term_count, updated_at_unix)
        \\values (?, ?, ?, ?, ?, ?, ?, ?, unixepoch())
    );
    defer doc.deinit();
    try doc.bindText(1, input.index_name);
    try doc.bindText(2, input.document_id);
    try doc.bindText(3, input.target_type);
    if (input.target_namespace) |value| {
        try doc.bindText(4, value);
    } else {
        try doc.bindNull(4);
    }
    if (input.target_ref) |value| {
        try doc.bindText(5, value);
    } else {
        try doc.bindNull(5);
    }
    try doc.bindInt64(6, std.math.cast(i64, normalized.items.len) orelse return error.TrgmInvalid);
    try doc.bindBlob(7, &hash);
    try doc.bindInt64(8, std.math.cast(i64, terms.len) orelse return error.TrgmInvalid);
    std.debug.assert((try doc.step()) == .done);

    var posting = try db.prepare(
        \\insert into _zova_ext_trgm_postings (index_name, term, document_id, count)
        \\values (?, ?, ?, ?)
    );
    defer posting.deinit();
    for (terms) |term_count| {
        try posting.bindText(1, input.index_name);
        try posting.bindBlob(2, &term_count.term);
        try posting.bindText(3, input.document_id);
        try posting.bindInt64(4, term_count.count);
        std.debug.assert((try posting.step()) == .done);
        try posting.reset();
        try posting.clearBindings();
    }

    try rebuildTerms(db, input.index_name);
}

fn deleteDocument(db: *sqlite.Database, index_name: []const u8, document_id: []const u8) Error!void {
    try ensureWritable(db);
    try validateIndexName(index_name);
    try validateDocumentId(document_id);
    if (!try indexExists(db, index_name)) return error.TrgmIndexNotFound;
    try deleteDocumentRows(db, index_name, document_id);
    try rebuildTerms(db, index_name);
}

fn deleteDocumentRows(db: *sqlite.Database, index_name: []const u8, document_id: []const u8) Error!void {
    var postings = try db.prepare("delete from _zova_ext_trgm_postings where index_name = ? and document_id = ?");
    defer postings.deinit();
    try postings.bindText(1, index_name);
    try postings.bindText(2, document_id);
    std.debug.assert((try postings.step()) == .done);

    var documents = try db.prepare("delete from _zova_ext_trgm_documents where index_name = ? and document_id = ?");
    defer documents.deinit();
    try documents.bindText(1, index_name);
    try documents.bindText(2, document_id);
    std.debug.assert((try documents.step()) == .done);
}

fn deleteByIndex(db: *sqlite.Database, comptime sql: [:0]const u8, index_name: []const u8) Error!void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try stmt.bindText(1, index_name);
    std.debug.assert((try stmt.step()) == .done);
}

fn rebuildTerms(db: *sqlite.Database, index_name: []const u8) Error!void {
    try deleteByIndex(db, "delete from _zova_ext_trgm_terms where index_name = ?", index_name);
    var stmt = try db.prepare(
        \\insert into _zova_ext_trgm_terms (index_name, term, document_count)
        \\select index_name, term, count(distinct document_id)
        \\from _zova_ext_trgm_postings
        \\where index_name = ?
        \\group by index_name, term
    );
    defer stmt.deinit();
    try stmt.bindText(1, index_name);
    std.debug.assert((try stmt.step()) == .done);
}

fn computeSimilarityValues(a_value: *c.sqlite3_value, b_value: *c.sqlite3_value) Error!f64 {
    const a = try valueText(a_value);
    const b = try valueText(b_value);
    return similarityText(a, b);
}

fn similarityText(a: []const u8, b: []const u8) Error!f64 {
    if (!std.unicode.utf8ValidateSlice(a) or !std.unicode.utf8ValidateSlice(b)) return error.TrgmInvalid;
    var normalized_a = try normalize(allocator, a);
    defer normalized_a.deinit(allocator);
    var normalized_b = try normalize(allocator, b);
    defer normalized_b.deinit(allocator);

    if (normalized_a.items.len == 0 and normalized_b.items.len == 0) return 1.0;
    if (normalized_a.items.len == 0 or normalized_b.items.len == 0) return 0.0;

    const a_terms = try extractTermCounts(allocator, normalized_a.items);
    defer allocator.free(a_terms);
    const b_terms = try extractTermCounts(allocator, normalized_b.items);
    defer allocator.free(b_terms);

    var intersection: usize = 0;
    for (a_terms) |left| {
        if (containsTerm(b_terms, left.term)) intersection += 1;
    }
    const union_count = a_terms.len + b_terms.len - intersection;
    if (union_count == 0) return 1.0;
    return scoreRatio(intersection, union_count);
}

fn scoreRatio(intersection: usize, union_count: usize) Error!f64 {
    if (intersection > std.math.maxInt(i32) or union_count > std.math.maxInt(i32)) {
        return error.TrgmInvalid;
    }
    const numerator: i32 = @intCast(intersection);
    const denominator: i32 = @intCast(union_count);
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
}

fn normalize(alloc: std.mem.Allocator, text: []const u8) Error!std.ArrayList(u8) {
    if (!std.unicode.utf8ValidateSlice(text)) return error.TrgmInvalid;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var pending_space = false;
    for (text) |byte| {
        if (isAsciiAlnum(byte)) {
            if (pending_space and out.items.len > 0) {
                try out.append(alloc, ' ');
                pending_space = false;
            }
            try out.append(alloc, std.ascii.toLower(byte));
        } else if (byte < 0x80) {
            pending_space = out.items.len > 0;
        } else {
            if (pending_space and out.items.len > 0) {
                try out.append(alloc, ' ');
                pending_space = false;
            }
            try out.append(alloc, byte);
        }
    }
    return out;
}

fn extractTermCounts(alloc: std.mem.Allocator, normalized: []const u8) Error![]TermCount {
    var terms: std.ArrayList(TermCount) = .empty;
    errdefer terms.deinit(alloc);
    if (normalized.len == 0) return try terms.toOwnedSlice(alloc);

    var padded = try alloc.alloc(u8, normalized.len + 4);
    defer alloc.free(padded);
    padded[0] = ' ';
    padded[1] = ' ';
    @memcpy(padded[2 .. 2 + normalized.len], normalized);
    padded[padded.len - 2] = ' ';
    padded[padded.len - 1] = ' ';

    var index: usize = 0;
    while (index + 3 <= padded.len) : (index += 1) {
        const term = [3]u8{ padded[index], padded[index + 1], padded[index + 2] };
        if (findTermIndex(terms.items, term)) |existing| {
            terms.items[existing].count += 1;
        } else {
            try terms.append(alloc, .{ .term = term, .count = 1 });
        }
    }
    return try terms.toOwnedSlice(alloc);
}

fn findTermIndex(terms: []const TermCount, needle: [3]u8) ?usize {
    for (terms, 0..) |term, index| {
        if (std.mem.eql(u8, &term.term, &needle)) return index;
    }
    return null;
}

fn containsTerm(terms: []const TermCount, needle: [3]u8) bool {
    return findTermIndex(terms, needle) != null;
}

const search_module = c.sqlite3_module{
    .iVersion = 3,
    .xCreate = null,
    .xConnect = searchConnect,
    .xBestIndex = searchBestIndex,
    .xDisconnect = searchDisconnect,
    .xDestroy = null,
    .xOpen = searchOpen,
    .xClose = searchClose,
    .xFilter = searchFilter,
    .xNext = searchNext,
    .xEof = searchEof,
    .xColumn = searchColumn,
    .xRowid = searchRowid,
    .xUpdate = null,
    .xBegin = null,
    .xSync = null,
    .xCommit = null,
    .xRollback = null,
    .xFindFunction = null,
    .xRename = null,
    .xSavepoint = null,
    .xRelease = null,
    .xRollbackTo = null,
    .xShadowName = null,
    .xIntegrity = null,
};

fn searchConnect(
    db: ?*c.sqlite3,
    p_aux: ?*anyopaque,
    argc: c_int,
    argv: [*c]const [*c]const u8,
    pp_vtab: [*c][*c]c.sqlite3_vtab,
    pz_err: [*c][*c]u8,
) callconv(.c) c_int {
    _ = argc;
    _ = argv;
    _ = pz_err;

    const raw_db = db orelse return c.SQLITE_ERROR;
    const aux_db: ?*c.sqlite3 = if (p_aux) |ptr| @ptrCast(ptr) else raw_db;
    const rc = c.sqlite3_declare_vtab(raw_db,
        \\create table zova_trgm_search(
        \\  rank integer,
        \\  document_id text,
        \\  target_type text,
        \\  target_namespace text,
        \\  target_ref text,
        \\  score real,
        \\  index_name text hidden,
        \\  query text hidden,
        \\  "limit" integer hidden,
        \\  threshold real hidden
        \\)
    );
    if (rc != c.SQLITE_OK) return rc;

    const table = allocator.create(SearchTable) catch return c.SQLITE_NOMEM;
    table.* = .{
        .base = .{ .pModule = &search_module, .nRef = 0, .zErrMsg = null },
        .db = aux_db,
    };
    pp_vtab.* = &table.base;
    return c.SQLITE_OK;
}

fn searchBestIndex(vtab: ?*c.sqlite3_vtab, info: ?*c.sqlite3_index_info) callconv(.c) c_int {
    _ = vtab;
    const idx = info orelse return c.SQLITE_ERROR;
    var bits: SearchConstraintBits = .{};
    var argv_index: c_int = 1;
    bits.index_name = assignConstraint(idx, @intFromEnum(SearchColumn.index_name), &argv_index);
    bits.query = assignConstraint(idx, @intFromEnum(SearchColumn.query), &argv_index);
    bits.limit = assignConstraint(idx, @intFromEnum(SearchColumn.limit), &argv_index);
    bits.threshold = assignConstraint(idx, @intFromEnum(SearchColumn.threshold), &argv_index);
    if (!bits.index_name or !bits.query) return c.SQLITE_CONSTRAINT;

    idx.idxNum = @intCast(@as(u8, @bitCast(bits)));
    idx.estimatedCost = 1000;
    idx.estimatedRows = if (bits.limit) 10 else default_search_limit;
    if (idx.nOrderBy == 1) {
        const order_by = idx.aOrderBy[0];
        if (order_by.iColumn == @intFromEnum(SearchColumn.rank) and order_by.desc == 0) {
            idx.orderByConsumed = 1;
        }
    }
    return c.SQLITE_OK;
}

fn searchDisconnect(vtab: ?*c.sqlite3_vtab) callconv(.c) c_int {
    if (vtab) |raw| {
        const table: *SearchTable = @fieldParentPtr("base", raw);
        if (table.base.zErrMsg) |msg| c.sqlite3_free(msg);
        allocator.destroy(table);
    }
    return c.SQLITE_OK;
}

fn searchOpen(vtab: ?*c.sqlite3_vtab, pp_cursor: [*c]?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = vtab orelse return c.SQLITE_ERROR;
    const table: *SearchTable = @fieldParentPtr("base", raw);
    const cursor = allocator.create(SearchCursor) catch return c.SQLITE_NOMEM;
    cursor.* = .{
        .base = .{ .pVtab = raw },
        .db = table.db,
    };
    pp_cursor.* = &cursor.base;
    return c.SQLITE_OK;
}

fn searchClose(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    if (cursor) |raw| {
        const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
        freeSearchRows(search_cursor.rows, search_cursor.rows_len);
        allocator.destroy(search_cursor);
    }
    return c.SQLITE_OK;
}

fn searchFilter(
    cursor: ?*c.sqlite3_vtab_cursor,
    idx_num: c_int,
    idx_str: [*c]const u8,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) c_int {
    _ = idx_str;
    const raw = cursor orelse return c.SQLITE_ERROR;
    const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
    freeSearchRows(search_cursor.rows, search_cursor.rows_len);
    search_cursor.rows = null;
    search_cursor.rows_len = 0;
    search_cursor.index = 0;

    const bits: SearchConstraintBits = @bitCast(@as(u8, @intCast(idx_num)));
    const expected_argc: c_int = @intCast(@as(u8, @intFromBool(bits.index_name)) +
        @as(u8, @intFromBool(bits.query)) +
        @as(u8, @intFromBool(bits.limit)) +
        @as(u8, @intFromBool(bits.threshold)));
    if (argc != expected_argc) return setCursorError(search_cursor, "invalid zova_trgm_search argument plan");

    var arg_index: usize = 0;
    const index_name = valueText(argv[arg_index] orelse return setCursorError(search_cursor, "missing index_name")) catch |err| return setCursorError(search_cursor, errorMessage(err));
    arg_index += 1;
    const query = valueText(argv[arg_index] orelse return setCursorError(search_cursor, "missing query")) catch |err| return setCursorError(search_cursor, errorMessage(err));
    arg_index += 1;

    var limit: usize = default_search_limit;
    if (bits.limit) {
        limit = parseLimit(argv[arg_index] orelse return setCursorError(search_cursor, "missing limit")) catch |err| return setCursorError(search_cursor, errorMessage(err));
        arg_index += 1;
    }

    var threshold: f64 = 0.0;
    if (bits.threshold) {
        threshold = parseThreshold(argv[arg_index] orelse return setCursorError(search_cursor, "missing threshold")) catch |err| return setCursorError(search_cursor, errorMessage(err));
        arg_index += 1;
    }

    const raw_db = search_cursor.db orelse return c.SQLITE_ERROR;
    var db = sqlite.Database{ .handle = raw_db };
    const rows = search(&db, index_name, query, limit, threshold) catch |err| return setCursorError(search_cursor, errorMessage(err));
    if (rows.len == 0) {
        allocator.free(rows);
        return c.SQLITE_OK;
    }
    search_cursor.rows = rows.ptr;
    search_cursor.rows_len = rows.len;
    return c.SQLITE_OK;
}

fn searchNext(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
    if (search_cursor.index < search_cursor.rows_len) search_cursor.index += 1;
    return c.SQLITE_OK;
}

fn searchEof(cursor: ?*c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const raw = cursor orelse return 1;
    const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
    return if (search_cursor.index >= search_cursor.rows_len) 1 else 0;
}

fn searchColumn(cursor: ?*c.sqlite3_vtab_cursor, ctx: ?*c.sqlite3_context, column_index: c_int) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const context = ctx orelse return c.SQLITE_ERROR;
    const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
    if (search_cursor.index >= search_cursor.rows_len) {
        c.sqlite3_result_null(context);
        return c.SQLITE_OK;
    }

    const row = search_cursor.rows.?[search_cursor.index];
    switch (@as(SearchColumn, @enumFromInt(column_index))) {
        .rank => c.sqlite3_result_int64(context, @intCast(search_cursor.index + 1)),
        .document_id => resultText(context, row.document_id),
        .target_type => resultText(context, row.target_type),
        .target_namespace => if (row.target_namespace) |value| resultText(context, value) else c.sqlite3_result_null(context),
        .target_ref => if (row.target_ref) |value| resultText(context, value) else c.sqlite3_result_null(context),
        .score => c.sqlite3_result_double(context, row.score),
        else => c.sqlite3_result_null(context),
    }
    return c.SQLITE_OK;
}

fn searchRowid(cursor: ?*c.sqlite3_vtab_cursor, rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const raw = cursor orelse return c.SQLITE_ERROR;
    const search_cursor: *SearchCursor = @fieldParentPtr("base", raw);
    rowid.* = @intCast(search_cursor.index + 1);
    return c.SQLITE_OK;
}

fn search(db: *sqlite.Database, index_name: []const u8, query: []const u8, limit: usize, threshold: f64) Error![]SearchRow {
    try validateIndexName(index_name);
    if (!try indexExists(db, index_name)) return error.TrgmIndexNotFound;
    if (!std.unicode.utf8ValidateSlice(query)) return error.TrgmInvalid;
    if (limit == 0) return allocator.alloc(SearchRow, 0);

    var normalized = try normalize(allocator, query);
    defer normalized.deinit(allocator);
    if (normalized.items.len == 0) return allocator.alloc(SearchRow, 0);

    const query_terms = try extractTermCounts(allocator, normalized.items);
    defer allocator.free(query_terms);

    var rows: std.ArrayList(SearchRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit();
        rows.deinit(allocator);
    }

    var docs = try db.prepare(
        \\select document_id, target_type, target_namespace, target_ref, term_count
        \\from _zova_ext_trgm_documents
        \\where index_name = ?
        \\order by document_id
    );
    defer docs.deinit();
    try docs.bindText(1, index_name);

    while (try docs.step() == .row) {
        const document_id = docs.columnText(0);
        const doc_term_count_i64 = docs.columnInt64(4);
        if (doc_term_count_i64 <= 0) continue;
        const intersection = try countIntersection(db, index_name, document_id, query_terms);
        if (intersection == 0) continue;
        const doc_term_count: usize = @intCast(doc_term_count_i64);
        const union_count = query_terms.len + doc_term_count - intersection;
        const score = try scoreRatio(intersection, union_count);
        if (score < threshold) continue;
        var row = try makeSearchRow(&docs, score);
        errdefer row.deinit();
        try rows.append(allocator, row);
    }

    std.mem.sort(SearchRow, rows.items, {}, searchRowLessThan);
    if (rows.items.len > limit) {
        for (rows.items[limit..]) |*row| row.deinit();
        rows.shrinkRetainingCapacity(limit);
    }

    return try rows.toOwnedSlice(allocator);
}

fn countIntersection(db: *sqlite.Database, index_name: []const u8, document_id: []const u8, query_terms: []const TermCount) Error!usize {
    var intersection: usize = 0;
    var stmt = try db.prepare(
        \\select count(*)
        \\from _zova_ext_trgm_postings
        \\where index_name = ? and document_id = ? and term = ?
    );
    defer stmt.deinit();
    for (query_terms) |term| {
        try stmt.bindText(1, index_name);
        try stmt.bindText(2, document_id);
        try stmt.bindBlob(3, &term.term);
        std.debug.assert((try stmt.step()) == .row);
        if (stmt.columnInt64(0) == 1) intersection += 1;
        try stmt.reset();
        try stmt.clearBindings();
    }
    return intersection;
}

fn makeSearchRow(stmt: *sqlite.Statement, score: f64) Error!SearchRow {
    const document_id = try allocator.dupe(u8, stmt.columnText(0));
    errdefer allocator.free(document_id);
    const target_type = try allocator.dupe(u8, stmt.columnText(1));
    errdefer allocator.free(target_type);
    const target_namespace = if (stmt.columnType(2) == .null) null else try allocator.dupe(u8, stmt.columnText(2));
    errdefer if (target_namespace) |value| allocator.free(value);
    const target_ref = if (stmt.columnType(3) == .null) null else try allocator.dupe(u8, stmt.columnText(3));
    errdefer if (target_ref) |value| allocator.free(value);
    return .{
        .document_id = document_id,
        .target_type = target_type,
        .target_namespace = target_namespace,
        .target_ref = target_ref,
        .score = score,
    };
}

fn searchRowLessThan(_: void, lhs: SearchRow, rhs: SearchRow) bool {
    if (lhs.score > rhs.score) return true;
    if (lhs.score < rhs.score) return false;
    return std.mem.order(u8, lhs.document_id, rhs.document_id) == .lt;
}

fn freeSearchRows(rows_ptr: ?[*]SearchRow, rows_len: usize) void {
    if (rows_ptr) |ptr| {
        const rows = ptr[0..rows_len];
        for (rows) |*row| row.deinit();
        allocator.free(rows);
    }
}

fn assignConstraint(idx: *c.sqlite3_index_info, column_index: c_int, argv_index: *c_int) bool {
    const constraints = idx.aConstraint[0..@intCast(idx.nConstraint)];
    const usages = idx.aConstraintUsage[0..@intCast(idx.nConstraint)];
    for (constraints, usages) |constraint, *usage| {
        if (constraint.usable == 0 or constraint.op != c.SQLITE_INDEX_CONSTRAINT_EQ) continue;
        if (constraint.iColumn != column_index) continue;
        usage.argvIndex = argv_index.*;
        usage.omit = 1;
        argv_index.* += 1;
        return true;
    }
    return false;
}

fn validateIndexName(index_name: []const u8) Error!void {
    try validateAsciiName(index_name, max_index_name_bytes);
}

fn validateDocumentId(document_id: []const u8) Error!void {
    if (document_id.len == 0 or document_id.len > max_document_id_bytes) return error.TrgmInvalid;
    if (!std.unicode.utf8ValidateSlice(document_id)) return error.TrgmInvalid;
    if (hasReservedZovaPrefix(document_id)) return error.TrgmInvalid;
    for (document_id) |byte| if (byte == 0) return error.TrgmInvalid;
}

fn validateAsciiName(value: []const u8, max_len: usize) Error!void {
    if (value.len == 0 or value.len > max_len) return error.TrgmInvalid;
    if (hasReservedZovaPrefix(value)) return error.TrgmInvalid;
    for (value) |byte| {
        if (!isNameByte(byte)) return error.TrgmInvalid;
    }
}

fn validateOptionalText(value: []const u8) Error!void {
    if (value.len > max_target_text_bytes) return error.TrgmInvalid;
    if (!std.unicode.utf8ValidateSlice(value)) return error.TrgmInvalid;
    for (value) |byte| if (byte == 0) return error.TrgmInvalid;
}

fn parseTargetType(value: []const u8) Error!TargetType {
    if (std.mem.eql(u8, value, "record")) return .record;
    if (std.mem.eql(u8, value, "object")) return .object;
    if (std.mem.eql(u8, value, "object_chunk")) return .object_chunk;
    if (std.mem.eql(u8, value, "vector")) return .vector;
    if (std.mem.eql(u8, value, "graph")) return .graph;
    if (std.mem.eql(u8, value, "entity")) return .entity;
    if (std.mem.eql(u8, value, "fact")) return .fact;
    if (std.mem.eql(u8, value, "concept")) return .concept;
    if (std.mem.eql(u8, value, "external")) return .external;
    return error.TrgmInvalid;
}

fn validateTarget(db: *sqlite.Database, target_type: TargetType, target_namespace: ?[]const u8, target_ref: ?[]const u8) Error!void {
    if (target_namespace) |value| try validateOptionalText(value);

    switch (target_type) {
        .record, .entity, .fact, .concept, .external => {
            if (target_ref) |ref| try validateOptionalText(ref);
        },
        .object => try validateObjectTarget(db, try requiredTargetRef(target_ref), "_zova_objects"),
        .object_chunk => try validateObjectTarget(db, try requiredTargetRef(target_ref), "_zova_chunks"),
        .vector => {
            const collection = target_namespace orelse return error.TrgmInvalid;
            try validateVectorTarget(db, collection, try requiredTargetRef(target_ref));
        },
        .graph => {
            const graph_name = target_namespace orelse graph.default_graph_name;
            try validateGraphTarget(db, graph_name, try requiredTargetRef(target_ref));
        },
    }
}

fn requiredTargetRef(target_ref: ?[]const u8) Error![]const u8 {
    const ref = target_ref orelse return error.TrgmInvalid;
    try validateOptionalText(ref);
    if (ref.len == 0) return error.TrgmInvalid;
    return ref;
}

fn validateObjectTarget(db: *sqlite.Database, hex_ref: []const u8, table_name: []const u8) Error!void {
    const id = try decodeHex32(hex_ref);
    if (try blobExists(db, table_name, if (std.mem.eql(u8, table_name, "_zova_objects")) "object_id" else "chunk_hash", &id)) return;
    if (try attachedSchemaExists(db, "object_store")) {
        var sql_buffer: [128]u8 = undefined;
        const sql = std.fmt.bufPrintZ(&sql_buffer, "select count(*) from object_store.{s} where {s} = ?", .{
            table_name,
            if (std.mem.eql(u8, table_name, "_zova_objects")) "object_id" else "chunk_hash",
        }) catch return error.SqliteError;
        var stmt = try db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindBlob(1, &id);
        std.debug.assert((try stmt.step()) == .row);
        if (stmt.columnInt64(0) == 1) return;
    }
    return error.TrgmInvalid;
}

fn validateVectorTarget(db: *sqlite.Database, collection: []const u8, vector_id: []const u8) Error!void {
    if (try vectorExists(db, "_zova_vectors", collection, vector_id)) return;
    if (try attachedSchemaExists(db, "vector_store")) {
        var stmt = try db.prepare(
            \\select count(*)
            \\from vector_store._zova_vectors
            \\where collection_name = ? and vector_id = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, collection);
        try stmt.bindText(2, vector_id);
        std.debug.assert((try stmt.step()) == .row);
        if (stmt.columnInt64(0) == 1) return;
    }
    return error.TrgmInvalid;
}

fn validateGraphTarget(db: *sqlite.Database, graph_name: []const u8, node_id: []const u8) Error!void {
    var stmt = try db.prepare("select count(*) from _zova_graph_nodes where graph_name = ? and node_id = ?");
    defer stmt.deinit();
    try stmt.bindText(1, graph_name);
    try stmt.bindText(2, node_id);
    std.debug.assert((try stmt.step()) == .row);
    if (stmt.columnInt64(0) != 1) return error.TrgmInvalid;
}

fn blobExists(db: *sqlite.Database, table_name: []const u8, column_name: []const u8, id: *const [32]u8) Error!bool {
    var sql_buffer: [128]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&sql_buffer, "select count(*) from {s} where {s} = ?", .{ table_name, column_name }) catch return error.SqliteError;
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try stmt.bindBlob(1, id);
    std.debug.assert((try stmt.step()) == .row);
    return stmt.columnInt64(0) == 1;
}

fn vectorExists(db: *sqlite.Database, table_name: []const u8, collection: []const u8, vector_id: []const u8) Error!bool {
    var sql_buffer: [160]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&sql_buffer, "select count(*) from {s} where collection_name = ? and vector_id = ?", .{table_name}) catch return error.SqliteError;
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try stmt.bindText(1, collection);
    try stmt.bindText(2, vector_id);
    std.debug.assert((try stmt.step()) == .row);
    return stmt.columnInt64(0) == 1;
}

fn attachedSchemaExists(db: *sqlite.Database, schema_name: []const u8) Error!bool {
    var stmt = try db.prepare("select count(*) from pragma_database_list where name = ?");
    defer stmt.deinit();
    try stmt.bindText(1, schema_name);
    std.debug.assert((try stmt.step()) == .row);
    return stmt.columnInt64(0) == 1;
}

fn decodeHex32(hex: []const u8) Error![32]u8 {
    if (hex.len != 64) return error.TrgmInvalid;
    var out: [32]u8 = undefined;
    var index: usize = 0;
    while (index < out.len) : (index += 1) {
        const hi = try hexValue(hex[index * 2]);
        const lo = try hexValue(hex[index * 2 + 1]);
        out[index] = (hi << 4) | lo;
    }
    return out;
}

fn hexValue(byte: u8) Error!u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return error.TrgmInvalid;
}

fn ensureWritable(db: *sqlite.Database) Error!void {
    if (c.sqlite3_db_readonly(db.handle, "main") == 1) return error.ReadOnly;
}

fn indexExists(db: *sqlite.Database, index_name: []const u8) Error!bool {
    var stmt = try db.prepare("select count(*) from _zova_ext_trgm_indexes where name = ?");
    defer stmt.deinit();
    try stmt.bindText(1, index_name);
    std.debug.assert((try stmt.step()) == .row);
    return stmt.columnInt64(0) == 1;
}

fn tableExists(db: *sqlite.Database, table_name: []const u8) Error!bool {
    var stmt = try db.prepare("select count(*) from sqlite_master where type = 'table' and name = ?");
    defer stmt.deinit();
    try stmt.bindText(1, table_name);
    std.debug.assert((try stmt.step()) == .row);
    return stmt.columnInt64(0) == 1;
}

fn expectNoRows(db: *sqlite.Database, comptime sql: [:0]const u8) Error!void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    switch (try stmt.step()) {
        .done => {},
        .row => return error.ExtensionInvalid,
    }
}

fn valueText(value: *c.sqlite3_value) Error![]const u8 {
    if (c.sqlite3_value_type(value) != c.SQLITE_TEXT) return error.TrgmInvalid;
    const ptr = c.sqlite3_value_text(value) orelse return "";
    const len = c.sqlite3_value_bytes(value);
    if (len < 0) return error.TrgmInvalid;
    const many: [*]const u8 = @ptrCast(ptr);
    const slice = many[0..@intCast(len)];
    if (!std.unicode.utf8ValidateSlice(slice)) return error.TrgmInvalid;
    return slice;
}

fn valueNullableText(value: *c.sqlite3_value) Error!?[]const u8 {
    if (c.sqlite3_value_type(value) == c.SQLITE_NULL) return null;
    return try valueText(value);
}

fn parseLimit(value: *c.sqlite3_value) Error!usize {
    if (c.sqlite3_value_type(value) != c.SQLITE_INTEGER) return error.TrgmInvalid;
    const raw = c.sqlite3_value_int64(value);
    if (raw < 0) return error.TrgmInvalid;
    return std.math.cast(usize, raw) orelse error.TrgmInvalid;
}

fn parseThreshold(value: *c.sqlite3_value) Error!f64 {
    const value_type = c.sqlite3_value_type(value);
    if (value_type != c.SQLITE_INTEGER and value_type != c.SQLITE_FLOAT) return error.TrgmInvalid;
    const threshold = c.sqlite3_value_double(value);
    if (std.math.isNan(threshold) or std.math.isInf(threshold)) return error.TrgmInvalid;
    if (threshold < 0.0 or threshold > 1.0) return error.TrgmInvalid;
    return threshold;
}

fn resultText(ctx: *c.sqlite3_context, value: []const u8) void {
    c.sqlite3_result_text(ctx, value.ptr, @intCast(value.len), null);
}

fn resultError(ctx: *c.sqlite3_context, message: []const u8) void {
    c.sqlite3_result_error(ctx, message.ptr, @intCast(message.len));
}

fn setCursorError(cursor: *SearchCursor, message: []const u8) c_int {
    const vtab: *c.sqlite3_vtab = @ptrCast(cursor.base.pVtab);
    const table: *SearchTable = @fieldParentPtr("base", vtab);
    if (table.base.zErrMsg) |old| c.sqlite3_free(old);
    table.base.zErrMsg = null;
    const raw = c.sqlite3_malloc64(@intCast(message.len + 1)) orelse return c.SQLITE_NOMEM;
    const copy: [*]u8 = @ptrCast(raw);
    @memcpy(copy[0..message.len], message);
    copy[message.len] = 0;
    table.base.zErrMsg = copy;
    return c.SQLITE_ERROR;
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.TrgmInvalid => "invalid Zova trgm value",
        error.TrgmIndexNotFound => "Zova trgm index not found",
        error.TrgmDocumentNotFound => "Zova trgm document not found",
        error.ReadOnly => "Zova trgm mutation requires a writable database",
        error.NoMemory, error.OutOfMemory => "out of memory",
        else => "Zova trgm SQL error",
    };
}

fn mapResultCode(rc: c_int) sqlite.Error {
    return switch (rc) {
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_NOMEM => error.NoMemory,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_CORRUPT => error.Corrupt,
        c.SQLITE_MISUSE => error.Misuse,
        else => error.SqliteError,
    };
}

fn isAsciiAlnum(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9');
}

fn isNameByte(byte: u8) bool {
    return isAsciiAlnum(byte) or byte == '_' or byte == '.' or byte == ':' or byte == '-';
}

fn hasReservedZovaPrefix(value: []const u8) bool {
    const reserved = "_zova_";
    if (value.len < reserved.len) return false;
    for (reserved, 0..) |expected, index| {
        if (std.ascii.toLower(value[index]) != expected) return false;
    }
    return true;
}
