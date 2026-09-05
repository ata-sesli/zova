//! Check and doctor commands with diagnostic report rendering.

const std = @import("std");
const zova = @import("zova");

const CommandContext = @import("types.zig").CommandContext;
const DatabaseSummary = @import("types.zig").DatabaseSummary;
const DiagnosticReport = @import("types.zig").DiagnosticReport;
const ExitCode = @import("common.zig").ExitCode;
const OutputFormat = @import("types.zig").OutputFormat;
const boundedCommandErrorFormat = @import("parse.zig").boundedCommandErrorFormat;
const boundedCommandUsageMessage = @import("parse.zig").boundedCommandUsageMessage;
const checkErrorFormat = @import("render.zig").checkErrorFormat;
const cli_json_version = @import("common.zig").cli_json_version;
const deepCheckErrorFormat = @import("render.zig").deepCheckErrorFormat;
const diagnosticErrorReport = @import("diagnostics.zig").diagnosticErrorReport;
const diagnosticIssueAreaText = @import("render.zig").diagnosticIssueAreaText;
const doctorCheckErrorFormat = @import("render.zig").doctorCheckErrorFormat;
const isExtensionHealthError = @import("common.zig").isExtensionHealthError;
const loadDatabaseSummary = @import("inspect.zig").loadDatabaseSummary;
const openDatabase = @import("common.zig").openDatabase;
const openErrorFormat = @import("render.zig").openErrorFormat;
const openManagementDatabase = @import("common.zig").openManagementDatabase;
const parseBoundedCommandArgs = @import("parse.zig").parseBoundedCommandArgs;
const quickCheck = @import("common.zig").quickCheck;
const reportHasIssue = @import("render.zig").reportHasIssue;
const runDiagnostics = @import("diagnostics.zig").runDiagnostics;
const usageErrorFormat = @import("render.zig").usageErrorFormat;
const writeDiagnosticIssueCountsJson = @import("render.zig").writeDiagnosticIssueCountsJson;
const writeDiagnosticIssuesJson = @import("render.zig").writeDiagnosticIssuesJson;
const writeDiagnosticSeverityCountsJson = @import("render.zig").writeDiagnosticSeverityCountsJson;
const writeExtensionSuggestedActionsText = @import("render.zig").writeExtensionSuggestedActionsText;
const writeJsonString = @import("render.zig").writeJsonString;
const writeSuggestedActionsJson = @import("render.zig").writeSuggestedActionsJson;
const writeSuggestedActionsJsonForIssues = @import("render.zig").writeSuggestedActionsJsonForIssues;
const writeSuggestedActionsText = @import("render.zig").writeSuggestedActionsText;

pub fn checkCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var deep = false;
    var format: OutputFormat = .text;
    var path_arg: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--deep")) {
            if (deep) return usageErrorFormat(stderr, "check", format, "duplicate --deep");
            deep = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            if (format == .json) return usageErrorFormat(stderr, "check", format, "duplicate --json");
            format = .json;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErrorFormat(stderr, "check", format, "unknown flag");
        } else if (path_arg == null) {
            path_arg = arg;
        } else {
            return usageErrorFormat(stderr, "check", format, "check accepts only [--json] [--deep] <file.zova>");
        }
    }

    const raw_path = path_arg orelse return usageErrorFormat(stderr, "check", format, "check requires <file.zova>");
    const path = try allocator.dupeZ(u8, raw_path);
    defer allocator.free(path);

    var db = open_db: {
        const opened = openDatabase(ctx, path) catch |err| {
            if (deep and isExtensionHealthError(err)) {
                break :open_db zova.Database.openForExtensionInspectionWithExtensions(path, .{}, ctx.registry) catch |inspect_err| {
                    return openErrorFormat(stderr, "check", format, inspect_err);
                };
            }
            if (deep) {
                if (try writeBoundStoreOpenFailureCheck(ctx, allocator, stderr, format, path, err)) |exit_code| return exit_code;
            }
            return openErrorFormat(stderr, "check", format, err);
        };
        break :open_db opened;
    };
    defer db.deinit();

    quickCheck(&db) catch |err| return checkErrorFormat(stderr, "check", format, "sqlite quick_check failed", err);

    if (deep) {
        var report = runDiagnostics(allocator, &db, 10) catch |err| return deepCheckErrorFormat(stderr, format, err);
        defer report.deinit(allocator);
        if (report.issue_count != 0) {
            switch (format) {
                .text => try writeDeepCheckFailureText(stderr, report),
                .json => try writeDeepCheckFailureJson(stderr, report),
            }
            return ExitCode.check_failed;
        }

        switch (format) {
            .text => try writeCheckText(stdout, report),
            .json => try writeCheckJson(stdout, report),
        }
        return ExitCode.ok;
    }

    switch (format) {
        .text => try writeCheckText(stdout, null),
        .json => try writeCheckJson(stdout, null),
    }
    return ExitCode.ok;
}

pub fn doctorCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseBoundedCommandArgs(args, false) catch |err| return usageErrorFormat(stderr, "doctor", boundedCommandErrorFormat(args), boundedCommandUsageMessage("doctor", err));
    const path = try allocator.dupeZ(u8, parsed.path);
    defer allocator.free(path);

    var db = open_db: {
        const opened = openDatabase(ctx, path) catch |err| {
            if (isExtensionHealthError(err)) {
                break :open_db zova.Database.openForExtensionInspectionWithExtensions(path, .{}, ctx.registry) catch |inspect_err| {
                    return openErrorFormat(stderr, "doctor", parsed.format, inspect_err);
                };
            }
            if (try writeBoundStoreOpenFailureDoctor(ctx, allocator, stderr, parsed.format, parsed.path, path, err)) |exit_code| return exit_code;
            return openErrorFormat(stderr, "doctor", parsed.format, err);
        };
        break :open_db opened;
    };
    defer db.deinit();

    quickCheck(&db) catch |err| return doctorCheckErrorFormat(stderr, parsed.format, parsed.path, "sqlite quick_check failed", err);

    var summary = loadDatabaseSummary(allocator, &db, path) catch |err| return doctorCheckErrorFormat(stderr, parsed.format, parsed.path, "summary failed", err);
    defer summary.deinit(allocator);

    var report = runDiagnostics(allocator, &db, parsed.limit) catch |err| return doctorCheckErrorFormat(stderr, parsed.format, parsed.path, "diagnostic check failed", err);
    defer report.deinit(allocator);

    if (report.issue_count != 0) {
        switch (parsed.format) {
            .text => try writeDoctorText(stderr, parsed.path, summary, report),
            .json => try writeDoctorJson(stderr, parsed.path, summary, report),
        }
        return ExitCode.check_failed;
    }

    switch (parsed.format) {
        .text => try writeDoctorText(stdout, parsed.path, summary, report),
        .json => try writeDoctorJson(stdout, parsed.path, summary, report),
    }
    return ExitCode.ok;
}

fn writeBoundStoreOpenFailureCheck(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    format: OutputFormat,
    path: [:0]const u8,
    open_err: anyerror,
) !?u8 {
    var db = openManagementDatabase(ctx, path) catch return null;
    defer db.deinit();

    var has_bound_store = false;
    if (try db.boundObjectStore(allocator)) |info_value| {
        var info = info_value;
        info.deinit(allocator);
        has_bound_store = true;
    }
    if (try db.boundVectorStore(allocator)) |info_value| {
        var info = info_value;
        info.deinit(allocator);
        has_bound_store = true;
    }
    if (try db.boundGraphStore(allocator)) |info_value| {
        var info = info_value;
        info.deinit(allocator);
        has_bound_store = true;
    }
    if (!has_bound_store) return null;

    var report = try runDiagnostics(allocator, &db, 10);
    if (report.issue_count == 0) {
        report.deinit(allocator);
        report = try diagnosticErrorReport(allocator, 10, .bound_store, "bound_store_open_failed", @errorName(open_err));
    }
    defer report.deinit(allocator);

    switch (format) {
        .text => {
            try writeDeepCheckFailureText(stderr, report);
            if (reportHasIssue(report, .bound_store, "missing_or_unreadable_store")) {
                try stderr.writeAll("suggested_actions:\n");
                try writeMissingBoundStoreActions(stderr, path, report);
            }
        },
        .json => try writeDeepCheckFailureJson(stderr, report),
    }
    return ExitCode.check_failed;
}

fn writeBoundStoreOpenFailureDoctor(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    format: OutputFormat,
    source_path: []const u8,
    path: [:0]const u8,
    open_err: anyerror,
) !?u8 {
    var db = openManagementDatabase(ctx, path) catch return null;
    defer db.deinit();

    var has_bound_store = false;
    if (try db.boundObjectStore(allocator)) |info_value| {
        var info = info_value;
        info.deinit(allocator);
        has_bound_store = true;
    }
    if (try db.boundVectorStore(allocator)) |info_value| {
        var info = info_value;
        info.deinit(allocator);
        has_bound_store = true;
    }
    if (try db.boundGraphStore(allocator)) |info_value| {
        var info = info_value;
        info.deinit(allocator);
        has_bound_store = true;
    }
    if (!has_bound_store) return null;

    quickCheck(&db) catch |err| return try doctorCheckErrorFormat(stderr, format, source_path, "sqlite quick_check failed", err);

    var summary = loadDatabaseSummary(allocator, &db, path) catch |err| return try doctorCheckErrorFormat(stderr, format, source_path, "summary failed", err);
    defer summary.deinit(allocator);

    var report = try runDiagnostics(allocator, &db, 10);
    if (report.issue_count == 0) {
        report.deinit(allocator);
        report = try diagnosticErrorReport(allocator, 10, .bound_store, "bound_store_open_failed", @errorName(open_err));
    }
    defer report.deinit(allocator);

    switch (format) {
        .text => try writeDoctorText(stderr, source_path, summary, report),
        .json => try writeDoctorJson(stderr, source_path, summary, report),
    }
    return ExitCode.check_failed;
}

fn writeCheckText(stdout: *std.Io.Writer, report: ?DiagnosticReport) !void {
    try stdout.print("quick_check: ok\n", .{});
    if (report) |deep_report| {
        try stdout.print(
            \\deep_check: ok
            \\extensions_checked: {d}
            \\objects_checked: {d}
            \\chunks_checked: {d}
            \\object_logical_bytes: {d}
            \\object_physical_chunk_bytes: {d}
            \\object_referenced_chunk_bytes: {d}
            \\fastcdc_manifest_rows: {d}
            \\fixed_1m_manifest_rows: {d}
            \\fastcdc_chunk_rows: {d}
            \\fixed_1m_chunk_rows: {d}
            \\object_deduplicated_bytes: {d}
            \\object_corruption_issues: {d}
            \\vectors_checked: {d}
            \\loose_chunks: {d}
            \\graphs_checked: {d}
            \\graph_nodes_checked: {d}
            \\graph_edges_checked: {d}
            \\issue_count: {d}
            \\sqlite_issues: {d}
            \\bound_store_issues: {d}
            \\extension_issues: {d}
            \\object_issues: {d}
            \\chunk_issues: {d}
            \\vector_issues: {d}
            \\graph_issues: {d}
            \\error_issues: {d}
            \\
        , .{
            deep_report.stats.extensions,
            deep_report.stats.objects,
            deep_report.stats.chunks,
            deep_report.stats.object_logical_bytes,
            deep_report.stats.object_physical_chunk_bytes,
            deep_report.stats.object_referenced_chunk_bytes,
            deep_report.stats.fastcdc_manifest_rows,
            deep_report.stats.fixed_1m_manifest_rows,
            deep_report.stats.fastcdc_chunk_rows,
            deep_report.stats.fixed_1m_chunk_rows,
            deep_report.stats.object_deduplicated_bytes,
            deep_report.issue_counts.object + deep_report.issue_counts.chunk,
            deep_report.stats.vectors,
            deep_report.stats.loose_chunks,
            deep_report.stats.graphs,
            deep_report.stats.graph_nodes,
            deep_report.stats.graph_edges,
            deep_report.issue_count,
            deep_report.issue_counts.sqlite,
            deep_report.issue_counts.bound_store,
            deep_report.issue_counts.extension,
            deep_report.issue_counts.object,
            deep_report.issue_counts.chunk,
            deep_report.issue_counts.vector,
            deep_report.issue_counts.graph,
            deep_report.severity_counts.errors,
        });
    }
    try stdout.print("status: ok\n", .{});
}

fn writeCheckJson(stdout: *std.Io.Writer, report: ?DiagnosticReport) !void {
    try stdout.writeAll("{\n");
    try stdout.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stdout.writeAll("  \"status\": \"ok\",\n");
    try stdout.writeAll("  \"command\": \"check\",\n");
    try stdout.writeAll("  \"quick_check\": \"ok\"");
    if (report) |deep_report| {
        try stdout.print(
            \\,
            \\  "deep_check": "ok",
            \\  "checked": {{
            \\    "extensions": {d},
            \\    "objects": {d},
            \\    "chunks": {d},
            \\    "vectors": {d},
            \\    "loose_chunks": {d},
            \\    "graphs": {d},
            \\    "graph_nodes": {d},
            \\    "graph_edges": {d}
            \\  }},
            \\  "object_storage": {{
            \\    "logical_bytes": {d},
            \\    "physical_chunk_bytes": {d},
            \\    "referenced_chunk_bytes": {d},
            \\    "fastcdc_manifest_rows": {d},
            \\    "fixed_1m_manifest_rows": {d},
            \\    "fastcdc_chunk_rows": {d},
            \\    "fixed_1m_chunk_rows": {d},
            \\    "deduplicated_bytes": {d},
            \\    "corruption_issues": {d}
            \\  }},
            \\  "issue_count": {d},
            \\  "issue_counts":
        , .{
            deep_report.stats.extensions,
            deep_report.stats.objects,
            deep_report.stats.chunks,
            deep_report.stats.vectors,
            deep_report.stats.loose_chunks,
            deep_report.stats.graphs,
            deep_report.stats.graph_nodes,
            deep_report.stats.graph_edges,
            deep_report.stats.object_logical_bytes,
            deep_report.stats.object_physical_chunk_bytes,
            deep_report.stats.object_referenced_chunk_bytes,
            deep_report.stats.fastcdc_manifest_rows,
            deep_report.stats.fixed_1m_manifest_rows,
            deep_report.stats.fastcdc_chunk_rows,
            deep_report.stats.fixed_1m_chunk_rows,
            deep_report.stats.object_deduplicated_bytes,
            deep_report.issue_counts.object + deep_report.issue_counts.chunk,
            deep_report.issue_count,
        });
        try stdout.writeByte(' ');
        try writeDiagnosticIssueCountsJson(stdout, deep_report.issue_counts);
        try stdout.writeAll(",\n  \"severity_counts\": ");
        try writeDiagnosticSeverityCountsJson(stdout, deep_report.severity_counts);
        try stdout.writeAll(",\n  \"issues_truncated\": false,\n  \"issues\": [],\n  \"suggested_actions\": ");
        try writeSuggestedActionsJson(stdout, "", false);
    }
    try stdout.writeAll("\n}\n");
}

fn writeDeepCheckFailureText(stderr: *std.Io.Writer, report: DiagnosticReport) !void {
    try stderr.print(
        \\deep_check: failed
        \\issue_count: {d}
        \\sqlite_issues: {d}
        \\bound_store_issues: {d}
        \\extension_issues: {d}
        \\object_issues: {d}
        \\chunk_issues: {d}
        \\vector_issues: {d}
        \\graph_issues: {d}
        \\error_issues: {d}
        \\issues_truncated: {}
        \\issues:
        \\
    , .{
        report.issue_count,
        report.issue_counts.sqlite,
        report.issue_counts.bound_store,
        report.issue_counts.extension,
        report.issue_counts.object,
        report.issue_counts.chunk,
        report.issue_counts.vector,
        report.issue_counts.graph,
        report.severity_counts.errors,
        report.issues_truncated,
    });
    if (report.issue_counts.object != 0 or report.issue_counts.chunk != 0) {
        try stderr.writeAll("object corruption: detected\n");
    }
    if (report.issue_counts.vector != 0) {
        try stderr.writeAll("vector corruption: detected\n");
    }
    if (report.issue_counts.graph != 0) {
        try stderr.writeAll("graph corruption: detected\n");
    }
    if (report.issue_counts.extension != 0) {
        try stderr.writeAll("extension issues: detected\n");
    }
    for (report.issues) |issue| {
        try stderr.print("  area={s} kind={s} severity={s} detail={s}", .{
            diagnosticIssueAreaText(issue.area),
            issue.kind,
            issue.severity,
            issue.detail,
        });
        if (issue.object_id_hex) |value| try stderr.print(" object_id={s}", .{value});
        if (issue.chunk_hash_hex) |value| try stderr.print(" chunk_hash={s}", .{value});
        if (issue.collection_name) |value| try stderr.print(" collection={s}", .{value});
        if (issue.vector_id) |value| try stderr.print(" vector_id={s}", .{value});
        if (issue.graph_name) |value| try stderr.print(" graph={s}", .{value});
        if (issue.node_id) |value| try stderr.print(" node_id={s}", .{value});
        if (issue.edge_type) |value| try stderr.print(" edge_type={s}", .{value});
        try stderr.writeByte('\n');
    }
    if (report.issue_counts.extension != 0) {
        try stderr.writeAll("suggested_actions:\n");
        try writeExtensionSuggestedActionsText(stderr, "");
    }
}

fn writeDeepCheckFailureJson(stderr: *std.Io.Writer, report: DiagnosticReport) !void {
    try stderr.writeAll("{\n");
    try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try stderr.writeAll("  \"status\": \"error\",\n");
    try stderr.writeAll("  \"command\": \"check\",\n");
    try stderr.writeAll("  \"kind\": \"deep_check\",\n");
    try stderr.writeAll("  \"error\": \"corruption detected\",\n");
    try stderr.print("  \"issue_count\": {d},\n", .{report.issue_count});
    try stderr.writeAll("  \"issue_counts\": ");
    try writeDiagnosticIssueCountsJson(stderr, report.issue_counts);
    try stderr.writeAll(",\n  \"severity_counts\": ");
    try writeDiagnosticSeverityCountsJson(stderr, report.severity_counts);
    try stderr.print(",\n  \"issues_truncated\": {},\n", .{report.issues_truncated});
    try stderr.writeAll("  \"issues\": ");
    try writeDiagnosticIssuesJson(stderr, report.issues);
    try stderr.writeAll(",\n  \"suggested_actions\": ");
    try writeSuggestedActionsJsonForIssues(stderr, "", true, report.issue_counts);
    try stderr.writeAll("\n}\n");
}

fn writeDoctorText(writer: *std.Io.Writer, source_path: []const u8, summary: DatabaseSummary, report: DiagnosticReport) !void {
    const has_issues = report.issue_count != 0;
    try writer.print(
        \\Zova doctor: {s}
        \\status: {s}
        \\quick_check: ok
        \\schema: ok
        \\extensions_checked: {d}
        \\objects_checked: {d}
        \\chunks_checked: {d}
        \\object_logical_bytes: {d}
        \\object_physical_chunk_bytes: {d}
        \\object_referenced_chunk_bytes: {d}
        \\fastcdc_manifest_rows: {d}
        \\fixed_1m_manifest_rows: {d}
        \\fastcdc_chunk_rows: {d}
        \\fixed_1m_chunk_rows: {d}
        \\object_deduplicated_bytes: {d}
        \\object_corruption_issues: {d}
        \\vectors_checked: {d}
        \\loose_chunks: {d}
        \\graphs_checked: {d}
        \\graph_nodes_checked: {d}
        \\graph_edges_checked: {d}
        \\user_tables: {d}
        \\private_tables: {d}
        \\issue_count: {d}
        \\sqlite_issues: {d}
        \\bound_store_issues: {d}
        \\extension_issues: {d}
        \\object_issues: {d}
        \\chunk_issues: {d}
        \\vector_issues: {d}
        \\graph_issues: {d}
        \\error_issues: {d}
        \\issues_truncated: {}
        \\
    , .{
        source_path,
        if (has_issues) "needs_attention" else "ok",
        report.stats.extensions,
        report.stats.objects,
        report.stats.chunks,
        report.stats.object_logical_bytes,
        report.stats.object_physical_chunk_bytes,
        report.stats.object_referenced_chunk_bytes,
        report.stats.fastcdc_manifest_rows,
        report.stats.fixed_1m_manifest_rows,
        report.stats.fastcdc_chunk_rows,
        report.stats.fixed_1m_chunk_rows,
        report.stats.object_deduplicated_bytes,
        report.issue_counts.object + report.issue_counts.chunk,
        report.stats.vectors,
        report.stats.loose_chunks,
        report.stats.graphs,
        report.stats.graph_nodes,
        report.stats.graph_edges,
        summary.user_table_count,
        summary.private_table_count,
        report.issue_count,
        report.issue_counts.sqlite,
        report.issue_counts.bound_store,
        report.issue_counts.extension,
        report.issue_counts.object,
        report.issue_counts.chunk,
        report.issue_counts.vector,
        report.issue_counts.graph,
        report.severity_counts.errors,
        report.issues_truncated,
    });

    try writer.writeAll("issues:\n");
    if (report.issues.len == 0) {
        if (report.issue_count == 0) {
            try writer.writeAll("  none\n");
        } else {
            try writer.writeAll("  no issue examples shown\n");
        }
    } else {
        for (report.issues) |issue| {
            try writer.print("  area={s} kind={s} severity={s} detail={s}", .{
                diagnosticIssueAreaText(issue.area),
                issue.kind,
                issue.severity,
                issue.detail,
            });
            if (issue.object_id_hex) |value| try writer.print(" object_id={s}", .{value});
            if (issue.chunk_hash_hex) |value| try writer.print(" chunk_hash={s}", .{value});
            if (issue.collection_name) |value| try writer.print(" collection={s}", .{value});
            if (issue.vector_id) |value| try writer.print(" vector_id={s}", .{value});
            if (issue.graph_name) |value| try writer.print(" graph={s}", .{value});
            if (issue.node_id) |value| try writer.print(" node_id={s}", .{value});
            if (issue.edge_type) |value| try writer.print(" edge_type={s}", .{value});
            try writer.writeByte('\n');
        }
    }

    try writer.writeAll("suggested_actions:\n");
    try writeSuggestedActionsText(writer, source_path, has_issues);
    if (reportHasIssue(report, .bound_store, "missing_or_unreadable_store")) {
        try writeMissingBoundStoreActions(writer, source_path, report);
    }
    if (report.issue_counts.extension != 0) {
        try writeExtensionSuggestedActionsText(writer, source_path);
    }
}

fn writeMissingBoundStoreActions(writer: *std.Io.Writer, source_path: []const u8, report: DiagnosticReport) !void {
    if (report.missing_object_store) try writer.print("  run zova object-store bind {s} <objects.zova>\n", .{source_path});
    if (report.missing_vector_store) try writer.print("  run zova vector-store bind {s} <vectors.zova>\n", .{source_path});
    if (report.missing_graph_store) try writer.print("  run zova graph-store bind {s} <graphs.zova>\n", .{source_path});
}

fn writeDoctorJson(writer: *std.Io.Writer, source_path: []const u8, summary: DatabaseSummary, report: DiagnosticReport) !void {
    const has_issues = report.issue_count != 0;
    try writer.writeAll("{\n");
    try writer.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try writer.print("  \"status\": \"{s}\",\n", .{if (has_issues) "needs_attention" else "ok"});
    try writer.writeAll("  \"command\": \"doctor\",\n");
    try writer.writeAll("  \"source_path\": ");
    try writeJsonString(writer, source_path);
    try writer.print(
        \\,
        \\  "quick_check": "ok",
        \\  "schema": "ok",
        \\  "checked": {{
        \\    "extensions": {d},
        \\    "objects": {d},
        \\    "chunks": {d},
        \\    "vectors": {d},
        \\    "loose_chunks": {d},
        \\    "graphs": {d},
        \\    "graph_nodes": {d},
        \\    "graph_edges": {d}
        \\  }},
        \\  "object_storage": {{
        \\    "logical_bytes": {d},
        \\    "physical_chunk_bytes": {d},
        \\    "referenced_chunk_bytes": {d},
        \\    "fastcdc_manifest_rows": {d},
        \\    "fixed_1m_manifest_rows": {d},
        \\    "fastcdc_chunk_rows": {d},
        \\    "fixed_1m_chunk_rows": {d},
        \\    "deduplicated_bytes": {d},
        \\    "corruption_issues": {d}
        \\  }},
        \\  "tables": {{
        \\    "user": {d},
        \\    "private": {d}
        \\  }},
        \\  "issue_count": {d},
        \\  "issue_counts":
    , .{
        report.stats.extensions,
        report.stats.objects,
        report.stats.chunks,
        report.stats.vectors,
        report.stats.loose_chunks,
        report.stats.graphs,
        report.stats.graph_nodes,
        report.stats.graph_edges,
        report.stats.object_logical_bytes,
        report.stats.object_physical_chunk_bytes,
        report.stats.object_referenced_chunk_bytes,
        report.stats.fastcdc_manifest_rows,
        report.stats.fixed_1m_manifest_rows,
        report.stats.fastcdc_chunk_rows,
        report.stats.fixed_1m_chunk_rows,
        report.stats.object_deduplicated_bytes,
        report.issue_counts.object + report.issue_counts.chunk,
        summary.user_table_count,
        summary.private_table_count,
        report.issue_count,
    });
    try writer.writeByte(' ');
    try writeDiagnosticIssueCountsJson(writer, report.issue_counts);
    try writer.writeAll(",\n  \"severity_counts\": ");
    try writeDiagnosticSeverityCountsJson(writer, report.severity_counts);
    try writer.print(",\n  \"issues_truncated\": {},\n", .{report.issues_truncated});
    try writer.writeAll("  \"issues\": ");
    try writeDiagnosticIssuesJson(writer, report.issues);
    try writer.writeAll(",\n  \"suggested_actions\": ");
    try writeSuggestedActionsJsonForIssues(writer, source_path, has_issues, report.issue_counts);
    try writer.writeAll("\n}\n");
}
