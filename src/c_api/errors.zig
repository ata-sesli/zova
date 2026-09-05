//! C ABI status mapping and connection-owned diagnostic messages.

const std = @import("std");
const sqlite = @import("../sqlite.zig");
const zova_version = @import("../version.zig");

const DatabaseHandle = @import("handles.zig").DatabaseHandle;
const allocator = @import("values.zig").allocator;
const databaseHandle = @import("handles.zig").databaseHandle;
const zova_database = @import("types.zig").zova_database;
const zova_message = @import("types.zig").zova_message;
const zova_message_free = @import("results.zig").zova_message_free;
const zova_status = @import("types.zig").zova_status;

pub fn zova_abi_version_major() callconv(.c) u32 {
    return zova_version.abi_version_major;
}

pub fn zova_abi_version_minor() callconv(.c) u32 {
    return zova_version.abi_version_minor;
}

pub fn zova_abi_version_patch() callconv(.c) u32 {
    return zova_version.abi_version_patch;
}

pub fn zova_abi_version_string() callconv(.c) [*:0]const u8 {
    return zova_version.abi_version_string;
}

// Accept a raw integer instead of a Zig enum so accidental or future C enum
// values cannot trigger a Zig enum safety check.

pub fn zova_status_name(status: c_int) callconv(.c) [*:0]const u8 {
    return statusName(status);
}

// Free functions are null-safe and reset containers. That makes repeated frees
// harmless for callers that follow the container API instead of freeing fields.

pub fn zova_database_last_error_message(db: ?*zova_database) callconv(.c) [*:0]const u8 {
    const handle = databaseHandle(db) orelse return "invalid database handle";
    handle.mutex.lock();
    defer handle.mutex.unlock();
    if (handle.last_error) |message| return message.ptr;
    return "";
}

// No-handle operations cannot use connection-scoped diagnostics, so request
// structs optionally carry an owned zova_message for callers that want details.

pub fn failDb(handle: *DatabaseHandle, err: anyerror) zova_status {
    const status = statusFromError(err);
    setLastError(handle, err);
    return status;
}

pub fn failDbSqliteResult(handle: *DatabaseHandle, rc: c_int) zova_status {
    const sqlite_message = handle.db.errorMessage();
    if (!std.mem.eql(u8, sqlite_message, "not an error") and sqlite_message.len > 0) {
        setLastErrorString(handle, sqlite_message);
    } else {
        setLastErrorString(handle, "SQLite error");
    }
    return statusFromSqliteResultCode(rc);
}

pub fn failDbStatusString(handle: *DatabaseHandle, status: zova_status, message: []const u8) zova_status {
    setLastErrorString(handle, message);
    return status;
}

pub fn okDb(handle: *DatabaseHandle) zova_status {
    clearLastError(handle);
    return .OK;
}

pub fn failMessage(message: ?*zova_message, err: anyerror) zova_status {
    setMessage(message, @errorName(err));
    return statusFromError(err);
}

// Prefer SQLite's detailed connection error when it has one; fall back to the
// Zig error name for Zova-native failures or argument validation.

fn setLastError(handle: *DatabaseHandle, err: anyerror) void {
    const sqlite_message = handle.db.errorMessage();
    if (!std.mem.eql(u8, sqlite_message, "not an error") and sqlite_message.len > 0) {
        setLastErrorString(handle, sqlite_message);
    } else {
        setLastErrorString(handle, @errorName(err));
    }
}

fn setLastErrorString(handle: *DatabaseHandle, message: []const u8) void {
    clearLastError(handle);
    handle.last_error = allocator.dupeZ(u8, message) catch null;
}

pub fn clearLastError(handle: *DatabaseHandle) void {
    if (handle.last_error) |message| {
        allocator.free(message);
    }
    handle.last_error = null;
}

fn setMessage(message: ?*zova_message, text: []const u8) void {
    const out = message orelse return;
    clearMessage(out);
    const copy = allocator.dupeZ(u8, text) catch return;
    out.* = .{ .data = copy.ptr, .len = text.len };
}

pub fn clearMessage(message: ?*zova_message) void {
    const out = message orelse return;
    zova_message_free(out);
}

// This is the only error translation table for the ABI. New public Zova errors
// should be considered here deliberately instead of leaking as SQLITE_ERROR.

fn statusFromError(err: anyerror) zova_status {
    return switch (err) {
        error.OutOfMemory, error.NoMemory => .OUT_OF_MEMORY,
        error.Busy => .BUSY,
        error.Locked => .LOCKED,
        error.Constraint => .CONSTRAINT,
        error.CantOpen => .CANT_OPEN,
        error.ReadOnly => .READ_ONLY,
        error.Corrupt => .CORRUPT,
        error.Misuse => .MISUSE,
        error.NotZovaPath => .NOT_ZOVA_PATH,
        error.NotZovaDatabase => .NOT_ZOVA_DATABASE,
        error.UnsupportedZovaVersion => .UNSUPPORTED_ZOVA_VERSION,
        error.MigrationRequired => .MIGRATION_REQUIRED,
        error.UnsupportedLegacyFormat => .UNSUPPORTED_LEGACY_FORMAT,
        error.UnsupportedFutureFormat => .UNSUPPORTED_FUTURE_FORMAT,
        error.NoMigrationPath => .NO_MIGRATION_PATH,
        error.DestinationExists => .DESTINATION_EXISTS,
        error.ZovaNameConflict => .ZOVA_NAME_CONFLICT,
        error.ObjectNotFound => .OBJECT_NOT_FOUND,
        error.ObjectAlreadyExists => .OBJECT_ALREADY_EXISTS,
        error.ObjectChunkNotFound => .OBJECT_CHUNK_NOT_FOUND,
        error.ObjectChunkHashMismatch => .OBJECT_CHUNK_HASH_MISMATCH,
        error.ObjectCorrupt => .OBJECT_CORRUPT,
        error.ObjectManifestInvalid => .OBJECT_MANIFEST_INVALID,
        error.ObjectRangeInvalid => .OBJECT_RANGE_INVALID,
        error.ObjectTooLarge => .OBJECT_TOO_LARGE,
        error.ObjectTransactionActive => .OBJECT_TRANSACTION_ACTIVE,
        error.ObjectWriterClosed => .OBJECT_WRITER_CLOSED,
        error.ObjectReaderClosed => .OBJECT_READER_CLOSED,
        error.BoundStoreExists => .BOUND_STORE_EXISTS,
        error.BoundStoreNotFound => .BOUND_STORE_NOT_FOUND,
        error.BoundStoreInvalid => .BOUND_STORE_INVALID,
        error.VectorCollectionExists => .VECTOR_COLLECTION_EXISTS,
        error.VectorCollectionNotFound => .VECTOR_COLLECTION_NOT_FOUND,
        error.VectorNotFound => .VECTOR_NOT_FOUND,
        error.VectorDimensionMismatch => .VECTOR_DIMENSION_MISMATCH,
        error.VectorCorrupt => .VECTOR_CORRUPT,
        error.VectorInvalid => .VECTOR_INVALID,
        error.GraphExists => .GRAPH_EXISTS,
        error.GraphNotFound => .GRAPH_NOT_FOUND,
        error.GraphNodeNotFound => .GRAPH_NODE_NOT_FOUND,
        error.GraphEdgeNotFound => .GRAPH_EDGE_NOT_FOUND,
        error.GraphInvalid => .GRAPH_INVALID,
        error.ExtensionNotFound => .EXTENSION_NOT_FOUND,
        error.ExtensionExists => .EXTENSION_EXISTS,
        error.ExtensionInvalid => .EXTENSION_INVALID,
        error.ExtensionIncompatible => .EXTENSION_INCOMPATIBLE,
        error.ExtensionUnavailable => .EXTENSION_UNAVAILABLE,
        error.ExtensionUntrusted => .EXTENSION_UNAVAILABLE,
        error.ExtensionLoadFailed => .EXTENSION_UNAVAILABLE,
        error.KvTooLarge => .KV_TOO_LARGE,
        error.KvCorrupt => .KV_CORRUPT,
        error.InvalidArgument => .INVALID_ARGUMENT,
        else => .SQLITE_ERROR,
    };
}

fn statusFromSqliteResultCode(rc: c_int) zova_status {
    return switch (rc) {
        sqlite.c.SQLITE_OK => .OK,
        sqlite.c.SQLITE_BUSY => .BUSY,
        sqlite.c.SQLITE_LOCKED => .LOCKED,
        sqlite.c.SQLITE_CONSTRAINT => .CONSTRAINT,
        sqlite.c.SQLITE_CANTOPEN => .CANT_OPEN,
        sqlite.c.SQLITE_READONLY => .READ_ONLY,
        sqlite.c.SQLITE_CORRUPT => .CORRUPT,
        sqlite.c.SQLITE_MISUSE => .MISUSE,
        sqlite.c.SQLITE_NOMEM => .OUT_OF_MEMORY,
        else => .SQLITE_ERROR,
    };
}

fn statusName(status: c_int) [*:0]const u8 {
    return switch (status) {
        @intFromEnum(zova_status.OK) => "ZOVA_OK",
        @intFromEnum(zova_status.INVALID_ARGUMENT) => "ZOVA_INVALID_ARGUMENT",
        @intFromEnum(zova_status.OUT_OF_MEMORY) => "ZOVA_OUT_OF_MEMORY",
        @intFromEnum(zova_status.BUSY) => "ZOVA_BUSY",
        @intFromEnum(zova_status.LOCKED) => "ZOVA_LOCKED",
        @intFromEnum(zova_status.CONSTRAINT) => "ZOVA_CONSTRAINT",
        @intFromEnum(zova_status.CANT_OPEN) => "ZOVA_CANT_OPEN",
        @intFromEnum(zova_status.READ_ONLY) => "ZOVA_READ_ONLY",
        @intFromEnum(zova_status.CORRUPT) => "ZOVA_CORRUPT",
        @intFromEnum(zova_status.MISUSE) => "ZOVA_MISUSE",
        @intFromEnum(zova_status.SQLITE_ERROR) => "ZOVA_SQLITE_ERROR",
        @intFromEnum(zova_status.NOT_ZOVA_PATH) => "ZOVA_NOT_ZOVA_PATH",
        @intFromEnum(zova_status.NOT_ZOVA_DATABASE) => "ZOVA_NOT_ZOVA_DATABASE",
        @intFromEnum(zova_status.UNSUPPORTED_ZOVA_VERSION) => "ZOVA_UNSUPPORTED_ZOVA_VERSION",
        @intFromEnum(zova_status.DESTINATION_EXISTS) => "ZOVA_DESTINATION_EXISTS",
        @intFromEnum(zova_status.ZOVA_NAME_CONFLICT) => "ZOVA_ZOVA_NAME_CONFLICT",
        @intFromEnum(zova_status.MIGRATION_REQUIRED) => "ZOVA_MIGRATION_REQUIRED",
        @intFromEnum(zova_status.UNSUPPORTED_FUTURE_FORMAT) => "ZOVA_UNSUPPORTED_FUTURE_FORMAT",
        @intFromEnum(zova_status.UNSUPPORTED_LEGACY_FORMAT) => "ZOVA_UNSUPPORTED_LEGACY_FORMAT",
        @intFromEnum(zova_status.NO_MIGRATION_PATH) => "ZOVA_NO_MIGRATION_PATH",
        @intFromEnum(zova_status.OBJECT_NOT_FOUND) => "ZOVA_OBJECT_NOT_FOUND",
        @intFromEnum(zova_status.OBJECT_ALREADY_EXISTS) => "ZOVA_OBJECT_ALREADY_EXISTS",
        @intFromEnum(zova_status.OBJECT_CHUNK_NOT_FOUND) => "ZOVA_OBJECT_CHUNK_NOT_FOUND",
        @intFromEnum(zova_status.OBJECT_CHUNK_HASH_MISMATCH) => "ZOVA_OBJECT_CHUNK_HASH_MISMATCH",
        @intFromEnum(zova_status.OBJECT_CORRUPT) => "ZOVA_OBJECT_CORRUPT",
        @intFromEnum(zova_status.OBJECT_MANIFEST_INVALID) => "ZOVA_OBJECT_MANIFEST_INVALID",
        @intFromEnum(zova_status.OBJECT_RANGE_INVALID) => "ZOVA_OBJECT_RANGE_INVALID",
        @intFromEnum(zova_status.OBJECT_TOO_LARGE) => "ZOVA_OBJECT_TOO_LARGE",
        @intFromEnum(zova_status.OBJECT_TRANSACTION_ACTIVE) => "ZOVA_OBJECT_TRANSACTION_ACTIVE",
        @intFromEnum(zova_status.OBJECT_WRITER_CLOSED) => "ZOVA_OBJECT_WRITER_CLOSED",
        @intFromEnum(zova_status.OBJECT_READER_CLOSED) => "ZOVA_OBJECT_READER_CLOSED",
        @intFromEnum(zova_status.BOUND_STORE_EXISTS) => "ZOVA_BOUND_STORE_EXISTS",
        @intFromEnum(zova_status.BOUND_STORE_NOT_FOUND) => "ZOVA_BOUND_STORE_NOT_FOUND",
        @intFromEnum(zova_status.BOUND_STORE_INVALID) => "ZOVA_BOUND_STORE_INVALID",
        @intFromEnum(zova_status.VECTOR_COLLECTION_EXISTS) => "ZOVA_VECTOR_COLLECTION_EXISTS",
        @intFromEnum(zova_status.VECTOR_COLLECTION_NOT_FOUND) => "ZOVA_VECTOR_COLLECTION_NOT_FOUND",
        @intFromEnum(zova_status.VECTOR_NOT_FOUND) => "ZOVA_VECTOR_NOT_FOUND",
        @intFromEnum(zova_status.VECTOR_DIMENSION_MISMATCH) => "ZOVA_VECTOR_DIMENSION_MISMATCH",
        @intFromEnum(zova_status.VECTOR_CORRUPT) => "ZOVA_VECTOR_CORRUPT",
        @intFromEnum(zova_status.VECTOR_INVALID) => "ZOVA_VECTOR_INVALID",
        @intFromEnum(zova_status.GRAPH_EXISTS) => "ZOVA_GRAPH_EXISTS",
        @intFromEnum(zova_status.GRAPH_NOT_FOUND) => "ZOVA_GRAPH_NOT_FOUND",
        @intFromEnum(zova_status.GRAPH_NODE_NOT_FOUND) => "ZOVA_GRAPH_NODE_NOT_FOUND",
        @intFromEnum(zova_status.GRAPH_EDGE_NOT_FOUND) => "ZOVA_GRAPH_EDGE_NOT_FOUND",
        @intFromEnum(zova_status.GRAPH_INVALID) => "ZOVA_GRAPH_INVALID",
        @intFromEnum(zova_status.EXTENSION_NOT_FOUND) => "ZOVA_EXTENSION_NOT_FOUND",
        @intFromEnum(zova_status.EXTENSION_EXISTS) => "ZOVA_EXTENSION_EXISTS",
        @intFromEnum(zova_status.EXTENSION_INVALID) => "ZOVA_EXTENSION_INVALID",
        @intFromEnum(zova_status.EXTENSION_INCOMPATIBLE) => "ZOVA_EXTENSION_INCOMPATIBLE",
        @intFromEnum(zova_status.EXTENSION_UNAVAILABLE) => "ZOVA_EXTENSION_UNAVAILABLE",
        @intFromEnum(zova_status.KV_TOO_LARGE) => "ZOVA_KV_TOO_LARGE",
        @intFromEnum(zova_status.KV_CORRUPT) => "ZOVA_KV_CORRUPT",
        else => "ZOVA_UNKNOWN_STATUS",
    };
}
