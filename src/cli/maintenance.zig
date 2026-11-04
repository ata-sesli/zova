//! Backup, compact, restore, format probing, and migration commands.

const std = @import("std");
const zova = @import("zova");

const CommandContext = @import("types.zig").CommandContext;
const ExitCode = @import("common.zig").ExitCode;
const FormatCommandArgs = @import("parse.zig").FormatCommandArgs;
const MigrateCommandArgs = @import("parse.zig").MigrateCommandArgs;
const OperationalCommandArgs = @import("types.zig").OperationalCommandArgs;
const OutputFormat = @import("types.zig").OutputFormat;
const argsContain = @import("parse.zig").argsContain;
const cli_json_version = @import("common.zig").cli_json_version;
const formatUsageMessage = @import("parse.zig").formatUsageMessage;
const free_space = @import("free_space.zig");
const migrateUsageMessage = @import("parse.zig").migrateUsageMessage;
const openDatabase = @import("common.zig").openDatabase;
const openErrorFormat = @import("render.zig").openErrorFormat;
const operationalErrorFormat = @import("render.zig").operationalErrorFormat;
const operationalUsageMessage = @import("parse.zig").operationalUsageMessage;
const parseFormatCommandArgs = @import("parse.zig").parseFormatCommandArgs;
const parseMigrateCommandArgs = @import("parse.zig").parseMigrateCommandArgs;
const parseOperationalCommandArgs = @import("parse.zig").parseOperationalCommandArgs;
const progress_output = @import("progress.zig");
const usageErrorFormat = @import("render.zig").usageErrorFormat;
const writeJsonErrorWithKind = @import("render.zig").writeJsonErrorWithKind;
const writeJsonString = @import("render.zig").writeJsonString;

fn formatCompatibilityString(compatibility: zova.FormatCompatibility) []const u8 {
    return switch (compatibility) {
        .current => "current",
        .migratable => "migratable",
        .unsupported_legacy => "unsupported_legacy",
        .unsupported_future => "unsupported_future",
    };
}

fn recommendedActionForCompatibility(compatibility: ?zova.FormatCompatibility) []const u8 {
    const compat = compatibility orelse return "unsupported";
    return switch (compat) {
        .current => "none",
        .migratable => "run 'zova migrate <source> <destination>'",
        .unsupported_legacy => "unsupported",
        .unsupported_future => "upgrade Zova",
    };
}

fn migrateErrorExitCode(err: anyerror) u8 {
    return switch (err) {
        error.Corrupt,
        error.ObjectCorrupt,
        error.ObjectNotFound,
        error.ObjectChunkNotFound,
        error.VectorCorrupt,
        error.VectorCollectionNotFound,
        error.VectorNotFound,
        => ExitCode.check_failed,
        else => ExitCode.open,
    };
}

fn migrateErrorFormat(stderr: *std.Io.Writer, format: OutputFormat, err: anyerror) !u8 {
    const exit_code = migrateErrorExitCode(err);
    const label = if (exit_code == ExitCode.check_failed) "verification failed" else "operation failed";
    const command: []const u8 = "migrate";
    switch (format) {
        .text => try stderr.print("{s}: {s}: {s}\n", .{ command, label, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, label, @errorName(err)),
    }
    return exit_code;
}

fn writeFormatSuccess(
    writer: *std.Io.Writer,
    parsed: FormatCommandArgs,
    info: ?zova.DatabaseFormatInfo,
) !void {
    const current_format = std.fmt.parseInt(u32, zova.version.format_version, 10) catch 0;
    const minimum_format = std.fmt.parseInt(u32, zova.minimum_migratable_format, 10) catch 0;
    const compatibility: ?zova.FormatCompatibility = if (info) |v| v.compatibility else null;
    const source_format: ?u32 = if (info) |v| v.format_version else null;
    const compat_str: []const u8 = if (compatibility) |c| formatCompatibilityString(c) else "invalid";
    const action = recommendedActionForCompatibility(compatibility);
    switch (parsed.format) {
        .text => {
            try writer.print("source: {s}\n", .{parsed.path});
            if (source_format) |sf| {
                try writer.print("source_format: {d}\n", .{sf});
            } else {
                try writer.writeAll("source_format: null\n");
            }
            try writer.print("current_format: {d}\n", .{current_format});
            try writer.print("minimum_migratable_format: {d}\n", .{minimum_format});
            try writer.print("compatibility: {s}\n", .{compat_str});
            try writer.print("recommended_action: {s}\n", .{action});
        },
        .json => {
            try writer.writeAll("{\n");
            try writer.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try writer.writeAll("  \"status\": \"ok\",\n");
            try writer.writeAll("  \"command\": \"format\",\n");
            try writer.writeAll("  \"source_path\": ");
            try writeJsonString(writer, parsed.path);
            try writer.writeAll(",\n");
            if (source_format) |sf| {
                try writer.print("  \"source_format\": {d},\n", .{sf});
            } else {
                try writer.writeAll("  \"source_format\": null,\n");
            }
            try writer.print("  \"current_format\": {d},\n", .{current_format});
            try writer.print("  \"minimum_migratable_format\": {d},\n", .{minimum_format});
            try writer.writeAll("  \"compatibility\": ");
            try writeJsonString(writer, compat_str);
            try writer.writeAll(",\n  \"recommended_action\": ");
            try writeJsonString(writer, action);
            try writer.writeAll("\n}\n");
        },
    }
}

pub fn formatCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    _ = ctx;
    const parsed = parseFormatCommandArgs(args) catch |err| {
        const fmt: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "format", fmt, formatUsageMessage(err));
    };
    const path_z = allocator.dupeSentinel(u8, parsed.path, 0) catch return ExitCode.unexpected;
    defer allocator.free(path_z);
    const info_or_err = zova.probeDatabaseFormat(path_z);
    if (info_or_err) |info| {
        try writeFormatSuccess(stdout, parsed, info);
        return ExitCode.ok;
    } else |err| switch (err) {
        error.NotZovaDatabase, error.NotZovaPath => {
            try writeFormatSuccess(stdout, parsed, null);
            return ExitCode.ok;
        },
        else => return openErrorFormat(stderr, "format", parsed.format, err),
    }
}

fn writeMigrateSuccess(
    writer: *std.Io.Writer,
    parsed: MigrateCommandArgs,
    source_format: u32,
    destination_format: u32,
    bound_objects: ?[]const u8,
    bound_vectors: ?[]const u8,
    bound_graphs: ?[]const u8,
) !void {
    switch (parsed.format) {
        .text => {
            try writer.writeAll("migrate: ok\n");
            try writer.print("source: {s}\n", .{parsed.source_path});
            try writer.print("destination: {s}\n", .{parsed.destination_path});
            try writer.print("source_format: {d}\n", .{source_format});
            try writer.print("destination_format: {d}\n", .{destination_format});
            try writer.print("verified: {}\n", .{parsed.verify});
            if (bound_objects) |p| try writer.print("bound_objects: {s}\n", .{p});
            if (bound_vectors) |p| try writer.print("bound_vectors: {s}\n", .{p});
            if (bound_graphs) |p| try writer.print("bound_graphs: {s}\n", .{p});
        },
        .json => {
            try writer.writeAll("{\n");
            try writer.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try writer.writeAll("  \"status\": \"ok\",\n");
            try writer.writeAll("  \"command\": \"migrate\",\n");
            try writer.writeAll("  \"source_path\": ");
            try writeJsonString(writer, parsed.source_path);
            try writer.writeAll(",\n  \"destination_path\": ");
            try writeJsonString(writer, parsed.destination_path);
            try writer.print(",\n  \"source_format\": {d},\n", .{source_format});
            try writer.print("  \"destination_format\": {d},\n", .{destination_format});
            try writer.print("  \"verified\": {s},\n", .{if (parsed.verify) "true" else "false"});
            try writer.writeAll("  \"bound_stores\": {\n");
            if (bound_objects) |p| {
                try writer.writeAll("    \"objects\": ");
                try writeJsonString(writer, p);
            } else {
                try writer.writeAll("    \"objects\": null");
            }
            try writer.writeAll(",\n");
            if (bound_vectors) |p| {
                try writer.writeAll("    \"vectors\": ");
                try writeJsonString(writer, p);
            } else {
                try writer.writeAll("    \"vectors\": null");
            }
            try writer.writeAll(",\n");
            if (bound_graphs) |p| {
                try writer.writeAll("    \"graphs\": ");
                try writeJsonString(writer, p);
            } else {
                try writer.writeAll("    \"graphs\": null");
            }
            try writer.writeAll("\n  }\n}\n");
        },
    }
}

const MigrateBoundPaths = struct {
    objects: ?[]u8 = null,
    vectors: ?[]u8 = null,
    graphs: ?[]u8 = null,

    fn deinit(self: *MigrateBoundPaths, allocator: std.mem.Allocator) void {
        if (self.objects) |p| allocator.free(p);
        if (self.vectors) |p| allocator.free(p);
        if (self.graphs) |p| allocator.free(p);
        self.* = .{};
    }
};

fn collectMigrateBoundPaths(
    allocator: std.mem.Allocator,
    ctx: CommandContext,
    destination_path: [:0]const u8,
) !MigrateBoundPaths {
    var result: MigrateBoundPaths = .{};
    errdefer result.deinit(allocator);
    var db = try zova.Database.openWithExtensions(destination_path, ctx.registry);
    defer db.deinit();
    if (try db.boundObjectStore(allocator)) |info| {
        var tmp = info;
        defer tmp.deinit(allocator);
        result.objects = try allocator.dupe(u8, tmp.path);
    }
    if (try db.boundVectorStore(allocator)) |info| {
        var tmp = info;
        defer tmp.deinit(allocator);
        result.vectors = try allocator.dupe(u8, tmp.path);
    }
    if (try db.boundGraphStore(allocator)) |info| {
        var tmp = info;
        defer tmp.deinit(allocator);
        result.graphs = try allocator.dupe(u8, tmp.path);
    }
    return result;
}

pub fn migrateCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseMigrateCommandArgs(args) catch |err| {
        const fmt: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "migrate", fmt, migrateUsageMessage(err));
    };
    if (std.mem.eql(u8, parsed.source_path, parsed.destination_path)) {
        const fmt = parsed.format;
        return usageErrorFormat(stderr, "migrate", fmt, "source and destination must differ");
    }
    const source_z = allocator.dupeSentinel(u8, parsed.source_path, 0) catch return ExitCode.unexpected;
    defer allocator.free(source_z);
    const dest_z = allocator.dupeSentinel(u8, parsed.destination_path, 0) catch return ExitCode.unexpected;
    defer allocator.free(dest_z);

    if (parsed.dry_run) return migrateDryRun(ctx, allocator, parsed, source_z, dest_z, stdout, stderr);

    const probe_before = zova.probeDatabaseFormat(source_z) catch |err| {
        return openErrorFormat(stderr, "migrate", parsed.format, err);
    };
    const source_format = probe_before.format_version;

    var reporter = progress_output.Reporter.init(stderr, "migrate", progress_output.mode(parsed.format, parsed.progress, ctx.stderr_terminal));
    zova.migrateDatabaseWithExtensions(source_z, dest_z, .{ .verify = parsed.verify, .progress = reporter.callback() }, ctx.registry) catch |err| {
        reporter.finish();
        return migrateErrorFormat(stderr, parsed.format, err);
    };
    reporter.finish();

    const dest_format = std.fmt.parseInt(u32, zova.version.format_version, 10) catch 0;

    const bound = collectMigrateBoundPaths(allocator, ctx, dest_z) catch |err| {
        return migrateErrorFormat(stderr, parsed.format, err);
    };
    defer {
        if (bound.objects) |p| allocator.free(p);
        if (bound.vectors) |p| allocator.free(p);
        if (bound.graphs) |p| allocator.free(p);
    }

    try writeMigrateSuccess(stdout, parsed, source_format, dest_format, bound.objects, bound.vectors, bound.graphs);
    return ExitCode.ok;
}

/// `migrate --dry-run`: report the plan on stdout, create nothing, and exit
/// with the code the real migration would return. `failure` is the first
/// check the migration would fail, or "InsufficientSpace" when the
/// destination filesystem cannot hold the copied pages.
fn migrateDryRun(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    parsed: MigrateCommandArgs,
    source_z: [:0]const u8,
    dest_z: [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var plan = zova.planMigration(allocator, source_z, dest_z, .{ .verify = parsed.verify }, ctx.registry) catch |err| {
        return openErrorFormat(stderr, "migrate", parsed.format, err);
    };
    defer plan.deinit(allocator);

    const parent = std.fs.path.dirname(parsed.destination_path) orelse ".";
    const parent_z = allocator.dupeSentinel(u8, parent, 0) catch return ExitCode.unexpected;
    defer allocator.free(parent_z);
    const free_bytes = free_space.availableBytes(parent_z);
    const copy_bytes = plan.copyBytes();

    var failure: ?[]const u8 = null;
    var exit_code: u8 = ExitCode.ok;
    if (plan.failure) |err| {
        failure = @errorName(err);
        exit_code = migrateErrorExitCode(err);
    } else if (free_bytes) |available| {
        if (available < copy_bytes) {
            failure = "InsufficientSpace";
            exit_code = ExitCode.open;
        }
    }
    try writeMigrateDryRun(stdout, parsed, &plan, copy_bytes, free_bytes, failure);
    return exit_code;
}

fn migrationPreflightString(preflight: zova.MigrationPreflight) []const u8 {
    return switch (preflight) {
        .passed => "passed",
        .failed => "failed",
        .skipped => "skipped",
    };
}

fn writeMigrateDryRun(
    writer: *std.Io.Writer,
    parsed: MigrateCommandArgs,
    plan: *const zova.MigrationPlan,
    copy_bytes: u64,
    free_bytes: ?u64,
    failure: ?[]const u8,
) !void {
    var reclaimable: u64 = 0;
    for (plan.members) |member| {
        if (member.sizes) |sizes| reclaimable += sizes.freeBytes();
    }
    switch (parsed.format) {
        .text => {
            if (failure) |name| {
                try writer.print("migrate --dry-run: would fail: {s}\n", .{name});
            } else {
                try writer.writeAll("migrate --dry-run: ok\n");
            }
            try writer.print("source: {s}\n", .{parsed.source_path});
            try writer.print("destination: {s}\n", .{parsed.destination_path});
            try writer.print("source_format: {d}\n", .{plan.source_format});
            try writer.print("destination_format: {d}\n", .{plan.target_format});
            try writer.print("compatibility: {s}\n", .{formatCompatibilityString(plan.compatibility)});
            try writer.print("verify: {}\n", .{plan.verify});
            try writer.print("preflight: {s}\n", .{migrationPreflightString(plan.preflight)});
            for (plan.members) |member| {
                try writer.print("member {s}: {s} -> {s}", .{ member.role, member.source_path, member.destination_path });
                if (member.sizes) |sizes| {
                    try writer.print(" (copy {d} bytes, {d} free)", .{ sizes.copyBytes(), sizes.freeBytes() });
                } else {
                    try writer.writeAll(" (size unknown)");
                }
                if (member.destination_exists) try writer.writeAll(" [destination exists]");
                try writer.writeAll("\n");
            }
            try writer.print("recovery_directory: {s}{s}\n", .{ plan.recovery_directory, if (plan.recovery_directory_exists) " [exists]" else "" });
            try writer.print("copy_bytes: {d}\n", .{copy_bytes});
            if (free_bytes) |available| {
                try writer.print("destination_free_bytes: {d}\n", .{available});
            } else {
                try writer.writeAll("destination_free_bytes: unknown\n");
            }
            for (plan.extensions) |item| {
                try writer.print("extension {s} {s}: {s}", .{ item.name, item.version, if (item.bundled) "bundled" else "needs bundle" });
                if (item.availability) |err| try writer.print(", unavailable ({s})", .{@errorName(err)});
                try writer.writeAll("\n");
            }
            if (reclaimable > 0) {
                try writer.print("note: migration copies {d} free bytes as is; 'zova compact' first would shrink the copy\n", .{reclaimable});
            }
        },
        .json => {
            try writer.writeAll("{\n");
            try writer.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try writer.print("  \"status\": \"{s}\",\n", .{if (failure == null) "ok" else "would_fail"});
            try writer.writeAll("  \"command\": \"migrate\",\n");
            try writer.writeAll("  \"dry_run\": true,\n");
            try writer.writeAll("  \"source_path\": ");
            try writeJsonString(writer, parsed.source_path);
            try writer.writeAll(",\n  \"destination_path\": ");
            try writeJsonString(writer, parsed.destination_path);
            try writer.print(",\n  \"source_format\": {d},\n", .{plan.source_format});
            try writer.print("  \"destination_format\": {d},\n", .{plan.target_format});
            try writer.print("  \"compatibility\": \"{s}\",\n", .{formatCompatibilityString(plan.compatibility)});
            try writer.print("  \"verify\": {},\n", .{plan.verify});
            try writer.print("  \"preflight\": \"{s}\",\n", .{migrationPreflightString(plan.preflight)});
            try writer.writeAll("  \"failure\": ");
            if (failure) |name| try writeJsonString(writer, name) else try writer.writeAll("null");
            try writer.writeAll(",\n  \"members\": [");
            for (plan.members, 0..) |member, index| {
                try writer.writeAll(if (index == 0) "\n    {" else ",\n    {");
                try writer.writeAll("\"role\": ");
                try writeJsonString(writer, member.role);
                try writer.writeAll(", \"source_path\": ");
                try writeJsonString(writer, member.source_path);
                try writer.writeAll(", \"destination_path\": ");
                try writeJsonString(writer, member.destination_path);
                try writer.print(", \"destination_exists\": {}", .{member.destination_exists});
                if (member.sizes) |sizes| {
                    try writer.print(
                        ", \"page_size\": {d}, \"page_count\": {d}, \"freelist_count\": {d}, \"copy_bytes\": {d}, \"free_bytes\": {d}",
                        .{ sizes.page_size, sizes.page_count, sizes.freelist_count, sizes.copyBytes(), sizes.freeBytes() },
                    );
                } else {
                    try writer.writeAll(", \"page_size\": null, \"page_count\": null, \"freelist_count\": null, \"copy_bytes\": null, \"free_bytes\": null");
                }
                try writer.writeAll("}");
            }
            try writer.writeAll(if (plan.members.len == 0) "],\n" else "\n  ],\n");
            try writer.writeAll("  \"recovery_directory\": ");
            try writeJsonString(writer, plan.recovery_directory);
            try writer.print(",\n  \"recovery_directory_exists\": {},\n", .{plan.recovery_directory_exists});
            try writer.print("  \"copy_bytes\": {d},\n", .{copy_bytes});
            try writer.print("  \"reclaimable_bytes\": {d},\n", .{reclaimable});
            if (free_bytes) |available| {
                try writer.print("  \"destination_free_bytes\": {d},\n", .{available});
            } else {
                try writer.writeAll("  \"destination_free_bytes\": null,\n");
            }
            try writer.writeAll("  \"extensions\": [");
            for (plan.extensions, 0..) |item, index| {
                try writer.writeAll(if (index == 0) "\n    {" else ",\n    {");
                try writer.writeAll("\"name\": ");
                try writeJsonString(writer, item.name);
                try writer.writeAll(", \"version\": ");
                try writeJsonString(writer, item.version);
                try writer.print(", \"bundled\": {}, \"available\": {}, \"error\": ", .{ item.bundled, item.availability == null });
                if (item.availability) |err| try writeJsonString(writer, @errorName(err)) else try writer.writeAll("null");
                try writer.writeAll("}");
            }
            try writer.writeAll(if (plan.extensions.len == 0) "]\n}\n" else "\n  ]\n}\n");
        },
    }
}

pub fn backupCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseOperationalCommandArgs(args, "backup", stderr) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "backup", format, operationalUsageMessage("backup", err));
    };

    const source = try allocator.dupeSentinel(u8, parsed.source_path, 0);
    defer allocator.free(source);
    const destination = try allocator.dupeSentinel(u8, parsed.destination_path, 0);
    defer allocator.free(destination);

    var db = openDatabase(ctx, source) catch |err| return openErrorFormat(stderr, "backup", parsed.format, err);
    defer db.deinit();

    var reporter = progress_output.Reporter.init(stderr, "backup", progress_output.mode(parsed.format, parsed.progress, ctx.stderr_terminal));
    db.backupTo(destination, .{ .verify = parsed.verify, .progress = reporter.callback() }) catch |err| {
        reporter.finish();
        return operationalErrorFormat(stderr, "backup", parsed.format, err);
    };
    reporter.finish();
    try writeOperationalSuccess(stdout, "backup", parsed, parsed.source_path, parsed.destination_path);
    return ExitCode.ok;
}

pub fn compactCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseOperationalCommandArgs(args, "compact", stderr) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "compact", format, operationalUsageMessage("compact", err));
    };

    const source = try allocator.dupeSentinel(u8, parsed.source_path, 0);
    defer allocator.free(source);
    const destination = try allocator.dupeSentinel(u8, parsed.destination_path, 0);
    defer allocator.free(destination);

    var db = openDatabase(ctx, source) catch |err| return openErrorFormat(stderr, "compact", parsed.format, err);
    defer db.deinit();

    var reporter = progress_output.Reporter.init(stderr, "compact", progress_output.mode(parsed.format, parsed.progress, ctx.stderr_terminal));
    db.compactTo(destination, .{ .verify = parsed.verify, .progress = reporter.callback() }) catch |err| {
        reporter.finish();
        return operationalErrorFormat(stderr, "compact", parsed.format, err);
    };
    reporter.finish();
    try writeOperationalSuccess(stdout, "compact", parsed, parsed.source_path, parsed.destination_path);
    return ExitCode.ok;
}

pub fn restoreCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseOperationalCommandArgs(args, "restore", stderr) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "restore", format, operationalUsageMessage("restore", err));
    };

    const source = try allocator.dupeSentinel(u8, parsed.source_path, 0);
    defer allocator.free(source);
    const destination = try allocator.dupeSentinel(u8, parsed.destination_path, 0);
    defer allocator.free(destination);

    zova.restoreBackupWithExtensions(source, destination, .{ .verify = parsed.verify }, ctx.registry) catch |err| return operationalErrorFormat(stderr, "restore", parsed.format, err);
    try writeOperationalSuccess(stdout, "restore", parsed, parsed.source_path, parsed.destination_path);
    return ExitCode.ok;
}

fn writeOperationalSuccess(
    stdout: *std.Io.Writer,
    command: []const u8,
    parsed: OperationalCommandArgs,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    switch (parsed.format) {
        .text => {
            try stdout.print("{s}: ok\n", .{command});
            try stdout.print("source: {s}\n", .{source_path});
            try stdout.print("destination: {s}\n", .{destination_path});
            try stdout.print("verified: {}\n", .{parsed.verify});
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"command\": ");
            try writeJsonString(stdout, command);
            try stdout.writeAll(",\n  \"source_path\": ");
            try writeJsonString(stdout, source_path);
            try stdout.writeAll(",\n  \"destination_path\": ");
            try writeJsonString(stdout, destination_path);
            try stdout.print(",\n  \"verified\": {}\n", .{parsed.verify});
            try stdout.writeAll("}\n");
        },
    }
}
