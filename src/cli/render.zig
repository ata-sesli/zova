//! CLI help, error output, and shared JSON/diagnostic rendering.

const std = @import("std");

const DiagnosticIssue = @import("types.zig").DiagnosticIssue;
const DiagnosticIssueArea = @import("types.zig").DiagnosticIssueArea;
const DiagnosticIssueCounts = @import("types.zig").DiagnosticIssueCounts;
const DiagnosticReport = @import("types.zig").DiagnosticReport;
const DiagnosticSeverityCounts = @import("types.zig").DiagnosticSeverityCounts;
const ExitCode = @import("common.zig").ExitCode;
const OutputFormat = @import("types.zig").OutputFormat;
const cli_json_version = @import("common.zig").cli_json_version;
const isExtensionHealthError = @import("common.zig").isExtensionHealthError;

pub fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage:
        \\  zova [--extension <bundle.zovaext> ...] <command>
        \\  zova --version
        \\  zova --help
        \\  zova info <file.zova>
        \\  zova info --json <file.zova>
        \\  zova stats [--json] [--limit <n>] <file.zova>
        \\  zova objects [--json] [--limit <n>] <file.zova>
        \\  zova object [--json] [--limit <n>] <file.zova> <object-id>
        \\  zova chunks [--json] [--limit <n>] <file.zova>
        \\  zova chunk [--json] [--limit <n>] <file.zova> <chunk-id>
        \\  zova vectors [--json] [--limit <n>] <file.zova>
        \\  zova vector-collection [--json] [--limit <n>] <file.zova> <name>
        \\  zova graphs [--json] [--limit <n>] <file.zova>
        \\  zova graph [--json] <file.zova> <graph>
        \\  zova graph-node [--json] <file.zova> <graph> <node-id>
        \\  zova graph-neighbors [--json] [--incoming] [--edge-type <type>] [--limit <n>] <file.zova> <graph> <node-id>
        \\  zova graph-walk [--json] [--edge-type <type>] [--max-depth <n>] [--limit <n>] <file.zova> <graph> <node-id>
        \\  zova tables [--json] [--limit <n>] <file.zova>
        \\  zova check [--deep] <file.zova>
        \\  zova check --json [--deep] <file.zova>
        \\  zova doctor [--json] [--limit <n>] <file.zova>
        \\  zova salvage --dry-run [--json] [--limit <n>] <source.zova>
        \\  zova salvage [--json] [--limit <n>] <source.zova> <destination.zova>
        \\  zova backup [--json] [--no-verify] <source.zova> <destination.zova>
        \\  zova compact [--json] [--no-verify] <source.zova> <destination.zova>
        \\  zova restore [--json] [--no-verify] <backup.zova> <destination.zova>
        \\  zova split (--objects | --vectors | --graphs) [--json] <main.zova> <store.zova>
        \\  zova object-store create [--json] <objects.zova>
        \\  zova object-store bind [--json] <main.zova> <objects.zova>
        \\  zova object-store info [--json] <main.zova>
        \\  zova object-store unbind [--json] <main.zova>
        \\  zova vector-store create [--json] <vectors.zova>
        \\  zova vector-store bind [--json] <main.zova> <vectors.zova>
        \\  zova vector-store info [--json] <main.zova>
        \\  zova vector-store unbind [--json] <main.zova>
        \\  zova graph-store create [--json] <graphs.zova>
        \\  zova graph-store bind [--json] <main.zova> <graphs.zova>
        \\  zova graph-store info [--json] <main.zova>
        \\  zova graph-store unbind [--json] <main.zova>
        \\  zova format [--json] <database.zova>
        \\  zova migrate [--json] [--no-verify] <source.zova> <destination.zova>
        \\  zova extension list [--json] <file.zova>
        \\  zova extension info [--json] <file.zova> <name>
        \\  zova extension check [--json] <file.zova> [name]
        \\  zova extension drop [--json] <file.zova> <name>
        \\  zova extension install [--json] <file.zova> <name>
        \\  zova extension trust [--json] <bundle.zovaext>
        \\  zova extension untrust [--json] <bundle.zovaext|name>
        \\  zova extension trusted [--json]
        \\  zova extension scaffold [--json] <dir> --name <name> --version <version>
        \\  zova extension build [--json] <dir>
        \\  zova extension pack [--json] <dir> --out <bundle.zovaext>
        \\  zova extension verify [--json] [--smoke] <bundle.zovaext>
        \\
        \\commands:
        \\  format inspect storage format and migration compatibility without mutation
        \\  migrate copy a database forward into the current storage format
        \\  info   print a bounded summary of a current-format Zova database
        \\  stats  print deeper bounded storage statistics
        \\  objects list bounded object metadata
        \\  object  inspect one object manifest without reading object bytes
        \\  chunks  list bounded chunk metadata
        \\  chunk   inspect one chunk reference summary without reading chunk bytes
        \\  vectors list bounded vector collection metadata without vector values
        \\  vector-collection inspect one collection and bounded vector ids
        \\  graphs list bounded graph metadata
        \\  graph inspect one graph summary
        \\  graph-node inspect one graph node without user row/object/vector data
        \\  graph-neighbors list bounded incoming or outgoing neighbors
        \\  graph-walk walk directed graph edges with depth and result bounds
        \\  tables  list bounded user/private table names without schema or rows
        \\  check  validate Zova identity/schema and SQLite quick_check
        \\  doctor explain database health and suggested recovery actions
        \\  salvage plan or copy best-effort recovery without mutating the source
        \\  backup create a verified snapshot copy without overwriting destination
        \\  compact create a verified space-reclaiming copy with VACUUM INTO
        \\  restore restore a backup into a new destination file
        \\  split  move existing single-file object, vector, or graph storage into a new bound store
        \\  object-store manage one optional bound object store
        \\  vector-store manage one optional bound vector store
        \\  graph-store manage one optional bound graph store
        \\  extension inspect, trust, load, and manage process-provided extensions
        \\
        \\exit codes:
        \\  0 healthy/success
        \\  1 unexpected internal error
        \\  2 usage error
        \\  3 open or Zova identity error
        \\  4 integrity or corruption check failure
        \\
    );
}

pub fn usageError(stderr: *std.Io.Writer, message: []const u8) !u8 {
    try stderr.print("usage error: {s}\n\n", .{message});
    try writeUsage(stderr);
    return ExitCode.usage;
}

pub fn usageErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, message: []const u8) !u8 {
    switch (format) {
        .text => return usageError(stderr, message),
        .json => try writeJsonError(stderr, command, message),
    }
    return ExitCode.usage;
}

fn operationalErrorExitCode(err: anyerror) u8 {
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

pub fn operationalErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    const exit_code = operationalErrorExitCode(err);
    const label = if (exit_code == ExitCode.check_failed) "verification failed" else "operation failed";
    switch (format) {
        .text => try stderr.print("{s}: {s}: {s}\n", .{ command, label, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, label, @errorName(err)),
    }
    return exit_code;
}

pub fn openErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    if (isExtensionHealthError(err)) {
        switch (format) {
            .text => try stderr.print("{s}: extension failed: {s}\n", .{ command, @errorName(err) }),
            .json => try writeJsonErrorWithKind(stderr, command, "extension failed", @errorName(err)),
        }
        return ExitCode.check_failed;
    }

    switch (format) {
        .text => try stderr.print("{s} open failed: {s}\n", .{ command, @errorName(err) }),
        .json => try writeJsonError(stderr, command, @errorName(err)),
    }
    return ExitCode.open;
}

pub fn checkErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, message: []const u8, err: anyerror) !u8 {
    switch (format) {
        .text => try stderr.print("{s}: {s}\n", .{ message, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, message, @errorName(err)),
    }
    return ExitCode.check_failed;
}

pub fn doctorCheckErrorFormat(stderr: *std.Io.Writer, format: OutputFormat, source_path: []const u8, message: []const u8, err: anyerror) !u8 {
    switch (format) {
        .text => {
            try stderr.print("Zova doctor: {s}\n", .{source_path});
            try stderr.print("status: needs_attention\nerror: {s}: {s}\n", .{ message, @errorName(err) });
            try stderr.writeAll("suggested_actions:\n");
            try writeSuggestedActionsText(stderr, source_path, true);
        },
        .json => {
            try stderr.writeAll("{\n");
            try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stderr.writeAll("  \"status\": \"needs_attention\",\n");
            try stderr.writeAll("  \"command\": \"doctor\",\n");
            try stderr.writeAll("  \"source_path\": ");
            try writeJsonString(stderr, source_path);
            try stderr.writeAll(",\n  \"error\": ");
            try writeJsonString(stderr, message);
            try stderr.writeAll(",\n  \"kind\": ");
            try writeJsonString(stderr, @errorName(err));
            try stderr.writeAll(",\n  \"suggested_actions\": ");
            try writeSuggestedActionsJson(stderr, source_path, true);
            try stderr.writeAll("\n}\n");
        },
    }
    return ExitCode.check_failed;
}

pub fn deepCheckErrorFormat(stderr: *std.Io.Writer, format: OutputFormat, err: anyerror) !u8 {
    const label = switch (err) {
        error.ObjectCorrupt,
        error.ObjectNotFound,
        error.ObjectChunkNotFound,
        => "object corruption",
        error.VectorCorrupt,
        error.VectorCollectionNotFound,
        error.VectorNotFound,
        => "vector corruption",
        else => "deep check failed",
    };
    switch (format) {
        .text => try stderr.print("{s}: {s}\n", .{ label, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, "check", label, @errorName(err)),
    }
    return ExitCode.check_failed;
}

pub fn inspectErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    const label = switch (err) {
        error.ObjectNotFound,
        error.ObjectChunkNotFound,
        => "not found",
        error.ObjectCorrupt => "object corruption",
        else => "inspection failed",
    };
    switch (format) {
        .text => try stderr.print("{s}: {s}: {s}\n", .{ command, label, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, label, @errorName(err)),
    }
    return ExitCode.check_failed;
}

pub fn vectorInspectErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    const label = switch (err) {
        error.VectorCollectionNotFound => "not found",
        error.VectorCorrupt => "vector corruption",
        else => "inspection failed",
    };
    switch (format) {
        .text => try stderr.print("{s}: {s}: {s}\n", .{ command, label, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, label, @errorName(err)),
    }
    return ExitCode.check_failed;
}

pub fn graphInspectErrorFormat(stderr: *std.Io.Writer, command: []const u8, format: OutputFormat, err: anyerror) !u8 {
    const label = switch (err) {
        error.GraphNotFound,
        error.GraphNodeNotFound,
        error.GraphEdgeNotFound,
        => "not found",
        error.GraphInvalid => "invalid graph input",
        else => "inspection failed",
    };
    switch (format) {
        .text => try stderr.print("{s}: {s}: {s}\n", .{ command, label, @errorName(err) }),
        .json => try writeJsonErrorWithKind(stderr, command, label, @errorName(err)),
    }
    return ExitCode.check_failed;
}

pub fn writeStringArrayJson(stdout: *std.Io.Writer, items: []const []const u8) !void {
    try stdout.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try stdout.writeAll(", ");
        try writeJsonString(stdout, item);
    }
    try stdout.writeAll("]");
}

pub fn writeNullableJsonString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |actual| {
        try writeJsonString(writer, actual);
    } else {
        try writer.writeAll("null");
    }
}

pub fn writeSuggestedActionsText(writer: *std.Io.Writer, source_path: []const u8, has_issues: bool) !void {
    if (!has_issues) {
        try writer.writeAll("  no action needed\n");
        return;
    }
    try writer.writeAll("  restore from a recent backup if available\n");
    try writer.print("  run zova check --deep {s}\n", .{source_path});
    try writer.print("  run zova salvage --dry-run {s}\n", .{source_path});
    try writer.print("  run zova salvage {s} <destination.zova>\n", .{source_path});
}

pub fn writeSuggestedActionsJson(writer: *std.Io.Writer, source_path: []const u8, has_issues: bool) !void {
    try writeSuggestedActionsJsonForIssues(writer, source_path, has_issues, null);
}

pub fn writeSuggestedActionsJsonForIssues(writer: *std.Io.Writer, source_path: []const u8, has_issues: bool, issue_counts: ?DiagnosticIssueCounts) !void {
    _ = source_path;
    if (!has_issues) {
        try writer.writeAll("[\"no action needed\"]");
        return;
    }
    try writer.writeAll("[");
    try writeJsonString(writer, "restore from a recent backup if available");
    try writer.writeAll(", ");
    try writeJsonString(writer, "run zova check --deep <file.zova>");
    try writer.writeAll(", ");
    try writeJsonString(writer, "run zova salvage --dry-run <file.zova>");
    try writer.writeAll(", ");
    try writeJsonString(writer, "run zova salvage <file.zova> <destination.zova>");
    if (issue_counts) |counts| {
        if (counts.extension != 0) {
            try writer.writeAll(", ");
            try writeJsonString(writer, "run zova extension list <file.zova>");
            try writer.writeAll(", ");
            try writeJsonString(writer, "run zova extension check <file.zova>");
            try writer.writeAll(", ");
            try writeJsonString(writer, "pass trusted dynamic bundles with zova --extension <bundle.zovaext> ... when required");
            try writer.writeAll(", ");
            try writeJsonString(writer, "run zova extension trust <bundle.zovaext> before using an untrusted bundle");
        }
    }
    try writer.writeAll("]");
}

pub fn writeExtensionSuggestedActionsText(writer: *std.Io.Writer, source_path: []const u8) !void {
    if (source_path.len != 0) {
        try writer.print("  run zova extension list {s}\n", .{source_path});
        try writer.print("  run zova extension check {s}\n", .{source_path});
    } else {
        try writer.writeAll("  run zova extension list <file.zova>\n");
        try writer.writeAll("  run zova extension check <file.zova>\n");
    }
    try writer.writeAll("  pass trusted dynamic bundles with zova --extension <bundle.zovaext> ... when required\n");
    try writer.writeAll("  run zova extension trust <bundle.zovaext> before using an untrusted bundle\n");
}

pub fn writeDiagnosticIssueCountsJson(writer: *std.Io.Writer, counts: DiagnosticIssueCounts) !void {
    try writer.print(
        \\{{
        \\    "sqlite": {d},
        \\    "bound_store": {d},
        \\    "extension": {d},
        \\    "object": {d},
        \\    "chunk": {d},
        \\    "vector": {d},
        \\    "graph": {d}
        \\  }}
    , .{ counts.sqlite, counts.bound_store, counts.extension, counts.object, counts.chunk, counts.vector, counts.graph });
}

pub fn writeDiagnosticSeverityCountsJson(writer: *std.Io.Writer, counts: DiagnosticSeverityCounts) !void {
    try writer.print(
        \\{{
        \\    "info": {d},
        \\    "warning": {d},
        \\    "error": {d},
        \\    "fatal": {d}
        \\  }}
    , .{ counts.info, counts.warning, counts.errors, counts.fatal });
}

pub fn writeDiagnosticIssuesJson(writer: *std.Io.Writer, issues: []const DiagnosticIssue) !void {
    try writer.writeAll("[");
    for (issues, 0..) |issue, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll("{\"area\": ");
        try writeJsonString(writer, diagnosticIssueAreaText(issue.area));
        try writer.writeAll(", \"kind\": ");
        try writeJsonString(writer, issue.kind);
        try writer.writeAll(", \"severity\": ");
        try writeJsonString(writer, issue.severity);
        try writer.writeAll(", \"detail\": ");
        try writeJsonString(writer, issue.detail);
        if (issue.object_id_hex) |value| {
            try writer.writeAll(", \"object_id\": ");
            try writeJsonString(writer, value);
        }
        if (issue.chunk_hash_hex) |value| {
            try writer.writeAll(", \"chunk_hash\": ");
            try writeJsonString(writer, value);
        }
        if (issue.collection_name) |value| {
            try writer.writeAll(", \"collection\": ");
            try writeJsonString(writer, value);
        }
        if (issue.vector_id) |value| {
            try writer.writeAll(", \"vector_id\": ");
            try writeJsonString(writer, value);
        }
        if (issue.graph_name) |value| {
            try writer.writeAll(", \"graph\": ");
            try writeJsonString(writer, value);
        }
        if (issue.node_id) |value| {
            try writer.writeAll(", \"node_id\": ");
            try writeJsonString(writer, value);
        }
        if (issue.edge_type) |value| {
            try writer.writeAll(", \"edge_type\": ");
            try writeJsonString(writer, value);
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

pub fn diagnosticIssueAreaText(area: DiagnosticIssueArea) []const u8 {
    return switch (area) {
        .sqlite => "sqlite",
        .bound_store => "bound_store",
        .extension => "extension",
        .object => "object",
        .chunk => "chunk",
        .vector => "vector",
        .graph => "graph",
    };
}

pub fn reportHasIssue(report: DiagnosticReport, area: DiagnosticIssueArea, kind: []const u8) bool {
    for (report.issues) |issue| {
        if (issue.area == area and std.mem.eql(u8, issue.kind, kind)) return true;
    }
    return false;
}

fn writeJsonError(stderr: *std.Io.Writer, command: []const u8, err: []const u8) !void {
    try writeJsonErrorWithKind(stderr, command, "error", err);
}

pub fn writeJsonErrorWithKind(stderr: *std.Io.Writer, command: []const u8, kind: []const u8, err: []const u8) !void {
    try stderr.writeAll("{\n");
    try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stderr.writeAll("  \"status\": \"error\",\n");
    try stderr.writeAll("  \"command\": ");
    try writeJsonString(stderr, command);
    try stderr.writeAll(",\n  \"kind\": ");
    try writeJsonString(stderr, kind);
    try stderr.writeAll(",\n  \"error\": ");
    try writeJsonString(stderr, err);
    try stderr.writeAll("\n}\n");
}

pub fn writeJsonErrorWithKindAndActions(stderr: *std.Io.Writer, command: []const u8, kind: []const u8, err: []const u8, issue_counts: DiagnosticIssueCounts) !void {
    try stderr.writeAll("{\n");
    try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stderr.writeAll("  \"status\": \"error\",\n");
    try stderr.writeAll("  \"command\": ");
    try writeJsonString(stderr, command);
    try stderr.writeAll(",\n  \"kind\": ");
    try writeJsonString(stderr, kind);
    try stderr.writeAll(",\n  \"error\": ");
    try writeJsonString(stderr, err);
    try stderr.writeAll(",\n  \"suggested_actions\": ");
    try writeSuggestedActionsJsonForIssues(stderr, "", true, issue_counts);
    try stderr.writeAll("\n}\n");
}

pub fn writeJsonStringFormat(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) !void {
    var buffer: [std.fs.max_path_bytes * 3]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, format, args) catch return error.NoSpaceLeft;
    try writeJsonString(writer, value);
}

pub fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}
