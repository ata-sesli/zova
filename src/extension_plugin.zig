//! Portable descriptor adapter. Never changes the legacy Zig Extension layout.
const std = @import("std");
const sqlite = @import("sqlite.zig");
const extension = @import("extension.zig");

pub const entrypoint = "zova_plugin_entry_v1";
pub const Hook = *const fn (*const Host, ?*anyopaque) callconv(.c) i32;
pub const Host = extern struct {
    struct_size: u32 = @sizeOf(Host),
    abi_version: u32 = 1,
    exec_sql: ?*const fn (?*anyopaque, ?[*]const u8, u64) callconv(.c) i32 = execSql,
};
pub const Descriptor = extern struct {
    struct_size: u32,
    abi_version: u32,
    flags: u64 = 0,
    name: ?[*:0]const u8,
    version: ?[*:0]const u8,
    storage_prefix: ?[*:0]const u8,
    zova_abi_min: ?[*:0]const u8,
    capabilities: ?[*:0]const u8 = null,
    install: ?Hook = null,
    check: ?Hook = null,
    drop: ?Hook = null,
    register_sql: ?Hook = null,
};
pub const Phase = enum { install, check, drop, register_sql };
pub const has_upgrade: u64 = 1;
pub const UpgradeDescriptor = extern struct {
    base: Descriptor,
    from_version: ?[*:0]const u8,
    upgrade: ?Hook,
};

pub fn upgradePath(d: *const Descriptor) extension.Error!?extension.Upgrade {
    if (d.flags == 0) return null;
    if (d.flags != has_upgrade or d.struct_size < @sizeOf(UpgradeDescriptor)) return error.ExtensionIncompatible;
    const tail: *const UpgradeDescriptor = @ptrCast(d);
    return .{
        .name = try string(d.name, 64),
        .from_version = try string(tail.from_version, 64),
        .to_version = try string(d.version, 64),
        .plugin_hook = tail.upgrade orelse return error.ExtensionInvalid,
    };
}

fn string(ptr: ?[*:0]const u8, max: usize) extension.Error![]const u8 {
    const value = ptr orelse return error.ExtensionInvalid;
    for (0..max + 1) |i| if (value[i] == 0) return value[0..i];
    return error.ExtensionInvalid;
}

pub fn validate(ptr: ?*const Descriptor) extension.Error!extension.Extension {
    const d = ptr orelse return error.ExtensionInvalid;
    // Read only the fixed two-u32 prefix until size/version are accepted.
    if (d.struct_size < @sizeOf(Descriptor) or d.abi_version != 1) return error.ExtensionIncompatible;
    if (d.flags != 0 and d.flags != has_upgrade) return error.ExtensionIncompatible;
    if (d.flags == has_upgrade and d.struct_size < @sizeOf(UpgradeDescriptor)) return error.ExtensionIncompatible;
    const manifest: extension.Manifest = .{
        .name = try string(d.name, 64),
        .version = try string(d.version, 64),
        .storage_prefix = try string(d.storage_prefix, 128),
        .zova_abi_min = try string(d.zova_abi_min, 64),
        .capabilities = if (d.capabilities != null) try string(d.capabilities, 512) else "",
    };
    try extension.validateManifest(manifest);
    return .{ .manifest = manifest, .install = unavailable, .check = unavailable, .drop = unavailable };
}

fn unavailable(_: *sqlite.Database, _: extension.Manifest) extension.Error!void {
    return error.ExtensionUnavailable;
}

pub fn invoke(d: Descriptor, phase: Phase, db: *sqlite.Database) extension.Error!void {
    const hook = switch (phase) {
        .install => d.install,
        .check => d.check,
        .drop => d.drop,
        .register_sql => d.register_sql,
    } orelse return;
    return invokeHook(hook, db);
}

pub fn invokeHook(hook: Hook, db: *sqlite.Database) extension.Error!void {
    const host: Host = .{};
    switch (hook(&host, db)) {
        0 => {},
        2 => return error.OutOfMemory,
        else => return error.ExtensionInvalid,
    }
}

fn execSql(context: ?*anyopaque, sql: ?[*]const u8, len: u64) callconv(.c) i32 {
    const raw = context orelse return 3;
    const bytes = sql orelse return 3;
    const size = std.math.cast(usize, len) orelse return 3;
    // Bound the host service and reject embedded NUL (sqlite exec uses C strings).
    if (size == 0 or size > 1024 * 1024 or std.mem.indexOfScalar(u8, bytes[0..size], 0) != null) return 3;
    const db: *sqlite.Database = @ptrCast(@alignCast(raw));
    // Match the extension host allocator; page_allocator requires unsupported
    // memory.grow intrinsics in Zig's generated-C WASM backend.
    const terminated = std.heap.c_allocator.dupeZ(u8, bytes[0..size]) catch return 2;
    defer std.heap.c_allocator.free(terminated);
    db.exec(terminated) catch |err| return if (err == error.OutOfMemory) 2 else 1;
    return 0;
}
