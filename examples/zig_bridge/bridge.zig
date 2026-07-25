const std = @import("std");
const zova = @import("zova");

const HookError = zova.sqlite.Error || error{ExtensionInvalid};

const manifest = zova.ExtensionManifest{
    .name = "codebase_memory_demo",
    .version = "0.1.0",
    .storage_prefix = "_zova_ext_codebase_memory_demo_",
    .zova_abi_min = "0.26.1",
    .capabilities = "sql",
    .required = true,
};

const extension = zova.Extension{
    .manifest = manifest,
    .install = install,
    .check = check,
    .drop = drop,
    .register_sql = registerSql,
};

const registry = zova.ExtensionRegistry.init(&.{extension});

pub export fn zova_extension_entry() callconv(.c) *const zova.Extension {
    return &extension;
}

pub export fn zova_bridge_smoke(db_path: ?[*:0]const u8) callconv(.c) c_int {
    const path = std.mem.span(db_path orelse return 10);
    var db = zova.Database.createWithExtensions(path, registry) catch |err| switch (err) {
        error.DestinationExists => zova.Database.openWithExtensions(path, registry) catch return 11,
        else => return 12,
    };
    defer db.deinit();

    db.installExtension(manifest.name) catch |err| switch (err) {
        error.ExtensionExists => {},
        else => return 20,
    };
    db.checkExtension(manifest.name) catch return 21;

    var stmt = db.prepare("select zova_bridge_demo_value(), zova_bridge_demo_text()") catch return 30;
    defer stmt.deinit();
    if ((stmt.step() catch return 31) != .row) return 32;
    if (stmt.columnInt64(0) != 42) return 33;
    if (!std.mem.eql(u8, stmt.columnText(1), "bridge-ok")) return 34;
    return 0;
}

fn install(db: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    try db.exec(
        \\create table _zova_ext_codebase_memory_demo_meta (
        \\  key text primary key,
        \\  value text not null
        \\)
    );
    var stmt = try db.prepare("insert into _zova_ext_codebase_memory_demo_meta (key, value) values ('installed', '0.1.0')");
    defer stmt.deinit();
    if ((try stmt.step()) != .done) return error.ExtensionInvalid;
}

fn check(db: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    var stmt = try db.prepare("select value from _zova_ext_codebase_memory_demo_meta where key = 'installed'");
    defer stmt.deinit();
    switch (try stmt.step()) {
        .row => if (!std.mem.eql(u8, stmt.columnText(0), "0.1.0")) return error.ExtensionInvalid,
        .done => return error.ExtensionInvalid,
    }
}

fn drop(db: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    try db.exec("drop table _zova_ext_codebase_memory_demo_meta");
}

fn registerSql(db: *zova.sqlite.Database, _: zova.ExtensionManifest) HookError!void {
    const rc = zova.sqlite.c.sqlite3_create_function_v2(
        db.handle,
        "zova_bridge_demo_value",
        0,
        zova.sqlite.c.SQLITE_UTF8 | zova.sqlite.c.SQLITE_DETERMINISTIC,
        null,
        valueFunc,
        null,
        null,
        null,
    );
    if (rc != zova.sqlite.c.SQLITE_OK) return error.SqliteError;

    const text_rc = zova.sqlite.c.sqlite3_create_function_v2(
        db.handle,
        "zova_bridge_demo_text",
        0,
        zova.sqlite.c.SQLITE_UTF8 | zova.sqlite.c.SQLITE_DETERMINISTIC,
        null,
        textFunc,
        null,
        null,
        null,
    );
    if (text_rc != zova.sqlite.c.SQLITE_OK) return error.SqliteError;
}

fn valueFunc(context: ?*zova.sqlite.c.sqlite3_context, argc: c_int, argv: [*c]?*zova.sqlite.c.sqlite3_value) callconv(.c) void {
    _ = argc;
    _ = argv;
    zova.sqlite.c.sqlite3_result_int64(context, 42);
}

fn textFunc(context: ?*zova.sqlite.c.sqlite3_context, argc: c_int, argv: [*c]?*zova.sqlite.c.sqlite3_value) callconv(.c) void {
    _ = argc;
    _ = argv;
    zova.sqlite.resultText(context.?, "bridge-ok");
}
