//! Database creation, opening, transactions, and maintenance entrypoint implementations.

const std = @import("std");
const zova = @import("../zova.zig");

const DatabaseHandle = @import("handles.zig").DatabaseHandle;
const ZOVA_BACKUP_NO_VERIFY = @import("types.zig").ZOVA_BACKUP_NO_VERIFY;
const ZOVA_COMPACT_NO_VERIFY = @import("types.zig").ZOVA_COMPACT_NO_VERIFY;
const ZOVA_MIGRATE_NO_VERIFY = @import("types.zig").ZOVA_MIGRATE_NO_VERIFY;
const ZOVA_OPEN_READ_ONLY = @import("types.zig").ZOVA_OPEN_READ_ONLY;
const ZOVA_PROGRESS_COPY = @import("types.zig").ZOVA_PROGRESS_COPY;
const ZOVA_PROGRESS_MIGRATE = @import("types.zig").ZOVA_PROGRESS_MIGRATE;
const ZOVA_PROGRESS_VERIFY = @import("types.zig").ZOVA_PROGRESS_VERIFY;
const ZOVA_PROGRESS_PUBLISH = @import("types.zig").ZOVA_PROGRESS_PUBLISH;
const ZOVA_PROGRESS_MEMBER_NONE = @import("types.zig").ZOVA_PROGRESS_MEMBER_NONE;
const ZOVA_PROGRESS_MEMBER_MAIN = @import("types.zig").ZOVA_PROGRESS_MEMBER_MAIN;
const ZOVA_PROGRESS_MEMBER_OBJECT_STORE = @import("types.zig").ZOVA_PROGRESS_MEMBER_OBJECT_STORE;
const ZOVA_PROGRESS_MEMBER_VECTOR_STORE = @import("types.zig").ZOVA_PROGRESS_MEMBER_VECTOR_STORE;
const ZOVA_PROGRESS_MEMBER_GRAPH_STORE = @import("types.zig").ZOVA_PROGRESS_MEMBER_GRAPH_STORE;
const ZOVA_RESTORE_NO_VERIFY = @import("types.zig").ZOVA_RESTORE_NO_VERIFY;
const allocator = @import("values.zig").allocator;
const bundlePathSlices = @import("extensions.zig").bundlePathSlices;
const clearLastError = @import("errors.zig").clearLastError;
const clearMessage = @import("errors.zig").clearMessage;
const lockDatabaseHandle = @import("handles.zig").lockDatabaseHandle;
const databaseHandleRaw = @import("handles.zig").databaseHandleRaw;
const deinitSqlFunctionRegistrations = @import("sql_functions.zig").deinitSqlFunctionRegistrations;
const failDb = @import("errors.zig").failDb;
const failDbStatusString = @import("errors.zig").failDbStatusString;
const failMessage = @import("errors.zig").failMessage;
const failMessageStatusString = @import("errors.zig").failMessageStatusString;
const okDb = @import("errors.zig").okDb;
const trustStoreOptions = @import("extensions.zig").trustStoreOptions;
const zova_convert_sqlite_to_zova_request = @import("types.zig").zova_convert_sqlite_to_zova_request;
const zova_database = @import("types.zig").zova_database;
const zova_database_backup_progress_request = @import("types.zig").zova_database_backup_progress_request;
const zova_database_backup_request = @import("types.zig").zova_database_backup_request;
const zova_database_busy_timeout_request = @import("types.zig").zova_database_busy_timeout_request;
const zova_database_changes_request = @import("types.zig").zova_database_changes_request;
const zova_database_compact_progress_request = @import("types.zig").zova_database_compact_progress_request;
const zova_database_compact_request = @import("types.zig").zova_database_compact_request;
const zova_database_reclaim_request = @import("types.zig").zova_database_reclaim_request;
const ZOVA_AUTO_VACUUM_FULL = @import("types.zig").ZOVA_AUTO_VACUUM_FULL;
const ZOVA_AUTO_VACUUM_INCREMENTAL = @import("types.zig").ZOVA_AUTO_VACUUM_INCREMENTAL;
const ZOVA_AUTO_VACUUM_NONE = @import("types.zig").ZOVA_AUTO_VACUUM_NONE;
const zova_database_create_memory_request = @import("types.zig").zova_database_create_memory_request;
const zova_database_create_options_request = @import("types.zig").zova_database_create_options_request;
const zova_database_exec_request = @import("types.zig").zova_database_exec_request;
const zova_database_last_insert_rowid_request = @import("types.zig").zova_database_last_insert_rowid_request;
const zova_database_migrate_extensions_request = @import("types.zig").zova_database_migrate_extensions_request;
const zova_database_migrate_progress_request = @import("types.zig").zova_database_migrate_progress_request;
const zova_progress = @import("types.zig").zova_progress;
const zova_progress_fn = @import("types.zig").zova_progress_fn;
const zova_database_migrate_request = @import("types.zig").zova_database_migrate_request;
const zova_database_open_extensions_request = @import("types.zig").zova_database_open_extensions_request;
const zova_database_open_options_request = @import("types.zig").zova_database_open_options_request;
const zova_database_open_plugins_request = @import("types.zig").zova_database_open_plugins_request;
const zova_plugin_descriptor_v1 = @import("types.zig").zova_plugin_descriptor_v1;
const zova_database_open_request = @import("types.zig").zova_database_open_request;
const zova_database_probe_format_request = @import("types.zig").zova_database_probe_format_request;
const zova_database_restore_request = @import("types.zig").zova_database_restore_request;
const zova_database_restore_to_memory_request = @import("types.zig").zova_database_restore_to_memory_request;
const zova_database_savepoint_request = @import("types.zig").zova_database_savepoint_request;
const zova_database_simple_request = @import("types.zig").zova_database_simple_request;
const zova_database_total_changes_request = @import("types.zig").zova_database_total_changes_request;
const zova_format_compatibility = @import("types.zig").zova_format_compatibility;
const zova_status = @import("types.zig").zova_status;

pub fn zova_database_create(request: ?*const zova_database_open_request) callconv(.c) zova_status {
    return openDatabase(request, .create);
}

pub fn zova_database_create_memory(request: ?*const zova_database_create_memory_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const out = req.out_db orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = null;

    var db = zova.Database.createMemory() catch |err| return failMessage(req.out_error_message, err);

    const handle = allocator.create(DatabaseHandle) catch |err| {
        db.deinit();
        return failMessage(req.out_error_message, err);
    };
    handle.* = .{ .db = db };
    out.* = @ptrCast(handle);
    return .OK;
}

pub fn zova_database_create_with_options(request: ?*const zova_database_create_options_request) callconv(.c) zova_status {
    return createDatabaseWithOptions(request);
}

pub fn zova_database_create_with_extensions(request: ?*const zova_database_open_extensions_request) callconv(.c) zova_status {
    return openDatabaseWithExtensions(request, .create, false);
}

pub fn zova_database_create_with_plugins(request: ?*const zova_database_open_plugins_request) callconv(.c) zova_status {
    return openDatabaseWithPlugins(request orelse return .INVALID_ARGUMENT, .create, false);
}

pub fn zova_database_open_with_plugins(request: ?*const zova_database_open_plugins_request) callconv(.c) zova_status {
    return openDatabaseWithPlugins(request orelse return .INVALID_ARGUMENT, .open, false);
}

pub fn zova_database_open_for_extension_upgrade_with_plugins(request: ?*const zova_database_open_plugins_request) callconv(.c) zova_status {
    return openDatabaseWithPlugins(request orelse return .INVALID_ARGUMENT, .open, true);
}

pub fn zova_database_open(request: ?*const zova_database_open_request) callconv(.c) zova_status {
    return openDatabase(request, .open);
}

pub fn zova_database_open_with_options(request: ?*const zova_database_open_options_request) callconv(.c) zova_status {
    return openDatabaseWithOptions(request);
}

pub fn zova_database_open_with_extensions(request: ?*const zova_database_open_extensions_request) callconv(.c) zova_status {
    return openDatabaseWithExtensions(request, .open, false);
}

pub fn zova_database_open_for_extension_upgrade(request: ?*const zova_database_open_extensions_request) callconv(.c) zova_status {
    return openDatabaseWithExtensions(request, .open, true);
}

pub fn zova_database_close(db: ?*zova_database) callconv(.c) zova_status {
    const handle = databaseHandleRaw(db) orelse return .INVALID_ARGUMENT;
    handle.mutex.lock();
    if (handle.live_statements != 0 or handle.live_writers != 0 or handle.live_readers != 0 or handle.live_subscriptions != 0 or handle.fresh_build_active) {
        defer handle.mutex.unlock();
        var message_buffer: [192]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "cannot close database with live child handles: {d} statements, {d} object writers, {d} object readers, {d} subscriptions, fresh build active={}",
            .{ handle.live_statements, handle.live_writers, handle.live_readers, handle.live_subscriptions, handle.fresh_build_active },
        ) catch "cannot close database with live child handles";
        return failDbStatusString(handle, .MISUSE, message);
    }
    clearLastError(handle);
    handle.db.deinit();
    if (handle.extension_registry) |*registry| registry.deinit();
    if (handle.dynamic_extensions) |*dynamic_extensions| dynamic_extensions.deinit();
    deinitSqlFunctionRegistrations(handle);
    handle.mutex.unlock();
    allocator.destroy(handle);
    return .OK;
}

pub fn zova_database_exec(request: ?*const zova_database_exec_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const sql = req.sql orelse return failDb(handle, error.InvalidArgument);
    handle.db.exec(std.mem.span(sql)) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_begin(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    handle.db.begin() catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_begin_immediate(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    handle.db.beginImmediate() catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_commit(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    handle.db.commit() catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_rollback(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    handle.db.rollback() catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return databaseSavepoint(request, .savepoint);
}

pub fn zova_database_rollback_to_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return databaseSavepoint(request, .rollback_to);
}

pub fn zova_database_release_savepoint(request: ?*const zova_database_savepoint_request) callconv(.c) zova_status {
    return databaseSavepoint(request, .release);
}

pub fn zova_database_vacuum(request: ?*const zova_database_simple_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    handle.db.vacuum() catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_backup(request: ?*const zova_database_backup_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    return zova_database_backup_with_progress(&.{
        .db = req.db,
        .destination_path = req.destination_path,
        .flags = req.flags,
    });
}

pub fn zova_database_backup_with_progress(request: ?*const zova_database_backup_progress_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const destination_path = req.destination_path orelse return failDb(handle, error.InvalidArgument);
    if ((req.flags & ~ZOVA_BACKUP_NO_VERIFY) != 0) return failDb(handle, error.InvalidArgument);

    var bridge: ProgressBridge = .{ .callback = req.progress, .user_data = req.progress_user_data };
    handle.db.backupTo(std.mem.span(destination_path), .{
        .verify = (req.flags & ZOVA_BACKUP_NO_VERIFY) == 0,
        .progress = bridge.zovaCallback(),
    }) catch |err| {
        if (bridge.cancelled) return failDbStatusString(handle, .INTERRUPTED, interrupted_message);
        return failDb(handle, err);
    };
    return okDb(handle);
}

pub fn zova_database_compact(request: ?*const zova_database_compact_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    return zova_database_compact_with_progress(&.{
        .db = req.db,
        .destination_path = req.destination_path,
        .flags = req.flags,
    });
}

pub fn zova_database_compact_with_progress(request: ?*const zova_database_compact_progress_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const destination_path = req.destination_path orelse return failDb(handle, error.InvalidArgument);
    if ((req.flags & ~ZOVA_COMPACT_NO_VERIFY) != 0) return failDb(handle, error.InvalidArgument);

    var bridge: ProgressBridge = .{ .callback = req.progress, .user_data = req.progress_user_data };
    handle.db.compactTo(std.mem.span(destination_path), .{
        .verify = (req.flags & ZOVA_COMPACT_NO_VERIFY) == 0,
        .progress = bridge.zovaCallback(),
    }) catch |err| {
        if (bridge.cancelled) return failDbStatusString(handle, .INTERRUPTED, interrupted_message);
        return failDb(handle, err);
    };
    return okDb(handle);
}

pub fn zova_database_reclaim(request: ?*const zova_database_reclaim_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_result orelse return failDb(handle, error.InvalidArgument);
    out.* = .{};
    const default_options: zova.ReclaimOptions = .{};
    const result = handle.db.reclaimSpace(.{
        .max_pages = req.max_pages,
        .step_pages = if (req.step_pages == 0) default_options.step_pages else req.step_pages,
    }) catch |err| return failDb(handle, err);
    for (result.members(), out.members[0..result.count]) |member, *entry| {
        entry.* = .{
            .member = switch (member.member) {
                .main => ZOVA_PROGRESS_MEMBER_MAIN,
                .object_store => ZOVA_PROGRESS_MEMBER_OBJECT_STORE,
                .vector_store => ZOVA_PROGRESS_MEMBER_VECTOR_STORE,
                .graph_store => ZOVA_PROGRESS_MEMBER_GRAPH_STORE,
            },
            .auto_vacuum = switch (member.auto_vacuum) {
                .none => ZOVA_AUTO_VACUUM_NONE,
                .full => ZOVA_AUTO_VACUUM_FULL,
                .incremental => ZOVA_AUTO_VACUUM_INCREMENTAL,
            },
            .page_size = member.page_size,
            .pages_released = member.pages_released,
            .free_pages_left = member.free_pages_left,
        };
    }
    out.member_count = result.count;
    return okDb(handle);
}

const interrupted_message = "operation cancelled by progress callback";

/// Adapts a C progress callback to `zova.ProgressCallback`.
///
/// The core reports verify once per item, so the bridge forwards only the
/// first event of each phase and member, whole-percent changes, and the event
/// that completes the group. A non-zero return cancels with `error.Interrupt`
/// and records that the caller asked for it, which keeps cancellation distinct
/// from an `error.Interrupt` raised by SQLite itself.
const ProgressBridge = struct {
    callback: ?zova_progress_fn,
    user_data: ?*anyopaque,
    cancelled: bool = false,
    last_phase: ?zova.ProgressPhase = null,
    last_member: ?zova.ProgressMember = null,
    last_percent: u64 = 0,

    fn zovaCallback(self: *ProgressBridge) ?zova.ProgressCallback {
        if (self.callback == null) return null;
        return .{ .context = self, .report = report };
    }

    fn report(context: ?*anyopaque, progress: zova.Progress) zova.Error!void {
        const self: *ProgressBridge = @ptrCast(@alignCast(context.?));
        const percent = if (progress.total == 0) 100 else progress.done * 100 / progress.total;
        const same_group = self.last_phase == progress.phase and self.last_member == progress.member;
        if (same_group and percent == self.last_percent and progress.done != progress.total) return;
        self.last_phase = progress.phase;
        self.last_member = progress.member;
        self.last_percent = percent;

        const event: zova_progress = .{
            .phase = switch (progress.phase) {
                .copy => ZOVA_PROGRESS_COPY,
                .migrate => ZOVA_PROGRESS_MIGRATE,
                .verify => ZOVA_PROGRESS_VERIFY,
                .publish => ZOVA_PROGRESS_PUBLISH,
            },
            .member = if (progress.member) |member| switch (member) {
                .main => ZOVA_PROGRESS_MEMBER_MAIN,
                .object_store => ZOVA_PROGRESS_MEMBER_OBJECT_STORE,
                .vector_store => ZOVA_PROGRESS_MEMBER_VECTOR_STORE,
                .graph_store => ZOVA_PROGRESS_MEMBER_GRAPH_STORE,
            } else ZOVA_PROGRESS_MEMBER_NONE,
            .done = progress.done,
            .total = progress.total,
        };
        if (self.callback.?(self.user_data, &event) != 0) {
            self.cancelled = true;
            return error.Interrupt;
        }
    }
};

pub fn zova_database_set_busy_timeout(request: ?*const zova_database_busy_timeout_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    if (req.milliseconds > std.math.maxInt(c_int)) return failDb(handle, error.InvalidArgument);
    handle.db.setBusyTimeout(req.milliseconds) catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_database_last_insert_rowid(request: ?*const zova_database_last_insert_rowid_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_rowid orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.lastInsertRowid();
    return okDb(handle);
}

pub fn zova_database_changes(request: ?*const zova_database_changes_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_changes orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.changes();
    return okDb(handle);
}

pub fn zova_database_total_changes(request: ?*const zova_database_total_changes_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const out = req.out_total_changes orelse return failDb(handle, error.InvalidArgument);
    out.* = handle.db.totalChanges();
    return okDb(handle);
}

const SavepointOperation = enum {
    savepoint,
    rollback_to,
    release,
};

fn databaseSavepoint(request: ?*const zova_database_savepoint_request, operation: SavepointOperation) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    const handle = lockDatabaseHandle(req.db) orelse return .INVALID_ARGUMENT;
    defer handle.mutex.unlock();
    const name = req.name orelse return failDb(handle, error.InvalidArgument);
    const result = switch (operation) {
        .savepoint => handle.db.savepoint(std.mem.span(name)),
        .rollback_to => handle.db.rollbackToSavepoint(std.mem.span(name)),
        .release => handle.db.releaseSavepoint(std.mem.span(name)),
    };
    result catch |err| return failDb(handle, err);
    return okDb(handle);
}

pub fn zova_convert_sqlite_to_zova(request: ?*const zova_convert_sqlite_to_zova_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const source_path = req.source_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    const dest_path = req.dest_path orelse return failMessage(req.out_error_message, error.InvalidArgument);

    zova.convertSqliteToZova(std.mem.span(source_path), std.mem.span(dest_path)) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    return .OK;
}

pub fn zova_database_restore(request: ?*const zova_database_restore_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const source_path = req.source_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    const destination_path = req.destination_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    if ((req.flags & ~ZOVA_RESTORE_NO_VERIFY) != 0) return failMessage(req.out_error_message, error.InvalidArgument);

    zova.restoreBackup(std.mem.span(source_path), std.mem.span(destination_path), .{
        .verify = (req.flags & ZOVA_RESTORE_NO_VERIFY) == 0,
    }) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    return .OK;
}

pub fn zova_database_probe_format(request: ?*const zova_database_probe_format_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const out = req.out_info orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = .{};
    const path = req.path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    const info = zova.probeDatabaseFormat(std.mem.span(path)) catch |err| return failMessage(req.out_error_message, err);
    const compat: c_int = switch (info.compatibility) {
        .current => @backingInt(zova_format_compatibility.CURRENT),
        .migratable => @backingInt(zova_format_compatibility.MIGRATABLE),
        .unsupported_legacy => @backingInt(zova_format_compatibility.UNSUPPORTED_LEGACY),
        .unsupported_future => @backingInt(zova_format_compatibility.UNSUPPORTED_FUTURE),
    };
    out.* = .{
        .format_version = info.format_version,
        .compatibility = compat,
    };
    return .OK;
}

pub fn zova_database_migrate(request: ?*const zova_database_migrate_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const source_path = req.source_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    const destination_path = req.destination_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    if ((req.flags & ~ZOVA_MIGRATE_NO_VERIFY) != 0) return failMessage(req.out_error_message, error.InvalidArgument);
    zova.migrateDatabaseWithExtensions(
        std.mem.span(source_path),
        std.mem.span(destination_path),
        .{ .verify = (req.flags & ZOVA_MIGRATE_NO_VERIFY) == 0 },
        zova.bundledExtensionRegistry(),
    ) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    return .OK;
}

pub fn zova_database_migrate_with_extensions(request: ?*const zova_database_migrate_extensions_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    return zova_database_migrate_with_progress(&.{
        .source_path = req.source_path,
        .destination_path = req.destination_path,
        .flags = req.flags,
        .extension_bundle_paths = req.extension_bundle_paths,
        .extension_bundle_count = req.extension_bundle_count,
        .trust_store_path = req.trust_store_path,
        .plugins = req.plugins,
        .plugin_count = req.plugin_count,
        .out_error_message = req.out_error_message,
    });
}

pub fn zova_database_migrate_with_progress(request: ?*const zova_database_migrate_progress_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const source_path = req.source_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    const destination_path = req.destination_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    if ((req.flags & ~ZOVA_MIGRATE_NO_VERIFY) != 0) return failMessage(req.out_error_message, error.InvalidArgument);
    const bundle_paths = bundlePathSlices(allocator, req.extension_bundle_paths, req.extension_bundle_count) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    defer allocator.free(bundle_paths);
    const plugins = pluginSlice(req.plugins, req.plugin_count) catch |err| return failMessage(req.out_error_message, err);

    var dynamic_extensions = zova.DynamicExtensionSet.loadWithPlugins(
        allocator,
        bundle_paths,
        trustStoreOptions(req.trust_store_path),
        plugins,
    ) catch |err| return failMessage(req.out_error_message, err);
    defer dynamic_extensions.deinit();
    var owned_registry = zova.DynamicExtensionOwnedRegistry.init(allocator, &.{
        zova.bundledExtensionRegistry(),
        dynamic_extensions.registry(),
    }) catch |err| return failMessage(req.out_error_message, err);
    defer owned_registry.deinit();

    var bridge: ProgressBridge = .{ .callback = req.progress, .user_data = req.progress_user_data };
    zova.migrateDatabaseWithExtensions(
        std.mem.span(source_path),
        std.mem.span(destination_path),
        .{
            .verify = (req.flags & ZOVA_MIGRATE_NO_VERIFY) == 0,
            .progress = bridge.zovaCallback(),
        },
        owned_registry.registry(),
    ) catch |err| {
        if (bridge.cancelled) return failMessageStatusString(req.out_error_message, .INTERRUPTED, interrupted_message);
        return failMessage(req.out_error_message, err);
    };
    return .OK;
}

fn pluginSlice(plugins: ?[*]const ?*const zova_plugin_descriptor_v1, count: usize) error{InvalidArgument}![]const ?*const zova_plugin_descriptor_v1 {
    if (count == 0) return &.{};
    const items = (plugins orelse return error.InvalidArgument)[0..count];
    for (items) |item| if (item == null) return error.InvalidArgument;
    return items;
}

pub fn zova_database_restore_to_memory(request: ?*const zova_database_restore_to_memory_request) callconv(.c) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const out = req.out_db orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = null;
    const source_path = req.source_path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    if ((req.flags & ~ZOVA_RESTORE_NO_VERIFY) != 0) return failMessage(req.out_error_message, error.InvalidArgument);

    var db = zova.restoreBackupToMemory(std.mem.span(source_path), .{
        .verify = (req.flags & ZOVA_RESTORE_NO_VERIFY) == 0,
    }) catch |err| return failMessage(req.out_error_message, err);

    const handle = allocator.create(DatabaseHandle) catch |err| {
        db.deinit();
        return failMessage(req.out_error_message, err);
    };
    handle.* = .{ .db = db };
    out.* = @ptrCast(handle);
    return .OK;
}

// The public helper name is not `zova_object_id`: in C, typedef names and
// function names share one namespace, so that would collide with the id type.

const OpenMode = enum { create, open };

fn openDatabase(request: ?*const zova_database_open_request, mode: OpenMode) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const out = req.out_db orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = null;
    const path = req.path orelse return failMessage(req.out_error_message, error.InvalidArgument);

    var db = switch (mode) {
        .create => zova.Database.create(std.mem.span(path)),
        .open => zova.Database.open(std.mem.span(path)),
    } catch |err| return failMessage(req.out_error_message, err);

    const handle = allocator.create(DatabaseHandle) catch |err| {
        db.deinit();
        return failMessage(req.out_error_message, err);
    };
    handle.* = .{ .db = db };
    out.* = @ptrCast(handle);
    return .OK;
}

fn createDatabaseWithOptions(request: ?*const zova_database_create_options_request) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const out = req.out_db orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = null;
    const path = req.path orelse return failMessage(req.out_error_message, error.InvalidArgument);

    var db = zova.Database.createWithOptions(std.mem.span(path), .{
        .page_size = req.page_size,
    }) catch |err| return failMessage(req.out_error_message, err);

    const handle = allocator.create(DatabaseHandle) catch |err| {
        db.deinit();
        return failMessage(req.out_error_message, err);
    };
    handle.* = .{ .db = db };
    out.* = @ptrCast(handle);
    return .OK;
}

fn openDatabaseWithOptions(request: ?*const zova_database_open_options_request) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    clearMessage(req.out_error_message);
    const out = req.out_db orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = null;
    const path = req.path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    if ((req.flags & ~ZOVA_OPEN_READ_ONLY) != 0) return failMessage(req.out_error_message, error.InvalidArgument);
    if (req.busy_timeout_ms > std.math.maxInt(c_int)) return failMessage(req.out_error_message, error.InvalidArgument);

    var db = zova.Database.openWithOptions(std.mem.span(path), .{
        .read_only = (req.flags & ZOVA_OPEN_READ_ONLY) != 0,
        .busy_timeout_ms = req.busy_timeout_ms,
    }) catch |err| return failMessage(req.out_error_message, err);

    const handle = allocator.create(DatabaseHandle) catch |err| {
        db.deinit();
        return failMessage(req.out_error_message, err);
    };
    handle.* = .{ .db = db };
    out.* = @ptrCast(handle);
    return .OK;
}

fn openDatabaseWithExtensions(request: ?*const zova_database_open_extensions_request, mode: OpenMode, for_upgrade: bool) zova_status {
    const req = request orelse return .INVALID_ARGUMENT;
    return openDatabaseWithPlugins(&.{
        .path = req.path,
        .flags = req.flags,
        .busy_timeout_ms = req.busy_timeout_ms,
        .extension_bundle_paths = req.extension_bundle_paths,
        .extension_bundle_count = req.extension_bundle_count,
        .trust_store_path = req.trust_store_path,
        .plugins = null,
        .plugin_count = 0,
        .out_db = req.out_db,
        .out_error_message = req.out_error_message,
    }, mode, for_upgrade);
}

fn openDatabaseWithPlugins(req: *const zova_database_open_plugins_request, mode: OpenMode, for_upgrade: bool) zova_status {
    clearMessage(req.out_error_message);
    const out = req.out_db orelse return failMessage(req.out_error_message, error.InvalidArgument);
    out.* = null;
    const path = req.path orelse return failMessage(req.out_error_message, error.InvalidArgument);
    if ((req.flags & ~ZOVA_OPEN_READ_ONLY) != 0) return failMessage(req.out_error_message, error.InvalidArgument);
    if (mode == .create and (req.flags != 0 or req.busy_timeout_ms != 0)) return failMessage(req.out_error_message, error.InvalidArgument);
    if (for_upgrade and req.flags != 0) return failMessage(req.out_error_message, error.InvalidArgument);
    if (req.busy_timeout_ms > std.math.maxInt(c_int)) return failMessage(req.out_error_message, error.InvalidArgument);

    const bundle_paths = bundlePathSlices(allocator, req.extension_bundle_paths, req.extension_bundle_count) catch |err| {
        return failMessage(req.out_error_message, err);
    };
    defer allocator.free(bundle_paths);
    const plugins = pluginSlice(req.plugins, req.plugin_count) catch |err| return failMessage(req.out_error_message, err);

    if (bundle_paths.len == 0 and plugins.len == 0 and !for_upgrade) {
        return switch (mode) {
            .create => openDatabase(&.{
                .path = req.path,
                .out_db = req.out_db,
                .out_error_message = req.out_error_message,
            }, .create),
            .open => openDatabaseWithOptions(&.{
                .path = req.path,
                .flags = req.flags,
                .busy_timeout_ms = req.busy_timeout_ms,
                .out_db = req.out_db,
                .out_error_message = req.out_error_message,
            }),
        };
    }

    var dynamic_extensions = zova.DynamicExtensionSet.loadWithPlugins(
        allocator,
        bundle_paths,
        trustStoreOptions(req.trust_store_path),
        plugins,
    ) catch |err| return failMessage(req.out_error_message, err);

    var owned_registry = zova.DynamicExtensionOwnedRegistry.init(allocator, &.{
        zova.bundledExtensionRegistry(),
        dynamic_extensions.registry(),
    }) catch |err| {
        dynamic_extensions.deinit();
        return failMessage(req.out_error_message, err);
    };

    var db = (if (for_upgrade) zova.Database.openForExtensionUpgradeWithExtensions(std.mem.span(path), .{
        .busy_timeout_ms = req.busy_timeout_ms,
    }, owned_registry.registry()) else switch (mode) {
        .create => zova.Database.createWithExtensions(std.mem.span(path), owned_registry.registry()),
        .open => zova.Database.openWithOptionsAndExtensions(std.mem.span(path), .{
            .read_only = (req.flags & ZOVA_OPEN_READ_ONLY) != 0,
            .busy_timeout_ms = req.busy_timeout_ms,
        }, owned_registry.registry()),
    }) catch |err| {
        owned_registry.deinit();
        dynamic_extensions.deinit();
        return failMessage(req.out_error_message, err);
    };

    const handle = allocator.create(DatabaseHandle) catch |err| {
        db.deinit();
        owned_registry.deinit();
        dynamic_extensions.deinit();
        return failMessage(req.out_error_message, err);
    };
    handle.* = .{
        .db = db,
        .dynamic_extensions = dynamic_extensions,
        .extension_registry = owned_registry,
    };
    out.* = @ptrCast(handle);
    return .OK;
}
