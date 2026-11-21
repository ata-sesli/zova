const api = @import("zova");
pub const panic = api.panic;
export fn zova_opfs_create(request: ?*const api.zova_database_open_request) api.zova_status {
    return api.zova_database_create(request);
}
export fn zova_opfs_open(request: ?*const api.zova_database_open_request) api.zova_status {
    return api.zova_database_open(request);
}
export fn zova_opfs_open_options(request: ?*const api.zova_database_open_options_request) api.zova_status {
    return api.zova_database_open_with_options(request);
}
export fn zova_opfs_open_plugins(request: ?*const api.zova_database_open_plugins_request) api.zova_status {
    return api.zova_database_open_with_plugins(request);
}
export fn zova_opfs_create_plugins(request: ?*const api.zova_database_open_plugins_request) api.zova_status {
    return api.zova_database_create_with_plugins(request);
}
export fn zova_opfs_create_options(request: ?*const api.zova_database_create_options_request) api.zova_status {
    return api.zova_database_create_with_options(request);
}
export fn zova_opfs_open_upgrade(request: ?*const api.zova_database_open_extensions_request) api.zova_status {
    return api.zova_database_open_for_extension_upgrade(request);
}
export fn zova_opfs_open_upgrade_plugins(request: ?*const api.zova_database_open_plugins_request) api.zova_status {
    return api.zova_database_open_for_extension_upgrade_with_plugins(request);
}
export fn zova_opfs_convert(request: ?*const api.zova_convert_sqlite_to_zova_request) api.zova_status {
    return api.zova_convert_sqlite_to_zova(request);
}
