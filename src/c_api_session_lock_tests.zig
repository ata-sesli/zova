const std = @import("std");
const api = @import("c_api_internal.zig");
const handles = @import("c_api/handles.zig");

const Pause = struct {
    entered: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),

    fn hook(context: ?*anyopaque) void {
        const self: *Pause = @ptrCast(@alignCast(context.?));
        if (self.entered.swap(true, .acq_rel)) return;
        while (!self.proceed.load(.acquire)) std.atomic.spinLoopHint();
    }

    fn wait(self: *Pause) void {
        while (!self.entered.load(.acquire)) std.atomic.spinLoopHint();
    }
};

test "ordinary call rechecks exclusion after a concurrent fresh begin" {
    var db: ?*api.zova_database = null;
    try std.testing.expectEqual(api.zova_status.OK, api.zova_database_create_memory(&.{ .out_db = &db, .out_error_message = null }));
    defer _ = api.zova_database_close(db);
    try std.testing.expectEqual(api.zova_status.OK, api.zova_database_exec(&.{ .db = db, .sql = "create table records(id integer)" }));
    const handle = handles.databaseHandleRaw(db).?;
    var pause: Pause = .{};
    handle.mutex.before_lock = Pause.hook;
    handle.mutex.before_lock_context = &pause;
    defer handle.mutex.before_lock = null;
    const Worker = struct {
        fn run(database: ?*api.zova_database, result: *api.zova_status) void {
            result.* = api.zova_database_exec(&.{ .db = database, .sql = "insert into records values(1)" });
        }
    };
    var result: api.zova_status = .OK;
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ db, &result });
    var joined = false;
    defer if (!joined) {
        pause.proceed.store(true, .release);
        thread.join();
    };
    pause.wait();
    var build: ?*api.zova_fresh_build = null;
    try std.testing.expectEqual(api.zova_status.OK, api.zova_fresh_build_begin(&.{ .db = db, .out_build = &build }));
    defer api.zova_fresh_build_destroy(build);
    pause.proceed.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expectEqual(api.zova_status.INVALID_ARGUMENT, result);
    try std.testing.expectEqual(api.zova_status.OK, api.zova_fresh_build_abort(build));
    // Once the session ends the ordinary call is allowed again.
    try std.testing.expectEqual(api.zova_status.OK, api.zova_database_exec(&.{ .db = db, .sql = "insert into records values(2)" }));
}

test "fresh operation rechecks active state after concurrent abort" {
    var db: ?*api.zova_database = null;
    try std.testing.expectEqual(api.zova_status.OK, api.zova_database_create_memory(&.{ .out_db = &db, .out_error_message = null }));
    defer _ = api.zova_database_close(db);
    var build: ?*api.zova_fresh_build = null;
    try std.testing.expectEqual(api.zova_status.OK, api.zova_fresh_build_begin(&.{ .db = db, .out_build = &build }));
    defer api.zova_fresh_build_destroy(build);
    const handle = handles.databaseHandleRaw(db).?;
    var pause: Pause = .{};
    handle.mutex.before_lock = Pause.hook;
    handle.mutex.before_lock_context = &pause;
    defer handle.mutex.before_lock = null;
    const Worker = struct {
        fn run(session: ?*api.zova_fresh_build, result: *api.zova_status) void {
            result.* = api.zova_fresh_build_abort(session);
        }
    };
    var result: api.zova_status = .OK;
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ build, &result });
    var joined = false;
    defer if (!joined) {
        pause.proceed.store(true, .release);
        thread.join();
    };
    pause.wait();
    try std.testing.expectEqual(api.zova_status.OK, api.zova_fresh_build_abort(build));
    pause.proceed.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expectEqual(api.zova_status.INVALID_ARGUMENT, result);
}
