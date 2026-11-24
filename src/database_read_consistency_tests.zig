//! One consistent view for multi-statement reads across handles (#259).
//!
//! Each test runs one public read on a reader handle while a writer handle
//! commits a change before a chosen statement step of that read. It repeats
//! the read once for every step after the first, and every repetition must
//! return what the undisturbed read returned: the state when the read began.

const Database = @import("zova.zig").Database;
const ObjectId = @import("zova.zig").ObjectId;
const createGraphStore = @import("zova.zig").createGraphStore;
const createObjectStore = @import("zova.zig").createObjectStore;
const createVectorStore = @import("zova.zig").createVectorStore;
const sqlite = @import("sqlite.zig");
const std = @import("std");
const testingDbPath = @import("zova_test_support.zig").testingDbPath;

const allocator = std.testing.allocator;
const Hasher = std.hash.Wyhash;

const SetPaths = struct {
    main_buffer: [std.fs.max_path_bytes]u8 = undefined,
    object_buffer: [std.fs.max_path_bytes]u8 = undefined,
    vector_buffer: [std.fs.max_path_bytes]u8 = undefined,
    graph_buffer: [std.fs.max_path_bytes]u8 = undefined,
    main: [:0]u8 = undefined,
};

/// Create a WAL database, optionally with one bound store of each kind.
/// WAL lets the writer commit while the reader holds a read transaction.
fn createWalSet(paths: *SetPaths, sub_path: []const u8, bound: bool) !Database {
    paths.main = try testingDbPath(&paths.main_buffer, sub_path, "main.zova");
    var db = try Database.create(paths.main);
    errdefer db.deinit();
    if (bound) {
        const object_path = try testingDbPath(&paths.object_buffer, sub_path, "objects.zova");
        const vector_path = try testingDbPath(&paths.vector_buffer, sub_path, "vectors.zova");
        const graph_path = try testingDbPath(&paths.graph_buffer, sub_path, "graphs.zova");
        try createObjectStore(object_path);
        try createVectorStore(vector_path);
        try createGraphStore(graph_path);
        try db.bindObjectStore(object_path);
        try db.bindVectorStore(vector_path);
        try db.bindGraphStore(graph_path);
    }
    _ = try db.setJournalMode(.wal);
    return db;
}

/// Runs the case's mutation on the writer before one chosen step of the
/// reader's statements, and counts the steps.
fn Interleave(comptime Case: type) type {
    return struct {
        case: *Case,
        writer: *Database,
        /// Step before which the writer commits; 0 only counts.
        fire_at: usize,
        steps: usize = 0,
        fired: bool = false,
        failure: ?anyerror = null,

        fn run(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.steps += 1;
            if (self.steps != self.fire_at) return;
            self.fired = true;
            self.case.mutate(self.writer) catch |err| {
                self.failure = err;
            };
        }
    };
}

/// Check that `case.read` returns its undisturbed fingerprint when the writer
/// commits `case.mutate` before any one of the read's statement steps after
/// the first.
fn expectOneView(case: anytype, reader: *Database, writer: *Database) !void {
    const Case = @TypeOf(case.*);
    // The first read can fill per-connection caches (graph edge types), which
    // later reads skip; count the steps of a warm read.
    _ = try case.read(reader);
    var counter: Interleave(Case) = .{ .case = case, .writer = writer, .fire_at = 0 };
    sqlite.before_step_hook = .{ .connection = reader.sqlite_db.handle, .context = &counter, .run = Interleave(Case).run };
    defer sqlite.before_step_hook = null;
    const baseline = try case.read(reader);
    const steps = counter.steps;
    try std.testing.expect(steps >= 2);

    var fire_at: usize = 2;
    while (fire_at <= steps) : (fire_at += 1) {
        var interleave: Interleave(Case) = .{ .case = case, .writer = writer, .fire_at = fire_at };
        sqlite.before_step_hook = .{ .connection = reader.sqlite_db.handle, .context = &interleave, .run = Interleave(Case).run };
        const result = case.read(reader);
        sqlite.before_step_hook = null;
        if (interleave.failure) |err| return err;
        try std.testing.expect(interleave.fired);
        const fingerprint = result catch |err| {
            std.debug.print("{s}: read failed with {s} after a commit before step {d} of {d}\n", .{ @typeName(Case), @errorName(err), fire_at, steps });
            return err;
        };
        if (fingerprint != baseline) {
            std.debug.print("{s}: read saw a commit made before step {d} of {d}\n", .{ @typeName(Case), fire_at, steps });
            return error.TestExpectedEqual;
        }
        try case.undo(writer);
    }
}

const ObjectCase = struct {
    method: enum { get, manifest, range, reader },
    id: ObjectId,
    bytes: []const u8,

    fn read(self: *ObjectCase, db: *Database) !u64 {
        var hasher = Hasher.init(0);
        switch (self.method) {
            .get => {
                var object = try db.getObject(allocator, self.id);
                defer object.deinit(allocator);
                hasher.update(object.bytes);
            },
            .manifest => {
                var manifest = try db.objectManifest(allocator, self.id);
                defer manifest.deinit(allocator);
                hasher.update(std.mem.asBytes(&manifest.size_bytes));
                hasher.update(std.mem.asBytes(&manifest.chunk_count));
            },
            .range => {
                const buffer = try allocator.alloc(u8, self.bytes.len - 1000);
                defer allocator.free(buffer);
                const read_len = try db.readObjectRange(self.id, 1000, buffer);
                hasher.update(buffer[0..read_len]);
            },
            .reader => {
                var reader = try db.objectReader(self.id);
                defer reader.deinit();
                var buffer: [4096]u8 = undefined;
                while (true) {
                    const read_len = try reader.read(&buffer);
                    if (read_len == 0) break;
                    hasher.update(buffer[0..read_len]);
                }
            },
        }
        return hasher.final();
    }

    fn mutate(self: *ObjectCase, db: *Database) !void {
        try db.deleteObject(self.id);
    }

    fn undo(self: *ObjectCase, db: *Database) !void {
        _ = try db.putObject(self.bytes);
    }
};

test "object reads keep one view while another handle deletes the object" {
    // Several content-defined chunks, so a read issues several statements.
    const bytes = try allocator.alloc(u8, 400 * 1024);
    defer allocator.free(bytes);
    var prng = std.Random.DefaultPrng.init(259);
    prng.random().bytes(bytes);

    for ([_]bool{ false, true }) |bound| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths: SetPaths = .{};
        var writer = try createWalSet(&paths, tmp.sub_path[0..], bound);
        defer writer.deinit();
        const id = try writer.putObject(bytes);
        var reader = try Database.open(paths.main);
        defer reader.deinit();

        for ([_]@FieldType(ObjectCase, "method"){ .get, .manifest, .range, .reader }) |method| {
            var case: ObjectCase = .{ .method = method, .id = id, .bytes = bytes };
            try expectOneView(&case, &reader, &writer);
        }
    }
}

const VectorCase = struct {
    method: enum { get, search, search_by_id },

    fn read(self: *VectorCase, db: *Database) !u64 {
        var hasher = Hasher.init(0);
        switch (self.method) {
            .get => {
                var vector = try db.getVector(allocator, "v", "a");
                defer vector.deinit(allocator);
                hasher.update(std.mem.sliceAsBytes(vector.values.f32));
            },
            .search, .search_by_id => {
                var results = if (self.method == .search)
                    try db.searchVectors(allocator, "v", .{ .f32 = &.{ 1, 2 } }, 10)
                else
                    try db.searchVectorsById(allocator, "v", "a", 10);
                defer results.deinit(allocator);
                for (results.items) |item| {
                    hasher.update(item.id);
                    hasher.update(std.mem.asBytes(&item.distance));
                }
            },
        }
        return hasher.final();
    }

    /// Recreate the collection with other dimensions; its key can be reused.
    fn mutate(_: *VectorCase, db: *Database) !void {
        try db.deleteVectorCollection("v");
        try db.createVectorCollection("v", .{ .dimensions = 3, .metric = .l2 });
        try db.putVector("v", "a", .{ .f32 = &.{ 7, 8, 9 } });
        try db.putVector("v", "c", .{ .f32 = &.{ 1, 2, 3 } });
    }

    fn undo(_: *VectorCase, db: *Database) !void {
        try db.deleteVectorCollection("v");
        try seedVectors(db);
    }

    fn seedVectors(db: *Database) !void {
        try db.createVectorCollection("v", .{ .dimensions = 2, .metric = .l2 });
        try db.putVector("v", "a", .{ .f32 = &.{ 1, 2 } });
        try db.putVector("v", "b", .{ .f32 = &.{ 3, 4 } });
    }
};

test "vector reads keep one view while another handle recreates the collection" {
    for ([_]bool{ false, true }) |bound| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths: SetPaths = .{};
        var writer = try createWalSet(&paths, tmp.sub_path[0..], bound);
        defer writer.deinit();
        try VectorCase.seedVectors(&writer);
        var reader = try Database.open(paths.main);
        defer reader.deinit();

        for ([_]@FieldType(VectorCase, "method"){ .get, .search, .search_by_id }) |method| {
            var case: VectorCase = .{ .method = method };
            try expectOneView(&case, &reader, &writer);
        }
    }
}

const GraphCase = struct {
    method: enum { neighbors, degree, walk, scan },

    fn read(self: *GraphCase, db: *Database) !u64 {
        var hasher = Hasher.init(0);
        switch (self.method) {
            .neighbors => {
                var list = try db.graphNeighbors(allocator, .{ .graph_name = "g", .node_id = "a" });
                defer list.deinit(allocator);
                for (list.items) |item| hasher.update(item.node_id);
            },
            .degree => {
                const degree = try db.graphDegree(.{ .graph_name = "g", .node_id = "a" });
                hasher.update(std.mem.asBytes(&degree));
            },
            .walk => {
                var walk = try db.graphWalk(allocator, .{ .graph_name = "g", .start_node_id = "a", .max_depth = 5, .limit = 20 });
                defer walk.deinit(allocator);
                for (walk.items) |item| hasher.update(item.node_id);
            },
            .scan => {
                var page = try db.graphScan(allocator, .{ .graph_name = "g", .node_limit = 20, .edge_limit = 20 });
                defer page.deinit(allocator);
                for (page.nodes) |node| hasher.update(node.node_id);
                for (page.edges) |edge| hasher.update(std.mem.asBytes(&edge.target_node_key));
            },
        }
        return hasher.final();
    }

    fn mutate(_: *GraphCase, db: *Database) !void {
        try db.putGraphNode(.{ .graph_name = "g", .node_id = "e", .kind = "n" });
        try db.putGraphEdge(.{ .graph_name = "g", .from_node_id = "a", .edge_type = "to", .to_node_id = "e" });
        try db.putGraphEdge(.{ .graph_name = "g", .from_node_id = "c", .edge_type = "to", .to_node_id = "e" });
    }

    fn undo(_: *GraphCase, db: *Database) !void {
        try db.deleteGraphNode("g", "e");
    }
};

test "graph reads keep one view while another handle adds nodes and edges" {
    for ([_]bool{ false, true }) |bound| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var paths: SetPaths = .{};
        var writer = try createWalSet(&paths, tmp.sub_path[0..], bound);
        defer writer.deinit();
        try writer.createGraph("g");
        for ([_][]const u8{ "a", "b", "c", "d" }) |node_id| {
            try writer.putGraphNode(.{ .graph_name = "g", .node_id = node_id, .kind = "n" });
        }
        try writer.putGraphEdge(.{ .graph_name = "g", .from_node_id = "a", .edge_type = "to", .to_node_id = "b" });
        try writer.putGraphEdge(.{ .graph_name = "g", .from_node_id = "b", .edge_type = "to", .to_node_id = "c" });
        try writer.putGraphEdge(.{ .graph_name = "g", .from_node_id = "c", .edge_type = "to", .to_node_id = "d" });
        var reader = try Database.open(paths.main);
        defer reader.deinit();

        for ([_]@FieldType(GraphCase, "method"){ .neighbors, .degree, .walk, .scan }) |method| {
            var case: GraphCase = .{ .method = method };
            try expectOneView(&case, &reader, &writer);
        }
    }
}

const KvCase = struct {
    const keys = [_][]const u8{ "k1", "k2", "k3" };

    fn read(_: *KvCase, db: *Database) !u64 {
        var hasher = Hasher.init(0);
        const results = try db.kvGetMany(allocator, "ns", &keys);
        defer {
            for (results) |*result| result.deinit(allocator);
            allocator.free(results);
        }
        for (results) |result| hasher.update(result.value);
        return hasher.final();
    }

    fn mutate(_: *KvCase, db: *Database) !void {
        for (keys) |key| try db.kvPut("ns", key, "new");
    }

    fn undo(_: *KvCase, db: *Database) !void {
        for (keys) |key| try db.kvPut("ns", key, "old");
    }
};

test "kvGetMany keeps one view while another handle rewrites the keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: SetPaths = .{};
    var writer = try createWalSet(&paths, tmp.sub_path[0..], false);
    defer writer.deinit();
    for (KvCase.keys) |key| try writer.kvPut("ns", key, "old");
    var reader = try Database.open(paths.main);
    defer reader.deinit();

    var case: KvCase = .{};
    try expectOneView(&case, &reader, &writer);
}

test "reads inside a caller transaction keep the caller's view" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var paths: SetPaths = .{};
    var writer = try createWalSet(&paths, tmp.sub_path[0..], false);
    defer writer.deinit();
    for (KvCase.keys) |key| try writer.kvPut("ns", key, "old");
    var reader = try Database.open(paths.main);
    defer reader.deinit();

    var case: KvCase = .{};
    try reader.begin();
    const before = try case.read(&reader);
    try case.mutate(&writer);
    try std.testing.expectEqual(before, try case.read(&reader));
    try reader.commit();
    try std.testing.expect(before != try case.read(&reader));
}
