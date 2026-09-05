//! Native transactional key-value subsystem over SQLite.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova_error = @import("zova_error.zig");

pub const Error = zova_error.Error;

pub const kv_table = "_zova_kv";
pub const kv_schema_sql =
    \\create table _zova_kv (
    \\  namespace blob not null,
    \\  key blob not null,
    \\  value blob not null,
    \\  primary key (namespace, key)
    \\) without rowid
;

/// One result for a single `get`.
///
/// `value` is caller-owned (allocator-provided) and empty when `found` is
/// false. Missing keys are not an error.
pub const GetResult = struct {
    found: bool,
    value: []u8,

    pub fn deinit(self: *const GetResult, allocator: std.mem.Allocator) void {
        if (self.found) allocator.free(self.value);
    }
};

/// One batch `put` entry. Key and value are borrowed for the call only.
pub const PutEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// How an atomic key-value batch scopes its writes.
///
/// An operation that owns the transaction uses a real SQLite transaction. An
/// operation that joins a caller-owned transaction uses an internal savepoint
/// so a failed batch rolls back only its own partial mutations while leaving
/// the caller's prior work intact.
const KvMutationScope = enum { transaction, savepoint };
const kv_batch_savepoint = "zova_kv_batch";

const SingleStatement = enum {
    get,
    put,

    fn sql(comptime self: SingleStatement) [:0]const u8 {
        return switch (self) {
            .get => "select value from _zova_kv where namespace = ? and key = ?",
            .put => "insert into _zova_kv (namespace, key, value) values (?, ?, ?) " ++
                "on conflict(namespace, key) do update set value = excluded.value",
        };
    }
};

/// Private, bounded KV cache owned by the Zova connection, not the temporary
/// subsystem facade. Raw handles avoid retaining pointers to a moved owner.
/// Uses the connection's existing external serialization; this is not a lock.
pub const StatementCache = struct {
    get: ?*sqlite.c.sqlite3_stmt = null,
    put: ?*sqlite.c.sqlite3_stmt = null,

    pub fn deinit(self: *StatementCache) void {
        if (self.get) |handle| _ = sqlite.c.sqlite3_finalize(handle);
        if (self.put) |handle| _ = sqlite.c.sqlite3_finalize(handle);
        self.* = .{};
    }
};

const StatementLease = struct {
    statement: sqlite.Statement,
    slot: ?*?*sqlite.c.sqlite3_stmt,

    fn release(self: *StatementLease) void {
        // Reset ends active reads; clearing releases all parameter allocations.
        // On any cleanup error discard the VM instead of caching bad state.
        self.statement.reset() catch {
            self.statement.deinit();
            return;
        };
        self.statement.clearBindings() catch {
            self.statement.deinit();
            return;
        };
        if (self.slot) |slot| {
            if (slot.* == null) {
                slot.* = self.statement.handle;
                return;
            }
        }
        // A nested call may have populated the slot while this lease was out.
        self.statement.deinit();
    }
};

/// The `_zova_kv` key-value table is a private Zova-owned representation.
/// Zova does not expose or stabilize its schema name.
pub const Database = struct {
    sqlite_db: *sqlite.Database,
    statement_cache: ?*StatementCache = null,

    fn acquire(self: *Database, comptime kind: SingleStatement) Error!StatementLease {
        const slot: ?*?*sqlite.c.sqlite3_stmt = if (self.statement_cache) |cache| switch (kind) {
            .get => &cache.get,
            .put => &cache.put,
        } else null;
        if (slot) |entry| {
            if (entry.*) |handle| {
                // Check out before entering SQLite, so a nested call never
                // resets or rebinds an in-flight statement.
                entry.* = null;
                return .{ .statement = .{ .db = self.sqlite_db, .handle = handle }, .slot = slot };
            }
        }
        // prepare_v2 statements automatically recompile on schema changes.
        // A failed step is discarded by release when reset reports its error.
        return .{ .statement = try self.sqlite_db.prepare(kind.sql()), .slot = slot };
    }

    /// Load one value by opaque byte namespace and key.
    ///
    /// Missing keys return `found = false`, not an error. Byte comparison is
    /// exact; Zova never normalizes or re-encodes namespace, key, or value.
    pub fn get(
        self: *Database,
        allocator: std.mem.Allocator,
        namespace: []const u8,
        key: []const u8,
    ) Error!GetResult {
        var lease = try self.acquire(.get);
        defer lease.release();
        const stmt = &lease.statement;

        try stmt.bindBlob(1, namespace);
        try stmt.bindBlob(2, key);

        return switch (try stmt.step()) {
            .done => .{ .found = false, .value = &.{} },
            .row => .{ .found = true, .value = try allocator.dupe(u8, stmt.columnBlob(0)) },
        };
    }

    /// Load many values. Results align with the input order and preserve
    /// duplicate keys exactly. Missing keys return `found = false`.
    pub fn getMany(
        self: *Database,
        allocator: std.mem.Allocator,
        namespace: []const u8,
        keys: []const []const u8,
    ) Error![]GetResult {
        var results = try allocator.alloc(GetResult, keys.len);
        errdefer {
            for (results) |item| item.deinit(allocator);
            allocator.free(results);
        }
        for (results) |*item| item.* = .{ .found = false, .value = &.{} };

        if (keys.len == 0) return results;

        var stmt = try self.sqlite_db.prepare(
            \\select value from _zova_kv where namespace = ? and key = ?
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, namespace);
        for (keys, 0..) |key, index| {
            try stmt.bindBlob(2, key);
            results[index] = switch (try stmt.step()) {
                .done => .{ .found = false, .value = &.{} },
                .row => .{ .found = true, .value = try allocator.dupe(u8, stmt.columnBlob(0)) },
            };
            try stmt.reset();
        }
        return results;
    }

    /// Insert or replace one entry. Existing values for the same
    /// namespace/key are replaced atomically.
    pub fn put(self: *Database, namespace: []const u8, key: []const u8, value: []const u8) Error!void {
        const scope = try beginMutation(self);
        var committed = false;
        errdefer if (!committed) rollbackMutation(self, scope) catch {};

        {
            var lease = try self.acquire(.put);
            defer lease.release();
            const stmt = &lease.statement;
            try stmt.bindBlob(1, namespace);
            try stmt.bindBlob(2, key);
            try stmt.bindBlob(3, value);
            std.debug.assert((try stmt.step()) == .done);
        }

        try finishMutation(self, scope);
        committed = true;
    }

    /// Insert or replace many entries in one atomic operation.
    ///
    /// The whole batch validates before any mutation and either commits
    /// together or rolls back together. Empty batches are lock-free no-ops
    /// that succeed without acquiring a transaction. When the caller already
    /// owns a transaction, the batch joins it under an internal savepoint so
    /// a fault rolls back only this batch's partial mutations while
    /// preserving the caller's earlier work.
    pub fn putMany(self: *Database, namespace: []const u8, entries: []const PutEntry) Error!void {
        try validateBatchEntries(entries);
        if (entries.len == 0) return;

        const scope = try beginMutation(self);
        var committed = false;
        errdefer if (!committed) rollbackMutation(self, scope) catch {};

        var stmt = try self.sqlite_db.prepare(
            \\insert into _zova_kv (namespace, key, value) values (?, ?, ?)
            \\on conflict(namespace, key) do update set value = excluded.value
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, namespace);
        for (entries) |entry| {
            try stmt.bindBlob(2, entry.key);
            try stmt.bindBlob(3, entry.value);
            std.debug.assert((try stmt.step()) == .done);
            try stmt.reset();
        }

        try finishMutation(self, scope);
        committed = true;
    }

    /// Delete one entry. Missing keys are ignored for replay safety.
    pub fn delete(self: *Database, namespace: []const u8, key: []const u8) Error!void {
        const scope = try beginMutation(self);
        var committed = false;
        errdefer if (!committed) rollbackMutation(self, scope) catch {};

        var stmt = try self.sqlite_db.prepare(
            \\delete from _zova_kv where namespace = ? and key = ?
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, namespace);
        try stmt.bindBlob(2, key);
        std.debug.assert((try stmt.step()) == .done);

        try finishMutation(self, scope);
        committed = true;
    }

    /// Delete many entries in one atomic operation. Missing keys are
    /// ignored. Empty batches are lock-free no-ops that succeed without
    /// acquiring a transaction. Like `putMany`, a caller-owned transaction
    /// is joined under an internal savepoint so a fault rolls back only this
    /// batch's partial mutations.
    pub fn deleteMany(self: *Database, namespace: []const u8, keys: []const []const u8) Error!void {
        try validateBatchKeys(keys);
        if (keys.len == 0) return;

        const scope = try beginMutation(self);
        var committed = false;
        errdefer if (!committed) rollbackMutation(self, scope) catch {};

        var stmt = try self.sqlite_db.prepare(
            \\delete from _zova_kv where namespace = ? and key = ?
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, namespace);
        for (keys) |key| {
            try stmt.bindBlob(2, key);
            std.debug.assert((try stmt.step()) == .done);
            try stmt.reset();
        }

        try finishMutation(self, scope);
        committed = true;
    }

    /// Return the number of entries in one namespace.
    pub fn count(self: *Database, namespace: []const u8) Error!u64 {
        var stmt = try self.sqlite_db.prepare(
            \\select count(*) from _zova_kv where namespace = ?
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, namespace);
        std.debug.assert((try stmt.step()) == .row);
        return sqliteI64ToU64(stmt.columnInt64(0));
    }

    /// Delete every entry in one namespace.
    pub fn clearNamespace(self: *Database, namespace: []const u8) Error!void {
        const scope = try beginMutation(self);
        var committed = false;
        errdefer if (!committed) rollbackMutation(self, scope) catch {};

        var stmt = try self.sqlite_db.prepare(
            \\delete from _zova_kv where namespace = ?
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, namespace);
        std.debug.assert((try stmt.step()) == .done);

        try finishMutation(self, scope);
        committed = true;
    }
};

fn validateBatchEntries(entries: []const PutEntry) Error!void {
    for (entries) |entry| {
        _ = try usizeToSqliteI64(entry.key.len);
        _ = try usizeToSqliteI64(entry.value.len);
    }
}

fn validateBatchKeys(keys: []const []const u8) Error!void {
    for (keys) |key| {
        _ = try usizeToSqliteI64(key.len);
    }
}

fn beginMutation(self: *Database) Error!KvMutationScope {
    if (hasActiveTransaction(self.sqlite_db)) {
        try self.sqlite_db.savepoint(kv_batch_savepoint);
        return .savepoint;
    }
    try self.sqlite_db.beginImmediate();
    return .transaction;
}

fn finishMutation(self: *Database, scope: KvMutationScope) Error!void {
    switch (scope) {
        .transaction => try self.sqlite_db.commit(),
        .savepoint => try self.sqlite_db.releaseSavepoint(kv_batch_savepoint),
    }
}

fn rollbackMutation(self: *Database, scope: KvMutationScope) Error!void {
    switch (scope) {
        .transaction => try self.sqlite_db.rollback(),
        .savepoint => {
            try self.sqlite_db.rollbackToSavepoint(kv_batch_savepoint);
            try self.sqlite_db.releaseSavepoint(kv_batch_savepoint);
        },
    }
}

fn hasActiveTransaction(db: *sqlite.Database) bool {
    return sqlite.c.sqlite3_get_autocommit(db.handle) == 0 or
        sqlite.c.sqlite3_txn_state(db.handle, null) != sqlite.c.SQLITE_TXN_NONE;
}

fn usizeToSqliteI64(value: usize) Error!i64 {
    if (value > std.math.maxInt(i64)) return error.KvTooLarge;
    return @intCast(value);
}

fn sqliteI64ToU64(value: i64) Error!u64 {
    if (value < 0) return error.KvCorrupt;
    return @intCast(value);
}
