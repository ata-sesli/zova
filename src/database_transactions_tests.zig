//! Public-only Database behavior tests. No private implementation helpers.

const Database = @import("zova.zig").Database;
const Error = @import("zova.zig").Error;
const createGraphStore = @import("zova.zig").createGraphStore;
const std = @import("std");
const testingCount = @import("zova_test_support.zig").testingCount;
const testingDbPath = @import("zova_test_support.zig").testingDbPath;
const testingQuickCheckOk = @import("zova_test_support.zig").testingQuickCheckOk;

test "memory rollback and savepoints match file backed behavior" {
    var db = try Database.createMemory();
    defer db.deinit();

    try db.exec("create table notes (body text not null)");
    try db.exec("insert into notes (body) values ('committed')");

    try db.begin();
    try db.exec("insert into notes (body) values ('rolled back')");
    try db.rollback();
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes"));

    try db.savepoint("sp");
    try db.exec("insert into notes (body) values ('savepoint rolled back')");
    try db.rollbackToSavepoint("sp");
    try db.releaseSavepoint("sp");
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes"));

    try db.savepoint("sp_keep");
    try db.exec("insert into notes (body) values ('savepoint kept')");
    try db.releaseSavepoint("sp_keep");
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from notes"));
}

test "failed graph replacement restores old attachment and savepoints reject management" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var main_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try testingDbPath(&main_buffer, tmp.sub_path[0..], "graph-replace-main.zova");
    var store_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try testingDbPath(&store_buffer, tmp.sub_path[0..], "graph-replace-store.zova");
    var invalid_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const invalid_path = try testingDbPath(&invalid_buffer, tmp.sub_path[0..], "graph-replace-invalid.zova");
    try createGraphStore(store_path);
    {
        var invalid = try Database.create(invalid_path);
        invalid.deinit();
    }
    var db = try Database.create(main_path);
    defer db.deinit();
    try db.bindGraphStore(store_path);
    try db.createGraph("deps");
    try std.testing.expectError(error.NotZovaDatabase, db.bindGraphStore(invalid_path));
    try std.testing.expect(try db.hasGraph("deps"));

    try db.savepoint("management_guard");
    try std.testing.expectError(error.ObjectTransactionActive, db.bindGraphStore(store_path));
    try std.testing.expectError(error.ObjectTransactionActive, db.unbindGraphStore());
    try db.rollbackToSavepoint("management_guard");
    try db.releaseSavepoint("management_guard");
}

test "savepoints roll back zova records objects and vectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "savepoints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec("create table notes (body text not null)");
    const readable_object = try db.putObject("readable inside savepoint");
    var pending_writer = try db.objectWriter(std.testing.allocator);
    defer pending_writer.deinit();
    try pending_writer.write("writer finish blocked inside savepoint");

    try db.exec("begin immediate");
    try db.exec("insert into notes (body) values ('outer')");

    try db.savepoint("sp_vectors");
    try db.exec("insert into notes (body) values ('rolled back')");
    var readable = try db.getObject(std.testing.allocator, readable_object);
    defer readable.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "readable inside savepoint", readable.bytes);
    var range_buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try db.readObjectRange(readable_object, 0, &range_buffer));
    try std.testing.expectEqualSlices(u8, "readable", &range_buffer);
    try std.testing.expectError(error.ObjectTransactionActive, db.putObject("savepoint object"));
    try std.testing.expectError(error.ObjectTransactionActive, db.deleteObject(readable_object));
    try std.testing.expectError(error.ObjectTransactionActive, pending_writer.finish());
    try db.createVectorCollection("save_vectors", .{ .dimensions = 2, .metric = .l2 });
    try db.putVector("save_vectors", "v1", .{ .f32 = &.{ 1.0, 2.0 } });
    try db.rollbackToSavepoint("sp_vectors");
    try db.releaseSavepoint("sp_vectors");

    try std.testing.expect(!try db.hasVectorCollection("save_vectors"));

    try db.savepoint("sp_release");
    try db.exec("insert into notes (body) values ('kept')");
    try db.createVectorCollection("kept_vectors", .{ .dimensions = 2, .metric = .l2 });
    try db.releaseSavepoint("sp_release");
    try db.exec("commit");

    try pending_writer.cancel();
    const kept_object = try db.putObject("kept savepoint object");
    try std.testing.expect(try db.hasObject(kept_object));
    try std.testing.expect(try db.hasVectorCollection("kept_vectors"));
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from notes"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from notes where body = 'rolled back'"));
    try testingQuickCheckOk(&db);
}

test "scoped savepoint helper releases rolls back nests and reports cleanup failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try testingDbPath(&path_buffer, tmp.sub_path[0..], "scoped-savepoints.zova");

    var db = try Database.create(db_path);
    defer db.deinit();

    try db.exec("create table notes (body text not null)");
    try db.exec("begin immediate");

    const Ctx = struct {
        db: *Database,
        invoked: *bool,

        fn insertKept(self: *@This()) Error!void {
            self.invoked.* = true;
            try self.db.exec("insert into notes (body) values ('kept scoped')");
        }

        fn insertThenFail(self: *@This()) Error!void {
            self.invoked.* = true;
            try self.db.exec("insert into notes (body) values ('rolled back scoped')");
            return error.InvalidArgument;
        }

        fn insertInner(self: *@This()) Error!void {
            try self.db.exec("insert into notes (body) values ('inner rolled back')");
        }

        fn nestedThenFail(self: *@This()) Error!void {
            self.invoked.* = true;
            try self.db.exec("insert into notes (body) values ('outer rolled back')");
            try self.db.withSavepoint("sp_inner", self, @This().insertInner);
            return error.InvalidArgument;
        }

        fn releaseManually(self: *@This()) Error!void {
            self.invoked.* = true;
            try self.db.exec("insert into notes (body) values ('manual release kept')");
            try self.db.releaseSavepoint("sp_manual");
        }
    };

    var invoked = false;
    var ctx = Ctx{ .db = &db, .invoked = &invoked };

    try db.withSavepoint("sp_keep", &ctx, Ctx.insertKept);
    try std.testing.expect(invoked);

    invoked = false;
    try std.testing.expectError(error.InvalidArgument, db.withSavepoint("sp_fail", &ctx, Ctx.insertThenFail));
    try std.testing.expect(invoked);

    invoked = false;
    try std.testing.expectError(error.InvalidArgument, db.withSavepoint("sp_outer", &ctx, Ctx.nestedThenFail));
    try std.testing.expect(invoked);

    invoked = false;
    try std.testing.expectError(error.InvalidArgument, db.withSavepoint("bad name", &ctx, Ctx.insertKept));
    try std.testing.expect(!invoked);

    invoked = false;
    try std.testing.expectError(error.SqliteError, db.withSavepoint("sp_manual", &ctx, Ctx.releaseManually));
    try std.testing.expect(invoked);

    try db.exec("commit");
    try std.testing.expectEqual(@as(i64, 2), try testingCount(&db, "select count(*) from notes"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes where body = 'kept scoped'"));
    try std.testing.expectEqual(@as(i64, 1), try testingCount(&db, "select count(*) from notes where body = 'manual release kept'"));
    try std.testing.expectEqual(@as(i64, 0), try testingCount(&db, "select count(*) from notes where body like '%rolled back%'"));
}
