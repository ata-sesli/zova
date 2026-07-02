//! Private extension host foundation.
//!
//! Extension code is process-provided. A database may record installed
//! extensions, but it never stores executable paths and never auto-loads code.

const std = @import("std");
const sqlite = @import("sqlite.zig");

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

pub const Extension = struct {
    manifest: Manifest,
    install: Hook,
    check: Hook,
    drop: Hook,
    register_sql: ?Hook = null,
};

pub const Registry = struct {
    extensions: []const Extension = &.{},

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
        for (self.extensions, 0..) |extension, index| {
            try validateManifest(extension.manifest);
            for (self.extensions[0..index]) |previous| {
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
    if (manifest.zova_abi_min.len == 0 or manifest.zova_abi_min.len > 64) return error.ExtensionInvalid;
    if (manifest.capabilities.len > 512) return error.ExtensionInvalid;
    if (manifest.manifest_json.len > 4096) return error.ExtensionInvalid;
    try validateStoragePrefix(manifest.name, manifest.storage_prefix);
}

pub fn install(db: *sqlite.Database, registry: Registry, name: []const u8) Error!void {
    try registry.validate();
    try validateName(name);
    const extension = registry.find(name) orelse return error.ExtensionNotFound;
    try validateManifest(extension.manifest);
    if (try isInstalled(db, name)) return error.ExtensionExists;

    try db.savepoint("extension_lifecycle");
    var released = false;
    errdefer if (!released) {
        db.rollbackToSavepoint("extension_lifecycle") catch {};
        db.releaseSavepoint("extension_lifecycle") catch {};
    };

    try extension.install(db, extension.manifest);
    try insertInstalled(db, extension.manifest);
    if (extension.register_sql) |register_sql| try register_sql(db, extension.manifest);

    try db.releaseSavepoint("extension_lifecycle");
    released = true;
}

pub fn drop(db: *sqlite.Database, registry: Registry, name: []const u8) Error!void {
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

    try extension.drop(db, extension.manifest);
    var delete_row = try db.prepare("delete from _zova_extensions where name = ?");
    defer delete_row.deinit();
    try delete_row.bindText(1, name);
    std.debug.assert((try delete_row.step()) == .done);

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
    try extension.check(db, extension.manifest);
}

pub fn checkAll(db: *sqlite.Database, registry: Registry) Error!void {
    try registry.validate();
    var list = try listInstalled(std.heap.c_allocator, db);
    defer list.deinit(std.heap.c_allocator);
    for (list.items) |item| {
        const extension = registry.find(item.name) orelse return error.ExtensionUnavailable;
        try ensureManifestMatchesInstalled(extension.manifest, item);
        try extension.check(db, extension.manifest);
    }
}

pub fn registerSqlForInstalled(db: *sqlite.Database, registry: Registry) Error!void {
    try registry.validate();
    var list = try listInstalled(std.heap.c_allocator, db);
    defer list.deinit(std.heap.c_allocator);
    for (list.items) |item| {
        const extension = registry.find(item.name) orelse return error.ExtensionUnavailable;
        try ensureManifestMatchesInstalled(extension.manifest, item);
        if (extension.register_sql) |register_sql| try register_sql(db, extension.manifest);
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
        var item = InstalledInfo{
            .name = try allocator.dupe(u8, stmt.columnText(0)),
            .version = try allocator.dupe(u8, stmt.columnText(1)),
            .storage_prefix = try allocator.dupe(u8, stmt.columnText(2)),
            .zova_abi_min = try allocator.dupe(u8, stmt.columnText(3)),
            .capabilities = try allocator.dupe(u8, stmt.columnText(4)),
            .required = stmt.columnInt64(5) != 0,
            .installed_at_unix = stmt.columnInt64(6),
            .manifest_json = try allocator.dupe(u8, stmt.columnText(7)),
        };
        errdefer item.deinit(allocator);
        try validateInstalledShape(item);
        try items.append(allocator, item);
    }

    return .{ .items = try items.toOwnedSlice(allocator) };
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
            var item = InstalledInfo{
                .name = try allocator.dupe(u8, stmt.columnText(0)),
                .version = try allocator.dupe(u8, stmt.columnText(1)),
                .storage_prefix = try allocator.dupe(u8, stmt.columnText(2)),
                .zova_abi_min = try allocator.dupe(u8, stmt.columnText(3)),
                .capabilities = try allocator.dupe(u8, stmt.columnText(4)),
                .required = stmt.columnInt64(5) != 0,
                .installed_at_unix = stmt.columnInt64(6),
                .manifest_json = try allocator.dupe(u8, stmt.columnText(7)),
            };
            errdefer item.deinit(allocator);
            try validateInstalledShape(item);
            return item;
        },
        .done => return error.ExtensionNotFound,
    }
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
    try validateStoragePrefix(item.name, item.storage_prefix);
}

fn ensureManifestMatchesInstalled(manifest: Manifest, installed: InstalledInfo) Error!void {
    try validateManifest(manifest);
    if (!std.mem.eql(u8, manifest.name, installed.name)) return error.ExtensionInvalid;
    if (!std.mem.eql(u8, manifest.version, installed.version)) return error.ExtensionIncompatible;
    if (!std.mem.eql(u8, manifest.storage_prefix, installed.storage_prefix)) return error.ExtensionInvalid;
    if (!std.mem.eql(u8, manifest.zova_abi_min, installed.zova_abi_min)) return error.ExtensionIncompatible;
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
