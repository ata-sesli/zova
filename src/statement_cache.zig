//! Bounded, connection-owned cache of idle read statements.
//!
//! Some object and graph read paths prepared the same SQL on every call. This
//! module lets those paths check out a previously prepared statement instead,
//! under the limits agreed for issue #98:
//!
//! - The cache lives on the stable connection owner (`zova.Database`), never
//!   on a temporary subsystem facade, because facades are rebuilt per call.
//! - At most `capacity` idle statements are retained, counted across main and
//!   bound schema variants together. The KV subsystem retains two more, so a
//!   connection stays within the eight-idle-statement ceiling.
//! - A checked-out statement is removed from the cache, so a nested call can
//!   never reset or rebind an in-flight statement; it prepares its own copy.
//! - Every return path resets and clears bindings before the statement becomes
//!   eligible for reuse. A statement that fails cleanup is finalized instead of
//!   being cached, and no data, snapshot or borrowed input is retained: a reset
//!   statement ends its read.
//! - Owners dispose the whole cache before detaching, rebinding or replacing a
//!   bound store, because those operations change the schemas the cached SQL
//!   refers to.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova_error = @import("zova_error.zig");

pub const Error = zova_error.Error;

/// Largest number of idle statements retained by one cache.
pub const capacity = 6;

/// The cached statement sites. Each tag maps to exactly one SQL template in one
/// schema, so a tag plus the bound-store flag identifies cached SQL.
pub const Tag = enum(u8) {
    object_metadata,
    object_range_fastcdc,
    object_range_fixed,
    graph_key,
    graph_neighbors_out,
    graph_neighbors_out_typed,
    graph_neighbors_in,
    graph_neighbors_in_typed,
    graph_degree_out,
    graph_degree_out_typed,
    graph_degree_in,
    graph_degree_in_typed,
    graph_has_edge,
    graph_has_node,
    graph_get_node,
    object_exists,
};

const Key = packed struct(u16) {
    tag: Tag,
    bound: bool,
    _padding: u7 = 0,
};

const Entry = struct {
    key: Key,
    handle: *sqlite.c.sqlite3_stmt,
};

/// Idle statements owned by one connection. Raw handles avoid retaining
/// pointers to a moved owner. Diagnostic counters are only read by benchmarks.
pub const Cache = struct {
    entries: [capacity]?Entry = @splat(null),
    prepares: u64 = 0,
    reuses: u64 = 0,

    /// Finalize every retained statement. Used on connection close and before
    /// any operation that changes the schemas the cached SQL refers to.
    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                _ = sqlite.c.sqlite3_finalize(entry.handle);
                slot.* = null;
            }
        }
    }

    pub fn retained(self: *const Cache) usize {
        var count: usize = 0;
        for (self.entries) |slot| {
            if (slot != null) count += 1;
        }
        return count;
    }

    /// Number of live cached statements matching `tag`, for cache-identity
    /// tests. A checked-out statement is not retained.
    pub fn countFor(self: *const Cache, tag: Tag, bound: bool) usize {
        const wanted = key(tag, bound);
        var count: usize = 0;
        for (self.entries) |slot| {
            if (slot) |entry| {
                if (entry.key.tag == wanted.tag and entry.key.bound == wanted.bound) count += 1;
            }
        }
        return count;
    }

    fn take(self: *Cache, wanted: Key) ?*sqlite.c.sqlite3_stmt {
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (entry.key.tag == wanted.tag and entry.key.bound == wanted.bound) {
                    // Check out before entering SQLite, so a nested call never
                    // resets or rebinds an in-flight statement.
                    slot.* = null;
                    return entry.handle;
                }
            }
        }
        return null;
    }

    fn put(self: *Cache, wanted: Key, handle: *sqlite.c.sqlite3_stmt) void {
        var free_slot: ?*?Entry = null;
        for (&self.entries) |*slot| {
            if (slot.* == null) {
                if (free_slot == null) free_slot = slot;
                continue;
            }
            const entry = slot.*.?;
            if (entry.key.tag == wanted.tag and entry.key.bound == wanted.bound) {
                // A nested call retained an identical statement while this
                // lease was checked out; keep one and finalize the other.
                _ = sqlite.c.sqlite3_finalize(handle);
                return;
            }
        }
        if (free_slot) |slot| {
            slot.* = .{ .key = wanted, .handle = handle };
            return;
        }
        // The bounded cache is full for this connection.
        _ = sqlite.c.sqlite3_finalize(handle);
    }
};

/// One checked-out statement. Release it on every path, including errors.
pub const Lease = struct {
    statement: sqlite.Statement,
    cache: ?*Cache,
    key: Key,

    pub fn release(self: *Lease) void {
        if (self.cache) |cache| {
            // Reset ends the read; clearing releases every parameter allocation
            // including borrowed input. On any cleanup error discard the VM
            // instead of caching bad state.
            self.statement.reset() catch {
                self.statement.deinit();
                return;
            };
            self.statement.clearBindings() catch {
                self.statement.deinit();
                return;
            };
            cache.put(self.key, self.statement.handle);
            return;
        }
        // No connection-owned cache: behave exactly like a call-local
        // statement and finalize it.
        self.statement.deinit();
    }
};

pub fn key(tag: Tag, bound: bool) Key {
    return .{ .tag = tag, .bound = bound };
}

/// Check out the cached statement for `tag`, preparing `template` when no idle
/// statement is available. `template` uses `{s}` for every schema prefix, and
/// `bound` keeps main and bound-store SQL in distinct cache entries.
pub fn acquire(
    cache: ?*Cache,
    db: *sqlite.Database,
    tag: Tag,
    bound: bool,
    comptime template: []const u8,
    prefix: []const u8,
) Error!Lease {
    const wanted = key(tag, bound);
    if (cache) |target| {
        if (target.take(wanted)) |handle| {
            target.reuses += 1;
            return .{ .statement = .{ .db = db, .handle = handle }, .cache = target, .key = wanted };
        }
        target.prepares += 1;
    }
    var buffer: [4096]u8 = undefined;
    const sql = try formatSchema(template, prefix, &buffer);
    return .{ .statement = try db.prepare(sql), .cache = cache, .key = wanted };
}

/// Substitute every `{s}` in `template` with the schema prefix.
pub fn formatSchema(comptime template: []const u8, prefix: []const u8, buffer: *[4096]u8) Error![:0]const u8 {
    const sql_len = std.mem.replacementSize(u8, template, "{s}", prefix);
    if (sql_len >= buffer.len) return error.SqliteError;
    _ = std.mem.replace(u8, template, "{s}", prefix, buffer[0..sql_len]);
    buffer[sql_len] = 0;
    return buffer[0..sql_len :0];
}
