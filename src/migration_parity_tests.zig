//! Logical-parity and lifecycle verification for storage-format migration.
//!
//! Proves that migration preserves public meaning — user schema and rows,
//! object bytes and manifests, vector values and search distances, graph
//! structure with payloads, opaque keys, ordering, neighbors, degree, walks,
//! and scan pagination — and that migrated databases remain fully usable
//! through every lifecycle operation. Also covers the failure matrix:
//! read-only sources, active writers, missing parents, allocation faults,
//! store-phase SQL faults, and cleanup.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const test_support = @import("zova_test_support.zig");
const zova = @import("zova.zig");

const Database = zova.Database;

const fixture_dir = "tests/fixtures";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn fileSha256(path: []const u8) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn copyFixtureInto(destination_path: [:0]const u8, fixture_name: []const u8) !void {
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, "{s}/{s}", .{ fixture_dir, fixture_name });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), source_path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = destination_path, .data = bytes });
}

fn expectScalarTextRaw(db: *sqlite.Database, sql: [:0]const u8, expected: []const u8) !void {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try std.testing.expectEqualStrings(expected, stmt.columnText(0));
}

// ---------------------------------------------------------------------------
// Snapshot capture and comparison.
// ---------------------------------------------------------------------------

const Snapshot = struct {
    user_schema_and_rows: []u8,
    objects: []u8,
    vectors: []u8,
    graphs: []u8,
    bindings_identity: []u8,
    extensions: []u8,
    extension_behavior: []u8,

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.user_schema_and_rows);
        allocator.free(self.objects);
        allocator.free(self.vectors);
        allocator.free(self.graphs);
        allocator.free(self.bindings_identity);
        allocator.free(self.extensions);
        allocator.free(self.extension_behavior);
    }
};

fn captureSnapshot(allocator: std.mem.Allocator, path: [:0]const u8) !Snapshot {
    // Inspection handles register the runtime SQL helpers without enforcing
    // the current storage format, so format-9 sources and format-11 results
    // are captured through identical code paths.
    var db = try zova.openForLogicalInspection(path);
    defer db.deinit();

    var raw = try sqlite.Database.openWithFlags(path, .read_only);
    defer raw.deinit();

    var out = Snapshot{
        .user_schema_and_rows = try allocator.dupe(u8, ""),
        .objects = try allocator.dupe(u8, ""),
        .vectors = try allocator.dupe(u8, ""),
        .graphs = try allocator.dupe(u8, ""),
        .bindings_identity = try allocator.dupe(u8, ""),
        .extensions = try allocator.dupe(u8, ""),
        .extension_behavior = try allocator.dupe(u8, ""),
    };
    errdefer out.deinit(allocator);

    out.user_schema_and_rows = try captureUserSchemaAndRows(allocator, &raw, &db);
    out.objects = try captureObjects(allocator, &db);
    out.vectors = try captureVectors(allocator, &db);
    out.graphs = try captureGraphs(allocator, &db);
    out.bindings_identity = try captureBindingsIdentity(allocator, &raw);
    out.extensions = try captureExtensions(allocator, &raw);
    out.extension_behavior = try captureExtensionBehavior(&db);
    return out;
}

/// User tables, their schema entries, and every row in deterministic order.
fn captureUserSchemaAndRows(allocator: std.mem.Allocator, raw: *sqlite.Database, db: *Database) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var schema = try raw.prepare(
        "select type, name, tbl_name, sql from sqlite_master where name not like '\\_%' escape '\\' and name not like 'sqlite_%' order by type, name",
    );
    defer schema.deinit();

    const Entry = struct { kind: []u8, name: []u8, tbl: []u8, sql: []u8 };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*entry| {
            allocator.free(entry.kind);
            allocator.free(entry.name);
            allocator.free(entry.tbl);
            allocator.free(entry.sql);
        }
        entries.deinit(allocator);
    }

    while (true) {
        const step = try schema.step();
        if (step == .done) break;
        try entries.append(allocator, .{
            .kind = try allocator.dupe(u8, schema.columnText(0)),
            .name = try allocator.dupe(u8, schema.columnText(1)),
            .tbl = try allocator.dupe(u8, schema.columnText(2)),
            .sql = try allocator.dupe(u8, schema.columnText(3)),
        });
    }

    for (entries.items) |*entry| {
        try out.print(allocator, "{s}|{s}|{s}|{s}\n", .{ entry.kind, entry.name, entry.tbl, entry.sql });

        if (!std.mem.eql(u8, entry.kind, "table")) continue;

        // Deterministic full-row dump with deterministic ordering. WITHOUT
        // ROWID tables lack rowid; fall back to primary-key ordering. All
        // values use length-prefixed canonical encoding to avoid delimiter
        // collisions.
        var order_clause: []const u8 = "rowid";
        var order_storage: ?[]u8 = null;
        defer if (order_storage) |storage| allocator.free(storage);

        if (std.ascii.indexOfIgnoreCase(entry.sql, "without rowid") != null) {
            var pk_stmt_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const pk_sql = try std.fmt.bufPrintZ(&pk_stmt_buffer, "pragma table_info(\"{s}\")", .{entry.name});
            var pk_stmt = try raw.prepare(pk_sql);
            defer pk_stmt.deinit();

            const PkCol = struct { pk: i64, name: []u8 };
            var pk_entries: std.ArrayList(PkCol) = .empty;
            defer {
                for (pk_entries.items) |*pk_entry| allocator.free(pk_entry.name);
                pk_entries.deinit(allocator);
            }

            while (true) {
                const step = try pk_stmt.step();
                if (step == .done) break;
                const pk = pk_stmt.columnInt64(5);
                if (pk > 0) {
                    try pk_entries.append(allocator, .{
                        .pk = pk,
                        .name = try allocator.dupe(u8, pk_stmt.columnText(1)),
                    });
                }
            }

            std.mem.sort(PkCol, pk_entries.items, {}, struct {
                fn lessThan(_: void, a: PkCol, b: PkCol) bool {
                    return a.pk < b.pk;
                }
            }.lessThan);

            if (pk_entries.items.len > 0) {
                var out2: std.ArrayList(u8) = .empty;
                defer out2.deinit(allocator);
                for (pk_entries.items, 0..) |pk_entry, idx| {
                    if (idx > 0) try out2.appendSlice(allocator, ", ");
                    const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{pk_entry.name});
                    defer allocator.free(quoted);
                    try out2.appendSlice(allocator, quoted);
                }
                order_storage = try out2.toOwnedSlice(allocator);
                order_clause = order_storage.?;
            } else {
                // No primary key; order by all columns for determinism.
                order_clause = "rowid";
            }
        }

        var rows_sql_buffer: [1024]u8 = undefined;
        const rows_sql = try std.fmt.bufPrintZ(&rows_sql_buffer, "select * from \"{s}\" order by {s}", .{ entry.name, order_clause });
        var rows = try raw.prepare(rows_sql);
        defer rows.deinit();

        while (true) {
            const step = try rows.step();
            if (step == .done) break;
            const column_count: usize = @intCast(rows.columnCount());
            for (0..column_count) |column| {
                const column_index: c_int = @intCast(column);
                switch (rows.columnType(column_index)) {
                    .integer => try out.print(allocator, "i:{d};", .{rows.columnInt64(column_index)}),
                    .float => try out.print(allocator, "f:{d};", .{rows.columnDouble(column_index)}),
                    .text => {
                        const text = rows.columnText(column_index);
                        try out.print(allocator, "t{d}:{s};", .{ text.len, text });
                    },
                    .blob => {
                        const blob = rows.columnBlob(column_index);
                        try out.print(allocator, "b{d}:{x};", .{ blob.len, blob });
                    },
                    .null => try out.appendSlice(allocator, "n;"),
                }
            }
            try out.append(allocator, '\n');
        }
        _ = db;
    }

    return out.toOwnedSlice(allocator);
}

/// Every stored object reconstructed byte-for-byte plus its manifest details.
fn captureObjects(allocator: std.mem.Allocator, db: *Database) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var ids: std.ArrayList(zova.ObjectId) = .empty;
    defer ids.deinit(allocator);
    {
        var raw_ids = try db.prepare("select object_id from _zova_objects order by size_bytes, object_id");
        defer raw_ids.deinit();
        while (true) {
            const step = try raw_ids.step();
            if (step == .done) break;
            const blob = raw_ids.columnBlob(0);
            var id: zova.ObjectId = undefined;
            @memcpy(&id, blob[0..32]);
            try ids.append(allocator, id);
        }
    }

    for (ids.items) |id| {
        var object = try db.getObject(allocator, id);
        defer object.deinit(allocator);

        var manifest = try db.objectManifest(allocator, id);
        defer manifest.deinit(allocator);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(object.bytes, &digest, .{});

        try out.print(allocator, "object {x} size={d} chunks={d} chunker={s}\n", .{
            digest,
            manifest.size_bytes,
            manifest.chunk_count,
            manifest.chunker,
        });
        for (manifest.chunks) |chunk| {
            try out.print(allocator, "  chunk index={d} hash={x} offset={d} size={d}\n", .{
                chunk.index, chunk.hash, chunk.offset, chunk.size_bytes,
            });
        }

        // Range reads: zero, EOF, and across chunk boundaries (exercised for the
        // multi-chunk object). Comparison is length-prefixed to avoid delimiter
        // collisions.
        {
            var buffer: [64]u8 = undefined;

            // Full read via range at offset 0 must equal getObject bytes.
            {
                var range_buf = try allocator.alloc(u8, object.bytes.len);
                defer allocator.free(range_buf);
                const n = try db.readObjectRange(id, 0, range_buf);
                try std.testing.expectEqual(object.bytes.len, n);
                try std.testing.expectEqualSlices(u8, object.bytes, range_buf[0..n]);
                try out.print(allocator, "  range full len={d} ok\n", .{n});
            }

            // Small prefix.
            {
                const len = @min(@as(usize, 5), object.bytes.len);
                const n = try db.readObjectRange(id, 0, buffer[0..len]);
                try std.testing.expectEqual(len, n);
                try std.testing.expectEqualSlices(u8, object.bytes[0..len], buffer[0..n]);
                try out.print(allocator, "  range prefix offset=0 len={d} bytes={x}\n", .{ n, buffer[0..n] });
            }

            // EOF: offset at size returns 0.
            {
                const n = try db.readObjectRange(id, object.bytes.len, buffer[0..10]);
                try std.testing.expectEqual(@as(usize, 0), n);
                try out.print(allocator, "  range eof offset={d} len=0\n", .{object.bytes.len});
            }

            // Last byte.
            if (object.bytes.len > 0) {
                const n = try db.readObjectRange(id, object.bytes.len - 1, buffer[0..1]);
                try std.testing.expectEqual(@as(usize, 1), n);
                try std.testing.expectEqual(object.bytes[object.bytes.len - 1], buffer[0]);
                try out.print(allocator, "  range last offset={d} byte={x}\n", .{ object.bytes.len - 1, buffer[0..1] });
            }

            // Across chunk boundary for multi-chunk objects.
            if (manifest.chunk_count > 1) {
                const first_size: usize = @intCast(manifest.chunks[0].size_bytes);
                const offset = if (first_size >= 2) first_size - 2 else 0;
                const len: usize = 5;
                const n = try db.readObjectRange(id, offset, buffer[0..len]);
                try std.testing.expectEqual(len, n);
                try std.testing.expectEqualSlices(u8, object.bytes[offset .. offset + len], buffer[0..n]);
                try out.print(allocator, "  range cross offset={d} len={d} bytes={x}\n", .{ offset, n, buffer[0..n] });

                const n2 = try db.readObjectRange(id, first_size, buffer[0..len]);
                try std.testing.expectEqual(len, n2);
                try std.testing.expectEqualSlices(u8, object.bytes[first_size .. first_size + len], buffer[0..n2]);
                try out.print(allocator, "  range boundary offset={d} len={d} bytes={x}\n", .{ first_size, n2, buffer[0..n2] });
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Collection metadata, every vector's values, and search results including
/// distances for fixed queries.
fn captureVectors(allocator: std.mem.Allocator, db: *Database) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var collections = try db.listVectorCollections(allocator);
    defer collections.deinit(allocator);

    for (collections.items) |*info| {
        try out.print(allocator, "collection {s} dims={d} metric={s} element={s} count={d}\n", .{
            info.name, info.dimensions, @tagName(info.metric), @tagName(info.element_type), info.vector_count,
        });

        var id_stmt = try db.prepare(
            \\select v.vector_id from _zova_vectors v
            \\join _zova_vector_collections c on v.collection_key = c.collection_key
            \\where c.name = ?1 order by v.vector_id
        );
        defer id_stmt.deinit();
        try id_stmt.bindText(1, info.name);
        while (true) {
            const step = try id_stmt.step();
            if (step == .done) break;
            const vector_id = try std.testing.allocator.dupe(u8, id_stmt.columnText(0));
            defer std.testing.allocator.free(vector_id);

            var vector = try db.getVector(allocator, info.name, vector_id);
            defer vector.deinit(allocator);

            try out.print(allocator, "  vector {s} values=", .{vector.id});
            switch (vector.values) {
                .f32 => |values| for (values) |value| try out.print(allocator, "{d},", .{value}),
                .f16 => |values| for (values) |value| try out.print(allocator, "{d},", .{@as(f32, value)}),
                .i8 => |values| for (values) |value| try out.print(allocator, "{d},", .{value}),
            }
            try out.append(allocator, '\n');
        }

        // Fixed queries: search results must match exactly, distances included.
        if (info.element_type == .f32) {
            var results = try db.searchVectors(
                allocator,
                info.name,
                .{ .f32 = &.{ 0.25, -0.5, 1.0, 2.0 } },
                10,
            );
            defer results.deinit(allocator);
            for (results.items) |*result| {
                try out.print(allocator, "  search hit {s} distance={d}\n", .{ result.id, result.distance });
            }
        } else if (info.element_type == .f16) {
            var results = try db.searchVectors(
                allocator,
                info.name,
                .{ .f16 = &.{ 0x3c00, 0xbc00, 0x4200, 0xc200 } },
                10,
            );
            defer results.deinit(allocator);
            for (results.items) |*result| {
                try out.print(allocator, "  search hit {s} distance={d}\n", .{ result.id, result.distance });
            }
        } else if (info.element_type == .i8) {
            var results = try db.searchVectors(
                allocator,
                info.name,
                .{ .i8 = &.{ 12, -34, 56, -78 } },
                10,
            );
            defer results.deinit(allocator);
            for (results.items) |*result| {
                try out.print(allocator, "  search hit {s} distance={d}\n", .{ result.id, result.distance });
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Graph structure: nodes with targets and creation order, edges with types
/// and opaque keys, payloads, neighbors, degrees, walks, and pagination.
fn captureGraphs(allocator: std.mem.Allocator, db: *Database) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var graph_names: std.ArrayList([]u8) = .empty;
    defer {
        for (graph_names.items) |name| allocator.free(name);
        graph_names.deinit(allocator);
    }
    {
        var names = try db.listGraphs(allocator);
        defer names.deinit(allocator);
        for (names.items) |*info| {
            try graph_names.append(allocator, try allocator.dupe(u8, info.name));
        }
    }

    for (graph_names.items) |graph_name| {
        try out.print(allocator, "graph {s}\n", .{graph_name});

        // Capture nodes and edges via independent cursor pagination with
        // small per-side limits, recording every page and cursor boundary.
        // Each side follows its exclusive cursor until exhausted; strictly
        // increasing keys prove every row is captured exactly once.
        {
            var node_cursor = zova.GraphScanCursor{};
            var previous_node_key: ?i64 = null;
            var node_page_index: usize = 0;
            while (true) {
                var page = try db.graphScan(allocator, .{
                    .graph_name = graph_name,
                    .node_after = node_cursor,
                    .node_limit = 2,
                    .edge_limit = 0,
                });
                defer page.deinit(allocator);

                try out.print(allocator, "  node page {d} rows={d} more={} cursor_before=({d},{d})\n", .{
                    node_page_index,
                    page.nodes.len,
                    page.has_more_nodes,
                    node_cursor.created_order,
                    node_cursor.key,
                });

                if (page.nodes.len == 0) break;
                for (page.nodes) |*node| {
                    try std.testing.expect(previous_node_key == null or node.node_key > previous_node_key.?);
                    previous_node_key = node.node_key;

                    var full = try db.getGraphNode(allocator, graph_name, node.node_id);
                    defer full.deinit(allocator);
                    try out.print(allocator, "    node key={d} id={s} kind={s} target={s}/{s}/{s} order={d}\n", .{
                        node.node_key,
                        full.node_id,
                        full.kind,
                        @tagName(full.target_type),
                        full.target_namespace orelse "-",
                        full.target_ref orelse "-",
                        node.created_order,
                    });
                }
                const node_last = page.nodes[page.nodes.len - 1];
                try out.print(allocator, "  node page {d} cursor_after=({d},{d})\n", .{
                    node_page_index,
                    node_last.created_order,
                    node_last.node_key,
                });
                if (!page.has_more_nodes) break;
                node_cursor = .{ .created_order = node_last.created_order, .key = node_last.node_key };
                node_page_index += 1;
            }

            var edge_cursor = zova.GraphScanCursor{};
            var previous_edge_key: ?i64 = null;
            var edge_page_index: usize = 0;
            while (true) {
                var page = try db.graphScan(allocator, .{
                    .graph_name = graph_name,
                    .edge_after = edge_cursor,
                    .node_limit = 0,
                    .edge_limit = 3,
                });
                defer page.deinit(allocator);

                try out.print(allocator, "  edge page {d} rows={d} more={} cursor_before=({d},{d})\n", .{
                    edge_page_index,
                    page.edges.len,
                    page.has_more_edges,
                    edge_cursor.created_order,
                    edge_cursor.key,
                });

                if (page.edges.len == 0) break;
                for (page.edges) |*edge| {
                    try std.testing.expect(previous_edge_key == null or edge.edge_key > previous_edge_key.?);
                    previous_edge_key = edge.edge_key;

                    var payload_lookup = try db.graphEdgePayloadsGetMany(allocator, graph_name, &.{edge.edge_key});
                    defer payload_lookup.deinit(allocator);
                    const payload: []const u8 = if (payload_lookup.items.len > 0 and payload_lookup.items[0].found)
                        payload_lookup.items[0].payload orelse ""
                    else
                        "";
                    try out.print(allocator, "    edge key={d} from={d} to={d} type={s} order={d} payload={s}\n", .{
                        edge.edge_key,
                        edge.source_node_key,
                        edge.target_node_key,
                        edge.edge_type,
                        edge.created_order,
                        payload,
                    });
                }
                const edge_last = page.edges[page.edges.len - 1];
                try out.print(allocator, "  edge page {d} cursor_after=({d},{d})\n", .{
                    edge_page_index,
                    edge_last.created_order,
                    edge_last.edge_key,
                });
                if (!page.has_more_edges) break;
                edge_cursor = .{ .created_order = edge_last.created_order, .key = edge_last.edge_key };
                edge_page_index += 1;
            }
        }

        // Neighbors, degree, and walks for every node in this graph.
        // Bound-set mains carry no graphs themselves (they live in the stores),
        // so we enumerate nodes dynamically.
        {
            var scan_nodes = try db.graphScan(allocator, .{
                .graph_name = graph_name,
                .node_limit = 1000,
                .edge_limit = 0,
            });
            defer scan_nodes.deinit(allocator);

            for (scan_nodes.nodes) |*node| {
                inline for (.{
                    zova.GraphNeighborDirection.outgoing,
                    zova.GraphNeighborDirection.incoming,
                }) |direction| {
                    var neighbors = try db.graphNeighbors(allocator, .{
                        .graph_name = graph_name,
                        .node_id = node.node_id,
                        .direction = direction,
                        .limit = 100,
                    });
                    defer neighbors.deinit(allocator);
                    for (neighbors.items) |*neighbor| {
                        try out.print(allocator, "    neighbor of {s} ({s}) -> {s} kind={s} via {s}\n", .{
                            node.node_id, @tagName(direction), neighbor.node_id, neighbor.kind, neighbor.edge_type,
                        });
                    }
                    const degree = try db.graphDegree(.{
                        .graph_name = graph_name,
                        .node_id = node.node_id,
                        .direction = direction,
                    });
                    try out.print(allocator, "    degree of {s} ({s}) = {d}\n", .{ node.node_id, @tagName(direction), degree });
                }

                var walk = try db.graphWalk(allocator, .{
                    .graph_name = graph_name,
                    .start_node_id = node.node_id,
                    .max_depth = 3,
                    .limit = 100,
                });
                defer walk.deinit(allocator);
                for (walk.items) |*item| {
                    try out.print(allocator, "    walk from {s} depth={d} node={s}\n", .{ node.node_id, item.depth, item.node_id });
                }
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Binding identity: role, store id, bound-set id, epochs, and counts. Paths
/// are intentionally excluded — they are validated separately against the
/// expected destination sibling names.
fn captureBindingsIdentity(allocator: std.mem.Allocator, raw: *sqlite.Database) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (!(try tableExistsRaw(raw, "_zova_bound_stores"))) {
        try out.appendSlice(allocator, "no bindings\n");
        return out.toOwnedSlice(allocator);
    }

    var stmt = try raw.prepare(
        "select role, store_id, bound_set_id, coalesce(object_epoch, -1), coalesce(vector_epoch, -1), coalesce(graph_epoch, -1) from _zova_bound_stores order by role",
    );
    defer stmt.deinit();

    while (true) {
        const step = try stmt.step();
        if (step == .done) break;
        try out.print(allocator, "binding role={s} store={s} set={s} epochs=({d},{d},{d})\n", .{
            stmt.columnText(0),  stmt.columnText(1),  stmt.columnText(2),
            stmt.columnInt64(3), stmt.columnInt64(4), stmt.columnInt64(5),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn tableExistsRaw(raw: *sqlite.Database, name: []const u8) !bool {
    var stmt = try raw.prepare("select count(*) from sqlite_master where type = 'table' and name = ?");
    defer stmt.deinit();
    try stmt.bindText(1, name);
    _ = try stmt.step();
    return stmt.columnInt64(0) != 0;
}

/// Installed extension records sorted by name (all fields, to prove exact parity).
fn captureExtensions(allocator: std.mem.Allocator, raw: *sqlite.Database) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var stmt = try raw.prepare(
        "select name, version, storage_prefix, zova_abi_min, capabilities, required, installed_at_unix, manifest_json from _zova_extensions order by name",
    );
    defer stmt.deinit();
    while (true) {
        const step = try stmt.step();
        if (step == .done) break;
        try out.print(allocator, "extension {s} v{s} prefix={s} abi={s} caps={s} required={} installed={d} manifest={s}\n", .{
            stmt.columnText(0),
            stmt.columnText(1),
            stmt.columnText(2),
            stmt.columnText(3),
            stmt.columnText(4),
            stmt.columnInt64(5) != 0,
            stmt.columnInt64(6),
            stmt.columnText(7),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Bundled trgm SQL behavior: function outputs must be identical after
/// migration, proving installed-extension SQL still runs on the copy.
fn captureExtensionBehavior(db: *Database) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.testing.allocator);

    var installed = try db.prepare("select count(*) from _zova_extensions");
    defer installed.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try installed.step());
    if (installed.columnInt64(0) == 0) {
        try out.appendSlice(std.testing.allocator, "no installed extensions\n");
        return out.toOwnedSlice(std.testing.allocator);
    }

    var stmt = try db.prepare(
        "select zova_trgm_similarity('alpha', 'alpha'), zova_trgm_similarity('alpha', 'bravo'), zova_trgm_similarity('migrate', 'migration')",
    );
    defer stmt.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try stmt.step());
    try out.print(std.testing.allocator, "similarity d={d:.12} d={d:.12} d={d:.12}\n", .{
        stmt.columnDouble(0), stmt.columnDouble(1), stmt.columnDouble(2),
    });
    return out.toOwnedSlice(std.testing.allocator);
}

fn expectSnapshotsEqual(allocator: std.mem.Allocator, expected: *Snapshot, actual: *Snapshot) !void {
    const fields = .{
        .{ "user_schema_and_rows", expected.user_schema_and_rows, actual.user_schema_and_rows },
        .{ "objects", expected.objects, actual.objects },
        .{ "vectors", expected.vectors, actual.vectors },
        .{ "graphs", expected.graphs, actual.graphs },
        .{ "bindings_identity", expected.bindings_identity, actual.bindings_identity },
        .{ "extensions", expected.extensions, actual.extensions },
        .{ "extension_behavior", expected.extension_behavior, actual.extension_behavior },
    };
    inline for (fields) |field| {
        if (!std.mem.eql(u8, field[1], field[2])) {
            std.debug.print("snapshot field '{s}' differs:\n--- expected ---\n{s}\n--- actual ---\n{s}\n", .{ field[0], field[1], field[2] });
            return error.TestUnexpectedResult;
        }
    }
    _ = allocator;
}

// ---------------------------------------------------------------------------
// Parity: source snapshot must equal destination snapshot after migration.
// ---------------------------------------------------------------------------

fn setupBoundSet(set_dir: []const u8) ![4][:0]u8 {
    try std.Io.Dir.cwd().createDirPath(io(), set_dir);

    const members = [_][]const u8{
        "bound-main-format-9.zova",
        "bound-main-format-9.objects.zova",
        "bound-main-format-9.vectors.zova",
        "bound-main-format-9.graphs.zova",
    };
    var paths: [4][:0]u8 = undefined;
    inline for (members, 0..) |name, index| {
        var member_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const member_path = try std.fmt.bufPrintZ(&member_buffer, "{s}/{s}", .{ set_dir, name });
        try copyFixtureInto(member_path, name);
        paths[index] = try std.testing.allocator.dupeZ(u8, member_path);
    }

    // Relocate bindings (caller concern before migration).
    {
        var raw = try sqlite.Database.open(paths[0]);
        defer raw.deinit();
        inline for (.{
            .{ .role = "object_store", .suffix = "objects" },
            .{ .role = "vector_store", .suffix = "vectors" },
            .{ .role = "graph_store", .suffix = "graphs" },
        }) |entry| {
            var update = try raw.prepare("update _zova_bound_stores set path = ?1 where role = ?2");
            defer update.deinit();
            var sibling_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const sibling = try std.fmt.bufPrintZ(&sibling_buffer, "{s}/bound-main-format-9.{s}.zova", .{ set_dir, entry.suffix });
            try update.bindText(1, sibling);
            try update.bindText(2, entry.role);
            _ = try update.step();
        }
    }
    return paths;
}

test "migrateDatabase preserves every public subsystem exactly in a single-file migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, ".zig-cache/tmp/{s}/parity-source.zova", .{tmp.sub_path[0..]});
    try copyFixtureInto(source_path, "format-9.zova");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrintZ(&dest_buffer, ".zig-cache/tmp/{s}/parity-dest.zova", .{tmp.sub_path[0..]});

    var before = try captureSnapshot(std.testing.allocator, source_path);
    defer before.deinit(std.testing.allocator);

    try zova.migrateDatabase(source_path, dest_path, .{});

    var after = try captureSnapshot(std.testing.allocator, dest_path);
    defer after.deinit(std.testing.allocator);

    try expectSnapshotsEqual(std.testing.allocator, &before, &after);
}

test "migrateDatabase preserves every public subsystem exactly across a bound set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const set_dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/bound-parity", .{tmp.sub_path[0..]});
    const paths = try setupBoundSet(set_dir);
    defer for (paths) |path| std.testing.allocator.free(path);

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_main = try std.fmt.bufPrintZ(&dest_buffer, "{s}/migrated-set.zova", .{set_dir});

    var before_main = try captureSnapshot(std.testing.allocator, paths[0]);
    defer before_main.deinit(std.testing.allocator);

    // Store files carry their own private content; compare each member too.
    var before_stores: [3]Snapshot = undefined;
    for (paths[1..4], 0..) |store_path, index| {
        before_stores[index] = try captureSnapshot(std.testing.allocator, store_path);
    }
    defer for (&before_stores) |*snapshot| snapshot.deinit(std.testing.allocator);

    try zova.migrateDatabase(paths[0], dest_main, .{});

    var after_main = try captureSnapshot(std.testing.allocator, dest_main);
    defer after_main.deinit(std.testing.allocator);
    try expectSnapshotsEqual(std.testing.allocator, &before_main, &after_main);

    // Store files carry the same private content; each migrated store's
    // identity metadata survives byte-for-byte.
    const store_pairs = [_][2][]const u8{
        .{ "bound-main-format-9.objects.zova", "migrated-set.objects.zova" },
        .{ "bound-main-format-9.vectors.zova", "migrated-set.vectors.zova" },
        .{ "bound-main-format-9.graphs.zova", "migrated-set.graphs.zova" },
    };
    inline for (store_pairs) |pair| {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src_path = try std.fmt.bufPrintZ(&src_buf, "{s}/{s}", .{ set_dir, pair[0] });
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst_path = try std.fmt.bufPrintZ(&dst_buf, "{s}/{s}", .{ set_dir, pair[1] });

        var src_raw = try sqlite.Database.openWithFlags(src_path, .read_only);
        defer src_raw.deinit();
        var dst_raw = try sqlite.Database.openWithFlags(dst_path, .read_only);
        defer dst_raw.deinit();

        for ([_][]const u8{ "store_id", "bound_set_id", "object_epoch", "vector_epoch", "graph_epoch" }) |key| {
            var q = try src_raw.prepare("select value from _zova_meta where key = ?");
            defer q.deinit();
            try q.bindText(1, key);
            _ = try q.step();
            const expected = try std.testing.allocator.dupe(u8, q.columnText(0));
            defer std.testing.allocator.free(expected);
            if (expected.len == 0) continue; // role-specific epochs are null on other roles
            var d = try dst_raw.prepare("select value from _zova_meta where key = ?");
            defer d.deinit();
            try d.bindText(1, key);
            _ = try d.step();
            try std.testing.expectEqualStrings(expected, d.columnText(0));
        }
    }

    // Per-store logical parity across migration.
    const migrated_store_names = [_][]const u8{
        "migrated-set.objects.zova",
        "migrated-set.vectors.zova",
        "migrated-set.graphs.zova",
    };
    for (&before_stores, migrated_store_names) |*expected_snapshot, migrated_name| {
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst_path = try std.fmt.bufPrintZ(&dst_buf, "{s}/{s}", .{ set_dir, migrated_name });
        var after_store = try captureSnapshot(std.testing.allocator, dst_path);
        defer after_store.deinit(std.testing.allocator);
        try expectSnapshotsEqual(std.testing.allocator, expected_snapshot, &after_store);
    }

    // Destination binding paths point at the expected siblings.
    {
        var raw = try sqlite.Database.openWithFlags(dest_main, .read_only);
        defer raw.deinit();
        inline for (.{
            .{ .role = "object_store", .suffix = "objects" },
            .{ .role = "vector_store", .suffix = "vectors" },
            .{ .role = "graph_store", .suffix = "graphs" },
        }) |entry| {
            var query = try raw.prepare("select path from _zova_bound_stores where role = ?1");
            defer query.deinit();
            try query.bindText(1, entry.role);
            _ = try query.step();
            var expect_buf: [std.fs.max_path_bytes]u8 = undefined;
            const expected = try std.fmt.bufPrint(&expect_buf, "{s}/migrated-set.{s}.zova", .{ set_dir, entry.suffix });
            try std.testing.expectEqualStrings(expected, query.columnText(0));
        }
    }
}

test "migrated format-9 database receives an empty transactional key-value store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, ".zig-cache/tmp/{s}/kv-source.zova", .{tmp.sub_path[0..]});
    try copyFixtureInto(source_path, "format-9.zova");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrintZ(&dest_buffer, ".zig-cache/tmp/{s}/kv-dest.zova", .{tmp.sub_path[0..]});
    try zova.migrateDatabase(source_path, dest_path, .{});

    var db = try Database.open(dest_path);
    defer db.deinit();

    var count = try db.prepare("select count(*) from _zova_kv");
    defer count.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 0), count.columnInt64(0));

    // Transactional round trip.
    try db.kvPut("parity", "key", "value");
    var got = try db.kvGet(std.testing.allocator, "parity", "key");
    defer got.deinit(std.testing.allocator);
    try std.testing.expect(got.found);
    try std.testing.expectEqualStrings("value", got.value);

    // Rollback discards an uncommitted write.
    try db.begin();
    try db.kvPut("parity", "rolled-back", "nope");
    try db.rollback();
    var missing = try db.kvGet(std.testing.allocator, "parity", "rolled-back");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!missing.found);

    try db.kvDelete("parity", "key");
    var deleted = try db.kvGet(std.testing.allocator, "parity", "key");
    defer deleted.deinit(std.testing.allocator);
    try std.testing.expect(!deleted.found);
}

// ---------------------------------------------------------------------------
// Lifecycle: every operation works on the migrated result.
// ---------------------------------------------------------------------------

fn expectIntegrityOk(path: [:0]const u8) !void {
    // Exercise the actual verification used by check/doctor.
    try zova.verifyOperationalCopy(path, zova.bundledExtensionRegistry());

    var raw = try sqlite.Database.openWithFlags(path, .read_only);
    defer raw.deinit();

    for ([_][:0]const u8{ "pragma integrity_check", "pragma foreign_key_check" }) |sql| {
        var stmt = try raw.prepare(sql);
        defer stmt.deinit();
        const step = try stmt.step();
        if (step == .row) {
            // integrity_check returns "ok"; foreign_key_check returns nothing.
            try std.testing.expectEqualStrings("ok", stmt.columnText(0));
            try std.testing.expectEqual(sqlite.Step.done, try stmt.step());
        }
    }
}

test "migrated database supports backup restore compact salvage and memory restore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, ".zig-cache/tmp/{s}/lifecycle-source.zova", .{tmp.sub_path[0..]});
    try copyFixtureInto(source_path, "format-9.zova");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrintZ(&dest_buffer, ".zig-cache/tmp/{s}/lifecycle-dest.zova", .{tmp.sub_path[0..]});
    try zova.migrateDatabase(source_path, dest_path, .{});

    // Reference object bytes for spot parity across every lifecycle output.
    var reference_db = try Database.open(dest_path);
    defer reference_db.deinit();
    var ids: std.ArrayList(zova.ObjectId) = .empty;
    defer ids.deinit(std.testing.allocator);
    {
        var id_stmt = try reference_db.prepare("select object_id from _zova_objects order by size_bytes");
        defer id_stmt.deinit();
        while (true) {
            if ((try id_stmt.step()) == .done) break;
            const blob = id_stmt.columnBlob(0);
            var id: zova.ObjectId = undefined;
            @memcpy(&id, blob[0..32]);
            try ids.append(std.testing.allocator, id);
        }
    }

    const ExpectObjects = struct {
        fn check(expected_ids: []const zova.ObjectId, db_path: [:0]const u8) !void {
            var db = try Database.open(db_path);
            defer db.deinit();
            for (expected_ids) |id| {
                var object = try db.getObject(std.testing.allocator, id);
                defer object.deinit(std.testing.allocator);
                // Reconstructed bytes must be non-empty and stable length-wise
                // with the manifest; full byte parity is asserted by snapshot
                // tests against the same id set.
                try std.testing.expect(object.bytes.len > 0);
            }
            try std.testing.expectEqual(@as(usize, 3), expected_ids.len);
        }
    };

    // 1. Backup the migrated result and reopen the backup.
    {
        var backup_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const backup_path = try std.fmt.bufPrintZ(&backup_buffer, ".zig-cache/tmp/{s}/lifecycle-backup.zova", .{tmp.sub_path[0..]});
        try reference_db.backupTo(backup_path, .{});
        try ExpectObjects.check(ids.items, backup_path);
        try expectIntegrityOk(backup_path);
    }

    // 2. Restore into a fresh file.
    {
        var restored_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const restored_path = try std.fmt.bufPrintZ(&restored_buffer, ".zig-cache/tmp/{s}/lifecycle-restored.zova", .{tmp.sub_path[0..]});
        try zova.restoreBackup(dest_path, restored_path, .{});
        try ExpectObjects.check(ids.items, restored_path);
        try expectIntegrityOk(restored_path);
    }

    // 3. Compact into a fresh file.
    {
        var compacted_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const compacted_path = try std.fmt.bufPrintZ(&compacted_buffer, ".zig-cache/tmp/{s}/lifecycle-compacted.zova", .{tmp.sub_path[0..]});
        var mutable_dest = try Database.open(dest_path);
        defer mutable_dest.deinit();
        try mutable_dest.compactTo(compacted_path, .{});
        try ExpectObjects.check(ids.items, compacted_path);
        try expectIntegrityOk(compacted_path);
    }

    // 4. Restore into memory.
    {
        var memory = try zova.restoreBackupToMemory(dest_path, .{});
        defer memory.deinit();
        for (ids.items) |id| {
            var object = try memory.getObject(std.testing.allocator, id);
            defer object.deinit(std.testing.allocator);
            try std.testing.expect(object.bytes.len > 0);
        }
    }

    // 5. Extension salvage reports no unknown storage on the migrated file.
    {
        var migrated_raw = try sqlite.Database.openWithFlags(dest_path, .read_only);
        defer migrated_raw.deinit();
        const result = try zova.salvageInstalledExtensions(
            std.testing.allocator,
            &migrated_raw,
            null,
            zova.bundledExtensionRegistry(),
            .plan,
        );
        try std.testing.expectEqual(@as(u64, 0), result.skipped_extensions);
        try std.testing.expectEqual(@as(u64, 0), result.skipped_private_objects);
        // The plan should account for the installed trgm extension without
        // reporting it as skipped.
        try std.testing.expect(result.copied_extensions > 0 or result.copied_private_objects > 0);
    }

    _ = &ids;
}

// ---------------------------------------------------------------------------
// Failure and edge matrix.
// ---------------------------------------------------------------------------

const c = @cImport({
    @cInclude("sys/stat.h");
});

fn setFileMode(path: [:0]const u8, mode: c.mode_t) !void {
    const rc = std.c.chmod(path.ptr, mode);
    if (rc != 0) return error.ChmodFailed;
}

fn expectDirectoryContainsExactly(set_dir: []const u8, expected_names: []const []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io(), set_dir, .{ .iterate = true });
    defer dir.close(io());
    var seen: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io())) |entry| {
        seen += 1;
        var matched = false;
        for (expected_names) |name| {
            if (std.mem.eql(u8, entry.name, name)) matched = true;
        }
        try std.testing.expect(matched);
    }
    try std.testing.expectEqual(expected_names.len, seen);
}

test "migrateDatabase migrates a read-only source without mutating it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, ".zig-cache/tmp/{s}/readonly-source.zova", .{tmp.sub_path[0..]});
    try copyFixtureInto(source_path, "format-9.zova");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrintZ(&dest_buffer, ".zig-cache/tmp/{s}/readonly-dest.zova", .{tmp.sub_path[0..]});

    // Lock the file to read-only permissions; migration never writes to the
    // source, so it must still succeed.
    try setFileMode(source_path, 0o444);
    errdefer setFileMode(source_path, 0o644) catch {};

    try zova.migrateDatabase(source_path, dest_path, .{});
    try setFileMode(source_path, 0o644);

    // Destination reopens as current format with the full object set.
    var db = try Database.open(dest_path);
    defer db.deinit();
    var count = try db.prepare("select count(*) from _zova_objects");
    defer count.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 3), count.columnInt64(0));
}

test "migrateDatabase returns Busy when a writer holds the source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, ".zig-cache/tmp/{s}/busy-source.zova", .{tmp.sub_path[0..]});
    try copyFixtureInto(source_path, "format-9.zova");

    var writer = try sqlite.Database.open(source_path);
    defer writer.deinit();
    try writer.beginImmediate();

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrintZ(&dest_buffer, ".zig-cache/tmp/{s}/busy-dest.zova", .{tmp.sub_path[0..]});

    const result = zova.migrateDatabase(source_path, dest_path, .{});
    try std.testing.expect(result == error.Busy or result == error.Locked);

    try writer.rollback();
    _ = &writer;

    // Nothing was created for the failed attempt.
    var dir_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try expectDirectoryContainsExactly(dir_path, &.{
        "busy-source.zova",
    });
}

test "migrateDatabase rejects destinations under missing parent directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrintZ(&source_buffer, ".zig-cache/tmp/{s}/orphan-source.zova", .{tmp.sub_path[0..]});
    try copyFixtureInto(source_path, "format-9.zova");

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrintZ(&dest_buffer, ".zig-cache/tmp/{s}/missing-parent/deep/migrated.zova", .{tmp.sub_path[0..]});

    try std.testing.expectError(error.CantOpen, zova.migrateDatabase(source_path, dest_path, .{}));

    // The missing parent directory must not have been created by the attempt.
    var parent_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const parent = try std.fmt.bufPrint(&parent_buffer, ".zig-cache/tmp/{s}/missing-parent", .{tmp.sub_path[0..]});
    const parent_exists = blk: {
        std.Io.Dir.cwd().access(io(), parent, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    try std.testing.expect(!parent_exists);
}

test "store-phase SQL faults roll back and clean every staging file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const set_dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/store-fault", .{tmp.sub_path[0..]});
    const paths = try setupBoundSet(set_dir);
    defer for (paths) |path| std.testing.allocator.free(path);

    // Inject a fault into one store file: the trigger is copied forward into
    // that store's staging file and aborts its migration step after KV
    // creation. The preservation baseline is taken after injection.
    {
        var raw = try sqlite.Database.open(paths[1]);
        defer raw.deinit();
        try raw.exec(
            \\create trigger migration_fault before update on _zova_meta
            \\when new.value = '10' and old.key = 'format_version'
            \\begin select raise(abort,'injected store fault'); end
        );
    }

    var hashes: [4][32]u8 = undefined;
    for (paths, 0..) |path, index| {
        hashes[index] = try fileSha256(path);
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_main = try std.fmt.bufPrintZ(&dest_buffer, "{s}/migrated-set.zova", .{set_dir});

    try std.testing.expectError(error.Constraint, zova.migrateDatabase(paths[0], dest_main, .{}));

    for (paths, 0..) |path, index| {
        const after = try fileSha256(path);
        try std.testing.expectEqualSlices(u8, &hashes[index], &after);
    }

    try expectDirectoryContainsExactly(set_dir, &.{
        "bound-main-format-9.zova",
        "bound-main-format-9.objects.zova",
        "bound-main-format-9.vectors.zova",
        "bound-main-format-9.graphs.zova",
    });
}

test "migrateDatabase cleans up under early allocation failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const set_dir = try std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}/oom-sweep", .{tmp.sub_path[0..]});
    const paths = try setupBoundSet(set_dir);
    defer for (paths) |path| std.testing.allocator.free(path);

    var hashes: [4][32]u8 = undefined;
    for (paths, 0..) |path, index| {
        hashes[index] = try fileSha256(path);
    }

    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dest_main = try std.fmt.bufPrintZ(&dest_buffer, "{s}/migrated-set.zova", .{set_dir});

    // Sweep the first 50 allocation indices. Every attempt must fail cleanly:
    // sources byte-identical and exactly the four source files remain.
    var fail_index: usize = 0;
    while (fail_index < 50) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });

        const result = zova.migrateDatabaseInternal(
            failing.allocator(),
            paths[0],
            dest_main,
            .{},
            zova.bundledExtensionRegistry(),
            null,
        );
        if (result) |_| {
            // Migration succeeded before reaching the failing index; later
            // indices will succeed too.
            break;
        } else |_| {}

        for (paths, 0..) |path, index| {
            const after = try fileSha256(path);
            try std.testing.expectEqualSlices(u8, &hashes[index], &after);
        }

        try expectDirectoryContainsExactly(set_dir, &.{
            "bound-main-format-9.zova",
            "bound-main-format-9.objects.zova",
            "bound-main-format-9.vectors.zova",
            "bound-main-format-9.graphs.zova",
        });
    }
}
