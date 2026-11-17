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
