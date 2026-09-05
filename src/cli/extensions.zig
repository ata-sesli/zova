//! Extension management, building, trust, and smoke verification commands.

const std = @import("std");
const builtin = @import("builtin");
const zova = @import("zova");
const cli_options = @import("cli_options");
const sqlite = zova.sqlite;
const source_root = cli_options.source_root;
const zig_exe = cli_options.zig_exe;
const zova_exe_path = cli_options.zova_exe_path;

const CommandContext = @import("types.zig").CommandContext;
const ExitCode = @import("common.zig").ExitCode;
const ExtensionCommandArgs = @import("types.zig").ExtensionCommandArgs;
const OutputFormat = @import("types.zig").OutputFormat;
const argsContain = @import("parse.zig").argsContain;
const cli_json_version = @import("common.zig").cli_json_version;
const defaultIo = @import("common.zig").defaultIo;
const extensionUsageMessage = @import("parse.zig").extensionUsageMessage;
const isExtensionHealthError = @import("common.zig").isExtensionHealthError;
const lowerHex32 = @import("common.zig").lowerHex32;
const openDatabase = @import("common.zig").openDatabase;
const parseExtensionCommandArgs = @import("parse.zig").parseExtensionCommandArgs;
const startsWithZovaPrefix = @import("common.zig").startsWithZovaPrefix;
const usageErrorFormat = @import("render.zig").usageErrorFormat;
const writeExtensionSuggestedActionsText = @import("render.zig").writeExtensionSuggestedActionsText;
const writeJsonErrorWithKind = @import("render.zig").writeJsonErrorWithKind;
const writeJsonErrorWithKindAndActions = @import("render.zig").writeJsonErrorWithKindAndActions;
const writeJsonString = @import("render.zig").writeJsonString;

pub fn extensionCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseExtensionCommandArgs(args) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "extension", format, extensionUsageMessage(err));
    };

    switch (parsed.action) {
        .scaffold => {
            extensionScaffoldCommand(allocator, parsed, stdout) catch |err| return extensionErrorFormat(stderr, "extension-scaffold", parsed.format, err);
            return ExitCode.ok;
        },
        .build => {
            extensionBuildCommand(allocator, parsed, stdout, stderr) catch |err| return extensionErrorFormat(stderr, "extension-build", parsed.format, err);
            return ExitCode.ok;
        },
        .pack => {
            extensionPackCommand(allocator, parsed, stdout) catch |err| return extensionErrorFormat(stderr, "extension-pack", parsed.format, err);
            return ExitCode.ok;
        },
        .verify => {
            extensionVerifyCommand(allocator, parsed, stdout, stderr) catch |err| return extensionErrorFormat(stderr, "extension-verify", parsed.format, err);
            return ExitCode.ok;
        },
        .trust => {
            var trusted = zova.extension_dynamic.trustBundle(allocator, parsed.path.?, .{}) catch |err| return extensionErrorFormat(stderr, "extension-trust", parsed.format, err);
            defer trusted.deinit(allocator);
            try writeExtensionTrustSuccess(stdout, parsed.format, "extension-trust", trusted);
            return ExitCode.ok;
        },
        .untrust => {
            const removed = zova.extension_dynamic.untrust(allocator, parsed.path.?, .{}) catch |err| return extensionErrorFormat(stderr, "extension-untrust", parsed.format, err);
            try writeExtensionUntrustSuccess(stdout, parsed.format, parsed.path.?, removed);
            return ExitCode.ok;
        },
        .trusted => {
            var trusted = zova.extension_dynamic.loadTrusted(allocator, .{}) catch |err| return extensionErrorFormat(stderr, "extension-trusted", parsed.format, err);
            defer trusted.deinit(allocator);
            try writeTrustedExtensionList(stdout, parsed.format, trusted);
            return ExitCode.ok;
        },
        else => {},
    }

    const path_z = try allocator.dupeZ(u8, parsed.path.?);
    defer allocator.free(path_z);

    var db = open_db: {
        const opened = openDatabase(ctx, path_z) catch |err| {
            if ((parsed.action == .list or parsed.action == .info) and isExtensionHealthError(err)) {
                break :open_db zova.Database.openForExtensionInspectionWithExtensions(path_z, .{}, ctx.registry) catch |inspect_err| {
                    return extensionOpenErrorFormat(stderr, parsed.format, inspect_err);
                };
            }
            return extensionOpenErrorFormat(stderr, parsed.format, err);
        };
        break :open_db opened;
    };
    defer db.deinit();

    switch (parsed.action) {
        .list => {
            var extensions = db.listExtensions(allocator) catch |err| return extensionErrorFormat(stderr, "extension-list", parsed.format, err);
            defer extensions.deinit(allocator);
            try writeExtensionList(stdout, parsed.format, parsed.path.?, extensions);
            return ExitCode.ok;
        },
        .info => {
            const name = parsed.name.?;
            var info = db.extensionInfo(allocator, name) catch |err| return extensionErrorFormat(stderr, "extension-info", parsed.format, err);
            defer info.deinit(allocator);
            try writeExtensionInfo(stdout, parsed.format, "extension-info", parsed.path.?, info);
            return ExitCode.ok;
        },
        .check => {
            if (parsed.name) |name| {
                db.checkExtension(name) catch |err| return extensionErrorFormat(stderr, "extension-check", parsed.format, err);
                var info = db.extensionInfo(allocator, name) catch |err| return extensionErrorFormat(stderr, "extension-check", parsed.format, err);
                defer info.deinit(allocator);
                try writeExtensionInfo(stdout, parsed.format, "extension-check", parsed.path.?, info);
            } else {
                var extensions = db.listExtensions(allocator) catch |err| return extensionErrorFormat(stderr, "extension-check", parsed.format, err);
                defer extensions.deinit(allocator);
                for (extensions.items) |item| {
                    db.checkExtension(item.name) catch |err| return extensionErrorFormat(stderr, "extension-check", parsed.format, err);
                }
                try writeExtensionList(stdout, parsed.format, parsed.path.?, extensions);
            }
            return ExitCode.ok;
        },
        .drop => {
            const name = parsed.name.?;
            db.dropExtension(name) catch |err| return extensionErrorFormat(stderr, "extension-drop", parsed.format, err);
            try writeExtensionMutationSuccess(stdout, parsed.format, "extension-drop", parsed.path.?, name);
            return ExitCode.ok;
        },
        .install => {
            const name = parsed.name.?;
            db.installExtension(name) catch |err| return extensionErrorFormat(stderr, "extension-install", parsed.format, err);
            var info = db.extensionInfo(allocator, name) catch |err| return extensionErrorFormat(stderr, "extension-install", parsed.format, err);
            defer info.deinit(allocator);
            try writeExtensionInfo(stdout, parsed.format, "extension-install", parsed.path.?, info);
            return ExitCode.ok;
        },
        .trust, .untrust, .trusted, .scaffold, .build, .pack, .verify => unreachable,
    }
}

fn extensionScaffoldCommand(allocator: std.mem.Allocator, parsed: ExtensionCommandArgs, stdout: *std.Io.Writer) !void {
    const dir_path = parsed.path.?;
    const name = parsed.name.?;
    const version = parsed.version.?;
    if (!isValidExtensionScaffoldName(name)) return error.ExtensionInvalid;

    const io = defaultIo();
    try std.Io.Dir.cwd().createDirPath(io, dir_path);

    const library = try dynamicLibraryFileName(allocator, name);
    defer allocator.free(library);
    const storage_prefix = try std.fmt.allocPrint(allocator, "_zova_ext_{s}_", .{name});
    defer allocator.free(storage_prefix);

    const extension_source = try scaffoldExtensionSource(allocator, name, version, storage_prefix);
    defer allocator.free(extension_source);
    const manifest_json = try scaffoldExtensionManifest(allocator, name, version, storage_prefix, library);
    defer allocator.free(manifest_json);

    const source_path = try std.fs.path.join(allocator, &.{ dir_path, "extension.zig" });
    defer allocator.free(source_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ dir_path, zova.extension_dynamic.bundle_manifest_file });
    defer allocator.free(manifest_path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = extension_source });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest_json });
    try writeExtensionBuilderSuccess(stdout, parsed.format, "extension-scaffold", dir_path, null, null);
}

fn extensionBuildCommand(allocator: std.mem.Allocator, parsed: ExtensionCommandArgs, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const dir_path = parsed.path.?;
    var manifest = try loadBuilderManifest(allocator, dir_path);
    defer manifest.deinit(allocator);

    const extension_source_path = try std.fs.path.join(allocator, &.{ dir_path, "extension.zig" });
    defer allocator.free(extension_source_path);
    const output_path = try std.fs.path.join(allocator, &.{ dir_path, manifest.library });
    defer allocator.free(output_path);
    const cache_path = try std.fs.path.join(allocator, &.{ dir_path, ".zig-cache" });
    defer allocator.free(cache_path);
    const global_cache_path = try std.fs.path.join(allocator, &.{ dir_path, ".zig-global-cache" });
    defer allocator.free(global_cache_path);
    const zova_root_path = try std.fs.path.join(allocator, &.{ source_root, "src/root.zig" });
    defer allocator.free(zova_root_path);
    const sqlite_vendor_dir = try std.fmt.allocPrint(allocator, "sqlite{s}", .{zova.version.sqlite_version});
    defer allocator.free(sqlite_vendor_dir);
    const sqlite_include_path = try std.fs.path.join(allocator, &.{ source_root, "vendor", sqlite_vendor_dir });
    defer allocator.free(sqlite_include_path);
    const zova_build_options_path = try std.fs.path.join(allocator, &.{ cache_path, "zova_build_options.zig" });
    defer allocator.free(zova_build_options_path);
    try std.Io.Dir.cwd().createDirPath(defaultIo(), cache_path);
    try std.Io.Dir.cwd().writeFile(defaultIo(), .{
        .sub_path = zova_build_options_path,
        .data = "pub const enable_dynamic_extensions = true;\n",
    });

    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{output_path});
    defer allocator.free(emit_arg);
    const root_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{extension_source_path});
    defer allocator.free(root_arg);
    const zova_arg = try std.fmt.allocPrint(allocator, "-Mzova={s}", .{zova_root_path});
    defer allocator.free(zova_arg);
    const zova_build_options_arg = try std.fmt.allocPrint(allocator, "-Mzova_build_options={s}", .{zova_build_options_path});
    defer allocator.free(zova_build_options_arg);
    const argv = [_][]const u8{
        zig_exe,
        "build-lib",
        "-dynamic",
        "-fPIC",
        "-fallow-shlib-undefined",
        "-lc",
        emit_arg,
        "--cache-dir",
        cache_path,
        "--global-cache-dir",
        global_cache_path,
        "--name",
        manifest.name,
        "--dep",
        "zova",
        root_arg,
        "-I",
        sqlite_include_path,
        "--dep",
        "zova_build_options",
        zova_arg,
        zova_build_options_arg,
    };

    const process_allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(process_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(process_allocator);
    defer env.deinit();
    try env.put("ZIG_GLOBAL_CACHE_DIR", global_cache_path);
    try env.put("HOME", global_cache_path);
    try env.put("TMPDIR", cache_path);
    try env.put("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin");
    const result = try std.process.run(process_allocator, io, .{
        .argv = &argv,
        .environ_map = &env,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            if (result.stderr.len != 0) try stderr.writeAll(result.stderr);
            if (result.stdout.len != 0) try stderr.writeAll(result.stdout);
            return error.ExtensionInvalid;
        },
        else => {
            if (result.stderr.len != 0) try stderr.writeAll(result.stderr);
            if (result.stdout.len != 0) try stderr.writeAll(result.stdout);
            return error.ExtensionInvalid;
        },
    }

    try writeExtensionBuilderSuccess(stdout, parsed.format, "extension-build", dir_path, output_path, null);
}

fn extensionPackCommand(allocator: std.mem.Allocator, parsed: ExtensionCommandArgs, stdout: *std.Io.Writer) !void {
    const dir_path = parsed.path.?;
    const out_path = parsed.out_path.?;
    if (!std.mem.endsWith(u8, out_path, ".zovaext")) return error.ExtensionInvalid;
    var manifest = try loadBuilderManifest(allocator, dir_path);
    defer manifest.deinit(allocator);

    const io = defaultIo();
    try std.Io.Dir.cwd().createDir(io, out_path, .default_dir);
    errdefer std.Io.Dir.cwd().deleteTree(io, out_path) catch {};

    const source_manifest_path = try std.fs.path.join(allocator, &.{ dir_path, zova.extension_dynamic.bundle_manifest_file });
    defer allocator.free(source_manifest_path);
    const dest_manifest_path = try std.fs.path.join(allocator, &.{ out_path, zova.extension_dynamic.bundle_manifest_file });
    defer allocator.free(dest_manifest_path);
    const source_library_path = try std.fs.path.join(allocator, &.{ dir_path, manifest.library });
    defer allocator.free(source_library_path);
    const dest_library_path = try std.fs.path.join(allocator, &.{ out_path, manifest.library });
    defer allocator.free(dest_library_path);

    try copyFileAlloc(allocator, source_manifest_path, dest_manifest_path, 64 * 1024);
    try copyFileAlloc(allocator, source_library_path, dest_library_path, 256 * 1024 * 1024);

    var info = try zova.extension_dynamic.loadBundleInfo(allocator, out_path);
    defer info.deinit(allocator);
    try zova.extension_dynamic.verifyBundleEntrypoint(allocator, out_path);
    const follow_up = try std.fmt.allocPrint(allocator, "zova extension trust {s}", .{out_path});
    defer allocator.free(follow_up);
    try writeExtensionBuilderSuccess(stdout, parsed.format, "extension-pack", dir_path, out_path, follow_up);
}

fn extensionVerifyCommand(allocator: std.mem.Allocator, parsed: ExtensionCommandArgs, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const bundle_path = parsed.path.?;
    var info = try zova.extension_dynamic.loadBundleInfo(allocator, bundle_path);
    defer info.deinit(allocator);
    try zova.extension_dynamic.verifyBundleEntrypoint(allocator, bundle_path);
    if (parsed.smoke) {
        try extensionSmokeInstallCheck(allocator, stderr, bundle_path, info.manifest.name);
    }
    try writeExtensionBuilderSuccess(stdout, parsed.format, "extension-verify", bundle_path, bundle_path, null);
}

fn extensionSmokeInstallCheck(allocator: std.mem.Allocator, stderr: *std.Io.Writer, bundle_path: []const u8, extension_name: []const u8) !void {
    const smoke_path = try extensionSmokeTempPath(allocator, extension_name);
    defer allocator.free(smoke_path);
    defer deleteExtensionSmokeDatabaseFiles(allocator, smoke_path);
    const smoke_trust_path = try extensionSmokeTrustPath(allocator, extension_name);
    defer allocator.free(smoke_trust_path);
    defer std.Io.Dir.cwd().deleteFile(defaultIo(), smoke_trust_path) catch {};

    {
        var db = try zova.Database.create(smoke_path);
        defer db.deinit();
    }

    var smoke_trust = try zova.extension_dynamic.trustBundle(allocator, bundle_path, .{ .path = smoke_trust_path });
    defer smoke_trust.deinit(allocator);

    const exe_path = try extensionSmokeExecutablePath(allocator);
    defer allocator.free(exe_path);

    try runExtensionSmokeChild(stderr, smoke_trust_path, &.{
        exe_path,
        "--extension",
        bundle_path,
        "extension",
        "install",
        "--json",
        smoke_path,
        extension_name,
    });
    try runExtensionSmokeChild(stderr, smoke_trust_path, &.{
        exe_path,
        "--extension",
        bundle_path,
        "extension",
        "check",
        "--json",
        smoke_path,
        extension_name,
    });
    try runExtensionSmokeChild(stderr, smoke_trust_path, &.{
        exe_path,
        "--extension",
        bundle_path,
        "check",
        "--json",
        "--deep",
        smoke_path,
    });
}

fn extensionSmokeExecutablePath(allocator: std.mem.Allocator) ![]u8 {
    const self_path = try std.process.executablePathAlloc(defaultIo(), allocator);
    errdefer allocator.free(self_path);
    if (isZigTestExecutable(self_path) and zova_exe_path.len != 0 and fileExists(zova_exe_path)) {
        allocator.free(self_path);
        return try allocator.dupe(u8, zova_exe_path);
    }
    return self_path;
}

fn isZigTestExecutable(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    return std.mem.eql(u8, basename, "test") or std.mem.eql(u8, basename, "test.exe");
}

fn runExtensionSmokeChild(stderr: *std.Io.Writer, smoke_trust_path: []const u8, argv: []const []const u8) !void {
    const process_allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(process_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(process_allocator);
    defer env.deinit();
    try copyEnv(&env, "PATH");
    try copyEnv(&env, "HOME");
    try copyEnv(&env, "TMPDIR");
    try copyEnv(&env, "TMP");
    try copyEnv(&env, "TEMP");
    try copyEnv(&env, "DYLD_LIBRARY_PATH");
    try copyEnv(&env, "LD_LIBRARY_PATH");
    try copyEnv(&env, "ZIG_GLOBAL_CACHE_DIR");
    try env.put("ZOVA_TRUST_STORE", smoke_trust_path);

    const result = std.process.run(process_allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return error.ExtensionInvalid;
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            writeExtensionSmokeChildFailure(stderr, argv, "exit", code, result.stdout, result.stderr);
            return error.ExtensionInvalid;
        },
        else => {
            writeExtensionSmokeChildFailure(stderr, argv, "signal", null, result.stdout, result.stderr);
            return error.ExtensionInvalid;
        },
    }
}

fn writeExtensionSmokeChildFailure(
    stderr: *std.Io.Writer,
    argv: []const []const u8,
    term_kind: []const u8,
    code: ?u8,
    child_stdout: []const u8,
    child_stderr: []const u8,
) void {
    stderr.writeAll("extension smoke child failed\nargv:") catch return;
    for (argv) |arg| {
        stderr.writeByte(' ') catch return;
        writeShellishArg(stderr, arg) catch return;
    }
    if (code) |value| {
        stderr.print("\nterm: {s} {d}\n", .{ term_kind, value }) catch return;
    } else {
        stderr.print("\nterm: {s}\n", .{term_kind}) catch return;
    }
    if (child_stdout.len != 0) {
        stderr.writeAll("child stdout:\n") catch return;
        stderr.writeAll(child_stdout) catch return;
        if (child_stdout[child_stdout.len - 1] != '\n') stderr.writeByte('\n') catch return;
    }
    if (child_stderr.len != 0) {
        stderr.writeAll("child stderr:\n") catch return;
        stderr.writeAll(child_stderr) catch return;
        if (child_stderr[child_stderr.len - 1] != '\n') stderr.writeByte('\n') catch return;
    }
}

fn writeShellishArg(writer: *std.Io.Writer, arg: []const u8) !void {
    try writer.writeByte('\'');
    for (arg) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('\'');
}

fn extensionSmokeTempPath(allocator: std.mem.Allocator, name: []const u8) ![:0]u8 {
    return extensionSmokeTempFilePath(allocator, "db", name, ".zova");
}

fn extensionSmokeTrustPath(allocator: std.mem.Allocator, name: []const u8) ![:0]u8 {
    return extensionSmokeTempFilePath(allocator, "trust", name, ".json");
}

fn extensionSmokeTempFilePath(allocator: std.mem.Allocator, kind: []const u8, name: []const u8, suffix: []const u8) ![:0]u8 {
    var random_bytes: [16]u8 = undefined;
    sqlite.c.sqlite3_randomness(random_bytes.len, &random_bytes);
    var random_hex: [32]u8 = undefined;
    lowerHex32(&random_hex, &random_bytes);

    const filename = try std.fmt.allocPrint(allocator, "zova-extension-smoke-{s}-{s}-{s}{s}", .{ kind, name, random_hex, suffix });
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ extensionSmokeTempRoot(), filename });
    defer allocator.free(path);
    return try allocator.dupeZ(u8, path);
}

fn deleteExtensionSmokeDatabaseFiles(allocator: std.mem.Allocator, path: []const u8) void {
    const io = defaultIo();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const wal_path = std.fmt.allocPrint(allocator, "{s}-wal", .{path}) catch return;
    defer allocator.free(wal_path);
    std.Io.Dir.cwd().deleteFile(io, wal_path) catch {};

    const journal_path = std.fmt.allocPrint(allocator, "{s}-journal", .{path}) catch return;
    defer allocator.free(journal_path);
    std.Io.Dir.cwd().deleteFile(io, journal_path) catch {};

    const shm_path = std.fmt.allocPrint(allocator, "{s}-shm", .{path}) catch return;
    defer allocator.free(shm_path);
    std.Io.Dir.cwd().deleteFile(io, shm_path) catch {};
}

fn extensionSmokeTempRoot() []const u8 {
    if (absoluteNonEmptyEnv("TMPDIR")) |path| return path;
    if (absoluteNonEmptyEnv("TMP")) |path| return path;
    if (absoluteNonEmptyEnv("TEMP")) |path| return path;
    return "/tmp";
}

fn absoluteNonEmptyEnv(name: [:0]const u8) ?[]const u8 {
    const value = getenv(name) orelse return null;
    if (value.len == 0 or !std.fs.path.isAbsolute(value)) return null;
    return value;
}

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(value);
}

fn copyEnv(env: *std.process.Environ.Map, name: [:0]const u8) !void {
    if (getenv(name)) |value| try env.put(name, value);
}

fn fileExists(path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(defaultIo(), path, .{}) catch return false;
    file.close(defaultIo());
    return true;
}

fn writeExtensionBuilderSuccess(
    stdout: *std.Io.Writer,
    format: OutputFormat,
    command: []const u8,
    path: []const u8,
    output_path: ?[]const u8,
    follow_up: ?[]const u8,
) !void {
    switch (format) {
        .text => {
            try stdout.print("{s}: ok\n", .{command});
            try stdout.writeAll("experimental: true\n");
            try stdout.print("path: {s}\n", .{path});
            if (output_path) |value| try stdout.print("output: {s}\n", .{value});
            if (follow_up) |value| try stdout.print("next: {s}\n", .{value});
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"experimental\": true,\n");
            try stdout.writeAll("  \"command\": ");
            try writeJsonString(stdout, command);
            try stdout.writeAll(",\n  \"path\": ");
            try writeJsonString(stdout, path);
            if (output_path) |value| {
                try stdout.writeAll(",\n  \"output\": ");
                try writeJsonString(stdout, value);
            }
            if (follow_up) |value| {
                try stdout.writeAll(",\n  \"next\": ");
                try writeJsonString(stdout, value);
            }
            try stdout.writeAll("\n}\n");
        },
    }
}

const BuilderManifest = struct {
    name: []u8,
    library: []u8,

    fn deinit(self: *BuilderManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.library);
    }
};

fn loadBuilderManifest(allocator: std.mem.Allocator, dir_path: []const u8) !BuilderManifest {
    const manifest_path = try std.fs.path.join(allocator, &.{ dir_path, zova.extension_dynamic.bundle_manifest_file });
    defer allocator.free(manifest_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(defaultIo(), manifest_path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.ExtensionInvalid;
    defer parsed.deinit();
    if (std.meta.activeTag(parsed.value) != .object) return error.ExtensionInvalid;
    const object = parsed.value.object;
    return .{
        .name = try allocator.dupe(u8, try builderJsonString(object, "name")),
        .library = try allocator.dupe(u8, try builderJsonString(object, "library")),
    };
}

fn builderJsonString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.ExtensionInvalid;
    if (std.meta.activeTag(value) != .string) return error.ExtensionInvalid;
    return value.string;
}

fn copyFileAlloc(allocator: std.mem.Allocator, source_path: []const u8, dest_path: []const u8, limit: usize) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(defaultIo(), source_path, allocator, .limited(limit));
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(defaultIo(), .{ .sub_path = dest_path, .data = bytes });
}

fn dynamicLibraryFileName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => try std.fmt.allocPrint(allocator, "{s}.dll", .{name}),
        .macos, .ios, .tvos, .watchos, .visionos => try std.fmt.allocPrint(allocator, "lib{s}.dylib", .{name}),
        else => try std.fmt.allocPrint(allocator, "lib{s}.so", .{name}),
    };
}

fn extensionAbiMinimum(buffer: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{
        zova.version.abi_version_major,
        zova.version.abi_version_minor,
        zova.version.abi_version_patch,
    }) catch unreachable;
}

fn scaffoldExtensionManifest(allocator: std.mem.Allocator, name: []const u8, version: []const u8, storage_prefix: []const u8, library: []const u8) ![]u8 {
    var abi_buffer: [32]u8 = undefined;
    const abi_minimum = extensionAbiMinimum(&abi_buffer);
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "{s}",
        \\  "version": "{s}",
        \\  "storage_prefix": "{s}",
        \\  "zova_abi_min": "{s}",
        \\  "capabilities": "experimental-builder",
        \\  "library": "{s}"
        \\}}
        \\
    , .{ name, version, storage_prefix, abi_minimum, library });
}

fn scaffoldExtensionSource(allocator: std.mem.Allocator, name: []const u8, version: []const u8, storage_prefix: []const u8) ![]u8 {
    var abi_buffer: [32]u8 = undefined;
    const abi_minimum = extensionAbiMinimum(&abi_buffer);
    return std.fmt.allocPrint(allocator,
        \\const zova = @import("zova");
        \\
        \\const HookError = error{{ ExtensionInvalid }};
        \\
        \\const manifest = zova.ExtensionManifest{{
        \\    .name = "{s}",
        \\    .version = "{s}",
        \\    .storage_prefix = "{s}",
        \\    .zova_abi_min = "{s}",
        \\    .capabilities = "experimental-builder",
        \\    .required = true,
        \\    .manifest_json = "{{\"extension\":\"{s}\",\"experimental\":true}}",
        \\}};
        \\
        \\const extension = zova.Extension{{
        \\    .manifest = manifest,
        \\    .install = install,
        \\    .check = check,
        \\    .drop = drop,
        \\}};
        \\
        \\pub export fn zova_extension_entry() callconv(.c) *const zova.Extension {{
        \\    return &extension;
        \\}}
        \\
        \\fn install(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {{
        \\}}
        \\
        \\fn check(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {{
        \\}}
        \\
        \\fn drop(_: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {{
        \\}}
        \\
    , .{ name, version, storage_prefix, abi_minimum, name });
}

fn isValidExtensionScaffoldName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (startsWithZovaPrefix(name)) return false;
    if (!((name[0] >= 'A' and name[0] <= 'Z') or (name[0] >= 'a' and name[0] <= 'z') or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        const ok = (byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '_';
        if (!ok) return false;
    }
    return true;
}

fn extensionOpenErrorFormat(stderr: *std.Io.Writer, format: OutputFormat, err: anyerror) !u8 {
    const is_extension_health = isExtensionHealthError(err);
    switch (format) {
        .text => try stderr.print("extension: {s}: {s}\n", .{ if (is_extension_health) "failed" else "open failed", @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, "extension", if (is_extension_health) "extension failed" else "open failed", @errorName(err)),
    }
    return if (is_extension_health) ExitCode.check_failed else ExitCode.open;
}

fn extensionErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    switch (format) {
        .text => try stderr.print("{s}: failed: {s}\n", .{ command, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, "extension failed", @errorName(err)),
    }
    return ExitCode.check_failed;
}

pub fn dynamicExtensionLoadErrorFormat(stderr: *std.Io.Writer, format: OutputFormat, err: anyerror) !u8 {
    switch (format) {
        .text => {
            try stderr.print("extension-load: failed: {s}\n", .{@errorName(err)});
            try stderr.writeAll("suggested_actions:\n");
            try writeExtensionSuggestedActionsText(stderr, "");
        },
        .json => {
            try writeJsonErrorWithKindAndActions(stderr, "extension-load", "extension load failed", @errorName(err), .{ .extension = 1 });
        },
    }
    return ExitCode.check_failed;
}

fn writeExtensionList(
    stdout: *std.Io.Writer,
    format: OutputFormat,
    path: []const u8,
    extensions: zova.ExtensionList,
) !void {
    switch (format) {
        .text => {
            try stdout.print("extension-list: {s}\n", .{path});
            try stdout.print("extensions: {d}\n", .{extensions.items.len});
            if (extensions.items.len == 0) {
                try stdout.writeAll("  none\n");
            } else {
                for (extensions.items) |item| {
                    try stdout.print("  {s} version={s} storage_prefix={s} required={}\n", .{
                        item.name,
                        item.version,
                        item.storage_prefix,
                        item.required,
                    });
                }
            }
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"command\": \"extension-list\",\n");
            try stdout.writeAll("  \"path\": ");
            try writeJsonString(stdout, path);
            try stdout.print(",\n  \"count\": {d},\n", .{extensions.items.len});
            try stdout.writeAll("  \"extensions\": [");
            for (extensions.items, 0..) |item, index| {
                if (index != 0) try stdout.writeAll(", ");
                try writeExtensionInfoObject(stdout, item);
            }
            try stdout.writeAll("]\n}\n");
        },
    }
}

fn writeExtensionInfo(
    stdout: *std.Io.Writer,
    format: OutputFormat,
    command: []const u8,
    path: []const u8,
    info: zova.ExtensionInfo,
) !void {
    switch (format) {
        .text => {
            try stdout.print("{s}: ok\n", .{command});
            try stdout.print("path: {s}\n", .{path});
            try stdout.print("name: {s}\n", .{info.name});
            try stdout.print("version: {s}\n", .{info.version});
            try stdout.print("storage_prefix: {s}\n", .{info.storage_prefix});
            try stdout.print("zova_abi_min: {s}\n", .{info.zova_abi_min});
            try stdout.print("capabilities: {s}\n", .{info.capabilities});
            try stdout.print("required: {}\n", .{info.required});
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"command\": ");
            try writeJsonString(stdout, command);
            try stdout.writeAll(",\n  \"path\": ");
            try writeJsonString(stdout, path);
            try stdout.writeAll(",\n  \"extension\": ");
            try writeExtensionInfoObject(stdout, info);
            try stdout.writeAll("\n}\n");
        },
    }
}

fn writeExtensionMutationSuccess(
    stdout: *std.Io.Writer,
    format: OutputFormat,
    command: []const u8,
    path: []const u8,
    name: []const u8,
) !void {
    switch (format) {
        .text => {
            try stdout.print("{s}: ok\n", .{command});
            try stdout.print("path: {s}\n", .{path});
            try stdout.print("name: {s}\n", .{name});
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"command\": ");
            try writeJsonString(stdout, command);
            try stdout.writeAll(",\n  \"path\": ");
            try writeJsonString(stdout, path);
            try stdout.writeAll(",\n  \"name\": ");
            try writeJsonString(stdout, name);
            try stdout.writeAll("\n}\n");
        },
    }
}

fn writeExtensionTrustSuccess(
    stdout: *std.Io.Writer,
    format: OutputFormat,
    command: []const u8,
    record: zova.DynamicExtensionTrustRecord,
) !void {
    switch (format) {
        .text => {
            try stdout.print("{s}: ok\n", .{command});
            try stdout.print("name: {s}\n", .{record.name});
            try stdout.print("version: {s}\n", .{record.version});
            try stdout.print("storage_prefix: {s}\n", .{record.storage_prefix});
            try stdout.print("bundle_path: {s}\n", .{record.bundle_path});
            try stdout.writeAll("trusted: true\n");
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"command\": ");
            try writeJsonString(stdout, command);
            try stdout.writeAll(",\n  \"trusted_extension\": ");
            try writeTrustedExtensionObject(stdout, record);
            try stdout.writeAll("\n}\n");
        },
    }
}

fn writeExtensionUntrustSuccess(
    stdout: *std.Io.Writer,
    format: OutputFormat,
    identifier: []const u8,
    removed: bool,
) !void {
    switch (format) {
        .text => {
            try stdout.writeAll("extension-untrust: ok\n");
            try stdout.print("identifier: {s}\n", .{identifier});
            try stdout.print("removed: {}\n", .{removed});
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"command\": \"extension-untrust\",\n");
            try stdout.writeAll("  \"identifier\": ");
            try writeJsonString(stdout, identifier);
            try stdout.print(",\n  \"removed\": {}\n", .{removed});
            try stdout.writeAll("}\n");
        },
    }
}

fn writeTrustedExtensionList(
    stdout: *std.Io.Writer,
    format: OutputFormat,
    trusted: zova.DynamicExtensionTrustedList,
) !void {
    switch (format) {
        .text => {
            try stdout.writeAll("extension-trusted: ok\n");
            try stdout.print("trusted_extensions: {d}\n", .{trusted.records.len});
            if (trusted.records.len == 0) {
                try stdout.writeAll("  none\n");
            } else {
                for (trusted.records) |record| {
                    try stdout.print("  {s} version={s} bundle_path={s}\n", .{ record.name, record.version, record.bundle_path });
                }
            }
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"command\": \"extension-trusted\",\n");
            try stdout.print("  \"count\": {d},\n", .{trusted.records.len});
            try stdout.writeAll("  \"trusted_extensions\": [");
            for (trusted.records, 0..) |record, index| {
                if (index != 0) try stdout.writeAll(", ");
                try writeTrustedExtensionObject(stdout, record);
            }
            try stdout.writeAll("]\n}\n");
        },
    }
}

fn writeTrustedExtensionObject(writer: *std.Io.Writer, record: zova.DynamicExtensionTrustRecord) !void {
    try writer.writeAll("{\"name\": ");
    try writeJsonString(writer, record.name);
    try writer.writeAll(", \"version\": ");
    try writeJsonString(writer, record.version);
    try writer.writeAll(", \"storage_prefix\": ");
    try writeJsonString(writer, record.storage_prefix);
    try writer.writeAll(", \"bundle_path\": ");
    try writeJsonString(writer, record.bundle_path);
    try writer.writeAll(", \"manifest_sha256\": ");
    try writeJsonString(writer, record.manifest_sha256[0..]);
    try writer.writeAll(", \"library_sha256\": ");
    try writeJsonString(writer, record.library_sha256[0..]);
    try writer.print(", \"trusted_at_unix\": {d}}}", .{record.trusted_at_unix});
}

fn writeExtensionInfoObject(writer: *std.Io.Writer, info: zova.ExtensionInfo) !void {
    try writer.writeAll("{\"name\": ");
    try writeJsonString(writer, info.name);
    try writer.writeAll(", \"version\": ");
    try writeJsonString(writer, info.version);
    try writer.writeAll(", \"storage_prefix\": ");
    try writeJsonString(writer, info.storage_prefix);
    try writer.writeAll(", \"zova_abi_min\": ");
    try writeJsonString(writer, info.zova_abi_min);
    try writer.writeAll(", \"capabilities\": ");
    try writeJsonString(writer, info.capabilities);
    try writer.print(", \"required\": {}}}", .{info.required});
}
