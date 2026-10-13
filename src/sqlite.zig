//! Thin SQLite wrapper for Zova v0.
//!
//! This module deliberately stays close to SQLite's C API. It owns database
//! and statement handles, maps a small set of common result codes into Zig
//! errors, exposes explicit transaction helpers, and keeps raw SQLite access
//! available through `sqlite.c`.
//!
//! Object storage, vector storage, migrations, Zova system tables, ORM
//! behavior, query building, async behavior, and connection pooling are
//! intentionally absent from this module today. Plain SQLite usage should not
//! require Zova-specific schema setup.
//!
//! The stable v0 package surface is `zova.sqlite`. Database paths stay
//! zero-terminated, `deinit` keeps assert-style close behavior, transaction
//! helpers stay manual, and raw result-code/debug needs should use
//! `errorMessage()` or the public `sqlite.c` escape hatch.
//!
//! Zova v0 is not a stricter, distributed, or more concurrent SQL dialect. It
//! does not alter SQLite PRAGMAs on open; callers remain responsible for
//! connection settings such as journal mode, synchronous mode, and foreign
//! keys. The vendored SQLite build keeps FTS5 enabled and relies on modern
//! SQLite's built-in JSON support.

const std = @import("std");

/// Raw SQLite C bindings.
///
/// Zova keeps this public on purpose: the wrapper below covers the common
/// v0 lifecycle, statement, and transaction paths, but callers can still drop
/// down to SQLite directly when they need an API Zova does not wrap yet.
pub const c = @import("sqlite_c");

/// Error set for the small public SQLite wrapper.
///
/// The wrapper maps common SQLite result codes to named Zig errors and folds
/// everything else into `SqliteError` until Zova needs more detail.
pub const Error = error{
    SqliteError,
    InvalidArgument,
    Busy,
    Locked,
    Constraint,
    CantOpen,
    Misuse,
    NoMemory,
    Interrupt,
    ReadOnly,
    Corrupt,
};

fn sqlAfterTrivia(sql: []const u8) []const u8 {
    var rest = sql;
    while (rest.len != 0) {
        rest = std.mem.trimStart(u8, rest, " \t\n\r\x0b\x0c");
        if (std.mem.startsWith(u8, rest, "--")) {
            const newline = std.mem.indexOfScalar(u8, rest, '\n') orelse return "";
            rest = rest[newline + 1 ..];
        } else if (std.mem.startsWith(u8, rest, "/*")) {
            const end = std.mem.indexOf(u8, rest[2..], "*/") orelse return "";
            rest = rest[end + 4 ..];
        } else break;
    }
    return rest;
}

/// Return the runtime SQLite library version used by this build.
pub fn version() []const u8 {
    return std.mem.span(c.sqlite3_libversion());
}

/// Return UTF-8 text from a SQLite scalar function callback.
///
/// Zig cannot safely use SQLite's `SQLITE_TRANSIENT` function-pointer macro
/// directly, so this makes a SQLite-owned copy and asks SQLite to free it.
pub fn resultText(ctx: *c.sqlite3_context, value: []const u8) void {
    const raw_copy = c.sqlite3_malloc64(@intCast(value.len + 1)) orelse {
        c.sqlite3_result_error_nomem(ctx);
        return;
    };
    const copy: [*]u8 = @ptrCast(raw_copy);
    @memcpy(copy[0..value.len], value);
    copy[value.len] = 0;

    c.sqlite3_result_text64(
        ctx,
        copy,
        @intCast(value.len),
        c.sqlite3_free,
        c.SQLITE_UTF8,
    );
}

/// Return blob bytes from a SQLite scalar function callback.
///
/// Non-empty blobs are copied into SQLite-owned memory. Empty blobs use
/// SQLite's zeroblob API so they stay zero-length blobs instead of SQL NULL.
pub fn resultBlob(ctx: *c.sqlite3_context, value: []const u8) void {
    if (value.len == 0) {
        _ = c.sqlite3_result_zeroblob64(ctx, 0);
        return;
    }

    const raw_copy = c.sqlite3_malloc64(@intCast(value.len)) orelse {
        c.sqlite3_result_error_nomem(ctx);
        return;
    };
    const copy: [*]u8 = @ptrCast(raw_copy);
    @memcpy(copy[0..value.len], value);

    c.sqlite3_result_blob64(ctx, copy, @intCast(value.len), c.sqlite3_free);
}

/// Explicit SQLite open mode used when callers need to avoid SQLite's default
/// create-on-open behavior.
pub const OpenFlags = enum {
    /// Open an existing database for reads and writes.
    read_write,
    /// Open an existing database for reads only.
    read_only,
};

/// Owns one SQLite database connection.
///
/// `Database` is a thin owner around `sqlite3*`. It does not hide SQL, build
/// queries, or manage schemas. Callers prepare and execute normal SQLite SQL,
/// while Zova centralizes handle ownership and result-code mapping.
pub const Database = struct {
    handle: *c.sqlite3,
    // Engine-owned connection-local SQL facilities. Not a SQLite handle or
    // plugin author surface; cleanup runs after SQLite releases callbacks.
    extension_sql_state: ?*anyopaque = null,
    extension_sql_cleanup: ?*const fn (?*anyopaque) void = null,

    /// Open a SQLite database at `path`.
    ///
    /// `path` is zero-terminated to match SQLite's C API. Use `":memory:"` for
    /// an in-memory database. v0 intentionally keeps this as the only open API
    /// and does not add an `openZ` alias or allocator-based path helper.
    pub fn open(path: [:0]const u8) Error!Database {
        var raw_db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &raw_db);
        if (rc != c.SQLITE_OK) {
            if (raw_db) |db| {
                _ = c.sqlite3_close(db);
            }
            return mapResultCode(rc);
        }

        return .{ .handle = raw_db.? };
    }

    /// Open an existing SQLite database with explicit SQLite flags.
    ///
    /// Plain `open` intentionally preserves SQLite's convenient default of
    /// creating a missing file. Use this when the caller needs read-only open
    /// behavior or wants missing files to fail.
    pub fn openWithFlags(path: [:0]const u8, flags: OpenFlags) Error!Database {
        var raw_db: ?*c.sqlite3 = null;
        const sqlite_flags: c_int = switch (flags) {
            .read_write => c.SQLITE_OPEN_READWRITE,
            .read_only => c.SQLITE_OPEN_READONLY,
        };
        const rc = c.sqlite3_open_v2(path.ptr, &raw_db, sqlite_flags, null);
        if (rc != c.SQLITE_OK) {
            if (raw_db) |db| {
                _ = c.sqlite3_close(db);
            }
            return mapResultCode(rc);
        }

        return .{ .handle = raw_db.? };
    }

    /// Close the database connection.
    ///
    /// In v0 this asserts that all statements have already been finalized.
    /// Leaving statements alive at database close is treated as programmer
    /// misuse rather than a recoverable runtime condition. v0 does not expose
    /// a fallible close API.
    pub fn deinit(self: *Database) void {
        const rc = c.sqlite3_close(self.handle);
        std.debug.assert(rc == c.SQLITE_OK);
        if (self.extension_sql_cleanup) |cleanup| cleanup(self.extension_sql_state);
        self.extension_sql_state = null;
        self.extension_sql_cleanup = null;
    }

    /// Execute SQL that does not need bound parameters or returned rows.
    pub fn exec(self: *Database, sql: [:0]const u8) Error!void {
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Attach another SQLite database under a compile-time schema name.
    ///
    /// This helper is intentionally narrow: the schema name is not a caller
    /// string, while the path is bound as data. Zova uses this for internal
    /// bound object stores without exposing a SQL-identifier escaping API.
    pub fn attachDatabase(self: *Database, path: []const u8, comptime schema_name: []const u8) Error!void {
        comptime validateInternalSchemaName(schema_name);

        var sql_buffer: [128]u8 = undefined;
        const sql = std.fmt.bufPrintSentinel(&sql_buffer, "attach database ? as {s}", .{schema_name}, 0) catch unreachable;

        var stmt = try self.prepare(sql);
        defer stmt.deinit();

        try stmt.bindText(1, path);
        try stmt.expectDone();
    }

    /// Detach a database previously attached with `attachDatabase`.
    pub fn detachDatabase(self: *Database, comptime schema_name: []const u8) Error!void {
        comptime validateInternalSchemaName(schema_name);

        var sql_buffer: [64]u8 = undefined;
        const sql = std.fmt.bufPrintSentinel(&sql_buffer, "detach database {s}", .{schema_name}, 0) catch unreachable;
        try self.exec(sql);
    }

    /// Set SQLite's connection-local query-only mode.
    ///
    /// This does not mutate the database file; it asks SQLite to reject write
    /// statements on this connection.
    pub fn setQueryOnly(self: *Database, enabled: bool) Error!void {
        if (enabled) {
            try self.exec("pragma query_only = on");
        } else {
            try self.exec("pragma query_only = off");
        }
    }

    /// Start a deferred SQLite transaction.
    ///
    /// This is a thin wrapper over `begin`; nested transaction behavior,
    /// locking, and failure modes are SQLite's normal semantics.
    pub fn begin(self: *Database) Error!void {
        try self.exec("begin");
    }

    /// Start an immediate SQLite transaction.
    ///
    /// This acquires the write lock up front, which is often the clearer
    /// default for storage code that knows it is about to write. Locking and
    /// busy behavior follow SQLite's normal `begin immediate` semantics.
    pub fn beginImmediate(self: *Database) Error!void {
        try self.exec("begin immediate");
    }

    /// Commit the active transaction using SQLite's normal `commit` semantics.
    pub fn commit(self: *Database) Error!void {
        try self.exec("commit");
    }

    /// Roll back the active transaction using SQLite's normal `rollback` semantics.
    pub fn rollback(self: *Database) Error!void {
        try self.exec("rollback");
    }

    /// Create a named SQLite savepoint.
    ///
    /// Savepoint names are validated as plain ASCII identifiers before SQL is
    /// built: 1-64 bytes, first byte `[A-Za-z_]`, remaining bytes
    /// `[A-Za-z0-9_]`, and not the reserved `_zova_` prefix.
    pub fn savepoint(self: *Database, name: []const u8) Error!void {
        try self.execSavepoint("savepoint", name);
    }

    /// Roll back changes made after a named SQLite savepoint.
    ///
    /// SQLite keeps the savepoint active after `ROLLBACK TO`; call
    /// `releaseSavepoint` when the checkpoint should be removed.
    pub fn rollbackToSavepoint(self: *Database, name: []const u8) Error!void {
        try self.execSavepoint("rollback to", name);
    }

    /// Release a named SQLite savepoint.
    pub fn releaseSavepoint(self: *Database, name: []const u8) Error!void {
        try self.execSavepoint("release", name);
    }

    fn execSavepoint(self: *Database, comptime prefix: []const u8, name: []const u8) Error!void {
        try validateSavepointName(name);
        var sql_buffer: [96]u8 = undefined;
        const sql = std.fmt.bufPrintSentinel(&sql_buffer, prefix ++ " {s}", .{name}, 0) catch unreachable;
        try self.exec(sql);
    }

    /// Set SQLite's busy timeout in milliseconds.
    ///
    /// Passing 0 clears the busy handler, matching SQLite's C API.
    pub fn setBusyTimeout(self: *Database, milliseconds: u32) Error!void {
        if (milliseconds > std.math.maxInt(c_int)) return error.Misuse;
        const rc = c.sqlite3_busy_timeout(self.handle, @intCast(milliseconds));
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Prepare SQL for repeated execution or bound parameters.
    ///
    /// The returned statement borrows this database connection. Finalize it
    /// with `Statement.deinit` before closing the database.
    pub fn prepare(self: *Database, sql: [:0]const u8) Error!Statement {
        var raw_stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &raw_stmt, null);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);

        return .{
            .db = self,
            .handle = raw_stmt.?,
        };
    }

    /// Prepare exactly one statement. Empty/comment-only input and additional
    /// statements are rejected without stepping anything. Trailing comments
    /// and whitespace are allowed. The caller still owns execution policy.
    pub fn prepareSingle(self: *Database, sql: [:0]const u8) Error!Statement {
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidArgument;
        var raw_stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &raw_stmt, &tail);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
        const handle = raw_stmt orelse return error.InvalidArgument;
        errdefer _ = c.sqlite3_finalize(handle);
        // Never prepare rejected trailing SQL: some PRAGMAs have effects even
        // during preparation. Only whitespace/comments may follow the statement.
        if (tail != null and sqlAfterTrivia(std.mem.span(tail)).len != 0) return error.InvalidArgument;
        return .{ .db = self, .handle = handle };
    }

    /// Strict single SELECT/WITH query, rejecting preparation-time PRAGMAs
    /// before SQLite sees them. WITH mutations are rejected before execution.
    /// Side-effecting user functions remain the caller's responsibility.
    pub fn prepareReadQuery(self: *Database, sql: [:0]const u8) Error!Statement {
        const text = sqlAfterTrivia(sql);
        var end: usize = 0;
        while (end < text.len and std.ascii.isAlphabetic(text[end])) : (end += 1) {}
        if (!std.ascii.eqlIgnoreCase(text[0..end], "SELECT") and !std.ascii.eqlIgnoreCase(text[0..end], "WITH")) return error.InvalidArgument;
        var stmt = try self.prepareSingle(sql);
        errdefer stmt.deinit();
        if (!stmt.isReadOnly() or stmt.columnCount() == 0) return error.InvalidArgument;
        return stmt;
    }

    /// Single data statement, never preparation-time PRAGMAs or DDL. Storage
    /// ownership must additionally be enforced by a scoped authorizer.
    pub fn prepareDml(self: *Database, sql: [:0]const u8) Error!Statement {
        const text = sqlAfterTrivia(sql);
        var end: usize = 0;
        while (end < text.len and std.ascii.isAlphabetic(text[end])) : (end += 1) {}
        for ([_][]const u8{ "SELECT", "WITH", "INSERT", "UPDATE", "DELETE" }) |keyword| {
            if (std.ascii.eqlIgnoreCase(text[0..end], keyword)) return self.prepareSingle(sql);
        }
        return error.InvalidArgument;
    }

    /// Connection-scoped authorization. The caller exclusively owns this
    /// connection and must clear the callback after all statements finalize.
    pub fn setAuthorizer(self: *Database, callback: ?*const fn (?*anyopaque, c_int, [*c]const u8, [*c]const u8, [*c]const u8, [*c]const u8) callconv(.c) c_int, context: ?*anyopaque) Error!void {
        const rc = c.sqlite3_set_authorizer(self.handle, callback, context);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Number of rows modified by the most recent INSERT, UPDATE, or DELETE.
    pub fn changes(self: *Database) i64 {
        return @intCast(c.sqlite3_changes64(self.handle));
    }

    /// Total number of rows modified by INSERT, UPDATE, or DELETE on this connection.
    pub fn totalChanges(self: *Database) i64 {
        return @intCast(c.sqlite3_total_changes64(self.handle));
    }

    /// Rowid from the most recent successful INSERT on this connection.
    pub fn lastInsertRowId(self: *Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Current SQLite error message for this connection.
    ///
    /// The slice is owned by SQLite and should be treated as borrowed.
    pub fn errorMessage(self: *Database) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }
};

/// Read-only incremental access to one SQLite BLOB row.
///
/// The handle is deliberately limited to the SQLite primitive. Callers must
/// supply the active schema, table, column, and rowid; higher-level storage
/// code keeps those private and never returns the rowid to its callers. A
/// successful open pins the connection's read snapshot until the handle is
/// closed or the connection is closed.
pub const Blob = struct {
    db: *Database,
    handle: ?*c.sqlite3_blob,
    size: usize,

    pub fn open(
        db: *Database,
        schema_name: [:0]const u8,
        table_name: [:0]const u8,
        column_name: [:0]const u8,
        rowid: i64,
    ) Error!Blob {
        if (rowid <= 0) return error.InvalidArgument;

        var raw_blob: ?*c.sqlite3_blob = null;
        const rc = c.sqlite3_blob_open(
            db.handle,
            schema_name.ptr,
            table_name.ptr,
            column_name.ptr,
            rowid,
            0,
            &raw_blob,
        );
        if (rc != c.SQLITE_OK) return mapResultCode(rc);

        const handle = raw_blob orelse return error.NoMemory;
        const size = c.sqlite3_blob_bytes(handle);
        if (size < 0) {
            _ = c.sqlite3_blob_close(handle);
            return error.SqliteError;
        }
        return .{ .db = db, .handle = handle, .size = @intCast(size) };
    }

    /// Return the current BLOB length.
    pub fn bytes(self: *const Blob) Error!usize {
        const handle = self.handle orelse return error.Misuse;
        const size = c.sqlite3_blob_bytes(handle);
        if (size < 0) return error.SqliteError;
        return @intCast(size);
    }

    /// Read bytes at an in-range offset without allocating.
    pub fn read(self: *Blob, destination: []u8, offset: u64) Error!void {
        const handle = self.handle orelse return error.Misuse;
        if (offset > self.size) return error.InvalidArgument;
        const offset_usize: usize = @intCast(offset);
        if (destination.len > self.size - offset_usize) return error.InvalidArgument;
        if (destination.len == 0) return;
        if (destination.len > std.math.maxInt(c_int) or offset > std.math.maxInt(c_int)) {
            return error.InvalidArgument;
        }

        const rc = c.sqlite3_blob_read(
            handle,
            destination.ptr,
            @intCast(destination.len),
            @intCast(offset),
        );
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Move the read-only handle to another row in the same table/column.
    pub fn reopen(self: *Blob, rowid: i64) Error!void {
        const handle = self.handle orelse return error.Misuse;
        if (rowid <= 0) return error.InvalidArgument;
        const rc = c.sqlite3_blob_reopen(handle, rowid);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
        const size = c.sqlite3_blob_bytes(handle);
        if (size < 0) return error.SqliteError;
        self.size = @intCast(size);
    }

    /// Close the handle. SQLite closes it even when close reports an error.
    pub fn close(self: *Blob) Error!void {
        const handle = self.handle orelse return;
        self.handle = null;
        self.size = 0;
        const rc = c.sqlite3_blob_close(handle);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Idempotent cleanup for error paths and deferred destruction.
    pub fn deinit(self: *Blob) void {
        self.close() catch {};
    }
};

fn validateSavepointName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > 64) return error.InvalidArgument;
    if (hasReservedZovaPrefix(name)) return error.InvalidArgument;
    if (!isAsciiIdentStart(name[0])) return error.InvalidArgument;
    for (name[1..]) |byte| {
        if (!isAsciiIdentContinue(byte)) return error.InvalidArgument;
    }
}

fn validateInternalSchemaName(comptime name: []const u8) void {
    if (name.len == 0) @compileError("schema name must not be empty");
    if (!isAsciiIdentStart(name[0])) @compileError("schema name must start with an identifier byte");
    for (name[1..]) |byte| {
        if (!isAsciiIdentContinue(byte)) @compileError("schema name must be an identifier");
    }
}

fn hasReservedZovaPrefix(name: []const u8) bool {
    const reserved = "_zova_";
    if (name.len < reserved.len) return false;
    for (reserved, 0..) |expected, index| {
        if (asciiLower(name[index]) != expected) return false;
    }
    return true;
}

fn isAsciiIdentStart(byte: u8) bool {
    return byte == '_' or (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}

fn isAsciiIdentContinue(byte: u8) bool {
    return isAsciiIdentStart(byte) or (byte >= '0' and byte <= '9');
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

/// Result of advancing a prepared statement.
pub const Step = enum {
    /// The statement produced a row, and column accessors may be used.
    row,
    /// The statement finished without producing another row.
    done,
};

/// SQLite's five fundamental runtime column types.
///
/// This is the Zig shape of `sqlite3_column_type`. The value is most useful
/// before calling accessors that may perform SQLite type conversion.
pub const ColumnType = enum {
    integer,
    float,
    text,
    blob,
    null,
};

/// Owns one prepared SQLite statement.
///
/// A statement borrows its parent database and must be finalized with
/// `deinit`. Column slices returned from this type are borrowed from SQLite
/// and are valid only until the statement is stepped, reset, or finalized.
pub const Statement = struct {
    db: *Database,
    handle: *c.sqlite3_stmt,

    /// Finalize the prepared statement.
    ///
    /// SQLite returns the previous `step` error from `sqlite3_finalize`, so
    /// cleanup intentionally ignores the result. Callers should observe
    /// execution errors from `step`, not from deferred cleanup.
    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    /// SQLite's statement classification, not a sandbox against side-effecting
    /// user functions or all PRAGMAs. Inspect before stepping the statement.
    pub fn isReadOnly(self: *Statement) bool {
        return c.sqlite3_stmt_readonly(self.handle) != 0;
    }

    /// Detect SQLite allocation failure after converting a column value.
    pub fn checkColumnError(self: *Statement) Error!void {
        if (c.sqlite3_errcode(self.db.handle) == c.SQLITE_NOMEM) return error.NoMemory;
    }

    /// Bind a signed 64-bit integer to a 1-based SQL parameter index.
    pub fn bindInt64(self: *Statement, index: c_int, value: i64) Error!void {
        const rc = c.sqlite3_bind_int64(self.handle, index, value);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Bind SQL NULL to a 1-based SQL parameter index.
    pub fn bindNull(self: *Statement, index: c_int) Error!void {
        const rc = c.sqlite3_bind_null(self.handle, index);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Bind a 64-bit floating point value to a 1-based SQL parameter index.
    pub fn bindDouble(self: *Statement, index: c_int, value: f64) Error!void {
        const rc = c.sqlite3_bind_double(self.handle, index, value);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Bind UTF-8 text to a 1-based SQL parameter index.
    ///
    /// The input slice does not need to outlive this call. Zig cannot safely
    /// use SQLite's `SQLITE_TRANSIENT` function-pointer macro directly, so
    /// Zova makes a SQLite-owned copy and asks SQLite to free it when done.
    pub fn bindText(self: *Statement, index: c_int, value: []const u8) Error!void {
        const raw_copy = c.sqlite3_malloc64(@intCast(value.len + 1)) orelse return error.NoMemory;
        const copy: [*]u8 = @ptrCast(raw_copy);
        @memcpy(copy[0..value.len], value);
        copy[value.len] = 0;

        const rc = c.sqlite3_bind_text64(
            self.handle,
            index,
            copy,
            @intCast(value.len),
            c.sqlite3_free,
            c.SQLITE_UTF8,
        );
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Borrows `value` until this parameter is rebound, its bindings are
    /// cleared, or the statement is finalized. The caller must keep the bytes
    /// valid and unchanged for that lifetime.
    pub fn bindTextBorrowed(self: *Statement, index: c_int, value: []const u8) Error!void {
        const bytes: []const u8 = if (value.len == 0) "" else value;
        const rc = c.sqlite3_bind_text64(
            self.handle,
            index,
            bytes.ptr,
            @intCast(bytes.len),
            null,
            c.SQLITE_UTF8,
        );
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Bind blob bytes to a 1-based SQL parameter index.
    ///
    /// The input slice does not need to outlive this call. Non-empty blobs are
    /// copied into SQLite-owned memory. Empty blobs use SQLite's zeroblob API
    /// so they stay zero-length blobs instead of becoming SQL NULL.
    pub fn bindBlob(self: *Statement, index: c_int, value: []const u8) Error!void {
        if (value.len == 0) {
            const rc = c.sqlite3_bind_zeroblob64(self.handle, index, 0);
            if (rc != c.SQLITE_OK) return mapResultCode(rc);
            return;
        }

        const raw_copy = c.sqlite3_malloc64(@intCast(value.len)) orelse return error.NoMemory;
        const copy: [*]u8 = @ptrCast(raw_copy);
        @memcpy(copy[0..value.len], value);

        const rc = c.sqlite3_bind_blob64(
            self.handle,
            index,
            copy,
            @intCast(value.len),
            c.sqlite3_free,
        );
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Bind blob bytes without copying them.
    ///
    /// The caller must keep `value` alive and unchanged until this parameter
    /// is rebound or the statement is finalized. Resetting a statement keeps
    /// the borrowed binding active. Empty values are bound as zero-length
    /// blobs and do not borrow caller memory.
    pub fn bindBlobBorrowed(self: *Statement, index: c_int, value: []const u8) Error!void {
        if (value.len == 0) {
            const rc = c.sqlite3_bind_zeroblob64(self.handle, index, 0);
            if (rc != c.SQLITE_OK) return mapResultCode(rc);
            return;
        }
        const rc = c.sqlite3_bind_blob64(self.handle, index, value.ptr, @intCast(value.len), null);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Advance the statement once.
    ///
    /// Returns `.row` when a result row is available and `.done` when the
    /// statement has completed.
    pub fn step(self: *Statement) Error!Step {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => mapResultCode(rc),
        };
    }

    /// Step a statement that must not produce a row.
    ///
    /// Returns `error.SqliteError` when a row is available instead.
    pub fn expectDone(self: *Statement) Error!void {
        switch (try self.step()) {
            .done => {},
            .row => return error.SqliteError,
        }
    }

    /// Reset the statement so it can be executed again.
    ///
    /// Existing bindings are preserved, matching SQLite's behavior. Use
    /// `clearBindings` when the next execution should start unbound.
    pub fn reset(self: *Statement) Error!void {
        const rc = c.sqlite3_reset(self.handle);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Clear all currently bound SQL parameters on the statement.
    pub fn clearBindings(self: *Statement) Error!void {
        const rc = c.sqlite3_clear_bindings(self.handle);
        if (rc != c.SQLITE_OK) return mapResultCode(rc);
    }

    /// Read a 0-based column from the current row as a signed 64-bit integer.
    ///
    /// Like SQLite's column APIs, this does not validate the index. Callers are
    /// responsible for passing a valid column index for the current row.
    pub fn columnInt64(self: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    /// Read a 0-based column from the current row as a 64-bit floating point value.
    ///
    /// Like SQLite's column APIs, this does not validate the index. Callers are
    /// responsible for passing a valid column index for the current row.
    pub fn columnDouble(self: *Statement, index: c_int) f64 {
        return c.sqlite3_column_double(self.handle, index);
    }

    /// Read a 0-based column from the current row as UTF-8 text.
    ///
    /// The returned slice is borrowed from SQLite. It remains valid until the
    /// next `step`, `reset`, or `deinit` on this statement. Call this only
    /// after `step` returns `.row`. Like SQLite's column APIs, this does not
    /// validate the index.
    pub fn columnText(self: *Statement, index: c_int) []const u8 {
        // SQLite documents this order as the safe way to force text conversion
        // before asking for the converted byte length.
        const ptr = c.sqlite3_column_text(self.handle, index);
        const bytes = c.sqlite3_column_bytes(self.handle, index);
        if (ptr == null or bytes <= 0) return "";

        const many: [*]const u8 = @ptrCast(ptr);
        return many[0..@intCast(bytes)];
    }

    /// Read a 0-based column from the current row as blob bytes.
    ///
    /// The returned slice is borrowed from SQLite. It remains valid until the
    /// next `step`, `reset`, or `deinit` on this statement. Call this only
    /// after `step` returns `.row`. Like SQLite's column APIs, this does not
    /// validate the index.
    pub fn columnBlob(self: *Statement, index: c_int) []const u8 {
        const ptr = c.sqlite3_column_blob(self.handle, index);
        const bytes = c.sqlite3_column_bytes(self.handle, index);
        if (ptr == null or bytes <= 0) return "";

        const many: [*]const u8 = @ptrCast(ptr);
        return many[0..@intCast(bytes)];
    }

    /// Return the runtime SQLite type of a column in the current row.
    ///
    /// Column indexes are 0-based. For the most precise result, call this
    /// before using accessors that may ask SQLite to convert the value.
    pub fn columnType(self: *Statement, index: c_int) ColumnType {
        return switch (c.sqlite3_column_type(self.handle, index)) {
            c.SQLITE_INTEGER => .integer,
            c.SQLITE_FLOAT => .float,
            c.SQLITE_TEXT => .text,
            c.SQLITE_BLOB => .blob,
            c.SQLITE_NULL => .null,
            else => unreachable,
        };
    }

    /// Return the number of columns produced by this statement.
    pub fn columnCount(self: *Statement) c_int {
        return c.sqlite3_column_count(self.handle);
    }

    /// Return the 0-based column name for a prepared statement result column.
    ///
    /// The returned slice is borrowed from SQLite and is valid until the
    /// statement is finalized or automatically reprepared. This validates the
    /// index before calling SQLite so bindings can surface clean misuse errors.
    pub fn columnName(self: *Statement, index: c_int) Error![]const u8 {
        if (index < 0 or index >= self.columnCount()) return error.Misuse;
        const ptr = c.sqlite3_column_name(self.handle, index) orelse return error.NoMemory;
        return std.mem.span(ptr);
    }

    /// Return the number of SQL parameters in this statement.
    pub fn parameterCount(self: *Statement) c_int {
        return c.sqlite3_bind_parameter_count(self.handle);
    }

    /// Return the 1-based index for a named SQL parameter.
    ///
    /// `name` must include SQLite's parameter prefix, such as `":id"`.
    /// SQLite returns `0` when the name is not present.
    pub fn parameterIndex(self: *Statement, name: [:0]const u8) c_int {
        return c.sqlite3_bind_parameter_index(self.handle, name.ptr);
    }
};

/// Convert a SQLite result code into Zova's small v0 error set.
fn mapResultCode(rc: c_int) Error {
    return switch (rc) {
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_CANTOPEN => error.CantOpen,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_NOMEM => error.NoMemory,
        c.SQLITE_INTERRUPT => error.Interrupt,
        c.SQLITE_READONLY => error.ReadOnly,
        c.SQLITE_CORRUPT => error.Corrupt,
        else => error.SqliteError,
    };
}

test "result code mapping covers locked misuse and generic errors" {
    try std.testing.expectEqual(error.Locked, mapResultCode(c.SQLITE_LOCKED));
    try std.testing.expectEqual(error.Misuse, mapResultCode(c.SQLITE_MISUSE));
    try std.testing.expectEqual(error.NoMemory, mapResultCode(c.SQLITE_NOMEM));
    try std.testing.expectEqual(error.Interrupt, mapResultCode(c.SQLITE_INTERRUPT));
    try std.testing.expectEqual(error.ReadOnly, mapResultCode(c.SQLITE_READONLY));
    try std.testing.expectEqual(error.Corrupt, mapResultCode(c.SQLITE_CORRUPT));
    try std.testing.expectEqual(error.SqliteError, mapResultCode(c.SQLITE_ERROR));
}

comptime {
    if (@import("builtin").is_test) _ = @import("sqlite_tests.zig");
}
