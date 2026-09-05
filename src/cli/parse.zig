//! CLI argument parsing and usage-error messages.

const std = @import("std");

const BoundedCommandArgs = @import("types.zig").BoundedCommandArgs;
const BoundedCommandParseError = @import("types.zig").BoundedCommandParseError;
const ExtensionAction = @import("types.zig").ExtensionAction;
const ExtensionCommandArgs = @import("types.zig").ExtensionCommandArgs;
const ExtensionCommandParseError = @import("types.zig").ExtensionCommandParseError;
const GraphCommandParseError = @import("types.zig").GraphCommandParseError;
const GraphNeighborsCommandArgs = @import("types.zig").GraphNeighborsCommandArgs;
const GraphNodeCommandArgs = @import("types.zig").GraphNodeCommandArgs;
const GraphWalkCommandArgs = @import("types.zig").GraphWalkCommandArgs;
const ObjectStoreAction = @import("types.zig").ObjectStoreAction;
const ObjectStoreCommandArgs = @import("types.zig").ObjectStoreCommandArgs;
const ObjectStoreCommandParseError = @import("types.zig").ObjectStoreCommandParseError;
const OperationalCommandArgs = @import("types.zig").OperationalCommandArgs;
const OutputFormat = @import("types.zig").OutputFormat;
const ParsedGlobalArgs = @import("types.zig").ParsedGlobalArgs;
const SalvageCommandArgs = @import("types.zig").SalvageCommandArgs;
const SalvageCommandParseError = @import("types.zig").SalvageCommandParseError;
const SplitCommandArgs = @import("types.zig").SplitCommandArgs;
const SplitCommandParseError = @import("types.zig").SplitCommandParseError;
const SplitRole = @import("types.zig").SplitRole;
const default_list_limit = @import("common.zig").default_list_limit;
const isValidCliExtensionName = @import("common.zig").isValidCliExtensionName;
const max_list_limit = @import("common.zig").max_list_limit;

const GlobalParseError = error{
    MissingExtensionPath,
};

pub fn parseGlobalArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParsedGlobalArgs {
    var remaining: std.ArrayList([]const u8) = .empty;
    errdefer remaining.deinit(allocator);
    var extension_paths: std.ArrayList([]const u8) = .empty;
    errdefer extension_paths.deinit(allocator);

    if (args.len == 0) {
        return .{
            .args = try allocator.alloc([]const u8, 0),
            .extension_paths = try allocator.alloc([]const u8, 0),
        };
    }

    try remaining.append(allocator, args[0]);
    var index: usize = 1;
    while (index < args.len and std.mem.eql(u8, args[index], "--extension")) {
        index += 1;
        if (index >= args.len) return error.MissingExtensionPath;
        try extension_paths.append(allocator, args[index]);
        index += 1;
    }
    while (index < args.len) : (index += 1) try remaining.append(allocator, args[index]);

    return .{
        .args = try remaining.toOwnedSlice(allocator),
        .extension_paths = try extension_paths.toOwnedSlice(allocator),
    };
}

fn globalUsageMessage(err: GlobalParseError) []const u8 {
    return switch (err) {
        error.MissingExtensionPath => "--extension requires <bundle.zovaext>",
    };
}

pub fn parseOperationalCommandArgs(
    args: []const []const u8,
    command: []const u8,
    stderr: *std.Io.Writer,
) !OperationalCommandArgs {
    var format: OutputFormat = .text;
    var verify = true;
    var saw_no_verify = false;
    var source_path: ?[]const u8 = null;
    var destination_path: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            if (saw_no_verify) return error.DuplicateNoVerify;
            saw_no_verify = true;
            verify = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (source_path == null) {
            source_path = arg;
        } else if (destination_path == null) {
            destination_path = arg;
        } else {
            return error.ExtraArgs;
        }
    }

    const source = source_path orelse {
        _ = stderr;
        _ = command;
        return error.MissingSource;
    };
    const destination = destination_path orelse return error.MissingDestination;

    return .{
        .format = format,
        .verify = verify,
        .source_path = source,
        .destination_path = destination,
    };
}

pub fn operationalUsageMessage(command: []const u8, err: anyerror) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.DuplicateNoVerify => "duplicate --no-verify",
        error.UnknownFlag => "unknown flag",
        error.MissingSource => "missing source path",
        error.MissingDestination => "missing destination path",
        error.ExtraArgs => if (std.mem.eql(u8, command, "restore"))
            "restore accepts only [--json] [--no-verify] <backup.zova> <destination.zova>"
        else
            "command accepts only [--json] [--no-verify] <source.zova> <destination.zova>",
        else => "invalid command arguments",
    };
}

pub fn argsContain(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

pub const FormatCommandArgs = struct {
    format: OutputFormat,
    path: []const u8,
};

pub const MigrateCommandArgs = struct {
    format: OutputFormat,
    verify: bool,
    source_path: []const u8,
    destination_path: []const u8,
};

const FormatCommandParseError = error{
    DuplicateJson,
    UnknownFlag,
    MissingPath,
    ExtraArgs,
};

const MigrateCommandParseError = error{
    DuplicateJson,
    DuplicateNoVerify,
    UnknownFlag,
    MissingSource,
    MissingDestination,
    ExtraArgs,
};

pub fn parseFormatCommandArgs(args: []const []const u8) FormatCommandParseError!FormatCommandArgs {
    var format: OutputFormat = .text;
    var path: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (path == null) {
            path = arg;
        } else {
            return error.ExtraArgs;
        }
    }
    const p = path orelse return error.MissingPath;
    return .{ .format = format, .path = p };
}

pub fn formatUsageMessage(err: FormatCommandParseError) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.UnknownFlag => "unknown flag",
        error.MissingPath => "format requires <database.zova>",
        error.ExtraArgs => "format accepts only [--json] <database.zova>",
    };
}

pub fn parseMigrateCommandArgs(args: []const []const u8) MigrateCommandParseError!MigrateCommandArgs {
    var format: OutputFormat = .text;
    var verify = true;
    var saw_no_verify = false;
    var source_path: ?[]const u8 = null;
    var destination_path: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            if (saw_no_verify) return error.DuplicateNoVerify;
            saw_no_verify = true;
            verify = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (source_path == null) {
            source_path = arg;
        } else if (destination_path == null) {
            destination_path = arg;
        } else {
            return error.ExtraArgs;
        }
    }
    const source = source_path orelse return error.MissingSource;
    const destination = destination_path orelse return error.MissingDestination;
    return .{
        .format = format,
        .verify = verify,
        .source_path = source,
        .destination_path = destination,
    };
}

pub fn migrateUsageMessage(err: MigrateCommandParseError) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.DuplicateNoVerify => "duplicate --no-verify",
        error.UnknownFlag => "unknown flag",
        error.MissingSource => "migrate requires <source.zova>",
        error.MissingDestination => "migrate requires <destination.zova>",
        error.ExtraArgs => "migrate accepts only [--json] [--no-verify] <source.zova> <destination.zova>",
    };
}

pub fn parseSplitCommandArgs(args: []const []const u8) SplitCommandParseError!SplitCommandArgs {
    var format: OutputFormat = .text;
    var role: ?SplitRole = null;
    var main_path: ?[]const u8 = null;
    var store_path: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--objects")) {
            if (role != null) return error.DuplicateRole;
            role = .objects;
        } else if (std.mem.eql(u8, arg, "--vectors")) {
            if (role != null) return error.DuplicateRole;
            role = .vectors;
        } else if (std.mem.eql(u8, arg, "--graphs")) {
            if (role != null) return error.DuplicateRole;
            role = .graphs;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (main_path == null) {
            main_path = arg;
        } else if (store_path == null) {
            store_path = arg;
        } else {
            return error.ExtraArgs;
        }
    }

    const selected_role = role orelse return error.MissingRole;
    const main = main_path orelse return error.MissingMainPath;
    const store = store_path orelse return error.MissingStorePath;
    if (std.mem.eql(u8, main, store)) return error.SamePath;

    return .{
        .format = format,
        .role = selected_role,
        .main_path = main,
        .store_path = store,
    };
}

pub fn splitUsageMessage(err: SplitCommandParseError) []const u8 {
    return switch (err) {
        error.MissingRole => "split requires exactly one of --objects, --vectors, or --graphs",
        error.DuplicateRole => "split accepts only one role flag",
        error.DuplicateJson => "duplicate --json",
        error.UnknownFlag => "unknown flag",
        error.MissingMainPath => "split requires <main.zova>",
        error.MissingStorePath => "split requires <store.zova>",
        error.SamePath => "split store path must differ from main path",
        error.ExtraArgs => "split accepts only (--objects | --vectors | --graphs) [--json] <main.zova> <store.zova>",
    };
}

pub fn parseObjectStoreCommandArgs(args: []const []const u8) ObjectStoreCommandParseError!ObjectStoreCommandArgs {
    if (args.len == 0) return error.MissingAction;

    const action = parseObjectStoreAction(args[0]) orelse return error.UnknownAction;
    var format: OutputFormat = .text;
    var first_path: ?[]const u8 = null;
    var second_path: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (first_path == null) {
            first_path = arg;
        } else if (second_path == null) {
            second_path = arg;
        } else {
            return error.ExtraArgs;
        }
    }

    switch (action) {
        .create => {
            const store_path = first_path orelse return error.MissingStorePath;
            if (second_path != null) return error.ExtraArgs;
            return .{ .format = format, .action = action, .main_path = null, .store_path = store_path };
        },
        .bind => {
            const main_path = first_path orelse return error.MissingMainPath;
            const store_path = second_path orelse return error.MissingStorePath;
            return .{ .format = format, .action = action, .main_path = main_path, .store_path = store_path };
        },
        .info, .unbind => {
            const main_path = first_path orelse return error.MissingMainPath;
            if (second_path != null) return error.ExtraArgs;
            return .{ .format = format, .action = action, .main_path = main_path, .store_path = null };
        },
    }
}

pub fn parseExtensionCommandArgs(args: []const []const u8) ExtensionCommandParseError!ExtensionCommandArgs {
    if (args.len == 0) return error.MissingAction;

    const action = parseExtensionAction(args[0]) orelse return error.UnknownAction;
    var format: OutputFormat = .text;
    var first_path: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var smoke = false;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--name")) {
            if (name != null) return error.DuplicateName;
            index += 1;
            if (index >= args.len) return error.MissingFlagValue;
            if (!isValidCliExtensionName(args[index])) return error.InvalidName;
            name = args[index];
        } else if (std.mem.eql(u8, arg, "--version")) {
            if (version != null) return error.DuplicateVersion;
            index += 1;
            if (index >= args.len) return error.MissingFlagValue;
            version = args[index];
        } else if (std.mem.eql(u8, arg, "--out")) {
            if (out_path != null) return error.DuplicateOut;
            index += 1;
            if (index >= args.len) return error.MissingFlagValue;
            out_path = args[index];
        } else if (std.mem.eql(u8, arg, "--smoke")) {
            if (smoke) return error.DuplicateSmoke;
            smoke = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (first_path == null) {
            first_path = arg;
        } else if (name == null) {
            if (!isValidCliExtensionName(arg)) return error.InvalidName;
            name = arg;
        } else {
            return error.ExtraArgs;
        }
    }

    switch (action) {
        .list => {
            _ = first_path orelse return error.MissingPath;
            if (name != null or version != null or out_path != null or smoke) return error.ExtraArgs;
        },
        .info, .drop, .install => {
            _ = first_path orelse return error.MissingPath;
            _ = name orelse return error.MissingName;
            if (version != null or out_path != null or smoke) return error.ExtraArgs;
        },
        .check => {
            _ = first_path orelse return error.MissingPath;
            if (version != null or out_path != null or smoke) return error.ExtraArgs;
        },
        .trust, .untrust => {
            _ = first_path orelse return error.MissingPath;
            if (name != null or version != null or out_path != null or smoke) return error.ExtraArgs;
        },
        .trusted => {
            if (first_path != null or name != null or version != null or out_path != null or smoke) return error.ExtraArgs;
        },
        .scaffold => {
            _ = first_path orelse return error.MissingPath;
            _ = name orelse return error.MissingName;
            _ = version orelse return error.MissingVersion;
            if (out_path != null or smoke) return error.ExtraArgs;
        },
        .build => {
            _ = first_path orelse return error.MissingPath;
            if (name != null or version != null or out_path != null or smoke) return error.ExtraArgs;
        },
        .pack => {
            _ = first_path orelse return error.MissingPath;
            _ = out_path orelse return error.MissingOut;
            if (name != null or version != null or smoke) return error.ExtraArgs;
        },
        .verify => {
            _ = first_path orelse return error.MissingPath;
            if (name != null or version != null or out_path != null) return error.ExtraArgs;
        },
    }

    return .{ .format = format, .action = action, .path = first_path, .name = name, .version = version, .out_path = out_path, .smoke = smoke };
}

fn parseExtensionAction(value: []const u8) ?ExtensionAction {
    if (std.mem.eql(u8, value, "list")) return .list;
    if (std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "check")) return .check;
    if (std.mem.eql(u8, value, "drop")) return .drop;
    if (std.mem.eql(u8, value, "install")) return .install;
    if (std.mem.eql(u8, value, "trust")) return .trust;
    if (std.mem.eql(u8, value, "untrust")) return .untrust;
    if (std.mem.eql(u8, value, "trusted")) return .trusted;
    if (std.mem.eql(u8, value, "scaffold")) return .scaffold;
    if (std.mem.eql(u8, value, "build")) return .build;
    if (std.mem.eql(u8, value, "pack")) return .pack;
    if (std.mem.eql(u8, value, "verify")) return .verify;
    return null;
}

pub fn extensionUsageMessage(err: ExtensionCommandParseError) []const u8 {
    return switch (err) {
        error.MissingAction => "extension requires list, info, check, drop, install, trust, untrust, trusted, scaffold, build, pack, or verify",
        error.UnknownAction => "unknown extension action",
        error.DuplicateJson => "duplicate --json",
        error.DuplicateName => "duplicate --name",
        error.DuplicateVersion => "duplicate --version",
        error.DuplicateOut => "duplicate --out",
        error.DuplicateSmoke => "duplicate --smoke",
        error.UnknownFlag => "unknown flag",
        error.MissingFlagValue => "extension flag requires a value",
        error.MissingPath => "extension action requires <file.zova> or <bundle.zovaext>",
        error.MissingName => "extension action requires <name>",
        error.MissingVersion => "extension scaffold requires --version <version>",
        error.MissingOut => "extension pack requires --out <bundle.zovaext>",
        error.InvalidName => "extension name is invalid",
        error.ExtraArgs => "extension action received extra arguments",
    };
}

fn parseObjectStoreAction(value: []const u8) ?ObjectStoreAction {
    if (std.mem.eql(u8, value, "create")) return .create;
    if (std.mem.eql(u8, value, "bind")) return .bind;
    if (std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "unbind")) return .unbind;
    return null;
}

pub fn objectStoreUsageMessage(err: ObjectStoreCommandParseError) []const u8 {
    return switch (err) {
        error.MissingAction => "object-store requires create, bind, info, or unbind",
        error.UnknownAction => "unknown object-store action",
        error.DuplicateJson => "duplicate --json",
        error.UnknownFlag => "unknown flag",
        error.MissingMainPath => "object-store action requires <main.zova>",
        error.MissingStorePath => "object-store action requires <objects.zova>",
        error.ExtraArgs => "object-store action received extra arguments",
    };
}

pub fn vectorStoreUsageMessage(err: ObjectStoreCommandParseError) []const u8 {
    return switch (err) {
        error.MissingAction => "vector-store requires create, bind, info, or unbind",
        error.UnknownAction => "unknown vector-store action",
        error.DuplicateJson => "duplicate --json",
        error.UnknownFlag => "unknown flag",
        error.MissingMainPath => "vector-store action requires <main.zova>",
        error.MissingStorePath => "vector-store action requires <vectors.zova>",
        error.ExtraArgs => "vector-store action received extra arguments",
    };
}

pub fn graphStoreUsageMessage(err: ObjectStoreCommandParseError) []const u8 {
    return switch (err) {
        error.MissingAction => "graph-store requires create, bind, info, or unbind",
        error.UnknownAction => "unknown graph-store action",
        error.DuplicateJson => "duplicate --json",
        error.UnknownFlag => "unknown flag",
        error.MissingMainPath => "graph-store action requires <main.zova>",
        error.MissingStorePath => "graph-store action requires <graphs.zova>",
        error.ExtraArgs => "graph-store action received extra arguments",
    };
}

pub fn parseLimit(value: []const u8, max_limit: usize) !usize {
    if (value.len == 0) return error.InvalidLimit;
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidLimit;
    if (parsed > max_limit) return error.InvalidLimit;
    return parsed;
}

pub fn parseBoundedCommandArgs(args: []const []const u8, expect_id: bool) BoundedCommandParseError!BoundedCommandArgs {
    var format: OutputFormat = .text;
    var limit: usize = default_list_limit;
    var saw_limit = false;
    var positionals: [2][]const u8 = undefined;
    var positional_count: usize = 0;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            if (saw_limit) return error.DuplicateLimit;
            saw_limit = true;
            index += 1;
            if (index >= args.len) return error.MissingLimitValue;
            limit = parseLimit(args[index], max_list_limit) catch return error.InvalidLimit;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (positional_count >= positionals.len) return error.ExtraArgs;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingPath;
    if (expect_id and positional_count == 1) return error.MissingId;
    if (!expect_id and positional_count > 1) return error.ExtraArgs;
    if (expect_id and positional_count > 2) return error.ExtraArgs;

    return .{
        .format = format,
        .limit = limit,
        .path = positionals[0],
        .id = if (expect_id) positionals[1] else null,
    };
}

pub fn parseGraphNodeCommandArgs(args: []const []const u8) GraphCommandParseError!GraphNodeCommandArgs {
    var format: OutputFormat = .text;
    var positionals: [3][]const u8 = undefined;
    var positional_count: usize = 0;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (positional_count >= positionals.len) return error.ExtraArgs;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingPath;
    if (positional_count == 1) return error.MissingGraph;
    if (positional_count == 2) return error.MissingNode;

    return .{
        .format = format,
        .path = positionals[0],
        .graph_name = positionals[1],
        .node_id = positionals[2],
    };
}

pub fn parseGraphNeighborsCommandArgs(args: []const []const u8) GraphCommandParseError!GraphNeighborsCommandArgs {
    var format: OutputFormat = .text;
    var limit: usize = default_list_limit;
    var incoming = false;
    var edge_type: ?[]const u8 = null;
    var saw_limit = false;
    var saw_incoming = false;
    var saw_edge_type = false;
    var positionals: [3][]const u8 = undefined;
    var positional_count: usize = 0;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            if (saw_limit) return error.DuplicateLimit;
            saw_limit = true;
            index += 1;
            if (index >= args.len) return error.MissingLimitValue;
            limit = parseLimit(args[index], max_list_limit) catch return error.InvalidLimit;
        } else if (std.mem.eql(u8, arg, "--incoming")) {
            if (saw_incoming) return error.DuplicateIncoming;
            saw_incoming = true;
            incoming = true;
        } else if (std.mem.eql(u8, arg, "--edge-type")) {
            if (saw_edge_type) return error.DuplicateEdgeType;
            saw_edge_type = true;
            index += 1;
            if (index >= args.len) return error.MissingEdgeTypeValue;
            edge_type = args[index];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (positional_count >= positionals.len) return error.ExtraArgs;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingPath;
    if (positional_count == 1) return error.MissingGraph;
    if (positional_count == 2) return error.MissingNode;

    return .{
        .format = format,
        .limit = limit,
        .path = positionals[0],
        .graph_name = positionals[1],
        .node_id = positionals[2],
        .incoming = incoming,
        .edge_type = edge_type,
    };
}

pub fn parseGraphWalkCommandArgs(args: []const []const u8) GraphCommandParseError!GraphWalkCommandArgs {
    var format: OutputFormat = .text;
    var limit: usize = default_list_limit;
    var max_depth: u32 = 1;
    var edge_type: ?[]const u8 = null;
    var saw_limit = false;
    var saw_max_depth = false;
    var saw_edge_type = false;
    var positionals: [3][]const u8 = undefined;
    var positional_count: usize = 0;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            if (saw_limit) return error.DuplicateLimit;
            saw_limit = true;
            index += 1;
            if (index >= args.len) return error.MissingLimitValue;
            limit = parseLimit(args[index], max_list_limit) catch return error.InvalidLimit;
        } else if (std.mem.eql(u8, arg, "--max-depth")) {
            if (saw_max_depth) return error.DuplicateMaxDepth;
            saw_max_depth = true;
            index += 1;
            if (index >= args.len) return error.MissingMaxDepthValue;
            const parsed = std.fmt.parseUnsigned(u32, args[index], 10) catch return error.InvalidMaxDepth;
            if (parsed > 64) return error.InvalidMaxDepth;
            max_depth = parsed;
        } else if (std.mem.eql(u8, arg, "--edge-type")) {
            if (saw_edge_type) return error.DuplicateEdgeType;
            saw_edge_type = true;
            index += 1;
            if (index >= args.len) return error.MissingEdgeTypeValue;
            edge_type = args[index];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (positional_count >= positionals.len) return error.ExtraArgs;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingPath;
    if (positional_count == 1) return error.MissingGraph;
    if (positional_count == 2) return error.MissingNode;

    return .{
        .format = format,
        .limit = limit,
        .max_depth = max_depth,
        .path = positionals[0],
        .graph_name = positionals[1],
        .node_id = positionals[2],
        .edge_type = edge_type,
    };
}

pub fn parseSalvageCommandArgs(args: []const []const u8) SalvageCommandParseError!SalvageCommandArgs {
    var format: OutputFormat = .text;
    var limit: usize = default_list_limit;
    var saw_dry_run = false;
    var saw_limit = false;
    var positionals: [2][]const u8 = undefined;
    var positional_count: usize = 0;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return error.DuplicateJson;
            format = .json;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            if (saw_dry_run) return error.DuplicateDryRun;
            saw_dry_run = true;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            if (saw_limit) return error.DuplicateLimit;
            saw_limit = true;
            index += 1;
            if (index >= args.len) return error.MissingLimitValue;
            limit = parseLimit(args[index], max_list_limit) catch return error.InvalidLimit;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (positional_count >= positionals.len) return error.ExtraArgs;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingSource;
    if (saw_dry_run and positional_count > 1) return error.DestinationNotAllowed;
    if (!saw_dry_run and positional_count == 1) return error.MissingDestination;
    if (!saw_dry_run and positional_count > 2) return error.ExtraArgs;

    return .{
        .format = format,
        .limit = limit,
        .dry_run = saw_dry_run,
        .source_path = positionals[0],
        .destination_path = if (saw_dry_run) null else positionals[1],
    };
}

pub fn boundedCommandUsageMessage(command: []const u8, err: BoundedCommandParseError) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.DuplicateLimit => "duplicate --limit",
        error.MissingLimitValue => "--limit requires a value",
        error.InvalidLimit => "invalid --limit",
        error.UnknownFlag => "unknown flag",
        error.MissingPath => if (std.mem.eql(u8, command, "object") or std.mem.eql(u8, command, "chunk") or std.mem.eql(u8, command, "vector-collection") or std.mem.eql(u8, command, "graph"))
            "command requires <file.zova> <id>"
        else
            "command requires <file.zova>",
        error.MissingId => if (std.mem.eql(u8, command, "object"))
            "object requires <file.zova> <object-id>"
        else if (std.mem.eql(u8, command, "chunk"))
            "chunk requires <file.zova> <chunk-id>"
        else if (std.mem.eql(u8, command, "graph"))
            "graph requires <file.zova> <graph>"
        else
            "vector-collection requires <file.zova> <name>",
        error.ExtraArgs => "too many arguments",
    };
}

pub fn graphCommandUsageMessage(command: []const u8, err: GraphCommandParseError) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.DuplicateLimit => "duplicate --limit",
        error.DuplicateIncoming => "duplicate --incoming",
        error.DuplicateEdgeType => "duplicate --edge-type",
        error.DuplicateMaxDepth => "duplicate --max-depth",
        error.MissingLimitValue => "--limit requires a value",
        error.MissingEdgeTypeValue => "--edge-type requires a value",
        error.MissingMaxDepthValue => "--max-depth requires a value",
        error.InvalidLimit => "invalid --limit",
        error.InvalidMaxDepth => "invalid --max-depth",
        error.UnknownFlag => "unknown flag",
        error.MissingPath => "command requires <file.zova> <graph> <node-id>",
        error.MissingGraph => "command requires <graph>",
        error.MissingNode => if (std.mem.eql(u8, command, "graph-node"))
            "graph-node requires <file.zova> <graph> <node-id>"
        else if (std.mem.eql(u8, command, "graph-neighbors"))
            "graph-neighbors requires <file.zova> <graph> <node-id>"
        else
            "graph-walk requires <file.zova> <graph> <node-id>",
        error.ExtraArgs => "too many arguments",
    };
}

pub fn salvageCommandUsageMessage(err: SalvageCommandParseError) []const u8 {
    return switch (err) {
        error.DuplicateJson => "duplicate --json",
        error.DuplicateDryRun => "duplicate --dry-run",
        error.DuplicateLimit => "duplicate --limit",
        error.MissingLimitValue => "--limit requires a value",
        error.InvalidLimit => "invalid --limit",
        error.UnknownFlag => "unknown flag",
        error.MissingSource => "salvage requires <source.zova>",
        error.MissingDestination => "salvage execution requires <destination.zova>",
        error.DestinationNotAllowed => "salvage --dry-run does not accept a destination",
        error.ExtraArgs => "too many arguments",
    };
}

pub fn boundedCommandErrorFormat(args: []const []const u8) OutputFormat {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return .json;
    }
    return .text;
}

pub fn graphCommandErrorFormat(args: []const []const u8) OutputFormat {
    return boundedCommandErrorFormat(args);
}

pub fn parseHex32(value: []const u8) ![32]u8 {
    if (value.len != 64) return error.InvalidHex;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*byte, index| {
        const high = hexNibble(value[index * 2]) orelse return error.InvalidHex;
        const low = hexNibble(value[index * 2 + 1]) orelse return error.InvalidHex;
        byte.* = (high << 4) | low;
    }
    return out;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}
