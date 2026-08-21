//! Format-9 fixture exporter for Zova storage-format migration testing.
//!
//! This program must be compiled against an unmodified checkout of the
//! released `v0.26.1` tag; never against current development sources. See
//! `scripts/export-format-9-fixtures.sh` for the supported invocation.
//!
//! Usage: export-format-9-fixtures <output-directory>

const std = @import("std");
const zova = @import("zova");

const populated_user_sql =
    \\create table user_documents (
    \\  id integer primary key,
    \\  title text not null,
    \\  body text not null,
    \\  word_count integer not null default 0,
    \\  created_at_unix integer not null
    \\);
    \\create index user_documents_title_idx on user_documents (title);
    \\create unique index user_documents_created_idx on user_documents (created_at_unix, id);
    \\create view user_document_titles as select id, title from user_documents order by id;
    \\create trigger user_documents_touch after insert on user_documents begin
    \\  update user_documents set word_count = length(new.body) where id = new.id;
    \\end;
;

fn populateUserSql(db: *zova.Database) !void {
    try db.exec(populated_user_sql);

    var insert = try db.prepare(
        "insert into user_documents (title, body, created_at_unix) values (?, ?, ?)",
    );
    defer insert.deinit();

    const rows = [_]struct { title: []const u8, body: []const u8, at: i64 }{
        .{ .title = "alpha", .body = "alpha document body", .at = 1750000000 },
        .{ .title = "beta", .body = "beta document body with more words", .at = 1750000100 },
        .{ .title = "gamma", .body = "gamma", .at = 1750000200 },
    };

    for (rows) |row| {
        try insert.reset();
        try insert.bindText(1, row.title);
        try insert.bindText(2, row.body);
        try insert.bindInt64(3, row.at);
        _ = try insert.step();
    }
}

fn writeObjects(db: *zova.Database, alloc: std.mem.Allocator, bound_store: bool) !void {
    // Small single-chunk payloads.
    const small_payloads = [_][]const u8{
        "first object payload: small enough for a single chunk.",
        "second object payload with modest size.",
    };

    for (small_payloads) |payload| {
        var writer = try db.objectWriter(alloc);
        defer writer.deinit();
        try writer.write(payload);
        _ = try writer.finish();
    }

    // One deterministic multi-chunk payload well beyond the 64 KiB maximum
    // chunk size so manifest ordering, offsets/ranges, and repeated chunk rows
    // are represented in the fixture evidence.
    const large_size = 320 * 1024;
    const large_payload = try alloc.alloc(u8, large_size);
    defer alloc.free(large_payload);

    var state: u32 = 0x9e3779b9;
    for (large_payload) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 16);
    }

    var writer = try db.objectWriter(alloc);
    defer writer.deinit();
    try writer.write(large_payload);
    const large_id = try writer.finish();

    // With a bound store, object bytes live in the attached object_store
    // schema instead of main.
    const count_sql: [:0]const u8 = if (bound_store)
        "select count(*) from object_store._zova_object_chunks where object_id = ?"
    else
        "select count(*) from _zova_object_chunks where object_id = ?";
    var chunk_count = try db.prepare(count_sql);
    defer chunk_count.deinit();
    try chunk_count.bindBlob(1, &large_id);
    _ = try chunk_count.step();
    const chunks = chunk_count.columnInt64(0);
    if (chunks < 2) {
        std.debug.print("error: multi-chunk object produced only {d} chunk(s)\n", .{chunks});
        return error.MultiChunkObjectExpected;
    }
}

fn putVectorRows(
    db: *zova.Database,
    comptime element: std.meta.Tag(zova.VectorValuesConst),
    collection: []const u8,
    inputs: []const zova.VectorInput,
) !void {
    _ = element;
    try db.putVectors(collection, inputs);
}

fn populateVectors(db: *zova.Database) !void {
    try db.createVectorCollection("embeddings_f32", .{
        .dimensions = 4,
        .metric = .cosine,
        .element_type = .f32,
    });
    try db.createVectorCollection("embeddings_f16", .{
        .dimensions = 4,
        .metric = .l2,
        .element_type = .f16,
    });
    try db.createVectorCollection("embeddings_i8", .{
        .dimensions = 4,
        .metric = .cosine,
        .element_type = .i8,
    });

    const f32_rows = [_]zova.VectorInput{
        .{ .id = "f32-a", .values = .{ .f32 = &.{ 0.25, -0.5, 1.0, 2.0 } } },
        .{ .id = "f32-b", .values = .{ .f32 = &.{ -1.5, 0.125, 0.75, -2.25 } } },
    };
    try putVectorRows(db, .f32, "embeddings_f32", &f32_rows);

    // IEEE 754 binary16 bit patterns transported as u16.
    const f16_rows = [_]zova.VectorInput{
        .{ .id = "f16-a", .values = .{ .f16 = &.{ 0x3c00, 0xbc00, 0x4200, 0xc200 } } },
        .{ .id = "f16-b", .values = .{ .f16 = &.{ 0x3800, 0xb800, 0x4000, 0x4400 } } },
    };
    try putVectorRows(db, .f16, "embeddings_f16", &f16_rows);

    const i8_rows = [_]zova.VectorInput{
        .{ .id = "i8-a", .values = .{ .i8 = &.{ 12, -34, 56, -78 } } },
        .{ .id = "i8-b", .values = .{ .i8 = &.{ -100, 100, 7, -7 } } },
    };
    try putVectorRows(db, .i8, "embeddings_i8", &i8_rows);
}

fn populateGraphs(db: *zova.Database) !void {
    try db.createGraph("social");
    try db.createGraph("workflow");

    try db.putGraphNode(.{
        .graph_name = "social",
        .node_id = "alice",
        .kind = "person",
        .target_type = .record,
        .target_namespace = "user_documents",
        .target_ref = "1",
    });
    try db.putGraphNode(.{
        .graph_name = "social",
        .node_id = "bob",
        .kind = "person",
        .target_type = .object,
        .target_namespace = "objects",
        .target_ref = "second-object",
    });

    var social_keys: [2]i64 = undefined;
    try db.putGraphEdgesKeyed(&.{
        .{ .graph_name = "social", .from_node_id = "alice", .edge_type = "knows", .to_node_id = "bob" },
        .{ .graph_name = "social", .from_node_id = "bob", .edge_type = "follows", .to_node_id = "alice" },
    }, &social_keys);

    try db.replaceGraphEdgePayloads("social", &.{
        .{ .edge_key = social_keys[0], .payload = "edge payload knows" },
        .{ .edge_key = social_keys[1], .payload = "edge payload follows" },
    });

    try db.putGraphNode(.{
        .graph_name = "workflow",
        .node_id = "start",
        .kind = "state",
    });
    try db.putGraphNode(.{
        .graph_name = "workflow",
        .node_id = "done",
        .kind = "state",
    });

    var workflow_keys: [1]i64 = undefined;
    try db.putGraphEdgesKeyed(&.{
        .{ .graph_name = "workflow", .from_node_id = "start", .edge_type = "transitions-to", .to_node_id = "done" },
    }, &workflow_keys);
}

fn createPopulatedDatabase(path: [:0]const u8, alloc: std.mem.Allocator) !void {
    var db = try zova.Database.create(path);
    defer db.deinit();

    try populateUserSql(&db);
    try db.installExtension("trgm");
    try writeObjects(&db, alloc, false);
    try populateVectors(&db);
    try populateGraphs(&db);
}

const BoundSetPaths = struct {
    main: [:0]const u8,
    objects: [:0]const u8,
    vectors: [:0]const u8,
    graphs: [:0]const u8,
};

fn createBoundSet(init: std.process.Init, paths: BoundSetPaths, alloc: std.mem.Allocator) !void {
    try zova.createObjectStore(paths.objects);
    errdefer std.Io.Dir.cwd().deleteFile(init.io, paths.objects) catch {};

    try zova.createVectorStore(paths.vectors);
    errdefer std.Io.Dir.cwd().deleteFile(init.io, paths.vectors) catch {};

    try zova.createGraphStore(paths.graphs);
    errdefer std.Io.Dir.cwd().deleteFile(init.io, paths.graphs) catch {};

    var main_db = try zova.Database.create(paths.main);
    defer main_db.deinit();

    try main_db.bindObjectStore(paths.objects);
    try main_db.bindVectorStore(paths.vectors);
    try main_db.bindGraphStore(paths.graphs);

    try populateUserSql(&main_db);
    try main_db.installExtension("trgm");
    try writeObjects(&main_db, alloc, true);
    try populateVectors(&main_db);
    try populateGraphs(&main_db);
}

/// Reopen the bound main through the released build and verify every attached
/// store is locatable via its recorded relative path and still holds data.
fn smokeCheckBoundSet(main_path: [:0]const u8) !void {
    var db = try zova.Database.open(main_path);
    defer db.deinit();

    const checks = [_]struct { sql: [:0]const u8, minimum: i64 }{
        .{ .sql = "select count(*) from object_store._zova_objects", .minimum = 3 },
        .{ .sql = "select count(*) from object_store._zova_object_chunks", .minimum = 4 },
        .{ .sql = "select count(*) from vector_store._zova_vectors", .minimum = 6 },
        .{ .sql = "select count(*) from vector_store._zova_vector_collections", .minimum = 3 },
        .{ .sql = "select count(*) from graph_store._zova_graph_nodes", .minimum = 4 },
        .{ .sql = "select count(*) from graph_store._zova_graph_edges", .minimum = 3 },
        .{ .sql = "select count(*) from graph_store._zova_graph_edges where length(payload) > 0", .minimum = 2 },
    };

    for (checks) |check| {
        var stmt = try db.prepare(check.sql);
        defer stmt.deinit();
        _ = try stmt.step();
        const count = stmt.columnInt64(0);
        if (count < check.minimum) {
            std.debug.print("error: bound-store smoke check failed: {s} returned {d}\n", .{ check.sql, count });
            return error.BoundStoreSmokeCheckFailed;
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 2) return 2;

    // Run from inside the output directory so bound stores are recorded as
    // stable relative sibling names instead of absolute temporary paths.
    try std.process.setCurrentPath(init.io, args[1]);

    // 1. Empty main database.
    {
        var db = try zova.Database.create("empty-main-format-9.zova");
        defer db.deinit();
    }

    // 2. Populated single-file database.
    try createPopulatedDatabase("format-9.zova", alloc);

    // 3. Main database with bound object, vector, and graph stores.
    {
        const paths = BoundSetPaths{
            .main = "bound-main-format-9.zova",
            .objects = "bound-main-format-9.objects.zova",
            .vectors = "bound-main-format-9.vectors.zova",
            .graphs = "bound-main-format-9.graphs.zova",
        };
        try createBoundSet(init, paths, alloc);
        try smokeCheckBoundSet(paths.main);
    }

    // 4. Standalone empty stores retained for legacy rejection tests.
    try zova.createVectorStore("empty-vector-store-format-9.zova");
    try zova.createGraphStore("empty-graph-store-format-9.zova");

    return 0;
}
