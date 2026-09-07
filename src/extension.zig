//! Private extension host foundation.
//!
//! Extension code is process-provided. A database may record installed
//! extensions, but it never stores executable paths and never auto-loads code.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const zova_version = @import("version.zig");
const plugin = @import("extension_plugin.zig");

pub const extensions_table = "_zova_extensions";
pub const storage_prefix_prefix = "_zova_ext_";

pub const extensions_schema_sql =
    \\create table _zova_extensions (
    \\  name text primary key,
    \\  version text not null,
    \\  storage_prefix text not null,
    \\  zova_abi_min text not null,
    \\  capabilities text not null,
    \\  required integer not null check (required in (0, 1)),
    \\  installed_at_unix integer not null,
    \\  manifest_json text not null default ''
    \\)
;

pub const Error = sqlite.Error || error{
    ExtensionNotFound,
    ExtensionExists,
    ExtensionInvalid,
    ExtensionIncompatible,
    ExtensionUnavailable,
    OutOfMemory,
};

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    storage_prefix: []const u8,
    zova_abi_min: []const u8,
    capabilities: []const u8 = "",
    required: bool = true,
    manifest_json: []const u8 = "",
};

pub const Hook = *const fn (*sqlite.Database, Manifest) Error!void;
pub const ValidationHook = *const fn (*sqlite.Database) anyerror!void;

pub const SalvageMode = enum {
    plan,
    copy,
};

pub const SalvageContext = struct {
    allocator: std.mem.Allocator,
    source: *sqlite.Database,
    destination: ?*sqlite.Database,
    mode: SalvageMode,
};

pub const SalvageResult = struct {
    copied_extensions: u64 = 0,
    copied_private_objects: u64 = 0,
    skipped_extensions: u64 = 0,
    skipped_private_objects: u64 = 0,
    installed_in_destination: bool = false,

    fn add(self: *SalvageResult, other: SalvageResult) void {
        self.copied_extensions += other.copied_extensions;
        self.copied_private_objects += other.copied_private_objects;
        self.skipped_extensions += other.skipped_extensions;
        self.skipped_private_objects += other.skipped_private_objects;
        self.installed_in_destination = self.installed_in_destination or other.installed_in_destination;
    }
};

pub const SalvageHook = *const fn (SalvageContext, Manifest) Error!SalvageResult;

pub const Extension = struct {
    manifest: Manifest,
    install: Hook,
    check: Hook,
    drop: Hook,
    register_sql: ?Hook = null,
    salvage: ?SalvageHook = null,
};

pub const Registry = struct {
    extensions: []const Extension = &.{},
    plugins: []const plugin.Descriptor = &.{},
    upgrades: []const Upgrade = &.{},

    fn invoke(self: Registry, item: Extension, db: *sqlite.Database, phase: plugin.Phase) Error!void {
        for (self.plugins) |descriptor| {
            if (std.mem.eql(u8, item.manifest.name, std.mem.span(descriptor.name.?))) {
                return plugin.invoke(descriptor, phase, db);
            }
        }
        switch (phase) {
            .install => try item.install(db, item.manifest),
            .check => try item.check(db, item.manifest),
            .drop => try item.drop(db, item.manifest),
            .register_sql => if (item.register_sql) |hook| try hook(db, item.manifest),
        }
    }

    pub fn init(extensions: []const Extension) Registry {
        return .{ .extensions = extensions };
    }

    pub fn empty() Registry {
        return .{};
    }

    pub fn find(self: Registry, name: []const u8) ?Extension {
        for (self.extensions) |extension| {
            if (std.mem.eql(u8, extension.manifest.name, name)) return extension;
        }
        return null;
    }

    pub fn validate(self: Registry) Error!void {
        for (self.upgrades, 0..) |path, i| {
            const target = self.find(path.name) orelse return error.ExtensionUnavailable;
            if (!std.mem.eql(u8, target.manifest.version, path.to_version)) return error.ExtensionIncompatible;
            try validateUpgradeDirection(path.from_version, path.to_version);
            if ((path.hook == null) == (path.plugin_hook == null)) return error.ExtensionInvalid;
            for (self.upgrades[0..i]) |previous| {
                if (std.mem.eql(u8, previous.name, path.name) and std.mem.eql(u8, previous.from_version, path.from_version)) return error.ExtensionInvalid;
            }
        }
        for (self.plugins, 0..) |*descriptor, i| {
            const item = try plugin.validate(descriptor);
            const registered = self.find(item.manifest.name) orelse return error.ExtensionInvalid;
            if (!std.mem.eql(u8, registered.manifest.storage_prefix, item.manifest.storage_prefix)) return error.ExtensionInvalid;
            for (self.plugins[0..i]) |previous| {
                if (std.mem.eql(u8, std.mem.span(previous.name.?), item.manifest.name)) return error.ExtensionInvalid;
            }
        }
        for (self.extensions, 0..) |extension, index| {
            try validateManifest(extension.manifest);
            for (self.extensions[0..index]) |previous| {
                if (std.mem.eql(u8, previous.manifest.name, extension.manifest.name)) {
                    return error.ExtensionInvalid;
                }
                if (std.mem.eql(u8, previous.manifest.storage_prefix, extension.manifest.storage_prefix)) {
                    return error.ExtensionInvalid;
                }
            }
        }
    }
};

pub const InstalledInfo = struct {
    name: []u8,
    version: []u8,
    storage_prefix: []u8,
    zova_abi_min: []u8,
    capabilities: []u8,
    required: bool,
    installed_at_unix: i64,
    manifest_json: []u8,

    pub fn deinit(self: *InstalledInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.storage_prefix);
        allocator.free(self.zova_abi_min);
        allocator.free(self.capabilities);
        allocator.free(self.manifest_json);
    }
};

pub const InstalledList = struct {
    items: []InstalledInfo,

    pub fn deinit(self: *InstalledList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

const SchemaObjectList = struct {
    names: [][]u8,

    fn deinit(self: *SchemaObjectList, allocator: std.mem.Allocator) void {
        for (self.names) |name| allocator.free(name);
        allocator.free(self.names);
    }
};

pub fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > 64) return error.ExtensionInvalid;
    if (hasReservedZovaPrefix(name)) return error.ExtensionInvalid;
    for (name) |byte| {
        if (!isExtensionNameByte(byte)) return error.ExtensionInvalid;
    }
}

pub fn validateStoragePrefix(name: []const u8, prefix: []const u8) Error!void {
    try validateName(name);
    var expected_buffer: [storage_prefix_prefix.len + 64 + 1]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buffer, "{s}{s}_", .{ storage_prefix_prefix, name }) catch unreachable;
    if (!std.mem.eql(u8, prefix, expected)) return error.ExtensionInvalid;
}

pub fn validateManifest(manifest: Manifest) Error!void {
    try validateName(manifest.name);
    if (manifest.version.len == 0 or manifest.version.len > 64) return error.ExtensionInvalid;
    const minimum_abi = try parseAbiVersion(manifest.zova_abi_min);
    if (minimum_abi.major != zova_version.abi_version_major or
        minimum_abi.minor > zova_version.abi_version_minor or
        (minimum_abi.minor == zova_version.abi_version_minor and
            minimum_abi.patch > zova_version.abi_version_patch))
    {
        return error.ExtensionIncompatible;
    }
    if (manifest.capabilities.len > 512) return error.ExtensionInvalid;
    if (manifest.manifest_json.len > 4096) return error.ExtensionInvalid;
    if (!manifest.required) return error.ExtensionInvalid;
    try validateStoragePrefix(manifest.name, manifest.storage_prefix);
}

const AbiVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

fn parseAbiVersion(value: []const u8) Error!AbiVersion {
    if (value.len == 0 or value.len > 64) return error.ExtensionInvalid;

    var parts = std.mem.splitScalar(u8, value, '.');
    const major = try parseAbiVersionPart(parts.next() orelse return error.ExtensionInvalid);
    const minor = try parseAbiVersionPart(parts.next() orelse return error.ExtensionInvalid);
    const patch = try parseAbiVersionPart(parts.next() orelse return error.ExtensionInvalid);
    if (parts.next() != null) return error.ExtensionInvalid;

    return .{ .major = major, .minor = minor, .patch = patch };
}

fn parseAbiVersionPart(value: []const u8) Error!u32 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.ExtensionInvalid;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return error.ExtensionInvalid;
    }
    return std.fmt.parseInt(u32, value, 10) catch error.ExtensionInvalid;
}

pub fn install(db: *sqlite.Database, registry: Registry, name: []const u8, validate_core: ?ValidationHook) Error!void {
    try registry.validate();
    try validateName(name);
    const extension = registry.find(name) orelse return error.ExtensionNotFound;
    try validateManifest(extension.manifest);
    if (try isInstalled(db, name)) return error.ExtensionExists;

    var before_objects = try listSchemaObjects(std.heap.c_allocator, db);
    defer before_objects.deinit(std.heap.c_allocator);

    try db.savepoint("extension_lifecycle");
    var released = false;
    errdefer if (!released) {
        db.rollbackToSavepoint("extension_lifecycle") catch {};
        db.releaseSavepoint("extension_lifecycle") catch {};
    };

    try registry.invoke(extension, db, .install);
    try insertInstalled(db, extension.manifest);
    try registry.invoke(extension, db, .register_sql);
    try validateNewSchemaObjectsOwnedBy(std.heap.c_allocator, db, before_objects.names, extension.manifest.storage_prefix);
    try validateInstalledState(std.heap.c_allocator, db);
    if (validate_core) |hook| hook(db) catch return error.ExtensionInvalid;

    try db.releaseSavepoint("extension_lifecycle");
    released = true;
}

/// Explicit forward path. Kept outside Extension to preserve the legacy ABI.
pub const Upgrade = struct {
    name: []const u8,
    from_version: []const u8,
    to_version: []const u8,
    hook: ?Hook = null,
    plugin_hook: ?plugin.Hook = null,
};

fn validateUpgradeDirection(from: []const u8, to: []const u8) Error!void {
    const a = parseAbiVersion(from) catch return error.ExtensionIncompatible;
    const b = parseAbiVersion(to) catch return error.ExtensionIncompatible;
    if (b.major > a.major or (b.major == a.major and b.minor > a.minor) or
        (b.major == a.major and b.minor == a.minor and b.patch > a.patch)) return;
    return error.ExtensionIncompatible;
}

/// Upgrade only a declared source version. The savepoint owns the metadata and
/// data changes together, including when nested inside a caller transaction.
pub fn upgrade(allocator: std.mem.Allocator, db: *sqlite.Database, registry: Registry, name: []const u8, validate_core: ?ValidationHook) Error!void {
    try registry.validate();
    try validateName(name);
    const target = registry.find(name) orelse return error.ExtensionUnavailable;
    try db.savepoint("extension_upgrade");
    errdefer {
        db.rollbackToSavepoint("extension_upgrade") catch {};
        db.releaseSavepoint("extension_upgrade") catch {};
    }
    var installed = try loadInfo(allocator, db, name);
    defer installed.deinit(allocator);
    if (!abiMinimumMatchesInstalled(target.manifest.zova_abi_min, installed.zova_abi_min)) {
        var source_manifest = target.manifest;
        source_manifest.zova_abi_min = installed.zova_abi_min;
        validateManifest(source_manifest) catch return error.ExtensionIncompatible;
    }
    if (!std.mem.eql(u8, target.manifest.storage_prefix, installed.storage_prefix)) return error.ExtensionIncompatible;
    try validateUpgradeDirection(installed.version, target.manifest.version);
    const path = for (registry.upgrades) |candidate| {
        if (std.mem.eql(u8, candidate.name, name) and std.mem.eql(u8, candidate.from_version, installed.version)) break candidate;
    } else return error.ExtensionIncompatible;
    var before = try listSchemaObjects(allocator, db);
    defer before.deinit(allocator);
    if (path.hook) |hook| {
        try hook(db, target.manifest);
    } else {
        try plugin.invokeHook(path.plugin_hook.?, db);
    }
    try registry.invoke(target, db, .register_sql);
    try registry.invoke(target, db, .check);
    try validateNewSchemaObjectsOwnedBy(allocator, db, before.names, target.manifest.storage_prefix);
    try validateInstalledState(allocator, db);
    if (validate_core) |hook| hook(db) catch return error.ExtensionInvalid;
    var stmt = try db.prepare("UPDATE _zova_extensions SET version=?, zova_abi_min=?, capabilities=?, manifest_json=? WHERE name=?");
    defer stmt.deinit();
    try stmt.bindText(1, target.manifest.version);
    try stmt.bindText(2, target.manifest.zova_abi_min);
    try stmt.bindText(3, target.manifest.capabilities);
    try stmt.bindText(4, target.manifest.manifest_json);
    try stmt.bindText(5, name);
    std.debug.assert(try stmt.step() == .done);
    try validateInstalledState(allocator, db);
    try db.releaseSavepoint("extension_upgrade");
}

pub fn drop(db: *sqlite.Database, registry: Registry, name: []const u8, validate_core: ?ValidationHook) Error!void {
    try registry.validate();
    try validateName(name);
    const installed = try loadInfo(std.heap.c_allocator, db, name);
    defer {
        var mutable = installed;
        mutable.deinit(std.heap.c_allocator);
    }
    const extension = registry.find(name) orelse return error.ExtensionUnavailable;
    try ensureManifestMatchesInstalled(extension.manifest, installed);

    try db.savepoint("extension_lifecycle");
    var released = false;
    errdefer if (!released) {
        db.rollbackToSavepoint("extension_lifecycle") catch {};
        db.releaseSavepoint("extension_lifecycle") catch {};
    };

    try registry.invoke(extension, db, .drop);
    var delete_row = try db.prepare("delete from _zova_extensions where name = ?");
    defer delete_row.deinit();
    try delete_row.bindText(1, name);
    std.debug.assert((try delete_row.step()) == .done);

    try validateInstalledState(std.heap.c_allocator, db);
    if (validate_core) |hook| hook(db) catch return error.ExtensionInvalid;

    try db.releaseSavepoint("extension_lifecycle");
    released = true;
}

pub fn check(db: *sqlite.Database, registry: Registry, name: []const u8) Error!void {
    try registry.validate();
    try validateName(name);
    const installed = try loadInfo(std.heap.c_allocator, db, name);
    defer {
        var mutable = installed;
        mutable.deinit(std.heap.c_allocator);
    }
    const extension = registry.find(name) orelse return error.ExtensionUnavailable;
    try ensureManifestMatchesInstalled(extension.manifest, installed);
    try registry.invoke(extension, db, .check);
}

pub fn registerSqlForInstalledExtension(db: *sqlite.Database, registry: Registry, name: []const u8) Error!void {
    try registry.validate();
    try validateName(name);
    const installed = try loadInfo(std.heap.c_allocator, db, name);
    defer {
        var mutable = installed;
        mutable.deinit(std.heap.c_allocator);
    }
    const extension = registry.find(name) orelse return error.ExtensionUnavailable;
    try ensureManifestMatchesInstalled(extension.manifest, installed);
    try registry.invoke(extension, db, .register_sql);
}

pub fn checkAll(db: *sqlite.Database, registry: Registry) Error!void {
    try registry.validate();
    try validateInstalledState(std.heap.c_allocator, db);
    var list = try listInstalled(std.heap.c_allocator, db);
    defer list.deinit(std.heap.c_allocator);
    for (list.items) |item| {
        const extension = registry.find(item.name) orelse return error.ExtensionUnavailable;
        try ensureManifestMatchesInstalled(extension.manifest, item);
        try registry.invoke(extension, db, .check);
    }
}

pub fn registerSqlForInstalled(db: *sqlite.Database, registry: Registry) Error!void {
    try registry.validate();
    try validateInstalledState(std.heap.c_allocator, db);
    var list = try listInstalled(std.heap.c_allocator, db);
    defer list.deinit(std.heap.c_allocator);
    for (list.items) |item| {
        const extension = registry.find(item.name) orelse return error.ExtensionUnavailable;
        try ensureManifestMatchesInstalled(extension.manifest, item);
        try registry.invoke(extension, db, .register_sql);
    }
}

pub fn listInstalled(allocator: std.mem.Allocator, db: *sqlite.Database) Error!InstalledList {
    var stmt = try db.prepare(
        \\select name, version, storage_prefix, zova_abi_min, capabilities,
        \\       required, installed_at_unix, manifest_json
        \\from _zova_extensions
        \\order by name
    );
    defer stmt.deinit();

    var items: std.ArrayList(InstalledInfo) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    while (try stmt.step() == .row) {
        var item = try readInstalledRow(allocator, &stmt);
        errdefer item.deinit(allocator);
        try validateInstalledShape(item);
        for (items.items) |previous| {
            if (std.mem.eql(u8, previous.storage_prefix, item.storage_prefix)) return error.ExtensionInvalid;
        }
        try items.append(allocator, item);
    }

    return .{ .items = try items.toOwnedSlice(allocator) };
}

pub fn validateInstalledState(allocator: std.mem.Allocator, db: *sqlite.Database) Error!void {
    var list = try listInstalled(allocator, db);
    defer list.deinit(allocator);
    try validatePrivateStorageOwners(db, list.items);
}

pub fn validateInstalledRegistry(allocator: std.mem.Allocator, db: *sqlite.Database) Error!void {
    var list = try listInstalled(allocator, db);
    defer list.deinit(allocator);
}

pub fn findUnknownPrivateStorage(allocator: std.mem.Allocator, db: *sqlite.Database) Error!?[]u8 {
    var list = try listInstalled(allocator, db);
    defer list.deinit(allocator);

    var stmt = try db.prepare(
        \\select name
        \\from sqlite_master
        \\where type in ('table', 'index', 'view', 'trigger')
        \\order by name
    );
    defer stmt.deinit();

    while (try stmt.step() == .row) {
        const name = stmt.columnText(0);
        if (!std.mem.startsWith(u8, name, storage_prefix_prefix)) continue;
        if (isOwnedPrivateStorage(name, list.items)) continue;
        return try allocator.dupe(u8, name);
    }
    return null;
}

pub fn countPrivateStorageObjects(db: *sqlite.Database, storage_prefix: []const u8) Error!u64 {
    var stmt = try db.prepare(
        \\select name
        \\from sqlite_master
        \\where type in ('table', 'index', 'view', 'trigger')
        \\order by name
    );
    defer stmt.deinit();

    var count: u64 = 0;
    while (try stmt.step() == .row) {
        const name = stmt.columnText(0);
        if (isSqliteInternalObject(name)) continue;
        if (std.mem.startsWith(u8, name, storage_prefix)) count += 1;
    }
    return count;
}

pub fn salvageInstalled(
    allocator: std.mem.Allocator,
    source: *sqlite.Database,
    destination: ?*sqlite.Database,
    registry: Registry,
    mode: SalvageMode,
) Error!SalvageResult {
    try registry.validate();
    var list = try listInstalled(allocator, source);
    defer list.deinit(allocator);

    var total = SalvageResult{};
    for (list.items) |item| {
        const private_objects = try countPrivateStorageObjects(source, item.storage_prefix);
        const extension = registry.find(item.name) orelse {
            total.skipped_extensions += 1;
            total.skipped_private_objects += private_objects;
            continue;
        };
        ensureManifestMatchesInstalled(extension.manifest, item) catch {
            total.skipped_extensions += 1;
            total.skipped_private_objects += private_objects;
            continue;
        };
        const hook = extension.salvage orelse {
            total.skipped_extensions += 1;
            total.skipped_private_objects += private_objects;
            continue;
        };

        const result = switch (mode) {
            .plan => try hook(.{
                .allocator = allocator,
                .source = source,
                .destination = null,
                .mode = .plan,
            }, extension.manifest),
            .copy => try runCopySalvageHook(allocator, source, destination orelse return error.ExtensionInvalid, extension, hook),
        };
        total.add(result);
    }
    return total;
}

fn runCopySalvageHook(
    allocator: std.mem.Allocator,
    source: *sqlite.Database,
    destination: *sqlite.Database,
    extension: Extension,
    hook: SalvageHook,
) Error!SalvageResult {
    var before_objects = try listSchemaObjects(allocator, destination);
    defer before_objects.deinit(allocator);

    try destination.savepoint("extension_salvage");
    var released = false;
    errdefer if (!released) {
        destination.rollbackToSavepoint("extension_salvage") catch {};
        destination.releaseSavepoint("extension_salvage") catch {};
    };

    const result = try hook(.{
        .allocator = allocator,
        .source = source,
        .destination = destination,
        .mode = .copy,
    }, extension.manifest);

    try validateNewSchemaObjectsOwnedBy(allocator, destination, before_objects.names, extension.manifest.storage_prefix);
    if (result.installed_in_destination) {
        if (!try isInstalled(destination, extension.manifest.name)) {
            try insertInstalled(destination, extension.manifest);
        }
        try validateInstalledState(allocator, destination);
    } else if (result.copied_private_objects != 0) {
        return error.ExtensionInvalid;
    }

    try destination.releaseSavepoint("extension_salvage");
    released = true;
    return result;
}

pub fn loadInfo(allocator: std.mem.Allocator, db: *sqlite.Database, name: []const u8) Error!InstalledInfo {
    try validateName(name);
    var stmt = try db.prepare(
        \\select name, version, storage_prefix, zova_abi_min, capabilities,
        \\       required, installed_at_unix, manifest_json
        \\from _zova_extensions
        \\where name = ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, name);

    switch (try stmt.step()) {
        .row => {
            var item = try readInstalledRow(allocator, &stmt);
            errdefer item.deinit(allocator);
            try validateInstalledShape(item);
            return item;
        },
        .done => return error.ExtensionNotFound,
    }
}

fn readInstalledRow(allocator: std.mem.Allocator, stmt: *sqlite.Statement) Error!InstalledInfo {
    var item: InstalledInfo = .{
        .name = &.{},
        .version = &.{},
        .storage_prefix = &.{},
        .zova_abi_min = &.{},
        .capabilities = &.{},
        .manifest_json = &.{},
        .required = stmt.columnInt64(5) != 0,
        .installed_at_unix = stmt.columnInt64(6),
    };
    errdefer item.deinit(allocator);
    item.name = try allocator.dupe(u8, stmt.columnText(0));
    item.version = try allocator.dupe(u8, stmt.columnText(1));
    item.storage_prefix = try allocator.dupe(u8, stmt.columnText(2));
    item.zova_abi_min = try allocator.dupe(u8, stmt.columnText(3));
    item.capabilities = try allocator.dupe(u8, stmt.columnText(4));
    item.manifest_json = try allocator.dupe(u8, stmt.columnText(7));
    return item;
}

fn insertInstalled(db: *sqlite.Database, manifest: Manifest) Error!void {
    var stmt = try db.prepare(
        \\insert into _zova_extensions
        \\  (name, version, storage_prefix, zova_abi_min, capabilities, required, installed_at_unix, manifest_json)
        \\values (?, ?, ?, ?, ?, ?, unixepoch(), ?)
    );
    defer stmt.deinit();
    try stmt.bindText(1, manifest.name);
    try stmt.bindText(2, manifest.version);
    try stmt.bindText(3, manifest.storage_prefix);
    try stmt.bindText(4, manifest.zova_abi_min);
    try stmt.bindText(5, manifest.capabilities);
    try stmt.bindInt64(6, if (manifest.required) 1 else 0);
    try stmt.bindText(7, manifest.manifest_json);
    std.debug.assert((try stmt.step()) == .done);
}

fn isInstalled(db: *sqlite.Database, name: []const u8) Error!bool {
    var stmt = try db.prepare("select count(*) from _zova_extensions where name = ?");
    defer stmt.deinit();
    try stmt.bindText(1, name);
    std.debug.assert((try stmt.step()) == .row);
    return stmt.columnInt64(0) != 0;
}

fn validateInstalledShape(item: InstalledInfo) Error!void {
    try validateName(item.name);
    if (item.version.len == 0 or item.version.len > 64) return error.ExtensionInvalid;
    if (item.zova_abi_min.len == 0 or item.zova_abi_min.len > 64) return error.ExtensionInvalid;
    if (item.capabilities.len > 512) return error.ExtensionInvalid;
    if (item.manifest_json.len > 4096) return error.ExtensionInvalid;
    if (!item.required) return error.ExtensionInvalid;
    try validateStoragePrefix(item.name, item.storage_prefix);
}

fn validatePrivateStorageOwners(db: *sqlite.Database, installed: []const InstalledInfo) Error!void {
    var stmt = try db.prepare(
        \\select name
        \\from sqlite_master
        \\where type in ('table', 'index', 'view', 'trigger')
        \\order by name
    );
    defer stmt.deinit();

    while (try stmt.step() == .row) {
        const name = stmt.columnText(0);
        if (!std.mem.startsWith(u8, name, storage_prefix_prefix)) continue;
        if (!isOwnedPrivateStorage(name, installed)) return error.ExtensionInvalid;
    }
}

fn listSchemaObjects(allocator: std.mem.Allocator, db: *sqlite.Database) Error!SchemaObjectList {
    var stmt = try db.prepare(
        \\select name
        \\from sqlite_master
        \\where type in ('table', 'index', 'view', 'trigger')
        \\order by name
    );
    defer stmt.deinit();

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    while (try stmt.step() == .row) {
        const name = stmt.columnText(0);
        if (isSqliteInternalObject(name)) continue;
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try names.append(allocator, owned);
    }

    return .{ .names = try names.toOwnedSlice(allocator) };
}

fn validateNewSchemaObjectsOwnedBy(allocator: std.mem.Allocator, db: *sqlite.Database, before: []const []const u8, storage_prefix: []const u8) Error!void {
    var after = try listSchemaObjects(allocator, db);
    defer after.deinit(allocator);

    for (after.names) |name| {
        if (schemaObjectExists(before, name)) continue;
        if (!std.mem.startsWith(u8, name, storage_prefix)) return error.ExtensionInvalid;
    }
}

fn schemaObjectExists(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn isOwnedPrivateStorage(name: []const u8, installed: []const InstalledInfo) bool {
    for (installed) |item| {
        if (std.mem.startsWith(u8, name, item.storage_prefix)) return true;
    }
    return false;
}

fn isSqliteInternalObject(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "sqlite_");
}

fn ensureManifestMatchesInstalled(manifest: Manifest, installed: InstalledInfo) Error!void {
    try validateManifest(manifest);
    if (!std.mem.eql(u8, manifest.name, installed.name)) return error.ExtensionInvalid;
    if (!std.mem.eql(u8, manifest.version, installed.version)) return error.ExtensionIncompatible;
    if (!std.mem.eql(u8, manifest.storage_prefix, installed.storage_prefix)) return error.ExtensionInvalid;
    if (!abiMinimumMatchesInstalled(manifest.zova_abi_min, installed.zova_abi_min)) return error.ExtensionIncompatible;
}

fn abiMinimumMatchesInstalled(current: []const u8, installed: []const u8) bool {
    if (std.mem.eql(u8, current, installed)) return true;

    // Format-9/10/11 databases can retain extension metadata written by the
    // pre-1.0 host. The trusted registry supplies the code that is actually
    // loaded and declares its current 1.0.0 compatibility; accepting the old
    // stored minimum preserves those databases without accepting 0.x code as
    // compatible with the 1.x runtime.
    const current_version = parseAbiVersion(current) catch return false;
    const installed_version = parseAbiVersion(installed) catch return false;
    return current_version.major == 1 and
        current_version.minor == 0 and
        current_version.patch == 0 and
        installed_version.major == 0;
}

fn hasReservedZovaPrefix(name: []const u8) bool {
    const reserved = "_zova_";
    if (name.len < reserved.len) return false;
    for (reserved, 0..) |expected, index| {
        if (asciiLower(name[index]) != expected) return false;
    }
    return true;
}

fn isExtensionNameByte(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or
        byte == '_' or byte == '.' or byte == ':' or byte == '-';
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}
