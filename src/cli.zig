//! CLI command dispatch. Parsing, output, and command implementations live in cli/.

const std = @import("std");
const zova = @import("zova");
const cli_options = @import("cli_options");
pub const package_version = cli_options.package_version;
pub const dynamic_extension_library_path = cli_options.dynamic_extension_library_path;
pub const source_root = cli_options.source_root;
pub const zig_exe = cli_options.zig_exe;
pub const zova_exe_path = cli_options.zova_exe_path;

const CommandContext = @import("cli/types.zig").CommandContext;
const ExitCode = @import("cli/common.zig").ExitCode;
const argsContain = @import("cli/parse.zig").argsContain;
const backupCommand = @import("cli/maintenance.zig").backupCommand;
const checkCommand = @import("cli/doctor.zig").checkCommand;
const chunkCommand = @import("cli/inspect.zig").chunkCommand;
const chunksCommand = @import("cli/inspect.zig").chunksCommand;
const compactCommand = @import("cli/maintenance.zig").compactCommand;
const doctorCommand = @import("cli/doctor.zig").doctorCommand;
const dynamicExtensionLoadErrorFormat = @import("cli/extensions.zig").dynamicExtensionLoadErrorFormat;
const extensionCommand = @import("cli/extensions.zig").extensionCommand;
const formatCommand = @import("cli/maintenance.zig").formatCommand;
const graphCommand = @import("cli/inspect.zig").graphCommand;
const graphNeighborsCommand = @import("cli/inspect.zig").graphNeighborsCommand;
const graphNodeCommand = @import("cli/inspect.zig").graphNodeCommand;
const graphStoreCommand = @import("cli/stores.zig").graphStoreCommand;
const graphWalkCommand = @import("cli/inspect.zig").graphWalkCommand;
const graphsCommand = @import("cli/inspect.zig").graphsCommand;
const infoCommand = @import("cli/inspect.zig").infoCommand;
const migrateCommand = @import("cli/maintenance.zig").migrateCommand;
const objectCommand = @import("cli/inspect.zig").objectCommand;
const objectStoreCommand = @import("cli/stores.zig").objectStoreCommand;
const objectsCommand = @import("cli/inspect.zig").objectsCommand;
const parseGlobalArgs = @import("cli/parse.zig").parseGlobalArgs;
const restoreCommand = @import("cli/maintenance.zig").restoreCommand;
const salvageCommand = @import("cli/salvage.zig").salvageCommand;
const splitCommand = @import("cli/stores.zig").splitCommand;
const statsCommand = @import("cli/inspect.zig").statsCommand;
const tablesCommand = @import("cli/inspect.zig").tablesCommand;
const usageError = @import("cli/render.zig").usageError;
const vectorCollectionCommand = @import("cli/inspect.zig").vectorCollectionCommand;
const vectorStoreCommand = @import("cli/stores.zig").vectorStoreCommand;
const vectorsCommand = @import("cli/inspect.zig").vectorsCommand;
const writeUsage = @import("cli/render.zig").writeUsage;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var parsed_global = parseGlobalArgs(allocator, args) catch |err| switch (err) {
        error.MissingExtensionPath => return usageError(stderr, "--extension requires <bundle.zovaext>"),
        else => return err,
    };
    defer parsed_global.deinit(allocator);

    var dynamic_extensions = zova.DynamicExtensionSet.loadTrustedBundles(
        allocator,
        parsed_global.extension_paths,
        .{},
    ) catch |err| return dynamicExtensionLoadErrorFormat(stderr, if (argsContain(args, "--json")) .json else .text, err);
    defer dynamic_extensions.deinit();

    var owned_registry = zova.DynamicExtensionOwnedRegistry.init(allocator, &.{
        zova.bundledExtensionRegistry(),
        dynamic_extensions.registry(),
    }) catch |err| return dynamicExtensionLoadErrorFormat(stderr, if (argsContain(args, "--json")) .json else .text, err);
    defer owned_registry.deinit();

    const ctx: CommandContext = .{ .registry = owned_registry.registry() };
    const parsed_args = parsed_global.args;

    if (parsed_args.len <= 1) {
        try writeUsage(stderr);
        return ExitCode.usage;
    }

    const command = parsed_args[1];
    if (std.mem.eql(u8, command, "--version")) {
        if (parsed_args.len != 2) return usageError(stderr, "unexpected argument after --version");
        try stdout.print("zova {s}\n", .{package_version});
        return ExitCode.ok;
    }
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        if (parsed_args.len != 2) return usageError(stderr, "unexpected argument after help");
        try writeUsage(stdout);
        return ExitCode.ok;
    }
    if (std.mem.eql(u8, command, "info")) {
        return infoCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "stats")) {
        return statsCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "objects")) {
        return objectsCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "object")) {
        return objectCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "chunks")) {
        return chunksCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "chunk")) {
        return chunkCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "vectors")) {
        return vectorsCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "vector-collection")) {
        return vectorCollectionCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "graphs")) {
        return graphsCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "graph")) {
        return graphCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "graph-node")) {
        return graphNodeCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "graph-neighbors")) {
        return graphNeighborsCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "graph-walk")) {
        return graphWalkCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "tables")) {
        return tablesCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "check")) {
        return checkCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "doctor")) {
        return doctorCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "salvage")) {
        return salvageCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "backup")) {
        return backupCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "compact")) {
        return compactCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "restore")) {
        return restoreCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "split")) {
        return splitCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "object-store")) {
        return objectStoreCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "vector-store")) {
        return vectorStoreCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "graph-store")) {
        return graphStoreCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "format")) {
        return formatCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "migrate")) {
        return migrateCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "extension")) {
        return extensionCommand(ctx, allocator, parsed_args[2..], stdout, stderr);
    }

    try stderr.print("unknown command: {s}\n\n", .{command});
    try writeUsage(stderr);
    return ExitCode.usage;
}
