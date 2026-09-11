//! Internal borrowed-array binding for synchronous graph reads.
const std = @import("std");
const sqlite = @import("sqlite.zig");

/// Keep values alive and unchanged until the statement is finalized. Reset
/// retains the binding. The C API accepts a mutable pointer but never writes it.
pub fn bindInt64Borrowed(stmt: *sqlite.Statement, index: c_int, values: []const i64) sqlite.Error!void {
    const len = std.math.cast(c_int, values.len) orelse return error.InvalidArgument;
    const rc = sqlite.c.sqlite3_carray_bind(stmt.handle, index, @constCast(values.ptr), len, sqlite.c.SQLITE_CARRAY_INT64, null);
    return switch (rc) {
        sqlite.c.SQLITE_OK => {},
        sqlite.c.SQLITE_NOMEM => error.NoMemory,
        else => error.SqliteError,
    };
}
