//! Salvage planning, recovery execution, and report rendering.

const std = @import("std");
const zova = @import("zova");

const CommandContext = @import("types.zig").CommandContext;
const DatabaseSummary = @import("types.zig").DatabaseSummary;
const DiagnosticReport = @import("types.zig").DiagnosticReport;
const ExitCode = @import("common.zig").ExitCode;
const OutputFormat = @import("types.zig").OutputFormat;
const SalvageCounts = @import("types.zig").SalvageCounts;
const SalvageExecutionResult = @import("types.zig").SalvageExecutionResult;
const SalvagePlan = @import("types.zig").SalvagePlan;
const SalvageRecoverability = @import("types.zig").SalvageRecoverability;
const UserSqlCopyResult = @import("types.zig").UserSqlCopyResult;
const UserSqlRowCopyResult = @import("types.zig").UserSqlRowCopyResult;
const boundedCommandErrorFormat = @import("parse.zig").boundedCommandErrorFormat;
const buildInsertAllSql = @import("common.zig").buildInsertAllSql;
const cli_json_version = @import("common.zig").cli_json_version;
const diagnosticErrorReport = @import("diagnostics.zig").diagnosticErrorReport;
const diagnosticIssueAreaText = @import("render.zig").diagnosticIssueAreaText;
const emptyDatabaseSummary = @import("inspect.zig").emptyDatabaseSummary;
const expectDone = @import("common.zig").expectDone;
const graphTargetTypeFromText = @import("common.zig").graphTargetTypeFromText;
const isExtensionHealthError = @import("common.zig").isExtensionHealthError;
const isValidGraphAsciiName = @import("diagnostics.zig").isValidGraphAsciiName;
const isValidGraphNodeId = @import("diagnostics.zig").isValidGraphNodeId;
const isValidGraphOptionalText = @import("diagnostics.zig").isValidGraphOptionalText;
const isZovaPath = @import("common.zig").isZovaPath;
const loadDatabaseSummary = @import("inspect.zig").loadDatabaseSummary;
const openDatabaseWithOptions = @import("common.zig").openDatabaseWithOptions;
const openErrorFormat = @import("render.zig").openErrorFormat;
const parseHex32 = @import("parse.zig").parseHex32;
const parseSalvageCommandArgs = @import("parse.zig").parseSalvageCommandArgs;
const quickCheck = @import("common.zig").quickCheck;
const quoteSqlIdentifierAlloc = @import("common.zig").quoteSqlIdentifierAlloc;
const runDiagnostics = @import("diagnostics.zig").runDiagnostics;
const salvageCommandUsageMessage = @import("parse.zig").salvageCommandUsageMessage;
const scalarU64 = @import("common.zig").scalarU64;
const usageErrorFormat = @import("render.zig").usageErrorFormat;
const writeDiagnosticIssueCountsJson = @import("render.zig").writeDiagnosticIssueCountsJson;
const writeDiagnosticIssuesJson = @import("render.zig").writeDiagnosticIssuesJson;
const writeDiagnosticSeverityCountsJson = @import("render.zig").writeDiagnosticSeverityCountsJson;
const writeJsonString = @import("render.zig").writeJsonString;

pub fn salvageCommand(
    ctx: CommandContext,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = parseSalvageCommandArgs(args) catch |err| {
        const format = boundedCommandErrorFormat(args);
        return usageErrorFormat(stderr, "salvage", format, salvageCommandUsageMessage(err));
    };
    if (!parsed.dry_run and !isZovaPath(parsed.destination_path.?)) {
        return usageErrorFormat(stderr, "salvage", parsed.format, "destination path must end in .zova");
    }

    const source = try allocator.dupeZ(u8, parsed.source_path);
    defer allocator.free(source);

    var db = open_salvage_db: {
        const opened = openDatabaseWithOptions(ctx, source, .{ .read_only = true }) catch |err| {
            if (isExtensionHealthError(err)) {
                break :open_salvage_db zova.Database.openForExtensionInspectionWithExtensions(source, .{}, ctx.registry) catch |inspect_err| {
                    return openErrorFormat(stderr, "salvage", parsed.format, inspect_err);
                };
            }
            return openErrorFormat(stderr, "salvage", parsed.format, err);
        };
        break :open_salvage_db opened;
    };
    defer db.deinit();

    if (quickCheck(&db)) |_| {} else |err| {
        const report = try diagnosticErrorReport(allocator, parsed.limit, .sqlite, "sqlite_quick_check", @errorName(err));
        var summary = try emptyDatabaseSummary(allocator);
        defer summary.deinit(allocator);
        var plan = buildSalvagePlan(summary, report);
        defer plan.deinit(allocator);
        return if (parsed.dry_run)
            writeSalvageFailure(stderr, parsed.format, parsed.source_path, plan)
        else
            writeSalvageExecutionFailure(stderr, parsed.format, parsed.source_path, parsed.destination_path.?, plan);
    }

    var summary = loadDatabaseSummary(allocator, &db, source) catch |err| {
        const report = try diagnosticErrorReport(allocator, parsed.limit, .sqlite, "summary", @errorName(err));
        var empty_summary = try emptyDatabaseSummary(allocator);
        defer empty_summary.deinit(allocator);
        var plan = buildSalvagePlan(empty_summary, report);
        defer plan.deinit(allocator);
        return if (parsed.dry_run)
            writeSalvageFailure(stderr, parsed.format, parsed.source_path, plan)
        else
            writeSalvageExecutionFailure(stderr, parsed.format, parsed.source_path, parsed.destination_path.?, plan);
    };
    defer summary.deinit(allocator);

    const report = runDiagnostics(allocator, &db, parsed.limit) catch |err| {
        const diagnostic_report = try diagnosticErrorReport(allocator, parsed.limit, .sqlite, "diagnostic_check", @errorName(err));
        var plan = buildSalvagePlan(summary, diagnostic_report);
        defer plan.deinit(allocator);
        return if (parsed.dry_run)
            writeSalvageFailure(stderr, parsed.format, parsed.source_path, plan)
        else
            writeSalvageExecutionFailure(stderr, parsed.format, parsed.source_path, parsed.destination_path.?, plan);
    };

    var plan = buildSalvagePlan(summary, report);
    plan.recoverable.user_schema_objects = countUserSchemaObjects(&db) catch 0;
    plan.recoverable.user_rows = countUserRows(allocator, &db) catch 0;
    applyExtensionSalvagePlan(allocator, &db, ctx.registry, &plan) catch |err| {
        plan.deinit(allocator);
        return salvageExecutionErrorFormat(stderr, parsed.format, parsed.source_path, parsed.destination_path orelse "", err);
    };

    if (!parsed.dry_run) {
        const destination = try allocator.dupeZ(u8, parsed.destination_path.?);
        defer allocator.free(destination);
        var result = executeSalvage(allocator, &db, destination, plan, ctx.registry) catch |err| {
            plan.deinit(allocator);
            return salvageExecutionErrorFormat(stderr, parsed.format, parsed.source_path, parsed.destination_path.?, err);
        };
        defer result.deinit(allocator);

        if (!result.destination_verified) {
            return writeSalvageExecutionFailure(stderr, parsed.format, parsed.source_path, parsed.destination_path.?, result.plan);
        }

        switch (parsed.format) {
            .text => try writeSalvageExecutionText(stdout, parsed.source_path, parsed.destination_path.?, result),
            .json => try writeSalvageExecutionJson(stdout, parsed.source_path, parsed.destination_path.?, result),
        }
        return ExitCode.ok;
    }

    defer plan.deinit(allocator);

    const has_issues = plan.report.issue_count != 0;
    if (has_issues) {
        switch (parsed.format) {
            .text => try writeSalvageDryRunText(stderr, parsed.source_path, plan),
            .json => try writeSalvageDryRunJson(stderr, parsed.source_path, plan),
        }
        return ExitCode.check_failed;
    }

    switch (parsed.format) {
        .text => try writeSalvageDryRunText(stdout, parsed.source_path, plan),
        .json => try writeSalvageDryRunJson(stdout, parsed.source_path, plan),
    }
    return ExitCode.ok;
}

fn writeSalvageFailure(stderr: *std.Io.Writer, format: OutputFormat, source_path: []const u8, plan: SalvagePlan) !u8 {
    switch (format) {
        .text => try writeSalvageDryRunText(stderr, source_path, plan),
        .json => try writeSalvageDryRunJson(stderr, source_path, plan),
    }
    return ExitCode.check_failed;
}

fn writeSalvageExecutionFailure(
    stderr: *std.Io.Writer,
    format: OutputFormat,
    source_path: []const u8,
    destination_path: []const u8,
    plan: SalvagePlan,
) !u8 {
    const result = SalvageExecutionResult{
        .plan = plan,
        .copied = .{},
        .destination_verified = false,
    };
    switch (format) {
        .text => try writeSalvageExecutionText(stderr, source_path, destination_path, result),
        .json => try writeSalvageExecutionJson(stderr, source_path, destination_path, result),
    }
    return ExitCode.check_failed;
}

fn salvageExecutionErrorFormat(
    stderr: *std.Io.Writer,
    format: OutputFormat,
    source_path: []const u8,
    destination_path: []const u8,
    err: anyerror,
) !u8 {
    switch (format) {
        .text => try stderr.print("salvage failed: {s}\nsource: {s}\ndestination: {s}\n", .{ @errorName(err), source_path, destination_path }),
        .json => {
            try stderr.writeAll("{\n");
            try stderr.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
            try stderr.writeAll("  \"status\": \"error\",\n");
            try stderr.writeAll("  \"command\": \"salvage\",\n");
            try stderr.writeAll("  \"source_path\": ");
            try writeJsonString(stderr, source_path);
            try stderr.writeAll(",\n  \"destination_path\": ");
            try writeJsonString(stderr, destination_path);
            try stderr.writeAll(",\n  \"error\": ");
            try writeJsonString(stderr, @errorName(err));
            try stderr.writeAll(",\n  \"destination_verified\": false\n");
            try stderr.writeAll("}\n");
        },
    }
    return ExitCode.check_failed;
}

fn writeSalvageDryRunText(writer: *std.Io.Writer, source_path: []const u8, plan: SalvagePlan) !void {
    const has_issues = plan.report.issue_count != 0;
    try writer.print(
        \\Zova salvage dry-run: {s}
        \\status: {s}
        \\dry_run: true
        \\will_write_destination: false
        \\recoverability: {s}
        \\recoverable_user_tables: {d}
        \\recoverable_user_schema_objects: {d}
        \\recoverable_user_rows: {d}
        \\recoverable_extensions: {d}
        \\recoverable_extension_private_objects: {d}
        \\recoverable_objects: {d}
        \\recoverable_chunks: {d}
        \\recoverable_loose_chunks: {d}
        \\recoverable_vector_collections: {d}
        \\recoverable_vectors: {d}
        \\skipped_user_tables: {d}
        \\skipped_user_schema_objects: {d}
        \\skipped_user_rows: {d}
        \\skipped_extensions: {d}
        \\skipped_extension_private_objects: {d}
        \\skipped_objects: {d}
        \\skipped_chunks: {d}
        \\skipped_loose_chunks: {d}
        \\skipped_vector_collections: {d}
        \\skipped_vectors: {d}
        \\issue_count: {d}
        \\sqlite_issues: {d}
        \\bound_store_issues: {d}
        \\extension_issues: {d}
        \\object_issues: {d}
        \\chunk_issues: {d}
        \\vector_issues: {d}
        \\error_issues: {d}
        \\issues_truncated: {}
        \\
    , .{
        source_path,
        if (has_issues) "needs_attention" else "ok",
        salvageRecoverabilityText(plan.recoverability),
        plan.recoverable.user_tables,
        plan.recoverable.user_schema_objects,
        plan.recoverable.user_rows,
        plan.recoverable.extensions,
        plan.recoverable.extension_private_objects,
        plan.recoverable.objects,
        plan.recoverable.chunks,
        plan.recoverable.loose_chunks,
        plan.recoverable.vector_collections,
        plan.recoverable.vectors,
        plan.skipped.user_tables,
        plan.skipped.user_schema_objects,
        plan.skipped.user_rows,
        plan.skipped.extensions,
        plan.skipped.extension_private_objects,
        plan.skipped.objects,
        plan.skipped.chunks,
        plan.skipped.loose_chunks,
        plan.skipped.vector_collections,
        plan.skipped.vectors,
        plan.report.issue_count,
        plan.report.issue_counts.sqlite,
        plan.report.issue_counts.bound_store,
        plan.report.issue_counts.extension,
        plan.report.issue_counts.object,
        plan.report.issue_counts.chunk,
        plan.report.issue_counts.vector,
        plan.report.severity_counts.errors,
        plan.report.issues_truncated,
    });

    try writer.writeAll("issues:\n");
    if (plan.report.issues.len == 0) {
        if (plan.report.issue_count == 0) {
            try writer.writeAll("  none\n");
        } else {
            try writer.writeAll("  no issue examples shown\n");
        }
    } else {
        for (plan.report.issues) |issue| {
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
            try writer.writeByte('\n');
        }
    }

    try writer.writeAll("suggested_actions:\n");
    try writeSalvageSuggestedActionsText(writer, source_path, has_issues);
}

fn writeSalvageDryRunJson(writer: *std.Io.Writer, source_path: []const u8, plan: SalvagePlan) !void {
    const has_issues = plan.report.issue_count != 0;
    try writer.writeAll("{\n");
    try writer.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try writer.print("  \"status\": \"{s}\",\n", .{if (has_issues) "needs_attention" else "ok"});
    try writer.writeAll("  \"command\": \"salvage\",\n");
    try writer.writeAll("  \"dry_run\": true,\n");
    try writer.writeAll("  \"will_write_destination\": false,\n");
    try writer.writeAll("  \"source_path\": ");
    try writeJsonString(writer, source_path);
    try writer.writeAll(",\n  \"recoverability\": ");
    try writeJsonString(writer, salvageRecoverabilityText(plan.recoverability));
    try writer.writeAll(",\n  \"recoverable\": ");
    try writeSalvageCountsJson(writer, plan.recoverable);
    try writer.writeAll(",\n  \"skipped\": ");
    try writeSalvageCountsJson(writer, plan.skipped);
    try writer.print(",\n  \"issue_count\": {d},\n", .{plan.report.issue_count});
    try writer.writeAll("  \"issue_counts\": ");
    try writeDiagnosticIssueCountsJson(writer, plan.report.issue_counts);
    try writer.writeAll(",\n  \"severity_counts\": ");
    try writeDiagnosticSeverityCountsJson(writer, plan.report.severity_counts);
    try writer.print(",\n  \"issues_truncated\": {},\n", .{plan.report.issues_truncated});
    try writer.writeAll("  \"issues\": ");
    try writeDiagnosticIssuesJson(writer, plan.report.issues);
    try writer.writeAll(",\n  \"suggested_actions\": ");
    try writeSalvageSuggestedActionsJson(writer, has_issues);
    try writer.writeAll("\n}\n");
}

fn writeSalvageExecutionText(
    writer: *std.Io.Writer,
    source_path: []const u8,
    destination_path: []const u8,
    result: SalvageExecutionResult,
) !void {
    try writer.print(
        \\Zova salvage: {s}
        \\status: {s}
        \\dry_run: false
        \\will_write_destination: true
        \\destination: {s}
        \\destination_verified: {}
        \\recoverability: {s}
        \\copied_user_tables: {d}
        \\copied_user_schema_objects: {d}
        \\copied_user_rows: {d}
        \\copied_extensions: {d}
        \\copied_extension_private_objects: {d}
        \\copied_objects: {d}
        \\copied_chunks: {d}
        \\copied_loose_chunks: {d}
        \\copied_vector_collections: {d}
        \\copied_vectors: {d}
        \\skipped_user_tables: {d}
        \\skipped_user_schema_objects: {d}
        \\skipped_user_rows: {d}
        \\skipped_extensions: {d}
        \\skipped_extension_private_objects: {d}
        \\skipped_objects: {d}
        \\skipped_chunks: {d}
        \\skipped_loose_chunks: {d}
        \\skipped_vector_collections: {d}
        \\skipped_vectors: {d}
        \\issue_count: {d}
        \\issues_truncated: {}
        \\
    , .{
        source_path,
        if (result.destination_verified) "ok" else "error",
        destination_path,
        result.destination_verified,
        salvageRecoverabilityText(result.plan.recoverability),
        result.copied.user_tables,
        result.copied.user_schema_objects,
        result.copied.user_rows,
        result.copied.extensions,
        result.copied.extension_private_objects,
        result.copied.objects,
        result.copied.chunks,
        result.copied.loose_chunks,
        result.copied.vector_collections,
        result.copied.vectors,
        result.plan.skipped.user_tables,
        result.plan.skipped.user_schema_objects,
        result.plan.skipped.user_rows,
        result.plan.skipped.extensions,
        result.plan.skipped.extension_private_objects,
        result.plan.skipped.objects,
        result.plan.skipped.chunks,
        result.plan.skipped.loose_chunks,
        result.plan.skipped.vector_collections,
        result.plan.skipped.vectors,
        result.plan.report.issue_count,
        result.plan.report.issues_truncated,
    });

    try writer.writeAll("issues:\n");
    if (result.plan.report.issues.len == 0) {
        if (result.plan.report.issue_count == 0) {
            try writer.writeAll("  none\n");
        } else {
            try writer.writeAll("  no issue examples shown\n");
        }
    } else {
        for (result.plan.report.issues) |issue| {
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
            try writer.writeByte('\n');
        }
    }

    try writer.writeAll("suggested_actions:\n");
    if (result.destination_verified) {
        try writer.writeAll("  run zova check --deep on the destination before replacing any live file\n");
    } else {
        try writer.writeAll("  restore from a recent backup if available\n");
        try writer.writeAll("  inspect the source with zova doctor before trying salvage again\n");
    }
}

fn writeSalvageExecutionJson(
    writer: *std.Io.Writer,
    source_path: []const u8,
    destination_path: []const u8,
    result: SalvageExecutionResult,
) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"cli_json_version\": {d},\n", .{cli_json_version});
    try writer.print("  \"status\": \"{s}\",\n", .{if (result.destination_verified) "ok" else "error"});
    try writer.writeAll("  \"command\": \"salvage\",\n");
    try writer.writeAll("  \"dry_run\": false,\n");
    try writer.writeAll("  \"will_write_destination\": true,\n");
    try writer.writeAll("  \"source_path\": ");
    try writeJsonString(writer, source_path);
    try writer.writeAll(",\n  \"destination_path\": ");
    try writeJsonString(writer, destination_path);
    try writer.print(",\n  \"destination_verified\": {},\n", .{result.destination_verified});
    try writer.writeAll("  \"recoverability\": ");
    try writeJsonString(writer, salvageRecoverabilityText(result.plan.recoverability));
    try writer.writeAll(",\n  \"copied\": ");
    try writeSalvageCountsJson(writer, result.copied);
    try writer.writeAll(",\n  \"recoverable\": ");
    try writeSalvageCountsJson(writer, result.plan.recoverable);
    try writer.writeAll(",\n  \"skipped\": ");
    try writeSalvageCountsJson(writer, result.plan.skipped);
    try writer.print(",\n  \"issue_count\": {d},\n", .{result.plan.report.issue_count});
    try writer.writeAll("  \"issue_counts\": ");
    try writeDiagnosticIssueCountsJson(writer, result.plan.report.issue_counts);
    try writer.writeAll(",\n  \"severity_counts\": ");
    try writeDiagnosticSeverityCountsJson(writer, result.plan.report.severity_counts);
    try writer.print(",\n  \"issues_truncated\": {},\n", .{result.plan.report.issues_truncated});
    try writer.writeAll("  \"issues\": ");
    try writeDiagnosticIssuesJson(writer, result.plan.report.issues);
    try writer.writeAll(",\n  \"suggested_actions\": ");
    if (result.destination_verified) {
        try writer.writeAll("[");
        try writeJsonString(writer, "run zova check --deep on the destination before replacing any live file");
        try writer.writeAll("]");
    } else {
        try writer.writeAll("[");
        try writeJsonString(writer, "restore from a recent backup if available");
        try writer.writeAll(", ");
        try writeJsonString(writer, "inspect the source with zova doctor before trying salvage again");
        try writer.writeAll("]");
    }
    try writer.writeAll("\n}\n");
}

fn writeSalvageCountsJson(writer: *std.Io.Writer, counts: SalvageCounts) !void {
    try writer.print(
        \\{{
        \\    "user_tables": {d},
        \\    "user_schema_objects": {d},
        \\    "user_rows": {d},
        \\    "extensions": {d},
        \\    "extension_private_objects": {d},
        \\    "graphs": {d},
        \\    "graph_nodes": {d},
        \\    "graph_edges": {d},
        \\    "objects": {d},
        \\    "chunks": {d},
        \\    "loose_chunks": {d},
        \\    "vector_collections": {d},
        \\    "vectors": {d}
        \\  }}
    , .{
        counts.user_tables,
        counts.user_schema_objects,
        counts.user_rows,
        counts.extensions,
        counts.extension_private_objects,
        counts.graphs,
        counts.graph_nodes,
        counts.graph_edges,
        counts.objects,
        counts.chunks,
        counts.loose_chunks,
        counts.vector_collections,
        counts.vectors,
    });
}

fn writeSalvageSuggestedActionsText(writer: *std.Io.Writer, source_path: []const u8, has_issues: bool) !void {
    if (!has_issues) {
        try writer.writeAll("  source appears recoverable\n");
        try writer.writeAll("  no destination was written\n");
        try writer.print("  run: zova salvage {s} <destination.zova>\n", .{source_path});
        return;
    }
    try writer.writeAll("  restore from a recent backup if available\n");
    try writer.print("  review this dry-run report before salvaging {s}\n", .{source_path});
    try writer.print("  run: zova salvage {s} <destination.zova>\n", .{source_path});
}

fn writeSalvageSuggestedActionsJson(writer: *std.Io.Writer, has_issues: bool) !void {
    if (!has_issues) {
        try writer.writeAll("[");
        try writeJsonString(writer, "source appears recoverable");
        try writer.writeAll(", ");
        try writeJsonString(writer, "no destination was written");
        try writer.writeAll(", ");
        try writeJsonString(writer, "run zova salvage <source.zova> <destination.zova> to create a recovery copy");
        try writer.writeAll("]");
        return;
    }
    try writer.writeAll("[");
    try writeJsonString(writer, "restore from a recent backup if available");
    try writer.writeAll(", ");
    try writeJsonString(writer, "review this dry-run report before salvaging");
    try writer.writeAll(", ");
    try writeJsonString(writer, "run zova salvage <source.zova> <destination.zova> to copy recoverable data into a new file");
    try writer.writeAll("]");
}

fn salvageRecoverabilityText(value: SalvageRecoverability) []const u8 {
    return switch (value) {
        .recoverable => "recoverable",
        .partially_recoverable => "partially_recoverable",
        .not_recoverable => "not_recoverable",
        .unknown => "unknown",
    };
}

fn buildSalvagePlan(summary: DatabaseSummary, report: DiagnosticReport) SalvagePlan {
    var recoverable = SalvageCounts{
        .user_tables = summary.user_table_count,
        .objects = summary.object_count,
        .chunks = summary.chunk_count,
        .loose_chunks = summary.loose_chunk_count,
        .vector_collections = summary.vector_collection_count,
        .vectors = summary.vector_count,
        .graphs = report.stats.graphs,
        .graph_nodes = report.stats.graph_nodes,
        .graph_edges = report.stats.graph_edges,
    };
    const skipped = SalvageCounts{
        .objects = @min(summary.object_count, report.issue_counts.object),
        .chunks = report.issue_counts.chunk,
        .vectors = @min(summary.vector_count, report.issue_counts.vector),
        .graph_edges = @min(report.stats.graph_edges, report.issue_counts.graph),
    };

    recoverable.objects = subtractClamped(recoverable.objects, skipped.objects);
    recoverable.chunks = subtractClamped(recoverable.chunks, skipped.chunks);
    recoverable.vectors = subtractClamped(recoverable.vectors, skipped.vectors);
    recoverable.graph_edges = subtractClamped(recoverable.graph_edges, skipped.graph_edges);

    const recoverability: SalvageRecoverability = if (report.issue_counts.sqlite != 0)
        .unknown
    else if (report.issue_count == 0)
        .recoverable
    else if (hasRecoverableData(recoverable))
        .partially_recoverable
    else
        .not_recoverable;

    return .{
        .report = report,
        .recoverability = recoverability,
        .recoverable = recoverable,
        .skipped = skipped,
    };
}

fn executeSalvage(
    allocator: std.mem.Allocator,
    source: *zova.Database,
    destination_path: [:0]const u8,
    plan: SalvagePlan,
    registry: zova.ExtensionRegistry,
) !SalvageExecutionResult {
    if (plan.report.issue_counts.sqlite != 0) return error.Corrupt;

    var destination = try zova.Database.createWithExtensions(destination_path, registry);
    defer destination.deinit();

    var result_plan = plan;
    var copied = SalvageCounts{};
    const user_sql = try copyUserSql(allocator, source, &destination);
    copied.user_tables = user_sql.copied_tables;
    copied.user_schema_objects = user_sql.copied_schema_objects;
    copied.user_rows = user_sql.copied_rows;
    result_plan.skipped.user_tables += user_sql.skipped_tables;
    result_plan.skipped.user_schema_objects += user_sql.skipped_schema_objects;
    result_plan.skipped.user_rows += user_sql.skipped_rows;
    result_plan.recoverable.user_tables = copied.user_tables;
    result_plan.recoverable.user_schema_objects = copied.user_schema_objects;
    result_plan.recoverable.user_rows = copied.user_rows;
    copied.objects = try copyValidObjects(allocator, source, &destination);
    copied.loose_chunks = try copyValidLooseChunks(allocator, source, &destination);
    try copyValidVectors(allocator, source, &destination, &copied);
    try copyValidGraphs(allocator, source, &destination, &copied);
    const extension_result = try zova.salvageInstalledExtensions(allocator, &source.sqlite_db, &destination.sqlite_db, registry, .copy);
    copied.extensions += extension_result.copied_extensions;
    copied.extension_private_objects += extension_result.copied_private_objects;
    result_plan.skipped.extensions = extension_result.skipped_extensions;
    result_plan.skipped.extension_private_objects = extension_result.skipped_private_objects;
    result_plan.recoverable.extensions = copied.extensions;
    result_plan.recoverable.extension_private_objects = copied.extension_private_objects;
    refreshSalvageRecoverability(&result_plan);
    copied.chunks = try scalarU64(&destination, "select count(*) from _zova_chunks");

    const destination_verified = try verifySalvageDestination(allocator, &destination);
    return .{
        .plan = result_plan,
        .copied = copied,
        .destination_verified = destination_verified,
    };
}

fn applyExtensionSalvagePlan(
    allocator: std.mem.Allocator,
    source: *zova.Database,
    registry: zova.ExtensionRegistry,
    plan: *SalvagePlan,
) !void {
    const result = try zova.salvageInstalledExtensions(allocator, &source.sqlite_db, null, registry, .plan);
    plan.recoverable.extensions += result.copied_extensions;
    plan.recoverable.extension_private_objects += result.copied_private_objects;
    plan.skipped.extensions += result.skipped_extensions;
    plan.skipped.extension_private_objects += result.skipped_private_objects;
    refreshSalvageRecoverability(plan);
}

fn copyUserSql(allocator: std.mem.Allocator, source: *zova.Database, destination: *zova.Database) !UserSqlCopyResult {
    var tables = try source.prepare(
        \\select name, sql
        \\from sqlite_master
        \\where type = 'table'
        \\  and sql is not null
        \\  and lower(substr(name, 1, 6)) != '_zova_'
        \\  and lower(substr(name, 1, 7)) != 'sqlite_'
        \\order by name asc
    );
    defer tables.deinit();

    var result = UserSqlCopyResult{};
    while ((try tables.step()) == .row) {
        const table_name = try allocator.dupe(u8, tables.columnText(0));
        defer allocator.free(table_name);
        const schema_sql = try allocator.dupeZ(u8, tables.columnText(1));
        defer allocator.free(schema_sql);
        const source_row_count = countRowsInUserTable(allocator, source, table_name) catch 0;

        destination.exec(schema_sql) catch {
            result.skipped_tables += 1;
            result.skipped_rows += source_row_count;
            continue;
        };
        const rows = copyUserTableRows(allocator, source, destination, table_name, source_row_count) catch {
            result.skipped_tables += 1;
            result.skipped_rows += source_row_count;
            continue;
        };
        result.copied_rows += rows.copied_rows;
        result.skipped_rows += rows.skipped_rows;
        if (rows.skipped_rows != 0) result.skipped_tables += 1;
        result.copied_tables += 1;
    }

    const schema_objects = try copyUserSchemaObjects(allocator, source, destination);
    result.copied_schema_objects = schema_objects.copied_schema_objects;
    result.skipped_schema_objects = schema_objects.skipped_schema_objects;
    return result;
}

fn copyUserSchemaObjects(allocator: std.mem.Allocator, source: *zova.Database, destination: *zova.Database) !UserSqlCopyResult {
    var objects = try source.prepare(
        \\select sql
        \\from sqlite_master
        \\where type in ('index', 'view', 'trigger')
        \\  and sql is not null
        \\  and lower(substr(name, 1, 6)) != '_zova_'
        \\  and lower(substr(name, 1, 7)) != 'sqlite_'
        \\  and lower(substr(tbl_name, 1, 6)) != '_zova_'
        \\  and lower(substr(tbl_name, 1, 7)) != 'sqlite_'
        \\order by
        \\  case type when 'index' then 0 when 'view' then 1 else 2 end,
        \\  name asc
    );
    defer objects.deinit();

    var result = UserSqlCopyResult{};
    while ((try objects.step()) == .row) {
        const schema_sql = try allocator.dupeZ(u8, objects.columnText(0));
        defer allocator.free(schema_sql);
        destination.exec(schema_sql) catch {
            result.skipped_schema_objects += 1;
            continue;
        };
        result.copied_schema_objects += 1;
    }
    return result;
}

fn countUserSchemaObjects(db: *zova.Database) !u64 {
    return try scalarU64(db,
        \\select count(*)
        \\from sqlite_master
        \\where type in ('index', 'view', 'trigger')
        \\  and sql is not null
        \\  and lower(substr(name, 1, 6)) != '_zova_'
        \\  and lower(substr(name, 1, 7)) != 'sqlite_'
        \\  and lower(substr(tbl_name, 1, 6)) != '_zova_'
        \\  and lower(substr(tbl_name, 1, 7)) != 'sqlite_'
    );
}

fn countUserRows(allocator: std.mem.Allocator, db: *zova.Database) !u64 {
    var tables = try db.prepare(
        \\select name
        \\from sqlite_master
        \\where type = 'table'
        \\  and sql is not null
        \\  and lower(substr(name, 1, 6)) != '_zova_'
        \\  and lower(substr(name, 1, 7)) != 'sqlite_'
        \\order by name asc
    );
    defer tables.deinit();

    var count: u64 = 0;
    while ((try tables.step()) == .row) {
        const table_name = try allocator.dupe(u8, tables.columnText(0));
        defer allocator.free(table_name);
        count += countRowsInUserTable(allocator, db, table_name) catch 0;
    }
    return count;
}

fn countRowsInUserTable(allocator: std.mem.Allocator, db: *zova.Database, table_name: []const u8) !u64 {
    const quoted_name = try quoteSqlIdentifierAlloc(allocator, table_name);
    defer allocator.free(quoted_name);

    const sql = try std.fmt.allocPrintSentinel(allocator, "select count(*) from {s}", .{quoted_name}, 0);
    defer allocator.free(sql);

    return try scalarU64(db, sql);
}

fn copyUserTableRows(
    allocator: std.mem.Allocator,
    source: *zova.Database,
    destination: *zova.Database,
    table_name: []const u8,
    source_row_count: u64,
) !UserSqlRowCopyResult {
    const quoted_name = try quoteSqlIdentifierAlloc(allocator, table_name);
    defer allocator.free(quoted_name);

    const select_sql = try std.fmt.allocPrintSentinel(allocator, "select * from {s}", .{quoted_name}, 0);
    defer allocator.free(select_sql);

    var read_rows = try source.prepare(select_sql);
    defer read_rows.deinit();

    const column_count = read_rows.columnCount();
    const insert_sql = try buildInsertAllSql(allocator, quoted_name, @intCast(column_count));
    defer allocator.free(insert_sql);

    var insert_row = destination.prepare(insert_sql) catch return .{ .skipped_rows = source_row_count };
    defer insert_row.deinit();

    var result = UserSqlRowCopyResult{};
    while ((try read_rows.step()) == .row) {
        var column_index: c_int = 0;
        var row_failed = false;
        while (column_index < column_count) : (column_index += 1) {
            const bind_index: c_int = column_index + 1;
            const bind_result = switch (read_rows.columnType(column_index)) {
                .integer => insert_row.bindInt64(bind_index, read_rows.columnInt64(column_index)),
                .float => insert_row.bindDouble(bind_index, read_rows.columnDouble(column_index)),
                .text => insert_row.bindText(bind_index, read_rows.columnText(column_index)),
                .blob => insert_row.bindBlob(bind_index, read_rows.columnBlob(column_index)),
                .null => insert_row.bindNull(bind_index),
            };
            bind_result catch {
                row_failed = true;
                break;
            };
        }
        if (!row_failed) {
            expectDone(&insert_row) catch {
                row_failed = true;
            };
        }
        if (row_failed) {
            result.skipped_rows += 1;
        } else {
            result.copied_rows += 1;
        }
        insert_row.reset() catch {};
        insert_row.clearBindings() catch {};
    }
    return result;
}

fn copyValidObjects(allocator: std.mem.Allocator, source: *zova.Database, destination: *zova.Database) !u64 {
    var objects = try source.prepare("select object_id from _zova_objects order by hex(object_id)");
    defer objects.deinit();

    var copied: u64 = 0;
    while ((try objects.step()) == .row) {
        const raw_id = objects.columnBlob(0);
        if (raw_id.len != @sizeOf(zova.ObjectId)) continue;

        var id: zova.ObjectId = undefined;
        @memcpy(&id, raw_id);
        var object = source.getObject(allocator, id) catch continue;

        const copied_id = destination.putObject(object.bytes) catch {
            object.deinit(allocator);
            continue;
        };
        object.deinit(allocator);
        if (std.mem.eql(u8, copied_id[0..], id[0..])) copied += 1;
    }
    return copied;
}

fn copyValidLooseChunks(allocator: std.mem.Allocator, source: *zova.Database, destination: *zova.Database) !u64 {
    var chunks = try source.prepare(
        \\select c.chunk_hash
        \\from _zova_chunks c
        \\where not exists (
        \\  select 1 from _zova_object_chunks oc where oc.chunk_hash = c.chunk_hash
        \\)
        \\order by hex(c.chunk_hash)
    );
    defer chunks.deinit();

    var copied: u64 = 0;
    while ((try chunks.step()) == .row) {
        const raw_hash = chunks.columnBlob(0);
        if (raw_hash.len != @sizeOf(zova.ObjectChunkId)) continue;

        var hash: zova.ObjectChunkId = undefined;
        @memcpy(&hash, raw_hash);
        var chunk = source.getObjectChunk(allocator, hash) catch continue;

        destination.putObjectChunk(hash, chunk.bytes) catch {
            chunk.deinit(allocator);
            continue;
        };
        chunk.deinit(allocator);
        copied += 1;
    }
    return copied;
}

fn copyValidVectors(
    allocator: std.mem.Allocator,
    source: *zova.Database,
    destination: *zova.Database,
    copied: *SalvageCounts,
) !void {
    var collections = try source.listVectorCollections(allocator);
    defer collections.deinit(allocator);

    for (collections.items) |collection| {
        destination.createVectorCollection(collection.name, .{
            .dimensions = collection.dimensions,
            .metric = collection.metric,
            .element_type = collection.element_type,
        }) catch continue;
        copied.vector_collections += 1;

        var vectors = try source.prepare(
            \\select v.vector_id
            \\from _zova_vectors v
            \\join _zova_vector_collections c on c.collection_key = v.collection_key
            \\where c.name = ?
            \\order by v.vector_id asc
        );
        defer vectors.deinit();
        try vectors.bindText(1, collection.name);

        while ((try vectors.step()) == .row) {
            const vector_id = try allocator.dupe(u8, vectors.columnText(0));

            var vector = source.getVector(allocator, collection.name, vector_id) catch {
                allocator.free(vector_id);
                continue;
            };

            destination.putVector(collection.name, vector.id, vector.values.asConst()) catch {
                vector.deinit(allocator);
                allocator.free(vector_id);
                continue;
            };
            vector.deinit(allocator);
            allocator.free(vector_id);
            copied.vectors += 1;
        }
    }
}

fn copyValidGraphs(
    allocator: std.mem.Allocator,
    source: *zova.Database,
    destination: *zova.Database,
    copied: *SalvageCounts,
) !void {
    _ = allocator;

    var graphs = try source.prepare("select name from _zova_graphs order by created_order, name");
    defer graphs.deinit();
    while ((try graphs.step()) == .row) {
        const graph_name = graphs.columnText(0);
        if (!isValidGraphAsciiName(graph_name, 128)) continue;
        destination.createGraph(graph_name) catch continue;
        copied.graphs += 1;
    }

    var nodes = try source.prepare(
        \\select g.name, n.node_id, n.kind, n.target_type, n.target_namespace, n.target_ref
        \\from _zova_graph_nodes n
        \\join _zova_graphs g on g.graph_key = n.graph_key
        \\order by n.created_order, g.name, n.node_id
    );
    defer nodes.deinit();
    while ((try nodes.step()) == .row) {
        const graph_name = nodes.columnText(0);
        const node_id = nodes.columnText(1);
        const kind = nodes.columnText(2);
        const target_type_text = nodes.columnText(3);
        if (!isValidGraphAsciiName(graph_name, 128)) continue;
        if (!isValidGraphNodeId(node_id)) continue;
        if (!isValidGraphAsciiName(kind, 128)) continue;
        const target_type = graphTargetTypeFromText(target_type_text) orelse continue;
        const target_namespace = if (nodes.columnType(4) == .null) null else nodes.columnText(4);
        const target_ref = if (nodes.columnType(5) == .null) null else nodes.columnText(5);
        if (target_namespace) |value| {
            if (!isValidGraphOptionalText(value)) continue;
        }
        if (target_ref) |value| {
            if (!isValidGraphOptionalText(value)) continue;
        }
        if (!graphTargetReferenceAvailable(destination, target_type, target_namespace, target_ref)) continue;
        destination.putGraphNode(.{
            .graph_name = graph_name,
            .node_id = node_id,
            .kind = kind,
            .target_type = target_type,
            .target_namespace = target_namespace,
            .target_ref = target_ref,
        }) catch continue;
        copied.graph_nodes += 1;
    }

    var edges = try source.prepare(
        \\select g.name, from_node.node_id, et.name, to_node.node_id
        \\from _zova_graph_edges e
        \\join _zova_graphs g on g.graph_key = e.graph_key
        \\join _zova_graph_edge_types et on et.graph_key=e.graph_key and et.edge_type_key=e.edge_type_key
        \\join _zova_graph_nodes from_node on from_node.graph_key = e.graph_key and from_node.node_key = e.from_node_key
        \\join _zova_graph_nodes to_node on to_node.graph_key = e.graph_key and to_node.node_key = e.to_node_key
        \\order by e.created_order, g.name, from_node.node_id, et.name, to_node.node_id
    );
    defer edges.deinit();
    while ((try edges.step()) == .row) {
        const graph_name = edges.columnText(0);
        const from_node_id = edges.columnText(1);
        const edge_type = edges.columnText(2);
        const to_node_id = edges.columnText(3);
        if (!isValidGraphAsciiName(graph_name, 128)) continue;
        if (!isValidGraphNodeId(from_node_id)) continue;
        if (!isValidGraphAsciiName(edge_type, 128)) continue;
        if (!isValidGraphNodeId(to_node_id)) continue;
        destination.putGraphEdge(.{
            .graph_name = graph_name,
            .from_node_id = from_node_id,
            .edge_type = edge_type,
            .to_node_id = to_node_id,
        }) catch continue;
        copied.graph_edges += 1;
    }
}

fn graphTargetReferenceAvailable(
    db: *zova.Database,
    target_type: zova.GraphTargetType,
    target_namespace: ?[]const u8,
    target_ref: ?[]const u8,
) bool {
    return switch (target_type) {
        .object => {
            const ref = target_ref orelse return false;
            const id = parseHex32(ref) catch return false;
            return db.hasObject(id) catch false;
        },
        .object_chunk => {
            const ref = target_ref orelse return false;
            const id = parseHex32(ref) catch return false;
            return db.hasObjectChunk(id) catch false;
        },
        .vector => {
            const collection = target_namespace orelse return false;
            const vector_id = target_ref orelse return false;
            return db.hasVector(collection, vector_id) catch false;
        },
        else => true,
    };
}

fn verifySalvageDestination(allocator: std.mem.Allocator, destination: *zova.Database) !bool {
    quickCheck(destination) catch return false;
    var report = runDiagnostics(allocator, destination, 0) catch return false;
    defer report.deinit(allocator);
    return report.issue_count == 0;
}

fn subtractClamped(value: u64, amount: u64) u64 {
    return if (amount >= value) 0 else value - amount;
}

fn refreshSalvageRecoverability(plan: *SalvagePlan) void {
    plan.recoverability = if (plan.report.issue_counts.sqlite != 0)
        .unknown
    else if (plan.report.issue_count == 0 and !hasSkippedData(plan.skipped))
        .recoverable
    else if (hasRecoverableData(plan.recoverable))
        .partially_recoverable
    else
        .not_recoverable;
}

fn hasRecoverableData(counts: SalvageCounts) bool {
    return counts.user_tables != 0 or
        counts.user_schema_objects != 0 or
        counts.user_rows != 0 or
        counts.extensions != 0 or
        counts.extension_private_objects != 0 or
        counts.graphs != 0 or
        counts.graph_nodes != 0 or
        counts.graph_edges != 0 or
        counts.objects != 0 or
        counts.chunks != 0 or
        counts.loose_chunks != 0 or
        counts.vector_collections != 0 or
        counts.vectors != 0;
}

fn hasSkippedData(counts: SalvageCounts) bool {
    return counts.user_tables != 0 or
        counts.user_schema_objects != 0 or
        counts.user_rows != 0 or
        counts.extensions != 0 or
        counts.extension_private_objects != 0 or
        counts.graphs != 0 or
        counts.graph_nodes != 0 or
        counts.graph_edges != 0 or
        counts.objects != 0 or
        counts.chunks != 0 or
        counts.loose_chunks != 0 or
        counts.vector_collections != 0 or
        counts.vectors != 0;
}
