//! Storage-format migration steps and copy-forward member planning.

const std = @import("std");
const kv_impl = @import("../kv.zig");
const object_impl = @import("../object.zig");
const sqlite = @import("../sqlite.zig");

const DatabaseFormatInfo = @import("types.zig").DatabaseFormatInfo;
const Error = @import("types.zig").Error;
const MigrationStep = @import("types.zig").MigrationStep;
const backupMainDatabase = @import("backup.zig").backupMainDatabase;
const bound_graph_store_role = @import("types.zig").bound_graph_store_role;
const bound_object_store_role = @import("types.zig").bound_object_store_role;
const bound_stores_table = @import("types.zig").bound_stores_table;
const bound_vector_store_role = @import("types.zig").bound_vector_store_role;
const defaultIo = @import("paths.zig").defaultIo;
const ensurePathExists = @import("paths.zig").ensurePathExists;
const expectMetadataValue = @import("metadata.zig").expectMetadataValue;
const format_version = @import("types.zig").format_version;
const isZovaPath = @import("paths.zig").isZovaPath;
const magic_value = @import("types.zig").magic_value;
const metadataValueAlloc = @import("metadata.zig").metadataValueAlloc;
const parseFormatVersion = @import("format.zig").parseFormatVersion;
const readFormatClassification = @import("format.zig").readFormatClassification;
const tableExists = @import("metadata.zig").tableExists;
const validateExtensionSchema = @import("validation.zig").validateExtensionSchema;
const validateGraphSchema = @import("validation.zig").validateGraphSchema;
const validateGraphStoreDatabaseExpected = @import("validation.zig").validateGraphStoreDatabaseExpected;
const validateKvSchema = @import("validation.zig").validateKvSchema;
const validateObjectSchema = @import("validation.zig").validateObjectSchema;
const validateObjectSchemaExpected = @import("validation.zig").validateObjectSchemaExpected;
const validateObjectStoreDatabaseExpected = @import("validation.zig").validateObjectStoreDatabaseExpected;
const validateOptionalBoundStoreSchema = @import("validation.zig").validateOptionalBoundStoreSchema;
const validateVectorSchema = @import("validation.zig").validateVectorSchema;
const validateVectorStoreDatabaseExpected = @import("validation.zig").validateVectorStoreDatabaseExpected;

/// Probe one database's storage format without mutation.
///
/// The probe opens the file with a raw read-only SQLite connection, reads only
/// the historical identity metadata required for classification, and never
/// attaches bound stores, repairs schemas, or writes. Recognized but
/// incompatible databases probe successfully; malformed or non-Zova inputs are
/// rejected exactly as `Database.open` rejects them.
pub fn probeDatabaseFormat(path: [:0]const u8) Error!DatabaseFormatInfo {
    if (!isZovaPath(path)) return error.NotZovaPath;
    try ensurePathExists(path);

    var raw = sqlite.Database.openWithFlags(path, .read_only) catch |err| switch (err) {
        error.SqliteError => return error.NotZovaDatabase,
        else => return err,
    };
    defer raw.deinit();

    try expectMetadataValue(&raw, "magic", magic_value, .magic);
    return readFormatClassification(&raw);
}

pub const migration_steps = [_]MigrationStep{
    .{ .from_version = 9, .to_version = 10, .apply = migrateFormat9To10 },
    .{ .from_version = 10, .to_version = 11, .apply = migrateFormat10To11 },
};

pub fn findMigrationStep(from_version: u32, to_version: u32) ?*const MigrationStep {
    for (&migration_steps) |*step| {
        if (step.from_version == from_version and step.to_version == to_version) return step;
    }
    return null;
}

fn migrateFormat9To10(db: *sqlite.Database) Error!void {
    // Format 10 introduces the private key-value schema. Extension-owned
    // tables are left unchanged; normal open-time extension compatibility
    // validation applies after migration.
    try db.exec(kv_impl.kv_schema_sql);
    try validateKvSchema(db);
}

fn migrateFormat10To11(db: *sqlite.Database) Error!void {
    // Rename the format-10 tables out of the way first, then create the final
    // format-11 tables from their canonical schema declarations. This keeps
    // sqlite_master text identical to a newly-created format-11 database and
    // lets the whole rebuild roll back atomically with the migration step.
    try db.exec(
        \\alter table _zova_object_chunks rename to _zova_object_chunks_format10;
        \\alter table _zova_objects rename to _zova_objects_format10;
        \\alter table _zova_chunks rename to _zova_chunks_format10;
    );

    try db.exec(object_impl.objects_schema_sql);
    try db.exec(object_impl.chunks_schema_sql);
    try db.exec(object_impl.object_chunks_schema_sql);

    try db.exec(
        \\insert into _zova_objects(object_id,size_bytes,chunk_count,chunker)
        \\select object_id,size_bytes,chunk_count,chunker from _zova_objects_format10;
        \\insert into _zova_chunks(chunk_hash,size_bytes,data)
        \\select chunk_hash,size_bytes,data from _zova_chunks_format10;
        \\insert into _zova_object_chunks(object_id,chunk_index,chunk_hash,offset,size_bytes)
        \\select object_id,chunk_index,chunk_hash,offset,size_bytes from _zova_object_chunks_format10;
        \\drop table _zova_object_chunks_format10;
        \\drop table _zova_objects_format10;
        \\drop table _zova_chunks_format10;
    );

    try validateObjectSchema(db);
}

/// Role-aware validation of one Zova file at an exact expected storage
/// format, structurally equivalent to the existing open-time and attach-time
/// validators while intentionally omitting only requirements introduced by
/// later formats (currently the format-10 private key-value schema that
/// migration itself adds).
///
/// Used by migration preflight so a forged or malformed file — wrong or
/// missing magic, missing metadata, malformed required tables, a store role
/// without its identity or schema, or a main with a malformed bound-store
/// table — can never be transformed. Object and KV validation is selected by
/// the exact source format so every adjacent step validates the schema that
/// actually existed at that version.
pub fn validateMigrationSourceSchema(db: *sqlite.Database, expected_format: []const u8) Error!void {
    if (try metadataValueAlloc(std.heap.c_allocator, db, "store_role")) |role| {
        defer std.heap.c_allocator.free(role);

        if (std.mem.eql(u8, role, bound_object_store_role)) {
            return validateObjectStoreDatabaseExpected(db, expected_format);
        }
        if (std.mem.eql(u8, role, bound_vector_store_role)) {
            return validateVectorStoreDatabaseExpected(db, expected_format);
        }
        if (std.mem.eql(u8, role, bound_graph_store_role)) {
            return validateGraphStoreDatabaseExpected(db, expected_format);
        }
        return error.NotZovaDatabase;
    }

    const expected_version = parseFormatVersion(expected_format) orelse return error.NotZovaDatabase;

    // Main database: every private schema plus the optional bound-store
    // table, with version-specific object and KV requirements.
    try expectMetadataValue(db, "magic", magic_value, .magic);
    try expectMetadataValue(db, "format_version", expected_format, .format_version);
    try validateExtensionSchema(db);
    try validateObjectSchemaExpected(db, expected_format);
    try validateVectorSchema(db);
    try validateGraphSchema(db);
    if (expected_version >= 10) try validateKvSchema(db);
    try validateOptionalBoundStoreSchema(db);
}

/// Apply the single registered adjacent migration step for this database's
/// storage format and return the new version.
///
/// The exact expected source identity, version, role, and schema are validated
/// after `BEGIN IMMEDIATE` so validation and mutation share one stable
/// transaction. Schema work happens first, `_zova_meta.format_version` is
/// updated as the final statement, and every failure path rolls back
/// completely so the version never advances on SQL, allocation, constraint,
/// or validation failure.
pub fn runMigrationStep(db: *sqlite.Database) Error!u32 {
    const info = try readFormatClassification(db);

    const current = parseFormatVersion(format_version) orelse unreachable;
    const target = std.math.add(u32, info.format_version, 1) catch return error.NoMigrationPath;
    if (target > current or info.compatibility != .migratable) return error.NoMigrationPath;

    const step = findMigrationStep(info.format_version, target) orelse return error.NoMigrationPath;

    var format_buffer: [16]u8 = undefined;
    const expected_format = std.fmt.bufPrint(&format_buffer, "{d}", .{info.format_version}) catch unreachable;

    try db.beginImmediate();
    errdefer db.rollback() catch {};

    try validateMigrationSourceSchema(db, expected_format);

    try step.apply(db);

    var version_buffer: [16]u8 = undefined;
    const version_text = std.fmt.bufPrint(&version_buffer, "{d}", .{target}) catch unreachable;
    {
        var update = try db.prepare("update _zova_meta set value = ?1 where key = 'format_version'");
        defer update.deinit();
        try update.bindText(1, version_text);
        _ = try update.step();
    }

    // Metadata is the final mutation. Structural and referential validation
    // run afterward inside the same transaction and therefore still roll the
    // complete step back on failure.
    try validateMigrationSourceSchema(db, version_text);
    try validateForeignKeys(db);

    try db.commit();
    return target;
}

pub fn runMigrationsToCurrent(db: *sqlite.Database) Error!void {
    const current = parseFormatVersion(format_version) orelse unreachable;
    while (true) {
        const info = try readFormatClassification(db);
        if (info.format_version == current and info.compatibility == .current) return;
        if (info.compatibility != .migratable) return error.NoMigrationPath;
        _ = try runMigrationStep(db);
    }
}

fn validateForeignKeys(db: *sqlite.Database) Error!void {
    var stmt = try db.prepare("pragma foreign_key_check");
    defer stmt.deinit();
    if ((try stmt.step()) != .done) return error.NotZovaDatabase;
}

/// One planned bound-store member of a migration set.
///
/// `role` and `suffix` are static strings; the other five fields are owned.
pub const MigrateBindingPlan = struct {
    role: []const u8,
    suffix: []const u8,
    /// Role-specific epoch name shared by the binding row column and the
    /// store file's identity metadata key.
    epoch_key: []const u8,
    store_path: [:0]u8,
    store_id: []u8,
    bound_set_id: []u8,
    final_path: [:0]u8,
    staging_path: [:0]u8,
    /// True once this attempt created the destination placeholder; pre-existing
    /// destinations are never removed by cleanup.
    reserved: bool = false,
    /// True once this attempt exclusively created the staging file; cleanup
    /// only ever removes staging files this attempt owns.
    staged: bool = false,
    epoch: u64,

    pub fn deinit(self: *MigrateBindingPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.store_path);
        allocator.free(self.store_id);
        allocator.free(self.bound_set_id);
        allocator.free(self.final_path);
        allocator.free(self.staging_path);
    }
};

/// Collect the main database's bound-store rows, if any. Single-file mains
/// produce zero bindings.
pub fn collectMigrationBindings(
    allocator: std.mem.Allocator,
    source_path: [:0]const u8,
    out: *[3]MigrateBindingPlan,
    count: *usize,
) Error!void {
    count.* = 0;

    var raw = try sqlite.Database.openWithFlags(source_path, .read_only);
    defer raw.deinit();
    if (!try tableExists(&raw, bound_stores_table)) return;

    inline for (.{
        .{ .role = bound_object_store_role, .suffix = "objects", .epoch_key = "object_epoch" },
        .{ .role = bound_vector_store_role, .suffix = "vectors", .epoch_key = "vector_epoch" },
        .{ .role = bound_graph_store_role, .suffix = "graphs", .epoch_key = "graph_epoch" },
    }) |entry| {
        const binding_sql = "select path, store_id, bound_set_id, " ++ entry.epoch_key ++ " from _zova_bound_stores where role = '" ++ entry.role ++ "' and name = 'default'";
        var stmt = try raw.prepare(binding_sql);
        defer stmt.deinit();

        if ((try stmt.step()) == .row) {
            const epoch_value = stmt.columnInt64(3);
            if (epoch_value < 0) return error.BoundStoreInvalid;
            const store_path = try allocator.dupeZ(u8, stmt.columnText(0));
            errdefer allocator.free(store_path);
            const store_id = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(store_id);
            const bound_set_id = try allocator.dupe(u8, stmt.columnText(2));
            errdefer allocator.free(bound_set_id);
            const final_path = try allocator.dupeZ(u8, "");
            errdefer allocator.free(final_path);
            const staging_path = try allocator.dupeZ(u8, "");
            errdefer allocator.free(staging_path);
            out[count.*] = .{
                .role = entry.role,
                .suffix = entry.suffix,
                .epoch_key = entry.epoch_key,
                .store_path = store_path,
                .store_id = store_id,
                .bound_set_id = bound_set_id,
                .epoch = @intCast(epoch_value),
                .final_path = final_path,
                .staging_path = staging_path,
            };
            count.* += 1;
        }
    }
}

/// Validate one recorded bound store before any copying: the file must exist,
/// carry a genuine migratable format-9 schema under its role, and its stored
/// identity must match the main database's binding row exactly.
pub fn validateMigrationStoreBinding(
    binding: *MigrateBindingPlan,
    expected_format: []const u8,
) Error!void {
    var store = sqlite.Database.openWithFlags(binding.store_path, .read_only) catch |err| switch (err) {
        error.CantOpen, error.SqliteError => return error.BoundStoreNotFound,
        else => return err,
    };
    defer store.deinit();

    const store_role = (try metadataValueAlloc(std.heap.c_allocator, &store, "store_role")) orelse return error.BoundStoreInvalid;
    defer std.heap.c_allocator.free(store_role);
    if (!std.mem.eql(u8, store_role, binding.role)) return error.BoundStoreInvalid;

    try validateMigrationSourceSchema(&store, expected_format);

    const store_id = (try metadataValueAlloc(std.heap.c_allocator, &store, "store_id")) orelse return error.BoundStoreInvalid;
    defer std.heap.c_allocator.free(store_id);
    if (!std.mem.eql(u8, store_id, binding.store_id)) return error.BoundStoreInvalid;

    const bound_set_id = (try metadataValueAlloc(std.heap.c_allocator, &store, "bound_set_id")) orelse return error.BoundStoreInvalid;
    defer std.heap.c_allocator.free(bound_set_id);
    if (!std.mem.eql(u8, bound_set_id, binding.bound_set_id)) return error.BoundStoreInvalid;

    const epoch_text = (try metadataValueAlloc(std.heap.c_allocator, &store, binding.epoch_key)) orelse return error.BoundStoreInvalid;
    defer std.heap.c_allocator.free(epoch_text);
    const stored_epoch = std.fmt.parseInt(u64, epoch_text, 10) catch return error.BoundStoreInvalid;
    if (stored_epoch != binding.epoch) return error.BoundStoreInvalid;
}

/// Copy one source member forward into a fresh staging file. Migration of the
/// staged copy is a separate step so each phase has its own fault boundary.
pub fn copyForwardMember(source: *sqlite.Database, staging_path: [:0]const u8) Error!void {
    var staged = try sqlite.Database.open(staging_path);
    defer staged.deinit();
    try backupMainDatabase(source, &staged);
}

const MigrateRebindTarget = enum { staging, final };

/// Rewrite only the destination binding paths in a staged main database.
pub fn rebindMigrationSet(
    staged_main_path: [:0]const u8,
    bindings: []MigrateBindingPlan,
    target: MigrateRebindTarget,
) Error!void {
    var staged = try sqlite.Database.open(staged_main_path);
    defer staged.deinit();

    for (bindings) |*binding| {
        const destination = switch (target) {
            .staging => binding.staging_path,
            .final => binding.final_path,
        };
        var update = try staged.prepare("update _zova_bound_stores set path = ?1 where role = ?2 and name = 'default'");
        defer update.deinit();
        try update.bindText(1, destination);
        try update.bindText(2, binding.role);
        _ = try update.step();
    }
}

/// Derive a destination sibling name `<stem>.<suffix>.zova` from a
/// destination whose name ends in `.zova`.
pub fn migrationSiblingPath(allocator: std.mem.Allocator, destination_path: []const u8, suffix: []const u8) Error![:0]u8 {
    const stem = destination_path[0 .. destination_path.len - ".zova".len];
    const length = stem.len + 1 + suffix.len + ".zova".len;
    const buffer = allocator.allocSentinel(u8, length, 0) catch return error.OutOfMemory;
    errdefer allocator.free(buffer);
    _ = std.fmt.bufPrint(buffer[0..length], "{s}.{s}.zova", .{ stem, suffix }) catch unreachable;
    return buffer;
}

/// Derive a unique hidden same-directory staging path for one final path.
///
/// Staging names keep the `.zova` extension so the staged set can be verified
/// through the full open path before publication.
/// Derive and exclusively create one staging file, retrying with fresh random
/// names on collision so a pre-existing caller file can never be opened or
/// deleted by this attempt.
pub fn reserveMigrationStagingPath(allocator: std.mem.Allocator, final_path: []const u8) Error![:0]u8 {
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        const candidate = try migrationStagingPath(allocator, final_path);
        var file = std.Io.Dir.cwd().createFile(defaultIo(), candidate, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(candidate);
                continue;
            },
            else => {
                allocator.free(candidate);
                return error.CantOpen;
            },
        };
        file.close(defaultIo());
        return candidate;
    }
    return error.CantOpen;
}

fn migrationStagingPath(allocator: std.mem.Allocator, final_path: []const u8) Error![:0]u8 {
    const dirname = std.fs.path.dirname(final_path) orelse "";
    const basename = std.fs.path.basename(final_path);
    const stem = basename[0 .. basename.len - ".zova".len];

    var random_bytes: [8]u8 = undefined;
    sqlite.c.sqlite3_randomness(random_bytes.len, &random_bytes);
    const hex_alphabet = "0123456789abcdef";
    var hex: [16]u8 = undefined;
    for (0..16) |index| {
        hex[index] = hex_alphabet[random_bytes[index / 2] % 16];
        if (index % 2 == 1) random_bytes[index / 2] /= 16;
    }

    // Hidden same-directory name keeping the `.zova` extension so staged sets
    // pass full open validation before publication.
    const prefix_len = dirname.len + (if (dirname.len != 0) @as(usize, 1) else 0) + 1 + stem.len + ".migrate-".len + hex.len + ".zova".len;
    const buffer = allocator.allocSentinel(u8, prefix_len, 0) catch return error.OutOfMemory;
    errdefer allocator.free(buffer);
    if (dirname.len == 0) {
        _ = std.fmt.bufPrint(buffer[0..prefix_len], ".{s}.migrate-{s}.zova", .{ stem, hex }) catch unreachable;
    } else {
        _ = std.fmt.bufPrint(buffer[0..prefix_len], "{s}/.{s}.migrate-{s}.zova", .{ dirname, stem, hex }) catch unreachable;
    }
    return buffer;
}
