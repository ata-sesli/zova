//! Retained hard-link witnesses for interrupted copy-forward publication.
//! Recovery is offline; see scripts/recover-migration.py. No source is changed.
const std = @import("std");
const Error = @import("types.zig").Error;
const paths = @import("paths.zig");
const io = paths.defaultIo;

pub const Publication = struct {
    allocator: std.mem.Allocator,
    directory: ?[:0]u8 = null,
    marker: ?[:0]u8 = null,
    owns_directory: bool = false,
    committed: bool = false,
    members: [4]Member = @splat(.{}),

    const Member = struct {
        final: ?[:0]u8 = null,
        reservation: ?[:0]u8 = null,
        stage: ?[:0]u8 = null,
        owns_reservation: bool = false,
        owns_stage: bool = false,
        owns_final: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, destination: []const u8) Error!Publication {
        const cwd = std.Io.Dir.cwd();
        var self: Publication = .{ .allocator = allocator };
        errdefer self.deinit();
        self.directory = try std.fmt.allocPrintSentinel(allocator, "{s}.migration-recovery", .{destination}, 0);
        self.marker = try std.fmt.allocPrintSentinel(allocator, "{s}/owner", .{self.directory.?}, 0);
        cwd.createDir(io(), self.directory.?, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => return error.DestinationExists,
            else => return error.CantOpen,
        };
        self.owns_directory = true;
        cwd.writeFile(io(), .{ .sub_path = self.marker.?, .data = "zova-migration-recovery-v1\n" }) catch return error.CantOpen;
        return self;
    }

    pub fn reserve(self: *Publication, index: usize, final: [:0]const u8) Error!void {
        const cwd = std.Io.Dir.cwd();
        try paths.ensureDestinationZovaPathAvailable(final);
        const m = &self.members[index];
        m.final = try self.allocator.dupeZ(u8, final);
        m.reservation = try std.fmt.allocPrintSentinel(self.allocator, "{s}/reserved-{s}", .{ self.directory.?, std.fs.path.basename(final) }, 0);
        m.stage = try std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ self.directory.?, std.fs.path.basename(final) }, 0);
        var file = cwd.createFile(io(), m.reservation.?, .{ .exclusive = true }) catch return error.CantOpen;
        file.close(io());
        m.owns_reservation = true;
        // The witness exists before the final name. A kill cannot leave an
        // unidentifiable reservation. Link creation never replaces a file.
        cwd.hardLink(m.reservation.?, cwd, final, io(), .{}) catch |err| switch (err) {
            error.PathAlreadyExists => return error.DestinationExists,
            else => return error.CantOpen,
        };
        m.owns_final = true;
    }

    pub fn stage(self: *Publication, index: usize) Error![:0]u8 {
        const cwd = std.Io.Dir.cwd();
        const m = &self.members[index];
        const result = try self.allocator.dupeZ(u8, m.stage.?);
        errdefer self.allocator.free(result);
        var file = cwd.createFile(io(), m.stage.?, .{ .exclusive = true }) catch return error.CantOpen;
        file.close(io());
        m.owns_stage = true;
        return result;
    }

    pub fn publish(self: *Publication, index: usize) Error!void {
        const cwd = std.Io.Dir.cwd();
        const m = &self.members[index];
        if (!sameFile(m.final.?, m.reservation.?)) return error.DestinationExists;
        cwd.deleteFile(io(), m.final.?) catch return error.CantOpen;
        m.owns_final = false;
        // Keep the staged inode as the ownership witness through publication.
        // A collision after unlink is rejected instead of overwritten.
        cwd.hardLink(m.stage.?, cwd, m.final.?, io(), .{}) catch |err| switch (err) {
            error.PathAlreadyExists => return error.DestinationExists,
            else => return error.CantOpen,
        };
        m.owns_final = true;
    }

    pub fn deinit(self: *Publication) void {
        self.cleanup();
        for (&self.members) |*m| {
            if (m.final) |p| self.allocator.free(p);
            if (m.stage) |p| self.allocator.free(p);
            if (m.reservation) |p| self.allocator.free(p);
        }
        if (self.marker) |p| self.allocator.free(p);
        if (self.directory) |p| self.allocator.free(p);
    }

    fn cleanup(self: *Publication) void {
        const cwd = std.Io.Dir.cwd();
        // Keep the main staged inode until every store witness is gone. It is
        // the commit proof if cleanup itself is interrupted.
        var index: usize = self.members.len;
        while (index > 0) {
            index -= 1;
            const m = &self.members[index];
            if (!self.committed and m.owns_final) {
                if (!sameFile(m.final.?, m.reservation.?) and !sameFile(m.final.?, m.stage.?)) return;
                cwd.deleteFile(io(), m.final.?) catch return;
            }
            // On cleanup failure retain the remaining witnesses, especially
            // the main commit proof, for offline recovery.
            if (m.owns_reservation) cwd.deleteFile(io(), m.reservation.?) catch return;
            if (m.owns_stage) cwd.deleteFile(io(), m.stage.?) catch return;
        }
        if (self.owns_directory) {
            if (self.marker) |p| cwd.deleteFile(io(), p) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return,
            };
            cwd.deleteDir(io(), self.directory.?) catch {};
        }
    }
};

fn sameFile(a: []const u8, b: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    // Both paths are in the same destination filesystem; reject symlinks.
    const left = cwd.statFile(io(), a, .{ .follow_symlinks = false }) catch return false;
    const right = cwd.statFile(io(), b, .{ .follow_symlinks = false }) catch return false;
    return left.kind == .file and right.kind == .file and left.nlink >= 2 and left.inode == right.inode;
}
