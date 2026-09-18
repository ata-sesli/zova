//! Dynamic trusted local extension loading.
//!
//! Supports explicitly selected C-v1 and legacy Zig-native descriptors. A `.zovaext` bundle is
//! local code that the process explicitly trusts and loads; database metadata
//! never contains executable paths and never triggers loading by itself.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("zova_build_options");
const extension = @import("extension.zig");
const plugin = @import("extension_plugin.zig");
const sqlite = @import("sqlite.zig");

/// Fixture library paths emitted by the build system. Empty when the host
/// cannot build portable plugin fixtures. Tests skip when unavailable.
const fixture_options = @import("plugin_fixture_options");

pub const supports_dynamic_loading = build_options.enable_dynamic_extensions;

/// Zig 0.16 removed Windows support from `std.DynLib`, so trusted Windows
/// bundles load through the restricted `LoadLibraryExW`/`GetProcAddress`/
/// `FreeLibrary` API instead. The bundle library path is always a fully
/// qualified path, and `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR` keeps sibling
/// dependencies resolvable from the bundle directory while the process current
/// directory is never searched.
pub const windows_load_library_search_dll_load_dir: u32 = 0x00000100;
pub const windows_load_library_search_default_dirs: u32 = 0x00001000;
pub const windows_dynamic_library_load_flags: u32 =
    windows_load_library_search_dll_load_dir | windows_load_library_search_default_dirs;

const WindowsDynamicLibrary = if (builtin.os.tag == .windows) struct {
    handle: std.os.windows.HMODULE,

    const native = struct {
        extern "kernel32" fn LoadLibraryExW(
            file_name: [*:0]const u16,
            file: ?*anyopaque,
            flags: u32,
        ) callconv(.winapi) ?std.os.windows.HMODULE;
        extern "kernel32" fn GetProcAddress(
            module: std.os.windows.HMODULE,
            name: [*:0]const u8,
        ) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn FreeLibrary(module: std.os.windows.HMODULE) callconv(.winapi) std.os.windows.BOOL;
        extern "kernel32" fn GetModuleFileNameW(
            module: ?std.os.windows.HMODULE,
            filename: [*]u16,
            size: std.os.windows.DWORD,
        ) callconv(.winapi) std.os.windows.DWORD;
        extern "kernel32" fn GetModuleHandleW(
            module_name: ?[*:0]const u16,
        ) callconv(.winapi) ?std.os.windows.HMODULE;
    };

    pub const OpenError = error{ OutOfMemory, LoadFailed };

    /// `path` must be an absolute, fully qualified path. Relative paths would
    /// make the restricted search flags behave unpredictably.
    pub fn open(path: []const u8) OpenError!WindowsDynamicLibrary {
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(std.heap.page_allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return error.LoadFailed,
        };
        defer std.heap.page_allocator.free(wide);
        const handle = native.LoadLibraryExW(wide.ptr, null, windows_dynamic_library_load_flags) orelse
            return error.LoadFailed;
        return .{ .handle = handle };
    }

    pub fn close(self: *WindowsDynamicLibrary) void {
        _ = native.FreeLibrary(self.handle);
        self.* = undefined;
    }

    pub fn lookup(self: *WindowsDynamicLibrary, comptime T: type, name: [:0]const u8) ?T {
        const symbol = native.GetProcAddress(self.handle, name.ptr) orelse return null;
        return @as(T, @ptrCast(@alignCast(symbol)));
    }

    /// Test helper: the fully qualified path this handle resolved to. This is
    /// what LoadLibraryExW actually loaded, so it identifies which same-named
    /// DLL won the restricted dependency search.
    pub fn resolvedPath(self: *WindowsDynamicLibrary, allocator: std.mem.Allocator) ![]u8 {
        return moduleFilePath(self.handle, allocator);
    }

    /// Test helper: the fully qualified path of the loaded module with the
    /// given wide file name, or null when no such module is mapped. Resolving
    /// the dependency module by import name shows which same-named DLL the
    /// restricted search actually selected.
    pub fn loadedModulePath(name: [*:0]const u16, allocator: std.mem.Allocator) !?[]u8 {
        const module = native.GetModuleHandleW(name) orelse return null;
        return try moduleFilePath(module, allocator);
    }

    fn moduleFilePath(module: std.os.windows.HMODULE, allocator: std.mem.Allocator) ![]u8 {
        const max_len = std.os.windows.MAX_PATH + 1;
        var buffer: [max_len]u16 = undefined;
        const written = native.GetModuleFileNameW(module, &buffer, buffer.len);
        if (written == 0) return error.LoadFailed;
        const wide = buffer[0..written];
        // WTF-8 never needs more than 4 bytes per UTF-16 unit.
        const wtf8 = try allocator.alloc(u8, wide.len * 4);
        errdefer allocator.free(wtf8);
        const wtf8_len = std.unicode.wtf16LeToWtf8(wtf8, wide);
        return allocator.realloc(wtf8, wtf8_len);
    }
} else struct {};

const DynamicLibrary = if (!supports_dynamic_loading)
    struct {}
else if (builtin.os.tag == .windows)
    WindowsDynamicLibrary
else
    std.DynLib;

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

const max_json_token_len = 64 * 1024;

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
    plugins: []plugin.Descriptor,
    upgrades: []extension.Upgrade,

    pub fn init(allocator: std.mem.Allocator, registries: []const extension.Registry) Error!OwnedRegistry {
        var total: usize = 0;
        for (registries) |item| total += item.extensions.len;

        const items = try allocator.alloc(extension.Extension, total);
        errdefer allocator.free(items);
        var plugin_total: usize = 0;
        var upgrade_total: usize = 0;
        for (registries) |item| upgrade_total += item.upgrades.len;
        const upgrades = try allocator.alloc(extension.Upgrade, upgrade_total);
        errdefer allocator.free(upgrades);
        var upgrade_index: usize = 0;
        for (registries) |item| {
            @memcpy(upgrades[upgrade_index..][0..item.upgrades.len], item.upgrades);
            upgrade_index += item.upgrades.len;
        }
        for (registries) |item| plugin_total += item.plugins.len;
        const plugins = try allocator.alloc(plugin.Descriptor, plugin_total);
        errdefer allocator.free(plugins);
        var plugin_index: usize = 0;
        for (registries) |item| {
            @memcpy(plugins[plugin_index..][0..item.plugins.len], item.plugins);
            plugin_index += item.plugins.len;
        }

        var index: usize = 0;
        for (registries) |item| {
            @memcpy(items[index..][0..item.extensions.len], item.extensions);
            index += item.extensions.len;
        }

        const owned: OwnedRegistry = .{ .allocator = allocator, .extensions = items, .plugins = plugins, .upgrades = upgrades };
        try owned.registry().validate();
        return owned;
    }

    pub fn registry(self: OwnedRegistry) extension.Registry {
        return .{ .extensions = self.extensions, .plugins = self.plugins, .upgrades = self.upgrades };
    }

    pub fn deinit(self: *OwnedRegistry) void {
        self.allocator.free(self.extensions);
        self.allocator.free(self.plugins);
        self.allocator.free(self.upgrades);
    }
};

pub const DynamicExtensionSet = struct {
    allocator: std.mem.Allocator,
    libraries: []DynamicLibrary,
    extensions: []extension.Extension,
    plugins: []plugin.Descriptor,
    upgrades: []extension.Upgrade,

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
                .plugins = try allocator.alloc(plugin.Descriptor, 0),
                .upgrades = try allocator.alloc(extension.Upgrade, 0),
            };
        }

        return loadTrustedBundlesDynamic(allocator, bundle_paths, options);
    }

    fn loadTrustedBundlesDynamic(
        allocator: std.mem.Allocator,
        bundle_paths: []const []const u8,
        options: TrustStoreOptions,
    ) Error!DynamicExtensionSet {
        var libraries: std.ArrayList(DynamicLibrary) = .empty;
        errdefer {
            for (libraries.items) |*library| library.close();
            libraries.deinit(allocator);
        }

        var extensions: std.ArrayList(extension.Extension) = .empty;
        errdefer extensions.deinit(allocator);
        var plugins: std.ArrayList(plugin.Descriptor) = .empty;
        defer plugins.deinit(allocator);
        var upgrades: std.ArrayList(extension.Upgrade) = .empty;
        defer upgrades.deinit(allocator);

        for (bundle_paths) |bundle_path| {
            var info = try loadBundleInfo(allocator, bundle_path);
            defer info.deinit(allocator);
            try ensureTrusted(allocator, info, options);

            var library = DynamicLibrary.open(info.library_path) catch return error.ExtensionLoadFailed;
            errdefer library.close();

            const loaded = try loadDescriptor(allocator, &library, info);
            try extensions.append(allocator, loaded.extension);
            if (loaded.plugin) |descriptor| try plugins.append(allocator, descriptor);
            if (loaded.upgrade) |path| try upgrades.append(allocator, path);
            // Transfer the handle last: avoid closing it twice on allocation failure.
            try libraries.append(allocator, library);
        }

        const owned_extensions = try extensions.toOwnedSlice(allocator);
        errdefer allocator.free(owned_extensions);
        const owned_libraries = try libraries.toOwnedSlice(allocator);
        errdefer {
            for (owned_libraries) |*library| library.close();
            allocator.free(owned_libraries);
        }
        const owned_plugins = try plugins.toOwnedSlice(allocator);
        errdefer allocator.free(owned_plugins);
        const owned_upgrades = try upgrades.toOwnedSlice(allocator);
        errdefer allocator.free(owned_upgrades);

        const set: DynamicExtensionSet = .{
            .allocator = allocator,
            .libraries = owned_libraries,
            .extensions = owned_extensions,
            .plugins = owned_plugins,
            .upgrades = owned_upgrades,
        };
        try set.registry().validate();
        return set;
    }

    pub fn registry(self: DynamicExtensionSet) extension.Registry {
        return .{ .extensions = self.extensions, .plugins = self.plugins, .upgrades = self.upgrades };
    }

    pub fn deinit(self: *DynamicExtensionSet) void {
        if (comptime supports_dynamic_loading) {
            for (self.libraries) |*library| library.close();
        }
        self.allocator.free(self.libraries);
        self.allocator.free(self.extensions);
        self.allocator.free(self.plugins);
        self.allocator.free(self.upgrades);
    }
};

pub const LoadedBundle = struct {
    library: DynamicLibrary,
    extensions: [1]extension.Extension,
    plugins: [1]plugin.Descriptor = undefined,
    plugin_count: usize = 0,
    upgrades: [1]extension.Upgrade = undefined,
    upgrade_count: usize = 0,

    pub fn load(allocator: std.mem.Allocator, bundle_path: []const u8) Error!LoadedBundle {
        if (comptime !supports_dynamic_loading) return error.ExtensionLoadFailed;

        return loadDynamic(allocator, bundle_path);
    }

    fn loadDynamic(allocator: std.mem.Allocator, bundle_path: []const u8) Error!LoadedBundle {
        var info = try loadBundleInfo(allocator, bundle_path);
        defer info.deinit(allocator);

        var library = DynamicLibrary.open(info.library_path) catch return error.ExtensionLoadFailed;
        errdefer library.close();

        const loaded = try loadDescriptor(allocator, &library, info);

        var bundle = LoadedBundle{
            .library = library,
            .extensions = .{loaded.extension},
        };
        if (loaded.plugin) |descriptor| {
            bundle.plugins[0] = descriptor;
            bundle.plugin_count = 1;
        }
        if (loaded.upgrade) |path| {
            bundle.upgrades[0] = path;
            bundle.upgrade_count = 1;
        }
        try bundle.registry().validate();
        return bundle;
    }

    pub fn registry(self: *const LoadedBundle) extension.Registry {
        return .{ .extensions = self.extensions[0..], .plugins = self.plugins[0..self.plugin_count], .upgrades = self.upgrades[0..self.upgrade_count] };
    }

    pub fn deinit(self: *LoadedBundle) void {
        if (comptime supports_dynamic_loading) self.library.close();
    }
};

pub fn verifyBundleEntrypoint(allocator: std.mem.Allocator, bundle_path: []const u8) Error!void {
    var bundle = try LoadedBundle.load(allocator, bundle_path);
    defer bundle.deinit();
}

fn loadDescriptor(allocator: std.mem.Allocator, library: *DynamicLibrary, info: BundleInfo) Error!struct { extension: extension.Extension, plugin: ?plugin.Descriptor = null, upgrade: ?extension.Upgrade = null } {
    // The manifest explicitly selects the new signature. No symbol probing or
    // fallback may reinterpret an old Zig descriptor as a C structure.
    if (std.mem.eql(u8, info.manifest.entrypoint, plugin.entrypoint)) {
        const Entry = *const fn (u32) callconv(.c) ?*const plugin.Descriptor;
        const entry = library.lookup(Entry, plugin.entrypoint) orelse return error.ExtensionLoadFailed;
        const descriptor = entry(1);
        const loaded = try plugin.validate(descriptor);
        try ensureLoadedExtensionMatches(info, loaded);
        return .{ .extension = loaded, .plugin = descriptor.?.*, .upgrade = try plugin.upgradePath(descriptor.?) };
    }
    const entry_name = try allocator.dupeZ(u8, info.manifest.entrypoint);
    defer allocator.free(entry_name);
    const Entry = *const fn () callconv(.c) *const extension.Extension;
    const entry = library.lookup(Entry, entry_name) orelse return error.ExtensionLoadFailed;
    const loaded = entry().*;
    try ensureLoadedExtensionMatches(info, loaded);
    return .{ .extension = loaded };
}

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

    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();

    var records: std.ArrayList(TrustRecord) = .empty;
    errdefer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit(allocator);
    }

    try expectJsonToken(&scanner, allocator, .object_begin);
    var saw_version = false;
    var saw_extensions = false;
    while (true) {
        const key = try nextJsonObjectKey(&scanner, allocator) orelse break;
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "version")) {
            if (saw_version) return error.ExtensionInvalid;
            saw_version = true;
            if (try expectJsonU32(&scanner, allocator) != trust_store_version) return error.ExtensionInvalid;
        } else if (std.mem.eql(u8, key, "extensions")) {
            if (saw_extensions) return error.ExtensionInvalid;
            saw_extensions = true;
            try expectJsonToken(&scanner, allocator, .array_begin);
            while (true) {
                if (try nextJsonArrayEnd(&scanner, allocator)) break;
                const record = try parseTrustRecord(allocator, &scanner);
                errdefer {
                    var mutable = record;
                    mutable.deinit(allocator);
                }
                try records.append(allocator, record);
            }
        } else {
            return error.ExtensionInvalid;
        }
    }
    if (!saw_version or !saw_extensions) return error.ExtensionInvalid;
    try expectJsonToken(&scanner, allocator, .end_of_document);

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
    if (getenv("LOCALAPPDATA")) |config| return std.fs.path.join(allocator, &.{ config, "zova", "trusted_extensions.json" });
    if (getenv("APPDATA")) |config| return std.fs.path.join(allocator, &.{ config, "zova", "trusted_extensions.json" });
    return error.ExtensionInvalid;
}

fn parseBundleManifest(allocator: std.mem.Allocator, bytes: []const u8) Error!BundleManifest {
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();

    var fields: ManifestFields = .{};
    errdefer fields.deinit(allocator);

    try expectJsonToken(&scanner, allocator, .object_begin);
    while (true) {
        const key = try nextJsonObjectKey(&scanner, allocator) orelse break;
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "name")) {
            if (fields.name != null) return error.ExtensionInvalid;
            fields.name = try expectJsonStringOwned(&scanner, allocator);
        } else if (std.mem.eql(u8, key, "version")) {
            if (fields.version != null) return error.ExtensionInvalid;
            fields.version = try expectJsonStringOwned(&scanner, allocator);
        } else if (std.mem.eql(u8, key, "storage_prefix")) {
            if (fields.storage_prefix != null) return error.ExtensionInvalid;
            fields.storage_prefix = try expectJsonStringOwned(&scanner, allocator);
        } else if (std.mem.eql(u8, key, "zova_abi_min")) {
            if (fields.zova_abi_min != null) return error.ExtensionInvalid;
            fields.zova_abi_min = try expectJsonStringOwned(&scanner, allocator);
        } else if (std.mem.eql(u8, key, "capabilities")) {
            if (fields.capabilities != null) return error.ExtensionInvalid;
            fields.capabilities = try expectJsonStringOwned(&scanner, allocator);
        } else if (std.mem.eql(u8, key, "library")) {
            if (fields.library != null) return error.ExtensionInvalid;
            fields.library = try expectJsonStringOwned(&scanner, allocator);
        } else if (std.mem.eql(u8, key, "entrypoint")) {
            if (fields.entrypoint != null) return error.ExtensionInvalid;
            fields.entrypoint = try expectJsonOptionalStringOwned(&scanner, allocator, default_entrypoint);
        } else {
            return error.ExtensionInvalid;
        }
    }
    try expectJsonToken(&scanner, allocator, .end_of_document);
    if (fields.entrypoint == null) fields.entrypoint = try allocator.dupe(u8, default_entrypoint);

    const result: BundleManifest = .{
        .name = fields.name orelse return error.ExtensionInvalid,
        .version = fields.version orelse return error.ExtensionInvalid,
        .storage_prefix = fields.storage_prefix orelse return error.ExtensionInvalid,
        .zova_abi_min = fields.zova_abi_min orelse return error.ExtensionInvalid,
        .capabilities = fields.capabilities orelse return error.ExtensionInvalid,
        .library = fields.library orelse return error.ExtensionInvalid,
        .entrypoint = fields.entrypoint orelse unreachable,
    };
    fields = .{};
    return result;
}

const ManifestFields = struct {
    name: ?[]u8 = null,
    version: ?[]u8 = null,
    storage_prefix: ?[]u8 = null,
    zova_abi_min: ?[]u8 = null,
    capabilities: ?[]u8 = null,
    library: ?[]u8 = null,
    entrypoint: ?[]u8 = null,

    fn deinit(self: *ManifestFields, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.version) |value| allocator.free(value);
        if (self.storage_prefix) |value| allocator.free(value);
        if (self.zova_abi_min) |value| allocator.free(value);
        if (self.capabilities) |value| allocator.free(value);
        if (self.library) |value| allocator.free(value);
        if (self.entrypoint) |value| allocator.free(value);
    }
};

const TrustRecordFields = struct {
    name: ?[]u8 = null,
    version: ?[]u8 = null,
    storage_prefix: ?[]u8 = null,
    bundle_path: ?[]u8 = null,
    manifest_sha256: ?[64]u8 = null,
    library_sha256: ?[64]u8 = null,
    trusted_at_unix: ?i64 = null,

    fn deinit(self: *TrustRecordFields, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.version) |value| allocator.free(value);
        if (self.storage_prefix) |value| allocator.free(value);
        if (self.bundle_path) |value| allocator.free(value);
    }
};

fn parseTrustRecord(allocator: std.mem.Allocator, scanner: *std.json.Scanner) Error!TrustRecord {
    var fields: TrustRecordFields = .{};
    errdefer fields.deinit(allocator);

    while (true) {
        const key = try nextJsonObjectKey(scanner, allocator) orelse break;
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "name")) {
            if (fields.name != null) return error.ExtensionInvalid;
            fields.name = try expectJsonStringOwned(scanner, allocator);
        } else if (std.mem.eql(u8, key, "version")) {
            if (fields.version != null) return error.ExtensionInvalid;
            fields.version = try expectJsonStringOwned(scanner, allocator);
        } else if (std.mem.eql(u8, key, "storage_prefix")) {
            if (fields.storage_prefix != null) return error.ExtensionInvalid;
            fields.storage_prefix = try expectJsonStringOwned(scanner, allocator);
        } else if (std.mem.eql(u8, key, "bundle_path")) {
            if (fields.bundle_path != null) return error.ExtensionInvalid;
            fields.bundle_path = try expectJsonStringOwned(scanner, allocator);
        } else if (std.mem.eql(u8, key, "manifest_sha256")) {
            if (fields.manifest_sha256 != null) return error.ExtensionInvalid;
            fields.manifest_sha256 = try expectJsonHex64(scanner, allocator);
        } else if (std.mem.eql(u8, key, "library_sha256")) {
            if (fields.library_sha256 != null) return error.ExtensionInvalid;
            fields.library_sha256 = try expectJsonHex64(scanner, allocator);
        } else if (std.mem.eql(u8, key, "trusted_at_unix")) {
            if (fields.trusted_at_unix != null) return error.ExtensionInvalid;
            fields.trusted_at_unix = try expectJsonI64(scanner, allocator);
        } else {
            return error.ExtensionInvalid;
        }
    }

    const result: TrustRecord = .{
        .name = fields.name orelse return error.ExtensionInvalid,
        .version = fields.version orelse return error.ExtensionInvalid,
        .storage_prefix = fields.storage_prefix orelse return error.ExtensionInvalid,
        .bundle_path = fields.bundle_path orelse return error.ExtensionInvalid,
        .manifest_sha256 = fields.manifest_sha256 orelse return error.ExtensionInvalid,
        .library_sha256 = fields.library_sha256 orelse return error.ExtensionInvalid,
        .trusted_at_unix = fields.trusted_at_unix orelse return error.ExtensionInvalid,
    };
    fields = .{};
    return result;
}

fn nextJsonToken(scanner: *std.json.Scanner, allocator: std.mem.Allocator) Error!std.json.Token {
    return scanner.nextAllocMax(allocator, .alloc_if_needed, max_json_token_len) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ExtensionInvalid,
    };
}

fn freeJsonToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |value| allocator.free(value),
        else => {},
    }
}

fn expectJsonToken(scanner: *std.json.Scanner, allocator: std.mem.Allocator, expected: std.meta.Tag(std.json.Token)) Error!void {
    const token = try nextJsonToken(scanner, allocator);
    defer freeJsonToken(allocator, token);
    if (std.meta.activeTag(token) != expected) return error.ExtensionInvalid;
}

fn nextJsonObjectKey(scanner: *std.json.Scanner, allocator: std.mem.Allocator) Error!?[]u8 {
    const token = try nextJsonToken(scanner, allocator);
    defer freeJsonToken(allocator, token);
    switch (token) {
        .object_end => return null,
        .string, .allocated_string => |value| return try allocator.dupe(u8, value),
        else => return error.ExtensionInvalid,
    }
}

fn nextJsonArrayEnd(scanner: *std.json.Scanner, allocator: std.mem.Allocator) Error!bool {
    const token = try nextJsonToken(scanner, allocator);
    defer freeJsonToken(allocator, token);
    switch (token) {
        .array_end => return true,
        .object_begin => return false,
        else => return error.ExtensionInvalid,
    }
}

fn expectJsonStringOwned(scanner: *std.json.Scanner, allocator: std.mem.Allocator) Error![]u8 {
    const token = try nextJsonToken(scanner, allocator);
    defer freeJsonToken(allocator, token);
    switch (token) {
        .string, .allocated_string => |value| return try allocator.dupe(u8, value),
        else => return error.ExtensionInvalid,
    }
}

fn expectJsonOptionalStringOwned(
    scanner: *std.json.Scanner,
    allocator: std.mem.Allocator,
    default_value: []const u8,
) Error![]u8 {
    const token = try nextJsonToken(scanner, allocator);
    defer freeJsonToken(allocator, token);
    switch (token) {
        .null => return try allocator.dupe(u8, default_value),
        .string, .allocated_string => |value| return try allocator.dupe(u8, value),
        else => return error.ExtensionInvalid,
    }
}

fn expectJsonHex64(scanner: *std.json.Scanner, allocator: std.mem.Allocator) Error![64]u8 {
    const token = try nextJsonToken(scanner, allocator);
    defer freeJsonToken(allocator, token);
    switch (token) {
        .string, .allocated_string => |value| return parseHex64(value),
        else => return error.ExtensionInvalid,
    }
}

fn expectJsonU32(scanner: *std.json.Scanner, allocator: std.mem.Allocator) Error!u32 {
    const token = try nextJsonToken(scanner, allocator);
    defer freeJsonToken(allocator, token);
    const value = switch (token) {
        .number, .allocated_number => |raw| raw,
        else => return error.ExtensionInvalid,
    };
    if (std.mem.indexOfAny(u8, value, ".eE+") != null) return error.ExtensionInvalid;
    return std.fmt.parseInt(u32, value, 10) catch return error.ExtensionInvalid;
}

fn expectJsonI64(scanner: *std.json.Scanner, allocator: std.mem.Allocator) Error!i64 {
    const token = try nextJsonToken(scanner, allocator);
    defer freeJsonToken(allocator, token);
    const value = switch (token) {
        .number, .allocated_number => |raw| raw,
        else => return error.ExtensionInvalid,
    };
    if (std.mem.indexOfAny(u8, value, ".eE+") != null) return error.ExtensionInvalid;
    return std.fmt.parseInt(i64, value, 10) catch return error.ExtensionInvalid;
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
    // Bundles are flat directories and manifests only use '/'. Reject native
    // Windows separators so a manifest cannot smuggle a traversal or an
    // alternate path interpretation past the containment check.
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.ExtensionInvalid;
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
    const ts = std.Io.Clock.now(.real, defaultIo());
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
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
        \\  "zova_abi_min": "1.0.0",
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
        \\  "zova_abi_min": "1.0.0",
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

test "dynamic extension bundle validation rejects native Windows separators" {
    try std.testing.expectError(error.ExtensionInvalid, validateRelativeLibraryPath("..\\evil.dll"));
    try std.testing.expectError(error.ExtensionInvalid, validateRelativeLibraryPath("nested\\lib.dll"));
    try std.testing.expectError(error.ExtensionInvalid, validateRelativeLibraryPath("C:\\evil.dll"));
    try validateRelativeLibraryPath("libdyn_test.dll");
}

test "windows dynamic library uses restricted dependency search flags" {
    // LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR keeps sibling bundle dependencies
    // resolvable; LOAD_LIBRARY_SEARCH_DEFAULT_DIRS keeps the safe default
    // roots. The unrestricted legacy search path is never requested.
    try std.testing.expectEqual(@as(u32, 0x00000100), windows_load_library_search_dll_load_dir);
    try std.testing.expectEqual(@as(u32, 0x00001000), windows_load_library_search_default_dirs);
    try std.testing.expectEqual(@as(u32, 0x00001100), windows_dynamic_library_load_flags);
}

test "windows trust records carry a real wall-clock timestamp" {
    if (comptime !supports_dynamic_loading) return error.SkipZigTest;
    // The pre-Windows-support loader returned 0 unconditionally on Windows,
    // which would surface as the Unix epoch in `zova extensions verify`.
    const lower_bound = unixTimestamp();
    try std.testing.expect(lower_bound > 1_752_000_000);
    const upper_bound = unixTimestamp();
    try std.testing.expect(lower_bound <= upper_bound);
}

test "windows dynamic library loads a system module and resolves symbols" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.LoadFailed, WindowsDynamicLibrary.open("Z:\\zova-missing\\missing.dll"));

    const system_root = getenv("SystemRoot") orelse return error.SkipZigTest;
    const path = try std.fs.path.join(allocator, &.{ system_root, "System32", "kernel32.dll" });
    defer allocator.free(path);

    var library = try WindowsDynamicLibrary.open(path);
    defer library.close();

    const GetLastErrorFn = *const fn () callconv(.winapi) std.os.windows.DWORD;
    const get_last_error = library.lookup(GetLastErrorFn, "GetLastError") orelse return error.TestUnexpectedResult;
    _ = get_last_error();
    try std.testing.expect(library.lookup(*anyopaque, "zova_missing_symbol") == null);
    const resolved = try library.resolvedPath(allocator);
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.eql(u8, std.fs.path.basename(resolved), "kernel32.dll"));
}

test "windows bundle dependency resolves from the bundle directory, never the current directory" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    if (fixture_options.plugin_with_dependency_fixture.len == 0 or
        fixture_options.plugin_dependency_fixture.len == 0 or
        fixture_options.plugin_rogue_dependency_fixture.len == 0)
        return error.SkipZigTest;

    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The dependency DLL keeps its unqualified import name and the plugin is
    // the dedicated dependency-aware fixture linked against it. A conflicting
    // same-named DLL in the process current directory must lose to the bundle
    // sibling because LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR wins.
    const dependency_name = "plugin_dependency_fixture.dll";

    const dependency_bytes = try std.Io.Dir.cwd().readFileAlloc(io, fixture_options.plugin_dependency_fixture, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(dependency_bytes);
    const rogue_dependency_bytes = try std.Io.Dir.cwd().readFileAlloc(io, fixture_options.plugin_rogue_dependency_fixture, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(rogue_dependency_bytes);
    const plugin_bytes = try std.Io.Dir.cwd().readFileAlloc(io, fixture_options.plugin_with_dependency_fixture, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(plugin_bytes);

    // Bundle: extension.json + plugin.dll + sibling dependency DLL.
    const library_name = if (builtin.os.tag == .macos)
        try std.fmt.allocPrint(allocator, "libplugin.dylib", .{})
    else if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(allocator, "plugin.dll", .{})
    else
        try std.fmt.allocPrint(allocator, "libplugin.so", .{});
    defer allocator.free(library_name);
    try tmp.dir.createDir(io, "bundle.zovaext", .default_dir);
    const library_sub_path = try std.fmt.allocPrint(allocator, "bundle.zovaext/{s}", .{library_name});
    defer allocator.free(library_sub_path);
    try tmp.dir.writeFile(io, .{ .sub_path = library_sub_path, .data = plugin_bytes });
    const dependency_sub_path = try std.fmt.allocPrint(allocator, "bundle.zovaext/{s}", .{dependency_name});
    defer allocator.free(dependency_sub_path);
    try tmp.dir.writeFile(io, .{ .sub_path = dependency_sub_path, .data = dependency_bytes });
    const manifest = try std.fmt.allocPrint(allocator,
        \\{{"name":"c_test","version":"1.0.0","storage_prefix":"_zova_ext_c_test_","zova_abi_min":"1.0.0","capabilities":"","library":"{s}","entrypoint":"zova_plugin_entry_v1"}}
    , .{library_name});
    defer allocator.free(manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = "bundle.zovaext/extension.json", .data = manifest });

    // Attacker-controlled same-named DLL in the process current directory. It
    // exports a failing marker, so if the loader resolved the dependency from
    // here instead of the bundle, the plugin hooks would refuse to run.
    const cwd_dependency_sub_path = try std.fmt.allocPrint(allocator, "{s}", .{dependency_name});
    defer allocator.free(cwd_dependency_sub_path);
    try tmp.dir.writeFile(io, .{ .sub_path = cwd_dependency_sub_path, .data = rogue_dependency_bytes });

    // Make the tmp directory (which holds both the bundle and the rogue DLL)
    // the process current directory. The restricted search must still resolve
    // the dependency from the bundle directory.
    const tmp_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(tmp_path);
    const previous_cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(previous_cwd);
    try std.process.setCurrentPath(io, tmp_path);
    defer std.process.setCurrentPath(io, previous_cwd) catch {};

    const bundle_path = "bundle.zovaext";
    const trust_path = "trusted_extensions.json";

    try std.testing.expectError(error.ExtensionUntrusted, DynamicExtensionSet.loadTrustedBundles(allocator, &.{bundle_path}, .{ .path = trust_path }));
    var record = try trustBundle(allocator, bundle_path, .{ .path = trust_path });
    defer record.deinit(allocator);

    // Load the bundle's plugin library itself, not the bundle directory: the
    // dependency import resolution only happens when a real module with an
    // import table is loaded.
    const plugin_library_path = try std.fs.path.join(allocator, &.{ record.bundle_path, library_name });
    defer allocator.free(plugin_library_path);
    var loaded = try DynamicLibrary.open(plugin_library_path);

    // The dependency module mapped under its unqualified import name must be
    // the bundle sibling, not the same-named DLL in the process current
    // directory. That only holds when LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR beat
    // the current directory during import resolution.
    const dependency_name_wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, dependency_name);
    defer allocator.free(dependency_name_wide);
    const resolved = (try DynamicLibrary.loadedModulePath(dependency_name_wide.ptr, allocator)) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.eql(u8, std.fs.path.basename(resolved), dependency_name));
    try std.testing.expect(std.mem.indexOf(u8, resolved, "bundle.zovaext") != null);

    // The plugin entrypoint must be reachable through the restricted loader.
    const Entry = *const fn (u32) callconv(.c) ?*const anyopaque;
    try std.testing.expect(loaded.lookup(Entry, "zova_plugin_entry_v1") != null);
    loaded.close();

    // The full trusted flow must work too: install dispatches through the
    // sibling dependency marker, proving the bundle dependency was used.
    var set = try DynamicExtensionSet.loadTrustedBundles(allocator, &.{bundle_path}, .{ .path = trust_path });
    defer set.deinit();
    var owned = try OwnedRegistry.init(allocator, &.{set.registry()});
    defer owned.deinit();
    var db = try sqlite.Database.open(":memory:");
    defer db.deinit();
    try db.exec(extension.extensions_schema_sql);
    try extension.install(&db, owned.registry(), "c_test", null);
    try db.exec("INSERT INTO _zova_ext_c_test_data VALUES(1)");
    try extension.check(&db, set.registry(), "c_test");
    try extension.drop(&db, set.registry(), "c_test", null);
}
