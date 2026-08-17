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

/// The `_zova_kv` key-value table is a private Zova-owned representation.
/// Zova does not expose or stabilize its schema name.
pub const Database = struct {
    sqlite_db: *sqlite.Database,

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
        var stmt = try self.sqlite_db.prepare(
            \\select value from _zova_kv where namespace = ? and key = ?
        );
        defer stmt.deinit();

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
        const owns_transaction = try beginOwnedWrite(self.sqlite_db);
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var stmt = try self.sqlite_db.prepare(
            \\insert into _zova_kv (namespace, key, value) values (?, ?, ?)
            \\on conflict(namespace, key) do update set value = excluded.value
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, namespace);
        try stmt.bindBlob(2, key);
        try stmt.bindBlob(3, value);
        std.debug.assert((try stmt.step()) == .done);

        if (owns_transaction) try self.sqlite_db.commit();
        committed = true;
    }

    /// Insert or replace many entries in one atomic transaction.
    ///
    /// The whole batch validates before any mutation and either commits
    /// together or rolls back together. Empty batches succeed.
    pub fn putMany(self: *Database, namespace: []const u8, entries: []const PutEntry) Error!void {
        try validateBatchEntries(entries);

        const owns_transaction = try beginOwnedWrite(self.sqlite_db);
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

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

        if (owns_transaction) try self.sqlite_db.commit();
        committed = true;
    }

    /// Delete one entry. Missing keys are ignored for replay safety.
    pub fn delete(self: *Database, namespace: []const u8, key: []const u8) Error!void {
        const owns_transaction = try beginOwnedWrite(self.sqlite_db);
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var stmt = try self.sqlite_db.prepare(
            \\delete from _zova_kv where namespace = ? and key = ?
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, namespace);
        try stmt.bindBlob(2, key);
        std.debug.assert((try stmt.step()) == .done);

        if (owns_transaction) try self.sqlite_db.commit();
        committed = true;
    }

    /// Delete many entries in one atomic transaction. Missing keys are
    /// ignored. Empty batches succeed.
    pub fn deleteMany(self: *Database, namespace: []const u8, keys: []const []const u8) Error!void {
        try validateBatchKeys(keys);

        const owns_transaction = try beginOwnedWrite(self.sqlite_db);
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

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

        if (owns_transaction) try self.sqlite_db.commit();
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
        const owns_transaction = try beginOwnedWrite(self.sqlite_db);
        var committed = false;
        errdefer if (owns_transaction and !committed) self.sqlite_db.rollback() catch {};

        var stmt = try self.sqlite_db.prepare(
            \\delete from _zova_kv where namespace = ?
        );
        defer stmt.deinit();

        try stmt.bindBlob(1, namespace);
        std.debug.assert((try stmt.step()) == .done);

        if (owns_transaction) try self.sqlite_db.commit();
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

fn beginOwnedWrite(db: *sqlite.Database) Error!bool {
    if (hasActiveTransaction(db)) return false;
    try db.beginImmediate();
    return true;
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