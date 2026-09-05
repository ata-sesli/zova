//! Read-only integrity checks used by check, doctor, and salvage.

const std = @import("std");
const zova = @import("zova");
const sqlite = zova.sqlite;

const DiagnosticIssue = @import("types.zig").DiagnosticIssue;
const DiagnosticIssueArea = @import("types.zig").DiagnosticIssueArea;
const DiagnosticReport = @import("types.zig").DiagnosticReport;
const diagnosticGraphSchemaPrefix = @import("common.zig").diagnosticGraphSchemaPrefix;
const diagnosticObjectSchemaPrefix = @import("common.zig").diagnosticObjectSchemaPrefix;
const diagnosticVectorSchemaPrefix = @import("common.zig").diagnosticVectorSchemaPrefix;
const graphTargetTypeFromText = @import("common.zig").graphTargetTypeFromText;
const lowerHexAlloc = @import("common.zig").lowerHexAlloc;
const parseHex32 = @import("parse.zig").parseHex32;
const sqliteMetaValueAlloc = @import("common.zig").sqliteMetaValueAlloc;
const startsWithZovaPrefix = @import("common.zig").startsWithZovaPrefix;

pub fn runDiagnostics(allocator: std.mem.Allocator, db: *zova.Database, issue_limit: usize) !DiagnosticReport {
    var issues: std.ArrayList(DiagnosticIssue) = .empty;
    errdefer {
        for (issues.items) |*issue| issue.deinit(allocator);
        issues.deinit(allocator);
    }

    var report = DiagnosticReport{ .issue_limit = issue_limit };
    try validateBoundStores(allocator, db, &report, &issues);
    try validateExtensions(allocator, db, &report, &issues);
    try collectObjectStorageStats(allocator, db, &report);
    try validateObjects(allocator, db, &report, &issues);
    try validateLooseChunks(allocator, db, &report, &issues);
    try validateVectors(allocator, db, &report, &issues);
    try validateGraphs(allocator, db, &report, &issues);
    report.issues = try issues.toOwnedSlice(allocator);
    return report;
}

fn collectObjectStorageStats(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport) !void {
    const prefix = diagnosticObjectSchemaPrefix(db);
    const sql = try std.fmt.allocPrintSentinel(allocator,
        \\select
        \\  coalesce((select sum(size_bytes) from {s}_zova_objects), 0),
        \\  coalesce((select sum(size_bytes) from {s}_zova_chunks), 0),
        \\  coalesce((select sum(c.size_bytes) from {s}_zova_chunks c
        \\    where exists (select 1 from {s}_zova_object_chunks oc where oc.chunk_hash = c.chunk_hash)), 0),
        \\  coalesce((select count(*) from {s}_zova_object_chunks oc
        \\    join {s}_zova_objects o on o.object_id = oc.object_id where o.chunker = 'fastcdc-v1'), 0),
        \\  coalesce((select count(*) from {s}_zova_object_chunks oc
        \\    join {s}_zova_objects o on o.object_id = oc.object_id where o.chunker = 'fixed-1m-v1'), 0),
        \\  coalesce((select count(distinct oc.chunk_hash) from {s}_zova_object_chunks oc
        \\    join {s}_zova_objects o on o.object_id = oc.object_id where o.chunker = 'fastcdc-v1'), 0),
        \\  coalesce((select count(distinct oc.chunk_hash) from {s}_zova_object_chunks oc
        \\    join {s}_zova_objects o on o.object_id = oc.object_id where o.chunker = 'fixed-1m-v1'), 0)
    , .{ prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix, prefix }, 0);
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.CheckFailed;

    report.stats.object_logical_bytes = @intCast(stmt.columnInt64(0));
    report.stats.object_physical_chunk_bytes = @intCast(stmt.columnInt64(1));
    report.stats.object_referenced_chunk_bytes = @intCast(stmt.columnInt64(2));
    report.stats.fastcdc_manifest_rows = @intCast(stmt.columnInt64(3));
    report.stats.fixed_1m_manifest_rows = @intCast(stmt.columnInt64(4));
    report.stats.fastcdc_chunk_rows = @intCast(stmt.columnInt64(5));
    report.stats.fixed_1m_chunk_rows = @intCast(stmt.columnInt64(6));
    report.stats.object_deduplicated_bytes = report.stats.object_logical_bytes -| report.stats.object_referenced_chunk_bytes;
}

fn validateExtensions(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    var extensions = db.listExtensions(allocator) catch |err| {
        try addDiagnosticIssue(allocator, report, issues, .extension, "extension_registry_unreadable", @errorName(err), null, null, null, null);
        return;
    };
    defer extensions.deinit(allocator);

    report.stats.extensions = extensions.items.len;
    const unknown_storage = db.unknownExtensionStorage(allocator) catch |err| {
        try addDiagnosticIssue(allocator, report, issues, .extension, "extension_storage_unreadable", @errorName(err), null, null, null, null);
        return;
    };
    if (unknown_storage) |name| {
        defer allocator.free(name);
        try addDiagnosticIssue(allocator, report, issues, .extension, "unknown_extension_storage", name, null, null, null, null);
    }
    for (extensions.items) |item| {
        db.registerExtensionSqlForDiagnostics(item.name) catch |err| {
            var detail_buffer: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buffer, "{s}: {s}", .{ item.name, @errorName(err) }) catch @errorName(err);
            try addDiagnosticIssue(allocator, report, issues, .extension, extensionDiagnosticIssueKind(item.name, err), detail, null, null, null, null);
            continue;
        };
        db.checkExtension(item.name) catch |err| {
            var detail_buffer: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buffer, "{s}: {s}", .{ item.name, @errorName(err) }) catch @errorName(err);
            try addDiagnosticIssue(allocator, report, issues, .extension, extensionDiagnosticIssueKind(item.name, err), detail, null, null, null, null);
        };
    }
}

fn extensionDiagnosticIssueKind(name: []const u8, err: anyerror) []const u8 {
    if (err == error.ExtensionUnavailable) return "extension_unavailable";
    if (err == error.ExtensionIncompatible) return "extension_incompatible";
    if (err == error.ExtensionUntrusted) return "extension_untrusted";
    if (err == error.ExtensionLoadFailed) return "extension_load_failed";
    if (std.mem.eql(u8, name, "trgm")) return "trgm_check_failed";
    return "extension_check_failed";
}

fn validateBoundStores(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    if (try db.boundObjectStore(allocator)) |info_value| {
        var info = info_value;
        defer info.deinit(allocator);
        try validateOneBoundStore(
            allocator,
            report,
            issues,
            info.path,
            "object_store",
            info.store_id,
            info.bound_set_id,
            "object_epoch",
            "missing_object_epoch",
            "object_epoch_unreadable",
            "object_epoch_invalid",
            "object_epoch_mismatch",
            info.object_epoch,
        );
    }

    if (try db.boundVectorStore(allocator)) |info_value| {
        var info = info_value;
        defer info.deinit(allocator);
        try validateOneBoundStore(
            allocator,
            report,
            issues,
            info.path,
            "vector_store",
            info.store_id,
            info.bound_set_id,
            "vector_epoch",
            "missing_vector_epoch",
            "vector_epoch_unreadable",
            "vector_epoch_invalid",
            "vector_epoch_mismatch",
            info.vector_epoch,
        );
    }

    if (try db.boundGraphStore(allocator)) |info_value| {
        var info = info_value;
        defer info.deinit(allocator);
        try validateOneBoundStore(
            allocator,
            report,
            issues,
            info.path,
            "graph_store",
            info.store_id,
            info.bound_set_id,
            "graph_epoch",
            "missing_graph_epoch",
            "graph_epoch_unreadable",
            "graph_epoch_invalid",
            "graph_epoch_mismatch",
            info.graph_epoch,
        );
    }
}

fn validateOneBoundStore(
    allocator: std.mem.Allocator,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    path: []const u8,
    expected_role: []const u8,
    expected_store_id: []const u8,
    expected_bound_set_id: []const u8,
    epoch_key: []const u8,
    missing_epoch_kind: []const u8,
    unreadable_epoch_kind: []const u8,
    invalid_epoch_kind: []const u8,
    mismatch_epoch_kind: []const u8,
    expected_epoch: u64,
) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var store = sqlite.Database.openWithFlags(path_z, .read_only) catch |err| {
        if (std.mem.eql(u8, expected_role, "object_store")) report.missing_object_store = true;
        if (std.mem.eql(u8, expected_role, "vector_store")) report.missing_vector_store = true;
        if (std.mem.eql(u8, expected_role, "graph_store")) report.missing_graph_store = true;
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "missing_or_unreadable_store", @errorName(err), null, null, null, null);
        return;
    };
    defer store.deinit();

    const magic = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, "magic", "missing_store_magic", "NotZovaDatabase", "store_magic_unreadable")) orelse return;
    defer allocator.free(magic);
    if (!std.mem.eql(u8, magic, "zova")) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "store_magic_mismatch", "NotZovaDatabase", null, null, null, null);
        return;
    }

    const format_version = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, "format_version", "missing_store_format_version", "UnsupportedZovaVersion", "store_format_version_unreadable")) orelse return;
    defer allocator.free(format_version);
    if (!std.mem.eql(u8, format_version, zova.version.format_version)) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "store_format_version_mismatch", "UnsupportedZovaVersion", null, null, null, null);
        return;
    }

    const role = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, "store_role", "missing_store_role", "BoundStoreInvalid", "store_role_unreadable")) orelse return;
    defer allocator.free(role);
    if (!std.mem.eql(u8, role, expected_role)) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "store_role_mismatch", "BoundStoreInvalid", null, null, null, null);
        return;
    }

    const store_id = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, "store_id", "missing_store_id", "BoundStoreInvalid", "store_id_unreadable")) orelse return;
    defer allocator.free(store_id);
    if (!std.mem.eql(u8, store_id, expected_store_id)) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "store_id_mismatch", "BoundStoreInvalid", null, null, null, null);
        return;
    }

    const bound_set_id = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, "bound_set_id", "missing_bound_set_id", "BoundStoreInvalid", "bound_set_id_unreadable")) orelse return;
    defer allocator.free(bound_set_id);
    if (!std.mem.eql(u8, bound_set_id, expected_bound_set_id)) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, "bound_set_id_mismatch", "BoundStoreInvalid", null, null, null, null);
        return;
    }

    const epoch_text = (try requiredBoundStoreMetaValueAlloc(allocator, &store, report, issues, epoch_key, missing_epoch_kind, "BoundStoreInvalid", unreadable_epoch_kind)) orelse return;
    defer allocator.free(epoch_text);
    const epoch = std.fmt.parseInt(u64, epoch_text, 10) catch {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, invalid_epoch_kind, "BoundStoreInvalid", null, null, null, null);
        return;
    };
    if (epoch != expected_epoch) {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, mismatch_epoch_kind, "BoundStoreInvalid", null, null, null, null);
    }
}

fn requiredBoundStoreMetaValueAlloc(
    allocator: std.mem.Allocator,
    store: *sqlite.Database,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    key: []const u8,
    missing_kind: []const u8,
    missing_detail: []const u8,
    unreadable_kind: []const u8,
) !?[]u8 {
    const value = sqliteMetaValueAlloc(allocator, store, key) catch |err| {
        try addDiagnosticIssue(allocator, report, issues, .bound_store, unreadable_kind, @errorName(err), null, null, null, null);
        return null;
    };
    if (value) |actual| return actual;

    try addDiagnosticIssue(allocator, report, issues, .bound_store, missing_kind, missing_detail, null, null, null, null);
    return null;
}

pub fn diagnosticErrorReport(
    allocator: std.mem.Allocator,
    issue_limit: usize,
    area: DiagnosticIssueArea,
    kind: []const u8,
    detail: []const u8,
) !DiagnosticReport {
    var issues: std.ArrayList(DiagnosticIssue) = .empty;
    errdefer {
        for (issues.items) |*issue| issue.deinit(allocator);
        issues.deinit(allocator);
    }

    var report = DiagnosticReport{ .issue_limit = issue_limit };
    try addDiagnosticIssue(allocator, &report, &issues, area, kind, detail, null, null, null, null);
    report.issues = try issues.toOwnedSlice(allocator);
    return report;
}

fn validateObjects(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    const prefix = diagnosticObjectSchemaPrefix(db);
    const sql = try std.fmt.allocPrintSentinel(allocator, "select object_id from {s}_zova_objects order by hex(object_id)", .{prefix}, 0);
    defer allocator.free(sql);
    const chunk_sql = try std.fmt.allocPrintSentinel(
        allocator,
        "select size_bytes, data from {s}_zova_chunks where chunk_hash = ?",
        .{prefix},
        0,
    );
    defer allocator.free(chunk_sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    var chunk_stmt = try db.prepare(chunk_sql);
    defer chunk_stmt.deinit();

    while ((try stmt.step()) == .row) {
        const raw_id = stmt.columnBlob(0);
        if (raw_id.len != @sizeOf(zova.ObjectId)) {
            try addDiagnosticIssue(allocator, report, issues, .object, "object_id_shape", "ObjectCorrupt", raw_id, null, null, null);
            continue;
        }
        var id: zova.ObjectId = undefined;
        @memcpy(&id, raw_id);
        report.stats.objects += 1;

        var manifest = db.objectManifest(allocator, id) catch |err| {
            try addMissingManifestChunkIssues(allocator, db, report, issues, id);
            try addDiagnosticIssue(allocator, report, issues, .object, "object_manifest", @errorName(err), id[0..], null, null, null);
            continue;
        };
        defer manifest.deinit(allocator);
        for (manifest.chunks) |chunk| {
            report.stats.chunks += 1;
            try chunk_stmt.bindBlob(1, &chunk.hash);
            const chunk_error: ?[]const u8 = switch (try chunk_stmt.step()) {
                .done => "ObjectChunkNotFound",
                .row => blk: {
                    const stored_size = chunk_stmt.columnInt64(0);
                    const data = chunk_stmt.columnBlob(1);
                    if (stored_size <= 0 or @as(u64, @intCast(stored_size)) != chunk.size_bytes or @as(u64, @intCast(data.len)) != chunk.size_bytes) {
                        break :blk "ObjectCorrupt";
                    }
                    if (!std.mem.eql(u8, &zova.objectChunkId(data), &chunk.hash)) break :blk "ObjectCorrupt";
                    break :blk null;
                },
            };
            try chunk_stmt.reset();
            try chunk_stmt.clearBindings();
            if (chunk_error) |detail| {
                try addDiagnosticIssue(allocator, report, issues, .chunk, "chunk_integrity", detail, id[0..], chunk.hash[0..], null, null);
            }
        }

        var object = db.getObject(allocator, id) catch |err| {
            try addDiagnosticIssue(allocator, report, issues, .object, "object_integrity", @errorName(err), id[0..], null, null, null);
            continue;
        };
        object.deinit(allocator);
    }
}

fn addMissingManifestChunkIssues(
    allocator: std.mem.Allocator,
    db: *zova.Database,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    object_id: zova.ObjectId,
) !void {
    const prefix = diagnosticObjectSchemaPrefix(db);
    const sql = try std.fmt.allocPrintSentinel(allocator,
        \\select oc.chunk_hash
        \\from {s}_zova_object_chunks oc
        \\left join {s}_zova_chunks c on c.chunk_hash = oc.chunk_hash
        \\where oc.object_id = ?
        \\  and c.chunk_hash is null
        \\order by oc.chunk_index asc
    , .{ prefix, prefix }, 0);
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try stmt.bindBlob(1, &object_id);

    while ((try stmt.step()) == .row) {
        const raw_hash = stmt.columnBlob(0);
        const kind: []const u8 = if (raw_hash.len == @sizeOf(zova.ObjectChunkId)) "missing_chunk" else "missing_chunk_id_shape";
        const detail: []const u8 = if (raw_hash.len == @sizeOf(zova.ObjectChunkId)) "ObjectChunkNotFound" else "ObjectCorrupt";
        try addDiagnosticIssue(allocator, report, issues, .chunk, kind, detail, object_id[0..], raw_hash, null, null);
    }
}

fn validateLooseChunks(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    const prefix = diagnosticObjectSchemaPrefix(db);
    const sql = try std.fmt.allocPrintSentinel(allocator,
        \\select c.chunk_hash
        \\from {s}_zova_chunks c
        \\where not exists (
        \\  select 1 from {s}_zova_object_chunks oc where oc.chunk_hash = c.chunk_hash
        \\)
        \\order by hex(c.chunk_hash)
    , .{ prefix, prefix }, 0);
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const raw_hash = stmt.columnBlob(0);
        if (raw_hash.len != @sizeOf(zova.ObjectChunkId)) {
            try addDiagnosticIssue(allocator, report, issues, .chunk, "loose_chunk_id_shape", "ObjectCorrupt", null, raw_hash, null, null);
            continue;
        }
        var hash: zova.ObjectChunkId = undefined;
        @memcpy(&hash, raw_hash);
        report.stats.loose_chunks += 1;

        var chunk = db.getObjectChunk(allocator, hash) catch |err| {
            try addDiagnosticIssue(allocator, report, issues, .chunk, "loose_chunk_integrity", @errorName(err), null, hash[0..], null, null);
            continue;
        };
        chunk.deinit(allocator);
    }
}

fn validateVectors(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    const prefix = diagnosticVectorSchemaPrefix(db);
    const sql = try std.fmt.allocPrintSentinel(allocator,
        \\select c.name, v.vector_id
        \\from {s}_zova_vectors v
        \\join {s}_zova_vector_collections c on c.collection_key = v.collection_key
        \\order by c.name, v.vector_id
    , .{ prefix, prefix }, 0);
    defer allocator.free(sql);

    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const collection_name = stmt.columnText(0);
        const vector_id = stmt.columnText(1);
        report.stats.vectors += 1;
        var vector = db.getVector(allocator, collection_name, vector_id) catch |err| {
            try addDiagnosticIssue(allocator, report, issues, .vector, "vector_integrity", @errorName(err), null, null, collection_name, vector_id);
            continue;
        };
        vector.deinit(allocator);
    }
}

fn validateGraphs(allocator: std.mem.Allocator, db: *zova.Database, report: *DiagnosticReport, issues: *std.ArrayList(DiagnosticIssue)) !void {
    const prefix = diagnosticGraphSchemaPrefix(db);
    const graphs_sql = try std.fmt.allocPrintSentinel(allocator, "select name from {s}_zova_graphs order by name", .{prefix}, 0);
    defer allocator.free(graphs_sql);
    var graphs = try db.prepare(graphs_sql);
    defer graphs.deinit();
    while ((try graphs.step()) == .row) {
        const graph_name = graphs.columnText(0);
        report.stats.graphs += 1;
        if (!isValidGraphAsciiName(graph_name, 128)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "graph_name_invalid", @errorName(error.GraphInvalid), graph_name, null, null);
        }
    }

    const nodes_sql = try std.fmt.allocPrintSentinel(allocator,
        \\select g.name, n.node_id, n.kind, n.target_type, n.target_namespace, n.target_ref
        \\from {s}_zova_graph_nodes n
        \\join {s}_zova_graphs g on g.graph_key = n.graph_key
        \\order by g.name, n.node_id
    , .{ prefix, prefix }, 0);
    defer allocator.free(nodes_sql);
    var nodes = try db.prepare(nodes_sql);
    defer nodes.deinit();
    while ((try nodes.step()) == .row) {
        const graph_name = nodes.columnText(0);
        const node_id = nodes.columnText(1);
        const kind = nodes.columnText(2);
        const target_type = nodes.columnText(3);
        report.stats.graph_nodes += 1;

        if (!isValidGraphAsciiName(graph_name, 128)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_graph_name_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (!isValidGraphNodeId(node_id)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_id_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (!isValidGraphAsciiName(kind, 128)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_kind_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (!isValidGraphTargetTypeText(target_type)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_target_type_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (nodes.columnType(4) != .null and !isValidGraphOptionalText(nodes.columnText(4))) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_target_namespace_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (nodes.columnType(5) != .null and !isValidGraphOptionalText(nodes.columnText(5))) {
            try addGraphDiagnosticIssue(allocator, report, issues, "node_target_ref_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
        }
        if (graphTargetTypeFromText(target_type)) |target_type_value| {
            try validateGraphTargetReference(
                allocator,
                db,
                report,
                issues,
                graph_name,
                node_id,
                target_type_value,
                if (nodes.columnType(4) == .null) null else nodes.columnText(4),
                if (nodes.columnType(5) == .null) null else nodes.columnText(5),
            );
        }
    }

    const edges_sql = try std.fmt.allocPrintSentinel(allocator,
        \\select g.name, from_node.node_id, et.name, to_node.node_id,
        \\  from_node.node_id is null,
        \\  to_node.node_id is null,
        \\  et.edge_type_key is null,
        \\  typeof(e.payload) != 'blob'
        \\from {s}_zova_graph_edges e
        \\join {s}_zova_graphs g on g.graph_key = e.graph_key
        \\left join {s}_zova_graph_edge_types et on et.graph_key=e.graph_key and et.edge_type_key=e.edge_type_key
        \\left join {s}_zova_graph_nodes from_node
        \\  on from_node.graph_key = e.graph_key and from_node.node_key = e.from_node_key
        \\left join {s}_zova_graph_nodes to_node
        \\  on to_node.graph_key = e.graph_key and to_node.node_key = e.to_node_key
        \\order by g.name, from_node.node_id, et.name, to_node.node_id
    , .{ prefix, prefix, prefix, prefix, prefix }, 0);
    defer allocator.free(edges_sql);
    var edges = try db.prepare(edges_sql);
    defer edges.deinit();
    while ((try edges.step()) == .row) {
        const graph_name = edges.columnText(0);
        const from_node_id = edges.columnText(1);
        const missing_type = edges.columnInt64(6) != 0;
        const edge_type = if (missing_type) "" else edges.columnText(2);
        const to_node_id = edges.columnText(3);
        const missing_from = edges.columnInt64(4) != 0;
        const missing_to = edges.columnInt64(5) != 0;
        const invalid_payload = edges.columnInt64(7) != 0;
        report.stats.graph_edges += 1;

        if (!isValidGraphAsciiName(graph_name, 128)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "edge_graph_name_invalid", @errorName(error.GraphInvalid), graph_name, from_node_id, edge_type);
        }
        if (!isValidGraphNodeId(from_node_id)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "edge_from_node_invalid", @errorName(error.GraphInvalid), graph_name, from_node_id, edge_type);
        }
        if (!isValidGraphNodeId(to_node_id)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "edge_to_node_invalid", @errorName(error.GraphInvalid), graph_name, to_node_id, edge_type);
        }
        if (missing_type) {
            try addGraphDiagnosticIssue(allocator, report, issues, "missing_edge_type", @errorName(error.GraphInvalid), graph_name, from_node_id, null);
        } else if (!isValidGraphAsciiName(edge_type, 128)) {
            try addGraphDiagnosticIssue(allocator, report, issues, "edge_type_invalid", @errorName(error.GraphInvalid), graph_name, from_node_id, edge_type);
        }
        if (missing_from) {
            try addGraphDiagnosticIssue(allocator, report, issues, "missing_edge_from_node", @errorName(error.GraphNodeNotFound), graph_name, from_node_id, edge_type);
        }
        if (missing_to) {
            try addGraphDiagnosticIssue(allocator, report, issues, "missing_edge_to_node", @errorName(error.GraphNodeNotFound), graph_name, to_node_id, edge_type);
        }
        if (invalid_payload) {
            try addGraphDiagnosticIssue(allocator, report, issues, "edge_payload_invalid", @errorName(error.GraphInvalid), graph_name, from_node_id, edge_type);
        }
    }
}

pub fn isValidGraphAsciiName(name: []const u8, max_len: usize) bool {
    if (name.len == 0 or name.len > max_len) return false;
    if (startsWithZovaPrefix(name)) return false;
    for (name) |byte| {
        if (!((byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '_' or
            byte == '.' or
            byte == ':' or
            byte == '-')) return false;
    }
    return true;
}

pub fn isValidGraphNodeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 512) return false;
    if (!std.unicode.utf8ValidateSlice(id)) return false;
    if (startsWithZovaPrefix(id)) return false;
    for (id) |byte| {
        if (byte == 0) return false;
    }
    return true;
}

pub fn isValidGraphOptionalText(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| {
        if (byte == 0) return false;
    }
    return true;
}

fn isValidGraphTargetTypeText(text: []const u8) bool {
    return std.mem.eql(u8, text, "none") or
        std.mem.eql(u8, text, "record") or
        std.mem.eql(u8, text, "object") or
        std.mem.eql(u8, text, "object_chunk") or
        std.mem.eql(u8, text, "vector") or
        std.mem.eql(u8, text, "entity") or
        std.mem.eql(u8, text, "fact") or
        std.mem.eql(u8, text, "concept") or
        std.mem.eql(u8, text, "external");
}

fn validateGraphTargetReference(
    allocator: std.mem.Allocator,
    db: *zova.Database,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    graph_name: []const u8,
    node_id: []const u8,
    target_type: zova.GraphTargetType,
    target_namespace: ?[]const u8,
    target_ref: ?[]const u8,
) !void {
    switch (target_type) {
        .object => {
            const ref = target_ref orelse {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_object_target_missing", @errorName(error.ObjectNotFound), graph_name, node_id, null);
                return;
            };
            const id = parseHex32(ref) catch {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_object_target_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
                return;
            };
            if (!(db.hasObject(id) catch false)) {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_object_target_missing", @errorName(error.ObjectNotFound), graph_name, node_id, null);
            }
        },
        .object_chunk => {
            const ref = target_ref orelse {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_chunk_target_missing", @errorName(error.ObjectChunkNotFound), graph_name, node_id, null);
                return;
            };
            const id = parseHex32(ref) catch {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_chunk_target_invalid", @errorName(error.GraphInvalid), graph_name, node_id, null);
                return;
            };
            if (!(db.hasObjectChunk(id) catch false)) {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_chunk_target_missing", @errorName(error.ObjectChunkNotFound), graph_name, node_id, null);
            }
        },
        .vector => {
            const collection = target_namespace orelse {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_vector_target_missing", @errorName(error.VectorNotFound), graph_name, node_id, null);
                return;
            };
            const vector_id = target_ref orelse {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_vector_target_missing", @errorName(error.VectorNotFound), graph_name, node_id, null);
                return;
            };
            if (!(db.hasVector(collection, vector_id) catch false)) {
                try addGraphDiagnosticIssue(allocator, report, issues, "node_vector_target_missing", @errorName(error.VectorNotFound), graph_name, node_id, null);
            }
        },
        else => {},
    }
}

fn addDiagnosticIssue(
    allocator: std.mem.Allocator,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    area: DiagnosticIssueArea,
    kind: []const u8,
    detail: []const u8,
    object_id: ?[]const u8,
    chunk_hash: ?[]const u8,
    collection_name: ?[]const u8,
    vector_id: ?[]const u8,
) !void {
    report.issue_count += 1;
    report.severity_counts.errors += 1;
    switch (area) {
        .sqlite => report.issue_counts.sqlite += 1,
        .bound_store => report.issue_counts.bound_store += 1,
        .extension => report.issue_counts.extension += 1,
        .object => report.issue_counts.object += 1,
        .chunk => report.issue_counts.chunk += 1,
        .vector => report.issue_counts.vector += 1,
        .graph => report.issue_counts.graph += 1,
    }

    if (issues.items.len >= report.issue_limit) {
        report.issues_truncated = true;
        return;
    }

    const owned_kind = try allocator.dupe(u8, kind);
    const owned_detail = allocator.dupe(u8, detail) catch |err| {
        allocator.free(owned_kind);
        return err;
    };

    var issue = DiagnosticIssue{
        .area = area,
        .kind = owned_kind,
        .detail = owned_detail,
    };
    errdefer issue.deinit(allocator);

    if (object_id) |bytes| issue.object_id_hex = try lowerHexAlloc(allocator, bytes);
    if (chunk_hash) |bytes| issue.chunk_hash_hex = try lowerHexAlloc(allocator, bytes);
    if (collection_name) |value| issue.collection_name = try allocator.dupe(u8, value);
    if (vector_id) |value| issue.vector_id = try allocator.dupe(u8, value);

    try issues.append(allocator, issue);
}

fn addGraphDiagnosticIssue(
    allocator: std.mem.Allocator,
    report: *DiagnosticReport,
    issues: *std.ArrayList(DiagnosticIssue),
    kind: []const u8,
    detail: []const u8,
    graph_name: ?[]const u8,
    node_id: ?[]const u8,
    edge_type: ?[]const u8,
) !void {
    report.issue_count += 1;
    report.severity_counts.errors += 1;
    report.issue_counts.graph += 1;

    if (issues.items.len >= report.issue_limit) {
        report.issues_truncated = true;
        return;
    }

    const owned_kind = try allocator.dupe(u8, kind);
    const owned_detail = allocator.dupe(u8, detail) catch |err| {
        allocator.free(owned_kind);
        return err;
    };

    var issue = DiagnosticIssue{
        .area = .graph,
        .kind = owned_kind,
        .detail = owned_detail,
    };
    errdefer issue.deinit(allocator);

    if (graph_name) |value| issue.graph_name = try allocator.dupe(u8, value);
    if (node_id) |value| issue.node_id = try allocator.dupe(u8, value);
    if (edge_type) |value| issue.edge_type = try allocator.dupe(u8, value);

    try issues.append(allocator, issue);
}
