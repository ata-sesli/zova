//! Non-mutating storage-format parsing and classification.

const std = @import("std");
const sqlite = @import("../sqlite.zig");

const DatabaseFormatInfo = @import("types.zig").DatabaseFormatInfo;
const Error = @import("types.zig").Error;
const FormatCompatibility = @import("types.zig").FormatCompatibility;
const format_version = @import("types.zig").format_version;
const minimum_migratable_format = @import("types.zig").minimum_migratable_format;

pub fn parseFormatVersion(value: []const u8) ?u32 {
    if (value.len == 0 or value[0] == '+' or value[0] == '-') return null;
    return std.fmt.parseInt(u32, value, 10) catch null;
}

pub fn classifyFormatVersion(value: []const u8) ?FormatCompatibility {
    const format = parseFormatVersion(value) orelse return null;
    const current = parseFormatVersion(format_version) orelse return null;
    const minimum_migratable = parseFormatVersion(minimum_migratable_format) orelse return null;

    if (format == current) return .current;
    if (format > current) return .unsupported_future;
    if (format >= minimum_migratable) return .migratable;
    return .unsupported_legacy;
}

/// Read and classify `_zova_meta.format_version` using the same strict parsing
/// as `probeDatabaseFormat`, so open and probe cannot disagree.
pub fn readFormatClassification(db: *sqlite.Database) Error!DatabaseFormatInfo {
    var stmt = db.prepare("select value from _zova_meta where key = 'format_version'") catch |err| switch (err) {
        error.SqliteError => return error.NotZovaDatabase,
        else => return err,
    };
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .done => error.NotZovaDatabase,
        .row => {
            const version_text = stmt.columnText(0);
            const format_version_value = parseFormatVersion(version_text) orelse return error.NotZovaDatabase;
            const compatibility = classifyFormatVersion(version_text) orelse return error.NotZovaDatabase;
            return .{ .format_version = format_version_value, .compatibility = compatibility };
        },
    };
}
