const std = @import("std");
const zova = @import("zova.zig");
const attachStore = @import("database/bound_stores.zig").attachStore;
const backupMainDatabase = @import("database/backup.zig").backupMainDatabase;
const bound_graph_store_role = @import("database/types.zig").bound_graph_store_role;
const bound_graph_store_schema_name = @import("database/types.zig").bound_graph_store_schema_name;
const bound_object_store_role = @import("database/types.zig").bound_object_store_role;
const bound_stores_schema_sql = @import("database/types.zig").bound_stores_schema_sql;
const bound_vector_store_role = @import("database/types.zig").bound_vector_store_role;
const BoundGraphStoreInfo = @import("database/types.zig").BoundGraphStoreInfo;
const BoundObjectStoreInfo = @import("database/types.zig").BoundObjectStoreInfo;
const BoundVectorStoreInfo = @import("database/types.zig").BoundVectorStoreInfo;
const bundled_extensions = @import("database/types.zig").bundled_extensions;
const classifyFormatVersion = @import("database/format.zig").classifyFormatVersion;
const convertSqliteToZova = zova.convertSqliteToZova;
const createGraphStore = @import("database/lifecycle.zig").createGraphStore;
const createObjectStore = @import("database/lifecycle.zig").createObjectStore;
const createVectorStore = @import("database/lifecycle.zig").createVectorStore;
const Database = zova.Database;
const defaultIo = @import("database/paths.zig").defaultIo;
const ensureBoundStoreTable = @import("database/lifecycle.zig").ensureBoundStoreTable;
const Extension = @import("database/types.zig").Extension;
const extension_impl = @import("extension.zig");
const ExtensionManifest = @import("database/types.zig").ExtensionManifest;
const ExtensionRegistry = @import("database/types.zig").ExtensionRegistry;
const format_version = @import("database/types.zig").format_version;
const FormatCompatibility = @import("database/types.zig").FormatCompatibility;
const GraphTargetType = @import("database/types.zig").GraphTargetType;
const isValidStoreId = @import("database/metadata.zig").isValidStoreId;
const Notification = @import("database/types.zig").Notification;
const notify_impl = @import("notify.zig");
const object_impl = @import("object.zig");
const ObjectChunkId = @import("database/types.zig").ObjectChunkId;
const objectChunkId = zova.objectChunkId;
const ObjectId = @import("database/types.zig").ObjectId;
const objectId = zova.objectId;
const randomHex64 = @import("database/metadata.zig").randomHex64;
const restoreBackup = zova.restoreBackup;
const restoreBackupToMemory = zova.restoreBackupToMemory;
const restoreBackupWithExtensions = zova.restoreBackupWithExtensions;
const setAttachedMetadataValue = @import("database/metadata.zig").setAttachedMetadataValue;
const SplitGraphStoreResult = @import("database/types.zig").SplitGraphStoreResult;
const sqlite = @import("sqlite.zig");
const tableExists = @import("database/metadata.zig").tableExists;
const validateAttachedGraphStoreAlloc = @import("database/validation.zig").validateAttachedGraphStoreAlloc;
const vector_impl = @import("vector.zig");
const version = @import("version.zig");

const test_support = @import("zova_test_support.zig");

const testingDbPath = test_support.testingDbPath;

const testingWriteMetadata = test_support.testingWriteMetadata;

const testingExpectTableCount = test_support.testingExpectTableCount;

const testingCount = test_support.testingCount;

const testingQuickCheckOk = test_support.testingQuickCheckOk;

const testingIntegrityCheckOk = test_support.testingIntegrityCheckOk;

fn testingExpectScalarText(db: *sqlite.Database, sql: [:0]const u8, expected: []const u8) !void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings(expected, stmt.columnText(0));
}

fn expectBoundObjectEpoch(db: *Database, expected: u64) !void {
    const main_epoch = try testingCount(&db.sqlite_db,
        \\select object_epoch
        \\from _zova_bound_stores
        \\where role = 'object_store' and name = 'default'
    );
    try std.testing.expectEqual(@as(i64, @intCast(expected)), main_epoch);

    const attached_epoch = try testingCount(&db.sqlite_db,
        \\select cast(value as integer)
        \\from object_store._zova_meta
        \\where key = 'object_epoch'
    );
    try std.testing.expectEqual(@as(i64, @intCast(expected)), attached_epoch);
}

fn expectBoundVectorEpoch(db: *Database, expected: u64) !void {
    const main_epoch = try testingCount(&db.sqlite_db,
        \\select vector_epoch
        \\from _zova_bound_stores
        \\where role = 'vector_store' and name = 'default'
    );
    try std.testing.expectEqual(@as(i64, @intCast(expected)), main_epoch);

    const attached_epoch = try testingCount(&db.sqlite_db,
        \\select cast(value as integer)
        \\from vector_store._zova_meta
        \\where key = 'vector_epoch'
    );
    try std.testing.expectEqual(@as(i64, @intCast(expected)), attached_epoch);
}

fn insertObjectReference(db: *Database, object_id: ObjectId) !void {
    var stmt = try db.prepare("insert into attachments(object_id) values (?)");
    defer stmt.deinit();

    try stmt.bindBlob(1, &object_id);
    try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
}

fn testingLowerHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[@intCast(byte >> 4)];
        out[index * 2 + 1] = digits[@intCast(byte & 0x0f)];
    }
    return out;
}

const OperationalFixtureIds = struct {
    primary_object: ObjectId,
    streamed_object: ObjectId,
    loose_chunk: ObjectChunkId,
};

fn fillOperationalLargeFixture(bytes: []u8) void {
    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 31 + index / 7) % 251);
    }
}

fn populateOperationalFixture(
    db: *Database,
    primary_bytes: []const u8,
    streamed_bytes: []const u8,
    loose_bytes: []const u8,
) !OperationalFixtureIds {
    try db.exec(
        \\create table docs (
        \\  id integer primary key,
        \\  title text not null,
        \\  object_id blob,
        \\  vector_id text
        \\);
        \\create table doc_log (
        \\  doc_id integer not null,
        \\  title text not null
        \\);
        \\create index docs_title_idx on docs (title);
        \\create view doc_titles as select title from docs;
        \\create trigger docs_after_insert
        \\after insert on docs
        \\begin
        \\  insert into doc_log (doc_id, title) values (new.id, new.title);
        \\end;
    );

    const primary_object = try db.putObject(primary_bytes);
    const streamed_object = try test_support.testingStreamObject(db, streamed_bytes, &.{ 1, 17, 4096, 70_000 });

    var insert_doc = try db.prepare(
        \\insert into docs (title, object_id, vector_id)
        \\values (?, ?, ?)
    );
    defer insert_doc.deinit();

    try insert_doc.bindText(1, "primary");
    try insert_doc.bindBlob(2, &primary_object);
    try insert_doc.bindText(3, "doc-a");
    try std.testing.expectEqual(sqlite.Step.done, try insert_doc.step());

    try insert_doc.reset();
    try insert_doc.clearBindings();
    try insert_doc.bindText(1, "streamed");
    try insert_doc.bindBlob(2, &streamed_object);
    try insert_doc.bindText(3, "doc-b");
    try std.testing.expectEqual(sqlite.Step.done, try insert_doc.step());

    try db.createVectorCollection("docs", .{ .dimensions = 3, .metric = .l2 });
    try db.putVectors("docs", &.{
        .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0, 0.0 } } },
        .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0, 0.0 } } },
    });

    try db.createGraph("ops");
    try db.putGraphNode(.{ .graph_name = "ops", .node_id = "doc:primary", .kind = "document", .target_type = .record, .target_namespace = "docs", .target_ref = "1" });
    try db.putGraphNode(.{ .graph_name = "ops", .node_id = "doc:streamed", .kind = "document", .target_type = .record, .target_namespace = "docs", .target_ref = "2" });
    try db.putGraphNode(.{ .graph_name = "ops", .node_id = "vector:doc-a", .kind = "embedding", .target_type = .vector, .target_namespace = "docs", .target_ref = "doc-a" });
    try db.putGraphEdge(.{ .graph_name = "ops", .from_node_id = "doc:primary", .edge_type = "related_to", .to_node_id = "doc:streamed" });
    try db.putGraphEdge(.{ .graph_name = "ops", .from_node_id = "doc:primary", .edge_type = "embedded_as", .to_node_id = "vector:doc-a" });

    const loose_chunk = objectChunkId(loose_bytes);
    try db.putObjectChunk(loose_chunk, loose_bytes);

    return .{
        .primary_object = primary_object,
        .streamed_object = streamed_object,
        .loose_chunk = loose_chunk,
    };
}

fn expectOperationalFixture(
    path: [:0]const u8,
    ids: OperationalFixtureIds,
    primary_bytes: []const u8,
    streamed_bytes: []const u8,
    loose_bytes: []const u8,
) !void {
    var db = try Database.open(path);
    defer db.deinit();

    try expectOperationalFixtureHandle(&db, ids, primary_bytes, streamed_bytes, loose_bytes);
}

fn expectOperationalFixtureHandle(
    db: *Database,
    ids: OperationalFixtureIds,
    primary_bytes: []const u8,
    streamed_bytes: []const u8,
    loose_bytes: []const u8,
) !void {
    try testingQuickCheckOk(db);
    try testingIntegrityCheckOk(db);

    try std.testing.expectEqual(@as(i64, 2), try testingCount(db, "select count(*) from docs"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(db, "select count(*) from doc_log"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(db,
        \\select count(*)
        \\from sqlite_master
        \\where name in ('docs_title_idx', 'doc_titles', 'docs_after_insert')
    ));

    var view_rows = try db.prepare("select title from doc_titles order by title");
    defer view_rows.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try view_rows.step());
    try std.testing.expectEqualStrings("primary", view_rows.columnText(0));
    try std.testing.expectEqual(sqlite.Step.row, try view_rows.step());
    try std.testing.expectEqualStrings("streamed", view_rows.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try view_rows.step());

    var primary = try db.getObject(std.testing.allocator, ids.primary_object);
    defer primary.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, primary_bytes, primary.bytes);

    var streamed = try db.getObject(std.testing.allocator, ids.streamed_object);
    defer streamed.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, streamed_bytes, streamed.bytes);

    var range: [37]u8 = undefined;
    const range_len = try db.readObjectRange(ids.streamed_object, 11, &range);
    try std.testing.expectEqual(@as(usize, range.len), range_len);
    try std.testing.expectEqualSlices(u8, streamed_bytes[11 .. 11 + range.len], &range);

    var manifest = try db.objectManifest(std.testing.allocator, ids.streamed_object);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expect(manifest.chunks.len > 1);

    var loose = try db.getObjectChunk(std.testing.allocator, ids.loose_chunk);
    defer loose.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, loose_bytes, loose.bytes);

    var vector = try db.getVector(std.testing.allocator, "docs", "doc-a");
    defer vector.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("doc-a", vector.id);
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0, 0.0 }, vector.values.f32);

    var results = try db.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0, 0.0 } }, 2);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("doc-a", results.items[0].id);

    try std.testing.expect(try db.hasGraph("ops"));
    try std.testing.expect(try db.hasGraphNode("ops", "doc:primary"));
    try std.testing.expect(try db.hasGraphEdge("ops", "doc:primary", "embedded_as", "vector:doc-a"));
    var neighbors = try db.graphNeighbors(std.testing.allocator, .{
        .graph_name = "ops",
        .node_id = "doc:primary",
        .limit = 10,
    });
    defer neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), neighbors.items.len);
    try std.testing.expectEqualStrings("doc:streamed", neighbors.items[0].node_id);
    try std.testing.expectEqualStrings("vector:doc-a", neighbors.items[1].node_id);

    const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 1.0, 0.0, 0.0 });
    defer std.testing.allocator.free(query_blob);

    var distance = try db.prepare("select zova_vector_distance('docs', 'doc-a', ?)");
    defer distance.deinit();
    try distance.bindBlob(1, query_blob);
    try std.testing.expectEqual(sqlite.Step.row, try distance.step());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), distance.columnDouble(0), 0.000001);
    try std.testing.expectEqual(sqlite.Step.done, try distance.step());
}

test "createMemory initializes complete schema without creating files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var db = try Database.createMemory();
    defer db.deinit();

    var meta = try db.prepare("select value from _zova_meta where key = 'format_version'");
    defer meta.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings(format_version, meta.columnText(0));
    try std.testing.expectEqual(sqlite.Step.done, try meta.step());

    var tables = try db.prepare(
        \\select count(*) from sqlite_master
        \\where type = 'table' and name in (
        \\  '_zova_extensions',
        \\  '_zova_objects',
        \\  '_zova_chunks',
        \\  '_zova_object_chunks',
        \\  '_zova_vector_collections',
        \\  '_zova_vectors',
        \\  '_zova_graphs',
        \\  '_zova_graph_nodes',
        \\  '_zova_graph_edge_types',
        \\  '_zova_graph_edges'
        \\)
    );
    defer tables.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try tables.step());
    try std.testing.expectEqual(@as(i64, 10), tables.columnInt64(0));
    try std.testing.expectEqual(sqlite.Step.done, try tables.step());

    const io = defaultIo();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const memory_base = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/memory.zova", .{tmp.sub_path[0..]});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, memory_base, .{}));
    var wal_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_buffer, ".zig-cache/tmp/{s}/memory.zova-wal", .{tmp.sub_path[0..]});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, wal_path, .{}));
    var journal_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const journal_path = try std.fmt.bufPrint(&journal_buffer, ".zig-cache/tmp/{s}/memory.zova-journal", .{tmp.sub_path[0..]});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, journal_path, .{}));
}

test "createMemory matches file backed records objects chunks and vectors" {
    var db = try Database.createMemory();
    defer db.deinit();

    const primary_bytes = "memory primary object bytes\x00with nul";
    const loose_bytes = "verified in-memory loose operational chunk";
    const streamed_bytes = try std.testing.allocator.alloc(u8, 140_000);
    defer std.testing.allocator.free(streamed_bytes);
    fillOperationalLargeFixture(streamed_bytes);

    const ids = try populateOperationalFixture(&db, primary_bytes, streamed_bytes, loose_bytes);
    try expectOperationalFixtureHandle(&db, ids, primary_bytes, streamed_bytes, loose_bytes);
}

test "in-memory database backups to a persistent zova file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "memory-backup.zova");

    const primary_bytes = "memory backup object bytes";
    const loose_bytes = "memory backup loose chunk";
    const streamed_bytes = try std.testing.allocator.alloc(u8, 140_000);
    defer std.testing.allocator.free(streamed_bytes);
    fillOperationalLargeFixture(streamed_bytes);

    const ids = blk: {
        var memory = try Database.createMemory();
        defer memory.deinit();
        const populated = try populateOperationalFixture(&memory, primary_bytes, streamed_bytes, loose_bytes);
        try memory.backupTo(backup_path, .{});
        break :blk populated;
    };

    try expectOperationalFixture(backup_path, ids, primary_bytes, streamed_bytes, loose_bytes);
}

test "restoreBackupToMemory restores schema and data into volatile memory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "memory-restore-source.zova");

    const primary_bytes = "file backed restore source object";
    const loose_bytes = "file backed restore source chunk";
    const streamed_bytes = try std.testing.allocator.alloc(u8, 140_000);
    defer std.testing.allocator.free(streamed_bytes);
    fillOperationalLargeFixture(streamed_bytes);

    const ids = blk: {
        var file = try Database.create(source_path);
        defer file.deinit();
        break :blk try populateOperationalFixture(&file, primary_bytes, streamed_bytes, loose_bytes);
    };

    var restored = try restoreBackupToMemory(source_path, .{});
    defer restored.deinit();

    try expectOperationalFixtureHandle(&restored, ids, primary_bytes, streamed_bytes, loose_bytes);
}

test "restoreBackupToMemory inlines bound object vector and graph stores with source parity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "memory-bound-restore-main.zova");
    var objects_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const objects_path = try testingDbPath(&objects_buffer, tmp.sub_path[0..], "memory-bound-restore-objects.zova");
    var vectors_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const vectors_path = try testingDbPath(&vectors_buffer, tmp.sub_path[0..], "memory-bound-restore-vectors.zova");
    var graphs_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const graphs_path = try testingDbPath(&graphs_buffer, tmp.sub_path[0..], "memory-bound-restore-graphs.zova");

    try createObjectStore(objects_path);
    try createVectorStore(vectors_path);
    try createGraphStore(graphs_path);

    const object_bytes = "bound object inline restored into memory";
    const loose_bytes = "bound loose chunk inline restored into memory";

    const object_id = blk: {
        var db = try Database.create(main_path);
        defer db.deinit();
        try db.bindObjectStore(objects_path);
        try db.bindVectorStore(vectors_path);
        try db.bindGraphStore(graphs_path);

        const id = try db.putObject(object_bytes);
        const loose_chunk = objectChunkId("bound loose chunk inline restored into memory");
        try db.putObjectChunk(loose_chunk, loose_bytes);

        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVectors("docs", &.{
            .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0 } } },
            .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0 } } },
        });

        try db.createGraph("alpha");
        try db.putGraphNode(.{ .graph_name = "alpha", .node_id = "root", .kind = "document" });
        try db.putGraphNode(.{ .graph_name = "alpha", .node_id = "leaf", .kind = "note" });
        try db.putGraphEdge(.{ .graph_name = "alpha", .from_node_id = "root", .edge_type = "links", .to_node_id = "leaf" });

        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from object_store._zova_objects"));
        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors"));
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from vector_store._zova_vectors"));
        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_graph_nodes"));
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from graph_store._zova_graph_nodes"));
        break :blk id;
    };

    var restored = try restoreBackupToMemory(main_path, .{});
    defer restored.deinit();

    try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try restored.boundObjectStore(std.testing.allocator));
    try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try restored.boundVectorStore(std.testing.allocator));
    try std.testing.expectEqual(@as(?BoundGraphStoreInfo, null), try restored.boundGraphStore(std.testing.allocator));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&restored, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&restored, "select count(*) from _zova_vectors"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&restored, "select count(*) from _zova_graph_nodes"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&restored, "select count(*) from _zova_graph_edges"));

    var object = try restored.getObject(std.testing.allocator, object_id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, object_bytes, object.bytes);

    var chunk = try restored.getObjectChunk(std.testing.allocator, objectChunkId("bound loose chunk inline restored into memory"));
    defer chunk.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, loose_bytes, chunk.bytes);

    var results = try restored.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0 } }, 2);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("doc-a", results.items[0].id);

    var neighbors = try restored.graphNeighbors(std.testing.allocator, .{ .graph_name = "alpha", .node_id = "root", .limit = 10 });
    defer neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), neighbors.items.len);
    try std.testing.expectEqualStrings("leaf", neighbors.items[0].node_id);
}

test "created zova database stores metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "metadata.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    var meta = try raw.prepare("select key, value from _zova_meta order by key");
    defer meta.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings("database_id", meta.columnText(0));
    try std.testing.expect(isValidStoreId(meta.columnText(1)));

    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings("format_version", meta.columnText(0));
    try std.testing.expectEqualStrings(format_version, meta.columnText(1));

    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings("magic", meta.columnText(0));
    try std.testing.expectEqualStrings("zova", meta.columnText(1));

    try std.testing.expectEqual(sqlite.Step.done, try meta.step());
}

test "current format reserves graph store metadata" {
    try std.testing.expectEqualStrings("12", format_version);
    try std.testing.expect(std.mem.indexOf(u8, bound_stores_schema_sql, "'graph_store'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bound_stores_schema_sql, "graph_epoch integer") != null);

    const result: SplitGraphStoreResult = .{
        .store_path = "graph.zova",
        .store_id = @as([64]u8, @splat('0')),
        .bound_set_id = @as([64]u8, @splat('1')),
        .copied = .{},
        .cleared = .{},
        .verified = true,
    };
    try std.testing.expectEqualStrings(bound_graph_store_role, result.role);
}

test "create graph store writes metadata and rejects main database open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-store.zova");

    try createGraphStore(store_path);

    {
        var raw = try sqlite.Database.open(store_path);
        defer raw.deinit();

        try testingExpectScalarText(&raw, "select value from _zova_meta where key = 'magic'", "zova");
        try testingExpectScalarText(&raw, "select value from _zova_meta where key = 'format_version'", format_version);
        try testingExpectScalarText(&raw, "select value from _zova_meta where key = 'store_role'", "graph_store");
        try testingExpectScalarText(&raw, "select value from _zova_meta where key = 'graph_epoch'", "0");

        var store_id = try raw.prepare("select value from _zova_meta where key = 'store_id'");
        defer store_id.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try store_id.step());
        try std.testing.expect(isValidStoreId(store_id.columnText(0)));
        try std.testing.expectEqual(sqlite.Step.done, try store_id.step());
    }

    try std.testing.expectError(error.BoundStoreInvalid, Database.open(store_path));
}

test "bound graph epochs participate in transactions and skip empty batches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-epoch-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-epoch-store.zova");
    try createGraphStore(store_path);
    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindGraphStore(store_path);
    try db.createGraph("deps");
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));
    try db.putGraphNodes(&.{});
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));

    try db.begin();
    try db.putGraphNode(.{ .graph_name = "deps", .node_id = "rolled-back", .kind = "file" });
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select cast(value as integer) from graph_store._zova_meta where key = 'graph_epoch'"));
    try db.rollback();
    try std.testing.expect(!(try db.hasGraphNode("deps", "rolled-back")));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select cast(value as integer) from graph_store._zova_meta where key = 'graph_epoch'"));

    try db.savepoint("graph_epoch_rollback");
    try db.putGraphNode(.{ .graph_name = "deps", .node_id = "savepoint-rolled-back", .kind = "file" });
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select cast(value as integer) from graph_store._zova_meta where key = 'graph_epoch'"));
    try db.rollbackToSavepoint("graph_epoch_rollback");
    try db.releaseSavepoint("graph_epoch_rollback");
    try std.testing.expect(!(try db.hasGraphNode("deps", "savepoint-rolled-back")));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select graph_epoch from _zova_bound_stores where role = 'graph_store'"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select cast(value as integer) from graph_store._zova_meta where key = 'graph_epoch'"));
}

test "unbound graph node batch rolls back earlier writes when a later write fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "graph-unbound-batch-rollback.zova");
    var db = try Database.create(db_path);
    defer db.deinit();
    try db.createGraph("deps");
    try db.exec(
        \\create trigger reject_second_graph_node before insert on _zova_graph_nodes
        \\when new.node_id = 'second' begin select raise(abort, 'reject second'); end;
    );
    try std.testing.expectError(error.Constraint, db.putGraphNodes(&.{
        .{ .graph_name = "deps", .node_id = "first", .kind = "file" },
        .{ .graph_name = "deps", .node_id = "second", .kind = "file" },
    }));
    try std.testing.expect(!(try db.hasGraphNode("deps", "first")));
}

test "read only graph store management rejects bind replacement and unbind without state changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var empty_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const empty_path = try testingDbPath(&empty_buffer, tmp.sub_path[0..], "graph-read-only-empty.zova");
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-read-only-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-read-only-store.zova");
    var replacement_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const replacement_path = try testingDbPath(&replacement_buffer, tmp.sub_path[0..], "graph-read-only-replacement.zova");
    try createGraphStore(store_path);
    try createGraphStore(replacement_path);
    {
        var empty = try Database.create(empty_path);
        empty.deinit();
    }
    {
        var db = try Database.create(main_path);
        defer db.deinit();
        try db.bindGraphStore(store_path);
        try db.createGraph("visible");
    }
    {
        var empty = try Database.openWithOptions(empty_path, .{ .read_only = true });
        defer empty.deinit();
        try std.testing.expectError(error.ReadOnly, empty.bindGraphStore(store_path));
        try std.testing.expectEqual(@as(?BoundGraphStoreInfo, null), try empty.boundGraphStore(std.testing.allocator));
    }
    {
        var read_only = try Database.openWithOptions(main_path, .{ .read_only = true });
        defer read_only.deinit();
        var before = (try read_only.boundGraphStore(std.testing.allocator)).?;
        defer before.deinit(std.testing.allocator);
        try std.testing.expectError(error.ReadOnly, read_only.bindGraphStore(replacement_path));
        try std.testing.expectError(error.ReadOnly, read_only.unbindGraphStore());
        var after = (try read_only.boundGraphStore(std.testing.allocator)).?;
        defer after.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(before.path, after.path);
        try std.testing.expectEqualStrings(before.bound_set_id, after.bound_set_id);
        try std.testing.expect(try read_only.hasGraph("visible"));
    }
}

test "open validates configured graph store identity role and format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-open-validation-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-open-validation-store.zova");
    try createGraphStore(store_path);
    var expected_store_id: [64]u8 = undefined;
    var expected_bound_set_id: [64]u8 = undefined;
    {
        var db = try Database.create(main_path);
        defer db.deinit();
        try db.bindGraphStore(store_path);
        var info = (try db.boundGraphStore(std.testing.allocator)).?;
        defer info.deinit(std.testing.allocator);
        @memcpy(expected_store_id[0..], info.store_id);
        @memcpy(expected_bound_set_id[0..], info.bound_set_id);
    }
    {
        var raw = try sqlite.Database.open(main_path);
        defer raw.deinit();
        try raw.exec("update _zova_bound_stores set store_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' where role = 'graph_store'");
    }
    try std.testing.expectError(error.BoundStoreInvalid, Database.open(main_path));
    {
        var raw = try sqlite.Database.open(main_path);
        defer raw.deinit();
        var stmt = try raw.prepare("update _zova_bound_stores set store_id = ?, bound_set_id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' where role = 'graph_store'");
        defer stmt.deinit();
        try stmt.bindText(1, &expected_store_id);
        try stmt.expectDone();
    }
    try std.testing.expectError(error.BoundStoreInvalid, Database.open(main_path));
    {
        var raw = try sqlite.Database.open(main_path);
        defer raw.deinit();
        var stmt = try raw.prepare("update _zova_bound_stores set bound_set_id = ? where role = 'graph_store'");
        defer stmt.deinit();
        try stmt.bindText(1, &expected_bound_set_id);
        try stmt.expectDone();
    }
    {
        var raw = try sqlite.Database.open(store_path);
        defer raw.deinit();
        try raw.exec("update _zova_meta set value = 'vector_store' where key = 'store_role'");
    }
    try std.testing.expectError(error.NotZovaDatabase, Database.open(main_path));
    {
        var raw = try sqlite.Database.open(store_path);
        defer raw.deinit();
        try raw.exec("update _zova_meta set value = 'graph_store' where key = 'store_role'; update _zova_meta set value = '6' where key = 'format_version'");
    }
    try std.testing.expectError(error.UnsupportedZovaVersion, Database.open(main_path));
}

test "configured graph store attaches routes graph APIs and reopens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-store.zova");

    try createGraphStore(store_path);
    {
        var db = try Database.create(main_path);
        defer db.deinit();

        try ensureBoundStoreTable(&db.sqlite_db);
        try attachStore(&db.sqlite_db, .graph, store_path, false);
        defer db.sqlite_db.detachDatabase(bound_graph_store_schema_name) catch {};

        const store_id = try validateAttachedGraphStoreAlloc(std.testing.allocator, &db.sqlite_db, bound_graph_store_schema_name);
        defer std.testing.allocator.free(store_id);
        var bound_set_id: [64]u8 = undefined;
        randomHex64(&bound_set_id);
        try setAttachedMetadataValue(&db.sqlite_db, bound_graph_store_schema_name, "bound_set_id", &bound_set_id);

        var insert = try db.sqlite_db.prepare(
            \\insert into _zova_bound_stores
            \\  (role, name, path, store_id, bound_set_id, object_epoch, vector_epoch, graph_epoch, created_at_unix)
            \\values ('graph_store', 'default', ?, ?, ?, null, null, 0, unixepoch())
        );
        defer insert.deinit();
        try insert.bindText(1, store_path);
        try insert.bindText(2, store_id);
        try insert.bindText(3, &bound_set_id);
        try std.testing.expectEqual(sqlite.Step.done, try insert.step());
    }

    {
        var db = try Database.open(main_path);
        defer db.deinit();
        try db.createGraph("deps");
        try db.putGraphNode(.{ .graph_name = "deps", .node_id = "a", .kind = "file" });
        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from main._zova_graphs"));
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from graph_store._zova_graphs"));
    }

    {
        var reopened = try Database.open(main_path);
        defer reopened.deinit();
        try std.testing.expect(try reopened.hasGraph("deps"));
        try std.testing.expect(try reopened.hasGraphNode("deps", "a"));
    }

    {
        var raw = try sqlite.Database.open(main_path);
        defer raw.deinit();
        try raw.exec("update _zova_bound_stores set graph_epoch = 1 where role = 'graph_store' and name = 'default'");
    }
    try std.testing.expectError(error.BoundStoreInvalid, Database.open(main_path));
}

test "created zova database stores required extension registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extensions-registry.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();

        var extensions = try db.listExtensions(std.testing.allocator);
        defer extensions.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), extensions.items.len);
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try std.testing.expect(try tableExists(&raw, "_zova_extensions"));
}

test "app registered extension installs checks registers sql and drops" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "registered-extension.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});

    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();

        try db.installExtension("test");

        var info = try db.extensionInfo(std.testing.allocator, "test");
        defer info.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("test", info.name);
        try std.testing.expectEqualStrings("0.1.0", info.version);
        try std.testing.expectEqualStrings("_zova_ext_test_", info.storage_prefix);

        try db.checkExtension("test");

        var scalar = try db.prepare("select zova_test_extension_value()");
        defer scalar.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
        try std.testing.expectEqual(@as(i64, 7), scalar.columnInt64(0));

        try std.testing.expect(try tableExists(&db.sqlite_db, "_zova_ext_test_meta"));
    }

    {
        var db = try Database.openWithExtensions(db_path, registry);
        defer db.deinit();
        try db.checkExtension("test");
        try db.dropExtension("test");
        try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_test_meta"));
        try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "test"));
    }
}

test "multiple app registered extensions register sql on one connection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "registered-extension-sql-multiple.zova");

    const registry = ExtensionRegistry.init(&.{ testExtension(), secondSqlExtension() });

    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();

        try db.installExtension("test");
        try db.installExtension("test_two");

        var scalar = try db.prepare("select zova_test_extension_value(), zova_test_extension_two_value()");
        defer scalar.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
        try std.testing.expectEqual(@as(i64, 7), scalar.columnInt64(0));
        try std.testing.expectEqual(@as(i64, 42), scalar.columnInt64(1));
    }

    {
        var db = try Database.openWithExtensions(db_path, registry);
        defer db.deinit();

        try db.checkExtension("test");
        try db.checkExtension("test_two");

        var scalar = try db.prepare("select zova_test_extension_value(), zova_test_extension_two_value()");
        defer scalar.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
        try std.testing.expectEqual(@as(i64, 7), scalar.columnInt64(0));
        try std.testing.expectEqual(@as(i64, 42), scalar.columnInt64(1));
    }
}

test "read only open registers extension sql and checks installed extension" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "registered-extension-read-only.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});
    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();
        try db.installExtension("test");
    }

    var db = try Database.openWithOptionsAndExtensions(db_path, .{ .read_only = true }, registry);
    defer db.deinit();

    try db.checkExtension("test");

    var scalar = try db.prepare("select zova_test_extension_value()");
    defer scalar.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
    try std.testing.expectEqual(@as(i64, 7), scalar.columnInt64(0));

    try std.testing.expectError(error.ReadOnly, db.exec("create table read_only_extension_write_blocked (id integer)"));
}

test "open with missing registered extension code fails clearly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-extension.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});
    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();
        try db.installExtension("test");
    }

    try std.testing.expectError(error.ExtensionUnavailable, Database.open(db_path));
}

test "extension inspection opens missing-code databases for metadata only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extension-inspection.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});
    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();
        try db.installExtension("test");
    }

    try std.testing.expectError(error.ExtensionUnavailable, Database.open(db_path));

    var inspected = try Database.openForExtensionInspection(db_path, .{});
    defer inspected.deinit();
    var extensions = try inspected.listExtensions(std.testing.allocator);
    defer extensions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), extensions.items.len);
    try std.testing.expectEqualStrings("test", extensions.items[0].name);
    try std.testing.expectError(error.ExtensionUnavailable, inspected.checkExtension("test"));
    try std.testing.expectError(error.ReadOnly, inspected.exec("create table inspection_write_blocked (id integer)"));
}

test "extension inspection diagnostics can run SQL-backed check hooks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extension-inspection-sql.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});
    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();
        try db.installExtension("test");
    }

    var inspected = try Database.openForExtensionInspectionWithExtensions(db_path, .{}, registry);
    defer inspected.deinit();
    try inspected.registerExtensionSqlForDiagnostics("test");
    try inspected.checkExtension("test");
}

test "extension registry is used for backup compact and restore verification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var restore_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "extension-copy-source.zova");
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "extension-copy-backup.zova");
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "extension-copy-compact.zova");
    const restore_path = try testingDbPath(&restore_buffer, tmp.sub_path[0..], "extension-copy-restore.zova");

    const registry = ExtensionRegistry.init(&.{testExtension()});

    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();
        try db.installExtension("test");

        try db.backupTo(backup_path, .{});
        try db.compactTo(compact_path, .{});
    }

    try restoreBackupWithExtensions(backup_path, restore_path, .{}, registry);

    for ([_][:0]const u8{ backup_path, compact_path, restore_path }) |copy_path| {
        var copy = try Database.openWithExtensions(copy_path, registry);
        defer copy.deinit();
        try copy.checkExtension("test");

        var scalar = try copy.prepare("select zova_test_extension_value()");
        defer scalar.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
        try std.testing.expectEqual(@as(i64, 7), scalar.columnInt64(0));
    }
}

test "extension manifests validate names prefixes and duplicate registry prefixes" {
    try extension_impl.validateManifest(.{
        .name = "compatible_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_compatible_abi_",
        .zova_abi_min = "1.0.0",
    });
    try extension_impl.validateManifest(.{
        .name = "current_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_current_abi_",
        .zova_abi_min = "1.0.0",
    });
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "malformed_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_malformed_abi_",
        .zova_abi_min = "0.23",
    }));
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "prefixed_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_prefixed_abi_",
        .zova_abi_min = "v0.23.0",
    }));
    var newer_abi_buffer: [32]u8 = undefined;
    const newer_abi = try std.fmt.bufPrint(&newer_abi_buffer, "{d}.{d}.0", .{
        version.abi_version_major,
        version.abi_version_minor + 1,
    });
    try std.testing.expectError(error.ExtensionIncompatible, extension_impl.validateManifest(.{
        .name = "newer_minor_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_newer_minor_abi_",
        .zova_abi_min = newer_abi,
    }));
    try std.testing.expectError(error.ExtensionIncompatible, extension_impl.validateManifest(.{
        .name = "different_major_abi",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_different_major_abi_",
        .zova_abi_min = "2.0.0",
    }));

    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext__",
        .zova_abi_min = "1.0.0",
    }));
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "_zova_hidden",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext__zova_hidden_",
        .zova_abi_min = "1.0.0",
    }));
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "bad name",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_bad name_",
        .zova_abi_min = "1.0.0",
    }));
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "test",
        .version = "0.1.0",
        .storage_prefix = "_zova_objects",
        .zova_abi_min = "1.0.0",
    }));
    try std.testing.expectError(error.ExtensionInvalid, extension_impl.validateManifest(.{
        .name = "optional",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_optional_",
        .zova_abi_min = "1.0.0",
        .required = false,
    }));

    const duplicate_one = testExtension();
    const duplicate_name = Extension{
        .manifest = .{
            .name = "test",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_test_two_",
            .zova_abi_min = "1.0.0",
        },
        .install = testExtensionInstall,
        .check = testExtensionCheck,
        .drop = testExtensionDrop,
    };
    try std.testing.expectError(error.ExtensionInvalid, ExtensionRegistry.init(&.{ duplicate_one, duplicate_name }).validate());

    const duplicate_two = Extension{
        .manifest = .{
            .name = "other",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_test_",
            .zova_abi_min = "1.0.0",
        },
        .install = testExtensionInstall,
        .check = testExtensionCheck,
        .drop = testExtensionDrop,
    };
    try std.testing.expectError(error.ExtensionInvalid, ExtensionRegistry.init(&.{ duplicate_one, duplicate_two }).validate());
}

test "extension registry rejects bundled trgm collisions before create or open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const trgm_collision = Extension{
        .manifest = .{
            .name = "trgm",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_trgm_",
            .zova_abi_min = "1.0.0",
        },
        .install = testExtensionInstall,
        .check = testExtensionCheck,
        .drop = testExtensionDrop,
    };
    const registry = ExtensionRegistry.init(&.{ bundled_extensions[0], trgm_collision });
    try std.testing.expectError(error.ExtensionInvalid, registry.validate());

    var create_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const create_path = try testingDbPath(&create_buffer, tmp.sub_path[0..], "extension-trgm-collision-create.zova");
    try std.testing.expectError(error.ExtensionInvalid, Database.createWithExtensions(create_path, registry));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(defaultIo(), create_path, .{}));

    var open_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const open_path = try testingDbPath(&open_buffer, tmp.sub_path[0..], "extension-trgm-collision-open.zova");
    {
        var db = try Database.create(open_path);
        defer db.deinit();
    }
    try std.testing.expectError(error.ExtensionInvalid, Database.openWithExtensions(open_path, registry));
}

test "extension duplicate install and failed hooks roll back cleanly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extension-rollback.zova");

    const registry = ExtensionRegistry.init(&.{ testExtension(), failingExtension(), registerFailingExtension() });
    var db = try Database.createWithExtensions(db_path, registry);
    defer db.deinit();

    try db.installExtension("test");
    try std.testing.expectError(error.ExtensionExists, db.installExtension("test"));

    try std.testing.expectError(error.ExtensionInvalid, db.installExtension("failing"));
    try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "failing"));
    try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_failing_meta"));

    try std.testing.expectError(error.ExtensionInvalid, db.installExtension("register_fail"));
    try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "register_fail"));
    try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_register_fail_meta"));
}

test "register_sql failure during open fails without mutating installed metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "extension-register-open-fail.zova");

    const registry = ExtensionRegistry.init(&.{reopenRegisterFailExtension()});
    {
        var db = try Database.createWithExtensions(db_path, registry);
        defer db.deinit();

        try db.installExtension("reopen_fail");
        var scalar = try db.prepare("select zova_reopen_fail_value()");
        defer scalar.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try scalar.step());
        try std.testing.expectEqual(@as(i64, 13), scalar.columnInt64(0));
    }

    try std.testing.expectError(error.ExtensionInvalid, Database.openWithExtensions(db_path, registry));

    var inspected = try Database.openForExtensionInspectionWithExtensions(db_path, .{}, registry);
    defer inspected.deinit();

    var extensions = try inspected.listExtensions(std.testing.allocator);
    defer extensions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), extensions.items.len);
    try std.testing.expectEqualStrings("reopen_fail", extensions.items[0].name);

    var mode = try inspected.prepare("select value from _zova_ext_reopen_fail_meta where key = 'mode'");
    defer mode.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try mode.step());
    try std.testing.expectEqualStrings("fail", mode.columnText(0));
}

test "extension lifecycle audits namespace and drop cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var escape_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const escape_path = try testingDbPath(&escape_buffer, tmp.sub_path[0..], "extension-escape.zova");

    {
        const registry = ExtensionRegistry.init(&.{escapingExtension()});
        var db = try Database.createWithExtensions(escape_path, registry);
        defer db.deinit();

        try std.testing.expectError(error.ExtensionInvalid, db.installExtension("escape"));
        try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "escape"));
        try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_escape_meta"));
        try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_other_meta"));
    }

    var leaky_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const leaky_path = try testingDbPath(&leaky_buffer, tmp.sub_path[0..], "extension-leaky.zova");

    {
        const registry = ExtensionRegistry.init(&.{leakyDropExtension()});
        var db = try Database.createWithExtensions(leaky_path, registry);
        defer db.deinit();

        try db.installExtension("leaky");
        try std.testing.expect(try tableExists(&db.sqlite_db, "_zova_ext_leaky_meta"));
        try std.testing.expectError(error.ExtensionInvalid, db.dropExtension("leaky"));

        var info = try db.extensionInfo(std.testing.allocator, "leaky");
        defer info.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("leaky", info.name);
        try std.testing.expect(try tableExists(&db.sqlite_db, "_zova_ext_leaky_meta"));
    }

    var cross_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cross_path = try testingDbPath(&cross_buffer, tmp.sub_path[0..], "extension-cross-namespace.zova");

    {
        const registry = ExtensionRegistry.init(&.{ testExtension(), crossNamespaceExtension() });
        var db = try Database.createWithExtensions(cross_path, registry);
        defer db.deinit();

        try db.installExtension("test");
        try std.testing.expectError(error.ExtensionInvalid, db.installExtension("cross"));
        try std.testing.expectError(error.ExtensionNotFound, db.extensionInfo(std.testing.allocator, "cross"));
        try std.testing.expect(!try tableExists(&db.sqlite_db, "_zova_ext_test_cross_meta"));
    }
}

test "extension salvage hook copies namespaced storage and installs destination metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "extension-salvage-source.zova");
    const destination_path = try testingDbPath(&destination_buffer, tmp.sub_path[0..], "extension-salvage-destination.zova");

    const registry = ExtensionRegistry.init(&.{salvageExtension()});
    var source = try Database.createWithExtensions(source_path, registry);
    defer source.deinit();
    try source.installExtension("salvage");

    var destination = try Database.createWithExtensions(destination_path, registry);
    defer destination.deinit();

    const result = try extension_impl.salvageInstalled(std.testing.allocator, &source.sqlite_db, &destination.sqlite_db, registry, .copy);
    try std.testing.expectEqual(@as(u64, 1), result.copied_extensions);
    try std.testing.expectEqual(@as(u64, 1), result.copied_private_objects);
    try std.testing.expectEqual(@as(u64, 0), result.skipped_extensions);
    try std.testing.expectEqual(@as(u64, 0), result.skipped_private_objects);
    try std.testing.expect(result.installed_in_destination);

    try std.testing.expect(try tableExists(&destination.sqlite_db, "_zova_ext_salvage_meta"));
    var info = try destination.extensionInfo(std.testing.allocator, "salvage");
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("salvage", info.name);
    try destination.checkExtension("salvage");
}

test "extension salvage hook rolls back storage outside its namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var destination_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "extension-salvage-bad-source.zova");
    const destination_path = try testingDbPath(&destination_buffer, tmp.sub_path[0..], "extension-salvage-bad-destination.zova");

    const registry = ExtensionRegistry.init(&.{badSalvageExtension()});
    var source = try Database.createWithExtensions(source_path, registry);
    defer source.deinit();
    try source.installExtension("bad_salvage");

    var destination = try Database.createWithExtensions(destination_path, registry);
    defer destination.deinit();

    try std.testing.expectError(error.ExtensionInvalid, extension_impl.salvageInstalled(std.testing.allocator, &source.sqlite_db, &destination.sqlite_db, registry, .copy));
    try std.testing.expect(!try tableExists(&destination.sqlite_db, "_zova_ext_other_salvage_meta"));
    try std.testing.expectError(error.ExtensionNotFound, destination.extensionInfo(std.testing.allocator, "bad_salvage"));
}

fn testExtension() Extension {
    return .{
        .manifest = .{
            .name = "test",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_test_",
            .zova_abi_min = "1.0.0",
            .capabilities = "sql",
        },
        .install = testExtensionInstall,
        .check = testExtensionCheck,
        .drop = testExtensionDrop,
        .register_sql = testExtensionRegisterSql,
    };
}

fn salvageExtension() Extension {
    return .{
        .manifest = .{
            .name = "salvage",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_salvage_",
            .zova_abi_min = "1.0.0",
        },
        .install = salvageExtensionInstall,
        .check = salvageExtensionCheck,
        .drop = salvageExtensionDrop,
        .salvage = salvageExtensionSalvage,
    };
}

fn badSalvageExtension() Extension {
    return .{
        .manifest = .{
            .name = "bad_salvage",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_bad_salvage_",
            .zova_abi_min = "1.0.0",
        },
        .install = badSalvageExtensionInstall,
        .check = badSalvageExtensionCheck,
        .drop = badSalvageExtensionDrop,
        .salvage = badSalvageExtensionSalvage,
    };
}

fn failingExtension() Extension {
    return .{
        .manifest = .{
            .name = "failing",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_failing_",
            .zova_abi_min = "1.0.0",
        },
        .install = failingExtensionInstall,
        .check = testExtensionCheck,
        .drop = testExtensionDrop,
    };
}

fn registerFailingExtension() Extension {
    return .{
        .manifest = .{
            .name = "register_fail",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_register_fail_",
            .zova_abi_min = "1.0.0",
        },
        .install = registerFailingExtensionInstall,
        .check = registerFailingExtensionCheck,
        .drop = registerFailingExtensionDrop,
        .register_sql = registerFailingExtensionRegisterSql,
    };
}

fn reopenRegisterFailExtension() Extension {
    return .{
        .manifest = .{
            .name = "reopen_fail",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_reopen_fail_",
            .zova_abi_min = "1.0.0",
        },
        .install = reopenRegisterFailExtensionInstall,
        .check = reopenRegisterFailExtensionCheck,
        .drop = reopenRegisterFailExtensionDrop,
        .register_sql = reopenRegisterFailExtensionRegisterSql,
    };
}

fn secondSqlExtension() Extension {
    return .{
        .manifest = .{
            .name = "test_two",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_test_two_",
            .zova_abi_min = "1.0.0",
            .capabilities = "sql",
        },
        .install = secondSqlExtensionInstall,
        .check = secondSqlExtensionCheck,
        .drop = secondSqlExtensionDrop,
        .register_sql = secondSqlExtensionRegisterSql,
    };
}

fn escapingExtension() Extension {
    return .{
        .manifest = .{
            .name = "escape",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_escape_",
            .zova_abi_min = "1.0.0",
        },
        .install = escapingExtensionInstall,
        .check = escapingExtensionCheck,
        .drop = escapingExtensionDrop,
    };
}

fn leakyDropExtension() Extension {
    return .{
        .manifest = .{
            .name = "leaky",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_leaky_",
            .zova_abi_min = "1.0.0",
        },
        .install = leakyDropExtensionInstall,
        .check = leakyDropExtensionCheck,
        .drop = leakyDropExtensionDrop,
    };
}

fn crossNamespaceExtension() Extension {
    return .{
        .manifest = .{
            .name = "cross",
            .version = "0.1.0",
            .storage_prefix = "_zova_ext_cross_",
            .zova_abi_min = "1.0.0",
        },
        .install = crossNamespaceExtensionInstall,
        .check = crossNamespaceExtensionCheck,
        .drop = crossNamespaceExtensionDrop,
    };
}

fn testExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec(
        \\create table _zova_ext_test_meta (
        \\  key text primary key,
        \\  value text not null
        \\)
    );
    var stmt = try db.prepare("insert into _zova_ext_test_meta (key, value) values ('installed', ?)");
    defer stmt.deinit();
    try stmt.bindText(1, manifest.version);
    try stmt.expectDone();
}

fn testExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    var stmt = try db.prepare("select value from _zova_ext_test_meta where key = 'installed'");
    defer stmt.deinit();
    switch (try stmt.step()) {
        .row => {
            if (!std.mem.eql(u8, stmt.columnText(0), manifest.version)) return error.ExtensionInvalid;
        },
        .done => return error.ExtensionInvalid,
    }

    var scalar = try db.prepare("select zova_test_extension_value()");
    defer scalar.deinit();
    if ((try scalar.step()) != .row) return error.ExtensionInvalid;
    if (scalar.columnInt64(0) != 7) return error.ExtensionInvalid;
}

fn testExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table _zova_ext_test_meta");
}

fn testExtensionRegisterSql(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    const rc = sqlite.c.sqlite3_create_function_v2(
        db.handle,
        "zova_test_extension_value",
        0,
        sqlite.c.SQLITE_UTF8,
        null,
        testExtensionValueFunc,
        null,
        null,
        null,
    );
    if (rc != sqlite.c.SQLITE_OK) return error.SqliteError;
}

fn salvageExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_salvage_meta (key text primary key, value text not null)");
    var stmt = try db.prepare("insert into _zova_ext_salvage_meta (key, value) values ('installed', ?)");
    defer stmt.deinit();
    try stmt.bindText(1, manifest.version);
    try stmt.expectDone();
}

fn salvageExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    var stmt = try db.prepare("select value from _zova_ext_salvage_meta where key = 'installed'");
    defer stmt.deinit();
    switch (try stmt.step()) {
        .row => if (!std.mem.eql(u8, stmt.columnText(0), manifest.version)) return error.ExtensionInvalid,
        .done => return error.ExtensionInvalid,
    }
}

fn salvageExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table if exists _zova_ext_salvage_meta");
}

fn salvageExtensionSalvage(context: extension_impl.SalvageContext, manifest: ExtensionManifest) extension_impl.Error!extension_impl.SalvageResult {
    try extension_impl.validateManifest(manifest);
    _ = context.source;
    if (context.mode == .plan) {
        return .{ .copied_extensions = 1, .copied_private_objects = 1 };
    }
    const destination = context.destination orelse return error.ExtensionInvalid;
    try destination.exec("create table _zova_ext_salvage_meta (key text primary key, value text not null)");
    var stmt = try destination.prepare("insert into _zova_ext_salvage_meta (key, value) values ('installed', ?)");
    defer stmt.deinit();
    try stmt.bindText(1, manifest.version);
    try stmt.expectDone();
    return .{ .copied_extensions = 1, .copied_private_objects = 1, .installed_in_destination = true };
}

fn badSalvageExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_bad_salvage_meta (key text primary key, value text not null)");
}

fn badSalvageExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn badSalvageExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table if exists _zova_ext_bad_salvage_meta");
}

fn badSalvageExtensionSalvage(context: extension_impl.SalvageContext, manifest: ExtensionManifest) extension_impl.Error!extension_impl.SalvageResult {
    try extension_impl.validateManifest(manifest);
    const destination = context.destination orelse return error.ExtensionInvalid;
    try destination.exec("create table _zova_ext_other_salvage_meta (key text primary key, value text not null)");
    return .{ .copied_extensions = 1, .copied_private_objects = 1, .installed_in_destination = true };
}

fn failingExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_failing_meta (key text primary key, value text not null)");
    return error.ExtensionInvalid;
}

fn registerFailingExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_register_fail_meta (key text primary key, value text not null)");
}

fn registerFailingExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn registerFailingExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table _zova_ext_register_fail_meta");
}

fn registerFailingExtensionRegisterSql(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
    return error.ExtensionInvalid;
}

fn reopenRegisterFailExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_reopen_fail_meta (key text primary key, value text not null)");
    try db.exec("insert into _zova_ext_reopen_fail_meta (key, value) values ('mode', 'install')");
}

fn reopenRegisterFailExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    var stmt = try db.prepare("select value from _zova_ext_reopen_fail_meta where key = 'mode'");
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.ExtensionInvalid;
}

fn reopenRegisterFailExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table _zova_ext_reopen_fail_meta");
}

fn reopenRegisterFailExtensionRegisterSql(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    var mode = try db.prepare("select value from _zova_ext_reopen_fail_meta where key = 'mode'");
    defer mode.deinit();
    if ((try mode.step()) != .row) return error.ExtensionInvalid;
    if (std.mem.eql(u8, mode.columnText(0), "fail")) return error.ExtensionInvalid;

    const rc = sqlite.c.sqlite3_create_function_v2(
        db.handle,
        "zova_reopen_fail_value",
        0,
        sqlite.c.SQLITE_UTF8,
        null,
        reopenFailValueFunc,
        null,
        null,
        null,
    );
    if (rc != sqlite.c.SQLITE_OK) return error.SqliteError;
    try db.exec("update _zova_ext_reopen_fail_meta set value = 'fail' where key = 'mode'");
}

fn secondSqlExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_test_two_meta (key text primary key, value text not null)");
    var stmt = try db.prepare("insert into _zova_ext_test_two_meta (key, value) values ('installed', ?)");
    defer stmt.deinit();
    try stmt.bindText(1, manifest.version);
    try stmt.expectDone();
}

fn secondSqlExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    var stmt = try db.prepare("select value from _zova_ext_test_two_meta where key = 'installed'");
    defer stmt.deinit();
    switch (try stmt.step()) {
        .row => if (!std.mem.eql(u8, stmt.columnText(0), manifest.version)) return error.ExtensionInvalid,
        .done => return error.ExtensionInvalid,
    }

    var scalar = try db.prepare("select zova_test_extension_two_value()");
    defer scalar.deinit();
    if ((try scalar.step()) != .row) return error.ExtensionInvalid;
    if (scalar.columnInt64(0) != 42) return error.ExtensionInvalid;
}

fn secondSqlExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table _zova_ext_test_two_meta");
}

fn secondSqlExtensionRegisterSql(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    const rc = sqlite.c.sqlite3_create_function_v2(
        db.handle,
        "zova_test_extension_two_value",
        0,
        sqlite.c.SQLITE_UTF8,
        null,
        secondSqlExtensionValueFunc,
        null,
        null,
        null,
    );
    if (rc != sqlite.c.SQLITE_OK) return error.SqliteError;
}

fn escapingExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_escape_meta (key text primary key, value text not null)");
    try db.exec("create table _zova_ext_other_meta (key text primary key, value text not null)");
}

fn escapingExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn escapingExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table if exists _zova_ext_escape_meta");
    try db.exec("drop table if exists _zova_ext_other_meta");
}

fn leakyDropExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_leaky_meta (key text primary key, value text not null)");
}

fn leakyDropExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn leakyDropExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn crossNamespaceExtensionInstall(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("create table _zova_ext_test_cross_meta (key text primary key, value text not null)");
}

fn crossNamespaceExtensionCheck(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    _ = db;
}

fn crossNamespaceExtensionDrop(db: *sqlite.Database, manifest: ExtensionManifest) extension_impl.Error!void {
    try extension_impl.validateManifest(manifest);
    try db.exec("drop table if exists _zova_ext_test_cross_meta");
}

fn testExtensionValueFunc(ctx: ?*sqlite.c.sqlite3_context, argc: c_int, argv: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    _ = argv;
    if (argc != 0) return;
    sqlite.c.sqlite3_result_int64(ctx, 7);
}

fn reopenFailValueFunc(ctx: ?*sqlite.c.sqlite3_context, argc: c_int, argv: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    _ = argv;
    if (argc != 0) return;
    sqlite.c.sqlite3_result_int64(ctx, 13);
}

fn secondSqlExtensionValueFunc(ctx: ?*sqlite.c.sqlite3_context, argc: c_int, argv: [*c]?*sqlite.c.sqlite3_value) callconv(.c) void {
    _ = argv;
    if (argc != 0) return;
    sqlite.c.sqlite3_result_int64(ctx, 42);
}

test "open rejects wrong magic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "wrong-magic.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try raw.exec(
            \\create table _zova_meta (key text primary key, value text not null);
            \\insert into _zova_meta (key, value) values ('magic', 'not-zova');
            \\insert into _zova_meta (key, value) values ('format_version', '4');
        );
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "open rejects old format version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "old-format.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "7");
    }

    try std.testing.expectError(error.UnsupportedLegacyFormat, Database.open(db_path));
}

fn testingFileSha256(path: []const u8) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn testingCopySqliteFile(source_path: [:0]const u8, destination_path: [:0]const u8) !void {
    var source = try sqlite.Database.openWithFlags(source_path, .read_only);
    defer source.deinit();
    var destination = try sqlite.Database.open(destination_path);
    defer destination.deinit();
    try backupMainDatabase(&source, &destination);
}

test "older main graph and vector fixtures are rejected without mutation" {
    const fixtures = .{
        .{ .path = "tests/fixtures/empty-format-7.zova", .role = StorageRole.main, .open_error = error.UnsupportedLegacyFormat },
        .{ .path = "tests/fixtures/empty-graph-store-format-7.zova", .role = StorageRole.graph },
        .{ .path = "tests/fixtures/empty-vector-store-format-7.zova", .role = StorageRole.vector },
        .{ .path = "tests/fixtures/format-8.zova", .role = StorageRole.main, .open_error = error.UnsupportedLegacyFormat },
        .{ .path = "tests/fixtures/empty-graph-store-format-8.zova", .role = StorageRole.graph },
        .{ .path = "tests/fixtures/empty-vector-store-format-8.zova", .role = StorageRole.vector },
        .{ .path = "tests/fixtures/format-9.zova", .role = StorageRole.main, .open_error = error.MigrationRequired },
        .{ .path = "tests/fixtures/empty-graph-store-format-9.zova", .role = StorageRole.graph },
        .{ .path = "tests/fixtures/empty-vector-store-format-9.zova", .role = StorageRole.vector },
        .{ .path = "tests/fixtures/format-10.zova", .role = StorageRole.main, .open_error = error.MigrationRequired },
        .{ .path = "tests/fixtures/bound-main-format-10.objects.zova", .role = StorageRole.object },
        .{ .path = "tests/fixtures/empty-graph-store-format-10.zova", .role = StorageRole.graph },
        .{ .path = "tests/fixtures/empty-vector-store-format-10.zova", .role = StorageRole.vector },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (fixtures, 0..) |fixture, index| {
        var copy_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const copy_path = try std.fmt.bufPrintSentinel(&copy_buffer, ".zig-cache/tmp/{s}/old-format-copy-{d}.zova", .{ tmp.sub_path[0..], index }, 0);
        try testingCopySqliteFile(fixture.path, copy_path);
        const before = try testingFileSha256(copy_path);

        switch (fixture.role) {
            .main => try std.testing.expectError(fixture.open_error, Database.open(copy_path)),
            .graph => {
                var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const main_path = try std.fmt.bufPrintSentinel(&main_buffer, ".zig-cache/tmp/{s}/format-11-main-graph-{d}.zova", .{ tmp.sub_path[0..], index }, 0);
                var db = try Database.create(main_path);
                defer db.deinit();
                try std.testing.expectError(error.UnsupportedZovaVersion, db.bindGraphStore(copy_path));
            },
            .object => {
                var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const main_path = try std.fmt.bufPrintSentinel(&main_buffer, ".zig-cache/tmp/{s}/format-11-main-object-{d}.zova", .{ tmp.sub_path[0..], index }, 0);
                var db = try Database.create(main_path);
                defer db.deinit();
                try std.testing.expectError(error.UnsupportedZovaVersion, db.bindObjectStore(copy_path));
            },
            .vector => {
                var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const main_path = try std.fmt.bufPrintSentinel(&main_buffer, ".zig-cache/tmp/{s}/format-11-main-vector-{d}.zova", .{ tmp.sub_path[0..], index }, 0);
                var db = try Database.create(main_path);
                defer db.deinit();
                try std.testing.expectError(error.UnsupportedZovaVersion, db.bindVectorStore(copy_path));
            },
        }

        const after = try testingFileSha256(copy_path);
        try std.testing.expectEqualSlices(u8, &before, &after);
    }
}

const StorageRole = enum { main, object, graph, vector };

test "open rejects future format version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "future.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try raw.exec(
            \\create table _zova_meta (key text primary key, value text not null);
            \\insert into _zova_meta (key, value) values ('magic', 'zova');
            \\insert into _zova_meta (key, value) values ('format_version', '13');
        );
    }

    try std.testing.expectError(error.UnsupportedFutureFormat, Database.open(db_path));
}

test "format version classification distinguishes current migratable legacy future and malformed" {
    try std.testing.expectEqual(FormatCompatibility.current, classifyFormatVersion(format_version).?);
    try std.testing.expectEqual(FormatCompatibility.current, classifyFormatVersion("12").?);
    try std.testing.expectEqual(FormatCompatibility.migratable, classifyFormatVersion("11").?);
    try std.testing.expectEqual(FormatCompatibility.migratable, classifyFormatVersion("10").?);
    try std.testing.expectEqual(FormatCompatibility.migratable, classifyFormatVersion("9").?);
    try std.testing.expectEqual(FormatCompatibility.unsupported_legacy, classifyFormatVersion("8").?);
    try std.testing.expectEqual(FormatCompatibility.unsupported_legacy, classifyFormatVersion("7").?);
    try std.testing.expectEqual(FormatCompatibility.unsupported_legacy, classifyFormatVersion("2").?);
    try std.testing.expectEqual(FormatCompatibility.unsupported_future, classifyFormatVersion("13").?);
    try std.testing.expectEqual(FormatCompatibility.unsupported_future, classifyFormatVersion("999").?);

    const malformed = [_][]const u8{
        "",
        "ten",
        "Ten",
        "9x",
        "x9",
        "+9",
        "-1",
        " 10",
        "10 ",
        "4294967296",
        "0x9",
    };
    for (malformed) |value| {
        try std.testing.expectEqual(@as(?FormatCompatibility, null), classifyFormatVersion(value));
    }
}

test "open rejects v0.4 format version two database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "v04-format.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", "2");
        try raw.exec(object_impl.objects_schema_sql ++ ";");
        try raw.exec(object_impl.chunks_schema_sql ++ ";");
        try raw.exec(object_impl.object_chunks_schema_sql ++ ";");
    }

    try std.testing.expectError(error.UnsupportedLegacyFormat, Database.open(db_path));
}

test "created zova database contains required object tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "object-tables.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_objects", 1);
    try testingExpectTableCount(&raw, "_zova_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 1);
}

test "single file remains the default object store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "single-file-default.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try db.boundObjectStore(std.testing.allocator));

    const id = try db.putObject("stored in the main database");
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_objects"));

    var object = try db.getObject(std.testing.allocator, id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "stored in the main database", object.bytes);
}

test "optional bound object store routes object APIs after reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "objects-store.zova");

    try createObjectStore(store_path);

    const id = stored: {
        var db = try Database.create(main_path);
        defer db.deinit();

        try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try db.boundObjectStore(std.testing.allocator));
        try db.bindObjectStore(store_path);

        var info = (try db.boundObjectStore(std.testing.allocator)).?;
        defer info.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.endsWith(u8, info.path, "objects-store.zova"));

        const object_id = try db.putObject("stored outside the main database");
        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from object_store._zova_objects"));
        break :stored object_id;
    };

    {
        var store_raw = try sqlite.Database.open(store_path);
        defer store_raw.deinit();
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&store_raw, "select count(*) from _zova_objects"));
    }

    {
        var reopened = try Database.open(main_path);
        defer reopened.deinit();

        var object = try reopened.getObject(std.testing.allocator, id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "stored outside the main database", object.bytes);

        try reopened.unbindObjectStore();
        try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try reopened.boundObjectStore(std.testing.allocator));
        try std.testing.expectError(error.ObjectNotFound, reopened.getObject(std.testing.allocator, id));

        try reopened.bindObjectStore(store_path);
        var rebound = try reopened.getObject(std.testing.allocator, id);
        defer rebound.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "stored outside the main database", rebound.bytes);
    }

    {
        var read_only = try Database.openWithOptions(main_path, .{ .read_only = true });
        defer read_only.deinit();

        var object = try read_only.getObject(std.testing.allocator, id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "stored outside the main database", object.bytes);
        try std.testing.expectError(error.ReadOnly, read_only.putObject("read-only object write"));
    }
}

test "bound object store initializes and advances consistency markers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-markers-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-markers-store.zova");

    try createObjectStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(store_path);

    var info = (try db.boundObjectStore(std.testing.allocator)).?;
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(isValidStoreId(info.bound_set_id));
    try std.testing.expectEqual(@as(u64, 0), info.object_epoch);
    try testingExpectScalarText(&db.sqlite_db, "select value from object_store._zova_meta where key = 'bound_set_id'", info.bound_set_id);
    try testingExpectScalarText(&db.sqlite_db, "select value from object_store._zova_meta where key = 'object_epoch'", "0");

    _ = try db.putObject("epoch object");
    try expectBoundObjectEpoch(&db, 1);

    var read_object = try db.getObject(std.testing.allocator, objectId("epoch object"));
    read_object.deinit(std.testing.allocator);
    try expectBoundObjectEpoch(&db, 1);

    try db.exec("create table notes (body text)");
    try db.exec("insert into notes (body) values ('raw user sql')");
    try expectBoundObjectEpoch(&db, 1);

    const loose = objectChunkId("epoch chunk");
    try db.putObjectChunk(loose, "epoch chunk");
    try expectBoundObjectEpoch(&db, 2);
    try std.testing.expect(try db.deleteObjectChunk(loose));
    try expectBoundObjectEpoch(&db, 3);
}

test "bound object store marker changes roll back with transactions and savepoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-marker-rollback-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-marker-rollback-store.zova");

    try createObjectStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(store_path);

    try db.beginImmediate();
    _ = try db.putObject("rolled back marker object");
    try expectBoundObjectEpoch(&db, 1);
    try db.rollback();
    try expectBoundObjectEpoch(&db, 0);

    try db.beginImmediate();
    try db.savepoint("sp");
    _ = try db.putObject("savepoint rolled back marker object");
    try expectBoundObjectEpoch(&db, 1);
    try db.rollbackToSavepoint("sp");
    try db.releaseSavepoint("sp");
    try expectBoundObjectEpoch(&db, 0);
    try db.commit();
    try expectBoundObjectEpoch(&db, 0);
}

test "operational copies inline bound object store data into single-file destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-copy-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-copy-objects.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "bound-copy-backup.zova");

    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "bound-copy-compact.zova");

    var restore_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restore_path = try testingDbPath(&restore_buffer, tmp.sub_path[0..], "bound-copy-restore.zova");

    try createObjectStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(store_path);

    const object_id = try db.putObject("bound object copied into one destination file");
    const loose_chunk = objectChunkId("loose chunk copied too");
    try db.putObjectChunk(loose_chunk, "loose chunk copied too");
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from object_store._zova_objects"));

    try db.backupTo(backup_path, .{});
    try db.compactTo(compact_path, .{});
    try restoreBackup(main_path, restore_path, .{});

    const copy_paths = [_][:0]const u8{ backup_path, compact_path, restore_path };
    for (copy_paths) |copy_path| {
        var copy = try Database.open(copy_path);
        defer copy.deinit();

        try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try copy.boundObjectStore(std.testing.allocator));
        try std.testing.expectEqual(@as(i64, 1), try testingCount(&copy, "select count(*) from _zova_objects"));

        var object = try copy.getObject(std.testing.allocator, object_id);
        defer object.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "bound object copied into one destination file", object.bytes);

        var chunk = try copy.getObjectChunk(std.testing.allocator, loose_chunk);
        defer chunk.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, "loose chunk copied too", chunk.bytes);
    }
}

test "split graph store and operational copies preserve graph storage and traversal order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "split-graph-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "split-graph-store.zova");
    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "split-graph-backup.zova");
    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "split-graph-compact.zova");
    var restore_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restore_path = try testingDbPath(&restore_buffer, tmp.sub_path[0..], "split-graph-restore.zova");

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.createGraph("alpha");
    try db.createGraph("beta");
    try db.putGraphNode(.{ .graph_name = "alpha", .node_id = "root", .kind = "document", .target_type = .record, .target_namespace = "docs", .target_ref = "1" });
    try db.putGraphNode(.{ .graph_name = "alpha", .node_id = "object", .kind = "blob", .target_type = .object, .target_ref = "abc" });
    try db.putGraphNode(.{ .graph_name = "alpha", .node_id = "external", .kind = "link", .target_type = .external, .target_namespace = "web", .target_ref = "https://example.test" });
    try db.putGraphNode(.{ .graph_name = "beta", .node_id = "plain", .kind = "note" });
    try db.putGraphEdge(.{ .graph_name = "alpha", .from_node_id = "root", .edge_type = "second", .to_node_id = "external" });
    try db.putGraphEdge(.{ .graph_name = "alpha", .from_node_id = "root", .edge_type = "first", .to_node_id = "object" });
    try db.putGraphEdge(.{ .graph_name = "alpha", .from_node_id = "object", .edge_type = "links", .to_node_id = "external" });

    var before = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "alpha", .node_id = "root", .limit = 10 });
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("external", before.items[0].node_id);
    try std.testing.expectEqualStrings("object", before.items[1].node_id);

    const result = try db.splitGraphStore(store_path);
    try std.testing.expectEqual(@as(u64, 2), result.copied.graphs);
    try std.testing.expectEqual(@as(u64, 4), result.copied.nodes);
    try std.testing.expectEqual(@as(u64, 3), result.copied.edges);
    try std.testing.expectEqual(result.copied, result.cleared);
    try std.testing.expect(result.verified);
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_graphs"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_graph_nodes"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_graph_edges"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&db, "select count(*) from graph_store._zova_graph_nodes"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(&db, "select count(*) from graph_store._zova_graph_edges"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(
        &db,
        "select count(*) from graph_store._zova_graph_nodes n join graph_store._zova_graphs g on g.graph_key=n.graph_key where g.name='alpha' and n.node_id='root' and n.created_order=1",
    ));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(
        &db,
        "select count(*) from graph_store._zova_graph_edges e join graph_store._zova_graphs g on g.graph_key=e.graph_key join graph_store._zova_graph_edge_types et on et.graph_key=e.graph_key and et.edge_type_key=e.edge_type_key where g.name='alpha' and et.name='second' and e.created_order=1",
    ));

    var after = try db.graphNeighbors(std.testing.allocator, .{ .graph_name = "alpha", .node_id = "root", .limit = 10 });
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(before.items[0].node_id, after.items[0].node_id);
    try std.testing.expectEqualStrings(before.items[1].node_id, after.items[1].node_id);
    var object = try db.getGraphNode(std.testing.allocator, "alpha", "object");
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqual(GraphTargetType.object, object.target_type);
    try std.testing.expectEqualStrings("abc", object.target_ref.?);

    try db.backupTo(backup_path, .{});
    try db.compactTo(compact_path, .{});
    try restoreBackup(main_path, restore_path, .{});
    const copy_paths = [_][:0]const u8{ backup_path, compact_path, restore_path };
    for (copy_paths) |copy_path| {
        var copy = try Database.open(copy_path);
        defer copy.deinit();
        try std.testing.expectEqual(@as(?BoundGraphStoreInfo, null), try copy.boundGraphStore(std.testing.allocator));
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&copy, "select count(*) from _zova_graphs"));
        var neighbors = try copy.graphNeighbors(std.testing.allocator, .{ .graph_name = "alpha", .node_id = "root", .limit = 10 });
        defer neighbors.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("external", neighbors.items[0].node_id);
        try std.testing.expectEqualStrings("object", neighbors.items[1].node_id);
    }
}

test "failed graph split removes destination and keeps main graph storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "split-graph-failure-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "split-graph-failure-store.zova");

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.createGraph("broken");
    try db.putGraphNode(.{ .graph_name = "broken", .node_id = "node", .kind = "note" });
    try db.exec("pragma ignore_check_constraints = on");
    try db.exec("update _zova_graph_nodes set target_type = 'invalid' where node_id = 'node'");
    try db.exec("pragma ignore_check_constraints = off");

    try std.testing.expectError(error.Constraint, db.splitGraphStore(store_path));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(defaultIo(), store_path, .{}));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_graphs"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_graph_nodes"));
    try std.testing.expectEqual(@as(?BoundGraphStoreInfo, null), try db.boundGraphStore(std.testing.allocator));
}

test "split object store moves existing object storage into a bound store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "split-object-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "split-object-store.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "split-object-backup.zova");

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.exec("create table documents (object_id blob not null, title text not null)");

    const object_id = try db.putObject("object moved into split store");
    const object_id_hex = try testingLowerHexAlloc(std.testing.allocator, &object_id);
    defer std.testing.allocator.free(object_id_hex);

    var insert = try db.prepare("insert into documents (object_id, title) values (?, 'kept in main')");
    defer insert.deinit();
    try insert.bindBlob(1, &object_id);
    try std.testing.expectEqual(sqlite.Step.done, try insert.step());

    const loose_chunk = objectChunkId("loose split chunk");
    try db.putObjectChunk(loose_chunk, "loose split chunk");

    const left_chunk = "assembled-left";
    const right_chunk = "assembled-right";
    const assembled_bytes = left_chunk ++ right_chunk;
    const left_hash = objectChunkId(left_chunk);
    const right_hash = objectChunkId(right_chunk);
    const assembled_id = objectId(assembled_bytes);
    try db.putObjectChunk(left_hash, left_chunk);
    try db.putObjectChunk(right_hash, right_chunk);
    try db.assembleObjectFromChunks(assembled_id, assembled_bytes.len, &.{
        .{ .index = 0, .hash = left_hash, .offset = 0, .size_bytes = left_chunk.len },
        .{ .index = 1, .hash = right_hash, .offset = left_chunk.len, .size_bytes = right_chunk.len },
    });

    try db.createGraph("split_objects");
    try db.putGraphNode(.{ .graph_name = "split_objects", .node_id = "doc:object", .kind = "document", .target_type = .record, .target_namespace = "documents", .target_ref = "kept in main" });
    try db.putGraphNode(.{ .graph_name = "split_objects", .node_id = "object:primary", .kind = "object", .target_type = .object, .target_ref = object_id_hex });
    try db.putGraphEdge(.{ .graph_name = "split_objects", .from_node_id = "doc:object", .edge_type = "has_object", .to_node_id = "object:primary" });

    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&db, "select count(*) from _zova_chunks"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(&db, "select count(*) from _zova_object_chunks"));

    const result = try db.splitObjectStore(store_path);
    try std.testing.expectEqualStrings(bound_object_store_role, result.role);
    try std.testing.expect(result.verified);
    try std.testing.expectEqual(@as(u64, 2), result.copied.objects);
    try std.testing.expectEqual(@as(u64, 4), result.copied.chunks);
    try std.testing.expectEqual(@as(u64, 3), result.copied.manifest_rows);
    try std.testing.expectEqual(result.copied, result.cleared);
    try std.testing.expect(isValidStoreId(&result.store_id));
    try std.testing.expect(isValidStoreId(&result.bound_set_id));

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_chunks"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_object_chunks"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from object_store._zova_objects"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&db, "select count(*) from object_store._zova_chunks"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(&db, "select count(*) from object_store._zova_object_chunks"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from documents"));

    var object = try db.getObject(std.testing.allocator, object_id);
    defer object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "object moved into split store", object.bytes);

    var assembled = try db.getObject(std.testing.allocator, assembled_id);
    defer assembled.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, assembled_bytes, assembled.bytes);
    var assembled_manifest = try db.objectManifest(std.testing.allocator, assembled_id);
    defer assembled_manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), assembled_manifest.chunks.len);

    var chunk = try db.getObjectChunk(std.testing.allocator, loose_chunk);
    defer chunk.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "loose split chunk", chunk.bytes);

    try std.testing.expect(try db.hasGraphNode("split_objects", "object:primary"));
    try std.testing.expect(try db.hasGraphEdge("split_objects", "doc:object", "has_object", "object:primary"));
    var graph_neighbors = try db.graphNeighbors(std.testing.allocator, .{
        .graph_name = "split_objects",
        .node_id = "doc:object",
        .limit = 10,
    });
    defer graph_neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), graph_neighbors.items.len);
    try std.testing.expectEqualStrings("object:primary", graph_neighbors.items[0].node_id);

    try db.backupTo(backup_path, .{});
    var backup = try Database.open(backup_path);
    defer backup.deinit();
    try std.testing.expectEqual(@as(?BoundObjectStoreInfo, null), try backup.boundObjectStore(std.testing.allocator));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&backup, "select count(*) from _zova_objects"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&backup, "select count(*) from _zova_chunks"));
    try std.testing.expectEqual(@as(i64, 3), try testingCount(&backup, "select count(*) from _zova_object_chunks"));
    try std.testing.expect(try backup.hasGraphEdge("split_objects", "doc:object", "has_object", "object:primary"));
}

test "optional bound vector store routes vector APIs and sql native search after reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-vector-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "vectors-store.zova");

    try createVectorStore(store_path);

    {
        var db = try Database.create(main_path);
        defer db.deinit();

        try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try db.boundVectorStore(std.testing.allocator));
        try db.bindVectorStore(store_path);

        var info = (try db.boundVectorStore(std.testing.allocator)).?;
        defer info.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.endsWith(u8, info.path, "vectors-store.zova"));

        try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
        try db.putVectors("docs", &.{
            .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0 } } },
            .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0 } } },
        });

        try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors"));
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from vector_store._zova_vectors"));

        const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 1.0, 0.0 });
        defer std.testing.allocator.free(query_blob);

        var distance = try db.prepare("select zova_vector_distance('docs', 'doc-a', ?)");
        defer distance.deinit();
        try distance.bindBlob(1, query_blob);
        try std.testing.expectEqual(sqlite.Step.row, try distance.step());
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), distance.columnDouble(0), 0.000001);
    }

    {
        var store_raw = try sqlite.Database.open(store_path);
        defer store_raw.deinit();
        try std.testing.expectEqual(@as(i64, 2), try testingCount(&store_raw, "select count(*) from _zova_vectors"));
    }

    {
        var reopened = try Database.open(main_path);
        defer reopened.deinit();

        var results = try reopened.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0 } }, 2);
        defer results.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), results.items.len);
        try std.testing.expectEqualStrings("doc-a", results.items[0].id);

        try reopened.unbindVectorStore();
        try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try reopened.boundVectorStore(std.testing.allocator));
        try std.testing.expectError(error.VectorCollectionNotFound, reopened.getVector(std.testing.allocator, "docs", "doc-a"));

        try reopened.bindVectorStore(store_path);
        var rebound = try reopened.getVector(std.testing.allocator, "docs", "doc-a");
        defer rebound.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 1.0, 0.0 }, rebound.values.f32);
    }

    {
        var read_only = try Database.openWithOptions(main_path, .{ .read_only = true });
        defer read_only.deinit();

        var vector = try read_only.getVector(std.testing.allocator, "docs", "doc-b");
        defer vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &.{ 0.0, 2.0 }, vector.values.f32);
        try std.testing.expectError(error.ReadOnly, read_only.putVector("docs", "read-only", .{ .f32 = &.{ 1.0, 1.0 } }));
    }
}

test "bound vector store markers roll back with transactions and savepoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-vector-markers-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-vector-markers-store.zova");

    try createVectorStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindVectorStore(store_path);

    var info = (try db.boundVectorStore(std.testing.allocator)).?;
    defer info.deinit(std.testing.allocator);
    try std.testing.expect(isValidStoreId(info.bound_set_id));
    try std.testing.expectEqual(@as(u64, 0), info.vector_epoch);
    try testingExpectScalarText(&db.sqlite_db, "select value from vector_store._zova_meta where key = 'bound_set_id'", info.bound_set_id);
    try testingExpectScalarText(&db.sqlite_db, "select value from vector_store._zova_meta where key = 'vector_epoch'", "0");

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try expectBoundVectorEpoch(&db, 1);
    try db.putVector("docs", "v1", .{ .f32 = &.{ 1.0, 2.0 } });
    try expectBoundVectorEpoch(&db, 2);

    var read_vector = try db.getVector(std.testing.allocator, "docs", "v1");
    read_vector.deinit(std.testing.allocator);
    try expectBoundVectorEpoch(&db, 2);

    try db.exec("create table notes (body text)");
    try db.exec("insert into notes (body) values ('raw user sql')");
    try expectBoundVectorEpoch(&db, 2);

    try db.beginImmediate();
    try db.putVector("docs", "rolled-back", .{ .f32 = &.{ 3.0, 4.0 } });
    try expectBoundVectorEpoch(&db, 3);
    try db.rollback();
    try expectBoundVectorEpoch(&db, 2);
    try std.testing.expectError(error.VectorNotFound, db.getVector(std.testing.allocator, "docs", "rolled-back"));

    try db.beginImmediate();
    try db.savepoint("sp");
    try db.putVector("docs", "savepoint-rolled-back", .{ .f32 = &.{ 5.0, 6.0 } });
    try expectBoundVectorEpoch(&db, 3);
    try db.rollbackToSavepoint("sp");
    try db.releaseSavepoint("sp");
    try expectBoundVectorEpoch(&db, 2);
    try db.commit();
    try expectBoundVectorEpoch(&db, 2);
}

test "operational copies inline bound vector store data into single-file destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-vector-copy-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-vector-copy-vectors.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "bound-vector-copy-backup.zova");

    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "bound-vector-copy-compact.zova");

    var restore_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restore_path = try testingDbPath(&restore_buffer, tmp.sub_path[0..], "bound-vector-copy-restore.zova");

    try createVectorStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindVectorStore(store_path);

    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVectors("docs", &.{
        .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0 } } },
        .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0 } } },
    });
    try db.createVectorCollection("bytes", .{ .dimensions = 2, .metric = .l2, .element_type = .i8 });
    try db.putVectors("bytes", &.{
        .{ .id = "byte-a", .values = .{ .i8 = &.{ @as(i8, 1), @as(i8, -1) } } },
        .{ .id = "byte-b", .values = .{ .i8 = &.{ @as(i8, 5), @as(i8, -1) } } },
    });
    try db.createVectorCollection("halves", .{ .dimensions = 2, .metric = .l2, .element_type = .f16 });
    try db.putVector("halves", "half-one", .{ .f16 = &.{ 0x3c00, 0x0000 } });
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors"));
    try std.testing.expectEqual(@as(i64, 5), try testingCount(&db, "select count(*) from vector_store._zova_vectors"));
    try std.testing.expectError(error.VectorCollectionNotFound, db.getVector(std.testing.allocator, "stale", "main-only"));

    try db.backupTo(backup_path, .{});
    try db.compactTo(compact_path, .{});
    try restoreBackup(main_path, restore_path, .{});

    const copy_paths = [_][:0]const u8{ backup_path, compact_path, restore_path };
    for (copy_paths) |copy_path| {
        var copy = try Database.open(copy_path);
        defer copy.deinit();

        try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try copy.boundVectorStore(std.testing.allocator));
        try std.testing.expectEqual(@as(i64, 5), try testingCount(&copy, "select count(*) from _zova_vectors"));

        var results = try copy.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0 } }, 2);
        defer results.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), results.items.len);
        try std.testing.expectEqualStrings("doc-a", results.items[0].id);

        var bytes_info = try copy.vectorCollectionInfo(std.testing.allocator, "bytes");
        defer bytes_info.deinit(std.testing.allocator);
        try std.testing.expectEqual(vector_impl.VectorElementType.i8, bytes_info.element_type);

        var byte_vector = try copy.getVector(std.testing.allocator, "bytes", "byte-a");
        defer byte_vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(i8, &.{ @as(i8, 1), @as(i8, -1) }, byte_vector.values.i8);

        var half_vector = try copy.getVector(std.testing.allocator, "halves", "half-one");
        defer half_vector.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u16, &.{ 0x3c00, 0x0000 }, half_vector.values.f16);

        var byte_results = try copy.searchVectors(std.testing.allocator, "bytes", .{ .i8 = &.{ @as(i8, 0), @as(i8, 0) } }, 2);
        defer byte_results.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), byte_results.items.len);
        try std.testing.expectEqualStrings("byte-a", byte_results.items[0].id);
    }
}

test "split vector store moves existing vector storage into a bound store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "split-vector-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "split-vector-store.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "split-vector-backup.zova");

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.exec("create table documents (vector_id text not null, title text not null)");
    try db.exec("insert into documents (vector_id, title) values ('doc-a', 'kept in main')");
    try db.createVectorCollection("docs", .{ .dimensions = 2, .metric = .l2 });
    try db.putVectors("docs", &.{
        .{ .id = "doc-a", .values = .{ .f32 = &.{ 1.0, 0.0 } } },
        .{ .id = "doc-b", .values = .{ .f32 = &.{ 0.0, 2.0 } } },
    });
    try db.createVectorCollection("bytes", .{ .dimensions = 2, .metric = .l2, .element_type = .i8 });
    try db.putVectors("bytes", &.{
        .{ .id = "byte-a", .values = .{ .i8 = &.{ @as(i8, 1), @as(i8, 0) } } },
        .{ .id = "byte-b", .values = .{ .i8 = &.{ @as(i8, 5), @as(i8, 0) } } },
    });
    try db.createGraph("split_vectors");
    try db.putGraphNode(.{ .graph_name = "split_vectors", .node_id = "doc:a", .kind = "document", .target_type = .record, .target_namespace = "documents", .target_ref = "doc-a" });
    try db.putGraphNode(.{ .graph_name = "split_vectors", .node_id = "vector:doc-a", .kind = "embedding", .target_type = .vector, .target_namespace = "docs", .target_ref = "doc-a" });
    try db.putGraphEdge(.{ .graph_name = "split_vectors", .from_node_id = "doc:a", .edge_type = "embedded_as", .to_node_id = "vector:doc-a" });
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from _zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&db, "select count(*) from _zova_vectors"));

    const result = try db.splitVectorStore(store_path);
    try std.testing.expectEqualStrings(bound_vector_store_role, result.role);
    try std.testing.expect(result.verified);
    try std.testing.expectEqual(@as(u64, 2), result.copied.vector_collections);
    try std.testing.expectEqual(@as(u64, 4), result.copied.vectors);
    try std.testing.expectEqual(result.copied, result.cleared);
    try std.testing.expect(isValidStoreId(&result.store_id));
    try std.testing.expect(isValidStoreId(&result.bound_set_id));

    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from _zova_vectors"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from vector_store._zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&db, "select count(*) from vector_store._zova_vectors"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from documents"));

    var results = try db.searchVectors(std.testing.allocator, "docs", .{ .f32 = &.{ 1.0, 0.0 } }, 2);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqualStrings("doc-a", results.items[0].id);
    try std.testing.expect(try db.hasGraphNode("split_vectors", "vector:doc-a"));
    try std.testing.expect(try db.hasGraphEdge("split_vectors", "doc:a", "embedded_as", "vector:doc-a"));

    var byte_vector = try db.getVector(std.testing.allocator, "bytes", "byte-a");
    defer byte_vector.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(i8, &.{ @as(i8, 1), @as(i8, 0) }, byte_vector.values.i8);

    const query_blob = try vector_impl.encodeF32Le(std.testing.allocator, &.{ 1.0, 0.0 });
    defer std.testing.allocator.free(query_blob);
    var distance = try db.prepare("select zova_vector_distance('docs', 'doc-a', ?)");
    defer distance.deinit();
    try distance.bindBlob(1, query_blob);
    try std.testing.expectEqual(sqlite.Step.row, try distance.step());
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), distance.columnDouble(0), 0.000001);

    try db.backupTo(backup_path, .{});
    var backup = try Database.open(backup_path);
    defer backup.deinit();
    try std.testing.expectEqual(@as(?BoundVectorStoreInfo, null), try backup.boundVectorStore(std.testing.allocator));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&backup, "select count(*) from _zova_vector_collections"));
    try std.testing.expectEqual(@as(i64, 4), try testingCount(&backup, "select count(*) from _zova_vectors"));
    try std.testing.expect(try backup.hasGraphEdge("split_vectors", "doc:a", "embedded_as", "vector:doc-a"));

    var backup_bytes = try backup.vectorCollectionInfo(std.testing.allocator, "bytes");
    defer backup_bytes.deinit(std.testing.allocator);
    try std.testing.expectEqual(vector_impl.VectorElementType.i8, backup_bytes.element_type);
}

test "open rejects bound object store id mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-id-main.zova");

    var store_one_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_one_path = try testingDbPath(&store_one_buffer, tmp.sub_path[0..], "bound-id-one.zova");

    var store_two_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_two_path = try testingDbPath(&store_two_buffer, tmp.sub_path[0..], "bound-id-two.zova");

    try createObjectStore(store_one_path);
    try createObjectStore(store_two_path);

    {
        var db = try Database.create(main_path);
        defer db.deinit();
        try db.bindObjectStore(store_one_path);

        var stmt = try db.sqlite_db.prepare(
            \\update _zova_bound_stores
            \\set path = ?
            \\where role = 'object_store' and name = 'default'
        );
        defer stmt.deinit();
        try stmt.bindText(1, store_two_path);
        try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
    }

    try std.testing.expectError(error.BoundStoreInvalid, Database.open(main_path));
}

test "bound object store participates in main transactions and savepoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "bound-attach-transaction-main.zova");

    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "bound-attach-transaction-objects.zova");

    try createObjectStore(store_path);

    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindObjectStore(store_path);
    try db.exec(
        \\create table attachments (
        \\  id integer primary key,
        \\  object_id blob not null
        \\)
    );

    try db.beginImmediate();
    const rolled_back = try db.putObject("rolled back object");
    try insertObjectReference(&db, rolled_back);
    try db.rollback();
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, rolled_back));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from attachments"));

    try db.beginImmediate();
    const committed = try db.putObject("committed object");
    try insertObjectReference(&db, committed);
    try db.commit();

    var committed_object = try db.getObject(std.testing.allocator, committed);
    defer committed_object.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "committed object", committed_object.bytes);
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from attachments"));

    try db.beginImmediate();
    try db.deleteObject(committed);
    try db.rollback();
    try std.testing.expect(try db.hasObject(committed));

    try db.beginImmediate();
    var writer = try db.objectWriter(std.testing.allocator);
    defer writer.deinit();
    try writer.write("writer rolled back with transaction");
    const writer_rolled_back = try writer.finish();
    try db.rollback();
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, writer_rolled_back));

    try db.beginImmediate();
    try db.savepoint("sp_rollback");
    const savepoint_rolled_back = try db.putObject("savepoint rolled back object");
    try db.rollbackToSavepoint("sp_rollback");
    try db.releaseSavepoint("sp_rollback");
    try db.commit();
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, savepoint_rolled_back));

    try db.beginImmediate();
    try db.savepoint("outer_sp");
    try db.savepoint("inner_sp");
    const inner_released = try db.putObject("inner released object");
    try db.releaseSavepoint("inner_sp");
    try db.rollbackToSavepoint("outer_sp");
    try db.releaseSavepoint("outer_sp");
    try db.commit();
    try std.testing.expectError(error.ObjectNotFound, db.getObject(std.testing.allocator, inner_released));
}

test "open rejects current format database missing required object table without mutating it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-object-table.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_objects", 0);
    try testingExpectTableCount(&raw, "_zova_chunks", 0);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 0);
}

test "open rejects current format database missing required vector table without mutating it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-vector-table.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
        try raw.exec(object_impl.objects_schema_sql ++ ";");
        try raw.exec(object_impl.chunks_schema_sql ++ ";");
        try raw.exec(object_impl.object_chunks_schema_sql ++ ";");
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try testingExpectTableCount(&raw, "_zova_vector_collections", 0);
    try testingExpectTableCount(&raw, "_zova_vectors", 0);
}

test "open rejects required object table missing required column" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-object-column.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
        try raw.exec(
            \\create table _zova_objects (
            \\  object_id blob not null primary key check (length(object_id) = 32),
            \\  chunk_count integer not null check (chunk_count >= 0),
            \\  chunker text not null check (chunker = 'fastcdc-v1')
            \\);
            \\create table _zova_chunks (
            \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  data blob not null check (length(data) = size_bytes)
            \\);
            \\create table _zova_object_chunks (
            \\  object_id blob not null check (length(object_id) = 32),
            \\  chunk_index integer not null check (chunk_index >= 0),
            \\  chunk_hash blob not null check (length(chunk_hash) = 32),
            \\  offset integer not null check (offset >= 0),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  primary key (object_id, chunk_index),
            \\  foreign key (object_id) references _zova_objects(object_id),
            \\  foreign key (chunk_hash) references _zova_chunks(chunk_hash)
            \\);
        );
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "open rejects required object table missing required constraint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-object-constraint.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
        try raw.exec(
            \\create table _zova_objects (
            \\  object_id blob not null primary key check (length(object_id) = 32),
            \\  size_bytes integer not null,
            \\  chunk_count integer not null check (chunk_count >= 0),
            \\  chunker text not null check (chunker = 'fastcdc-v1')
            \\);
            \\create table _zova_chunks (
            \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  data blob not null check (length(data) = size_bytes)
            \\);
            \\create table _zova_object_chunks (
            \\  object_id blob not null check (length(object_id) = 32),
            \\  chunk_index integer not null check (chunk_index >= 0),
            \\  chunk_hash blob not null check (length(chunk_hash) = 32),
            \\  offset integer not null check (offset >= 0),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  primary key (object_id, chunk_index),
            \\  foreign key (object_id) references _zova_objects(object_id),
            \\  foreign key (chunk_hash) references _zova_chunks(chunk_hash)
            \\);
        );
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "open rejects fake constraint text in required object table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "fake-object-constraint.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
        try raw.exec(
            \\create table _zova_objects (
            \\  object_id blob not null primary key check (length(object_id) = 32),
            \\  size_bytes integer not null check ('check (size_bytes >= 0)' is not null),
            \\  chunk_count integer not null check (chunk_count >= 0),
            \\  chunker text not null check (chunker = 'fastcdc-v1')
            \\);
            \\create table _zova_chunks (
            \\  chunk_hash blob not null primary key check (length(chunk_hash) = 32),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  data blob not null check (length(data) = size_bytes)
            \\);
            \\create table _zova_object_chunks (
            \\  object_id blob not null check (length(object_id) = 32),
            \\  chunk_index integer not null check (chunk_index >= 0),
            \\  chunk_hash blob not null check (length(chunk_hash) = 32),
            \\  offset integer not null check (offset >= 0),
            \\  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 65536),
            \\  primary key (object_id, chunk_index),
            \\  foreign key (object_id) references _zova_objects(object_id),
            \\  foreign key (chunk_hash) references _zova_chunks(chunk_hash)
            \\);
        );
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "open rejects required vector table missing required column" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "missing-vector-column.zova");

    {
        var raw = try sqlite.Database.open(db_path);
        defer raw.deinit();

        try testingWriteMetadata(&raw, "zova", format_version);
        try raw.exec(extension_impl.extensions_schema_sql ++ ";");
        try raw.exec(object_impl.objects_schema_sql ++ ";");
        try raw.exec(object_impl.chunks_schema_sql ++ ";");
        try raw.exec(object_impl.object_chunks_schema_sql ++ ";");
        try raw.exec(
            \\create table _zova_vector_collections (
            \\  name text not null primary key check (length(name) > 0 and length(name) <= 255),
            \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
            \\  element_type text not null check (element_type = 'f32')
            \\);
            \\create table _zova_vectors (
            \\  collection_name text not null,
            \\  vector_id text not null check (length(vector_id) > 0),
            \\  dimensions integer not null check (dimensions > 0 and dimensions <= 16384),
            \\  "values" blob not null check (length("values") = dimensions * 4),
            \\  primary key (collection_name, vector_id),
            \\  foreign key (collection_name) references _zova_vector_collections(name)
            \\);
        );
    }

    try std.testing.expectError(error.NotZovaDatabase, Database.open(db_path));
}

test "sqlite wrapper can inspect zova object tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "sqlite-inspect.zova");

    {
        var db = try Database.create(db_path);
        defer db.deinit();
    }

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    var tables = try raw.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table'
        \\  and name in ('_zova_objects', '_zova_chunks', '_zova_object_chunks')
    );
    defer tables.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try tables.step());
    try std.testing.expectEqual(@as(i64, 3), tables.columnInt64(0));
}

test "plain sqlite open on zova path does not initialize metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "sqlite-wrapper.zova");

    var raw = try sqlite.Database.open(db_path);
    defer raw.deinit();

    try raw.exec("create table user_data (id integer primary key)");

    var count = try raw.prepare(
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table' and name = '_zova_meta'
    );
    defer count.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 0), count.columnInt64(0));
}

test "convert sqlite to zova preserves table rows and source file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "source.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "converted.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();

        try source.exec(
            \\create table messages (
            \\  id integer primary key,
            \\  body text not null
            \\);
            \\insert into messages (body) values ('alpha');
            \\insert into messages (body) values ('beta');
        );
    }

    try convertSqliteToZova(source_path, dest_path);

    {
        var dest = try Database.open(dest_path);
        defer dest.deinit();

        var rows = try dest.prepare("select body from messages order by id");
        defer rows.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try rows.step());
        try std.testing.expectEqualStrings("alpha", rows.columnText(0));
        try std.testing.expectEqual(sqlite.Step.row, try rows.step());
        try std.testing.expectEqualStrings("beta", rows.columnText(0));
        try std.testing.expectEqual(sqlite.Step.done, try rows.step());
    }

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();

        var count = try source.prepare("select count(*) from messages");
        defer count.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try count.step());
        try std.testing.expectEqual(@as(i64, 2), count.columnInt64(0));

        var metadata = try source.prepare(
            \\select count(*)
            \\from sqlite_master
            \\where type = 'table' and name = '_zova_meta'
        );
        defer metadata.deinit();

        try std.testing.expectEqual(sqlite.Step.row, try metadata.step());
        try std.testing.expectEqual(@as(i64, 0), metadata.columnInt64(0));
    }
}

test "converted zova remains readable through sqlite wrapper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "sqlite-readable.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "sqlite-readable.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table items (name text not null); insert into items (name) values ('kept')");
    }

    try convertSqliteToZova(source_path, dest_path);

    var raw = try sqlite.Database.open(dest_path);
    defer raw.deinit();

    var item = try raw.prepare("select name from items");
    defer item.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try item.step());
    try std.testing.expectEqualStrings("kept", item.columnText(0));

    var meta = try raw.prepare("select value from _zova_meta where key = 'format_version'");
    defer meta.deinit();

    try std.testing.expectEqual(sqlite.Step.row, try meta.step());
    try std.testing.expectEqualStrings(format_version, meta.columnText(0));

    try testingExpectTableCount(&raw, "_zova_objects", 1);
    try testingExpectTableCount(&raw, "_zova_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_object_chunks", 1);
    try testingExpectTableCount(&raw, "_zova_vector_collections", 1);
    try testingExpectTableCount(&raw, "_zova_vectors", 1);
    try testingExpectTableCount(&raw, "_zova_graphs", 1);
    try testingExpectTableCount(&raw, "_zova_graph_nodes", 1);
    try testingExpectTableCount(&raw, "_zova_graph_edges", 1);
}

test "backup compact and restore preserve zova records objects chunks and vectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "operations-source.zova");

    var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const backup_path = try testingDbPath(&backup_buffer, tmp.sub_path[0..], "operations-backup.zova");

    var compact_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const compact_path = try testingDbPath(&compact_buffer, tmp.sub_path[0..], "operations-compact.zova");

    var restored_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const restored_path = try testingDbPath(&restored_buffer, tmp.sub_path[0..], "operations-restored.zova");

    var quoted_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const quoted_path = try testingDbPath(&quoted_buffer, tmp.sub_path[0..], "operations copy 'quoted'.zova");

    const primary_bytes = "primary object bytes\x00with nul";
    const loose_bytes = "verified loose operational chunk";

    const streamed_bytes = try std.testing.allocator.alloc(u8, 140_000);
    defer std.testing.allocator.free(streamed_bytes);
    fillOperationalLargeFixture(streamed_bytes);

    var ids: OperationalFixtureIds = undefined;
    {
        var db = try Database.create(source_path);
        defer db.deinit();

        ids = try populateOperationalFixture(&db, primary_bytes, streamed_bytes, loose_bytes);
        try db.backupTo(backup_path, .{});
        try db.compactTo(compact_path, .{});
        try db.backupTo(quoted_path, .{});
    }

    try restoreBackup(backup_path, restored_path, .{});

    try expectOperationalFixture(backup_path, ids, primary_bytes, streamed_bytes, loose_bytes);
    try expectOperationalFixture(compact_path, ids, primary_bytes, streamed_bytes, loose_bytes);
    try expectOperationalFixture(restored_path, ids, primary_bytes, streamed_bytes, loose_bytes);
    try expectOperationalFixture(quoted_path, ids, primary_bytes, streamed_bytes, loose_bytes);
}

test "notification queues drop oldest entries and report dropped count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "notification-overflow.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var sub = try db.listen("overflow");
    defer sub.deinit();

    var index: usize = 0;
    while (index < notify_impl.queue_capacity + 1) : (index += 1) {
        var payload_buffer: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buffer, "event-{d}", .{index});
        try db.notify("overflow", payload);
    }

    var first = (try sub.tryReceive(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event-1", first.payload);
    try std.testing.expectEqual(@as(u64, 1), first.dropped_before);
}

test "notification validation rejects invalid channels payloads and SQL notify inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "notification-validation.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    var sub = try db.listen("messages");
    defer sub.deinit();

    const invalid_channel_bytes = [_]u8{ 0xc3, 0xa9 };
    const invalid_channels = [_][]const u8{
        "",
        "bad channel",
        "_zova_private",
        invalid_channel_bytes[0..],
    };
    for (invalid_channels) |channel| {
        try std.testing.expectError(error.InvalidArgument, db.listen(channel));
        try std.testing.expectError(error.InvalidArgument, db.notify(channel, "payload"));
    }

    var long_channel: [notify_impl.max_channel_len + 1]u8 = undefined;
    @memset(long_channel[0..], 'a');
    try std.testing.expectError(error.InvalidArgument, db.listen(long_channel[0..]));
    try std.testing.expectError(error.InvalidArgument, db.notify(long_channel[0..], "payload"));

    const invalid_payload = [_]u8{0xff};
    try std.testing.expectError(error.InvalidArgument, db.notify("messages", invalid_payload[0..]));

    try std.testing.expectError(error.SqliteError, db.exec("select zova_notify('_zova_private', 'payload')"));
    try std.testing.expectError(error.SqliteError, db.exec("select zova_notify('messages', cast(x'ff' as text))"));
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
}

test "in-memory notifications follow transaction savepoint and overflow semantics" {
    var db = try Database.createMemory();
    defer db.deinit();

    var sub = try db.listen("cache:search-results");
    defer sub.deinit();

    try db.notify("cache:search-results", "outside");
    var outside_note = (try sub.tryReceive(std.testing.allocator)).?;
    defer outside_note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cache:search-results", outside_note.channel);
    try std.testing.expectEqualStrings("outside", outside_note.payload);

    try db.beginImmediate();
    try db.notify("cache:search-results", "committed");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();
    {
        var note = (try sub.tryReceive(std.testing.allocator)).?;
        defer note.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("committed", note.payload);
    }

    try db.beginImmediate();
    try db.savepoint("inner");
    try db.notify("cache:search-results", "discarded");
    try db.rollbackToSavepoint("inner");
    try db.notify("cache:search-results", "kept");
    try db.releaseSavepoint("inner");
    try db.rollback();
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));

    var index: usize = 0;
    while (index < notify_impl.queue_capacity + 1) : (index += 1) {
        var payload_buffer: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buffer, "event-{d}", .{index});
        try db.notify("cache:search-results", payload);
    }
    var overflowed = (try sub.tryReceive(std.testing.allocator)).?;
    defer overflowed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event-1", overflowed.payload);
    try std.testing.expectEqual(@as(u64, 1), overflowed.dropped_before);
}

test "notifications defer across one transaction spanning SQL vector graph and kv" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.createVectorCollection("chunks", .{ .dimensions = 2, .metric = .cosine });
    try db.createGraph("app");

    var sub = try db.listen("app:changed");
    defer sub.deinit();

    try db.beginImmediate();
    try db.exec("insert into _zova_meta (key, value) values ('app:version', '2')");
    try db.putVectors("chunks", &.{.{ .id = "vec-1", .values = .{ .f32 = &.{ 1.0, 2.0 } } }});
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "node-a", .kind = "entity" });
    try db.putGraphNode(.{ .graph_name = "app", .node_id = "node-b", .kind = "entity" });
    try db.putGraphEdge(.{ .graph_name = "app", .from_node_id = "node-a", .edge_type = "links", .to_node_id = "node-b" });
    try db.kvPut("app", "key", "value");
    try db.notify("app:changed", "all-subsystems");
    try std.testing.expectEqual(@as(?Notification, null), try sub.tryReceive(std.testing.allocator));
    try db.commit();

    var note = (try sub.tryReceive(std.testing.allocator)).?;
    defer note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("app:changed", note.channel);
    try std.testing.expectEqualStrings("all-subsystems", note.payload);
    try std.testing.expectEqual(@as(u64, 1), note.sequence);

    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from _zova_meta where key = 'app:version'"));
    try std.testing.expect(try db.hasGraphNode("app", "node-a"));
    try std.testing.expect(try db.hasGraphEdge("app", "node-a", "links", "node-b"));
    var kv_value = try db.kvGet(std.testing.allocator, "app", "key");
    defer kv_value.deinit(std.testing.allocator);
    try std.testing.expect(kv_value.found);
    try std.testing.expectEqualSlices(u8, "value", kv_value.value);
}

test "convert sqlite to zova rejects non sqlite source file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "not-sqlite.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "not-sqlite.zova");

    try std.Io.Dir.cwd().writeFile(defaultIo(), .{
        .sub_path = source_path,
        .data = "this is not a sqlite database",
    });

    try std.testing.expectError(error.SqliteError, convertSqliteToZova(source_path, dest_path));
    try std.testing.expectError(error.NotZovaDatabase, Database.open(dest_path));
}

test "convert sqlite to zova rejects reserved zova source names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "reserved.db");

    var meta_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const meta_dest_path = try testingDbPath(&meta_dest_buffer, tmp.sub_path[0..], "reserved-meta.zova");

    var prefix_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const prefix_dest_path = try testingDbPath(&prefix_dest_buffer, tmp.sub_path[0..], "reserved-prefix.zova");

    var case_dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const case_dest_path = try testingDbPath(&case_dest_buffer, tmp.sub_path[0..], "reserved-case.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table _zova_meta (key text primary key, value text not null)");
    }

    try std.testing.expectError(error.ZovaNameConflict, convertSqliteToZova(source_path, meta_dest_path));

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("drop table _zova_meta; create table _zova_user_data (id integer primary key)");
    }

    try std.testing.expectError(error.ZovaNameConflict, convertSqliteToZova(source_path, prefix_dest_path));

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("drop table _zova_user_data; create table _ZOVA_case (id integer primary key)");
    }

    try std.testing.expectError(error.ZovaNameConflict, convertSqliteToZova(source_path, case_dest_path));
}

test "failed conversion cleans up destination file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "cleanup.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "cleanup.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec("create table _zova_user_data (id integer primary key)");
    }

    try std.testing.expectError(error.ZovaNameConflict, convertSqliteToZova(source_path, dest_path));
    try std.testing.expectError(error.NotZovaDatabase, Database.open(dest_path));
}

test "conversion rejects extension private source names and cleans destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try testingDbPath(&source_buffer, tmp.sub_path[0..], "extension-private-source.db");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try testingDbPath(&dest_buffer, tmp.sub_path[0..], "extension-private-source.zova");

    {
        var source = try sqlite.Database.open(source_path);
        defer source.deinit();
        try source.exec(
            \\create table _zova_ext_external_documents (
            \\  id integer primary key,
            \\  body text not null
            \\)
        );
    }

    try std.testing.expectError(error.ZovaNameConflict, convertSqliteToZova(source_path, dest_path));
    try std.testing.expectError(error.NotZovaDatabase, Database.open(dest_path));
}
