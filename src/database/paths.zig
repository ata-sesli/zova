//! Filesystem preconditions and destination reservation for database operations.

const std = @import("std");

const Error = @import("types.zig").Error;
const build_options = @import("zova_build_options");
pub const wasm_opfs = @import("builtin").os.tag == .emscripten and
    @hasDecl(build_options, "enable_wasm_opfs") and build_options.enable_wasm_opfs;

// Only the private OPFS spike enables this path. The pool's exclusive handles
// cover the synchronous check/open interval; never fall back to MEMFS.
fn opfsPathExists(path: []const u8) Error!bool {
    const c = @import("../sqlite.zig").c;
    const vfs = c.sqlite3_vfs_find("opfs-sahpool");
    if (vfs == null or c.sqlite3_vfs_find(null) != vfs) return error.CantOpen;
    const name = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(name);
    var exists: c_int = 0;
    if (vfs.*.xAccess.?(vfs, name.ptr, c.SQLITE_ACCESS_EXISTS, &exists) != c.SQLITE_OK)
        return error.CantOpen;
    return exists != 0;
}

pub fn isZovaPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zova");
}

pub fn isMemoryPath(path: []const u8) bool {
    return std.mem.eql(u8, path, ":memory:");
}

pub fn defaultIo() std.Io {
    // The browser preview has no host filesystem. Memory creation skips these
    // operations; any accidental file operation must fail, not access a VFS.
    if (@import("builtin").os.tag == .emscripten) return .failing;
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn ensureDestinationZovaPathAvailable(path: [:0]const u8) Error!void {
    if (!isZovaPath(path)) return error.NotZovaPath;

    const io = defaultIo();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try ensureParentPathExists(io, path);
                return;
            },
            else => return error.CantOpen,
        };
        return error.DestinationExists;
    }

    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try ensureParentPathExists(io, path);
            return;
        },
        else => return error.CantOpen,
    };

    return error.DestinationExists;
}

fn ensureParentPathExists(io: std.Io, path: []const u8) Error!void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;

    if (std.fs.path.isAbsolute(parent)) {
        std.Io.Dir.accessAbsolute(io, parent, .{}) catch return error.CantOpen;
    } else {
        std.Io.Dir.cwd().access(io, parent, .{}) catch return error.CantOpen;
    }
}

pub fn reserveDestinationZovaFile(path: [:0]const u8) Error!void {
    if (wasm_opfs) {
        if (!isZovaPath(path)) return error.NotZovaPath;
        if (try opfsPathExists(path)) return error.DestinationExists;
        return;
    }
    try ensureDestinationZovaPathAvailable(path);

    const io = defaultIo();
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DestinationExists,
        else => return error.CantOpen,
    };
    file.close(io);
}

pub fn deleteDestinationFile(path: [:0]const u8) void {
    std.Io.Dir.cwd().deleteFile(defaultIo(), path) catch {};
}

pub fn ensurePathExists(path: []const u8) Error!void {
    if (wasm_opfs) {
        if (!try opfsPathExists(path)) return error.NotZovaDatabase;
        return;
    }
    const io = defaultIo();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return missingPathError(io, path),
            else => return error.CantOpen,
        };
        return;
    }

    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return missingPathError(io, path),
        else => return error.CantOpen,
    };
}

fn missingPathError(io: std.Io, path: []const u8) Error {
    const parent = std.fs.path.dirname(path) orelse return error.NotZovaDatabase;
    if (parent.len == 0) return error.NotZovaDatabase;

    if (std.fs.path.isAbsolute(parent)) {
        std.Io.Dir.accessAbsolute(io, parent, .{}) catch return error.CantOpen;
    } else {
        std.Io.Dir.cwd().access(io, parent, .{}) catch return error.CantOpen;
    }

    return error.NotZovaDatabase;
}

pub fn ensureSourcePathExists(path: []const u8) Error!void {
    const io = defaultIo();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return error.CantOpen;
        return;
    }

    std.Io.Dir.cwd().access(io, path, .{}) catch return error.CantOpen;
}
