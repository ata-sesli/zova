const std = @import("std");
const zova = @import("zova.zig");
const support = @import("zova_test_support.zig");

pub const Operation = enum { node_put, node_delete, edge_put, edge_delete, vector_put, vector_delete };

fn run(db: *zova.Database, comptime op: Operation) !void {
    const nodes = [_]zova.GraphNodeInput{
        .{ .graph_name = "app", .node_id = "a", .kind = "updated" },
        .{ .graph_name = "app", .node_id = "b", .kind = "updated" },
        .{ .graph_name = "app", .node_id = "c", .kind = "updated" },
        .{ .graph_name = "app", .node_id = "c", .kind = "final" },
    };
    const edges = [_]zova.GraphEdgeInput{
        .{ .graph_name = "app", .from_node_id = "a", .to_node_id = "b", .edge_type = "link" },
        .{ .graph_name = "app", .from_node_id = "b", .to_node_id = "c", .edge_type = "link" },
        .{ .graph_name = "app", .from_node_id = "c", .to_node_id = "a", .edge_type = "link" },
        .{ .graph_name = "app", .from_node_id = "c", .to_node_id = "a", .edge_type = "link" },
    };
    switch (op) {
        .node_put => try db.putGraphNodes(&nodes),
        .node_delete => try db.deleteGraphNodes("app", &.{ "a", "b", "c", "c", "missing" }),
        .edge_put => try db.putGraphEdges(&edges),
        .edge_delete => try db.deleteGraphEdges(&edges),
        .vector_put => try db.putVectors("app", &.{
            .{ .id = "a", .values = .{ .f32 = &.{2} } },
            .{ .id = "b", .values = .{ .f32 = &.{2} } },
            .{ .id = "c", .values = .{ .f32 = &.{2} } },
            .{ .id = "c", .values = .{ .f32 = &.{3} } },
        }),
        .vector_delete => try db.deleteVectors("app", &.{ "a", "b", "c", "c", "missing" }),
    }
}

pub fn check(comptime op: Operation) !void {
    inline for (.{ false, true }) |bound| {
        inline for (.{ false, true }) |caller_transaction| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var main_buf: [std.fs.max_path_bytes]u8 = undefined;
            var store_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try support.testingDbPath(&main_buf, tmp.sub_path[0..], "batch.zova");
            const store = try support.testingDbPath(&store_buf, tmp.sub_path[0..], "store.zova");
            var db = try zova.Database.create(path);
            defer db.deinit();
            const vector = op == .vector_put or op == .vector_delete;
            const schema = if (!bound) "main" else if (vector) "vector_store" else "graph_store";
            const epoch = if (vector) "vector_epoch" else "graph_epoch";
            if (bound) {
                if (vector) {
                    try zova.createVectorStore(store);
                    try db.bindVectorStore(store);
                } else {
                    try zova.createGraphStore(store);
                    try db.bindGraphStore(store);
                }
            }
            if (vector) {
                try db.createVectorCollection("app", .{ .dimensions = 1, .metric = .cosine });
                for ([_][]const u8{ "a", "b", "c" }) |id| try db.putVector("app", id, .{ .f32 = &.{1} });
            } else {
                try db.createGraph("app");
                for ([_][]const u8{ "a", "b", "c" }) |id| try db.putGraphNode(.{ .graph_name = "app", .node_id = id, .kind = "original" });
                if (op == .edge_delete or op == .node_delete) try run(&db, .edge_put);
            }
            const table = switch (op) {
                .node_put, .node_delete => "_zova_graph_nodes",
                .edge_put, .edge_delete => "_zova_graph_edges",
                .vector_put, .vector_delete => "_zova_vectors",
            };
            const count_sql = "select count(*) from " ++ schema ++ "." ++ table;
            const before = try support.testingCount(&db, count_sql);
            const epoch_sql = "select " ++ epoch ++ " from main._zova_bound_stores where role='" ++ schema ++ "'";
            const before_epoch = if (bound) try support.testingCount(&db, epoch_sql) else 0;
            try db.exec("create table caller_work(value integer); create temp table batch_progress(value integer)");
            const event = switch (op) {
                .node_put, .edge_put, .vector_put => "insert",
                else => "delete",
            };
            // FAIL deliberately preserves earlier statement/trigger work; only
            // the operation's transaction/savepoint can remove it all.
            try db.exec("create temp trigger fail_batch before " ++ event ++ " on " ++ schema ++ "." ++ table ++
                " begin insert into batch_progress values (1);" ++
                " select case when (select count(*) from batch_progress)=3 then raise(fail,'batch fault') end; end");
            if (caller_transaction) try db.begin();
            try db.exec("insert into caller_work values (1)");
            try std.testing.expectError(error.Constraint, run(&db, op));
            try std.testing.expectEqual(before, try support.testingCount(&db, count_sql));
            try std.testing.expectEqual(@as(i64, 0), try support.testingCount(&db, "select count(*) from batch_progress"));
            try std.testing.expectEqual(@as(i64, 1), try support.testingCount(&db, "select count(*) from caller_work"));
            if (op == .node_put) try std.testing.expectEqual(@as(i64, 3), try support.testingCount(&db, "select count(*) from " ++ schema ++ "." ++ table ++ " where kind='original'"));
            if (op == .vector_put) try std.testing.expectEqual(@as(i64, 3), try support.testingCount(&db, "select count(*) from " ++ schema ++ "." ++ table ++ " where norm_squared=1"));
            if (bound) {
                try std.testing.expectEqual(before_epoch, try support.testingCount(&db, epoch_sql));
                try std.testing.expectEqual(before_epoch, try support.testingCount(&db, "select cast(value as integer) from " ++ schema ++ "._zova_meta where key='" ++ epoch ++ "'"));
            }
            try db.exec("drop trigger fail_batch");
            if (bound) {
                // Fail after the data writes and main epoch update, while
                // publishing the matching attached-store epoch.
                try db.exec("create temp trigger fail_epoch before update on " ++ schema ++ "._zova_meta" ++
                    " when new.key='" ++ epoch ++ "' begin select raise(fail,'epoch fault'); end");
                try std.testing.expectError(error.Constraint, run(&db, op));
                try std.testing.expectEqual(before, try support.testingCount(&db, count_sql));
                try std.testing.expectEqual(before_epoch, try support.testingCount(&db, epoch_sql));
                try std.testing.expectEqual(before_epoch, try support.testingCount(&db, "select cast(value as integer) from " ++ schema ++ "._zova_meta where key='" ++ epoch ++ "'"));
                if (op == .node_put) try std.testing.expectEqual(@as(i64, 3), try support.testingCount(&db, "select count(*) from " ++ schema ++ "." ++ table ++ " where kind='original'"));
                if (op == .vector_put) try std.testing.expectEqual(@as(i64, 3), try support.testingCount(&db, "select count(*) from " ++ schema ++ "." ++ table ++ " where norm_squared=1"));
                try db.exec("drop trigger fail_epoch");
            }
            try run(&db, op);
            const expected_count: i64 = switch (op) {
                .node_put, .edge_put, .vector_put => 3,
                else => 0,
            };
            try std.testing.expectEqual(expected_count, try support.testingCount(&db, count_sql));
            if (op == .node_put) try std.testing.expectEqual(@as(i64, 1), try support.testingCount(&db, "select count(*) from " ++ schema ++ "." ++ table ++ " where node_id='c' and kind='final'"));
            if (op == .vector_put) try std.testing.expectEqual(@as(i64, 1), try support.testingCount(&db, "select count(*) from " ++ schema ++ "." ++ table ++ " where vector_id='c' and norm_squared=9"));
            if (op == .node_delete) try std.testing.expectEqual(@as(i64, 0), try support.testingCount(&db, "select count(*) from " ++ schema ++ "._zova_graph_edges"));
            if (bound) try std.testing.expectEqual(before_epoch + 1, try support.testingCount(&db, epoch_sql));
            if (caller_transaction) {
                try db.rollback();
                try std.testing.expectEqual(before, try support.testingCount(&db, count_sql));
                try std.testing.expectEqual(@as(i64, 0), try support.testingCount(&db, "select count(*) from caller_work"));
                if (bound) try std.testing.expectEqual(before_epoch, try support.testingCount(&db, epoch_sql));
                if (op == .node_delete) try std.testing.expectEqual(@as(i64, 3), try support.testingCount(&db, "select count(*) from " ++ schema ++ "._zova_graph_edges"));
            } else {
                // The failed owned transaction must also leave the connection usable.
                try db.begin();
                try db.exec("insert into caller_work values (2)");
                try db.commit();
            }
        }
    }
}
