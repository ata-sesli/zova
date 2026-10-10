//! A Zig author using the portable C descriptor, not the legacy Zig ABI.
//! Built and loaded by test-extensions; bundled as c_test by the fixture.
const plugin = @import("zova_plugin");

fn install(host: *const plugin.Host, connection: ?*anyopaque) callconv(.c) i32 {
    const client: plugin.Client = .{ .host = host, .connection = connection };
    client.exec("CREATE TABLE _zova_ext_c_test_data(id INTEGER)") catch return 1;
    return 0;
}

fn receive(raw: ?*anyopaque, values: ?[*]const plugin.Value, count: u64) callconv(.c) i32 {
    const found: *bool = @ptrCast(@alignCast(raw.?));
    if (count != 1 or values == null) return 1;
    found.* = values.?[0].kind == plugin.value_integer and values.?[0].integer == 1;
    return 0;
}

fn check(host: *const plugin.Host, connection: ?*anyopaque) callconv(.c) i32 {
    const client: plugin.Client = .{ .host = host, .connection = connection };
    const sql = "SELECT count(*) FROM _zova_ext_c_test_data WHERE id = ?";
    const parameters = [_]plugin.Value{.{ .kind = plugin.value_integer, .integer = 1 }};
    var found = false;
    client.storage(&.{ .sql = sql, .sql_len = sql.len, .parameters = &parameters, .parameter_count = 1, .row_limit = 1, .byte_limit = 1024, .row = receive, .user_data = &found }) catch return 1;
    return if (found) 0 else 1;
}

fn drop(host: *const plugin.Host, connection: ?*anyopaque) callconv(.c) i32 {
    const client: plugin.Client = .{ .host = host, .connection = connection };
    client.exec("DROP TABLE _zova_ext_c_test_data") catch return 1;
    return 0;
}

const descriptor: plugin.Descriptor = .{
    .struct_size = @sizeOf(plugin.Descriptor),
    .abi_version = 1,
    .flags = plugin.requires_storage,
    .name = "c_test",
    .version = "1.0.0",
    .storage_prefix = "_zova_ext_c_test_",
    .zova_abi_min = "1.0.0",
    .install = install,
    .check = check,
    .drop = drop,
};

pub export fn zova_plugin_entry_v1(version: u32) callconv(.c) ?*const plugin.Descriptor {
    return if (version == 1) &descriptor else null;
}
