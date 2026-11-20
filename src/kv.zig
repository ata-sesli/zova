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

/// Selects one page of a namespace for `scan`. All bounds compare raw key
/// bytes: a shorter key sorts before every longer key it is a prefix of.
pub const ScanOptions = struct {
    /// Only keys that begin with these bytes. Empty matches every key.
    prefix: []const u8 = "",
    /// Inclusive lower bound, or null for no lower bound.
    start: ?[]const u8 = null,
    /// Exclusive upper bound, or null for no upper bound.
    end: ?[]const u8 = null,
    /// Continue strictly after this key: pass the last key of the previous page.
    after: ?[]const u8 = null,
    /// Most entries returned; must be greater than zero.
    limit: usize,
    /// Return keys only; every `Entry.value` is then empty and unread.
    keys_only: bool = false,
};

/// One caller-owned scanned entry.
pub const Entry = struct {
    key: []u8,
    value: []u8,

    pub fn deinit(self: *const Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

/// One caller-owned scan page in ascending key byte order. `has_more` is
/// true when at least one further entry matches the same options.
pub const ScanResult = struct {
    entries: []Entry,
    has_more: bool,

    pub fn deinit(self: *const ScanResult, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
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
            try stmt.expectDone();
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
            try stmt.expectDone();
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
        try stmt.expectDone();

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
            try stmt.expectDone();
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
        try stmt.expectDone();

        try finishMutation(self, scope);
        committed = true;
    }

    /// Return one page of a namespace in ascending key byte order.
    ///
    /// The page holds at most `options.limit` entries matching every given
    /// bound. Each call prepares, reads and finalizes its own statement and
    /// holds nothing between pages; continue by passing the last returned key
    /// as `after`. Writes between pages are visible to later pages.
    pub fn scan(self: *Database, allocator: std.mem.Allocator, namespace: []const u8, options: ScanOptions) Error!ScanResult {
        if (options.limit == 0) return error.InvalidArgument;
        const query_limit = std.math.cast(i64, std.math.add(usize, options.limit, 1) catch return error.InvalidArgument) orelse
            return error.InvalidArgument;

        // Reduce every bound to one inclusive lower and one exclusive upper key,
        // so the statement is a single range read on the primary key.
        var lower: []const u8 = options.start orelse "";
        if (std.mem.order(u8, options.prefix, lower) == .gt) lower = options.prefix;
        var after_successor: []u8 = &.{};
        defer allocator.free(after_successor);
        if (options.after) |after| {
            // The smallest key greater than `after` is `after` followed by 0x00.
            after_successor = try allocator.alloc(u8, after.len + 1);
            @memcpy(after_successor[0..after.len], after);
            after_successor[after.len] = 0;
            if (std.mem.order(u8, after_successor, lower) == .gt) lower = after_successor;
        }
        const prefix_end = try prefixUpperBound(allocator, options.prefix);
        defer if (prefix_end) |bound| allocator.free(bound);
        var upper = options.end;
        if (prefix_end) |bound| {
            if (upper == null or std.mem.order(u8, bound, upper.?) == .lt) upper = bound;
        }
        if (upper) |bound| {
            if (std.mem.order(u8, lower, bound) != .lt) {
                return .{ .entries = try allocator.alloc(Entry, 0), .has_more = false };
            }
        }

        var stmt = try self.sqlite_db.prepare(switch (@as(u2, @intFromBool(options.keys_only)) << 1 | @intFromBool(upper != null)) {
            0b00 => "select key, value from _zova_kv where namespace = ?1 and key >= ?2 order by key limit ?4",
            0b01 => "select key, value from _zova_kv where namespace = ?1 and key >= ?2 and key < ?3 order by key limit ?4",
            0b10 => "select key from _zova_kv where namespace = ?1 and key >= ?2 order by key limit ?4",
            0b11 => "select key from _zova_kv where namespace = ?1 and key >= ?2 and key < ?3 order by key limit ?4",
        });
        defer stmt.deinit();
        try stmt.bindBlobBorrowed(1, namespace);
        try stmt.bindBlobBorrowed(2, lower);
        if (upper) |bound| try stmt.bindBlobBorrowed(3, bound);
        try stmt.bindInt64(4, query_limit);

        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }
        var has_more = false;
        while ((try stmt.step()) == .row) {
            if (entries.items.len == options.limit) {
                has_more = true;
                break;
            }
            const key = try allocator.dupe(u8, stmt.columnBlob(0));
            errdefer allocator.free(key);
            const value = if (options.keys_only) try allocator.alloc(u8, 0) else try allocator.dupe(u8, stmt.columnBlob(1));
            errdefer allocator.free(value);
            try entries.append(allocator, .{ .key = key, .value = value });
        }
        return .{ .entries = try entries.toOwnedSlice(allocator), .has_more = has_more };
    }

    /// Insert one entry only when its key is absent. Returns whether it was written.
    pub fn putIfAbsent(self: *Database, namespace: []const u8, key: []const u8, value: []const u8) Error!bool {
        return self.conditionalWrite(
            "insert into _zova_kv (namespace, key, value) values (?1, ?2, ?3) on conflict(namespace, key) do nothing",
            &.{ namespace, key, value },
        );
    }

    /// Replace one value only when the current value equals `expected`
    /// byte for byte. A missing key never matches. Returns whether it was written.
    pub fn compareAndPut(self: *Database, namespace: []const u8, key: []const u8, expected: []const u8, value: []const u8) Error!bool {
        return self.conditionalWrite(
            "update _zova_kv set value = ?4 where namespace = ?1 and key = ?2 and value = ?3",
            &.{ namespace, key, expected, value },
        );
    }

    /// Delete one entry only when its current value equals `expected` byte
    /// for byte. A missing key never matches. Returns whether it was deleted.
    pub fn compareAndDelete(self: *Database, namespace: []const u8, key: []const u8, expected: []const u8) Error!bool {
        return self.conditionalWrite(
            "delete from _zova_kv where namespace = ?1 and key = ?2 and value = ?3",
            &.{ namespace, key, expected },
        );
    }

    /// One conditional statement, atomic like every other KV mutation; its
    /// condition and write are evaluated by SQLite as a single step.
    fn conditionalWrite(self: *Database, comptime sql: [:0]const u8, arguments: []const []const u8) Error!bool {
        const scope = try beginMutation(self);
        var committed = false;
        errdefer if (!committed) rollbackMutation(self, scope) catch {};

        var stmt = try self.sqlite_db.prepare(sql);
        defer stmt.deinit();
        for (arguments, 1..) |argument, index| try stmt.bindBlob(@intCast(index), argument);
        try stmt.expectDone();
        const applied = self.sqlite_db.changes() == 1;

        try finishMutation(self, scope);
        committed = true;
        return applied;
    }
};

/// The smallest key greater than every key starting with `prefix`, or null
/// when no such key exists (an empty prefix or one made only of 0xff bytes).
fn prefixUpperBound(allocator: std.mem.Allocator, prefix: []const u8) Error!?[]u8 {
    var end = prefix.len;
    while (end > 0 and prefix[end - 1] == 0xff) end -= 1;
    if (end == 0) return null;
    const bound = try allocator.dupe(u8, prefix[0..end]);
    bound[end - 1] += 1;
    return bound;
}

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
