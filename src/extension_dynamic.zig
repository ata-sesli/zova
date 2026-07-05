//! Dynamic trusted local extension loading.
//!
//! This is intentionally a Zig-native trusted ABI. A `.zovaext` bundle is
//! local code that the process explicitly trusts and loads; database metadata
//! never contains executable paths and never triggers loading by itself.

const std = @import("std");
const builtin = @import("builtin");
const extension = @import("extension.zig");

pub const supports_dynamic_loading = builtin.os.tag != .windows;
const DynamicLibrary = if (supports_dynamic_loading) std.DynLib else struct {};

pub const default_entrypoint = "zova_extension_entry";
pub const bundle_manifest_file = "extension.json";
pub const trust_store_version = 1;

pub const Error = extension.Error || error{
    ExtensionUntrusted,
    ExtensionLoadFailed,
    FileNotFound,
    BadPathName,
    AccessDenied,
    PermissionDenied,
    IsDir,
    NotDir,
    NameTooLong,
    CurrentDirUnlinked,
    InvalidJson,
    SyntaxError,
    UnexpectedToken,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
    WriteFailed,
    OutOfMemory,
};

pub const TrustStoreOptions = struct {
    path: ?[]const u8 = null,
};

pub const BundleManifest = struct {
    name: []u8,
    version: []u8,
    storage_prefix: []u8,
    zova_abi_min: []u8,
    capabilities: []u8,
    library: []u8,
    entrypoint: []u8,

    pub fn deinit(self: *BundleManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.storage_prefix);
        allocator.free(self.zova_abi_min);
        allocator.free(self.capabilities);
        allocator.free(self.library);
        allocator.free(self.entrypoint);
    }
};

pub const BundleInfo = struct {
    bundle_path: []u8,
    library_path: []u8,
    manifest: BundleManifest,
    manifest_sha256: [64]u8,
    library_sha256: [64]u8,

    pub fn deinit(self: *BundleInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.bundle_path);
        allocator.free(self.library_path);
        self.manifest.deinit(allocator);
    }
};

pub const TrustRecord = struct {
    name: []u8,
    version: []u8,
    storage_prefix: []u8,
    bundle_path: []u8,
    manifest_sha256: [64]u8,
    library_sha256: [64]u8,
    trusted_at_unix: i64,

    pub fn deinit(self: *TrustRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.storage_prefix);
        allocator.free(self.bundle_path);
    }
};

pub const TrustedList = struct {
    records: []TrustRecord,

    pub fn deinit(self: *TrustedList, allocator: std.mem.Allocator) void {
        for (self.records) |*record| record.deinit(allocator);
        allocator.free(self.records);
    }
};

pub const OwnedRegistry = struct {
    allocator: std.mem.Allocator,
    extensions: []extension.Extension,

    pub fn init(allocator: std.mem.Allocator, registries: []const extension.Registry) Error!OwnedRegistry {
        var total: usize = 0;
        for (registries) |item| total += item.extensions.len;

        const items = try allocator.alloc(extension.Extension, total);
        errdefer allocator.free(items);

        var index: usize = 0;
        for (registries) |item| {
            @memcpy(items[index..][0..item.extensions.len], item.extensions);
            index += item.extensions.len;
        }

        const owned: OwnedRegistry = .{ .allocator = allocator, .extensions = items };
        try owned.registry().validate();
        return owned;
    }

    pub fn registry(self: OwnedRegistry) extension.Registry {
        return extension.Registry.init(self.extensions);
    }

    pub fn deinit(self: *OwnedRegistry) void {
        self.allocator.free(self.extensions);
    }
};

pub const DynamicExtensionSet = struct {
    allocator: std.mem.Allocator,
    libraries: []DynamicLibrary,
    extensions: []extension.Extension,

    pub fn loadTrustedBundles(
        allocator: std.mem.Allocator,
        bundle_paths: []const []const u8,
        options: TrustStoreOptions,
    ) Error!DynamicExtensionSet {
        if (comptime !supports_dynamic_loading) {
            if (bundle_paths.len != 0) return error.ExtensionLoadFailed;
            return .{
                .allocator = allocator,
                .libraries = try allocator.alloc(DynamicLibrary, 0),
                .extensions = try allocator.alloc(extension.Extension, 0),
            };
        }

        var libraries: std.ArrayList(DynamicLibrary) = .empty;
        errdefer {
            for (libraries.items) |*library| library.close();
            libraries.deinit(allocator);
        }

        var extensions: std.ArrayList(extension.Extension) = .empty;
        errdefer extensions.deinit(allocator);

        for (bundle_paths) |bundle_path| {
            var info = try loadBundleInfo(allocator, bundle_path);
            defer info.deinit(allocator);
            try ensureTrusted(allocator, info, options);

            var library = std.DynLib.open(info.library_path) catch return error.ExtensionLoadFailed;
            errdefer library.close();

            const entry_name = try allocator.dupeZ(u8, info.manifest.entrypoint);
            defer allocator.free(entry_name);
            const Entry = *const fn () callconv(.c) *const extension.Extension;
            const entry = library.lookup(Entry, entry_name) orelse return error.ExtensionLoadFailed;
            const loaded = entry().*;
            try ensureLoadedExtensionMatches(info, loaded);

            try libraries.append(allocator, library);
            try extensions.append(allocator, loaded);
        }

        const owned_extensions = try extensions.toOwnedSlice(allocator);
        errdefer allocator.free(owned_extensions);
        const owned_libraries = try libraries.toOwnedSlice(allocator);
        errdefer {
            for (owned_libraries) |*library| library.close();
            allocator.free(owned_libraries);
        }

        const set: DynamicExtensionSet = .{
            .allocator = allocator,
            .libraries = owned_libraries,
            .extensions = owned_extensions,
        };
        try set.registry().validate();
        return set;
    }

    pub fn registry(self: DynamicExtensionSet) extension.Registry {
        return extension.Registry.init(self.extensions);
    }

    pub fn deinit(self: *DynamicExtensionSet) void {
        if (comptime supports_dynamic_loading) {
            for (self.libraries) |*library| library.close();
        }
        self.allocator.free(self.libraries);
        self.allocator.free(self.extensions);
    }
};

pub fn loadBundleInfo(allocator: std.mem.Allocator, bundle_path: []const u8) Error!BundleInfo {
    if (!std.mem.endsWith(u8, bundle_path, ".zovaext")) return error.ExtensionInvalid;

    const normalized_bundle_path = try canonicalizeExistingPath(allocator, bundle_path);
    errdefer allocator.free(normalized_bundle_path);

    const manifest_path = try std.fs.path.join(allocator, &.{ normalized_bundle_path, bundle_manifest_file });
    defer allocator.free(manifest_path);
    const manifest_bytes = try readFileAlloc(allocator, manifest_path, 64 * 1024);
    defer allocator.free(manifest_bytes);

    var manifest = try parseBundleManifest(allocator, manifest_bytes);
    errdefer manifest.deinit(allocator);
    try extension.validateManifest(.{
        .name = manifest.name,
        .version = manifest.version,
        .storage_prefix = manifest.storage_prefix,
        .zova_abi_min = manifest.zova_abi_min,
        .capabilities = manifest.capabilities,
        .required = true,
    });
    try validateRelativeLibraryPath(manifest.library);
    try validateEntrypoint(manifest.entrypoint);

    const joined_library_path = try std.fs.path.join(allocator, &.{ normalized_bundle_path, manifest.library });
    defer allocator.free(joined_library_path);
    const library_path = try canonicalizeExistingPath(allocator, joined_library_path);
    errdefer allocator.free(library_path);
    if (!isPathInsideDirectory(normalized_bundle_path, library_path)) return error.ExtensionInvalid;
    const library_bytes = try readFileAlloc(allocator, library_path, 256 * 1024 * 1024);
    defer allocator.free(library_bytes);

    return .{
        .bundle_path = normalized_bundle_path,
        .library_path = library_path,
        .manifest = manifest,
        .manifest_sha256 = sha256Hex(manifest_bytes),
        .library_sha256 = sha256Hex(library_bytes),
    };
}

pub fn trustBundle(allocator: std.mem.Allocator, bundle_path: []const u8, options: TrustStoreOptions) Error!TrustRecord {
    var info = try loadBundleInfo(allocator, bundle_path);
    defer info.deinit(allocator);

    var list = try loadTrusted(allocator, options);
    defer list.deinit(allocator);

    var records: std.ArrayList(TrustRecord) = .empty;
    defer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit(allocator);
    }

    for (list.records) |record| {
        if (std.mem.eql(u8, record.name, info.manifest.name) or std.mem.eql(u8, record.bundle_path, info.bundle_path)) {
            continue;
        }
        try records.append(allocator, try cloneTrustRecord(allocator, record));
    }

    const trusted_record = try trustRecordFromBundleInfo(allocator, info);
    errdefer {
        var mutable = trusted_record;
        mutable.deinit(allocator);
    }
    try records.append(allocator, try cloneTrustRecord(allocator, trusted_record));
    try writeTrusted(allocator, .{ .records = records.items }, options);
    return trusted_record;
}

pub fn untrust(allocator: std.mem.Allocator, identifier: []const u8, options: TrustStoreOptions) Error!bool {
    var list = try loadTrusted(allocator, options);
    defer list.deinit(allocator);

    const maybe_path = if (looksLikeBundlePath(identifier)) try trustIdentifierPath(allocator, identifier) else null;
    defer if (maybe_path) |path| allocator.free(path);
    if (maybe_path == null) try extension.validateName(identifier);

    var removed = false;
    var records: std.ArrayList(TrustRecord) = .empty;
    defer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit(allocator);
    }

    for (list.records) |record| {
        const matches_name = maybe_path == null and std.mem.eql(u8, record.name, identifier);
        const matches_path = if (maybe_path) |path| std.mem.eql(u8, record.bundle_path, path) else false;
        if (matches_name or matches_path) {
            removed = true;
            continue;
        }
        try records.append(allocator, try cloneTrustRecord(allocator, record));
    }

    try writeTrusted(allocator, .{ .records = records.items }, options);
    return removed;
}

pub fn loadTrusted(allocator: std.mem.Allocator, options: TrustStoreOptions) Error!TrustedList {
    const path = try trustStorePath(allocator, options);
    defer allocator.free(path);

    const bytes = readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{ .records = try allocator.alloc(TrustRecord, 0) },
        else => |e| return e,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.ExtensionInvalid;
    defer parsed.deinit();
    if (std.meta.activeTag(parsed.value) != .object) return error.ExtensionInvalid;
    const version_value = parsed.value.object.get("version") orelse return error.ExtensionInvalid;
    if (std.meta.activeTag(version_value) != .integer or version_value.integer != trust_store_version) return error.ExtensionInvalid;
    const extensions_value = parsed.value.object.get("extensions") orelse return error.ExtensionInvalid;
    if (std.meta.activeTag(extensions_value) != .array) return error.ExtensionInvalid;

    var records: std.ArrayList(TrustRecord) = .empty;
    errdefer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit(allocator);
    }

    for (extensions_value.array.items) |item| {
        if (std.meta.activeTag(item) != .object) return error.ExtensionInvalid;
        const record = try parseTrustRecord(allocator, item.object);
        errdefer {
            var mutable = record;
            mutable.deinit(allocator);
        }
        try records.append(allocator, record);
    }

    return .{ .records = try records.toOwnedSlice(allocator) };
}

fn ensureTrusted(allocator: std.mem.Allocator, info: BundleInfo, options: TrustStoreOptions) Error!void {
    var list = try loadTrusted(allocator, options);
    defer list.deinit(allocator);

    for (list.records) |record| {
        if (!std.mem.eql(u8, record.bundle_path, info.bundle_path)) continue;
        if (!std.mem.eql(u8, record.name, info.manifest.name)) return error.ExtensionUntrusted;
        if (!std.mem.eql(u8, record.version, info.manifest.version)) return error.ExtensionUntrusted;
        if (!std.mem.eql(u8, record.storage_prefix, info.manifest.storage_prefix)) return error.ExtensionUntrusted;
        if (!std.mem.eql(u8, record.manifest_sha256[0..], info.manifest_sha256[0..])) return error.ExtensionUntrusted;
        if (!std.mem.eql(u8, record.library_sha256[0..], info.library_sha256[0..])) return error.ExtensionUntrusted;
        return;
    }

    return error.ExtensionUntrusted;
}

fn writeTrusted(allocator: std.mem.Allocator, list: TrustedList, options: TrustStoreOptions) Error!void {
    const path = try trustStorePath(allocator, options);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| std.Io.Dir.cwd().createDirPath(defaultIo(), parent) catch return error.ExtensionInvalid;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"version\": 1,\n  \"extensions\": [");
    for (list.records, 0..) |record, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\n      \"name\": ");
        try writeJsonString(writer, record.name);
        try writer.writeAll(",\n      \"version\": ");
        try writeJsonString(writer, record.version);
        try writer.writeAll(",\n      \"storage_prefix\": ");
        try writeJsonString(writer, record.storage_prefix);
        try writer.writeAll(",\n      \"bundle_path\": ");
        try writeJsonString(writer, record.bundle_path);
        try writer.writeAll(",\n      \"manifest_sha256\": ");
        try writeJsonString(writer, record.manifest_sha256[0..]);
        try writer.writeAll(",\n      \"library_sha256\": ");
        try writeJsonString(writer, record.library_sha256[0..]);
        try writer.print(",\n      \"trusted_at_unix\": {d}\n    }}", .{record.trusted_at_unix});
    }
    try writer.writeAll("\n  ]\n}\n");

    std.Io.Dir.cwd().writeFile(defaultIo(), .{ .sub_path = path, .data = out.written() }) catch return error.ExtensionInvalid;
}

fn trustStorePath(allocator: std.mem.Allocator, options: TrustStoreOptions) Error![]u8 {
    if (options.path) |path| return normalizePath(allocator, path);
    if (getenv("ZOVA_TRUST_STORE")) |path| return normalizePath(allocator, path);
    if (getenv("XDG_CONFIG_HOME")) |config| return std.fs.path.join(allocator, &.{ config, "zova", "trusted_extensions.json" });
    if (getenv("HOME")) |home| return std.fs.path.join(allocator, &.{ home, ".config", "zova", "trusted_extensions.json" });
    return error.ExtensionInvalid;
}

fn parseBundleManifest(allocator: std.mem.Allocator, bytes: []const u8) Error!BundleManifest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.ExtensionInvalid;
    defer parsed.deinit();
    if (std.meta.activeTag(parsed.value) != .object) return error.ExtensionInvalid;
    const object = parsed.value.object;

    return .{
        .name = try allocator.dupe(u8, try jsonString(object, "name")),
        .version = try allocator.dupe(u8, try jsonString(object, "version")),
        .storage_prefix = try allocator.dupe(u8, try jsonString(object, "storage_prefix")),
        .zova_abi_min = try allocator.dupe(u8, try jsonString(object, "zova_abi_min")),
        .capabilities = try allocator.dupe(u8, try jsonString(object, "capabilities")),
        .library = try allocator.dupe(u8, try jsonString(object, "library")),
        .entrypoint = try allocator.dupe(u8, jsonString(object, "entrypoint") catch default_entrypoint),
    };
}

fn parseTrustRecord(allocator: std.mem.Allocator, object: std.json.ObjectMap) Error!TrustRecord {
    return .{
        .name = try allocator.dupe(u8, try jsonString(object, "name")),
        .version = try allocator.dupe(u8, try jsonString(object, "version")),
        .storage_prefix = try allocator.dupe(u8, try jsonString(object, "storage_prefix")),
        .bundle_path = try allocator.dupe(u8, try jsonString(object, "bundle_path")),
        .manifest_sha256 = try parseHex64(try jsonString(object, "manifest_sha256")),
        .library_sha256 = try parseHex64(try jsonString(object, "library_sha256")),
        .trusted_at_unix = try jsonInteger(object, "trusted_at_unix"),
    };
}

fn trustRecordFromBundleInfo(allocator: std.mem.Allocator, info: BundleInfo) Error!TrustRecord {
    return .{
        .name = try allocator.dupe(u8, info.manifest.name),
        .version = try allocator.dupe(u8, info.manifest.version),
        .storage_prefix = try allocator.dupe(u8, info.manifest.storage_prefix),
        .bundle_path = try allocator.dupe(u8, info.bundle_path),
        .manifest_sha256 = info.manifest_sha256,
        .library_sha256 = info.library_sha256,
        .trusted_at_unix = unixTimestamp(),
    };
}

fn cloneTrustRecord(allocator: std.mem.Allocator, record: TrustRecord) Error!TrustRecord {
    return .{
        .name = try allocator.dupe(u8, record.name),
        .version = try allocator.dupe(u8, record.version),
        .storage_prefix = try allocator.dupe(u8, record.storage_prefix),
        .bundle_path = try allocator.dupe(u8, record.bundle_path),
        .manifest_sha256 = record.manifest_sha256,
        .library_sha256 = record.library_sha256,
        .trusted_at_unix = record.trusted_at_unix,
    };
}

fn ensureLoadedExtensionMatches(info: BundleInfo, loaded: extension.Extension) Error!void {
    try extension.validateManifest(loaded.manifest);
    if (!std.mem.eql(u8, loaded.manifest.name, info.manifest.name)) return error.ExtensionIncompatible;
    if (!std.mem.eql(u8, loaded.manifest.version, info.manifest.version)) return error.ExtensionIncompatible;
    if (!std.mem.eql(u8, loaded.manifest.storage_prefix, info.manifest.storage_prefix)) return error.ExtensionIncompatible;
    if (!std.mem.eql(u8, loaded.manifest.zova_abi_min, info.manifest.zova_abi_min)) return error.ExtensionIncompatible;
    if (!std.mem.eql(u8, loaded.manifest.capabilities, info.manifest.capabilities)) return error.ExtensionIncompatible;
}

fn validateRelativeLibraryPath(path: []const u8) Error!void {
    if (path.len == 0 or path.len > 512) return error.ExtensionInvalid;
    if (std.fs.path.isAbsolute(path)) return error.ExtensionInvalid;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.ExtensionInvalid;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return error.ExtensionInvalid;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.ExtensionInvalid;
    }
}

fn validateEntrypoint(name: []const u8) Error!void {
    if (name.len == 0 or name.len > 128) return error.ExtensionInvalid;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return error.ExtensionInvalid;
    }
}

fn isPathInsideDirectory(directory: []const u8, path: []const u8) bool {
    if (path.len <= directory.len) return false;
    if (!std.mem.startsWith(u8, path, directory)) return false;
    return isPathSeparator(path[directory.len]);
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = std.process.currentPathAlloc(defaultIo(), allocator) catch return error.BadPathName;
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn canonicalizeExistingPath(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), path, allocator) catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.NotDir => error.NotDir,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ExtensionInvalid,
    };
    defer allocator.free(real_path);
    return allocator.dupe(u8, real_path);
}

fn trustIdentifierPath(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    return canonicalizeExistingPath(allocator, path) catch |err| switch (err) {
        error.FileNotFound => normalizePath(allocator, path),
        else => |e| return e,
    };
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) Error![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.IsDir => error.IsDir,
        error.NotDir => error.NotDir,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        else => error.ExtensionInvalid,
    };
}

fn unixTimestamp() i64 {
    if (comptime builtin.os.tag == .windows) return 0;
    var ts: std.posix.timespec = undefined;
    return switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
        .SUCCESS => @intCast(ts.sec),
        else => 0,
    };
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const digits = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        out[index * 2] = digits[@intCast(byte >> 4)];
        out[index * 2 + 1] = digits[@intCast(byte & 0x0f)];
    }
    return out;
}

fn parseHex64(value: []const u8) Error![64]u8 {
    if (value.len != 64) return error.ExtensionInvalid;
    var out: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isHex(byte)) return error.ExtensionInvalid;
        out[index] = std.ascii.toLower(byte);
    }
    return out;
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const value = object.get(key) orelse return error.ExtensionInvalid;
    if (std.meta.activeTag(value) != .string) return error.ExtensionInvalid;
    return value.string;
}

fn jsonInteger(object: std.json.ObjectMap, key: []const u8) Error!i64 {
    const value = object.get(key) orelse return error.ExtensionInvalid;
    if (std.meta.activeTag(value) != .integer) return error.ExtensionInvalid;
    return value.integer;
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn looksLikeBundlePath(value: []const u8) bool {
    return std.mem.endsWith(u8, value, ".zovaext") or std.mem.indexOfScalar(u8, value, '/') != null;
}

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(value);
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "dynamic extension bundle validation rejects unsafe library paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = defaultIo();

    try tmp.dir.createDir(io, "bad.zovaext", .default_dir);
    try tmp.dir.writeFile(io, .{
        .sub_path = "bad.zovaext/extension.json",
        .data =
        \\{
        \\  "name": "dyn_test",
        \\  "version": "0.1.0",
        \\  "storage_prefix": "_zova_ext_dyn_test_",
        \\  "zova_abi_min": "0.21.0",
        \\  "capabilities": "sql",
        \\  "library": "../libdyn_test.dylib"
        \\}
        ,
    });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/bad.zovaext", .{tmp.sub_path});
    try std.testing.expectError(error.ExtensionInvalid, loadBundleInfo(allocator, path));
}

test "dynamic extension library path containment requires directory boundary" {
    try std.testing.expect(isPathInsideDirectory("/tmp/good.zovaext", "/tmp/good.zovaext/libdyn"));
    try std.testing.expect(isPathInsideDirectory("/tmp/good.zovaext", "/tmp/good.zovaext/nested/libdyn"));
    try std.testing.expect(!isPathInsideDirectory("/tmp/good.zovaext", "/tmp/good.zovaext"));
    try std.testing.expect(!isPathInsideDirectory("/tmp/good.zovaext", "/tmp/good.zovaext-other/libdyn"));
}

test "dynamic extension trust store detects changed bundle contents" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = defaultIo();

    try tmp.dir.createDir(io, "good.zovaext", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "good.zovaext/libdyn_test.dylib", .data = "library one" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "good.zovaext/extension.json",
        .data =
        \\{
        \\  "name": "dyn_test",
        \\  "version": "0.1.0",
        \\  "storage_prefix": "_zova_ext_dyn_test_",
        \\  "zova_abi_min": "0.21.0",
        \\  "capabilities": "sql",
        \\  "library": "libdyn_test.dylib"
        \\}
        ,
    });

    var bundle_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_buffer, ".zig-cache/tmp/{s}/good.zovaext", .{tmp.sub_path});
    var trust_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const trust_path = try std.fmt.bufPrint(&trust_buffer, ".zig-cache/tmp/{s}/trusted_extensions.json", .{tmp.sub_path});

    var record = try trustBundle(allocator, bundle_path, .{ .path = trust_path });
    defer record.deinit(allocator);
    try std.testing.expectEqualStrings("dyn_test", record.name);

    var trusted = try loadTrusted(allocator, .{ .path = trust_path });
    defer trusted.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), trusted.records.len);

    var info = try loadBundleInfo(allocator, bundle_path);
    defer info.deinit(allocator);
    try ensureTrusted(allocator, info, .{ .path = trust_path });

    try tmp.dir.createDir(io, "alias", .default_dir);
    var alias_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const alias_path = try std.fmt.bufPrint(&alias_buffer, ".zig-cache/tmp/{s}/alias/../good.zovaext", .{tmp.sub_path});
    var alias_info = try loadBundleInfo(allocator, alias_path);
    defer alias_info.deinit(allocator);
    try ensureTrusted(allocator, alias_info, .{ .path = trust_path });

    const removed_by_alias = try untrust(allocator, alias_path, .{ .path = trust_path });
    try std.testing.expect(removed_by_alias);
    var empty = try loadTrusted(allocator, .{ .path = trust_path });
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.records.len);

    var record_again = try trustBundle(allocator, bundle_path, .{ .path = trust_path });
    defer record_again.deinit(allocator);

    try tmp.dir.writeFile(io, .{ .sub_path = "good.zovaext/libdyn_test.dylib", .data = "library two" });
    var changed = try loadBundleInfo(allocator, bundle_path);
    defer changed.deinit(allocator);
    try std.testing.expectError(error.ExtensionUntrusted, ensureTrusted(allocator, changed, .{ .path = trust_path }));
}
