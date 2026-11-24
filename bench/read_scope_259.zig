//! Issue #259: cost of the internal read transaction on single-row reads.
//! One bounded sample. Usage: <binary> <new .zova path> delete|wal
//! Build the same file against the baseline and candidate trees and compare.
const std = @import("std");
const zova = @import("zova");
const repeats = 20_000;
const allocator = std.heap.c_allocator;

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
}

fn report(name: []const u8, start: std.Io.Timestamp) void {
    const ns = start.durationTo(now()).toNanoseconds();
    std.debug.print("{s}_us={d:.6}\n", .{ name, @as(f64, @floatFromInt(ns)) / repeats / 1000 });
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArgument;
    const path = try init.arena.allocator().dupeSentinel(u8, args[1], 0);
    var db = try zova.Database.create(path);
    defer db.deinit();
    if (std.mem.eql(u8, args[2], "wal")) {
        try db.exec("pragma journal_mode=wal");
    } else if (!std.mem.eql(u8, args[2], "delete")) return error.InvalidArgument;

    try db.kvPut("ns", "key", "small-value");
    const object_id = try db.putObject("small object");
    try db.createVectorCollection("v", .{ .dimensions = 8, .metric = .l2 });
    var id_buffer: [16]u8 = undefined;
    for (0..1000) |i| {
        const value: f32 = @floatFromInt(i);
        try db.putVector("v", try std.fmt.bufPrint(&id_buffer, "v{d}", .{i}), .{ .f32 = &.{ value, 1, 2, 3, 4, 5, 6, 7 } });
    }
    try db.createGraph("g");
    try db.putGraphNode(.{ .graph_name = "g", .node_id = "a", .kind = "n" });
    try db.putGraphNode(.{ .graph_name = "g", .node_id = "b", .kind = "n" });
    try db.putGraphEdge(.{ .graph_name = "g", .from_node_id = "a", .edge_type = "to", .to_node_id = "b" });

    // Wrapped reads: each issues more than one statement.
    var start = now();
    for (0..repeats) |_| {
        var vector = try db.getVector(allocator, "v", "v500");
        vector.deinit(allocator);
    }
    report("get_vector", start);
    start = now();
    for (0..repeats) |_| if (!try db.hasVector("v", "v500")) return error.BadResult;
    report("has_vector", start);
    start = now();
    for (0..repeats) |_| {
        var object = try db.getObject(allocator, object_id);
        object.deinit(allocator);
    }
    report("get_object_small", start);
    start = now();
    for (0..repeats) |_| {
        const results = try db.kvGetMany(allocator, "ns", &.{"key"});
        for (results) |*result| result.deinit(allocator);
        allocator.free(results);
    }
    report("kv_get_many_one", start);
    start = now();
    for (0..repeats) |_| {
        var list = try db.graphNeighbors(allocator, .{ .graph_name = "g", .node_id = "a" });
        list.deinit(allocator);
    }
    report("graph_neighbors_one", start);
    start = now();
    for (0..repeats) |_| if (try db.graphDegree(.{ .graph_name = "g", .node_id = "a" }) != 1) return error.BadResult;
    report("graph_degree", start);

    // Controls: one-statement reads are not wrapped; an empty deferred
    // transaction is the added work's floor.
    start = now();
    for (0..repeats) |_| {
        const result = try db.kvGet(allocator, "ns", "key");
        result.deinit(allocator);
    }
    report("kv_get_unwrapped", start);
    start = now();
    for (0..repeats) |_| {
        try db.sqlite_db.begin();
        try db.sqlite_db.commit();
    }
    report("empty_deferred_transaction", start);
}
