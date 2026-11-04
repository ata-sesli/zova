//! Storage-format migration steps and copy-forward member planning.

const std = @import("std");
const kv_impl = @import("../kv.zig");
const object_impl = @import("../object.zig");
const sqlite = @import("../sqlite.zig");

const DatabaseFormatInfo = @import("types.zig").DatabaseFormatInfo;
const FormatCompatibility = @import("types.zig").FormatCompatibility;
const Registry = @import("types.zig").ExtensionRegistry;
const ensureDestinationZovaPathAvailable = @import("paths.zig").ensureDestinationZovaPathAvailable;
const ensureSourcePathExists = @import("paths.zig").ensureSourcePathExists;
const extension_impl = @import("../extension.zig");
const Error = @import("types.zig").Error;
const MigrationStep = @import("types.zig").MigrationStep;
const backupMainDatabaseReporting = @import("backup.zig").backupMainDatabaseReporting;
const ProgressCallback = @import("types.zig").ProgressCallback;
const ProgressMember = @import("types.zig").ProgressMember;
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
    .{ .from_version = 11, .to_version = 12, .apply = migrateFormat11To12 },
    .{ .from_version = 12, .to_version = 13, .apply = migrateFormat12To13 },
};

fn migrateFormat12To13(db: *sqlite.Database) Error!void {
    // Every Zova file role carries the object tables. The step only adds the
    // chunk-reference index; the file keeps its `auto_vacuum` mode, and
    // `compactTo` is the conversion path to incremental mode.
    if (try tableExists(db, object_impl.object_chunks_table)) try db.exec(object_impl.object_chunks_chunk_hash_index_sql);
}

fn migrateFormat11To12(db: *sqlite.Database) Error!void {
    // Object/graph stores have no vector source. Main and vector-store files
    // initialize history in the very same file as their authoritative vectors.
    if (try tableExists(db, "_zova_vector_collections")) try @import("../vector_maintenance.zig").initialize(db);
}

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

    try @import("validation.zig").validateObjectSchemaExpected(db, "11");
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
    try @import("validation.zig").validateVectorSchemaExpected(db, expected_format);
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
    return runMigrationsToCurrentReporting(db, null, .main);
}

/// Run every migration step, reporting `migrate` progress for `member` before
/// the first step and after each committed step.
pub fn runMigrationsToCurrentReporting(db: *sqlite.Database, progress: ?ProgressCallback, member: ProgressMember) Error!void {
    const current = parseFormatVersion(format_version) orelse unreachable;
    const start = try readFormatClassification(db);
    const total: u64 = if (start.format_version < current) current - start.format_version else 0;
    var done: u64 = 0;
    try ProgressCallback.emit(progress, .{ .phase = .migrate, .member = member, .done = done, .total = total });
    while (true) {
        const info = try readFormatClassification(db);
        if (info.format_version == current and info.compatibility == .current) return;
        if (info.compatibility != .migratable) return error.NoMigrationPath;
        _ = try runMigrationStep(db);
        done = @min(done + 1, total);
        try ProgressCallback.emit(progress, .{ .phase = .migrate, .member = member, .done = done, .total = total });
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
            const store_path = try allocator.dupeSentinel(u8, stmt.columnText(0), 0);
            errdefer allocator.free(store_path);
            const store_id = try allocator.dupe(u8, stmt.columnText(1));
            errdefer allocator.free(store_id);
            const bound_set_id = try allocator.dupe(u8, stmt.columnText(2));
            errdefer allocator.free(bound_set_id);
            const final_path = try allocator.dupeSentinel(u8, "", 0);
            errdefer allocator.free(final_path);
            const staging_path = try allocator.dupeSentinel(u8, "", 0);
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
pub fn copyForwardMember(
    source: *sqlite.Database,
    staging_path: [:0]const u8,
    progress: ?ProgressCallback,
    member: ProgressMember,
) Error!void {
    var staged = try sqlite.Database.open(staging_path);
    defer staged.deinit();
    try backupMainDatabaseReporting(source, &staged, progress, member);
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

/// Classify a migration source with a raw read-only connection, before any
/// destination is touched.
pub fn classifyMigrationSource(source_path: [:0]const u8) Error!DatabaseFormatInfo {
    var probe = try sqlite.Database.openWithFlags(source_path, .read_only);
    defer probe.deinit();
    return readFormatClassification(&probe);
}

/// Only migratable formats have a path to the current format.
pub fn requireMigratable(compatibility: FormatCompatibility) Error!void {
    switch (compatibility) {
        .migratable => {},
        .current => return error.NoMigrationPath,
        .unsupported_legacy => return error.UnsupportedLegacyFormat,
        .unsupported_future => return error.UnsupportedFutureFormat,
    }
}

/// Preflight the whole set before copying: the exact source schema plus every
/// recorded store's identity, role, epoch, schema, and cross-checked IDs.
pub fn preflightMigrationSet(
    source_path: [:0]const u8,
    source_format_version: u32,
    bindings: []MigrateBindingPlan,
) Error!void {
    var snapshot = try sqlite.Database.openWithFlags(source_path, .read_only);
    defer snapshot.deinit();
    var source_format_buffer: [16]u8 = undefined;
    const source_format_text = std.fmt.bufPrint(&source_format_buffer, "{d}", .{source_format_version}) catch unreachable;
    try validateMigrationSourceSchema(&snapshot, source_format_text);
    for (bindings) |*binding| try validateMigrationStoreBinding(binding, source_format_text);
}

/// Result of the source-schema and bound-store preflight in a migration plan.
pub const MigrationPreflight = enum {
    passed,
    failed,
    /// Not run because an earlier check already rules the migration out.
    skipped,
};

/// SQLite page counts of one source member. Migration copies every page,
/// free pages included, so the staged copy is `copyBytes()` before any
/// format step runs.
pub const MigrationMemberSizes = struct {
    page_size: u64,
    page_count: u64,
    freelist_count: u64,

    pub fn copyBytes(self: MigrationMemberSizes) u64 {
        return self.page_count * self.page_size;
    }

    pub fn freeBytes(self: MigrationMemberSizes) u64 {
        return self.freelist_count * self.page_size;
    }
};

/// One file a migration would write: the main database or a bound store.
pub const MigrationPlanMember = struct {
    /// "main", "objects", "vectors" or "graphs"; static.
    role: []const u8,
    source_path: [:0]u8,
    destination_path: [:0]u8,
    destination_exists: bool = false,
    /// Null when the source member cannot be read.
    sizes: ?MigrationMemberSizes = null,

    fn deinit(self: *MigrationPlanMember, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.destination_path);
    }
};

/// One extension installed in the source main database.
pub const MigrationPlanExtension = struct {
    name: []u8,
    version: []u8,
    /// Shipped inside Zova itself, so no bundle is ever needed.
    bundled: bool,
    /// Null when the supplied registry satisfies the extension exactly as
    /// verification's open would; otherwise the error that open returns.
    availability: ?Error,

    fn deinit(self: *MigrationPlanExtension, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
    }
};

/// What a migration would copy and whether its checks pass, produced without
/// creating or modifying anything. See `planMigrationSet`.
pub const MigrationPlan = struct {
    source_format: u32,
    target_format: u32,
    compatibility: FormatCompatibility,
    verify: bool,
    members: []MigrationPlanMember,
    recovery_directory: [:0]u8,
    recovery_directory_exists: bool,
    extensions: []MigrationPlanExtension,
    preflight: MigrationPreflight,
    /// The first error a real migration would return from the checks the plan
    /// repeats, in the real migration's order; null when all pass. Disk space
    /// and the copy itself are not part of it.
    failure: ?Error,

    /// Bytes the copy writes across every member, before format steps run.
    pub fn copyBytes(self: MigrationPlan) u64 {
        var total: u64 = 0;
        for (self.members) |member| {
            if (member.sizes) |sizes| total += sizes.copyBytes();
        }
        return total;
    }

    pub fn deinit(self: *MigrationPlan, allocator: std.mem.Allocator) void {
        for (self.members) |*member| member.deinit(allocator);
        allocator.free(self.members);
        for (self.extensions) |*item| item.deinit(allocator);
        allocator.free(self.extensions);
        allocator.free(self.recovery_directory);
        self.* = undefined;
    }
};

/// Plan a migration with the same classification, binding collection,
/// destination naming and preflight code `migrateDatabaseInternal` runs, but
/// read-only: no destination, sibling, staging file or recovery directory is
/// created and the source is never written. Path and source-existence errors
/// are returned; every later check is recorded in `failure`.
///
/// The source is not locked, so the plan describes the set as it is now.
pub fn planMigrationSet(
    allocator: std.mem.Allocator,
    source_path: [:0]const u8,
    destination_path: [:0]const u8,
    verify: bool,
    registry: Registry,
    bundled_registry: Registry,
) Error!MigrationPlan {
    if (!isZovaPath(source_path)) return error.NotZovaPath;
    if (!isZovaPath(destination_path)) return error.NotZovaPath;
    try ensureSourcePathExists(source_path);
    const info = try classifyMigrationSource(source_path);

    var failure: ?Error = null;
    requireMigratable(info.compatibility) catch |err| {
        failure = err;
    };

    var bindings: [3]MigrateBindingPlan = undefined;
    var binding_count: usize = 0;
    defer for (bindings[0..binding_count]) |*binding| binding.deinit(allocator);
    var bindings_collected = true;
    collectMigrationBindings(allocator, source_path, &bindings, &binding_count) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            bindings_collected = false;
            if (failure == null) failure = err;
        },
    };

    var members: std.ArrayList(MigrationPlanMember) = .empty;
    defer {
        for (members.items) |*member| member.deinit(allocator);
        members.deinit(allocator);
    }
    try members.ensureTotalCapacity(allocator, 1 + binding_count);
    {
        const source = try allocator.dupeSentinel(u8, source_path, 0);
        errdefer allocator.free(source);
        const destination = try allocator.dupeSentinel(u8, destination_path, 0);
        members.appendAssumeCapacity(.{ .role = "main", .source_path = source, .destination_path = destination });
    }
    for (bindings[0..binding_count]) |*binding| {
        const source = try allocator.dupeSentinel(u8, binding.store_path, 0);
        errdefer allocator.free(source);
        const destination = try migrationSiblingPath(allocator, destination_path, binding.suffix);
        members.appendAssumeCapacity(.{ .role = binding.suffix, .source_path = source, .destination_path = destination });
    }
    for (members.items) |*member| member.sizes = readMemberSizes(member.source_path) catch null;

    // Destination checks in the real migration's order: main, the recovery
    // directory, then each sibling.
    const recovery_directory = try @import("migration_publication.zig").recoveryDirectoryPath(allocator, destination_path);
    errdefer allocator.free(recovery_directory);
    const recovery_directory_exists = pathExists(recovery_directory);
    for (members.items, 0..) |*member, index| {
        ensureDestinationZovaPathAvailable(member.destination_path) catch |err| {
            if (err == error.DestinationExists) member.destination_exists = true;
            if (failure == null) failure = err;
        };
        if (index == 0 and recovery_directory_exists and failure == null) failure = error.DestinationExists;
    }

    var preflight: MigrationPreflight = .skipped;
    if (info.compatibility == .migratable and bindings_collected) {
        if (preflightMigrationSet(source_path, info.format_version, bindings[0..binding_count])) |_| {
            preflight = .passed;
        } else |err| {
            if (err == error.OutOfMemory) return err;
            preflight = .failed;
            if (failure == null) failure = err;
        }
    }

    const extensions = try planExtensions(allocator, source_path, registry, bundled_registry, verify, &failure);
    errdefer {
        for (extensions) |*item| item.deinit(allocator);
        allocator.free(extensions);
    }
    const member_slice = try members.toOwnedSlice(allocator);

    return .{
        .source_format = info.format_version,
        .target_format = parseFormatVersion(format_version) orelse unreachable,
        .compatibility = info.compatibility,
        .verify = verify,
        .members = member_slice,
        .recovery_directory = recovery_directory,
        .recovery_directory_exists = recovery_directory_exists,
        .extensions = extensions,
        .preflight = preflight,
        .failure = failure,
    };
}

/// Report every installed extension against the supplied registry. Verification
/// opens the migrated main with that registry, so with `verify` an unavailable
/// extension is a migration failure; without it no extension code is loaded.
fn planExtensions(
    allocator: std.mem.Allocator,
    source_path: [:0]const u8,
    registry: Registry,
    bundled_registry: Registry,
    verify: bool,
    failure: *?Error,
) Error![]MigrationPlanExtension {
    var raw = try sqlite.Database.openWithFlags(source_path, .read_only);
    defer raw.deinit();
    var installed = extension_impl.listInstalled(allocator, &raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (failure.* == null) failure.* = err;
            return allocator.alloc(MigrationPlanExtension, 0);
        },
    };
    defer installed.deinit(allocator);

    const registry_error: ?Error = if (registry.validate()) |_| null else |err| err;
    var result: std.ArrayList(MigrationPlanExtension) = .empty;
    errdefer {
        for (result.items) |*item| item.deinit(allocator);
        result.deinit(allocator);
    }
    try result.ensureTotalCapacity(allocator, installed.items.len);
    for (installed.items) |item| {
        const availability: ?Error = registry_error orelse
            if (extension_impl.ensureAvailable(registry, item)) |_| null else |err| err;
        if (verify and availability != null and failure.* == null) failure.* = availability;
        const name = try allocator.dupe(u8, item.name);
        errdefer allocator.free(name);
        const version_text = try allocator.dupe(u8, item.version);
        result.appendAssumeCapacity(.{
            .name = name,
            .version = version_text,
            .bundled = bundled_registry.find(item.name) != null,
            .availability = availability,
        });
    }
    return result.toOwnedSlice(allocator);
}

fn readMemberSizes(path: [:0]const u8) Error!MigrationMemberSizes {
    var db = try sqlite.Database.openWithFlags(path, .read_only);
    defer db.deinit();
    return .{
        .page_size = try pragmaCount(&db, "pragma page_size"),
        .page_count = try pragmaCount(&db, "pragma page_count"),
        .freelist_count = try pragmaCount(&db, "pragma freelist_count"),
    };
}

fn pragmaCount(db: *sqlite.Database, sql: [:0]const u8) Error!u64 {
    var stmt = try db.prepare(sql);
    defer stmt.deinit();
    if ((try stmt.step()) != .row) return error.NotZovaDatabase;
    const value = stmt.columnInt64(0);
    if (value < 0) return error.NotZovaDatabase;
    return @intCast(value);
}

fn pathExists(path: []const u8) bool {
    const io = defaultIo();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
