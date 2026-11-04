//! Progress output on stderr for `migrate`, `backup`, and `compact`.
//!
//! Text mode shows a one-line display that rewrites itself when stderr is a
//! terminal; `--progress` forces plain lines when it is not. `--json
//! --progress` writes one JSON object per line with `"event": "progress"`,
//! which the final result object on stdout never carries.
//!
//! Output is throttled to whole-percent changes per phase and member, and a
//! failed stderr write never cancels the operation.

const std = @import("std");
const zova = @import("zova");

const OutputFormat = @import("types.zig").OutputFormat;
const cli_json_version = @import("common.zig").cli_json_version;

pub const Mode = enum { off, terminal, lines, json };

pub fn mode(format: OutputFormat, requested: bool, stderr_terminal: bool) Mode {
    return switch (format) {
        .json => if (requested) .json else .off,
        .text => if (stderr_terminal) .terminal else if (requested) .lines else .off,
    };
}

pub const Reporter = struct {
    stderr: *std.Io.Writer,
    command: []const u8,
    mode: Mode,
    last_phase: ?zova.ProgressPhase = null,
    last_member: ?zova.ProgressMember = null,
    last_percent: u64 = 0,
    /// A terminal line is open and needs a newline before other output.
    line_open: bool = false,

    pub fn init(stderr: *std.Io.Writer, command: []const u8, progress_mode: Mode) Reporter {
        return .{ .stderr = stderr, .command = command, .mode = progress_mode };
    }

    /// The callback to pass in operation options, or null when progress is off.
    pub fn callback(self: *Reporter) ?zova.ProgressCallback {
        if (self.mode == .off) return null;
        return .{ .context = self, .report = report };
    }

    /// End an open terminal line so later stderr output starts cleanly.
    pub fn finish(self: *Reporter) void {
        if (!self.line_open) return;
        self.stderr.writeAll("\n") catch {};
        self.stderr.flush() catch {};
        self.line_open = false;
    }

    fn report(context: ?*anyopaque, progress: zova.Progress) zova.Error!void {
        const self: *Reporter = @ptrCast(@alignCast(context.?));
        const percent = if (progress.total == 0) 100 else progress.done * 100 / progress.total;
        const same_group = self.last_phase == progress.phase and self.last_member == progress.member;
        if (same_group and percent == self.last_percent and progress.done != progress.total) return;
        self.last_phase = progress.phase;
        self.last_member = progress.member;
        self.last_percent = percent;
        self.write(progress, percent) catch {};
    }

    fn write(self: *Reporter, progress: zova.Progress, percent: u64) !void {
        const w = self.stderr;
        switch (self.mode) {
            .off => return,
            .json => {
                try w.print("{{\"cli_json_version\":{d},\"event\":\"progress\",\"command\":\"{s}\",\"phase\":\"{s}\",\"member\":", .{
                    cli_json_version,
                    self.command,
                    @tagName(progress.phase),
                });
                if (progress.member) |member| try w.print("\"{s}\"", .{@tagName(member)}) else try w.writeAll("null");
                try w.print(",\"done\":{d},\"total\":{d}}}\n", .{ progress.done, progress.total });
            },
            .terminal, .lines => {
                if (self.mode == .terminal) try w.writeAll("\r\x1b[K");
                try w.print("{s}: {s}", .{ self.command, @tagName(progress.phase) });
                if (progress.member) |member| try w.print(" {s}", .{@tagName(member)});
                try w.print(" {d}% ({d}/{d} {s})", .{ percent, progress.done, progress.total, unit(progress.phase) });
                const group_done = progress.done == progress.total;
                if (self.mode == .lines or group_done) {
                    try w.writeAll("\n");
                    self.line_open = false;
                } else {
                    self.line_open = true;
                }
            },
        }
        try w.flush();
    }
};

fn unit(phase: zova.ProgressPhase) []const u8 {
    return switch (phase) {
        .copy => "pages",
        .migrate => "steps",
        .verify => "items",
        .publish => "files",
    };
}
