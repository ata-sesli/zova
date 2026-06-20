//! Text-only inspection and check CLI for Zova.
//!
//! The CLI is intentionally non-mutating. It opens current-format `.zova`
//! databases, reports bounded summaries, and validates existing object/vector
//! storage. It does not repair, migrate, delete, vacuum, or dump binary content.

const std = @import("std");
const zova = @import("zova");
const cli_options = @import("cli_options");
const sqlite = zova.sqlite;

pub const package_version = cli_options.package_version;

const ExitCode = struct {
    const ok: u8 = 0;
    const unexpected: u8 = 1;
    const usage: u8 = 2;
    const open: u8 = 3;
    const check_failed: u8 = 4;
};

const DeepStats = struct {
    objects: u64 = 0,
    chunks: u64 = 0,
    vectors: u64 = 0,
    loose_chunks: u64 = 0,
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len <= 1) {
        try writeUsage(stderr);
        return ExitCode.usage;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--version")) {
        if (args.len != 2) return usageError(stderr, "unexpected argument after --version");
        try stdout.print("zova {s}\n", .{package_version});
        return ExitCode.ok;
    }
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        if (args.len != 2) return usageError(stderr, "unexpected argument after help");
        try writeUsage(stdout);
        return ExitCode.ok;
    }
    if (std.mem.eql(u8, command, "info")) {
        return infoCommand(allocator, args[2..], stdout, stderr);
    }
    if (std.mem.eql(u8, command, "check")) {
        return checkCommand(allocator, args[2..], stdout, stderr);
    }

    try stderr.print("unknown command: {s}\n\n", .{command});
    try writeUsage(stderr);
    return ExitCode.usage;
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage:
        \\  zova --version
        \\  zova --help
        \\  zova info <file.zova>
        \\  zova check [--deep] <file.zova>
        \\
        \\commands:
        \\  info   print a bounded summary of a current-format Zova database
        \\  check  validate Zova identity/schema and SQLite quick_check
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

fn usageError(stderr: *std.Io.Writer, message: []const u8) !u8 {
    try stderr.print("usage error: {s}\n\n", .{message});
    try writeUsage(stderr);
    return ExitCode.usage;
}

fn infoCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (args.len != 1) return usageError(stderr, "info requires exactly one <file.zova>");
    const path = try allocator.dupeZ(u8, args[0]);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openError(stderr, "info", err);
    defer db.deinit();

    const format_version = try scalarTextAlloc(allocator, &db, "select value from _zova_meta where key = 'format_version'");
    defer allocator.free(format_version);
    const object_count = try scalarU64(&db, "select count(*) from _zova_objects");
    const chunk_count = try scalarU64(&db, "select count(*) from _zova_chunks");
    const manifest_count = try scalarU64(&db, "select count(*) from _zova_object_chunks");
    const loose_chunk_count = try scalarU64(&db,
        \\select count(*)
        \\from _zova_chunks c
        \\where not exists (
        \\  select 1 from _zova_object_chunks oc where oc.chunk_hash = c.chunk_hash
        \\)
    );
    const chunk_bytes = try scalarU64(&db, "select coalesce(sum(size_bytes), 0) from _zova_chunks");
    const vector_collection_count = try scalarU64(&db, "select count(*) from _zova_vector_collections");
    const vector_count = try scalarU64(&db, "select count(*) from _zova_vectors");
    const user_table_count = try scalarU64(&db,
        \\select count(*)
        \\from sqlite_master
        \\where type = 'table'
        \\  and substr(name, 1, 6) != '_zova_'
        \\  and substr(name, 1, 7) != 'sqlite_'
    );

    try stdout.print(
        \\Zova database: {s}
        \\package_version: {s}
        \\sqlite_version: {s}
        \\format_version: {s}
        \\objects: {d}
        \\chunks: {d}
        \\manifest_rows: {d}
        \\loose_chunks: {d}
        \\stored_chunk_bytes: {d}
        \\vector_collections: {d}
        \\vectors: {d}
        \\user_tables: {d}
        \\
    , .{
        args[0],
        package_version,
        sqlite.version(),
        format_version,
        object_count,
        chunk_count,
        manifest_count,
        loose_chunk_count,
        chunk_bytes,
        vector_collection_count,
        vector_count,
        user_table_count,
    });
    return ExitCode.ok;
}

fn checkCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var deep = false;
    var path_arg: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--deep")) {
            if (deep) return usageError(stderr, "duplicate --deep");
            deep = true;
        } else if (path_arg == null) {
            path_arg = arg;
        } else {
            return usageError(stderr, "check accepts only [--deep] <file.zova>");
        }
    }

    const raw_path = path_arg orelse return usageError(stderr, "check requires <file.zova>");
    const path = try allocator.dupeZ(u8, raw_path);
    defer allocator.free(path);

    var db = zova.Database.open(path) catch |err| return openError(stderr, "check", err);
    defer db.deinit();

    quickCheck(&db) catch |err| return checkError(stderr, "sqlite quick_check failed", err);
    try stdout.print("quick_check: ok\n", .{});

    if (deep) {
        const stats = deepCheck(allocator, &db) catch |err| return deepCheckError(stderr, err);
        try stdout.print(
            \\deep_check: ok
            \\objects_checked: {d}
            \\chunks_checked: {d}
            \\vectors_checked: {d}
            \\loose_chunks: {d}
            \\
        , .{ stats.objects, stats.chunks, stats.vectors, stats.loose_chunks });
    }

    try stdout.print("status: ok\n", .{});
    return ExitCode.ok;
}

fn openError(stderr: *std.Io.Writer, command: []const u8, err: anyerror) !u8 {
    try stderr.print("{s} open failed: {s}\n", .{ command, @errorName(err) });
    return ExitCode.open;
}

fn checkError(stderr: *std.Io.Writer, message: []const u8, err: anyerror) !u8 {
    try stderr.print("{s}: {s}\n", .{ message, @errorName(err) });
    return ExitCode.check_failed;
}

fn deepCheckError(stderr: *std.Io.Writer, err: anyerror) !u8 {
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
    try stderr.print("{s}: {s}\n", .{ label, @errorName(err) });
    return ExitCode.check_failed;
}

fn quickCheck(db: *zova.Database) !void {
    var stmt = try db.prepare("pragma quick_check");
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        if (!std.mem.eql(u8, stmt.columnText(0), "ok")) return error.CheckFailed;
    }
}

fn deepCheck(allocator: std.mem.Allocator, db: *zova.Database) !DeepStats {
    var stats = DeepStats{};
    try validateObjects(allocator, db, &stats);
    try validateLooseChunks(allocator, db, &stats);
    try validateVectors(allocator, db, &stats);
    return stats;
}

fn validateObjects(allocator: std.mem.Allocator, db: *zova.Database, stats: *DeepStats) !void {
    var stmt = try db.prepare("select object_id from _zova_objects order by hex(object_id)");
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const raw_id = stmt.columnBlob(0);
        if (raw_id.len != @sizeOf(zova.ObjectId)) return error.ObjectCorrupt;
        var id: zova.ObjectId = undefined;
        @memcpy(&id, raw_id);

        var manifest = try db.objectManifest(allocator, id);
        defer manifest.deinit(allocator);
        for (manifest.chunks) |chunk| {
            var chunk_data = try db.getObjectChunk(allocator, chunk.hash);
            defer chunk_data.deinit(allocator);
            stats.chunks += 1;
        }

        var object = try db.getObject(allocator, id);
        object.deinit(allocator);
        stats.objects += 1;
    }
}

fn validateLooseChunks(allocator: std.mem.Allocator, db: *zova.Database, stats: *DeepStats) !void {
    var stmt = try db.prepare(
        \\select c.chunk_hash
        \\from _zova_chunks c
        \\where not exists (
        \\  select 1 from _zova_object_chunks oc where oc.chunk_hash = c.chunk_hash
        \\)
        \\order by hex(c.chunk_hash)
    );
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const raw_hash = stmt.columnBlob(0);
        if (raw_hash.len != @sizeOf(zova.ObjectChunkId)) return error.ObjectCorrupt;
        var hash: zova.ObjectChunkId = undefined;
        @memcpy(&hash, raw_hash);

        var chunk = try db.getObjectChunk(allocator, hash);
        chunk.deinit(allocator);
        stats.loose_chunks += 1;
    }
}

fn validateVectors(allocator: std.mem.Allocator, db: *zova.Database, stats: *DeepStats) !void {
    var stmt = try db.prepare(
        \\select collection_name, vector_id
        \\from _zova_vectors
        \\order by collection_name, vector_id
    );
    defer stmt.deinit();

    while ((try stmt.step()) == .row) {
        const collection_name = stmt.columnText(0);
        const vector_id = stmt.columnText(1);
        var vector = try db.getVector(allocator, collection_name, vector_id);
        vector.deinit(allocator);
        stats.vectors += 1;
    }
}

fn scalarU64(db: *zova.Database, sql: [:0]const u8) !u64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    return switch (try stmt.step()) {
        .row => @intCast(stmt.columnInt64(0)),
        .done => 0,
    };
}

fn scalarTextAlloc(allocator: std.mem.Allocator, db: *zova.Database, sql: [:0]const u8) ![]u8 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    return switch (try stmt.step()) {
        .row => try allocator.dupe(u8, stmt.columnText(0)),
        .done => try allocator.dupe(u8, ""),
    };
}
