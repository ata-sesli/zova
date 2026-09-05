//! Bound-store management and split commands.

const std = @import("std");
const zova = @import("zova");

const CommandContext = @import("types.zig").CommandContext;
const ExitCode = @import("common.zig").ExitCode;
const ObjectStoreAction = @import("types.zig").ObjectStoreAction;
const OutputFormat = @import("types.zig").OutputFormat;
const SplitCommandArgs = @import("types.zig").SplitCommandArgs;
const SplitRole = @import("types.zig").SplitRole;
const argsContain = @import("parse.zig").argsContain;
const cli_json_version = @import("common.zig").cli_json_version;
const graphStoreUsageMessage = @import("parse.zig").graphStoreUsageMessage;
const objectStoreUsageMessage = @import("parse.zig").objectStoreUsageMessage;
const openErrorFormat = @import("render.zig").openErrorFormat;
const openManagementDatabase = @import("common.zig").openManagementDatabase;
const parseObjectStoreCommandArgs = @import("parse.zig").parseObjectStoreCommandArgs;
const parseSplitCommandArgs = @import("parse.zig").parseSplitCommandArgs;
const splitUsageMessage = @import("parse.zig").splitUsageMessage;
const usageErrorFormat = @import("render.zig").usageErrorFormat;
const vectorStoreUsageMessage = @import("parse.zig").vectorStoreUsageMessage;
const writeJsonErrorWithKind = @import("render.zig").writeJsonErrorWithKind;
const writeJsonString = @import("render.zig").writeJsonString;
const writeJsonStringFormat = @import("render.zig").writeJsonStringFormat;

pub fn splitCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseSplitCommandArgs(args) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "split", format, splitUsageMessage(err));
    };

    const main_z = try allocator.dupeZ(u8, parsed.main_path);
    defer allocator.free(main_z);
    const store_z = try allocator.dupeZ(u8, parsed.store_path);
    defer allocator.free(store_z);

    var db = openManagementDatabase(ctx, main_z) catch |err| return openErrorFormat(stderr, "split", parsed.format, err);
    defer db.deinit();

    switch (parsed.role) {
        .objects => {
            const result = db.splitObjectStore(store_z) catch |err| return splitErrorFormat(stderr, parsed.format, err);
            try writeSplitObjectSuccess(stdout, parsed, result);
        },
        .vectors => {
            const result = db.splitVectorStore(store_z) catch |err| return splitErrorFormat(stderr, parsed.format, err);
            try writeSplitVectorSuccess(stdout, parsed, result);
        },
        .graphs => {
            const result = db.splitGraphStore(store_z) catch |err| return splitErrorFormat(stderr, parsed.format, err);
            try writeSplitGraphSuccess(stdout, parsed, result);
        },
    }
    return ExitCode.ok;
}

fn splitErrorFormat(stderr: *std.Io.Writer, format: OutputFormat, err: anyerror) !u8 {
    switch (format) {
        .text => try stderr.print("split: failed: {s}\n", .{@errorName(err)}),
        .json => try writeJsonErrorWithKind(stderr, "split", "operation failed", @errorName(err)),
    }
    return ExitCode.open;
}

pub fn objectStoreCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseObjectStoreCommandArgs(args) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "object-store", format, objectStoreUsageMessage(err));
    };

    const command_name = objectStoreCommandName(parsed.action);
    switch (parsed.action) {
        .create => {
            const store_path = parsed.store_path.?;
            const store_z = try allocator.dupeZ(u8, store_path);
            defer allocator.free(store_z);

            zova.createObjectStore(store_z) catch |err| return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, null, store_path, null, true, true);
            return ExitCode.ok;
        },
        .bind => {
            const main_path = parsed.main_path.?;
            const store_path = parsed.store_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);
            const store_z = try allocator.dupeZ(u8, store_path);
            defer allocator.free(store_z);

            var db = openManagementDatabase(ctx, main_z) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            db.bindObjectStore(store_z) catch |err| {
                if (err == error.BoundStoreExists) return boundStoreMigrationRequiredFormat(stderr, command_name, parsed.format, .objects, main_path, store_path);
                return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            };
            var info = (try db.boundObjectStore(allocator)).?;
            defer info.deinit(allocator);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, info.path, info.store_id, false, true);
            return ExitCode.ok;
        },
        .info => {
            const main_path = parsed.main_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);

            var db = openManagementDatabase(ctx, main_z) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            var maybe_info = try db.boundObjectStore(allocator);
            if (maybe_info) |*info| {
                defer info.deinit(allocator);
                try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, info.path, info.store_id, false, true);
            } else {
                try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, null, null, false, false);
            }
            return ExitCode.ok;
        },
        .unbind => {
            const main_path = parsed.main_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);

            var db = openManagementDatabase(ctx, main_z) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            db.unbindObjectStore() catch |err| return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, null, null, false, false);
            return ExitCode.ok;
        },
    }
}

pub fn vectorStoreCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseObjectStoreCommandArgs(args) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "vector-store", format, vectorStoreUsageMessage(err));
    };

    const command_name = vectorStoreCommandName(parsed.action);
    switch (parsed.action) {
        .create => {
            const store_path = parsed.store_path.?;
            const store_z = try allocator.dupeZ(u8, store_path);
            defer allocator.free(store_z);

            zova.createVectorStore(store_z) catch |err| return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, null, store_path, null, true, true);
            return ExitCode.ok;
        },
        .bind => {
            const main_path = parsed.main_path.?;
            const store_path = parsed.store_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);
            const store_z = try allocator.dupeZ(u8, store_path);
            defer allocator.free(store_z);

            var db = openManagementDatabase(ctx, main_z) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            db.bindVectorStore(store_z) catch |err| {
                if (err == error.BoundStoreExists) return boundStoreMigrationRequiredFormat(stderr, command_name, parsed.format, .vectors, main_path, store_path);
                return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            };
            var info = (try db.boundVectorStore(allocator)).?;
            defer info.deinit(allocator);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, info.path, info.store_id, false, true);
            return ExitCode.ok;
        },
        .info => {
            const main_path = parsed.main_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);

            var db = openManagementDatabase(ctx, main_z) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            var maybe_info = try db.boundVectorStore(allocator);
            if (maybe_info) |*info| {
                defer info.deinit(allocator);
                try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, info.path, info.store_id, false, true);
            } else {
                try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, null, null, false, false);
            }
            return ExitCode.ok;
        },
        .unbind => {
            const main_path = parsed.main_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);

            var db = openManagementDatabase(ctx, main_z) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();

            db.unbindVectorStore() catch |err| return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, null, null, false, false);
            return ExitCode.ok;
        },
    }
}

pub fn graphStoreCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseObjectStoreCommandArgs(args) catch |err| {
        const format: OutputFormat = if (argsContain(args, "--json")) .json else .text;
        return usageErrorFormat(stderr, "graph-store", format, graphStoreUsageMessage(err));
    };

    const command_name = graphStoreCommandName(parsed.action);
    switch (parsed.action) {
        .create => {
            const store_path = parsed.store_path.?;
            const store_z = try allocator.dupeZ(u8, store_path);
            defer allocator.free(store_z);
            zova.createGraphStore(store_z) catch |err| return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, null, store_path, null, true, true);
            return ExitCode.ok;
        },
        .bind => {
            const main_path = parsed.main_path.?;
            const store_path = parsed.store_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);
            const store_z = try allocator.dupeZ(u8, store_path);
            defer allocator.free(store_z);
            var db = openManagementDatabase(ctx, main_z) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();
            db.bindGraphStore(store_z) catch |err| {
                if (err == error.BoundStoreExists) return boundStoreMigrationRequiredFormat(stderr, command_name, parsed.format, .graphs, main_path, store_path);
                return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            };
            var info = (try db.boundGraphStore(allocator)).?;
            defer info.deinit(allocator);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, info.path, info.store_id, false, true);
            return ExitCode.ok;
        },
        .info => {
            const main_path = parsed.main_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);
            var db = openManagementDatabase(ctx, main_z) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();
            var maybe_info = try db.boundGraphStore(allocator);
            if (maybe_info) |*info| {
                defer info.deinit(allocator);
                try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, info.path, info.store_id, false, true);
            } else {
                try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, null, null, false, false);
            }
            return ExitCode.ok;
        },
        .unbind => {
            const main_path = parsed.main_path.?;
            const main_z = try allocator.dupeZ(u8, main_path);
            defer allocator.free(main_z);
            var db = openManagementDatabase(ctx, main_z) catch |err| return openErrorFormat(stderr, command_name, parsed.format, err);
            defer db.deinit();
            db.unbindGraphStore() catch |err| return objectStoreErrorFormat(stderr, command_name, parsed.format, err);
            try writeObjectStoreSuccess(stdout, parsed.format, command_name, main_path, null, null, false, false);
            return ExitCode.ok;
        },
    }
}

fn objectStoreCommandName(action: ObjectStoreAction) []const u8 {
    return switch (action) {
        .create => "object-store-create",
        .bind => "object-store-bind",
        .info => "object-store-info",
        .unbind => "object-store-unbind",
    };
}

fn vectorStoreCommandName(action: ObjectStoreAction) []const u8 {
    return switch (action) {
        .create => "vector-store-create",
        .bind => "vector-store-bind",
        .info => "vector-store-info",
        .unbind => "vector-store-unbind",
    };
}

fn graphStoreCommandName(action: ObjectStoreAction) []const u8 {
    return switch (action) {
        .create => "graph-store-create",
        .bind => "graph-store-bind",
        .info => "graph-store-info",
        .unbind => "graph-store-unbind",
    };
}

fn objectStoreErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    switch (format) {
        .text => try stderr.print("{s}: failed: {s}\n", .{ command, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, "operation failed", @errorName(err)),
    }
    return ExitCode.open;
}

fn boundStoreMigrationRequiredFormat(
    stderr: *std.Io.Writer,
    command: []const u8,
    format: OutputFormat,
    role: SplitRole,
    main_path: []const u8,
    store_path: []const u8,
) !u8 {
    const role_flag = splitRoleFlag(role);
    switch (format) {
        .text => {
            try stderr.print("{s}: failed: BoundStoreExists\n", .{command});
            try stderr.print("main database already contains {s} storage; run zova split {s} {s} {s}\n", .{
                splitRoleStorageName(role),
                role_flag,
                main_path,
                store_path,
            });
        },
        .json => {
            try stderr.writeAll("{\n");
            try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stderr.writeAll("  \"status\": \"error\",\n");
            try stderr.writeAll("  \"command\": ");
            try writeJsonString(stderr, command);
            try stderr.writeAll(",\n  \"kind\": \"split required\",\n");
            try stderr.writeAll("  \"error\": \"BoundStoreExists\",\n");
            try stderr.writeAll("  \"suggested_command\": ");
            try writeJsonStringFormat(stderr, "zova split {s} {s} {s}", .{ role_flag, main_path, store_path });
            try stderr.writeAll("\n}\n");
        },
    }
    return ExitCode.open;
}

fn writeSplitObjectSuccess(stdout: *std.Io.Writer, parsed: SplitCommandArgs, result: zova.SplitObjectStoreResult) !void {
    switch (parsed.format) {
        .text => {
            try stdout.writeAll("split: ok\n");
            try stdout.writeAll("role: objects\n");
            try stdout.print("main_path: {s}\n", .{parsed.main_path});
            try stdout.print("store_path: {s}\n", .{parsed.store_path});
            try stdout.print("copied_objects: {d}\n", .{result.copied.objects});
            try stdout.print("copied_chunks: {d}\n", .{result.copied.chunks});
            try stdout.print("copied_manifest_rows: {d}\n", .{result.copied.manifest_rows});
            try stdout.print("cleared_objects: {d}\n", .{result.cleared.objects});
            try stdout.print("cleared_chunks: {d}\n", .{result.cleared.chunks});
            try stdout.print("cleared_manifest_rows: {d}\n", .{result.cleared.manifest_rows});
            try stdout.print("verified: {}\n", .{result.verified});
        },
        .json => {
            try writeSplitJsonHeader(stdout, parsed, result.store_id, result.bound_set_id, result.verified);
            try stdout.writeAll(",\n  \"copied\": {\n");
            try stdout.print("    \"objects\": {d},\n", .{result.copied.objects});
            try stdout.print("    \"chunks\": {d},\n", .{result.copied.chunks});
            try stdout.print("    \"manifest_rows\": {d}\n", .{result.copied.manifest_rows});
            try stdout.writeAll("  },\n  \"cleared\": {\n");
            try stdout.print("    \"objects\": {d},\n", .{result.cleared.objects});
            try stdout.print("    \"chunks\": {d},\n", .{result.cleared.chunks});
            try stdout.print("    \"manifest_rows\": {d}\n", .{result.cleared.manifest_rows});
            try stdout.writeAll("  }\n}\n");
        },
    }
}

fn writeSplitVectorSuccess(stdout: *std.Io.Writer, parsed: SplitCommandArgs, result: zova.SplitVectorStoreResult) !void {
    switch (parsed.format) {
        .text => {
            try stdout.writeAll("split: ok\n");
            try stdout.writeAll("role: vectors\n");
            try stdout.print("main_path: {s}\n", .{parsed.main_path});
            try stdout.print("store_path: {s}\n", .{parsed.store_path});
            try stdout.print("copied_vector_collections: {d}\n", .{result.copied.vector_collections});
            try stdout.print("copied_vectors: {d}\n", .{result.copied.vectors});
            try stdout.print("cleared_vector_collections: {d}\n", .{result.cleared.vector_collections});
            try stdout.print("cleared_vectors: {d}\n", .{result.cleared.vectors});
            try stdout.print("verified: {}\n", .{result.verified});
        },
        .json => {
            try writeSplitJsonHeader(stdout, parsed, result.store_id, result.bound_set_id, result.verified);
            try stdout.writeAll(",\n  \"copied\": {\n");
            try stdout.print("    \"vector_collections\": {d},\n", .{result.copied.vector_collections});
            try stdout.print("    \"vectors\": {d}\n", .{result.copied.vectors});
            try stdout.writeAll("  },\n  \"cleared\": {\n");
            try stdout.print("    \"vector_collections\": {d},\n", .{result.cleared.vector_collections});
            try stdout.print("    \"vectors\": {d}\n", .{result.cleared.vectors});
            try stdout.writeAll("  }\n}\n");
        },
    }
}

fn writeSplitGraphSuccess(stdout: *std.Io.Writer, parsed: SplitCommandArgs, result: zova.SplitGraphStoreResult) !void {
    switch (parsed.format) {
        .text => {
            try stdout.writeAll("split: ok\n");
            try stdout.writeAll("role: graphs\n");
            try stdout.print("main_path: {s}\n", .{parsed.main_path});
            try stdout.print("store_path: {s}\n", .{parsed.store_path});
            try stdout.print("copied_graphs: {d}\n", .{result.copied.graphs});
            try stdout.print("copied_nodes: {d}\n", .{result.copied.nodes});
            try stdout.print("copied_edges: {d}\n", .{result.copied.edges});
            try stdout.print("cleared_graphs: {d}\n", .{result.cleared.graphs});
            try stdout.print("cleared_nodes: {d}\n", .{result.cleared.nodes});
            try stdout.print("cleared_edges: {d}\n", .{result.cleared.edges});
            try stdout.print("verified: {}\n", .{result.verified});
        },
        .json => {
            try writeSplitJsonHeader(stdout, parsed, result.store_id, result.bound_set_id, result.verified);
            try stdout.writeAll(",\n  \"copied\": {\n");
            try stdout.print("    \"graphs\": {d},\n", .{result.copied.graphs});
            try stdout.print("    \"nodes\": {d},\n", .{result.copied.nodes});
            try stdout.print("    \"edges\": {d}\n", .{result.copied.edges});
            try stdout.writeAll("  },\n  \"cleared\": {\n");
            try stdout.print("    \"graphs\": {d},\n", .{result.cleared.graphs});
            try stdout.print("    \"nodes\": {d},\n", .{result.cleared.nodes});
            try stdout.print("    \"edges\": {d}\n", .{result.cleared.edges});
            try stdout.writeAll("  }\n}\n");
        },
    }
}

fn writeSplitJsonHeader(
    stdout: *std.Io.Writer,
    parsed: SplitCommandArgs,
    store_id: [64]u8,
    bound_set_id: [64]u8,
    verified: bool,
) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"split\",\n");
    try stdout.writeAll("  \"role\": ");
    try writeJsonString(stdout, splitRoleJsonName(parsed.role));
    try stdout.writeAll(",\n  \"main_path\": ");
    try writeJsonString(stdout, parsed.main_path);
    try stdout.writeAll(",\n  \"store_path\": ");
    try writeJsonString(stdout, parsed.store_path);
    try stdout.writeAll(",\n  \"created\": true,\n");
    try stdout.writeAll("  \"bound\": true,\n");
    try stdout.print("  \"verified\": {},\n", .{verified});
    try stdout.writeAll("  \"store_id\": ");
    try writeJsonString(stdout, store_id[0..]);
    try stdout.writeAll(",\n  \"bound_set_id\": ");
    try writeJsonString(stdout, bound_set_id[0..]);
}

fn splitRoleJsonName(role: SplitRole) []const u8 {
    return switch (role) {
        .objects => "objects",
        .vectors => "vectors",
        .graphs => "graphs",
    };
}

fn splitRoleFlag(role: SplitRole) []const u8 {
    return switch (role) {
        .objects => "--objects",
        .vectors => "--vectors",
        .graphs => "--graphs",
    };
}

fn splitRoleStorageName(role: SplitRole) []const u8 {
    return switch (role) {
        .objects => "object",
        .vectors => "vector",
        .graphs => "graph",
    };
}

fn writeObjectStoreSuccess(
    stdout: *std.Io.Writer,
    format: OutputFormat,
    command: []const u8,
    main_path: ?[]const u8,
    store_path: ?[]const u8,
    store_id: ?[]const u8,
    created: bool,
    bound: bool,
) !void {
    switch (format) {
        .text => {
            try stdout.print("{s}: ok\n", .{command});
            if (main_path) |value| try stdout.print("main_path: {s}\n", .{value});
            if (store_path) |value| try stdout.print("path: {s}\n", .{value});
            if (store_id) |value| try stdout.print("store_id: {s}\n", .{value});
            if (created) try stdout.writeAll("created: true\n");
            try stdout.print("bound: {}\n", .{bound});
        },
        .json => {
            try stdout.writeAll("{\n");
            try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stdout.writeAll("  \"status\": \"ok\",\n");
            try stdout.writeAll("  \"command\": ");
            try writeJsonString(stdout, command);
            if (main_path) |value| {
                try stdout.writeAll(",\n  \"main_path\": ");
                try writeJsonString(stdout, value);
            }
            if (store_path) |value| {
                try stdout.writeAll(",\n  \"path\": ");
                try writeJsonString(stdout, value);
            }
            if (store_id) |value| {
                try stdout.writeAll(",\n  \"store_id\": ");
                try writeJsonString(stdout, value);
            }
            try stdout.print(",\n  \"created\": {},\n  \"bound\": {}\n", .{ created, bound });
            try stdout.writeAll("}\n");
        },
    }
}
