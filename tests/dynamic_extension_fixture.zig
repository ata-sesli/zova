const std = @import("std");
const zova = @import("zova");
const HookError = zova.sqlite.Error || error{ ExtensionInvalid, OutOfMemory };

const manifest = zova.ExtensionManifest{
    .name = "dyn_test",
    .version = "0.1.0",
    .storage_prefix = "_zova_ext_dyn_test_",
    .zova_abi_min = "0.21.0",
    .capabilities = "sql,dynamic-test",
    .required = true,
    .manifest_json = "{\"extension\":\"dyn_test\",\"version\":\"0.1.0\"}",
};

const dyn_test_extension = zova.Extension{
    .manifest = manifest,
    .install = install,
    .check = check,
    .drop = drop,
    .register_sql = registerSql,
};

pub export fn zova_extension_entry() callconv(.c) *const zova.Extension {
    return &dyn_test_extension;
}

fn install(db: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    try db.exec(
        \\create table _zova_ext_dyn_test_meta (
        \\  key text primary key,
        \\  value text not null
        \\)
    );
    var stmt = try db.prepare("insert into _zova_ext_dyn_test_meta (key, value) values ('installed', '0.1.0')");
    defer stmt.deinit();
    if ((try stmt.step()) != .done) return error.ExtensionInvalid;
}

fn check(db: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    var stmt = try db.prepare("select value from _zova_ext_dyn_test_meta where key = 'installed'");
    defer stmt.deinit();
    switch (try stmt.step()) {
        .row => {
            if (!std.mem.eql(u8, stmt.columnText(0), "0.1.0")) return error.ExtensionInvalid;
        },
        .done => return error.ExtensionInvalid,
    }

    var scalar = try db.prepare("select zova_dyn_test_value()");
    defer scalar.deinit();
    if ((try scalar.step()) != .row) return error.ExtensionInvalid;
    if (scalar.columnInt64(0) != 21) return error.ExtensionInvalid;
}

fn drop(db: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    try db.exec("drop table _zova_ext_dyn_test_meta");
}

fn registerSql(db: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    const rc = zova.sqlite.c.sqlite3_create_function_v2(
        db.handle,
        "zova_dyn_test_value",
        0,
        zova.sqlite.c.SQLITE_UTF8,
        null,
        valueFunc,
        null,
        null,
        null,
    );
    if (rc != zova.sqlite.c.SQLITE_OK) return error.SqliteError;
}

fn valueFunc(context: ?*zova.sqlite.c.sqlite3_context, argc: c_int, argv: [*c]?*zova.sqlite.c.sqlite3_value) callconv(.c) void {
    _ = argc;
    _ = argv;
    zova.sqlite.c.sqlite3_result_int64(context, 21);
}
